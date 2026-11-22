param([Parameter(Mandatory = $true)][string]$ConfigPath)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'state-io.ps1')
$config = Read-LingoJson -Path $ConfigPath -ThrowOnError
. (Join-Path $PSScriptRoot 'credential-store.ps1')
. (Join-Path $PSScriptRoot 'resource-planner.ps1')
. (Join-Path $PSScriptRoot 'media-normalization.ps1')
. (Join-Path $PSScriptRoot 'media-cache.ps1')
. (Join-Path $PSScriptRoot 'transfer-slots.ps1')
. (Join-Path $PSScriptRoot 'resource-pipeline.ps1')
. (Join-Path $PSScriptRoot 'subtitle-document.ps1')
. (Join-Path $PSScriptRoot 'playlist-folders.ps1')

$script:statusPath = [string]$config.statusPath
$script:status = Read-LingoJson -Path $script:statusPath -ThrowOnError
$script:priorItems = @($script:status.items)
$script:status.items = [System.Collections.ArrayList]::new()
foreach ($prior in $script:priorItems) { [void]$script:status.items.Add($prior) }
$script:lastWrite = [DateTime]::MinValue
$script:currentItem = $null
$script:currentAsset = $null
$script:jobsRoot = Split-Path -Parent $script:statusPath
$script:controlPath = if ($config.controlPath) { [string]$config.controlPath } else { Join-Path $script:jobsRoot "$($config.id).control.json" }
$script:processing = $false
$script:storeRoot = if ($config.storeRoot) { [string]$config.storeRoot } else { $script:jobsRoot }
$script:cookieMarkerPath = Join-Path $script:jobsRoot "$($config.id).cookie-temp.json"
$script:mediaPidPath = Join-Path $script:jobsRoot "$($config.id).media.pid.json"
$script:ffprobePath = [string]$config.ffprobePath
$script:partialRoot = Join-Path ([string]$config.path) '.lingosave-partials'
[void][System.IO.Directory]::CreateDirectory($script:partialRoot)
$extraPaths = @([string]$config.ffmpegDirectory)
if ($config.denoPath) { $extraPaths += (Split-Path -Parent ([string]$config.denoPath)) }
$env:PATH = ($extraPaths -join ';') + ';' + $env:PATH
$env:PYTHONIOENCODING = 'utf-8'

$script:nativeJobAvailable = $false
try {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

public sealed class LingoResourceProcessJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimit {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public IntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public IntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimit {
        public BasicLimit BasicLimitInformation;
        public IoCounters IoInfo;
        public IntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
    private IntPtr handle;
    private LingoResourceProcessJob(IntPtr value) { handle = value; }
    public static LingoResourceProcessJob Create() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            ExtendedLimit limits = new ExtendedLimit();
            limits.BasicLimitInformation.LimitFlags = 0x2000;
            int size = Marshal.SizeOf(typeof(ExtendedLimit));
            IntPtr pointer = Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(limits, pointer, false);
                if (!SetInformationJobObject(job, 9, pointer, (uint)size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { Marshal.FreeHGlobal(pointer); }
            return new LingoResourceProcessJob(job);
        } catch { CloseHandle(job); throw; }
    }
    public bool Add(Process process) { return AssignProcessToJobObject(handle, process.Handle); }
    public void Terminate() { if (handle != IntPtr.Zero) TerminateJobObject(handle, 1); }
    public void Dispose() { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
}
'@ -ErrorAction Stop
    $script:nativeJobAvailable = $true
} catch { }

function Save-ResourceStatus {
    param([switch]$Force)
    if (-not $Force -and ([DateTime]::UtcNow - $script:lastWrite).TotalMilliseconds -lt 350) { return }
    $saved = Write-LingoJson -Path $script:statusPath -Value $script:status -Depth 15 -BestEffort:(-not $Force)
    if ($saved) { $script:lastWrite = [DateTime]::UtcNow }
}

function Set-TransferPhase {
    param([string]$Phase)
    Set-LingoObjectField -Object $script:status -Name 'phase' -Value $Phase
    if ($script:currentItem) { Set-LingoObjectField -Object $script:currentItem -Name 'phase' -Value $Phase }
    if ($script:currentAsset) { Set-LingoObjectField -Object $script:currentAsset -Name 'stage' -Value $Phase }
}

function Stop-TransferRates {
    $script:status.speedBytesPerSecond = $null
    $script:status.etaSeconds = $null
    foreach ($record in @($script:currentItem, $script:currentAsset)) {
        if ($record) { Set-LingoObjectField -Object $record -Name 'speedBytesPerSecond' -Value $null; Set-LingoObjectField -Object $record -Name 'etaSeconds' -Value $null }
    }
}

function Save-ItemRecord {
    param($Item)
    for ($i = 0; $i -lt $script:status.items.Count; $i++) {
        $old = $script:status.items[$i]
        if ([string]$old.url -ceq [string]$Item.url -and [string]$old.id -ceq [string]$Item.id -and (Test-LingoPlaylistScope -First $old -Second $Item)) { $script:status.items[$i] = $Item; return }
    }
    [void]$script:status.items.Add($Item)
}

function Save-AssetRecord {
    param($Item, $Record)
    for ($i = 0; $i -lt $Item.assets.Count; $i++) {
        if ([string]$Item.assets[$i].key -ceq [string]$Record.key) { $Item.assets[$i] = $Record; return }
    }
    [void]$Item.assets.Add($Record)
}

function Wait-NetworkRetry {
    param([int]$Attempt, [string]$Message)
    Assert-LingoTransferAllowed -ControlPath $script:controlPath
    $seconds = [int][math]::Min(30, [math]::Pow(2, [math]::Min(5, $Attempt)))
    $until = [DateTime]::UtcNow.AddSeconds($seconds)
    $script:status.status = 'waiting_network'
    $script:status.message = "网络暂时不可用，$seconds 秒后重试"
    Set-LingoObjectField -Object $script:status -Name 'retryAt' -Value $until.ToString('o')
    Set-LingoObjectField -Object $script:status -Name 'retryCount' -Value $Attempt
    if ($script:currentItem) { $script:currentItem.status = 'waiting_network' }
    if ($script:currentAsset) { $script:currentAsset.status = 'waiting_network' }
    Stop-TransferRates
    Save-ResourceStatus -Force
    while ([DateTime]::UtcNow -lt $until) { Assert-LingoTransferAllowed -ControlPath $script:controlPath; Start-Sleep -Milliseconds 150 }
    Assert-LingoTransferAllowed -ControlPath $script:controlPath
    $script:status.status = 'running'
    $script:status.message = '正在恢复下载'
    Set-LingoObjectField -Object $script:status -Name 'retryAt' -Value $null
    if ($script:currentItem) { $script:currentItem.status = 'running' }
    if ($script:currentAsset) { $script:currentAsset.status = 'running' }
    Save-ResourceStatus -Force
}

function Reset-TransferStatus {
    $script:status.progress = $null
    $script:status.speedBytesPerSecond = $null
    $script:status.downloadedBytes = $null
    $script:status.totalBytes = $null
    $script:status.etaSeconds = $null
    if ($script:currentItem) {
        $script:currentItem.progress = $null
        $script:currentItem.speedBytesPerSecond = $null
        $script:currentItem.downloadedBytes = $null
        $script:currentItem.totalBytes = $null
        $script:currentItem.etaSeconds = $null
    }
}

function Convert-Number {
    param([string]$Text)
    if (-not $Text -or $Text -eq 'NA' -or $Text -eq 'None') { return $null }
    $number = 0.0
    if ([double]::TryParse($Text.Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $number }
    return $null
}

function Update-Progress {
    param([string]$Line)
    $values = $Line.Substring('__LINGO_PROGRESS__'.Length) -split '\|', 6
    if ($values.Count -lt 6) { return }
    $percent = Convert-Number ($values[0] -replace '[^0-9.]', '')
    $speed = Convert-Number $values[1]
    $downloaded = Convert-Number $values[2]
    $total = Convert-Number $values[3]
    if ($null -eq $total) { $total = Convert-Number $values[4] }
    $eta = Convert-Number $values[5]
    # PowerShell 5 selects Math.Min(int,int) when the first argument is integer 1,
    # rounding a fraction to 0 or 1. Keep both clamps explicitly floating point.
    $fraction = if ($null -ne $downloaded -and $null -ne $total -and $total -gt 0) { $downloaded / $total } elseif ($null -ne $percent) { $percent / 100.0 } else { $null }
    $progress = if ($null -ne $fraction) { [math]::Max(0.0, [math]::Min(1.0, [double]$fraction)) } else { $null }
    $script:status.progress = $progress
    $script:status.speedBytesPerSecond = $speed
    $script:status.downloadedBytes = $downloaded
    $script:status.totalBytes = $total
    $script:status.etaSeconds = $eta
    if ($script:currentItem) {
        $script:currentItem.progress = $progress
        $script:currentItem.speedBytesPerSecond = $speed
        $script:currentItem.downloadedBytes = $downloaded
        $script:currentItem.totalBytes = $total
        $script:currentItem.etaSeconds = $eta
    }
    if ($script:currentAsset) {
        $script:currentAsset.progress = $progress
        $script:currentAsset.speedBytesPerSecond = $speed
        $script:currentAsset.downloadedBytes = $downloaded
        $script:currentAsset.totalBytes = $total
        $script:currentAsset.etaSeconds = $eta
    }
    Save-ResourceStatus
}

function Quote-WindowsArgument {
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append('\' * ($slashes * 2 + 1))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append('\' * $slashes); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append('\' * ($slashes * 2)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-LingoYtDlpAttempt {
    param([string[]]$Arguments, [switch]$Capture, [string]$Executable, [switch]$Processing)
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = if ($Executable) { $Executable } else { [string]$config.ytDlpPath }
    $start.Arguments = (@($Arguments | ForEach-Object { Quote-WindowsArgument $_ }) -join ' ')
    $start.WorkingDirectory = [string]$config.path
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    $processJob = $null
    $output = [System.Text.StringBuilder]::new()
    $errors = [System.Collections.Generic.Queue[string]]::new()
    $script:processing = [bool]$Processing
    try {
        if ($script:nativeJobAvailable) { try { $processJob = [LingoResourceProcessJob]::Create() } catch { $processJob = $null } }
        if (-not $process.Start()) { throw 'yt-dlp 无法启动。' }
        if ($processJob -and -not $processJob.Add($process)) { $processJob.Dispose(); $processJob = $null }
        $pidInfo = @{ pid = $process.Id; startedAtTicks = $process.StartTime.Ticks; processName = $process.ProcessName }
        [System.IO.File]::WriteAllText($script:mediaPidPath, (ConvertTo-Json -InputObject $pidInfo -Compress), [System.Text.UTF8Encoding]::new($false))
        $outTask = $process.StandardOutput.ReadLineAsync()
        $errTask = $process.StandardError.ReadLineAsync()
        $outDone = $false
        $errDone = $false
        while (-not ($process.HasExited -and $outDone -and $errDone)) {
            if (-not $outDone -and $outTask.IsCompleted) {
                $line = $outTask.GetAwaiter().GetResult()
                if ($null -eq $line) { $outDone = $true }
                else {
                    if ($line.StartsWith('__LINGO_PROGRESS__')) { Update-Progress $line }
                    elseif ($line.StartsWith('__LINGO_PHASE__') -or $line -match '^\[(?:Merger|VideoRemuxer|VideoConvertor|ExtractAudio|SubtitlesConvertor|Fixup[^\]]*)\]') {
                        $script:processing = $true
                        Set-TransferPhase $(if ($line -match 'Merger') { 'merge' } else { 'convert' })
                        Save-ResourceStatus -Force
                    }
                    elseif ($Capture) {
                        if ($output.Length + $line.Length -gt 64000000) { throw '资源元数据过大。' }
                        [void]$output.AppendLine($line)
                    }
                    $outTask = $process.StandardOutput.ReadLineAsync()
                }
            }
            if (-not $errDone -and $errTask.IsCompleted) {
                $line = $errTask.GetAwaiter().GetResult()
                if ($null -eq $line) { $errDone = $true }
                else {
                    if ($line.StartsWith('__LINGO_PROGRESS__')) { Update-Progress $line }
                    elseif ($line.StartsWith('__LINGO_PHASE__') -or $line -match '^\[(?:Merger|VideoRemuxer|VideoConvertor|ExtractAudio|SubtitlesConvertor|Fixup[^\]]*)\]') {
                        $script:processing = $true
                        Set-TransferPhase $(if ($line -match 'Merger') { 'merge' } else { 'convert' })
                        Save-ResourceStatus -Force
                    }
                    elseif ($Processing -or $line -match 'ERROR:|WARNING:') {
                        $errors.Enqueue($line)
                        if ($errors.Count -gt 8) { [void]$errors.Dequeue() }
                    }
                    $errTask = $process.StandardError.ReadLineAsync()
                }
            }
            $action = Get-LingoControlAction -Path $script:controlPath
            if ($action -eq 'cancel' -or ($action -eq 'pause' -and -not $script:processing)) { Assert-LingoTransferAllowed -ControlPath $script:controlPath }
            if ($action -eq 'pause' -and $script:processing -and $script:status.status -ne 'pausing') {
                $script:status.status = 'pausing'
                $script:status.message = '暂停中，正在完成当前媒体处理'
                Save-ResourceStatus -Force
            }
            if (-not ($process.HasExited -and $outDone -and $errDone)) { Start-Sleep -Milliseconds 30 }
        }
        return @{ code = $process.ExitCode; output = $output.ToString(); error = (@($errors.ToArray()) -join ' ') }
    } finally {
        Stop-LingoProcessTree -Process $process -ProcessJob $processJob
        if ($processJob) { $processJob.Dispose() }
        $process.Dispose()
        if ([System.IO.File]::Exists($script:mediaPidPath)) { try { [System.IO.File]::Delete($script:mediaPidPath) } catch { } }
    }
}

function Invoke-LingoYtDlp {
    param([string[]]$Arguments, [switch]$Capture, [ValidateSet('download','metadata','none')][string]$Kind='download')
    $attempt = 0
    while ($true) {
        Assert-LingoTransferAllowed -ControlPath $script:controlPath
        $lease=$null
        try {
            if($Kind -ne 'none'){$lease=Enter-LingoTransferSlot -StoreRoot $script:storeRoot -Kind $Kind -ControlPath $script:controlPath}
            $result = Invoke-LingoYtDlpAttempt -Arguments $Arguments -Capture:$Capture
        } finally { if($lease){Exit-LingoTransferSlot -Lease $lease} }
        if ($result.code -eq 0 -or -not (Test-LingoNetworkError -Message ([string]$result.error))) { return $result }
        $attempt++
        Wait-NetworkRetry -Attempt $attempt -Message ([string]$result.error)
        if (-not $Capture) { Set-TransferPhase 'download' }
    }
}

function Get-UrlSite {
    param([string]$Url)
    return [string]((Get-LingoSiteForUrl -Url $Url).id)
}

function Get-BaseArguments {
    param([string]$CookieFile)
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in @('--no-config', '--no-colors', '--newline', '--windows-filenames', '--socket-timeout', '15', '--retries', '3', '--extractor-retries', '3', '--fragment-retries', '3', '--retry-sleep', 'http:exp=1:8', '--retry-sleep', 'fragment:exp=1:8', '--ffmpeg-location', [string]$config.ffmpegDirectory)) { [void]$arguments.Add($arg) }
    if ($config.denoPath) { [void]$arguments.Add('--js-runtimes'); [void]$arguments.Add("deno:$($config.denoPath)") }
    if ($CookieFile) { [void]$arguments.Add('--cookies'); [void]$arguments.Add($CookieFile) }
    return ,$arguments.ToArray()
}

function Get-InspectionInfo {
    param([string]$Url, [string]$CookieFile, [switch]$Flat, [switch]$NoPlaylist, [switch]$Force)
    $revision=Get-LingoCookieRevisionForUrl $Url
    $completePath=Get-LingoMetadataPath -StoreRoot $script:storeRoot -Url $Url -CookieRevision $revision -Mode single
    if(-not $Force){
        if($config.prefetchedInfo -and [string]$config.prefetchedCookieRevision -ceq $revision){
            $candidate=@{version=1;url=$Url;cookieRevision=$revision;fetchedAt=[string]$config.prefetchedAt;complete=$true;info=$config.prefetchedInfo}
            if(Test-LingoMetadataFresh -Envelope $candidate -Url $Url -CookieRevision $revision -RequireComplete){
                $candidate.info=Normalize-LingoMediaInfo -Info $candidate.info -SourceUrl $Url
                [void](Save-LingoMetadataCache -Path $completePath -Url $Url -CookieRevision $revision -Info $candidate.info -Complete -FetchedAt ([string]$candidate.fetchedAt))
                Set-LingoObjectField $config 'prefetchedInfo' $null
                return $candidate.info
            }
        }
        $cached=Read-LingoMetadataCache -Path $completePath -Url $Url -CookieRevision $revision -RequireComplete
        if($cached){return (Normalize-LingoMediaInfo -Info $cached -SourceUrl $Url)}
        if($config.metadataPath){
            $supplied=Read-LingoMetadataCache -Path ([string]$config.metadataPath) -Url $Url -CookieRevision $revision -RequireComplete
            if($supplied){return (Normalize-LingoMediaInfo -Info $supplied -SourceUrl $Url)}
        }
    }
    Set-TransferPhase 'inspect'
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($arg in (Get-BaseArguments $CookieFile)) { [void]$arguments.Add([string]$arg) }
    foreach ($arg in @('--dump-single-json', '--simulate', '--write-subs', '--write-auto-subs')) { [void]$arguments.Add($arg) }
    if ($Flat) { [void]$arguments.Add('--flat-playlist') }
    if ($NoPlaylist) { [void]$arguments.Add('--no-playlist') } else { [void]$arguments.Add('--yes-playlist') }
    [void]$arguments.Add($Url)
    $result = Invoke-LingoYtDlp -Arguments $arguments.ToArray() -Capture -Kind metadata
    if ($result.code -ne 0 -or -not $result.output.Trim()) {
        $hint = Get-LingoSiteFailureHint -Site (Get-UrlSite $Url) -Message ([string]$result.error)
        if (-not $hint) { $hint = [string]$result.error }
        throw "资源解析失败：$hint"
    }
    try { $info=ConvertFrom-Json -InputObject $result.output } catch {throw '资源元数据格式无效。'}
    if ($result.error -match '(?i)subtitles are only available when logged in|login required.*subtitles|subtitles.*login required') {Set-LingoObjectField $info 'subtitleAvailability' 'login-required'}
    $info=Normalize-LingoMediaInfo -Info $info -SourceUrl $Url
    $complete=$info.id -and $info._type -notin @('playlist','multi_video','url','url_transparent') -and $null -eq $info.entries -and ($info.formats -or $info.url -or $info.subtitles -or $info.automatic_captions)
    if($complete){[void](Save-LingoMetadataCache -Path $completePath -Url $Url -CookieRevision $revision -Info $info -Complete)}
    return $info
}

function Resolve-EntryUrl {
    param($Entry, [string]$Site)
    return Resolve-LingoMediaEntryUrl -Entry $Entry -Site $Site
}

function Get-SafeFilePart {
    param([string]$Value, [int]$Limit = 120)
    $part = [regex]::Replace($Value, '[<>:"/\\|?*\x00-\x1F]', '_').Trim(' ', '.')
    if (-not $part) { $part = 'media' }
    if ($part.Length -gt $Limit) { $part = $part.Substring(0, $Limit).Trim(' ', '.') }
    return $part
}

function Get-ShortHash {
    param([string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').Substring(0, 16).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-LingoItemHash {
    param([string]$Url, [string]$MediaId)
    $identity = $Url + '|' + $MediaId
    if ($config.partialScope) { $identity += '|' + (Get-LingoPlaylistFullPath ([string]$config.partialScope)).ToLowerInvariant() }
    return Get-ShortHash $identity
}
function Test-AssetOutput {
    param([string]$Path, [string]$Type, [string]$Format)
    if (-not [System.IO.File]::Exists($Path) -or ([System.IO.FileInfo]::new($Path)).Length -le 0) { throw '输出文件不存在或为空。' }
    if ($Type -eq 'subtitle') {
        if ($Format -eq 'docx') {
            Assert-LingoSubtitleWordDocument -Path $Path
            return
        }
        $content = [System.IO.File]::ReadAllText($Path)
        if ($content.Length -lt 20 -or $content -notmatch '(?m)\d{2}:\d{2}:\d{2}[,.]\d{3}\s*-->') { throw '字幕文件没有可识别的时间轴。' }
        if ($Format -eq 'vtt' -and $content -notmatch '^\s*WEBVTT') { throw '字幕不是有效 VTT。' }
        return
    }
    if (-not [System.IO.File]::Exists($script:ffprobePath)) { throw 'ffprobe 不存在。' }
    $json = & $script:ffprobePath -v error -show_entries 'stream=codec_type:stream_disposition=attached_pic' -of json $Path 2>$null | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $json.Trim()) { throw '媒体文件不能通过 ffprobe 校验。' }
    $streams = @(($json | ConvertFrom-Json).streams)
    $hasAudio = @($streams | Where-Object { $_.codec_type -eq 'audio' }).Count -gt 0
    $hasVideo = @($streams | Where-Object { $_.codec_type -eq 'video' -and $_.disposition.attached_pic -ne 1 }).Count -gt 0
    if ($Type -eq 'video' -and (-not $hasVideo -or -not $hasAudio)) { throw '完整视频缺少视频或音频流。' }
    if ($Type -eq 'audio' -and (-not $hasAudio -or $hasVideo)) { throw '独立音轨输出不是纯音频文件。' }
}

function Move-AssetToDestination {
    param([string]$SourcePath, [string]$Base, [string]$Extension, [string[]]$AvoidExtension, [switch]$ExactName)
    $directory = if ($script:currentItem.groupedDirectory) { $script:currentItem.groupedDirectory } else { $script:currentItem.outputDirectory }
    $index = 1
    while ($true) {
        $stem = if ($index -eq 1) { $Base } else { "$Base ($index)" }
        $path = Join-Path ([string]$directory) "$stem.$Extension"
        $occupied = $false
        foreach ($extensionToAvoid in $AvoidExtension) {
            $companion = Join-Path ([string]$directory) "$stem.$extensionToAvoid"
            if ([IO.File]::Exists($companion) -or [IO.Directory]::Exists($companion)) { $occupied = $true; break }
        }
        if ($occupied) { $index++; continue }
        try {
            # File.Move never replaces an existing destination. The move itself
            # arbitrates collisions between workers without leaving empty files.
            [System.IO.File]::Move($SourcePath, $path)
            return $path
        } catch [System.IO.IOException] {
            if (-not [IO.File]::Exists($path) -and -not [IO.Directory]::Exists($path)) { throw }
            if ($ExactName) { throw '同名文件已占用，为保留音频与字幕的配对，未覆盖已有文件。' }
            $index++
        }
    }
}

function Download-Asset {
    param($Plan, $Asset, [string]$Url, [string]$CookieFile, $PreviousAsset, $SourceInfo)
    $record = @{ key = $Asset.key; type = $Asset.type; trackId = (Get-LingoField $Asset 'formatId' (Get-LingoField $Asset 'rawKey')); formatId = (Get-LingoField $Asset 'formatId'); outputFormat = (Get-LingoField $Asset 'outputFormat'); rawKey = (Get-LingoField $Asset 'rawKey'); language = $Asset.language; source = (Get-LingoField $Asset 'source'); status = 'queued'; path = $null; error = $null; stage = 'download'; progress = $null; speedBytesPerSecond = $null; downloadedBytes = $null; totalBytes = $null; etaSeconds = $null }
    if ($PreviousAsset -and $PreviousAsset.status -eq 'completed' -and $PreviousAsset.path) {
        try {
            Test-AssetOutput -Path ([string]$PreviousAsset.path) -Type $Asset.type -Format ([string](Get-LingoField $Asset 'subtitleFormat' $config.subtitleFormat))
            $record.status = 'completed'
            $record.stage = 'completed'
            $record.path = [string]$PreviousAsset.path
            Save-AssetRecord -Item $script:currentItem -Record $record
            return $record
        } catch { }
    }
    $script:currentAsset = $record
    Save-AssetRecord -Item $script:currentItem -Record $record
    $record.status = 'running'
    $script:status.currentAsset = $Asset.type
    $script:currentItem.currentAsset = $Asset.type
    Reset-TransferStatus
    Set-TransferPhase 'download'
    $script:status.message = "正在下载$(@{video='视频';audio='音轨';subtitle='字幕'}[[string]$Asset.type])"
    Save-ResourceStatus -Force
    $itemHash = Get-LingoItemHash -Url $Url -MediaId ([string]$Plan.id)
    $assetHash = Get-ShortHash ([string]$Asset.key)
    $assetRoot = Join-Path $script:partialRoot "$($config.id)\$itemHash\$assetHash"
    [void][System.IO.Directory]::CreateDirectory($assetRoot)
    $formatMetadata = @()
    foreach ($format in @($SourceInfo.formats)) {
        if ($Asset.type -eq 'audio' -and [string](Get-LingoField $format 'format_id') -cne [string]$Asset.formatId) { continue }
        $formatMetadata += [ordered]@{ id = (Get-LingoField $format 'format_id'); filesize = (Get-LingoField $format 'filesize'); width = (Get-LingoField $format 'width'); height = (Get-LingoField $format 'height'); vcodec = (Get-LingoField $format 'vcodec'); acodec = (Get-LingoField $format 'acodec') }
    }
    $descriptor = [ordered]@{ mediaId = $Plan.id; assetKey = $Asset.key; formatId = (Get-LingoField $Asset 'formatId'); outputFormat = (Get-LingoField $Asset 'outputFormat'); rawKey = (Get-LingoField $Asset 'rawKey'); source = (Get-LingoField $Asset 'source'); container = $config.container; subtitleFormat = (Get-LingoField $Asset 'subtitleFormat' $config.subtitleFormat); formats = @($formatMetadata | Sort-Object { [string]$_.id }) }
    # Ignore signed media URLs and estimated file sizes. The identity and known format
    # dimensions/sizes/codecs detect incompatible checkpoints without normal URL expiry.
    $signature = Get-ShortHash (ConvertTo-Json -InputObject $descriptor -Depth 10 -Compress)
    $manifestPath = Join-Path $assetRoot 'resume.metadata.json'
    $manifest = Read-LingoJson -Path $manifestPath -ThrowOnError
    $assetDirectory = $assetRoot
    if ($manifest -and $manifest.signature -ceq $signature -and $manifest.directory) { $assetDirectory = [string]$manifest.directory }
    elseif ($manifest -and $manifest.signature -cne $signature) {
        $assetDirectory = Join-Path $assetRoot "restart-$signature"
        Set-LingoObjectField $record 'recoveryMessage' '资源格式或已知内容信息发生变化，重新下载当前未完成资源；其他成品保留。'
        $script:status.message = $record.recoveryMessage
        Save-ResourceStatus -Force
    }
    $resolvedAsset = [IO.Path]::GetFullPath($assetDirectory)
    $resolvedRoot = [IO.Path]::GetFullPath($assetRoot).TrimEnd('\')
    if ($resolvedAsset -ne $resolvedRoot -and -not $resolvedAsset.StartsWith($resolvedRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '下载恢复目录无效。' }
    [void][System.IO.Directory]::CreateDirectory($assetDirectory)
    [void](Write-LingoJson -Path $manifestPath -Value @{ signature = $signature; descriptor = $descriptor; directory = $assetDirectory } -Depth 15)
    $itemDirectory=Join-Path $script:partialRoot "$($config.id)\$itemHash"
    $outputPath=Invoke-LingoAssetPipeline -Plan $Plan -Asset $Asset -Url $Url -CookieFile $CookieFile -AssetDirectory $assetDirectory -ItemDirectory $itemDirectory
    Reset-TransferStatus
    Set-TransferPhase 'verify'
    $script:status.currentAsset = 'verify'
    $script:currentItem.currentAsset = 'verify'
    $script:status.message = '正在校验输出'
    Save-ResourceStatus -Force
    $expectedExtension = switch ($Asset.type) { 'video' { [string]$config.container } 'audio' { [IO.Path]::GetExtension($outputPath).TrimStart('.') } default { [string](Get-LingoField $Asset 'subtitleFormat' $config.subtitleFormat) } }
    $file=[IO.FileInfo]::new($outputPath)
    Test-AssetOutput -Path $file.FullName -Type $Asset.type -Format ([string](Get-LingoField $Asset 'subtitleFormat' $config.subtitleFormat))
    $title = Get-SafeFilePart ([string]$Plan.title)
    $site = Get-LingoSiteForUrl -Url $Url
    $language = if ($Asset.type -eq 'video' -or $site.mediaType -eq 'audio') { $null } else { Get-LingoFileLanguage $Asset.language }
    $base = if ($language) { "$title.$language" } else { $title }
    $avoidExtension = $null
    $exactName = $false
    if ($site.id -eq 'radiofrance' -and 'audio' -in $Plan.assets.type -and 'subtitle' -in $Plan.assets.type) {
        $audio = $script:currentItem.assets | Where-Object { $_.type -eq 'audio' -and $_.status -eq 'completed' -and [IO.File]::Exists($_.path) } | Select-Object -First 1
        $companion = $null
        if ($Asset.type -eq 'subtitle') {
            $companion = $audio
            $avoidExtension = 'mp3'
        } elseif ($Asset.type -eq 'audio' -and -not $audio) {
            $companion = $script:currentItem.assets | Where-Object { $_.type -eq 'subtitle' -and $_.status -eq 'completed' -and [IO.File]::Exists($_.path) } | Select-Object -First 1
            $avoidExtension = @($Plan.assets | Where-Object type -eq 'subtitle' | ForEach-Object subtitleFormat)
        }
        if ($companion) {
            $base = [IO.Path]::GetFileNameWithoutExtension([string]$companion.path)
            $avoidExtension = $null
            $exactName = $true
        }
    }
    $destination = Move-AssetToDestination -SourcePath $file.FullName -Base $base -Extension $expectedExtension -AvoidExtension $avoidExtension -ExactName:$exactName
    $record.path = $destination
    $record.status = 'completed'
    $record.stage = 'completed'
    $record.progress = $null
    $record.speedBytesPerSecond = $null
    return $record
}

function Get-PriorItem {
    param([string]$Url, [string]$Id, [string]$SourceUrl)
    $matches = @($script:priorItems | Where-Object { [string]$_.url -ceq $Url -and [string]$_.id -ceq $Id })
    if ($SourceUrl) {
        $exact = @($matches | Where-Object { [string](Get-LingoField $_ 'sourceUrl' $_.url) -ceq $SourceUrl } | Select-Object -First 1)
        if ($exact.Count) { return $exact }
        if ($SourceUrl -ceq $Url -and $matches.Count -eq 1) { return @($matches[0]) }
        return @()
    }
    return @($matches | Select-Object -First 1)
}

function Group-CompletedVideoFiles {
    param($Item)
    $base = Get-LingoPlaylistFullPath ([string]$config.path)
    if ($Item.outputDirectory -ine $base) { return }
    $files = @($Item.assets | Where-Object { $_.status -eq 'completed' -and $_.path })
    if (-not $Item.groupedDirectory) {
        if (@($files.path | Where-Object { [IO.File]::Exists($_) } | Select-Object -Unique).Count -lt 2) { return }
        $Item.groupedDirectory = Get-LingoPlaylistDirectory -Config $config -ConfigPath $ConfigPath -SourceUrl $Item.sourceUrl -Info $Item -ReserveOnly
        Save-ResourceStatus -Force
    }
    $directory = Assert-LingoPlaylistDirectory -BasePath $base -Directory $Item.groupedDirectory -Create
    foreach ($asset in $files) {
        $source = [IO.Path]::GetFullPath([string]$asset.path)
        if ([IO.Path]::GetDirectoryName($source) -ine $base) { continue }
        $destination = Join-Path $directory ([IO.Path]::GetFileName($source))
        # The reserved directory is persisted before any move, so a restart
        # can recover files moved before their status update reached disk.
        if (-not [IO.File]::Exists($destination)) {
            if (-not [IO.File]::Exists($source)) { continue }
            [IO.File]::Move($source, $destination)
        } elseif ([IO.File]::Exists($source)) {
            throw '下载文件夹中已有同名文件，无法归档该文件。'
        }
        if ([string]$Item.path -ieq $source) { $Item.path = $destination }
        Set-LingoObjectField $asset 'path' $destination
        Save-ResourceStatus -Force
    }
}

function Process-Video {
    param([string]$Url, $Info, [string]$CookieFile, [string]$SourceUrl)
    $priorMatch = @(Get-PriorItem -Url $Url -Id ([string]$Info.id) -SourceUrl $SourceUrl)
    $prior = if ($priorMatch.Count -gt 0) { $priorMatch[0] } else { $null }
    if ($prior -and $prior.sourceUrl) { $SourceUrl = [string]$prior.sourceUrl }
    if (-not $SourceUrl) { $SourceUrl = $Url }
    $outputDirectory = Get-LingoSavedPlaylistDirectory -Config $config -SourceUrl $SourceUrl
    if (-not $outputDirectory -and $config.singleVideo -and $config.outputDirectory) { $outputDirectory = [string]$config.outputDirectory }
    if ($outputDirectory) { $outputDirectory = Assert-LingoPlaylistDirectory -BasePath ([string]$config.path) -Directory $outputDirectory -Create }
    else { $outputDirectory = [string]$config.path }
    $scope = @{ sourceUrl = $SourceUrl; outputDirectory = $outputDirectory }
    $otherIdentity = @($script:priorItems | Where-Object { [string]$_.url -ceq $Url -and (Test-LingoPlaylistScope -First $_ -Second $scope) -and $_.id -and [string]$_.id -cne [string]$Info.id -and -not ($_.status -eq 'queued' -and @($_.assets).Count -eq 0) })
    if ($otherIdentity.Count -gt 0) { throw '此链接对应的媒体标识已经变化，请重新解析并创建下载任务；原有成品与断点已保留。' }
    for($placeholder=$script:status.items.Count-1;$placeholder -ge 0;$placeholder--){
        $pending=$script:status.items[$placeholder]
        if([string]$pending.url -ceq $Url -and (Test-LingoPlaylistScope -First $pending -Second $scope) -and [string]$pending.id -cne [string]$Info.id -and $pending.status -eq 'queued' -and @($pending.assets).Count -eq 0){$script:status.items.RemoveAt($placeholder)}
    }

    $item = @{ id = [string]$Info.id; url = $Url; sourceUrl = $SourceUrl; title = [string]$Info.title; status = 'running'; path = $null; error = $null; assets = [System.Collections.ArrayList]::new(); progress = $null; speedBytesPerSecond = $null; downloadedBytes = $null; totalBytes = $null; etaSeconds = $null; currentAsset = 'inspect'; phase = 'inspect' }
    $officialTitle = [string](Get-LingoField $config.singleEntry 'officialPlaylistTitle')
    if (-not $officialTitle) { $officialTitle = [string](Get-LingoField $prior 'officialPlaylistTitle') }
    if (-not $officialTitle -and $SourceUrl -cne $Url) {
        $officialTitle = Get-LingoOfficialPlaylistTitle -Info $Info -Site (Get-UrlSite $Url)
    }
    if ($officialTitle) {
        $item.officialPlaylistTitle = $officialTitle
        $item.title = $officialTitle
    }
    Set-LingoObjectField $item 'outputDirectory' $outputDirectory
    Set-LingoObjectField $item 'partialScope' (Get-LingoField $config 'partialScope')
    if ($prior) {
        foreach ($oldAsset in @($prior.assets)) { [void]$item.assets.Add($oldAsset) }
        $item.path = $prior.path
        if ($prior.groupedDirectory) { $item.groupedDirectory = [string]$prior.groupedDirectory }
    }
    Save-ItemRecord -Item $item
    $script:currentItem = $item
    $script:status.currentTitle = $item.title
    $script:status.currentAsset = 'inspect'
    $script:status.message = '正在规划资源'
    Reset-TransferStatus
    Save-ResourceStatus -Force
    try {
        if ($item.groupedDirectory) { Group-CompletedVideoFiles -Item $item }
        $plan = New-LingoResourcePlan -Info $Info -Config $config -SourceUrl $Url
        if ($officialTitle) { $plan.title = $officialTitle -replace '(?<=\d)/(?=\d)', '-' }
        $plannedKeys = @(@($plan.assets | ForEach-Object { [string]$_.key }) + @($plan.issues | ForEach-Object { [string]$_.key }))
        for ($i = $item.assets.Count - 1; $i -ge 0; $i--) {
            if ($item.assets[$i].status -ne 'completed' -and [string]$item.assets[$i].key -cnotin $plannedKeys) { $item.assets.RemoveAt($i) }
        }
        foreach ($asset in $plan.assets) {
            Assert-LingoTransferAllowed -ControlPath $script:controlPath
            $old = @()
            if ($prior) { $old = @($prior.assets | Where-Object { [string]$_.key -ceq [string]$asset.key } | Select-Object -First 1) }
            $previousAsset = if ($old.Count -gt 0) { $old[0] } else { $null }
            try {
                $record = Download-Asset -Plan $plan -Asset $asset -Url $Url -CookieFile $CookieFile -PreviousAsset $previousAsset -SourceInfo $Info
                if ($record.type -eq 'video' -and $record.status -eq 'completed') { $item.path = $record.path }
            } catch {
                if (Test-LingoControlException $_) {
                    if ($script:currentAsset) { $script:currentAsset.status = if ($_.Exception.Data['LingoControlAction'] -eq 'pause') { 'paused' } else { 'cancelled' } }
                    $item.status = if ($_.Exception.Data['LingoControlAction'] -eq 'pause') { 'paused' } else { 'cancelled' }
                    Stop-TransferRates
                    throw
                }
                $message = ([string]$_.Exception.Message).Substring(0, [math]::Min(600, ([string]$_.Exception.Message).Length))
                Save-AssetRecord -Item $item -Record @{ key = $asset.key; type = $asset.type; trackId = (Get-LingoField $asset 'formatId' (Get-LingoField $asset 'rawKey')); formatId = (Get-LingoField $asset 'formatId'); outputFormat = (Get-LingoField $asset 'outputFormat'); rawKey = (Get-LingoField $asset 'rawKey'); language = $asset.language; source = (Get-LingoField $asset 'source'); status = 'failed'; path = $null; error = $message; stage = (Get-LingoField $script:status 'phase' 'download') }
                $item.error = $message
            } finally {
                $script:currentAsset = $null
                $script:status.currentAsset = $null
                $item.currentAsset = $null
                if ($item.status -in @('paused', 'cancelled')) { Stop-TransferRates } else { Reset-TransferStatus }
                Save-ResourceStatus -Force
            }
        }
        foreach ($issue in $plan.issues) {
            $issueStatus = Get-LingoField $issue 'status' 'skipped'
            Save-AssetRecord -Item $item -Record @{ key = $issue.key; type = $issue.type; trackId = (Get-LingoField $issue 'formatId' (Get-LingoField $issue 'rawKey')); formatId = (Get-LingoField $issue 'formatId'); rawKey = (Get-LingoField $issue 'rawKey'); language = $issue.language; source = (Get-LingoField $issue 'source'); status = $issueStatus; path = $null; error = $(if ($issueStatus -eq 'failed') { $issue.error } else { $null }); message = $issue.error; reason = (Get-LingoField $issue 'reason' 'missing-resource') }
        }
        Group-CompletedVideoFiles -Item $item
        $bad = @($item.assets | Where-Object { $_.status -eq 'failed' }).Count
        $goodCount = @($item.assets | Where-Object { $_.status -eq 'completed' }).Count
        if ($bad -gt 0 -and -not $item.error) { $item.error = [string](@($item.assets | Where-Object status -eq 'failed' | Select-Object -First 1)[0].error) }
        $item.status = if ($bad -gt 0) { if ($goodCount -gt 0) { 'partial' } else { 'failed' } } elseif ($goodCount -eq 0 -and @($plan.issues).Count -gt 0) { 'skipped' } else { 'completed' }
        if ($item.status -eq 'completed') { Clear-LingoCompletedRawCache -Url $Url -MediaId ([string]$Info.id) }
        if ($item.status -eq 'skipped') { $item.message = '所选资源不可用，已跳过下载。' + (@($plan.issues | ForEach-Object { $_.error }) -join ' ') }
        if (-not $item.path) { $good = @($item.assets | Where-Object { $_.status -eq 'completed' } | Select-Object -First 1); if ($good.Count -gt 0) { $item.path = $good[0].path } }
    } catch {
        if (Test-LingoControlException $_) { $item.status = if ($_.Exception.Data['LingoControlAction'] -eq 'pause') { 'paused' } else { 'cancelled' }; throw }
        $item.status = 'failed'
        $item.error = ([string]$_.Exception.Message).Substring(0, [math]::Min(600, ([string]$_.Exception.Message).Length))
    } finally {
        $script:status.completed = @($script:status.items | Where-Object { $_.status -eq 'completed' }).Count
        $script:status.failed = @($script:status.items | Where-Object { $_.status -in @('failed', 'partial') }).Count
        $script:status.message = "已完成 $($script:status.completed) 项，失败 $($script:status.failed) 项"
        if ($item.error) { $script:status.error = $item.error }
        $script:status.currentTitle = $null
        $script:status.currentAsset = $null
        $script:currentItem = $null
        if ($item.status -in @('paused', 'cancelled')) { Stop-TransferRates } else { Reset-TransferStatus }
        Save-ResourceStatus -Force
    }
}

try {
    $script:status.status = 'running'
    $script:status.error = $null
    $script:status.message = '正在解析来源'
    Reset-TransferStatus
    Save-ResourceStatus -Force
    $sourceUrls = if (@($config.retryUrls).Count -gt 0 -and $config.retryUrls) { @($config.retryUrls) } else { @($config.urls) }
    foreach ($sourceUrl in $sourceUrls) {
        Assert-LingoTransferAllowed -ControlPath $script:controlPath
        $cookieFile = $null
        try {
            $site = Get-UrlSite ([string]$sourceUrl)
            $revision = Get-LingoField $config.cookieRevisions $site
            if ($revision) {
                $cookieFile = New-LingoTemporaryCookieFile -Site $site -StoreRoot $script:storeRoot -Revision ([string]$revision)
                [System.IO.File]::WriteAllText($script:cookieMarkerPath, (ConvertTo-Json -InputObject @{ path = $cookieFile } -Compress), [System.Text.UTF8Encoding]::new($false))
            }
            $uri = [Uri]([string]$sourceUrl)
            $noPlaylist = ($site -eq 'bilibili' -and $uri.AbsolutePath -match '^/video/' -and $uri.Query -match '(?:^\?|&)p=[1-9][0-9]*(?:&|$)')
            $originInfo = if ($config.singleVideo) { Get-InspectionInfo -Url ([string]$sourceUrl) -CookieFile $cookieFile -NoPlaylist } else { Get-InspectionInfo -Url ([string]$sourceUrl) -CookieFile $cookieFile -Flat -NoPlaylist:$noPlaylist }
            for ($i = $script:status.items.Count - 1; $i -ge 0; $i--) {
                $oldSource = $script:status.items[$i]
                if (-not $oldSource.id -and [string]$oldSource.url -ceq [string]$sourceUrl -and $oldSource.status -eq 'failed') { $script:status.items.RemoveAt($i) }
            }
            if ($originInfo._type -in @('playlist', 'multi_video') -or $null -ne $originInfo.entries) {
                $playlistDirectory = Get-LingoPlaylistDirectory -Config $config -ConfigPath $ConfigPath -SourceUrl ([string]$sourceUrl) -Info $originInfo
                # Persist not-yet-visited entries before beginning the first transfer.
                foreach ($entry in @($originInfo.entries)) {
                    if (-not $entry) { continue }
                    $pendingUrl = Resolve-EntryUrl -Entry $entry -Site $site
                    if (-not $pendingUrl) { continue }
                    $pendingId = [string](Get-LingoField $entry 'id')
                    $existing = @(Get-PriorItem -Url $pendingUrl -Id $pendingId -SourceUrl ([string]$sourceUrl))
                    if ($existing.Count -eq 0) { Save-ItemRecord -Item @{ id = $pendingId; url = $pendingUrl; sourceUrl = [string]$sourceUrl; title = [string](Get-LingoField $entry 'title'); outputDirectory = $playlistDirectory; status = 'queued'; path = $null; error = $null; assets = [System.Collections.ArrayList]::new() } }
                }
                $script:status.total = $script:status.items.Count
                Save-ResourceStatus -Force
                foreach ($entry in @($originInfo.entries)) {
                    Assert-LingoTransferAllowed -ControlPath $script:controlPath
                    if (-not $entry) { continue }
                    $entryUrl = Resolve-EntryUrl -Entry $entry -Site $site
                    if (-not $entryUrl) {
                        $failure = @{ id = [string](Get-LingoField $entry 'id'); url = [string]$sourceUrl; sourceUrl = [string]$sourceUrl; title = [string](Get-LingoField $entry 'title'); status = 'failed'; error = '播放列表条目缺少可用视频链接。'; phase = 'inspect'; assets = @() }
                        Save-ItemRecord -Item $failure
                        Save-ResourceStatus -Force
                        continue
                    }
                    try {
                        [void](Get-UrlSite $entryUrl)
                        $info = Get-InspectionInfo -Url $entryUrl -CookieFile $cookieFile -NoPlaylist
                        Process-Video -Url $entryUrl -Info $info -CookieFile $cookieFile -SourceUrl ([string]$sourceUrl)
                    } catch {
                        if (Test-LingoControlException $_) { throw }
                        Save-ItemRecord -Item @{ id = [string](Get-LingoField $entry 'id'); url = $entryUrl; sourceUrl = [string]$sourceUrl; title = [string](Get-LingoField $entry 'title'); status = 'failed'; error = [string]$_.Exception.Message; phase = 'inspect'; assets = @() }
                        Save-ResourceStatus -Force
                    }
                }
            } else {
                $originalSource=if($config.singleEntry -and $config.singleEntry.sourceUrl){[string]$config.singleEntry.sourceUrl}else{[string]$sourceUrl}
                Process-Video -Url ([string]$sourceUrl) -Info $originInfo -CookieFile $cookieFile -SourceUrl $originalSource
            }
        } catch {
            if (Test-LingoControlException $_) { throw }
            Save-ItemRecord -Item @{ id = $null; url = [string]$sourceUrl; sourceUrl = [string]$sourceUrl; title = $(if ($config.singleEntry.officialPlaylistTitle) { $config.singleEntry.officialPlaylistTitle } else { [string]$sourceUrl }); officialPlaylistTitle = $config.singleEntry.officialPlaylistTitle; status = 'failed'; error = [string]$_.Exception.Message; phase = 'inspect'; assets = @() }
            Save-ResourceStatus -Force
        } finally {
            if ($cookieFile) { try { Remove-LingoTemporaryCookieFile -Path $cookieFile -StoreRoot $script:storeRoot } catch { } }
            if ([System.IO.File]::Exists($script:cookieMarkerPath)) { try { [System.IO.File]::Delete($script:cookieMarkerPath) } catch { } }
        }
    }
    $script:status.total = $script:status.items.Count
    $script:status.completed = @($script:status.items | Where-Object { $_.status -eq 'completed' }).Count
    $script:status.failed = @($script:status.items | Where-Object { $_.status -in @('failed', 'partial') }).Count
    Set-LingoObjectField $script:status 'skipped' @($script:status.items | Where-Object { $_.status -eq 'skipped' }).Count
    $hasSavedAsset = @($script:status.items | ForEach-Object { @($_.assets) } | Where-Object { $_.status -eq 'completed' }).Count -gt 0
    $script:status.status = if ($script:status.failed -gt 0) { if ($script:status.completed -gt 0 -or $hasSavedAsset) { 'partial' } else { 'failed' } } else { 'completed' }
    $script:status.message = if ($script:status.completed -eq 0 -and $script:status.failed -eq 0 -and $script:status.skipped -gt 0) { "无可下载资源，已跳过 $($script:status.skipped) 项" } else { "完成 $($script:status.completed) 项，失败 $($script:status.failed) 项，跳过 $($script:status.skipped) 项" }
    $script:status.currentTitle = $null
    $script:status.currentAsset = $null
    Reset-TransferStatus
    Save-ResourceStatus -Force
} catch {
    if (Test-LingoControlException $_) {
        $action = [string]$_.Exception.Data['LingoControlAction']
        $script:status.status = if ($action -eq 'pause') { 'paused' } else { 'cancelled' }
        $script:status.message = if ($action -eq 'pause') { '已暂停，下载数据已保留' } else { '已取消，下载数据已保留' }
        Set-LingoObjectField -Object $script:status -Name 'retryAt' -Value $null
        $script:status.error = $null
        Stop-TransferRates
        Save-ResourceStatus -Force
        exit 0
    }
    $script:status.status = 'failed'
    $script:status.error = "下载工作进程异常：$($_.Exception.Message)"
    $script:status.message = $script:status.error
    $script:status.currentAsset = $null
    Reset-TransferStatus
    Save-ResourceStatus -Force
    exit 1
}

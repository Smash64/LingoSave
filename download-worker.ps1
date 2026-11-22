param([Parameter(Mandatory = $true)][string]$ConfigPath)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'state-io.ps1')
. (Join-Path $PSScriptRoot 'transfer-slots.ps1')
. (Join-Path $PSScriptRoot 'resource-planner.ps1')
$config = Read-LingoJson -Path $ConfigPath -ThrowOnError
. (Join-Path $PSScriptRoot 'credential-store.ps1')
$statusPath = [string]$config.statusPath
$script:storeRoot = if ($config.storeRoot) { [string]$config.storeRoot } else { Split-Path -Parent (Split-Path -Parent $statusPath) }
$script:cookieMarkerPath = Join-Path (Split-Path -Parent $statusPath) "$($config.id).cookie-temp.json"
$script:status = Read-LingoJson -Path $statusPath -ThrowOnError
$script:controlPath = Join-Path (Split-Path -Parent $statusPath) "$($config.id).control.json"
$script:processing = $false
$script:networkMessage = $null
$previousItems = @($script:status.items)
$script:status.items = [System.Collections.ArrayList]::new()
$script:preexistingKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$script:archiveIdsToRemove = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($previous in $previousItems) {
    [void]$script:status.items.Add($previous)
    if ($previous.status -eq 'completed' -and $previous.path -and [System.IO.File]::Exists([string]$previous.path)) {
        if ($previous.id -and $previous.url) { $origin = if ($previous.sourceUrl) { $previous.sourceUrl } else { $previous.url }; [void]$script:preexistingKeys.Add("$origin`n$($previous.id)") }
    } elseif ($previous.status -eq 'completed' -and $previous.id) {
        [void]$script:archiveIdsToRemove.Add([string]$previous.id)
    } elseif ($previous.status -eq 'skipped') {
        if ($previous.id -and $previous.url) { $origin = if ($previous.sourceUrl) { $previous.sourceUrl } else { $previous.url }; [void]$script:preexistingKeys.Add("$origin`n$($previous.id)") }
    }
}
$script:status.completed = @($script:status.items | Where-Object { $_.status -eq 'completed' }).Count
$script:status.skipped = @($script:status.items | Where-Object { $_.status -eq 'skipped' }).Count
$script:status.failed = 0
$script:status.error = $null
$script:currentIndex = -1
$script:sourceErrors = 0
$script:sourceErrorKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$script:currentOrdinal = 0
$script:lastWrite = [DateTime]::MinValue
$script:probePath = if ($config.ffprobePath) { [string]$config.ffprobePath } else { Join-Path ([string]$config.ffmpegDirectory) 'ffprobe.exe' }
$script:legacyPartialRoot = Join-Path ([string]$config.path) ".lingosave-partials\$($config.id)\legacy"
[void][IO.Directory]::CreateDirectory($script:legacyPartialRoot)
$extraPaths = @([string]$config.ffmpegDirectory)
if ($config.denoPath) { $extraPaths += (Split-Path -Parent ([string]$config.denoPath)) }
$env:PATH = ($extraPaths -join ';') + ';' + $env:PATH
$env:PYTHONIOENCODING = 'utf-8'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$script:NativeJobAvailable = $false
try {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

public sealed class LingoNativeProcessJob : IDisposable {
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
    private LingoNativeProcessJob(IntPtr value) { handle = value; }
    public static LingoNativeProcessJob Create() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            ExtendedLimit limits = new ExtendedLimit();
            limits.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            int size = Marshal.SizeOf(typeof(ExtendedLimit));
            IntPtr pointer = Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(limits, pointer, false);
                if (!SetInformationJobObject(job, 9, pointer, (uint)size))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { Marshal.FreeHGlobal(pointer); }
            return new LingoNativeProcessJob(job);
        } catch { CloseHandle(job); throw; }
    }
    public bool Add(Process process) { return AssignProcessToJobObject(handle, process.Handle); }
    public void Terminate() { if (handle != IntPtr.Zero) TerminateJobObject(handle, 1); }
    public void Dispose() { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
}
'@ -ErrorAction Stop
    $script:NativeJobAvailable = $true
} catch { }

function Remove-InvalidArchiveEntries {
    if ($script:archiveIdsToRemove.Count -eq 0 -or -not [System.IO.File]::Exists([string]$config.archivePath)) { return }
    $lines = [System.IO.File]::ReadAllLines([string]$config.archivePath, [System.Text.Encoding]::UTF8)
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        $id = ($line -split '\s+')[-1]
        if (-not $script:archiveIdsToRemove.Contains($id)) { [void]$kept.Add($line) }
    }
    [System.IO.File]::WriteAllLines([string]$config.archivePath, $kept.ToArray(), [System.Text.UTF8Encoding]::new($false))
}

function Test-MediaOutput {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { throw '下载器报告完成，但输出文件不存在。' }
    if (([System.IO.FileInfo]::new($Path)).Length -le 0) { throw '输出文件为空。' }
    if (-not [System.IO.File]::Exists($script:probePath)) { throw '无法验证输出：ffprobe 不存在。' }
    $json = & $script:probePath -v error -show_entries stream=codec_type -of json $Path 2>$null | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $json.Trim()) { throw '输出文件无法通过 ffprobe 检查。' }
    $streams = @(($json | ConvertFrom-Json).streams)
    if ($config.mode -eq 'audio') {
        if (-not @($streams | Where-Object { $_.codec_type -eq 'audio' }).Count) { throw '输出文件不含音频流。' }
    } elseif (-not @($streams | Where-Object { $_.codec_type -eq 'video' }).Count -or -not @($streams | Where-Object { $_.codec_type -eq 'audio' }).Count) {
        throw '输出文件缺少视频或音频流。'
    }
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

function Get-UrlSite {
    param([string]$Url)
    return [string]((Get-LingoSiteForUrl -Url $Url).id)
}

function Invoke-DownloaderAttempt {
    param([string[]]$Arguments, [string]$Source)
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = [string]$config.ytDlpPath
    $info.Arguments = (@($Arguments | ForEach-Object { Quote-WindowsArgument $_ }) -join ' ')
    $info.WorkingDirectory = [string]$config.path
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    $processJob = $null
    $pidPath = Join-Path (Split-Path -Parent $statusPath) "$($config.id).media.pid.json"
    $script:processing = $false
    $script:networkMessage = $null
    $transferLease = $null
    try {
        $transferLease = Enter-LingoTransferSlot -StoreRoot $script:storeRoot -Kind download -ControlPath $script:controlPath -OnWait {
            Set-LingoObjectField $script:status 'phase' 'waiting_capacity'
            $script:status.message = '正在等待下载名额'
            Save-Status -Force
        }
        Set-LingoObjectField $script:status 'phase' 'download'
        if ($script:NativeJobAvailable) {
            try { $processJob = [LingoNativeProcessJob]::Create() } catch { $processJob = $null }
        }
        if (-not $process.Start()) { throw '下载器进程无法启动。' }
        if ($processJob -and -not $processJob.Add($process)) {
            $processJob.Dispose()
            $processJob = $null
        }
        $pidInfo = @{ pid = $process.Id; startedAtTicks = $process.StartTime.Ticks; processName = $process.ProcessName }
        [System.IO.File]::WriteAllText($pidPath, (ConvertTo-Json -InputObject $pidInfo -Compress), [System.Text.UTF8Encoding]::new($false))
        $stdoutTask = $process.StandardOutput.ReadLineAsync()
        $stderrTask = $process.StandardError.ReadLineAsync()
        $stdoutDone = $false
        $stderrDone = $false
        while (-not ($process.HasExited -and $stdoutDone -and $stderrDone)) {
            if (-not $stdoutDone -and $stdoutTask.IsCompleted) {
                $line = $stdoutTask.GetAwaiter().GetResult()
                if ($null -eq $line) { $stdoutDone = $true }
                else { Handle-Line -Line $line -Source $Source; $stdoutTask = $process.StandardOutput.ReadLineAsync() }
            }
            $action = Get-LingoControlAction -Path $script:controlPath
            if ($action -eq 'cancel' -or ($action -eq 'pause' -and -not $script:processing)) { Assert-LingoTransferAllowed -ControlPath $script:controlPath }
            if ($action -eq 'pause' -and $script:processing -and $script:status.status -ne 'pausing') {
                $script:status.status = 'pausing'
                $script:status.message = '暂停中，正在完成当前媒体处理'
                Save-Status -Force
            }
            if (-not $stderrDone -and $stderrTask.IsCompleted) {
                $line = $stderrTask.GetAwaiter().GetResult()
                if ($null -eq $line) { $stderrDone = $true }
                else { Handle-Line -Line $line -Source $Source; $stderrTask = $process.StandardError.ReadLineAsync() }
            }
            if (-not ($process.HasExited -and $stdoutDone -and $stderrDone)) { Start-Sleep -Milliseconds 35 }
        }
        return $process.ExitCode
    } finally {
        Stop-LingoProcessTree -Process $process -ProcessJob $processJob
        if ($processJob) { $processJob.Dispose() }
        $process.Dispose()
        if ([System.IO.File]::Exists($pidPath)) { [System.IO.File]::Delete($pidPath) }
        Exit-LingoTransferSlot $transferLease
    }
}

function Invoke-Downloader {
    param([string[]]$Arguments, [string]$Source)
    $attempt = 0
    while ($true) {
        Assert-LingoTransferAllowed -ControlPath $script:controlPath
        $code = Invoke-DownloaderAttempt -Arguments $Arguments -Source $Source
        if ($code -eq 0 -or -not $script:networkMessage) { return $code }
        $attempt++
        $seconds = [int][math]::Min(30, [math]::Pow(2, [math]::Min(5, $attempt)))
        $until = [DateTime]::UtcNow.AddSeconds($seconds)
        $script:status.status = 'waiting_network'
        $script:status.message = "网络暂时不可用，$seconds 秒后重试"
        Set-LingoObjectField $script:status 'speedBytesPerSecond' $null
        Set-LingoObjectField $script:status 'etaSeconds' $null
        Set-LingoObjectField $script:status 'retryAt' $until.ToString('o')
        Set-LingoObjectField $script:status 'retryCount' $attempt
        if ($script:currentIndex -ge 0) { $script:status.items[$script:currentIndex].status = 'waiting_network' }
        Save-Status -Force
        while ([DateTime]::UtcNow -lt $until) { Assert-LingoTransferAllowed -ControlPath $script:controlPath; Start-Sleep -Milliseconds 150 }
        Assert-LingoTransferAllowed -ControlPath $script:controlPath
        $script:status.status = 'running'
        Set-LingoObjectField $script:status 'retryAt' $null
        Save-Status -Force
    }
}

function Save-Status {
    param([switch]$Force)
    if (-not $Force -and ([DateTime]::UtcNow - $script:lastWrite).TotalMilliseconds -lt 400) { return }
    $saved = Write-LingoJson -Path $statusPath -Value $script:status -Depth 15 -BestEffort:(-not $Force)
    if ($saved) { $script:lastWrite = [DateTime]::UtcNow }
}

function Move-LegacyOutput {
    param([string]$SourcePath, [string]$Title, [string]$Language)
    $base = [regex]::Replace($Title, '[<>:"/\\|?*\x00-\x1F]', '_').Trim(' ', '.')
    if (-not $base) { $base = 'media' }
    if ($base.Length -gt 120) { $base = $base.Substring(0, 120).Trim(' ', '.') }
    $suffix = Get-LingoFileLanguage $Language
    if ($suffix) { $base += ".$suffix" }
    $extension = [IO.Path]::GetExtension($SourcePath)
    $index = 1
    while ($true) {
        $name = if ($index -eq 1) { "$base$extension" } else { "$base ($index)$extension" }
        $destination = Join-Path ([string]$config.path) $name
        try { [IO.File]::Move($SourcePath, $destination); return $destination }
        catch [IO.IOException] {
            if (-not [IO.File]::Exists($destination) -and -not [IO.Directory]::Exists($destination)) { throw }
            $index++
        }
    }
}

function Add-Failure {
    param([string]$Message, [string]$Source, [string]$Id = $null)
    $key = if ($script:currentOrdinal -gt 0) { "item:$($script:currentOrdinal)" } else { 'source' }
    if (-not $script:sourceErrorKeys.Add($key)) { return }
    if ($Id) { [void]$script:archiveIdsToRemove.Add($Id) }
    if ($Message -match 'WinError 10013') { $Message = '当前运行环境阻止连接视频站点（WinError 10013）。' }
    $message = if ($Message.Length -gt 600) { $Message.Substring(0, 600) } else { $Message }
    if ($script:currentIndex -ge 0 -and $script:status.items[$script:currentIndex].status -in @('running','waiting_network')) {
        $item = $script:status.items[$script:currentIndex]
        $item.status = 'failed'
        $item.error = $message
        $script:currentIndex = -1
    } else {
        $found = $false
        for ($i=0; $i -lt $script:status.items.Count; $i++) {
            if (-not $script:status.items[$i].id -and [string]$script:status.items[$i].url -ceq $Source) { $script:status.items[$i] = @{ id = $null; url = $Source; sourceUrl = $Source; status = 'failed'; error = $message; phase = 'inspect' }; $found = $true; break }
        }
        if (-not $found) { [void]$script:status.items.Add(@{ id = $null; url = $Source; sourceUrl = $Source; status = 'failed'; error = $message; phase = 'inspect' }) }
    }
    $script:status.failed = [int]$script:status.failed + 1
    $script:status.error = $message
    $script:sourceErrors++
    Save-Status -Force
}

function Handle-Line {
    param([string]$Line, [string]$Source)
    if ($Line.StartsWith('__LINGOSAVE_PHASE__') -or $Line -match '^\[(?:Merger|VideoRemuxer|VideoConvertor|ExtractAudio|SubtitlesConvertor|Fixup[^\]]*)\]') {
        $script:processing = $true
        Set-LingoObjectField $script:status 'phase' $(if ($Line -match 'Merger') { 'merge' } else { 'convert' })
        Save-Status -Force
        return
    }
    if ($Line.StartsWith('__LINGOSAVE_BEGIN__')) {
        try {
            $parts = $Line.Substring('__LINGOSAVE_BEGIN__'.Length) -split '\|', 3
            $entryUrl = if ($parts.Count -gt 2) { [string](ConvertFrom-Json -InputObject $parts[2]) } else { $Source }
            if ($entryUrl -notmatch '^https?://') { $entryUrl = $Source }
            $item = @{ id = [string](ConvertFrom-Json -InputObject $parts[0]); title = [string](ConvertFrom-Json -InputObject $parts[1]); url = $entryUrl; sourceUrl = $Source; status = 'running'; path = $null; error = $null }
            for ($i = $script:status.items.Count - 1; $i -ge 0; $i--) { if (-not $script:status.items[$i].id -and [string]$script:status.items[$i].url -ceq $Source -and $script:status.items[$i].status -eq 'failed') { $script:status.items.RemoveAt($i) } }
            $script:currentIndex = -1
            for ($i = 0; $i -lt $script:status.items.Count; $i++) {
                $previous = $script:status.items[$i]
                if ([string]$previous.id -ceq [string]$item.id -and ([string]$previous.url -ceq $entryUrl -or [string]$previous.sourceUrl -ceq $Source)) { $script:currentIndex = $i; break }
            }
            if ($script:currentIndex -ge 0) { $script:status.items[$script:currentIndex] = $item }
            else { [void]$script:status.items.Add($item); $script:currentIndex = $script:status.items.Count - 1 }
            $script:processing = $false
            Set-LingoObjectField $script:status 'phase' 'download'
            $script:status.currentTitle = $item.title
            $script:status.progress = 0
            Save-Status -Force
        } catch { }
        return
    }
    if ($Line.StartsWith('__LINGOSAVE_DONE__')) {
        try {
            $parts = $Line.Substring('__LINGOSAVE_DONE__'.Length) -split '\|', 4
            $id = [string](ConvertFrom-Json -InputObject $parts[0])
            $filePath = [string](ConvertFrom-Json -InputObject $parts[1])
            $title = [string](ConvertFrom-Json -InputObject $(if ($parts.Count -ge 4) { $parts[3] } else { $parts[2] }))
            $language = if ($parts.Count -ge 4 -and $parts[2] -ne 'NA') { [string](ConvertFrom-Json -InputObject $parts[2]) } else { $null }
            try { Test-MediaOutput -Path $filePath }
            catch { Add-Failure -Message "成品校验失败：$($_.Exception.Message)" -Source $Source -Id $id; return }
            $existing = @($script:status.items | Where-Object { $_.status -eq 'completed' -and $_.id -eq $id -and $_.url -eq $Source -and $_.path -eq $filePath } | Select-Object -First 1)
            if ($existing.Count -gt 0) {
                if ($script:currentIndex -ge 0 -and $script:status.items[$script:currentIndex].status -eq 'running') {
                    $script:status.items.RemoveAt($script:currentIndex)
                }
                $script:currentIndex = -1
                $script:status.progress = 0
                Save-Status -Force
                return
            }
            $index = $script:currentIndex
            if ($index -lt 0 -or $script:status.items[$index].status -ne 'running') {
            $item = @{ id = $id; title = $title; url = $Source; sourceUrl = $Source; status = 'running'; path = $null; error = $null }
                [void]$script:status.items.Add($item)
                $index = $script:status.items.Count - 1
            }
            $internalBase = [IO.Path]::GetFileNameWithoutExtension($filePath)
            $sourceDirectory = [IO.Path]::GetDirectoryName($filePath)
            $subtitleFiles = @(Get-ChildItem -LiteralPath $sourceDirectory -File | Where-Object { $_.Name.StartsWith($internalBase + '.', [StringComparison]::OrdinalIgnoreCase) -and $_.Extension.TrimStart('.') -in @('srt', 'vtt', 'ass', 'lrc') })
            $filePath = Move-LegacyOutput -SourcePath $filePath -Title $title -Language $(if ($config.mode -eq 'audio') { $language } else { $null })
            foreach ($subtitleFile in $subtitleFiles) {
                $subtitleLanguage = $subtitleFile.Name.Substring($internalBase.Length + 1)
                $subtitleLanguage = $subtitleLanguage.Substring(0, $subtitleLanguage.Length - $subtitleFile.Extension.Length)
                [void](Move-LegacyOutput -SourcePath $subtitleFile.FullName -Title $title -Language $subtitleLanguage)
            }
            $script:status.items[$index].status = 'completed'
            $script:status.items[$index].path = $filePath
            $script:status.completed = [int]$script:status.completed + 1
            $script:status.progress = 0
            $script:currentIndex = -1
            Save-Status -Force
        } catch { }
        return
    }
    if ($Line.StartsWith('__LINGOSAVE_PROGRESS__')) {
        $script:processing = $false
        Set-LingoObjectField $script:status 'phase' 'download'
        $values = $Line.Substring('__LINGOSAVE_PROGRESS__'.Length) -split '\|', 6
        $percent = [regex]::Match($Line, '([0-9]+(?:\.[0-9]+)?)%')
        $fraction = if ($percent.Success) { [double]::Parse($percent.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) / 100.0 } else { $null }
        if ($values.Count -eq 6) {
            $fields = @('speedBytesPerSecond','downloadedBytes','totalBytes','totalBytesEstimate','etaSeconds')
            for ($i=1; $i -lt 6; $i++) {
                $number = 0.0; $parsed = if ([double]::TryParse($values[$i],[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) { $number } else { $null }
                Set-LingoObjectField $script:status $fields[$i-1] $parsed
                if ($script:currentIndex -ge 0) { Set-LingoObjectField $script:status.items[$script:currentIndex] $fields[$i-1] $parsed }
            }
            if ($null -eq $script:status.totalBytes) { $script:status.totalBytes = $script:status.totalBytesEstimate }
            if ($script:status.totalBytes -gt 0 -and $null -ne $script:status.downloadedBytes) { $fraction = [double]$script:status.downloadedBytes / [double]$script:status.totalBytes }
        }
        # Explicit doubles prevent PowerShell 5's integer overload from rounding 0..1.
        $script:status.progress = if ($null -ne $fraction) { [math]::Max(0.0, [math]::Min(1.0, [double]$fraction)) } else { $null }
        if ($script:currentIndex -ge 0) { Set-LingoObjectField $script:status.items[$script:currentIndex] 'progress' $script:status.progress }
        Save-Status
        return
    }
    if ($Line -match 'has already been recorded in the archive') {
        $id = if ($Line -match '^\[download\]\s+([^:]+):') { $Matches[1] } else { $null }
        if ($id -and $script:preexistingKeys.Contains("$Source`n$id")) { return }
        $script:status.skipped = [int]$script:status.skipped + 1
        [void]$script:status.items.Add(@{ id = $id; url = $Source; status = 'skipped'; title = $null; path = $null; error = $null })
        Save-Status -Force
        return
    }
    if ($Line -match '(?:^|\s)ERROR:\s*(.+)$') {
        if (Test-LingoNetworkError -Message $Matches[1]) { $script:networkMessage = $Matches[1]; return }
        Add-Failure -Message $Matches[1] -Source $Source
        return
    }
    if ($Line -match '^\[download\] Downloading item ([0-9]+) of ([0-9]+)') {
        $script:currentOrdinal = [int]$Matches[1]
        $script:status.message = "正在处理播放列表第 $($Matches[1]) / $($Matches[2]) 项"
        Save-Status
    }
}

try {
    Remove-InvalidArchiveEntries
    $script:status.status = 'running'
    $script:status.message = '正在下载'
    Save-Status -Force

    $sourceUrls = if ($config.retryUrls -and @($config.retryUrls).Count -gt 0) { @($config.retryUrls) } else { @($config.urls) }
    foreach ($url in $sourceUrls) {
        Assert-LingoTransferAllowed -ControlPath $script:controlPath
        $script:currentIndex = -1
        $script:sourceErrors = 0
        $script:currentOrdinal = 0
        $script:sourceErrorKeys.Clear()
        $cookieFile = $null
        try {
        $site = Get-UrlSite ([string]$url)
        $uri = [Uri]([string]$url)
        $playlistOption = if ($site -eq 'bilibili' -and $uri.AbsolutePath -match '^/video/' -and $uri.Query -match '(?:^\?|&)p=[1-9][0-9]*(?:&|$)') { '--no-playlist' } else { '--yes-playlist' }
        $revisionProperty = if ($config.cookieRevisions) { $config.cookieRevisions.PSObject.Properties[$site] } else { $null }
        if ($revisionProperty -and $revisionProperty.Value) {
            $cookieFile = New-LingoTemporaryCookieFile -Site $site -StoreRoot $script:storeRoot -Revision ([string]$revisionProperty.Value)
            [System.IO.File]::WriteAllText($script:cookieMarkerPath, (ConvertTo-Json -InputObject @{ path = $cookieFile } -Compress), [System.Text.UTF8Encoding]::new($false))
        }
        $args = [System.Collections.Generic.List[string]]::new()
        foreach ($value in @(
            '--no-config', $playlistOption, '--no-flat-playlist', '--no-abort-on-error', '--no-simulate',
            '--newline', '--progress', '--no-colors', '--windows-filenames', '--continue', '--part', '--concurrent-fragments', '4', '--abort-on-unavailable-fragments', '--socket-timeout', '15', '--retries', '3', '--fragment-retries', '3', '--extractor-retries', '3', '--retry-sleep', 'http:exp=1:8', '--retry-sleep', 'fragment:exp=1:8',
            '--ffmpeg-location', [string]$config.ffmpegDirectory,
            '--paths', $script:legacyPartialRoot,
            '--output', '%(extractor_key)s-%(id)s.%(ext)s',
            '--download-archive', [string]$config.archivePath,
            '--print', 'before_dl:__LINGOSAVE_BEGIN__%(id)j|%(title)j|%(webpage_url)j',
            '--print', 'post_process:__LINGOSAVE_PHASE__%(id)s',
            '--print', 'after_move:__LINGOSAVE_DONE__%(id)j|%(filepath)j|%(language)j|%(title)j',
            '--progress-template', 'download:__LINGOSAVE_PROGRESS__%(progress._percent_str)s|%(progress.speed)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.eta)s',
            '--no-quiet'
        )) { [void]$args.Add($value) }
        if ($config.denoPath) {
            [void]$args.Add('--js-runtimes')
            [void]$args.Add("deno:$($config.denoPath)")
        }
        if ($cookieFile) {
            [void]$args.Add('--cookies')
            [void]$args.Add($cookieFile)
        }
        if ($config.mode -eq 'audio') {
            foreach ($value in @('--format', 'bestaudio/best', '--extract-audio', '--audio-format', 'mp3', '--audio-quality', '0')) { [void]$args.Add($value) }
        } else {
            $format = switch ($config.quality) {
                '720p' { 'bestvideo[height<=720]+bestaudio/best[height<=720]/best' }
                '1080p' { 'bestvideo[height<=1080]+bestaudio/best[height<=1080]/best' }
                '1440p' { 'bestvideo[height<=1440]+bestaudio/best[height<=1440]' }
                '2160p' { 'bestvideo[height<=2160]+bestaudio/best[height<=2160]' }
                default { 'bestvideo+bestaudio/best' }
            }
            foreach ($value in @('--format', $format, '--merge-output-format', [string]$config.container, '--remux-video', [string]$config.container)) { [void]$args.Add($value) }
            if ($config.subtitleLanguages.Count -gt 0) {
                $patterns = @($config.subtitleLanguages | ForEach-Object {
                    if ($_ -eq 'fr') { '^fr(?:$|[-_](?!acc(?:$|[-_])).*)' }
                    else { '^' + [regex]::Escape([string]$_) + '(?:$|[-_].*)' }
                })
                foreach ($value in @('--write-subs', '--no-write-auto-subs', '--sub-langs', ($patterns -join ','), '--convert-subs', [string]$config.subtitleFormat)) { [void]$args.Add($value) }
            }
        }
        [void]$args.Add([string]$url)
        $script:status.currentTitle = [string]$url
        $script:status.message = '正在解析来源'
        Save-Status -Force

        $code = Invoke-Downloader -Arguments $args.ToArray() -Source ([string]$url)
        if ($code -ne 0 -and $script:sourceErrors -eq 0) {
            Add-Failure -Message "yt-dlp 退出代码 $code；请检查网络、登录状态或此链接是否可访问。" -Source ([string]$url)
        }
        if ($script:currentIndex -ge 0 -and $script:status.items[$script:currentIndex].status -eq 'running') {
            Add-Failure -Message '下载或后处理未正常完成。' -Source ([string]$url)
        }
        Remove-InvalidArchiveEntries
        } catch {
            if (Test-LingoControlException $_) { throw }
            Add-Failure -Message "来源处理失败：$($_.Exception.Message)" -Source ([string]$url)
        } finally {
            if ($cookieFile) {
                try { Remove-LingoTemporaryCookieFile -Path $cookieFile -StoreRoot $script:storeRoot } catch { }
            }
            if ([System.IO.File]::Exists($script:cookieMarkerPath)) {
                try { [System.IO.File]::Delete($script:cookieMarkerPath) } catch { }
            }
        }
    }

    $script:status.completed = @($script:status.items | Where-Object { $_.status -eq 'completed' }).Count
    $script:status.skipped = @($script:status.items | Where-Object { $_.status -eq 'skipped' }).Count
    $script:status.failed = @($script:status.items | Where-Object { $_.status -in @('failed', 'partial') }).Count
    $done = [int]$script:status.completed + [int]$script:status.skipped
    if ($null -eq $script:status.total -or [int]$script:status.total -lt $done + [int]$script:status.failed) {
        $script:status.total = $done + [int]$script:status.failed
    }
    if ([int]$script:status.failed -gt 0) {
        $script:status.status = if ($done -gt 0) { 'partial' } else { 'failed' }
        $script:status.message = "完成 $done 项，失败 $($script:status.failed) 项"
    } elseif ($null -ne $script:status.total -and $done -lt [int]$script:status.total) {
        $script:status.status = 'partial'
        $script:status.error = "预计 $($script:status.total) 项，实际完成或跳过 $done 项；请检查播放列表中是否有不可访问的视频。"
        $script:status.message = $script:status.error
    } else {
        $script:status.status = 'completed'
        $script:status.message = "完成 $($script:status.completed) 项，跳过重复项 $($script:status.skipped) 项"
        $script:status.error = $null
    }
    $script:status.progress = $null
    $script:status.currentTitle = $null
    Save-Status -Force
} catch {
    if (Test-LingoControlException $_) {
        $action = [string]$_.Exception.Data['LingoControlAction']
        $script:status.status = if ($action -eq 'pause') { 'paused' } else { 'cancelled' }
        if ($script:currentIndex -ge 0) { $script:status.items[$script:currentIndex].status = $script:status.status }
        $script:status.message = if ($action -eq 'pause') { '已暂停，下载数据已保留' } else { '已取消，下载数据已保留' }
        $script:status.error = $null
        Set-LingoObjectField $script:status 'retryAt' $null
        Set-LingoObjectField $script:status 'speedBytesPerSecond' $null
        Save-Status -Force
        exit 0
    }
    $script:status.status = 'failed'
    $script:status.error = "下载工作进程异常：$($_.Exception.Message)"
    $script:status.message = $script:status.error
    Save-Status -Force
    exit 1
}

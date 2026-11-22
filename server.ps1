param([ValidateRange(1024, 65535)][int]$Port = 8765, [int]$ParentPid = 0, [long]$ParentStartTicks = 0, [string]$LaunchId = $null)

$ErrorActionPreference = 'Stop'
if ($LaunchId -and $LaunchId -notmatch '^[0-9a-f]{32}$') { throw 'LaunchId 必须是 32 位十六进制标识。' }
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'

$script:Root = $PSScriptRoot
. (Join-Path $script:Root 'credential-store.ps1')
. (Join-Path $script:Root 'state-io.ps1')
. (Join-Path $script:Root 'playlist-folders.ps1')
. (Join-Path $script:Root 'history-store.ps1')
. (Join-Path $script:Root 'transfer-slots.ps1')
$script:DataRoot = if ($env:LINGOSAVE_DATA_DIR) { [System.IO.Path]::GetFullPath([string]$env:LINGOSAVE_DATA_DIR) } else { Join-Path $env:LOCALAPPDATA 'LingoSave' }
$mutexHash = [System.Security.Cryptography.SHA256]::Create()
try {
    $hashBytes = $mutexHash.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($script:DataRoot.ToLowerInvariant()))
    $mutexSuffix = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').Substring(0, 24)
} finally { $mutexHash.Dispose() }
$script:InstanceMutex = [System.Threading.Mutex]::new($false, "Local\LingoSave-$mutexSuffix")
$script:OwnInstanceMutex = $false
try { $script:OwnInstanceMutex = $script:InstanceMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $script:OwnInstanceMutex = $true }
if (-not $script:OwnInstanceMutex) { throw '此用户数据目录已有一个 LingoSave 服务在运行。' }
$legacyDataRoot = Join-Path $script:Root '.lingosave-data'
if (-not $env:LINGOSAVE_DATA_DIR -and [System.IO.Directory]::Exists($legacyDataRoot)) {
    [void][System.IO.Directory]::CreateDirectory($script:DataRoot)
    $legacyJobs = Join-Path $legacyDataRoot 'jobs'
    if ([System.IO.Directory]::Exists($legacyJobs) -and -not [System.IO.Directory]::Exists((Join-Path $script:DataRoot 'jobs'))) {
        Copy-Item -LiteralPath $legacyJobs -Destination $script:DataRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $legacySettings = Join-Path $legacyDataRoot 'settings.json'
    if ([System.IO.File]::Exists($legacySettings) -and -not [System.IO.File]::Exists((Join-Path $script:DataRoot 'settings.json'))) {
        Copy-Item -LiteralPath $legacySettings -Destination $script:DataRoot -Force -ErrorAction SilentlyContinue
    }
}
$script:JobsRoot = Join-Path $script:DataRoot 'jobs'
[void][System.IO.Directory]::CreateDirectory($script:JobsRoot)
Initialize-LingoHistory -DataRoot $script:DataRoot
$script:SettingsPath = Join-Path $script:DataRoot 'settings.json'
$script:ShutdownPath = Join-Path $script:DataRoot 'shutdown.request'
if ([System.IO.File]::Exists($script:ShutdownPath)) { [System.IO.File]::Delete($script:ShutdownPath) }
$script:Queue = [System.Collections.Generic.Queue[string]]::new()
$script:QueuedIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:ActiveWorkers = @{}
$script:MaxConcurrentDownloads = 3
$script:ArchivedJobsRoot = Join-Path $script:DataRoot 'history-job-snapshots'
$script:PreviewCache = $null
$script:PreviewsRoot = Join-Path $script:DataRoot 'previews'
[void][System.IO.Directory]::CreateDirectory($script:PreviewsRoot)
$script:PreviewQueue = [System.Collections.Generic.Queue[string]]::new()
$script:CurrentPreviewProcess = $null
$script:CurrentPreviewId = $null
$script:InspectionsRoot = Join-Path $script:DataRoot 'inspections'
[void][System.IO.Directory]::CreateDirectory($script:InspectionsRoot)
$script:InspectionQueue = [System.Collections.Generic.Queue[string]]::new()
$script:CurrentInspectionProcess = $null
$script:CurrentInspectionId = $null
$script:CurrentInspectionStarted = [DateTime]::MinValue

function Get-DefaultDownloadPath {
    $downloads = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace('shell:Downloads')
        if ($folder -and $folder.Self) { $downloads = [string]$folder.Self.Path }
    } catch { }
    if (-not $downloads) { $downloads = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads' }
    return (Join-Path $downloads 'LingoSave')
}

function Read-DefaultDownloadParts {
    param($Value)
    $parts = @{}
    foreach ($name in @('video', 'audio', 'subtitles')) {
        if ($null -eq $Value -or $Value.PSObject.Properties[$name].Value -isnot [bool]) { throw '请选择有效的默认下载内容。' }
        $parts[$name] = $Value.PSObject.Properties[$name].Value
    }
    if (-not ($parts.video -or $parts.audio -or $parts.subtitles)) { throw '至少选择一种默认下载内容。' }
    return $parts
}

$script:DefaultDownloadParts = @{ video = $true; audio = $false; subtitles = $true }
$script:DefaultDownloadPath = Get-DefaultDownloadPath
if ([System.IO.File]::Exists($script:SettingsPath)) {
    try {
        $savedSettings = Read-LingoJson -Path $script:SettingsPath
        if ($savedSettings.maxConcurrentDownloads -is [int] -and $savedSettings.maxConcurrentDownloads -ge 1 -and $savedSettings.maxConcurrentDownloads -le 5) { $script:MaxConcurrentDownloads = [int]$savedSettings.maxConcurrentDownloads }
        if ($savedSettings.defaultDownloadPath -is [string] -and $savedSettings.defaultDownloadPath -match '^[A-Za-z]:[\\/]') {
            $script:DefaultDownloadPath = [string]$savedSettings.defaultDownloadPath
        }
        if ($savedSettings.defaultDownloadParts) { $script:DefaultDownloadParts = Read-DefaultDownloadParts $savedSettings.defaultDownloadParts }
    } catch { }
}

[void](Set-LingoTransferPolicy -StoreRoot $script:DataRoot -DownloadLimit $script:MaxConcurrentDownloads)

function Find-Executable {
    param([string[]]$Candidates, [string]$CommandName)
    foreach ($candidate in $Candidates) {
        if ($candidate -and [System.IO.File]::Exists($candidate)) { return [System.IO.Path]::GetFullPath($candidate) }
    }
    $command = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Test-LauncherAlive {
    if ($ParentPid -le 0) { return $true }
    try {
        $parent = Get-Process -Id $ParentPid -ErrorAction Stop
        if ($ParentStartTicks -gt 0 -and $parent.StartTime.Ticks -ne $ParentStartTicks) { return $false }
        return $true
    } catch { return $false }
}

$script:YtDlp = Find-Executable -Candidates @($env:LINGOSAVE_YTDLP_PATH, (Join-Path $script:Root 'tools\yt-dlp.exe')) -CommandName 'yt-dlp.exe'
$ffmpegDirectoryOverride = if ($env:LINGOSAVE_FFMPEG_DIR) { [string]$env:LINGOSAVE_FFMPEG_DIR } else { $null }
$ffmpegCandidates = @((Join-Path $script:Root 'tools\ffmpeg\bin\ffmpeg.exe'))
if ($ffmpegDirectoryOverride) { $ffmpegCandidates += (Join-Path $ffmpegDirectoryOverride 'ffmpeg.exe') }
$script:Ffmpeg = Find-Executable -Candidates $ffmpegCandidates -CommandName 'ffmpeg.exe'
if (-not $script:Ffmpeg) { $script:Ffmpeg = Find-Executable -Candidates @('E:\ffmpeg\bin\ffmpeg.exe') -CommandName '__lingosave_no_command__' }
$ffprobeCandidates = @()
if ($script:Ffmpeg) { $ffprobeCandidates += (Join-Path (Split-Path -Parent $script:Ffmpeg) 'ffprobe.exe') }
$ffprobeCandidates += (Join-Path $script:Root 'tools\ffmpeg\bin\ffprobe.exe')
if ($ffmpegDirectoryOverride) { $ffprobeCandidates += (Join-Path $ffmpegDirectoryOverride 'ffprobe.exe') }
$script:Ffprobe = Find-Executable -Candidates $ffprobeCandidates -CommandName 'ffprobe.exe'
if (-not $script:Ffprobe) { $script:Ffprobe = Find-Executable -Candidates @('E:\ffmpeg\bin\ffprobe.exe') -CommandName '__lingosave_no_command__' }
$script:Deno = Find-Executable -Candidates @((Join-Path $script:Root 'tools\deno\deno.exe')) -CommandName 'deno.exe'
$script:YtVersion = $null
if ($script:YtDlp) {
    try { $script:YtVersion = (& $script:YtDlp --version | Select-Object -First 1).Trim() } catch { }
}
$script:Ready = [bool]($script:YtDlp -and $script:Ffmpeg -and $script:Ffprobe)
$script:HealthError = if (-not $script:YtDlp) { '缺少 tools\yt-dlp.exe。' } elseif (-not $script:Ffmpeg -or -not $script:Ffprobe) { '缺少 FFmpeg 或 ffprobe。' } else { $null }

function Send-Json {
    param($Context, $Value, [int]$Code = 200)
    $json = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    Send-Bytes -Context $Context -Bytes $bytes -ContentType 'application/json; charset=utf-8' -Code $Code
}

function Send-Bytes {
    param($Context, [byte[]]$Bytes, [string]$ContentType, [int]$Code = 200)
    $reason = switch ($Code) { 200 { 'OK' } 202 { 'Accepted' } 400 { 'Bad Request' } 403 { 'Forbidden' } 404 { 'Not Found' } 503 { 'Service Unavailable' } default { 'Internal Server Error' } }
    $header = "HTTP/1.1 $Code $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($Bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Context.Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Context.Stream.Write($Bytes, 0, $Bytes.Length)
    $Context.Stream.Flush()
}

function Read-Request {
    param($Client)
    $stream = $Client.GetStream()
    $stream.ReadTimeout = 10000
    $stream.WriteTimeout = 10000
    $headerBytes = [System.Collections.Generic.List[byte]]::new()
    while ($headerBytes.Count -lt 16384) {
        $next = $stream.ReadByte()
        if ($next -lt 0) { throw '连接过早关闭。' }
        [void]$headerBytes.Add([byte]$next)
        $size = $headerBytes.Count
        if ($size -ge 4 -and $headerBytes[$size - 4] -eq 13 -and $headerBytes[$size - 3] -eq 10 -and $headerBytes[$size - 2] -eq 13 -and $headerBytes[$size - 1] -eq 10) { break }
    }
    if ($headerBytes.Count -ge 16384) { throw 'HTTP 请求头过大。' }
    $headerText = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
    $lines = $headerText -split "`r`n"
    if ($lines[0] -notmatch '^(GET|POST|DELETE) (/[^ ]*) HTTP/1\.[01]$') { throw 'HTTP 请求格式无效。' }
    $method = $Matches[1]
    $target = $Matches[2]
    $headers = @{}
    foreach ($line in $lines | Select-Object -Skip 1) {
        if ($line -match '^([^:]+):\s*(.*)$') { $headers[$Matches[1]] = $Matches[2] }
    }
    if ($headers['Host'] -notin @("127.0.0.1:$Port", "localhost:$Port")) { throw '只接受本机地址。' }
    $contentLength = 0
    if ($headers['Content-Length']) {
        if (-not [int]::TryParse($headers['Content-Length'], [ref]$contentLength) -or $contentLength -lt 0 -or $contentLength -gt 65536) { throw '请求内容过大或长度无效。' }
    }
    if ($headers['Transfer-Encoding']) { throw '不支持分块请求。' }
    $body = [byte[]]::new($contentLength)
    $read = 0
    while ($read -lt $contentLength) {
        $n = $stream.Read($body, $read, $contentLength - $read)
        if ($n -le 0) { throw '请求内容不完整。' }
        $read += $n
    }
    $bodyStream = [System.IO.MemoryStream]::new($body, $false)
    $request = [pscustomobject]@{ HttpMethod = $method; Url = [Uri]::new("http://127.0.0.1:$Port$target"); Headers = $headers; ContentType = $headers['Content-Type']; ContentLength64 = $contentLength; InputStream = $bodyStream }
    return [pscustomobject]@{ Request = $request; Stream = $stream; Client = $Client }
}

function Read-JsonBody {
    param($Context)
    if ($Context.Request.ContentType -notmatch '^application/json(?:\s*;|$)') { throw '请求必须是 application/json。' }
    if ($Context.Request.ContentLength64 -gt 65536) { throw '请求内容过大。' }
    $reader = [System.IO.StreamReader]::new($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    if ($body.Length -gt 65536) { throw '请求内容过大。' }
    try { return ConvertFrom-Json -InputObject $body } catch { throw 'JSON 格式无效。' }
}

function Validate-Urls {
    param($Raw)
    if ($Raw -isnot [array] -or $Raw.Count -lt 1 -or $Raw.Count -gt 200) { throw '请提供 1 至 200 条链接。' }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $urls = [System.Collections.Generic.List[string]]::new()
    foreach ($value in $Raw) {
        if ($value -isnot [string]) { throw '链接格式无效。' }
        $urlText = $value.Trim()
        if ($urlText.Length -gt 4096 -or $urlText -match '[\r\n"<>]') { throw '链接过长或包含无效字符。' }
        $uri = $null
        if (-not [Uri]::TryCreate($urlText, [UriKind]::Absolute, [ref]$uri)) { throw "无效链接：$urlText" }
        if ($uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or -not $uri.IsDefaultPort) { throw "仅支持普通 http(s) 视频链接：$urlText" }
        [void](Get-LingoSiteForUrl -Url $urlText)
        if ($seen.Add($urlText)) { [void]$urls.Add($urlText) }
    }
    return ,$urls.ToArray()
}

function Validate-LanguageList {
    param($Raw, [string]$Label)
    if ($null -eq $Raw) { return ,@() }
    if ($Raw -isnot [array] -or $Raw.Count -gt 40) { throw "$Label 必须是最多 40 项的数组。" }
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Raw) {
        if ($entry -isnot [string] -or $entry -notmatch '^[A-Za-z]{2,8}(?:[-_][A-Za-z0-9]{1,16})?$') { throw "$Label 包含无效语言代码。" }
        if (-not $values.Contains($entry)) { [void]$values.Add($entry) }
    }
    return ,$values.ToArray()
}

function Validate-SourceSelections {
    param($Raw, [string[]]$Urls)
    if ($null -eq $Raw) { return @{} }
    if ($Raw -isnot [pscustomobject]) { throw '精确轨道选择格式无效。' }
    if (@($Raw.PSObject.Properties).Count -gt 500) { throw '一次最多提交 500 条视频的精确轨道选择。' }
    $result = @{}
    foreach ($property in $Raw.PSObject.Properties) {
        $url = [string]$property.Name
        [void](Validate-Urls @($url))
        if ($url -cnotin $Urls) {
            $belongsToPlaylist = $false
            foreach ($file in Get-ChildItem -LiteralPath $script:PreviewsRoot -Filter '*.status.json' -File) {
                $preview = Read-Status $file.FullName
                foreach ($source in @($preview.result.items)) {
                    if ([string]$source.url -cnotin $Urls) { continue }
                    if (@($source.entries | Where-Object { [string]$_.url -ceq $url -or [string]$_.webpageUrl -ceq $url }).Count) { $belongsToPlaylist = $true; break }
                }
                if ($belongsToPlaylist) { break }
            }
            if (-not $belongsToPlaylist) { throw '精确轨道选择与任务或播放列表中的视频不一致，请先预览该播放列表。' }
        }
        $selection = $property.Value
        if ($selection -isnot [pscustomobject] -or $selection.mediaId -isnot [string] -or $selection.mediaId.Length -lt 1 -or $selection.mediaId.Length -gt 180) { throw '精确轨道选择缺少资源 ID。' }
        $audioIds = @($selection.audioFormatIds)
        $subtitleTracks = @($selection.subtitleTracks)
        if ($selection.audioFormatIds -isnot [array] -or $selection.subtitleTracks -isnot [array] -or $audioIds.Count -gt 100 -or $subtitleTracks.Count -gt 100) { throw '轨道选择数量或格式无效。' }
        if ($null -ne $selection.explicitAudio -and $selection.explicitAudio -isnot [bool]) { throw '音轨选择标志无效。' }
        if ($null -ne $selection.explicitSubtitles -and $selection.explicitSubtitles -isnot [bool]) { throw '字幕选择标志无效。' }
        foreach ($formatId in $audioIds) {
            if ($formatId -isnot [string] -or $formatId -notmatch '\A[\p{L}\p{M}\p{Nd}_.-]{1,100}\z') { throw '音轨格式 ID 无效。' }
        }
        foreach ($track in $subtitleTracks) {
            if ($track -isnot [pscustomobject] -or $track.rawKey -isnot [string] -or $track.rawKey -notmatch '^[A-Za-z0-9_.+-]{1,100}$' -or $track.source -notin @('provided', 'auto', 'unknown')) { throw '字幕轨道 ID 或来源无效。' }
        }
        $matchedInspection = $null
        foreach ($file in (Get-ChildItem -LiteralPath $script:InspectionsRoot -Filter '*.status.json' -File | Sort-Object LastWriteTimeUtc -Descending)) {
            $inspection = Read-Status $file.FullName
            if (-not $inspection -or $inspection.status -ne 'completed' -or [string]$inspection.result.url -cne $url -or [string]$inspection.result.id -cne [string]$selection.mediaId) { continue }
            try {
                if (([DateTime]::UtcNow - [DateTime]::Parse([string]$inspection.createdAtUtc)).TotalHours -gt 1) { continue }
            } catch { continue }
            $matchedInspection = $inspection.result
            break
        }
        if (-not $matchedInspection) { throw '精确轨道选择未匹配近期解析结果；请重新解析此视频。' }
        foreach ($formatId in $audioIds) {
            if (-not @($matchedInspection.audioTracks | Where-Object { [string]$_.formatId -ceq [string]$formatId }).Count) { throw "音轨格式 $formatId 不属于已解析的视频。" }
        }
        foreach ($track in $subtitleTracks) {
            $source = if ($track.source -eq 'unknown') { 'provided' } else { [string]$track.source }
            if (-not @($matchedInspection.subtitles | Where-Object { [string]$_.rawKey -ceq [string]$track.rawKey -and [string]$_.source -ceq $source }).Count) { throw "字幕轨道 $source`:$($track.rawKey) 不属于已解析的视频。" }
        }
        $result[$url] = @{ mediaId = [string]$selection.mediaId; audioFormatIds = @($audioIds); subtitleTracks = @($subtitleTracks); explicitAudio = [bool]$selection.explicitAudio; explicitSubtitles = [bool]$selection.explicitSubtitles }
    }
    return $result
}

function Validate-Path {
    param($Raw)
    if ($Raw -isnot [string] -or $Raw.Length -gt 1024 -or $Raw -notmatch '^[A-Za-z]:[\\/]') { throw '请输入本机磁盘上的绝对保存路径，例如 C:\Users\Public\Videos\LingoSave。' }
    try {
        $full = [System.IO.Path]::GetFullPath($Raw)
        $drive = [System.IO.Path]::GetPathRoot($full)
        if (-not [System.IO.Directory]::Exists($drive)) { throw '保存路径所在磁盘不存在。' }
        [void][System.IO.Directory]::CreateDirectory($full)
        $probe = Join-Path $full ('.lingosave-write-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try { [System.IO.File]::WriteAllBytes($probe, [byte[]]::new(0)) }
        finally { if ([System.IO.File]::Exists($probe)) { [System.IO.File]::Delete($probe) } }
        return $full
    } catch { throw "保存目录不可用：$($_.Exception.Message)" }
}

function Select-Folder {
    param($CurrentPath)
    if ($null -ne $CurrentPath -and $CurrentPath -isnot [string]) { throw '当前目录必须是字符串或 null。' }
    if ($CurrentPath -and $CurrentPath.Length -gt 1024) { throw '当前目录路径过长。' }
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw '文件夹选择窗口需要 STA 线程，请通过 run.ps1 启动本机服务。'
    }

    if (-not ('LingoFolderPicker' -as [type])) {
        Add-Type -Path (Join-Path $script:Root 'desktop\FolderPicker.cs') -ReferencedAssemblies 'System.Windows.Forms.dll','System.Drawing.dll'
    }
    $initialDirectory = $script:DefaultDownloadPath
    if ($CurrentPath -and [IO.Path]::IsPathRooted($CurrentPath) -and [IO.Directory]::Exists($CurrentPath)) {
        $initialDirectory = [IO.Path]::GetFullPath($CurrentPath)
    }
    $selectedPath = [LingoFolderPicker]::Show($initialDirectory, '选择 LingoSave 保存文件夹')
    if ($null -eq $selectedPath) { return @{ cancelled = $true; path = $null } }
    if ($selectedPath.Length -gt 1024 -or $selectedPath -notmatch '^[A-Za-z]:\\') { throw '请选择本机磁盘上的文件夹。' }
    $selectedPath = [IO.Path]::GetFullPath($selectedPath)
    if (-not [IO.Directory]::Exists($selectedPath)) { throw '所选文件夹不存在或不可访问。' }
    return @{ cancelled = $false; path = $selectedPath }
}

function Select-CookieFile {
    param([string]$Site)
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw '文件选择窗口需要 STA 线程，请通过 run.ps1 启动本机服务。'
    }
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    $owner = [System.Windows.Forms.Form]::new()
    try {
        $owner.Text = 'LingoSave Cookie 导入'
        $owner.ShowInTaskbar = $false
        $owner.TopMost = $true
        $owner.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $owner.Size = [System.Drawing.Size]::new(1, 1)
        $owner.Opacity = 0
        $owner.Show()
        [void]$owner.Activate()
        $dialog.Title = "为 $Site 选择 Netscape cookies.txt 文件"
        $dialog.Filter = 'Cookie 文本文件 (*.txt)|*.txt|所有文件 (*.*)|*.*'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        $dialog.RestoreDirectory = $true
        if ($dialog.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return [string]$dialog.FileName
    } finally {
        $dialog.Dispose()
        $owner.Close()
        $owner.Dispose()
    }
}

function Get-SiteFromUrl {
    param([string]$Url)
    return [string]((Get-LingoSiteForUrl -Url $Url).id)
}

function Read-Status {
    param([string]$Path)
    $value = Read-LingoJson -Path $Path
    if ($value -and $value.id -and $value.status -and $value.urls) {
        $defaults = @{ total = $null; completed = 0; skipped = 0; failed = 0; items = @(); currentTitle = $null; currentAsset = $null; progress = $null; speedBytesPerSecond = $null; downloadedBytes = $null; totalBytes = $null; etaSeconds = $null; error = $null; message = ''; attempt = 1 }
        foreach ($name in $defaults.Keys) { if (-not $value.PSObject.Properties[$name]) { Set-HistoryField $value $name $defaults[$name] } }
    }
    return $value
}

function Save-StatusFromServer {
    param([string]$Path, $Value)
    [void](Write-LingoJson -Path $Path -Value $Value -Depth 25)
}

function Remove-PreviewTemporaryCookie {
    param([string]$Id)
    $marker = Join-Path $script:PreviewsRoot "$Id.cookie-temp.json"
    if (-not [System.IO.File]::Exists($marker)) { return }
    try {
        $record = Read-Status $marker
        if ($record.path) { Remove-LingoTemporaryCookieFile -Path ([string]$record.path) -StoreRoot $script:DataRoot }
    } catch { }
    try { [System.IO.File]::Delete($marker) } catch { }
}

function Stop-CurrentPreview {
    if (-not $script:CurrentPreviewProcess) { return }
    $process = $script:CurrentPreviewProcess
    $id = $script:CurrentPreviewId
    try {
        if (-not $process.HasExited) {
            $taskkill = Join-Path $env:WINDIR 'System32\taskkill.exe'
            if ([System.IO.File]::Exists($taskkill)) { & $taskkill /PID $process.Id /T /F *> $null }
            else { $process.Kill() }
            [void]$process.WaitForExit(3000)
        }
    } catch { try { $process.Kill() } catch { } }
    Stop-RecordedProcess (Join-Path $script:PreviewsRoot "$id.extractor.pid.json")
    Remove-PreviewTemporaryCookie -Id $id
    try { [System.IO.File]::Delete((Join-Path $script:PreviewsRoot "$id.worker.pid.json")) } catch { }
    try { $process.Dispose() } catch { }
    $script:CurrentPreviewProcess = $null
    $script:CurrentPreviewId = $null
}

function Sync-CurrentPreview {
    if (-not $script:CurrentPreviewProcess) { return }
    $exited = $false
    try { $exited = $script:CurrentPreviewProcess.HasExited } catch { $exited = $true }
    if (-not $exited) { return }
    $id = $script:CurrentPreviewId
    Stop-CurrentPreview
    $statusPath = Join-Path $script:PreviewsRoot "$id.status.json"
    $status = Read-Status $statusPath
    if ($status -and $status.status -in @('queued', 'running')) {
        $status.status = 'failed'
        $status.error = '预览工作进程异常退出，请重新预览。'
        Save-StatusFromServer -Path $statusPath -Value $status
    }
    if ($status -and $status.status -eq 'completed') { Update-LingoRecentTitles -Items $status.result.items }
}

function Start-NextPreview {
    if ($script:CurrentPreviewProcess) { return }
    while ($script:PreviewQueue.Count -gt 0) {
        $id = $script:PreviewQueue.Dequeue()
        $statusPath = Join-Path $script:PreviewsRoot "$id.status.json"
        $configPath = Join-Path $script:PreviewsRoot "$id.config.json"
        $status = Read-Status $statusPath
        if (-not $status -or $status.status -ne 'queued') { continue }
        try {
            if (-not [System.IO.File]::Exists($configPath)) { throw '预览配置文件不存在。' }
            $workerPath = Join-Path $script:Root 'preview-worker.ps1'
            if (-not [System.IO.File]::Exists($workerPath)) { throw '预览组件不存在。' }
            $start = [System.Diagnostics.ProcessStartInfo]::new()
            $start.FileName = Join-Path $PSHOME 'powershell.exe'
            $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $workerPath + '" -ConfigPath "' + $configPath + '"'
            $start.WorkingDirectory = $script:Root
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $start
            if (-not $process.Start()) { throw '无法启动预览进程。' }
            $script:CurrentPreviewProcess = $process
            $script:CurrentPreviewId = $id
            $pidInfo = @{ pid = $process.Id; startedAtTicks = $process.StartTime.Ticks; processName = $process.ProcessName }
            Save-StatusFromServer -Path (Join-Path $script:PreviewsRoot "$id.worker.pid.json") -Value $pidInfo
            return
        } catch {
            if ($script:CurrentPreviewId -eq $id) { Stop-CurrentPreview }
            $status.status = 'failed'
            $status.error = "无法启动预览：$($_.Exception.Message)"
            Save-StatusFromServer -Path $statusPath -Value $status
        }
    }
}

function Remove-InspectionTemporaryCookie {
    param([string]$Id)
    $marker = Join-Path $script:InspectionsRoot "$Id.cookie-temp.json"
    if (-not [System.IO.File]::Exists($marker)) { return }
    try {
        $record = Read-Status $marker
        if ($record.path) { Remove-LingoTemporaryCookieFile -Path ([string]$record.path) -StoreRoot $script:DataRoot }
    } catch { }
    try { [System.IO.File]::Delete($marker) } catch { }
}

function Stop-CurrentInspection {
    if (-not $script:CurrentInspectionProcess) { return }
    $process = $script:CurrentInspectionProcess
    $id = $script:CurrentInspectionId
    try {
        if (-not $process.HasExited) {
            $taskkill = Join-Path $env:WINDIR 'System32\taskkill.exe'
            if ([System.IO.File]::Exists($taskkill)) { & $taskkill /PID $process.Id /T /F *> $null }
            else { $process.Kill() }
            [void]$process.WaitForExit(3000)
        }
    } catch { try { $process.Kill() } catch { } }
    try { $process.Dispose() } catch { }
    Remove-InspectionTemporaryCookie -Id $id
    try { [System.IO.File]::Delete((Join-Path $script:InspectionsRoot "$id.worker.pid.json")) } catch { }
    $script:CurrentInspectionProcess = $null
    $script:CurrentInspectionId = $null
    $script:CurrentInspectionStarted = [DateTime]::MinValue
}

function Sync-CurrentInspection {
    if (-not $script:CurrentInspectionProcess) { return }
    $timedOut = ([DateTime]::UtcNow - $script:CurrentInspectionStarted).TotalSeconds -gt 120
    $exited = $false
    try { $exited = $script:CurrentInspectionProcess.HasExited } catch { $exited = $true }
    if (-not $exited -and -not $timedOut) { return }
    $id = $script:CurrentInspectionId
    Stop-CurrentInspection
    $statusPath = Join-Path $script:InspectionsRoot "$id.status.json"
    $status = Read-Status $statusPath
    if ($status -and $status.status -in @('queued', 'running')) {
        $status.status = 'failed'
        $status.error = if ($timedOut) { '资源解析超过 120 秒，请重试。' } else { '资源解析进程异常退出，请重试。' }
        Save-StatusFromServer -Path $statusPath -Value $status
    }
}

function Start-NextInspection {
    if ($script:CurrentInspectionProcess) { return }
    while ($script:InspectionQueue.Count -gt 0) {
        $id = $script:InspectionQueue.Dequeue()
        $statusPath = Join-Path $script:InspectionsRoot "$id.status.json"
        $configPath = Join-Path $script:InspectionsRoot "$id.config.json"
        $status = Read-Status $statusPath
        if (-not $status -or $status.status -ne 'queued') { continue }
        try {
            if (-not [System.IO.File]::Exists($configPath)) { throw '资源解析配置不存在。' }
            $workerPath = Join-Path $script:Root 'inspection-worker.ps1'
            if (-not [System.IO.File]::Exists($workerPath)) { throw '资源解析组件不存在。' }
            $start = [System.Diagnostics.ProcessStartInfo]::new()
            $start.FileName = Join-Path $PSHOME 'powershell.exe'
            $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $workerPath + '" -ConfigPath "' + $configPath + '"'
            $start.WorkingDirectory = $script:Root
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $start
            if (-not $process.Start()) { throw '无法启动资源解析进程。' }
            $script:CurrentInspectionProcess = $process
            $script:CurrentInspectionId = $id
            $script:CurrentInspectionStarted = [DateTime]::UtcNow
            $pidInfo = @{ pid = $process.Id; startedAtTicks = $process.StartTime.Ticks; processName = $process.ProcessName }
            Save-StatusFromServer -Path (Join-Path $script:InspectionsRoot "$id.worker.pid.json") -Value $pidInfo
            return
        } catch {
            if ($script:CurrentInspectionId -eq $id) { Stop-CurrentInspection }
            $status.status = 'failed'
            $status.error = "无法启动资源解析：$($_.Exception.Message)"
            Save-StatusFromServer -Path $statusPath -Value $status
        }
    }
}

function Enqueue-Job {
    param([string]$Id)
    if (-not $script:ActiveWorkers.ContainsKey($Id) -and $script:QueuedIds.Add($Id)) { $script:Queue.Enqueue($Id) }
}

function Get-JobControl {
    param([string]$Id)
    return Read-Status (Join-Path $script:JobsRoot "$Id.control.json")
}

function Set-JobControl {
    param([string]$Id, [AllowNull()][string]$Action)
    Save-StatusFromServer -Path (Join-Path $script:JobsRoot "$Id.control.json") -Value @{ action = $Action; requestedAt = [DateTime]::UtcNow.ToString('o') }
}

function Sync-JobHistory {
    param($Job)
    if (-not $Job -or $Job.status -notin @('completed', 'partial', 'failed')) { return }
    try {
        $config = Read-Status (Join-Path $script:JobsRoot "$($Job.id).config.json")
        Sync-LingoFailureHistory -Job $Job -Config $config
    } catch {
        try { [IO.File]::AppendAllText((Join-Path $script:DataRoot 'history-errors.log'), "$([DateTime]::UtcNow.ToString('o')) $($Job.id): $($_.Exception.Message)`r`n", [Text.UTF8Encoding]::new($false)) } catch { }
    }
}

function Queue-JobAgain {
    param([string]$Id, [switch]$Resume, [string]$RetryUrl)
    $statusPath = Join-Path $script:JobsRoot "$Id.status.json"
    $configPath = Join-Path $script:JobsRoot "$Id.config.json"
    $job = Read-Status $statusPath
    $config = Read-Status $configPath
    if (-not $job -or -not $config) { throw '原下载任务或配置不存在，无法恢复；请回填链接后重新下载。' }
    if ($Resume -and $job.status -in @('queued', 'running', 'waiting_network') -and (Get-JobControl $Id).action -ne 'pause') { return $job }
    if ($script:ActiveWorkers.ContainsKey($Id)) { throw '任务正在保存状态，请稍后继续。' }
    if ($Resume -and $job.status -ne 'paused') { throw '此任务当前不能继续。' }
    if (-not $Resume -and $job.status -notin @('failed', 'partial', 'cancelled', 'completed')) { throw '此任务当前不能重试。' }
    Sync-JobHistory $job
    if (-not $Resume) {
        $attempt = [int](Get-HistoryField $job 'attempt' 1) + 1
        Set-HistoryField $job 'attempt' $attempt
        Set-HistoryField $config 'attempt' $attempt
        $targets = @(if ($RetryUrl) { $RetryUrl })
        Set-HistoryField $config 'retryUrls' $targets
        Set-HistoryField $config 'attemptTargets' $targets
        if (-not $config.cookieRevisions) { Set-HistoryField $config 'cookieRevisions' @{} }
        foreach ($url in @($config.urls)) {
            $site = Get-SiteFromUrl $url
            $metadata = Get-LingoCookieMetadata -Site $site -StoreRoot $script:DataRoot
            if ($metadata) { Set-HistoryField $config.cookieRevisions $site ([string]$metadata.revision) }
            elseif ($config.cookieRevisions -and $config.cookieRevisions.PSObject.Properties[$site]) { $config.cookieRevisions.PSObject.Properties.Remove($site) }
        }
        Save-StatusFromServer -Path $configPath -Value $config
    }
    Set-JobControl -Id $Id -Action $null
    $job.status = 'queued'
    $job.error = $null
    $job.message = if ($Resume) { '已继续排队；将从已有下载数据恢复。' } elseif ($RetryUrl) { '已排队重试此失败视频；保留已完成的资源。' } else { '已重新排队；已有成品和下载数据会保留。' }
    $job.speedBytesPerSecond = $null
    $job.etaSeconds = $null
    Save-StatusFromServer -Path $statusPath -Value $job
    Enqueue-Job $Id
    return $job
}

function Get-RevealTarget {
    param([string]$JobId, [string]$Path)
    if ($JobId -notmatch '^[0-9a-f]{32}$' -or -not $Path) { throw '请提供任务和已下载文件路径。' }
    $job = Read-Status (Join-Path $script:JobsRoot "$JobId.status.json")
    if (-not $job) { throw '下载任务不存在。' }
    $allowed = @()
    foreach ($item in @($job.items)) {
        if ($item.path -and $item.status -eq 'completed') { $allowed += [string]$item.path }
        foreach ($asset in @($item.assets)) { if ($asset.path -and $asset.status -eq 'completed') { $allowed += [string]$asset.path } }
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not @($allowed | Where-Object { [IO.Path]::GetFullPath($_) -ieq $full }).Count) { throw '只能定位此任务已经下载完成的文件。' }
    $directory = [IO.Path]::GetDirectoryName($full)
    if ([IO.File]::Exists($full)) { return @{ file = $full; directory = $directory; missing = $false } }
    if ([IO.Directory]::Exists($directory)) { return @{ file = $null; directory = $directory; missing = $true } }
    throw '文件和原保存文件夹已不存在，可能已被移动或删除。'
}

function Open-RevealTarget {
    param($Target)
    if (-not ('LingoSaveFileLocation' -as [type])) {
        Add-Type -Path (Join-Path $script:Root 'desktop\FileLocation.cs') -ErrorAction Stop
    }
    if ($Target.file) { [LingoSaveFileLocation]::RevealFile([string]$Target.file) }
    else { [LingoSaveFileLocation]::OpenDirectory([string]$Target.directory) }
}

function Stop-RecordedProcess {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return }
    try {
        $record = Read-Status $Path
        $process = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
        if ($process -and $process.ProcessName -eq [string]$record.processName -and $process.StartTime.Ticks -eq [long]$record.startedAtTicks) {
            $taskkill = Join-Path $env:WINDIR 'System32\taskkill.exe'
            if ([IO.File]::Exists($taskkill)) { & $taskkill /PID $process.Id /T /F *> $null }
            else { Stop-Process -Id $process.Id -Force -ErrorAction Stop }
        }
    } catch { }
    try { [System.IO.File]::Delete($Path) } catch { }
}

function Stop-JobChildren {
    param([string]$Id)
    if ($Id -notmatch '^[0-9a-f]{32}$') { return }
    $root = [IO.Path]::GetFullPath((Join-Path $script:JobsRoot "$Id.children"))
    $expectedParent = [IO.Path]::GetFullPath($script:JobsRoot).TrimEnd('\') + '\'
    if (-not $root.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($root) -cne "$Id.children") { throw '子任务元数据路径无效。' }
    if (-not [IO.Directory]::Exists($root)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.pid.json' -File -Recurse) { Stop-RecordedProcess -Path $file.FullName }
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.cookie-temp.json' -File -Recurse) {
        try { $marker = Read-Status $file.FullName; if ($marker.path) { Remove-LingoTemporaryCookieFile -Path ([string]$marker.path) -StoreRoot $script:DataRoot } } catch { }
        try { [IO.File]::Delete($file.FullName) } catch { }
    }
}

function Merge-SavedJobChildren {
    param($Job)
    if (-not $Job -or [string]$Job.id -notmatch '^[0-9a-f]{32}$') { return $Job }
    $root = [IO.Path]::GetFullPath((Join-Path $script:JobsRoot "$($Job.id).children"))
    $expectedParent = [IO.Path]::GetFullPath($script:JobsRoot).TrimEnd('\') + '\'
    if (-not $root.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($root) -cne "$($Job.id).children") { throw '子任务状态路径无效。' }
    if (-not [IO.Directory]::Exists($root)) { return $Job }
    $items = [Collections.ArrayList]@($Job.items)
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter 'status.json' -File -Recurse) {
        $child = Read-Status $file.FullName
        if (-not $child -or [string]$child.id -cne [string]$Job.id) { continue }
        foreach ($item in @($child.items)) {
            if (-not $item -or -not $item.url) { continue }
            $matched = $false
            for ($i = 0; $i -lt $items.Count; $i++) {
                if ([string]$items[$i].url -ceq [string]$item.url -and [string]$items[$i].id -ceq [string]$item.id -and (Test-LingoPlaylistScope -First $items[$i] -Second $item)) { $items[$i] = $item; $matched = $true; break }
            }
            if (-not $matched) {
                for ($i = $items.Count - 1; $i -ge 0; $i--) {
                    $old = $items[$i]
                    if ([string]$old.url -ceq [string]$item.url -and (Test-LingoPlaylistScope -First $old -Second $item) -and ((-not $old.id -and $old.status -eq 'failed') -or ($old.status -eq 'queued' -and @($old.assets).Count -eq 0))) { $items.RemoveAt($i) }
                }
                [void]$items.Add($item)
            }
        }
    }
    Set-LingoObjectField $Job 'items' @($items)
    Set-LingoObjectField $Job 'total' $items.Count
    Set-LingoObjectField $Job 'completed' @($items | Where-Object status -eq 'completed').Count
    Set-LingoObjectField $Job 'failed' @($items | Where-Object {$_.status -in @('failed', 'partial')}).Count
    Set-LingoObjectField $Job 'skipped' @($items | Where-Object status -eq 'skipped').Count
    return $Job
}

function Remove-JobTemporaryCookie {
    param([string]$Id)
    $marker = Join-Path $script:JobsRoot "$Id.cookie-temp.json"
    if (-not [System.IO.File]::Exists($marker)) { return }
    try {
        $record = Read-Status $marker
        if ($record.path) { Remove-LingoTemporaryCookieFile -Path ([string]$record.path) -StoreRoot $script:DataRoot }
    } catch { }
    try { [System.IO.File]::Delete($marker) } catch { }
}

function Stop-CurrentWorker {
    param([string]$Id)
    $ids = if ($Id) { @($Id) } else { @($script:ActiveWorkers.Keys) }
    foreach ($workerId in $ids) {
        if (-not $script:ActiveWorkers.ContainsKey($workerId)) { continue }
        $process = $script:ActiveWorkers[$workerId]
        try {
            if (-not $process.HasExited) {
                $taskkill = Join-Path $env:WINDIR 'System32\taskkill.exe'
                if ([System.IO.File]::Exists($taskkill)) { & $taskkill /PID $process.Id /T /F *> $null }
                else { $process.Kill() }
                [void]$process.WaitForExit(3000)
            }
        } catch { }
        try { if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction Stop; [void]$process.WaitForExit(3000) } } catch { try { $process.Kill() } catch { } }
        Stop-RecordedProcess (Join-Path $script:JobsRoot "$workerId.media.pid.json")
        try { $process.Dispose() } catch { }
        Stop-JobChildren -Id $workerId
        Remove-JobTemporaryCookie -Id $workerId
        try { [System.IO.File]::Delete((Join-Path $script:JobsRoot "$workerId.worker.pid.json")) } catch { }
        $script:ActiveWorkers.Remove($workerId)
    }
}

function Sync-CurrentWorker {
    foreach ($id in @($script:ActiveWorkers.Keys)) {
        $process = $script:ActiveWorkers[$id]
        $exited = $false
        try { $exited = $process.HasExited } catch { $exited = $true }
        if (-not $exited) { continue }
        try { $process.Dispose() } catch { }
        $script:ActiveWorkers.Remove($id)
        try { [System.IO.File]::Delete((Join-Path $script:JobsRoot "$id.worker.pid.json")) } catch { }
        Stop-RecordedProcess (Join-Path $script:JobsRoot "$id.media.pid.json")
        Stop-JobChildren -Id $id
        Remove-JobTemporaryCookie -Id $id
        $statusPath = Join-Path $script:JobsRoot "$id.status.json"
        $job = Merge-SavedJobChildren (Read-Status $statusPath)
        if ($job -and $job.status -in @('queued', 'running', 'waiting_network', 'pausing')) {
            $control = (Get-JobControl $id).action
            $paused = $control -eq 'pause'
            $cancelled = $control -eq 'cancel'
            $job.status = if ($paused) { 'paused' } elseif ($cancelled) { 'cancelled' } else { 'failed' }
            $job.error = if ($paused -or $cancelled) { $null } else { '下载工作进程异常退出；可点击重试继续。' }
            $job.message = $job.error
            if ($paused) { $job.message = '已暂停；保留下载数据，点击继续恢复。' }
            elseif ($cancelled) { $job.message = '已取消；已完成的文件仍保留。' }
            foreach ($item in @($job.items | Where-Object { $_.status -in @('running', 'waiting_network') })) {
                $item.status = if ($paused) { 'paused' } elseif ($cancelled) { 'cancelled' } else { 'failed' }
                if (-not ($paused -or $cancelled)) { Set-HistoryField $item 'error' $job.error }
                foreach ($asset in @($item.assets | Where-Object { $_.status -in @('running', 'waiting_network') })) {
                    $asset.status = if ($paused) { 'paused' } elseif ($cancelled) { 'cancelled' } else { 'failed' }
                    if (-not ($paused -or $cancelled)) { Set-HistoryField $asset 'error' $job.error }
                }
            }
            if (-not $paused) { $job.progress = $null; $job.currentAsset = $null; $job.downloadedBytes = $null; $job.totalBytes = $null }
            $job.speedBytesPerSecond = $null
            $job.etaSeconds = $null
            Save-StatusFromServer -Path $statusPath -Value $job
        }
        Sync-JobHistory $job
    }
}

function Start-NextJob {
    while ($script:Queue.Count -gt 0 -and $script:ActiveWorkers.Count -lt $script:MaxConcurrentDownloads) {
        $id = $script:Queue.Dequeue()
        [void]$script:QueuedIds.Remove($id)
        if ($script:ActiveWorkers.ContainsKey($id)) { continue }
        $statusPath = Join-Path $script:JobsRoot "$id.status.json"
        $configPath = Join-Path $script:JobsRoot "$id.config.json"
        $job = Read-Status $statusPath
        if (-not $job -or $job.status -ne 'queued') { continue }
        if ((Get-JobControl $id).action -eq 'pause') {
            $job.status = 'paused'
            $job.message = '已暂停。'
            Save-StatusFromServer -Path $statusPath -Value $job
            continue
        }
        try {
            if (-not [System.IO.File]::Exists($configPath)) { throw '任务配置文件不存在。' }
            $config = Read-Status $configPath
            [void](Validate-Path $config.path)
            $workerPath = Join-Path $script:Root $(if ($config.parts) { 'resource-coordinator.ps1' } else { 'download-worker.ps1' })
            $powershellPath = Join-Path $PSHOME 'powershell.exe'
            $start = [System.Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $powershellPath
            $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $workerPath + '" -ConfigPath "' + $configPath + '"'
            $start.WorkingDirectory = $script:Root
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $start
            if (-not $process.Start()) { throw '无法启动下载工作进程。' }
            $script:ActiveWorkers[$id] = $process
            $pidInfo = @{ pid = $process.Id; startedAtTicks = $process.StartTime.Ticks; processName = $process.ProcessName }
            Save-StatusFromServer -Path (Join-Path $script:JobsRoot "$id.worker.pid.json") -Value $pidInfo
        } catch {
            if ($script:ActiveWorkers.ContainsKey($id)) { Stop-CurrentWorker -Id $id }
            $job.status = 'failed'
            $job.error = "无法启动或继续下载：$($_.Exception.Message)"
            $job.message = $job.error
            $job.progress = $null
            $job.currentAsset = $null
            $job.speedBytesPerSecond = $null
            $job.downloadedBytes = $null
            $job.totalBytes = $null
            $job.etaSeconds = $null
            Save-StatusFromServer -Path $statusPath -Value $job
            Sync-JobHistory $job
        }
    }
}

function List-Jobs {
    $jobs = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $script:JobsRoot -Filter '*.status.json' -File) {
        $job = Read-Status $file.FullName
        if (-not $job) { continue }
        Sync-JobHistory $job
        if ($script:ActiveWorkers.ContainsKey([string]$job.id) -and $job.status -in @('queued', 'running', 'waiting_network') -and (Get-JobControl $job.id).action -eq 'pause') {
            $job.status = 'pausing'
            $job.message = '正在暂停并保存下载状态；合并、转换或校验会在安全位置暂停。'
        }
        [void]$jobs.Add($job)
    }
    return @($jobs | Sort-Object -Property createdAt -Descending)
}

function Get-TrayView {
    $jobs = @(List-Jobs | Where-Object { $_.status -in @('queued', 'running', 'waiting_network', 'pausing', 'paused') })
    $summaries = @(foreach ($job in $jobs) {
        $title = [string]$job.currentTitle
        if (-not $title) { $title = [string](@($job.items | Where-Object { $_.title } | Select-Object -First 1)[0].title) }
        if (-not $title -and @($job.urls).Count -eq 1) { $title = [string]$job.urls[0] }
        if (-not $title) { $title = '下载任务' }
        @{ id = $job.id; status = $job.status; title = $title; currentTitle = $job.currentTitle; progress = $job.progress; completed = $job.completed; total = $job.total; createdAt = $job.createdAt }
    })
    return @{ jobs = $summaries; activeCount = @($jobs | Where-Object { $_.status -in @('running', 'waiting_network', 'pausing') -or $script:ActiveWorkers.ContainsKey([string]$_.id) }).Count; queuedCount = @($jobs | Where-Object { $_.status -eq 'queued' -and -not $script:ActiveWorkers.ContainsKey([string]$_.id) }).Count }
}

function Restore-HistoryJob {
    param([string]$Id)
    if ($Id -notmatch '^[0-9a-f]{32}$') { throw '历史任务标识无效。' }
    $statusPath = Join-Path $script:JobsRoot "$Id.status.json"
    $configPath = Join-Path $script:JobsRoot "$Id.config.json"
    if ([IO.File]::Exists($statusPath) -and [IO.File]::Exists($configPath)) { return }
    $snapshotPath = Join-Path $script:ArchivedJobsRoot "$Id.json"
    $snapshot = Read-Status $snapshotPath
    if (-not $snapshot -or -not $snapshot.job -or -not $snapshot.config) { return }
    Save-StatusFromServer -Path $configPath -Value $snapshot.config
    Save-StatusFromServer -Path $statusPath -Value $snapshot.job
}

function Remove-JobRecord {
    param([string]$Id)
    if ($Id -notmatch '^[0-9a-f]{32}$') { throw '任务标识无效。' }
    $statusPath = Join-Path $script:JobsRoot "$Id.status.json"
    $job = Read-Status $statusPath
    if (-not $job) { throw '任务不存在。' }
    if ($script:ActiveWorkers.ContainsKey($Id) -or $job.status -notin @('completed', 'partial', 'failed', 'cancelled')) { throw '请先取消进行中或暂停的任务，再清除此记录。' }
    Sync-JobHistory $job
    $references = @($script:LinkHistory.failedLinks | Where-Object { [string]$_.jobId -eq $Id -or @($_.failedResources | Where-Object { [string]$_.jobId -eq $Id }).Count })
    if ($references.Count) {
        $config = Read-Status (Join-Path $script:JobsRoot "$Id.config.json")
        if ($config) { Save-StatusFromServer -Path (Join-Path $script:ArchivedJobsRoot "$Id.json") -Value @{ job = $job; config = $config } }
    }
    # Only files with this exact validated job ID in the metadata directory are removed.
    # Downloaded media and partial transfer directories are intentionally outside this operation.
    $metadataRoot = [IO.Path]::GetFullPath($script:JobsRoot).TrimEnd('\') + '\'
    $files = @(Get-ChildItem -LiteralPath $script:JobsRoot -Filter "$Id.*" -File)
    foreach ($file in $files) {
        $full = [IO.Path]::GetFullPath($file.FullName)
        if (-not $full.StartsWith($metadataRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike "$Id.*") { throw '任务元数据路径无效。' }
    }
    # Hide the record first; an old queue entry is skipped because its status no longer exists.
    [IO.File]::Delete($statusPath)
    foreach ($file in $files | Where-Object { $_.FullName -ine $statusPath }) { [IO.File]::Delete($file.FullName) }
    $childrenRoot = [IO.Path]::GetFullPath((Join-Path $script:JobsRoot "$Id.children"))
    if ([IO.Directory]::Exists($childrenRoot)) {
        if (-not $childrenRoot.StartsWith($metadataRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($childrenRoot) -cne "$Id.children") { throw '子任务元数据清理路径无效。' }
        Stop-JobChildren -Id $Id
        Remove-Item -LiteralPath $childrenRoot -Recurse -Force
    }
    [void]$script:QueuedIds.Remove($Id)
    return $Id
}

function Get-RemovalResult {
    param([string[]]$RemovedIds)
    $jobs = @(List-Jobs)
    return @{ removedIds = @($RemovedIds); retainedActive = @($jobs | Where-Object { $_.status -notin @('completed', 'partial', 'failed', 'cancelled') } | ForEach-Object { [string]$_.id }); removedCount = @($RemovedIds).Count; remainingCount = $jobs.Count; jobs = $jobs }
}

function Serve-Static {
    param($Context, [string]$Name)
    $types = @{ 'index.html' = 'text/html; charset=utf-8'; 'styles.css' = 'text/css; charset=utf-8'; 'app.js' = 'text/javascript; charset=utf-8'; 'batch.js' = 'text/javascript; charset=utf-8'; 'assets/icons/lingosave-app.png' = 'image/png'; 'assets/icons/lingosave-app-v2.ico' = 'image/x-icon' }
    if (-not $types.ContainsKey($Name)) { Send-Json $Context @{ error = 'Not found' } 404; return }
    $path = Join-Path $script:Root $Name
    if (-not [System.IO.File]::Exists($path)) { Send-Json $Context @{ error = 'Not found' } 404; return }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    Send-Bytes -Context $Context -Bytes $bytes -ContentType $types[$Name]
}

function Handle-Request {
    param($Context)
    $request = $Context.Request
    $path = $request.Url.AbsolutePath
    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/health') {
        $warnings = @()
        if (-not $script:Deno) { $warnings += '未找到 Deno，YouTube 某些视频或格式可能无法解析。' }
        Send-Json $Context @{ ready = $script:Ready; error = $script:HealthError; ytDlpVersion = $script:YtVersion; ytDlpPath = $script:YtDlp; ffmpegPath = $script:Ffmpeg; ffprobePath = $script:Ffprobe; denoPath = $script:Deno; defaultDownloadPath = $script:DefaultDownloadPath; launchId = $LaunchId; warnings = $warnings }
        return
    }
    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/settings') {
        Send-Json $Context @{ defaultDownloadPath = $script:DefaultDownloadPath; maxConcurrentDownloads = $script:MaxConcurrentDownloads; defaultDownloadParts = $script:DefaultDownloadParts }
        return
    }
    if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/settings') {
        $origin = $request.Headers['Origin']
        if ($origin -and $origin -notin @("http://127.0.0.1:$Port", "http://localhost:$Port")) { Send-Json $Context @{ error = '只接受本机界面发起的请求。' } 403; return }
        try {
            $body = Read-JsonBody $Context
            if ($body -isnot [pscustomobject] -or (-not $body.PSObject.Properties['defaultDownloadPath'] -and -not $body.PSObject.Properties['maxConcurrentDownloads'] -and -not $body.PSObject.Properties['defaultDownloadParts'])) { throw '请求缺少可保存的设置。' }
            $directory = $script:DefaultDownloadPath
            $limit = $script:MaxConcurrentDownloads
            if ($body.PSObject.Properties['maxConcurrentDownloads']) {
                if ($body.maxConcurrentDownloads -isnot [int] -or $body.maxConcurrentDownloads -lt 1 -or $body.maxConcurrentDownloads -gt 5) { throw '并行下载数量必须是 1 至 5 的整数。' }
                $limit = [int]$body.maxConcurrentDownloads
            }
            if ($body.PSObject.Properties['defaultDownloadPath']) { $directory = Validate-Path $body.defaultDownloadPath }
            $defaultParts = $script:DefaultDownloadParts
            if ($body.PSObject.Properties['defaultDownloadParts']) { $defaultParts = Read-DefaultDownloadParts $body.defaultDownloadParts }
            $settings = @{ defaultDownloadPath = $directory; maxConcurrentDownloads = $limit; defaultDownloadParts = $defaultParts }
            Save-StatusFromServer -Path $script:SettingsPath -Value $settings
            $script:DefaultDownloadPath = $directory
            $script:DefaultDownloadParts = $defaultParts
            $script:MaxConcurrentDownloads = $limit
            [void](Set-LingoTransferPolicy -StoreRoot $script:DataRoot -DownloadLimit $limit)
            Send-Json $Context $settings
        } catch { Send-Json $Context @{ error = [string]$_.Exception.Message } 400 }
        return
    }
    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/jobs') {
        Send-Json $Context @{ jobs = @(List-Jobs) }
        return
    }
    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/tray') {
        Send-Json $Context (Get-TrayView)
        return
    }
    if (($request.HttpMethod -eq 'DELETE' -and $path -match '^/api/jobs/([0-9a-f]{32})$') -or ($request.HttpMethod -eq 'POST' -and $path -eq '/api/jobs/clear')) {
        $id = if ($request.HttpMethod -eq 'DELETE') { $Matches[1] } else { $null }
        $origin = $request.Headers['Origin']
        if ($origin -and $origin -notin @("http://127.0.0.1:$Port", "http://localhost:$Port")) { Send-Json $Context @{ error = '只接受本机界面发起的请求。' } 403; return }
        try {
            if ($request.HttpMethod -eq 'POST') { [void](Read-JsonBody $Context) }
            Sync-CurrentWorker
            $removed = @()
            if ($id) {
                if (-not [IO.File]::Exists((Join-Path $script:JobsRoot "$id.status.json"))) { Send-Json $Context @{ error = '任务不存在。' } 404; return }
                $removed = @(Remove-JobRecord -Id $id)
            } else {
                foreach ($job in @(List-Jobs)) {
                    if ($job.status -in @('completed', 'partial', 'failed', 'cancelled') -and -not $script:ActiveWorkers.ContainsKey([string]$job.id)) { $removed += Remove-JobRecord -Id ([string]$job.id) }
                }
            }
            Send-Json $Context (Get-RemovalResult -RemovedIds $removed)
        } catch { Send-Json $Context @{ error = [string]$_.Exception.Message } 400 }
        return
    }
    if ($request.HttpMethod -eq 'GET' -and $path -match '^/api/preview/([0-9a-f]{32})$') {
        $id = $Matches[1]
        $statusPath = Join-Path $script:PreviewsRoot "$id.status.json"
        if (-not [System.IO.File]::Exists($statusPath)) { Send-Json $Context @{ error = '预览任务不存在。' } 404; return }
        $status = Read-Status $statusPath
        if (-not $status) { Send-Json $Context @{ error = '预览状态暂时不可读取。' } 503; return }
        if ($status.status -eq 'completed') {
            $configPath = Join-Path $script:PreviewsRoot "$id.config.json"
            try {
                $config = Read-Status $configPath
                $script:PreviewCache = @{ key = (@($config.urls) -join "`n"); total = [int]$status.result.totalVideos; at = [DateTime]::UtcNow }
            } catch { }
        }
        Send-Json $Context $status
        return
    }
    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/cookies') {
        try {
            $sites = @{}
            foreach ($definition in (Get-LingoSites)) {
                $sites[[string]$definition.id] = Get-LingoCookieMetadata -Site ([string]$definition.id) -StoreRoot $script:DataRoot
            }
            Send-Json $Context @{ sites = $sites; supportedSites = @(Get-LingoSites) }
        } catch { Send-Json $Context @{ error = [string]$_.Exception.Message } 500 }
        return
    }
    if ($request.HttpMethod -eq 'POST' -and $path -match '^/api/cookies/([a-z][a-z0-9-]{0,31})/(import|remove)$') {
        $site = $Matches[1]
        $action = $Matches[2]
        $origin = $request.Headers['Origin']
        if ($origin -and $origin -notin @("http://127.0.0.1:$Port", "http://localhost:$Port")) { Send-Json $Context @{ error = '只接受本机界面发起的请求。' } 403; return }
        try {
            $site = [string]((Get-LingoSiteDefinition -Id $site).id)
            [void](Read-JsonBody $Context)
            if ($action -eq 'remove') {
                Remove-LingoCookieFile -Site $site -StoreRoot $script:DataRoot
                Send-Json $Context @{ site = $site; removed = $true }
            } else {
                $selectedPath = Select-CookieFile -Site $site
                if (-not $selectedPath) { Send-Json $Context @{ cancelled = $true; credential = $null }; return }
                $metadata = Import-LingoCookieFile -Site $site -SourcePath $selectedPath -StoreRoot $script:DataRoot
                Send-Json $Context @{ cancelled = $false; credential = $metadata }
            }
        } catch { Send-Json $Context @{ error = [string]$_.Exception.Message } 400 }
        return
    }
    if ($request.HttpMethod -eq 'POST' -and $path -match '^/api/jobs/([0-9a-f]{32})/(cancel|retry|pause|resume)$') {
        $id = $Matches[1]
        $action = $Matches[2]
        $origin = $request.Headers['Origin']
        if ($origin -and $origin -notin @("http://127.0.0.1:$Port", "http://localhost:$Port")) { Send-Json $Context @{ error = '只接受本机界面发起的请求。' } 403; return }
        try {
            [void](Read-JsonBody $Context)
            $statusPath = Join-Path $script:JobsRoot "$id.status.json"
            $configPath = Join-Path $script:JobsRoot "$id.config.json"
            if (-not [System.IO.File]::Exists($statusPath) -or -not [System.IO.File]::Exists($configPath)) { Send-Json $Context @{ error = '任务不存在。' } 404; return }
            $job = Read-Status $statusPath
            if (-not $job) { throw '任务状态文件不可读。' }
            if ($action -eq 'pause') {
                if ($job.status -in @('paused', 'pausing')) { Send-Json $Context @{ job = $job }; return }
                if ($job.status -notin @('queued', 'running', 'waiting_network')) { throw '此任务当前不能暂停。' }
                Set-JobControl -Id $id -Action 'pause'
                if (-not $script:ActiveWorkers.ContainsKey($id)) {
                    $job.status = 'paused'
                    $job.message = '已暂停；点击继续恢复下载。'
                    Save-StatusFromServer -Path $statusPath -Value $job
                } else {
                    # Only the worker writes active download state. This response is an overlay.
                    $job.status = 'pausing'
                    $job.message = '正在保存下载状态；处理文件时会在安全位置暂停。'
                }
                Send-Json $Context @{ job = $job } 202
                return
            }
            if ($action -eq 'resume') {
                $job = Queue-JobAgain -Id $id -Resume
                Send-Json $Context @{ job = $job } 202
                return
            }
            if ($action -eq 'cancel') {
                if ($job.status -notin @('queued', 'running', 'waiting_network', 'pausing', 'paused')) { throw '此任务当前不能取消。' }
                Set-JobControl -Id $id -Action 'cancel'
                if ($script:ActiveWorkers.ContainsKey($id)) { Stop-CurrentWorker -Id $id; $job = Read-Status $statusPath }
                $job = Merge-SavedJobChildren $job
                $job.status = 'cancelled'
                $job.error = $null
                $job.message = '已取消；已完成的文件仍保留。'
                $job.currentTitle = $null
                $job.currentAsset = $null
                $job.progress = $null
                $job.speedBytesPerSecond = $null
                $job.downloadedBytes = $null
                $job.totalBytes = $null
                $job.etaSeconds = $null
                Save-StatusFromServer -Path $statusPath -Value $job
                Send-Json $Context @{ job = $job }
                return
            }
            if ($job.status -notin @('failed', 'partial', 'cancelled')) { throw '此任务当前不能重试。' }
            $job = Queue-JobAgain -Id $id
            Send-Json $Context @{ job = $job } 202
        } catch { Send-Json $Context @{ error = [string]$_.Exception.Message } 400 }
        return
    }
    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/history') {
        [void](List-Jobs)
        Send-Json $Context (Get-LingoHistoryView)
        return
    }
    if ($path -match '^/api/history/(recent|recent/delete|failed/delete|failed/clear|failed/[0-9a-f]{32}/retry)$' -and $request.HttpMethod -in @('POST', 'DELETE')) {
        $operation = $Matches[1]
        $origin = $request.Headers['Origin']
        if ($origin -and $origin -notin @("http://127.0.0.1:$Port", "http://localhost:$Port")) { Send-Json $Context @{ error = '只接受本机界面发起的请求。' } 403; return }
        try {
            $body = if ($request.HttpMethod -eq 'POST') { Read-JsonBody $Context } else { $null }
            switch -Regex ($operation) {
                '^recent$' {
                    if ($request.HttpMethod -eq 'DELETE') { $script:LinkHistory.recentLinks = @(); Save-LingoHistory }
                    else { Remember-LingoLinks -Urls (Validate-Urls $body.urls) }
                    break
                }
                '^recent/delete$' { $script:LinkHistory.recentLinks = @($script:LinkHistory.recentLinks | Where-Object { [string]$_.url -cne [string]$body.url }); Save-LingoHistory; break }
                '^failed/delete$' { $script:LinkHistory.failedLinks = @($script:LinkHistory.failedLinks | Where-Object { [string]$_.id -cne [string]$body.id }); Save-LingoHistory; break }
                '^failed/clear$' { $script:LinkHistory.failedLinks = @(); Save-LingoHistory; break }
                '^failed/([0-9a-f]{32})/retry$' {
                    $historyId = $Matches[1]
                    $record = @($script:LinkHistory.failedLinks | Where-Object { $_.id -eq $historyId } | Select-Object -First 1)
                    if (-not $record.Count) { throw '失败记录不存在。' }
                    if ($record[0].status -eq 'resolved') { throw '此记录已恢复，可回填链接重新下载。' }
                    $resources = @($record[0].failedResources | Where-Object { $_.status -eq 'unresolved' })
                    $retryJobIds = @($resources | ForEach-Object { [string]$_.jobId } | Select-Object -Unique)
                    if (-not $retryJobIds.Count) { $retryJobIds = @([string]$record[0].jobId) }
                    foreach ($retryJobId in $retryJobIds) {
                        Restore-HistoryJob -Id $retryJobId
                        $originalJob = Read-Status (Join-Path $script:JobsRoot "$retryJobId.status.json")
                        if (-not $originalJob -or -not [IO.File]::Exists((Join-Path $script:JobsRoot "$retryJobId.config.json"))) { throw '原任务或设置不存在，请回填链接后重新下载。' }
                        if ($originalJob.status -notin @('failed', 'partial', 'cancelled', 'completed')) { throw '关联任务正在运行、排队或暂停，请处理该任务后再重试。' }
                    }
                    $retryJobs = @(foreach ($retryJobId in $retryJobIds) { Queue-JobAgain -Id $retryJobId -RetryUrl ([string]$record[0].url) })
                    Send-Json $Context @{ job = $retryJobs[0]; jobs = $retryJobs; message = "已按 $($retryJobs.Count) 组原始设置重试失败视频；保留成品和有效断点。" } 202
                    return
                }
            }
            Send-Json $Context (Get-LingoHistoryView)
        } catch { Send-Json $Context @{ error = [string]$_.Exception.Message } 400 }
        return
    }
    if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/reveal-file') {
        $origin = $request.Headers['Origin']
        if ($origin -and $origin -notin @("http://127.0.0.1:$Port", "http://localhost:$Port")) { Send-Json $Context @{ error = '只接受本机界面发起的请求。' } 403; return }
        try {
            $body = Read-JsonBody $Context
            $target = Get-RevealTarget -JobId $body.jobId -Path $body.path
            Open-RevealTarget -Target $target
            Send-Json $Context @{ opened = $true; missing = $target.missing; message = $(if ($target.missing) { '文件已被移动或删除，已打开原保存文件夹。' } else { '已在文件夹中选中文件。' }) }
        } catch { Send-Json $Context @{ error = [string]$_.Exception.Message } 400 }
        return
    }
    if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/select-folder') {
        $origin = $request.Headers['Origin']
        if ($origin -and $origin -notin @("http://127.0.0.1:$Port", "http://localhost:$Port")) { Send-Json $Context @{ error = '只接受本机界面发起的请求。' } 403; return }
        try {
            $body = Read-JsonBody $Context
            if ($body -isnot [pscustomobject] -or -not $body.PSObject.Properties['currentPath']) { throw '请求必须包含 currentPath。' }
            $result = Select-Folder -CurrentPath $body.currentPath
            Send-Json $Context $result
        } catch {
            Send-Json $Context @{ error = [string]$_.Exception.Message } 400
        }
        return
    }
    if ($request.HttpMethod -eq 'GET' -and $path -match '^/api/inspect/([0-9a-f]{32})$') {
        $id = $Matches[1]
        $statusPath = Join-Path $script:InspectionsRoot "$id.status.json"
        if (-not [System.IO.File]::Exists($statusPath)) { Send-Json $Context @{ error = '资源解析任务不存在。' } 404; return }
        $status = Read-Status $statusPath
        if (-not $status) { Send-Json $Context @{ error = '资源解析状态暂时不可读取。' } 503; return }
        Send-Json $Context $status
        return
    }
    if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/inspect') {
        $origin = $request.Headers['Origin']
        if ($origin -and $origin -notin @("http://127.0.0.1:$Port", "http://localhost:$Port")) { Send-Json $Context @{ error = '只接受本机界面发起的请求。' } 403; return }
        if (-not $script:Ready) { Send-Json $Context @{ error = $script:HealthError } 503; return }
        try {
            $body = Read-JsonBody $Context
            if ($body -isnot [pscustomobject] -or $body.url -isnot [string]) { throw '请求必须包含一条 URL。' }
            $url = (Validate-Urls @($body.url))[0]
            $pending = 0
            foreach ($file in Get-ChildItem -LiteralPath $script:InspectionsRoot -Filter '*.status.json' -File) {
                $entry = Read-Status $file.FullName
                if ($entry -and $entry.status -in @('queued', 'running')) { $pending++ }
            }
            if ($pending -ge 8) { Send-Json $Context @{ error = '已有 8 个资源解析正在排队，请稍后重试。' } 503; return }
            $id = [guid]::NewGuid().ToString('N')
            $statusPath = Join-Path $script:InspectionsRoot "$id.status.json"
            $configPath = Join-Path $script:InspectionsRoot "$id.config.json"
            $site = Get-SiteFromUrl $url
            $metadata = Get-LingoCookieMetadata -Site $site -StoreRoot $script:DataRoot
            $status = @{ inspectionId = $id; status = 'queued'; result = $null; error = $null; createdAtUtc = [DateTime]::UtcNow.ToString('o') }
            $config = @{ id = $id; url = $url; site = $site; cookieRevision = $(if ($metadata) { [string]$metadata.revision } else { $null }); ytDlpPath = $script:YtDlp; denoPath = $script:Deno; storeRoot = $script:DataRoot; statusPath = $statusPath; inspectionsRoot = $script:InspectionsRoot }
            Save-StatusFromServer -Path $configPath -Value $config
            Save-StatusFromServer -Path $statusPath -Value $status
            $script:InspectionQueue.Enqueue($id)
            Send-Json $Context @{ inspectionId = $id; status = 'queued' } 202
        } catch { Send-Json $Context @{ error = [string]$_.Exception.Message } 400 }
        return
    }
    if ($request.HttpMethod -eq 'POST' -and $path -in @('/api/preview', '/api/jobs')) {
        $origin = $request.Headers['Origin']
        if ($origin -and $origin -notin @("http://127.0.0.1:$Port", "http://localhost:$Port")) { Send-Json $Context @{ error = '只接受本机界面发起的请求。' } 403; return }
        if (-not $script:Ready) { Send-Json $Context @{ error = $script:HealthError } 503; return }
        try {
            $body = Read-JsonBody $Context
            $urls = Validate-Urls $body.urls
            if ($path -eq '/api/preview') {
                $pending = 0
                foreach ($file in Get-ChildItem -LiteralPath $script:PreviewsRoot -Filter '*.status.json' -File) {
                    $existing = Read-Status $file.FullName
                    if ($existing -and $existing.status -in @('queued', 'running')) { $pending++ }
                }
                if ($pending -ge 8) { Send-Json $Context @{ error = '已有 8 个预览正在排队，请稍后重试。' } 503; return }
                Remember-LingoLinks -Urls $urls
                $id = [guid]::NewGuid().ToString('N')
                $statusPath = Join-Path $script:PreviewsRoot "$id.status.json"
                $configPath = Join-Path $script:PreviewsRoot "$id.config.json"
                $status = @{ previewId = $id; status = 'queued'; result = $null; error = $null; processed = 0; totalSources = $urls.Count }
                $config = @{ id = $id; urls = @($urls); ytDlpPath = $script:YtDlp; denoPath = $script:Deno; storeRoot = $script:DataRoot; statusPath = $statusPath; previewRoot = $script:PreviewsRoot }
                Save-StatusFromServer -Path $configPath -Value $config
                Save-StatusFromServer -Path $statusPath -Value $status
                $script:PreviewQueue.Enqueue($id)
                Send-Json $Context @{ previewId = $id; status = 'queued' } 202
                return
            }
            $selectedVideos = @{}
            if ($null -ne $body.selectedVideos) {
                if ($body.selectedVideos -isnot [pscustomobject]) { throw '视频选择格式无效。' }
                foreach ($property in $body.selectedVideos.PSObject.Properties) {
                    if ($property.Name -cnotin $urls -or $property.Value -isnot [array] -or $property.Value.Count -lt 1) { throw '所选视频必须属于当前提交的来源。' }
                    foreach ($value in $property.Value) { if ($value -isnot [string] -or -not $value -or $value.Length -gt 4096 -or $value -match '[\r\n]') { throw '视频选择标识无效。' } }
                    $selectedVideos[$property.Name] = @($property.Value | Select-Object -Unique)
                }
            }
            $resourceMode = $null -ne $body.parts
            $parts = $null
            $audioLanguages = @()
            $sourceSelections = @{}
            $autoSimplify = $false
            if ($resourceMode) {
                if ($body.parts -isnot [pscustomobject]) { throw '下载部件设置无效。' }
                foreach ($partName in @('video', 'audio', 'subtitles')) {
                    $partProperty = $body.parts.PSObject.Properties[$partName]
                    if (-not $partProperty -or $partProperty.Value -isnot [bool]) { throw "部件 $partName 必须是布尔值。" }
                }
                $parts = @{ video = [bool]$body.parts.video; audio = [bool]$body.parts.audio; subtitles = [bool]$body.parts.subtitles }
                if (-not ($parts.video -or $parts.audio -or $parts.subtitles)) { throw '至少选择一种下载部件。' }
                if ($null -ne $body.autoSimplify -and $body.autoSimplify -isnot [bool]) { throw '自动简化设置无效。' }
                $audioLanguages = Validate-LanguageList -Raw $body.audioLanguages -Label '音轨语言'
                $sourceSelections = Validate-SourceSelections -Raw $body.sourceSelections -Urls $urls
                $mode = 'resources'
            } else {
                $mode = if ($body.mode -in @('video', 'audio')) { [string]$body.mode } else { throw '仅支持视频或音频模式。' }
            }
            $audioOutputFormats = @('original')
            if ($null -ne $body.audioOutputFormats) {
                if ($body.audioOutputFormats -isnot [array] -or $body.audioOutputFormats.Count -lt 1 -or $body.audioOutputFormats.Count -gt 2) { throw '请选择原始音频或 MP3，可同时选择。' }
                foreach ($outputFormat in $body.audioOutputFormats) { if ($outputFormat -isnot [string] -or $outputFormat -cnotin @('original', 'mp3')) { throw '音频格式仅支持原始音频和 MP3。' } }
                $audioOutputFormats = @($body.audioOutputFormats | Select-Object -Unique)
            }
            $quality = if ($body.quality -in @('720p', '1080p', '1440p', '2160p', 'best')) { [string]$body.quality } else { 'best' }
            $container = if ($body.container -in @('mkv', 'mp4')) { [string]$body.container } else { 'mkv' }
            $subtitleLanguages = if ($resourceMode) { Validate-LanguageList -Raw $body.subtitleLanguages -Label '字幕语言' } else { @() }
            if (-not $resourceMode -and $null -ne $body.subtitleLanguages) {
                if ($body.subtitleLanguages -isnot [array]) { throw '字幕语言格式无效。' }
                $subtitleLanguages = @($body.subtitleLanguages | Where-Object { $_ -in @('fr', 'de', 'en', 'es', 'it', 'pt', 'zh') } | Select-Object -Unique)
                if ($subtitleLanguages.Count -ne $body.subtitleLanguages.Count) { throw '字幕语言仅支持 fr、de、en、es、it、pt、zh。' }
            }
            if (-not $resourceMode -and $body.subtitleFormat -eq 'docx') { throw 'Word 字幕需要使用下载内容设置。' }
            $subtitleFormat = if ($body.subtitleFormat -in @('srt', 'vtt', 'docx')) { ([string]$body.subtitleFormat).ToLowerInvariant() } else { 'srt' }
            $subtitleFormats = @($subtitleFormat)
            if ($null -ne $body.subtitleFormats) {
                if (-not $resourceMode -or $body.subtitleFormats -isnot [array] -or $body.subtitleFormats.Count -notin (1..3)) { throw '请选择有效的字幕格式。' }
                foreach ($format in $body.subtitleFormats) { if ($format -isnot [string] -or $format -cnotin @('srt','vtt','docx')) { throw '不支持所选字幕格式。' } }
                $subtitleFormats = @($body.subtitleFormats | Select-Object -Unique)
            }
            $directory = Validate-Path $body.path
            Remember-LingoLinks -Urls $urls
            $id = [guid]::NewGuid().ToString('N')
            $statusPath = Join-Path $script:JobsRoot "$id.status.json"
            $configPath = Join-Path $script:JobsRoot "$id.config.json"
            $archivePath = Join-Path $script:JobsRoot "$id.archive.txt"
            $knownTotal = $null
            if ($script:PreviewCache -and $script:PreviewCache.key -eq ($urls -join "`n") -and ([DateTime]::UtcNow - $script:PreviewCache.at).TotalMinutes -lt 30) { $knownTotal = $script:PreviewCache.total }
            $cookieRevisions = @{}
            foreach ($url in $urls) {
                $site = Get-SiteFromUrl $url
                if (-not $cookieRevisions.ContainsKey($site)) {
                    $metadata = Get-LingoCookieMetadata -Site $site -StoreRoot $script:DataRoot
                    if ($metadata) { $cookieRevisions[$site] = [string]$metadata.revision }
                }
            }
            $job = @{ id = $id; status = 'queued'; createdAt = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); path = $directory; urls = @($urls); sourceCount = $urls.Count; total = $knownTotal; completed = 0; skipped = 0; failed = 0; currentTitle = $null; currentAsset = $null; progress = 0; speedBytesPerSecond = $null; downloadedBytes = $null; totalBytes = $null; etaSeconds = $null; error = $null; message = '已排队'; items = @() }
            $config = @{ id = $id; urls = @($urls); path = $directory; mode = $mode; parts = $parts; audioLanguages = @($audioLanguages); audioOutputFormats = @($audioOutputFormats); autoSimplify = $autoSimplify; sourceSelections = $sourceSelections; selectedVideos = $selectedVideos; quality = $quality; container = $container; subtitleLanguages = @($subtitleLanguages); subtitleFormat = $subtitleFormat; subtitleFormats = $subtitleFormats; ytDlpPath = $script:YtDlp; ffmpegDirectory = (Split-Path -Parent $script:Ffmpeg); ffprobePath = $script:Ffprobe; denoPath = $script:Deno; statusPath = $statusPath; archivePath = $archivePath; storeRoot = $script:DataRoot; cookieRevisions = $cookieRevisions }
            $job.attempt = 1
            $config.attempt = 1
            Save-StatusFromServer -Path $statusPath -Value $job
            Save-StatusFromServer -Path $configPath -Value $config
            Enqueue-Job $id
            $response = @{ job = $job }
            if ($directory -cne $script:DefaultDownloadPath) {
                try {
                    Save-StatusFromServer -Path $script:SettingsPath -Value @{
                        defaultDownloadPath = $directory
                        maxConcurrentDownloads = $script:MaxConcurrentDownloads
                        defaultDownloadParts = $script:DefaultDownloadParts
                    }
                    $script:DefaultDownloadPath = $directory
                } catch {
                    $response.settingsWarning = '下载任务已加入队列，最近使用的目录未能保存到设置。'
                }
            }
            $response.defaultDownloadPath = $script:DefaultDownloadPath
            Send-Json $Context $response 202
            return
        } catch {
            Send-Json $Context @{ error = [string]$_.Exception.Message } 400
            return
        }
    }
    if ($request.HttpMethod -eq 'GET' -and $path -in @('/', '/index.html', '/styles.css', '/app.js', '/batch.js', '/assets/icons/lingosave-app.png', '/assets/icons/lingosave-app-v2.ico')) {
        $name = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
        Serve-Static $Context $name
        return
    }
    Send-Json $Context @{ error = 'Not found' } 404
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
try {
    $listener.Start()
    foreach ($file in Get-ChildItem -LiteralPath $script:PreviewsRoot -Filter '*.status.json' -File) {
        $oldPreview = Read-Status $file.FullName
        if ($oldPreview -and $oldPreview.status -in @('queued', 'running')) {
            $id = [string]$oldPreview.previewId
            if ($id -match '^[0-9a-f]{32}$') {
                Stop-RecordedProcess (Join-Path $script:PreviewsRoot "$id.worker.pid.json")
                Stop-RecordedProcess (Join-Path $script:PreviewsRoot "$id.extractor.pid.json")
                Remove-PreviewTemporaryCookie -Id $id
            }
            $oldPreview.status = 'failed'
            $oldPreview.error = '服务已重新启动，请重新预览。'
            Save-StatusFromServer -Path $file.FullName -Value $oldPreview
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $script:InspectionsRoot -Filter '*.status.json' -File) {
        $oldInspection = Read-Status $file.FullName
        if ($oldInspection -and $oldInspection.status -in @('queued', 'running')) {
            $id = [string]$oldInspection.inspectionId
            if ($id -match '^[0-9a-f]{32}$') {
                Stop-RecordedProcess (Join-Path $script:InspectionsRoot "$id.worker.pid.json")
                Remove-InspectionTemporaryCookie -Id $id
            }
            $oldInspection.status = 'failed'
            $oldInspection.error = '服务已重新启动，请重新解析资源。'
            Save-StatusFromServer -Path $file.FullName -Value $oldInspection
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $script:JobsRoot -Filter '*.status.json' -File) {
        $oldJob = Read-Status $file.FullName
        if ($oldJob -and $oldJob.status -in @('queued', 'running', 'waiting_network', 'pausing', 'paused')) {
            Stop-RecordedProcess (Join-Path $script:JobsRoot "$($oldJob.id).worker.pid.json")
            Stop-RecordedProcess (Join-Path $script:JobsRoot "$($oldJob.id).media.pid.json")
            Stop-JobChildren -Id ([string]$oldJob.id)
            Remove-JobTemporaryCookie -Id ([string]$oldJob.id)
            $oldJob = Merge-SavedJobChildren $oldJob
            $wasPaused = $oldJob.status -in @('pausing', 'paused') -or (Get-JobControl $oldJob.id).action -eq 'pause'
            $oldJob.status = if ($wasPaused) { 'paused' } else { 'queued' }
            $oldJob.error = $null
            $oldJob.message = if ($wasPaused) { '服务重启后保持暂停；点击继续恢复。' } else { '服务重启后已恢复排队，将复用已有下载数据。' }
            if (-not $wasPaused) { $oldJob.currentTitle = $null; $oldJob.currentAsset = $null; $oldJob.downloadedBytes = $null; $oldJob.totalBytes = $null }
            $oldJob.speedBytesPerSecond = $null
            $oldJob.etaSeconds = $null
            Save-StatusFromServer -Path $file.FullName -Value $oldJob
            if (-not $wasPaused) { Enqueue-Job ([string]$oldJob.id) }
        }
        Sync-JobHistory $oldJob
    }
    $cookieTempRoot = Join-Path (Join-Path $script:DataRoot 'credentials') 'tmp'
    if ([System.IO.Directory]::Exists($cookieTempRoot)) {
        foreach ($file in Get-ChildItem -LiteralPath $cookieTempRoot -Filter 'lingosave-cookie-*.txt' -File) {
            try { Remove-LingoTemporaryCookieFile -Path $file.FullName -StoreRoot $script:DataRoot } catch { }
        }
    }
    Write-Host "LingoSave 本机服务：http://127.0.0.1:$Port/"
    if (-not $script:Ready) { Write-Warning $script:HealthError }
    if (-not $script:Deno) { Write-Warning '未找到 Deno，YouTube 支持可能不完整。' }
    while ($true) {
        if (-not (Test-LauncherAlive)) { break }
        if ([System.IO.File]::Exists($script:ShutdownPath)) { break }
        Sync-CurrentWorker
        Start-NextJob
        Sync-CurrentPreview
        Start-NextPreview
        Sync-CurrentInspection
        Start-NextInspection
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 120; continue }
        $client = $listener.AcceptTcpClient()
        $context = $null
        try {
            $context = Read-Request $client
            Handle-Request $context
        }
        catch {
            if ($context) { try { Send-Json $context @{ error = "服务错误：$($_.Exception.Message)" } 500 } catch { } }
        }
        finally { try { $client.Close() } catch { } }
    }
} finally {
    Stop-CurrentInspection
    Stop-CurrentPreview
    Stop-CurrentWorker
    $listener.Stop()
    try { if ([System.IO.File]::Exists($script:ShutdownPath)) { [System.IO.File]::Delete($script:ShutdownPath) } } catch { }
    if ($script:OwnInstanceMutex) { try { $script:InstanceMutex.ReleaseMutex() } catch { } }
    if ($script:InstanceMutex) { $script:InstanceMutex.Dispose() }
}

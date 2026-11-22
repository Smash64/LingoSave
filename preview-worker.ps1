param([Parameter(Mandatory = $true)][string]$ConfigPath)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'credential-store.ps1')
. (Join-Path $PSScriptRoot 'state-io.ps1')

. (Join-Path $PSScriptRoot 'playlist-folders.ps1')

$config = Read-LingoJson -Path $ConfigPath -ThrowOnError
$id = [string]$config.id
if ($id -notmatch '^[0-9a-f]{32}$') { throw '预览标识无效。' }
$previewRoot = [System.IO.Path]::GetFullPath([string]$config.previewRoot)
$storeRoot = [System.IO.Path]::GetFullPath([string]$config.storeRoot)
$statusPath = Join-Path $previewRoot "$id.status.json"
$extractorPidPath = Join-Path $previewRoot "$id.extractor.pid.json"
$cookieMarkerPath = Join-Path $previewRoot "$id.cookie-temp.json"
$deadline = [DateTime]::UtcNow.AddSeconds(180)

function Save-PreviewStatus {
    param($Value)
    [void](Write-LingoJson -Path $statusPath -Value $Value -Depth 15)
}

function Get-PreviewEntryUrl {
    param($Entry, [string]$Site)
    return Resolve-LingoMediaEntryUrl -Entry $Entry -Site $Site
}

function Get-PreviewSite {
    param([string]$Url)
    return [string]((Get-LingoSiteForUrl -Url $Url).id)
}

function Get-PreviewPlatform {
    param([string]$Site)
    return [string]((Get-LingoSiteDefinition -Id $Site).label)
}

function Stop-Extractor {
    param($Process)
    try {
        if (-not $Process.HasExited) {
            $taskkill = Join-Path $env:WINDIR 'System32\taskkill.exe'
            if ([System.IO.File]::Exists($taskkill)) { & $taskkill /PID $Process.Id /T /F *> $null }
            else { $Process.Kill() }
            [void]$Process.WaitForExit(3000)
        }
    } catch { try { $Process.Kill() } catch { } }
}

function Invoke-PreviewOne {
    param([string]$Url)
    $site = Get-PreviewSite $Url
    $cookieFile = $null
    $process = $null
    try {
        $uri = [Uri]$Url
        $singleBilibiliPart = $site -eq 'bilibili' -and $uri.AbsolutePath -match '^/video/' -and $uri.Query -match '(?:^\?|&)p=[1-9][0-9]*(?:&|$)'
        $playlistOption = if ($singleBilibiliPart) { '--no-playlist' } else { '--yes-playlist' }
        $arguments = @('--no-config', '--dump-single-json', '--flat-playlist', $playlistOption, '--no-abort-on-error', '--no-warnings', '--no-colors')
        if ($config.denoPath) { $arguments += @('--js-runtimes', "deno:$($config.denoPath)") }
        $metadata = Get-LingoCookieMetadata -Site $site -StoreRoot $storeRoot
        if ($metadata) {
            $cookieFile = New-LingoTemporaryCookieFile -Site $site -StoreRoot $storeRoot -Revision ([string]$metadata.revision)
            [System.IO.File]::WriteAllText($cookieMarkerPath, (ConvertTo-Json -InputObject @{ path = $cookieFile } -Compress), [System.Text.UTF8Encoding]::new($false))
            $arguments += @('--cookies', $cookieFile)
        }
        $arguments += $Url
        $start = [System.Diagnostics.ProcessStartInfo]::new()
        $start.FileName = [string]$config.ytDlpPath
        $start.Arguments = (($arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' ')
        $start.WorkingDirectory = $PSScriptRoot
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $start.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $start
        if (-not $process.Start()) { throw '无法启动 yt-dlp。' }
        $pidInfo = @{ pid = $process.Id; startedAtTicks = $process.StartTime.Ticks; processName = $process.ProcessName }
        [System.IO.File]::WriteAllText($extractorPidPath, (ConvertTo-Json -InputObject $pidInfo -Compress), [System.Text.UTF8Encoding]::new($false))
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timeLeft = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
        $timeout = [int][Math]::Max(1, [Math]::Min(30000, $timeLeft))
        if (-not $process.WaitForExit($timeout)) { throw '预览此链接超过 30 秒，已停止解析。' }
        $json = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or -not $json.Trim()) {
            if ($errors -match 'WinError 10013') { throw '当前运行环境阻止 yt-dlp 连接视频站点（WinError 10013）。' }
            $details = ($errors -split '\r?\n' | Where-Object { $_ -match 'ERROR:' } | Select-Object -First 1)
            if ($details -match 'ERROR:\s*(.*)$') { $details = $Matches[1] }
            if (-not $details) { $details = "yt-dlp 退出代码 $($process.ExitCode)" }
            $hint = Get-LingoSiteFailureHint -Site $site -Message $errors
            if ($hint) { throw $hint }
            throw ([string]$details).Trim()
        }
        if ($json.Length -gt 8MB) { throw '播放列表预览数据过大，请直接添加下载任务。' }
        $info = ConvertFrom-Json -InputObject $json
        $isPlaylist = $info._type -in @('playlist', 'multi_video') -or $null -ne $info.entries
        $entries = [System.Collections.Generic.List[object]]::new()
        $count = 1
        $countIsEstimate = $false
        if ($isPlaylist) {
            foreach ($entry in $info.entries) {
                if ($null -eq $entry) { continue }
                $officialTitle = Get-LingoOfficialPlaylistTitle -Info $entry -Site $site
                $entryTitle = if ($entry.title) { [string]$entry.title } elseif ($entry.id) { [string]$entry.id } else { '未命名资源' }
                if ($officialTitle) { $entryTitle = $officialTitle }
                [void]$entries.Add(@{ title = $entryTitle; id = [string]$entry.id; url = (Get-PreviewEntryUrl -Entry $entry -Site $site); sourceUrl = $Url })
            }
            $count = $entries.Count
            $playlistCount = 0
            if ([int]::TryParse([string]$info.playlist_count, [ref]$playlistCount) -and $playlistCount -gt $count) { $count = $playlistCount }

        }
        $audioOnly = (Get-LingoSiteDefinition -Id $site).mediaType -eq 'audio'
        return @{ url = $Url; title = [string]$info.title; kind = $(if ($isPlaylist) { 'playlist' } elseif ($audioOnly) { 'audio' } else { 'video' }); mediaType = $(if ($audioOnly) { 'audio' } else { 'video' }); count = $count; countIsEstimate = $countIsEstimate; entries = @($entries.ToArray()); platform = (Get-PreviewPlatform $site) }
    } finally {
        if ($process) {
            Stop-Extractor $process
            try { $process.Dispose() } catch { }
        }
        try { [System.IO.File]::Delete($extractorPidPath) } catch { }
        if ($cookieFile) { try { Remove-LingoTemporaryCookieFile -Path $cookieFile -StoreRoot $storeRoot } catch { } }
        try { [System.IO.File]::Delete($cookieMarkerPath) } catch { }
    }
}

$status = @{ previewId = $id; status = 'running'; result = $null; error = $null; processed = 0; totalSources = @($config.urls).Count }
$items = [System.Collections.Generic.List[object]]::new()
$total = 0
try {
    Save-PreviewStatus $status
    foreach ($url in $config.urls) {
        $site = Get-PreviewSite ([string]$url)
        try {
            if ([DateTime]::UtcNow -ge $deadline) { throw '本批预览超过 180 秒，剩余链接请直接下载或另行预览。' }
            $item = Invoke-PreviewOne -Url ([string]$url)
            $total += [int]$item.count
        } catch {
            $message = [string]$_.Exception.Message
            if ($message.Length -gt 500) { $message = $message.Substring(0, 500) }
            $item = @{ url = [string]$url; platform = (Get-PreviewPlatform $site); kind = 'video'; title = [string]$url; count = 0; entries = @(); error = $message }
        }
        [void]$items.Add($item)
        $status.processed = $items.Count
        Save-PreviewStatus $status
    }
    $status.status = 'completed'
    $status.result = @{ items = @($items.ToArray()); totalVideos = $total }
    Save-PreviewStatus $status
} catch {
    $status.status = 'failed'
    $status.error = [string]$_.Exception.Message
    Save-PreviewStatus $status
    exit 1
}

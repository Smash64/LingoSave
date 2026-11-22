$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $env:TEMP ('lingosave-server-improvements-' + [guid]::NewGuid().ToString('N'))
$dataRoot = Join-Path $testRoot 'data'
$jobsRoot = Join-Path $dataRoot 'jobs'
$mediaRoot = Join-Path $testRoot 'media'
$fakePath = Join-Path $testRoot 'fake-yt-dlp.exe'
$oldData = $env:LINGOSAVE_DATA_DIR
$oldExtractor = $env:LINGOSAVE_YTDLP_PATH
$script:service = $null
$script:assertions = 0
[void][IO.Directory]::CreateDirectory($jobsRoot)
[void][IO.Directory]::CreateDirectory($mediaRoot)
. (Join-Path $projectRoot 'state-io.ps1')

function Assert-ServerTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:assertions++
    Write-Host "PASS: $Message"
}

function Invoke-TestApi {
    param([string]$Method, [string]$Path, $Body = $null)
    $request = [Net.HttpWebRequest][Net.WebRequest]::Create("http://127.0.0.1:$script:testPort$Path")
    $request.Method = $Method
    $request.Timeout = 4000
    $request.ReadWriteTimeout = 4000
    $request.Proxy = $null
    if ($Method -eq 'POST') {
        $request.ContentType = 'application/json; charset=utf-8'
        $json = if ($null -eq $Body) { '{}' } else { ConvertTo-Json -InputObject $Body -Depth 25 -Compress }
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    try { $response = [Net.HttpWebResponse]$request.GetResponse() }
    catch [Net.WebException] { if (-not $_.Exception.Response) { throw }; $response = [Net.HttpWebResponse]$_.Exception.Response }
    try {
        $reader = [IO.StreamReader]::new($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return [pscustomobject]@{ Code = [int]$response.StatusCode; Json = ($content | ConvertFrom-Json) }
    } finally { $response.Dispose() }
}

function Write-TestJson { param([string]$Path, $Value); [void](Write-LingoJson -Path $Path -Value $Value -Depth 25) }
function Read-TestJob { param([string]$Id); return Read-LingoJson -Path (Join-Path $jobsRoot "$Id.status.json") -ThrowOnError }

function Start-TestService {
    $reserve = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $reserve.Start()
    $script:testPort = ([Net.IPEndPoint]$reserve.LocalEndpoint).Port
    $reserve.Stop()
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $PSHOME 'powershell.exe'
    $start.Arguments = '-NoProfile -NonInteractive -Sta -ExecutionPolicy Bypass -File "' + (Join-Path $projectRoot 'server.ps1') + '" -Port ' + $script:testPort
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $script:service = [Diagnostics.Process]::Start($start)
    $ready = $false
    for ($attempt = 0; $attempt -lt 70; $attempt++) {
        if ($script:service.HasExited) { throw "Isolated service exited: $($script:service.StandardError.ReadToEnd())" }
        try { $health = Invoke-TestApi 'GET' '/api/health'; if ($health.Code -eq 200 -and $health.Json.ready) { $ready = $true; break } } catch { }
        Start-Sleep -Milliseconds 150
    }
    Assert-ServerTest $ready 'isolated service starts with fake extractor and a fresh data directory'
}

function Stop-TestService {
    if (-not $script:service) { return }
    if (-not $script:service.HasExited) {
        [IO.File]::WriteAllText((Join-Path $dataRoot 'shutdown.request'), '', [Text.Encoding]::ASCII)
        if (-not $script:service.WaitForExit(20000)) { throw 'Isolated service did not stop safely.' }
    }
    [IO.File]::WriteAllText((Join-Path $testRoot 'server-out.log'), $script:service.StandardOutput.ReadToEnd(), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $testRoot 'server-error.log'), $script:service.StandardError.ReadToEnd(), [Text.UTF8Encoding]::new($false))
    $script:service.Dispose()
    $script:service = $null
}

function Wait-TestJob {
    param([string]$Id, [string[]]$States, [int]$Seconds = 20)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
        $response = Invoke-TestApi 'GET' '/api/jobs'
        $job = @($response.Json.jobs | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
        if ($job.Count -and $job[0].status -in $States) { return $job[0] }
        Start-Sleep -Milliseconds 150
    }
    $job = Read-TestJob $Id
    throw "Job $Id did not reach $($States -join ', '); actual $($job.status): $($job.error)"
}

function New-TestConfig {
    param([string]$Id, [string[]]$Urls, [switch]$Resources)
    return @{ id = $Id; urls = @($Urls); path = $mediaRoot; mode = 'video'; parts = $(if ($Resources) { @{ video = $true; audio = $true; subtitles = $true } } else { $null }); quality = '720p'; container = 'mp4'; audioLanguages = @('en', 'fr'); subtitleLanguages = @('fr'); subtitleFormat = 'srt'; sourceSelections = @{}; attempt = 1; ytDlpPath = $fakePath; ffmpegDirectory = 'E:\ffmpeg\bin'; ffprobePath = 'E:\ffmpeg\bin\ffprobe.exe'; statusPath = (Join-Path $jobsRoot "$Id.status.json"); archivePath = (Join-Path $jobsRoot "$Id.archive.txt"); storeRoot = $dataRoot; cookieRevisions = @{} }
}

try {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe "/out:$fakePath" (Join-Path $PSScriptRoot 'FakePreviewExtractor.cs')
    if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($fakePath)) { throw 'Cannot build fake extractor.' }
    $env:LINGOSAVE_DATA_DIR = $dataRoot
    $env:LINGOSAVE_YTDLP_PATH = $fakePath

    $failedId = [guid]::NewGuid().ToString('N')
    $partialId = [guid]::NewGuid().ToString('N')
    $failedUrl = 'https://www.youtube.com/watch?v=failed-fixture'
    $partialUrl = 'https://www.youtube.com/watch?v=hang-target'
    $playlistUrl = 'https://www.youtube.com/playlist?list=fixture'
    $completePath = Join-Path $mediaRoot '已有完整视频.mp4'
    [IO.File]::WriteAllText($completePath, 'fixture-completed-output', [Text.Encoding]::ASCII)
    $failedStatus = @{ id = $failedId; status = 'failed'; attempt = 1; urls = @($failedUrl); items = @(@{ url = $failedUrl; title = 'Failed fixture'; status = 'failed'; error = 'Fixture disk error'; assets = @() }); error = 'Fixture disk error'; message = 'Fixture disk error'; path = $mediaRoot; completed = 0; failed = 1 }
    $partialStatus = @{ id = $partialId; status = 'partial'; attempt = 1; urls = @($playlistUrl); path = $mediaRoot; error = 'Fixture subtitle error'; message = 'Fixture subtitle error'; completed = 1; failed = 1; items = @(@{ url = $partialUrl; sourceUrl = $playlistUrl; title = 'Partial fixture'; status = 'partial'; assets = @(@{ key = 'video'; type = 'video'; status = 'completed'; path = $completePath }, @{ key = 'subtitle:fr:provided'; type = 'subtitle'; language = 'fr'; source = 'provided'; trackId = 'fr'; stage = 'subtitle'; status = 'failed'; error = 'Fixture subtitle error' }) }, @{ url = 'https://www.youtube.com/watch?v=good-fixture'; sourceUrl = $playlistUrl; title = 'Completed sibling'; status = 'completed'; path = $completePath; assets = @() }) }
    foreach ($seed in @($failedStatus, $partialStatus)) { foreach ($field in @('speedBytesPerSecond', 'etaSeconds', 'progress', 'downloadedBytes', 'totalBytes', 'currentTitle', 'currentAsset')) { $seed[$field] = $null } }
    Write-TestJson (Join-Path $jobsRoot "$failedId.status.json") $failedStatus
    Write-TestJson (Join-Path $jobsRoot "$failedId.config.json") (New-TestConfig $failedId @($failedUrl))
    $partialConfig = New-TestConfig $partialId @($playlistUrl) -Resources
    $partialConfig.sourceSelections[$partialUrl] = @{ mediaId = 'target'; audioFormatIds = @('251'); subtitleTracks = @(@{ rawKey = 'fr'; source = 'provided' }); explicitAudio = $true; explicitSubtitles = $true }
    Write-TestJson (Join-Path $jobsRoot "$partialId.status.json") $partialStatus
    Write-TestJson (Join-Path $jobsRoot "$partialId.config.json") $partialConfig

    Start-TestService
    # These original lifecycle scenarios deliberately exercise a single busy queue.
    $initial = (Invoke-TestApi 'GET' '/api/settings').Json.defaultDownloadParts
    Assert-ServerTest ($initial.video -and -not $initial.audio -and $initial.subtitles) 'new installs default to video and subtitles, with separate audio turned off'
    $invalid = Invoke-TestApi 'POST' '/api/settings' @{ defaultDownloadParts = @{ video = $false; audio = $false; subtitles = $false } }
    Assert-ServerTest ($invalid.Code -eq 400) 'empty default download settings are rejected'
    $savedParts = Invoke-TestApi 'POST' '/api/settings' @{ defaultDownloadParts = @{ video = $false; audio = $true; subtitles = $false } }
    Assert-ServerTest ($savedParts.Code -eq 200 -and $savedParts.Json.defaultDownloadParts.audio) 'users can save a custom default download selection'
    [void](Invoke-TestApi 'POST' '/api/settings' @{ maxConcurrentDownloads = 1 })
    $history = Invoke-TestApi 'GET' '/api/history'
    Assert-ServerTest ($history.Code -eq 200 -and @($history.Json.failedLinks).Count -eq 2) 'failed and partial playlist entries produce separate failure histories'
    $partialRecord = @($history.Json.failedLinks | Where-Object { $_.url -eq $partialUrl })[0]
    Assert-ServerTest ($partialRecord.failureCount -eq 1 -and @($partialRecord.failedResources).Count -eq 1 -and $partialRecord.failedResources[0].type -eq 'subtitle') 'partial failure records only the failed resource and preserves the video'
    for ($index = 0; $index -lt 4; $index++) { $history = Invoke-TestApi 'GET' '/api/history' }
    Assert-ServerTest (@($history.Json.failedLinks | Where-Object { $_.url -eq $failedUrl })[0].failureCount -eq 1) 'polling the same completed attempt does not increase failure count'
    $failedStatus.attempt = 2
    Write-TestJson (Join-Path $jobsRoot "$failedId.status.json") $failedStatus
    $history = Invoke-TestApi 'GET' '/api/history'
    Assert-ServerTest (@($history.Json.failedLinks | Where-Object { $_.url -eq $failedUrl })[0].failureCount -eq 2) 'a new failed attempt increases failure count exactly once'

    $body = @{ urls = @('https://www.youtube.com/watch?v=hang'); mode = 'video'; quality = 'best'; container = 'mkv'; subtitleLanguages = @(); path = $mediaRoot }
    $blocker = Invoke-TestApi 'POST' '/api/jobs' $body
    Assert-ServerTest ($blocker.Code -eq 202) 'running pause fixture is accepted'
    $savedFolder = Invoke-TestApi 'GET' '/api/settings'
    Assert-ServerTest ($blocker.Json.defaultDownloadPath -eq $mediaRoot -and $savedFolder.Json.defaultDownloadPath -eq $mediaRoot -and $savedFolder.Json.maxConcurrentDownloads -eq 1) 'accepted job updates the default folder and preserves the download limit'
    $blockerId = [string]$blocker.Json.job.id
    [void](Wait-TestJob $blockerId @('running'))

    # Keep the fake legacy downloader occupied so API validation can be tested independently.
    $entryUrl = 'https://www.youtube.com/watch?v=playlist-selection-fixture'
    $outsideEntryUrl = 'https://www.youtube.com/watch?v=outside-playlist-fixture'
    $previewSeedId = [guid]::NewGuid().ToString('N')
    $inspectionSeedId = [guid]::NewGuid().ToString('N')
    $previewSeed = @{ previewId = $previewSeedId; status = 'completed'; result = @{ totalVideos = 1; items = @(@{ url = $playlistUrl; title = 'Playlist selection fixture'; platform = 'YouTube'; type = 'playlist'; count = 1; entries = @(@{ id = 'playlist-child-fixture'; title = 'Child selection fixture'; url = $entryUrl; webpageUrl = $entryUrl }) }) } }
    $inspectionSeed = @{ inspectionId = $inspectionSeedId; status = 'completed'; createdAtUtc = [DateTime]::UtcNow.ToString('o'); result = @{ url = $entryUrl; id = 'playlist-child-fixture'; mediaId = 'playlist-child-fixture'; audioTracks = @(@{ formatId = '251'; language = 'en' }); subtitles = @(@{ rawKey = 'en'; source = 'provided'; language = 'en' }) } }
    Write-TestJson (Join-Path (Join-Path $dataRoot 'previews') "$previewSeedId.status.json") $previewSeed
    Write-TestJson (Join-Path (Join-Path $dataRoot 'inspections') "$inspectionSeedId.status.json") $inspectionSeed
    $childSelection = @{ mediaId = 'playlist-child-fixture'; audioFormatIds = @('251'); subtitleTracks = @(@{ rawKey = 'en'; source = 'provided' }); explicitAudio = $true; explicitSubtitles = $true }
    $playlistParts = @{ video = $true; audio = $true; subtitles = $true }
    $entrySelections = @{}
    $entrySelections[$entryUrl] = $childSelection
    $playlistBody = @{ urls = @($playlistUrl); parts = $playlistParts; sourceSelections = $entrySelections; quality = '720p'; container = 'mp4'; audioLanguages = @('en'); subtitleLanguages = @('en'); subtitleFormat = 'srt'; path = $mediaRoot }
    $selectedPlaylist = Invoke-TestApi 'POST' '/api/jobs' $playlistBody
    Assert-ServerTest ($selectedPlaylist.Code -eq 202 -and $selectedPlaylist.Json.job.urls[0] -eq $playlistUrl) 'playlist job accepts an exact selection for an inspected child belonging to its preview'
    $selectedPlaylistId = [string]$selectedPlaylist.Json.job.id
    $selectedConfig = Read-LingoJson -Path (Join-Path $jobsRoot "$selectedPlaylistId.config.json") -ThrowOnError
    $storedChildSelection = $selectedConfig.sourceSelections.PSObject.Properties[$entryUrl].Value
    Assert-ServerTest ($storedChildSelection.mediaId -eq 'playlist-child-fixture' -and $storedChildSelection.audioFormatIds[0] -eq '251' -and $storedChildSelection.subtitleTracks[0].rawKey -eq 'en' -and $storedChildSelection.subtitleTracks[0].source -eq 'provided') 'playlist child selection retains exact media, audio format and subtitle identity in the root configuration'
    [void](Invoke-TestApi 'POST' "/api/jobs/$selectedPlaylistId/cancel")
    $outsideSelections = @{}
    $outsideSelections[$outsideEntryUrl] = $childSelection
    $playlistBody.sourceSelections = $outsideSelections
    $outsideResult = Invoke-TestApi 'POST' '/api/jobs' $playlistBody
    Assert-ServerTest ($outsideResult.Code -eq 400 -and $outsideResult.Json.error -match '播放列表') 'exact selections for URLs outside the requested playlist are rejected before download'

    $queued = Invoke-TestApi 'POST' '/api/jobs' $body
    $queuedId = [string]$queued.Json.job.id
    $pauseQueued = Invoke-TestApi 'POST' "/api/jobs/$queuedId/pause"
    Assert-ServerTest ($pauseQueued.Code -eq 202 -and $pauseQueued.Json.job.status -eq 'paused') 'queued job pauses without starting a downloader'
    $pauseAgain = Invoke-TestApi 'POST' "/api/jobs/$queuedId/pause"
    Assert-ServerTest ($pauseAgain.Code -eq 200 -and $pauseAgain.Json.job.status -eq 'paused') 'repeated pause is idempotent'
    $checkpoint = Join-Path $jobsRoot "$queuedId.test-checkpoint.part"
    [IO.File]::WriteAllText($checkpoint, 'already-transferred-bytes', [Text.Encoding]::ASCII)
    $resume = Invoke-TestApi 'POST' "/api/jobs/$queuedId/resume"
    $resumeAgain = Invoke-TestApi 'POST' "/api/jobs/$queuedId/resume"
    Assert-ServerTest ($resume.Code -eq 202 -and $resumeAgain.Code -eq 202 -and $resume.Json.job.id -eq $queuedId -and $resumeAgain.Json.job.id -eq $queuedId) 'resume reuses the same job and duplicate resume succeeds'
    Assert-ServerTest ((Read-TestJob $queuedId).attempt -eq 1 -and [IO.File]::ReadAllText($checkpoint) -eq 'already-transferred-bytes') 'resume preserves attempt and checkpoint data'
    [void](Invoke-TestApi 'POST' "/api/jobs/$queuedId/pause")

    $retry = Invoke-TestApi 'POST' "/api/history/failed/$($partialRecord.id)/retry"
    if ($retry.Code -ne 202) { Write-Host ('Retry response: ' + ($retry | ConvertTo-Json -Depth 6 -Compress)) }
    Assert-ServerTest ($retry.Code -eq 202 -and $retry.Json.job.id -eq $partialId -and $retry.Json.job.attempt -eq 2) 'failure history retry preserves original job and increments attempt'
    $retriedConfig = Read-LingoJson -Path (Join-Path $jobsRoot "$partialId.config.json") -ThrowOnError
    Assert-ServerTest ($retriedConfig.retryUrls -is [array] -and @($retriedConfig.retryUrls).Count -eq 1 -and $retriedConfig.retryUrls[0] -eq $partialUrl -and $retriedConfig.attemptTargets -is [array] -and @($retriedConfig.attemptTargets).Count -eq 1 -and $retriedConfig.attemptTargets[0] -eq $partialUrl) 'playlist retry targets only the failed video in retryUrls and attemptTargets'
    Assert-ServerTest ($retriedConfig.attempt -eq 2 -and $retriedConfig.quality -eq '720p' -and $retriedConfig.container -eq 'mp4' -and $retriedConfig.subtitleFormat -eq 'srt' -and @($retriedConfig.audioLanguages).Count -eq 2 -and $retriedConfig.sourceSelections.PSObject.Properties[$partialUrl].Value.audioFormatIds[0] -eq '251') 'retry retains format, languages and exact track selections'
    Assert-ServerTest ([IO.File]::Exists($completePath)) 'retry does not remove completed output'
    [void](Invoke-TestApi 'POST' "/api/jobs/$partialId/pause")
    $pauseRunning = Invoke-TestApi 'POST' "/api/jobs/$blockerId/pause"
    Assert-ServerTest ($pauseRunning.Code -eq 202 -and $pauseRunning.Json.job.status -in @('pausing', 'paused')) 'running pause acknowledges safe checkpoint request'
    $pausedRunning = Wait-TestJob $blockerId @('paused')
    Assert-ServerTest ($pausedRunning.status -eq 'paused') 'running downloader stops and reaches paused'

    $recentUrls = @(1..12 | ForEach-Object { "https://www.youtube.com/watch?v=recent$_" })
    $remembered = Invoke-TestApi 'POST' '/api/history/recent' @{ urls = $recentUrls }
    Assert-ServerTest ($remembered.Code -eq 200 -and @($remembered.Json.recentLinks).Count -eq 10 -and $remembered.Json.recentLinks[0].url -eq $recentUrls[11]) 'recent links retain newest ten individual URLs'
    $remembered = Invoke-TestApi 'POST' '/api/history/recent' @{ urls = @($recentUrls[4], $recentUrls[4]) }
    Assert-ServerTest (@($remembered.Json.recentLinks).Count -eq 10 -and $remembered.Json.recentLinks[0].url -eq $recentUrls[4] -and @($remembered.Json.recentLinks | Where-Object { $_.url -eq $recentUrls[4] }).Count -eq 1) 'duplicate input moves existing URL to front without duplication'
    Stop-TestService
    Start-TestService
    $jobs = (Invoke-TestApi 'GET' '/api/jobs').Json.jobs
    Assert-ServerTest (@($jobs | Where-Object { $_.id -eq $queuedId })[0].status -eq 'paused' -and @($jobs | Where-Object { $_.id -eq $blockerId })[0].status -eq 'paused' -and [IO.File]::Exists($checkpoint)) 'restart preserves manual pause and checkpoint data'
    $history = Invoke-TestApi 'GET' '/api/history'
    Assert-ServerTest (@($history.Json.recentLinks).Count -eq 10 -and $history.Json.recentLinks[0].url -eq $recentUrls[4]) 'recent history survives service restart'
    $savedFolder = Invoke-TestApi 'GET' '/api/settings'
    Assert-ServerTest ($savedFolder.Json.defaultDownloadPath -eq $mediaRoot -and $savedFolder.Json.maxConcurrentDownloads -eq 1) 'last used download folder survives service restart'
    $persistedParts = $savedFolder.Json.defaultDownloadParts
    Assert-ServerTest ($persistedParts.audio -and -not $persistedParts.video -and -not $persistedParts.subtitles) 'defaults survive folder and concurrency updates and service restart'
    $clearRecent = Invoke-TestApi 'DELETE' '/api/history/recent'
    Assert-ServerTest ($clearRecent.Code -eq 200 -and @($clearRecent.Json.recentLinks).Count -eq 0) 'recent history clear supports DELETE and returns an empty list'
    $deleted = Invoke-TestApi 'POST' '/api/history/failed/delete' @{ id = $partialRecord.id }
    Assert-ServerTest ($deleted.Code -eq 200 -and @($deleted.Json.failedLinks | Where-Object { $_.id -eq $partialRecord.id }).Count -eq 0 -and [IO.File]::Exists($completePath)) 'deleting failure history leaves completed files intact'
    [void](Invoke-TestApi 'POST' '/api/history/failed/clear')
    Stop-TestService
    Start-TestService
    $history = Invoke-TestApi 'GET' '/api/history'
    Assert-ServerTest (@($history.Json.recentLinks).Count -eq 0 -and @($history.Json.failedLinks).Count -eq 0 -and [IO.File]::Exists($completePath)) 'cleared histories remain empty after restart and outputs remain intact'
    Stop-TestService

    # Extract only the pure target resolver. Do not invoke Explorer or the route.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'server.ps1'), [ref]$tokens, [ref]$errors)
    $resolver = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-RevealTarget' }, $true)
    Invoke-Expression $resolver.Extent.Text
    function Read-Status { param([string]$Path); Read-LingoJson -Path $Path }
    $script:JobsRoot = $jobsRoot
    $revealId = [guid]::NewGuid().ToString('N')
    $revealDirectory = Join-Path $mediaRoot '中文 文件夹'
    [void][IO.Directory]::CreateDirectory($revealDirectory)
    $revealPath = Join-Path $revealDirectory '中文 空格 视频.mp4'
    [IO.File]::WriteAllText($revealPath, 'fixture', [Text.Encoding]::ASCII)
    Write-TestJson (Join-Path $jobsRoot "$revealId.status.json") @{ id = $revealId; status = 'completed'; items = @(@{ status = 'completed'; assets = @(@{ type = 'video'; status = 'completed'; path = $revealPath }) }) }
    $target = Get-RevealTarget -JobId $revealId -Path $revealPath
    Assert-ServerTest ($target.file -eq $revealPath -and $target.directory -eq $revealDirectory -and -not $target.missing) 'folder target preserves Chinese and spaces and selects existing video'
    $rejected = $false
    try { [void](Get-RevealTarget -JobId $revealId -Path $completePath) } catch { $rejected = $true }
    Assert-ServerTest $rejected 'folder target rejects a completed file belonging to another job'
    [IO.File]::Delete($revealPath)
    $target = Get-RevealTarget -JobId $revealId -Path $revealPath
    Assert-ServerTest ($null -eq $target.file -and $target.directory -eq $revealDirectory -and $target.missing) 'missing video falls back to its original folder'
    [IO.Directory]::Delete($revealDirectory)
    $rejected = $false
    try { [void](Get-RevealTarget -JobId $revealId -Path $revealPath) } catch { $rejected = $true }
    Assert-ServerTest $rejected 'missing original folder produces an explicit failure'
    Write-Host "PASS: $script:assertions server improvement assertions; no external network or Explorer launch."
} finally {
    try { Stop-TestService } catch { Write-Warning $_.Exception.Message }
    $env:LINGOSAVE_DATA_DIR = $oldData
    $env:LINGOSAVE_YTDLP_PATH = $oldExtractor
    $fullTest = [IO.Path]::GetFullPath($testRoot)
    $fullTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($fullTest.StartsWith($fullTemp, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($fullTest).StartsWith('lingosave-server-improvements-')) {
        if (-not $script:service) { Remove-Item -LiteralPath $fullTest -Recurse -Force -ErrorAction SilentlyContinue }
    } else { throw "Unsafe cleanup target: $fullTest" }
}

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $env:TEMP ('lingosave-parallel-queue-' + [guid]::NewGuid().ToString('N'))
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
    if ($script:requestOrigin) { $request.Headers['Origin'] = $script:requestOrigin }
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
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'server.ps1'), [ref]$tokens, [ref]$errors)
    Assert-ServerTest ($errors.Count -eq 0) 'server script has valid PowerShell syntax'
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe "/out:$fakePath" (Join-Path $PSScriptRoot 'FakePreviewExtractor.cs')
    if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($fakePath)) { throw 'Cannot build isolated extractor.' }
    $env:LINGOSAVE_DATA_DIR = $dataRoot
    $env:LINGOSAVE_YTDLP_PATH = $fakePath

    $doneId = [guid]::NewGuid().ToString('N')
    $failedId = [guid]::NewGuid().ToString('N')
    $failedUrl = 'https://www.youtube.com/watch?v=hang-failed-history'
    $donePath = Join-Path $mediaRoot 'Do not delete this video.mp4'
    $partPath = Join-Path $mediaRoot 'Do not delete this partial.part'
    [IO.File]::WriteAllText($donePath, 'completed-media-original', [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($partPath, 'partial-media-original', [Text.Encoding]::ASCII)
    $done = @{ id = $doneId; status = 'completed'; attempt = 1; createdAt = '2026-01-01 00:00:01'; urls = @('https://www.youtube.com/watch?v=complete'); path = $mediaRoot; completed = 1; failed = 0; items = @(@{ title = 'Completed fixture'; status = 'completed'; url = 'https://www.youtube.com/watch?v=complete'; path = $donePath; assets = @() }) }
    $failed = @{ id = $failedId; status = 'failed'; attempt = 1; createdAt = '2026-01-01 00:00:02'; urls = @($failedUrl); path = $mediaRoot; completed = 0; failed = 1; error = 'Fixture download failed'; items = @(@{ title = 'Failed fixture'; status = 'failed'; url = $failedUrl; error = 'Fixture download failed'; assets = @() }) }
    foreach ($seed in @($done,$failed)) {
        foreach ($field in @('speedBytesPerSecond', 'etaSeconds', 'progress', 'downloadedBytes', 'totalBytes', 'currentTitle', 'currentAsset')) { $seed[$field] = $null }
        Write-TestJson (Join-Path $jobsRoot "$($seed.id).status.json") $seed
        Write-TestJson (Join-Path $jobsRoot "$($seed.id).config.json") (New-TestConfig $seed.id $seed.urls)
    }
    Start-TestService
    $settings = Invoke-TestApi 'GET' '/api/settings'
    Assert-ServerTest ($settings.Json.maxConcurrentDownloads -eq 3) 'new installation defaults to three simultaneous downloads'
    foreach ($value in @(0,6,2.5,'3',$null)) {
        $invalid = Invoke-TestApi 'POST' '/api/settings' @{ maxConcurrentDownloads = $value }
        Assert-ServerTest ($invalid.Code -eq 400) "invalid parallel limit '$value' is rejected"
    }
    $jobs = @(foreach ($index in 1..4) {
        $r = Invoke-TestApi 'POST' '/api/jobs' @{ urls = @("https://www.youtube.com/watch?v=hang-parallel-$index"); mode = 'video'; quality = 'best'; container = 'mkv'; subtitleLanguages = @(); path = $mediaRoot }
        Assert-ServerTest ($r.Code -eq 202) "parallel task $index is accepted"
        [string]$r.Json.job.id
    })
    foreach ($id in $jobs[0..2]) { [void](Wait-TestJob $id @('running')) }
    $all = (Invoke-TestApi 'GET' '/api/jobs').Json.jobs
    Assert-ServerTest (@($all | Where-Object { $_.id -in $jobs -and $_.status -eq 'running' }).Count -eq 3 -and @($all | Where-Object { $_.id -eq $jobs[3] })[0].status -eq 'queued') 'three real worker processes run concurrently and the fourth stays queued'
    $workerRecords = @($jobs[0..2] | ForEach-Object { Read-LingoJson (Join-Path $jobsRoot "$_.worker.pid.json") -ThrowOnError })
    Assert-ServerTest (@($workerRecords.pid | Select-Object -Unique).Count -eq 3 -and @($workerRecords | Where-Object { Get-Process -Id $_.pid -ErrorAction SilentlyContinue }).Count -eq 3) 'concurrent tasks have three distinct live process identities'
    $tray = Invoke-TestApi 'GET' '/api/tray'
    Assert-ServerTest ($tray.Code -eq 200 -and $tray.Json.activeCount -eq 3 -and $tray.Json.queuedCount -eq 1 -and @($tray.Json.jobs).Count -eq 4) 'tray summary reports current tasks and active versus queued counts'
    Assert-ServerTest (@($tray.Json.jobs | Where-Object { $_.PSObject.Properties['items'] -or $_.PSObject.Properties['urls'] }).Count -eq 0) 'tray summary omits playlist item arrays and URL arrays'
    $deleteRunning = Invoke-TestApi 'DELETE' "/api/jobs/$($jobs[0])"
    Assert-ServerTest ($deleteRunning.Code -eq 400 -and (Read-TestJob $jobs[0]).status -eq 'running') 'active task cannot be deleted without cancellation'
    $duplicate = Invoke-TestApi 'POST' "/api/jobs/$($jobs[0])/resume"
    $afterDuplicate = Read-LingoJson (Join-Path $jobsRoot "$($jobs[0]).worker.pid.json") -ThrowOnError
    Assert-ServerTest ($duplicate.Code -eq 202 -and $afterDuplicate.pid -eq $workerRecords[0].pid) 'repeat resume cannot start a second process for the same task'
    $limit = Invoke-TestApi 'POST' '/api/settings' @{ maxConcurrentDownloads = 2 }
    Assert-ServerTest ($limit.Code -eq 200 -and $limit.Json.maxConcurrentDownloads -eq 2 -and $limit.Json.defaultDownloadPath -eq $settings.Json.defaultDownloadPath) 'parallel limit changes independently of download directory'
    [void](Invoke-TestApi 'POST' "/api/jobs/$($jobs[0])/pause")
    [void](Wait-TestJob $jobs[0] @('paused'))
    $deletePaused = Invoke-TestApi 'DELETE' "/api/jobs/$($jobs[0])"
    Assert-ServerTest ($deletePaused.Code -eq 400) 'paused task retains its state until explicitly cancelled'
    $siblings = @((Invoke-TestApi 'GET' '/api/jobs').Json.jobs | Where-Object { $_.id -in $jobs[1..2] -and $_.status -eq 'running' })
    Assert-ServerTest ($siblings.Count -eq 2 -and (Read-TestJob $jobs[3]).status -eq 'queued') 'pausing one task leaves both siblings running under the lowered limit'
    [void](Invoke-TestApi 'POST' "/api/jobs/$($jobs[1])/cancel")
    [void](Wait-TestJob $jobs[3] @('running'))
    Assert-ServerTest ((Read-TestJob $jobs[2]).status -eq 'running' -and (Read-TestJob $jobs[1]).status -eq 'cancelled') 'cancelling one task frees its slot without stopping another task'
    $deleted = Invoke-TestApi 'DELETE' "/api/jobs/$doneId"
    Assert-ServerTest ($deleted.Code -eq 200 -and $deleted.Json.removedCount -eq 1 -and $deleted.Json.removedIds[0] -eq $doneId -and -not [IO.File]::Exists((Join-Path $jobsRoot "$doneId.status.json"))) 'single completed task record is removed'
    Assert-ServerTest ([IO.File]::ReadAllText($donePath) -eq 'completed-media-original' -and [IO.File]::ReadAllText($partPath) -eq 'partial-media-original') 'record deletion preserves completed media and partial transfer bytes'
    $script:requestOrigin = 'https://example.invalid'
    $blockedClear = Invoke-TestApi 'POST' '/api/jobs/clear'
    $blockedDelete = Invoke-TestApi 'DELETE' "/api/jobs/$failedId"
    $script:requestOrigin = $null
    Assert-ServerTest ($blockedClear.Code -eq 403 -and $blockedDelete.Code -eq 403) 'cross origin record deletions are rejected'
    $history = (Invoke-TestApi 'GET' '/api/history').Json
    $failureRecord = @($history.failedLinks | Where-Object { $_.url -eq $failedUrl })[0]
    Assert-ServerTest ($null -ne $failureRecord -and @($history.recentLinks).Count -eq 4) 'failure and recent input histories exist independently of task records'
    $cleared = Invoke-TestApi 'POST' '/api/jobs/clear'
    Assert-ServerTest ($cleared.Code -eq 200 -and $cleared.Json.removedCount -eq 2 -and @($cleared.Json.retainedActive).Count -eq 3 -and @($cleared.Json.jobs).Count -eq 3) 'clear removes terminal records while retaining running and paused tasks'
    $historyAfter = (Invoke-TestApi 'GET' '/api/history').Json
    Assert-ServerTest (@($historyAfter.failedLinks).Count -eq @($history.failedLinks).Count -and @($historyAfter.recentLinks).Count -eq 4 -and [IO.File]::Exists((Join-Path (Join-Path $dataRoot 'history-job-snapshots') "$failedId.json"))) 'cleared failure task retains its retry snapshot and both histories'
    Stop-TestService
    Start-TestService
    foreach ($id in $jobs[2..3]) { [void](Wait-TestJob $id @('running')) }
    $settingsAfter = (Invoke-TestApi 'GET' '/api/settings').Json
    $restored = (Invoke-TestApi 'GET' '/api/jobs').Json.jobs
    Assert-ServerTest ($settingsAfter.maxConcurrentDownloads -eq 2 -and @($restored | Where-Object { $_.status -eq 'running' }).Count -eq 2 -and (Read-TestJob $jobs[0]).status -eq 'paused') 'restart restores independent active tasks, preserves pause, and persists concurrency setting'
    Assert-ServerTest (@($restored | Where-Object { $_.id -in @($failedId,$doneId,$jobs[1]) }).Count -eq 0) 'cleared records never reappear merely because the service restarted'
    $retry = Invoke-TestApi 'POST' "/api/history/failed/$($failureRecord.id)/retry"
    Assert-ServerTest ($retry.Code -eq 202 -and $retry.Json.job.id -eq $failedId -and $retry.Json.job.attempt -eq 2 -and [IO.File]::Exists((Join-Path $jobsRoot "$failedId.config.json"))) 'failure history retry restores a cleared task only on explicit retry'
    $raise = Invoke-TestApi 'POST' '/api/settings' @{ maxConcurrentDownloads = 5 }
    [void](Wait-TestJob $failedId @('running'))
    Assert-ServerTest ($raise.Code -eq 200 -and (Invoke-TestApi 'GET' '/api/tray').Json.activeCount -eq 3) 'increasing concurrency starts a waiting task alongside existing downloads'
    foreach ($id in @($jobs[0],$jobs[2],$jobs[3],$failedId)) { [void](Invoke-TestApi 'POST' "/api/jobs/$id/cancel") }
    $final = Invoke-TestApi 'POST' '/api/jobs/clear'
    Assert-ServerTest ($final.Code -eq 200 -and $final.Json.remainingCount -eq 0 -and @($final.Json.jobs).Count -eq 0 -and @($final.Json.retainedActive).Count -eq 0) 'all task records can be cleared after cancellation'
    Assert-ServerTest ([IO.File]::ReadAllText($donePath) -eq 'completed-media-original' -and [IO.File]::ReadAllText($partPath) -eq 'partial-media-original') 'clear all preserves both final and partial downloaded files'
    Stop-TestService
    Write-Host "PASS: $script:assertions parallel queue and deletion assertions; isolated metadata and no external network."
} finally {
    try { Stop-TestService } catch { Write-Warning $_.Exception.Message }
    $env:LINGOSAVE_DATA_DIR = $oldData
    $env:LINGOSAVE_YTDLP_PATH = $oldExtractor
    $fullTest = [IO.Path]::GetFullPath($testRoot)
    $fullTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($fullTest.StartsWith($fullTemp, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($fullTest).StartsWith('lingosave-parallel-queue-')) {
        if (-not $script:service) { Remove-Item -LiteralPath $fullTest -Recurse -Force -ErrorAction SilentlyContinue }
    } else { throw "Unsafe cleanup target: $fullTest" }
}

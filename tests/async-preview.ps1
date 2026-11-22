param([switch]$VerifyTimeout)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not [IO.File]::Exists($compiler)) { throw 'C# test compiler is unavailable.' }
$testRoot = Join-Path $env:TEMP ('lingosave-async-preview-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$dataRoot = Join-Path $testRoot 'data'
$fakePath = Join-Path $testRoot 'fake-yt-dlp.exe'
$oldData = $env:LINGOSAVE_DATA_DIR
$oldYt = $env:LINGOSAVE_YTDLP_PATH
$service = $null

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}

function Invoke-LocalApi {
    param([string]$Method, [string]$Path, [string]$Body = $null, [int]$Timeout = 3000)
    $request = [Net.HttpWebRequest][Net.WebRequest]::Create("http://127.0.0.1:$port$Path")
    $request.Method = $Method
    $request.Timeout = $Timeout
    $request.ReadWriteTimeout = $Timeout
    $request.Proxy = $null
    if ($Method -eq 'POST') {
        $request.ContentType = 'application/json'
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    try { $response = [Net.HttpWebResponse]$request.GetResponse() }
    catch [Net.WebException] {
        if (-not $_.Exception.Response) { throw }
        $response = [Net.HttpWebResponse]$_.Exception.Response
    }
    try {
        $reader = [IO.StreamReader]::new($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $bodyText = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return [pscustomobject]@{ Code = [int]$response.StatusCode; Json = ($bodyText | ConvertFrom-Json) }
    } finally { $response.Dispose() }
}

try {
    & $compiler /nologo /target:exe "/out:$fakePath" (Join-Path $PSScriptRoot 'FakePreviewExtractor.cs')
    if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($fakePath)) { throw 'Cannot build fake extractor.' }
    $env:LINGOSAVE_DATA_DIR = $dataRoot
    $env:LINGOSAVE_YTDLP_PATH = $fakePath
    [void][IO.Directory]::CreateDirectory($dataRoot)

    . (Join-Path $root 'credential-store.ps1')
    $cookieSource = Join-Path $testRoot 'cookies.txt'
    [IO.File]::WriteAllText($cookieSource, "# Netscape HTTP Cookie File`n.youtube.com`tTRUE`t/`tTRUE`t0`tsession`tfake`n", [Text.UTF8Encoding]::new($false))
    $cookieImported = $false
    try {
        [void](Import-LingoCookieFile -Site 'youtube' -SourcePath $cookieSource -StoreRoot $dataRoot)
        $cookieImported = $true
    } catch [System.Security.Cryptography.CryptographicException] {
        Write-Warning 'DPAPI is unavailable in this execution context; shutdown cleanup will use a synthetic temporary Cookie marker.'
    } catch {
        if ($_.Exception.Message -notmatch 'data protection operation') { throw }
        Write-Warning 'DPAPI is unavailable in this execution context; shutdown cleanup will use a synthetic temporary Cookie marker.'
    }

    $reserve = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $reserve.Start()
    $port = ([Net.IPEndPoint]$reserve.LocalEndpoint).Port
    $reserve.Stop()
    $serviceScript = Join-Path $root 'server.ps1'
    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    $service = Start-Process -FilePath $powershellExe -ArgumentList @('-NoProfile', '-NonInteractive', '-Sta', '-ExecutionPolicy', 'Bypass', '-File', "`"$serviceScript`"", '-Port', "$port") -PassThru -WindowStyle Hidden
    $ready = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            $health = Invoke-LocalApi -Method 'GET' -Path '/api/health' -Timeout 1000
            if ($health.Code -eq 200 -and $health.Json.ready) { $ready = $true; break }
        } catch { Start-Sleep -Milliseconds 150 }
    }
    Assert-Test $ready 'service starts with fake extractor'

    $playlist = Invoke-LocalApi -Method 'POST' -Path '/api/preview' -Body '{"urls":["https://www.youtube.com/playlist?list=fixture"]}'
    Assert-Test ($playlist.Code -eq 202 -and $playlist.Json.previewId -match '^[0-9a-f]{32}$') 'preview creation is asynchronous'
    $playlistStatus = $null
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $playlistStatus = Invoke-LocalApi -Method 'GET' -Path "/api/preview/$($playlist.Json.previewId)"
        if ($playlistStatus.Json.status -in @('completed', 'failed')) { break }
        Start-Sleep -Milliseconds 150
    }
    Assert-Test ($playlistStatus.Json.status -eq 'completed' -and $playlistStatus.Json.result.totalVideos -eq 25 -and @($playlistStatus.Json.result.items[0].entries).Count -eq 20) 'playlist preview shows 20 items and full count'

    $hung = Invoke-LocalApi -Method 'POST' -Path '/api/preview' -Body '{"urls":["https://www.youtube.com/watch?v=hang"]}'
    Assert-Test ($hung.Code -eq 202) 'hung preview accepted promptly'
    $hungId = [string]$hung.Json.previewId
    $running = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $state = Invoke-LocalApi -Method 'GET' -Path "/api/preview/$hungId"
        if ($state.Json.status -eq 'running' -and [IO.File]::Exists((Join-Path $dataRoot "previews\$hungId.extractor.pid.json"))) { $running = $true; break }
        Start-Sleep -Milliseconds 150
    }
    Assert-Test $running 'preview is running in a separate extractor process'
    if ($cookieImported) {
        Assert-Test ([IO.File]::Exists((Join-Path $dataRoot "previews\$hungId.cookie-temp.json"))) 'preview uses a temporary Cookie'
    } else {
        $cookieTempRoot = Join-Path $dataRoot 'credentials\tmp'
        [void][IO.Directory]::CreateDirectory($cookieTempRoot)
        $syntheticCookie = Join-Path $cookieTempRoot ('lingosave-cookie-youtube-' + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($syntheticCookie, '# synthetic cleanup fixture', [Text.Encoding]::ASCII)
        $marker = Join-Path $dataRoot "previews\$hungId.cookie-temp.json"
        [IO.File]::WriteAllText($marker, (ConvertTo-Json -InputObject @{ path = $syntheticCookie } -Compress), [Text.Encoding]::UTF8)
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $healthWhileHung = Invoke-LocalApi -Method 'GET' -Path '/api/health'
    $jobsWhileHung = Invoke-LocalApi -Method 'GET' -Path '/api/jobs'
    $timer.Stop()
    Assert-Test ($healthWhileHung.Code -eq 200 -and $jobsWhileHung.Code -eq 200 -and $timer.ElapsedMilliseconds -lt 3000) 'health and jobs respond while extractor hangs'

    $mediaRoot = Join-Path $testRoot 'media'
    [void][IO.Directory]::CreateDirectory($mediaRoot)
    $jobBody = @{ urls = @('https://www.youtube.com/watch?v=hang'); mode = 'video'; quality = 'best'; container = 'mkv'; path = $mediaRoot; subtitleLanguages = @() } | ConvertTo-Json -Compress
    $job = Invoke-LocalApi -Method 'POST' -Path '/api/jobs' -Body $jobBody
    Assert-Test ($job.Code -eq 202) 'job can be queued during preview'
    $timer.Restart()
    $cancel = Invoke-LocalApi -Method 'POST' -Path "/api/jobs/$($job.Json.job.id)/cancel" -Body '{}'
    $timer.Stop()
    Assert-Test ($cancel.Code -eq 200 -and $cancel.Json.job.status -eq 'cancelled' -and $timer.ElapsedMilliseconds -lt 3000) 'job cancellation responds during preview'

    if ($VerifyTimeout) {
        $timedOut = $false
        for ($attempt = 0; $attempt -lt 80; $attempt++) {
            $state = Invoke-LocalApi -Method 'GET' -Path "/api/preview/$hungId"
            if ($state.Json.status -eq 'completed') {
                $timedOut = $state.Json.result.items[0].error -match '30'
                break
            }
            Start-Sleep -Milliseconds 500
        }
        Assert-Test $timedOut 'per-link preview timeout completes with an item error'
        if (-not $cookieImported -and [IO.File]::Exists($syntheticCookie)) {
            [IO.File]::Delete($syntheticCookie)
        }
        $hungAgain = Invoke-LocalApi -Method 'POST' -Path '/api/preview' -Body '{"urls":["https://www.youtube.com/watch?v=hang"]}'
        $hungId = [string]$hungAgain.Json.previewId
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            if ([IO.File]::Exists((Join-Path $dataRoot "previews\$hungId.extractor.pid.json"))) { break }
            Start-Sleep -Milliseconds 150
        }
        Assert-Test ([IO.File]::Exists((Join-Path $dataRoot "previews\$hungId.extractor.pid.json"))) 'second preview is active before shutdown'
        if (-not $cookieImported) {
            $syntheticCookie = Join-Path $cookieTempRoot ('lingosave-cookie-youtube-' + [guid]::NewGuid().ToString('N') + '.txt')
            [IO.File]::WriteAllText($syntheticCookie, '# synthetic cleanup fixture', [Text.Encoding]::ASCII)
            $marker = Join-Path $dataRoot "previews\$hungId.cookie-temp.json"
            [IO.File]::WriteAllText($marker, (ConvertTo-Json -InputObject @{ path = $syntheticCookie } -Compress), [Text.Encoding]::UTF8)
        }
    }

    $previewWorkerRecord = Get-Content -LiteralPath (Join-Path $dataRoot "previews\$hungId.worker.pid.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $extractorRecord = Get-Content -LiteralPath (Join-Path $dataRoot "previews\$hungId.extractor.pid.json") -Raw -Encoding UTF8 | ConvertFrom-Json

    [IO.File]::WriteAllText((Join-Path $dataRoot 'shutdown.request'), '', [Text.Encoding]::ASCII)
    Assert-Test ($service.WaitForExit(20000)) 'service exits cleanly'
    $service.Refresh()
    $previewWorker = Join-Path $dataRoot "previews\$hungId.worker.pid.json"
    $extractor = Join-Path $dataRoot "previews\$hungId.extractor.pid.json"
    $cookieMarker = Join-Path $dataRoot "previews\$hungId.cookie-temp.json"
    $cookieTempRoot = Join-Path $dataRoot 'credentials\tmp'
    $tempCookies = if ([IO.Directory]::Exists($cookieTempRoot)) { @(Get-ChildItem -LiteralPath $cookieTempRoot -Filter 'lingosave-cookie-*.txt' -File) } else { @() }
    Assert-Test (-not [IO.File]::Exists($previewWorker) -and -not [IO.File]::Exists($extractor) -and -not [IO.File]::Exists($cookieMarker) -and $tempCookies.Count -eq 0) 'shutdown removes preview processes and temporary Cookie'
    foreach ($record in @($previewWorkerRecord, $extractorRecord)) {
        $stillRunning = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
        if ($stillRunning -and $stillRunning.StartTime.Ticks -eq [long]$record.startedAtTicks) { throw "Orphaned preview process: $($record.pid)" }
    }
    Write-Host 'PASS: shutdown leaves no preview worker or extractor process'
} finally {
    if ($service) {
        try {
            $service.Refresh()
            if (-not $service.HasExited) {
                if ([IO.Directory]::Exists($dataRoot)) { [IO.File]::WriteAllText((Join-Path $dataRoot 'shutdown.request'), '', [Text.Encoding]::ASCII) }
                if (-not $service.WaitForExit(5000)) { $service.Kill(); [void]$service.WaitForExit(5000) }
            }
        } catch { }
        $service.Dispose()
    }
    $env:LINGOSAVE_DATA_DIR = $oldData
    $env:LINGOSAVE_YTDLP_PATH = $oldYt
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

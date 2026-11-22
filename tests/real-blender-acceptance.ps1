param([switch]$KeepFiles)

# Blender's Glass Half is published under CC BY 3.0:
# https://studio.blender.org/projects/glass-half/pages/licensing/
$ErrorActionPreference = 'Stop'
$url = 'https://www.youtube.com/watch?v=lqiN98z6Dak'
$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $PSScriptRoot ('real-blender-' + [guid]::NewGuid().ToString('N'))
$dataRoot = Join-Path $testRoot 'data'
$mediaRoot = Join-Path $testRoot 'media'
$oldDataRoot = $env:LINGOSAVE_DATA_DIR
$service = $null
$success = $false

function Invoke-LingoApi {
    param([string]$Method, [string]$Path, $Body = $null)
    $request = [Net.HttpWebRequest][Net.WebRequest]::Create("http://127.0.0.1:$port$Path")
    $request.Method = $Method
    $request.Proxy = $null
    $request.Timeout = 10000
    $request.ReadWriteTimeout = 10000
    if ($Method -eq 'POST') {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 12 -Compress))
        $request.ContentType = 'application/json; charset=utf-8'
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
        try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return [pscustomobject]@{ Code = [int]$response.StatusCode; Json = $(if ($content) { ConvertFrom-Json -InputObject $content } else { $null }) }
    } finally { $response.Dispose() }
}

function Wait-Inspection {
    param([string]$SourceUrl)
    $created = Invoke-LingoApi -Method 'POST' -Path '/api/inspect' -Body @{ url = $SourceUrl }
    if ($created.Code -ne 202 -or -not $created.Json.inspectionId) { throw 'Inspection did not start asynchronously.' }
    for ($attempt = 0; $attempt -lt 240; $attempt++) {
        $state = Invoke-LingoApi -Method 'GET' -Path "/api/inspect/$($created.Json.inspectionId)"
        if ($state.Json.status -eq 'completed') { return $state.Json.result }
        if ($state.Json.status -eq 'failed') { throw "Inspection failed: $($state.Json.error)" }
        Start-Sleep -Milliseconds 500
    }
    throw 'Inspection timed out.'
}

try {
    [void][IO.Directory]::CreateDirectory($mediaRoot)
    $env:LINGOSAVE_DATA_DIR = $dataRoot
    $reserve = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $reserve.Start()
    $port = ([Net.IPEndPoint]$reserve.LocalEndpoint).Port
    $reserve.Stop()
    $psExe = Join-Path $PSHOME 'powershell.exe'
    $script = Join-Path $root 'run.ps1'
    $service = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', "`"$script`"", '-Port', "$port") -PassThru -WindowStyle Hidden
    $ready = $false
    for ($attempt = 0; $attempt -lt 80; $attempt++) {
        try {
            $health = Invoke-LingoApi -Method 'GET' -Path '/api/health'
            if ($health.Code -eq 200 -and $health.Json.ready) { $ready = $true; break }
        } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $ready) { throw 'LingoSave service was not ready.' }
    Write-Output "Service ready on port $port"

    $inspection = Wait-Inspection -SourceUrl $url
    $audio = @($inspection.audioTracks | Where-Object { $_.audioOnly -and $_.formatId -and $_.language -like 'en*' } | Sort-Object bitrate -Descending | Select-Object -First 1)[0]
    $subtitle = @($inspection.subtitles | Where-Object { $_.source -eq 'auto' -and $_.rawKey -eq 'en' } | Select-Object -First 1)[0]
    if (-not $audio -or -not $subtitle -or -not $inspection.id) { throw 'Required audio or automatic English subtitle was not found.' }
    Write-Output "Inspected media ID $($inspection.id); audio $($audio.formatId); subtitle $($subtitle.id)"

    $selected = @{
        mediaId = [string]$inspection.id
        audioFormatIds = @([string]$audio.formatId)
        subtitleTracks = @(@{ rawKey = [string]$subtitle.rawKey; source = 'auto' })
        explicitAudio = $true
        explicitSubtitles = $true
    }
    $selections = @{}
    $selections[$url] = $selected
    $payload = @{
        urls = @($url)
        path = $mediaRoot
        parts = @{ video = $true; audio = $true; subtitles = $true }
        autoSimplify = $true
        quality = '720p'
        container = 'mkv'
        subtitleFormat = 'vtt'
        audioLanguages = @('en')
        subtitleLanguages = @('en')
        sourceSelections = $selections
    }
    $createdJob = Invoke-LingoApi -Method 'POST' -Path '/api/jobs' -Body $payload
    if ($createdJob.Code -ne 202 -or -not $createdJob.Json.job.id) { throw "Job was not accepted: $($createdJob.Json.error)" }
    $jobId = [string]$createdJob.Json.job.id
    $seenSpeed = $false
    $seenProgress = $false
    $lastJob = $null
    for ($attempt = 0; $attempt -lt 1200; $attempt++) {
        $jobs = Invoke-LingoApi -Method 'GET' -Path '/api/jobs'
        $lastJob = @($jobs.Json.jobs | Where-Object { $_.id -eq $jobId } | Select-Object -First 1)[0]
        if (-not $lastJob) { throw 'Created job disappeared.' }
        if ($lastJob.speedBytesPerSecond -ne $null -and [double]$lastJob.speedBytesPerSecond -gt 0) { $seenSpeed = $true }
        if ($lastJob.progress -ne $null -and [double]$lastJob.progress -gt 0) { $seenProgress = $true }
        if ($lastJob.status -in @('completed', 'partial', 'failed', 'cancelled')) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($lastJob.status -ne 'completed') {
        $itemErrors = @($lastJob.items | ForEach-Object { $_.error; $_.assets | ForEach-Object { $_.error } } | Where-Object { $_ }) -join ' | '
        throw "Job ended as $($lastJob.status): $($lastJob.error) $($lastJob.message) $itemErrors"
    }
    $assets = @($lastJob.items | ForEach-Object { $_.assets } | Where-Object { $_ })
    $types = @($assets | ForEach-Object { $_.type })
    foreach ($type in @('video', 'audio', 'subtitle')) {
        if ($types -notcontains $type) { throw "Missing $type asset in job status." }
    }
    foreach ($asset in $assets) {
        if ($asset.status -ne 'completed' -or -not $asset.path -or -not [IO.File]::Exists([string]$asset.path)) {
            throw "Incomplete asset: $($asset.type) $($asset.status) $($asset.path)"
        }
    }
    if (-not $seenSpeed -or -not $seenProgress) { throw "Transfer telemetry missing: speed=$seenSpeed progress=$seenProgress" }
    $success = $true
    Write-Output "PASS real video/audio/subtitle assets ($($assets.Count)); speed and progress observed."
} finally {
    if ($service) {
        try {
            if (-not $service.HasExited) {
                [IO.File]::WriteAllText((Join-Path $dataRoot 'shutdown.request'), '', [Text.Encoding]::ASCII)
                if (-not $service.WaitForExit(10000)) { $service.Kill(); [void]$service.WaitForExit(5000) }
            }
        } catch { }
        $service.Dispose()
    }
    $env:LINGOSAVE_DATA_DIR = $oldDataRoot
    $workspace = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (($success -or -not $KeepFiles) -and $resolved.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } elseif ([IO.Directory]::Exists($resolved)) { Write-Warning "Kept acceptance data at $resolved" }
}

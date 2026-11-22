$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $env:TEMP ('lingosave-arte-selection-api-' + [guid]::NewGuid().ToString('N'))
$dataRoot = Join-Path $testRoot 'data'
$jobsRoot = Join-Path $dataRoot 'jobs'
$inspectionRoot = Join-Path $dataRoot 'inspections'
$mediaRoot = Join-Path $testRoot 'media'
$fakePath = Join-Path $testRoot 'fake-yt-dlp.exe'
$oldData = $env:LINGOSAVE_DATA_DIR
$oldExtractor = $env:LINGOSAVE_YTDLP_PATH
$script:service = $null
$script:assertions = 0
[void][IO.Directory]::CreateDirectory($jobsRoot)
[void][IO.Directory]::CreateDirectory($inspectionRoot)
[void][IO.Directory]::CreateDirectory($mediaRoot)
. (Join-Path $projectRoot 'state-io.ps1')

function Assert-ArteApi {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:assertions++
    Write-Host "PASS: $Message"
}

function Invoke-ArteApi {
    param([string]$Method, [string]$Path, $Body = $null)
    $request = [Net.HttpWebRequest][Net.WebRequest]::Create("http://127.0.0.1:$script:testPort$Path")
    $request.Method = $Method
    $request.Timeout = 5000
    $request.ReadWriteTimeout = 5000
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
    catch [Net.WebException] {
        if (-not $_.Exception.Response) { throw }
        $response = [Net.HttpWebResponse]$_.Exception.Response
    }
    try {
        $reader = [IO.StreamReader]::new($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return [pscustomobject]@{ Code = [int]$response.StatusCode; Json = ($content | ConvertFrom-Json) }
    } finally { $response.Dispose() }
}

function Start-ArteService {
    $reserve = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $reserve.Start()
    $script:testPort = ([Net.IPEndPoint]$reserve.LocalEndpoint).Port
    $reserve.Stop()
    if ($script:testPort -eq 8765) { throw 'Isolated test must not use the main service port.' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments = '-NoProfile -NonInteractive -Sta -ExecutionPolicy Bypass -File "' + (Join-Path $projectRoot 'server.ps1') + '" -Port ' + $script:testPort
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $script:service = [Diagnostics.Process]::Start($start)
    $ready = $false
    for ($attempt = 0; $attempt -lt 80; $attempt++) {
        if ($script:service.HasExited) { throw "Isolated service exited: $($script:service.StandardError.ReadToEnd())" }
        try { $health = Invoke-ArteApi 'GET' '/api/health'; if ($health.Code -eq 200 -and $health.Json.ready) { $ready = $true; break } } catch { }
        Start-Sleep -Milliseconds 150
    }
    Assert-ArteApi $ready 'isolated service is ready on a separate port and TEMP data directory'
}

function Stop-ArteService {
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

function New-ArteBody {
    param([object[]]$FormatIds)
    $selections = @{}
    $selections[$script:arteUrl] = @{
        mediaId = $script:mediaId
        audioFormatIds = @($FormatIds)
        subtitleTracks = @()
        explicitAudio = $true
        explicitSubtitles = $true
    }
    return @{
        urls = @($script:arteUrl); path = $mediaRoot
        parts = @{ video = $false; audio = $true; subtitles = $false }
        quality = 'best'; container = 'mkv'; audioLanguages = @('fr', 'de', 'mul')
        subtitleLanguages = @(); subtitleFormat = 'srt'; sourceSelections = $selections
    }
}

function Assert-AcceptedIds {
    param([string[]]$Ids, [string]$Label)
    $response = Invoke-ArteApi 'POST' '/api/jobs' (New-ArteBody $Ids)
    Assert-ArteApi ($response.Code -eq 202 -and $response.Json.job.id) "$Label is accepted through POST /api/jobs"
    $id = [string]$response.Json.job.id
    $cfg = Read-LingoJson (Join-Path $jobsRoot "$id.config.json") -ThrowOnError
    $stored = $cfg.sourceSelections.PSObject.Properties[$script:arteUrl].Value
    $same = @($stored.audioFormatIds).Count -eq $Ids.Count
    for ($i = 0; $i -lt $Ids.Count; $i++) {
        if ([string]$stored.audioFormatIds[$i] -cne $Ids[$i]) { $same = $false }
    }
    Assert-ArteApi ($same -and [string]$stored.mediaId -ceq $script:mediaId) "$Label persists exact source IDs without translating or stripping accents"
    [void](Invoke-ArteApi 'POST' "/api/jobs/$id/cancel")
}

function Assert-RejectedId {
    param([object]$Id, [string]$MessagePattern, [string]$Label)
    $response = Invoke-ArteApi 'POST' '/api/jobs' (New-ArteBody @($Id))
    Assert-ArteApi ($response.Code -eq 400 -and $response.Json.error -match $MessagePattern) "$Label is rejected before entering the download queue"
}

try {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe "/out:$fakePath" (Join-Path $PSScriptRoot 'FakePreviewExtractor.cs')
    if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($fakePath)) { throw 'Cannot build isolated fake extractor.' }
    $env:LINGOSAVE_DATA_DIR = $dataRoot
    $env:LINGOSAVE_YTDLP_PATH = $fakePath
    Start-ArteService
    $settings = Invoke-ArteApi 'POST' '/api/settings' @{ maxConcurrentDownloads = 1 }
    Assert-ArteApi ($settings.Code -eq 200) 'isolated queue has one download slot'
    $blocker = Invoke-ArteApi 'POST' '/api/jobs' @{
        urls = @('https://www.youtube.com/watch?v=hang-arte-api-blocker')
        path = $mediaRoot; mode = 'video'; quality = 'best'; container = 'mkv'; subtitleLanguages = @()
    }
    Assert-ArteApi ($blocker.Code -eq 202) 'fake blocker occupies the queue without external network traffic'
    $running = $false
    for ($i = 0; $i -lt 50; $i++) {
        $jobs = Invoke-ArteApi 'GET' '/api/jobs'
        $job = @($jobs.Json.jobs | Where-Object id -eq $blocker.Json.job.id)[0]
        if ($job.status -eq 'running') { $running = $true; break }
        Start-Sleep -Milliseconds 100
    }
    Assert-ArteApi $running 'accepted selection jobs remain queued behind the fake blocker'

    $script:arteUrl = 'https://www.arte.tv/fr/videos/115508-001-A/le-monde-des-croyances/'
    $script:mediaId = '115508-001-A'
    $ids = @(
        'VF-STF-audio_0-français'
        'VF-STF-audio_0-français__confort_audio_'
        'VF-STF-audio_0-allemand'
        'VF-STF-audio_0-allemand__confort_audio_'
        'VF-STF-audio_0-multilingue'
    )
    $olderPath = Join-Path $inspectionRoot '00000000000000000000000000000001.status.json'
    $newerPath = Join-Path $inspectionRoot 'ffffffffffffffffffffffffffffffff.status.json'
    $older = @{
        inspectionId = '00000000000000000000000000000001'; status = 'completed'
        createdAtUtc = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
        result = @{ url = $script:arteUrl; id = $script:mediaId; mediaId = $script:mediaId; audioTracks = @(); subtitles = @() }
    }
    $newer = @{
        inspectionId = 'ffffffffffffffffffffffffffffffff'; status = 'completed'
        createdAtUtc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
        result = @{ url = $script:arteUrl; id = $script:mediaId; mediaId = $script:mediaId; audioTracks = @($ids | ForEach-Object { @{ formatId = $_; language = 'fr' } }); subtitles = @() }
    }
    [void](Write-LingoJson $olderPath $older -Depth 25)
    [void](Write-LingoJson $newerPath $newer -Depth 25)
    [IO.File]::SetLastWriteTimeUtc($olderPath, [DateTime]::UtcNow.AddMinutes(-5))
    [IO.File]::SetLastWriteTimeUtc($newerPath, [DateTime]::UtcNow.AddMinutes(-1))
    Assert-AcceptedIds $ids 'all five actual ARTE audio IDs with a stale empty inspection present'
    Assert-AcceptedIds @($ids[0], $ids[1]) 'both French cedilla audio IDs'
    Assert-AcceptedIds @($ids[2], $ids[3], $ids[4]) 'ASCII German and multilingual audio IDs'

    Assert-RejectedId 'VF-STF-audio_0-inconnu' '不属于已解析' 'valid-looking but uninspected ID'
    Assert-RejectedId ($ids[0].ToUpperInvariant()) '不属于已解析' 'case-changed ID'
    foreach ($malformed in @(
        ($ids[0] + '+' + $ids[2])
        ($ids[0] + '/' + $ids[2])
        ($ids[0] + '[language=fr]')
        ($ids[0] + ',' + $ids[2])
        ($ids[0] + ' ' + $ids[2])
        ($ids[0] + '"')
        ($ids[0] + [char]10)
        ('x' * 101)
    )) {
        Assert-RejectedId $malformed '音轨格式 ID 无效' 'format expression, delimiter, control character or overlong ID'
    }
    Assert-RejectedId 251 '音轨格式 ID 无效' 'non-string format ID'

    # A newer completed parse is authoritative, even if an older parse offered that track.
    $newer.result.audioTracks = @(@{ formatId = $ids[2]; language = 'de' })
    [void](Write-LingoJson $newerPath $newer -Depth 25)
    [IO.File]::SetLastWriteTimeUtc($newerPath, [DateTime]::UtcNow)
    Assert-RejectedId $ids[0] '不属于已解析' 'track absent from the latest completed inspection'
    Assert-AcceptedIds @($ids[2]) 'remaining track from the latest completed inspection'

    [void](Invoke-ArteApi 'POST' ("/api/jobs/" + [string]$blocker.Json.job.id + '/cancel'))
    Write-Host "PASS: $script:assertions ARTE audio selection API assertions; main service and external network untouched."
} finally {
    try { Stop-ArteService } catch { Write-Warning $_.Exception.Message }
    $env:LINGOSAVE_DATA_DIR = $oldData
    $env:LINGOSAVE_YTDLP_PATH = $oldExtractor
    $fullTest = [IO.Path]::GetFullPath($testRoot)
    $fullTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $fullTest.StartsWith($fullTemp, [StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($fullTest).StartsWith('lingosave-arte-selection-api-')) { throw "Unsafe cleanup target: $fullTest" }
    if (-not $script:service) { Remove-Item -LiteralPath $fullTest -Recurse -Force -ErrorAction SilentlyContinue }
}

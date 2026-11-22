param([switch]$KeepArtifacts)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$projectRoot=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('lingosave-speed-integration-'+[guid]::NewGuid().ToString('N'))
$dataRoot=Join-Path $testRoot 'data';$jobsRoot=Join-Path $dataRoot 'jobs';$mediaRoot=Join-Path $testRoot 'media'
$fakePath=Join-Path $testRoot 'fake-yt-dlp.exe'
$script:service=$null;$script:assertions=0
$saved=@{}
foreach($name in @('LINGOSAVE_DATA_DIR','LINGOSAVE_YTDLP_PATH','LINGOSAVE_FFMPEG_DIR','LINGOSAVE_FAKE_RESOURCE_FIXTURE','LINGOSAVE_FAKE_RESOURCE_LOG','LINGOSAVE_FAKE_PROCESSING_MS','LINGOSAVE_FAKE_STAGGER_NETWORK')){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
[void][IO.Directory]::CreateDirectory($jobsRoot);[void][IO.Directory]::CreateDirectory($mediaRoot)
. (Join-Path $projectRoot 'state-io.ps1')
. (Join-Path $projectRoot 'transfer-slots.ps1')
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
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe /reference:System.Web.Extensions.dll "/out:$fakePath" (Join-Path $PSScriptRoot 'FakeResourceExtractor.cs')
    Assert-ServerTest ($LASTEXITCODE -eq 0) 'integration extractor fixture compiles'
    [IO.File]::Copy($fakePath,(Join-Path $testRoot 'ffprobe.exe'));[IO.File]::Copy($fakePath,(Join-Path $testRoot 'ffmpeg.exe'))
    $env:LINGOSAVE_DATA_DIR=$dataRoot;$env:LINGOSAVE_YTDLP_PATH=$fakePath;$env:LINGOSAVE_FFMPEG_DIR=$testRoot
    $env:LINGOSAVE_FAKE_RESOURCE_FIXTURE=Join-Path $PSScriptRoot 'fixtures\acceptance-media.json'
    $env:LINGOSAVE_FAKE_RESOURCE_LOG=Join-Path $testRoot 'calls.log'
    $env:LINGOSAVE_FAKE_PROCESSING_MS='1000';$env:LINGOSAVE_FAKE_STAGGER_NETWORK='1'
    Start-TestService
    [void](Invoke-TestApi 'POST' '/api/settings' @{maxConcurrentDownloads=2})
    $response=Invoke-TestApi 'POST' '/api/jobs' @{urls=@('https://www.arte.tv/en/videos/playlist-acceptance/');parts=@{video=$true;audio=$true;subtitles=$false};mode='resources';quality='720p';container='mkv';audioLanguages=@('fr');subtitleLanguages=@();path=$mediaRoot}
    Assert-ServerTest ($response.Code -eq 202) 'actual server accepts a full video plus independent French audio playlist'
    $id=[string]$response.Json.job.id
    $samples=[Collections.Generic.List[object]]::new();$maxDownload=0;$maxProcessing=0
    $timer=[Diagnostics.Stopwatch]::StartNew();$job=$null
    while($timer.Elapsed.TotalSeconds -lt 45){
        $job=@((Invoke-TestApi 'GET' '/api/jobs').Json.jobs | Where-Object id -eq $id)[0]
        $samples.Add(@{status=$job.status;progress=$job.progress;speed=$job.speedBytesPerSecond;bytes=$job.downloadedBytes;active=$job.activeVideos;download=$job.downloadingVideos;processing=$job.processingVideos})
        $slotRoot=Join-Path $dataRoot 'transfer-slots'
        $downloads=@(Get-ChildItem -LiteralPath $slotRoot -Filter 'download-*.json' -ErrorAction SilentlyContinue | Where-Object {Test-LingoSlotOwner (Read-LingoJson $_.FullName)})
        $processing=@(Get-ChildItem -LiteralPath $slotRoot -Filter 'processing-*.json' -ErrorAction SilentlyContinue | Where-Object {Test-LingoSlotOwner (Read-LingoJson $_.FullName)})
        $maxDownload=[math]::Max($maxDownload,$downloads.Count);$maxProcessing=[math]::Max($maxProcessing,$processing.Count)
        if($job.status -in @('completed','partial','failed','cancelled')){break}
        Start-Sleep -Milliseconds 80
    }
    Assert-ServerTest ($job.status -eq 'completed' -and $job.total -eq 2 -and $job.completed -eq 2 -and $job.failed -eq 0) 'real coordinator and resource workers complete both playlist entries without duplicate placeholders'
    Assert-ServerTest (@($samples | Where-Object {$_.active -ge 2}).Count -gt 0) 'playlist entries run as concurrent child processes'
    Assert-ServerTest ($maxDownload -eq 2 -and $maxProcessing -ge 1 -and $maxProcessing -le 2) 'raw transfers and processing share the configured global budgets'
    Assert-ServerTest (@($samples | Where-Object {$_.download -gt 0 -and $_.processing -gt 0}).Count -gt 0) 'one child downloads while another merges or converts'
    Assert-ServerTest (@($samples | Where-Object {$_.progress -gt 0 -and $_.progress -lt 1 -and $_.speed -gt 0 -and $_.bytes -gt 0}).Count -gt 0) 'parent publishes aggregate intermediate percent, speed and bytes'
    $assets=@($job.items | ForEach-Object {$_.assets})
    Assert-ServerTest ($assets.Count -eq 4 -and @($assets | Where-Object status -ne 'completed').Count -eq 0 -and @($assets | Where-Object {-not [IO.File]::Exists([string]$_.path)}).Count -eq 0) 'both entries publish one complete video and one independent audio file'
    Assert-ServerTest (@($assets.path | Select-Object -Unique).Count -eq 4 -and @($assets.path | Where-Object {$_ -match '\[.*\]'}).Count -eq 0) 'published filenames are simple and every output has a distinct path'
    $calls=[IO.File]::ReadAllLines($env:LINGOSAVE_FAKE_RESOURCE_LOG)
    foreach($number in @('001','002')){
        $source='https://www.arte.tv/en/videos/acceptance-'+$number+'/'
        Assert-ServerTest (@($calls | Where-Object {$_ -eq ('download|'+$source+'|audio|audio-fr-original')}).Count -eq 1) "French raw audio for entry $number is fetched once for video and independent audio"
    }
    Assert-ServerTest (@($calls | Where-Object {$_ -like 'download|*|audio|audio-de-dub'}).Count -eq 0) 'integration never fetches the unselected German audio track'
    $childrenRoot=Join-Path $jobsRoot ($id+'.children')
    Assert-ServerTest (@(Get-ChildItem -LiteralPath $childrenRoot -Filter 'worker.pid.json' -Recurse -ErrorAction SilentlyContinue).Count -eq 0) 'coordinator removes child process identities after completion'
    Stop-TestService
    Write-Host "PASS: $script:assertions real server/coordinator/worker integration assertions; synthetic local media only."
} finally {
    try{Stop-TestService}catch{Write-Warning $_.Exception.Message}
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
    if($KeepArtifacts){Write-Host "Artifacts: $testRoot"}
    else{
        $full=[IO.Path]::GetFullPath($testRoot);$allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
        if($full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full).StartsWith('lingosave-speed-integration-')){Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue}else{throw 'Unsafe integration cleanup target.'}
    }
}
param([switch]$KeepArtifacts)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $env:TEMP ('lingosave-multi-site-' + [guid]::NewGuid().ToString('N'))
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


$savedMulti=@{}
foreach($name in @('LINGOSAVE_DATA_DIR','LINGOSAVE_YTDLP_PATH','LINGOSAVE_FFMPEG_DIR','LINGOSAVE_FAKE_RESOURCE_FIXTURE','LINGOSAVE_FAKE_RESOURCE_LOG','LINGOSAVE_MULTI_BASE_EXE')){$savedMulti[$name]=[Environment]::GetEnvironmentVariable($name)}
try {
 . (Join-Path $projectRoot 'site-catalog.ps1')
 $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
 $baseExe=Join-Path $testRoot 'base-extractor.exe'
 & $compiler /nologo /target:exe /reference:System.Web.Extensions.dll "/out:$baseExe" (Join-Path $PSScriptRoot 'FakeResourceExtractor.cs')
 if($LASTEXITCODE-ne 0){throw 'Base test extractor compile failed'}
 & $compiler /nologo /target:exe /reference:System.Web.Extensions.dll "/out:$fakePath" (Join-Path $PSScriptRoot 'MultiSiteExtractor.cs')
 Assert-ServerTest ($LASTEXITCODE-eq 0) 'multi-site parser and downloader test fixtures compile'
 Copy-Item -LiteralPath $baseExe -Destination (Join-Path $testRoot 'ffmpeg.exe');Copy-Item -LiteralPath $baseExe -Destination (Join-Path $testRoot 'ffprobe.exe')
 $env:LINGOSAVE_DATA_DIR=$dataRoot;$env:LINGOSAVE_YTDLP_PATH=$fakePath;$env:LINGOSAVE_FFMPEG_DIR=$testRoot
 $env:LINGOSAVE_MULTI_BASE_EXE=$baseExe;$env:LINGOSAVE_FAKE_RESOURCE_FIXTURE=Join-Path $PSScriptRoot 'fixtures\acceptance-media.json';$env:LINGOSAVE_FAKE_RESOURCE_LOG=Join-Path $testRoot 'calls.log'
 Start-TestService
 $supported=(Invoke-TestApi 'GET' '/api/cookies').Json
 Assert-ServerTest (@($supported.supportedSites).Count-eq 16-and@($supported.sites.PSObject.Properties).Count-eq 16) 'real API publishes all site names and per-provider credential states'
 $urls=@('https://vimeo.com/76979871','https://www.dailymotion.com/video/x84sh87','https://www.ted.com/talks/test','https://x.com/i/status/123456','https://www.facebook.com/watch/?v=123','https://www.instagram.com/reel/test/','https://www.tiktok.com/@test/video/123456','https://www.douyin.com/video/123456','https://www.xiaohongshu.com/explore/123456','https://www.acfun.cn/v/ac123456','https://tv.cctv.com/2026/11/03/VIDEtest.shtml')
 $preview=Invoke-TestApi 'POST' '/api/preview' @{urls=$urls}
 Assert-ServerTest ($preview.Code-eq 202) 'all eleven new providers enter the async preview API'
 $path=Join-Path (Join-Path $dataRoot 'previews') ($preview.Json.previewId+'.status.json');$deadline=[DateTime]::UtcNow.AddSeconds(30)
 do{$parsed=Read-LingoJson $path;if($parsed.status-in@('completed','failed')){break};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow-lt$deadline)
 Assert-ServerTest ($parsed.status-eq'completed'-and@($parsed.result.items).Count-eq 11-and-not@($parsed.result.items|Where-Object error).Count) 'all new sources parse without an unsupported-site error'
 foreach($item in $parsed.result.items){Assert-ServerTest ($item.platform-ceq(Get-LingoSiteForUrl $item.url).label) ('preview label is correct for '+$item.platform)}
 $jobResult=Invoke-TestApi 'POST' '/api/jobs' @{urls=$urls;parts=@{video=$true;audio=$true;subtitles=$true};quality='720p';container='mkv';audioLanguages=@('fr');subtitleLanguages=@('fr');path=$mediaRoot}
 Assert-ServerTest ($jobResult.Code-eq 202) 'new platforms accept video plus separate audio and subtitles'
 $job=Wait-TestJob $jobResult.Json.job.id @('completed','partial','failed') 55
 if($job.status-ne'completed'){Write-Host ($job|ConvertTo-Json -Depth 12)}
 Assert-ServerTest ($job.status-eq'completed'-and$job.completed-eq 11-and$job.failed-eq 0) 'actual server, coordinator and workers finish all eleven provider sources'
 $assets=@($job.items|ForEach-Object {$_.assets})
 Assert-ServerTest ($assets.Count-eq 33-and-not@($assets|Where-Object {$_.status-ne'completed'-or-not[IO.File]::Exists([string]$_.path)}).Count) 'each provider publishes separate video, audio and subtitle outputs'
 foreach ($item in $job.items) {
     $assetDirectories = @($item.assets | ForEach-Object { [IO.Path]::GetDirectoryName($_.path) } | Select-Object -Unique)
     Assert-ServerTest ($assetDirectories.Count -eq 1 -and [IO.Path]::GetDirectoryName($assetDirectories[0]) -eq $mediaRoot -and $item.path.StartsWith($assetDirectories[0] + '\')) 'a video with three outputs groups all files and updates the primary file path'
 }
 $inspection=Invoke-TestApi 'POST' '/api/inspect' @{url=$urls[0]}
 $inspectPath=Join-Path (Join-Path $dataRoot 'inspections') ($inspection.Json.inspectionId+'.status.json');$deadline=[DateTime]::UtcNow.AddSeconds(20)
 do{$inspected=Read-LingoJson $inspectPath;if($inspected.status-in@('completed','failed')){break};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow-lt$deadline)
 Assert-ServerTest ($inspected.status-eq'completed'-and$inspected.result.platform-eq'Vimeo'-and@($inspected.result.audioTracks).Count-ge 2) 'manual inspection uses the new provider and retains selectable audio tracks'
 $selection=@{};$selection[$urls[0]]=@{mediaId=[string]$inspected.result.id;audioFormatIds=@('audio-fr-original');subtitleTracks=@();explicitAudio=$true;explicitSubtitles=$true}
 $audioResult=Invoke-TestApi 'POST' '/api/jobs' @{urls=@($urls[0]);parts=@{video=$false;audio=$true;subtitles=$false};audioLanguages=@('fr');sourceSelections=$selection;path=$mediaRoot}
 Assert-ServerTest ($audioResult.Code-eq 202) 'exact audio selection for a new provider passes the actual submission API'
 $audioJob=Wait-TestJob $audioResult.Json.job.id @('completed','partial','failed') 25
 Assert-ServerTest ($audioJob.status-eq'completed'-and@($audioJob.items|ForEach-Object {$_.assets}|Where-Object { $_.type -ne 'audio' }).Count-eq 0) 'audio-only selection on a new provider never creates a video output'
 Assert-ServerTest ([IO.Path]::GetDirectoryName($audioJob.items[0].path) -eq $mediaRoot) 'one output stays directly in the selected folder'
 $list=Invoke-TestApi 'POST' '/api/jobs' @{urls=@('https://vimeo.com/album/1234');parts=@{video=$true;audio=$false;subtitles=$false};container='mkv';path=$mediaRoot}
 $listed=Wait-TestJob $list.Json.job.id @('completed','partial','failed') 30
 Assert-ServerTest ($listed.status-eq'completed'-and$listed.total-eq 2-and$listed.completed-eq 2) 'Vimeo ID-only playlist entries both download without duplicate placeholders'
 $paths=@($listed.items|ForEach-Object {$_.assets}|Where-Object { $_.status -eq 'completed' }|ForEach-Object path)
 Assert-ServerTest ($paths.Count-eq 2-and@($paths|Where-Object {[IO.Path]::GetFileName([IO.Path]::GetDirectoryName($_))-ne'Vimeo'}).Count-eq 0) 'new provider playlists use the automatically named playlist folder'
 $selectedMap=@{};$selectedMap['https://vimeo.com/album/1234']=@([string]$listed.items[1].url)
 $picked=Invoke-TestApi 'POST' '/api/jobs' @{urls=@('https://vimeo.com/album/1234');selectedVideos=$selectedMap;parts=@{video=$true;audio=$false;subtitles=$false};container='mkv';path=$mediaRoot}
 $pickedJob=Wait-TestJob $picked.Json.job.id @('completed','partial','failed') 30
 Assert-ServerTest ($pickedJob.status-eq'completed'-and$pickedJob.completed-eq 1-and$pickedJob.items.Count-eq 1-and$pickedJob.items[0].url-eq$listed.items[1].url) 'playlist selection schedules only the checked video through actual API and workers'
 Assert-ServerTest ($pickedJob.items[0].title -notmatch '^\d+ - ' -and [IO.Path]::GetFileName($pickedJob.items[0].path) -notmatch '^\d+ - ') 'a playlist clip without a site-provided episode number is not numbered'
 $wordRequest=Invoke-TestApi 'POST' '/api/jobs' @{urls=@($urls[0]);parts=@{video=$false;audio=$false;subtitles=$true};subtitleLanguages=@('fr');subtitleFormat='docx';path=$mediaRoot}
 $wordJob=Wait-TestJob $wordRequest.Json.job.id @('completed','partial','failed') 30
 $wordAsset=$wordJob.items[0].assets | Select-Object -First 1
 Assert-ServerTest ($wordJob.status -eq 'completed' -and $wordJob.items[0].assets.Count -eq 1 -and [IO.Path]::GetExtension($wordAsset.path) -eq '.docx') 'ordinary site subtitles can be downloaded as Word without downloading video'
 Add-Type -AssemblyName WindowsBase
 $wordDocument=[IO.Packaging.Package]::Open($wordAsset.path,[IO.FileMode]::Open,[IO.FileAccess]::Read)
 try {
     $relation=$wordDocument.GetRelationshipsByType('http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument') | Select-Object -First 1
     $part=$wordDocument.GetPart([IO.Packaging.PackUriHelper]::ResolvePartUri($relation.SourceUri,$relation.TargetUri))
     $reader=[IO.StreamReader]::new($part.GetStream())
     try { [xml]$wordXml=$reader.ReadToEnd() } finally { $reader.Dispose() }
     Assert-ServerTest ($wordXml.DocumentElement.InnerText -ceq 'Acceptance subtitle') 'Word package contains subtitle dialogue without numeric cue or timestamp'
 } finally { $wordDocument.Close() }
 $removed=Invoke-TestApi 'POST' '/api/cookies/vimeo/remove' @{}
 Assert-ServerTest ($removed.Code-eq 200) 'new provider credential actions are routed correctly'
 $unknown=Invoke-TestApi 'POST' '/api/cookies/not-a-provider/import' @{}
 Assert-ServerTest ($unknown.Code-eq 400) 'unregistered credential providers are rejected before a file picker opens'
 $bad=Invoke-TestApi 'POST' '/api/preview' @{urls=@('https://vimeo.com.evil.invalid/123')}
 Assert-ServerTest ($bad.Code-eq 400) 'new public API retains domain-boundary validation'
 Stop-TestService
 Write-Host "PASS $script:assertions multi-site API and worker integration checks."
} finally {
 try{Stop-TestService}catch{Write-Warning $_.Exception.Message}
 foreach($name in $savedMulti.Keys){[Environment]::SetEnvironmentVariable($name,$savedMulti[$name])}
 if($KeepArtifacts){Write-Host "Artifacts: $testRoot"}else{$full=[IO.Path]::GetFullPath($testRoot);$allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\';if($full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($full).StartsWith('lingosave-multi-site-')){Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue}else{throw 'Unsafe site integration cleanup target'}}
}
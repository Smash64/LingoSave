param([switch]$KeepArtifacts)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$projectRoot=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('lingosave-playlist-folder-integration-'+[guid]::NewGuid().ToString('N'))
$dataRoot=Join-Path $testRoot 'data';$jobsRoot=Join-Path $dataRoot 'jobs';$mediaRoot=Join-Path $testRoot 'media'
$fakePath=Join-Path $testRoot 'fake-yt-dlp.exe'
$script:service=$null;$script:assertions=0
$saved=@{}
foreach($name in @('LINGOSAVE_DATA_DIR','LINGOSAVE_YTDLP_PATH','LINGOSAVE_FFMPEG_DIR','LINGOSAVE_FAKE_RESOURCE_FIXTURE','LINGOSAVE_FAKE_RESOURCE_LOG','LINGOSAVE_FAKE_PROCESSING_MS','LINGOSAVE_FAKE_STAGGER_NETWORK','LINGOSAVE_FAKE_FAIL_ONCE')){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
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



function Get-PlaylistOutputDirectory {
    param($Job, [string]$SourceUrl)
    $items=@($Job.items | Where-Object {[string]$_.sourceUrl -ceq $SourceUrl})
    $directories=@($items | ForEach-Object {@($_.assets)} | Where-Object {$_.status -eq 'completed'} | ForEach-Object {[IO.Path]::GetDirectoryName([string]$_.path)} | Select-Object -Unique)
    Assert-ServerTest ($directories.Count -eq 1) 'all completed resources of a playlist share one output directory'
    return [string]$directories[0]
}
function Submit-ResourceJob {
    param([string[]]$Urls, [switch]$AudioOnly, [string]$Language='fr')
    $response=Invoke-TestApi 'POST' '/api/jobs' @{urls=@($Urls);parts=@{video=(-not $AudioOnly);audio=$true;subtitles=(-not $AudioOnly)};quality='720p';container='mkv';audioLanguages=@($Language);subtitleLanguages=@('fr');subtitleFormat='srt';autoSimplify=$false;path=$mediaRoot}
    Assert-ServerTest ($response.Code -eq 202) 'actual API accepts the fixture resource task'
    return [string]$response.Json.job.id
}
function Get-FinalJob {
    param([string]$Id)
    $job=Wait-TestJob -Id $Id -States @('completed','partial','failed','cancelled') -Seconds 55
    # Final status can be saved slightly before the parent process exits; let the API release it.
    for($attempt=0;$attempt -lt 20;$attempt++){[void](Invoke-TestApi 'GET' '/api/jobs');Start-Sleep -Milliseconds 100}
    return $job
}

try {
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $fixtureSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FakeResourceExtractor.cs'),[Text.Encoding]::UTF8)
    $anchor='\"id\":\"acceptance-list\",\"entries\"'
    $replacement='\"id\":\"" + Regex.Replace(url, "[^a-zA-Z0-9]", "-") + "\",\"title\":\"List\",\"entries\"'
    Assert-ServerTest ($fixtureSource.Contains($anchor)) 'playlist metadata fixture has a replaceable identity anchor'
    $fixtureSource=$fixtureSource.Replace($anchor,$replacement)
    # Restrict the one intentional failure to one child, avoiding a fixture race.
    $fixtureSource=$fixtureSource.Replace('type == "audio" && format == "audio-de-dub" && !File.Exists(failOnce)', 'type == "audio" && format == "audio-de-dub" && url.Contains("acceptance-001") && !File.Exists(failOnce)')
    $fixtureSourcePath=Join-Path $testRoot 'PlaylistFolderExtractor.cs'
    [IO.File]::WriteAllText($fixtureSourcePath,$fixtureSource,[Text.UTF8Encoding]::new($false))
    & $compiler /nologo /target:exe /reference:System.Web.Extensions.dll "/out:$fakePath" $fixtureSourcePath
    Assert-ServerTest ($LASTEXITCODE -eq 0) 'local playlist extractor fixture compiles'
    [IO.File]::Copy($fakePath,(Join-Path $testRoot 'ffprobe.exe'));[IO.File]::Copy($fakePath,(Join-Path $testRoot 'ffmpeg.exe'))
    $env:LINGOSAVE_DATA_DIR=$dataRoot;$env:LINGOSAVE_YTDLP_PATH=$fakePath;$env:LINGOSAVE_FFMPEG_DIR=$testRoot
    $env:LINGOSAVE_FAKE_RESOURCE_FIXTURE=Join-Path $PSScriptRoot 'fixtures\acceptance-media.json'
    $env:LINGOSAVE_FAKE_RESOURCE_LOG=Join-Path $testRoot 'calls.log'
    $env:LINGOSAVE_FAKE_PROCESSING_MS='600';$env:LINGOSAVE_FAKE_STAGGER_NETWORK='1'
    $env:LINGOSAVE_FAKE_FAIL_ONCE=Join-Path $testRoot 'failed-once.marker'
    Start-TestService
    [void](Invoke-TestApi 'POST' '/api/settings' @{maxConcurrentDownloads=2})

    $playlist='https://www.arte.tv/en/videos/playlist-folder-first/'
    $shared='https://www.arte.tv/en/videos/playlist-folder-shared/'
    $single='https://www.arte.tv/en/videos/acceptance-single/'
    $id=Submit-ResourceJob -Urls @($playlist,$shared,$single)
    $done=Get-FinalJob $id
    Assert-ServerTest ($done.status -eq 'completed' -and $done.completed -eq 5 -and $done.failed -eq 0) 'mixed playlist and single source complete through real coordinator and resource workers'
    $directory=Get-PlaylistOutputDirectory -Job $done -SourceUrl $playlist
    Assert-ServerTest ($directory -eq (Join-Path $mediaRoot 'List')) 'playlist title creates the output subfolder under the selected save directory'
    $sharedDirectory=Get-PlaylistOutputDirectory -Job $done -SourceUrl $shared
    Assert-ServerTest ($sharedDirectory -ne $directory -and [IO.Path]::GetDirectoryName($sharedDirectory) -eq $mediaRoot) 'two playlists in one batch each receive a separate folder even when they share the same videos'
    $sharedAssets=@($done.items | Where-Object {[string]$_.sourceUrl -ceq $shared} | ForEach-Object {@($_.assets)})
    Assert-ServerTest ($sharedAssets.Count -eq 6 -and @($sharedAssets | Where-Object {[IO.Path]::GetDirectoryName([string]$_.path) -ne $sharedDirectory}).Count -eq 0) 'shared videos are saved in both playlist folders with their video, audio and subtitle files'
    $assets=@($done.items | ForEach-Object {@($_.assets)})
    Assert-ServerTest ($assets.Count -eq 15 -and @($assets | Where-Object {-not [IO.File]::Exists([string]$_.path)}).Count -eq 0) 'five playlist/single items each retain their full video, independent audio and subtitle files'
    $playlistAssets=@($done.items | Where-Object {[string]$_.sourceUrl -ceq $playlist} | ForEach-Object {@($_.assets)})
    Assert-ServerTest (@($playlistAssets | Where-Object {[IO.Path]::GetDirectoryName([string]$_.path) -ne $directory}).Count -eq 0 -and @($playlistAssets | Where-Object type -eq 'video').Count -eq 2 -and @($playlistAssets | Where-Object type -eq 'audio').Count -eq 2 -and @($playlistAssets | Where-Object type -eq 'subtitle').Count -eq 2) 'all three asset types of both playlist entries stay in the playlist folder'
    $singleAssets=@($done.items | Where-Object {[string]$_.sourceUrl -ceq $single} | ForEach-Object {@($_.assets)})
    Assert-ServerTest ($singleAssets.Count -eq 3 -and @($singleAssets | Where-Object {[IO.Path]::GetDirectoryName([string]$_.path) -ne $mediaRoot}).Count -eq 0) 'a single video mixed with a playlist keeps the original save directory'
    $persisted=Read-LingoJson -Path (Join-Path $jobsRoot "$id.config.json") -ThrowOnError
    Assert-ServerTest (@($persisted.playlistDirectories).Count -eq 2 -and $persisted.path -eq $mediaRoot) 'parent persists independent playlist mappings while keeping the original partial-transfer root'
    $entries=Read-LingoJson -Path (Join-Path $jobsRoot "$id.children\entries.json") -ThrowOnError
    Assert-ServerTest (@($entries.entries | Where-Object {[string]$_.sourceUrl -ceq $playlist -and $_.outputDirectory -eq $directory}).Count -eq 2) 'persisted child entries retain their playlist output directory'
    $second='https://www.arte.tv/en/videos/playlist-folder-second/'
    $secondId=Submit-ResourceJob -Urls @($second)
    $secondDone=Get-FinalJob $secondId
    Assert-ServerTest ($secondDone.status -eq 'completed') 'a second playlist with the same title completes'
    $secondDirectory=Get-PlaylistOutputDirectory -Job $secondDone -SourceUrl $second
    Assert-ServerTest ($secondDirectory -ne $directory -and [IO.Path]::GetDirectoryName($secondDirectory) -eq $mediaRoot -and [IO.Path]::GetFileName($secondDirectory) -match '^List \([2-9][0-9]*\)$') 'different playlists with the same title receive separate numbered folders'

    $pausedSource='https://www.arte.tv/en/videos/playlist-folder-pause/'
    $pauseId=Submit-ResourceJob -Urls @($pausedSource)
    $timer=[Diagnostics.Stopwatch]::StartNew();$pauseJob=$null
    while($timer.Elapsed.TotalSeconds -lt 25){
        $pauseJob=@((Invoke-TestApi 'GET' '/api/jobs').Json.jobs | Where-Object id -eq $pauseId)[0]
        if($pauseJob.downloadingVideos -gt 0){break}
        if($pauseJob.status -in @('completed','failed','partial')){throw 'Pause fixture finished before entering download.'}
        Start-Sleep -Milliseconds 60
    }
    Assert-ServerTest ($pauseJob.downloadingVideos -gt 0) 'pause fixture reaches a real resource download'
    $pauseConfig=Read-LingoJson -Path (Join-Path $jobsRoot "$pauseId.config.json") -ThrowOnError
    $mappingBefore=ConvertTo-Json -InputObject @($pauseConfig.playlistDirectories) -Depth 10 -Compress
    $folderCountBefore=@(Get-ChildItem -LiteralPath $mediaRoot -Directory | Where-Object {$_.Name -ne '.lingosave-partials'}).Count
    $pause=Invoke-TestApi 'POST' ("/api/jobs/$pauseId/pause") @{}
    Assert-ServerTest ($pause.Code -eq 200 -or $pause.Code -eq 202) 'API accepts pause while playlist children are downloading'
    $paused=Wait-TestJob -Id $pauseId -States @('paused') -Seconds 35
    Assert-ServerTest ($paused.status -eq 'paused' -and [IO.Directory]::Exists((Join-Path $mediaRoot ('.lingosave-partials\'+$pauseId)))) 'paused playlist preserves partial data under the original root and task identity'
    for($attempt=0;$attempt -lt 15;$attempt++){[void](Invoke-TestApi 'GET' '/api/jobs');Start-Sleep -Milliseconds 100}
    $resume=Invoke-TestApi 'POST' ("/api/jobs/$pauseId/resume") @{}
    Assert-ServerTest ($resume.Code -eq 200 -or $resume.Code -eq 202) 'API accepts resume of the paused playlist'
    $resumed=Get-FinalJob $pauseId
    $resumedDirectory=Get-PlaylistOutputDirectory -Job $resumed -SourceUrl $pausedSource
    $resumeConfig=Read-LingoJson -Path (Join-Path $jobsRoot "$pauseId.config.json") -ThrowOnError
    $mappingAfter=ConvertTo-Json -InputObject @($resumeConfig.playlistDirectories) -Depth 10 -Compress
    $folderCountAfter=@(Get-ChildItem -LiteralPath $mediaRoot -Directory | Where-Object {$_.Name -ne '.lingosave-partials'}).Count
    Assert-ServerTest ($resumed.status -eq 'completed' -and $mappingBefore -ceq $mappingAfter -and $folderCountBefore -eq $folderCountAfter -and [IO.Path]::GetDirectoryName($resumedDirectory) -eq $mediaRoot) 'pause and resume reuse exactly the original playlist folder without creating a duplicate'

    $failedSource='https://www.arte.tv/en/videos/playlist-folder-history/'
    $failedId=Submit-ResourceJob -Urls @($failedSource) -AudioOnly -Language 'de'
    $failed=Get-FinalJob $failedId
    Assert-ServerTest ($failed.status -eq 'partial' -and $failed.failed -eq 1 -and $failed.completed -eq 1) 'one fixture child fails independently while its sibling audio remains completed'
    $failureDirectory=Get-PlaylistOutputDirectory -Job $failed -SourceUrl $failedSource
    $history=(Invoke-TestApi 'GET' '/api/history').Json
    $record=@($history.failedLinks | Where-Object {$_.jobId -eq $failedId -and $_.status -eq 'unresolved'} | Select-Object -First 1)[0]
    Assert-ServerTest ($record -and [string]$record.sourceUrl -ceq $failedSource) 'failed child history retains its original playlist source'
    $configBeforeClear=Read-LingoJson -Path (Join-Path $jobsRoot "$failedId.config.json") -ThrowOnError
    $mappingBeforeClear=ConvertTo-Json -InputObject @($configBeforeClear.playlistDirectories) -Depth 10 -Compress
    $completedPaths=@($failed.items | ForEach-Object {@($_.assets)} | Where-Object status -eq 'completed' | ForEach-Object path)
    $clear=Invoke-TestApi 'DELETE' ("/api/jobs/$failedId")
    Assert-ServerTest ($clear.Code -eq 200 -and -not [IO.Directory]::Exists((Join-Path $jobsRoot ($failedId+'.children')))) 'clearing a failed task removes only its task metadata and child expansion plan'
    $snapshot=Read-LingoJson -Path (Join-Path $dataRoot ("history-job-snapshots\$failedId.json")) -ThrowOnError
    $archivedMapping=ConvertTo-Json -InputObject @($snapshot.config.playlistDirectories) -Depth 10 -Compress
    Assert-ServerTest ($mappingBeforeClear -ceq $archivedMapping -and @($completedPaths | Where-Object {-not [IO.File]::Exists([string]$_)}).Count -eq 0) 'failed-task archive preserves the folder mapping and existing completed media'
    $historyRetry=Invoke-TestApi 'POST' ("/api/history/failed/$($record.id)/retry") @{}
    Assert-ServerTest ($historyRetry.Code -eq 202 -and $historyRetry.Json.job.id -eq $failedId) 'failed history restores the original task and retries only its failed child URL'
    $recovered=Get-FinalJob $failedId
    $recoveredDirectory=Get-PlaylistOutputDirectory -Job $recovered -SourceUrl $failedSource
    $recoveredConfig=Read-LingoJson -Path (Join-Path $jobsRoot "$failedId.config.json") -ThrowOnError
    $mappingRecovered=ConvertTo-Json -InputObject @($recoveredConfig.playlistDirectories) -Depth 10 -Compress
    Assert-ServerTest ($recovered.status -eq 'completed' -and $recoveredDirectory -eq $failureDirectory -and $mappingRecovered -ceq $mappingBeforeClear) 'a child-link retry after archive restore saves to the original playlist folder'
    Assert-ServerTest (@($recovered.items | ForEach-Object {@($_.assets)} | Where-Object {$_.status -eq 'completed' -and [IO.Path]::GetDirectoryName([string]$_.path) -ne $failureDirectory}).Count -eq 0 -and @($completedPaths | Where-Object {-not [IO.File]::Exists([string]$_)}).Count -eq 0) 'history retry keeps both the recovered audio and existing sibling file in their original folder'
    $updatedHistory=(Invoke-TestApi 'GET' '/api/history').Json
    Assert-ServerTest (@($updatedHistory.failedLinks | Where-Object {$_.id -eq $record.id -and $_.status -eq 'resolved'}).Count -eq 1) 'successful retry resolves the failed-link history record'

    Stop-TestService
    Write-Host "PASS: $script:assertions playlist folder real API/coordinator/resource-worker assertions; synthetic local media only."
} finally {
    try{Stop-TestService}catch{Write-Warning $_.Exception.Message}
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
    if($KeepArtifacts){Write-Host "Artifacts: $testRoot"}
    else{
        $full=[IO.Path]::GetFullPath($testRoot);$allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
        if($full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full).StartsWith('lingosave-playlist-folder-integration-')){Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue}else{throw 'Unsafe playlist integration cleanup target.'}
    }
}
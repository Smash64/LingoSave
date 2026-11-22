param([switch]$KeepArtifacts)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$projectRoot=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('lingosave-radio-integration-'+[guid]::NewGuid().ToString('N'))
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


$saved['LINGOSAVE_RADIO_TEST_PAGES']=$env:LINGOSAVE_RADIO_TEST_PAGES
$saved['NO_PROXY']=$env:NO_PROXY
$env:NO_PROXY='127.0.0.1,localhost'
$mediaServer=$null
try {
 Copy-Item -LiteralPath (Join-Path $projectRoot 'tools\yt-dlp.exe') -Destination $fakePath
 $pluginRoot=Join-Path $testRoot 'yt-dlp-plugins\radio\yt_dlp_plugins\extractor';[void][IO.Directory]::CreateDirectory($pluginRoot)
 Copy-Item -LiteralPath (Join-Path $projectRoot 'tools\yt-dlp-plugins\lingosave\yt_dlp_plugins\extractor\lingosave_radiofrance.py') -Destination $pluginRoot
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'RadioFranceFixture.py') -Destination (Join-Path $pluginRoot 'z_radio_fixture.py')
 $source=Join-Path $testRoot 'source';[void][IO.Directory]::CreateDirectory($source)
 & 'E:\ffmpeg\bin\ffmpeg.exe' -hide_banner -loglevel error -f lavfi -i 'sine=frequency=440:duration=1.2' -c:a libmp3lame -y (Join-Path $source 'audio.mp3')
 Assert-ServerTest ($LASTEXITCODE-eq 0) 'real MP3 fixture generated'
 & 'E:\ffmpeg\bin\ffmpeg.exe' -hide_banner -loglevel error -f lavfi -i 'color=c=green:s=64x64' -frames:v 1 -threads 1 -y (Join-Path $source 'cover.jpg')
 Assert-ServerTest ($LASTEXITCODE-eq 0) 'real radio cover generated'
 & 'E:\ffmpeg\bin\ffmpeg.exe' -hide_banner -loglevel error -i (Join-Path $source 'audio.mp3') -i (Join-Path $source 'cover.jpg') -map '0:a' -map '1:v' -c copy -id3v2_version 3 -disposition:v attached_pic -y (Join-Path $source 'covered.mp3')
 Assert-ServerTest ($LASTEXITCODE-eq 0) 'MP3 fixture carries a real attached picture as Radio France does'
 Move-Item -LiteralPath (Join-Path $source 'covered.mp3') -Destination (Join-Path $source 'audio.mp3') -Force
 $transcript=@{transcript=@(
     @{start=0.127;end=0.489;speaker='SPEAKER_01';text='INTERVENANT 1: Écoutez bien.'},
     @{start=0.534;end=1.097;speaker='SPEAKER_02';text='[INTERVENANT 2] Voici la suite.'},
     @{start=1.11;end=1.17;speaker='SPEAKER_02';text='Un intervenant reste un mot.'},
     @{start=2;end=1;speaker='SPEAKER_99';text='Ignored invalid time'}
 )}
 Write-TestJson (Join-Path $source 'transcript.json') $transcript
 $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe';$mediaExe=Join-Path $testRoot 'media-server.exe'
 & $compiler /nologo /target:exe "/out:$mediaExe" (Join-Path $PSScriptRoot 'LocalResumeServer.cs')
 if($LASTEXITCODE-ne 0){throw 'Local media server compilation failed'}
 $portFile=Join-Path $testRoot 'media-port.txt';$mediaServer=Start-Process $mediaExe -ArgumentList @(('"'+$source+'"'),('"'+(Join-Path $testRoot 'requests.log')+'"'),('"'+$portFile+'"')) -WindowStyle Hidden -PassThru
 $deadline=[DateTime]::UtcNow.AddSeconds(10);while(-not[IO.File]::Exists($portFile)){if([DateTime]::UtcNow-gt$deadline){throw 'Media server not ready'};Start-Sleep -Milliseconds 50}
 $mediaUrl='http://127.0.0.1:'+([IO.File]::ReadAllText($portFile).Trim())+'/audio.mp3'
 $series='https://www.radiofrance.fr/franceculture/podcasts/lingosave-test-series';$single='https://www.radiofrance.fr/franceculture/podcasts/lingosave-test-episode-100001';$second=$series+'?lingosave_episode=episode-2';$aodUrl='https://www.radiofrance.fr/transistor/aod/episode-2'
 $content=@{id='radio-list';title='Radio';expressionCount=2;expressions=@{next=$null;items=@(@{id='episode-1';titleProps=@{href=$single.Replace('https://www.radiofrance.fr/','');title='01 · Écouter'}},@{id='episode-2';duration=1.2;titleProps=@{href='';title='02 · Lecture'}})}}
 $seriesPage='<script>content:'+($content|ConvertTo-Json -Depth 12 -Compress)+'</script>'
 $ld=@{'@type'='AudioObject';contentUrl=$mediaUrl;encodingFormat='mp3';duration='PT1.2S';name='01 · Écouter'}
 $singlePage='<script type="application/ld+json">'+($ld|ConvertTo-Json -Compress)+'</script><script>content:'+(@{id='episode-1';title='01 · Écouter'}|ConvertTo-Json -Compress)+'</script>'
 $missing='https://www.radiofrance.fr/franceculture/podcasts/lingosave-test-episode-100003'
 $transcriptUrl=$mediaUrl.Replace('/audio.mp3','/transcript.json')
 $data=@{pages=@{};json=@{};transcripts=@{'episode-1'=$transcriptUrl;'episode-2'=$transcriptUrl}}
 $data.pages[$series]=$seriesPage
 $data.pages[$single]=$singlePage
 $data.pages[$second]=$seriesPage
 $data.pages[$missing]=$singlePage.Replace('episode-1','episode-3').Replace('01 · Écouter','03 · Sans transcription')
 $data.json['https://www.radiofrance.fr/transistor/aod/episode-1']=@{hasTranscript=$true}
 $data.json[$aodUrl]=@{metadata=@{secondLine='02 · Lecture'};sources=@(@{url=$mediaUrl;preset='hifi'});hasTranscript=$true}
 $data.json['https://www.radiofrance.fr/transistor/aod/episode-3']=@{hasTranscript=$false}
 $fixturePath=Join-Path $testRoot 'pages.json';Write-TestJson $fixturePath $data
 $env:LINGOSAVE_RADIO_TEST_PAGES=$fixturePath;$env:LINGOSAVE_DATA_DIR=$dataRoot;$env:LINGOSAVE_YTDLP_PATH=$fakePath;$env:LINGOSAVE_FFMPEG_DIR='E:\ffmpeg\bin'
 $raw=& $fakePath --no-config --no-colors --no-warnings --flat-playlist --playlist-end 1 --simulate --dump-single-json $series 2>(Join-Path $testRoot 'parser.log')
 if($LASTEXITCODE-ne 0){throw ([IO.File]::ReadAllText((Join-Path $testRoot 'parser.log')))};$parsed=($raw|Out-String)|ConvertFrom-Json
 Assert-ServerTest ($parsed.title-eq'Radio' -and @($parsed.entries).Count-eq 1 -and $parsed.playlist_count-eq 2) 'production parser respects preview limits and retains full series count'
 . (Join-Path $projectRoot 'resource-planner.ps1')
 $selectionMap=@{};$selectionMap[$single]=@{mediaId='episode-1';audioFormatIds=@();subtitleTracks=@();explicitAudio=$false;explicitSubtitles=$false}
 $plan=New-LingoResourcePlan -Info ([pscustomobject]@{id='episode-1';title='Radio';lingosave_audio_only=$true;formats=@(@{format_id='radio-audio';url=$mediaUrl;ext='mp3';vcodec='none';acodec='mp3';language='fr'})}) -SourceUrl $single -Config @{parts=@{video=$true;audio=$true;subtitles=$true};audioLanguages=@('de');sourceSelections=$selectionMap}
 Assert-ServerTest (@($plan.assets).Count-eq 1-and$plan.assets[0].type-eq'audio'-and@($plan.issues | Where-Object type -ne 'subtitle').Count-eq 0 -and -not $plan.fallbackVideo) 'default radio audio is retained when a requested transcript is unavailable'
 Start-TestService
 $preview=Invoke-TestApi 'POST' '/api/preview' @{urls=@($series)};Assert-ServerTest ($preview.Code-eq 202) 'Radio France series accepted by preview API'
 $previewPath=Join-Path (Join-Path $dataRoot 'previews') ($preview.Json.previewId+'.status.json');$deadline=[DateTime]::UtcNow.AddSeconds(20)
 do{$p=Read-LingoJson $previewPath;if($p.status-in@('completed','failed')){break};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow-lt$deadline)
 Assert-ServerTest ($p.status-eq'completed' -and $p.result.items[0].platform-eq'Radio France' -and $p.result.items[0].mediaType-eq'audio' -and $p.result.items[0].count-eq 2) 'preview identifies radio platform, episode count and audio type'
 $submitted=Invoke-TestApi 'POST' '/api/jobs' @{urls=@($series);parts=@{video=$true;audio=$true;subtitles=$true};quality='best';container='mkv';audioLanguages=@('de');subtitleLanguages=@('fr');path=$mediaRoot};Assert-ServerTest ($submitted.Code-eq 202) 'default three-part settings accept radio without manual toggles'
 $job=Wait-TestJob $submitted.Json.job.id @('completed','failed','partial') 55
 if($job.status-ne'completed'){Write-Host ($job|ConvertTo-Json -Depth 12)}
 Assert-ServerTest ($job.status-eq'completed' -and $job.completed-eq 2 -and $job.failed-eq 0) 'real workers finish both a published page and a series AOD-only episode'
 $allAssets=@($job.items|ForEach-Object {$_.assets})
 $assets=@($allAssets | Where-Object type -eq 'audio')
 Assert-ServerTest ($assets.Count-eq 2 -and $allAssets.Count-eq 4 -and @($allAssets|Where-Object status -ne 'completed').Count-eq 0) 'audio and French official subtitles publish together for both Radio France entry types'
 foreach($item in $job.items){
     $audio=$item.assets | Where-Object type -eq 'audio'
     $subtitle=$item.assets | Where-Object type -eq 'subtitle'
     Assert-ServerTest ([IO.Path]::ChangeExtension($audio.path,'srt') -ceq $subtitle.path) 'subtitle path matches its exact audio basename'
     $text=[IO.File]::ReadAllText($subtitle.path)
     Assert-ServerTest ($text.Contains('00:00:00,127 --> 00:00:00,489') -and $text.Contains('Écoutez bien.') -and $text.Contains('Voici la suite.') -and $text.Contains('Un intervenant reste un mot.') -and $text -cnotmatch 'INTERVENANT \d+|SPEAKER_\d+|Ignored invalid time') 'SRT retains official timing and dialogue, strips only speaker labels and skips invalid cues'
 }
 $dirs=@($assets.path|ForEach-Object {[IO.Path]::GetDirectoryName($_)}|Select-Object -Unique);Assert-ServerTest ($dirs.Count-eq 1 -and [IO.Path]::GetFileName($dirs[0])-eq'Radio' -and [IO.Path]::GetDirectoryName($dirs[0])-eq$mediaRoot) 'series files share the automatically named series folder'
 foreach($asset in $assets){Assert-ServerTest ($asset.outputFormat-eq'original' -and (Get-FileHash -LiteralPath $asset.path).Hash -eq (Get-FileHash -LiteralPath (Join-Path $source 'audio.mp3')).Hash) 'default original MP3 is saved byte-for-byte without re-encoding'}
 Assert-ServerTest (@($assets.path|ForEach-Object {[IO.Path]::GetFileName($_)}|Where-Object {$_-notmatch '^0[12] · .+\.mp3$'-or$_-match '\[|\.fr\.mp3$'}).Count-eq 0) 'filenames preserve episode names without IDs or language suffixes'
 foreach($asset in $assets){$probe=& 'E:\ffmpeg\bin\ffprobe.exe' -v error -show_entries 'stream=codec_type:stream_disposition=attached_pic' -of json $asset.path|Out-String;$streams=@(($probe|ConvertFrom-Json).streams);Assert-ServerTest ($LASTEXITCODE-eq 0 -and @($streams|Where-Object codec_type -eq 'audio').Count-eq 1 -and @($streams|Where-Object {$_.codec_type-eq'video' -and $_.disposition.attached_pic-eq 1}).Count-eq 1 -and @($streams|Where-Object {$_.codec_type-eq'video' -and $_.disposition.attached_pic-ne 1}).Count-eq 0) 'original Radio France MP3 retains audio and cover without a real video stream'}
 $inspection=Invoke-TestApi 'POST' '/api/inspect' @{url=$single}
 $inspectionPath=Join-Path (Join-Path $dataRoot 'inspections') ($inspection.Json.inspectionId+'.status.json')
 $deadline=[DateTime]::UtcNow.AddSeconds(20)
 do{$parsed=Read-LingoJson $inspectionPath;if($parsed.status-in@('completed','failed')){break};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow-lt$deadline)
 $track=$parsed.result.subtitles | Select-Object -First 1
 Assert-ServerTest ($parsed.status -eq 'completed' -and $track.rawKey -eq 'fr' -and $track.source -eq 'provided' -and 'srt' -in $track.formats -and 'vtt' -in $track.formats) 'manual inspection exposes the official French track as SRT and VTT'
 $exact=@{};$exact[$single]=@{mediaId='episode-1';audioFormatIds=@();subtitleTracks=@(@{rawKey='fr';source='provided'});explicitAudio=$false;explicitSubtitles=$true}
 $vttJob=Invoke-TestApi 'POST' '/api/jobs' @{urls=@($single);parts=@{video=$false;audio=$false;subtitles=$true};subtitleLanguages=@('fr');subtitleFormat='vtt';sourceSelections=$exact;path=$mediaRoot}
 $vtt=Wait-TestJob $vttJob.Json.job.id @('completed','failed','partial') 35
 $vttAsset=$vtt.items[0].assets | Select-Object -First 1
 Assert-ServerTest ($vtt.status -eq 'completed' -and $vtt.items[0].assets.Count -eq 1 -and $vttAsset.type -eq 'subtitle' -and [IO.Path]::GetDirectoryName($vttAsset.path) -eq $mediaRoot) 'subtitle-only VTT does not download audio or create a single-file folder'
 $vttText=[IO.File]::ReadAllText($vttAsset.path)
 Assert-ServerTest ($vttText.StartsWith('WEBVTT') -and $vttText.Contains('00:00:00.127 --> 00:00:00.489') -and $vttText -cnotmatch 'INTERVENANT \d+') 'VTT retains millisecond timing and removes speaker labels'
 $existingName=Join-Path $mediaRoot '01 · Écouter.docx'
 [IO.File]::WriteAllText($existingName,'existing sidecar')
 $pairJob=Invoke-TestApi 'POST' '/api/jobs' @{urls=@($single);parts=@{video=$false;audio=$true;subtitles=$true};subtitleLanguages=@('fr');subtitleFormats=@('srt','vtt','docx');path=$mediaRoot}
 $pair=Wait-TestJob $pairJob.Json.job.id @('completed','failed','partial') 35
 $pairAudio=$pair.items[0].assets | Where-Object type -eq 'audio'
 $pairedSubtitles=@($pair.items[0].assets | Where-Object type -eq 'subtitle')
 $pairSubtitle=$pairedSubtitles | Where-Object {$_.path -like '*.docx'}
 Assert-ServerTest ($pairedSubtitles.Count -eq 3 -and @($pairedSubtitles | Where-Object {[IO.Path]::GetFileNameWithoutExtension($_.path) -ne [IO.Path]::GetFileNameWithoutExtension($pairAudio.path)}).Count -eq 0) 'all three subtitle formats publish with the matching audio basename'
 Assert-ServerTest ($pair.status -eq 'completed' -and [IO.Path]::ChangeExtension($pairAudio.path,'docx') -ceq $pairSubtitle.path -and [IO.Path]::GetDirectoryName($pairAudio.path) -ne $mediaRoot -and [IO.File]::ReadAllText($existingName) -eq 'existing sidecar') 'standalone episode groups a matching MP3 and Word file even if the original subtitle name exists'
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $wordPackage=[IO.Compression.ZipFile]::OpenRead($pairSubtitle.path)
 try {
     $reader=[IO.StreamReader]::new($wordPackage.GetEntry('word/document.xml').Open())
     try { [xml]$doc=$reader.ReadToEnd() } finally { $reader.Dispose() }
 } finally { $wordPackage.Dispose() }
 $paragraphs=@($doc.GetElementsByTagName('p','http://schemas.openxmlformats.org/wordprocessingml/2006/main') | ForEach-Object InnerText)
 Assert-ServerTest (($paragraphs -join '|') -ceq 'Écoutez bien.|Voici la suite.|Un intervenant reste un mot.') 'Word subtitles put sentences in separate paragraphs without timestamps, indexes or speaker labels'
 $only=Invoke-TestApi 'POST' '/api/jobs' @{urls=@($missing);parts=@{video=$false;audio=$false;subtitles=$true};subtitleLanguages=@('fr');path=$mediaRoot};$skip=Wait-TestJob $only.Json.job.id @('completed','failed','partial') 30
 Assert-ServerTest ($skip.status-eq'completed'-and$skip.skipped-eq 1) 'subtitle-only request skips absent subtitles without downloading radio audio'
 $bad=Invoke-TestApi 'POST' '/api/preview' @{urls=@('https://radiofrance.fr.evil.invalid/franceculture/podcasts/test')};Assert-ServerTest ($bad.Code-eq 400) 'lookalike domains remain rejected'
 Stop-TestService;Write-Host "PASS: $script:assertions Radio France real parser/API/MP3 assertions."
} finally {
 try{Stop-TestService}catch{Write-Warning $_.Exception.Message}
 if($mediaServer){try{if(-not$mediaServer.HasExited){$mediaServer.Kill();[void]$mediaServer.WaitForExit(3000)};$mediaServer.Dispose()}catch{}}
 foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
 if($KeepArtifacts){Write-Host "Artifacts: $testRoot"}else{$full=[IO.Path]::GetFullPath($testRoot);$allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\';if($full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($full).StartsWith('lingosave-radio-integration-')){Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue}else{throw 'Unsafe radio cleanup target'}}
}
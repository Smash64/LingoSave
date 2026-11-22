param([switch]$KeepArtifacts)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'state-io.ps1')
. (Join-Path $root 'media-cache.ps1')
. (Join-Path $root 'transfer-slots.ps1')
$testRoot=Join-Path $env:TEMP ('lingosave-speed-resources-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$psExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$ffmpegDir='E:\ffmpeg\bin';$realYt=Join-Path $root 'tools\yt-dlp.exe'
$processes=[Collections.Generic.List[object]]::new();$assertions=0
$saved=@{};foreach($name in @('LINGO_SPEED_FIXTURE','LINGO_SPEED_REAL_YT','LINGO_SPEED_LOG','LINGO_SPEED_REAL_FFMPEG','LINGO_SPEED_DELAY','LINGO_SPEED_PROCESS_FAIL_ONCE')){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
function Assert-Speed{param([bool]$Condition,[string]$Message);if(-not $Condition){throw $Message};$script:assertions++;Write-Host ('PASS '+$Message)}
function Hash-Speed{param([string]$Text);$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').Substring(0,16).ToLowerInvariant()}finally{$sha.Dispose()}}
function New-SpeedCase{
    param([string]$Name,[bool]$Video=$true,[bool]$Audio=$true,[bool]$Subs=$true,[string]$StoreRoot)
    $caseRoot=Join-Path $testRoot $Name;[void][IO.Directory]::CreateDirectory($caseRoot)
    $destination=Join-Path $caseRoot 'output';[void][IO.Directory]::CreateDirectory($destination)
    $id=[guid]::NewGuid().ToString('N');$url='https://www.arte.tv/en/videos/speed-fixture/'
    if(-not $StoreRoot){$StoreRoot=$caseRoot}
    $statusPath=Join-Path $caseRoot ($id+'.status.json');$configPath=Join-Path $caseRoot ($id+'.config.json')
    [void](Write-LingoJson -Path $statusPath -Value @{id=$id;status='queued';path=$destination;urls=@($url);items=@();total=$null;completed=0;failed=0;skipped=0;currentTitle=$null;currentAsset=$null;message=$null;error=$null;progress=$null;speedBytesPerSecond=$null;downloadedBytes=$null;totalBytes=$null;etaSeconds=$null})
    $selection=@{};$selection[$url]=@{mediaId='speed-fixture';audioFormatIds=@('fr','de');subtitleTracks=@(@{rawKey='fr';source='provided'});explicitAudio=$true;explicitSubtitles=$true}
    [void](Write-LingoJson -Path $configPath -Value @{id=$id;urls=@($url);path=$destination;parts=@{video=$Video;audio=$Audio;subtitles=$Subs};audioLanguages=@('fr','de');subtitleLanguages=@('fr');sourceSelections=$selection;quality='best';container='mkv';subtitleFormat='srt';ytDlpPath=(Join-Path $testRoot 'speed-adapter.exe');ffmpegDirectory=(Join-Path $testRoot 'processing');ffprobePath=(Join-Path $ffmpegDir 'ffprobe.exe');storeRoot=$StoreRoot;statusPath=$statusPath;cookieRevisions=@{};singleVideo=$true;singleEntry=@{id='speed-fixture';url=$url;sourceUrl=$url}} -Depth 20)
    return @{id=$id;url=$url;root=$caseRoot;destination=$destination;config=$configPath;status=$statusPath;storeRoot=$StoreRoot}
}
function Start-SpeedCase{param($Case);$p=Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $root 'resource-worker.ps1')+'"'),'-ConfigPath',('"'+$Case.config+'"')) -PassThru -WindowStyle Hidden;$processes.Add($p);return $p}
function Finish-SpeedCase{param($Case,$Process);Assert-Speed ($Process.WaitForExit(35000)) 'resource worker finishes';$Process.Refresh();Assert-Speed ($Process.ExitCode -eq 0) 'resource worker exits cleanly';$s=Read-LingoJson $Case.status -ThrowOnError;if($s.status -notin @('completed','partial')){throw ($s | ConvertTo-Json -Depth 15 -Compress)};return $s}
try{
    $source=Join-Path $testRoot 'source';[void][IO.Directory]::CreateDirectory($source)
    & (Join-Path $ffmpegDir 'ffmpeg.exe') -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=128x128:r=24:d=3' -an -c:v libx264 -b:v 800k -pix_fmt yuv420p -y (Join-Path $source 'video.mp4')
    Assert-Speed ($LASTEXITCODE -eq 0) 'real video fixture generated'
    foreach($language in @('fr','de')){& (Join-Path $ffmpegDir 'ffmpeg.exe') -hide_banner -loglevel error -f lavfi -i 'sine=frequency=440:duration=3' -c:a aac -b:a 192k -y (Join-Path $source ($language+'.m4a'));Assert-Speed ($LASTEXITCODE -eq 0) ('real '+$language+' audio generated')}
    [IO.File]::WriteAllText((Join-Path $source 'fr.srt'),"1`n00:00:00,000 --> 00:00:02,500`nFrench fixture`n",[Text.UTF8Encoding]::new($false))
    $serverExe=Join-Path $testRoot 'server.exe'; & $compiler /nologo /target:exe ('/out:'+$serverExe) (Join-Path $PSScriptRoot 'LocalResumeServer.cs')
    Assert-Speed ($LASTEXITCODE -eq 0) 'local Range fixture server compiles'
    $httpLog=Join-Path $testRoot 'requests.log';$portPath=Join-Path $testRoot 'port.txt'
    $server=Start-Process -FilePath $serverExe -ArgumentList @(('"'+$source+'"'),('"'+$httpLog+'"'),('"'+$portPath+'"')) -PassThru -WindowStyle Hidden;$processes.Add($server)
    $deadline=[DateTime]::UtcNow.AddSeconds(10);while(-not[IO.File]::Exists($portPath)){if([DateTime]::UtcNow -gt $deadline){throw 'Fixture server timed out'};Start-Sleep -Milliseconds 50}
    $address='http://127.0.0.1:'+([IO.File]::ReadAllText($portPath).Trim())
    $formats=@(@{format_id='video';url=($address+'/video.mp4');ext='mp4';vcodec='h264';acodec='none';width=128;height=128;filesize=(Get-Item (Join-Path $source 'video.mp4')).Length},@{format_id='fr';url=($address+'/fr.m4a');ext='m4a';vcodec='none';acodec='aac';language='fr';abr=192;filesize=(Get-Item (Join-Path $source 'fr.m4a')).Length},@{format_id='de';url=($address+'/de.m4a');ext='m4a';vcodec='none';acodec='aac';language='de';abr=128;filesize=(Get-Item (Join-Path $source 'de.m4a')).Length})
    $fixture=@{id='speed-fixture';title='Speed Lesson';extractor='generic';extractor_key='Generic';webpage_url='https://www.arte.tv/en/videos/speed-fixture/';duration=3;formats=$formats;subtitles=@{fr=@(@{ext='srt';url=($address+'/fr.srt')})};automatic_captions=@{}}
    # Reproduce cached metadata from a previous default format selection.
    $fixture.requested_formats=@($formats[0],$formats[2]);$fixture.requested_downloads=@(@{format_id='video+de';requested_formats=@($formats[0],$formats[2]);_filename='old-choice.mkv'});$fixture.format_id='video+de';$fixture.format='old default selection'
    $fixturePath=Join-Path $testRoot 'fixture.json';[void](Write-LingoJson $fixturePath $fixture -Depth 30)
    $env:LINGO_SPEED_FIXTURE=$fixturePath;$env:LINGO_SPEED_REAL_YT=$realYt;$env:LINGO_SPEED_LOG=Join-Path $testRoot 'calls.log';$env:LINGO_SPEED_REAL_FFMPEG=Join-Path $ffmpegDir 'ffmpeg.exe';$env:LINGO_SPEED_DELAY='0'
    $adapterSource=@'
using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Diagnostics;
using System.Threading;
public static class SpeedAdapter {
    static string Quote(string value) { if(value.Length>0 && value.All(c=>!Char.IsWhiteSpace(c)&&c!='"'))return value;StringBuilder s=new StringBuilder("\"");int n=0;foreach(char c in value){if(c=='\\'){n++;continue;}if(c=='"'){s.Append('\\',n*2+1);s.Append(c);n=0;continue;}s.Append('\\',n);n=0;s.Append(c);}s.Append('\\',n*2);s.Append('"');return s.ToString();}
    static string Arg(string[] args,string name){for(int i=0;i<args.Length-1;i++)if(args[i]==name)return args[i+1];return "";}
    static void Log(string line){string path=Environment.GetEnvironmentVariable("LINGO_SPEED_LOG");for(int i=0;i<20;i++){try{File.AppendAllText(path,DateTime.UtcNow.Ticks+"|"+line+"\n",new UTF8Encoding(false));return;}catch(IOException){Thread.Sleep(20);}}}
    public static int Main(string[] args){Console.OutputEncoding=new UTF8Encoding(false);bool ffmpeg=Path.GetFileNameWithoutExtension(Process.GetCurrentProcess().MainModule.FileName)=="ffmpeg";if(ffmpeg){Log("processing");int delay;Int32.TryParse(Environment.GetEnvironmentVariable("LINGO_SPEED_DELAY"),out delay);Thread.Sleep(delay);}else if(args.Contains("--dump-single-json")&&!args.Contains("--load-info-json")){Log("inspect");Console.WriteLine(File.ReadAllText(Environment.GetEnvironmentVariable("LINGO_SPEED_FIXTURE"),Encoding.UTF8));return 0;}else{Log((args.Contains("--dump-single-json")?"select":"download")+"|"+Arg(args,"--format"));}
    string exe=Environment.GetEnvironmentVariable(ffmpeg?"LINGO_SPEED_REAL_FFMPEG":"LINGO_SPEED_REAL_YT");string[] forwarded=ffmpeg?args:args.Concat(new string[]{"--proxy",""}).ToArray();ProcessStartInfo start=new ProcessStartInfo(exe,String.Join(" ",forwarded.Select(Quote)));start.UseShellExecute=false;start.CreateNoWindow=true;start.RedirectStandardOutput=true;start.RedirectStandardError=true;start.StandardOutputEncoding=Encoding.UTF8;start.StandardErrorEncoding=Encoding.UTF8;using(Process p=Process.Start(start)){var output=p.StandardOutput.ReadToEndAsync();var errors=p.StandardError.ReadToEndAsync();p.WaitForExit();Console.Write(output.Result);Console.Error.Write(errors.Result);if(ffmpeg&&p.ExitCode==0){string marker=Environment.GetEnvironmentVariable("LINGO_SPEED_PROCESS_FAIL_ONCE");if(!String.IsNullOrEmpty(marker)&&!File.Exists(marker)){File.WriteAllText(marker,"failure after valid temporary media");return 7;}}return p.ExitCode;}}
}
'@
    $adapterCs=Join-Path $testRoot 'SpeedAdapter.cs';[IO.File]::WriteAllText($adapterCs,$adapterSource,[Text.UTF8Encoding]::new($false))
    $adapterExe=Join-Path $testRoot 'speed-adapter.exe';& $compiler /nologo /target:exe ('/out:'+$adapterExe) $adapterCs;Assert-Speed ($LASTEXITCODE -eq 0) 'real downloader/processor adapter compiles'
    $processingRoot=Join-Path $testRoot 'processing';[void][IO.Directory]::CreateDirectory($processingRoot);[IO.File]::Copy($adapterExe,(Join-Path $processingRoot 'ffmpeg.exe'))
    $full=New-SpeedCase 'full';$done=Finish-SpeedCase $full (Start-SpeedCase $full)
    Assert-Speed ($done.status -eq 'completed' -and @($done.items[0].assets | Where-Object status -eq 'completed').Count -eq 4) 'full video, two audio languages and external subtitle complete'
    $logs=[IO.File]::ReadAllLines($env:LINGO_SPEED_LOG)
    Assert-Speed (@($logs | Where-Object {$_ -match '\|inspect$'}).Count -eq 1) 'one website metadata extraction serves all assets'
    $http=[IO.File]::ReadAllLines($httpLog)
    Assert-Speed (@($http | Where-Object {$_ -match '^REQUEST GET /fr.m4a status=200'}).Count -eq 1 -and @($http | Where-Object {$_ -match '^REQUEST GET /de.m4a status=200'}).Count -eq 1) 'video shares its actual French format with separate MP3 while distinct German track downloads once'
    $audioAsset=@($done.items[0].assets | Where-Object { $_.type -eq 'audio' -and $_.language -eq 'fr' })[0]
    Assert-Speed ($audioAsset.reusedRaw -and [IO.Path]::GetFileName($audioAsset.path) -eq 'Speed Lesson.fr.mp3') 'reuse is recorded with original title/language filename'
    $videoAsset=@($done.items[0].assets | Where-Object type -eq 'video')[0]
    $probe=& (Join-Path $ffmpegDir 'ffprobe.exe') -v error -show_entries stream=codec_type -of json $videoAsset.path | ConvertFrom-Json
    Assert-Speed (@($probe.streams | Where-Object codec_type -eq 'video').Count -eq 1 -and @($probe.streams | Where-Object codec_type -eq 'audio').Count -eq 1 -and @($probe.streams | Where-Object codec_type -eq 'subtitle').Count -eq 0) 'merged complete video retains video/audio without embedding subtitle'
    $successfulRaw=Get-ChildItem -LiteralPath $full.destination -Directory -Recurse -Filter 'raw'
    Assert-Speed (@($successfulRaw).Count -eq 0) 'completed item releases raw media cache after all final assets are verified'
    $callsBefore=$logs.Count;$again=Finish-SpeedCase $full (Start-SpeedCase $full);$callsAfter=[IO.File]::ReadAllLines($env:LINGO_SPEED_LOG).Count
    Assert-Speed ($again.status -eq 'completed' -and $callsAfter -eq $callsBefore) 'completed assets reuse verified outputs without any extractor or downloader invocation'
    $envelope=@{version=1;url=$full.url;cookieRevision='v1';fetchedAt=[DateTime]::UtcNow.ToString('o');complete=$true;info=$fixture}
    Assert-Speed (Test-LingoMetadataFresh $envelope $full.url 'v1' -RequireComplete) 'complete fresh metadata accepted'
    Assert-Speed (-not(Test-LingoMetadataFresh $envelope $full.url 'v2' -RequireComplete)) 'Cookie revision mismatch rejects metadata reuse'
    $poison=@{version=1;url=$full.url;cookieRevision='v1';fetchedAt=[DateTime]::UtcNow.ToString('o');complete=$true;info=@{id='flat-entry';title='Flat placeholder';url='https://www.arte.tv/en/videos/flat/';_type='url';formats=$null}}
    Assert-Speed (-not(Test-LingoMetadataFresh $poison $full.url 'v1' -RequireComplete)) 'poisoned complete flat-entry cache is rejected'
    $envelope.fetchedAt=[DateTime]::UtcNow.AddMinutes(-6).ToString('o');Assert-Speed (-not(Test-LingoMetadataFresh $envelope $full.url 'v1' -RequireComplete)) 'expired metadata TTL forces refresh'
    $envelope.fetchedAt=[DateTime]::UtcNow.ToString('o');$fixture.formats[0].url=$address+'/video.mp4?expire='+([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+10);Assert-Speed (-not(Test-LingoMetadataFresh $envelope $full.url 'v1' -RequireComplete)) 'near-expiry signed media URL rejects cache'
    $fixture.formats[0].url=$address+'/video.mp4'
    $legacy=New-SpeedCase 'legacy-part' $false $true $false
    $legacyConfig=Read-LingoJson $legacy.config -ThrowOnError;$legacyConfig.sourceSelections= @{};$legacyConfig.sourceSelections[$legacy.url]=@{mediaId='speed-fixture';audioFormatIds=@('fr');explicitAudio=$true;explicitSubtitles=$true;subtitleTracks=@()};[void](Write-LingoJson $legacy.config $legacyConfig -Depth 30)
    $itemHash=Hash-Speed ($legacy.url+'|speed-fixture');$assetHash=Hash-Speed 'audio:fr'
    $assetRoot=Join-Path $legacy.destination ('.lingosave-partials\'+$legacy.id+'\'+$itemHash+'\'+$assetHash);[void][IO.Directory]::CreateDirectory($assetRoot)
    $formatMetadata=@([ordered]@{id='fr';filesize=$formats[1].filesize;width=$null;height=$null;vcodec='none';acodec='aac'})
    $descriptor=[ordered]@{mediaId='speed-fixture';assetKey='audio:fr';formatId='fr';rawKey=$null;source=$null;container='mkv';subtitleFormat='srt';formats=$formatMetadata}
    $signature=Hash-Speed (ConvertTo-Json -InputObject $descriptor -Depth 10 -Compress)
    [void](Write-LingoJson (Join-Path $assetRoot 'resume.metadata.json') @{signature=$signature;descriptor=$descriptor;directory=$assetRoot} -Depth 15)
    $oldPart=Join-Path $assetRoot 'media.m4a.part';$bytes=[IO.File]::ReadAllBytes((Join-Path $source 'fr.m4a'));$seed=[byte[]]::new(4096);[Array]::Copy($bytes,$seed,4096);[IO.File]::WriteAllBytes($oldPart,$seed)
    $done=Finish-SpeedCase $legacy (Start-SpeedCase $legacy);$http=[IO.File]::ReadAllLines($httpLog)
    Assert-Speed ($done.status -eq 'completed' -and @($http | Where-Object {$_ -match '^REQUEST GET /fr.m4a status=206 start=4096'}).Count -eq 1 -and (Get-Item $oldPart).Length -eq 4096) 'new raw pipeline continues compatible legacy part at exact saved byte offset and retains original checkpoint'
    $originalFixture=Read-LingoJson $fixturePath -ThrowOnError
    $json3Fixture=Read-LingoJson $fixturePath -ThrowOnError
    $json3Fixture.subtitles=@{fr=@(@{ext='json3';data='{"events":[{"tStartMs":0,"dDurationMs":1500,"segs":[{"utf8":"French JSON fixture"}]}]}'})}
    [void](Write-LingoJson $fixturePath $json3Fixture -Depth 40)
    $json3Case=New-SpeedCase 'json3-caption' $false $false $true
    $json3Done=Finish-SpeedCase $json3Case (Start-SpeedCase $json3Case)
    $json3Output=@($json3Done.items[0].assets | Where-Object status -eq 'completed')[0].path
    Assert-Speed ($json3Done.status -eq 'completed' -and [IO.File]::ReadAllText($json3Output).Contains('French JSON fixture')) 'JSON3 caption converts into external SRT from local data without another website extraction'
    $combinedPath=Join-Path $source 'combined.mp4'
    & (Join-Path $ffmpegDir 'ffmpeg.exe') -hide_banner -loglevel error -i (Join-Path $source 'video.mp4') -i (Join-Path $source 'fr.m4a') -c copy -y $combinedPath
    Assert-Speed ($LASTEXITCODE -eq 0) 'real combined video fixture generated'
    $combinedInfo=@{id='speed-fixture';title='Combined Lesson';extractor='generic';extractor_key='Generic';webpage_url=$full.url;duration=3;url=($address+'/combined.mp4');format_id='combined';ext='mp4';vcodec='h264';acodec='aac';width=128;height=128;filesize=(Get-Item $combinedPath).Length}
    $singleEnvelope=@{version=1;url=$full.url;cookieRevision='v1';fetchedAt=[DateTime]::UtcNow.ToString('o');complete=$true;info=$combinedInfo}
    Assert-Speed (Test-LingoMetadataFresh $singleEnvelope $full.url 'v1' -RequireComplete) 'complete single-format root metadata without a formats list is accepted'
    $combinedInfo.url=$address+'/combined.mp4?expire='+([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-1)
    Assert-Speed (-not(Test-LingoMetadataFresh $singleEnvelope $full.url 'v1' -RequireComplete)) 'single-format root URL expiry rejects metadata reuse'
    $combinedInfo.url=$address+'/combined.mp4';[void](Write-LingoJson $fixturePath $combinedInfo -Depth 30)
    $combinedCase=New-SpeedCase 'combined-root' $true $false $false
    $combinedDone=Finish-SpeedCase $combinedCase (Start-SpeedCase $combinedCase)
    Assert-Speed ($combinedDone.status -eq 'completed' -and [IO.File]::Exists($combinedDone.items[0].path)) 'cached direct combined single-format video retains format identity and completes'
    [void](Write-LingoJson $fixturePath $originalFixture -Depth 40)
    $processingFail=New-SpeedCase 'processing-fail' $false $true $false
    $failConfig=Read-LingoJson $processingFail.config -ThrowOnError;$failConfig.sourceSelections= @{};$failConfig.sourceSelections[$processingFail.url]=@{mediaId='speed-fixture';audioFormatIds=@('fr');explicitAudio=$true;explicitSubtitles=$true;subtitleTracks=@()};[void](Write-LingoJson $processingFail.config $failConfig -Depth 30)
    $env:LINGO_SPEED_PROCESS_FAIL_ONCE=Join-Path $testRoot 'processing-fail.marker'
    $failedProcess=Start-SpeedCase $processingFail;Assert-Speed ($failedProcess.WaitForExit(25000)) 'intentional processing failure exits'
    $failedStatus=Read-LingoJson $processingFail.status -ThrowOnError
    $temporary=@(Get-ChildItem -LiteralPath $processingFail.destination -File -Recurse -Filter 'media.processing.mp3')
    Assert-Speed ($failedStatus.status -eq 'failed' -and $temporary.Count -eq 1 -and @(Get-ChildItem -LiteralPath $processingFail.destination -File -Filter '*.mp3').Count -eq 0) 'nonzero processing exit keeps temporary media separate and publishes no completed audio'
    $processorCalls=@([IO.File]::ReadAllLines($env:LINGO_SPEED_LOG) | Where-Object {$_ -match '\|processing$'}).Count
    $retryDone=Finish-SpeedCase $processingFail (Start-SpeedCase $processingFail)
    $afterProcessorCalls=@([IO.File]::ReadAllLines($env:LINGO_SPEED_LOG) | Where-Object {$_ -match '\|processing$'}).Count
    Assert-Speed ($retryDone.status -eq 'completed' -and $afterProcessorCalls -eq ($processorCalls+1)) 'retry reconverts valid-looking temporary output instead of treating failed processing as completed'
    $env:LINGO_SPEED_PROCESS_FAIL_ONCE=$null
    $sharedStore=Join-Path $testRoot 'shared-store';[void](Set-LingoTransferPolicy -StoreRoot $sharedStore -DownloadLimit 1 -ProcessingLimit 1)
    $env:LINGO_SPEED_DELAY='2400';$one=New-SpeedCase 'overlap-one' $true $false $false $sharedStore;$two=New-SpeedCase 'overlap-two' $true $false $false $sharedStore
    $p1=Start-SpeedCase $one;$deadline=[DateTime]::UtcNow.AddSeconds(20)
    while((Read-LingoJson $one.status).phase -ne 'merge'){if($p1.HasExited -or [DateTime]::UtcNow -gt $deadline){throw 'First processing phase unavailable'};Start-Sleep -Milliseconds 40}
    $p2=Start-SpeedCase $two;$sawOverlap=$false;$deadline=[DateTime]::UtcNow.AddSeconds(15)
    while(-not$p2.HasExited -and [DateTime]::UtcNow -lt $deadline){$leases=@(Get-ChildItem -LiteralPath (Join-Path $sharedStore 'transfer-slots') -File -Filter '*.json');if(@($leases | Where-Object Name -like 'processing-*').Count -eq 1 -and @($leases | Where-Object Name -like 'download-*').Count -eq 1){$sawOverlap=$true;break};Start-Sleep -Milliseconds 20}
    [void](Finish-SpeedCase $one $p1);[void](Finish-SpeedCase $two $p2)
    Assert-Speed ($sawOverlap) 'second real download overlaps first real FFmpeg stage with independent global slots'
    Assert-Speed (@(Get-ChildItem -LiteralPath (Join-Path $sharedStore 'transfer-slots') -File -Filter '*.json').Count -eq 0) 'successful workers release all global network and processing leases'
    Write-Host ('Speed resources acceptance passed: '+$assertions+' assertions; real local yt-dlp and FFmpeg.')
}finally{
    foreach($p in $processes){try{if(-not$p.HasExited){$p.Kill();[void]$p.WaitForExit(3000)};$p.Dispose()}catch{}}
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
    if($KeepArtifacts){Write-Host ('Artifacts: '+$testRoot)}else{$resolved=[IO.Path]::GetFullPath($testRoot);$allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\';if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}}
}

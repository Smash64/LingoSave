param([switch]$KeepArtifacts)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'state-io.ps1')
. (Join-Path $root 'resource-planner.ps1')
. (Join-Path $root 'media-cache.ps1')
$testRoot=Join-Path $env:TEMP ('lingosave-arte-audio-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$psExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$ffmpeg='E:\ffmpeg\bin\ffmpeg.exe';$ffprobe='E:\ffmpeg\bin\ffprobe.exe'
$processes=[Collections.Generic.List[object]]::new();$assertions=0
$url='https://www.arte.tv/fr/videos/115508-001-A/le-monde-des-croyances/'
$mediaId='115508-001-A'
$saved=@{};foreach($name in @('LINGO_ARTE_FIXTURE','LINGO_ARTE_REAL_YT','LINGO_ARTE_LOG')){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
function Assert-Arte{param([bool]$Condition,[string]$Message);if(-not$Condition){throw $Message};$script:assertions++;Write-Host ('PASS '+$Message)}
function New-ArteCase{
    param([string]$Name,[bool]$Video=$false,[bool]$Audio=$true,[bool]$Subs=$false,[string[]]$SelectedIds=@(),[switch]$NoSelection,[switch]$OldCache)
    $caseRoot=Join-Path $testRoot $Name;[void][IO.Directory]::CreateDirectory($caseRoot)
    $output=Join-Path $caseRoot 'output';[void][IO.Directory]::CreateDirectory($output)
    $id=[guid]::NewGuid().ToString('N');$status=Join-Path $caseRoot ($id+'.status.json');$configPath=Join-Path $caseRoot ($id+'.config.json')
    [void](Write-LingoJson $status @{id=$id;status='queued';path=$output;urls=@($url);items=@();completed=0;failed=0;skipped=0;total=$null;currentTitle=$null;currentAsset=$null;error=$null;message=$null;progress=$null;speedBytesPerSecond=$null;downloadedBytes=$null;totalBytes=$null;etaSeconds=$null})
    $selections=@{};if(-not$NoSelection){$selections[$url]=@{mediaId=$mediaId;audioFormatIds=@($SelectedIds);subtitleTracks=@(@{rawKey='fr';source='provided'});explicitAudio=$true;explicitSubtitles=$true}}
    $cfg=@{id=$id;urls=@($url);path=$output;parts=@{video=$Video;audio=$Audio;subtitles=$Subs};audioLanguages=@('fr');subtitleLanguages=@('fr');sourceSelections=$selections;quality='best';container='mkv';subtitleFormat='srt';ytDlpPath=(Join-Path $testRoot 'arte-adapter.exe');ffmpegDirectory='E:\ffmpeg\bin';ffprobePath=$ffprobe;storeRoot=$caseRoot;statusPath=$status;cookieRevisions=@{};singleVideo=$true;singleEntry=@{id=$mediaId;url=$url;sourceUrl=$url}}
    if($OldCache){$oldInfo=Read-LingoJson $env:LINGO_ARTE_FIXTURE -ThrowOnError;$cachePath=Get-LingoMetadataPath -StoreRoot $caseRoot -Url $url -Mode single;[void](Save-LingoMetadataCache -Path $cachePath -Url $url -Info $oldInfo -Complete)}
    [void](Write-LingoJson $configPath $cfg -Depth 30)
    return @{root=$caseRoot;output=$output;config=$configPath;status=$status}
}
function Run-ArteCase{
    param($Case)
    $p=Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $root 'resource-worker.ps1')+'"'),'-ConfigPath',('"'+$Case.config+'"')) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Case.root 'worker.out.log') -RedirectStandardError (Join-Path $Case.root 'worker.err.log')
    [void]$p.Handle
    $processes.Add($p)
    if(-not$p.WaitForExit(45000)){throw 'ARTE resource worker timeout'}
    $p.Refresh();$status=Read-LingoJson $Case.status -ThrowOnError
    if($p.ExitCode -ne 0 -or $status.status -notin @('completed','skipped')){throw ('ExitCode='+$p.ExitCode+'; '+($status|ConvertTo-Json -Depth 20 -Compress)+'; '+[IO.File]::ReadAllText((Join-Path $Case.root 'worker.err.log')))}
    return $status
}
function Get-ArteFrequency{
    param([string]$Path)
    $pcm=Join-Path $testRoot ([guid]::NewGuid().ToString('N')+'.pcm')
    & $ffmpeg -hide_banner -loglevel error -i $Path -map '0:a:0' -t 1 -ar 44100 -ac 1 -f s16le -y $pcm
    if($LASTEXITCODE -ne 0){throw 'Cannot decode selected audio'}
    $bytes=[IO.File]::ReadAllBytes($pcm);$samples=[int]($bytes.Length/2);$first=[int]($samples/4);$last=[int]($samples*3/4);$crossings=0
    for($i=$first+1;$i -lt $last;$i++){if([BitConverter]::ToInt16($bytes,($i-1)*2) -lt 0 -and [BitConverter]::ToInt16($bytes,$i*2) -ge 0){$crossings++}}
    return $crossings*44100/($last-$first)
}
function Audio-Asset{param($Status,[string]$FormatId);return @($Status.items[0].assets|Where-Object {$_.type -eq 'audio' -and $_.formatId -ceq $FormatId -and $_.status -eq 'completed'})[0]}
try{
    $source=Join-Path $testRoot 'source';[void][IO.Directory]::CreateDirectory($source)
    & $ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=96x96:r=12:d=1.5' -an -c:v libx264 -pix_fmt yuv420p -y (Join-Path $source 'video.mp4')
    if($LASTEXITCODE -ne 0){throw 'Cannot create real video fixture'}
    $tracks=@(
        @{slug='de';name='allemand';language='de';frequency=440},
        @{slug='de-ad';name='allemand__confort_audio_';language='de';frequency=550},
        @{slug='fr-ad';name='français__confort_audio_';language='fr';frequency=660},
        @{slug='mul';name='multilingue';language='mul';frequency=770},
        @{slug='fr';name='français';language='fr';frequency=880}
    )
    foreach($track in $tracks){$track.id='VF-STF-audio_0-'+$track.name;$dir=Join-Path $source $track.slug;[void][IO.Directory]::CreateDirectory($dir);& $ffmpeg -hide_banner -loglevel error -f lavfi -i ('sine=frequency='+$track.frequency+':duration=1.5') -c:a aac -b:a 96k -f hls -hls_time 0.4 -hls_list_size 0 -hls_segment_filename (Join-Path $dir 'seg%03d.ts') -y (Join-Path $dir 'index.m3u8');if($LASTEXITCODE -ne 0){throw 'Cannot create HLS audio '+$track.slug}}
    $serverExe=Join-Path $testRoot 'server.exe';& $compiler /nologo /target:exe ('/out:'+$serverExe) (Join-Path $PSScriptRoot 'LocalResumeServer.cs');if($LASTEXITCODE -ne 0){throw 'Local fixture server compile failed'}
    $httpLog=Join-Path $testRoot 'http.log';$portPath=Join-Path $testRoot 'port.txt'
    $server=Start-Process -FilePath $serverExe -ArgumentList @(('"'+$source+'"'),('"'+$httpLog+'"'),('"'+$portPath+'"')) -PassThru -WindowStyle Hidden;$processes.Add($server)
    $deadline=[DateTime]::UtcNow.AddSeconds(10);while(-not[IO.File]::Exists($portPath)){if([DateTime]::UtcNow -gt $deadline){throw 'Local fixture server timeout'};Start-Sleep -Milliseconds 50}
    $address='http://127.0.0.1:'+([IO.File]::ReadAllText($portPath).Trim())
    $formats=@(@{format_id='VF-STF-1800';url=($address+'/video.mp4');ext='mp4';vcodec='h264';acodec='none';width=96;height=96;filesize=(Get-Item (Join-Path $source 'video.mp4')).Length})
    foreach($track in $tracks){$formats+=@{format_id=$track.id;url=($address+'/'+$track.slug+'/index.m3u8');ext='mp4';vcodec='none';acodec=$null;protocol='m3u8_native';language=$track.language;format_note='Français [VF]';abr=96}}
    $fixture=@{id=$mediaId;title='ARTE Audio Fixture';extractor='ArteTV';extractor_key='ArteTV';webpage_url=$url;duration=1.5;formats=$formats;subtitles=@{};automatic_captions=@{}}
    $fixturePath=Join-Path $testRoot 'fixture.json';[void](Write-LingoJson $fixturePath $fixture -Depth 40)
    $env:LINGO_ARTE_FIXTURE=$fixturePath;$env:LINGO_ARTE_REAL_YT=Join-Path $root 'tools\yt-dlp.exe';$env:LINGO_ARTE_LOG=Join-Path $testRoot 'calls.log'
    $adapterCs=Join-Path $PSScriptRoot 'ArteAudioAdapter.cs';$adapterExe=Join-Path $testRoot 'arte-adapter.exe';& $compiler /nologo /target:exe ('/out:'+$adapterExe) $adapterCs;if($LASTEXITCODE -ne 0){throw 'Real yt-dlp adapter compile failed'}
    $normalized=Normalize-LingoMediaInfo -Info (Read-LingoJson $fixturePath -ThrowOnError) -SourceUrl $url
    $normalAudio=@($normalized.formats|Where-Object {$_.vcodec -eq 'none' -and $_.acodec -ne 'none'})
    $allConfig=@{parts=@{video=$false;audio=$true;subtitles=$false};sourceSelections=@{};audioLanguages=@()};$allConfig.sourceSelections[$url]=@{mediaId=$mediaId;audioFormatIds=@($tracks|ForEach-Object id);explicitAudio=$true}
    $allPlan=New-LingoResourcePlan -Info $normalized -Config $allConfig -SourceUrl $url
    Assert-Arte ($normalAudio.Count -eq 5 -and @($normalAudio|ForEach-Object audio_track_id|Select-Object -Unique).Count -eq 5 -and @($allPlan.assets|Where-Object type -eq 'audio').Count -eq 5) 'ARTE null-codec metadata keeps five distinct selectable audio renditions'
    $audioCase=New-ArteCase 'exact-audio' -SelectedIds @($tracks[2].id,$tracks[3].id);$audioDone=Run-ArteCase $audioCase
    $adAsset=Audio-Asset $audioDone $tracks[2].id;$mulAsset=Audio-Asset $audioDone $tracks[3].id
    Assert-Arte ($adAsset -and $mulAsset -and [Math]::Abs((Get-ArteFrequency $adAsset.path)-660) -lt 8 -and [Math]::Abs((Get-ArteFrequency $mulAsset.path)-770) -lt 8 -and @($audioDone.items[0].assets|Where-Object type -eq 'video').Count -eq 0) 'exact French audio description and Multilingual selections download only their actual audio signals'
    $before=@([IO.File]::ReadAllLines($httpLog)|Where-Object {$_ -match 'REQUEST GET /fr-ad/index.m3u8'}).Count
    $fullCase=New-ArteCase 'full-selected' -Video $true -SelectedIds @($tracks[2].id)
    $fullConfig=Read-LingoJson $fullCase.config -ThrowOnError
    $fullConfig.singleEntry.sourceUrl='https://www.arte.tv/fr/videos/RC-028096/inquisitions/'
    $fullConfig.sourceSelections | Add-Member -NotePropertyName $fullConfig.singleEntry.sourceUrl -NotePropertyValue $fullConfig.sourceSelections.PSObject.Properties[$url].Value
    $fullConfig.singleEntry | Add-Member -NotePropertyName officialPlaylistTitle -NotePropertyValue 'Inquisitions (2/2) - Le secret et le faste'
    [void](Write-LingoJson $fullCase.config $fullConfig -Depth 30)
    $fullDone=Run-ArteCase $fullCase
    Assert-Arte ($fullDone.items[0].title -eq 'Inquisitions (2/2) - Le secret et le faste' -and [IO.Path]::GetFileName($fullDone.items[0].path) -eq 'Inquisitions (2-2) - Le secret et le faste.mkv') 'ARTE official episode number survives from playlist title to the actual filename'
    $video=@($fullDone.items[0].assets|Where-Object {$_.type -eq 'video' -and $_.status -eq 'completed'})[0];$fullAd=Audio-Asset $fullDone $tracks[2].id
    $probe=& $ffprobe -v error -show_entries stream=codec_type -of json $video.path|ConvertFrom-Json
    Assert-Arte ($fullAd -and [Math]::Abs((Get-ArteFrequency $video.path)-660) -lt 8 -and @($probe.streams|Where-Object codec_type -eq 'video').Count -eq 1 -and @($probe.streams|Where-Object codec_type -eq 'audio').Count -eq 1) 'complete video merges the exact selected French audio description track'
    $after=@([IO.File]::ReadAllLines($httpLog)|Where-Object {$_ -match 'REQUEST GET /fr-ad/index.m3u8'}).Count
    Assert-Arte ($fullAd.reusedRaw -and $after-$before -eq 1) 'selected HLS source audio is reused between full video and standalone audio'
    $defaultCase=New-ArteCase 'default-language' -NoSelection;$defaultDone=Run-ArteCase $defaultCase
    $mainAsset=Audio-Asset $defaultDone $tracks[4].id
    Assert-Arte ($mainAsset -and @($defaultDone.items[0].assets|Where-Object {$_.type -eq 'audio' -and $_.status -eq 'completed'}).Count -eq 1 -and [Math]::Abs((Get-ArteFrequency $mainAsset.path)-880) -lt 8) 'default French preference selects regular French audio rather than audio description'
    $beforeInspect=@([IO.File]::ReadAllLines($env:LINGO_ARTE_LOG)|Where-Object {$_ -eq 'inspect'}).Count
    $cacheCase=New-ArteCase 'legacy-cache' -OldCache -SelectedIds @($tracks[1].id);$cacheDone=Run-ArteCase $cacheCase
    $afterInspect=@([IO.File]::ReadAllLines($env:LINGO_ARTE_LOG)|Where-Object {$_ -eq 'inspect'}).Count;$cachedAsset=Audio-Asset $cacheDone $tracks[1].id
    Assert-Arte ($beforeInspect -eq $afterInspect -and $cachedAsset -and [Math]::Abs((Get-ArteFrequency $cachedAsset.path)-550) -lt 8) 'fresh legacy ARTE cache with null codecs is normalized and exact German description downloads without metadata re-extraction'
    $beforeDownloads=@([IO.File]::ReadAllLines($env:LINGO_ARTE_LOG)|Where-Object {$_ -like 'download|*'}).Count
    $missingCase=New-ArteCase 'missing-subtitle' -Audio $false -Subs $true;$missingDone=Run-ArteCase $missingCase
    $afterDownloads=@([IO.File]::ReadAllLines($env:LINGO_ARTE_LOG)|Where-Object {$_ -like 'download|*'}).Count
    Assert-Arte ($beforeDownloads -eq $afterDownloads -and @($missingDone.items[0].assets|Where-Object {$_.status -eq 'completed' -or $_.type -eq 'video'}).Count -eq 0 -and @($missingDone.items[0].assets|Where-Object status -eq 'skipped').Count -ge 1) 'subtitle-only ARTE request with absent subtitles skips the resource without downloading video'
    $nativeCase=New-ArteCase 'native-only' -SelectedIds @($tracks[4].id)
    $nativeConfig=Read-LingoJson $nativeCase.config;Set-LingoObjectField $nativeConfig 'audioOutputFormats' @('original');[void](Write-LingoJson $nativeCase.config $nativeConfig -Depth 30)
    $nativeDone=Run-ArteCase $nativeCase;$nativeAsset=Audio-Asset $nativeDone $tracks[4].id
    $nativeProbe=& $ffprobe -v error -show_entries stream=codec_type,codec_name -of json $nativeAsset.path|ConvertFrom-Json
    Assert-Arte ($nativeAsset.outputFormat -eq 'original' -and [IO.Path]::GetExtension($nativeAsset.path) -eq '.m4a' -and $nativeProbe.streams.Count -eq 1 -and $nativeProbe.streams[0].codec_name -eq 'aac') 'original HLS audio keeps AAC encoding in audio-only M4A'
    $beforeDual=@([IO.File]::ReadAllLines($httpLog)|Where-Object {$_ -match 'REQUEST GET /fr/index.m3u8'}).Count
    $dualCase=New-ArteCase 'dual-output' -SelectedIds @($tracks[4].id)
    $dualConfig=Read-LingoJson $dualCase.config;Set-LingoObjectField $dualConfig 'audioOutputFormats' @('original','mp3');[void](Write-LingoJson $dualCase.config $dualConfig -Depth 30)
    $dualDone=Run-ArteCase $dualCase;$dualAssets=@($dualDone.items[0].assets|Where-Object {$_.type -eq 'audio' -and $_.status -eq 'completed'})
    $afterDual=@([IO.File]::ReadAllLines($httpLog)|Where-Object {$_ -match 'REQUEST GET /fr/index.m3u8'}).Count
    Assert-Arte ($dualAssets.Count -eq 2 -and @($dualAssets.path|ForEach-Object {[IO.Path]::GetExtension($_)}|Select-Object -Unique).Count -eq 2 -and $afterDual-$beforeDual -eq 1) 'dual original and MP3 outputs reuse a single HLS download'
    foreach($a in $dualAssets){Assert-Arte ([Math]::Abs((Get-ArteFrequency $a.path)-880) -lt 8) 'both format outputs contain the selected actual audio signal'}
    Write-Host ('ARTE audio download acceptance passed: '+$assertions+' assertions; real local yt-dlp/HLS/FFmpeg.')
}finally{
    foreach($p in $processes){try{if(-not$p.HasExited){$p.Kill();[void]$p.WaitForExit(3000)};$p.Dispose()}catch{}}
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
    if($KeepArtifacts){Write-Host ('Artifacts: '+$testRoot)}else{$resolved=[IO.Path]::GetFullPath($testRoot);$allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\';if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}}
}
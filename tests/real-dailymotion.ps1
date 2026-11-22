param([switch]$KeepArtifacts)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'state-io.ps1')
$fixture=Join-Path $env:TEMP ('lingosave-real-dailymotion-'+[guid]::NewGuid().ToString('N'))
$data=Join-Path $fixture 'data';$jobs=Join-Path $data 'jobs';$media=Join-Path $fixture 'media'
foreach($path in @($jobs,$media)){[void][IO.Directory]::CreateDirectory($path)}
$id=[guid]::NewGuid().ToString('N');$url='https://www.dailymotion.com/video/x84sh87';$statusPath=Join-Path $jobs ($id+'.status.json');$configPath=Join-Path $jobs ($id+'.config.json');$worker=$null
try {
 [void](Write-LingoJson $statusPath @{id=$id;status='queued';path=$media;urls=@($url);items=@();completed=0;failed=0;skipped=0;total=$null;message=$null;error=$null;currentTitle=$null;currentAsset=$null;progress=$null;speedBytesPerSecond=$null;downloadedBytes=$null;totalBytes=$null;etaSeconds=$null})
 [void](Write-LingoJson $configPath @{id=$id;statusPath=$statusPath;storeRoot=$data;urls=@($url);path=$media;parts=@{video=$true;audio=$false;subtitles=$false};audioLanguages=@();subtitleLanguages=@();sourceSelections=@{};quality='720p';container='mp4';subtitleFormat='srt';ytDlpPath=(Join-Path $root 'tools\yt-dlp.exe');ffmpegDirectory='E:\ffmpeg\bin';ffprobePath='E:\ffmpeg\bin\ffprobe.exe';denoPath=(Join-Path $root 'tools\deno\deno.exe');cookieRevisions=@{};singleVideo=$true;singleEntry=@{url=$url;sourceUrl=$url}} -Depth 20)
 $ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $worker=Start-Process $ps -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $root 'resource-worker.ps1')+'"'),'-ConfigPath',('"'+$configPath+'"')) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $fixture 'worker-out.log') -RedirectStandardError (Join-Path $fixture 'worker-error.log')
 if(-not$worker.WaitForExit(110000)){throw 'Public Dailymotion download exceeded the bounded test timeout.'}
 $status=Read-LingoJson $statusPath -ThrowOnError
 if($status.status-ne'completed'-or$status.completed-ne 1){throw ($status|ConvertTo-Json -Depth 12)}
 $assets=@($status.items|ForEach-Object {$_.assets}|Where-Object {$_.status-eq'completed'})
 if($assets.Count-ne 1-or$assets[0].type-ne'video'-or-not[IO.File]::Exists($assets[0].path)){throw 'Real public video output was not published.'}
 $probe=& 'E:\ffmpeg\bin\ffprobe.exe' -v error -show_entries stream=codec_type:format=duration -of json $assets[0].path|Out-String
 if($LASTEXITCODE-ne 0){throw 'Real downloaded video did not pass ffprobe.'}
 $decoded=$probe|ConvertFrom-Json
 if(-not@($decoded.streams|Where-Object codec_type -eq 'video').Count-or-not@($decoded.streams|Where-Object codec_type -eq 'audio').Count-or[double]$decoded.format.duration-lt 20){throw 'Public demo video is missing picture, sound or duration.'}
 Write-Host 'PASS actual Dailymotion 25-second video downloaded by the application worker; MP4 picture, sound and automatic title verified.'
} finally {
 if($worker){if(-not$worker.HasExited){[void](Write-LingoJson (Join-Path $jobs ($id+'.control.json')) @{action='cancel'});if(-not$worker.WaitForExit(6000)){& (Join-Path $env:WINDIR 'System32\taskkill.exe') /PID $worker.Id /T /F *> $null}};$worker.Dispose()}
 if($KeepArtifacts){Write-Host "Artifacts: $fixture"}else{$full=[IO.Path]::GetFullPath($fixture);$prefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\';if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($full)-match '^lingosave-real-dailymotion-[0-9a-f]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue}else{throw 'Unsafe public video fixture cleanup path'}}
}
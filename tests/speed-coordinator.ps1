$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$project=Split-Path -Parent $PSScriptRoot
$fixture=Join-Path $env:TEMP ('lingosave-speed-coordinator-'+[guid]::NewGuid().ToString('N'))
$codeRoot=Join-Path $fixture 'code';$store=Join-Path $fixture 'data';$jobs=Join-Path $store 'jobs';$media=Join-Path $fixture 'media'
foreach($path in @($codeRoot,$jobs,$media)){[void][IO.Directory]::CreateDirectory($path)}
foreach($name in @('resource-coordinator.ps1','state-io.ps1','credential-store.ps1','resource-planner.ps1','transfer-slots.ps1','media-cache.ps1','media-normalization.ps1','playlist-folders.ps1','site-catalog.ps1','sites.json')){Copy-Item -LiteralPath (Join-Path $project $name) -Destination (Join-Path $codeRoot $name)}
. (Join-Path $project 'state-io.ps1')
. (Join-Path $project 'transfer-slots.ps1')
. (Join-Path $project 'media-cache.ps1')
. (Join-Path $project 'resource-planner.ps1')
. (Join-Path $project 'playlist-folders.ps1')
$script:assertions=0;$script:processes=[Collections.ArrayList]::new()
function Check {param([bool]$Condition,[string]$Message);if(-not $Condition){throw "FAIL: $Message"};$script:assertions++;Write-Host "PASS: $Message"}
function Write-Test {param([string]$Path,$Value);[void](Write-LingoJson -Path $Path -Value $Value -Depth 30)}
$worker=@'
param([string]$ConfigPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'state-io.ps1')
. (Join-Path $PSScriptRoot 'transfer-slots.ps1')
$c=Read-LingoJson $ConfigPath
$s=Read-LingoJson $c.statusPath
$entry=$c.singleEntry
$item=@{id=$entry.id;url=$entry.url;sourceUrl=$entry.sourceUrl;title=$entry.title;status='running';assets=@();path=$null;error=$null;progress=$null}
if($entry.id -eq 'clip1'){$item.id='actualclip1'}
$s.items=@($item);$s.status='running';$s.currentTitle=$entry.title;$s.currentAsset='video';$s.phase='download'
$eventRoot=Join-Path $c.storeRoot 'events';[void][IO.Directory]::CreateDirectory($eventRoot)
function Event {param([string]$Kind);[void](Write-LingoJson -Path (Join-Path $eventRoot ("$PID-"+$Kind+'.json')) -Value @{pid=$PID;id=$item.id;kind=$Kind;at=[DateTime]::UtcNow.Ticks})}
function Save {[void](Write-LingoJson -Path $c.statusPath -Value $s -Depth 30)}
$download=$null;$processing=$null
try{
    $download=Enter-LingoTransferSlot -StoreRoot $c.storeRoot -Kind download -ControlPath $c.controlPath
    Event 'download-start'
    for($i=1;$i -le 28;$i++){Assert-LingoTransferAllowed -ControlPath $c.controlPath;$s.progress=$i/28.0;$item.progress=$s.progress;$s.speedBytesPerSecond=100;$s.downloadedBytes=$i*100;$s.totalBytes=2800;Save;Start-Sleep -Milliseconds 100}
    Event 'download-end';Exit-LingoTransferSlot $download;$download=$null
    $processing=Enter-LingoTransferSlot -StoreRoot $c.storeRoot -Kind processing -ControlPath $c.controlPath
    $s.phase='convert';$s.currentAsset='convert';$s.speedBytesPerSecond=$null;Save
    Event 'processing-start'
    Start-Sleep -Milliseconds 1400
    $path=Join-Path $c.path ($entry.id+'.mp4');[IO.File]::WriteAllText($path,'fixture')
    Event 'processing-end'
    $item.status='completed';$item.path=$path;$item.assets=@(@{key='video';type='video';status='completed';path=$path})
    $s.status='completed';$s.completed=1;$s.progress=$null;Save
}catch{
    $action=$_.Exception.Data['LingoControlAction']
    $s.status=if($action -eq 'pause'){'paused'}elseif($action -eq 'cancel'){'cancelled'}else{'failed'}
    $item.status=$s.status;$s.progress=$null;$s.speedBytesPerSecond=$null;Save
}finally{if($download){Exit-LingoTransferSlot $download};if($processing){Exit-LingoTransferSlot $processing}}
'@
[IO.File]::WriteAllText((Join-Path $codeRoot 'resource-worker.ps1'),$worker,[Text.UTF8Encoding]::new($true))
$mockSource=@'
using System; using System.IO;
public class CoordinatorExtractor { public static int Main(string[] args) { string log=Environment.GetEnvironmentVariable("LINGO_COORDINATOR_QUERY_LOG");if(!String.IsNullOrEmpty(log)){File.AppendAllText(log,"query\n");} if(Array.Exists(args,x=>x.Contains("slowSource"))){File.AppendAllText(log,"slow-start\n");System.Threading.Thread.Sleep(4500);File.AppendAllText(log,"slow-end\n");Console.WriteLine("{\"id\":\"slowSource\",\"title\":\"Slow source\",\"formats\":[{\"format_id\":\"best\",\"url\":\"https://example.invalid/video\"}]}");return 0;} string entries="";for(int i=1;i<=6;i++){if(i>1)entries+=",";entries+="{\"id\":\"clip"+i+"\",\"title\":\"Video "+i+"\",\"url\":\"https://www.youtube.com/watch?v=clip"+i+"\",\"extractor_key\":\"Youtube\"}";}Console.WriteLine("{\"_type\":\"playlist\",\"id\":\"list\",\"title\":\"Fixture\",\"entries\":["+entries+"]}");return 0;} }
'@
$extractor=Join-Path $fixture 'extractor.exe'
Add-Type -TypeDefinition $mockSource -OutputAssembly $extractor -OutputType ConsoleApplication
$oldLog=$env:LINGO_COORDINATOR_QUERY_LOG
$env:LINGO_COORDINATOR_QUERY_LOG=Join-Path $fixture 'query.log'
[void](Set-LingoTransferPolicy -StoreRoot $store -DownloadLimit 2 -ProcessingLimit 1)
function New-Parent {
    $id=[guid]::NewGuid().ToString('N');$statusPath=Join-Path $jobs "$id.status.json"
    Write-Test $statusPath @{id=$id;status='queued';urls=@('https://www.youtube.com/playlist?list=fixture');items=@();completed=0;failed=0;total=1;progress=$null;speedBytesPerSecond=$null;downloadedBytes=$null;totalBytes=$null;etaSeconds=$null;currentTitle=$null;currentAsset=$null;message=$null;error=$null;createdAt=[DateTime]::UtcNow.ToString('o')}
    Write-Test (Join-Path $jobs "$id.config.json") @{id=$id;statusPath=$statusPath;storeRoot=$store;path=$media;urls=@('https://www.youtube.com/playlist?list=fixture');ytdlpPath=$extractor;ffmpegDirectory=$media;parts=@{video=$true;audio=$false;subtitles=$false};retryUrls=@();cookieRevisions=@{}}
    return $id
}
function Launch {param([string]$Id)
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $PSHOME 'powershell.exe';$start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $codeRoot 'resource-coordinator.ps1')+'" -ConfigPath "'+(Join-Path $jobs "$Id.config.json")+'"'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $p=[Diagnostics.Process]::Start($start);[void]$script:processes.Add($p);return $p
}
function Await-State {param([string]$Id,[string[]]$States,[Diagnostics.Process]$Process,[int]$Seconds=35)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while($timer.Elapsed.TotalSeconds -lt $Seconds){$s=Read-LingoJson (Join-Path $jobs "$Id.status.json");if($s -and $s.status -in $States){return $s};if($Process.HasExited){throw ('Coordinator exited: '+$Process.StandardError.ReadToEnd()+' status='+($s | ConvertTo-Json -Depth 3 -Compress))};Start-Sleep -Milliseconds 100}
    throw "Timeout waiting parent $Id states $States"
}
try{
    $id=New-Parent;$p=Launch $id
    $seenConcurrent=$false;$seenProgress=$false;$maxDownloads=0;$maxProcessing=0
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while($timer.Elapsed.TotalSeconds -lt 15){
        $s=Read-LingoJson (Join-Path $jobs "$id.status.json")
        $leases=@(Get-ChildItem (Join-Path $store 'transfer-slots') -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {Read-LingoJson $_.FullName})
        $downloads=@($leases | Where-Object kind -eq 'download').Count;$processing=@($leases | Where-Object kind -eq 'processing').Count
        $maxDownloads=[math]::Max($maxDownloads,$downloads);$maxProcessing=[math]::Max($maxProcessing,$processing)
        if($downloads -ge 2){$seenConcurrent=$true}
        if($s -and $s.progress -gt 0 -and $s.progress -lt 1 -and $s.speedBytesPerSecond -gt 0){$seenProgress=$true}
        if($s.completed -ge 1 -and $s.status -eq 'running'){break}
        if($p.HasExited){throw ('Coordinator early exit: '+$p.StandardError.ReadToEnd())};Start-Sleep -Milliseconds 100
    }
    Check $seenConcurrent 'one playlist launches multiple simultaneous video downloads'
    Check $seenProgress 'parent progress and transfer speed update before completion'
    Check (-not (Read-LingoJson -Path (Get-LingoMetadataPath -StoreRoot $store -Url 'https://www.youtube.com/watch?v=clip2' -Mode single))) 'flat playlist placeholders never become complete single-video cache entries'
    Check ($maxDownloads -le 2 -and $maxProcessing -le 1) 'global download and processing budgets are obeyed'
    Write-Test (Join-Path $jobs "$id.control.json") @{action='pause'}
    $paused=Await-State $id @('paused') $p
    Check ($p.WaitForExit(5000)) 'parent pause completes after child workers safely stop'
    $completedIds=@($paused.items | Where-Object status -eq 'completed' | ForEach-Object id)
    Check ($completedIds.Count -gt 0) 'pause retains already completed media'
    $childConfigs=@(Get-ChildItem (Join-Path $jobs "$id.children") -Filter config.json -File -Recurse | ForEach-Object {Read-LingoJson $_.FullName})
    Check (@($childConfigs | Where-Object {$_.id -ne $id -or -not $_.singleVideo -or $_.controlPath -ne (Join-Path $jobs "$id.control.json")}).Count -eq 0) 'children retain parent partial identity and share the parent control file'
    Check (@($paused.items | Where-Object {$_.sourceUrl -ne 'https://www.youtube.com/playlist?list=fixture'}).Count -eq 0) 'all playlist items preserve their source URL for failure history'
    $eventsBefore=@(Get-ChildItem (Join-Path $store 'events') -Filter '*download-start.json' -File | ForEach-Object {Read-LingoJson $_.FullName})
    # Model a coordinator crash between a child commit and the next parent snapshot.
    $staleCompleted=@($paused.items | Where-Object status -eq 'completed' | Select-Object -First 1)[0]
    $staleCompleted.status='running'
    Write-Test (Join-Path $jobs "$id.status.json") $paused
    Write-Test (Join-Path $jobs "$id.control.json") @{action=$null};$p2=Launch $id
    $done=Await-State $id @('completed','failed','partial') $p2
    Check ($done.status -eq 'completed' -and $done.completed -eq 6 -and @($done.items).Count -eq 6) 'resume finishes six unique playlist entries without duplicate parent records'
    Check (@($done.items | Where-Object id -eq 'actualclip1').Count -eq 1 -and @($done.items | Where-Object id -eq 'clip1').Count -eq 0) 'complete metadata replaces an untouched flat playlist alias without duplicating it'
    Check ($p2.WaitForExit(5000)) 'completed coordinator exits cleanly'
    $eventsAfter=@(Get-ChildItem (Join-Path $store 'events') -Filter '*download-start.json' -File | ForEach-Object {Read-LingoJson $_.FullName})
    foreach($completeId in $completedIds){Check (@($eventsAfter | Where-Object id -eq $completeId).Count -eq @($eventsBefore | Where-Object id -eq $completeId).Count) "completed $completeId is not downloaded again on resume"}
    Check (@(Get-Content $env:LINGO_COORDINATOR_QUERY_LOG).Count -eq 1) 'playlist expansion is reused across pause and resume'
    $events=@(Get-ChildItem (Join-Path $store 'events') -Filter '*.json' -File | ForEach-Object {Read-LingoJson $_.FullName})
    $overlap=$false
    foreach($start in @($events | Where-Object kind -eq 'processing-start')){
        $end=@($events | Where-Object {$_.pid -eq $start.pid -and $_.kind -eq 'processing-end'} | Select-Object -First 1)
        if(-not $end.Count){continue}
        foreach($download in @($events | Where-Object kind -eq 'download-start')){
            $downloadEnd=@($events | Where-Object {$_.pid -eq $download.pid -and $_.kind -eq 'download-end'} | Select-Object -First 1)
            if($download.pid -ne $start.pid -and $downloadEnd.Count -gt 0 -and $download.at -lt $end[0].at -and $downloadEnd[0].at -gt $start.at){$overlap=$true}
        }
    }
    Check $overlap 'a different video transfers while completed downloads are being converted'
    $cachedId=New-Parent
    $cachedUrl='https://www.youtube.com/watch?v=cachedDirect'
    $cachedConfig=Read-LingoJson (Join-Path $jobs "$cachedId.config.json")
    $cachedConfig.urls=@($cachedUrl)
    Write-Test (Join-Path $jobs "$cachedId.config.json") $cachedConfig
    [void](Save-LingoMetadataCache -Path (Get-LingoMetadataPath -StoreRoot $store -Url $cachedUrl -Mode single) -Url $cachedUrl -Info @{id='cachedDirect';title='Fresh manual inspection';formats=@(@{format_id='best';url='https://example.invalid/video'})} -Complete)
    $queryCountBefore=@(Get-Content $env:LINGO_COORDINATOR_QUERY_LOG).Count
    $cachedProcess=Launch $cachedId
    $cachedDone=Await-State $cachedId @('completed','failed','partial') $cachedProcess
    Check ($cachedDone.status -eq 'completed' -and $cachedDone.completed -eq 1 -and @(Get-Content $env:LINGO_COORDINATOR_QUERY_LOG).Count -eq $queryCountBefore) 'fresh complete manual metadata dispatches a single video without any source query'
    [void]$cachedProcess.WaitForExit(5000)
    $streamId=New-Parent
    $streamConfig=Read-LingoJson (Join-Path $jobs "$streamId.config.json")
    $streamConfig.urls=@('https://www.youtube.com/playlist?list=fixture','https://www.youtube.com/watch?v=slowSource')
    Write-Test (Join-Path $jobs "$streamId.config.json") $streamConfig
    $stream=Launch $streamId;$timer.Restart();$transferringBeforeDiscovery=$false
    while($timer.Elapsed.TotalSeconds -lt 12){
        $queryLog=[IO.File]::ReadAllText($env:LINGO_COORDINATOR_QUERY_LOG)
        $leases=@(Get-ChildItem (Join-Path $store 'transfer-slots') -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {Read-LingoJson $_.FullName})
        if($queryLog.Contains('slow-start') -and -not $queryLog.Contains('slow-end') -and @($leases | Where-Object kind -eq 'download').Count -gt 0){$transferringBeforeDiscovery=$true;break}
        if($stream.HasExited){throw ('Streaming coordinator early exit: '+$stream.StandardError.ReadToEnd())};Start-Sleep -Milliseconds 100
    }
    Check $transferringBeforeDiscovery 'an already discovered playlist transfers while the later source is still resolving'
    Write-Test (Join-Path $jobs "$streamId.control.json") @{action='cancel'}
    [void](Await-State $streamId @('cancelled') $stream)
    Check ($stream.WaitForExit(5000)) 'cancel stops both discovery and spawned download children'
    # Abrupt parent death must release children and transfer leases without orphan downloads.
    $crashId=New-Parent;$crash=Launch $crashId;$timer.Restart();$childPids=@()
    while($timer.Elapsed.TotalSeconds -lt 15){
        $childPids=@(Get-ChildItem (Join-Path $jobs "$crashId.children") -Filter worker.pid.json -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {Read-LingoJson $_.FullName})
        if($childPids.Count -ge 2){break};Start-Sleep -Milliseconds 100
    }
    Check ($childPids.Count -ge 2) 'crash acceptance observes spawned child processes'
    Stop-Process -Id $crash.Id -Force;[void]$crash.WaitForExit(5000)
    Start-Sleep -Milliseconds 800
    $alive=@($childPids | Where-Object {Get-Process -Id ([int]$_.pid) -ErrorAction SilentlyContinue})
    Check ($alive.Count -eq 0) 'Windows job removes all child workers when the parent coordinator is killed'
    # Use the real aggregate function against a controlled mixed-stage snapshot.
    $sourceText=[IO.File]::ReadAllText((Join-Path $project 'resource-coordinator.ps1'))
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($sourceText,[ref]$tokens,[ref]$parseErrors)
    foreach($name in @('Save-CoordinatorStatus','Merge-CoordinatorItem','Get-CoordinatorHash','Get-CoordinatorEntryKey','Update-CoordinatorAggregate')){
        $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $script:childRoot=Join-Path $fixture 'focus-children'
    $script:parentPath=Join-Path $fixture 'focus-parent.json'
    $script:lastSave=[DateTime]::MinValue
    $script:status=@{id='focus';items=[Collections.ArrayList]::new();status='running';total=2;completed=0;failed=0;progress=$null;speedBytesPerSecond=$null;downloadedBytes=$null;totalBytes=$null;etaSeconds=$null;currentTitle=$null;currentAsset=$null;message=$null}
    $script:entries=@(@{id='processing';url='https://www.youtube.com/watch?v=processing'},@{id='downloading';url='https://www.youtube.com/watch?v=downloading'})
    $script:active=@{}
    foreach($entry in $script:entries){
        $directory=Join-Path $script:childRoot (Get-CoordinatorHash ($entry.url+"\n"+$entry.id));[void][IO.Directory]::CreateDirectory($directory)
        $path=Join-Path $directory 'status.json';$script:active[$path]=@{}
        $isDownload=$entry.id -eq 'downloading'
        Write-Test $path @{status='running';currentTitle=$(if($isDownload){'Download focus'}else{'Processing focus'});currentAsset=$(if($isDownload){'video'}else{'convert'});phase=$(if($isDownload){'download'}else{'convert'});progress=$(if($isDownload){0.4}else{$null});speedBytesPerSecond=$(if($isDownload){1234}else{$null});downloadedBytes=400;totalBytes=1000;items=@(@{id=$entry.id;url=$entry.url;status='running';assets=@()})}
    }
    Update-CoordinatorAggregate
    Check ($script:status.currentTitle -eq 'Download focus' -and $script:status.currentAsset -eq 'video' -and $script:status.phase -eq 'download' -and $script:status.speedBytesPerSecond -eq 1234) 'mixed conversion and transfer uses the downloading video for both current title and stage'
    Write-Host "Speed coordinator acceptance passed: $script:assertions assertions"
}finally{
    foreach($process in $script:processes){try{if(-not $process.HasExited){& (Join-Path $env:WINDIR 'System32\taskkill.exe') /PID $process.Id /T /F *> $null};$process.Dispose()}catch{}}
    $env:LINGO_COORDINATOR_QUERY_LOG=$oldLog
    Write-Host "Fixture: $fixture"
}

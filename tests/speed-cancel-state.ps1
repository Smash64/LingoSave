$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$project=Split-Path -Parent $PSScriptRoot
$fixture=Join-Path $env:TEMP ('lingosave-speed-cancel-state-'+[guid]::NewGuid().ToString('N'))
$data=Join-Path $fixture 'data';$jobs=Join-Path $data 'jobs';$media=Join-Path $fixture 'media'
foreach($path in @($jobs,$media)){[void][IO.Directory]::CreateDirectory($path)}
. (Join-Path $project 'state-io.ps1')
$oldData=$env:LINGOSAVE_DATA_DIR
$env:LINGOSAVE_DATA_DIR=$data
$service=$null
function Write-Test {param([string]$Path,$Value);[void](Write-LingoJson -Path $Path -Value $Value -Depth 30)}
function Api {param([string]$Method,[string]$Path)
    $request=[Net.HttpWebRequest][Net.WebRequest]::Create("http://127.0.0.1:$port$Path")
    $request.Method=$Method;$request.Proxy=$null;$request.Timeout=5000
    if($Method -eq 'POST'){$bytes=[Text.Encoding]::UTF8.GetBytes('{}');$request.ContentType='application/json';$request.ContentLength=$bytes.Length;$stream=$request.GetRequestStream();try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}
    $response=$request.GetResponse();$reader=[IO.StreamReader]::new($response.GetResponseStream(),[Text.Encoding]::UTF8)
    try{return ($reader.ReadToEnd() | ConvertFrom-Json)}finally{$reader.Dispose();$response.Dispose()}
}
try{
    $id=[guid]::NewGuid().ToString('N')
    $url='https://www.youtube.com/watch?v=existingCompleted'
    $statusPath=Join-Path $jobs "$id.status.json"
    $item=@{id='existingCompleted';url=$url;sourceUrl='https://www.youtube.com/playlist?list=parent';title='Existing';status='paused';assets=@();path=$null;error=$null}
    Write-Test $statusPath @{id=$id;status='paused';urls=@($url);items=@($item);completed=0;failed=0;total=1;progress=$null;speedBytesPerSecond=$null;downloadedBytes=$null;totalBytes=$null;etaSeconds=$null;currentTitle=$null;currentAsset=$null;message=$null;error=$null;createdAt=[DateTime]::UtcNow.ToString('o')}
    Write-Test (Join-Path $jobs "$id.config.json") @{id=$id;statusPath=$statusPath;storeRoot=$data;path=$media;urls=@($url);parts=@{video=$true;audio=$false;subtitles=$false};cookieRevisions=@{}}
    Write-Test (Join-Path $jobs "$id.control.json") @{action='pause'}
    $reserve=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$reserve.Start();$port=([Net.IPEndPoint]$reserve.LocalEndpoint).Port;$reserve.Stop()
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $PSHOME 'powershell.exe';$start.Arguments='-NoProfile -NonInteractive -Sta -ExecutionPolicy Bypass -File "'+(Join-Path $project 'server.ps1')+'" -Port '+$port
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $service=[Diagnostics.Process]::Start($start);$ready=$false
    for($attempt=0;$attempt -lt 60;$attempt++){
        if($service.HasExited){throw ('Isolated service exited: '+$service.StandardError.ReadToEnd())}
        try{$health=Api GET '/api/health';if($health.ready){$ready=$true;break}}catch{}
        Start-Sleep -Milliseconds 100
    }
    if(-not $ready){throw 'Isolated service did not become ready.'}
    # Commit a child result after service startup, leaving the parent snapshot behind.
    $output=Join-Path $media 'Existing.mp4';$partial=Join-Path $media '.lingosave-partials\existing.part'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $partial))
    [IO.File]::WriteAllText($output,'completed fixture');[IO.File]::WriteAllText($partial,'remaining checkpoint')
    $completed=@{id='existingCompleted';url=$url;sourceUrl=$item.sourceUrl;title='Existing';status='completed';path=$output;assets=@(@{key='video';type='video';status='completed';path=$output});error=$null}
    $childRoot=Join-Path $jobs "$id.children\entry";[void][IO.Directory]::CreateDirectory($childRoot)
    Write-Test (Join-Path $childRoot 'status.json') @{id=$id;status='completed';items=@($completed);completed=1;failed=0;total=1}
    $cancel=Api POST "/api/jobs/$id/cancel"
    if($cancel.job.status -ne 'cancelled' -or $cancel.job.completed -ne 1 -or @($cancel.job.items).Count -ne 1 -or $cancel.job.items[0].assets[0].path -ne $output){throw 'Cancel lost the committed child result from the stale parent snapshot.'}
    Write-Host 'PASS: cancel merges completed child state before returning the parent record'
    if(-not [IO.File]::Exists($output) -or -not [IO.File]::Exists($partial) -or $cancel.job.items[0].sourceUrl -ne $item.sourceUrl){throw 'Cancel altered completed media, checkpoints, or source identity.'}
    Write-Host 'PASS: cancelled job preserves completed media, partial data, and original playlist identity'
    $saved=Read-LingoJson -Path $statusPath
    if($saved.status -ne 'cancelled' -or $saved.completed -ne 1 -or $saved.items[0].assets[0].status -ne 'completed'){throw 'Merged cancel state was not persisted.'}
    Write-Host 'PASS: the merged completed asset remains visible in the saved parent status'
    Write-Host 'Speed cancel-state acceptance passed: 3 assertions'
}finally{
    if($service){try{if(-not $service.HasExited){[IO.File]::WriteAllText((Join-Path $data 'shutdown.request'),'');if(-not $service.WaitForExit(10000)){& (Join-Path $env:WINDIR 'System32\taskkill.exe') /PID $service.Id /T /F *> $null}};$service.Dispose()}catch{}}
    $env:LINGOSAVE_DATA_DIR=$oldData
    Write-Host "Fixture: $fixture"
}

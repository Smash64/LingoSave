param([string]$FixtureRoot,[string]$WorkerId,[ValidateSet('download','processing','metadata')][string]$Kind='download',[int]$HoldMilliseconds=900)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'transfer-slots.ps1')
if($WorkerId){
    $lease=$null; $record=@{id=$WorkerId;kind=$Kind;started=$null;finished=$null;action=$null}
    try{
        $lease=Enter-LingoTransferSlot -StoreRoot $FixtureRoot -Kind $Kind -ControlPath (Join-Path $FixtureRoot "$WorkerId.control.json")
        $record.started=[DateTime]::UtcNow.Ticks
        [void](Write-LingoJson -Path (Join-Path $FixtureRoot "$WorkerId.event.json") -Value $record)
        Start-Sleep -Milliseconds $HoldMilliseconds
    }catch{
        if(Test-LingoControlException $_){$record.action=$_.Exception.Data['LingoControlAction']}else{throw}
    }finally{
        $record.finished=[DateTime]::UtcNow.Ticks
        Exit-LingoTransferSlot $lease
        [void](Write-LingoJson -Path (Join-Path $FixtureRoot "$WorkerId.event.json") -Value $record)
    }
    exit 0
}
$testRoot=Join-Path $env:TEMP ('lingosave-transfer-slots-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$processes=[Collections.Generic.List[Diagnostics.Process]]::new()
$leases=[Collections.Generic.List[object]]::new()
$assertions=0
function Assert-Slot([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:assertions++;Write-Host "PASS: $message"}
function Start-SlotCase([string]$id,[string]$kind='download',[int]$hold=900){
    $proc=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-FixtureRoot',('"'+$testRoot+'"'),'-WorkerId',$id,'-Kind',$kind,'-HoldMilliseconds',$hold) -WindowStyle Hidden -PassThru
    $processes.Add($proc);return $proc
}
function Wait-SlotFile([string]$path){$deadline=[DateTime]::UtcNow.AddSeconds(15);while([DateTime]::UtcNow -lt $deadline){if([IO.File]::Exists($path)){return};Start-Sleep -Milliseconds 50};throw "Missing event: $path"}
try{
    $policy=Set-LingoTransferPolicy -StoreRoot $testRoot -DownloadLimit 2
    Assert-Slot ($policy.downloadLimit -eq 2 -and $policy.fragmentConcurrency -eq 4) 'download profile keeps the configured budget and four-fragment concurrency'
    $workers=@();1..4|ForEach-Object {$workers+=,(Start-SlotCase "parallel-$_")}
    foreach($proc in $workers){Assert-Slot ($proc.WaitForExit(20000)) 'owned concurrent slot worker exits';$proc.Refresh();if($proc.ExitCode -ne 0){throw 'slot worker failed'}}
    $events=@(1..4|ForEach-Object {Read-LingoJson -Path (Join-Path $testRoot "parallel-$_.event.json") -ThrowOnError})
    $points=@();foreach($event in $events){$points+=@{tick=[long]$event.started;delta=1};$points+=@{tick=[long]$event.finished;delta=-1}}
    $count=0;$peak=0;foreach($point in @($points|Sort-Object @{Expression={$_.tick}},@{Expression={$_.delta}})){$count+=$point.delta;$peak=[math]::Max($peak,$count)}
    Assert-Slot ($peak -eq 2) 'four real processes overlap in pairs and never exceed the global download limit'
    $held=Enter-LingoTransferSlot -StoreRoot $testRoot -Kind download;$leases.Add($held)
    [void](Set-LingoTransferPolicy -StoreRoot $testRoot -DownloadLimit 1)
    $processing=Enter-LingoTransferSlot -StoreRoot $testRoot -Kind processing;$leases.Add($processing)
    Assert-Slot ($processing.Kind -eq 'processing' -and [IO.File]::Exists($held.Path)) 'processing can start while the only download slot is occupied; lowering the limit preserves its owner'
    $waiting=Start-SlotCase 'paused-waiter'
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    while([DateTime]::UtcNow -lt $deadline -and @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'transfer-slots\waiting') -Filter 'download-*.json' -File).Count -eq 0){Start-Sleep -Milliseconds 50}
    [void](Write-LingoJson -Path (Join-Path $testRoot 'paused-waiter.control.json') -Value @{action='pause'})
    Assert-Slot ($waiting.WaitForExit(10000)) 'pause wakes a worker waiting for a global transfer slot'
    $paused=Read-LingoJson -Path (Join-Path $testRoot 'paused-waiter.event.json') -ThrowOnError
    Assert-Slot ($paused.action -eq 'pause' -and $null -eq $paused.started -and @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'transfer-slots\waiting') -File).Count -eq 0) 'paused waiting worker never downloads and removes its pending request'
    foreach($lease in $leases){Exit-LingoTransferSlot $lease};$leases.Clear()
    $crash=Start-SlotCase 'crashed-owner' 'download' 20000
    Wait-SlotFile (Join-Path $testRoot 'crashed-owner.event.json')
    $crash.Kill();[void]$crash.WaitForExit(5000)
    $recovered=Enter-LingoTransferSlot -StoreRoot $testRoot -Kind download;$leases.Add($recovered)
    Assert-Slot ([IO.Path]::GetFileName($recovered.Path) -eq 'download-0.json') 'a killed owner does not leak its transfer slot and the next process reclaims it'
    Write-Host "Transfer slots acceptance passed: $script:assertions assertions."
}finally{
    foreach($lease in $leases){try{Exit-LingoTransferSlot $lease}catch{}}
    foreach($proc in $processes){try{if(-not $proc.HasExited){$proc.Kill();[void]$proc.WaitForExit(3000)};$proc.Dispose()}catch{}}
    $resolved=[IO.Path]::GetFullPath($testRoot);$allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
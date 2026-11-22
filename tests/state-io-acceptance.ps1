param([switch]$KeepArtifacts)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'state-io.ps1')
$testRoot = Join-Path $env:TEMP ('lingosave-state-io-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$path = Join-Path $testRoot 'state.json'
$script:assertions = 0
function Assert-Io { param([bool]$Condition,[string]$Message); if (-not $Condition) { throw $Message }; $script:assertions++; Write-Host "PASS $Message" }
function Start-IoHelper {
    param([string]$Name,[string]$Body)
    $helper = Join-Path $testRoot "$Name.ps1"
    [IO.File]::WriteAllText($helper,$Body,[Text.UTF8Encoding]::new($true))
    return Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$helper+'"')) -WindowStyle Hidden -PassThru
}
try {
    Assert-Io ($null -eq (Read-LingoJson -Path $path -ThrowOnError)) 'missing JSON returns null for initialization'
    [void](Write-LingoJson $path @{version=1})
    $snapshot = [IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        Assert-Io (Write-LingoJson $path @{version=2}) 'atomic replacement succeeds while a shared snapshot reader is open'
        $reader=[IO.StreamReader]::new($snapshot,[Text.Encoding]::UTF8); $old=$reader.ReadToEnd() | ConvertFrom-Json
        Assert-Io ($old.version -eq 1 -and (Read-LingoJson $path -ThrowOnError).version -eq 2) 'reader sees a complete old snapshot and subsequent reader sees complete new JSON'
        $reader.Dispose()
    } finally { $snapshot.Dispose() }
    $escapedPath=$path.Replace("'","''"); $escapedHelper=(Join-Path $root 'state-io.ps1').Replace("'","''")
    $writer=Start-IoHelper 'writer' ". '$escapedHelper'`nfor(`$i=3;`$i -le 100;`$i++){[void](Write-LingoJson -Path '$escapedPath' -Value @{version=`$i;payload=('x'*1000)});Start-Sleep -Milliseconds 2}"
    $reads=0
    while(-not $writer.HasExited){$value=Read-LingoJson $path -ThrowOnError; if(-not $value -or -not $value.version){throw 'Corrupt or missing status snapshot'};$reads++;Start-Sleep -Milliseconds 3}
    $writer.Refresh();Assert-Io ($writer.ExitCode -eq 0 -and $reads -gt 10 -and (Read-LingoJson $path -ThrowOnError).version -eq 100) 'high-frequency polling and writes never expose incomplete or missing JSON'
    $writer.Dispose()
    $marker=Join-Path $testRoot 'locked.marker';$escapedMarker=$marker.Replace("'","''")
    $locker=Start-IoHelper 'lock-short' "`$s=[IO.FileStream]::new('$escapedPath',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);[IO.File]::WriteAllText('$escapedMarker','1');Start-Sleep -Milliseconds 650;`$s.Dispose()"
    $deadline=[DateTime]::UtcNow.AddSeconds(5);while(-not [IO.File]::Exists($marker) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 20}
    Assert-Io (Write-LingoJson $path @{version=101}) 'critical state retries temporary exclusive file occupation'
    [void]$locker.WaitForExit(5000);$locker.Dispose();Remove-Item -LiteralPath $marker
    $locker=Start-IoHelper 'lock-long' "`$s=[IO.FileStream]::new('$escapedPath',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);[IO.File]::WriteAllText('$escapedMarker','1');Start-Sleep -Milliseconds 1800;`$s.Dispose()"
    $deadline=[DateTime]::UtcNow.AddSeconds(5);while(-not [IO.File]::Exists($marker) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 20}
    Assert-Io (-not (Write-LingoJson $path @{version=102} -BestEffort)) 'ordinary progress write returns false instead of stopping media transfer when occupation persists'
    [void]$locker.WaitForExit(5000);$locker.Dispose()
    Assert-Io (Write-LingoJson $path @{version=102}) 'pending in-memory progress is persisted after occupation ends'
    Assert-Io ([IO.File]::Exists("$path.io.log") -and [IO.File]::ReadAllText("$path.io.log") -match 'write_failed|write_recovered') 'occupation diagnostic is recorded without serializing task contents'
    [IO.File]::WriteAllText($path,'{bad json')
    $threw=$false;try{$corruptValue=Read-LingoJson -Path $path -ThrowOnError}catch{$threw=$true}
    Assert-Io $threw 'critical read does not silently overwrite damaged state'
    Assert-Io (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.tmp' -File).Count -eq 0) 'temporary JSON files are cleaned after success and failure'
    Write-Host "State IO acceptance passed: $script:assertions assertions."
} finally {
    if($KeepArtifacts){Write-Host "Artifacts: $testRoot"}
    else{$resolved=[IO.Path]::GetFullPath($testRoot);$allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\';if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}}
}

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'state-io.ps1')
. (Join-Path $root 'media-cache.ps1')
$testRoot = Join-Path $env:TEMP ('lingosave-manual-cache-' + [guid]::NewGuid().ToString('N'))
$inspections = Join-Path $testRoot 'inspections'
[void][IO.Directory]::CreateDirectory($inspections)
$worker = $null
try {
    $id = [guid]::NewGuid().ToString('N')
    $url = 'https://www.arte.tv/zh/videos/sample-001/'
    $statusPath = Join-Path $inspections ($id + '.status.json')
    $configPath = Join-Path $inspections ($id + '.config.json')
    [void](Write-LingoJson -Path $statusPath -Value @{inspectionId=$id;status='queued';result=$null;error=$null})
    [void](Write-LingoJson -Path $configPath -Value @{id=$id;url=$url;site='arte';ytDlpPath=(Join-Path $PSScriptRoot 'fake-yt-dlp.ps1');storeRoot=$testRoot;statusPath=$statusPath;inspectionsRoot=$inspections})
    $worker = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $root 'inspection-worker.ps1')+'"'),'-ConfigPath',('"'+$configPath+'"')) -PassThru -WindowStyle Hidden
    if (-not $worker.WaitForExit(15000)) { throw 'Manual inspection worker timed out.' }
    $status = Read-LingoJson -Path $statusPath -ThrowOnError
    if ($status.status -ne 'completed') { throw ('Manual inspection failed: '+$status.error) }
    Write-Host 'PASS manual inspection worker completes with shared budget'
    $cachePath = Get-LingoMetadataPath -StoreRoot $testRoot -Url $url -Mode single
    $info = Read-LingoMetadataCache -Path $cachePath -Url $url -RequireComplete
    if (-not $info -or $info.id -ne 'sample-001' -or @($info.formats | Where-Object format_id -eq 'a-fr').Count -ne 1 -or -not $info.subtitles.'fr-acc') { throw 'Complete raw metadata was not cached.' }
    Write-Host 'PASS complete raw formats and exact subtitle identities are cached for download reuse'
    if ($status.result.PSObject.Properties['info'] -or @($status.result.formats | Where-Object {$_.PSObject.Properties['url'] -or $_.PSObject.Properties['format_id']}).Count) { throw 'Raw metadata leaked into UI result.' }
    Write-Host 'PASS UI result retains normalized track schema without raw metadata'
    if (Read-LingoMetadataCache -Path $cachePath -Url $url -CookieRevision 'changed' -RequireComplete) { throw 'Cache survived Cookie revision change.' }
    Write-Host 'PASS Cookie revision changes invalidate manual metadata cache'
    $leases = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'transfer-slots') -Filter 'metadata-*.json' -File -ErrorAction SilentlyContinue)
    if ($leases.Count) { throw 'Manual inspection leaked metadata lease.' }
    Write-Host 'PASS inspection releases shared metadata lease'
} finally {
    if ($worker) { try { if (-not $worker.HasExited) { $worker.Kill(); [void]$worker.WaitForExit(3000) } } catch {}; $worker.Dispose() }
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolvedTest.StartsWith($resolvedTemp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedTest).StartsWith('lingosave-manual-cache-')) { Remove-Item -LiteralPath $resolvedTest -Recurse -Force }
}
param([switch]$KeepArtifacts)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'state-io.ps1')
$testRoot = Join-Path $env:TEMP ('lingosave-stability-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$fake = Join-Path $testRoot 'fake-yt-dlp.exe'
$probe = Join-Path $testRoot 'ffprobe.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$savedEnvironment = @{}
foreach ($name in @('LINGO_STABILITY_LOG','LINGO_STABILITY_SCENARIO','LINGO_STABILITY_MARKER','LINGO_STABILITY_FIXTURE')) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
$env:LINGO_STABILITY_FIXTURE = Join-Path $PSScriptRoot 'fixtures\acceptance-media.json'
$script:count = 0

function Assert-Stable { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message }; $script:count++; Write-Host "PASS $Message" }
function New-StableCase {
    param([string]$Name, [string]$Scenario, [switch]$Playlist, [switch]$Audio)
    $dir = Join-Path $testRoot $Name; [void][IO.Directory]::CreateDirectory($dir)
    $destination = Join-Path $dir 'Chinese 中文 media'; [void][IO.Directory]::CreateDirectory($destination)
    $id = [guid]::NewGuid().ToString('N')
    $url = if ($Playlist) { 'https://www.arte.tv/en/videos/stability-playlist/' } else { 'https://www.arte.tv/en/videos/stability-001/' }
    $statusPath = Join-Path $dir "$id.status.json"
    $configPath = Join-Path $dir "$id.config.json"
    $status = @{ id = $id; status = 'queued'; path = $destination; urls = @($url); items = @(); total = $null; completed = 0; failed = 0; progress = $null; speedBytesPerSecond = $null; downloadedBytes = $null; totalBytes = $null; etaSeconds = $null; currentTitle = $null; currentAsset = $null; error = $null; message = $null }
    $config = @{ id = $id; urls = @($url); path = $destination; parts = @{ video = $true; audio = [bool]$Audio; subtitles = $false }; audioLanguages = @('fr'); subtitleLanguages = @('fr'); sourceSelections = @{}; quality = '720p'; container = 'mkv'; subtitleFormat = 'srt'; ytDlpPath = $fake; ffmpegDirectory = $testRoot; ffprobePath = $probe; denoPath = $null; storeRoot = $dir; statusPath = $statusPath; cookieRevisions = @{} }
    [void](Write-LingoJson $statusPath $status); [void](Write-LingoJson $configPath $config)
    $env:LINGO_STABILITY_SCENARIO = $Scenario
    $env:LINGO_STABILITY_LOG = Join-Path $dir 'calls.log'
    $env:LINGO_STABILITY_MARKER = Join-Path $dir 'network.marker'
    return @{ Root=$dir; Id=$id; Status=$statusPath; Config=$configPath; Control=(Join-Path $dir "$id.control.json"); Destination=$destination; Url=$url; Log=$env:LINGO_STABILITY_LOG }
}
function Start-StableWorker {
    param($Case, [switch]$Legacy)
    $worker = if ($Legacy) { 'download-worker.ps1' } else { 'resource-worker.ps1' }
    return Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File', ('"' + (Join-Path $root $worker) + '"'), '-ConfigPath', ('"' + $Case.Config + '"')) -WindowStyle Hidden -PassThru
}
function Wait-StableStatus {
    param($Case, [string]$Wanted, $Process, [int]$Milliseconds=20000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $status = Read-LingoJson $Case.Status -ThrowOnError
        if (($Wanted -eq 'progress' -and $status.downloadedBytes -ge 3000 -and $status.downloadedBytes -lt 12000) -or ($Wanted -eq 'processing' -and $status.phase -in @('merge','convert')) -or $status.status -eq $Wanted) { return $status }
        if ($Process.HasExited) { throw "Worker exited before $Wanted`: $($status | ConvertTo-Json -Depth 15 -Compress)" }
        Start-Sleep -Milliseconds 35
    }
    throw "Timed out waiting for $Wanted"
}
function Finish-StableWorker {
    param($Case, $Process)
    try { Assert-Stable ($Process.WaitForExit(20000)) 'worker exits at a safe boundary'; $Process.Refresh(); Assert-Stable ($Process.ExitCode -eq 0) 'worker exits cleanly'; return Read-LingoJson $Case.Status -ThrowOnError }
    finally { if (-not $Process.HasExited) { $Process.Kill() }; $Process.Dispose() }
}

try {
    & $compiler /nologo /target:exe /reference:System.Web.Extensions.dll "/out:$fake" (Join-Path $PSScriptRoot 'FakeResumableExtractor.cs')
    Assert-Stable ($LASTEXITCODE -eq 0) 'resumable test extractor compiles'
    [IO.File]::Copy($fake,$probe)
    [IO.File]::Copy($fake,(Join-Path $testRoot 'ffmpeg.exe'))

    $case = New-StableCase 'manual-pause' '' -Playlist
    $process = Start-StableWorker $case
    $before = Wait-StableStatus $case 'progress' $process
    [void](Write-LingoJson $case.Control @{action='pause'})
    $paused = Finish-StableWorker $case $process
    Assert-Stable ($paused.status -eq 'paused' -and @($paused.items).Count -eq 2 -and $paused.items[1].status -eq 'queued') 'pause preserves current and unvisited playlist entries'
    $partial = @(Get-ChildItem -LiteralPath $case.Destination -Filter '*.part' -Recurse -Force)
    Assert-Stable ($partial.Count -eq 1 -and $partial[0].Length -ge 3000 -and $partial[0].Length -lt 12000) 'pause retains actual partial file bytes'
    $offset = $partial[0].Length
    Remove-Item -LiteralPath $case.Control
    $process = Start-StableWorker $case
    $done = Finish-StableWorker $case $process
    Assert-Stable ($done.status -eq 'completed' -and $done.completed -eq 2 -and @($done.items).Count -eq 2) 'resume uses same task and completes the remaining playlist'
    $calls = [IO.File]::ReadAllLines($case.Log)
    Assert-Stable (@($calls | Where-Object { $_ -like "DOWNLOAD|*stability-001*|START=$offset" }).Count -eq 1) 'resume starts at saved byte offset instead of zero'
    Assert-Stable (@(Get-ChildItem -LiteralPath $case.Destination -File -Filter '*.mkv').Count -eq 2) 'resume publishes exactly one final file per video'

    $case = New-StableCase 'automatic-reconnect' 'network-once'
    $process = Start-StableWorker $case
    $waiting = Wait-StableStatus $case 'waiting_network' $process
    Assert-Stable ($waiting.retryCount -eq 1 -and $waiting.retryAt -and $waiting.failed -eq 0) 'network failure waits with bounded backoff without becoming terminal failure'
    $done = Finish-StableWorker $case $process
    Assert-Stable ($done.status -eq 'completed' -and @([IO.File]::ReadAllLines($case.Log) | Where-Object { $_ -like 'DOWNLOAD|*|START=3000' }).Count -eq 1) 'automatic reconnect reuses existing bytes and completes'

    $case = New-StableCase 'pause-network-wait' 'always-network'
    $process = Start-StableWorker $case
    [void](Wait-StableStatus $case 'waiting_network' $process)
    [void](Write-LingoJson $case.Control @{action='pause'})
    $paused = Finish-StableWorker $case $process
    $callsBefore = @([IO.File]::ReadAllLines($case.Log)).Count
    Start-Sleep -Milliseconds 300
    Assert-Stable ($paused.status -eq 'paused' -and $paused.failed -eq 0 -and @([IO.File]::ReadAllLines($case.Log)).Count -eq $callsBefore) 'manual pause during reconnect prevents automatic restart'

    $case = New-StableCase 'processing-pause' 'merge-pause' -Audio
    $process = Start-StableWorker $case
    [void](Wait-StableStatus $case 'processing' $process)
    $downloadsBeforePause = @([IO.File]::ReadAllLines($case.Log) | Where-Object { $_ -like 'DOWNLOAD|*' }).Count
    [void](Write-LingoJson $case.Control @{action='pause'})
    $paused = Finish-StableWorker $case $process
    Assert-Stable ($paused.status -eq 'paused' -and @($paused.items[0].assets | Where-Object { $_.type -eq 'video' -and $_.status -eq 'completed' }).Count -eq 1) 'pause during processing waits for validated video to be published'
    Assert-Stable (@([IO.File]::ReadAllLines($case.Log) | Where-Object { $_ -like 'DOWNLOAD|*' }).Count -eq $downloadsBeforePause -and @($paused.items[0].assets | Where-Object { $_.type -eq 'audio' -and $_.status -eq 'completed' }).Count -eq 0) 'pause prevents the next asset starting after processing'

    $case = New-StableCase 'source-retry' 'source-fail-once'
    $process = Start-StableWorker $case; $failed = Finish-StableWorker $case $process
    Assert-Stable ($failed.status -eq 'failed' -and -not $failed.items[0].id) 'source failure is recorded before a media id is available'
    $process = Start-StableWorker $case; $done = Finish-StableWorker $case $process
    Assert-Stable ($done.status -eq 'completed' -and @($done.items).Count -eq 1 -and $done.failed -eq 0) 'successful source retry removes stale source failure placeholder'

    $case = New-StableCase 'missing-track' '' -Audio
    $config = Read-LingoJson $case.Config -ThrowOnError
    $config.parts.subtitles = $true
    $config.sourceSelections = @{ $case.Url = @{ mediaId='arte-acceptance-001'; explicitAudio=$true; audioFormatIds=@('audio-fr-original'); explicitSubtitles=$true; subtitleTracks=@(@{source='provided';rawKey='zz-missing'}) } }
    [void](Write-LingoJson $case.Config $config)
    $process = Start-StableWorker $case; $done = Finish-StableWorker $case $process
    Assert-Stable ($done.status -eq 'completed' -and @($done.items[0].assets | Where-Object status -eq 'completed').Count -eq 2 -and @($done.items[0].assets | Where-Object status -eq 'skipped').Count -eq 1) 'missing subtitle is skipped while complete video and existing audio are kept'
    Assert-Stable ($done.items[0].sourceUrl -eq $case.Url -and -not $done.items[0].error) 'skipped missing resources retain source mapping and are not failures'

    $case = New-StableCase 'legacy-pause' ''
    $config = Read-LingoJson $case.Config -ThrowOnError
    Set-LingoObjectField $config 'mode' 'video'
    Set-LingoObjectField $config 'archivePath' (Join-Path $case.Root 'archive.txt')
    $config.subtitleLanguages = @()
    [void](Write-LingoJson $case.Config $config)
    $status = Read-LingoJson $case.Status -ThrowOnError; Set-LingoObjectField $status 'skipped' 0; [void](Write-LingoJson $case.Status $status)
    $process = Start-StableWorker $case -Legacy
    [void](Wait-StableStatus $case 'progress' $process)
    [void](Write-LingoJson $case.Control @{action='pause'})
    $paused = Finish-StableWorker $case $process
    Assert-Stable ($paused.status -eq 'paused') 'legacy worker also cooperates with manual pause'
    $legacyParts = @(Get-ChildItem -LiteralPath $case.Destination -File -Filter 'media.part' -Recurse -Force)
    Assert-Stable ($legacyParts.Count -eq 1) 'legacy partial bytes stay in its isolated task directory'
    $part = $legacyParts[0]
    $offset = $part.Length
    Remove-Item -LiteralPath $case.Control
    $process = Start-StableWorker $case -Legacy; $done = Finish-StableWorker $case $process
    Assert-Stable ($done.status -eq 'completed' -and @($done.items).Count -eq 1 -and @([IO.File]::ReadAllLines($case.Log) | Where-Object { $_ -like "DOWNLOAD|*|START=$offset" }).Count -eq 1) 'legacy resume retains same item and reuses actual partial bytes'

    $case = New-StableCase 'changed-checkpoint' ''
    $process = Start-StableWorker $case
    [void](Wait-StableStatus $case 'progress' $process)
    [void](Write-LingoJson $case.Control @{action='pause'})
    $paused = Finish-StableWorker $case $process
    $originalPart = @(Get-ChildItem -LiteralPath $case.Destination -Filter '*.part' -Recurse -Force)[0]
    $originalBytes = $originalPart.Length
    $changedFixture = Join-Path $case.Root 'changed-fixture.json'
    $fixture = Read-LingoJson $env:LINGO_STABILITY_FIXTURE -ThrowOnError
    Set-LingoObjectField (@($fixture.formats | Where-Object format_id -eq 'video-720')[0]) 'filesize' 22222
    foreach($cache in @(Get-ChildItem -LiteralPath (Join-Path $case.Root 'metadata-cache') -Filter '*.json' -ErrorAction SilentlyContinue)) { $saved=Read-LingoJson $cache.FullName -ThrowOnError; $saved.fetchedAt=[DateTime]::UtcNow.AddMinutes(-10).ToString('o'); [void](Write-LingoJson $cache.FullName $saved -Depth 60) }
    [void](Write-LingoJson $changedFixture $fixture)
    $env:LINGO_STABILITY_FIXTURE = $changedFixture
    Remove-Item -LiteralPath $case.Control
    $process = Start-StableWorker $case; $done = Finish-StableWorker $case $process
    Assert-Stable ($done.status -eq 'completed' -and $done.items[0].assets[0].recoveryMessage -and [IO.File]::Exists($originalPart.FullName) -and (Get-Item -LiteralPath $originalPart.FullName).Length -eq $originalBytes) 'changed known media metadata restarts only the current asset and preserves its previous checkpoint'
    Assert-Stable (@([IO.File]::ReadAllLines($case.Log) | Where-Object { $_ -like 'DOWNLOAD|*|video|video-720|START=0' }).Count -eq 2) 'incompatible byte checkpoint is never appended to a changed resource'
    $env:LINGO_STABILITY_FIXTURE = Join-Path $PSScriptRoot 'fixtures\acceptance-media.json'
    Write-Host "Download stability acceptance passed: $script:count assertions."
} finally {
    foreach($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name]) }
    if ($KeepArtifacts) { Write-Host "Artifacts: $testRoot" }
    else { $resolved=[IO.Path]::GetFullPath($testRoot); $allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'; if ($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force } }
}

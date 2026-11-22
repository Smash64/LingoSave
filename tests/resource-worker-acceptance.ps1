param([switch]$KeepArtifacts, [switch]$OnlyRetry)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not [IO.File]::Exists($compiler)) { throw 'C# test compiler is unavailable.' }
$testRoot = Join-Path $env:TEMP ('lingosave-resource-acceptance-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$fakePath = Join-Path $testRoot 'fake-yt-dlp.exe'
$probePath = Join-Path $testRoot 'ffprobe.exe'
$fixturePath = Join-Path $PSScriptRoot 'fixtures\acceptance-media.json'
$script:assertions = 0
$oldFixture = $env:LINGOSAVE_FAKE_RESOURCE_FIXTURE
$oldLog = $env:LINGOSAVE_FAKE_RESOURCE_LOG
$oldFail = $env:LINGOSAVE_FAKE_FAIL_ONCE
$env:LINGOSAVE_FAKE_RESOURCE_FIXTURE = $fixturePath
$env:LINGOSAVE_FAKE_RESOURCE_LOG = Join-Path $testRoot 'calls.log'

function Assert-Acceptance {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Resource worker acceptance failed: $Message" }
    $script:assertions++
    Write-Host "PASS $Message"
}

function New-WorkerCase {
    param([string]$Name, [string[]]$Urls, $Parts, $Selections, [string[]]$AudioLanguages = @('fr', 'de'), [string[]]$SubtitleLanguages = @('fr'))
    $caseRoot = Join-Path $testRoot $Name
    $destination = Join-Path $caseRoot 'Chinese 中文 media'
    [void][IO.Directory]::CreateDirectory($destination)
    $id = [guid]::NewGuid().ToString('N')
    $statusPath = Join-Path $caseRoot "$id.status.json"
    $configPath = Join-Path $caseRoot "$id.config.json"
    $status = @{ id = $id; status = 'queued'; path = $destination; urls = @($Urls); sourceCount = $Urls.Count; total = $null; completed = 0; failed = 0; skipped = 0; items = @(); message = 'queued'; error = $null; progress = $null; speedBytesPerSecond = $null; downloadedBytes = $null; totalBytes = $null; etaSeconds = $null; currentAsset = $null; currentTitle = $null }
    $config = @{ id = $id; urls = @($Urls); path = $destination; mode = 'resources'; parts = $Parts; audioLanguages = @($AudioLanguages); subtitleLanguages = @($SubtitleLanguages); autoSimplify = $false; sourceSelections = $Selections; quality = '720p'; container = 'mkv'; subtitleFormat = 'srt'; ytDlpPath = $fakePath; ffmpegDirectory = $testRoot; ffprobePath = $probePath; denoPath = $null; storeRoot = $caseRoot; statusPath = $statusPath; archivePath = (Join-Path $caseRoot "$id.archive.txt"); cookieRevisions = @{} }
    [IO.File]::WriteAllText($statusPath, (ConvertTo-Json -InputObject $status -Depth 15 -Compress), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($configPath, (ConvertTo-Json -InputObject $config -Depth 15 -Compress), [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Name = $Name; Root = $caseRoot; Destination = $destination; Id = $id; StatusPath = $statusPath; ConfigPath = $configPath }
}

function Invoke-Worker {
    param($Case)
    $powershellPath = Join-Path $PSHOME 'powershell.exe'
    $workerPath = Join-Path $root 'resource-worker.ps1'
    $process = Start-Process -FilePath $powershellPath -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$workerPath`"", '-ConfigPath', "`"$($Case.ConfigPath)`"") -PassThru -WindowStyle Hidden
    $sawProgress = $false
    try {
        for ($attempt = 0; $attempt -lt 180; $attempt++) {
            if ($process.HasExited) { break }
            try {
                $interim = Get-Content -LiteralPath $Case.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($interim.currentAsset -in @('video', 'audio', 'subtitle') -and $interim.progress -gt 0 -and $interim.speedBytesPerSecond -gt 0 -and $interim.downloadedBytes -gt 0) { $sawProgress = $true }
            } catch { }
            Start-Sleep -Milliseconds 80
        }
        Assert-Acceptance ($process.WaitForExit(10000)) "$($Case.Name) worker exits"
        $process.Refresh()
        Assert-Acceptance ($process.ExitCode -eq 0) "$($Case.Name) worker exit code is zero"
        return [pscustomobject]@{ Status = (Get-Content -LiteralPath $Case.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json); SawProgress = $sawProgress }
    } finally {
        if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(3000) }
        $process.Dispose()
    }
}

try {
    $sourcePath = Join-Path $testRoot 'FakeResourceExtractor.cs'
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FakeResourceExtractor.cs'), [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($sourcePath, $source, [Text.UTF8Encoding]::new($false))
    & $compiler /nologo /target:exe /reference:System.Web.Extensions.dll "/out:$fakePath" $sourcePath
    Assert-Acceptance ($LASTEXITCODE -eq 0 -and [IO.File]::Exists($fakePath)) 'fake extractor compiles'
    [IO.File]::Copy($fakePath, $probePath)
    [IO.File]::Copy($fakePath, (Join-Path $testRoot 'ffmpeg.exe'))

    $url = 'https://www.arte.tv/en/videos/acceptance-001/'
    $selection = @{ mediaId = 'arte-acceptance-001'; audioFormatIds = @('audio-fr-original', 'audio-de-dub'); subtitleTracks = @(@{ rawKey = 'fr'; source = 'provided' }, @{ rawKey = 'fr-acc'; source = 'provided' }, @{ rawKey = 'fr'; source = 'auto' }); explicitAudio = $true; explicitSubtitles = $true }
    $selections = @{}; $selections[$url] = $selection
    if (-not $OnlyRetry) {
    $full = New-WorkerCase -Name 'full' -Urls @($url) -Parts @{ video = $true; audio = $true; subtitles = $true } -Selections $selections
    $first = Invoke-Worker $full
    $assets = @($first.Status.items[0].assets)
    Assert-Acceptance ($first.Status.status -eq 'completed' -and $assets.Count -eq 6 -and @($assets | Where-Object status -ne 'completed').Count -eq 0) 'full video, two audio tracks and three subtitles complete independently'
    Assert-Acceptance ($first.SawProgress) 'download reports percent, speed and bytes while running'
    Assert-Acceptance (@($assets | Where-Object { -not [IO.File]::Exists([string]$_.path) }).Count -eq 0) 'all six asset files exist in selected folder'
    Assert-Acceptance (@($assets | Where-Object type -eq 'audio' | ForEach-Object trackId) -contains 'audio-de-dub') 'precise German audio format is preserved'
    Assert-Acceptance (@($assets | Where-Object { $_.type -eq 'subtitle' -and $_.source -eq 'auto' }).Count -eq 1) 'automatic caption remains separate from provided caption'

    foreach ($part in @('video', 'audio', 'subtitles')) {
        $parts = @{ video = ($part -eq 'video'); audio = ($part -eq 'audio'); subtitles = ($part -eq 'subtitles') }
        $case = New-WorkerCase -Name "only-$part" -Urls @($url) -Parts $parts -Selections $selections
        $outcome = Invoke-Worker $case
        $wanted = if ($part -eq 'subtitles') { 'subtitle' } else { $part }
        Assert-Acceptance ($outcome.Status.status -eq 'completed' -and @($outcome.Status.items[0].assets | Where-Object type -ne $wanted).Count -eq 0) "$part alone produces only its requested asset type"
    }

    $playlistUrl = 'https://www.arte.tv/en/videos/playlist-acceptance/'
    $playlist = New-WorkerCase -Name 'playlist' -Urls @($playlistUrl) -Parts @{ video = $true; audio = $false; subtitles = $false } -Selections @{}
    $playlistOutcome = Invoke-Worker $playlist
    Assert-Acceptance ($playlistOutcome.Status.status -eq 'completed' -and $playlistOutcome.Status.total -eq 2 -and @($playlistOutcome.Status.items).Count -eq 2) 'playlist expands and downloads every entry'
    }

    $retrySelection = @{}; $retrySelection[$url] = $selection
    $retry = New-WorkerCase -Name 'retry' -Urls @($url) -Parts @{ video = $true; audio = $true; subtitles = $false } -Selections $retrySelection
    $env:LINGOSAVE_FAKE_FAIL_ONCE = Join-Path $retry.Root 'failed-once.marker'
    $failed = Invoke-Worker $retry
    Assert-Acceptance ($failed.Status.status -eq 'partial' -and @($failed.Status.items[0].assets | Where-Object status -eq 'failed').Count -eq 1 -and @($failed.Status.items[0].assets | Where-Object status -eq 'completed').Count -eq 2) 'one failed audio asset leaves successful video and audio intact'
    $callsBefore = @([IO.File]::ReadAllLines($env:LINGOSAVE_FAKE_RESOURCE_LOG) | Where-Object { $_ -like 'download|*' }).Count
    $succeeded = Invoke-Worker $retry
    $callsAfter = @([IO.File]::ReadAllLines($env:LINGOSAVE_FAKE_RESOURCE_LOG) | Where-Object { $_ -like 'download|*' }).Count
    if ($succeeded.Status.status -ne 'completed' -or $callsAfter -ne ($callsBefore + 1)) {
        Write-Host "Retry diagnostic: status=$($succeeded.Status.status), callsBefore=$callsBefore, callsAfter=$callsAfter"
        Get-Content -LiteralPath $env:LINGOSAVE_FAKE_RESOURCE_LOG -Encoding UTF8 | Select-Object -Last 8 | Write-Host
    }
    Assert-Acceptance ($succeeded.Status.status -eq 'completed' -and $callsAfter -eq ($callsBefore + 1)) 'retry downloads only the previously failed asset'
    Write-Host "Resource worker acceptance passed: $script:assertions assertions with isolated synthetic artifacts."
} finally {
    $env:LINGOSAVE_FAKE_RESOURCE_FIXTURE = $oldFixture
    $env:LINGOSAVE_FAKE_RESOURCE_LOG = $oldLog
    $env:LINGOSAVE_FAKE_FAIL_ONCE = $oldFail
    if ($KeepArtifacts) { Write-Host "Artifacts: $testRoot" }
    else {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        $allowed = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $env:TEMP ('lingosave-real-resume-' + [guid]::NewGuid().ToString('N'))
$mediaRoot = Join-Path $testRoot 'media'
$downloadRoot = Join-Path $testRoot 'downloads'
$ffmpegRoot = 'E:\ffmpeg\bin'
$ytDlp = Join-Path $projectRoot 'tools\yt-dlp.exe'
$ffmpeg = Join-Path $ffmpegRoot 'ffmpeg.exe'
$ffprobe = Join-Path $ffmpegRoot 'ffprobe.exe'
$script:httpFixture = $null
$script:activeDownload = $null
$script:assertions = 0
[void][IO.Directory]::CreateDirectory($mediaRoot)
[void][IO.Directory]::CreateDirectory($downloadRoot)

function Assert-Resume {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:assertions++
    Write-Host "PASS: $Message"
}

function Quote-TestArgument {
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Start-TestProcess {
    param([string]$Executable, [string[]]$Arguments)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.Arguments = (@($Arguments | ForEach-Object { Quote-TestArgument $_ }) -join ' ')
    $start.WorkingDirectory = $testRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    return @{ process = $process; stdout = $process.StandardOutput.ReadToEndAsync(); stderr = $process.StandardError.ReadToEndAsync() }
}

function Stop-OwnedProcess {
    param($Handle)
    if (-not $Handle) { return }
    $process = $Handle.process
    if (-not $process.HasExited) {
        # This PID was just created by this test. Kill its download subprocesses too.
        & (Join-Path $env:WINDIR 'System32\taskkill.exe') /PID $process.Id /T /F *> $null
        if (-not $process.WaitForExit(8000)) { throw 'Test process did not stop.' }
    }
    $process.WaitForExit()
    $process.Dispose()
}

function Finish-TestProcess {
    param($Handle, [int]$TimeoutSeconds = 50)
    if (-not $Handle.process.WaitForExit($TimeoutSeconds * 1000)) { throw 'Local download did not finish before timeout.' }
    $Handle.process.WaitForExit()
    $result = @{ code = $Handle.process.ExitCode; stdout = $Handle.stdout.Result; stderr = $Handle.stderr.Result }
    $Handle.process.Dispose()
    return $result
}

function Start-LocalDownload {
    param([string]$Url, [string]$Output, [string[]]$Extra = @())
    $arguments = @('--ignore-config', '--no-cache-dir', '--proxy', '', '--no-playlist', '--continue', '--part', '--no-overwrites', '--newline', '--no-progress', '--ffmpeg-location', $ffmpegRoot, '-o', $Output) + $Extra + @($Url)
    return Start-TestProcess $ytDlp $arguments
}

function Get-MediaProbe {
    param([string]$Path)
    $probe = Start-TestProcess $ffprobe @('-v', 'error', '-show_entries', 'stream=codec_type:format=duration', '-of', 'json', $Path)
    $result = Finish-TestProcess $probe
    if ($result.code -ne 0) { throw "ffprobe failed: $($result.stderr)" }
    return ConvertFrom-Json -InputObject $result.stdout
}

try {
    foreach ($required in @($ytDlp, $ffmpeg, $ffprobe)) { if (-not [IO.File]::Exists($required)) { throw "Missing actual media tool: $required" } }
    $sourcePath = Join-Path $mediaRoot 'source.mp4'
    $generate = Start-TestProcess $ffmpeg @('-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '20', '-c:v', 'libx264', '-preset', 'ultrafast', '-b:v', '2M', '-g', '60', '-keyint_min', '60', '-sc_threshold', '0', '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart', $sourcePath)
    $generated = Finish-TestProcess $generate
    Assert-Resume ($generated.code -eq 0 -and (Get-Item -LiteralPath $sourcePath).Length -gt 1000000) 'real FFmpeg creates a video with sufficient data for interruption'
    $hlsRoot = Join-Path $mediaRoot 'hls'
    [void][IO.Directory]::CreateDirectory($hlsRoot)
    $hlsGenerate = Start-TestProcess $ffmpeg @('-hide_banner', '-loglevel', 'error', '-y', '-i', $sourcePath, '-c', 'copy', '-f', 'hls', '-hls_time', '2', '-hls_playlist_type', 'vod', '-hls_segment_filename', (Join-Path $hlsRoot 'seg%03d.ts'), (Join-Path $hlsRoot 'index.m3u8'))
    $hlsGenerated = Finish-TestProcess $hlsGenerate
    Assert-Resume ($hlsGenerated.code -eq 0 -and @(Get-ChildItem -LiteralPath $hlsRoot -Filter '*.ts').Count -ge 8) 'real FFmpeg creates a complete HLS fragment fixture'
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $fixtureExe = Join-Path $testRoot 'local-resume-server.exe'
    & $compiler /nologo /target:exe "/out:$fixtureExe" (Join-Path $PSScriptRoot 'LocalResumeServer.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot build localhost HTTP fixture.' }
    $logPath = Join-Path $testRoot 'http-requests.log'
    $portPath = Join-Path $testRoot 'http-port.txt'
    $script:httpFixture = Start-TestProcess $fixtureExe @($mediaRoot, $logPath, $portPath)
    for ($attempt = 0; $attempt -lt 50 -and -not [IO.File]::Exists($portPath); $attempt++) { Start-Sleep -Milliseconds 100 }
    $port = [int][IO.File]::ReadAllText($portPath)
    $rangeOutput = Join-Path $downloadRoot 'range.mp4'
    $script:activeDownload = Start-LocalDownload "http://127.0.0.1:$port/range.mp4" $rangeOutput
    $rangePart = "$rangeOutput.part"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 25) {
        if ([IO.File]::Exists($rangePart) -and (Get-Item -LiteralPath $rangePart).Length -ge 262144) { break }
        if ($script:activeDownload.process.HasExited) { throw "Range fixture ended too early: $($script:activeDownload.stderr.Result)" }
        Start-Sleep -Milliseconds 60
    }
    Assert-Resume ([IO.File]::Exists($rangePart) -and (Get-Item -LiteralPath $rangePart).Length -gt 0 -and (Get-Item -LiteralPath $rangePart).Length -lt (Get-Item -LiteralPath $sourcePath).Length) 'real yt-dlp writes a partial file before interruption'
    Stop-OwnedProcess $script:activeDownload
    $script:activeDownload = $null
    $rangeOffset = (Get-Item -LiteralPath $rangePart).Length
    $beforeLog = [IO.File]::ReadAllLines($logPath).Count
    $script:activeDownload = Start-LocalDownload "http://127.0.0.1:$port/range.mp4" $rangeOutput
    $rangeResult = Finish-TestProcess $script:activeDownload
    $script:activeDownload = $null
    Assert-Resume ($rangeResult.code -eq 0 -and [IO.File]::Exists($rangeOutput)) "real yt-dlp resumes and publishes complete video (retained $rangeOffset bytes)"
    $resumedRequests = @([IO.File]::ReadAllLines($logPath) | Select-Object -Skip $beforeLog)
    $positiveRange = @($resumedRequests | Where-Object { $_ -match '^REQUEST GET /range\.mp4 status=206 start=([1-9][0-9]*)$' })
    Assert-Resume ($positiveRange.Count -gt 0) 'HTTP log confirms resumed request uses a positive Range offset'
    Assert-Resume ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $rangeOutput -Algorithm SHA256).Hash) 'resumed Range output SHA256 is identical to original source'
    $probe = Get-MediaProbe $rangeOutput
    Assert-Resume (@($probe.streams | Where-Object { $_.codec_type -eq 'video' }).Count -gt 0 -and @($probe.streams | Where-Object { $_.codec_type -eq 'audio' }).Count -gt 0) 'ffprobe verifies Range output contains both video and audio'

    $hlsOutput = Join-Path $downloadRoot 'hls.mp4'
    $script:activeDownload = Start-LocalDownload "http://127.0.0.1:$port/hls/index.m3u8" $hlsOutput @('--hls-prefer-native', '--concurrent-fragments', '4', '--abort-on-unavailable-fragments')
    $hlsCheckpoint = "$hlsOutput.ytdl"
    $fragmentIndex = -1
    $timer.Restart()
    while ($timer.Elapsed.TotalSeconds -lt 30) {
        if ([IO.File]::Exists($hlsCheckpoint)) {
            try { $checkpoint = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($hlsCheckpoint)); $fragmentIndex = [int]$checkpoint.downloader.current_fragment.index } catch { }
            if ($fragmentIndex -ge 2) { break }
        }
        if ($script:activeDownload.process.HasExited) { throw "HLS fixture ended too early: $($script:activeDownload.stderr.Result)" }
        Start-Sleep -Milliseconds 60
    }
    Assert-Resume ($fragmentIndex -ge 2 -and [IO.File]::Exists("$hlsOutput.part")) 'native HLS downloader persists completed fragment checkpoint before interruption'
    Stop-OwnedProcess $script:activeDownload
    $script:activeDownload = $null
    $checkpoint = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($hlsCheckpoint))
    $fragmentIndex = [int]$checkpoint.downloader.current_fragment.index
    $beforeLog = [IO.File]::ReadAllLines($logPath).Count
    $script:activeDownload = Start-LocalDownload "http://127.0.0.1:$port/hls/index.m3u8" $hlsOutput @('--hls-prefer-native', '--concurrent-fragments', '4', '--abort-on-unavailable-fragments')
    $hlsResult = Finish-TestProcess $script:activeDownload
    $script:activeDownload = $null
    Assert-Resume ($hlsResult.code -eq 0 -and [IO.File]::Exists($hlsOutput)) "native HLS resumes from completed fragment index $fragmentIndex"
    $resumedRequests = @([IO.File]::ReadAllLines($logPath) | Select-Object -Skip $beforeLog)
    $repeatedComplete = @($resumedRequests | Where-Object { $_ -match '^REQUEST GET /hls/seg([0-9]+)\.ts ' -and [int]$Matches[1] -lt $fragmentIndex })
    Assert-Resume ($repeatedComplete.Count -eq 0) 'HLS resume does not request already completed fragments again'
    $probe = Get-MediaProbe $hlsOutput
    Assert-Resume (@($probe.streams | Where-Object { $_.codec_type -eq 'video' }).Count -gt 0 -and @($probe.streams | Where-Object { $_.codec_type -eq 'audio' }).Count -gt 0 -and [double]$probe.format.duration -ge 19) 'ffprobe verifies resumed HLS contains video, audio and full duration'

    $brokenOutput = Join-Path $downloadRoot 'broken.mp4'
    $script:activeDownload = Start-LocalDownload "http://127.0.0.1:$port/broken/index.m3u8" $brokenOutput @('--hls-prefer-native', '--concurrent-fragments', '4', '--abort-on-unavailable-fragments', '--fragment-retries', '0', '--retries', '0')
    $brokenResult = Finish-TestProcess $script:activeDownload
    $script:activeDownload = $null
    Assert-Resume ($brokenResult.code -ne 0 -and -not [IO.File]::Exists($brokenOutput) -and $brokenResult.stderr -match 'fragment|404') 'missing required HLS fragment fails without publishing incomplete final video'
    Write-Host "PASS: $script:assertions actual yt-dlp / FFmpeg protocol assertions using localhost only."
    Write-Host "Range checkpoint bytes: $rangeOffset; HLS completed fragment index: $fragmentIndex."
} finally {
    if ($script:activeDownload) { try { Stop-OwnedProcess $script:activeDownload } catch { Write-Warning $_.Exception.Message } }
    if ($script:httpFixture) { try { Stop-OwnedProcess $script:httpFixture } catch { Write-Warning $_.Exception.Message } }
    $fullTest = [IO.Path]::GetFullPath($testRoot)
    $fullTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($fullTest.StartsWith($fullTemp, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($fullTest).StartsWith('lingosave-real-resume-')) { Remove-Item -LiteralPath $fullTest -Recurse -Force -ErrorAction SilentlyContinue }
    else { throw "Unsafe cleanup target: $fullTest" }
}

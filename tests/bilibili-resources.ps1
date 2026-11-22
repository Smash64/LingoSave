param([switch]$KeepArtifacts)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'state-io.ps1')
$testRoot = Join-Path $env:TEMP ('lingosave-bili-resources-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$realYt = Join-Path $root 'tools\yt-dlp.exe'
$ffmpegDir = 'E:\ffmpeg\bin'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$saved = @{}
foreach ($name in @('LINGO_BILI_FIXTURE', 'LINGO_BILI_REAL_YT')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$processes = [Collections.Generic.List[object]]::new()
$script:assertions = 0
function Assert-Resource {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:assertions++
    Write-Host "PASS $Message"
}
function New-Case {
    param([string]$Name, [string]$Destination, [bool]$Audio, [bool]$Subs, [string[]]$SubtitleLanguages = @('fr'), $Selections = @{})
    [void][IO.Directory]::CreateDirectory($Destination)
    $caseRoot = Join-Path $testRoot $Name; [void][IO.Directory]::CreateDirectory($caseRoot)
    $id = [guid]::NewGuid().ToString('N')
    $statusPath = Join-Path $caseRoot "$id.status.json"
    $configPath = Join-Path $caseRoot "$id.config.json"
    $url = 'https://www.bilibili.com/video/BVfixture/'
    [void](Write-LingoJson $statusPath @{ id=$id; status='queued'; path=$Destination; urls=@($url); items=@(); total=$null; completed=0; failed=0; skipped=0; currentTitle=$null; currentAsset=$null; message=$null; error=$null; progress=$null; speedBytesPerSecond=$null; downloadedBytes=$null; totalBytes=$null; etaSeconds=$null })
    [void](Write-LingoJson $configPath @{ id=$id; urls=@($url); path=$Destination; parts=@{ video=$false; audio=$Audio; subtitles=$Subs }; audioLanguages=@('fr'); subtitleLanguages=@($SubtitleLanguages); sourceSelections=$Selections; quality='best'; container='mkv'; subtitleFormat='srt'; ytDlpPath=(Join-Path $testRoot 'bili-fixture.exe'); ffmpegDirectory=$ffmpegDir; ffprobePath=(Join-Path $ffmpegDir 'ffprobe.exe'); denoPath=$null; storeRoot=$caseRoot; statusPath=$statusPath; cookieRevisions=@{} })
    return @{ Config=$configPath; Status=$statusPath; Destination=$Destination }
}
function Start-Case {
    param($Case)
    $worker = Join-Path $root 'resource-worker.ps1'
    $proc = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File', ('"'+$worker+'"'),'-ConfigPath',('"'+$Case.Config+'"')) -WindowStyle Hidden -PassThru
    $processes.Add($proc)
    return $proc
}
function Finish-Case {
    param($Case, $Process)
    Assert-Resource ($Process.WaitForExit(25000)) 'production resource worker finishes within timeout'
    $Process.Refresh()
    Assert-Resource ($Process.ExitCode -eq 0) 'production resource worker exits cleanly'
    $status = Read-LingoJson $Case.Status -ThrowOnError
    if ($status.status -eq 'failed') { throw "Worker failed: $($status.error)" }
    return $status
}
try {
    Assert-Resource ([IO.File]::Exists($realYt) -and [IO.File]::Exists((Join-Path $ffmpegDir 'ffprobe.exe'))) 'real yt-dlp and ffprobe are available'
    $audioPath = Join-Path $testRoot 'tone.wav'
    & (Join-Path $ffmpegDir 'ffmpeg.exe') -hide_banner -loglevel error -f lavfi -i 'sine=frequency=440:duration=1' -y $audioPath
    Assert-Resource ($LASTEXITCODE -eq 0) 'local audio fixture is valid media'
    $frSubtitle = "1`n00:00:00,000 --> 00:00:00,800`nProvided French`n"
    $urlSubtitle = Join-Path $testRoot 'automatic.fr.srt'
    [IO.File]::WriteAllText($urlSubtitle, "1`n00:00:00,000 --> 00:00:00,800`nAutomatic French`n", [Text.UTF8Encoding]::new($false))
    $fixture = @{ id='BVfixture'; title='Lesson'; extractor='BiliBili'; extractor_key='BiliBili'; webpage_url='https://www.bilibili.com/video/BVfixture/'; duration=1; formats=@(@{ format_id='30280'; url=([Uri]$audioPath).AbsoluteUri; ext='wav'; vcodec='none'; acodec='pcm_s16le'; abr=192 }); subtitles=@{ fr=@(@{ ext='srt'; data=$frSubtitle }); danmaku=@(@{ ext='xml'; data='<i></i>' }) }; automatic_captions=@{ fr=@(@{ ext='srt'; url=([Uri]$urlSubtitle).AbsoluteUri }) } }
    $fixturePath = Join-Path $testRoot 'bili.json'
    [void](Write-LingoJson $fixturePath $fixture -Depth 15)
    $env:LINGO_BILI_FIXTURE=$fixturePath; $env:LINGO_BILI_REAL_YT=$realYt
    $source = @'
using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Diagnostics;
using System.Collections.Generic;
public static class BiliFixture {
    static string Quote(string value) {
        if (value.Length > 0 && value.All(c => !Char.IsWhiteSpace(c) && c != '"')) return value;
        StringBuilder s = new StringBuilder("\""); int n = 0;
        foreach (char c in value) { if (c == '\\') { n++; continue; } if (c == '"') { s.Append('\\', n * 2 + 1); s.Append(c); n=0; continue; } s.Append('\\',n); n=0; s.Append(c); }
        s.Append('\\',n*2); s.Append('"'); return s.ToString();
    }
    public static int Main(string[] args) {
        Console.OutputEncoding = new UTF8Encoding(false);
        string fixture = Environment.GetEnvironmentVariable("LINGO_BILI_FIXTURE");
        if (args.Contains("--dump-single-json") && !args.Contains("--load-info-json")) {
            if (!args.Contains("--simulate") || !args.Contains("--write-subs") || !args.Contains("--write-auto-subs")) { Console.Error.WriteLine("ERROR: metadata must request Bilibili subtitles in simulation mode"); return 9; }
            Console.WriteLine(File.ReadAllText(fixture, Encoding.UTF8)); return 0;
        }
        List<string> forwarded = args.Contains("--load-info-json") ? args.ToList() : args.Take(args.Length - 1).ToList();
        forwarded.Add("--enable-file-urls"); forwarded.Add("--proxy"); forwarded.Add("");
        if (!args.Contains("--load-info-json")) { forwarded.Add("--load-info-json"); forwarded.Add(fixture); }
        ProcessStartInfo start = new ProcessStartInfo(Environment.GetEnvironmentVariable("LINGO_BILI_REAL_YT"), String.Join(" ", forwarded.Select(Quote)));
        start.UseShellExecute=false; start.CreateNoWindow=true; start.RedirectStandardOutput=true; start.RedirectStandardError=true;
        start.StandardOutputEncoding=Encoding.UTF8; start.StandardErrorEncoding=Encoding.UTF8;
        using (Process process = Process.Start(start)) {
            var output=process.StandardOutput.ReadToEndAsync(); var errors=process.StandardError.ReadToEndAsync();
            process.WaitForExit(); Console.Write(output.Result); Console.Error.Write(errors.Result); return process.ExitCode;
        }
    }
}
'@
    $sourcePath=Join-Path $testRoot 'BiliFixture.cs'; [IO.File]::WriteAllText($sourcePath,$source,[Text.UTF8Encoding]::new($false))
    & $compiler /nologo /target:exe ('/out:'+(Join-Path $testRoot 'bili-fixture.exe')) $sourcePath
    Assert-Resource ($LASTEXITCODE -eq 0) 'metadata fixture adapter compiles'
    $inspection = & (Join-Path $root 'media-inspection.ps1') -Url 'https://www.bilibili.com/video/BVfixture/' -YtDlpPath (Join-Path $testRoot 'bili-fixture.exe') | ConvertFrom-Json
    Assert-Resource (@($inspection.subtitles).Count -eq 2 -and @($inspection.subtitles | Where-Object rawKey -eq 'danmaku').Count -eq 0) 'manual inspection triggers subtitle extraction and excludes XML danmaku'
    $audioCase=New-Case 'only-audio' (Join-Path $testRoot 'audio') $true $false
    $audioStatus=Finish-Case $audioCase (Start-Case $audioCase)
    $audioFile=@($audioStatus.items[0].assets | Where-Object status -eq 'completed')[0].path
    Assert-Resource ($audioStatus.completed -eq 1 -and [IO.Path]::GetFileName($audioFile) -eq 'Lesson.mp3' -and @($audioStatus.items[0].assets | Where-Object type -eq 'video').Count -eq 0) 'uninspected Bilibili single unknown-language audio produces title.mp3 without video or ID suffix'
    $streams = & (Join-Path $ffmpegDir 'ffprobe.exe') -v error -show_entries stream=codec_type -of json $audioFile | ConvertFrom-Json
    Assert-Resource (@($streams.streams).Count -eq 1 -and $streams.streams[0].codec_type -eq 'audio') 'audio-only output passes real ffprobe with no video stream'
    $selection=@{}; $selection['https://www.bilibili.com/video/BVfixture/']=@{ mediaId='BVfixture'; audioFormatIds=@(); subtitleTracks=@(@{rawKey='fr';source='provided'},@{rawKey='fr';source='auto'}); explicitSubtitles=$true; explicitAudio=$true }
    $subsCase=New-Case 'two-subtitles' (Join-Path $testRoot 'subs') $false $true @('fr') $selection
    $subsStatus=Finish-Case $subsCase (Start-Case $subsCase)
    $files=@(Get-ChildItem -LiteralPath $subsCase.Destination -File)
    Assert-Resource ($subsStatus.completed -eq 1 -and $files.Count -eq 2 -and @($files.Name | Where-Object { $_ -notin @('Lesson.fr.srt','Lesson.fr (2).srt') }).Count -eq 0) 'real yt-dlp saves inline and URL subtitles as title.fr.srt with collision numbering'
    $contents=@($files | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join '|'
    Assert-Resource ($contents.Contains('Provided French') -and $contents.Contains('Automatic French')) 'same-language provided and automatic subtitle tracks retain different real contents'
    $missingCase=New-Case 'missing-subtitle' (Join-Path $testRoot 'missing') $false $true @('it')
    $missingStatus=Finish-Case $missingCase (Start-Case $missingCase)
    Assert-Resource ($missingStatus.completed -eq 0 -and $missingStatus.failed -eq 0 -and $missingStatus.skipped -eq 1 -and $missingStatus.items[0].status -eq 'skipped' -and $missingStatus.items[0].message -and @(Get-ChildItem -LiteralPath $missingCase.Destination -File).Count -eq 0) 'unavailable subtitle-only resource is visibly skipped with no media download'
    $shared=Join-Path $testRoot 'shared'
    $cases=@(); $parallel=@()
    1..3 | ForEach-Object { $case=New-Case "parallel-$_" $shared $false $true; $cases+=,$case; $parallel+=,(Start-Case $case) }
    $paths=@()
    for ($i=0;$i -lt 3;$i++) { $state=Finish-Case $cases[$i] $parallel[$i]; $paths+=@($state.items[0].assets | Where-Object status -eq 'completed')[0].path }
    Assert-Resource (@($paths | Select-Object -Unique).Count -eq 3 -and @(Get-ChildItem -LiteralPath $shared -File).Count -eq 3 -and @($paths | Where-Object { -not [IO.File]::Exists($_) }).Count -eq 0) 'three concurrent production workers publish same-title subtitles atomically without losing or overwriting outputs'
    $legacyCase=New-Case 'legacy-audio' (Join-Path $testRoot 'legacy-audio-output') $true $false
    $legacyConfig=Read-LingoJson $legacyCase.Config -ThrowOnError
    Set-LingoObjectField $legacyConfig 'mode' 'audio'; Set-LingoObjectField $legacyConfig 'archivePath' (Join-Path $testRoot 'legacy-archive.txt')
    $legacyConfig.subtitleLanguages=@(); [void](Write-LingoJson $legacyCase.Config $legacyConfig -Depth 15)
    $legacyWorker=Join-Path $root 'download-worker.ps1'
    $legacyProc=Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$legacyWorker+'"'),'-ConfigPath',('"'+$legacyCase.Config+'"')) -WindowStyle Hidden -PassThru
    $processes.Add($legacyProc)
    $legacyStatus=Finish-Case $legacyCase $legacyProc
    Assert-Resource ($legacyStatus.status -eq 'completed' -and [IO.Path]::GetFileName($legacyStatus.items[0].path) -eq 'Lesson.mp3') 'legacy worker handles real yt-dlp completion payload and publishes a title-only audio filename'
    $videoPath=Join-Path $testRoot 'clip.mp4'
    & (Join-Path $ffmpegDir 'ffmpeg.exe') -hide_banner -loglevel error -f lavfi -i 'color=c=blue:s=64x64:r=5:d=1' -i $audioPath -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest -y $videoPath
    Assert-Resource ($LASTEXITCODE -eq 0) 'local complete-video authentication fixture is valid media'
    $fixture.formats+=@{ format_id='combined'; url=([Uri]$videoPath).AbsoluteUri; ext='mp4'; vcodec='h264'; acodec='aac'; width=64; height=64; abr=128 }
    $fixture.subtitleAvailability='login-required'; [void](Write-LingoJson $fixturePath $fixture -Depth 15)
    $authCase=New-Case 'subtitle-login-required' (Join-Path $testRoot 'auth') $true $true
    $authConfig=Read-LingoJson $authCase.Config -ThrowOnError; $authConfig.parts.video=$true; [void](Write-LingoJson $authCase.Config $authConfig -Depth 15)
    $authStatus=Finish-Case $authCase (Start-Case $authCase)
    Assert-Resource ($authStatus.status -eq 'partial' -and @($authStatus.items[0].assets | Where-Object { $_.status -eq 'completed' -and $_.type -in @('video','audio') }).Count -eq 2 -and @($authStatus.items[0].assets | Where-Object { $_.status -eq 'failed' -and $_.reason -eq 'login-required' -and $_.type -eq 'subtitle' }).Count -eq 1 -and $authStatus.items[0].error) 'subtitle authentication failure preserves real complete video and audio downloads and explicitly records a failed subtitle'
    Write-Host "Bilibili resources acceptance passed: $script:assertions assertions, real yt-dlp downloads and ffprobe verification."
} finally {
    foreach ($proc in $processes) { try { if (-not $proc.HasExited) { $proc.Kill(); [void]$proc.WaitForExit(3000) }; $proc.Dispose() } catch { } }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) }
    if ($KeepArtifacts) { Write-Host "Artifacts: $testRoot" }
    else { $resolved=[IO.Path]::GetFullPath($testRoot); $allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'; if ($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force } }
}

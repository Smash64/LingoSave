param([switch]$ProbeOnly, [switch]$KeepArtifacts)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'state-io.ps1')
$testRoot = Join-Path $env:TEMP ('lingosave-live-progress-' + [guid]::NewGuid().ToString('N'))
$mediaRoot = Join-Path $testRoot 'media'
[void][IO.Directory]::CreateDirectory($mediaRoot)
$ytDlp = Join-Path $root 'tools\yt-dlp.exe'
$ffmpegRoot = 'E:\ffmpeg\bin'
$script:owned = [Collections.Generic.List[object]]::new()
$script:assertions = 0
function Assert-Live {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
    $script:assertions++; Write-Host "PASS $Message"
}
function Quote-LiveArgument {
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    return '"' + ($Value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"'
}
function Start-LiveProcess {
    param([string]$Executable,[string[]]$Arguments)
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$Executable; $start.Arguments=(@($Arguments | ForEach-Object { Quote-LiveArgument $_ }) -join ' ')
    $start.WorkingDirectory=$testRoot; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($start)
    $handle=@{process=$process; stdout=$process.StandardOutput.ReadToEndAsync(); stderr=$process.StandardError.ReadToEndAsync()}
    $script:owned.Add($handle);return $handle
}
function Finish-LiveProcess {
    param($Handle)
    if (-not $Handle.process.WaitForExit(60000)) { throw 'Owned localhost test process timed out.' }
    $Handle.process.WaitForExit()
    return @{ code=$Handle.process.ExitCode; stdout=$Handle.stdout.Result; stderr=$Handle.stderr.Result }
}
try {
    $generate=Start-LiveProcess (Join-Path $ffmpegRoot 'ffmpeg.exe') @('-hide_banner','-loglevel','error','-y','-f','lavfi','-i','testsrc2=size=640x360:rate=30','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','12','-c:v','libx264','-preset','ultrafast','-b:v','1200k','-c:a','aac','-b:a','96k','-movflags','+faststart',(Join-Path $mediaRoot 'source.mp4'))
    $generated=Finish-LiveProcess $generate
    Assert-Live ($generated.code -eq 0) 'real FFmpeg creates a video for slow localhost download'
    $serverExe=Join-Path $testRoot 'local-server.exe'
    & (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:exe "/out:$serverExe" (Join-Path $PSScriptRoot 'LocalResumeServer.cs')
    Assert-Live ($LASTEXITCODE -eq 0) 'localhost HTTP fixture compiles'
    $portPath=Join-Path $testRoot 'port.txt'
    $server=Start-LiveProcess $serverExe @($mediaRoot,(Join-Path $testRoot 'requests.log'),$portPath)
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while (-not [IO.File]::Exists($portPath) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    $port=[int][IO.File]::ReadAllText($portPath)
    $url="http://127.0.0.1:$port/range.mp4"
    $probe=Start-LiveProcess $ytDlp @('--no-config','--proxy','','--no-playlist','--no-simulate','--newline','--progress','--no-colors','--progress-template','download:__LINGO_PROGRESS__%(progress._percent_str)s|%(progress.speed)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.eta)s','--print','post_process:__LINGO_PHASE__%(id)s','--no-quiet','--ffmpeg-location',$ffmpegRoot,'--output',(Join-Path $testRoot 'probe.mp4'),$url)
    $probeResult=Finish-LiveProcess $probe
    [IO.File]::WriteAllText((Join-Path $testRoot 'probe.stdout.log'),$probeResult.stdout)
    [IO.File]::WriteAllText((Join-Path $testRoot 'probe.stderr.log'),$probeResult.stderr)
    Assert-Live ($probeResult.code -eq 0) 'installed yt-dlp downloads slow localhost video'
    Assert-Live (@(($probeResult.stdout + $probeResult.stderr) -split '\r?\n' | Where-Object { $_ -match '^__LINGO_PROGRESS__' }).Count -ge 4) 'real output has the machine-readable progress prefix despite print options'
    Assert-Live ($probeResult.stdout.LastIndexOf('__LINGO_PHASE__range') -gt $probeResult.stdout.LastIndexOf('__LINGO_PROGRESS__')) 'post_process phase marker occurs after network transfer'
    if ($ProbeOnly) { return }

    foreach ($kind in @('resource','legacy')) {
        $caseRoot=Join-Path $testRoot $kind;[void][IO.Directory]::CreateDirectory($caseRoot)
        $destination=Join-Path $caseRoot 'downloads';[void][IO.Directory]::CreateDirectory($destination)
        $id=[guid]::NewGuid().ToString('N');$statusPath=Join-Path $caseRoot 'status.json'
        $config=@{id=$id;path=$destination;ytDlpPath=$ytDlp;ffmpegDirectory=$ffmpegRoot;ffprobePath=(Join-Path $ffmpegRoot 'ffprobe.exe');container='mp4';subtitleFormat='srt';statusPath=$statusPath;denoPath=$null;mode='video';storeRoot=$caseRoot;fixtureSourcePath=(Join-Path $mediaRoot 'source.mp4');cookieRevisions=@{};archivePath=(Join-Path $caseRoot 'archive.txt')}
        $configPath=Join-Path $caseRoot 'config.json';[void](Write-LingoJson $configPath $config)
        $helper=Join-Path $caseRoot 'worker.ps1'
        $helperSource=@'
param([string]$Root,[string]$ConfigPath,[string]$Kind,[string]$Url)
$ErrorActionPreference='Stop'
. (Join-Path $Root 'state-io.ps1')
. (Join-Path $Root 'resource-planner.ps1')
. (Join-Path $Root 'media-cache.ps1')
. (Join-Path $Root 'transfer-slots.ps1')
. (Join-Path $Root 'resource-pipeline.ps1')
# The fixture uses localhost rather than a supported public site.
function Get-LingoCookieRevisionForUrl { param([string]$Url); return '' }
$config=Read-LingoJson $ConfigPath -ThrowOnError
$statusPath=[string]$config.statusPath
$script:statusPath=$statusPath
$script:storeRoot=[string]$config.storeRoot
$script:status=@{id=$config.id;status='running';progress=0;speedBytesPerSecond=$null;downloadedBytes=$null;totalBytes=$null;etaSeconds=$null;completed=0;failed=0;skipped=0;currentAsset='video';currentTitle='Live progress';message='downloading';error=$null;items=[Collections.ArrayList]::new()}
$script:lastWrite=[DateTime]::MinValue
$script:controlPath=Join-Path ([IO.Path]::GetDirectoryName($statusPath)) 'control.json'
$script:mediaPidPath=Join-Path ([IO.Path]::GetDirectoryName($statusPath)) 'media.pid.json'
$script:partialRoot=Join-Path ([string]$config.path) '.lingosave-partials'
$script:ffprobePath=[string]$config.ffprobePath
$script:probePath=[string]$config.ffprobePath
$script:NativeJobAvailable=$false
$script:processing=$false
$script:currentIndex=-1
$script:currentOrdinal=0
$script:sourceErrors=0
$script:preexistingKeys=[Collections.Generic.HashSet[string]]::new()
$script:sourceErrorKeys=[Collections.Generic.HashSet[string]]::new()
$script:archiveIdsToRemove=[Collections.Generic.HashSet[string]]::new()
$workerPath=Join-Path $Root $(if($Kind -eq 'resource'){'resource-worker.ps1'}else{'download-worker.ps1'})
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($workerPath,[ref]$tokens,[ref]$errors)
foreach($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){Invoke-Expression $function.Extent.Text}
if($Kind -eq 'resource'){
    $script:localBaseArguments=${function:Get-BaseArguments}
    function Get-BaseArguments { param([string]$CookieFile); return ,((& $script:localBaseArguments $CookieFile)+@('--proxy','')) }
}
[void](Write-LingoJson $statusPath $script:status)
if($Kind -eq 'resource'){
    $script:currentItem=@{id='range';url=$Url;title='Live progress';status='running';assets=[Collections.ArrayList]::new();progress=$null;speedBytesPerSecond=$null;downloadedBytes=$null;totalBytes=$null;etaSeconds=$null;currentAsset='video'}
    [void]$script:status.items.Add($script:currentItem)
    $sourceInfo=Get-InspectionInfo -Url $Url -NoPlaylist
    # Generic direct HTTP metadata omits codecs; obtain them from the actual local fixture.
    $sourceProbe=(& $script:ffprobePath -v error -show_entries stream=codec_type,codec_name -of json ([string]$config.fixtureSourcePath) | Out-String | ConvertFrom-Json)
    $videoCodec=@($sourceProbe.streams | Where-Object codec_type -eq 'video')[0].codec_name
    $audioCodec=@($sourceProbe.streams | Where-Object codec_type -eq 'audio')[0].codec_name
    foreach($format in @($sourceInfo.formats)){Set-LingoObjectField $format 'vcodec' $videoCodec;Set-LingoObjectField $format 'acodec' $audioCodec}
    [void](Save-LingoMetadataCache -Path (Get-LingoMetadataPath -StoreRoot $script:storeRoot -Url $Url) -Url $Url -Info $sourceInfo -Complete)
    $record=Download-Asset -Plan @{id='range';title='Live progress'} -Asset @{key='video';type='video';formatId='best';language=$null} -Url $Url -SourceInfo $sourceInfo
    $script:status.status='completed';$script:status.progress=1
    Save-ResourceStatus -Force
}else{
    $arguments=@('--no-config','--proxy','','--no-playlist','--no-simulate','--newline','--progress','--no-colors','--progress-template','download:__LINGOSAVE_PROGRESS__%(progress._percent_str)s|%(progress.speed)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.eta)s','--print','before_dl:__LINGOSAVE_BEGIN__%(id)j|%(title)j|%(webpage_url)j','--print','post_process:__LINGOSAVE_PHASE__%(id)s','--print','after_move:__LINGOSAVE_DONE__%(id)j|%(filepath)j|%(title)j','--no-quiet','--ffmpeg-location',[string]$config.ffmpegDirectory,'--paths',[string]$config.path,'--output','media.%(ext)s',$Url)
    $exit=Invoke-Downloader -Arguments $arguments -Source $Url
    if($exit -ne 0){throw "yt-dlp exit=$exit"}
    $script:status.status='completed';$script:status.progress=1
    Save-Status -Force
}
'@
        [IO.File]::WriteAllText($helper,$helperSource,[Text.UTF8Encoding]::new($true))
        $handle=Start-LiveProcess (Join-Path $PSHOME 'powershell.exe') @('-NoProfile','-ExecutionPolicy','Bypass','-File',$helper,'-Root',$root,'-ConfigPath',$configPath,'-Kind',$kind,'-Url',$url)
        $samples=[Collections.Generic.List[object]]::new();$deadline=[DateTime]::UtcNow.AddSeconds(50)
        while (-not $handle.process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            $status=Read-LingoJson $statusPath
            if($status -and $status.progress -gt 0 -and $status.progress -lt 1){$samples.Add(@{progress=$status.progress;bytes=$status.downloadedBytes;speed=$status.speedBytesPerSecond;phase=$status.phase})}
            Start-Sleep -Milliseconds 50
        }
        $result=Finish-LiveProcess $handle
        Assert-Live ($result.code -eq 0) "$kind production transfer completes: $($result.stderr)"
        $distinct=@($samples | ForEach-Object progress | Sort-Object -Unique)
        [void](Write-LingoJson (Join-Path $caseRoot 'progress-samples.json') @($samples.ToArray()))
        Assert-Live ($distinct.Count -ge 4) "$kind status JSON contains at least four distinct intermediate percentages (observed $($distinct.Count))"
        Assert-Live (@($samples | Where-Object {$_.bytes -gt 0 -and $_.speed -gt 0}).Count -gt 0) "$kind status JSON publishes real byte counts and transfer speed"
        Assert-Live (@($samples | Where-Object {$_.phase -in @('merge','convert')}).Count -eq 0) "$kind keeps slow network transfer in download phase"
        Write-Host "$kind percentages: $((@($distinct | ForEach-Object {[math]::Round($_*100,1)})) -join ', ')"
    }
    Write-Host "Live progress acceptance passed: $script:assertions assertions using real installed yt-dlp and localhost HTTP."
} finally {
    foreach($handle in $script:owned){try{if(-not $handle.process.HasExited){$handle.process.Kill();[void]$handle.process.WaitForExit(5000)};$handle.process.Dispose()}catch{}}
    if($KeepArtifacts){Write-Host "Artifacts: $testRoot"}
    else{$resolved=[IO.Path]::GetFullPath($testRoot);$allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\';if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('lingosave-live-progress-')){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}else{throw 'Unsafe test cleanup target.'}}
}

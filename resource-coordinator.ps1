param([Parameter(Mandatory=$true)][string]$ConfigPath)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'state-io.ps1')
. (Join-Path $PSScriptRoot 'credential-store.ps1')
. (Join-Path $PSScriptRoot 'resource-planner.ps1')
. (Join-Path $PSScriptRoot 'transfer-slots.ps1')
. (Join-Path $PSScriptRoot 'media-cache.ps1')
. (Join-Path $PSScriptRoot 'playlist-folders.ps1')
$config = Read-LingoJson -Path $ConfigPath -ThrowOnError
$script:parentPath = [string]$config.statusPath
$script:status = Read-LingoJson -Path $script:parentPath -ThrowOnError
$script:status.items = [Collections.ArrayList]@($script:status.items)
$script:storeRoot = [string]$config.storeRoot
$script:jobsRoot = Split-Path -Parent $script:parentPath
$script:controlPath = Join-Path $script:jobsRoot "$($config.id).control.json"
$script:childRoot = Join-Path $script:jobsRoot "$($config.id).children"
$script:planPath = Join-Path $script:childRoot 'entries.json'
$script:active = @{}
$script:entries = [Collections.ArrayList]::new()
$script:started = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$script:lastSave = [DateTime]::MinValue
$script:cookieMarker = Join-Path $script:jobsRoot "$($config.id).cookie-temp.json"
$script:extractorPid = Join-Path $script:jobsRoot "$($config.id).media.pid.json"
[void][IO.Directory]::CreateDirectory($script:childRoot)
$env:PYTHONIOENCODING = 'utf-8'

# KILL_ON_JOB_CLOSE protects grandchildren even if the coordinator crashes.
Add-Type -TypeDefinition 'using System; using System.ComponentModel; using System.Diagnostics; using System.Runtime.InteropServices; public sealed class LingoCoordinatorProcessJob : IDisposable { [StructLayout(LayoutKind.Sequential)] private struct Basic { public long a,b; public uint flags; public IntPtr min,max; public uint count; public IntPtr affinity; public uint priority,schedule; } [StructLayout(LayoutKind.Sequential)] private struct IO { public ulong a,b,c,d,e,f; } [StructLayout(LayoutKind.Sequential)] private struct Limits { public Basic basic; public IO io; public IntPtr a,b,c,d; } [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern IntPtr CreateJobObject(IntPtr a,string n); [DllImport("kernel32.dll",SetLastError=true)] private static extern bool SetInformationJobObject(IntPtr h,int c,IntPtr p,uint n); [DllImport("kernel32.dll",SetLastError=true)] private static extern bool AssignProcessToJobObject(IntPtr h,IntPtr p); [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h); private IntPtr handle; public LingoCoordinatorProcessJob() { handle=CreateJobObject(IntPtr.Zero,null); if(handle==IntPtr.Zero) throw new Win32Exception(); Limits v=new Limits(); v.basic.flags=0x2000; int n=Marshal.SizeOf(v); IntPtr p=Marshal.AllocHGlobal(n); try { Marshal.StructureToPtr(v,p,false); if(!SetInformationJobObject(handle,9,p,(uint)n)) { CloseHandle(handle); handle=IntPtr.Zero; throw new Win32Exception(); } } finally {Marshal.FreeHGlobal(p);} } public bool Add(Process p) {return AssignProcessToJobObject(handle,p.Handle);} public void Dispose(){if(handle!=IntPtr.Zero){CloseHandle(handle);handle=IntPtr.Zero;}} }'
$script:processJob = [LingoCoordinatorProcessJob]::new()

function Save-CoordinatorStatus {
    param([switch]$Force)
    if (-not $Force -and ([DateTime]::UtcNow-$script:lastSave).TotalMilliseconds -lt 300) { return }
    if (Write-LingoJson -Path $script:parentPath -Value $script:status -Depth 30 -BestEffort:(-not $Force)) { $script:lastSave=[DateTime]::UtcNow }
}
function Merge-CoordinatorItem {
    param($Item)
    for($i=0;$i -lt $script:status.items.Count;$i++){
        $old=$script:status.items[$i]
        if([string]$old.url -ceq [string]$Item.url -and [string]$old.id -ceq [string]$Item.id -and (Test-LingoPlaylistScope -First $old -Second $Item)){$script:status.items[$i]=$Item;return}
    }
    # Flat playlist IDs may be extractor aliases. Replace only untouched queued placeholders.
    for($i=$script:status.items.Count-1;$i -ge 0;$i--){
        $old=$script:status.items[$i]
        if([string]$old.url -ceq [string]$Item.url -and (Test-LingoPlaylistScope -First $old -Second $Item) -and ((-not $old.id -and $old.status -eq 'failed') -or ($old.status -eq 'queued' -and @($old.assets).Count -eq 0))){$script:status.items.RemoveAt($i)}
    }
    [void]$script:status.items.Add($Item)
}
function Get-CoordinatorItem {
    param($Entry)
    $matches=@($script:status.items | Where-Object { [string]$_.url -ceq [string]$Entry.url -and (Test-LingoPlaylistScope -First $_ -Second $Entry) -and ([string]$_.id -ceq [string]$Entry.id -or -not $Entry.id) } | Select-Object -First 1)
    if($matches.Count){return $matches[0]}
    $sameUrl=@($script:status.items | Where-Object {[string]$_.url -ceq [string]$Entry.url -and (Test-LingoPlaylistScope -First $_ -Second $Entry)})
    if($sameUrl.Count -eq 1){return $sameUrl[0]}
    return $null
}
function Test-CoordinatorFinished {
    param($Item)
    if(-not $Item){return $false}
    if($Item.status -eq 'skipped'){return $true}
    if($Item.status -ne 'completed'){return $false}
    $assets=@($Item.assets | Where-Object status -eq 'completed')
    if($assets.Count){foreach($asset in $assets){if(-not $asset.path -or -not [IO.File]::Exists([string]$asset.path)){return $false}};return $true}
    return ($Item.path -and [IO.File]::Exists([string]$Item.path))
}
function Get-CoordinatorHash {
    param([string]$Value)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').Substring(0,24).ToLowerInvariant()}finally{$sha.Dispose()}
}
function Get-CoordinatorEntryKey {
    param($Entry)
    $identity = [string]$Entry.url + "\n" + [string]$Entry.id
    $directory = [string](Get-LingoField $Entry 'outputDirectory')
    if ($directory) { $identity += "\n" + (Get-LingoPlaylistFullPath $directory).ToLowerInvariant() }
    return Get-CoordinatorHash $identity
}
function Get-CoordinatorSite {
    param([string]$Url)
    return [string]((Get-LingoSiteForUrl -Url $Url).id)
}
function Resolve-CoordinatorUrl {
    param($Entry, [string]$Site)
    return Resolve-LingoMediaEntryUrl -Entry $Entry -Site $Site
}
function Quote-CoordinatorArgument {
    param([string]$Value)
    $escaped=[regex]::Replace($Value,'(\\*)"', '$1$1\"')
    $escaped=[regex]::Replace($escaped,'(\\+)$','$1$1')
    return '"' + $escaped + '"'
}
function Stop-CoordinatorProcess {
    param([Diagnostics.Process]$Process)
    if(-not $Process){return}
    try{if(-not $Process.HasExited){& (Join-Path $env:WINDIR 'System32\taskkill.exe') /PID $Process.Id /T /F *> $null;[void]$Process.WaitForExit(3000)}}catch{}
    try{if(-not $Process.HasExited){$Process.Kill();[void]$Process.WaitForExit(3000)}}catch{}
}
function Get-CoordinatorMetadata {
    param([string]$Url,[string]$CookieFile,[string]$Revision)
    $site=Get-CoordinatorSite $Url
    $uri=[Uri]$Url
    # A no-playlist manual inspection cannot prove the scope of a list or a multi-part Bilibili URL.
    $explicitBiliPart=($site -eq 'bilibili' -and $uri.AbsolutePath -match '^/video/' -and $uri.Query -match '(?:^\?|&)p=[1-9][0-9]*(?:&|$)')
    $singleAllowed=($site -ne 'bilibili' -or $explicitBiliPart)
    if($site -eq 'youtube' -and ($uri.Query -match '(?:^\?|&)list=' -or $uri.AbsolutePath -match '^/playlist(?:/|$)')){$singleAllowed=$false}
    if($singleAllowed){
        $singlePath=Get-LingoMetadataPath -StoreRoot $script:storeRoot -Url $Url -CookieRevision $Revision -Mode single
        $single=Read-LingoJson -Path $singlePath
        if((Test-LingoMetadataFresh -Envelope $single -Url $Url -CookieRevision $Revision -RequireComplete) -and $single.info._type -notin @('playlist','multi_video') -and $null -eq $single.info.entries){return $single}
    }
    $cachePath=Get-LingoMetadataPath -StoreRoot $script:storeRoot -Url $Url -CookieRevision $Revision -Mode source
    $envelope=Read-LingoJson -Path $cachePath
    if(Test-LingoMetadataFresh -Envelope $envelope -Url $Url -CookieRevision $Revision){return $envelope}
    $site=Get-CoordinatorSite $Url
    $uri=[Uri]$Url
    $noPlaylist=($site -eq 'bilibili' -and $uri.AbsolutePath -match '^/video/' -and $uri.Query -match '(?:^\?|&)p=[1-9][0-9]*(?:&|$)')
    $args=[Collections.Generic.List[string]]::new()
    foreach($arg in @('--no-config','--no-colors','--newline','--socket-timeout','15','--retries','3','--extractor-retries','3','--dump-single-json','--simulate','--write-subs','--write-auto-subs','--flat-playlist','--ffmpeg-location',[string]$config.ffmpegDirectory)){[void]$args.Add($arg)}
    if($config.denoPath){[void]$args.Add('--js-runtimes');[void]$args.Add("deno:$($config.denoPath)")}
    if($CookieFile){[void]$args.Add('--cookies');[void]$args.Add($CookieFile)}
    [void]$args.Add($(if($noPlaylist){'--no-playlist'}else{'--yes-playlist'}))
    [void]$args.Add($Url)
    $attempt=0
    while($true){
        Assert-LingoTransferAllowed -ControlPath $script:controlPath
        $lease=$null;$process=$null
        try{
            $lease=Enter-LingoTransferSlot -StoreRoot $script:storeRoot -Kind metadata -ControlPath $script:controlPath -OnWait {if($script:entries.Count){Sync-CoordinatorChildren;Start-DiscoveredChildren;Update-CoordinatorAggregate}}
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=[string]$config.ytdlpPath
            $start.Arguments=(@($args | ForEach-Object { Quote-CoordinatorArgument ([string]$_) }) -join ' ')
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true
            $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            $start.StandardOutputEncoding=[Text.Encoding]::UTF8;$start.StandardErrorEncoding=[Text.Encoding]::UTF8
            $process=[Diagnostics.Process]::new();$process.StartInfo=$start
            if(-not $process.Start()){throw '无法启动视频解析器。'}
            if(-not $script:processJob.Add($process)){Stop-CoordinatorProcess $process;throw '无法保护解析器进程，请稍后重试。'}
            [void](Write-LingoJson -Path $script:extractorPid -Value @{pid=$process.Id;startedAtTicks=$process.StartTime.Ticks;processName=$process.ProcessName})
            $out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
            while(-not $process.HasExited){Assert-LingoTransferAllowed -ControlPath $script:controlPath;if($script:entries.Count){Sync-CoordinatorChildren;Start-DiscoveredChildren;Update-CoordinatorAggregate};Start-Sleep -Milliseconds 100}
            $output=$out.GetAwaiter().GetResult();$errorText=$err.GetAwaiter().GetResult()
            if($process.ExitCode -eq 0 -and $output.Trim()){
                $info=ConvertFrom-Json -InputObject $output -ErrorAction Stop
                if($errorText -match '(?i)subtitles are only available when logged in|login required.*subtitles|subtitles.*login required'){Set-LingoObjectField $info 'subtitleAvailability' 'login-required'}
                $complete=($info._type -notin @('playlist','multi_video') -and $null -eq $info.entries -and $info.formats -and @($info.formats | Where-Object {$_ -and $_.url}).Count -gt 0)
                $saved=Save-LingoMetadataCache -Path $cachePath -Url $Url -CookieRevision $Revision -Info $info -Complete:$complete
                if($complete){[void](Save-LingoMetadataCache -Path (Get-LingoMetadataPath -StoreRoot $script:storeRoot -Url $Url -CookieRevision $Revision) -Url $Url -CookieRevision $Revision -Info $info -Complete -FetchedAt $saved.fetchedAt)}
                return $saved
            }
            if(-not (Test-LingoNetworkError -Message $errorText)){
                $hint = Get-LingoSiteFailureHint -Site $site -Message $errorText
                if (-not $hint) { $hint = $errorText.Substring(0,[math]::Min(600,$errorText.Length)) }
                throw ('资源解析失败：' + $hint)
            }
            $attempt++
        }finally{
            if($process){Stop-CoordinatorProcess $process;$process.Dispose()}
            if($lease){Exit-LingoTransferSlot -Lease $lease}
            if([IO.File]::Exists($script:extractorPid)){[IO.File]::Delete($script:extractorPid)}
        }
        $seconds=[int][math]::Min(30,[math]::Pow(2,[math]::Min(5,$attempt)))
        $script:status.status='waiting_network';$script:status.message="网络暂时不可用，$seconds 秒后重新解析"
        Set-LingoObjectField $script:status 'retryAt' ([DateTime]::UtcNow.AddSeconds($seconds).ToString('o'))
        Save-CoordinatorStatus -Force
        $until=[DateTime]::UtcNow.AddSeconds($seconds)
        while([DateTime]::UtcNow -lt $until){Assert-LingoTransferAllowed -ControlPath $script:controlPath;if($script:entries.Count){Sync-CoordinatorChildren;Start-DiscoveredChildren;Update-CoordinatorAggregate};Start-Sleep -Milliseconds 150}
        $script:status.status='running';Set-LingoObjectField $script:status 'retryAt' $null
    }
}
function Add-CoordinatorEntry {
    param($Entry)
    foreach($old in $script:entries){if([string]$old.url -ceq [string]$Entry.url -and [string]$old.id -ceq [string]$Entry.id -and (Test-LingoPlaylistScope -First $old -Second $Entry)){return}}
    $shared = @($script:entries | Where-Object { [string]$_.url -ceq [string]$Entry.url -and -not (Test-LingoPlaylistScope -First $_ -Second $Entry) })
    if ($shared.Count -and -not (Get-LingoField $Entry 'partialScope')) {
        $scope = [string](Get-LingoField $Entry 'outputDirectory' ([string]$config.path))
        Set-LingoObjectField $Entry 'partialScope' $scope
    }
    [void]$script:entries.Add($Entry)
    $prior=Get-CoordinatorItem $Entry
    if(-not $prior){Merge-CoordinatorItem @{id=$Entry.id;url=$Entry.url;sourceUrl=$Entry.sourceUrl;title=$Entry.title;officialPlaylistTitle=$Entry.officialPlaylistTitle;outputDirectory=(Get-LingoField $Entry 'outputDirectory');status='queued';path=$null;error=$null;assets=@();phase='queued'}}
}
function Update-CoordinatorAggregate {
    param([string]$ControlAction)
    $live=[Collections.Generic.List[object]]::new()
    foreach($entry in $script:entries){
        $childPath=Join-Path (Join-Path $script:childRoot (Get-CoordinatorEntryKey $entry)) 'status.json'
        $child=Read-LingoJson -Path $childPath
        if($child){foreach($item in @($child.items)){Merge-CoordinatorItem $item};if($script:active.ContainsKey($childPath)){[void]$live.Add($child)}}
    }
    $items=@($script:status.items)
    $script:status.total=$items.Count
    $script:status.completed=@($items | Where-Object status -eq 'completed').Count
    $script:status.failed=@($items | Where-Object {$_.status -in @('failed','partial')}).Count
    Set-LingoObjectField $script:status 'skipped' @($items | Where-Object status -eq 'skipped').Count
    $finished=@($items | Where-Object {$_.status -in @('completed','partial','failed','skipped')}).Count
    $fraction=[double]$finished
    foreach($child in $live){if($child.status -notin @('completed','partial','failed','skipped') -and @($child.items | Where-Object {$_.status -notin @('completed','partial','failed','skipped')}).Count -gt 0 -and $null -ne $child.progress){$fraction += [math]::Max(0.0,[math]::Min(1.0,[double]$child.progress))}}
    $script:status.progress=if($items.Count){[math]::Min(1.0,($fraction/[double]$items.Count))}else{$null}
    $downloads=@($live | Where-Object {$_.status -eq 'running' -and $_.phase -in @('download','transfer')})
    $processing=@($live | Where-Object {$_.phase -in @('processing','convert','merge','verify')})
    $speed=[double]0;$downloaded=[double]0;$total=[double]0;$allTotals=$true
    foreach($child in $downloads){if($child.speedBytesPerSecond -gt 0){$speed += [double]$child.speedBytesPerSecond};if($null -ne $child.downloadedBytes){$downloaded += [double]$child.downloadedBytes};if($child.totalBytes -gt 0){$total += [double]$child.totalBytes}else{$allTotals=$false}}
    $script:status.speedBytesPerSecond=if($downloads.Count){$speed}else{$null}
    $script:status.downloadedBytes=if($downloads.Count){$downloaded}else{$null}
    $script:status.totalBytes=if($downloads.Count -and $allTotals){$total}else{$null}
    $script:status.etaSeconds=if($speed -gt 0 -and $allTotals){[math]::Max(0.0,($total-$downloaded)/$speed)}else{$null}
    $focus=if($downloads.Count){$downloads[0]}elseif($processing.Count){$processing[0]}elseif($live.Count){$live[0]}else{$null}
    $script:status.currentTitle=if($focus){[string]$focus.currentTitle}else{$null}
    $script:status.currentAsset=if($downloads.Count){[string]$downloads[0].currentAsset}elseif($processing.Count){'processing'}else{'inspect'}
    Set-LingoObjectField $script:status 'phase' $(if($downloads.Count){'download'}elseif($processing.Count){'processing'}elseif($live.Count){'inspect'}else{'queued'})
    Set-LingoObjectField $script:status 'activeVideos' $live.Count
    Set-LingoObjectField $script:status 'downloadingVideos' $downloads.Count
    Set-LingoObjectField $script:status 'processingVideos' $processing.Count
    $script:status.status=if($ControlAction -eq 'pause'){'pausing'}elseif($live.Count -gt 0 -and @($live | Where-Object status -eq 'waiting_network').Count -eq $live.Count){'waiting_network'}else{'running'}
    $script:status.message=if($ControlAction -eq 'pause'){'正在暂停并保存所有资源的下载状态'}else{"并行下载 $($downloads.Count) 项，处理 $($processing.Count) 项；完成 $($script:status.completed)/$($script:status.total)"}
    Save-CoordinatorStatus
}
function Start-CoordinatorChild {
    param($Entry)
    $key=Get-CoordinatorEntryKey $Entry
    $directory=Join-Path $script:childRoot $key
    [void][IO.Directory]::CreateDirectory($directory)
    $childPath=Join-Path $directory 'status.json'
    $childConfigPath=Join-Path $directory 'config.json'
    $previous=Get-CoordinatorItem $Entry
    $old=Read-LingoJson -Path $childPath
    if($old){foreach($item in @($old.items)){Merge-CoordinatorItem $item};$previous=Get-CoordinatorItem $Entry}
    $child=($script:status | ConvertTo-Json -Depth 30 -Compress | ConvertFrom-Json)
    $child.items=@(if($previous){$previous});$child.total=1;$child.completed=0;$child.failed=0;$child.status='queued';$child.error=$null;$child.progress=$null;$child.speedBytesPerSecond=$null
    [void](Write-LingoJson -Path $childPath -Value $child -Depth 30)
    $childConfig=($config | ConvertTo-Json -Depth 30 -Compress | ConvertFrom-Json)
    Set-LingoObjectField $childConfig 'statusPath' $childPath
    Set-LingoObjectField $childConfig 'controlPath' $script:controlPath
    Set-LingoObjectField $childConfig 'singleVideo' $true
    Set-LingoObjectField $childConfig 'singleEntry' $Entry
    $outputDirectory = [string](Get-LingoField $Entry 'outputDirectory')
    $selectionSource = [string]$Entry.sourceUrl
    if (-not $selectionSource) { $selectionSource = [string]$Entry.url }
    if (-not $outputDirectory) { $outputDirectory = Get-LingoSavedPlaylistDirectory -Config $config -SourceUrl $selectionSource }
    if ($outputDirectory) { $outputDirectory = Assert-LingoPlaylistDirectory -BasePath ([string]$config.path) -Directory $outputDirectory -Create }
    Set-LingoObjectField $childConfig 'outputDirectory' $outputDirectory
    Set-LingoObjectField $childConfig 'partialScope' (Get-LingoField $Entry 'partialScope')
    Set-LingoObjectField $childConfig 'urls' @([string]$Entry.url)
    Set-LingoObjectField $childConfig 'retryUrls' @()
    $revision=[string](Get-LingoField $config.cookieRevisions (Get-CoordinatorSite $Entry.url))
    $metadataPath=Get-LingoMetadataPath -StoreRoot $script:storeRoot -Url $Entry.url -CookieRevision $revision
    Set-LingoObjectField $childConfig 'metadataPath' $metadataPath
    $metadata=Read-LingoJson -Path $metadataPath
    if(Test-LingoMetadataFresh -Envelope $metadata -Url $Entry.url -CookieRevision $revision -RequireComplete){
        Set-LingoObjectField $childConfig 'prefetchedInfo' $metadata.info
        Set-LingoObjectField $childConfig 'prefetchedAt' $metadata.fetchedAt
        Set-LingoObjectField $childConfig 'prefetchedCookieRevision' $revision
    }
    [void](Write-LingoJson -Path $childConfigPath -Value $childConfig -Depth 60)
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=Join-Path $PSHOME 'powershell.exe'
    $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'resource-worker.ps1')+'" -ConfigPath "'+$childConfigPath+'"'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WorkingDirectory=$PSScriptRoot
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    if(-not $process.Start()){throw '无法启动视频下载工作进程。'}
    if(-not $script:processJob.Add($process)){Stop-CoordinatorProcess $process;$process.Dispose();throw '无法保护视频下载工作进程。'}
    [void](Write-LingoJson -Path (Join-Path $directory 'worker.pid.json') -Value @{pid=$process.Id;startedAtTicks=$process.StartTime.Ticks;processName=$process.ProcessName})
    $script:active[$childPath]=@{process=$process;entry=$Entry;directory=$directory}
}
function Start-DiscoveredChildren {
    # Discovery and transfer share the same bounded pipeline, including while a later source resolves.
    foreach($entry in $script:entries){
        if($script:active.Count -ge 5){break}
        Assert-LingoTransferAllowed -ControlPath $script:controlPath
        $key=Get-CoordinatorEntryKey $entry
        if($script:started.Contains($key)){continue}
        if(@($config.retryUrls).Count -gt 0 -and $config.retryUrls -and [string]$entry.sourceUrl -cnotin @($config.retryUrls) -and [string]$entry.url -cnotin @($config.retryUrls)){continue}
        if(Test-CoordinatorFinished (Get-CoordinatorItem $entry)){[void]$script:started.Add($key);continue}
        [void]$script:started.Add($key)
        try{Start-CoordinatorChild $entry}catch{
            if(Test-LingoControlException $_){throw}
            Merge-CoordinatorItem @{id=$entry.id;url=$entry.url;sourceUrl=$entry.sourceUrl;title=$entry.title;officialPlaylistTitle=$entry.officialPlaylistTitle;status='failed';error=$_.Exception.Message;phase='queued';assets=@()}
        }
    }
}
function Sync-CoordinatorChildren {
    foreach($path in @($script:active.Keys)){
        $record=$script:active[$path];$process=$record.process
        if(-not $process.HasExited){continue}
        $child=Read-LingoJson -Path $path
        if($child){
            foreach($item in @($child.items)){Merge-CoordinatorItem $item}
            if($child.status -notin @('completed','partial','failed','paused','cancelled')){
                $item=Get-CoordinatorItem $record.entry
                if(-not $item){$item=@{id=$record.entry.id;url=$record.entry.url;sourceUrl=$record.entry.sourceUrl;title=$record.entry.title;officialPlaylistTitle=$record.entry.officialPlaylistTitle;assets=@()}}
                Set-LingoObjectField $item 'status' $(if(@($item.assets | Where-Object status -eq 'completed').Count){'partial'}else{'failed'})
                Set-LingoObjectField $item 'error' '视频下载工作进程异常退出，可重试继续。'
                Merge-CoordinatorItem $item
                $child.status=$item.status;$child.items=@($item)
                [void](Write-LingoJson -Path $path -Value $child -Depth 30)
            }
        }else{
            $item=@{id=$record.entry.id;url=$record.entry.url;sourceUrl=$record.entry.sourceUrl;title=$record.entry.title;officialPlaylistTitle=$record.entry.officialPlaylistTitle;status='failed';error='视频下载工作进程异常退出，未生成可读状态。';assets=@()}
            Merge-CoordinatorItem $item
            [void](Write-LingoJson -Path $path -Value @{status='failed';items=@($item)} -Depth 30)
        }
        $process.Dispose();$script:active.Remove($path)
        $pidPath=Join-Path $record.directory 'worker.pid.json'
        if([IO.File]::Exists($pidPath)){[IO.File]::Delete($pidPath)}
    }
}
try{
    $script:status.status='running';$script:status.error=$null;$script:status.message='正在解析并安排并行下载任务'
    Set-LingoObjectField $script:status 'phase' 'inspect'
    Save-CoordinatorStatus -Force
    $savedPlan=Read-LingoJson -Path $script:planPath
    if($savedPlan){foreach($entry in @($savedPlan.entries)){Add-CoordinatorEntry $entry};Update-CoordinatorAggregate}
    $sources=if(@($config.retryUrls).Count -gt 0 -and $config.retryUrls){@($config.retryUrls)}else{@($config.urls)}
    foreach($source in $sources){
        Assert-LingoTransferAllowed -ControlPath $script:controlPath
        if(@($script:entries | Where-Object {[string]$_.sourceUrl -ceq [string]$source -or [string]$_.url -ceq [string]$source}).Count){continue}
        $cookieFile=$null
        try{
            $site=Get-CoordinatorSite ([string]$source);$revision=[string](Get-LingoField $config.cookieRevisions $site)
            if($revision){$cookieFile=New-LingoTemporaryCookieFile -Site $site -StoreRoot $script:storeRoot -Revision $revision;[void](Write-LingoJson -Path $script:cookieMarker -Value @{path=$cookieFile})}
            $origin=Get-CoordinatorMetadata -Url ([string]$source) -CookieFile $cookieFile -Revision $revision
            for($i=$script:status.items.Count-1;$i -ge 0;$i--){$old=$script:status.items[$i];if(-not $old.id -and [string]$old.url -ceq [string]$source -and $old.status -eq 'failed'){$script:status.items.RemoveAt($i)}}
            if($origin.info._type -in @('playlist','multi_video') -or $null -ne $origin.info.entries){
                $playlistDirectory = Get-LingoPlaylistDirectory -Config $config -ConfigPath $ConfigPath -SourceUrl ([string]$source) -Info $origin.info
                foreach($raw in @($origin.info.entries)){
                    if(-not $raw){continue}
                    $url=Resolve-CoordinatorUrl -Entry $raw -Site $site
                    $selected = Get-LingoField (Get-LingoField $config 'selectedVideos') ([string]$source)
                    if ($null -ne $selected -and [string]$raw.id -cnotin @($selected) -and [string]$url -cnotin @($selected)) { continue }
                    $officialTitle = Get-LingoOfficialPlaylistTitle -Info $raw -Site $site
                    $entryTitle = if ($raw.title) { [string]$raw.title } elseif ($raw.id) { [string]$raw.id } else { '未命名资源' }
                    if ($officialTitle) { $entryTitle = $officialTitle }
                    if(-not $url){Merge-CoordinatorItem @{id=$raw.id;url=[string]$source;sourceUrl=[string]$source;title=$entryTitle;officialPlaylistTitle=$officialTitle;status='failed';error='播放列表条目缺少可用视频链接。';assets=@();phase='inspect'};continue}
                    $entry=@{id=[string]$raw.id;title=$entryTitle;officialPlaylistTitle=$officialTitle;url=$url;sourceUrl=[string]$source;outputDirectory=$playlistDirectory}
                    Add-CoordinatorEntry $entry
                    if($raw.formats -and @($raw.formats | Where-Object {$_ -and $_.url}).Count -gt 0){[void](Save-LingoMetadataCache -Path (Get-LingoMetadataPath -StoreRoot $script:storeRoot -Url $url -CookieRevision $revision) -Url $url -CookieRevision $revision -Info $raw -Complete -FetchedAt $origin.fetchedAt)}
                }
            }else{
                # A failure-history retry may restore only root snapshots, without its child plan.
                # Rebuild each prior occurrence so shared videos keep their original folder.
                $restored = @()
                if (@($config.retryUrls).Count -gt 0 -and $config.retryUrls) {
                    $restored = @($script:status.items | Where-Object { [string]$_.url -ceq [string]$source })
                }
                if ($restored.Count) {
                    foreach ($previous in $restored) {
                        $originalSource = [string](Get-LingoField $previous 'sourceUrl' ([string]$source))
                        if (-not $originalSource) { $originalSource = [string]$source }
                        $entry = @{id=[string]$origin.info.id;title=[string]$origin.info.title;url=[string]$source;sourceUrl=$originalSource}
                        if ($previous.officialPlaylistTitle) {
                            $entry.officialPlaylistTitle = [string]$previous.officialPlaylistTitle
                            $entry.title = $entry.officialPlaylistTitle
                        }
                        $directory = Get-LingoSavedPlaylistDirectory -Config $config -SourceUrl $originalSource
                        if (-not $directory -and $previous.outputDirectory -and [string]$previous.outputDirectory -ine [string]$config.path) {
                            $directory = Assert-LingoPlaylistDirectory -BasePath ([string]$config.path) -Directory ([string]$previous.outputDirectory) -Create
                        }
                        if ($directory) { Set-LingoObjectField $entry 'outputDirectory' $directory }
                        if ($previous.partialScope) { Set-LingoObjectField $entry 'partialScope' ([string]$previous.partialScope) }
                        Add-CoordinatorEntry $entry
                    }
                }else{Add-CoordinatorEntry @{id=[string]$origin.info.id;title=[string]$origin.info.title;url=[string]$source;sourceUrl=[string]$source}}
            }
            [void](Write-LingoJson -Path $script:planPath -Value @{entries=@($script:entries);createdAt=[DateTime]::UtcNow.ToString('o')} -Depth 30)
            Save-CoordinatorStatus -Force
            Sync-CoordinatorChildren;Start-DiscoveredChildren;Update-CoordinatorAggregate
        }catch{
            if(Test-LingoControlException $_){throw}
            Merge-CoordinatorItem @{id=$null;url=[string]$source;sourceUrl=[string]$source;title=[string]$source;status='failed';error=$_.Exception.Message;phase='inspect';assets=@()}
            Save-CoordinatorStatus -Force
        }finally{if($cookieFile){Remove-LingoTemporaryCookieFile -Path $cookieFile -StoreRoot $script:storeRoot};if([IO.File]::Exists($script:cookieMarker)){[IO.File]::Delete($script:cookieMarker)}}
    }
    $pending=[Collections.Generic.Queue[object]]::new()
    foreach($entry in $script:entries){
        if(@($config.retryUrls).Count -gt 0 -and $config.retryUrls -and [string]$entry.sourceUrl -cnotin @($config.retryUrls) -and [string]$entry.url -cnotin @($config.retryUrls)){continue}
        if(-not $script:started.Contains((Get-CoordinatorEntryKey $entry)) -and -not (Test-CoordinatorFinished (Get-CoordinatorItem $entry))){$pending.Enqueue($entry)}
    }
    while($pending.Count -gt 0 -or $script:active.Count -gt 0){
        Sync-CoordinatorChildren
        $action=Get-LingoControlAction -Path $script:controlPath
        if($action -eq 'cancel'){Assert-LingoTransferAllowed -ControlPath $script:controlPath}
        while(-not $action -and $pending.Count -gt 0 -and $script:active.Count -lt 5){
            $entry=$pending.Dequeue()
            try{Start-CoordinatorChild $entry}catch{Merge-CoordinatorItem @{id=$entry.id;url=$entry.url;sourceUrl=$entry.sourceUrl;title=$entry.title;officialPlaylistTitle=$entry.officialPlaylistTitle;status='failed';error=$_.Exception.Message;phase='queued';assets=@()}}
            $action=Get-LingoControlAction -Path $script:controlPath
        }
        Update-CoordinatorAggregate -ControlAction $action
        if($action -eq 'pause' -and $script:active.Count -eq 0){Assert-LingoTransferAllowed -ControlPath $script:controlPath}
        if($script:active.Count -eq 0 -and $pending.Count -eq 0){break}
        Start-Sleep -Milliseconds 180
    }
    Update-CoordinatorAggregate
    $goodAssets=@($script:status.items | ForEach-Object {@($_.assets)} | Where-Object status -eq 'completed').Count
    $script:status.status=if($script:status.failed -gt 0){if($script:status.completed -gt 0 -or $goodAssets -gt 0){'partial'}else{'failed'}}else{'completed'}
    $script:status.message="完成 $($script:status.completed) 项，失败 $($script:status.failed) 项，跳过 $($script:status.skipped) 项"
    $script:status.error=if($script:status.failed){[string](@($script:status.items | Where-Object {$_.status -in @('failed','partial')} | Select-Object -First 1)[0].error)}else{$null}
    $script:status.currentTitle=$null;$script:status.currentAsset=$null;$script:status.progress=$null;$script:status.speedBytesPerSecond=$null;$script:status.downloadedBytes=$null;$script:status.totalBytes=$null;$script:status.etaSeconds=$null
    Set-LingoObjectField $script:status 'phase' 'completed'
    Save-CoordinatorStatus -Force
}catch{
    $control=if(Test-LingoControlException $_){[string]$_.Exception.Data['LingoControlAction']}else{$null}
    if($control -eq 'pause'){
        # A metadata request can observe pause while sibling children are converting.
        # Let those children finish their safe processing boundary before ending the parent.
        while($script:active.Count -gt 0){Sync-CoordinatorChildren;Update-CoordinatorAggregate -ControlAction 'pause';Start-Sleep -Milliseconds 150}
    }else{foreach($record in @($script:active.Values)){Stop-CoordinatorProcess $record.process}}
    Update-CoordinatorAggregate -ControlAction $control
    $script:status.status=if($control -eq 'pause'){'paused'}elseif($control -eq 'cancel'){'cancelled'}else{'failed'}
    $script:status.error=if($control){$null}else{$_.Exception.Message}
    $script:status.message=if($control -eq 'pause'){'已暂停，所有成品与下载片段已保留'}elseif($control -eq 'cancel'){'已取消，所有成品与下载片段已保留'}else{$script:status.error}
    $script:status.speedBytesPerSecond=$null;$script:status.etaSeconds=$null
    foreach($item in @($script:status.items | Where-Object {$_.status -in @('queued','running','waiting_network','pausing')})){Set-LingoObjectField $item 'status' $(if($control -eq 'pause'){'paused'}elseif($control -eq 'cancel'){'cancelled'}else{'failed'})}
    Save-CoordinatorStatus -Force
}finally{
    foreach($record in @($script:active.Values)){Stop-CoordinatorProcess $record.process;try{$record.process.Dispose()}catch{}}
    if($script:processJob){$script:processJob.Dispose()}
}

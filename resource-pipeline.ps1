function Format-LingoRadioTranscriptTime {
    param([double]$Seconds, [string]$Separator)
    $time = [TimeSpan]::FromMilliseconds([Math]::Round($Seconds * 1000))
    return '{0:00}:{1:00}:{2:00}{3}{4:000}' -f ([int][Math]::Floor($time.TotalHours)), $time.Minutes, $time.Seconds, $Separator, $time.Milliseconds
}

function Convert-LingoRadioTranscript {
    param([string]$SourcePath, [string]$DestinationPath, [ValidateSet('srt', 'vtt')][string]$Format)
    $document = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($SourcePath))
    $builder = [Text.StringBuilder]::new()
    $separator = ','
    if ($Format -eq 'vtt') {
        $separator = '.'
        [void]$builder.AppendLine('WEBVTT').AppendLine()
    }
    $count = 0
    foreach ($cue in @($document.transcript)) {
        if ($null -eq $cue.start -or $null -eq $cue.end -or $cue.text -isnot [string]) { continue }
        try { $start = [double]$cue.start; $end = [double]$cue.end } catch { continue }
        if ([double]::IsNaN($start) -or [double]::IsNaN($end) -or $start -lt 0 -or $end -le $start -or $end -ge [TimeSpan]::MaxValue.TotalSeconds) { continue }
        # The official speaker field is separate from the dialogue. Strip only
        # explicit speaker labels if they also appear inside a text field.
        $text = $cue.text -replace '(?i)\[(?:INTERVENANT[ \t]+\d+|SPEAKER_\d+)\][ \t]*', ''
        $text = $text -replace '(?im)^[ \t]*(?:INTERVENANT[ \t]+\d+|SPEAKER_\d+)(?:[ \t]*[:：–—-][ \t]*|[ \t]*\r?$)', ''
        $lines = @($text -split '\r?\n|\r' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (-not $lines.Count) { continue }
        $count++
        if ($Format -eq 'srt') { [void]$builder.AppendLine([string]$count) }
        $startTime = Format-LingoRadioTranscriptTime -Seconds $start -Separator $separator
        $endTime = Format-LingoRadioTranscriptTime -Seconds $end -Separator $separator
        [void]$builder.AppendLine("$startTime --> $endTime")
        foreach ($line in $lines) { [void]$builder.AppendLine($line) }
        [void]$builder.AppendLine()
    }
    if (-not $count) { throw 'Radio France 官方转录没有可用的字幕时间轴。' }
    [IO.File]::WriteAllText($DestinationPath, $builder.ToString(), [Text.UTF8Encoding]::new($false))
}

function Convert-LingoJson3Subtitle {
    param([string]$SourcePath,[string]$DestinationPath)
    $source=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($SourcePath))
    $events=@($source.events | Where-Object {$_.segs -and $null -ne $_.tStartMs} | Sort-Object {[double]$_.tStartMs})
    $builder=[Text.StringBuilder]::new();$sequence=0
    for($index=0;$index -lt $events.Count;$index++){
        $event=$events[$index];$text=(@($event.segs | ForEach-Object {[string]$_.utf8}) -join '').Trim()
        if(-not $text){continue}
        $start=[double]$event.tStartMs;$duration=Get-LingoField $event 'dDurationMs' 0
        $end=if([double]$duration -gt 0){$start+[double]$duration}elseif($index+1 -lt $events.Count){[double]$events[$index+1].tStartMs}else{$start+2000}
        if($index+1 -lt $events.Count -and [double]$events[$index+1].tStartMs -gt $start){$end=[math]::Min($end,[double]$events[$index+1].tStartMs)}
        if($end -le $start){$end=$start+1}
        $startTime=[TimeSpan]::FromMilliseconds($start);$endTime=[TimeSpan]::FromMilliseconds($end)
        $startText='{0:00}:{1:00}:{2:00},{3:000}' -f [int][math]::Floor($startTime.TotalHours),$startTime.Minutes,$startTime.Seconds,$startTime.Milliseconds
        $endText='{0:00}:{1:00}:{2:00},{3:000}' -f [int][math]::Floor($endTime.TotalHours),$endTime.Minutes,$endTime.Seconds,$endTime.Milliseconds
        $sequence++;[void]$builder.AppendLine([string]$sequence);[void]$builder.AppendLine($startText+' --> '+$endText);[void]$builder.AppendLine($text);[void]$builder.AppendLine()
    }
    if($sequence -eq 0){throw 'JSON3 字幕没有可保存的时间轴内容。'}
    [IO.File]::WriteAllText($DestinationPath,$builder.ToString(),[Text.UTF8Encoding]::new($false))
}
function Get-LingoSourceFormat {
    param($Info,[string]$FormatId)
    $found=@($Info.formats | Where-Object {[string]$_.format_id -ceq $FormatId} | Select-Object -First 1)
    if($found.Count -eq 1){return $found[0]}
    if(-not $Info.formats -and [string]$Info.format_id -ceq $FormatId -and $Info.url){return $Info}
    return $null
}
function Get-LingoCookieRevisionForUrl {
    param([string]$Url)
    $site=Get-UrlSite $Url
    return [string](Get-LingoField $config.cookieRevisions $site '')
}
function Get-LingoDownloadInfoPath {
    param([string]$Url,[string]$CookieFile,[string]$Directory,[switch]$Refresh)
    $info=Get-InspectionInfo -Url $Url -CookieFile $CookieFile -NoPlaylist -Force:$Refresh
    if ([string]$info.id -cne [string]$script:currentItem.id) {throw '视频 ID 已变化，请重新解析；已保存的文件和断点保留。'}
    $script:resolvedInfo=$info
    $downloadInfo=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $info -Depth 60)
    foreach($field in @('requested_downloads','requested_formats','requested_subtitles')){if($downloadInfo.PSObject.Properties[$field]){$downloadInfo.PSObject.Properties.Remove($field)}}
    if($downloadInfo.formats -and @($downloadInfo.formats | Where-Object {$_ -and $_.format_id}).Count -gt 0){
        foreach($field in @('format_id','format','url','ext','protocol','vcodec','acodec','resolution','width','height','fps','dynamic_range')){if($downloadInfo.PSObject.Properties[$field]){$downloadInfo.PSObject.Properties.Remove($field)}}
    }
    $path=Join-Path $Directory 'source.download.json'
    [void](Write-LingoJson -Path $path -Value $downloadInfo -Depth 60)
    return $path
}
function Get-LingoSelectedFormats {
    param([string]$Expression,[string]$InfoPath,[string]$CookieFile)
    $arguments=(Get-BaseArguments $CookieFile)+@('--load-info-json',$InfoPath,'--no-playlist','--simulate','--dump-single-json','--no-write-subs','--no-write-auto-subs','--format',$Expression)
    $result=Invoke-LingoYtDlp -Arguments $arguments -Capture -Kind none
    if ($result.code -ne 0 -or -not $result.output.Trim()) {throw ('格式选择失败：'+$result.error)}
    $selected=ConvertFrom-Json -InputObject $result.output
    $validDownloads=@($selected.requested_downloads | Where-Object {$_.format_id -or $_.requested_formats});$groups=if($selected.requested_formats){@($selected)}elseif($validDownloads.Count){$validDownloads}else{@($selected)}
    $formats=[Collections.Generic.List[object]]::new()
    foreach($group in $groups){
        $pieces=if($group.requested_formats){@($group.requested_formats)}else{@($group)}
        foreach($piece in $pieces){
            $formatId=[string]$piece.format_id
            if (-not $formatId -or $formatId -match '[+/]') {throw '无法确定原始下载格式，停止以避免下载错误音轨。'}
            $original=@(Get-LingoSourceFormat -Info $script:resolvedInfo -FormatId $formatId)
            $format=if($original.Count -eq 1){$original[0]}else{$piece}
            if (-not $format.url) {throw '所选原始格式缺少下载地址。'}
            if (-not @($formats | Where-Object {[string]$_.format_id -ceq $formatId}).Count) {[void]$formats.Add($format)}
        }
    }
    return ,$formats.ToArray()
}
function Get-LingoRawDescriptor {
    param($Format)
    return [ordered]@{id=[string]$Format.format_id;filesize=(Get-LingoField $Format 'filesize');width=(Get-LingoField $Format 'width');height=(Get-LingoField $Format 'height');vcodec=(Get-LingoField $Format 'vcodec');acodec=(Get-LingoField $Format 'acodec');ext=(Get-LingoField $Format 'ext')}
}
function Assert-LingoRawMetadata {
    param([string]$FormatId,[string]$ExpectedSignature)
    $fresh=@(Get-LingoSourceFormat -Info $script:resolvedInfo -FormatId $FormatId)
    if($fresh.Count -ne 1 -or (Get-ShortHash (ConvertTo-Json -InputObject (Get-LingoRawDescriptor $fresh[0]) -Depth 10 -Compress)) -cne $ExpectedSignature){throw '下载时原始格式信息发生变化，旧断点已保留；请重试当前资源。'}
}
function Test-LingoRawMedia {
    param([string]$Path,$Format)
    if(-not [IO.File]::Exists($Path) -or ([IO.FileInfo]::new($Path)).Length -le 0){return $false}
    try{
        $json=& $script:ffprobePath -v error -show_entries 'stream=codec_type:stream_disposition=attached_pic' -of json $Path 2>$null | Out-String
        if($LASTEXITCODE -ne 0){return $false}
        $streams=@(($json | ConvertFrom-Json).streams)
        if($Format.vcodec -and $Format.vcodec -ne 'none' -and -not @($streams | Where-Object { $_.codec_type -eq 'video' -and $_.disposition.attached_pic -ne 1 }).Count){return $false}
        if($Format.acodec -and $Format.acodec -ne 'none' -and -not @($streams | Where-Object codec_type -eq 'audio').Count){return $false}
        return $streams.Count -gt 0
    }catch{return $false}
}
function Invoke-LingoCachedTransfer {
    param([scriptblock]$BuildArguments,[string]$Url,[string]$CookieFile,[string]$Directory,[ref]$InfoPath)
    $attempt=0;$refreshCount=0
    while($true){
        Assert-LingoTransferAllowed -ControlPath $script:controlPath
        $arguments=& $BuildArguments ([string]$InfoPath.Value)
        $lease=$null
        try{
            $lease=Enter-LingoTransferSlot -StoreRoot $script:storeRoot -Kind download -ControlPath $script:controlPath -OnWait { Set-TransferPhase 'waiting_capacity'; $script:status.message='等待可用下载连接';Stop-TransferRates;Save-ResourceStatus }
            Set-TransferPhase 'download'
            $result=Invoke-LingoYtDlpAttempt -Arguments $arguments
        }finally{if($lease){Exit-LingoTransferSlot -Lease $lease}}
        if($result.code -eq 0){return $result}
        $expired=[string]$result.error -match '(?i)403|410|expired|signature|url.*expire'
        if($expired -and $refreshCount -lt 2){
            $refreshCount++
            $InfoPath.Value=Get-LingoDownloadInfoPath -Url $Url -CookieFile $CookieFile -Directory $Directory -Refresh
            Set-TransferPhase 'download';continue
        }
        if(-not(Test-LingoNetworkError -Message ([string]$result.error))){return $result}
        $attempt++;Wait-NetworkRetry -Attempt $attempt -Message ([string]$result.error)
        # Refresh only when the cached URLs are no longer fresh; retain the same raw path.
        $InfoPath.Value=Get-LingoDownloadInfoPath -Url $Url -CookieFile $CookieFile -Directory $Directory
    }
}
function Get-LingoRawMedia {
    param($Format,[string]$Url,[string]$CookieFile,[string]$ItemDirectory,[string]$LegacyDirectory,[ref]$InfoPath)
    $descriptor=Get-LingoRawDescriptor $Format
    $signature=Get-ShortHash (ConvertTo-Json -InputObject $descriptor -Depth 10 -Compress)
    $rawRoot=Join-Path (Join-Path $ItemDirectory 'raw') (Get-ShortHash ([string]$Format.format_id))
    [void][IO.Directory]::CreateDirectory($rawRoot)
    $manifestPath=Join-Path $rawRoot 'resume.metadata.json'
    $manifest=Read-LingoJson -Path $manifestPath
    $directory=if($manifest -and $manifest.signature -ceq $signature -and $manifest.directory){[string]$manifest.directory}elseif($manifest -and $manifest.signature -cne $signature){Join-Path $rawRoot ('restart-'+$signature)}else{$rawRoot}
    $fullRoot=[IO.Path]::GetFullPath($rawRoot).TrimEnd('\');$fullDirectory=[IO.Path]::GetFullPath($directory)
    if($fullDirectory -ne $fullRoot -and -not $fullDirectory.StartsWith($fullRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw '原始流恢复目录无效。'}
    [void][IO.Directory]::CreateDirectory($directory)
    if($manifest -and $manifest.signature -cne $signature){Set-LingoObjectField $script:currentAsset 'recoveryMessage' '资源格式或已知内容信息发生变化，重新下载当前未完成资源；其他成品保留。'}
    $extension=[string]$Format.ext
    if($extension -notmatch '^[a-zA-Z0-9]{1,8}$'){throw '原始流文件格式无效。'}
    $path=Join-Path $directory ('media.'+$extension)
    # Old yt-dlp per-asset checkpoints remain reusable: copy matching bytes and fragment sidecar,
    # leaving original checkpoint untouched in case source validation later fails.
    if(-not $manifest -and $LegacyDirectory -and [IO.Directory]::Exists($LegacyDirectory)){
        $legacyName='media.f'+[string]$Format.format_id+'.'+$extension
        $candidates=@($legacyName,('media.'+$extension))
        foreach($candidate in $candidates){
            foreach($suffix in @('.part','.ytdl')){
                $old=Join-Path $LegacyDirectory ($candidate+$suffix);$next=$path+$suffix
                if([IO.File]::Exists($old) -and -not [IO.File]::Exists($next)){[IO.File]::Copy($old,$next)}
            }
            if([IO.File]::Exists((Join-Path $LegacyDirectory $candidate)) -and -not [IO.File]::Exists($path)){[IO.File]::Copy((Join-Path $LegacyDirectory $candidate),$path)}
        }
    }
    [void](Write-LingoJson -Path $manifestPath -Value @{signature=$signature;descriptor=$descriptor;directory=$directory;complete=$false} -Depth 15)
    if(Test-LingoRawMedia -Path $path -Format $Format){Set-LingoObjectField $script:currentAsset 'reusedRaw' $true;return @{path=$path;format=$Format}}
    $formatId=[string]$Format.format_id
    $build={param($loadedPath) Assert-LingoRawMetadata -FormatId $formatId -ExpectedSignature $signature; (Get-BaseArguments $CookieFile)+@('--load-info-json',$loadedPath,'--no-playlist','--no-simulate','--continue','--part','--concurrent-fragments','4','--abort-on-unavailable-fragments','--fixup','never','--progress','--progress-template','download:__LINGO_PROGRESS__%(progress._percent_str)s|%(progress.speed)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.eta)s','--no-quiet','--no-write-subs','--no-write-auto-subs','--paths',$directory,'--output','media.%(ext)s','--format',$formatId)}.GetNewClosure()
    $result=Invoke-LingoCachedTransfer -BuildArguments $build -Url $Url -CookieFile $CookieFile -Directory $ItemDirectory -InfoPath $InfoPath
    if($result.code -ne 0){throw ('yt-dlp 退出代码 '+$result.code+'：'+$result.error)}
    $fresh=@(Get-LingoSourceFormat -Info $script:resolvedInfo -FormatId $formatId)
    if($fresh.Count -eq 1 -and (Get-ShortHash (ConvertTo-Json -InputObject (Get-LingoRawDescriptor $fresh[0]) -Depth 10 -Compress)) -cne $signature){throw '下载时资源信息发生变化，旧断点已保留；请重试当前资源。'}
    if(-not(Test-LingoRawMedia -Path $path -Format $Format)){throw '原始媒体流未通过校验。'}
    [void](Write-LingoJson -Path $manifestPath -Value @{signature=$signature;descriptor=$descriptor;directory=$directory;complete=$true;path=$path} -Depth 15)
    return @{path=$path;format=$Format}
}
function Invoke-LingoMediaProcessing {
    param([string[]]$Arguments,[string]$Phase,[string]$Executable)
    Assert-LingoTransferAllowed -ControlPath $script:controlPath
    $lease=$null
    try{
        $lease=Enter-LingoTransferSlot -StoreRoot $script:storeRoot -Kind processing -ControlPath $script:controlPath -OnWait { Set-TransferPhase 'waiting_capacity'; $script:status.message='等待媒体处理';Stop-TransferRates;Save-ResourceStatus }
        Reset-TransferStatus;Set-TransferPhase $Phase;Stop-TransferRates
        $script:status.message=if($Phase -eq 'merge' -and $script:currentAsset.type -eq 'audio'){'正在无损提取音轨'}elseif($Phase -eq 'merge'){'正在合并视频和音轨'}else{'正在转换资源'}
        Save-ResourceStatus -Force
        $executable=if($Executable){$Executable}else{Join-Path ([string]$config.ffmpegDirectory) 'ffmpeg.exe'}
        if(-not [IO.File]::Exists($executable)){throw 'ffmpeg 不存在。'}
        $result=Invoke-LingoYtDlpAttempt -Arguments $Arguments -Executable $executable -Processing
        if($result.code -ne 0){throw ('媒体处理失败，退出代码 '+$result.code+'：'+$result.error)}
    }finally{if($lease){Exit-LingoTransferSlot -Lease $lease}}
}
function Get-LingoOriginalAudioExtension {
    param($Format)
    $ext = [string](Get-LingoField $Format 'ext')
    if ((Get-LingoField $Format 'vcodec') -eq 'none' -and $ext -in @('m4a','mp3','aac','opus','ogg','flac','wav','webm','mka')) { return $ext }
    $codec = [string](Get-LingoField $Format 'acodec')
    if ($codec -match '^(aac|mp4a)' -or $ext -in @('mp4','m4a','aac')) { return 'm4a' }
    if ($codec -match '^opus') { return 'opus' }
    if ($codec -match '^vorbis') { return 'ogg' }
    if ($codec -match '^mp3') { return 'mp3' }
    if ($codec -eq 'flac') { return 'flac' }
    return 'mka'
}
function Invoke-LingoAssetPipeline {
    param($Plan,$Asset,[string]$Url,[string]$CookieFile,[string]$AssetDirectory,[string]$ItemDirectory)
    $infoPath=Get-LingoDownloadInfoPath -Url $Url -CookieFile $CookieFile -Directory $ItemDirectory
    $expectedExtension=switch($Asset.type){'video'{[string]$config.container}'audio'{if ((Get-LingoField $Asset 'outputFormat' 'mp3') -eq 'original') { Get-LingoOriginalAudioExtension (Get-LingoSourceFormat -Info $script:resolvedInfo -FormatId $Asset.formatId) } else { 'mp3' }}default{[string](Get-LingoField $Asset 'subtitleFormat' $config.subtitleFormat)}}
    $outputPath=Join-Path $AssetDirectory ('media.'+$expectedExtension)
    $processingOutput=Join-Path $AssetDirectory ('media.processing.'+$expectedExtension)
    if([IO.File]::Exists($outputPath)) {try{Test-AssetOutput -Path $outputPath -Type $Asset.type -Format ([string](Get-LingoField $Asset 'subtitleFormat' $config.subtitleFormat));return $outputPath}catch{}}
    if($Asset.type -eq 'subtitle'){
        $timedFormat = if ($expectedExtension -eq 'docx') { 'srt' } else { $expectedExtension }
        $timedPath = $null
        $sourceFlag=if($Asset.source -eq 'auto'){'--write-auto-subs'}else{'--write-subs'}
        $excludeFlag=if($Asset.source -eq 'auto'){'--no-write-subs'}else{'--no-write-auto-subs'}
        $languageRegex='^'+[regex]::Escape([string]$Asset.rawKey)+'$'
        $build={param($loadedPath) (Get-BaseArguments $CookieFile)+@('--load-info-json',$loadedPath,'--no-playlist','--no-simulate','--continue','--part','--skip-download',$sourceFlag,$excludeFlag,'--sub-langs',$languageRegex,'--sub-format',($timedFormat+'/best'),'--paths',$AssetDirectory,'--output','subtitle.%(ext)s')}.GetNewClosure()
        $result=Invoke-LingoCachedTransfer -BuildArguments $build -Url $Url -CookieFile $CookieFile -Directory $ItemDirectory -InfoPath ([ref]$infoPath)
        if($result.code -ne 0){throw ('字幕下载失败：'+$result.error)}
        if ((Get-UrlSite $Url) -eq 'radiofrance' -and $Asset.source -eq 'provided') {
            $variants = Get-LingoField (Get-LingoField $script:resolvedInfo 'subtitles') ([string]$Asset.rawKey)
            $transcript = @($variants | Where-Object { Test-LingoRadioTranscriptVariant $_ }).Count -gt 0
            if ($transcript) {
                $rawTranscript = Join-Path $AssetDirectory ('subtitle.' + [string]$Asset.rawKey + '.json')
                if (-not [IO.File]::Exists($rawTranscript)) { throw '没有取得 Radio France 官方转录。' }
                $timedPath = Join-Path $AssetDirectory ('subtitle.transcript.' + $timedFormat)
                Convert-LingoRadioTranscript -SourcePath $rawTranscript -DestinationPath $timedPath -Format $timedFormat
            }
        }
        if (-not $timedPath) {
            $rawFiles=@(Get-ChildItem -LiteralPath $AssetDirectory -File | Where-Object {$_.BaseName -ceq ('subtitle.'+[string]$Asset.rawKey) -and $_.Extension -in @('.srt','.vtt','.ttml','.ass','.lrc','.json3','.srv1','.srv2','.srv3') } | Sort-Object LastWriteTimeUtc -Descending)
            if($rawFiles.Count -eq 0){throw '没有取得所选字幕轨道。'}
            $raw=$rawFiles[0]
            if($raw.Extension -eq '.json3'){
                $json3Srt=Join-Path $AssetDirectory 'subtitle.from-json3.srt'
                Convert-LingoJson3Subtitle -SourcePath $raw.FullName -DestinationPath $json3Srt
                $raw=[IO.FileInfo]::new($json3Srt)
            }
            if($raw.Extension -ieq ('.'+$timedFormat)){$timedPath = $raw.FullName}
            else{
                # Conversion reads embedded local subtitle data, so no network is held or repeated.
                $localInfo=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $script:resolvedInfo -Depth 60)
                Set-LingoObjectField $localInfo 'subtitles' @{ ([string]$Asset.rawKey)=@(@{ext=$raw.Extension.TrimStart('.');data=[IO.File]::ReadAllText($raw.FullName)}) }
                Set-LingoObjectField $localInfo 'automatic_captions' @{}
                foreach($field in @('requested_subtitles','requested_downloads','requested_formats')){if($localInfo.PSObject.Properties[$field]){$localInfo.PSObject.Properties.Remove($field)}}
                $localPath=Join-Path $AssetDirectory 'subtitle.local.json'
                [void](Write-LingoJson -Path $localPath -Value $localInfo -Depth 60)
                $conversion=(Get-BaseArguments $null)+@('--load-info-json',$localPath,'--no-playlist','--no-simulate','--skip-download','--write-subs','--no-write-auto-subs','--sub-langs',$languageRegex,'--sub-format',$raw.Extension.TrimStart('.'),'--convert-subs',$timedFormat,'--paths',$AssetDirectory,'--output','converted.%(ext)s')
                Invoke-LingoMediaProcessing -Phase convert -Executable ([string]$config.ytDlpPath) -Arguments $conversion
                $converted=Join-Path $AssetDirectory ('converted.'+[string]$Asset.rawKey+'.'+$timedFormat)
                if(-not [IO.File]::Exists($converted)){throw '字幕格式转换没有生成期望的文件。'}
                $timedPath = $converted
            }
        }
        if ($expectedExtension -eq 'docx') {
            Assert-LingoTransferAllowed -ControlPath $script:controlPath
            Convert-LingoSubtitleToWord -SourcePath $timedPath -DestinationPath $processingOutput
            Assert-LingoSubtitleWordDocument -Path $processingOutput
            [IO.File]::Copy($processingOutput, $outputPath, $true)
        } else {
            Test-AssetOutput -Path $timedPath -Type 'subtitle' -Format $timedFormat
            [IO.File]::Copy($timedPath, $outputPath, $true)
        }
        return $outputPath
    }
    $formats=Get-LingoSelectedFormats -Expression ([string]$Asset.formatId) -InfoPath $infoPath -CookieFile $CookieFile
    Set-LingoObjectField $script:currentAsset 'downloadFormatIds' @($formats | ForEach-Object {[string]$_.format_id})
    $rawMedia=@()
    foreach($format in $formats){$rawMedia+=Get-LingoRawMedia -Format $format -Url $Url -CookieFile $CookieFile -ItemDirectory $ItemDirectory -LegacyDirectory $AssetDirectory -InfoPath ([ref]$infoPath)}
    if($Asset.type -eq 'audio'){
        if($rawMedia.Count -ne 1){throw '独立音轨包含多个原始格式。'}
        $raw = $rawMedia[0]
        $original = (Get-LingoField $Asset 'outputFormat' 'mp3') -eq 'original'
        $pure = (Get-LingoField $raw.format 'vcodec') -eq 'none'
        $rawExtension = [IO.Path]::GetExtension([string]$raw.path).TrimStart('.')
        if ($pure -and $rawExtension -eq $expectedExtension -and ($original -or ($expectedExtension -eq 'mp3' -and (Get-LingoField $raw.format 'acodec') -match '^mp3'))) {
            [IO.File]::Copy([string]$raw.path, $processingOutput, $true)
        } elseif ($original) {
            Invoke-LingoMediaProcessing -Phase merge -Arguments @('-nostdin','-hide_banner','-loglevel','error','-y','-i',[string]$raw.path,'-map','0:a:0','-vn','-sn','-dn','-c:a','copy',$processingOutput)
        } else {
            Invoke-LingoMediaProcessing -Phase convert -Arguments @('-nostdin','-hide_banner','-loglevel','error','-y','-i',[string]$raw.path,'-map','0:a:0','-vn','-c:a','libmp3lame','-q:a','0',$processingOutput)
        }
    }else{
        $video=@($rawMedia | Where-Object {$_.format.vcodec -and $_.format.vcodec -ne 'none'} | Select-Object -First 1)
        $audio=@($rawMedia | Where-Object {$_.format.acodec -and $_.format.acodec -ne 'none'} | Select-Object -First 1)
        if($video.Count -ne 1 -or $audio.Count -ne 1){throw '完整视频缺少所选视频或音轨。'}
        $arguments=@('-nostdin','-hide_banner','-loglevel','error','-y','-i',[string]$video[0].path)
        $audioIndex=0
        if([string]$video[0].path -cne [string]$audio[0].path){$arguments+=@('-i',[string]$audio[0].path);$audioIndex=1}
        $arguments+=@('-map','0:v:0','-map',($audioIndex.ToString()+':a:0'),'-c','copy','-sn')
        if($expectedExtension -eq 'mp4'){$arguments+=@('-movflags','+faststart')}
        $arguments+=@($processingOutput)
        Invoke-LingoMediaProcessing -Phase merge -Arguments $arguments
    }
    Test-AssetOutput -Path $processingOutput -Type $Asset.type -Format ([string](Get-LingoField $Asset 'subtitleFormat' $config.subtitleFormat))
    if([IO.File]::Exists($outputPath)){[IO.File]::Move($outputPath,($outputPath+'.invalid-'+[guid]::NewGuid().ToString('N').Substring(0,8)))} 
    [IO.File]::Move($processingOutput,$outputPath)
    return $outputPath
}

function Clear-LingoCompletedRawCache {
    param([string]$Url,[string]$MediaId)
    $itemDirectory=Join-Path $script:partialRoot ($config.id+'\'+(Get-LingoItemHash -Url $Url -MediaId $MediaId))
    $rawDirectory=Join-Path $itemDirectory 'raw'
    try{
        $allowed=[IO.Path]::GetFullPath($script:partialRoot).TrimEnd('\')+'\'
        $resolvedItem=[IO.Path]::GetFullPath($itemDirectory)
        $resolvedRaw=[IO.Path]::GetFullPath($rawDirectory)
        if(-not $resolvedItem.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($resolvedRaw) -ne $resolvedItem -or [IO.Path]::GetFileName($resolvedRaw) -ne 'raw'){throw '原始媒体缓存清理目录无效。'}
        foreach($ancestor in @([IO.Path]::GetFullPath($script:partialRoot),[IO.Path]::GetDirectoryName($resolvedItem),$resolvedItem)){
            if([IO.Directory]::Exists($ancestor) -and (([IO.DirectoryInfo]::new($ancestor)).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw '原始媒体缓存父目录包含链接，保留缓存。'}
        }
        if(-not [IO.Directory]::Exists($resolvedRaw)){return}
        $pending=[Collections.Generic.Stack[IO.DirectoryInfo]]::new();$pending.Push([IO.DirectoryInfo]::new($resolvedRaw))
        while($pending.Count){
            $directory=$pending.Pop()
            if(($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw '原始媒体缓存包含链接，保留缓存。'}
            foreach($entry in $directory.GetFileSystemInfos()){
                if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw '原始媒体缓存包含链接，保留缓存。'}
                if($entry -is [IO.DirectoryInfo]){$pending.Push($entry)}
            }
        }
        Remove-Item -LiteralPath $resolvedRaw -Recurse -Force
    }catch{Write-LingoIoDiagnostic -Path (Join-Path $itemDirectory 'raw-cleanup') -Operation 'cleanup_deferred' -Message $_.Exception.Message}
}

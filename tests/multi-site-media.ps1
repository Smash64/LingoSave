$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'resource-planner.ps1')
$script:checks=0
function Check([bool]$Value,[string]$Name){if(-not$Value){throw $Name};$script:checks++;Write-Host ('PASS '+$Name)}
$info=@{id='ted-hls';title='TED audio';extractor_key='TedTalk';formats=@(
 @{format_id='video-720';url='https://example.invalid/video.m3u8';protocol='m3u8_native';vcodec='h264';acodec='none';height=720},
 @{format_id='hls-audio0-low';url='https://example.invalid/low.m3u8';protocol='m3u8_native';vcodec='none';acodec=$null;language='en';abr=64},
 @{format_id='hls-audio0-high';url='https://example.invalid/high.m3u8';protocol='m3u8_native';vcodec='none';acodec=$null;language='en';abr=192},
 @{format_id='silent';url='https://example.invalid/silent.m3u8';protocol='m3u8_native';vcodec='none';acodec='none'},
 @{format_id='http';url='https://example.invalid/file.mp4';protocol='https';vcodec=$null;acodec=$null},
 @{format_id='storyboard';url='https://example.invalid/story.mhtml';protocol='mhtml';vcodec='none';acodec=$null}
);subtitles=@{};automatic_captions=@{}}
$source='https://www.ted.com/talks/sample'
[void](Normalize-LingoMediaInfo -Info $info -SourceUrl $source)
Check ($info.formats[1].acodec-eq'unknown'-and$info.formats[2].acodec-eq'unknown') 'TED and other audio-only HLS renditions with missing CODECS stay selectable'
Check ($info.formats[3].acodec-eq'none') 'explicitly silent formats never become audio'
Check ($null-eq$info.formats[4].acodec-and$null-eq$info.formats[5].acodec) 'unknown HTTP video and storyboards are not guessed to be audio'
Check (-not$info.formats[1].ContainsKey('audio_track_id')) 'other providers never inherit ARTE rendition identity fields'
$plan=New-LingoResourcePlan -Info $info -SourceUrl $source -Config @{parts=@{video=$false;audio=$true;subtitles=$false};audioLanguages=@('en')}
Check ($plan.assets.Count-eq 1-and$plan.assets[0].type-eq'audio'-and$plan.assets[0].formatId-eq'hls-audio0-high') 'audio-only TED request chooses the highest bitrate audio without adding video'
$plan=New-LingoResourcePlan -Info $info -SourceUrl $source -Config @{parts=@{video=$true;audio=$true;subtitles=$false};audioLanguages=@('en')}
Check (@($plan.assets|Where-Object type -eq 'audio').Count-eq 1-and@($plan.assets|Where-Object type -eq 'video').Count-eq 1) 'video and independent HLS audio remain separately planned'
[void](Normalize-LingoMediaInfo -Info $info -SourceUrl $source)
Check ($info.formats[1].acodec-eq'unknown') 'cached normalized metadata is stable across repeated inspection'
Write-Host "PASS $script:checks generic HLS media checks."
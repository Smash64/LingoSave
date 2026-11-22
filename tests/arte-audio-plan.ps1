$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'resource-planner.ps1')
. (Join-Path $root 'state-io.ps1')
. (Join-Path $root 'media-cache.ps1')
$script:assertions = 0
function Assert-Arte {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ARTE audio acceptance failed: $Message" }
    $script:assertions++
    Write-Output "PASS $Message"
}
function Copy-ArteInfo {
    param($Info)
    return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Info -Depth 30)
}
function New-ArteConfig {
    param([string[]]$Languages = @('fr'), [bool]$Video = $true, [hashtable]$Selections = @{})
    return @{ parts=@{video=$Video;audio=$true;subtitles=$false}; quality='1080p'; audioLanguages=@($Languages); sourceSelections=$Selections }
}
$fixturePath = Join-Path $PSScriptRoot 'fixtures\arte-five-audio.json'
$fixture = [IO.File]::ReadAllText($fixturePath) | ConvertFrom-Json
$url = [string]$fixture.webpage_url
$rawIds = @($fixture.formats | ForEach-Object format_id)
$normalized = Normalize-LingoMediaInfo -Info $fixture -SourceUrl $url
Assert-Arte ([object]::ReferenceEquals($fixture,$normalized)) 'normalization retains the same media object'
$audio = @($normalized.formats | Where-Object vcodec -eq 'none')
Assert-Arte ($audio.Count -eq 5 -and @($audio | Where-Object acodec -eq 'unknown').Count -eq 5) 'five known HLS audio renditions are recognized despite missing acodec'
Assert-Arte (@($audio | ForEach-Object {Get-LingoAudioIdentity $_} | Select-Object -Unique).Count -eq 5) 'main, multilingual and accessibility audio keep five identities'
Assert-Arte (@($audio | Where-Object audio_role -eq 'main').Count -eq 3 -and @($audio | Where-Object audio_role -eq 'description').Count -eq 2) 'rendition names distinguish ordinary audio from confort audio'
Assert-Arte (@($audio | Where-Object {$_.language -eq 'de' -and $_.audio_role -eq 'description' -and $_.audio_display_name -eq 'German — Audio description'}).Count -eq 1) 'German accessibility audio is labeled from rendition name despite French version note'
Assert-Arte (@($audio | Where-Object {$_.language -eq 'fr' -and $_.audio_role -eq 'description' -and $_.audio_display_name -eq 'French — Audio description'}).Count -eq 1) 'French accessibility audio has its own display name'
Assert-Arte ((Get-LingoEnglishLanguageName 'mul') -eq 'Multilingual' -and @($audio | Where-Object {$_.language -eq 'mul' -and $_.audio_display_name -eq 'Multilingual'}).Count -eq 1) 'multilingual is a recognized language display name'
Assert-Arte ((@($normalized.formats | ForEach-Object format_id) -join '|') -ceq ($rawIds -join '|')) 'normalization retains exact downloader format IDs'
Assert-Arte ($normalized.formats[-1].acodec -eq 'none' -and -not $normalized.formats[-1].PSObject.Properties['audio_role']) 'video-only formats are not marked as audio renditions'
$before = ConvertTo-Json -InputObject $normalized -Depth 30 -Compress
[void](Normalize-LingoMediaInfo -Info $normalized -SourceUrl $url)
Assert-Arte ($before -ceq (ConvertTo-Json -InputObject $normalized -Depth 30 -Compress)) 'normalization is idempotent for cached metadata'

$frPlan = New-LingoResourcePlan -Info $normalized -Config (New-ArteConfig) -SourceUrl $url
$frAssets = @($frPlan.assets | Where-Object type -eq 'audio')
Assert-Arte ($frAssets.Count -eq 1 -and $frAssets[0].formatId -ceq 'VF-STF-audio_0-français') 'French language preference downloads regular French audio only'
Assert-Arte ($frPlan.assets[0].formatId -ceq 'bestvideo[height<=1080]+VF-STF-audio_0-français') 'full video uses regular preferred French audio instead of audio description'
$dePlan = New-LingoResourcePlan -Info $normalized -Config (New-ArteConfig -Languages @('de') -Video $false) -SourceUrl $url
Assert-Arte ($dePlan.assets.Count -eq 1 -and $dePlan.assets[0].formatId -ceq 'VF-STF-audio_0-allemand') 'German preference is an independent ordinary audio-only request'
$mulPlan = New-LingoResourcePlan -Info $normalized -Config (New-ArteConfig -Languages @('mul') -Video $false) -SourceUrl $url
Assert-Arte ($mulPlan.assets.Count -eq 1 -and $mulPlan.assets[0].formatId -ceq 'VF-STF-audio_0-multilingue') 'multilingual audio can be requested independently'
$allPlan = New-LingoResourcePlan -Info $normalized -Config (New-ArteConfig -Languages @() -Video $false) -SourceUrl $url
Assert-Arte ($allPlan.assets.Count -eq 3 -and @($allPlan.assets | Where-Object {$_.formatId -match 'confort'}).Count -eq 0) 'automatic ARTE language choices retain the three ordinary audio tracks'
$selected = @{}; $selected[$url] = @{mediaId=$normalized.id;audioFormatIds=@($audio | ForEach-Object format_id);subtitleTracks=@();explicitAudio=$true;explicitSubtitles=$true}
$exactPlan = New-LingoResourcePlan -Info $normalized -Config (New-ArteConfig -Selections $selected) -SourceUrl $url
Assert-Arte (@($exactPlan.assets | Where-Object type -eq 'audio').Count -eq 5 -and $exactPlan.issues.Count -eq 0) 'explicit selection downloads all five exact audio IDs without folding roles'
$selected[$url].audioFormatIds = @('VF-STF-audio_0-français__confort_audio_', 'VF-STF-audio_0-français')
$descriptionPlan = New-LingoResourcePlan -Info $normalized -Config (New-ArteConfig -Selections $selected) -SourceUrl $url
Assert-Arte (@($descriptionPlan.assets | Where-Object type -eq 'audio').Count -eq 2 -and $descriptionPlan.assets[0].formatId -ceq 'bestvideo[height<=1080]+VF-STF-audio_0-français__confort_audio_') 'explicit French accessibility choice stays exact for standalone audio and full video'
$videoConfig = New-ArteConfig -Languages @('de'); $videoConfig.parts.audio=$false
$videoOnly = New-LingoResourcePlan -Info $normalized -Config $videoConfig -SourceUrl $url
Assert-Arte ($videoOnly.assets.Count -eq 1 -and $videoOnly.assets[0].formatId -ceq 'bestvideo[height<=1080]+VF-STF-audio_0-allemand') 'video-only ARTE request respects preferred regular audio language'
$inspectedVideoConfig = New-ArteConfig -Languages @('fr') -Selections $selected; $inspectedVideoConfig.parts.audio=$false
$inspectedVideoOnly = New-LingoResourcePlan -Info $normalized -Config $inspectedVideoConfig -SourceUrl $url
Assert-Arte ($inspectedVideoOnly.assets.Count -eq 1 -and $inspectedVideoOnly.assets[0].formatId -ceq 'bestvideo[height<=1080]+VF-STF-audio_0-français' -and $inspectedVideoOnly.issues.Count -eq 0) 'inspected video-only ARTE request still uses ordinary preferred audio without adding audio assets'
$descriptionOnly = Copy-ArteInfo $normalized
$descriptionOnly.formats = @($descriptionOnly.formats | Where-Object {$_.vcodec -ne 'none' -or ($_.language -eq 'fr' -and $_.audio_role -eq 'description')})
$descriptionOnlyPlan = New-LingoResourcePlan -Info $descriptionOnly -Config (New-ArteConfig -Video $false) -SourceUrl $url
Assert-Arte ($descriptionOnlyPlan.assets.Count -eq 1 -and $descriptionOnlyPlan.assets[0].formatId -match 'confort') 'a language with only accessibility audio remains available'

$unrelated = @{extractor='Youtube';webpage_url='https://www.youtube.com/watch?v=fixture';formats=@(@{format_id='VF-STF-audio_0-français';vcodec='none';acodec=$null;language='fr';protocol='m3u8_native'})}
[void](Normalize-LingoMediaInfo -Info $unrelated -SourceUrl $unrelated.webpage_url)
Assert-Arte ($unrelated.formats[0].acodec -eq 'unknown' -and -not $unrelated.formats[0].ContainsKey('audio_role')) 'other explicit HLS audio is recognized without receiving ARTE track roles'
$nonArteRoles = Copy-ArteInfo $normalized; $nonArteRoles.extractor='Youtube';$nonArteRoles.extractor_key='Youtube';$nonArteRoles.webpage_url='https://www.youtube.com/watch?v=fixture'
$nonArtePlan = New-LingoResourcePlan -Info $nonArteRoles -Config (New-ArteConfig -Video $false) -SourceUrl $nonArteRoles.webpage_url
Assert-Arte (@($nonArtePlan.assets | Where-Object type -eq 'audio').Count -eq 2) 'non-ARTE same-language role selection preserves existing behavior'
$ineligible = @{extractor='ArteTV';formats=@(
    @{format_id='VF-STF-audio_0-français';vcodec='none';acodec='none';language='fr';protocol='m3u8_native'},
    @{format_id='VF-STF-audio_1-français';vcodec='h264';acodec=$null;language='fr';protocol='m3u8_native'},
    @{format_id='VF-STF-audio_2-français';vcodec='none';acodec=$null;language='fr';protocol='https';url='https://media.example.invalid/audio.mp4'},
    @{format_id='unidentified-hls';vcodec='none';acodec=$null;language='fr';protocol='m3u8_native'}
)}
[void](Normalize-LingoMediaInfo -Info $ineligible -SourceUrl $url)
Assert-Arte ($ineligible.formats[0].acodec -eq 'none' -and @($ineligible.formats | Where-Object {$_.audio_role}).Count -eq 0) 'explicit silent, video, non-HLS and unidentified streams are excluded'
$dict = @{extractor='ArteTV';formats=@(@{format_id='VF-STF-audio_0-multilingue';vcodec='none';acodec=$null;language='mul';protocol='m3u8_native'})}
[void](Normalize-LingoMediaInfo -Info $dict -SourceUrl $url)
Assert-Arte ($dict.formats[0].acodec -eq 'unknown' -and $dict.formats[0].audio_role -eq 'main' -and $dict.formats[0].audio_display_name -eq 'Multilingual') 'dictionary metadata is normalized like JSON metadata'
$selectedMetadata = @{extractor='ArteTV';requested_downloads=@(@{requested_formats=@(@{format_id='VF-STF-audio_0-allemand';vcodec='none';acodec=$null;language='de';protocol='m3u8_native'})})}
[void](Normalize-LingoMediaInfo -Info $selectedMetadata -SourceUrl $url)
Assert-Arte ($selectedMetadata.requested_downloads[0].requested_formats[0].audio_display_name -eq 'German') 'selected-format metadata also keeps rendition identity'

$legacy = @{id='arte-legacy-audio';extractor='ArteTV';formats=@(
    @{format_id='VF-audio_0-Français';vcodec='none';acodec=$null;language='fr';protocol='m3u8_native';format_note='Français [VF]'},
    @{format_id='VAUD-audio_0-Français';vcodec='none';acodec=$null;language='fr';protocol='m3u8_native';format_note='Audiodescription [VAUD]'}
);subtitles=@{};automatic_captions=@{}}
[void](Normalize-LingoMediaInfo -Info $legacy -SourceUrl $url)
Assert-Arte ($legacy.formats[0].audio_role -eq 'main' -and $legacy.formats[1].audio_role -eq 'description' -and (Get-LingoAudioIdentity $legacy.formats[0]) -cne (Get-LingoAudioIdentity $legacy.formats[1])) 'legacy VF and VAUD streams with the same rendition name retain different roles and identities'
$legacyPlan = New-LingoResourcePlan -Info $legacy -Config (New-ArteConfig -Video $false) -SourceUrl $url
Assert-Arte ($legacyPlan.assets.Count -eq 1 -and $legacyPlan.assets[0].formatId -ceq 'VF-audio_0-Français') 'legacy French language preference uses ordinary VF audio'
$existingRole = @{extractor='ArteTV';formats=@(@{format_id='VF-audio_0-Français';vcodec='none';acodec='aac';language='fr';protocol='m3u8_native';audio_role='commentary'})}
[void](Normalize-LingoMediaInfo -Info $existingRole -SourceUrl $url)
Assert-Arte ($existingRole.formats[0].audio_role -eq 'commentary' -and $existingRole.formats[0].acodec -eq 'aac') 'existing explicit audio roles and known codecs remain intact'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('lingosave-arte-audio-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempRoot)
try {
    [IO.File]::Copy($fixturePath,(Join-Path $tempRoot 'arte-fixture.json'))
    $fake = @('[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)', '[IO.File]::ReadAllText((Join-Path $PSScriptRoot ''arte-fixture.json''))') -join "`r`n"
    $fakePath = Join-Path $tempRoot 'fake-arte-extractor.ps1'
    [IO.File]::WriteAllText($fakePath,$fake,[Text.UTF8Encoding]::new($true))
    $cachePath = Join-Path $tempRoot 'metadata.json'
    $result = & (Join-Path $root 'media-inspection.ps1') -Url $url -YtDlpPath $fakePath -MetadataCachePath $cachePath -CookieRevision 'fixture-cookie' | ConvertFrom-Json
    Assert-Arte ($result.audioTracks.Count -eq 5 -and $result.audioIdentityCount -eq 5) 'inspection exposes five tracks and five audio identities'
    Assert-Arte (@($result.audioTracks | Where-Object {$_.role -eq 'description' -and $_.displayName -like '*Audio description*'}).Count -eq 2) 'inspection exposes the two descriptive labels and role fields'
    Assert-Arte (@($result.audioTracks | Where-Object {$_.language -eq 'mul' -and $_.englishLanguageName -eq 'Multilingual'}).Count -eq 1) 'inspection displays multilingual instead of Unknown (mul)'
    Assert-Arte (@($result.audioTracks | ForEach-Object trackId | Select-Object -Unique).Count -eq 5 -and @($result.audioTracks | Where-Object {$_.name -match 'confort audio'}).Count -eq 2) 'inspection keeps stable track IDs and original rendition names'
    $cache = Read-LingoMetadataCache -Path $cachePath -Url $url -CookieRevision 'fixture-cookie' -RequireComplete
    Assert-Arte ($null -ne $cache -and @($cache.formats | Where-Object acodec -eq 'unknown').Count -eq 5) 'inspection caches normalized complete audio metadata for downloads'
} finally {
    $fullRoot = [IO.Path]::GetFullPath($tempRoot)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $fullRoot.StartsWith($tempParent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($fullRoot) -notlike 'lingosave-arte-audio-*') { throw 'ARTE fixture cleanup path is invalid.' }
    Remove-Item -LiteralPath $fullRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "ARTE audio planning and inspection passed: $script:assertions assertions."
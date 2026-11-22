$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'resource-planner.ps1')

$multi = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\acceptance-media.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$single = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\acceptance-single-media.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$multiUrl = [string]$multi.webpage_url
$singleUrl = [string]$single.webpage_url

function Assert-Plan {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Resource planning acceptance failed: $Message" }
    Write-Output "PASS $Message"
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-Plan $threw $Message
}

function New-Config {
    param(
        [bool]$Video = $true,
        [bool]$Audio = $true,
        [bool]$Subtitles = $true,
        [string[]]$AudioLanguages = @(),
        [string[]]$SubtitleLanguages = @(),
        [bool]$AutoSimplify = $false,
        [hashtable]$SourceSelections = @{}
    )
    return @{
        parts = @{ video = $Video; audio = $Audio; subtitles = $Subtitles }
        quality = '1080p'
        audioLanguages = @($AudioLanguages)
        subtitleLanguages = @($SubtitleLanguages)
        autoSimplify = $AutoSimplify
        sourceSelections = $SourceSelections
    }
}

$selection = @{
    mediaId = 'arte-acceptance-001'
    audioFormatIds = @('audio-fr-original', 'audio-de-dub')
    subtitleTracks = @(
        @{ rawKey = 'fr'; source = 'provided' },
        @{ rawKey = 'fr-acc'; source = 'provided' },
        @{ rawKey = 'fr'; source = 'auto' }
    )
}
$sourceSelections = @{}
$sourceSelections[$multiUrl] = $selection
$config = New-Config -SourceSelections $sourceSelections
$plan = New-LingoResourcePlan -Info $multi -Config $config -SourceUrl $multiUrl
$keys = @($plan.assets | ForEach-Object { [string]$_.key })
Assert-Plan ($plan.id -eq 'arte-acceptance-001' -and -not $plan.simplified) 'exact multi-track plan keeps media identity and selection'
Assert-Plan ($keys.Count -eq 6 -and $keys -contains 'video' -and $keys -contains 'audio:audio-fr-original' -and $keys -contains 'audio:audio-de-dub') 'full video and two selected audio assets stay separate'
Assert-Plan ((@($plan.assets | Where-Object type -eq 'video')[0]).formatId -eq 'bestvideo[height<=1080]+audio-fr-original') 'full video does not fall back from its exact selected audio track'
Assert-Plan ($keys -contains 'subtitle:provided:fr' -and $keys -contains 'subtitle:provided:fr-acc' -and $keys -contains 'subtitle:auto:fr') 'fr, fr-acc and same-language automatic captions remain distinct'
Assert-Plan (@($plan.assets | Where-Object { $_.type -eq 'audio' -and $_.formatId -notin @('audio-fr-original', 'audio-de-dub') }).Count -eq 0) 'exact audio selection does not add other formats'

$videoOnly = New-LingoResourcePlan -Info $multi -Config (New-Config -Audio $false -Subtitles $false) -SourceUrl $multiUrl
Assert-Plan ($videoOnly.assets.Count -eq 1 -and $videoOnly.assets[0].type -eq 'video') 'video-only plan contains no separate audio or subtitle asset'

$audioSelection = @{}
$audioSelection[$multiUrl] = @{ mediaId = 'arte-acceptance-001'; audioFormatIds = @('audio-de-dub'); subtitleTracks = @() }
$audioOnly = New-LingoResourcePlan -Info $multi -Config (New-Config -Video $false -Subtitles $false -SourceSelections $audioSelection) -SourceUrl $multiUrl
Assert-Plan ($audioOnly.assets.Count -eq 1 -and $audioOnly.assets[0].key -eq 'audio:audio-de-dub') 'audio-only plan retains exact selected track'

$subtitleSelection = @{}
$subtitleSelection[$multiUrl] = @{ mediaId = 'arte-acceptance-001'; audioFormatIds = @(); subtitleTracks = @(@{ rawKey = 'fr-acc'; source = 'provided' }, @{ rawKey = 'fr'; source = 'auto' }) }
$subtitleOnly = New-LingoResourcePlan -Info $multi -Config (New-Config -Video $false -Audio $false -SourceSelections $subtitleSelection) -SourceUrl $multiUrl
$subtitleKeys = @($subtitleOnly.assets | ForEach-Object { [string]$_.key })
Assert-Plan ($subtitleKeys.Count -eq 2 -and $subtitleKeys -contains 'subtitle:provided:fr-acc' -and $subtitleKeys -contains 'subtitle:auto:fr') 'subtitle-only plan retains raw key and source'

$singleNoSubtitle = New-LingoResourcePlan -Info $single -Config (New-Config -AutoSimplify $true) -SourceUrl $singleUrl
Assert-Plan (-not $singleNoSubtitle.simplified -and $singleNoSubtitle.fallbackVideo -and $singleNoSubtitle.assets.Count -eq 2 -and $singleNoSubtitle.assets[0].type -eq 'video' -and $singleNoSubtitle.assets[1].type -eq 'audio') 'single-audio no-subtitle source keeps requested audio and a complete fallback video'
Assert-Plan ($singleNoSubtitle.issues.Count -eq 1 -and $singleNoSubtitle.issues[0].type -eq 'subtitle' -and $singleNoSubtitle.issues[0].status -eq 'skipped') 'missing default subtitles are skipped without discarding existing audio'

$oneAudioWithSubtitle = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $multi -Depth 12)
$oneAudioWithSubtitle.formats = @($oneAudioWithSubtitle.formats | Where-Object { $_.format_id -notin @('audio-de-dub', 'combined-fr-720') })
$singleAudioWithSubtitles = New-LingoResourcePlan -Info $oneAudioWithSubtitle -Config (New-Config -AutoSimplify $true) -SourceUrl $multiUrl
Assert-Plan (-not $singleAudioWithSubtitles.simplified -and -not $singleAudioWithSubtitles.fallbackVideo -and $singleAudioWithSubtitles.assets.Count -eq 4 -and @($singleAudioWithSubtitles.assets | Where-Object type -eq 'audio').Count -eq 1 -and @($singleAudioWithSubtitles.assets | Where-Object type -eq 'subtitle').Count -eq 2) 'single audio language retains selected audio and subtitles despite legacy autoSimplify option'

$multiAudioNoSubtitle = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $multi -Depth 12)
$multiAudioNoSubtitle.subtitles = [pscustomobject]@{}
$multiAudioNoSubtitle.automatic_captions = [pscustomobject]@{}
$noSubtitles = New-LingoResourcePlan -Info $multiAudioNoSubtitle -Config (New-Config -AutoSimplify $true) -SourceUrl $multiUrl
Assert-Plan (-not $noSubtitles.simplified -and $noSubtitles.fallbackVideo -and $noSubtitles.assets.Count -eq 3 -and @($noSubtitles.assets | Where-Object type -eq 'audio').Count -eq 2 -and @($noSubtitles.assets | Where-Object type -eq 'video').Count -eq 1) 'no subtitles keeps both available audio languages and only one complete video'

$multiAudioAutoSubtitles = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $multi -Depth 12)
$multiAudioAutoSubtitles.subtitles = [pscustomobject]@{}
$autoOnlyConfig = New-Config -AudioLanguages @('fr', 'de') -SubtitleLanguages @('en') -AutoSimplify $true
$autoOnlyPlan = New-LingoResourcePlan -Info $multiAudioAutoSubtitles -Config $autoOnlyConfig -SourceUrl $multiUrl
$autoOnlyKeys = @($autoOnlyPlan.assets | ForEach-Object { [string]$_.key })
Assert-Plan (-not $autoOnlyPlan.simplified -and $autoOnlyKeys.Count -eq 4 -and $autoOnlyKeys -contains 'video' -and $autoOnlyKeys -contains 'audio:audio-fr-original' -and $autoOnlyKeys -contains 'audio:audio-de-dub' -and $autoOnlyKeys -contains 'subtitle:auto:en' -and $autoOnlyKeys -notcontains 'subtitle:auto:fr') 'automatic captions count as available, and only preferred auto language is selected'

$audioNotSimplified = New-LingoResourcePlan -Info $single -Config (New-Config -Video $false -Subtitles $false -AutoSimplify $true) -SourceUrl $singleUrl
Assert-Plan (-not $audioNotSimplified.simplified -and $audioNotSimplified.assets.Count -eq 1 -and $audioNotSimplified.assets[0].type -eq 'audio' -and $audioNotSimplified.assets[0].formatId -eq 'combined-only') 'audio-only selection remains audio when auto simplification is enabled'

$plainFrenchSubtitles = New-LingoResourcePlan -Info $multi -Config (New-Config -Video $false -Audio $false -SubtitleLanguages @('fr')) -SourceUrl $multiUrl
$plainFrenchKeys = @($plainFrenchSubtitles.assets | ForEach-Object { [string]$_.key })
Assert-Plan ($plainFrenchKeys.Count -eq 1 -and $plainFrenchKeys[0] -eq 'subtitle:provided:fr') 'plain French preference does not silently include fr-acc'

$wrongIdentity = @{}
$wrongIdentity[$multiUrl] = @{ mediaId = 'different-video'; audioFormatIds = @('audio-fr-original'); subtitleTracks = @() }
Assert-Throws { New-LingoResourcePlan -Info $multi -Config (New-Config -SourceSelections $wrongIdentity) -SourceUrl $multiUrl } 'changed media identity requires new inspection'

$missingAudio = @{}
$missingAudio[$multiUrl] = @{ mediaId = 'arte-acceptance-001'; audioFormatIds = @('missing-format'); subtitleTracks = @(@{ rawKey = 'fr'; source = 'provided' }); explicitAudio = $true; explicitSubtitles = $true }
$missingExactAudioPlan = New-LingoResourcePlan -Info $multi -Config (New-Config -Video $false -SourceSelections $missingAudio) -SourceUrl $multiUrl
Assert-Plan ($missingExactAudioPlan.fallbackVideo -and $missingExactAudioPlan.assets.Count -eq 2 -and $missingExactAudioPlan.assets[0].type -eq 'video' -and $missingExactAudioPlan.assets[1].key -eq 'subtitle:provided:fr' -and $missingExactAudioPlan.issues.Count -eq 1 -and $missingExactAudioPlan.issues[0].formatId -eq 'missing-format' -and $missingExactAudioPlan.issues[0].status -eq 'skipped') 'missing exact audio skips that track and keeps existing subtitle plus one complete fallback video'

$missingSubtitle = @{}
$missingSubtitle[$multiUrl] = @{ mediaId = 'arte-acceptance-001'; audioFormatIds = @('audio-fr-original'); subtitleTracks = @(@{ rawKey = 'de'; source = 'provided' }); explicitAudio = $true; explicitSubtitles = $true }
$missingExactSubtitlePlan = New-LingoResourcePlan -Info $multi -Config (New-Config -Video $false -SourceSelections $missingSubtitle) -SourceUrl $multiUrl
Assert-Plan ($missingExactSubtitlePlan.fallbackVideo -and $missingExactSubtitlePlan.assets.Count -eq 2 -and $missingExactSubtitlePlan.assets[0].type -eq 'video' -and $missingExactSubtitlePlan.assets[1].key -eq 'audio:audio-fr-original' -and $missingExactSubtitlePlan.issues.Count -eq 1 -and $missingExactSubtitlePlan.issues[0].rawKey -eq 'de' -and $missingExactSubtitlePlan.issues[0].source -eq 'provided' -and $missingExactSubtitlePlan.issues[0].status -eq 'skipped') 'missing exact subtitle skips that source and keeps existing selected audio plus a complete fallback video'

$unavailableAudio = New-LingoResourcePlan -Info $multi -Config (New-Config -Video $false -Subtitles $false -AudioLanguages @('it')) -SourceUrl $multiUrl
Assert-Plan (-not $unavailableAudio.fallbackVideo -and $unavailableAudio.assets.Count -eq 0 -and @($unavailableAudio.issues | Where-Object { $_.type -eq 'audio' -and $_.language -eq 'it' -and $_.status -eq 'skipped' }).Count -eq 1) 'unavailable audio-only preference skips without downloading video'

$unavailableSubtitle = New-LingoResourcePlan -Info $single -Config (New-Config -Video $false -Audio $false -SubtitleLanguages @('fr')) -SourceUrl $singleUrl
Assert-Plan (-not $unavailableSubtitle.fallbackVideo -and $unavailableSubtitle.assets.Count -eq 0 -and @($unavailableSubtitle.issues | Where-Object { $_.type -eq 'subtitle' -and $_.language -eq 'fr' -and $_.status -eq 'skipped' }).Count -eq 1) 'no-subtitle source skips a subtitle-only request without downloading video'

$emptyDefaults = @{}
$emptyDefaults[$multiUrl] = @{ mediaId = 'arte-acceptance-001'; audioFormatIds = @(); subtitleTracks = @(); explicitAudio = $false; explicitSubtitles = $false }
$missingPreferences = New-LingoResourcePlan -Info $multi -Config (New-Config -AudioLanguages @('it') -SubtitleLanguages @('it') -SourceSelections $emptyDefaults) -SourceUrl $multiUrl
Assert-Plan ($missingPreferences.assets.Count -eq 1 -and $missingPreferences.assets[0].type -eq 'video' -and @($missingPreferences.issues | Where-Object { $_.type -eq 'audio' -and $_.language -eq 'it' }).Count -eq 1 -and @($missingPreferences.issues | Where-Object { $_.type -eq 'subtitle' -and $_.language -eq 'it' }).Count -eq 1) 'inspected source reports unavailable preferred audio and subtitles when no exact tracks were chosen'

$partialDefaults = @{}
$partialDefaults[$multiUrl] = @{ mediaId = 'arte-acceptance-001'; audioFormatIds = @('audio-fr-original'); subtitleTracks = @(@{ rawKey = 'fr'; source = 'provided' }); explicitAudio = $false; explicitSubtitles = $false }
$partialPreferences = New-LingoResourcePlan -Info $multi -Config (New-Config -AudioLanguages @('fr', 'it') -SubtitleLanguages @('fr', 'it') -SourceSelections $partialDefaults) -SourceUrl $multiUrl
$partialKeys = @($partialPreferences.assets | ForEach-Object { [string]$_.key })
Assert-Plan ($partialKeys.Count -eq 3 -and $partialKeys -contains 'video' -and $partialKeys -contains 'audio:audio-fr-original' -and $partialKeys -contains 'subtitle:provided:fr' -and @($partialPreferences.issues | Where-Object { $_.type -eq 'audio' -and $_.language -eq 'it' }).Count -eq 1 -and @($partialPreferences.issues | Where-Object { $_.type -eq 'subtitle' -and $_.language -eq 'it' }).Count -eq 1 -and @($partialPreferences.issues | Where-Object { $_.language -eq 'fr' }).Count -eq 0) 'inspected source preserves selected French tracks and reports only unavailable Italian preferences'

$partialAudioOnly = New-LingoResourcePlan -Info $multi -Config (New-Config -Video $false -Subtitles $false -AudioLanguages @('fr', 'it')) -SourceUrl $multiUrl
Assert-Plan (-not $partialAudioOnly.fallbackVideo -and $partialAudioOnly.assets.Count -eq 1 -and $partialAudioOnly.assets[0].key -eq 'audio:audio-fr-original' -and $partialAudioOnly.issues.Count -eq 1) 'audio-only partial availability downloads the available language without adding video'

$partialSubtitleOnly = New-LingoResourcePlan -Info $multi -Config (New-Config -Video $false -Audio $false -SubtitleLanguages @('fr', 'it')) -SourceUrl $multiUrl
Assert-Plan (-not $partialSubtitleOnly.fallbackVideo -and $partialSubtitleOnly.assets.Count -eq 1 -and $partialSubtitleOnly.assets[0].key -eq 'subtitle:provided:fr' -and $partialSubtitleOnly.issues.Count -eq 1) 'subtitle-only partial availability downloads the available language without adding video'

$bothMissing = New-LingoResourcePlan -Info $multi -Config (New-Config -Video $false -AudioLanguages @('it') -SubtitleLanguages @('it')) -SourceUrl $multiUrl
Assert-Plan ($bothMissing.fallbackVideo -and $bothMissing.assets.Count -eq 1 -and $bothMissing.assets[0].key -eq 'video' -and $bothMissing.issues.Count -eq 2 -and @($bothMissing.issues | Where-Object status -ne 'skipped').Count -eq 0) 'both missing selected resources save only one full video and two skipped records'

$mixedExact = @{}
$mixedExact[$multiUrl] = @{ mediaId = 'arte-acceptance-001'; audioFormatIds = @('missing-format', 'audio-fr-original'); subtitleTracks = @(@{ rawKey = 'fr'; source = 'provided' }, @{ rawKey = 'de'; source = 'provided' }); explicitAudio = $true; explicitSubtitles = $true }
$mixedExactPlan = New-LingoResourcePlan -Info $multi -Config (New-Config -Video $false -SourceSelections $mixedExact) -SourceUrl $multiUrl
Assert-Plan ($mixedExactPlan.fallbackVideo -and $mixedExactPlan.assets.Count -eq 3 -and @($mixedExactPlan.assets | Where-Object type -eq 'video').Count -eq 1 -and $mixedExactPlan.issues.Count -eq 2 -and $mixedExactPlan.assets[0].formatId -eq 'bestvideo[height<=1080]+audio-fr-original') 'partial exact selections retain surviving tracks with one fallback video using an existing selected audio track'
Assert-Plan (@($mixedExactPlan.issues | ForEach-Object { $_.key } | Select-Object -Unique).Count -eq 2 -and @($mixedExactPlan.issues | Where-Object reason -ne 'missing-resource').Count -eq 0) 'missing exact resource identities are distinct and explicitly mark known missing resources'

$dictionaryMedia = @{ id = 'dictionary-source'; title = 'Dictionary fixture'; formats = @(@{ format_id = 'a-en'; language = 'en'; acodec = 'aac'; vcodec = 'none' }); subtitles = @{ en = @(@{ ext = 'vtt' }) }; automatic_captions = @{ fr = @(@{ ext = 'vtt' }) } }
$dictionaryPlan = New-LingoResourcePlan -Info $dictionaryMedia -Config (New-Config -Video $false -Audio $false -SubtitleLanguages @('en', 'fr')) -SourceUrl $singleUrl
Assert-Plan ($dictionaryPlan.assets.Count -eq 2 -and -not $dictionaryPlan.fallbackVideo -and $dictionaryPlan.issues.Count -eq 0) 'dictionary metadata resolves provided and automatic subtitle preferences like JSON metadata'

$noAudio = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $single -Depth 12)
$noAudio.formats = @(@{ format_id = 'silent-video'; vcodec = 'h264'; acodec = 'none' })
$noAudioPlan = New-LingoResourcePlan -Info $noAudio -Config (New-Config -Video $false -Subtitles $false) -SourceUrl $singleUrl
Assert-Plan (-not $noAudioPlan.fallbackVideo -and $noAudioPlan.assets.Count -eq 0 -and $noAudioPlan.issues.Count -eq 1 -and $noAudioPlan.issues[0].type -eq 'audio') 'no audio formats in an audio-only request produces only a skipped issue'

$bili = @{ id = 'BV1yc411o7s2'; title = 'Bilibili fixture'; formats = @(@{ format_id = '30216'; acodec = 'aac'; vcodec = 'none'; abr = 64 }, @{ format_id = '30280'; acodec = 'aac'; vcodec = 'none'; abr = 192 }); subtitles = @{ danmaku = @(@{ ext = 'xml' }); zh = @(@{ ext = 'srt'; data = "1`n00:00:00,000 --> 00:00:01,000`n字幕`n" }) } }
$biliUrl = 'https://www.bilibili.com/video/BV1yc411o7s2/'
$biliAudio = New-LingoResourcePlan -Info $bili -Config (New-Config -Video $false -Subtitles $false -AudioLanguages @('fr')) -SourceUrl $biliUrl
Assert-Plan ($biliAudio.assets.Count -eq 1 -and $biliAudio.assets[0].type -eq 'audio' -and $biliAudio.assets[0].formatId -eq '30280' -and $biliAudio.issues.Count -eq 0) 'Bilibili unknown-language single audio downloads audio without manual inspection despite a French default preference'
$biliSelection = @{}; $biliSelection[$biliUrl] = @{ mediaId = $bili.id; audioFormatIds = @(); explicitAudio = $false; subtitleTracks = @() }
$biliInspected = New-LingoResourcePlan -Info $bili -Config (New-Config -Video $false -Subtitles $false -AudioLanguages @('fr') -SourceSelections $biliSelection) -SourceUrl $biliUrl
Assert-Plan ($biliInspected.assets.Count -eq 1 -and $biliInspected.assets[0].formatId -eq '30280' -and $biliInspected.issues.Count -eq 0) 'Bilibili automatically chosen unknown-language audio also works with an inspected source'
$biliSubtitle = New-LingoResourcePlan -Info $bili -Config (New-Config -Video $false -Audio $false -SubtitleLanguages @('zh')) -SourceUrl $biliUrl
Assert-Plan ($biliSubtitle.assets.Count -eq 1 -and $biliSubtitle.assets[0].key -eq 'subtitle:provided:zh') 'Bilibili inline SRT subtitle metadata is planned independently and XML danmaku is excluded'
Assert-Plan ((Get-LingoFileLanguage 'fr-acc') -eq 'fr' -and (Get-LingoFileLanguage 'ai-zh') -eq 'zh' -and (Get-LingoFileLanguage 'und') -eq $null -and (Get-LingoFileLanguage 'Unknown') -eq $null) 'published filenames use simple language codes and omit unknown-language suffixes'
Assert-Plan ((Get-LingoEnglishLanguageName 'ai-zh') -like 'Chinese*' -and (Test-LingoLanguageMatch -Actual 'ai-zh' -Wanted 'zh')) 'Bilibili AI subtitle raw keys display and match their actual language while keeping exact download identity'
$authBili = $bili.Clone(); $authBili.subtitleAvailability = 'login-required'
$authMixed = New-LingoResourcePlan -Info $authBili -Config (New-Config -AudioLanguages @('fr')) -SourceUrl $biliUrl
Assert-Plan ($authMixed.assets.Count -eq 2 -and @($authMixed.assets | Where-Object type -eq 'video').Count -eq 1 -and @($authMixed.assets | Where-Object type -eq 'audio').Count -eq 1 -and $authMixed.issues.Count -eq 1 -and $authMixed.issues[0].status -eq 'failed' -and $authMixed.issues[0].reason -eq 'login-required') 'subtitle login failure retains the requested video and audio as independently downloadable resources'
$authOnlySub = New-LingoResourcePlan -Info $authBili -Config (New-Config -Video $false -Audio $false) -SourceUrl $biliUrl
Assert-Plan ($authOnlySub.assets.Count -eq 0 -and -not $authOnlySub.fallbackVideo -and $authOnlySub.issues[0].status -eq 'failed') 'subtitle-only authentication failure is a resource failure without missing-resource fallback video'
$authOnlyAudio = New-LingoResourcePlan -Info $authBili -Config (New-Config -Video $false -Subtitles $false) -SourceUrl $biliUrl
Assert-Plan ($authOnlyAudio.assets.Count -eq 1 -and $authOnlyAudio.assets[0].type -eq 'audio' -and $authOnlyAudio.issues.Count -eq 0) 'audio-only requests are unaffected by subtitle authentication warnings'

Assert-Plan ((Get-LingoEnglishLanguageName 'en') -eq 'English' -and (Get-LingoEnglishLanguageName 'fr-acc') -eq 'French' -and (Get-LingoEnglishLanguageName 'fra') -eq 'French' -and (Get-LingoEnglishLanguageName 'und') -eq 'Unknown') 'English language names resolve plain codes, accessibility keys, ISO aliases and unknown languages'
Assert-Plan ((Get-LingoEnglishLanguageName 'en-US') -like 'English*United States*' -and (Get-LingoEnglishLanguageName 'zh-Hans') -like 'Chinese*Simplified*') 'regional and script language names remain specific in English'

$intentionalClear = @{}
$intentionalClear[$multiUrl] = @{ mediaId = 'arte-acceptance-001'; audioFormatIds = @(); subtitleTracks = @(); explicitAudio = $true; explicitSubtitles = $true }
$cleared = New-LingoResourcePlan -Info $multi -Config (New-Config -AudioLanguages @('it') -SubtitleLanguages @('it') -SourceSelections $intentionalClear) -SourceUrl $multiUrl
Assert-Plan ($cleared.assets.Count -eq 1 -and $cleared.assets[0].type -eq 'video' -and @($cleared.issues).Count -eq 0) 'explicitly clearing both track selections does not report missing preferences'

Assert-Throws { New-LingoResourcePlan -Info $multi -Config (New-Config -Video $false -Audio $false -Subtitles $false) -SourceUrl $multiUrl } 'empty parts are rejected'

$playlist = @{ _type = 'playlist'; id = 'acceptance-list'; entries = @($multi) }
Assert-Throws { New-LingoResourcePlan -Info $playlist -Config (New-Config) -SourceUrl $multiUrl } 'playlist must expand before per-video planning'

Write-Output 'Resource planning acceptance passed without network or download processes.'

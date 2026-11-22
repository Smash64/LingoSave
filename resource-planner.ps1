. (Join-Path $PSScriptRoot 'media-normalization.ps1')

function Get-LingoField {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Get-LingoLanguage {
    param($Value)
    if (-not $Value -or [string]$Value -eq 'none') { return 'und' }
    return ([string]$Value).ToLowerInvariant()
}

function Get-LingoEnglishLanguageName {
    param($Value)
    $raw = Get-LingoLanguage $Value
    if ($raw -eq 'und') { return 'Unknown' }
    if ($raw -eq 'mul') { return 'Multilingual' }
    # Keep the original track key separate from its language display name.
    $cultureKey = (($raw -replace '^ai-', '') -replace '_', '-') -replace '-(?:orig|original|acc)(?=$|-)', ''
    $languageAliases = @{ eng = 'en'; fra = 'fr'; fre = 'fr'; deu = 'de'; ger = 'de'; zho = 'zh'; chi = 'zh'; jpn = 'ja'; kor = 'ko'; spa = 'es'; por = 'pt'; ara = 'ar'; rus = 'ru'; ita = 'it'; nld = 'nl'; dut = 'nl'; hin = 'hi'; heb = 'he'; ind = 'id'; msa = 'ms'; may = 'ms'; vie = 'vi'; tha = 'th'; tur = 'tr'; pol = 'pl'; ukr = 'uk'; ces = 'cs'; cze = 'cs'; ell = 'el'; gre = 'el'; ron = 'ro'; rum = 'ro'; swe = 'sv'; dan = 'da'; fin = 'fi'; nor = 'no'; hun = 'hu'; fil = 'fil' }
    $base = ($cultureKey -split '-')[0]
    if ($languageAliases.ContainsKey($base)) { $cultureKey = $languageAliases[$base] + $cultureKey.Substring($base.Length) }
    try {
        $culture = [System.Globalization.CultureInfo]::GetCultureInfo($cultureKey)
        if ($culture.EnglishName -and $culture.EnglishName -ne 'Invariant Language (Invariant Country)') { return $culture.EnglishName }
    } catch { }
    return "Unknown ($raw)"
}

function Get-LingoFileLanguage {
    param($Value)
    $raw = Get-LingoLanguage $Value
    if ($raw -in @('und', 'unknown', 'na', 'n/a', 'none')) { return $null }
    $cultureKey = (($raw -replace '^ai-', '') -replace '_', '-') -replace '-(?:orig|original|acc)(?=$|-)', ''
    try {
        $culture = [System.Globalization.CultureInfo]::GetCultureInfo($cultureKey)
        if ($culture.TwoLetterISOLanguageName -and $culture.TwoLetterISOLanguageName -ne 'iv') { return $culture.TwoLetterISOLanguageName }
    } catch { }
    $code = (($cultureKey -split '-')[0] -replace '[^a-z0-9]', '')
    $aliases = @{ eng = 'en'; fra = 'fr'; fre = 'fr'; deu = 'de'; ger = 'de'; zho = 'zh'; chi = 'zh'; jpn = 'ja'; kor = 'ko'; spa = 'es'; por = 'pt'; ara = 'ar'; rus = 'ru' }
    if ($aliases.ContainsKey($code)) { return $aliases[$code] }
    return $code
}

function Test-LingoLanguageMatch {
    param([string]$Actual, [string]$Wanted)
    $actualName = $Actual.ToLowerInvariant() -replace '^ai-', ''
    $wantedName = $Wanted.ToLowerInvariant() -replace '^ai-', ''
    if ($actualName -eq $wantedName) { return $true }
    if ($actualName -match '[-_]acc(?:$|[-_])' -and $wantedName -notmatch '[-_]acc(?:$|[-_])') { return $false }
    return ($actualName.StartsWith("$wantedName-") -or $actualName.StartsWith("$wantedName`_"))
}

function Test-LingoRadioTranscriptVariant {
    param($Variant)
    return ((Get-LingoField $Variant 'ext') -eq 'json' -and (Get-LingoField $Variant 'lingosave_radio_transcript') -eq $true)
}

function Test-LingoSubtitleVariants {
    param($Variants)
    foreach ($variant in @($Variants)) {
        if ([string](Get-LingoField $variant 'ext') -in @('srt', 'vtt', 'ttml', 'srv1', 'srv2', 'srv3', 'json3', 'ass', 'lrc') -or (Test-LingoRadioTranscriptVariant $variant)) { return $true }
    }
    return $false
}

function Get-LingoSubtitleKeys {
    param($Source)
    if (-not $Source) { return }
    $keys = if ($Source -is [System.Collections.IDictionary]) { @($Source.Keys) } else { @($Source.PSObject.Properties | ForEach-Object { $_.Name }) }
    foreach ($key in $keys) {
        if (Test-LingoSubtitleVariants (Get-LingoField $Source ([string]$key))) { [string]$key }
    }
}

function Get-LingoAudioIdentity {
    param($Format)
    $language = Get-LingoLanguage (Get-LingoField $Format 'language')
    $trackId = [string](Get-LingoField $Format 'audio_track_id' (Get-LingoField $Format 'audio_track'))
    if ($trackId) { return "$language|id:$trackId" }
    $role = [string](Get-LingoField $Format 'audio_role')
    if (-not $role) {
        $note = [string](Get-LingoField $Format 'format_note')
        if ($note -match '(?i)audio description|descriptive audio|description') { $role = 'description' }
        elseif ($note -match '(?i)commentary') { $role = 'commentary' }
        elseif ($note -match '(?i)dubbed|dubbing') { $role = 'dubbed' }
        else { $role = 'main' }
    }
    return "$language|role:$($role.ToLowerInvariant())"
}

function New-LingoResourcePlan {
    param([Parameter(Mandatory = $true)]$Info, [Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$SourceUrl)

    if ((Get-LingoField $Info '_type') -in @('playlist', 'multi_video') -or $null -ne (Get-LingoField $Info 'entries')) {
        throw '资源计划需要单个视频，收到播放列表。'
    }
    $Info = Normalize-LingoMediaInfo -Info $Info -SourceUrl $SourceUrl
    $isArte = Test-LingoArteMedia -Info $Info -SourceUrl $SourceUrl
    $id = [string](Get-LingoField $Info 'id')
    if (-not $id) { throw '视频缺少资源 ID。' }
    $parts = Get-LingoField $Config 'parts'
    $wantVideo = [bool](Get-LingoField $parts 'video' $true)
    $wantAudio = [bool](Get-LingoField $parts 'audio' $true)
    $wantSubtitles = [bool](Get-LingoField $parts 'subtitles' $true)
    if (-not ($wantVideo -or $wantAudio -or $wantSubtitles)) { throw '至少需要选择视频、音轨或字幕之一。' }
    $isRadioFrance = ([Uri]$SourceUrl).DnsSafeHost -match '(^|\.)radiofrance\.fr$'
    $isRadio = [bool](Get-LingoField $Info 'lingosave_audio_only' $false) -or $isRadioFrance
    if ($isRadio -and ($wantVideo -or $wantAudio)) {
        # Spoken radio programmes have audio only, regardless of the video defaults.
        $wantVideo = $false
        $wantAudio = $true
        if (-not $isRadioFrance) { $wantSubtitles = $false }
    }
    $subtitleLoginRequired = $wantSubtitles -and (Get-LingoField $Info 'subtitleAvailability') -in @('needs-login', 'login-required')

    $selectionMap = Get-LingoField $Config 'sourceSelections'
    $selection = Get-LingoField $selectionMap $SourceUrl
    $exact = $null -ne $selection
    if ($exact) {
        if ([string](Get-LingoField $selection 'mediaId') -ne $id) { throw "资源 ID 已变化：预览时为 $([string](Get-LingoField $selection 'mediaId'))，现在为 $id；请重新解析。" }
    }

    $formats = @((Get-LingoField $Info 'formats' @()))
    $audioFormats = @($formats | Where-Object {
        $codec = [string](Get-LingoField $_ 'acodec')
        $codec -and $codec -ne 'none'
    })
    $subtitleSources = @{
        provided = (Get-LingoField $Info 'subtitles')
        auto = (Get-LingoField $Info 'automatic_captions')
    }
    $providedKeys = @(Get-LingoSubtitleKeys $subtitleSources.provided)
    $autoKeys = @(Get-LingoSubtitleKeys $subtitleSources.auto)
    $availableLanguages = @($audioFormats | ForEach-Object { Get-LingoLanguage (Get-LingoField $_ 'language') } | Select-Object -Unique)
    $audioIdentities = @($audioFormats | ForEach-Object { Get-LingoAudioIdentity $_ } | Select-Object -Unique)
    $unknownSingleAudio = $availableLanguages.Count -eq 1 -and $availableLanguages[0] -eq 'und' -and $audioIdentities.Count -eq 1
    $assets = [System.Collections.Generic.List[object]]::new()
    $issues = [System.Collections.Generic.List[object]]::new()
    $chosenAudio = [System.Collections.Generic.List[object]]::new()
    if ($wantAudio) {
        if ($exact) {
            $requestedIds = @(Get-LingoField $selection 'audioFormatIds' @())
            if ($requestedIds.Count -eq 0 -and ($unknownSingleAudio -or $isRadio) -and -not [bool](Get-LingoField $selection 'explicitAudio' $false)) {
                $bestUnknown = @($audioFormats | Sort-Object -Property @{ Expression = {
                    $videoCodec = [string](Get-LingoField $_ 'vcodec')
                    $score = if (-not $videoCodec -or $videoCodec -eq 'none') { 100000 } else { 0 }
                    $rate = Get-LingoField $_ 'abr' (Get-LingoField $_ 'tbr' 0)
                    try { $score + [double]$rate } catch { $score }
                }; Descending = $true } | Select-Object -First 1)
                $requestedIds = @([string](Get-LingoField $bestUnknown[0] 'format_id'))
            }
            foreach ($formatId in $requestedIds) {
                $format = @($audioFormats | Where-Object { [string](Get-LingoField $_ 'format_id') -ceq [string]$formatId } | Select-Object -First 1)
                if ($format.Count -eq 0) {
                    [void]$issues.Add(@{ type = 'audio'; formatId = [string]$formatId; language = $null; status = 'skipped'; error = "所选音轨格式 $formatId 已不存在，已跳过；将保存完整视频。" })
                    continue
                }
                if (-not @($chosenAudio | Where-Object { [string](Get-LingoField $_ 'format_id') -ceq [string]$formatId }).Count) { [void]$chosenAudio.Add($format[0]) }
            }
            if (-not [bool](Get-LingoField $selection 'explicitAudio' $false)) {
                $preferences = if ($isRadio) { @($availableLanguages) } else { @(Get-LingoField $Config 'audioLanguages' @()) }
                if ($unknownSingleAudio -and $chosenAudio.Count -gt 0) { $preferences = @('und') }
                if ($preferences.Count -eq 0 -and $chosenAudio.Count -eq 0) { $preferences = @('所选') }
                foreach ($language in $preferences) {
                    $matched = @($chosenAudio | Where-Object { Test-LingoLanguageMatch -Actual (Get-LingoLanguage (Get-LingoField $_ 'language')) -Wanted ([string]$language) }).Count -gt 0
                    if (-not $matched -and -not ($language -eq '所选' -and $requestedIds.Count -gt 0)) { [void]$issues.Add(@{ type = 'audio'; language = [string]$language; status = 'skipped'; error = "没有所选的 $language 音轨，已跳过；将保存完整视频。" }) }
                }
            }
        } else {
            $languagePrefs = if ($isRadio) { @($availableLanguages) } else { @(Get-LingoField $Config 'audioLanguages' @()) }
            if ($unknownSingleAudio) { $languagePrefs = @('und') }
            if ($languagePrefs.Count -eq 0) { $languagePrefs = @($availableLanguages) }
            foreach ($language in $languagePrefs) {
                $matches = @($audioFormats | Where-Object {
                    Test-LingoLanguageMatch -Actual (Get-LingoLanguage (Get-LingoField $_ 'language')) -Wanted ([string]$language)
                } | Sort-Object -Property @{ Expression = {
                    $videoCodec = [string](Get-LingoField $_ 'vcodec')
                    $score = if (-not $videoCodec -or $videoCodec -eq 'none') { 100000 } else { 0 }
                    $rate = Get-LingoField $_ 'abr' (Get-LingoField $_ 'tbr' 0)
                    try { $score + [double]$rate } catch { $score }
                }; Descending = $true })
                # ARTE language preferences use regular audio when that language also has audio description.
                if ($isArte -and @($matches | Where-Object { (Get-LingoField $_ 'audio_role') -eq 'main' }).Count -gt 0) {
                    $matches = @($matches | Where-Object { (Get-LingoField $_ 'audio_role') -ne 'description' })
                }
                if ($matches.Count -eq 0) {
                    [void]$issues.Add(@{ type = 'audio'; language = [string]$language; status = 'skipped'; error = "没有所选的 $language 音轨，已跳过；将保存完整视频。" })
                    continue
                }
                $seenIdentities = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($candidate in $matches) {
                    $identity = Get-LingoAudioIdentity $candidate
                    if (-not $seenIdentities.Add($identity)) { continue }
                    $candidateId = [string](Get-LingoField $candidate 'format_id')
                    if (-not @($chosenAudio | Where-Object { [string](Get-LingoField $_ 'format_id') -ceq $candidateId }).Count) { [void]$chosenAudio.Add($candidate) }
                }
            }
            if ($languagePrefs.Count -eq 0) { [void]$issues.Add(@{ type = 'audio'; language = 'und'; status = 'skipped'; error = '没有可用的音轨，已跳过独立音轨；将保存完整视频。' }) }
        }
    }

    foreach ($format in $chosenAudio) {
        $formatId = [string](Get-LingoField $format 'format_id')
        # Missing field denotes an old task: retain its MP3 output and checkpoint key.
        $outputFormats = @(Get-LingoField $Config 'audioOutputFormats' @('mp3'))
        foreach ($outputFormat in @($outputFormats | Select-Object -Unique)) {
            if ($outputFormat -cnotin @('original', 'mp3')) { throw '音频输出格式无效。' }
            $assetKey = if ($outputFormat -eq 'original') { "audio:${formatId}:original" } else { "audio:$formatId" }
            [void]$assets.Add(@{ key = $assetKey; type = 'audio'; outputFormat = $outputFormat; language = (Get-LingoLanguage (Get-LingoField $format 'language')); formatId = $formatId })
        }
    }

    if ($subtitleLoginRequired) {
        [void]$issues.Add(@{ type = 'subtitle'; language = 'und'; status = 'failed'; reason = 'login-required'; error = 'Bilibili 外挂字幕需要登录，请在设置中导入有效的 Bilibili Cookie 后重新解析。' })
    } elseif ($wantSubtitles) {
        $selectedTracks = [System.Collections.Generic.List[object]]::new()
        if ($exact) {
            $requestedTracks = @(Get-LingoField $selection 'subtitleTracks' @())
            foreach ($track in $requestedTracks) {
                $source = [string](Get-LingoField $track 'source')
                if ($source -eq 'unknown') { $source = 'provided' }
                $key = [string](Get-LingoField $track 'rawKey')
                if ($source -notin @('provided', 'auto')) { throw "不支持字幕来源 $source。" }
                $record = Get-LingoField $subtitleSources[$source] $key
                if (-not (Test-LingoSubtitleVariants $record)) {
                    [void]$issues.Add(@{ type = 'subtitle'; source = $source; rawKey = $key; language = $key; status = 'skipped'; error = "所选字幕 $source`:$key 已不存在，已跳过；将保存完整视频。" })
                    continue
                }
                if (-not @($selectedTracks | Where-Object { $_.source -ceq $source -and $_.rawKey -ceq $key }).Count) {
                    [void]$selectedTracks.Add(@{ source = $source; rawKey = $key })
                }
            }
            if (-not [bool](Get-LingoField $selection 'explicitSubtitles' $false)) {
                $preferences = @(Get-LingoField $Config 'subtitleLanguages' @())
                if ($preferences.Count -eq 0 -and $selectedTracks.Count -eq 0) { $preferences = @('所选') }
                foreach ($language in $preferences) {
                    $matched = @($selectedTracks | Where-Object { Test-LingoLanguageMatch -Actual ([string]$_.rawKey) -Wanted ([string]$language) }).Count -gt 0
                    if (-not $matched -and -not ($language -eq '所选' -and $requestedTracks.Count -gt 0)) { [void]$issues.Add(@{ type = 'subtitle'; language = [string]$language; status = 'skipped'; error = "没有所选的 $language 字幕，已跳过；将保存完整视频。" }) }
                }
            }
        } else {
            $prefs = @(Get-LingoField $Config 'subtitleLanguages' @())
            if ($prefs.Count -eq 0) {
                if ($providedKeys.Count -gt 0) { $prefs = @($providedKeys) }
                else {
                    $prefs = @($availableLanguages | Where-Object { $_ -ne 'und' })
                    if ($prefs.Count -eq 0 -and $autoKeys.Count -gt 0) {
                        $preferredAuto = @($autoKeys | Where-Object { $_ -match '^(en|zh|fr|de)(-|$)' } | Select-Object -First 1)
                        $prefs = if ($preferredAuto.Count -gt 0) { @($preferredAuto[0]) } else { @($autoKeys[0]) }
                    }
                }
            }
            foreach ($language in $prefs) {
                $matches = @($providedKeys | Where-Object { Test-LingoLanguageMatch -Actual $_ -Wanted ([string]$language) })
                $source = 'provided'
                if ($matches.Count -eq 0 -and $subtitleSources.auto) {
                    $matches = @($autoKeys | Where-Object { Test-LingoLanguageMatch -Actual $_ -Wanted ([string]$language) })
                    $source = 'auto'
                }
                if ($matches.Count -eq 0) {
                    [void]$issues.Add(@{ type = 'subtitle'; language = [string]$language; status = 'skipped'; error = "没有所选的 $language 字幕，已跳过；将保存完整视频。" })
                    continue
                }
                foreach ($key in $matches) {
                    if (-not @($selectedTracks | Where-Object { $_.source -ceq $source -and $_.rawKey -ceq $key }).Count) {
                        [void]$selectedTracks.Add(@{ source = $source; rawKey = $key })
                    }
                }
            }
            if ($prefs.Count -eq 0) { [void]$issues.Add(@{ type = 'subtitle'; language = 'und'; status = 'skipped'; error = '没有可用的字幕，已跳过；将保存完整视频。' }) }
        }
        foreach ($track in $selectedTracks) {
            $subtitleFormats = @(Get-LingoField $Config 'subtitleFormats' @(Get-LingoField $Config 'subtitleFormat' 'srt'))
            foreach ($format in $subtitleFormats) {
                $key = "subtitle:$($track.source):$($track.rawKey)"
                if ($subtitleFormats.Count -gt 1) { $key += ":$format" }
                [void]$assets.Add(@{ key = $key; type = 'subtitle'; source = $track.source; rawKey = $track.rawKey; language = $track.rawKey; subtitleFormat = $format })
            }
        }
    }
    foreach ($issue in $issues) {
        $identity = if (Get-LingoField $issue 'formatId') { [string]$issue.formatId } elseif (Get-LingoField $issue 'rawKey') { "$($issue.source):$($issue.rawKey)" } else { [string]$issue.language }
        if ((Get-LingoField $issue 'reason') -eq 'login-required') { $issue.key = 'unavailable:subtitle:login-required' }
        else { $issue.key = "missing:$($issue.type):$identity"; $issue.reason = 'missing-resource' }
    }
    # A request for only audio or only subtitles must never silently download video.
    # Mixed audio/subtitle requests retain the previously agreed missing-track fallback.
    $resourceOnly = -not $wantVideo -and ($wantAudio -xor $wantSubtitles)
    $fallbackVideo = @($issues | Where-Object status -eq 'skipped').Count -gt 0 -and -not $resourceOnly -and -not $isRadio
    if ($resourceOnly -or $isRadio) {
        foreach ($issue in $issues) { $issue.error = ([string]$issue.error) -replace '；将保存完整视频。', '。' }
        if ($assets.Count -eq 0 -and $issues.Count -eq 0) { throw '所选资源没有可下载的内容。' }
    }
    if ($wantVideo -or $fallbackVideo) {
        $quality = [string](Get-LingoField $Config 'quality' 'best')
        $limit = switch ($quality) { '720p' { '[height<=720]' } '1080p' { '[height<=1080]' } '1440p' { '[height<=1440]' } '2160p' { '[height<=2160]' } default { '' } }
        $formatExpression = "bestvideo$limit+bestaudio/best$limit/best"
        if ($quality -in @('1440p', '2160p')) { $formatExpression = "bestvideo$limit+bestaudio/best$limit" }
        $videoAudio = $null
        if ($chosenAudio.Count -gt 0 -and ($exact -or $isArte)) { $videoAudio = $chosenAudio[0] }
        elseif ($isArte) {
            $regular = @($audioFormats | Where-Object { (Get-LingoField $_ 'audio_role') -eq 'main' })
            $preferences = @(Get-LingoField $Config 'audioLanguages' @())
            foreach ($language in $preferences) {
                $preferred = @($regular | Where-Object { Test-LingoLanguageMatch -Actual (Get-LingoLanguage (Get-LingoField $_ 'language')) -Wanted ([string]$language) } | Sort-Object @{ Expression = { Get-LingoField $_ 'abr' (Get-LingoField $_ 'tbr' 0) }; Descending = $true })
                if ($preferred.Count -gt 0) { $videoAudio = $preferred[0]; break }
            }
            if (-not $videoAudio -and $regular.Count -gt 0) { $videoAudio = @($regular | Sort-Object @{ Expression = { Get-LingoField $_ 'abr' (Get-LingoField $_ 'tbr' 0) }; Descending = $true })[0] }
        }
        if ($videoAudio) {
            $first = $videoAudio
            $firstId = [string](Get-LingoField $first 'format_id')
            $videoCodec = [string](Get-LingoField $first 'vcodec')
            if ($videoCodec -and $videoCodec -ne 'none') { $formatExpression = $firstId }
            else { $formatExpression = "bestvideo$limit+$firstId" }
        }
        [void]$assets.Insert(0, @{ key = 'video'; type = 'video'; language = $null; formatId = $formatExpression; fallback = $fallbackVideo })
    }
    if ($assets.Count -eq 0 -and $issues.Count -eq 0) { throw '所选资源没有可下载的内容。' }
    return @{ id = $id; title = [string](Get-LingoField $Info 'title' $id); assets = @($assets.ToArray()); issues = @($issues.ToArray()); simplified = $false; fallbackVideo = $fallbackVideo }
}

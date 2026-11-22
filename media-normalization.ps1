# ARTE declares HLS audio renditions without a codec; rendition NAME, not stream-version notes, identifies the track.
function Get-LingoNormalizationField {
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

function Set-LingoNormalizationField {
    param($Object, [string]$Name, $Value)
    if ($Object -is [System.Collections.IDictionary]) { $Object[$Name] = $Value; return }
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Test-LingoArteMedia {
    param($Info, [string]$SourceUrl)
    $extractor = [string](Get-LingoNormalizationField $Info 'extractor' (Get-LingoNormalizationField $Info 'extractor_key'))
    if ($extractor -match '(?i)^Arte(?:TV|TVEmbed|TVPlaylist|TVCollection)?$') { return $true }
    foreach ($url in @($SourceUrl, (Get-LingoNormalizationField $Info 'webpage_url'), (Get-LingoNormalizationField $Info 'original_url'))) {
        if (-not $url) { continue }
        try {
            $hostName = ([Uri][string]$url).DnsSafeHost
            if ($hostName -eq 'arte.tv' -or $hostName.EndsWith('.arte.tv', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        } catch { }
    }
    return $false
}

function Normalize-LingoMediaInfo {
    param([Parameter(Mandatory = $true)]$Info, [string]$SourceUrl)
    $isArte = Test-LingoArteMedia -Info $Info -SourceUrl $SourceUrl
    $formats = @((Get-LingoNormalizationField $Info 'formats' @()))
    # Single-format and selected-format metadata also occur after yt-dlp format selection.
    if (Get-LingoNormalizationField $Info 'format_id') { $formats += $Info }
    $formats += @((Get-LingoNormalizationField $Info 'requested_formats' @()))
    foreach ($download in @((Get-LingoNormalizationField $Info 'requested_downloads' @()))) {
        if ($null -eq $download) { continue }
        if (Get-LingoNormalizationField $download 'requested_formats') { $formats += @((Get-LingoNormalizationField $download 'requested_formats')) }
        else { $formats += $download }
    }
    foreach ($format in $formats) {
        if ($null -eq $format) { continue }
        $formatId = [string](Get-LingoNormalizationField $format 'format_id')
        $videoCodec = [string](Get-LingoNormalizationField $format 'vcodec')
        $protocol = [string](Get-LingoNormalizationField $format 'protocol')
        $manifest = [string](Get-LingoNormalizationField $format 'manifest_url' (Get-LingoNormalizationField $format 'url'))
        # An HLS rendition that explicitly has no video is audio even when CODECS is absent.
        # Do not infer audio for silent formats, HTTP video or storyboard metadata.
        $audioCodec = [string](Get-LingoNormalizationField $format 'acodec')
        if ($videoCodec -eq 'none' -and -not $audioCodec -and ($protocol -match '^m3u8' -or $manifest -match '(?i)\.m3u8(?:[?#]|$)')) {
            Set-LingoNormalizationField $format 'acodec' 'unknown'
        }
        if (-not $isArte) { continue }
        $renditionMatch = [regex]::Match($formatId, '(?i)(?<rendition>audio_\d+[-_](?<name>.+))$')
        if ($videoCodec -ne 'none' -or ($protocol -notmatch '^m3u8' -and $manifest -notmatch '(?i)\.m3u8(?:[?#]|$)') -or -not $renditionMatch.Success) { continue }
        $renditionId = $renditionMatch.Groups['rendition'].Value
        $name = ($renditionMatch.Groups['name'].Value.Trim('_') -replace '_+', ' ').Trim()
        if (-not $name) { continue }
        $audioCodec = [string](Get-LingoNormalizationField $format 'acodec')
        # Explicit "none" means silent media and must never be repaired into audio.
        if ($audioCodec -eq 'none') { continue }
        if (-not $audioCodec) { Set-LingoNormalizationField $format 'acodec' 'unknown' }
        $knownRole = [string](Get-LingoNormalizationField $format 'audio_role')
        $versionNote = [string](Get-LingoNormalizationField $format 'format_note')
        $role = if ($name -match '(?i)confort\s+audio|audio[ -]*description|audiodescription|descriptive[ -]+audio') { 'description' }
        elseif ($knownRole) { $knownRole.ToLowerInvariant() }
        elseif ($formatId -match '(?i)^V[A-Z]*AUD(?:[-_]|$)' -or $versionNote -match '(?i)audio[ -]*description|audiodescription|descriptive[ -]+audio') { 'description' }
        else { 'main' }
        $language = [string](Get-LingoNormalizationField $format 'language')
        if (-not $language -or $language -eq 'und') {
            $language = if ($name -match '(?i)fran[cç]ais|french') { 'fr' } elseif ($name -match '(?i)allemand|german|deutsch') { 'de' } elseif ($name -match '(?i)multiling') { 'mul' } else { 'und' }
            Set-LingoNormalizationField $format 'language' $language
        }
        $display = switch ($language.ToLowerInvariant()) {
            'fr' { 'French' }; 'fra' { 'French' }; 'fre' { 'French' }
            'de' { 'German' }; 'deu' { 'German' }; 'ger' { 'German' }
            'mul' { 'Multilingual' }
            default { if (Get-Command Get-LingoEnglishLanguageName -ErrorAction SilentlyContinue) { Get-LingoEnglishLanguageName $language } else { $language } }
        }
        if ($role -eq 'description') { $display += ' — Audio description' }
        Set-LingoNormalizationField $format 'audio_track_id' ('arte:' + $role + ':' + $renditionId)
        Set-LingoNormalizationField $format 'audio_role' $role
        Set-LingoNormalizationField $format 'audio_track_name' $name
        Set-LingoNormalizationField $format 'audio_display_name' $display
    }
    return $Info
}
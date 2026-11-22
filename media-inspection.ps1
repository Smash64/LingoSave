param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$YtDlpPath,
    [string]$DenoPath,
    [string]$CookiePath,
    [string]$MetadataCachePath,
    [string]$CookieRevision = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'resource-planner.ps1')
. (Join-Path $PSScriptRoot 'site-catalog.ps1')

function Short-Text {
    param($Value, [int]$Limit = 180)
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ($text.Length -gt $Limit) { return $text.Substring(0, $Limit) }
    return $text
}

function Media-Platform {
    param([string]$Link)
    return [string]((Get-LingoSiteForUrl -Url $Link).label)
}

function Track-Language {
    param($Raw)
    if (-not $Raw) { return 'und' }
    return (Short-Text $Raw 50)
}

function Build-SubtitleTracks {
    param($Source, [string]$Kind, $Output)
    if (-not $Source) { return }
    foreach ($property in $Source.PSObject.Properties) {
        $key = [string]$property.Name
        if (-not $key -or $key.Length -gt 100) { continue }
        $extensions = [System.Collections.Generic.List[string]]::new()
        foreach ($variant in @($property.Value)) {
            if (Test-LingoRadioTranscriptVariant $variant) {
                foreach ($format in @('srt', 'vtt')) {
                    if (-not $extensions.Contains($format)) { [void]$extensions.Add($format) }
                }
                continue
            }
            $ext = ([string]$variant.ext).ToLowerInvariant()
            if ($ext -in @('srt', 'vtt', 'ttml', 'srv1', 'srv2', 'srv3', 'json3', 'ass', 'lrc') -and -not $extensions.Contains($ext)) {
                [void]$extensions.Add($ext)
            }
        }
        if ($extensions.Count -eq 0) { continue }
        [void]$Output.Add(@{
            id = "$Kind`:$key"
            rawKey = $key
            language = $key
            englishLanguageName = (Get-LingoEnglishLanguageName $key)
            source = $Kind
            formats = @($extensions.ToArray())
        })
    }
}

try {
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
        throw 'A valid HTTP(S) media URL is required.'
    }
    if (-not [System.IO.File]::Exists($YtDlpPath)) { throw 'yt-dlp executable was not found.' }
    # Bilibili only calls its subtitle API when subtitle extraction is requested.
    # Simulate keeps this inspection read-only even when write-subs is enabled.
    $arguments = @('--no-config', '--dump-single-json', '--simulate', '--write-subs', '--write-auto-subs', '--no-playlist', '--no-colors')
    if ($DenoPath -and [System.IO.File]::Exists($DenoPath)) { $arguments += @('--js-runtimes', "deno:$DenoPath") }
    if ($CookiePath) {
        if (-not [System.IO.File]::Exists($CookiePath)) { throw 'The selected Cookie file is unavailable.' }
        $arguments += @('--cookies', $CookiePath)
    }
    $arguments += $Url
    $errorPath = Join-Path ([System.IO.Path]::GetTempPath()) ("lingosave-inspect-$([guid]::NewGuid().ToString('N')).log")
    try {
        $ErrorActionPreference = 'Continue'
        $json = & $YtDlpPath @arguments 2> $errorPath | Out-String
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        $ErrorActionPreference = 'Stop'
        if ($code -ne 0 -or -not $json.Trim()) {
            $details = if ([System.IO.File]::Exists($errorPath)) { [System.IO.File]::ReadAllText($errorPath) } else { '' }
            $failureText = $details
            $details = ($details -split '\r?\n' | Where-Object { $_ -match 'ERROR:' } | Select-Object -First 1)
            if ($details -match 'ERROR:\s*(.*)$') { $details = $Matches[1] }
            if (-not $details) { $details = "yt-dlp exited with code $code" }
            $hint = Get-LingoSiteFailureHint -Site ([string](Get-LingoSiteForUrl $Url).id) -Message $failureText
            if ($hint) { throw $hint }
            throw (Short-Text $details 500)
        }
        if ($json.Length -gt 12000000) { throw 'Media metadata exceeds the supported size.' }
        $info = ConvertFrom-Json -InputObject $json
        $inspectionWarnings = if ([IO.File]::Exists($errorPath)) { [IO.File]::ReadAllText($errorPath) } else { '' }
        $subtitleNeedsLogin = $inspectionWarnings -match '(?i)subtitles are only available when logged in|login required.*subtitles|subtitles.*login required'
    } finally {
        if ([System.IO.File]::Exists($errorPath)) { Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue }
    }

    if ($info._type -in @('playlist', 'multi_video') -or $null -ne $info.entries) {
        throw 'This link resolves to a playlist. Use the batch download preview to inspect its full scope.'
    }

    $info = Normalize-LingoMediaInfo -Info $info -SourceUrl $Url

    if ($MetadataCachePath) {
        . (Join-Path $PSScriptRoot 'state-io.ps1')
        . (Join-Path $PSScriptRoot 'media-cache.ps1')
        if ($subtitleNeedsLogin) { Set-LingoObjectField $info 'subtitleAvailability' 'login-required' }
        try { [void](Save-LingoMetadataCache -Path $MetadataCachePath -Url $Url -CookieRevision $CookieRevision -Info $info -Complete) }
        catch { [Console]::Error.WriteLine('元数据缓存暂时无法保存，下载时将重新解析。') }
    }
    $formats = [System.Collections.Generic.List[object]]::new()
    $audioTracks = [System.Collections.Generic.List[object]]::new()
    $seenAudio = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $rawFormats = @($info.formats)
    foreach ($format in $rawFormats) {
        if ($formats.Count -ge 500) { break }
        $formatId = [string]$format.format_id
        if (-not $formatId) { continue }
        $videoCodec = [string]$format.vcodec
        $audioCodec = [string]$format.acodec
        $entry = @{
            id = $formatId
            ext = (Short-Text $format.ext 20)
            videoCodec = (Short-Text $videoCodec 80)
            audioCodec = (Short-Text $audioCodec 80)
            language = (Track-Language $format.language)
            englishLanguageName = (Get-LingoEnglishLanguageName $format.language)
            note = (Short-Text $format.format_note 120)
            width = $format.width
            height = $format.height
            fps = $format.fps
            bitrate = $format.tbr
            audioBitrate = $format.abr
            audioChannels = $format.audio_channels
            size = $(if ($format.filesize) { $format.filesize } else { $format.filesize_approx })
        }
        [void]$formats.Add($entry)
        if ($audioCodec -and $audioCodec -ne 'none' -and $seenAudio.Add($formatId) -and $audioTracks.Count -lt 200) {
            [void]$audioTracks.Add(@{
                formatId = $formatId
                trackId = (Short-Text (Get-LingoField $format 'audio_track_id') 180)
                role = (Short-Text (Get-LingoField $format 'audio_role') 40)
                name = (Short-Text (Get-LingoField $format 'audio_track_name') 180)
                displayName = (Short-Text (Get-LingoField $format 'audio_display_name') 200)
                language = $entry.language
                englishLanguageName = $entry.englishLanguageName
                note = $entry.note
                codec = $entry.audioCodec
                bitrate = $entry.audioBitrate
                channels = $entry.audioChannels
                audioOnly = (-not $videoCodec -or $videoCodec -eq 'none')
            })
        }
    }

    $subtitles = [System.Collections.Generic.List[object]]::new()
    Build-SubtitleTracks -Source $info.subtitles -Kind 'provided' -Output $subtitles
    Build-SubtitleTracks -Source $info.automatic_captions -Kind 'auto' -Output $subtitles
    $audioIdentityCount = @($rawFormats | Where-Object { $_.acodec -and $_.acodec -ne 'none' } | ForEach-Object { Get-LingoAudioIdentity $_ } | Select-Object -Unique).Count
    $result = @{
        url = $Url
        title = (Short-Text $info.title 500)
        platform = (Media-Platform $Url)
        id = (Short-Text $info.id 180)
        mediaId = (Short-Text $info.id 180)
        duration = $info.duration
        availability = (Short-Text $info.availability 80)
        isLive = [bool]$info.is_live
        formats = @($formats.ToArray())
        audioTracks = @($audioTracks.ToArray())
        subtitles = @($subtitles.ToArray() | Select-Object -First 200)
        subtitleAvailability = $(if ($subtitleNeedsLogin) { 'login-required' } else { 'available-or-absent' })
        subtitleNotice = $(if ($subtitleNeedsLogin) { 'Bilibili 外挂字幕需要登录，请在设置中导入有效的 Bilibili Cookie 后重新解析。' } else { $null })
        audioIdentityCount = $audioIdentityCount
        autoSimplifyCandidate = $false
        truncated = ($rawFormats.Count -gt 500 -or $audioTracks.Count -ge 200 -or $subtitles.Count -gt 200)
    }
    $result | ConvertTo-Json -Depth 10 -Compress
} catch {
    [Console]::Error.WriteLine([string]$_.Exception.Message)
    exit 1
}

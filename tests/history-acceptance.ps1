param([switch]$KeepArtifacts)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('lingosave-history-acceptance-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:JobsRoot = Join-Path $testRoot 'jobs'
[void][IO.Directory]::CreateDirectory($script:JobsRoot)
$script:Failures = [Collections.Generic.List[string]]::new()
$stateModule = Join-Path $root 'state-io.ps1'
if ([IO.File]::Exists($stateModule)) {
    . $stateModule
    Write-Output 'Using production state JSON helpers.'
} else {
    # The history module can be validated while state IO is being built independently.
    function Read-LingoJson {
        param([string]$Path, [switch]$ThrowOnError)
        if (-not [IO.File]::Exists($Path)) { return $null }
        return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
    }
    function Write-LingoJson {
        param([string]$Path, $Value, [int]$Depth = 25)
        [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth $Depth -Compress), [Text.UTF8Encoding]::new($false))
        return $true
    }
    Write-Output 'Using isolated state JSON stubs; no application data is touched.'
}

function Get-SiteFromUrl {
    param([string]$Url)
    if ($Url -match 'youtube|youtu\.be') { return 'YouTube' }
    if ($Url -match 'arte\.tv') { return 'ARTE' }
    return 'Bilibili'
}

. (Join-Path $root 'history-store.ps1')

function Assert-History {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Output "PASS $Message" }
    else { [void]$script:Failures.Add($Message); Write-Output "FAIL $Message" }
}

function New-HistoryConfig {
    return @{ parts = @{ video = $true; audio = $true; subtitles = $true }; quality = '1080p'; container = 'mp4'; audioLanguages = @('en'); subtitleLanguages = @('fr'); subtitleFormat = 'srt'; sourceSelections = @{} }
}

function New-HistoryAsset {
    param([string]$Type, [string]$Key, [string]$Status, [string]$Language = '', [string]$Track = '', [string]$Source = '')
    return @{ type = $Type; key = $Key; status = $Status; language = $Language; trackId = $Track; formatId = $Track; rawKey = $(if ($Type -eq 'subtitle') { $Track } else { '' }); source = $Source; path = $(if ($Status -eq 'completed') { Join-Path $testRoot ($Type + '-中文.mp4') } else { $null }); error = $(if ($Status -eq 'failed') { 'Fixture download failed' } elseif ($Status -eq 'skipped') { 'Fixture resource does not exist' } else { $null }) }
}

function New-HistoryItem {
    param([string]$Url, [string]$Status, $Assets, [string]$SourceUrl = '')
    if (-not $SourceUrl) { $SourceUrl = $Url }
    return @{ url = $Url; sourceUrl = $SourceUrl; title = 'History 中文 fixture'; status = $Status; assets = @($Assets); path = $null; error = $(if ($Status -eq 'failed') { 'Fixture source failed' } else { $null }) }
}

function New-HistoryJob {
    param([string]$Id, [string]$Status, [int]$Attempt = 1, $Items = @())
    return @{ id = $Id; status = $Status; attempt = $Attempt; items = @($Items); urls = @($Items | ForEach-Object { $_.url }); error = 'Fixture job failed' }
}

function Find-HistoryRecord {
    param([string]$Url)
    return @($script:LinkHistory.failedLinks | Where-Object { $_.url -ceq $Url } | Select-Object -First 1)[0]
}

try {
    Initialize-LingoHistory -DataRoot $testRoot
    $links = @(1..12 | ForEach-Object { 'https://www.youtube.com/watch?v=history{0:00}' -f $_ })
    Remember-LingoLinks -Urls $links
    Assert-History ($script:LinkHistory.recentLinks.Count -eq 10 -and $script:LinkHistory.recentLinks[0].url -eq $links[11] -and $script:LinkHistory.recentLinks[9].url -eq $links[2]) 'recent input history keeps the latest ten single URLs in recency order'
    Remember-LingoLinks -Urls @("  $($links[4])  ", $links[4])
    Assert-History ($script:LinkHistory.recentLinks.Count -eq 10 -and $script:LinkHistory.recentLinks[0].url -eq $links[4] -and @($script:LinkHistory.recentLinks | Where-Object url -eq $links[4]).Count -eq 1) 'reusing and trimming a URL moves one deduplicated entry to the top'
    $playlist = 'https://www.youtube.com/playlist?list=history-list'
    $childA = 'https://www.youtube.com/watch?v=child-a'
    $childB = 'https://www.youtube.com/watch?v=child-b'
    Remember-LingoLinks -Urls @($playlist)
    Update-LingoRecentTitles -Items @(@{ url = $playlist; title = 'Playlist 中文'; platform = 'YouTube'; entries = @(@{ url = $childA }, @{ url = $childB }) }, @{ url = $childA; title = 'Child A' })
    Assert-History ($script:LinkHistory.recentLinks[0].url -eq $playlist -and $script:LinkHistory.recentLinks[0].title -eq 'Playlist 中文' -and @($script:LinkHistory.recentLinks | Where-Object { $_.url -in @($childA, $childB) }).Count -eq 0) 'a playlist is one input history entry and title updates never expand its child URLs'
    Initialize-LingoHistory -DataRoot $testRoot
    Assert-History ($script:LinkHistory.recentLinks.Count -eq 10 -and $script:LinkHistory.recentLinks[0].url -eq $playlist -and $script:LinkHistory.recentLinks[0].title -eq 'Playlist 中文') 'recent URLs and Unicode titles persist across history initialization'

    $config = New-HistoryConfig
    $url = 'https://www.youtube.com/watch?v=failed-subtitle'
    $video = New-HistoryAsset -Type 'video' -Key 'video' -Status 'completed'
    $audio = New-HistoryAsset -Type 'audio' -Key 'audio:en-main' -Status 'completed' -Language 'en' -Track 'en-main'
    $subtitleFailure = New-HistoryAsset -Type 'subtitle' -Key 'subtitle:provided:fr' -Status 'failed' -Language 'fr' -Track 'fr' -Source 'provided'
    $partialItem = New-HistoryItem -Url $url -Status 'partial' -Assets @($video, $audio, $subtitleFailure) -SourceUrl $playlist
    $partialJob = New-HistoryJob -Id 'partial-attempt' -Status 'partial' -Items @($partialItem)
    Sync-LingoFailureHistory -Job $partialJob -Config $config
    $partialRecord = Find-HistoryRecord $url
    Assert-History ($partialRecord.failureCount -eq 1 -and $partialRecord.status -eq 'unresolved' -and $partialRecord.sourceUrl -eq $playlist -and $partialRecord.failedResources.Count -eq 1 -and $partialRecord.failedResources[0].type -eq 'subtitle' -and @($partialItem.assets | Where-Object { $_.type -eq 'audio' -and $_.status -eq 'completed' }).Count -eq 1) 'partial subtitle failure records only its failed resource, retaining the completed video and audio and playlist source'
    Sync-LingoFailureHistory -Job $partialJob -Config $config
    Assert-History ((Find-HistoryRecord $url).failureCount -eq 1) 'repeated persistence of the same final attempt never increments failure count'

    $multipleUrl = 'https://www.youtube.com/watch?v=multiple-failures'
    $audioFailure = New-HistoryAsset -Type 'audio' -Key 'audio:en-main' -Status 'failed' -Language 'en' -Track 'en-main'
    $multipleItem = New-HistoryItem -Url $multipleUrl -Status 'partial' -Assets @($video, $audioFailure, $subtitleFailure)
    Sync-LingoFailureHistory -Job (New-HistoryJob -Id 'multiple-assets' -Status 'partial' -Items @($multipleItem)) -Config $config
    Assert-History ((Find-HistoryRecord $multipleUrl).failureCount -eq 1 -and (Find-HistoryRecord $multipleUrl).failedResources.Count -eq 2) 'multiple failed assets within one attempt count as one link failure'
    Sync-LingoFailureHistory -Job (New-HistoryJob -Id 'multiple-assets' -Status 'partial' -Attempt 2 -Items @($multipleItem)) -Config $config
    Assert-History ((Find-HistoryRecord $multipleUrl).failureCount -eq 2) 'a new final download attempt increments the same link record once'

    $duplicateUrl = 'https://www.youtube.com/watch?v=duplicate-list-entry'
    $duplicateItem = New-HistoryItem -Url $duplicateUrl -Status 'failed' -Assets @($audioFailure)
    Sync-LingoFailureHistory -Job (New-HistoryJob -Id 'duplicate-entry' -Status 'failed' -Items @($duplicateItem, $duplicateItem)) -Config $config
    Assert-History ((Find-HistoryRecord $duplicateUrl).failureCount -eq 1) 'duplicate playlist entries for the same URL count once in a final attempt'

    $skippedUrl = 'https://www.youtube.com/watch?v=missing-resource'
    $skipped = New-HistoryAsset -Type 'subtitle' -Key 'missing:subtitle:fr' -Status 'skipped' -Language 'fr' -Track 'fr' -Source 'provided'
    Sync-LingoFailureHistory -Job (New-HistoryJob -Id 'skipped-only' -Status 'completed' -Items @((New-HistoryItem -Url $skippedUrl -Status 'completed' -Assets @($video, $audio, $skipped)))) -Config $config
    Assert-History (@($script:LinkHistory.failedLinks | Where-Object url -eq $skippedUrl).Count -eq 0) 'known missing skipped resources do not create failure history'
    foreach ($state in @('paused', 'pausing', 'cancelled', 'waiting_network', 'retrying', 'running')) {
        Sync-LingoFailureHistory -Job (New-HistoryJob -Id "nonfinal-$state" -Status $state -Items @((New-HistoryItem -Url "https://www.youtube.com/watch?v=$state" -Status 'failed' -Assets @($audioFailure)))) -Config $config
    }
    Assert-History (@($script:LinkHistory.failedLinks | Where-Object { $_.url -match '\?v=(paused|pausing|cancelled|waiting_network|retrying|running)$' }).Count -eq 0) 'pause, cancellation and temporary network recovery never form final failure records'

    $crashedUrl = 'https://www.youtube.com/watch?v=worker-crashed'
    $unstartedUrl = 'https://www.youtube.com/watch?v=worker-not-started'
    $activeAudio = New-HistoryAsset -Type 'audio' -Key 'audio:en-crash-track' -Status 'running' -Language 'en' -Track 'en-crash-track'
    $activeAudio.stage = 'convert'
    $activeItem = New-HistoryItem -Url $crashedUrl -Status 'running' -Assets @($video, $activeAudio) -SourceUrl $playlist
    $activeItem.phase = 'convert'
    $unstartedItem = New-HistoryItem -Url $unstartedUrl -Status 'queued' -Assets @()
    $crashedJob = New-HistoryJob -Id 'worker-crash-history' -Status 'failed' -Items @($activeItem, $unstartedItem)
    Sync-LingoFailureHistory -Job $crashedJob -Config $config
    $crashedRecord = Find-HistoryRecord $crashedUrl
    Assert-History ($crashedRecord -and $crashedRecord.failureCount -eq 1 -and $crashedRecord.failedResources.Count -eq 1 -and $crashedRecord.failedResources[0].key -eq 'audio:en-crash-track' -and $crashedRecord.failedResources[0].trackId -eq 'en-crash-track' -and $crashedRecord.failedResources[0].stage -eq 'convert' -and $crashedRecord.failedResources[0].error) 'final worker failure records its active resource with exact track identity, processing stage and error'
    Assert-History (@($script:LinkHistory.failedLinks | Where-Object url -eq $unstartedUrl).Count -eq 0 -and $activeItem.status -eq 'running' -and $activeAudio.status -eq 'running') 'history crash fallback excludes unstarted queued links and does not mutate job snapshots'

    $lostNetworkUrl = 'https://www.youtube.com/watch?v=worker-network-crash'
    $activeSubtitle = New-HistoryAsset -Type 'subtitle' -Key 'subtitle:provided:fr' -Status 'waiting_network' -Language 'fr' -Track 'fr' -Source 'provided'
    $activeSubtitle.stage = 'download'
    $networkItem = New-HistoryItem -Url $lostNetworkUrl -Status 'waiting_network' -Assets @($video, $audio, $activeSubtitle)
    $networkItem.phase = 'download'
    $networkFinalJob = New-HistoryJob -Id 'worker-network-final' -Status 'partial' -Items @($networkItem)
    Sync-LingoFailureHistory -Job $networkFinalJob -Config $config
    $networkRecord = Find-HistoryRecord $lostNetworkUrl
    Assert-History ($networkRecord -and $networkRecord.failedResources.Count -eq 1 -and $networkRecord.failedResources[0].trackId -eq 'fr' -and $networkRecord.failedResources[0].stage -eq 'download' -and $networkRecord.sourceUrl -eq $lostNetworkUrl) 'final partial worker failure records the waiting-network resource without marking completed video or audio failed'

    $otherSubtitle = New-HistoryAsset -Type 'subtitle' -Key 'subtitle:provided:en' -Status 'completed' -Language 'en' -Track 'en' -Source 'provided'
    Sync-LingoFailureHistory -Job (New-HistoryJob -Id 'other-language' -Status 'completed' -Items @((New-HistoryItem -Url $url -Status 'completed' -Assets @($video, $audio, $otherSubtitle)))) -Config $config
    Assert-History ((Find-HistoryRecord $url).status -eq 'unresolved') 'success in another subtitle language does not resolve the original failed language'
    $sameSubtitle = New-HistoryAsset -Type 'subtitle' -Key 'subtitle:provided:fr' -Status 'completed' -Language 'fr' -Track 'fr' -Source 'provided'
    $otherFormatConfig = New-HistoryConfig
    $otherFormatConfig.subtitleFormat = 'vtt'
    Sync-LingoFailureHistory -Job (New-HistoryJob -Id 'other-subtitle-format' -Status 'completed' -Items @((New-HistoryItem -Url $url -Status 'completed' -Assets @($sameSubtitle)))) -Config $otherFormatConfig
    Assert-History ((Find-HistoryRecord $url).status -eq 'unresolved') 'another subtitle file format does not resolve the original failed format'
    Sync-LingoFailureHistory -Job (New-HistoryJob -Id 'same-subtitle-success' -Status 'completed' -Items @((New-HistoryItem -Url $url -Status 'completed' -Assets @($sameSubtitle)))) -Config $config
    Assert-History ((Find-HistoryRecord $url).status -eq 'resolved' -and (Find-HistoryRecord $url).resolvedAt -and (Find-HistoryRecord $url).failureCount -eq 1) 'success of the same failed resource resolves the retained history without changing failure count'

    $videoUrl = 'https://www.youtube.com/watch?v=video-format-history'
    $videoFailure = New-HistoryAsset -Type 'video' -Key 'video' -Status 'failed'
    Sync-LingoFailureHistory -Job (New-HistoryJob -Id 'video-format-failure' -Status 'failed' -Items @((New-HistoryItem -Url $videoUrl -Status 'failed' -Assets @($videoFailure)))) -Config $config
    $otherVideoConfig = New-HistoryConfig
    $otherVideoConfig.container = 'mkv'
    Sync-LingoFailureHistory -Job (New-HistoryJob -Id 'other-video-container' -Status 'completed' -Items @((New-HistoryItem -Url $videoUrl -Status 'completed' -Assets @($video)))) -Config $otherVideoConfig
    Assert-History ((Find-HistoryRecord $videoUrl).status -eq 'unresolved') 'success with another video container does not resolve the original failed format'
    $otherVideoConfig = New-HistoryConfig
    $otherVideoConfig.quality = '720p'
    Sync-LingoFailureHistory -Job (New-HistoryJob -Id 'other-video-quality' -Status 'completed' -Items @((New-HistoryItem -Url $videoUrl -Status 'completed' -Assets @($video)))) -Config $otherVideoConfig
    Assert-History ((Find-HistoryRecord $videoUrl).status -eq 'unresolved') 'success at another requested video quality does not resolve the original failed format'
    Sync-LingoFailureHistory -Job (New-HistoryJob -Id 'same-video-success' -Status 'completed' -Items @((New-HistoryItem -Url $videoUrl -Status 'completed' -Assets @($video)))) -Config $config
    Assert-History ((Find-HistoryRecord $videoUrl).status -eq 'resolved') 'success of the original video format and quality resolves its history'

    $scopeA = 'https://www.youtube.com/watch?v=scope-a'
    $scopeB = 'https://www.youtube.com/watch?v=scope-b'
    $scopeAItem = New-HistoryItem -Url $scopeA -Status 'failed' -Assets @($audioFailure)
    $scopeBItem = New-HistoryItem -Url $scopeB -Status 'failed' -Assets @($audioFailure)
    Sync-LingoFailureHistory -Job (New-HistoryJob -Id 'target-scope' -Status 'failed' -Items @($scopeAItem, $scopeBItem)) -Config $config
    $scopeRetry = New-HistoryJob -Id 'target-scope' -Status 'failed' -Attempt 2 -Items @($scopeAItem, $scopeBItem)
    $scopeConfig = New-HistoryConfig
    $scopeConfig.attemptTargets = @($scopeA)
    Sync-LingoFailureHistory -Job $scopeRetry -Config $scopeConfig
    Assert-History ((Find-HistoryRecord $scopeA).failureCount -eq 2 -and (Find-HistoryRecord $scopeB).failureCount -eq 1) 'retry attemptTargets increments only the links actually attempted'
    $scopeResolution = New-HistoryJob -Id 'target-scope' -Status 'completed' -Attempt 3 -Items @((New-HistoryItem -Url $scopeA -Status 'completed' -Assets @($audio)), (New-HistoryItem -Url $scopeB -Status 'completed' -Assets @($audio)))
    Sync-LingoFailureHistory -Job $scopeResolution -Config $scopeConfig
    Assert-History ((Find-HistoryRecord $scopeA).status -eq 'resolved' -and (Find-HistoryRecord $scopeB).status -eq 'unresolved') 'attemptTargets prevents old successful items from resolving unrelated failed links'

    $sourceUrl = 'https://www.youtube.com/playlist?list=source-history'
    $sourceFailure = New-HistoryJob -Id 'source-parse-attempt' -Status 'failed'
    $sourceFailure.urls = @($sourceUrl)
    Sync-LingoFailureHistory -Job $sourceFailure -Config $config
    Assert-History ((Find-HistoryRecord $sourceUrl).failureCount -eq 1 -and (Find-HistoryRecord $sourceUrl).failedResources[0].type -eq 'source') 'a whole-source parsing failure records its original playlist URL'
    Sync-LingoFailureHistory -Job (New-HistoryJob -Id 'source-parse-success' -Status 'completed' -Items @((New-HistoryItem -Url $sourceUrl -Status 'completed' -Assets @($video, $audio, $sameSubtitle)))) -Config $config
    Assert-History ((Find-HistoryRecord $sourceUrl).status -eq 'resolved') 'a successful retry with the original resource settings resolves source parsing history'

    $wholeListUrl = 'https://www.youtube.com/playlist?list=whole-group-history'
    $wholeListFailure = New-HistoryJob -Id 'whole-list' -Status 'failed'
    $wholeListFailure.urls = @($wholeListUrl)
    Sync-LingoFailureHistory -Job $wholeListFailure -Config $config
    $childrenComplete = @((New-HistoryItem -Url $childA -Status 'completed' -Assets @($video, $audio) -SourceUrl $wholeListUrl), (New-HistoryItem -Url $childB -Status 'completed' -Assets @($video, $audio) -SourceUrl $wholeListUrl))
    $oneChildRetry = New-HistoryJob -Id 'whole-list' -Status 'completed' -Attempt 2 -Items $childrenComplete
    $oneChildRetry.urls = @($wholeListUrl)
    $oneChildConfig = New-HistoryConfig
    $oneChildConfig.attemptTargets = @($childA)
    Sync-LingoFailureHistory -Job $oneChildRetry -Config $oneChildConfig
    Assert-History ((Find-HistoryRecord $wholeListUrl).status -eq 'unresolved') 'retrying one child cannot resolve the original whole-playlist source failure'
    $incompleteGroup = New-HistoryJob -Id 'whole-list' -Status 'partial' -Attempt 3 -Items @($childrenComplete[0], (New-HistoryItem -Url $childB -Status 'failed' -Assets @($audioFailure) -SourceUrl $wholeListUrl))
    $incompleteGroup.urls = @($wholeListUrl)
    Sync-LingoFailureHistory -Job $incompleteGroup -Config $config
    Assert-History ((Find-HistoryRecord $wholeListUrl).status -eq 'unresolved') 'a playlist group with a still-failed child does not resolve the source record'
    $wholeListSuccess = New-HistoryJob -Id 'whole-list' -Status 'completed' -Attempt 4 -Items $childrenComplete
    $wholeListSuccess.urls = @($wholeListUrl)
    Sync-LingoFailureHistory -Job $wholeListSuccess -Config $config
    Assert-History ((Find-HistoryRecord $wholeListUrl).status -eq 'resolved' -and (Find-HistoryRecord $wholeListUrl).failureCount -eq 1) 'successful child items resolve a whole-playlist source failure through their shared sourceUrl'

    $fallbackTarget = 'https://www.youtube.com/watch?v=target-without-items'
    $unattemptedFallback = 'https://www.youtube.com/watch?v=unattempted-without-items'
    $noItems = New-HistoryJob -Id 'source-with-targets' -Status 'failed'
    $noItems.urls = @($fallbackTarget, $unattemptedFallback)
    $noItemsConfig = New-HistoryConfig
    $noItemsConfig.attemptTargets = @($fallbackTarget)
    Sync-LingoFailureHistory -Job $noItems -Config $noItemsConfig
    Assert-History (@($script:LinkHistory.failedLinks | Where-Object url -eq $fallbackTarget).Count -eq 1 -and @($script:LinkHistory.failedLinks | Where-Object url -eq $unattemptedFallback).Count -eq 0) 'source failure without item snapshots records only explicit attemptTargets'

    Initialize-LingoHistory -DataRoot $testRoot
    Assert-History ((Find-HistoryRecord $url).status -eq 'resolved' -and (Find-HistoryRecord $multipleUrl).failureCount -eq 2 -and $script:LinkHistory.recentLinks.Count -eq 10) 'failure count, resolved state and recent history persist together across restart'
    $view = Get-LingoHistoryView
    $viewJson = ConvertTo-Json -InputObject $view -Depth 15 -Compress
    Assert-History ($viewJson -notmatch 'configPath|signature|processedAttempts') 'UI history contains no private configuration paths, signatures or processed attempts'
    # The clear operation removes records while retaining attempt idempotency markers.
    $script:LinkHistory.failedLinks = @()
    Save-LingoHistory
    Initialize-LingoHistory -DataRoot $testRoot
    Sync-LingoFailureHistory -Job $partialJob -Config $config
    Assert-History ($script:LinkHistory.failedLinks.Count -eq 0) 'cleared history is not resurrected when an old final attempt is read after restart'
    $freshFailure = New-HistoryJob -Id 'partial-attempt' -Status 'partial' -Attempt 2 -Items @($partialItem)
    Sync-LingoFailureHistory -Job $freshFailure -Config $config
    Assert-History ($script:LinkHistory.failedLinks.Count -eq 1 -and (Find-HistoryRecord $url).failureCount -eq 1) 'a fresh attempt may create a new failure record after history is cleared'

    if ($script:Failures.Count -gt 0) { throw ("History acceptance failed ({0}): {1}" -f $script:Failures.Count, ($script:Failures -join '; ')) }
    Write-Output 'History acceptance passed without using application data or network requests.'
} finally {
    if ($KeepArtifacts) { Write-Output "History test artifacts: $testRoot" }
    else {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'lingosave-history-acceptance-*') { throw 'Refusing cleanup outside the isolated history test directory.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

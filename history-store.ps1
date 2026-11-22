function Get-HistoryField {
    param($Value, [string]$Name, $Default = $null)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [Collections.IDictionary]) { if ($Value.Contains($Name)) { return $Value[$Name] }; return $Default }
    if ($Value.PSObject.Properties[$Name]) { return $Value.$Name }
    return $Default
}

function Set-HistoryField {
    param($Value, [string]$Name, $Data)
    if ($Value -is [Collections.IDictionary]) { $Value[$Name] = $Data }
    else { $Value | Add-Member -MemberType NoteProperty -Name $Name -Value $Data -Force }
}

function Initialize-LingoHistory {
    param([string]$DataRoot)
    $script:HistoryPath = Join-Path $DataRoot 'link-history.json'
    $script:LinkHistory = Read-LingoJson -Path $script:HistoryPath -ThrowOnError
    if (-not $script:LinkHistory) { $script:LinkHistory = @{ schemaVersion = 1; recentLinks = @(); failedLinks = @(); processedAttempts = @() } }
    foreach ($key in @('recentLinks', 'failedLinks', 'processedAttempts')) {
        if ($null -eq (Get-HistoryField $script:LinkHistory $key)) { Set-HistoryField $script:LinkHistory $key @() }
    }
    $script:HistoryDirty = $false
}

function Save-LingoHistory {
    $script:HistoryDirty = $true
    [void](Write-LingoJson -Path $script:HistoryPath -Value $script:LinkHistory -Depth 25)
    $script:HistoryDirty = $false
}

function Remember-LingoLinks {
    param([string[]]$Urls)
    $recent = @($script:LinkHistory.recentLinks)
    foreach ($url in $Urls) {
        $url = $url.Trim()
        $old = @($recent | Where-Object { [string]$_.url -ceq $url } | Select-Object -First 1)
        $entry = @{ url = $url; title = $(if ($old.Count) { $old[0].title } else { $url }); platform = (Get-SiteFromUrl $url); lastUsedAt = [DateTime]::UtcNow.ToString('o') }
        $recent = @($entry) + @($recent | Where-Object { [string]$_.url -cne $url })
    }
    $script:LinkHistory.recentLinks = @($recent | Select-Object -First 10)
    Save-LingoHistory
}

function Update-LingoRecentTitles {
    param($Items)
    $changed = $false
    foreach ($item in @($Items)) {
        foreach ($recent in @($script:LinkHistory.recentLinks)) {
            if ([string]$recent.url -ceq [string]$item.url -and $item.title -and -not $item.error) {
                $recent.title = [string]$item.title
                if ($item.platform) { $recent.platform = [string]$item.platform }
                $changed = $true
            }
        }
    }
    if ($changed) { Save-LingoHistory }
}

function Get-HistoryResourceSignature {
    param($Asset, $Config)
    $type = [string](Get-HistoryField $Asset 'type' 'source')
    $identity = [string](Get-HistoryField $Asset 'key' $type)
    $track = [string](Get-HistoryField $Asset 'trackId' (Get-HistoryField $Asset 'formatId' (Get-HistoryField $Asset 'rawKey' '')))
    $format = if ($type -eq 'video') { "$($Config.quality)|$($Config.container)" } elseif ($type -eq 'subtitle') { [string]$Config.subtitleFormat } else { '' }
    if ($type -eq 'source') { $format = ConvertTo-Json -InputObject @($Config.parts, $Config.quality, $Config.container, $Config.audioLanguages, $Config.subtitleLanguages, $Config.sourceSelections) -Depth 10 -Compress }
    return "$type|$identity|$track|$($Asset.language)|$($Asset.source)|$format"
}

function Sync-LingoFailureHistory {
    param($Job, $Config)
    if (-not $Job -or $Job.status -notin @('failed', 'partial', 'completed')) { return }
    $attempt = [int](Get-HistoryField $Job 'attempt' 1)
    $attemptKey = "$($Job.id):$attempt"
    if (@($script:LinkHistory.processedAttempts | Where-Object { $_ -ceq $attemptKey }).Count) {
        if ($script:HistoryDirty) { Save-LingoHistory }
        return
    }
    if (-not $Config) { return }
    $targets = @(Get-HistoryField $Config 'attemptTargets' @())
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($item in @($Job.items)) {
        if (-not $item -or -not $item.url) { continue }
        if ($targets.Count -and [string]$item.url -cnotin $targets) { continue }
        $bad = @($item.assets | Where-Object { $_.status -eq 'failed' })
        $good = @($item.assets | Where-Object { $_.status -eq 'completed' })
        if ($Job.status -in @('failed', 'partial') -and $item.status -in @('running', 'waiting_network')) {
            foreach ($asset in @($item.assets | Where-Object { $_.status -in @('running', 'waiting_network') })) {
                $bad += @{ key = $asset.key; type = $asset.type; trackId = $asset.trackId; formatId = $asset.formatId; rawKey = $asset.rawKey; language = $asset.language; source = $asset.source; stage = (Get-HistoryField $asset 'stage' (Get-HistoryField $item 'phase' 'download')); error = $Job.error }
            }
            if (-not $bad.Count) { $bad = @(@{ key = 'source'; type = 'source'; stage = (Get-HistoryField $item 'phase' 'inspect'); error = $Job.error }) }
        }
        if ($item.status -eq 'failed' -and $bad.Count -eq 0) { $bad = @(@{ key = 'source'; type = 'source'; error = $item.error }) }
        # Old non-resource jobs have a completed file but no asset list.
        if ($item.status -eq 'completed' -and $good.Count -eq 0 -and $item.path) { $good = @(@{ key = 'source'; type = 'source' }) }
        [void]$entries.Add(@{ url = [string]$item.url; title = [string]$item.title; sourceUrl = [string](Get-HistoryField $item 'sourceUrl' $item.url); bad = $bad; good = $good; completed = ($item.status -eq 'completed') })
    }
    # A previously failed playlist extraction is recovered only when its whole group completes.
    foreach ($sourceUrl in @($Job.urls)) {
        if ($targets.Count -and [string]$sourceUrl -cnotin $targets) { continue }
        $children = @($Job.items | Where-Object { [string](Get-HistoryField $_ 'sourceUrl' $_.url) -ceq [string]$sourceUrl })
        if (-not $children.Count -or @($children | Where-Object { $_.status -ne 'completed' }).Count) { continue }
        if (@($entries | Where-Object { $_.url -ceq [string]$sourceUrl }).Count) { continue }
        [void]$entries.Add(@{ url = [string]$sourceUrl; sourceUrl = [string]$sourceUrl; title = [string]$sourceUrl; bad = @(); good = @(@{ key = 'source'; type = 'source' }); completed = $true })
    }
    if ($entries.Count -eq 0 -and $Job.status -eq 'failed') {
        $failedUrls = if ($targets.Count) { $targets } else { @($Job.urls) }
        foreach ($url in $failedUrls) { [void]$entries.Add(@{ url = [string]$url; sourceUrl = [string]$url; title = [string]$url; bad = @(@{ key = 'source'; type = 'source'; error = $Job.error }); good = @(); completed = $false }) }
    }
    $records = @($script:LinkHistory.failedLinks)
    $countedUrls = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $entries) {
        $matches = @($records | Where-Object { [string]$_.url -ceq $entry.url } | Select-Object -First 1)
        $record = if ($matches.Count) { $matches[0] } else { $null }
        if (-not $record -and $entry.bad.Count) {
            $record = @{ id = [guid]::NewGuid().ToString('N'); url = $entry.url; title = $entry.title; sourceUrl = $entry.sourceUrl; platform = (Get-SiteFromUrl $entry.url); lastFailedAt = $null; error = $null; stage = $null; failureCount = 0; status = 'unresolved'; jobId = [string]$Job.id; failedResources = @(); resolvedAt = $null }
            $records += @($record)
        }
        if (-not $record) { continue }
        $resources = @($record.failedResources)
        foreach ($asset in $entry.good) {
            $signature = Get-HistoryResourceSignature $asset $Config
            foreach ($resource in $resources) { if ([string]$resource.signature -ceq $signature) { $resource.status = 'resolved' } }
        }
        if ($entry.completed) {
            $sourceSignature = Get-HistoryResourceSignature @{ key = 'source'; type = 'source' } $Config
            foreach ($resource in $resources) { if ($resource.type -eq 'source' -and [string]$resource.signature -ceq $sourceSignature) { $resource.status = 'resolved' } }
        }
        if ($entry.bad.Count) {
            if ($countedUrls.Add($entry.url)) { $record.failureCount = [int]$record.failureCount + 1 }
            $record.lastFailedAt = [DateTime]::UtcNow.ToString('o')
            $record.jobId = [string]$Job.id
            $record.sourceUrl = $entry.sourceUrl
            if ($entry.title) { $record.title = $entry.title }
            foreach ($asset in $entry.bad) {
                $signature = Get-HistoryResourceSignature $asset $Config
                $resources = @($resources | Where-Object { [string]$_.signature -cne $signature })
                $resource = @{ key = [string](Get-HistoryField $asset 'key' 'source'); type = [string](Get-HistoryField $asset 'type' 'source'); signature = $signature; trackId = [string](Get-HistoryField $asset 'trackId'); language = [string]$asset.language; source = [string]$asset.source; stage = [string](Get-HistoryField $asset 'stage' (Get-HistoryField $asset 'type' 'source')); error = [string](Get-HistoryField $asset 'error' $Job.error); status = 'unresolved'; jobId = [string]$Job.id; configPath = (Join-Path $script:JobsRoot "$($Job.id).config.json") }
                $resources += @($resource)
                $record.error = $resource.error
                $record.stage = $resource.stage
            }
        }
        $record.failedResources = @($resources)
        if (@($resources | Where-Object { $_.status -eq 'unresolved' }).Count) { $record.status = 'unresolved'; $record.resolvedAt = $null }
        else { $record.status = 'resolved'; $record.resolvedAt = [DateTime]::UtcNow.ToString('o') }
    }
    $script:LinkHistory.failedLinks = @($records | Sort-Object -Property lastFailedAt -Descending)
    $script:LinkHistory.processedAttempts = @($script:LinkHistory.processedAttempts) + @($attemptKey)
    Save-LingoHistory
}

function Get-LingoHistoryView {
    $failed = foreach ($entry in @($script:LinkHistory.failedLinks)) {
        # Expose only UI fields, never internal configuration paths or signatures.
        $resources = foreach ($asset in @($entry.failedResources)) { @{ key = $asset.key; type = $asset.type; language = $asset.language; source = $asset.source; error = $asset.error; status = $asset.status } }
        @{ id = $entry.id; url = $entry.url; title = $entry.title; sourceUrl = $entry.sourceUrl; platform = $entry.platform; lastFailedAt = $entry.lastFailedAt; error = $entry.error; stage = $entry.stage; failureCount = $entry.failureCount; status = $entry.status; jobId = $entry.jobId; failedResources = @($resources); resolvedAt = $entry.resolvedAt }
    }
    return @{ recentLinks = @($script:LinkHistory.recentLinks); failedLinks = @($failed) }
}

function Get-LingoMetadataPath {
    param([string]$StoreRoot, [string]$Url, [string]$CookieRevision='', [ValidateSet('single','flat','source')][string]$Mode='single')
    # Radio France entries cached before transcript discovery lack the availability flag.
    $schema = if (([Uri]$Url).DnsSafeHost -match '(^|\.)radiofrance\.fr$') { '|rf-transcript-v1' } else { '' }
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url+'|'+$CookieRevision+'|'+$Mode+$schema)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    return Join-Path (Join-Path $StoreRoot 'metadata-cache') ($key+'.json')
}
function Test-LingoMetadataFresh {
    param($Envelope,[string]$Url,[string]$CookieRevision='', [switch]$RequireComplete)
    if (-not $Envelope -or [int]$Envelope.version -ne 1 -or [string]$Envelope.url -cne $Url -or [string]$Envelope.cookieRevision -cne $CookieRevision -or -not $Envelope.info) { return $false }
    $timestamp=[DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$Envelope.fetchedAt,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$timestamp)) { return $false }
    $age=([DateTime]::UtcNow-$timestamp.ToUniversalTime()).TotalSeconds
    if ($age -lt -30 -or $age -gt 300) { return $false }
    if ($RequireComplete -and (-not $Envelope.complete -or -not $Envelope.info.id -or $Envelope.info._type -in @('url','url_transparent','playlist','multi_video') -or $null -ne $Envelope.info.entries -or -not ($Envelope.info.formats -or ($Envelope.info.format_id -and $Envelope.info.url) -or $Envelope.info.subtitles -or $Envelope.info.automatic_captions))) { return $false }
    $urls=[Collections.Generic.List[string]]::new()
    if($Envelope.info.url){[void]$urls.Add([string]$Envelope.info.url)}
    foreach($format in @($Envelope.info.formats)) { if($format.url){[void]$urls.Add([string]$format.url)}; foreach($fragment in @($format.fragments)){if($fragment.url){[void]$urls.Add([string]$fragment.url)}} }
    foreach($source in @($Envelope.info.subtitles,$Envelope.info.automatic_captions)) {
        if (-not $source) {continue}
        $keys=if($source -is [Collections.IDictionary]){@($source.Keys)}else{@($source.PSObject.Properties | ForEach-Object Name)}
        foreach($key in $keys){$variants=if($source -is [Collections.IDictionary]){$source[$key]}else{$source.$key};foreach($variant in @($variants)){if($variant.url){[void]$urls.Add([string]$variant.url)}}}
    }
    $minimum=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+30
    foreach($address in $urls){
        if ($address -match '(?i)(?:[?&])(?:expire|expires|deadline|exp)=(\d{10})(?:&|$)' -and [long]$Matches[1] -le $minimum) {return $false}
    }
    return $true
}
function Read-LingoMetadataCache {
    param([string]$Path,[string]$Url,[string]$CookieRevision='', [switch]$RequireComplete)
    $saved=Read-LingoJson -Path $Path
    if(Test-LingoMetadataFresh -Envelope $saved -Url $Url -CookieRevision $CookieRevision -RequireComplete:$RequireComplete){return $saved.info}
    return $null
}
function Save-LingoMetadataCache {
    param([string]$Path,[string]$Url,[string]$CookieRevision='', $Info, [switch]$Complete,[string]$FetchedAt=([DateTime]::UtcNow.ToString('o')))
    $envelope=@{version=1;url=$Url;cookieRevision=$CookieRevision;fetchedAt=$FetchedAt;complete=[bool]$Complete;info=$Info}
    [void](Write-LingoJson -Path $Path -Value $envelope -Depth 60)
    return $envelope
}

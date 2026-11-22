# Shared supported-site registry for URL recognition, display names and credentials.
$script:LingoSiteCatalog = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'sites.json')) | ConvertFrom-Json
if (-not $script:LingoSiteCatalog.Count) { throw '网站配置为空。' }
$siteKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($definition in $script:LingoSiteCatalog) {
    if ([string]$definition.id -notmatch '\A[a-z][a-z0-9-]{0,31}\z' -or -not $siteKeys.Add([string]$definition.id) -or -not $definition.label -or -not @($definition.domains).Count) { throw '网站配置无效。' }
    foreach ($domain in $definition.domains) {
        if ($domain -notmatch '\A[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z]{2,}\z') { throw '网站域名配置无效。' }
    }
}
function Get-LingoSites { return @($script:LingoSiteCatalog) }
function Get-LingoSiteDefinition {
    param([string]$Id)
    foreach ($site in $script:LingoSiteCatalog) { if ([string]$site.id -eq $Id) { return $site } }
    throw '此网站未在支持列表中。'
}
function Get-LingoSiteForUrl {
    param([Parameter(Mandatory=$true)][string]$Url)
    $uri = $null
    if ($Url.Length -gt 4096 -or $Url -match '[\r\n"<>]' -or -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or -not $uri.IsDefaultPort) { throw '请输入支持网站的普通 HTTP(S) 链接。' }
    $hostName = $uri.DnsSafeHost.ToLowerInvariant()
    foreach ($site in $script:LingoSiteCatalog) {
        foreach ($domain in $site.domains) {
            if ($hostName -eq $domain -or $hostName.EndsWith('.'+$domain, [StringComparison]::Ordinal)) {
                if ($site.pathPattern -and $uri.AbsolutePath -notmatch $site.pathPattern) { throw ([string]$site.pathHint) }
                return $site
            }
        }
    }
    throw '暂不支持此网站，请参考链接输入框下方的支持平台。'
}
function Get-LingoSiteField {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}
function Resolve-LingoMediaEntryUrl {
    param($Entry, [string]$Site)
    foreach ($field in @('webpage_url','url')) {
        $candidate = [string](Get-LingoSiteField $Entry $field)
        if ($candidate -match '^https?://') {
            try { [void](Get-LingoSiteForUrl $candidate); return $candidate } catch { }
        }
    }
    $extractor = [string](Get-LingoSiteField $Entry 'extractor_key')
    if (-not $extractor) { $extractor = [string](Get-LingoSiteField $Entry 'ie_key') }
    $id = [string](Get-LingoSiteField $Entry 'id')
    foreach ($definition in $script:LingoSiteCatalog) {
        if (-not $definition.entryTemplate -or -not $definition.idPattern) { continue }
        $matchesSite = if ($extractor) { $extractor -match $definition.extractorPattern } else { $Site -eq $definition.id }
        if ($matchesSite -and $id -cmatch $definition.idPattern) { return ([string]$definition.entryTemplate).Replace('{id}', $id) }
    }
    return $null
}
function Get-LingoSiteFailureHint {
    param([string]$Site, [string]$Message)
    $label = [string]((Get-LingoSiteDefinition -Id $Site).label)
    if ($Message -match '(?i)logged.in|log.in.required|login.required|sign.in|use --cookies|fresh cookies|cookies.*needed|authentication required') {
        return "$label 要求登录验证。请在浏览器确认该视频可访问，再到设置中导入对应网站的 Cookie 后重新解析。"
    }
    if ($Message -match '(?i)HTTP (?:Error )?403|403 Forbidden|status(?: code)?[:= ]+403') {
        return "$label 拒绝访问此媒体（HTTP 403）。请确认视频在浏览器中可播放；如需登录，可导入对应网站的 Cookie 后重试。网站的访问限制仍可能阻止下载。"
    }
    if ($Message -match '(?i)Unsupported URL') { return "$label 未识别到可下载视频，请使用具体视频或支持的播放列表页面链接。" }
    return $null
}
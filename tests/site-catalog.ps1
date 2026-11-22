$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'site-catalog.ps1')
. (Join-Path $root 'credential-store.ps1')
$script:checks=0
function Check([bool]$Value,[string]$Name){if(-not$Value){throw $Name};$script:checks++;Write-Host ('PASS '+$Name)}
$cases=@{
 'https://www.youtube.com/watch?v=sample12345'='youtube';'https://b23.tv/abc'='bilibili';'https://www.arte.tv/fr/videos/115508-001-A/test/'='arte';'https://www.radiofrance.fr/franceculture/podcasts/test'='radiofrance';
 'https://podcasts.ina.fr/main/pub/emission/15180'='ina';'https://podcasts.ina.fr/main/pub/emission/15180-La-L%C3%A9gende-des-chevaliers-de-la-Table-ronde'='ina';'https://podcasts.ina.fr/main/pub/podcast/2081062-Bande-annonce?productor=test'='ina';'https://podcasts.ina.fr/main/pub/podcast/2081062?productor=test'='ina';
 'https://player.vimeo.com/video/76979871'='vimeo';'https://dai.ly/x84sh87'='dailymotion';'https://www.ted.com/talks/demo'='ted';'https://x.com/demo/status/123'='twitter';'https://fb.watch/demo/'='facebook';'https://www.instagram.com/reel/demo/'='instagram';'https://vm.tiktok.com/demo/'='tiktok';'https://v.douyin.com/demo/'='douyin';'https://xhslink.com/demo/'='xiaohongshu';'https://www.acfun.cn/v/ac123'='acfun';'https://tv.cctv.com/2026/11/03/VIDEexample.shtml'='cctv'
}
foreach($url in $cases.Keys){Check ((Get-LingoSiteForUrl $url).id-ceq$cases[$url]) ('correct provider for '+$cases[$url])}
Check (@(Get-LingoSites).Count-eq 16) 'registry contains all sixteen configured providers'
foreach($bad in @('http://localhost/','http://127.0.0.1/','http://192.168.1.1/','file:///D:/sample.mp4','https://vimeo.com.evil.invalid/a','https://evilvimeo.com/a','https://vimeo.com@evil.invalid/a','https://vimeo.com:8443/a','https://www.radiofrance.fr/franceculture/')){$blocked=$false;try{[void](Get-LingoSiteForUrl $bad)}catch{$blocked=$true};Check $blocked 'unsupported URL stays blocked'}
Check ((Get-LingoSiteForUrl 'https://WWW.VIMEO.COM/123').id-eq'vimeo') 'hostname recognition is case insensitive'
Check ((Resolve-LingoMediaEntryUrl -Entry @{id='123456';ie_key='Vimeo'})-ceq'https://vimeo.com/123456') 'Vimeo ID-only playlist entries get a canonical URL'
Check ((Resolve-LingoMediaEntryUrl -Entry @{id='x84sh87'} -Site dailymotion)-ceq'https://www.dailymotion.com/video/x84sh87') 'Dailymotion parent scope resolves flat entries'
Check ((Resolve-LingoMediaEntryUrl -Entry @{id='123';extractor_key='AcFunVideo'})-ceq'https://www.acfun.cn/v/ac123') 'AcFun flat video IDs resolve correctly'
Check ((Resolve-LingoMediaEntryUrl -Entry @{id='bad/id';ie_key='Vimeo'})-eq$null) 'malformed video IDs cannot be interpolated into URLs'
Check ((Resolve-LingoMediaEntryUrl -Entry @{id='123';ie_key='Unrelated'})-eq$null) 'unknown extractor IDs are not guessed as another platform'
Check ((Resolve-LingoMediaEntryUrl -Entry @{id='123';ie_key='Vimeo';url='https://cdn.invalid/file.mp4'})-ceq'https://vimeo.com/123') 'flat CDN URLs never replace a supported video page'
Check ((Resolve-LingoMediaEntryUrl -Entry @{url='https://www.youtube.com/watch?v=sample12345'} -Site vimeo)-ceq'https://www.youtube.com/watch?v=sample12345') 'cross-platform supported entries retain their actual video page'
Check ((Get-LingoSiteFailureHint -Site vimeo -Message 'The web client only works when logged-in') -like '*Vimeo*Cookie*') 'Vimeo login failures explain the matching Cookie action'
Check ((Get-LingoSiteFailureHint -Site dailymotion -Message 'Unable to download m3u8: HTTP Error 403: Forbidden') -like '*Dailymotion*403*') 'media access restrictions retain HTTP 403 in the user message'
Check ($null-eq(Get-LingoSiteFailureHint -Site ted -Message 'unexpected parser error')) 'unrelated extraction errors keep their original diagnostics'
$fixture=Join-Path $env:TEMP ('lingosave-sites-cookie-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
try {
 foreach($site in (Get-LingoSites)){
  $domain=[string]$site.domains[0];$source=Join-Path $fixture ($site.id+'.txt')
  $lines=@('# Netscape HTTP Cookie File',('.'+$domain+"`tTRUE`t/`tTRUE`t2147483647`tsynthetic`tfixture"),"evil.invalid`tFALSE`t/`tTRUE`t2147483647`tforeign`tfiltered")
  [IO.File]::WriteAllLines($source,$lines,[Text.UTF8Encoding]::new($false))
  $metadata=Import-LingoCookieFile -Site $site.id -SourcePath $source -StoreRoot $fixture
  Check ($metadata.cookieCount-eq 1) ('cookie isolation for '+$site.id)
  $temp=New-LingoTemporaryCookieFile -Site $site.id -StoreRoot $fixture
  $plain=[IO.File]::ReadAllText($temp);Check ($plain.Contains('synthetic')-and-not$plain.Contains('foreign')) 'only matching provider cookies are decrypted'
  Remove-LingoTemporaryCookieFile -Path $temp -StoreRoot $fixture
  Check (-not[IO.File]::Exists($temp)) 'new provider temporary cookie file is safely removed'
 }
 $unknown=$false;try{[void](Get-LingoCookiePaths -Site '../escape' -StoreRoot $fixture)}catch{$unknown=$true};Check $unknown 'invalid cookie storage provider is rejected'
}finally{$full=[IO.Path]::GetFullPath($fixture);$prefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\';if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($full)-match '^lingosave-sites-cookie-[0-9a-f]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}}
Write-Host "PASS $script:checks shared site and real DPAPI credential checks."
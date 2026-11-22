param()

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'credential-store.ps1')

function Assert-CookieTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Cookie test failed: $Message" }
    Write-Host "PASS: $Message"
}

$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $tempBase ("LingoSaveCredentialTest-$([guid]::NewGuid().ToString('N'))")))
$youtubeTemp = $null
$bilibiliTemp = $null

try {
    try {
        $probe = [System.Security.Cryptography.ProtectedData]::Protect(
            [byte[]]@(1, 2, 3), $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        [Array]::Clear($probe, 0, $probe.Length)
    } catch {
        throw "DPAPI CurrentUser is unavailable for this Windows profile: $($_.Exception.GetBaseException().Message)"
    }

    [void][System.IO.Directory]::CreateDirectory($testRoot)
    $source = Join-Path $testRoot 'fixture.txt'
    $youtubeValue = "synthetic-youtube-$([guid]::NewGuid().ToString('N'))"
    $bilibiliValue = "synthetic-bilibili-$([guid]::NewGuid().ToString('N'))"
    $unrelatedValue = "synthetic-unrelated-$([guid]::NewGuid().ToString('N'))"
    $fixture = "# Netscape HTTP Cookie File`n" +
        ".youtube.com`tTRUE`t/`tTRUE`t0`tYT_TEST`t$youtubeValue`n" +
        ".bilibili.com`tTRUE`t/`tTRUE`t0`tBILI_TEST`t$bilibiliValue`n" +
        ".example.com`tTRUE`t/`tFALSE`t0`tOTHER_TEST`t$unrelatedValue`n"
    [System.IO.File]::WriteAllText($source, $fixture, [System.Text.UTF8Encoding]::new($false))

    $youtube = Import-LingoCookieFile -Site youtube -SourcePath $source -StoreRoot $testRoot
    $bilibili = Import-LingoCookieFile -Site bilibili -SourcePath $source -StoreRoot $testRoot
    Assert-CookieTest ($youtube.cookieCount -eq 1 -and $youtube.ignoredCount -eq 2 -and
        $bilibili.cookieCount -eq 1 -and $bilibili.ignoredCount -eq 2) 'per-site rows are isolated'
    Assert-CookieTest ($youtube.revision -match '^[0-9a-f]{32}$' -and
        $bilibili.revision -match '^[0-9a-f]{32}$' -and
        -not (Get-LingoCookieMetadata -Site arte -StoreRoot $testRoot)) 'metadata and revisions are available without Cookie values'

    foreach ($site in @('youtube', 'bilibili')) {
        $stored = [System.IO.File]::ReadAllText((Join-Path $testRoot "credentials\$site.json"))
        Assert-CookieTest (-not $stored.Contains($youtubeValue) -and
            -not $stored.Contains($bilibiliValue) -and
            -not $stored.Contains($unrelatedValue)) "$site record stores ciphertext"
    }

    $youtubeTemp = New-LingoTemporaryCookieFile -Site youtube -StoreRoot $testRoot
    $bilibiliTemp = New-LingoTemporaryCookieFile -Site bilibili -StoreRoot $testRoot
    $youtubeText = [System.IO.File]::ReadAllText($youtubeTemp)
    $bilibiliText = [System.IO.File]::ReadAllText($bilibiliTemp)
    Assert-CookieTest ($youtubeText.Contains($youtubeValue) -and
        -not $youtubeText.Contains($bilibiliValue) -and
        -not $youtubeText.Contains($unrelatedValue)) 'YouTube temporary file contains only YouTube fixture'
    Assert-CookieTest ($bilibiliText.Contains($bilibiliValue) -and
        -not $bilibiliText.Contains($youtubeValue) -and
        -not $bilibiliText.Contains($unrelatedValue)) 'Bilibili temporary file contains only Bilibili fixture'

    $newYoutubeValue = "synthetic-youtube-new-$([guid]::NewGuid().ToString('N'))"
    $newFixture = "# Netscape HTTP Cookie File`n.youtube.com`tTRUE`t/`tTRUE`t0`tYT_TEST`t$newYoutubeValue`n"
    [System.IO.File]::WriteAllText($source, $newFixture, [System.Text.UTF8Encoding]::new($false))
    $updated = Import-LingoCookieFile -Site youtube -SourcePath $source -StoreRoot $testRoot
    Assert-CookieTest ($updated.revision -ne $youtube.revision -and
        (Get-LingoCookieMetadata -Site youtube -StoreRoot $testRoot -Revision $youtube.revision).revision -eq $youtube.revision) 'older credential revision remains available'
    $olderTemp = New-LingoTemporaryCookieFile -Site youtube -StoreRoot $testRoot -Revision $youtube.revision
    try {
        $olderText = [System.IO.File]::ReadAllText($olderTemp)
        Assert-CookieTest ($olderText.Contains($youtubeValue) -and -not $olderText.Contains($newYoutubeValue)) 'queued task can use its original revision'
    } finally {
        Remove-LingoTemporaryCookieFile -Path $olderTemp -StoreRoot $testRoot
    }

    Remove-LingoTemporaryCookieFile -Path $youtubeTemp -StoreRoot $testRoot
    Remove-LingoTemporaryCookieFile -Path $bilibiliTemp -StoreRoot $testRoot
    Assert-CookieTest (-not [System.IO.File]::Exists($youtubeTemp) -and
        -not [System.IO.File]::Exists($bilibiliTemp)) 'temporary Cookie files are removed'
    $youtubeTemp = $null
    $bilibiliTemp = $null

    Remove-LingoCookieFile -Site youtube -StoreRoot $testRoot
    Remove-LingoCookieFile -Site bilibili -StoreRoot $testRoot
    Assert-CookieTest (-not (Get-LingoCookieMetadata -Site youtube -StoreRoot $testRoot) -and
        -not (Get-LingoCookieMetadata -Site bilibili -StoreRoot $testRoot)) 'encrypted records are removed'
    Write-Host 'Cookie tests completed using synthetic data only.'
} finally {
    if ($youtubeTemp -and [System.IO.File]::Exists($youtubeTemp)) { Remove-LingoTemporaryCookieFile -Path $youtubeTemp -StoreRoot $testRoot }
    if ($bilibiliTemp -and [System.IO.File]::Exists($bilibiliTemp)) { Remove-LingoTemporaryCookieFile -Path $bilibiliTemp -StoreRoot $testRoot }
    $prefix = $tempBase + [System.IO.Path]::DirectorySeparatorChar
    if ($testRoot.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($testRoot) -match '^LingoSaveCredentialTest-[0-9a-f]{32}$' -and
        [System.IO.Directory]::Exists($testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

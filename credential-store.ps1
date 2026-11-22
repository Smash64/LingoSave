. (Join-Path $PSScriptRoot 'site-catalog.ps1')
# Dot-source this file to manage site-specific Netscape cookies.txt credentials.
# StoreRoot is the application data directory. Only the current Windows user can
# decrypt the stored payload. Call Remove-LingoTemporaryCookieFile after yt-dlp.

Add-Type -AssemblyName System.Security

function Get-LingoCookiePaths {
    param([Parameter(Mandatory = $true)][ValidateScript({ [void](Get-LingoSiteDefinition -Id $_); $true })][string]$Site,
          [Parameter(Mandatory = $true)][string]$StoreRoot)
    $root = [System.IO.Path]::GetFullPath($StoreRoot)
    $privateRoot = Join-Path $root 'credentials'
    return [pscustomobject]@{
        Root = $privateRoot
        File = Join-Path $privateRoot "$Site.json"
        Temp = Join-Path $privateRoot 'tmp'
    }
}

function Set-LingoPrivateDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $directory = [System.IO.Directory]::CreateDirectory($Path)
    if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Credential directory cannot be a reparse point.'
    }
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($user)
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $user, [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inherit, [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
    $directory.SetAccessControl($acl)
}

function Set-LingoPrivateFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [System.Security.AccessControl.FileSecurity]::new()
    $acl.SetOwner($user)
    $acl.SetAccessRuleProtection($true, $false)
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $user, [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
    [System.IO.File]::SetAccessControl($Path, $acl)
}

function Get-LingoCookieAllowedDomains {
    param([string]$Site)
    $definition = Get-LingoSiteDefinition -Id $Site
    return @($definition.domains)
}

function Test-LingoCookieDomain {
    param([string]$Domain, [string[]]$AllowedDomains)
    $hostName = ($Domain -replace '^#HttpOnly_', '').TrimStart('.').ToLowerInvariant()
    if ($hostName -notmatch '^[a-z0-9.-]+$' -or $hostName.Contains('..')) { return $false }
    foreach ($allowed in $AllowedDomains) {
        if ($hostName -eq $allowed -or $hostName.EndsWith(".$allowed")) { return $true }
    }
    return $false
}

function ConvertTo-LingoCookiePayload {
    param([Parameter(Mandatory = $true)][string]$SourcePath,
          [Parameter(Mandatory = $true)][string]$Site)
    $file = [System.IO.FileInfo]::new([System.IO.Path]::GetFullPath($SourcePath))
    if (-not $file.Exists -or $file.Length -lt 1 -or $file.Length -gt 5MB) {
        throw 'Cookie file is missing, empty, or larger than 5 MB.'
    }
    try {
        $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $raw = [System.IO.File]::ReadAllText($file.FullName, $utf8).TrimStart([char]0xFEFF)
    } catch {
        throw 'Cookie file must be valid UTF-8 Netscape text.'
    }
    if ($raw -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { throw 'Cookie file contains invalid control characters.' }
    $lines = $raw -split "`n"
    $first = @($lines | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($first.Count -ne 1 -or $first[0].TrimEnd("`r") -notmatch '^#\s*(Netscape HTTP Cookie File|HTTP Cookie File)\s*$') {
        throw 'Cookie file needs a Netscape HTTP Cookie File header.'
    }
    $allowed = @(Get-LingoCookieAllowedDomains -Site $Site)
    $retained = [System.Collections.Generic.List[string]]::new()
    $ignored = 0
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index].TrimEnd("`r")
        if (-not $line -or ($line.StartsWith('#') -and -not $line.StartsWith('#HttpOnly_'))) { continue }
        $fields = $line -split "`t"
        if ($fields.Count -ne 7 -or $fields[0] -notmatch '^(?:#HttpOnly_)?\.?[A-Za-z0-9.-]+$' -or
            $fields[1] -notin @('TRUE', 'FALSE') -or $fields[2] -notmatch '^/' -or
            $fields[3] -notin @('TRUE', 'FALSE') -or $fields[5].Length -eq 0) {
            throw "Cookie file has an invalid Netscape row at line $($index + 1)."
        }
        $expiry = [long]0
        if (-not [long]::TryParse($fields[4], [ref]$expiry) -or $expiry -lt 0) {
            throw "Cookie file has an invalid expiry at line $($index + 1)."
        }
        if (Test-LingoCookieDomain -Domain $fields[0] -AllowedDomains $allowed) {
            [void]$retained.Add($line)
        } else {
            $ignored++
        }
    }
    if ($retained.Count -eq 0) { throw "Cookie file has no cookies for site $Site." }
    $canonical = "# Netscape HTTP Cookie File`n" + ($retained -join "`n") + "`n"
    return [pscustomobject]@{ Bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical); CookieCount = $retained.Count; IgnoredCount = $ignored }
}

function Get-LingoCookieRecord {
    param([string]$Site, [string]$StoreRoot,
          [string]$Revision)
    if ($Revision -and $Revision -notmatch '^[0-9a-f]{32}$') { throw 'Invalid Cookie revision.' }
    $paths = Get-LingoCookiePaths -Site $Site -StoreRoot $StoreRoot
    $file = if ($Revision) { Join-Path $paths.Root "$Site.$Revision.json" } else { $paths.File }
    if (-not [System.IO.File]::Exists($file)) { return $null }
    try {
        $record = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8))
        if ($record.site -ne $Site -or -not $record.protectedData -or -not $record.revision -or
            ($Revision -and $record.revision -ne $Revision)) { throw 'Invalid record.' }
        return $record
    } catch {
        throw "Stored Cookie record for site $Site is invalid."
    }
}

function Get-LingoCookieMetadata {
    param([Parameter(Mandatory = $true)][ValidateScript({ [void](Get-LingoSiteDefinition -Id $_); $true })][string]$Site,
          [Parameter(Mandatory = $true)][string]$StoreRoot,
          [string]$Revision)
    $record = Get-LingoCookieRecord -Site $Site -StoreRoot $StoreRoot -Revision $Revision
    if (-not $record) { return $null }
    return [pscustomobject]@{
        site = $Site
        revision = [string]$record.revision
        importedAt = [string]$record.importedAt
        cookieCount = [int]$record.cookieCount
        ignoredCount = [int]$record.ignoredCount
        status = 'imported_pending_validation'
    }
}

function Import-LingoCookieFile {
    param([Parameter(Mandatory = $true)][ValidateScript({ [void](Get-LingoSiteDefinition -Id $_); $true })][string]$Site,
          [Parameter(Mandatory = $true)][string]$SourcePath,
          [Parameter(Mandatory = $true)][string]$StoreRoot)
    $payload = ConvertTo-LingoCookiePayload -SourcePath $SourcePath -Site $Site
    $paths = Get-LingoCookiePaths -Site $Site -StoreRoot $StoreRoot
    Set-LingoPrivateDirectory -Path $paths.Root
    $entropy = [System.Text.Encoding]::UTF8.GetBytes("LingoSave:$Site")
    $cipher = [System.Security.Cryptography.ProtectedData]::Protect(
        $payload.Bytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    $record = [ordered]@{
        site = $Site
        revision = [guid]::NewGuid().ToString('N')
        importedAt = [DateTime]::UtcNow.ToString('o')
        cookieCount = $payload.CookieCount
        ignoredCount = $payload.IgnoredCount
        protectedData = [Convert]::ToBase64String($cipher)
    }
    $versionFile = Join-Path $paths.Root "$Site.$($record.revision).json"
    $temp = Join-Path $paths.Root ("$Site.$([guid]::NewGuid().ToString('N')).tmp")
    $backup = $null
    try {
        [System.IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $record -Compress), [System.Text.UTF8Encoding]::new($false))
        Set-LingoPrivateFile -Path $temp
        [System.IO.File]::Copy($temp, $versionFile)
        Set-LingoPrivateFile -Path $versionFile
        if ([System.IO.File]::Exists($paths.File)) {
            $backup = Join-Path $paths.Root ("$Site.$([guid]::NewGuid().ToString('N')).bak")
            [System.IO.File]::Replace($temp, $paths.File, $backup)
        } else {
            [System.IO.File]::Move($temp, $paths.File)
        }
        Set-LingoPrivateFile -Path $paths.File
    } finally {
        if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) }
        if ($backup -and [System.IO.File]::Exists($backup)) { [System.IO.File]::Delete($backup) }
    }
    return Get-LingoCookieMetadata -Site $Site -StoreRoot $StoreRoot
}

function New-LingoTemporaryCookieFile {
    param([Parameter(Mandatory = $true)][ValidateScript({ [void](Get-LingoSiteDefinition -Id $_); $true })][string]$Site,
          [Parameter(Mandatory = $true)][string]$StoreRoot,
          [string]$Revision)
    $paths = Get-LingoCookiePaths -Site $Site -StoreRoot $StoreRoot
    $record = Get-LingoCookieRecord -Site $Site -StoreRoot $StoreRoot -Revision $Revision
    if (-not $record) { throw "No matching Cookie revision imported for site $Site." }
    Set-LingoPrivateDirectory -Path $paths.Temp
    $entropy = [System.Text.Encoding]::UTF8.GetBytes("LingoSave:$Site")
    try {
        $cipher = [Convert]::FromBase64String([string]$record.protectedData)
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $cipher, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } catch {
        throw "Stored Cookie file for site $Site cannot be decrypted by this Windows user."
    }
    $path = Join-Path $paths.Temp ("lingosave-cookie-$Site-$([guid]::NewGuid().ToString('N')).txt")
    $stream = $null
    try {
        $stream = [System.IO.FileStream]::new($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Write($plain, 0, $plain.Length)
        $stream.Dispose()
        $stream = $null
        Set-LingoPrivateFile -Path $path
        return $path
    } catch {
        if ($stream) { $stream.Dispose() }
        if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
        throw
    } finally {
        [Array]::Clear($plain, 0, $plain.Length)
    }
}

function Remove-LingoTemporaryCookieFile {
    param([Parameter(Mandatory = $true)][string]$Path,
          [Parameter(Mandatory = $true)][string]$StoreRoot)
    $full = [System.IO.Path]::GetFullPath($Path)
    $paths = Get-LingoCookiePaths -Site youtube -StoreRoot $StoreRoot
    $expectedParent = [System.IO.Path]::GetFullPath($paths.Temp).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $name = [System.IO.Path]::GetFileName($full)
    $parent = [System.IO.Path]::GetDirectoryName($full)
    $knownCookieName = $false
    if ($name -match '\Alingosave-cookie-([a-z][a-z0-9-]{0,31})-[0-9a-f]{32}\.txt\z') {
        try { [void](Get-LingoSiteDefinition -Id $Matches[1]); $knownCookieName = $true } catch { }
    }
    if (-not $knownCookieName -or
        -not [string]::Equals($parent, $expectedParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a file outside the LingoSave temporary Cookie directory.'
    }
    if ([System.IO.File]::Exists($full)) {
        $file = [System.IO.FileInfo]::new($full)
        if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Refusing to remove a reparse-point Cookie file.'
        }
        [System.IO.File]::Delete($full)
    }
}

function Remove-LingoCookieFile {
    param([Parameter(Mandatory = $true)][ValidateScript({ [void](Get-LingoSiteDefinition -Id $_); $true })][string]$Site,
          [Parameter(Mandatory = $true)][string]$StoreRoot)
    $paths = Get-LingoCookiePaths -Site $Site -StoreRoot $StoreRoot
    if ([System.IO.File]::Exists($paths.File)) { [System.IO.File]::Delete($paths.File) }
    if ([System.IO.Directory]::Exists($paths.Root)) {
        foreach ($file in [System.IO.Directory]::GetFiles($paths.Root, "$Site.*.json")) {
            if ([System.IO.Path]::GetFileName($file) -match "^$Site\.[0-9a-f]{32}\.json$") {
                [System.IO.File]::Delete($file)
            }
        }
    }
}

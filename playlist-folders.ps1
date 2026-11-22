# Persisted output locations for playlist downloads. No per-process state is kept here.
if (-not (Get-Command Write-LingoJson -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'state-io.ps1') }

function Get-LingoPlaylistField {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Set-LingoPlaylistField {
    param($Object, [string]$Name, $Value)
    if ($Object -is [Collections.IDictionary]) { $Object[$Name] = $Value }
    elseif ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-LingoPlaylistFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) { throw '播放列表保存路径必须是绝对路径。' }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd('\', '/') -eq $root.TrimEnd('\', '/')) { return $root }
    return $full.TrimEnd('\', '/')
}

function Assert-LingoPlaylistPathAncestors {
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = $Path
    while ($current) {
        $attributes = $null
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch {
            $cause = $_.Exception.GetBaseException()
            if ($cause -isnot [IO.FileNotFoundException] -and $cause -isnot [IO.DirectoryNotFoundException]) { throw }
        }
        if ($null -ne $attributes) {
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '播放列表保存目录不能包含目录链接。' }
            if (($attributes -band [IO.FileAttributes]::Directory) -eq 0) { throw '播放列表保存路径已被文件占用。' }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-LingoPlaylistDirectory {
    param([Parameter(Mandatory = $true)][string]$BasePath, [Parameter(Mandatory = $true)][string]$Directory, [switch]$Create)
    $base = Get-LingoPlaylistFullPath $BasePath
    $full = Get-LingoPlaylistFullPath $Directory
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not $parent -or -not [string]::Equals((Get-LingoPlaylistFullPath $parent), $base, [StringComparison]::OrdinalIgnoreCase)) {
        throw '播放列表目录必须是当前保存位置的直接子目录。'
    }
    $name = [IO.Path]::GetFileName($full)
    if (-not $name -or $name -match '[<>:"/\\|?*\x00-\x1F]' -or $name -ne $name.Trim(' ', '.') -or $name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
        throw '播放列表文件夹名称无效。'
    }
    Assert-LingoPlaylistPathAncestors -Path $full
    if ($Create) {
        [void][IO.Directory]::CreateDirectory($full)
        Assert-LingoPlaylistPathAncestors -Path $full
    }
    return $full
}

function Get-LingoPlaylistFolderName {
    param([AllowEmptyString()][string]$Value, [int]$Limit = 80)
    $Limit = [math]::Max(1, $Limit)
    $name = [regex]::Replace($Value, '[<>:"/\\|?*\x00-\x1F]', '_').Trim(' ', '.')
    if (-not $name) { $name = '播放列表' }
    if ($name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') { $name = '_' + $name }
    if ($name.Length -gt $Limit) {
        $name = $name.Substring(0, $Limit)
        if ($name.Length -gt 0 -and [char]::IsHighSurrogate($name[$name.Length - 1])) { $name = $name.Substring(0, $name.Length - 1) }
        $name = $name.Trim(' ', '.')
    }
    if (-not $name) { $name = '列表' }
    if ($name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') { $name = '_' + $name }
    return $name
}

function Get-LingoSavedPlaylistDirectory {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$SourceUrl)
    $base = Get-LingoPlaylistFullPath ([string](Get-LingoPlaylistField $Config 'path'))
    foreach ($entry in @(Get-LingoPlaylistField $Config 'playlistDirectories' @())) {
        if ($null -eq $entry -or [string](Get-LingoPlaylistField $entry 'sourceUrl') -cne $SourceUrl) { continue }
        $savedBase = Get-LingoPlaylistFullPath ([string](Get-LingoPlaylistField $entry 'basePath'))
        if (-not [string]::Equals($savedBase, $base, [StringComparison]::OrdinalIgnoreCase)) { continue }
        return Assert-LingoPlaylistDirectory -BasePath $base -Directory ([string](Get-LingoPlaylistField $entry 'directory'))
    }
    return $null
}

function Get-LingoPlaylistDirectory {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$ConfigPath, [Parameter(Mandatory = $true)][string]$SourceUrl, [Parameter(Mandatory = $true)]$Info, [switch]$ReserveOnly)
    $base = Get-LingoPlaylistFullPath ([string](Get-LingoPlaylistField $Config 'path'))
    Assert-LingoPlaylistPathAncestors -Path $base
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($base.ToUpperInvariant())))).Replace('-', '') }
    finally { $sha.Dispose() }
    $mutex = $null
    $locked = $false
    try {
        $mutex = [Threading.Mutex]::new($false, "Local\LingoSavePlaylistFolders-$key")
        try { $locked = $mutex.WaitOne(15000) }
        catch {
            if ($_.Exception.GetBaseException() -is [Threading.AbandonedMutexException]) { $locked = $true } else { throw }
        }
        if (-not $locked) { throw [IO.IOException]::new('创建播放列表文件夹的锁超时。') }
        Assert-LingoPlaylistPathAncestors -Path $base
        [void][IO.Directory]::CreateDirectory($base)
        # Re-read persisted maps while holding the directory lock: independent workers
        # for the same root job may have loaded the original config simultaneously.
        $persisted = if (-not $ReserveOnly) { Read-LingoJson -Path $ConfigPath -ThrowOnError }
        $writeConfig = if ($persisted) { $persisted } else { $Config }
        if ($persisted) {
            $persistedBase = Get-LingoPlaylistFullPath ([string](Get-LingoPlaylistField $persisted 'path'))
            if (-not [string]::Equals($persistedBase, $base, [StringComparison]::OrdinalIgnoreCase)) { throw '播放列表配置的保存位置已经变化。' }
            Set-LingoPlaylistField $Config 'playlistDirectories' @(Get-LingoPlaylistField $persisted 'playlistDirectories' @())
        }
        $saved = if (-not $ReserveOnly) { Get-LingoSavedPlaylistDirectory -Config $Config -SourceUrl $SourceUrl }
        if ($saved) { return Assert-LingoPlaylistDirectory -BasePath $base -Directory $saved -Create }
        $title = [string](Get-LingoPlaylistField $Info 'title')
        if (-not $title.Trim()) { $title = [string](Get-LingoPlaylistField $Info 'playlist_title') }
        $playlistId = [string](Get-LingoPlaylistField $Info 'id')
        if (-not $title.Trim()) { $title = if ($playlistId.Trim()) { $playlistId } else { '播放列表' } }
        # Reserve 144 characters for the existing 120-character media title,
        # language/extension and conversion suffix. Very long base paths retain
        # at least eight folder-name characters and the downloader's path checks.
        $limit = [math]::Max(8, [math]::Min(80, (240 - $base.Length - 1 - 144)))
        $directory = $null
        for ($number = 1; $number -le 10000; $number++) {
            $suffix = if ($number -eq 1) { '' } else { " ($number)" }
            $name = (Get-LingoPlaylistFolderName -Value $title -Limit ($limit - $suffix.Length)) + $suffix
            $candidate = Join-Path $base $name
            try { $existing = [IO.File]::GetAttributes($candidate) }
            catch {
                $cause = $_.Exception.GetBaseException()
                if ($cause -isnot [IO.FileNotFoundException] -and $cause -isnot [IO.DirectoryNotFoundException]) { throw }
                $existing = $null
            }
            if ($null -ne $existing) { continue }
            $directory = Assert-LingoPlaylistDirectory -BasePath $base -Directory $candidate -Create
            break
        }
        if (-not $directory) { throw '无法创建唯一的下载文件夹。' }
        if ($ReserveOnly) { return $directory }
        $maps = @(Get-LingoPlaylistField $Config 'playlistDirectories' @()) + @([pscustomobject]@{
            sourceUrl = $SourceUrl; title = $title; playlistId = $playlistId; basePath = $base; directory = $directory
        })
        Set-LingoPlaylistField $Config 'playlistDirectories' $maps
        Set-LingoPlaylistField $writeConfig 'playlistDirectories' $maps
        [void](Write-LingoJson -Path $ConfigPath -Value $writeConfig -Depth 40)
        return $directory
    } finally {
        if ($locked -and $mutex) { try { $mutex.ReleaseMutex() } catch { } }
        if ($mutex) { $mutex.Dispose() }
    }
}
function Test-LingoPlaylistScope {
    param([Parameter(Mandatory = $true)]$First, [Parameter(Mandatory = $true)]$Second)
    $firstDirectory = [string](Get-LingoPlaylistField $First 'outputDirectory')
    $secondDirectory = [string](Get-LingoPlaylistField $Second 'outputDirectory')
    if ($firstDirectory -and $secondDirectory) {
        return [string]::Equals((Get-LingoPlaylistFullPath $firstDirectory), (Get-LingoPlaylistFullPath $secondDirectory), [StringComparison]::OrdinalIgnoreCase)
    }
    if ($firstDirectory -or $secondDirectory) {
        $firstSource = [string](Get-LingoPlaylistField $First 'sourceUrl')
        $secondSource = [string](Get-LingoPlaylistField $Second 'sourceUrl')
        if (-not $firstSource) { $firstSource = [string](Get-LingoPlaylistField $First 'url') }
        if (-not $secondSource) { $secondSource = [string](Get-LingoPlaylistField $Second 'url') }
        return $firstSource -ceq $secondSource
    }
    return $true
}
function Get-LingoOfficialPlaylistTitle {
    param($Info, [string]$Site)
    $title = ([string](Get-LingoPlaylistField $Info 'title')).Trim()
    $altTitle = ([string](Get-LingoPlaylistField $Info 'alt_title')).Trim()
    $numberPattern = '(?i)(?:\b\d+\s*(?:/|sur|von|of)\s*\d+\b|\b(?:[ée]pisode|fol[gG]e|part(?:ie)?|teil|e)\s*#?\s*\d+\b|#\s*\d+\b|^\d+\s*[-·–—.]\s+)'
    if ($Site -eq 'arte' -and $altTitle -and $title -and $altTitle -ine $title) {
        if ($title -match $numberPattern) { return "$title - $altTitle" }
        if ($altTitle -match $numberPattern) { return "$altTitle - $title" }
    }
    if ($title -match $numberPattern) { return $title }
    $episode = 0
    if ($title -and [int]::TryParse([string](Get-LingoPlaylistField $Info 'episode_number'), [ref]$episode) -and $episode -gt 0) {
        return "E$episode - $title"
    }
    return $null
}

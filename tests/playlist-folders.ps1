param([switch]$KeepArtifacts)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'playlist-folders.ps1')
$testRoot = Join-Path $env:TEMP ('ls-playlist-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$base = Join-Path $testRoot 'media'
[void][IO.Directory]::CreateDirectory($base)
$passed = 0
$processes = [Collections.ArrayList]::new()
$junction = $null
function Assert-Folder { param([bool]$Ok, [string]$Message); if (-not $Ok) { throw $Message }; $script:passed++; Write-Host ('PASS ' + $Message) }
function Assert-Rejected { param([scriptblock]$Action, [string]$Message); $caught = $false; try { & $Action | Out-Null } catch { $caught = $true }; Assert-Folder $caught $Message }
function New-FolderConfig { param([string]$Name, $Value = $null); if (-not $Value) { $Value = [pscustomobject]@{ path = $base; urls = @('https://example.test/list'); marker = 'preserve' } }; $path = Join-Path $testRoot ($Name + '.config.json'); [void](Write-LingoJson $path $Value); return @{ value = $Value; path = $path } }
function Start-FolderChild { param([string]$ConfigPath, [string]$SourceUrl, [string]$OutputPath)
    $si = [Diagnostics.ProcessStartInfo]::new()
    $si.FileName = Join-Path $PSHOME 'powershell.exe'
    $si.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $childPath + '" -ConfigPath "' + $ConfigPath + '" -SourceUrl "' + $SourceUrl + '" -OutputPath "' + $OutputPath + '"'
    $si.UseShellExecute = $false; $si.CreateNoWindow = $true; $si.RedirectStandardOutput = $true; $si.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($si); [void]$processes.Add($p); return $p
}
try {
    $one = New-FolderConfig 'one'
    $directory = Get-LingoPlaylistDirectory -Config $one.value -ConfigPath $one.path -SourceUrl 'https://example.test/list' -Info @{ title = '中文课程'; id = 'list-one' }
    Assert-Folder ([IO.Directory]::Exists($directory) -and [IO.Path]::GetFileName($directory) -eq '中文课程') 'creates a real folder using the playlist title'
    $disk = Read-LingoJson $one.path
    Assert-Folder (@($disk.playlistDirectories).Count -eq 1 -and $disk.playlistDirectories[0].directory -eq $directory -and $disk.playlistDirectories[0].playlistId -eq 'list-one' -and $disk.marker -eq 'preserve') 'persists playlist identity and absolute directory in root config'
    $resumed = Get-LingoPlaylistDirectory -Config $disk -ConfigPath $one.path -SourceUrl 'https://example.test/list' -Info @{ title = 'Changed title'; id = 'list-one' }
    Assert-Folder ($resumed -eq $directory -and @($disk.playlistDirectories).Count -eq 1) 'resume keeps the existing directory after a title change'
    [IO.Directory]::Delete($directory)
    $restored = Get-LingoPlaylistDirectory -Config $disk -ConfigPath $one.path -SourceUrl 'https://example.test/list' -Info @{ title = 'Changed title'; id = 'list-one' }
    Assert-Folder ($restored -eq $directory -and [IO.Directory]::Exists($directory)) 'recreates a missing saved playlist directory'
    $two = New-FolderConfig 'two' @{ path = $base; urls = @('https://example.test/other') }
    $collision = Get-LingoPlaylistDirectory -Config $two.value -ConfigPath $two.path -SourceUrl 'https://example.test/other' -Info @{ title = '中文课程'; id = 'list-two' }
    Assert-Folder ([IO.Path]::GetFileName($collision) -eq '中文课程 (2)') 'a different job uses a numbered folder without mixing downloads'
    $otherSource = Get-LingoPlaylistDirectory -Config $one.value -ConfigPath $one.path -SourceUrl 'https://example.test/third' -Info @{ title = '中文课程'; id = 'list-three' }
    Assert-Folder ([IO.Path]::GetFileName($otherSource) -eq '中文课程 (3)' -and @((Read-LingoJson $one.path).playlistDirectories).Count -eq 2) 'different playlist links in one job keep separate mappings'
    $dirty = New-FolderConfig 'dirty'
    $clean = Get-LingoPlaylistDirectory -Config $dirty.value -ConfigPath $dirty.path -SourceUrl 'dirty' -Info @{ title = '  A:<B>/C\D|E?*.  '; id = 'dirty' }
    Assert-Folder ([IO.Path]::GetFileName($clean) -eq 'A__B__C_D_E__') 'removes Windows illegal characters and trailing spaces or dots'
    foreach ($name in @('CON', 'con.txt', 'PRN', 'AUX.json', 'NUL', 'COM1', 'COM9.mp4', 'LPT1', 'LPT9.txt', '.', '..', ' . ')) {
        $fixture = New-FolderConfig ('reserved-' + $passed)
        $safe = Get-LingoPlaylistDirectory -Config $fixture.value -ConfigPath $fixture.path -SourceUrl ('reserved-' + $passed) -Info @{ title = $name; id = 'reserved' }
        Assert-Folder ([IO.Directory]::Exists($safe) -and [IO.Path]::GetDirectoryName($safe) -eq $base -and [IO.Path]::GetFileName($safe) -notmatch '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') ('handles reserved title ' + $name)
    }
    [IO.File]::WriteAllText((Join-Path $base 'Occupied'), 'keep')
    $occupied = New-FolderConfig 'occupied'
    $free = Get-LingoPlaylistDirectory -Config $occupied.value -ConfigPath $occupied.path -SourceUrl 'occupied' -Info @{ title = 'Occupied'; id = 'occupied' }
    Assert-Folder ([IO.Path]::GetFileName($free) -eq 'Occupied (2)' -and [IO.File]::ReadAllText((Join-Path $base 'Occupied')) -eq 'keep') 'does not overwrite an existing file with the same basename'
    $fallback = New-FolderConfig 'fallback'
    $fallbackFolder = Get-LingoPlaylistDirectory -Config $fallback.value -ConfigPath $fallback.path -SourceUrl 'fallback' -Info @{ id = 'PL123' }
    Assert-Folder ([IO.Path]::GetFileName($fallbackFolder) -eq 'PL123') 'uses the playlist ID when title is absent'
    $empty = New-FolderConfig 'empty'
    $emptyFolder = Get-LingoPlaylistDirectory -Config $empty.value -ConfigPath $empty.path -SourceUrl 'empty' -Info @{}
    Assert-Folder ([IO.Path]::GetFileName($emptyFolder).StartsWith('播放列表') -and [IO.Directory]::Exists($emptyFolder)) 'uses a readable fallback when title and ID are absent'
    $long = New-FolderConfig 'long'
    $longFolder = Get-LingoPlaylistDirectory -Config $long.value -ConfigPath $long.path -SourceUrl 'long' -Info @{ title = ('Very long lesson ' * 30); id = 'long' }
    Assert-Folder ([IO.Path]::GetFileName($longFolder).Length -le 80 -and [IO.Path]::GetFileName($longFolder).Length -ge 8) 'caps folder names and retains a nonempty name with media filename headroom'
    Assert-Rejected { Assert-LingoPlaylistDirectory -BasePath $base -Directory (Join-Path $testRoot 'outside') -Create } 'rejects a directory outside the selected base'
    Assert-Rejected { Assert-LingoPlaylistDirectory -BasePath $base -Directory (Join-Path $base 'nested\outside') -Create } 'rejects a nested mapping instead of a direct child'
    Assert-Rejected { Assert-LingoPlaylistDirectory -BasePath $base -Directory (Join-Path $base '..\escape') -Create } 'rejects traversal in a saved mapping'
    Assert-Rejected { Assert-LingoPlaylistDirectory -BasePath $base -Directory (Join-Path $base 'Occupied') -Create } 'rejects a saved mapping now occupied by a file'
    $bad = @{ path = $base; playlistDirectories = @(@{ sourceUrl = 'bad'; basePath = $base; directory = (Join-Path $testRoot 'outside') }) }
    Assert-Rejected { Get-LingoSavedPlaylistDirectory -Config $bad -SourceUrl 'bad' } 'rejects an escaped persisted playlist directory'
    $target = Join-Path $testRoot 'junction-target'; [void][IO.Directory]::CreateDirectory($target)
    $junction = Join-Path $base 'junction'
    New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
    Assert-Rejected { Assert-LingoPlaylistDirectory -BasePath $base -Directory $junction -Create } 'rejects a playlist directory that is a junction'
    Assert-Rejected { Assert-LingoPlaylistDirectory -BasePath $junction -Directory (Join-Path $junction 'child') -Create } 'rejects reparse points in the base ancestry'
    $childPath = Join-Path $testRoot 'create-folder.ps1'
    $childSource = 'param([string]$ConfigPath, [string]$SourceUrl, [string]$OutputPath)
$ErrorActionPreference = "Stop"
. "D:\Codex\playlist-folders.ps1"
$config = Read-LingoJson -Path $ConfigPath
$folder = Get-LingoPlaylistDirectory -Config $config -ConfigPath $ConfigPath -SourceUrl $SourceUrl -Info @{ title = "Parallel"; id = $SourceUrl }
[IO.File]::WriteAllText($OutputPath, $folder, [Text.UTF8Encoding]::new($false))'
    [IO.File]::WriteAllText($childPath, $childSource, [Text.UTF8Encoding]::new($true))
    $children = @()
    for ($n = 1; $n -le 4; $n++) {
        $c = New-FolderConfig ('parallel-' + $n)
        $output = Join-Path $testRoot ('parallel-' + $n + '.result')
        $children += @{ process = (Start-FolderChild $c.path ('parallel-' + $n) $output); output = $output }
    }
    $folders = @()
    foreach ($child in $children) {
        if (-not $child.process.WaitForExit(20000)) { throw 'parallel folder creator timed out' }
        $errorOutput = $child.process.StandardError.ReadToEnd()
        Assert-Folder ($child.process.ExitCode -eq 0) ('parallel folder creator succeeded: ' + $errorOutput)
        $folders += [IO.File]::ReadAllText($child.output)
    }
    Assert-Folder (@($folders | Select-Object -Unique).Count -eq 4 -and @($folders | Where-Object { [IO.Directory]::Exists($_) }).Count -eq 4) 'cross-process directory lock assigns four unique real folders'
    $same = New-FolderConfig 'same-parallel'
    $sameA = Join-Path $testRoot 'same-a.result'; $sameB = Join-Path $testRoot 'same-b.result'
    $a = Start-FolderChild $same.path 'same-source' $sameA; $b = Start-FolderChild $same.path 'same-source' $sameB
    foreach ($p in @($a, $b)) { if (-not $p.WaitForExit(20000)) { throw 'same-job creator timed out' }; $err = $p.StandardError.ReadToEnd(); Assert-Folder ($p.ExitCode -eq 0) ('same-job creator succeeded: ' + $err) }
    Assert-Folder ([IO.File]::ReadAllText($sameA) -eq [IO.File]::ReadAllText($sameB) -and @((Read-LingoJson $same.path).playlistDirectories).Count -eq 1) 'workers that loaded one config concurrently reuse one persisted directory'
    Assert-Folder (-not (Test-LingoPlaylistScope -First @{ outputDirectory = $directory; sourceUrl = 'same' } -Second @{ outputDirectory = $collision; sourceUrl = 'same' })) 'shared videos in different playlist directories have different scopes'
    Assert-Folder (Test-LingoPlaylistScope -First @{ outputDirectory = $directory; sourceUrl = 'same' } -Second @{ sourceUrl = 'same' }) 'old item without output directory still matches the same source'
    Assert-Folder (-not (Test-LingoPlaylistScope -First @{ outputDirectory = $directory; sourceUrl = 'same' } -Second @{ sourceUrl = 'other' })) 'old item without output directory does not match another source'
    Assert-Folder (Test-LingoPlaylistScope -First @{ outputDirectory = $directory.ToUpperInvariant(); sourceUrl = 'same' } -Second @{ outputDirectory = $directory; sourceUrl = 'other' }) 'folder scope is case-insensitive when both paths are saved'
    Assert-Folder (Test-LingoPlaylistScope -First @{ sourceUrl = 'one' } -Second @{ sourceUrl = 'two' }) 'two legacy items without saved output paths retain previous identity behavior'
    Assert-Folder ((Get-LingoPlaylistFolderName -Value 'title' -Limit 0).Length -gt 0) 'retains a nonempty stem even when a large collision suffix uses the available name budget'
    $longBase = Join-Path $base ('long-base-' + ('a' * 75))
    $longCase = New-FolderConfig 'long-base-config' @{ path = $longBase; marker = 'long-base' }
    $longBaseFolder = Get-LingoPlaylistDirectory -Config $longCase.value -ConfigPath $longCase.path -SourceUrl 'long-base' -Info @{ title = ('Lesson title ' * 30); id = 'long-base' }
    Assert-Folder ([IO.Directory]::Exists($longBaseFolder) -and [IO.Path]::GetFileName($longBaseFolder).Length -eq 8) 'a long selected base retains at least eight title characters instead of an empty folder name'
    foreach ($legacy in @(@{ url = 'https://example.test/old' }, @{ url = 'https://example.test/old'; sourceUrl = $null })) {
        Assert-Folder (Test-LingoPlaylistScope -First $legacy -Second @{ outputDirectory = $base; sourceUrl = 'https://example.test/old'; url = 'https://example.test/old' }) 'legacy source missing or null falls back to its matching URL'
    }
    Assert-Folder (-not (Test-LingoPlaylistScope -First @{ url = 'https://example.test/old'; sourceUrl = $null } -Second @{ outputDirectory = $base; sourceUrl = 'https://example.test/other'; url = 'https://example.test/other' })) 'legacy empty source fallback does not match a different URL'
    Write-Host ('Playlist folder assertions: ' + $passed)
} finally {
    foreach ($p in $processes) { try { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(5000) }; $p.Dispose() } catch { } }
    if ($junction -and [IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction) }
    if ($KeepArtifacts) { Write-Host ('Artifacts: ' + $testRoot) }
    else {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        $allowed = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('ls-playlist-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
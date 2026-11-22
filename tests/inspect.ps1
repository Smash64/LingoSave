$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$result = & (Join-Path $root 'media-inspection.ps1') -Url 'https://www.arte.tv/zh/videos/sample-001/' -YtDlpPath (Join-Path $PSScriptRoot 'fake-yt-dlp.ps1') | ConvertFrom-Json
if ($result.platform -ne 'ARTE' -or $result.id -ne 'sample-001') { throw 'Media identity mismatch.' }
if ($result.formats.Count -ne 3 -or $result.audioTracks.Count -ne 2) { throw 'Format enumeration mismatch.' }
if (@($result.subtitles | Where-Object rawKey -eq 'fr-acc').Count -ne 1) { throw 'fr-acc was lost.' }
if (@($result.subtitles | Where-Object rawKey -eq 'danmaku').Count -ne 0) { throw 'XML danmaku was misclassified.' }
if (@($result.subtitles | Where-Object source -eq 'auto').Count -ne 1) { throw 'Automatic subtitle source mismatch.' }
Write-Output 'Media inspection fixture passed.'

param([string]$Source = 'lingosave-03-brand.png')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if ([IO.Path]::GetFileName($Source) -cne $Source) { throw 'Source must be an icon filename.' }
$sourcePath = Join-Path $PSScriptRoot $Source
$bitmap = [Drawing.Bitmap]::new($sourcePath)
try {
    $left = $bitmap.Width; $top = $bitmap.Height; $right = -1; $bottom = -1
    for ($y = 0; $y -lt $bitmap.Height; $y++) {
        for ($x = 0; $x -lt $bitmap.Width; $x++) {
            if ($bitmap.GetPixel($x, $y).A -le 20) { continue }
            $left = [Math]::Min($left, $x); $right = [Math]::Max($right, $x)
            $top = [Math]::Min($top, $y); $bottom = [Math]::Max($bottom, $y)
        }
    }
    if ($right -lt 0) { throw 'Icon source is empty.' }
    $contentSize = [Math]::Max($right - $left + 1, $bottom - $top + 1)
    $padding = [Math]::Max(2, [int][Math]::Ceiling($contentSize * 0.0075))
    $size = [int][Math]::Ceiling(($contentSize + 2 * $padding) / 2.0) * 2
    if ($size -gt $bitmap.Width -or $size -gt $bitmap.Height) { throw 'Source has insufficient transparent margin.' }
    $cropX = [Math]::Max(0, [Math]::Min($bitmap.Width - $size, [int][Math]::Floor(($left + $right + 1 - $size) / 2.0)))
    $cropY = [Math]::Max(0, [Math]::Min($bitmap.Height - $size, [int][Math]::Floor(($top + $bottom + 1 - $size) / 2.0)))
} finally { $bitmap.Dispose() }

$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$output = Join-Path $PSScriptRoot 'lingosave-app.png'
& $ffmpeg -hide_banner -loglevel error -y -i $sourcePath -vf "crop=${size}:${size}:${cropX}:${cropY},format=rgba" -frames:v 1 $output
if ($LASTEXITCODE -ne 0) { throw 'App icon preparation failed.' }
& (Join-Path $PSScriptRoot 'make-ico.ps1') -Names 'lingosave-app.png'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'lingosave-app.ico') -Destination (Join-Path $PSScriptRoot 'lingosave-app-v2.ico') -Force
Write-Output "App icon: ${size}x${size}, original source preserved."

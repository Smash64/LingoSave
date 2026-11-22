param([string[]]$Names = @('lingosave-01-media.png', 'lingosave-02-download.png', 'lingosave-03-brand.png'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$iconDirectory = [IO.Path]::GetFullPath($PSScriptRoot)
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$sizes = @(256, 192, 128, 96, 80, 64, 48, 40, 32, 24, 20, 16)
$scratch = Join-Path $iconDirectory ('.ico-build-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)

try {
    foreach ($name in $Names) {
        if ([IO.Path]::GetFileName($name) -cne $name -or $name -notmatch '\.png$') { throw "Invalid icon filename: $name" }
        $source = Get-Item -LiteralPath (Join-Path $iconDirectory $name) -ErrorAction Stop
        $frames = [System.Collections.Generic.List[object]]::new()
        foreach ($size in $sizes) {
            $temporary = Join-Path $scratch "$($source.BaseName)-$size.ico"
            & $ffmpeg -hide_banner -loglevel error -y -i $source.FullName -vf "scale=${size}:${size}:flags=lanczos,format=bgra" -frames:v 1 -c:v bmp $temporary
            if ($LASTEXITCODE -ne 0) { throw "Failed to render $($source.Name) at $size pixels." }

            $bytes = [IO.File]::ReadAllBytes($temporary)
            if ($bytes.Length -lt 22 -or [BitConverter]::ToUInt16($bytes, 2) -ne 1) { throw "Invalid temporary icon: $temporary" }
            $length = [int][BitConverter]::ToUInt32($bytes, 14)
            $offset = [int][BitConverter]::ToUInt32($bytes, 18)
            if ($length -le 0 -or $offset + $length -gt $bytes.Length) { throw "Invalid frame bounds: $temporary" }
            $entry = [byte[]]::new(8)
            [Buffer]::BlockCopy($bytes, 6, $entry, 0, 8)
            $payload = [byte[]]::new($length)
            [Buffer]::BlockCopy($bytes, $offset, $payload, 0, $length)
            [void]$frames.Add(@{ Entry = $entry; Payload = $payload })
        }

        $destination = Join-Path $iconDirectory ($source.BaseName + '.ico')
        $file = [IO.File]::Open($destination, [IO.FileMode]::Create, [IO.FileAccess]::Write)
        $writer = [IO.BinaryWriter]::new($file)
        try {
            $writer.Write([uint16]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]$frames.Count)
            $offset = 6 + 16 * $frames.Count
            foreach ($frame in $frames) {
                $writer.Write([byte[]]$frame.Entry)
                $writer.Write([uint32]$frame.Payload.Length)
                $writer.Write([uint32]$offset)
                $offset += $frame.Payload.Length
            }
            foreach ($frame in $frames) { $writer.Write([byte[]]$frame.Payload) }
        } finally { $writer.Dispose() }

        $icon = [Drawing.Icon]::new($destination)
        try {
            $bitmap = $icon.ToBitmap()
            try { Write-Output "$($source.BaseName).ico: $($bitmap.Width)x$($bitmap.Height), $($frames.Count) sizes" }
            finally { $bitmap.Dispose() }
        } finally { $icon.Dispose() }
    }
} finally {
    $allowed = $iconDirectory.TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath($scratch)
    if ($target.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($target)) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

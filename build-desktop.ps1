param([string]$OutputPath)

$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not [System.IO.File]::Exists($compiler)) { throw 'Windows C# compiler was not found.' }
$source = Join-Path $PSScriptRoot 'desktop\LingoSaveLauncher.cs'
$branding = Join-Path $PSScriptRoot 'desktop\DesktopBranding.cs'
$trayTasks = Join-Path $PSScriptRoot 'desktop\TrayTasks.cs'
$manifest = Join-Path $PSScriptRoot 'desktop\LingoSave.manifest'
$icon = Join-Path $PSScriptRoot 'assets\icons\lingosave-app.ico'
if (-not [System.IO.File]::Exists($icon)) { throw 'LingoSave app icon was not found.' }
$output = if ($OutputPath) { [System.IO.Path]::GetFullPath($OutputPath) } else { Join-Path $PSScriptRoot 'LingoSave.exe' }
& $compiler /nologo /target:winexe /platform:x64 /codepage:65001 "/out:$output" "/win32icon:$icon" "/win32manifest:$manifest" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll $source $branding $trayTasks
if ($LASTEXITCODE -ne 0) { throw "Build failed, exit code $LASTEXITCODE" }
Write-Output "Built $output"

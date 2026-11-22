param([ValidateRange(1024, 65535)][int]$Port = 8765, [int]$ParentPid = 0, [long]$ParentStartTicks = 0, [string]$LaunchId = $null)

$launchArgs = @('-Port', $Port, '-ParentPid', $ParentPid, '-ParentStartTicks', $ParentStartTicks)
if ($LaunchId) { $launchArgs += @('-LaunchId', $LaunchId) }
$launchParams = @{ Port = $Port; ParentPid = $ParentPid; ParentStartTicks = $ParentStartTicks }
if ($LaunchId) { $launchParams.LaunchId = $LaunchId }

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not [System.IO.File]::Exists($windowsPowerShell)) { throw '无法启动 STA PowerShell，文件夹选择窗口不可用。' }
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -Sta -File $PSCommandPath @launchArgs
    return
}

& (Join-Path $PSScriptRoot 'server.ps1') @launchParams

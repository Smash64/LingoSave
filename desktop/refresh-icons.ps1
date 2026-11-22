param([string]$Executable = (Join-Path (Split-Path $PSScriptRoot -Parent) 'LingoSave.exe'))

$ErrorActionPreference = 'Stop'
$resolved = (Get-Item -LiteralPath $Executable).FullName
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LingoSaveIconRefresh {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern void SHChangeNotify(uint events, uint flags, string item1, string item2);
    public static void Refresh(string executable) {
        SHChangeNotify(0x2000, 0x1005, executable, null); // SHCNE_UPDATEITEM, SHCNF_PATHW | SHCNF_FLUSH
        SHChangeNotify(0x8000000, 0, null, null); // Refresh Shell icon associations.
    }
}
'@
[LingoSaveIconRefresh]::Refresh($resolved)
$iconUtility = Join-Path $env:WINDIR 'System32\ie4uinit.exe'
if (Test-Path -LiteralPath $iconUtility) {
    $refresh = Start-Process -FilePath $iconUtility -ArgumentList '-show' -WindowStyle Hidden -PassThru
    [void]$refresh.WaitForExit(10000)
}
Write-Output 'Windows icon refresh requested.'

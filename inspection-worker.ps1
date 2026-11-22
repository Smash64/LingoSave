param([Parameter(Mandatory = $true)][string]$ConfigPath)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'state-io.ps1')
$config = Read-LingoJson -Path $ConfigPath -ThrowOnError
. (Join-Path $PSScriptRoot 'credential-store.ps1')
. (Join-Path $PSScriptRoot 'media-cache.ps1')
. (Join-Path $PSScriptRoot 'transfer-slots.ps1')

function Save-InspectionStatus {
    param($Status)
    $target = [string]$config.statusPath
    [void](Write-LingoJson -Path $target -Value $Status -Depth 15)
}

$status = Read-LingoJson -Path $config.statusPath -ThrowOnError
$cookieFile = $null
$metadataLease = $null
$markerPath = Join-Path ([string]$config.inspectionsRoot) "$($config.id).cookie-temp.json"
try {
    $status.status = 'running'
    Save-InspectionStatus $status
    if ($config.cookieRevision) {
        $cookieFile = New-LingoTemporaryCookieFile -Site ([string]$config.site) -StoreRoot ([string]$config.storeRoot) -Revision ([string]$config.cookieRevision)
        [System.IO.File]::WriteAllText($markerPath, (ConvertTo-Json -InputObject @{ path = $cookieFile } -Compress), [System.Text.UTF8Encoding]::new($false))
    }
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'media-inspection.ps1'), '-Url', [string]$config.url, '-YtDlpPath', [string]$config.ytDlpPath)
    if ($config.denoPath) { $arguments += @('-DenoPath', [string]$config.denoPath) }
    $cachePath = Get-LingoMetadataPath -StoreRoot ([string]$config.storeRoot) -Url ([string]$config.url) -CookieRevision ([string]$config.cookieRevision) -Mode single
    $arguments += @('-MetadataCachePath', $cachePath)
    if ($config.cookieRevision) { $arguments += @('-CookieRevision', [string]$config.cookieRevision) }
    $metadataLease = Enter-LingoTransferSlot -StoreRoot ([string]$config.storeRoot) -Kind metadata
    if ($cookieFile) { $arguments += @('-CookiePath', $cookieFile) }
    $errorPath = Join-Path ([string]$config.inspectionsRoot) "$($config.id).error.log"
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $resultText = & (Join-Path $PSHOME 'powershell.exe') @arguments 2> $errorPath | Out-String
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($code -ne 0 -or -not $resultText.Trim()) {
        $details = if ([System.IO.File]::Exists($errorPath)) { [System.IO.File]::ReadAllText($errorPath) } else { '' }
        $lines = @($details -split '\r?\n' | Where-Object { $_.Trim() })
        $line = @($lines | Where-Object { $_ -match 'ERROR:|Unable to|unavailable|access denied|HTTP Error|超时|失败' } | Select-Object -First 1)
        if ($line.Count -eq 0) { $line = @($lines | Where-Object { $_ -notmatch '^\s*(\+|At |CategoryInfo|FullyQualifiedErrorId)' } | Select-Object -First 1) }
        if ($line.Count -eq 0) { throw "资源解析失败（进程代码 $code）。" }
        $message = ([string]$line[0]).Trim()
        throw $message.Substring(0, [math]::Min(500, $message.Length))
    }
    $status.result = ConvertFrom-Json -InputObject $resultText
    $status.status = 'completed'
    $status.error = $null
    Save-InspectionStatus $status
} catch {
    $status.status = 'failed'
    $status.error = ([string]$_.Exception.Message).Substring(0, [math]::Min(500, ([string]$_.Exception.Message).Length))
    Save-InspectionStatus $status
    exit 1
} finally {
    if ($metadataLease) { Exit-LingoTransferSlot -Lease $metadataLease }
    if ($cookieFile) { try { Remove-LingoTemporaryCookieFile -Path $cookieFile -StoreRoot ([string]$config.storeRoot) } catch { } }
    if ([System.IO.File]::Exists($markerPath)) { try { [System.IO.File]::Delete($markerPath) } catch { } }
    if ([System.IO.File]::Exists($errorPath)) { try { [System.IO.File]::Delete($errorPath) } catch { } }
}

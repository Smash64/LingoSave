# Cross-process resource budgets. Leases belong to a PID and exact process start time.
if (-not (Get-Command Read-LingoJson -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'state-io.ps1') }

function Get-LingoTransferPolicy {
    param([Parameter(Mandatory=$true)][string]$StoreRoot)
    $saved = Read-LingoJson -Path (Join-Path $StoreRoot 'transfer-policy.json')
    $download = 3; $processing = 2; $metadata = 2
    if ($saved) {
        if ($saved.downloadLimit -is [int] -and $saved.downloadLimit -ge 1) { $download = [math]::Min(4, [int]$saved.downloadLimit) }
        if ($saved.processingLimit -is [int] -and $saved.processingLimit -ge 1) { $processing = [math]::Min(2, [int]$saved.processingLimit) }
        if ($saved.metadataLimit -is [int] -and $saved.metadataLimit -ge 1) { $metadata = [math]::Min(2, [int]$saved.metadataLimit) }
    }
    return @{ downloadLimit=$download; processingLimit=$processing; metadataLimit=$metadata; fragmentConcurrency=4; maxFragmentConnections=16 }
}

function Set-LingoTransferPolicy {
    param([Parameter(Mandatory=$true)][string]$StoreRoot, [ValidateRange(1,5)][int]$DownloadLimit=3, [ValidateRange(1,2)][int]$ProcessingLimit=2, [ValidateRange(1,2)][int]$MetadataLimit=2, [ValidateSet(4)][int]$FragmentConcurrency=4)
    $policy = @{ downloadLimit=[math]::Min(4,$DownloadLimit); processingLimit=$ProcessingLimit; metadataLimit=$MetadataLimit; fragmentConcurrency=$FragmentConcurrency; maxFragmentConnections=16 }
    [void](Write-LingoJson -Path (Join-Path $StoreRoot 'transfer-policy.json') -Value $policy)
    return $policy
}

function New-LingoSlotMutex {
    param([string]$StoreRoot)
    $normalized = [IO.Path]::GetFullPath($StoreRoot).TrimEnd('\').ToUpperInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-','').Substring(0,24) }
    finally { $sha.Dispose() }
    return [Threading.Mutex]::new($false, "Local\LingoSaveTransfers-$key")
}

function Test-LingoSlotOwner {
    param($Record)
    if (-not $Record -or -not $Record.pid -or -not $Record.startedAtTicks) { return $false }
    try {
        $owner = [Diagnostics.Process]::GetProcessById([int]$Record.pid)
        try { return (-not $owner.HasExited -and $owner.StartTime.Ticks -eq [long]$Record.startedAtTicks) }
        finally { $owner.Dispose() }
    } catch { return $false }
}

function Enter-LingoTransferSlot {
    param([Parameter(Mandatory=$true)][string]$StoreRoot, [Parameter(Mandatory=$true)][ValidateSet('download','processing','metadata')][string]$Kind, [string]$ControlPath, [scriptblock]$OnWait)
    if ([string]::IsNullOrWhiteSpace($StoreRoot)) { throw '下载资源预算需要独立的用户数据目录。' }
    $fullRoot = [IO.Path]::GetFullPath($StoreRoot)
    $slotRoot = Join-Path $fullRoot 'transfer-slots'
    $waitRoot = Join-Path $slotRoot 'waiting'
    [void][IO.Directory]::CreateDirectory($waitRoot)
    $self = [Diagnostics.Process]::GetCurrentProcess()
    try { $startedAtTicks = $self.StartTime.Ticks } finally { $self.Dispose() }
    $token = [guid]::NewGuid().ToString('N')
    $request = @{ pid=$PID; startedAtTicks=$startedAtTicks; token=$token; kind=$Kind; requestedTicks=[DateTime]::UtcNow.Ticks }
    $waitPath = Join-Path $waitRoot "$Kind-$token.json"
    [void](Write-LingoJson -Path $waitPath -Value $request)
    $mutex = New-LingoSlotMutex $fullRoot
    $lastNotification = [DateTime]::MinValue
    $acquired = $false
    try {
        while (-not $acquired) {
            if ($ControlPath) { Assert-LingoTransferAllowed -ControlPath $ControlPath }
            $locked = $false
            try {
                try { $locked = $mutex.WaitOne(1000) } catch [Threading.AbandonedMutexException] { $locked=$true }
                if ($locked) {
                    $policy = Get-LingoTransferPolicy $fullRoot
                    $limit = switch ($Kind) { 'download' { [int]$policy.downloadLimit } 'processing' { [int]$policy.processingLimit } default { [int]$policy.metadataLimit } }
                    $liveLeases = @()
                    foreach ($file in @(Get-ChildItem -LiteralPath $slotRoot -Filter "$Kind-*.json" -File)) {
                        $record = Read-LingoJson -Path $file.FullName
                        if (Test-LingoSlotOwner $record) { $liveLeases += @{ path=$file.FullName; record=$record } }
                        else { [IO.File]::Delete($file.FullName) }
                    }
                    $waiting = @()
                    foreach ($file in @(Get-ChildItem -LiteralPath $waitRoot -Filter "$Kind-*.json" -File)) {
                        $record = Read-LingoJson -Path $file.FullName
                        if (Test-LingoSlotOwner $record) { $waiting += $record }
                        else { [IO.File]::Delete($file.FullName) }
                    }
                    $first = @($waiting | Sort-Object @{Expression={[long]$_.requestedTicks}}, @{Expression={[string]$_.token}} | Select-Object -First 1)
                    # Lowering the limit never terminates an in-flight transfer.
                    if ($liveLeases.Count -lt $limit -and $first.Count -eq 1 -and $first[0].token -eq $token) {
                        for ($index=0; $index -lt $limit; $index++) {
                            $leasePath = Join-Path $slotRoot "$Kind-$index.json"
                            if (-not [IO.File]::Exists($leasePath)) {
                                [void](Write-LingoJson -Path $leasePath -Value $request)
                                [IO.File]::Delete($waitPath)
                                $acquired=$true
                                return [pscustomobject]@{ StoreRoot=$fullRoot; Kind=$Kind; Token=$token; Path=$leasePath; Pid=$PID; StartedAtTicks=$startedAtTicks }
                            }
                        }
                    }
                }
            } finally { if($locked){$mutex.ReleaseMutex()} }
            if ($OnWait -and ([DateTime]::UtcNow-$lastNotification).TotalMilliseconds -ge 500) { & $OnWait; $lastNotification=[DateTime]::UtcNow }
            Start-Sleep -Milliseconds 120
        }
    } finally {
        if (-not $acquired -and [IO.File]::Exists($waitPath)) { [IO.File]::Delete($waitPath) }
        $mutex.Dispose()
    }
}

function Exit-LingoTransferSlot {
    param($Lease)
    if (-not $Lease) { return }
    $slotRoot = [IO.Path]::GetFullPath((Join-Path ([string]$Lease.StoreRoot) 'transfer-slots')).TrimEnd('\')
    $leasePath = [IO.Path]::GetFullPath([string]$Lease.Path)
    if ([IO.Path]::GetDirectoryName($leasePath) -ne $slotRoot -or [IO.Path]::GetFileName($leasePath) -notmatch '^(download|processing|metadata)-[0-3]\.json$') { throw '下载资源预算释放路径无效。' }
    $mutex = New-LingoSlotMutex ([string]$Lease.StoreRoot)
    $locked=$false
    try {
        try { $locked=$mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] {$locked=$true}
        if (-not $locked) { throw '下载资源预算释放锁超时。' }
        $record=Read-LingoJson -Path $leasePath
        if ($record -and [string]$record.token -eq [string]$Lease.Token -and [int]$record.pid -eq $PID) { [IO.File]::Delete($leasePath) }
    } finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
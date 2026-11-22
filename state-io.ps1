# Shared, atomic JSON persistence. Readers permit replacement while a snapshot is open.
function Write-LingoIoDiagnostic {
    param([string]$Path, [string]$Operation, [string]$Message)
    try {
        $line = "{0:o} {1} {2}{3}" -f [DateTime]::UtcNow, $Operation, ($Message -replace '[\r\n]+', ' '), [Environment]::NewLine
        [System.IO.File]::AppendAllText("$Path.io.log", $line, [System.Text.UTF8Encoding]::new($false))
    } catch { }
}

function Read-LingoJson {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$ThrowOnError)
    $lastError = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $stream = $null
        $reader = $null
        try {
            $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
            $json = $reader.ReadToEnd()
            $value = ConvertFrom-Json -InputObject $json -ErrorAction Stop
            return $value
        } catch {
            $lastError = $_
            $baseError = $_.Exception.GetBaseException()
            if ($baseError.GetType() -eq [System.IO.FileNotFoundException] -or $baseError.GetType() -eq [System.IO.DirectoryNotFoundException]) { return $null }
            if ($attempt -lt 4) { Start-Sleep -Milliseconds (30 * ($attempt + 1)) }
        }
        finally { if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() } }
    }
    if ($lastError) {
        Write-LingoIoDiagnostic -Path $Path -Operation 'read_failed' -Message $lastError.Exception.Message
    }
    if ($ThrowOnError) { throw $lastError }
    return $null
}

function Write-LingoJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowNull()]$Value, [int]$Depth = 15, [switch]$BestEffort)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fullPath.ToUpperInvariant())))).Replace('-', '') }
    finally { $sha.Dispose() }
    $mutex = $null
    $locked = $false
    # Keep the temporary basename short: checkpoint folders can approach MAX_PATH.
    $temp = Join-Path ([System.IO.Path]::GetDirectoryName($fullPath)) ('.ls-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.tmp')
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth $Depth -Compress -ErrorAction Stop
        $mutex = [System.Threading.Mutex]::new($false, "Local\LingoSaveState-$key")
        try { $locked = $mutex.WaitOne(5000) } catch {
            if ($_.Exception.GetBaseException().GetType() -eq [System.Threading.AbandonedMutexException]) { $locked = $true } else { throw }
        }
        if (-not $locked) { throw [System.IO.IOException]::new('状态文件写入锁超时。') }
        $parent = [System.IO.Path]::GetDirectoryName($fullPath)
        [void][System.IO.Directory]::CreateDirectory($parent)
        [System.IO.File]::WriteAllText($temp, $json, [System.Text.UTF8Encoding]::new($false))
        $limit = if ($BestEffort) { 3 } else { 10 }
        for ($attempt = 0; $attempt -lt $limit; $attempt++) {
            try {
                if ([System.IO.File]::Exists($fullPath)) { [System.IO.File]::Replace($temp, $fullPath, [NullString]::Value) }
                else { [System.IO.File]::Move($temp, $fullPath) }
                if ($attempt -gt 0) { Write-LingoIoDiagnostic -Path $fullPath -Operation 'write_recovered' -Message "retries=$attempt" }
                return $true
            } catch {
                if ($_.Exception.GetBaseException() -isnot [System.IO.IOException] -or $attempt -eq ($limit - 1)) { throw }
                Start-Sleep -Milliseconds ([int][math]::Min(500, 40 * [math]::Pow(2, $attempt)))
            }
        }
    } catch {
        Write-LingoIoDiagnostic -Path $fullPath -Operation 'write_failed' -Message $_.Exception.Message
        if (-not $BestEffort) { throw }
        return $false
    } finally {
        if ($locked -and $mutex) { try { $mutex.ReleaseMutex() } catch { } }
        if ($mutex) { $mutex.Dispose() }
        if ([System.IO.File]::Exists($temp)) { try { [System.IO.File]::Delete($temp) } catch { } }
    }
}

function Set-LingoObjectField {
    param($Object, [string]$Name, $Value)
    if ($Object -is [System.Collections.IDictionary]) { $Object[$Name] = $Value }
    elseif ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-LingoControlAction {
    param([string]$Path)
    $control = Read-LingoJson -Path $Path
    if ($control -and [string]$control.action -in @('pause', 'cancel')) { return [string]$control.action }
    return $null
}

function Assert-LingoTransferAllowed {
    param([string]$ControlPath)
    $action = Get-LingoControlAction -Path $ControlPath
    if ($action) {
        $exception = [System.OperationCanceledException]::new("LingoSave $action")
        $exception.Data['LingoControlAction'] = $action
        throw $exception
    }
}

function Test-LingoControlException {
    param($ErrorRecord)
    return $ErrorRecord.Exception.Data.Contains('LingoControlAction')
}

function Test-LingoNetworkError {
    param([string]$Message)
    # Authentication, removed media, disk errors and HTTP 4xx except 408/429 are terminal.
    return $Message -match '(?i)timed?\s*out|timeout|connection (?:reset|refused|aborted|closed)|remote (?:end )?closed|network (?:is )?(?:unreachable|down)|temporary failure|name or service not known|name resolution|getaddrinfo|unable to resolve|failed to resolve|no route to host|incomplete read|incompleteread|HTTP (?:Error )?(?:408|429|5\d\d)|WinError (?:10050|10051|10052|10053|10054|10060|10061|10065|11001)|errno (?:101|104|110|111)|断网|网络.*(?:超时|中断)'
}

function Stop-LingoProcessTree {
    param($Process, $ProcessJob)
    if ($ProcessJob) { try { $ProcessJob.Terminate() } catch { } }
    try {
        if (-not $Process.HasExited) {
            if (-not $ProcessJob) {
                $taskkill = Join-Path $env:WINDIR 'System32\taskkill.exe'
                if ([System.IO.File]::Exists($taskkill)) { & $taskkill /PID $Process.Id /T /F *> $null }
                else { $Process.Kill() }
            } else { $Process.Kill() }
            [void]$Process.WaitForExit(5000)
        }
    } catch { }
}

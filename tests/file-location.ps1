param([switch]$KeepArtifacts, [switch]$NoForegroundFixture)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'state-io.ps1')
$testRoot = Join-Path $env:TEMP ('lingosave-file-location-' + [guid]::NewGuid().ToString('N'))
$dataRoot = Join-Path $testRoot 'data'
$mediaRoot = Join-Path $testRoot 'Chinese 中文, saved files'
[void][IO.Directory]::CreateDirectory((Join-Path $dataRoot 'jobs'))
[void][IO.Directory]::CreateDirectory($mediaRoot)
$mediaPath = Join-Path $mediaRoot 'Video 视频, episode 01 & final.mp4'
$secondMediaPath = Join-Path $mediaRoot 'Video 视频, episode 02 & final.mp4'
[IO.File]::WriteAllText($mediaPath, 'A local file used only for folder selection verification.')
[IO.File]::WriteAllText($secondMediaPath, 'A second local file used only for folder selection verification.')
$id = [guid]::NewGuid().ToString('N')
$url = 'https://www.youtube.com/watch?v=local-folder-test'
$job = @{ id=$id; status='completed'; urls=@($url); createdAt=[DateTime]::Now.ToString('s'); path=$mediaRoot; completed=2; items=@(@{ id='local-folder-test'; url=$url; status='completed'; path=$mediaPath; assets=@(@{ key='video'; type='video'; status='completed'; path=$mediaPath }) },@{ id='local-folder-test-2'; url=$url; status='completed'; path=$secondMediaPath; assets=@(@{ key='video'; type='video'; status='completed'; path=$secondMediaPath }) }) }
$config = @{ id=$id; urls=@($url); path=$mediaRoot; parts=@{video=$true;audio=$false;subtitles=$false}; quality='best';container='mp4';subtitleFormat='srt' }
[void](Write-LingoJson (Join-Path $dataRoot "jobs\$id.status.json") $job)
[void](Write-LingoJson (Join-Path $dataRoot "jobs\$id.config.json") $config)
$oldData = $env:LINGOSAVE_DATA_DIR
$service = $null
$shell = New-Object -ComObject Shell.Application
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
public static class LingoFolderTestWindows {
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    private static Form fixture;
    private static Thread fixtureThread;
    public static IntPtr FixtureHandle { get; private set; }
    public static void StartFixture(string title) {
        var ready = new ManualResetEventSlim(false);
        fixtureThread = new Thread(delegate() {
            fixture = new Form();
            fixture.Text = title;
            fixture.StartPosition = FormStartPosition.Manual;
            fixture.Location = new Point(80, 80);
            fixture.Size = new Size(360, 180);
            fixture.Controls.Add(new Label { Text = "LingoSave foreground acceptance fixture", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter });
            fixture.Shown += delegate { FixtureHandle = fixture.Handle; ready.Set(); };
            Application.Run(fixture);
            fixture.Dispose();
        });
        fixtureThread.IsBackground = true;
        fixtureThread.SetApartmentState(ApartmentState.STA);
        fixtureThread.Start();
        if (!ready.Wait(5000)) throw new Exception("The isolated foreground fixture did not open.");
        ready.Dispose();
    }
    public static void ForegroundFixture() {
        fixture.Invoke((Action)delegate {
            uint process;
            uint current = GetCurrentThreadId();
            uint foreground = GetWindowThreadProcessId(GetForegroundWindow(), out process);
            bool attached = foreground != 0 && foreground != current && AttachThreadInput(current, foreground, true);
            try { fixture.Activate(); SetForegroundWindow(fixture.Handle); }
            finally { if (attached) AttachThreadInput(current, foreground, false); }
        });
    }
    public static void CloseFixture() {
        if (fixture != null && !fixture.IsDisposed) fixture.Invoke((Action)delegate { fixture.Close(); });
        if (fixtureThread != null) fixtureThread.Join(3000);
    }
}
'@
$existingExplorerRoots=@{}
foreach($window in @($shell.Windows())){
    try{
        $handle=[IntPtr][long]$window.HWND
        $windowRoot=[LingoFolderTestWindows]::GetAncestor($handle,2)
        if($windowRoot -eq [IntPtr]::Zero){$windowRoot=$handle}
        $existingExplorerRoots[[string]$windowRoot]=$true
    }catch{}
}

function Invoke-FolderApi {
    param([string]$Method, [string]$Route, $Body)
    $request = [Net.HttpWebRequest][Net.WebRequest]::Create("http://127.0.0.1:$port$Route")
    $request.Method=$Method; $request.Timeout=6000; $request.Proxy=$null
    if ($Method -eq 'POST') {
        $request.ContentType='application/json'
        $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $Body -Compress))
        $request.ContentLength=$bytes.Length
        $stream=$request.GetRequestStream(); try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    }
    try { $response=$request.GetResponse() } catch [Net.WebException] { if(-not $_.Exception.Response){throw};$response=$_.Exception.Response }
    $reader=[IO.StreamReader]::new($response.GetResponseStream(),[Text.Encoding]::UTF8)
    try { return @{code=[int]$response.StatusCode;data=($reader.ReadToEnd() | ConvertFrom-Json)} } finally { $reader.Dispose();$response.Dispose() }
}

function Find-TestFolderWindow {
    foreach ($window in @($shell.Windows())) {
        try { if ([string]$window.Document.Folder.Self.Path -ieq $mediaRoot -and [LingoFolderTestWindows]::IsWindowVisible([IntPtr][long]$window.HWND)) { return $window } } catch { }
    }
    return $null
}

function Assert-SingleTestFolderWindow {
    # Shell navigation is asynchronous; count again after it has settled.
    Start-Sleep -Milliseconds 400
    $matching=@($shell.Windows() | Where-Object {
        try { [string]$_.Document.Folder.Self.Path -ieq $mediaRoot } catch { $false }
    })
    if($matching.Count -ne 1){throw "Expected one Explorer folder view, found $($matching.Count)."}
}

function Wait-TestFolderWindow {
    param([string]$SelectedPath)
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    $diagnostic='The requested Explorer folder did not become visible.'
    do {
        $window=Find-TestFolderWindow
        if($window){
            $handle=[IntPtr][long]$window.HWND
            $windowRoot=[LingoFolderTestWindows]::GetAncestor($handle,2)
            if($windowRoot -eq [IntPtr]::Zero){$windowRoot=$handle}
            $foreground=[LingoFolderTestWindows]::GetForegroundWindow()
            $selected=@($window.Document.SelectedItems() | ForEach-Object {$_.Path})
            $selectionMatches=(-not $SelectedPath) -or ($selected.Count -eq 1 -and $selected[0] -ceq $SelectedPath)
            $diagnostic="Explorer HWND=$handle, root=$windowRoot, foreground=$foreground, minimized=$([LingoFolderTestWindows]::IsIconic($windowRoot)), selected=[$($selected -join ', ')]"
            if($foreground -eq $windowRoot -and -not [LingoFolderTestWindows]::IsIconic($windowRoot) -and $selectionMatches){return $window}
        }
        Start-Sleep -Milliseconds 150
    } while([DateTime]::UtcNow -lt $deadline)
    throw "Explorer was not foreground with the expected file selection. $diagnostic"
}

function Set-FixtureForeground {
    if($NoForegroundFixture){return}
    [LingoFolderTestWindows]::ForegroundFixture()
    $deadline=[DateTime]::UtcNow.AddSeconds(3)
    do {
        if([LingoFolderTestWindows]::GetForegroundWindow() -eq [LingoFolderTestWindows]::FixtureHandle){return}
        Start-Sleep -Milliseconds 50
    } while([DateTime]::UtcNow -lt $deadline)
    throw "Foreground fixture could not activate: expected=$([LingoFolderTestWindows]::FixtureHandle), actual=$([LingoFolderTestWindows]::GetForegroundWindow())"
}

try {
    $reserve=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$reserve.Start();$port=([Net.IPEndPoint]$reserve.LocalEndpoint).Port;$reserve.Stop()
    $env:LINGOSAVE_DATA_DIR=$dataRoot
    $service=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-NonInteractive','-Sta','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $root 'server.ps1')+'"'),'-Port',"$port") -WindowStyle Hidden -PassThru
    $ready=$false
    for($attempt=0;$attempt -lt 40;$attempt++){try{$health=Invoke-FolderApi 'GET' '/api/health';if($health.code -eq 200){$ready=$true;break}}catch{};Start-Sleep -Milliseconds 150}
    if(-not $ready){throw 'Isolated file-location API did not start.'}
    if(-not $NoForegroundFixture){[LingoFolderTestWindows]::StartFixture('LingoSave foreground test ' + $id)}
    Set-FixtureForeground
    $result=Invoke-FolderApi 'POST' '/api/reveal-file' @{jobId=$id;path=$mediaPath}
    if($result.code -ne 200 -or -not $result.data.opened){throw "File reveal failed: $($result.data.error)"}
    $window=Wait-TestFolderWindow -SelectedPath $mediaPath
    Assert-SingleTestFolderWindow
    $initialRoot=[LingoFolderTestWindows]::GetAncestor([IntPtr][long]$window.HWND,2)
    if($initialRoot -eq [IntPtr]::Zero){$initialRoot=[IntPtr][long]$window.HWND}
    Write-Host 'PASS: real API opens exactly one foreground Explorer folder view and selects the exact Unicode/comma/space filename.'

    Set-FixtureForeground
    $result=Invoke-FolderApi 'POST' '/api/reveal-file' @{jobId=$id;path=$secondMediaPath}
    if($result.code -ne 200 -or -not $result.data.opened){throw "Repeat file reveal failed: $($result.data.error)"}
    $window=Wait-TestFolderWindow -SelectedPath $secondMediaPath
    Assert-SingleTestFolderWindow
    $reusedRoot=[LingoFolderTestWindows]::GetAncestor([IntPtr][long]$window.HWND,2)
    if($reusedRoot -eq [IntPtr]::Zero){$reusedRoot=[IntPtr][long]$window.HWND}
    if($reusedRoot -ne $initialRoot){throw 'The existing folder window was replaced instead of reused.'}
    Write-Host 'PASS: reopening an existing folder brings it to the foreground and changes selection to only the requested file.'

    foreach($repeat in 1..3){
        $result=Invoke-FolderApi 'POST' '/api/reveal-file' @{jobId=$id;path=$secondMediaPath}
        if($result.code -ne 200 -or -not $result.data.opened){throw 'Repeated file reveal failed.'}
    }
    $window=Wait-TestFolderWindow -SelectedPath $secondMediaPath
    Assert-SingleTestFolderWindow
    Write-Host 'PASS: repeated requests keep exactly one folder view with the requested file selected.'

    $windowRoot=[LingoFolderTestWindows]::GetAncestor([IntPtr][long]$window.HWND,2)
    [void][LingoFolderTestWindows]::ShowWindowAsync($windowRoot,6)
    $deadline=[DateTime]::UtcNow.AddSeconds(3)
    while(-not [LingoFolderTestWindows]::IsIconic($windowRoot) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
    if(-not [LingoFolderTestWindows]::IsIconic($windowRoot)){throw 'The isolated Explorer window did not minimize for the restore test.'}
    Set-FixtureForeground
    $result=Invoke-FolderApi 'POST' '/api/reveal-file' @{jobId=$id;path=$mediaPath}
    if($result.code -ne 200 -or -not $result.data.opened){throw "Minimized file reveal failed: $($result.data.error)"}
    $window=Wait-TestFolderWindow -SelectedPath $mediaPath
    Assert-SingleTestFolderWindow
    Write-Host 'PASS: a minimized folder is restored to the foreground with the requested file selected.'

    Remove-Item -LiteralPath $mediaPath
    Set-FixtureForeground
    $result=Invoke-FolderApi 'POST' '/api/reveal-file' @{jobId=$id;path=$mediaPath}
    if($result.code -ne 200 -or -not $result.data.missing){throw 'Missing-file fallback did not report the missing file.'}
    $window=Wait-TestFolderWindow
    Assert-SingleTestFolderWindow
    Write-Host 'PASS: moved or deleted file brings its original folder to the foreground and reports the fallback.'
    Set-FixtureForeground
    $foregroundBeforeReject=[LingoFolderTestWindows]::GetForegroundWindow()
    $wrong=Invoke-FolderApi 'POST' '/api/reveal-file' @{jobId=$id;path=(Join-Path $root 'server.ps1')}
    if($wrong.code -ne 400){throw 'A file outside the completed task was accepted.'}
    if([LingoFolderTestWindows]::GetForegroundWindow() -ne $foregroundBeforeReject){throw 'Rejecting an unrelated file changed the foreground window.'}
    Write-Host 'PASS: unrelated file paths are rejected without changing the foreground window.'
} finally {
    [LingoFolderTestWindows]::CloseFixture()
    foreach($window in @($shell.Windows())){
        try{
            if([string]$window.Document.Folder.Self.Path -ieq $mediaRoot){
                $handle=[IntPtr][long]$window.HWND
                $windowRoot=[LingoFolderTestWindows]::GetAncestor($handle,2)
                if($windowRoot -eq [IntPtr]::Zero){$windowRoot=$handle}
                # Windows 11 may reuse an existing tabbed Explorer window; do not close that user's window.
                if(-not $existingExplorerRoots.ContainsKey([string]$windowRoot)){$window.Quit()}
            }
        }catch{}
    }
    if($service){if(-not $service.HasExited){[IO.File]::WriteAllText((Join-Path $dataRoot 'shutdown.request'),'');if(-not $service.WaitForExit(10000)){$service.Kill()}};$service.Dispose()}
    $env:LINGOSAVE_DATA_DIR=$oldData
    if($KeepArtifacts){Write-Host "Artifacts: $testRoot"}else{$resolved=[IO.Path]::GetFullPath($testRoot);$allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\';if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Test directory escaped TEMP.'};Remove-Item -LiteralPath $resolved -Recurse -Force}
}

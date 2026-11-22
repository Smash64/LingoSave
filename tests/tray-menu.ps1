$ErrorActionPreference = 'Stop'
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'desktop\TrayTasks.cs')
$script:trayAssertions=0
function Assert-Tray { param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message};$script:trayAssertions++;Write-Host "PASS: $Message" }
$jobs=@(
    @{status='running';currentTitle='课程 & 会话';progress=0.466},
    @{status='queued';title='排队任务';progress=$null},
    @{status='paused';title='暂停任务';progress=0.253},
    @{status='waiting_network';title='网络任务';progress=$null},
    @{status='completed';title='完成的旧任务';progress=1}
)
$snapshot=[LingoSaveDesktop.TrayTaskSnapshot]::FromJson((@{jobs=$jobs} | ConvertTo-Json -Depth 5 -Compress))
Assert-Tray ($snapshot.Jobs.Count -eq 4) 'current task menu includes running/queued/paused/network jobs and excludes completed records'
$menu=New-Object System.Windows.Forms.ContextMenuStrip
$script:openRequests=0;$script:exitRequests=0
$openAction=[Action]{$script:openRequests++};$exitAction=[Action]{$script:exitRequests++}
try{
    [LingoSaveDesktop.TrayTaskMenu]::Populate($menu,$snapshot,$openAction,$exitAction)
    Assert-Tray ($menu.Items[1].Text -eq '下载中 46.6% · 课程 && 会话') 'native menu displays fractional progress and a literal ampersand in the title'
    $menu.Items[1].PerformClick()
    Assert-Tray ($script:openRequests -eq 1) 'clicking a current task opens the application'
    Assert-Tray ($menu.Items[$menu.Items.Count-1].Text -eq '退出') 'exit is directly available in the tray context menu'
    $menu.Items[$menu.Items.Count-1].PerformClick()
    Assert-Tray ($script:exitRequests -eq 1) 'the exit menu calls the existing application exit handler'
    1..8 | ForEach-Object {$snapshot.Jobs.Add([LingoSaveDesktop.TrayTaskInfo]@{Title=('更多任务 '+$_);Status='queued'})}
    [LingoSaveDesktop.TrayTaskMenu]::Populate($menu,$snapshot,$openAction,$exitAction)
    Assert-Tray ($menu.Items.Count -eq 11 -and $menu.Items[7].Text -eq '还有 6 项，打开应用查看') 'a long task list stays bounded and provides an entry to the remaining tasks'
    $empty=[LingoSaveDesktop.TrayTaskSnapshot]::FromJson('{"jobs":[]}')
    [LingoSaveDesktop.TrayTaskMenu]::Populate($menu,$empty,$openAction,$exitAction)
    Assert-Tray ($menu.Items.Count -eq 5 -and $menu.Items[1].Text -eq '暂无进行中的任务') 'refresh removes stale task rows when the queue becomes empty'
    $invalid=$false;try{[void][LingoSaveDesktop.TrayTaskSnapshot]::FromJson('{"jobs":"wrong"}')}catch{$invalid=$true}
    Assert-Tray $invalid 'an invalid service response is rejected instead of displaying false task status'
    $inactive=[LingoSaveDesktop.TrayTaskSnapshot]::FromJson('{"jobs":[{"status":"cancelled","items":[{"status":"queued"}]},{"status":"completed","items":[{"status":"running"}]},{"status":"paused"}]}')
    Assert-Tray (-not $inactive.HasActiveJobs) 'cancelled/completed child records and manually paused jobs do not create a false active-download exit prompt'
    $waiting=[LingoSaveDesktop.TrayTaskSnapshot]::FromJson('{"jobs":[{"status":"waiting_network"}]}')
    Assert-Tray ($snapshot.HasActiveJobs -and $waiting.HasActiveJobs) 'real running, queued and reconnecting jobs still require confirmation before exiting'
    Write-Host "Tray menu acceptance passed: $script:trayAssertions assertions."
}finally{$menu.Dispose()}

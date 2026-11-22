param(
    [string]$BaseUrl = 'http://127.0.0.1:8765'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$root = Split-Path -Parent $PSScriptRoot
$base = $null
if (-not [Uri]::TryCreate($BaseUrl.TrimEnd('/'), [UriKind]::Absolute, [ref]$base) -or
    $base.Scheme -ne 'http' -or
    $base.Host -notin @('127.0.0.1', 'localhost') -or
    $base.AbsolutePath -ne '/' -or
    $base.UserInfo) {
    throw 'BaseUrl 必须是本机服务地址，例如 http://127.0.0.1:8765。'
}

function Assert-Smoke {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "冒烟测试失败：$Message" }
    Write-Host "通过：$Message"
}

function Invoke-SmokeRequest {
    param([string]$Method, [string]$Path, [string]$Body, [string]$Origin)
    $uri = "$($base.GetLeftPart([UriPartial]::Authority))$Path"
    $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($uri)
    $request.Method = $Method
    $request.Timeout = 10000
    $request.ReadWriteTimeout = 10000
    $request.Proxy = $null
    if ($Origin) { $request.Headers['Origin'] = $Origin }
    if ($Method -eq 'POST') {
        $request.ContentType = 'application/json; charset=utf-8'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
    } catch [System.Net.WebException] {
        if (-not $_.Exception.Response) {
            throw "无法连接 $uri。请先启动 LingoSave.exe 或 run.ps1；原始错误：$($_.Exception.Message)"
        }
        $response = [System.Net.HttpWebResponse]$_.Exception.Response
    }
    try {
        $reader = [System.IO.StreamReader]::new($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return [pscustomobject]@{
            Status = [int]$response.StatusCode
            ContentType = [string]$response.ContentType
            Content = $content
            Json = $(if ($response.ContentType -like 'application/json*' -and $content) { ConvertFrom-Json -InputObject $content } else { $null })
        }
    } finally {
        $response.Dispose()
    }
}

$scriptFiles = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File) + @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)
foreach ($file in $scriptFiles) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "PowerShell 语法错误：$($file.FullName)：$($errors[0].Message)"
    }
}
Assert-Smoke ($scriptFiles.Count -ge 4) "PowerShell 脚本语法（$($scriptFiles.Count) 个文件）"

$page = Invoke-SmokeRequest -Method 'GET' -Path '/'
Assert-Smoke ($page.Status -eq 200 -and $page.ContentType -like 'text/html*' -and $page.Content -match 'LingoSave') '主页可访问'

$health = Invoke-SmokeRequest -Method 'GET' -Path '/api/health'
Assert-Smoke ($health.Status -eq 200 -and $null -ne $health.Json -and $null -ne $health.Json.PSObject.Properties['ready']) '健康接口返回依赖状态'
if (-not $health.Json.ready) {
    Write-Warning "下载依赖未就绪：$($health.Json.error)"
} else {
    Assert-Smoke ((Test-Path -LiteralPath ([string]$health.Json.ytDlpPath)) -and
        (Test-Path -LiteralPath ([string]$health.Json.ffmpegPath)) -and
        (Test-Path -LiteralPath ([string]$health.Json.ffprobePath))) '下载依赖路径存在'
}

$jobs = Invoke-SmokeRequest -Method 'GET' -Path '/api/jobs'
Assert-Smoke ($jobs.Status -eq 200 -and $null -ne $jobs.Json.PSObject.Properties['jobs']) '任务列表接口可访问'

$cookies = Invoke-SmokeRequest -Method 'GET' -Path '/api/cookies'
$missingSites = @(@('youtube', 'bilibili', 'arte') | Where-Object { $null -eq $cookies.Json.sites.PSObject.Properties[$_] })
Assert-Smoke ($cookies.Status -eq 200 -and $null -ne $cookies.Json.sites -and
    $missingSites.Count -eq 0) '网站 Cookie 元数据接口可访问'

$blockedImport = Invoke-SmokeRequest -Method 'POST' -Path '/api/cookies/youtube/import' -Body '{}' -Origin 'https://example.invalid'
Assert-Smoke ($blockedImport.Status -eq 403 -and $blockedImport.Json.error) '跨来源 Cookie 导入被拒绝，未打开文件选择窗口'

$settings = Invoke-SmokeRequest -Method 'GET' -Path '/api/settings'
Assert-Smoke ($settings.Status -eq 200 -and $settings.Json.defaultDownloadPath -match '^[A-Za-z]:[\\/]') '默认目录设置可读取'

$badSettings = Invoke-SmokeRequest -Method 'POST' -Path '/api/settings' -Body '{}'
Assert-Smoke ($badSettings.Status -eq 400 -and $badSettings.Json.error) '无效设置请求被拒绝，未修改默认目录'

$settingsAfter = Invoke-SmokeRequest -Method 'GET' -Path '/api/settings'
Assert-Smoke ($settingsAfter.Json.defaultDownloadPath -eq $settings.Json.defaultDownloadPath) '无效请求后默认目录保持不变'

$badInspection = Invoke-SmokeRequest -Method 'POST' -Path '/api/inspect' -Body '{}'
Assert-Smoke ($badInspection.Status -eq 400 -and $badInspection.Json.error) '无效资源检查请求被拒绝，未连接视频站点'

$badPreview = Invoke-SmokeRequest -Method 'POST' -Path '/api/preview' -Body '{"urls":[]}'
Assert-Smoke ($badPreview.Status -eq 400 -and $badPreview.Json.error) '空链接被拒绝，未发起解析'

$badJob = Invoke-SmokeRequest -Method 'POST' -Path '/api/jobs' -Body '{"urls":[]}'
Assert-Smoke ($badJob.Status -eq 400 -and $badJob.Json.error) '空链接被拒绝，未创建下载任务'

$badFolder = Invoke-SmokeRequest -Method 'POST' -Path '/api/select-folder' -Body '{}'
Assert-Smoke ($badFolder.Status -eq 400 -and $badFolder.Json.error) '无效选择目录请求被拒绝，未打开选择窗口'

$missingId = [guid]::NewGuid().ToString('N')
$badCancel = Invoke-SmokeRequest -Method 'POST' -Path "/api/jobs/$missingId/cancel" -Body '{}'
$badRetry = Invoke-SmokeRequest -Method 'POST' -Path "/api/jobs/$missingId/retry" -Body '{}'
Assert-Smoke ($badCancel.Status -eq 404 -and $badRetry.Status -eq 404) '不存在的任务不能取消或重试'

Write-Host '冒烟测试完成：未连接视频站点、未创建或修改任务、未打开目录选择窗口。'

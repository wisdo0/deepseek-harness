<#
    dsh-gpu.ps1 — 在低配 / 老显卡机器上以 GPU 加速方式启动 DeepSeek Harness 的 Web UI

    背景：GT218 世代显卡（GeForce 310M 等）在 Chromium 驱动黑名单里，默认走 CPU
        软件光栅化。实测同一页面 12.6fps -> 40.2fps（p95 300ms -> 34.3ms），
        唯一变量就是下面的启动标志。

    用法：
        dsh-gpu                  启动（必要时拉起后端，然后打开加速窗口）
        dsh-gpu -Stop            停止后端
        dsh-gpu -Port 3081       指定端口
        dsh-gpu -Browser chrome  强制用 Chrome
        dsh-gpu -NoApp           普通标签页而非 --app 窗口
#>
[CmdletBinding()]
param(
    [int]$Port = 3080,
    [ValidateSet('auto', 'edge', 'chrome')]
    [string]$Browser = 'auto',
    [switch]$Stop,
    [switch]$NoApp,
    [string]$ProfileDir = "$env:LOCALAPPDATA\dsh-gpu-profile"
)

$ErrorActionPreference = 'Stop'
$nodeExe = 'C:\Users\wisdo\bin\node-v24.22.3-win-x64\node.exe'
$dshDir  = 'C:\Users\wisdo\dsh'
$dshBin  = Join-Path $dshDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
$logFile = Join-Path $dshDir 'server.log'
$pidFile = Join-Path $dshDir 'server.pid'

function Stop-Server {
    if (Test-Path $pidFile) {
        $old = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($old) {
            if (Get-Process -Id $old -ErrorAction SilentlyContinue) {
                Stop-Process -Id $old -Force
                Write-Host "[dsh] 已停止后端 pid=$old"
            }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'deepseek-ai[\\/]dsh' } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host "[dsh] 清理残留 pid=$($_.ProcessId)"
        }
}

if ($Stop) { Stop-Server; return }

# 从后端日志里取带 token 的真实入口；裸地址会返回 401
function Get-AppUrl {
    if (Test-Path $logFile) {
        $m = Select-String -Path $logFile -Pattern 'http://127\.0\.0\.1:\d+/\?token=[A-Za-z0-9_\-]+' -AllMatches |
             Select-Object -Last 1
        if ($m) { return $m.Matches[0].Value }
    }
    return $null
}

function Test-Up {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        return $true
    } catch {
        if ($_.Exception.Response) { return $true }   # 401 也算活着
        return $false
    }
}

# 复用前先确认这个端口上跑的是我们这次的目标，且日志里有 token
$needStart = -not (Test-Up)
if (-not $needStart -and -not (Get-AppUrl)) {
    Write-Host "[dsh] 端口 $Port 已有服务但没有可用 token，重启后端"
    Stop-Server
    Start-Sleep -Seconds 1
    $needStart = $true
}

if ($needStart) {
    if (-not (Test-Path $nodeExe)) { throw "找不到 Node 24：$nodeExe" }
    if (-not (Test-Path $dshBin))  { throw "找不到 dsh：$dshBin（先在 $dshDir 执行 npm install @deepseek-ai/dsh）" }

    Write-Host "[dsh] 启动后端 → 端口 $Port"
    Remove-Item $logFile -Force -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $nodeExe `
        -ArgumentList @($dshBin, 'web', '--no-open', '--port', "$Port") `
        -WorkingDirectory $dshDir -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err" `
        -PassThru -WindowStyle Hidden
    Set-Content -Path $pidFile -Value $proc.Id
    Write-Host "[dsh] pid=$($proc.Id)  日志：$logFile"

    $up = $false
    for ($i = 0; $i -lt 120; $i++) {
        if (Test-Up) { $up = $true; break }
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $up) {
        Write-Host "[dsh] 后端没起来，日志尾部：" -ForegroundColor Red
        if (Test-Path $logFile)     { Get-Content $logFile -Tail 30 }
        if (Test-Path "$logFile.err") { Get-Content "$logFile.err" -Tail 30 }
        throw "启动失败"
    }
    Write-Host "[dsh] 后端就绪"
} else {
    Write-Host "[dsh] 复用已在运行的后端"
}

$appUrl = Get-AppUrl
if (-not $appUrl) { throw "没从 $logFile 解析到 token 入口，检查后端日志" }
Write-Host "[dsh] 入口 $appUrl"

# ---- 选择浏览器 ----
$candidates = [ordered]@{
    edge   = @("C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe", "C:\Program Files\Microsoft\Edge\Application\msedge.exe")
    chrome = @("C:\Program Files\Google\Chrome\Application\chrome.exe", "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe")
}
$chooser = if ($Browser -eq 'auto') { @('edge', 'chrome') } else { @($Browser) }
$exe = $null; $browserName = $null
foreach ($name in $chooser) {
    foreach ($c in $candidates[$name]) { if (Test-Path $c) { $exe = $c; $browserName = $name; break } }
    if ($exe) { break }
}
if (-not $exe) { throw "没找到 Edge 或 Chrome" }

# ---- GPU 标志（实测有效，勿随意删减）----
$flags = @(
    "--user-data-dir=$ProfileDir",
    "--ignore-gpu-blocklist",                    # 关键：绕过 2015 年停更驱动的黑名单
    "--enable-gpu-rasterization",                # 光栅化交给 GPU
    "--enable-zero-copy",                        # 少一次显存拷贝
    "--disable-gpu-driver-bug-workarounds",      # 老驱动上的规避逻辑本身会拖慢
    "--use-angle=d3d11",
    "--enable-features=CanvasOopRasterization",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-backgrounding-occluded-windows"
)

if ($NoApp) { $flags += "--new-window"; $flags += $appUrl }
else {
    $flags += "--app=$appUrl"
    $flags += "--window-size=1280,760"
}

Write-Host "[dsh] 以 $browserName 打开（GPU 加速）"
Start-Process -FilePath $exe -ArgumentList $flags | Out-Null
Write-Host "[dsh] 完成。停止后端：dsh-gpu -Stop"

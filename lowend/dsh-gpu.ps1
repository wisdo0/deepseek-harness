<#
    dsh-gpu.ps1 — 在低配 / 老显卡机器上以 GPU 加速方式启动 DeepSeek Harness 的 Web UI

    背景：GT218 世代显卡（GeForce 310M 等）在 Chromium 驱动黑名单里，默认走 CPU
        软件光栅化。实测同一页面 12.6fps -> 40.2fps（p95 300ms -> 34.3ms），
        唯一变量就是下面的启动标志。

    用法：
        dsh-gpu                  启动（必要时拉起后端，然后打开加速窗口）
        dsh-gpu -Check           只打印探测到的环境，不做任何启动
        dsh-gpu -Stop            停止后端
        dsh-gpu -Port 3081       指定端口
        dsh-gpu -Browser chrome  强制用 Chrome
        dsh-gpu -NoApp           普通标签页而非 --app 窗口
        dsh-gpu -Lite            额外关掉平滑滚动与过渡动画（更省，观感略生硬）
        dsh-gpu -DshDir D:\dsh   指定 dsh 安装目录

    环境变量覆盖：DSH_NODE、DSH_BIN、DSH_DIR
#>
[CmdletBinding()]
param(
    [int]$Port = 3080,
    [ValidateSet('auto', 'edge', 'chrome')]
    [string]$Browser = 'auto',
    [switch]$Stop,
    [switch]$NoApp,
    [switch]$Check,
    [switch]$Lite,
    [string]$DshDir,
    [string]$ProfileDir = "$env:LOCALAPPDATA\dsh-gpu-profile"
)

$ErrorActionPreference = 'Stop'
$MinNodeMajor = 24
$MinNodeMinor = 9

# ---------- 环境探测 ----------
function Get-NodeVersion([string]$exe) {
    try {
        $v = & $exe --version 2>$null
        if ($v -match '^v(\d+)\.(\d+)\.(\d+)') {
            return [pscustomobject]@{ Major = [int]$Matches[1]; Minor = [int]$Matches[2]; Patch = [int]$Matches[3]; Raw = $v.Trim() }
        }
    } catch {}
    return $null
}

function Resolve-NodeExe {
    if ($env:DSH_NODE -and (Test-Path $env:DSH_NODE)) { return (Resolve-Path $env:DSH_NODE).Path }

    $cands = New-Object System.Collections.Generic.List[string]
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $cands.Add($cmd.Source) }
    foreach ($p in @(
        "$env:ProgramFiles\nodejs\node.exe",
        "${env:ProgramFiles(x86)}\nodejs\node.exe",
        "$env:LOCALAPPDATA\Programs\nodejs\node.exe"
    )) { if ($p -and (Test-Path $p)) { $cands.Add($p) } }

    # 便携安装常见位置
    foreach ($root in @("$env:USERPROFILE\bin", "$env:USERPROFILE\scoop\apps\nodejs\current", "$env:LOCALAPPDATA\nvs")) {
        if (Test-Path $root) {
            Get-ChildItem -Path $root -Filter node.exe -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                Select-Object -First 8 | ForEach-Object { $cands.Add($_.FullName) }
        }
    }

    $seen = @{}
    foreach ($c in $cands) {
        if (-not $c) { continue }
        $full = try { (Resolve-Path $c).Path } catch { $c }
        if ($seen[$full]) { continue }
        $seen[$full] = $true
        $v = Get-NodeVersion $full
        if ($v -and ($v.Major -gt $MinNodeMajor -or ($v.Major -eq $MinNodeMajor -and $v.Minor -ge $MinNodeMinor))) { return $full }
    }
    return $null
}

function Resolve-DshBin([string]$nodeExe) {
    if ($env:DSH_BIN -and (Test-Path $env:DSH_BIN)) { return (Resolve-Path $env:DSH_BIN).Path }

    $roots = New-Object System.Collections.Generic.List[string]
    if ($DshDir) { $roots.Add($DshDir) }
    if ($env:DSH_DIR) { $roots.Add($env:DSH_DIR) }
    $roots.Add($PSScriptRoot)
    $roots.Add("$env:USERPROFILE\dsh")
    $roots.Add("$env:USERPROFILE\.dsh")

    if ($nodeExe) {
        $npmCli = Join-Path (Split-Path $nodeExe -Parent) 'node_modules\npm\bin\npm-cli.js'
        if (Test-Path $npmCli) {
            try {
                $npmRoot = & $nodeExe $npmCli root -g 2>$null
                if ($LASTEXITCODE -eq 0 -and $npmRoot) { $roots.Add($npmRoot.Trim()) }
            } catch {}
        }
    }

    foreach ($r in $roots) {
        $bin = Join-Path $r 'node_modules\@deepseek-ai\dsh\lib\bin.js'
        if (Test-Path $bin) { return (Resolve-Path $bin).Path }
        $binAlt = Join-Path $r '@deepseek-ai\dsh\lib\bin.js'
        if (Test-Path $binAlt) { return (Resolve-Path $binAlt).Path }
    }
    return $null
}

function Find-Browser([string]$Name) {
    $paths = if ($Name -eq 'edge') {
        @("$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe", "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe")
    } else {
        @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")
    }
    foreach ($p in $paths) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

$nodeExe = Resolve-NodeExe
$dshBin  = Resolve-DshBin $nodeExe
$logDir  = $null
if ($DshDir)   { $logDir = $DshDir }
elseif ($dshBin -match '^(.*?)[\\/]node_modules[\\/]') {
    # <root>\node_modules\@deepseek-ai\dsh\lib\bin.js -> <root>（按锚点截断，别数层级）
    $logDir = $Matches[1]
}
if (-not $logDir) { $logDir = $PSScriptRoot }
$logFile = Join-Path $logDir 'server.log'
$pidFile = Join-Path $logDir 'server.pid'

if ($Check) {
    Write-Host "node    : $(if($nodeExe){$nodeExe}else{'未找到 (需 >= 24.9)'})"
    if ($nodeExe) { Write-Host "          版本 $((Get-NodeVersion $nodeExe).Raw)" }
    Write-Host "dsh bin : $(if($dshBin){$dshBin}else{'未找到'})"
    Write-Host "日志    : $logFile"
    $b = Find-Browser 'edge'; if (-not $b) { $b = Find-Browser 'chrome' }
    Write-Host "浏览器  : $(if($b){$b}else{'未找到'})"
    # 自检失败要有非零退出码，否则 CI 里等于没测
    if (-not $nodeExe -or -not $dshBin) { exit 1 }
    return
}

function Stop-Server {
    if (Test-Path $pidFile) {
        $old = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($old -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $old -Force
            Write-Host "[dsh] 已停止后端 pid=$old"
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'deepseek-ai[\\/]dsh' } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host "[dsh] 清理残留 pid=$($_.ProcessId)"
        }
    # lite 反代也要一起收掉
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'lite-proxy\.mjs' } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host "[dsh] 已停止 lite 反代 pid=$($_.ProcessId)"
        }
}

if ($Stop) { Stop-Server; return }

function Get-AppUrl([int]$p) {
    if (Test-Path $logFile) {
        $pat = "http://127\.0\.0\.1:$p/\?token=[A-Za-z0-9_\-]+"
        $m = Select-String -Path $logFile -Pattern $pat -AllMatches | Select-Object -Last 1
        if ($m) { return $m.Matches[0].Value }
    }
    return $null
}

function Test-Port([int]$p) {
    try {
        Invoke-WebRequest -Uri "http://127.0.0.1:$p/" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop | Out-Null
        return $true
    } catch {
        if ($_.Exception.Response) { return $true }
        return $false
    }
}

if (-not $nodeExe) { throw "找不到 Node >= $MinNodeMajor.$MinNodeMinor。装一个，或用 `$env:DSH_NODE 指向它。" }
if (-not $dshBin)  { throw "找不到 @deepseek-ai/dsh。先在某目录 npm install @deepseek-ai/dsh，或用 -DshDir / `$env:DSH_DIR 指定位置。" }

# 端口被非 dsh 进程占用则顺延
$chosen = $Port
for ($i = 0; $i -lt 10; $i++) {
    if (-not (Test-Port $chosen)) { break }
    if (Get-AppUrl $chosen) { break }
    $chosen++
}

if (Test-Port $chosen) {
    if (-not (Get-AppUrl $chosen)) { throw "端口 $chosen 被其它进程占用，且日志里没有可用 token" }
    Write-Host "[dsh] 复用已在运行的后端（端口 $chosen）"
} else {
    Write-Host "[dsh] 启动后端 → 端口 $chosen"
    Remove-Item $logFile -Force -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $nodeExe `
        -ArgumentList @($dshBin, 'web', '--no-open', '--port', "$chosen") `
        -WorkingDirectory $logDir -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err" `
        -PassThru -WindowStyle Hidden
    Set-Content -Path $pidFile -Value $proc.Id
    Write-Host "[dsh] pid=$($proc.Id)  日志：$logFile"

    $up = $false
    for ($i = 0; $i -lt 160; $i++) {
        if (Test-Port $chosen) { $up = $true; break }
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $up) {
        Write-Host "[dsh] 后端没起来，日志尾部：" -ForegroundColor Red
        if (Test-Path $logFile)       { Get-Content $logFile -Tail 30 }
        if (Test-Path "$logFile.err") { Get-Content "$logFile.err" -Tail 30 }
        throw "启动失败"
    }
    Write-Host "[dsh] 后端就绪"
}

$appUrl = Get-AppUrl $chosen
if (-not $appUrl) { throw "没从 $logFile 解析到 token 入口，检查后端日志" }

if ($Lite) {
    $proxyEntry = Join-Path $PSScriptRoot 'lite-proxy.mjs'
    if (-not (Test-Path $proxyEntry)) { throw "找不到 lite 反代：$proxyEntry" }

    $litePort = $chosen + 1
    if (Test-Port $litePort) {
        Write-Host "[dsh] 复用已在运行的 lite 反代（端口 $litePort）"
    } else {
        Write-Host "[dsh] 启动 lite 反代 $chosen -> $litePort"
        $env:DSH_UPSTREAM_PORT = "$chosen"
        $env:DSH_LITE_PORT     = "$litePort"
        $proxyLog = Join-Path $logDir 'lite-proxy.log'
        $pproc = Start-Process -FilePath $nodeExe -ArgumentList @($proxyEntry) `
            -WorkingDirectory $logDir -RedirectStandardOutput $proxyLog -RedirectStandardError "$proxyLog.err" `
            -PassThru -WindowStyle Hidden

        $ok = $false
        for ($i = 0; $i -lt 40; $i++) {
            if (Test-Port $litePort) { $ok = $true; break }
            if ($pproc.HasExited) { break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $ok) {
            Write-Host "[dsh] lite 反代没起来，日志：" -ForegroundColor Red
            if (Test-Path $proxyLog) { Get-Content $proxyLog -Tail 20 }
            throw "lite 反代启动失败"
        }
    }
    # 打开反代地址而不是后端地址，同源不变，token 原样带过去
    $appUrl = $appUrl -replace ":$chosen/", ":$litePort/"
    Write-Host "[dsh] 已注入 lite 样式（经反代 $litePort）"
}

Write-Host "[dsh] 入口 $appUrl"

$chooser = if ($Browser -eq 'auto') { @('edge', 'chrome') } else { @($Browser) }
$exe = $null; $browserName = $null
foreach ($name in $chooser) {
    $p = Find-Browser $name
    if ($p) { $exe = $p; $browserName = $name; break }
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

# 更激进的减负：前端若尊重 prefers-reduced-motion，可关掉大部分过渡与动画
if ($Lite) {
    $flags += "--force-prefers-reduced-motion"
    $flags += "--disable-smooth-scrolling"
}

if ($NoApp) { $flags += "--new-window"; $flags += $appUrl }
else {
    $flags += "--app=$appUrl"
    $flags += "--window-size=1280,760"
}

Write-Host "[dsh] 以 $browserName 打开（GPU 加速）"
Start-Process -FilePath $exe -ArgumentList $flags | Out-Null
Write-Host "[dsh] 完成。停止后端：dsh-gpu -Stop"

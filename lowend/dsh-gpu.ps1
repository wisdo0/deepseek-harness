<#
    dsh-gpu.ps1 — 在低配 / 老显卡机器上以 GPU 加速方式启动 DeepSeek Harness 的 Web UI

    背景：GT218 世代显卡（GeForce 310M 等）在 Chromium 驱动黑名单里，默认走 CPU
        软件光栅化。实测同一页面 12.6fps -> 40.2fps（p95 300ms -> 34.3ms），
        唯一变量就是下面的启动标志。

    用法：
        dsh-gpu                  启动（必要时拉起后端，然后打开加速窗口）
        dsh-gpu -Check           只打印探测到的环境，不做任何启动
        dsh-gpu -Stop            停止后端 + 反代 + 本工具启动的浏览器窗口
        dsh-gpu -Clean           全停后清磁盘缓存（保留登录态与历史）
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
    [switch]$Clean,
    [string]$DshDir,
    [string]$ProfileDir = "$env:LOCALAPPDATA\dsh-gpu-profile"
)

$ErrorActionPreference = 'Stop'
$MinNodeMajor = 24
$MinNodeMinor = 9

# ---------- 环境块归一化 ----------
# Windows 环境块允许 HTTP_PROXY 与 http_proxy 并存（大小写不同算不同键）。
# 开了 Clash / 企业代理的机器常见这种重复，而 PowerShell 5.1 的 env: 驱动器
# 和 Start-Process 内部都用「不区分大小写的字典 + Add」填充，碰到重复键会抛
# "已添加项"，脚本直接死在启动进程那一步。这里每个逻辑键重写一遍，去重。
function Repair-ProcessEnv {
    $vars = [System.Environment]::GetEnvironmentVariables()
    $n = 0
    foreach ($name in @($vars.Keys)) {
        if ([string]::IsNullOrEmpty($name)) { continue }
        $value = $vars[$name]
        try {
            # SetEnvironmentVariable 在 Windows 上大小写不敏感，一次调用能清掉所有变体
            [System.Environment]::SetEnvironmentVariable($name, $null, 'Process')
            if ($null -ne $value) { [System.Environment]::SetEnvironmentVariable($name, [string]$value, 'Process') }
            $n++
        } catch { }
    }
    return $n
}
Repair-ProcessEnv | Out-Null

# ---------- 便携模式 ----------
# 便携包结构：<root>\lowend\dsh-gpu.ps1 + <root>\node\node.exe + <root>\app\node_modules\...
# 命中就全部用包内相对路径，不依赖目标机器装过 Node / dsh，也不污染全局环境。
$PortableRoot = Split-Path $PSScriptRoot -Parent
$PortableNode = Join-Path $PortableRoot 'node\node.exe'
$PortableDshRoot = Join-Path $PortableRoot 'app'
$IsPortable = (Test-Path $PortableNode) -and (Test-Path (Join-Path $PortableDshRoot 'node_modules\@deepseek-ai\dsh\lib\bin.js'))
if ($IsPortable -and -not $PSBoundParameters.ContainsKey('ProfileDir')) {
    # 浏览器配置也放在包内，换机器/换目录不留下残留
    $ProfileDir = Join-Path $PortableRoot 'profile'
}

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
    if ($IsPortable) { return $PortableNode }
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
    if ($IsPortable) { $roots.Add($PortableDshRoot) }
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

function Stop-Browser {
    # 只关用我们这个 profile 起来的实例，绝不碰用户自己的浏览器。
    # Edge 可能把路径规范化成不同斜杠形式，比较前统一。
    $want = ([IO.Path]::GetFullPath($ProfileDir)).Replace('/', '\').TrimEnd('\')
    $n = 0
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.CommandLine -match '--user-data-dir=("([^"]+)"|(\S+))') {
            $raw = $Matches[2]
            if (-not $raw) { $raw = $Matches[3] }
            if ($raw) {
                $got = $raw.Replace('/', '\').TrimEnd('\')
                if ($got -ieq $want) {
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                    $n++
                }
            }
        }
    }
    if ($n -gt 0) { Write-Host "[dsh] 已关闭本工具启动的浏览器（$n 个进程）" }
}

if ($Stop) { Stop-Server; Stop-Browser; return }

if ($Clean) {
    # 只删可再生缓存，保留 Cookies / Login Data / Preferences，不丢登录态。
    # 实测这个 profile 目录能涨到 300MB，主要是磁盘缓存。
    Stop-Server
    Stop-Browser
    Start-Sleep -Milliseconds 1500
    $cacheDirs = @(
        'Cache', 'Code Cache', 'GPUCache', 'ShaderCache', 'DawnCache', 'GrShaderCache',
        'Default\Cache', 'Default\Code Cache', 'Default\GPUCache',
        'Default\Service Worker\CacheStorage'
    )
    $freed = 0
    foreach ($d in $cacheDirs) {
        $p = Join-Path $ProfileDir $d
        if (Test-Path $p) {
            $size = (Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
            $freed += $size
            Write-Host "[dsh] 清理 $d"
        }
    }
    Write-Host ("[dsh] 释放 {0:N0} MB，登录态保留" -f ($freed / 1MB))
    return
}

function Get-AppUrl([int]$p, [int]$TimeoutSec = 25) {
    # 必须轮询：TCP 端口 listen 与「日志里写出 token」不是同一时刻，
    # 端口刚起就读日志会读空。冷启动时这个窗口有几百毫秒。
    $pat = "http://127\.0\.0\.1:$p/\?token=[A-Za-z0-9_\-]+"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        if (Test-Path $logFile) {
            $m = Select-String -Path $logFile -Pattern $pat -AllMatches -ErrorAction SilentlyContinue | Select-Object -Last 1
            if ($m) { return $m.Matches[0].Value }
        }
        if ((Get-Date) -ge $deadline) { return $null }
        Start-Sleep -Milliseconds 250
    }
}

function Test-Port([int]$p) {
    # 用裸 TCP 探测而不是 Invoke-WebRequest：后者会读 HTTP_PROXY，
    # 在开了代理的机器上访问 127.0.0.1 也可能被劫持，导致误判"端口没人听"。
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $p, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(600)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

if (-not $nodeExe) { throw "找不到 Node >= $MinNodeMajor.$MinNodeMinor。装一个，或用 `$env:DSH_NODE 指向它。" }
if (-not $dshBin)  { throw "找不到 @deepseek-ai/dsh。先在某目录 npm install @deepseek-ai/dsh，或用 -DshDir / `$env:DSH_DIR 指定位置。" }

# 端口被非 dsh 进程占用则顺延
$chosen = $Port
for ($i = 0; $i -lt 10; $i++) {
    if (-not (Test-Port $chosen)) { break }
    if (Get-AppUrl $chosen 1) { break }
    $chosen++
}

if (Test-Port $chosen) {
    if (-not (Get-AppUrl $chosen 1)) { throw "端口 $chosen 被其它进程占用，且日志里没有可用 token" }
    Write-Host "[dsh] 复用已在运行的后端（端口 $chosen）"
} else {
    Write-Host "[dsh] 启动后端 → 端口 $chosen"
    Write-Host "[dsh] 首次启动较慢（这台机器约 1 分钟），请稍候，不要关闭本窗口..." -ForegroundColor Yellow
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
    Write-Host "[dsh] 后端就绪，正在打开浏览器窗口..." -ForegroundColor Green
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
    "--disable-backgrounding-occluded-windows",

    # ---- 省内存：这台机器可用内存常年 <1.5GB，比显卡更容易成为瓶颈 ----
    "--disable-component-extensions-with-background-pages",  # Edge 自带的后台扩展页白吃内存
    "--disable-background-networking",         # 关掉更新检查等后台联网
    "--disable-default-apps",
    "--disable-sync",
    "--no-pings",
    "--disk-cache-size=67108864",              # 磁盘缓存限 64MB，否则 profile 能涨到 300MB+
    "--disable-features=msEdgeSyncPromo,EdgeSyncConfirmationDialog,Translate"
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

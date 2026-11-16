# dsh-lowend — 让 DeepSeek Harness 在老旧显卡机器上跑顺

针对 **GT218 世代 NVIDIA 显卡**（GeForce 310M / 315M 等，Feature Level 10_1）的
DeepSeek Harness 前端加速补丁集。

## 问题

`dsh web` 在这类机器上极卡。原因不是显卡不行——**WebGL 后端本身就是
`ANGLE (NVIDIA GeForce 310M Direct3D11 vs_4_1)`，硬件加速是通的**。真正的原因是
Chromium 的驱动黑名单把 2015 年停更的驱动一刀切掉，导致合成与光栅化回落到 CPU。

## 实测（同一台机器，1366×768，单页 250 条消息 + 毛玻璃 + 渐变动画）

测量前先预热：等连续 10 帧稳定在 50ms 内才开始计时。不预热会把开窗瞬间的
节流帧算进去，得出几百毫秒的假数据（我第一版就掉进这个坑）。

| 配置 | 帧率 | 平均帧时间 | p95 帧时间 |
|---|---|---|---|
| 默认 | 8 秒内凑不出 10 帧连续 <50ms（未达预热门槛） | — | — |
| 强制 GPU 光栅化 | 57.3 fps | 17.4 ms | 17.9 ms |
| 强制 GPU + `lite.css` | 60.0 fps | 16.7 ms | 16.9 ms |

**默认那一栏比任何数字都说明问题**：软件光栅化下页面根本稳不住 20fps，连
"10 帧连续低于 50ms"都做不到，预热阶段直接超时。

对照组 WebGL renderer 字符串完全一致，唯一变量是启动标志。

### 关于 `lite.css` 的诚实结论

两次对照结果不一致：一次 p95 从 32.8ms 降到 17.0ms，另一次是 17.9ms 对 16.9ms。
均值差异可以忽略，**说明在 GPU 光栅化已经生效的前提下，砍毛玻璃和动画的边际收益
落在噪声范围内**。真正解决问题的是浏览器标志，不是这份样式。

它只在一种情况下有意义：显存被打满（512MB 同时开多个窗口/长会话），GPU 光栅化
退让时，关掉 `backdrop-filter` 能少掉一些帧。所以默认关闭，需要时再加 `-Lite`。

测试条件：LENOVO / Core i3 M 380 (2C4T) / 6GB RAM / GeForce 310M 512MB /
驱动 9.18.13.4174 / Microsoft Edge 157.0.4341.46。

## 用法

```powershell
# 首次：安装运行时（需要 Node >= 24.9.0）
npm install @deepseek-ai/dsh

# 先看它探测到了什么（不做任何启动）
.\lowend\dsh-gpu.cmd -Check

# 启动（会自动拉起后端，再打开加速窗口）
.\lowend\dsh-gpu.cmd

# 停止：后端 + 反代 + 本工具启动的浏览器窗口，一次全停
.\lowend\dsh-gpu.cmd -Stop

# 清理磁盘缓存（会先全停）。只删可再生缓存，保留登录态与历史
.\lowend\dsh-gpu.cmd -Clean

# 还嫌不够顺：注入 lite 样式（关掉毛玻璃、过渡动画、平滑滚动）
.\lowend\dsh-gpu.cmd -Lite
```

`-Stop` 只关**用本工具 profile 目录起来**的浏览器进程，按 `--user-data-dir`
规范化后比对，不会误伤你自己正在用的浏览器（实测：本工具 9 个进程全关，
其它 10 个 Edge 进程原样保留）。

`-Clean` 实测把 profile 从 38MB 降到 14MB，`Preferences` / `Login Data` /
`Web Data` / `History` / `Local State` 全部保留。日常不需要跑，缓存涨到几百 MB 时再用。

脚本会自动探测 Node（≥24.9）、`@deepseek-ai/dsh` 与浏览器；端口被占用时顺延。
探测结果不对时用 `-DshDir`，或环境变量 `DSH_NODE` / `DSH_BIN` / `DSH_DIR` 覆盖。

窗口以 `--app=` 模式打开，无地址栏，观感接近桌面应用。

## 内存：这台机器真正的第二个瓶颈

GPU 光栅化解决之后，可用内存往往比显卡更早见底（本机总 5.86GB，可用常年 <1.5GB）。
所以启动器默认再带一组省内存标志，实测 A/B（同一页面，只换标志）：

| 指标 | 仅 GPU 组 | + 省内存组 | 差异 |
|---|---|---|---|
| Edge 进程数 | 13 | **9** | −4 |
| 工作集内存 | 704 MB | **495 MB** | **−209 MB（−30%）** |
| 帧率 | 60 fps | 60 fps | 无变化 |
| 平均帧时间 | 16.7 ms | 16.7 ms | 无变化 |
| p95 帧时间 | 16.8 ms | 16.9 ms | 噪声内 |
| JS 堆 | 25.3 MB | 25.3 MB | 相同 |

JS 堆一致说明省掉的是**浏览器自身开销**（后台扩展页、同步服务、后台联网），
页面本身没受影响，帧率也没降。

```text
--disable-component-extensions-with-background-pages   后台扩展页白吃内存
--disable-background-networking                       关掉更新检查等后台联网
--disable-default-apps / --disable-sync / --no-pings
--disk-cache-size=67108864                            磁盘缓存限 64MB
--disable-features=msEdgeSyncPromo,EdgeSyncConfirmationDialog,Translate
```

> `--disk-cache-size` 限的是磁盘不是内存，但能避免 profile 目录涨到 300MB+。
> `--disable-features` 一个进程只认一次，别和别的 `--disable-features` 重复给。

## `-Lite` 是怎么实现的

不改上游代码，也不改前端构建产物：启动时在本地拉起一个反代
（`lite-proxy.mjs`，默认后端端口 +1），把 `lite.css` 以**同源样式表**的形式
注入 HTML 的 `</head>` 之前，然后让浏览器打开反代地址。

四点值得注意：

- **同源**：样式表从反代自身路径 `/__dsh_lite.css` 取，站点 CSP 里
  `style-src 'self'` 即可通过，不需要放宽安全策略。
- **`Origin` 必须跟着 `Host` 一起改写**：这是最容易踩的坑，见下节。
- **WebSocket 单独转发**：dsh 靠 WS 推流式回复，反代的 `upgrade` 走原始首部直通。
- **非 HTML 不碰**：流式响应原样 `pipe`，绝不缓冲。

代价是多一个本地进程（约 30MB 内存），`-Stop` 会一并收掉。

### 坑：只改 `Host` 不改 `Origin`，界面会一直「重新连接中」

第一版反代只把 `Host` 改写成上游，`Origin` 原样透传。结果：

- 页面 HTML、CSS、JS 全部正常加载，界面骨架也渲染出来了
- 但 **WebSocket 握手被上游 403**，界面卡在「重新连接中…」，所有 API 调用报
  `transport failure`

dsh 会校验 `Origin` 与自身 authority 是否一致。浏览器访问的是
`http://127.0.0.1:3081`，于是发出 `Origin: http://127.0.0.1:3081`；反代把请求转给
`127.0.0.1:3080` 时虽然改了 `Host`，但 `Origin` 还是 3081，上游一比就拒。

实测对照（同一上游，只改 Origin）：

| 请求 | 结果 |
|---|---|
| 直连 3080，`Origin: http://127.0.0.1:3080` | `101 Switching Protocols` |
| 直连 3080，`Origin: http://127.0.0.1:3081` | `403 Forbidden` |
| 经反代 3081，`Origin: http://127.0.0.1:3081` | 修复前 `403` → 修复后 `101` |

修复后浏览器实测：WS 建连 1 个、握手 101、发 6 帧 891 字节、收 6 帧 3967 字节、
零重连提示，界面正文从 78 字符（只有「重新连接中」）变为 368 字符的完整界面。

`tests/proxy.test.mjs` 里为此加了一组带**对照组**的断言：先证明 mock 上游确实会
拒绝错 Origin（否则断言等于摆设），再验证经反代能拿到 101，并断言反代送来的
`Origin` 已被改写为上游地址。把修复去掉重跑，会有 5 项断言失败。

## 生效的启动标志

```text
--ignore-gpu-blocklist                 绕过驱动黑名单（关键）
--enable-gpu-rasterization             光栅化交给 GPU
--enable-zero-copy                     减少显存拷贝
--disable-gpu-driver-bug-workarounds   老驱动上的规避逻辑本身会拖慢
--use-angle=d3d11
--enable-features=CanvasOopRasterization
--user-data-dir=<独立配置目录>          保证标志不被已有实例吞掉
```

> 切换标志组合后，务必用**独立的 `user-data-dir`** 重开，否则 Chromium 可能沿用
> 已在运行的进程而不读取新标志。

## 便携包（推荐分发方式）

`portable-build.yml` 在 `lowend/` 有改动并 push 后自动跑，**约 3 分钟**出包，
不需要本机做任何复制或压缩（本机 2 核机器上同样的活要 30 分钟）。

产物 `dsh-portable.zip`（约 234MB），解压后是一个 `dsh-portable\` 目录：

```
dsh-portable\
  DeepSeek.cmd         双击启动
  DeepSeek-Stop.cmd    双击全停
  使用说明.txt
  node\                Node 24 运行时（免安装）
  app\                 dsh 及全部依赖
  lowend\              启动器 / 反代 / 样式
  profile\             浏览器配置（首次运行生成）
```

**解压 → 双击 `DeepSeek.cmd`** 即可，目标机器不需要装 Node 或任何开发环境。
整个目录可随意移动、复制到别的电脑，路径全部相对，配置写在包内。

```bash
gh run download <run-id> -n dsh-portable     # 取某次构建的包
```

手动重建：改任意 `lowend/` 文件后 push 即触发（workflow_dispatch 只读默认分支，
而本文件在 lowend-win，所以不提供按钮式触发）。

## 桌面端（Electron）

上游有完整桌面端：`apps/desktop`（Electron 44 + electron-builder）。
`lowend/scripts/apply-desktop-flags.mjs` 在**构建时**把同一组 Chromium 标志注入
`apps/desktop/src/main.ts`，而不是直接改仓库里的上游源码——这样 lowend-win
才能一直干净地合并上游。

注入点选在 import 块之后的第一条语句，脚本会自检注入位置早于 `app.whenReady()`，
否则标志不会生效。重复执行幂等；上游若改动了锚点，脚本会**报错并拒绝继续**，
不会静默地产出一个没有补丁的包。

标志只在 Windows 生效，设 `DSH_LOWEND_GPU=0` 可整体关闭。

```bash
gh workflow run desktop-build.yml        # 手动触发构建
```

构建约 14 分钟，产物在 `apps/desktop/.desktop-build/targets/win-x64/unsigned-artifacts/`
（注意：**点开头**的隐藏目录，且相对 desktop 项目目录，不是仓库根），CI 会把
`deepseek-harness-<版本>-win-x64-unsigned.exe` 作为 artifact 上传。
上传时必须加 `include-hidden-files: true`，否则 `upload-artifact` 默认排除隐藏目录。
产物自包含 Node / pnpm / Python 运行时，目标机器不需要装开发环境。

**配置限制（重要）**：打包需要 `apps/desktop/.env.windows`，且 mandatory-update
origin 在 unsigned 构建下也必填。workflow 里现在填的是**占位值**——能过构建校验，
但包内置的更新与登录地址不是真实服务。上游的真实配置放在 GitHub Environments
（`desktop-test` / `desktop-production`）的 secrets 里，不在仓库中。

所以要出**真正可用**的安装包，需要把 workflow「生成 .env.windows」那一步里的
`DOWNLOAD_TEST_ORIGIN`、`DSH_DESKTOP_MANDATORY_UPDATE_*_ORIGIN`、
`allowedAuthOrigins` 换成你自己的服务端地址。只验证构建链路则不用改。

> 桌面端与浏览器启动器用的是**同一组标志**，性能上没有差别。
> 它的价值在于免装 Node / dsh、单 exe 分发，适合自己机器以外的场景。

## 跟随上游

`upstream-sync.yml` 每周一 09:23（北京）自动检查上游，也可手动触发。

**这个文件在 master 分支，不在 lowend-win**。原因：GitHub 的 `schedule` 与
`workflow_dispatch` **只读默认分支**上的 workflow 文件；而 `lowend-build.yml`
走 `push` 事件，读的是被推送的分支，所以它留在 lowend-win。改同步逻辑请改 master。

同步用 **merge 不用 rebase**（不改写历史，出问题好回溯）。因为 `lowend/` 是独立
目录、不碰上游代码，合并基本不会冲突；workflow 会先打印上游是否碰到了我们的文件。

流程：合并 → 校验脚本 BOM/语法 → 跑反代测试 → 推送。任何一步失败都会开一个
标题为「上游同步需要人工处理」的 issue（已有未关闭的则不重复开）。
推送后 `lowend-build` 会接着跑完整集成测试。

```bash
gh workflow run upstream-sync.yml -f dry_run=true   # 只看差距，不动分支
gh workflow run upstream-sync.yml                   # 真同步
```

已实测合并路径（构造 master 领先 lowend-win 的场景）：合并、校验、反代测试、推送
全部通过，测试分支不影响 lowend-win。上游若改动了 `.github/workflows/*`，
`GITHUB_TOKEN` 会因缺 workflows 权限推送失败，这时走 issue 人工处理。

> GitHub 会在仓库 60 天无活动后自动停用 scheduled workflow，需要到 Actions 页手动重新启用。

## 编码注意

`dsh-gpu.ps1` **必须保存为 UTF-8 with BOM**。Windows PowerShell 5.1 对无 BOM 的
UTF-8 会按 ANSI(GBK) 解析，中文字符串直接导致语法错误。改脚本后别用会去 BOM 的编辑器。

## 坑：开着代理时 PowerShell 5.1 会直接崩

Windows 环境块允许 `HTTP_PROXY` 与 `http_proxy` 并存（大小写不同算不同键）。
装了 Clash / 公司代理的机器经常两个都有，而 PowerShell 5.1 的 `env:` 驱动器和
`Start-Process` 内部都用「不区分大小写的字典 + Add」填充，碰到重复键就抛：

```
Start-Process : 已添加项。字典中的关键字:“HTTP_PROXY”所添加的关键字:“http_proxy”
```

脚本会死在拉起后端的那一刻。现在 `Repair-ProcessEnv` 在启动最前面把每个逻辑键
重写一遍（`SetEnvironmentVariable` 在 Windows 上大小写不敏感，一次调用能清掉所有
变体），每组只留一份，代理本身仍然可用。

同时端口探测从 `Invoke-WebRequest` 换成了裸 TCP：前者会读 `HTTP_PROXY`，在开了
代理的机器上访问 `127.0.0.1` 也可能被劫持，误判成「端口没人听」。

> 顺带修了一个由此暴露的时序 bug：改用 TCP 探测后，端口 listen 与「日志写出 token」
> 不是同一时刻，端口刚起就读日志会读空。`Get-AppUrl` 现在会轮询等待。


## 复现测量

```powershell
cd lowend\probe
node server.mjs          # 终端 A
# 终端 B：分别用默认 / 带标志的浏览器打开 http://127.0.0.1:8899/
```

探针会在页面内测 3 秒 rAF 帧间隔，上报 fps / 平均 / p95 与 WebGL renderer。

## 注意

- 这个补丁**不改变 DeepSeek Harness 的推理路径**。推理始终在远端 API，
  本地只负责渲染。前端加速只影响界面流畅度。
- 512MB 显存跑满屏毛玻璃仍会吃力；若仍不顺，下一步是裁剪 `backdrop-filter`
  与大面积动画（见 ROADMAP）。
- 非 GT218 机器通常不需要这些标志，Chromium 默认就会启用 GPU 光栅化。

## ROADMAP

- [x] 量化默认与强制 GPU 的差距，确认瓶颈在黑名单而非硬件
- [x] 一键启动器（后端托管 + app 模式 + 标志固化）
- [x] 为 Web 前端提供 `lite` 渲染档（反代注入 CSS，不动上游代码）
- [x] 反代行为回归测试进 CI（含 Origin 改写对照组）
- [x] 省内存标志 A/B 实测（−30% 工作集，帧率不变）
- [x] `-Stop` 全停（含浏览器，按 profile 精确匹配不误伤）与 `-Clean` 缓存清理
- [x] 上游自动同步（merge + 验证 + 失败开 issue，合并路径已实测）
- [x] Electron 桌面端固化标志（构建时注入 main.ts，已产出 309MB win-x64 安装包）

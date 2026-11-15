# dsh-lowend — 让 DeepSeek Harness 在老旧显卡机器上跑顺

针对 **GT218 世代 NVIDIA 显卡**（GeForce 310M / 315M 等，Feature Level 10_1）的
DeepSeek Harness 前端加速补丁集。

## 问题

`dsh web` 在这类机器上极卡。原因不是显卡不行——**WebGL 后端本身就是
`ANGLE (NVIDIA GeForce 310M Direct3D11 vs_4_1)`，硬件加速是通的**。真正的原因是
Chromium 的驱动黑名单把 2015 年停更的驱动一刀切掉，导致合成与光栅化回落到 CPU。

## 实测（同一台机器，1366×768，单页 250 条消息 + 毛玻璃 + 渐变动画）

| 指标 | 默认 | 强制 GPU 光栅化 | 提升 |
|---|---|---|---|
| 帧率 | 12.6 fps | **40.2 fps** | 3.2× |
| 平均帧时间 | 79.6 ms | **24.9 ms** | 3.2× |
| p95 帧时间 | 300 ms | **34.3 ms** | 8.7× |

对照组 WebGL renderer 字符串完全一致，唯一变量是启动标志。

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

# 停止后端
.\lowend\dsh-gpu.cmd -Stop
```

脚本会自动探测 Node（≥24.9）、`@deepseek-ai/dsh` 与浏览器；端口被占用时顺延。
探测结果不对时用 `-DshDir`，或环境变量 `DSH_NODE` / `DSH_BIN` / `DSH_DIR` 覆盖。

窗口以 `--app=` 模式打开，无地址栏，观感接近桌面应用。

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

## 编码注意

`dsh-gpu.ps1` **必须保存为 UTF-8 with BOM**。Windows PowerShell 5.1 对无 BOM 的
UTF-8 会按 ANSI(GBK) 解析，中文字符串直接导致语法错误。改脚本后别用会去 BOM 的编辑器。

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
- [ ] 为 Web 前端提供 `lite` 渲染档：关闭 `backdrop-filter`、限制动画、虚拟滚动
- [ ] Electron 桌面端在 `app.commandLine` 层固化标志，免去浏览器依赖
- [ ] CI 构建 Windows 产物并附测量报告

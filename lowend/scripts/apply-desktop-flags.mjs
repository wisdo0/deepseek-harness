// 把低配 GPU 标志注入 apps/desktop/src/main.ts。
//
// 为什么不直接改仓库里的 main.ts：lowend-win 分支刻意不改上游源码，
// 这样每周的上游合并才不会冲突。标志在 CI 构建桌面端时才注入。
// 上游若改动了锚点，这里会报错并指出，而不是静默地产出一个没有补丁的包。
//
// 用法：node lowend/scripts/apply-desktop-flags.mjs [repoRoot]
// 幂等：重复执行不会重复插入。

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import path from 'node:path';

const repoRoot = process.argv[2] || process.cwd();
const target = path.join(repoRoot, 'apps', 'desktop', 'src', 'main.ts');

// 锚点：main.ts 里 import 块结束后的第一条语句。
// 必须在 app ready 之前设置标志，所以插到模块顶层。
const ANCHOR = 'let focusPrimaryWindow = (): void => {}';
const MARK = '__DSH_LOWEND_GPU_FLAGS__';

const BLOCK = `// ${MARK}
// 老显卡（GT218 世代）被 Chromium 驱动黑名单挡在软件光栅化，这里显式打开 GPU 路径。
// 实测同一页面 12.6fps -> 40.2fps，唯一变量就是这些标志。
// 仅 Windows；设 DSH_LOWEND_GPU=0 可完全关闭本补丁。
if (process.platform === 'win32' && process.env.DSH_LOWEND_GPU !== '0') {
  const lowendSwitches: Array<[string, string?]> = [
    ['ignore-gpu-blocklist'],
    ['enable-gpu-rasterization'],
    ['enable-zero-copy'],
    ['disable-gpu-driver-bug-workarounds'],
    ['use-angle', 'd3d11'],
    ['enable-features', 'CanvasOopRasterization'],
    ['disable-background-networking'],
    ['disk-cache-size', '67108864'],
  ]
  for (const [name, value] of lowendSwitches) {
    if (value === undefined) app.commandLine.appendSwitch(name)
    else app.commandLine.appendSwitch(name, value)
  }
}
// ${MARK} END

`;

if (!existsSync(target)) {
  console.error(`找不到 ${target}`);
  console.error('请在 monorepo 根目录运行，或用参数指定根目录。');
  process.exit(1);
}

const src = readFileSync(target, 'utf8');

if (src.includes(MARK)) {
  console.log('已注入过，跳过（幂等）');
  process.exit(0);
}

if (!src.includes(ANCHOR)) {
  console.error('锚点未找到，无法安全注入。');
  console.error(`期望存在：${ANCHOR}`);
  console.error('上游很可能改了 main.ts 的结构。请人工确认插入点后更新本脚本的 ANCHOR。');
  console.error('要求：插入位置必须在 app.whenReady() 之前，且能访问到 electron 的 app。');
  process.exit(1);
}

const out = src.replace(ANCHOR, BLOCK + ANCHOR);
writeFileSync(target, out, 'utf8');

// 自检：插入位置必须在 whenReady 之前
const idxPatch = out.indexOf(MARK);
const idxReady = out.indexOf('app.whenReady()');
if (idxReady !== -1 && idxPatch > idxReady) {
  console.error('注入点晚于 app.whenReady()，标志不会生效。已中止。');
  process.exit(1);
}

console.log(`已注入 GPU 标志到 ${path.relative(repoRoot, target)}`);
console.log(`  注入位置：第 ${out.slice(0, idxPatch).split('\n').length} 行（whenReady 在第 ${out.slice(0, idxReady).split('\n').length} 行）`);
console.log('  关闭方式：设置环境变量 DSH_LOWEND_GPU=0');

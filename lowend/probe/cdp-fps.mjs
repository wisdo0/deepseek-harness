// 在真实的 dsh 界面里测帧率：连 CDP，注入测量脚本，边滚边测。
const port = process.argv[2] || '9223';

async function findTarget() {
  for (let i = 0; i < 40; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
      const page = list.find(t => t.type === 'page' && t.webSocketDebuggerUrl);
      if (page) return page;
    } catch {}
    await new Promise(r => setTimeout(r, 500));
  }
  throw new Error('没有可连接的页面目标');
}

const expr = `(async () => {
  // 找页面上最大的可滚动容器
  let sc = null, best = 0;
  for (const el of document.querySelectorAll('*')) {
    const d = el.scrollHeight - el.clientHeight;
    if (d > best && el.clientHeight > 100) { best = d; sc = el; }
  }
  const info = {
    scrollable: !!sc,
    scrollRange: best,
    nodes: document.querySelectorAll('*').length,
    backdrop: 0, anim: 0
  };
  if (sc) {
    const cs = getComputedStyle(sc);
    info.overflow = cs.overflowY;
  }
  // 统计毛玻璃与动画元素数量（软件光栅化下这些最贵）
  for (const el of document.querySelectorAll('*')) {
    const s = getComputedStyle(el);
    if (s.backdropFilter && s.backdropFilter !== 'none') info.backdrop++;
    if (s.animationName && s.animationName !== 'none') info.anim++;
  }

  const deltas = [];
  let last = performance.now();
  const t0 = last;
  let dir = 1;
  await new Promise(resolve => {
    function frame(now) {
      deltas.push(now - last); last = now;
      if (sc) {
        sc.scrollTop += 20 * dir;
        if (sc.scrollTop + sc.clientHeight >= sc.scrollHeight - 2) dir = -1;
        if (sc.scrollTop <= 0) dir = 1;
      }
      if (now - t0 < 3000) requestAnimationFrame(frame);
      else resolve();
    }
    requestAnimationFrame(frame);
  });
  const v = deltas.slice(3).filter(d => d > 0).sort((a, b) => a - b);
  const avg = v.reduce((a, b) => a + b, 0) / (v.length || 1);
  return JSON.stringify({
    fps: +(1000 / avg).toFixed(1),
    avgMs: +avg.toFixed(1),
    p95Ms: +(v[Math.floor(v.length * 0.95)] || 0).toFixed(1),
    n: v.length,
    ...info
  });
})()`;

const target = await findTarget();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

const result = await new Promise((resolve, reject) => {
  const id = 1;
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id === id) {
      if (msg.error) return reject(new Error(JSON.stringify(msg.error)));
      resolve(msg.result);
    }
  };
  ws.send(JSON.stringify({
    id, method: 'Runtime.evaluate',
    params: { expression: expr, awaitPromise: true, returnByValue: true }
  }));
  setTimeout(() => reject(new Error('评估超时')), 60000);
});

ws.close();
const raw = result?.result?.value;
console.log('RESULT ' + raw);

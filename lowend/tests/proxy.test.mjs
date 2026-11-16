// dsh-lite 反代的行为测试：不需要真的 dsh，用 mock 上游验证三条硬要求。
//   1. HTML 被注入样式表且 content-length 正确
//   2. 非 HTML / 流式响应原样通过，不被改动
//   3. WebSocket upgrade 能透传到上游
//
// 用法：node lowend/tests/proxy.test.mjs   （退出码 0 = 全过）

import http from 'node:http';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const proxyEntry = path.join(here, '..', 'lite-proxy.mjs');

const MOCK_PORT = 39080;
const PROXY_PORT = 39081;

let failures = 0;
function check(name, cond, extra = '') {
  if (cond) console.log(`  PASS  ${name}`);
  else { console.log(`  FAIL  ${name} ${extra}`); failures++; }
}

// ---------- mock 上游 ----------
const mockHtml = '<!doctype html><html><head><title>t</title></head><body><h1>hi</h1></body></html>';
const streamingChunks = ['alpha', 'beta', 'gamma'];
const MOCK_SELF = `http://127.0.0.1:${MOCK_PORT}`;

// 记录反代实际送来的 Origin，用来断言改写生效
let lastUpgradeOrigin = null;
let lastHttpOrigin = null;

const mock = http.createServer((req, res) => {
  const url = req.url.split('?')[0];
  lastHttpOrigin = req.headers.origin ?? null;
  // 模拟 dsh 的 Origin 校验：与自身 authority 不一致直接拒
  if (req.headers.origin && req.headers.origin !== MOCK_SELF) {
    res.writeHead(403, { 'content-type': 'text/plain' });
    res.end('forbidden');
    return;
  }
  if (url === '/') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(mockHtml);
    return;
  }
  if (url === '/plain') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true}');
    return;
  }
  if (url === '/stream') {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    let i = 0;
    const timer = setInterval(() => {
      if (i >= streamingChunks.length) { clearInterval(timer); res.end(); return; }
      res.write(`data: ${streamingChunks[i++]}\n\n`);
    }, 40);
    return;
  }
  res.writeHead(404);
  res.end('nope');
});

// 最小 WebSocket 握手，够验 upgrade 通不通
mock.on('upgrade', (req, socket) => {
  lastUpgradeOrigin = req.headers.origin ?? null;
  // 关键：真实 dsh 就是这样校验的，Origin 与自身 authority 不一致 -> 403。
  // 反代若只改 Host 不改 Origin，握手必然失败（界面卡在"重新连接中"）。
  if (req.headers.origin && req.headers.origin !== MOCK_SELF) {
    socket.write('HTTP/1.1 403 Forbidden\r\ncontent-length: 9\r\n\r\nforbidden');
    socket.destroy();
    return;
  }
  const key = req.headers['sec-websocket-key'] || '';
  const accept = Buffer.from(
    // sha1(key + GUID) 的结果；这里只为验证链路，用固定 key 对应固定 accept
    key === 'dGhlIHNhbXBsZSBub25jZQ==' ? 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=' : 'invalid'
  ).toString();
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
  );
  socket.on('data', (d) => socket.write(d)); // echo
});

function listen(server, port) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
}

function get(port, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path, method: 'GET', headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({
        status: res.statusCode,
        headers: res.headers,
        body: Buffer.concat(chunks).toString('utf8')
      }));
    });
    req.on('error', reject);
    req.end();
  });
}

function upgrade(port, path, extraHeaders = {}) {
  return new Promise((resolve) => {
    const base = {
      Host: `127.0.0.1:${port}`,
      Upgrade: 'websocket',
      Connection: 'Upgrade',
      'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==',
      'Sec-WebSocket-Version': '13'
    };
    const headers = { ...base, ...extraHeaders };
    const lines = [`GET ${path} HTTP/1.1`];
    for (const [k, v] of Object.entries(headers)) lines.push(`${k}: ${v}`);

    const sock = net.connect(port, '127.0.0.1', () => sock.write(lines.join('\r\n') + '\r\n\r\n'));
    let buf = '';
    const timer = setTimeout(() => { sock.destroy(); resolve(buf); }, 3000);
    sock.on('data', (d) => {
      buf += d.toString();
      if (buf.includes('\r\n\r\n')) { clearTimeout(timer); sock.destroy(); resolve(buf); }
    });
    sock.on('error', () => { clearTimeout(timer); resolve(''); });
  });
}

async function main() {
  await listen(mock, MOCK_PORT);

  const proxy = spawn(process.execPath, [proxyEntry], {
    env: { ...process.env, DSH_UPSTREAM_PORT: String(MOCK_PORT), DSH_LITE_PORT: String(PROXY_PORT) },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  let proxyErr = '';
  proxy.stderr.on('data', (d) => { proxyErr += d.toString(); });

  // 等代理就绪
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('代理启动超时 ' + proxyErr)), 10000);
    proxy.stdout.on('data', (d) => {
      if (d.toString().includes('就绪')) { clearTimeout(timer); resolve(); }
    });
    proxy.on('exit', (code) => { clearTimeout(timer); reject(new Error('代理提前退出 code=' + code + ' ' + proxyErr)); });
  });

  try {
    // 1. HTML 注入
    const html = await get(PROXY_PORT, '/');
    check('HTML 被注入样式表', html.body.includes('__dsh_lite.css'));
    check('注入位置在 </head> 之前',
      html.body.indexOf('__dsh_lite.css') < html.body.indexOf('</head>') &&
      html.body.indexOf('__dsh_lite.css') > 0);
    check('content-length 被重算',
      Number(html.headers['content-length']) === Buffer.byteLength(html.body, 'utf8'),
      `header=${html.headers['content-length']} real=${Buffer.byteLength(html.body, 'utf8')}`);
    check('原始内容仍在', html.body.includes('<h1>hi</h1>'));

    // 2. 非 HTML 不动
    const json = await get(PROXY_PORT, '/plain');
    check('JSON 原样通过', json.body === '{"ok":true}', `got=${json.body}`);

    // 3. 流式响应完整性
    const sse = await get(PROXY_PORT, '/stream');
    check('SSE 三段都到达', streamingChunks.every((c) => sse.body.includes(`data: ${c}`)), `got=${sse.body}`);

    // 4. 样式表本体
    const css = await get(PROXY_PORT, '/__dsh_lite.css');
    check('样式表可取得', css.status === 200 && css.body.includes('backdrop-filter'));

    // 5. WebSocket upgrade（Origin 必须被改写，否则上游 403）
    const proxyOrigin = `http://127.0.0.1:${PROXY_PORT}`;

    // 先证明 mock 确实会拒绝错 Origin —— 否则下面的断言没有意义
    const control = await upgrade(MOCK_PORT, '/ws', { Origin: proxyOrigin });
    check('对照：直连上游且 Origin 不符时被拒', /^HTTP\/1\.1 403/.test(control), `got=${control.slice(0, 40)}`);

    const wsResult = await upgrade(PROXY_PORT, '/ws', { Origin: proxyOrigin });
    check('WebSocket upgrade 返回 101', /^HTTP\/1\.1 101/.test(wsResult), `got=${wsResult.slice(0, 60)}`);
    check('Sec-WebSocket-Accept 由上游生成', wsResult.includes('s3pPLMBiTxaQ9kYGzzhZRbK+xOo='), `got=${wsResult.slice(0, 120)}`);
    check('反代把 Origin 改写为上游地址', lastUpgradeOrigin === MOCK_SELF, `got=${lastUpgradeOrigin}`);

    // 6. 普通 HTTP 的 Origin 同样要改写
    const httpOrigin = await get(PROXY_PORT, '/plain', { Origin: proxyOrigin });
    check('HTTP 请求的 Origin 也被改写', lastHttpOrigin === MOCK_SELF, `got=${lastHttpOrigin}`);
    check('改写后 HTTP 请求不再被 403', httpOrigin.status === 200, `status=${httpOrigin.status}`);
  } finally {
    proxy.kill();
    mock.close();
  }

  console.log(failures === 0 ? '\n全部通过' : `\n${failures} 项失败`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('测试异常：', e.message);
  process.exit(1);
});

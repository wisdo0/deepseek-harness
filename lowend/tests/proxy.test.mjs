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

const mock = http.createServer((req, res) => {
  const url = req.url.split('?')[0];
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

    // 5. WebSocket upgrade
    const wsResult = await new Promise((resolve) => {
      const sock = net.connect(PROXY_PORT, '127.0.0.1', () => {
        sock.write(
          'GET /ws HTTP/1.1\r\n' +
          'Host: 127.0.0.1\r\n' +
          'Upgrade: websocket\r\n' +
          'Connection: Upgrade\r\n' +
          'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n' +
          'Sec-WebSocket-Version: 13\r\n\r\n'
        );
      });
      let buf = '';
      const timer = setTimeout(() => { sock.destroy(); resolve(buf); }, 3000);
      sock.on('data', (d) => {
        buf += d.toString();
        if (buf.includes('\r\n\r\n')) { clearTimeout(timer); sock.destroy(); resolve(buf); }
      });
      sock.on('error', () => { clearTimeout(timer); resolve(''); });
    });
    check('WebSocket upgrade 返回 101', /^HTTP\/1\.1 101/.test(wsResult), `got=${wsResult.slice(0, 60)}`);
    check('Sec-WebSocket-Accept 由上游生成', wsResult.includes('s3pPLMBiTxaQ9kYGzzhZRbK+xOo='), `got=${wsResult.slice(0, 120)}`);
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

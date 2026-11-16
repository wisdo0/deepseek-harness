// dsh-lite 反代：把 lite.css 注入 dsh 的 HTML，其余流量原样转发。
//
// 为什么用反代而不是改前端：不碰上游代码，跟版本走；升级 dsh 不用 rebase。
//
// 三个必须做对的地方：
//   1. HTML 要缓冲后注入并重算 content-length（不能边流边改）
//   2. 其它响应（含 SSE / 流式输出）必须原样 pipe，不能缓冲
//   3. WebSocket upgrade 要单独转发，否则界面收不到流式回复
//
// 环境变量：
//   DSH_UPSTREAM_PORT  上游 dsh 端口（默认 3080）
//   DSH_LITE_PORT      本代理端口（默认 3081）

import http from 'node:http';
import net from 'node:net';
import { readFileSync } from 'node:fs';

const UPSTREAM_HOST = '127.0.0.1';
const UPSTREAM_PORT = Number(process.env.DSH_UPSTREAM_PORT || 3080);
const LISTEN_PORT = Number(process.env.DSH_LITE_PORT || 3081);
const CSS_PATH = '/__dsh_lite.css';
const CSS_TAG = `<link rel="stylesheet" href="${CSS_PATH}" data-dsh-lite>`;

const css = readFileSync(new URL('./lite.css', import.meta.url));

// 逐跳首部不能透传
const HOP_BY_HOP = new Set([
  'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailer', 'transfer-encoding', 'upgrade'
]);

function buildUpstreamHeaders(raw) {
  const out = {};
  for (const [k, v] of Object.entries(raw)) {
    if (HOP_BY_HOP.has(k.toLowerCase())) continue;
    out[k] = v;
  }
  // 上游回明文，我们才能安全注入
  delete out['accept-encoding'];
  out.host = `${UPSTREAM_HOST}:${UPSTREAM_PORT}`;
  return out;
}

const server = http.createServer((req, res) => {
  if (req.url.split('?')[0] === CSS_PATH) {
    res.writeHead(200, {
      'content-type': 'text/css; charset=utf-8',
      'cache-control': 'no-store'
    });
    res.end(css);
    return;
  }

  const upstream = http.request(
    {
      host: UPSTREAM_HOST,
      port: UPSTREAM_PORT,
      method: req.method,
      path: req.url,
      headers: buildUpstreamHeaders(req.headers)
    },
    (up) => {
      const type = String(up.headers['content-type'] || '');
      const isHtml = type.includes('text/html');

      // 非 HTML：原样转发，绝不缓冲（流式输出走这里）
      if (!isHtml) {
        res.writeHead(up.statusCode || 502, up.headers);
        up.pipe(res);
        return;
      }

      const chunks = [];
      up.on('data', (c) => chunks.push(c));
      up.on('end', () => {
        let body = Buffer.concat(chunks).toString('utf8');
        if (body.includes(CSS_TAG)) {
          // 已经注入过（比如上游自己缓存了），不重复
        } else if (body.includes('</head>')) {
          body = body.replace('</head>', `${CSS_TAG}</head>`);
        } else {
          body = CSS_TAG + body;
        }

        const buf = Buffer.from(body, 'utf8');
        const headers = { ...up.headers };
        delete headers['content-length'];
        delete headers['content-encoding'];
        delete headers['transfer-encoding'];
        headers['content-length'] = String(buf.length);
        // 注入的是同源样式表，CSP 里 style-src 'self' 就能过，无需放宽策略
        res.writeHead(up.statusCode || 200, headers);
        res.end(buf);
      });
    }
  );

  upstream.on('error', (err) => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    res.end(`dsh-lite 转发失败：${err.message}\n`);
  });

  req.pipe(upstream);
});

// WebSocket（dsh 靠它推流式回复）：按原始首部转发，之后双向直通
server.on('upgrade', (req, socket, head) => {
  const up = net.connect(UPSTREAM_PORT, UPSTREAM_HOST, () => {
    const lines = [`${req.method} ${req.url} HTTP/1.1`];
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      const name = req.rawHeaders[i];
      const value = req.rawHeaders[i + 1];
      if (name.toLowerCase() === 'host') {
        lines.push(`${name}: ${UPSTREAM_HOST}:${UPSTREAM_PORT}`);
      } else {
        lines.push(`${name}: ${value}`);
      }
    }
    up.write(lines.join('\r\n') + '\r\n\r\n');
    if (head && head.length) up.write(head);
    up.pipe(socket);
    socket.pipe(up);
  });

  up.on('error', () => socket.destroy());
  socket.on('error', () => up.destroy());
  socket.on('close', () => up.destroy());
});

server.on('error', (err) => {
  console.error(`dsh-lite 监听 ${LISTEN_PORT} 失败：${err.message}`);
  process.exit(1);
});

server.listen(LISTEN_PORT, '127.0.0.1', () => {
  console.log(`dsh-lite 就绪：http://127.0.0.1:${LISTEN_PORT} -> 127.0.0.1:${UPSTREAM_PORT}`);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1000).unref();
  });
}

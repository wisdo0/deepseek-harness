import http from 'node:http';
import { readFileSync } from 'node:fs';

const PORT = 8899;
const page = readFileSync(new URL('./probe.html', import.meta.url));
const liteCss = readFileSync(new URL('../lite.css', import.meta.url));

const server = http.createServer((req, res) => {
  if (req.url.startsWith('/lite.css')) {
    res.writeHead(200, { 'content-type': 'text/css; charset=utf-8', 'cache-control': 'no-store' });
    res.end(liteCss);
    return;
  }
  if (req.url.startsWith('/report')) {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      res.writeHead(200, { 'content-type': 'text/plain', 'access-control-allow-origin': '*' });
      res.end('ok');
      try {
        console.log('RESULT ' + JSON.stringify(JSON.parse(body)));
      } catch {
        console.log('BAD ' + body.slice(0, 300));
      }
      setTimeout(() => process.exit(0), 200);
    });
    return;
  }
  if (req.url.startsWith('/ping')) {
    console.log('PING ' + (req.headers['user-agent'] || '').slice(0, 60));
    res.writeHead(200, { 'content-type': 'text/plain', 'access-control-allow-origin': '*' });
    res.end('pong');
    return;
  }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(page);
});

server.listen(PORT, '127.0.0.1', () => console.log('LISTEN ' + PORT));
setTimeout(() => { console.log('TIMEOUT'); process.exit(1); }, 240000);

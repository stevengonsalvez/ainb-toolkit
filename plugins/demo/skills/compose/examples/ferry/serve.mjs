// ABOUTME: Tiny static server for the Skerry Ferries example app. A made-up ferry operator,
// three plain HTML pages, no build and no login.
// Usage: node serve.mjs [port]   (default 7744, or $PORT)
import { createServer } from 'node:http'; import { readFileSync } from 'node:fs'; import { fileURLToPath } from 'node:url';
const dir = fileURLToPath(new URL('./app/', import.meta.url));
const port = +(process.argv[2] || process.env.PORT || 7744);
const types = { '.css': 'text/css', '.html': 'text/html' };
createServer((q, s) => {
  let p = q.url.split('?')[0]; if (p === '/') p = '/board';
  const f = p.includes('.') ? p : p + '.html';
  if (f.includes('..')) { s.writeHead(400); return s.end(); }
  let body;
  try { body = readFileSync(dir + f.slice(1)); } catch { s.writeHead(404); return s.end('not found'); }
  s.writeHead(200, { 'content-type': types[f.slice(f.lastIndexOf('.'))] || 'text/plain' }); s.end(body);
}).listen(port, '127.0.0.1', () => console.log('ferry on ' + port));

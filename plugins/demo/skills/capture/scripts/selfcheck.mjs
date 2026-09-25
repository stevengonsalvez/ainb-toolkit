#!/usr/bin/env node
// ABOUTME: One runnable self-check for the rig, against a throwaway local server
// (no app, no login). Exits non-zero if the core capture logic breaks.
// Usage: node selfcheck.mjs   (or `npm run check` from the skill dir)
import http from 'http'; import fs from 'fs'; import os from 'os'; import path from 'path';
import assert from 'assert/strict'; import { execFileSync } from 'child_process';
import { capture, checkPath } from './capture.mjs';

const BG = '#3a6ea5';                             // luma ~100: neither blank white nor splash black
const nav = `<nav class="fixed bottom-0" style="position:fixed;bottom:0;left:0;right:0;height:64px;background:#222;display:flex;gap:40px;justify-content:center;align-items:center">
  <a href="/b" style="color:#fff">REPORTS</a><a href="/a" style="color:#fff">HOME</a></nav>`;
const pages = {
  // A headline sharing the nav's text: bare `text=REPORTS` hits this first.
  '/a': `<body style="margin:0;background:${BG};height:100vh"><h1><a href="/news" style="color:#fff">REPORTS show a record season</a></h1>${nav}</body>`,
  // Tall page with a white block (bigger than the 2x camera box) far below the fold: zooming on it after a scroll must film it.
  '/tall': `<body style="margin:0;background:${BG};height:3000px"><div id="w" style="position:absolute;top:2000px;left:290px;width:700px;height:400px;background:#fff"></div></body>`,
  '/news': `<body style="background:${BG}">news</body>`,
  // Splash until a slow request lands, like an SPA shell fetching its data.
  '/b': `<body style="margin:0;background:#000;height:100vh">${nav}<script>fetch('/slow').then(() => document.body.style.background = '${BG}')</script></body>`,
};
const server = http.createServer((req, res) => {
  if (req.url === '/slow') return setTimeout(() => res.end('ok'), 1500);
  res.setHeader('content-type', 'text/html'); res.end(pages[req.url] ?? '404');
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;
const out = fs.mkdtempSync(path.join(os.tmpdir(), 'demo-capture-check-'));
const luma = jpg => Number(execFileSync('/usr/bin/ffmpeg', ['-v', 'error', '-i', jpg, '-vf',
  'signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-', '-f', 'null', '-']).toString().match(/YAVG=([\d.]+)/)[1]);
const frame = (dir, i) => path.join(dir, `f${String(i).padStart(5, '0')}.jpg`);

try {
  // 1. Path guard.
  checkPath('/reports', 'http://x/reports/team');
  checkPath(/^\/b$/, 'http://x/b');
  assert.throws(() => checkPath('/reports', 'http://x/news/article'), /expected path \/reports, got \/news/);

  // 2. Main take: zoom, marks, scoped click, wait out the splash.
  const r = await capture({ base, out, chapter: 'main', beats: [
    { goto: '/a' },
    { mark: { label: 'nav', on: 'nav.fixed.bottom-0' } },
    { zoom: { on: 'nav.fixed.bottom-0', scale: 2, ms: 500 }, mark: { label: 'zoomed', on: 'nav.fixed.bottom-0' } },
    { wide: 500 },
    { name: 'reports', click: 'nav.fixed.bottom-0 >> text=REPORTS', expectPath: '/b' },
  ] });
  const ev = JSON.parse(fs.readFileSync(path.join(r.dir, 'events.json'), 'utf8'));
  for (const k of ['chapter', 'viewport', 'dur', 'frames', 'events']) assert.ok(k in ev, `events.json missing ${k}`);
  assert.equal(ev.frames, r.frames);
  for (const e of ev.events) for (const k of ['t', 'kind', 'label', 'rect', 'cam']) assert.ok(k in e, `event missing ${k}`);
  const z = ev.events.find(e => e.label === 'zoomed');
  assert.equal(z.cam.s, 2, 'zoom did not reach scale 2');
  assert.ok(z.cam.y + z.cam.h >= z.rect.y + z.rect.h, 'zoom box does not frame the nav');
  const head = luma(frame(r.dir, 0)), tail = luma(frame(r.dir, r.frames - 1));
  assert.ok(head > 60 && head < 140, `first frame is blank/splash (luma ${head})`);
  assert.ok(tail > 60 && tail < 140, `last frame is still the splash (luma ${tail})`);

  // 3. Holds must keep producing frames (screencast only emits on repaint).
  const h = await capture({ base, out, chapter: 'hold', beats: [{ goto: '/a', hold: 2500 }] });
  assert.ok(h.frames >= 30, `2.5s hold produced only ${h.frames} frames`);

  // 4. Zoom after scroll frames the target (override viewport is document-relative).
  const sz = await capture({ base, out, chapter: 'scrollzoom', beats: [{ goto: '/tall' }, { scroll: 1700 }, { zoom: { on: '#w', scale: 2, ms: 400 }, hold: 800 }] });
  const zl = luma(frame(sz.dir, sz.frames - 1));
  assert.ok(zl > 200, `zoom after scroll missed the target (luma ${zl})`);

  // 5. A bare-text mis-click must fail the take.
  await assert.rejects(capture({ base, out, chapter: 'wrong', beats: [
    { goto: '/a' }, { name: 'bare', click: 'text=REPORTS', expectPath: '/b' }] }), /expected path \/b, got \/news/);

  console.log(`selfcheck OK: main ${r.frames} frames/${r.dur.toFixed(1)}s luma head ${head} tail ${tail}; hold ${h.frames} frames; scroll-zoom luma ${zl}; guard threw`);
} finally {
  server.close(); fs.rmSync(out, { recursive: true, force: true });
}

#!/usr/bin/env node
// ABOUTME: One runnable self-check for the rig, against a throwaway local server
// (no app, no login). Exits non-zero if the core capture logic breaks.
// Usage: node selfcheck.mjs   (or `npm run check` from the skill dir)
import http from 'http'; import fs from 'fs'; import os from 'os'; import path from 'path';
import assert from 'assert/strict'; import { execFileSync } from 'child_process';
import { chromium } from '@playwright/test';
import { capture, checkPath, ensureState, overlay } from './capture.mjs';

const BG = '#3a6ea5';                             // luma ~100: neither blank white nor splash black
const nav = `<nav class="fixed bottom-0" style="position:fixed;bottom:0;left:0;right:0;height:64px;background:#222;display:flex;gap:40px;justify-content:center;align-items:center">
  <a href="/b" style="color:#fff">REPORTS</a><a href="/a" style="color:#fff">HOME</a></nav>`;
const pages = {
  // A headline sharing the nav's text: bare `text=REPORTS` hits this first.
  '/a': `<body style="margin:0;background:${BG};height:100vh"><h1><a href="/news" style="color:#fff">REPORTS show a record season</a></h1>${nav}</body>`,
  // Tall page with a white block (bigger than the 2x camera box) far below the fold: zooming on it after a scroll must film it.
  '/tall': `<body style="margin:0;background:${BG};height:3000px"><div id="w" style="position:absolute;top:2000px;left:290px;width:700px;height:400px;background:#fff"></div></body>`,
  '/news': `<body style="background:${BG}">news</body>`,
  '/frame': `<body style="margin:0;background:${BG};height:100vh"><iframe src="/news" width="400" height="200"></iframe></body>`,
  // Turns white once the input holds exactly the typed text: the last frame proves the type beat.
  '/type': `<body style="margin:0;background:${BG};height:100vh"><input id="q" style="margin:200px;font-size:30px" oninput="if (this.value === 'ferry times') document.body.style.background = '#fff'"></body>`,
  // A login form, and a home page that sends logged-out visitors to /welcome, not to /login.
  '/login': `<body><input id="email"><input id="password" type="password"><button onclick="document.cookie='sid=1;path=/';location='/home'">Log in</button></body>`,
  '/welcome': `<body>welcome</body>`,
  // Splash until a slow request lands, like an SPA shell fetching its data.
  '/b': `<body style="margin:0;background:#000;height:100vh">${nav}<script>fetch('/slow').then(() => document.body.style.background = '${BG}')</script></body>`,
};
const server = http.createServer((req, res) => {
  if (req.url === '/slow') return setTimeout(() => res.end('ok'), 1500);
  // A sandboxed document: localStorage throws in it.
  if (req.url === '/sandboxed') { res.setHeader('content-security-policy', 'sandbox allow-scripts'); return res.end(`<body style="background:${BG}">sandboxed</body>`); }
  if (req.url === '/home') {
    if (!/sid=1/.test(req.headers.cookie || '')) { res.writeHead(302, { location: '/welcome' }); return res.end(); }
    res.setHeader('content-type', 'text/html'); return res.end('<body><div id="me">signed in</div></body>');
  }
  res.setHeader('content-type', 'text/html'); res.end(pages[req.url] ?? '404');
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;
const out = fs.mkdtempSync(path.join(os.tmpdir(), 'demo-capture-check-'));
const luma = jpg => Number(execFileSync(process.env.FFMPEG || 'ffmpeg', ['-v', 'error', '-i', jpg, '-vf',
  'signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-', '-f', 'null', '-']).toString().match(/YAVG=([\d.]+)/)[1]);
const frame = (dir, i) => path.join(dir, `f${String(i).padStart(5, '0')}.jpg`);

try {
  // 1. Path guard.
  checkPath('/reports', 'http://x/reports/team');
  checkPath(/^\/b$/, 'http://x/b');
  assert.throws(() => checkPath('/reports', 'http://x/news/article'), /expected path \/reports, got \/news/);
  // A sibling path sharing the prefix is a different page.
  checkPath('/reports', 'http://x/reports?tab=2#top');
  assert.throws(() => checkPath('/reports', 'http://x/reports-archive'), /got \/reports-archive/);

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
  // The mp4 must run as long as the take. Zoom glides deliver frames faster than 30fps; an
  // encoder that mishandles those squeezes the timeline and puts every mark late.
  execFileSync(path.join(import.meta.dirname, 'encode.sh'), [r.dir, `${r.dir}.mp4`]);
  const n = Number(execFileSync(process.env.FFPROBE || 'ffprobe', ['-v', 'error', '-count_frames', '-select_streams', 'v:0',
    '-show_entries', 'stream=nb_read_frames', '-of', 'csv=p=0', `${r.dir}.mp4`]).toString());
  assert.ok(Math.abs(n / 30 - r.dur) < 0.1, `mp4 holds ${n} frames (${(n / 30).toFixed(2)}s) for a ${r.dur.toFixed(2)}s take`);
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

  // 6. Overlay: one cursor per page even with an iframe, mounts in a sandboxed document where
  //    storage throws, and every click ripple starts from scale(1).
  const browser = await chromium.launch();
  let ripple, sandboxErrs;
  try {
    const page = await browser.newPage();
    await page.addInitScript(overlay, { ls: { k: 'v' }, hidden: false });
    await page.goto(`${base}/frame`); await page.frames()[1].waitForLoadState();
    const cursors = (await Promise.all(page.frames().map(f => f.locator('#__cur').count()))).reduce((a, b) => a + b);
    assert.equal(cursors, 1, `expected 1 cursor across ${page.frames().length} frames, got ${cursors}`);

    const errs = []; page.on('pageerror', e => errs.push(e.message));
    await page.goto(`${base}/sandboxed`);
    assert.equal(await page.locator('#__cur').count(), 1, 'cursor did not mount in a sandboxed document');
    sandboxErrs = errs.length;
    assert.equal(sandboxErrs, 0, `init script threw: ${errs}`);

    await page.goto(`${base}/news`);
    await page.evaluate(() => { window.__log = []; document.addEventListener('mousedown', () => {
      const r = document.getElementById('__ring'); window.__log.push([r.style.transform, r.style.cssText.length]); }); });
    for (const x of [300, 500, 700]) { await page.mouse.click(x, 300); await page.waitForTimeout(700); }
    ripple = await page.evaluate(() => window.__log);
    assert.deepEqual(ripple.map(r => r[0]), ['scale(1)', 'scale(1)', 'scale(1)'], `ripple start transforms ${JSON.stringify(ripple)}`);
    assert.equal(new Set(ripple.map(r => r[1])).size, 1, `ripple cssText grows per click ${JSON.stringify(ripple)}`);
  } finally { await browser.close(); }

  // 7. type beat types key by key (fill() would finish in one frame), and a hidden cursor still
  //    keeps a hold emitting frames.
  const ty = await capture({ base, out, chapter: 'type', cursor: { hidden: true }, beats: [{ goto: '/type' }, { type: { into: '#q', text: 'ferry times', cps: 10 } }, { hold: 1500 }] });
  const tl = luma(frame(ty.dir, ty.frames - 1));
  assert.ok(tl > 200, `typed text did not land (luma ${tl})`);
  assert.ok(ty.dur > 1.0 + 1.5, `type beat too fast for 11 chars at 10 cps (${ty.dur.toFixed(2)}s)`);
  assert.ok(ty.frames >= 30, `hidden-cursor take produced only ${ty.frames} frames`);

  // 8. pace scales holds: the same 1s hold at pace 2 films about twice as long.
  const p1 = await capture({ base, out, chapter: 'pace1', beats: [{ goto: '/a', hold: 1000 }] });
  const p2 = await capture({ base, out, chapter: 'pace2', pace: 2, beats: [{ goto: '/a', hold: 1000 }] });
  assert.ok(p2.dur - p1.dur > 0.8, `pace 2 did not lengthen the take (${p1.dur.toFixed(2)}s vs ${p2.dur.toFixed(2)}s)`);

  // 9. A dead session on an app that sends logged-out users to /welcome must be re-minted when
  //    loggedInSel is set; without it the probe only checks "not on /login" and wrongly reuses it.
  const state = path.join(out, 'state.json');
  fs.writeFileSync(state, JSON.stringify({ cookies: [], origins: [] }));
  const login = { email: 'a@example.test', password: 'x' };
  assert.equal(await ensureState({ base, state, login }), 'reused');
  fs.writeFileSync(state, JSON.stringify({ cookies: [], origins: [] }));
  assert.equal(await ensureState({ base, state, login: { ...login, loggedInSel: '#me' } }), 'minted');
  assert.equal(await ensureState({ base, state, login: { ...login, loggedInSel: '#me' } }), 'reused');

  console.log(`selfcheck OK: cursors 1 with iframe; sandbox errors ${sandboxErrs}; ripple ${JSON.stringify(ripple)}; type ${ty.dur.toFixed(2)}s luma ${tl}; pace ${p1.dur.toFixed(2)}s -> ${p2.dur.toFixed(2)}s; loggedInSel re-mints`);
  console.log(`selfcheck OK: main ${r.frames} frames/${r.dur.toFixed(1)}s mp4 ${n} frames luma head ${head} tail ${tail}; hold ${h.frames} frames; scroll-zoom luma ${zl}; guard threw`);
} finally {
  server.close(); fs.rmSync(out, { recursive: true, force: true });
}

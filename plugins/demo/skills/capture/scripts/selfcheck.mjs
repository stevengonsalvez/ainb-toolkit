#!/usr/bin/env node
// ABOUTME: One runnable self-check for the rig, against a throwaway local server
// (no app, no login). Exits non-zero if the core capture logic breaks.
// Usage: node selfcheck.mjs   (or `npm run check` from the skill dir)
import http from 'http'; import fs from 'fs'; import os from 'os'; import path from 'path';
import assert from 'assert/strict'; import { execFileSync } from 'child_process';
import { chromium } from '@playwright/test';
import { capture, checkPath, ensureState, overlay } from './capture.mjs';
import { Camera, Cursor, spring1d, CAMERA, CURSOR, SNAPPY } from './motion.mjs';

const BG = '#3a6ea5';                             // luma ~100: neither blank white nor splash black
const nav = `<nav class="fixed bottom-0" style="position:fixed;bottom:0;left:0;right:0;height:64px;background:#222;display:flex;gap:40px;justify-content:center;align-items:center">
  <a href="/b" style="color:#fff">REPORTS</a><a href="/a" style="color:#fff">HOME</a></nav>`;
const pages = {
  // A headline sharing the nav's text: bare `text=REPORTS` hits this first.
  '/a': `<body style="margin:0;background:${BG};height:100vh"><h1><a href="/news" style="color:#fff">REPORTS show a record season</a></h1>${nav}</body>`,
  // Tall page with a white block (bigger than the 2x camera box) far below the fold: zooming on it after a scroll must film it.
  '/tall': `<body style="margin:0;background:${BG};height:3000px"><div id="w" style="position:absolute;top:2000px;left:290px;width:700px;height:400px;background:#fff"></div></body>`,
  '/news': `<body style="background:${BG}">news</body>`,
  // Plain page with an invisible zoom target: the only white pixels in a frame are the cursor's.
  // #go fills the zoom target, so a click on it navigates while the camera is zoomed.
  '/plain': `<body style="margin:0;background:${BG};height:100vh"><div id="z" style="position:absolute;left:440px;top:260px;width:400px;height:200px"><a id="go" href="/plain2" style="position:absolute;inset:0"></a></div></body>`,
  '/plain2': `<body style="margin:0;background:${BG};height:100vh"></body>`,
  '/frame': `<body style="margin:0;background:${BG};height:100vh"><iframe src="/news" width="400" height="200"></iframe></body>`,
  // Turns white once the input holds exactly the typed text: the last frame proves the type beat.
  '/type': `<body style="margin:0;background:${BG};height:100vh"><input id="q" style="margin:200px;font-size:30px" oninput="if (this.value === 'ferry times') document.body.style.background = '#fff'"></body>`,
  // A login form, and a home page that sends logged-out visitors to /welcome, not to /login.
  '/login': `<body><input id="email"><input id="password" type="password"><button onclick="document.cookie='sid=1;path=/';location='/home'">Log in</button></body>`,
  '/welcome': `<body>welcome</body>`,
  // Splash until a slow request lands, like an SPA shell fetching its data.
  '/b': `<body style="margin:0;background:#000;height:100vh">${nav}<script>fetch('/slow').then(() => document.body.style.background = '${BG}')</script></body>`,
  // Something moves on every frame: a CSS animation and a rAF-driven bar.
  '/anim': `<body style="margin:0;background:${BG};height:100vh"><div style="position:absolute;top:200px;width:60px;height:60px;background:#fff;animation:mv 3s linear infinite"></div>
    <div id="r" style="position:absolute;top:400px;height:20px;background:#f80"></div><style>@keyframes mv{to{transform:translateX(1200px)}}</style>
    <script>const r = document.getElementById('r'); (function f(t) { r.style.width = (t / 3 % 1200) + 'px'; requestAnimationFrame(f); })(0)</script></body>`,
  // Holds an SSE stream open for good, like a live-updates channel.
  '/sse': `<body style="margin:0;background:${BG};height:100vh"><script>new EventSource('/stream')</script></body>`,
  // A lazy-loaded module, like a code-split route: turns white once it has loaded.
  '/lazy': `<body style="margin:0;background:${BG};height:100vh"><button id="go" style="margin:200px" onclick="import('/mod.js').then(m => document.body.style.background = m.c)">go</button></body>`,
};
const server = http.createServer((req, res) => {
  if (req.url === '/slow') return setTimeout(() => res.end('ok'), 1500);
  if (req.url === '/mod.js') { res.setHeader('content-type', 'text/javascript'); return res.end(`export const c = '#fff';`); }
  if (req.url === '/stream') { res.writeHead(200, { 'content-type': 'text/event-stream' }); return res.write('data: hi\n\n'); }
  // A sandboxed document: localStorage throws in it.
  if (req.url === '/sandboxed') { res.setHeader('content-security-policy', 'sandbox allow-scripts'); return res.end(`<body style="background:${BG}">sandboxed</body>`); }
  if (req.url === '/home') {
    if (!/sid=1/.test(req.headers.cookie || '')) { res.writeHead(302, { location: '/welcome' }); return res.end(); }
    // #me renders late, like an SPA shell: a check that does not wait reads a live session as dead.
    res.setHeader('content-type', 'text/html'); return res.end(`<body><script>setTimeout(() => document.body.innerHTML = '<div id="me">signed in</div>', 2000)</script></body>`);
  }
  res.setHeader('content-type', 'text/html'); res.end(pages[req.url] ?? '404');
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;
const out = fs.mkdtempSync(path.join(os.tmpdir(), 'demo-capture-check-'));
// $FFMPEG/$FFPROBE, else the distro build at /usr/bin, else PATH (Homebrew on macOS, where /usr/bin is read-only).
const ffbin = name => process.env[name.toUpperCase()] || (fs.existsSync(`/usr/bin/${name}`) ? `/usr/bin/${name}` : name);
const FFMPEG = ffbin('ffmpeg'), FFPROBE = ffbin('ffprobe');
const SC = { mode: 'screencast' };
// Motion blur multiplies capture time (fact 14); takes that do not test it film without it.
const NB = { blur: false };
const ev = t => JSON.parse(fs.readFileSync(path.join(t.dir, 'events.json'), 'utf8'));
// Output frame k of a take (cfr/ is the constant-rate sequence: PNG when deterministic, JPEG from screencast).
const frame = (t, k) => { const f = path.join(t.dir, 'cfr', String(k).padStart(5, '0')); return fs.existsSync(`${f}.png`) ? `${f}.png` : `${f}.jpg`; };
const last = t => frame(t, fs.readdirSync(path.join(t.dir, 'cfr')).length - 1);
const yavg = (img, vf = '') => Number(execFileSync(FFMPEG, ['-v', 'error', '-i', img, '-vf',
  `${vf}signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-`, '-f', 'null', '-']).toString().match(/YAVG=([\d.]+)/)[1]);
const luma = img => yavg(img);
const probe = mp4 => JSON.parse(execFileSync(FFPROBE, ['-v', 'error', '-count_frames', '-select_streams', 'v:0',
  '-show_entries', 'stream=width,height,avg_frame_rate,nb_read_frames', '-of', 'json', mp4]).toString()).streams[0];
// An ffmpeg stand-in for capture's blur jobs (the only calls with tmix): every other call, and
// every job after the first, runs the real ffmpeg. For the first job, `nowrite` exits 0 without
// writing its frame; `stall` marks `started`, waits, then marks `finished` and runs.
const ffStandIn = (mode, marks) => {
  const f = path.join(marks, `ffmpeg-${mode}.sh`);
  fs.writeFileSync(f, `#!/bin/sh
case "$*" in *tmix=*) ;; *) exec "${FFMPEG}" "$@";; esac
if mkdir "${marks}/first" 2>/dev/null; then
  ${mode === 'nowrite' ? 'exit 0' : `touch "${marks}/started"; sleep 8; touch "${marks}/finished"`}
fi
exec "${FFMPEG}" "$@"
`);
  fs.chmodSync(f, 0o755);
  return f;
};
const encode = (dir, mp4) => execFileSync(path.join(import.meta.dirname, 'encode.sh'), [dir, mp4]);

try {
  // 1. Path guard.
  checkPath('/reports', 'http://x/reports/team');
  checkPath(/^\/b$/, 'http://x/b');
  assert.throws(() => checkPath('/reports', 'http://x/news/article'), /expected path \/reports, got \/news/);
  // A sibling path sharing the prefix is a different page.
  checkPath('/reports', 'http://x/reports?tab=2#top');
  assert.throws(() => checkPath('/reports', 'http://x/reports-archive'), /got \/reports-archive/);

  // 2. Spring solver (motion.mjs), pure.
  //    a. The integrator against the damped oscillator's own theory: for each profile, a unit step
  //       peaks at t = pi / (w sqrt(1 - z^2)) with overshoot exp(-pi z / sqrt(1 - z^2)).
  const springs = {};
  for (const [nm, P] of Object.entries({ camera: CAMERA, cursor: CURSOR, snappy: SNAPPY })) {
    const w = Math.sqrt(P.k / P.m), z = P.c / (2 * Math.sqrt(P.k * P.m)), wd = w * Math.sqrt(1 - z * z);
    let e = -1, v = 0, peak = -Infinity, tp = 0;
    for (let i = 1; i <= 3000; i++) { [e, v] = spring1d(e, v, 0.001, P.k, P.c, P.m); if (e > peak) { peak = e; tp = i / 1000; } }
    // The damping ratio the overshoot implies, z = -ln(os) / sqrt(pi^2 + ln(os)^2), must be the
    // profile's own within 0.005, and the peak must come within 2% of its time.
    const L = Math.log(peak), zm = -L / Math.sqrt(Math.PI ** 2 + L * L), tw = Math.PI / wd;
    springs[nm] = `z ${z.toFixed(4)} measured ${zm.toFixed(4)}, peak ${tp}s want ${tw.toFixed(3)}s`;
    assert.ok(Math.abs(zm - z) < 0.005 && Math.abs(tp / tw - 1) < 0.02, `${nm} spring: ${springs[nm]}`);
    // and it settles: within 0.1% after six time constants of the decay envelope
    assert.ok(Math.abs(spring1d(-1, 0, 6 / (z * w) + 0.5, P.k, P.c, P.m)[0]) < 1e-3, `${nm} spring never settles`);
  }
  //    b. A zoom from wide is pre-aimed: the centre jumps to the (off-centre) target, so the zoom
  //       scales about one fixed page point, which holds still on screen while the scale grows.
  const cam = new Camera(1280, 720), FI = 1 / 60;
  cam.aim({ x: 100, y: 60, w: 640, h: 360, s: 2 });
  const fx = cam.u.x * 1280, fy = cam.v.x * 720;
  assert.ok(Math.abs(cam.u.x - 100 / 640) < 1e-12 && Math.abs(cam.v.x - 60 / 360) < 1e-12 && cam.u.v === 0, `zoom from wide was not pre-aimed (u ${cam.u.x})`);
  const xs = [];
  for (let i = 0; i < 12; i++) {
    cam.step(FI); const b = cam.box(); xs.push(b);
    assert.ok(Math.hypot((fx - b.x) * b.s - fx, (fy - b.y) * b.s - fy) < 1e-6, `zoom from wide panned: fixed point moved at frame ${i}`);
  }
  //    c. A retarget mid-flight keeps the velocity (no kink).
  cam.aim({ x: 600, y: 300, w: 512, h: 288, s: 2.5 });
  for (let i = 0; i < 12; i++) { cam.step(FI); xs.push(cam.box()); }
  // Velocity of the scale channel frame to frame: its largest jump across the retarget is no
  // bigger than its largest jump anywhere else (a velocity reset would spike it).
  const dv = xs.slice(2).map((b, i) => Math.abs((b.s - xs[i + 1].s) - (xs[i + 1].s - xs[i].s)));
  assert.ok(dv[10] <= Math.max(...dv.filter((_, i) => i !== 10)) * 1.5 + 1e-9, `scale velocity jumps at the retarget: ${dv.map(v => v.toExponential(1))}`);
  let settle = 0; while (!cam.settled() && settle < 600) { cam.step(FI); settle++; }
  assert.deepEqual(cam.box(), { x: 600, y: 300, w: 512, h: 288, s: 2.5 }, 'camera did not settle exactly on its target');
  //    d. zoom.ms 0 is a cut, not a NaN camera that never settles.
  const cut = new Camera(1280, 720); cut.aim({ x: 100, y: 60, w: 640, h: 360, s: 2 }, 0);
  assert.ok(cut.settled() && cut.box().s === 2, `zoom.ms 0: ${JSON.stringify(cut.box())}`);
  //    e. A planned click lands within half a pixel; the shake window is 100ms (t is seconds), and
  //       a click is never dropped as shake.
  const cur = new Cursor(100, 100, 1280, 720), press = cur.click(0, 900, 500);
  for (let t = 0; t < press - 1e-9; t += FI) cur.step(t, Math.min(FI, press - t));
  assert.ok(Math.hypot(cur.x.x - 900, cur.y.x - 500) < 0.5 && press >= 0.5, `click planned at ${press}s lands ${JSON.stringify(cur.pos())}`);
  const sh = new Cursor(0, 0, 1280, 720);
  assert.deepEqual([sh.aim(0, 10, 10), sh.aim(0.05, 5, 5), sh.aim(0.3, 0, 0)], [true, false, true], 'shake window is not 100ms');
  sh.aim(1, 10, 10); assert.ok(sh.click(1.05, 5, 5) > 1.05, 'a click reversing a tiny move was dropped as shake');

  // 3. Main take (deterministic, the default): zoom, marks, scoped click, wait out the splash.
  const r = await capture({ base, out, chapter: 'main', beats: [
    { goto: '/a' },
    { mark: { label: 'nav', on: 'nav.fixed.bottom-0' } },
    { zoom: { on: 'nav.fixed.bottom-0', scale: 2, ms: 500 }, mark: { label: 'zoomed', on: 'nav.fixed.bottom-0' }, hold: 1000 },
    { wide: 500 },
    { name: 'reports', click: 'nav.fixed.bottom-0 >> text=REPORTS', expectPath: '/b' },
  ] });
  const e = ev(r);
  for (const k of ['chapter', 'viewport', 'dpr', 'fps', 'capture', 'dur', 'frames', 'events']) assert.ok(k in e, `events.json missing ${k}`);
  assert.equal(e.capture.mode, 'deterministic', `main take fell back: ${e.capture.fallback}`);
  assert.equal(e.frames, r.frames);
  const z = e.events.find(m => m.label === 'zoomed');
  for (const m of e.events.filter(m => m.kind === 'mark')) for (const k of ['t', 'kind', 'label', 'rect', 'cam']) assert.ok(k in m, `event missing ${k}`);
  // Every camera move (zoom and wide) is logged with its span, so compose can play it at 1x.
  const moves = e.events.filter(m => m.kind === 'camera');
  assert.equal(moves.length, 2, `expected 2 camera events, got ${moves.length}`);
  // A sound cue per click, timed inside the take.
  const clicks = e.events.filter(m => m.kind === 'click');
  assert.ok(clicks.length === 1 && clicks[0].t > moves[1].t1 && clicks[0].t <= e.dur, `click cues ${JSON.stringify(clicks)}`);
  for (const m of moves) assert.ok(m.t1 - m.t0 >= 0.3, `camera event span ${m.t0}..${m.t1} too short for a 500ms spring`);
  assert.ok(moves[0].t1 <= z.t, 'zoom ended after the mark that follows it');
  assert.equal(z.cam.s, 2, 'zoom did not reach scale 2');
  // Page time and footage time agree through blurred frames: the 1s hold (the pointer parks, so its
  // frames are blurred) lasts 1s of footage. It once ran half a frame short per blurred frame.
  assert.ok(Math.abs(moves[1].t0 - z.t - 1) < 1.5 / 60, `1s hold filmed as ${(moves[1].t0 - z.t).toFixed(3)}s`);
  assert.ok(e.capture.blur.spans.some(([a, b]) => a >= z.t * 60 && b <= z.t * 60 + 60), `no blurred frames while the pointer parked: ${JSON.stringify(e.capture.blur.spans)}`);
  assert.ok(z.cam.y + z.cam.h >= z.rect.y + z.rect.h, 'zoom box does not frame the nav');
  // 2560x1440 at exactly 60fps, and the mp4 holds every frame: dur * 60 + 1.
  encode(r.dir, `${r.dir}.mp4`);
  const pm = probe(`${r.dir}.mp4`), n = +pm.nb_read_frames;
  assert.deepEqual([pm.width, pm.height, pm.avg_frame_rate], [2560, 1440, '60/1'], `main mp4 is ${JSON.stringify(pm)}`);
  assert.ok(Math.abs(n - (r.dur * 60 + 1)) < 1.001, `mp4 holds ${n} frames for a ${r.dur.toFixed(3)}s take`);
  // A '%' in the take's path: ffmpeg reads the cfr/ input as a %05d pattern, and an unescaped
  // "100%/" failed with "Error opening input file" (exit 254). Same take, copied under one.
  const pct = path.join(out, 'pct 100%', 'main');
  fs.cpSync(r.dir, pct, { recursive: true });
  encode(pct, `${pct}.mp4`);
  assert.equal(+probe(`${pct}.mp4`).nb_read_frames, n, `encode under a '%' path gave a different frame count`);
  const head = luma(frame(r, 0)), tail = luma(last(r));
  assert.ok(head > 60 && head < 140, `first frame is blank/splash (luma ${head})`);
  assert.ok(tail > 60 && tail < 140, `last frame is still the splash (luma ${tail})`);

  // 4. Animated page: every frame is new (no repeats), 60fps exactly, frame count = dur * 60 + 1.
  const an = await capture({ base, out, chapter: 'anim', beats: [{ goto: '/anim', hold: 1500 }] });
  encode(an.dir, `${an.dir}.mp4`);
  const md5 = execFileSync(FFMPEG, ['-v', 'error', '-i', `${an.dir}.mp4`, '-f', 'framemd5', '-']).toString()
    .split('\n').filter(l => /^\d/.test(l)).map(l => l.split(',').at(-1).trim());
  const repeats = md5.filter((h, i) => i && h === md5[i - 1]).length;
  assert.equal(repeats, 0, `${repeats} repeated frames on an animated page`);
  assert.ok(Math.abs(md5.length - (an.dur * 60 + 1)) < 1.001 && an.dur >= 1.9, `anim: ${md5.length} frames for ${an.dur}s`);

  // 5. Requests that hold virtual time. A dynamic import() never lets pauseIfNetworkFetchesPending
  //    expire (measured, even for an instant module): the default network 'auto' forces that frame
  //    through and the take stays deterministic with latency edited out elsewhere. A stream that
  //    never ends holds it at every frame: 'auto' films on with page time running regardless and
  //    says so; 'pause' instead falls back to screencast, says so once, and records the mode it used.
  const lz = await capture({ base, out, chapter: 'lazy', capture: NB, beats: [{ goto: '/lazy' }, { click: '#go', ready: 'body[style*="rgb(255, 255, 255)"]', hold: 300 }] });
  assert.deepEqual([lz.mode, ev(lz).capture.network], ['deterministic', 'pause'], `lazy import: ${JSON.stringify(ev(lz).capture)}`);
  assert.ok(luma(last(lz)) > 200, 'lazy module never loaded');
  const warned = []; const warn = console.warn; console.warn = (...a) => { warned.push(a.join(' ')); };
  let fb, ss;
  try {
    ss = await capture({ base, out, chapter: 'sse-auto', capture: NB, beats: [{ goto: '/sse', hold: 600 }] });
    fb = await capture({ base, out, chapter: 'sse', capture: { stallMs: 3000, network: 'pause' }, beats: [{ goto: '/sse', hold: 600 }] });
  } finally { console.warn = warn; }
  assert.deepEqual([ss.mode, ev(ss).capture.network], ['deterministic', 'advance'], `SSE under auto: ${JSON.stringify(ev(ss).capture)}`);
  assert.match(ev(ss).capture.networkNote, /eventsource request to .*\/stream never finished/);
  assert.equal(fb.mode, 'screencast');
  assert.match(ev(fb).capture.fallback, /stalled.*eventsource request to .*\/stream/, `fallback cause ${ev(fb).capture.fallback}`);
  assert.equal(warned.filter(w => /re-filming it in screencast mode/.test(w)).length, 1, `fallback message: ${JSON.stringify(warned)}`);
  assert.equal(warned.filter(w => /page time running regardless of the network/.test(w)).length, 1, `auto message: ${JSON.stringify(warned)}`);

  // 5b. A fallback while a blur job is still averaging: jobs are killed and awaited before the
  //     re-film wipes the directory. Before, a job finishing late threw ENOENT, uncaught, and took
  //     node down, or could write a stray PNG into the new take. Event-driven: the first job's
  //     ffmpeg stand-in marks `started` and waits; the test then kills the browser, which forces
  //     the fallback with that job in flight. `finished` must never appear (the job was killed).
  const zz = [{ goto: '/plain' }];
  for (let i = 0; i < 4; i++) zz.push({ zoom: { on: '#z', scale: 2.5, ms: 400 } }, { wide: 400 });
  const marks = fs.mkdtempSync(path.join(out, 'marks-'));
  console.warn = () => {};
  const ffPrev = process.env.FFMPEG; process.env.FFMPEG = ffStandIn('stall', marks);
  let mb;
  try {
    const filming = capture({ base, out, chapter: 'midblur', beats: zz });
    filming.catch(() => {});                               // an early reject fails the assert below, not node
    for (let i = 0; i < 1200 && !fs.existsSync(path.join(marks, 'started')); i++) await new Promise(r => setTimeout(r, 100));
    assert.ok(fs.existsSync(path.join(marks, 'started')), 'no blur job started');
    for (const pid of execFileSync('pgrep', ['-P', String(process.pid), '-f', 'headless']).toString().trim().split('\n')) process.kill(+pid, 'SIGKILL');
    // The browser's death itself must end the take (the disconnect handler), re-film included,
    // well inside 30 s: without it the frame loop hangs on a dead CDP call until the hard timeout.
    let late;
    mb = await Promise.race([filming, new Promise((_, rej) => { late = setTimeout(() => rej(new Error('the take did not end within 30 s of the browser dying')), 30000); })]);
    clearTimeout(late);
    await new Promise(r => setTimeout(r, 2000));            // room for a late job to misbehave
  } finally { console.warn = warn; if (ffPrev === undefined) delete process.env.FFMPEG; else process.env.FFMPEG = ffPrev; }
  const left = fs.readdirSync(path.join(mb.dir, 'cfr')).filter(f => !f.endsWith('.jpg'));
  assert.ok(mb.mode === 'screencast' && !fs.existsSync(path.join(marks, 'finished')) && !left.length && !fs.existsSync(path.join(mb.dir, 'sub')),
    `fallback with a blur job in flight: mode ${mb.mode} (${ev(mb).capture.fallback}), job finished ${fs.existsSync(path.join(marks, 'finished'))}, stray ${left.slice(0, 3)}`);
  //    And it fell back for that reason, not a generic failure.
  assert.match(ev(mb).capture.fallback, /browser exited mid-take/, `fallback cause ${ev(mb).capture.fallback}`);

  // 6. Motion blur only where something moves: the camera is the only mover in this take (no
  //    clicks, no marks), so every blurred frame sits inside a camera move.
  const bl = await capture({ base, out, chapter: 'blur', beats: [{ goto: '/plain', hold: 500 }, { zoom: { on: '#z', scale: 2, ms: 500 }, hold: 500 }, { wide: 500, hold: 500 }] });
  const be = ev(bl), spans = be.capture.blur.spans, mv = be.events.filter(m => m.kind === 'camera').map(m => [m.t0 * 60, m.t1 * 60]);
  assert.ok(spans.length >= 2, `expected blur on both camera moves, got ${JSON.stringify(spans)}`);
  for (const [a, b] of spans) assert.ok(mv.some(([u, v]) => a >= u - 1 && b <= v + 1), `blurred frames ${a}-${b} outside the camera moves ${JSON.stringify(mv)}`);
  //    The sample count follows the motion over the shutter: neighbouring samples never sit more
  //    than `spacing` (1.5) output px apart, and every camera frame gets the gap fill. Capped at 6
  //    samples, the same move has wider gaps, still filled.
  const bb = be.capture.blur;
  assert.ok(bb.maxGap > 0 && bb.maxGap <= 1.5 && bb.maxSamples > 6 && bb.filled > 0, `blur sampling ${JSON.stringify(bb)}`);
  const capped = ev(await capture({ base, out, chapter: 'blur-capped', capture: { blur: { max: 6 } }, beats: [{ goto: '/plain', hold: 300 }, { zoom: { on: '#z', scale: 2, ms: 500 } }] })).capture.blur;
  assert.ok(capped.maxSamples === 6 && capped.maxGap > 1.5 && capped.filled > 0, `capped blur ${JSON.stringify(capped)}`);
  //    A blur job that fails must fail the take, at once: its error used to be dropped, leaving a
  //    hole in cfr/ that encode.sh read as the end of the take (cut short, exit 0). Two ways:
  //    ffmpeg failing outright, and ffmpeg exiting 0 for one frame without writing it.
  const ff = process.env.FFMPEG;
  try {
    process.env.FFMPEG = '/bin/false';
    await assert.rejects(capture({ base, out, chapter: 'blur-fails', beats: [{ goto: '/plain', hold: 200 }, { zoom: { on: '#z', scale: 2, ms: 300 } }] }), /motion blur averaging failed/);
    process.env.FFMPEG = ffStandIn('nowrite', fs.mkdtempSync(path.join(out, 'marks-')));
    await assert.rejects(capture({ base, out, chapter: 'blur-gap', beats: [{ goto: '/plain', hold: 200 }, { zoom: { on: '#z', scale: 2, ms: 300 } }] }), /wrote no frame|is missing/);
  } finally { if (ff === undefined) delete process.env.FFMPEG; else process.env.FFMPEG = ff; }

  // 7. Holds must keep producing frames (screencast only emits on repaint).
  const h = await capture({ base, out, chapter: 'hold', capture: SC, beats: [{ goto: '/a', hold: 2500 }] });
  assert.ok(h.frames >= 30, `2.5s hold produced only ${h.frames} frames`);

  // 8. Zoom after scroll frames the target (override viewport is document-relative; under
  //    deterministic capture its x/y are device pixels too).
  const zl = {};
  for (const [m, c] of [['det', NB], ['sc', SC]]) {
    const sz = await capture({ base, out, chapter: `scrollzoom-${m}`, capture: c, beats: [{ goto: '/tall' }, { scroll: 1700 }, { zoom: { on: '#w', scale: 2, ms: 400 }, hold: 800 }] });
    zl[m] = luma(last(sz));
    assert.ok(zl[m] > 200, `${m}: zoom after scroll missed the target (luma ${zl[m]})`);
  }

  // 9. A bare-text mis-click must fail the take (and never falls back: it is not a capture problem).
  await assert.rejects(capture({ base, out, chapter: 'wrong', beats: [
    { goto: '/a' }, { name: 'bare', click: 'text=REPORTS', expectPath: '/b' }] }), /expected path \/b, got \/news/);

  // 10. Overlay: one cursor per page even with an iframe, mounts in a sandboxed document where
  //     storage throws, and every click restarts the feedback (one ring animation, from its start).
  const browser = await chromium.launch();
  let ripple, sandboxErrs;
  try {
    const page = await browser.newPage();
    await page.addInitScript(overlay, { ls: { k: 'v' }, hidden: false, ringColor: '#ff0000' });
    await page.goto(`${base}/frame`); await page.frames()[1].waitForLoadState();
    const cursors = (await Promise.all(page.frames().map(f => f.locator('#__cur').count()))).reduce((a, b) => a + b);
    assert.equal(cursors, 1, `expected 1 cursor across ${page.frames().length} frames, got ${cursors}`);

    const errs = []; page.on('pageerror', e => errs.push(e.message));
    await page.goto(`${base}/sandboxed`);
    assert.equal(await page.locator('#__cur').count(), 1, 'cursor did not mount in a sandboxed document');
    sandboxErrs = errs.length;
    assert.equal(sandboxErrs, 0, `init script threw: ${errs}`);

    await page.goto(`${base}/news`);
    ripple = [];
    for (const x of [300, 500, 700]) {
      await page.mouse.click(x, 300); await page.waitForTimeout(100);
      ripple.push(await page.evaluate(() => { const r = document.getElementById('__ring'), a = r.getAnimations();
        return [a.length, a[0] ? Math.round(a[0].currentTime / 100) : -1, r.style.left]; }));
    }
    assert.equal(await page.evaluate(() => getComputedStyle(document.getElementById('__ring')).borderTopColor), 'rgb(255, 0, 0)', 'click ring ignores cursor.ring');
    assert.deepEqual(ripple.map(r => r.slice(0, 2)), [[1, 1], [1, 1], [1, 1]], `ring animations per click ${JSON.stringify(ripple)}`);
  } finally { await browser.close(); }

  // 11. type beat types key by key on the take's clock (fill() would finish in one frame), and a
  //     hidden cursor still keeps a screencast hold emitting frames.
  const ty = {};
  for (const [m, c] of [['det', NB], ['sc', SC]]) {
    const t = await capture({ base, out, chapter: `type-${m}`, capture: c, cursor: { hidden: true }, beats: [{ goto: '/type' }, { type: { into: '#q', text: 'ferry times', cps: 10 } }, { hold: 1500 }] });
    ty[m] = [t.dur, luma(last(t))];
    const cue = ev(t).events.find(x => x.kind === 'type');
    assert.ok(cue && cue.chars === 11 && cue.dur > 1.0, `${m}: type cue ${JSON.stringify(cue)}`);
    assert.ok(ty[m][1] > 200, `${m}: typed text did not land (luma ${ty[m][1]})`);
    assert.ok(t.dur > 1.0 + 1.5, `${m}: type beat too fast for 11 chars at 10 cps (${t.dur.toFixed(2)}s)`);
    assert.ok(t.frames >= 30, `${m}: hidden-cursor take produced only ${t.frames} frames`);
  }

  // 12. pace scales holds: the same 1s hold at pace 2 films about twice as long.
  const p1 = await capture({ base, out, chapter: 'pace1', beats: [{ goto: '/a', hold: 1000 }] });
  const p2 = await capture({ base, out, chapter: 'pace2', pace: 2, beats: [{ goto: '/a', hold: 1000 }] });
  assert.ok(Math.abs(p2.dur - p1.dur - 1.5) < 0.05, `pace 2 did not add 1.5s (the 1s hold and the 0.5s tail, once more; the first settle is before filming) (${p1.dur.toFixed(2)}s vs ${p2.dur.toFixed(2)}s)`);

  // 13. A dead session on an app that sends logged-out users to /welcome must be re-minted when
  //     loggedInSel is set; without it the probe only checks "not on /login" and wrongly reuses it.
  const state = path.join(out, 'state.json');
  fs.writeFileSync(state, JSON.stringify({ cookies: [], origins: [] }));
  const login = { email: 'a@example.test', password: 'x' };
  assert.equal(await ensureState({ base, state, login }), 'reused');
  fs.writeFileSync(state, JSON.stringify({ cookies: [], origins: [] }));
  assert.equal(await ensureState({ base, state, login: { ...login, loggedInSel: '#me' } }), 'minted');
  assert.equal(await ensureState({ base, state, login: { ...login, loggedInSel: '#me' } }), 'reused');

  // 14. The cursor keeps its size under a zoom: white pixels (only the cursor is white on /plain)
  //     in a zoomed hold vs an unzoomed one. Screencast measured 1.00-1.34 with the counter-scale,
  //     5.14 without. And still after a click navigates while zoomed: the new page's overlay reads
  //     the counter-scale at mount (5.10 when it did not).
  const white = img => yavg(img, "format=gray,lutyuv=y='if(gt(val,200),255,0)',");
  // cursor area in a take's last frame over its area just before the take's first camera move
  const growth = t => {
    const e = ev(t), mv = e.events.find(m => m.kind === 'camera');
    const before = white(frame(t, Math.floor((mv.t0 - 0.15) * e.fps)));
    assert.ok(before > 0, `${t.dir}: no cursor before the zoom`);
    return white(last(t)) / before;
  };
  const cs = {};
  for (const [m, c] of [['det', NB], ['sc', SC]]) {
    cs[m] = [growth(await capture({ base, out, chapter: `counter-${m}`, capture: c, beats: [{ goto: '/plain', hold: 700 }, { zoom: { on: '#z', scale: 2, ms: 300 }, hold: 700 }] })),
      growth(await capture({ base, out, chapter: `counter-nav-${m}`, capture: c, beats: [{ goto: '/plain', hold: 700 },
        { zoom: { on: '#z', scale: 2, ms: 300 } }, { name: 'go', click: '#go', expectPath: '/plain2', hold: 700 }] }))];
    for (const v of cs[m]) assert.ok(v > 0.6 && v < 1.6, `${m}: cursor ${v.toFixed(2)}x its unzoomed size under a 2x zoom (want ~1): ${cs[m]}`);
  }

  const f2 = v => v.toFixed(2);
  console.log(`selfcheck OK: springs ${JSON.stringify(springs)}; pre-aim holds the fixed point; retarget keeps velocity; settles exact; ms 0 cuts; click lands at ${press.toFixed(3)}s; shake 100ms`);
  console.log(`selfcheck OK: main ${r.frames} frames/${r.dur.toFixed(2)}s 2560x1440@60 mp4 ${n} frames luma head ${head} tail ${tail}; anim ${md5.length} frames 0 repeats; blur spans ${JSON.stringify(spans)} inside camera moves, up to ${bb.maxSamples} samples ${bb.maxGap}px apart, capped run filled ${capped.filled} frames`);
  console.log(`selfcheck OK: lazy import stays deterministic; SSE runs on under auto, falls back to ${fb.mode} under pause, one message each; screencast hold ${h.frames} frames; scroll-zoom luma ${zl.det}/${zl.sc}; guard threw`);
  console.log(`selfcheck OK: cursor under 2x zoom det ${cs.det.map(f2)} sc ${cs.sc.map(f2)} (zoomed, after nav); ring per click ${JSON.stringify(ripple)}; type det ${f2(ty.det[0])}s sc ${f2(ty.sc[0])}s; pace ${f2(p1.dur)}s -> ${f2(p2.dur)}s; loggedInSel re-mints; sandbox errors ${sandboxErrs}`);
} finally {
  server.close(); fs.rmSync(out, { recursive: true, force: true });
}

#!/usr/bin/env node
// ABOUTME: One runnable self-check for the rig, against a throwaway local server
// (no app, no login). Exits non-zero if the core capture logic breaks.
// Usage: node selfcheck.mjs   (or `npm run check` from the skill dir)
import http from 'http'; import fs from 'fs'; import os from 'os'; import path from 'path';
import assert from 'assert/strict'; import { execFileSync, execFile, spawn } from 'child_process'; import { fileURLToPath } from 'url';
import { chromium } from '@playwright/test';
import { capture, checkPath, ensureState, overlay, blurArgs, poser, timeoutFor } from './capture.mjs';
import { inventory } from './locate.mjs';
import { Camera, Cursor, spring1d, CAMERA, CURSOR, SNAPPY } from './motion.mjs';
import { narrativeLint, composeFor } from './narrative.mjs';

const BG = '#3a6ea5';                             // luma ~100: neither blank white nor splash black
const nav = `<nav class="fixed bottom-0" style="position:fixed;bottom:0;left:0;right:0;height:64px;background:#222;display:flex;gap:40px;justify-content:center;align-items:center">
  <a href="/b" style="color:#fff">REPORTS</a><a href="/a" style="color:#fff">HOME</a></nav>`;
const pages = {
  // A headline sharing the nav's text: bare `text=REPORTS` hits this first.
  '/a': `<body style="margin:0;background:${BG};height:100vh"><h1><a href="/news" style="color:#fff">REPORTS show a record season</a></h1>${nav}</body>`,
  // Tall page with a white block (bigger than the 2x camera box) far below the fold: zooming on it after a scroll must film it.
  '/tall': `<body style="margin:0;background:${BG};height:3000px"><div id="w" style="position:absolute;top:2000px;left:290px;width:700px;height:400px;background:#fff"></div></body>`,
  '/news': `<body style="background:${BG}">news</body>`,
  // A target inside the window but under a fixed bottom bar, as an app's bottom nav covers content.
  '/covered': `<body style="margin:0;background:${BG};height:2000px"><div id="t" style="position:absolute;top:600px;left:290px;width:700px;height:80px;background:#fff"></div><div style="position:fixed;bottom:0;left:0;right:0;height:140px;background:#333"></div></body>`,
  // Re-renders its buttons every 20ms, as a polling dashboard does: an inventory walk meets nodes
  // that are gone by the time it asks about them.
  '/swap': `<body style="margin:0;background:${BG};height:100vh"><div id="list"></div><script>const r = () => document.getElementById('list').innerHTML = Array.from({ length: 60 }, (_, i) => '<button>Item ' + i + '</button>').join(''); r(); setInterval(r, 20)</script></body>`,
  // Plain page with an invisible zoom target: the only white pixels in a frame are the cursor's.
  // #go fills the zoom target, so a click on it navigates while the camera is zoomed.
  '/plain': `<body style="margin:0;background:${BG};height:100vh"><div id="z" style="position:absolute;left:440px;top:260px;width:400px;height:200px"><a id="go" href="/plain2" style="position:absolute;inset:0"></a></div></body>`,
  '/plain2': `<body style="margin:0;background:${BG};height:100vh"></body>`,
  '/frame': `<body style="margin:0;background:${BG};height:100vh"><iframe src="/news" width="400" height="200"></iframe></body>`,
  // Fields for the type cue's rect: one widens as it fills, one hides once it holds "go".
  '/grow': `<body style="margin:0;background:${BG};height:100vh"><input id="g" placeholder="Search sailings" style="position:absolute;left:100px;top:100px;width:100px;box-sizing:border-box" oninput="this.style.width = (100 + this.value.length * 20) + 'px'"></body>`,
  '/hide': `<body style="margin:0;background:${BG};height:100vh"><input id="h" placeholder="short" aria-label="Departure port for the outbound crossing you want" style="position:absolute;left:100px;top:100px" oninput="if (this.value === 'go') this.style.display = 'none'"></body>`,
  // A button named only by its image's alt text.
  '/imgbtn': `<body style="margin:0;background:${BG};height:100vh"><button id="b" style="position:absolute;left:100px;top:200px"><img alt="Save" width="24" height="24" src="data:image/gif;base64,R0lGODlhAQABAAAAACw="></button></body>`,
  // A full-page modal that a seeded localStorage key removes, over the button a beat clicks.
  '/consent': `<body style="margin:0;background:${BG};height:100vh"><button id="go" style="margin:200px">go</button><div id="modal" style="position:fixed;inset:0;background:#000"></div><script>if (localStorage.getItem('consent') === 'yes') document.getElementById('modal').remove()</script></body>`,
  // Two navigations with a link of the same name, and a search field beside a text field.
  '/navs': `<body style="margin:0;background:${BG};height:100vh"><header><nav><a href="#h">Home</a></nav></header><input type="search" id="s" aria-label="Find"><input id="t" aria-label="Name"><footer><nav><a href="#f">Home</a></nav></footer></body>`,
  // A second "Go" button appears once the pointer nears the first (mid-glide, after the target
  // resolved; the pointer parks at the centre before that).
  '/dup': `<body style="margin:0;background:${BG};height:100vh"><button style="margin:200px">Go</button><script>addEventListener('mousemove', e => { if (e.clientX > 50 && e.clientX < 450 && document.querySelectorAll('button').length < 2) document.body.insertAdjacentHTML('beforeend', '<button>Go</button>'); })</script></body>`,
  // Turns white once the input holds exactly the typed text: the last frame proves the type beat.
  '/type': `<body style="margin:0;background:${BG};height:100vh"><input id="q" style="margin:200px;font-size:30px" oninput="if (this.value === 'ferry times') document.body.style.background = '#fff'"></body>`,
  // A login form, and a home page that sends logged-out visitors to /welcome, not to /login.
  // A login whose session the server can revoke: /logout2 ends it server-side, as real apps do.
  '/login2': `<body><input id="email"><input id="password" type="password"><button onclick="const s = Math.random().toString(36).slice(2); fetch('/grant?sid=' + s).then(() => { document.cookie = 'sid2=' + s + ';path=/'; location = '/home2' })">Log in</button></body>`,
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
  // A target taller than the window, under a fixed bottom bar: only its top part is on screen and clear.
  '/tallbar': `<body style="margin:0;background:${BG};height:2000px"><div id="t" style="position:absolute;top:100px;left:290px;width:700px;height:900px;background:#fff"></div><div style="position:fixed;bottom:0;left:0;right:0;height:140px;background:#333"></div></body>`,
  '/lazy': `<body style="margin:0;background:${BG};height:100vh"><button id="go" style="margin:200px" onclick="import('/mod.js').then(m => document.body.style.background = m.c)">go</button></body>`,
};
const sessions = new Set();
const server = http.createServer((req, res) => {
  if (req.url.startsWith('/grant?')) { sessions.add(new URL(req.url, base).searchParams.get('sid')); return res.end('ok'); }
  if (req.url === '/home2' || req.url === '/logout2') {
    const sid = (req.headers.cookie || '').match(/sid2=(\w+)/)?.[1];
    res.setHeader('content-type', 'text/html');
    if (req.url === '/logout2') { sessions.delete(sid); return res.end('<body>signed out</body>'); }
    if (!sessions.has(sid)) { res.writeHead(302, { location: '/welcome' }); return res.end(); }
    return res.end('<body><div id="me">signed in</div></body>');
  }
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
// An ffmpeg stand-in for capture's blur jobs (the only calls with mix=inputs): every other call, and
// every job after the first, runs the real ffmpeg. For the first job, `nowrite` exits 0 without
// writing its frame; `stall` marks `started`, waits, then marks `finished` and runs.
const ffStandIn = (mode, marks) => {
  const f = path.join(marks, `ffmpeg-${mode}.sh`);
  fs.writeFileSync(f, `#!/bin/sh
case "$*" in *mix=inputs=*) ;; *) exec "${FFMPEG}" "$@";; esac
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

  // 2b. Narrative lint, on the timeline the beats will film (no browser): a still hold over 2s with
  //     no mark, a first mark after 3s, narration over 160 wpm until the next mark, and more than
  //     5 chapters each warn; a tight chapter does not.
  const slow = { name: 'slow', beats: [{ goto: '/', hold: 2500 }, { click: 'x' }, { zoom: { on: 'y', ms: 800 }, mark: { label: 'Late', on: 'y' }, hold: 1500 },
    { zoom: { on: 'z' }, mark: { label: 'Cars', on: 'z' } }] };
  const tight = { name: 'tight', beats: [{ goto: '/' }, { zoom: { on: 'y' }, mark: { label: 'Late', on: 'y' }, hold: 1500 }] };
  const said = { chapters: [{ name: 'slow', narration: { marks: ['one two three four five six seven eight nine ten {@x}eleven twelve', null] } },
    { name: 'tight', narration: { marks: ['the next sailing is late'] } }] };
  const nl = narrativeLint({ chapters: [slow, tight] }, said);
  for (const re of [/slow: beat "#0" holds 2.5s with no mark/, /slow: first mark \("Late"\) at about 4.2s/, /slow: narration for "Late" runs 327 wpm over the 2.2s/])
    assert.ok(nl.some(w => re.test(w)), `narrative lint missed ${re}: ${JSON.stringify(nl)}`);
  assert.ok(!nl.some(w => /^tight:/.test(w)), `narrative lint flagged a tight chapter: ${JSON.stringify(nl)}`);
  //     Typing on screen fills a sparse line's window: 4 words over the 4s before the next mark
  //     warn as slow, but not when that window is mostly typing.
  const sparse = (typed) => narrativeLint({ chapters: [{ name: 's', beats: [{ goto: '/' }, { zoom: { on: 'y' }, mark: { label: 'A', on: 'y' }, hold: 1000 },
    typed ? { type: { into: 'q', text: 'ferry times to the island', cps: 12 } } : { hold: 2500 }, { mark: { label: 'B', on: 'z' } }] }] },
    { chapters: [{ name: 's', narration: { marks: ['one two three four', null] } }] }).filter(w => /runs \d+ wpm/.test(w));
  assert.ok(sparse(false).length === 1 && sparse(true).length === 0, `slow narration rule with/without typing: ${JSON.stringify([sparse(false), sparse(true)])}`);
  //     A compose config the beats file names but that is not there, or not JSON, is said, with its path.
  assert.throws(() => composeFor({ compose: './nope.json' }, path.join(out, 'b.mjs')), /compose: \.\/nope\.json \(from the beats file\) is not there/);
  fs.writeFileSync(path.join(out, 'bad.json'), '{ nope');
  assert.throws(() => composeFor({ compose: './bad.json' }, path.join(out, 'b.mjs')), /bad\.json is not valid JSON/);
  assert.ok(narrativeLint({ chapters: Array.from({ length: 6 }, (_, i) => ({ ...tight, name: `c${i}` })) }).some(w => /^6 chapters/.test(w)), 'six chapters not flagged');

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
  //    It carries its target's rect (CSS px, as a mark's) and the camera box (wide here): the
  //    REPORTS link, inside the nav the first mark measured.
  const nav = e.events.find(m => m.label === 'nav').rect, cr = clicks[0].rect;
  assert.ok(cr && cr.w > 0 && cr.h > 0 && cr.x >= nav.x && cr.y >= nav.y && cr.x + cr.w <= nav.x + nav.w && cr.y + cr.h <= nav.y + nav.h && 'cam' in clicks[0] && clicks[0].cam === null,
    `click rect ${JSON.stringify(clicks[0])} not inside the nav ${JSON.stringify(nav)}`);
  //    And its accessible name and role, so the walkthrough can say "Open REPORTS".
  assert.ok(clicks[0].name === 'REPORTS' && clicks[0].role === 'link', `click name/role ${JSON.stringify(clicks[0])}`);
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
  //    A hidden pointer that moves (parking by a mark through its hold) blurs nothing.
  const hidBlur = ev(await capture({ base, out, chapter: 'blur-hidden', cursor: { hidden: true },
    beats: [{ goto: '/plain', hold: 300 }, { mark: { label: 'z', on: '#z' }, hold: 500 }] })).capture.blur;
  assert.deepEqual(hidBlur.spans, [], `a hidden pointer was blurred: ${JSON.stringify(hidBlur)}`);
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

  // 8b. Scroll to a target: it ends inside the viewport (a dialog's content the window cannot reach
  //     works the same way), and a target already fully in view is not scrolled at all.
  const markRect = async (chapter, beats) => ev(await capture({ base, out, chapter, capture: SC, beats })).events.find(e => e.kind === 'mark').rect;
  const far = await markRect('scrollto', [{ goto: '/tall' }, { scroll: '#w' }, { mark: { label: 'w', on: '#w' } }]);
  assert.ok(far.y >= 0 && far.y + far.h <= 720, `scroll to #w left it outside the viewport (y ${far.y}, h ${far.h})`);
  const near = await markRect('scrollto-visible', [{ goto: '/tall' }, { scroll: 1700 }, { scroll: '#w' }, { mark: { label: 'w', on: '#w' } }]);
  assert.equal(Math.round(near.y), 300, `scroll to an already visible #w moved the page (y ${near.y}, expected 300)`);
  // A target inside the window but under a fixed bar counts as covered and is scrolled clear of it.
  const cov = await markRect('scrollto-covered', [{ goto: '/covered' }, { scroll: '#t' }, { mark: { label: 't', on: '#t' } }]);
  assert.ok(cov.y + cov.h <= 720 - 140, `scroll to #t left it under the fixed bar (y ${cov.y}, h ${cov.h}; the bar starts at 580)`);

  // 9. A bare-text mis-click must fail the take (and never falls back: it is not a capture problem).
  await assert.rejects(capture({ base, out, chapter: 'wrong', beats: [
    { goto: '/a' }, { name: 'bare', click: 'text=REPORTS', expectPath: '/b' }] }), /expected path \/b, got \/news/);

  // 9b. Locator chains: the first entry that finds exactly one visible element wins, and
  //     events.json records which. A chain that finds nothing fails the take at once, naming each
  //     entry with what it found and the nearest candidates on the page, and writes no events.json.
  const lc = await capture({ base, out, chapter: 'chain', capture: SC, cursor: { hidden: true }, beats: [
    { goto: '/a' }, { name: 'nav', click: [{ testid: 'reports' }, { role: 'link', name: 'REPORTS' }], expectPath: '/b' }] });
  assert.deepEqual(ev(lc).targets.find(t => t.use === 'click'), { beat: 'nav', use: 'click', matched: 'role=link[name="REPORTS"]', index: 1, of: 2 }, `chain match ${JSON.stringify(ev(lc).targets)}`);
  await assert.rejects(capture({ base, out, chapter: 'chain-miss', capture: SC, beats: [{ goto: '/a' }, { name: 'nav', click: [{ role: 'link', name: 'REPORT' }, { testid: 'reports' }] }] }),
    e => /beat "nav": click .*Tried role=link\[name="REPORT"\] \(0 visible\), testid=reports \(0 visible\)\. Nearest on the page: .*link "REPORTS"/.test(e.message) || assert.fail(`miss message: ${e.message}`));
  assert.ok(!fs.existsSync(path.join(out, 'chain-miss', 'events.json')), 'a take that missed a target wrote events.json');
  //     The dry run (run.mjs --dry-run) resolves every target with no frames: exit 0 on a good beats
  //     file, 1 naming the beat on a broken one; and a plain run dry-runs first, so a broken file
  //     films nothing. Async: a blocking spawn would stall this process's own server.
  const node = args => new Promise(res => execFile(process.execPath, args, { encoding: 'utf8' }, (err, stdout, stderr) => res({ status: err ? err.code : 0, out: stdout + stderr })));
  const runMjs = path.join(path.dirname(fileURLToPath(import.meta.url)), 'run.mjs');
  const beatsFile = (name, chapters) => { const f = path.join(out, `${name}.beats.mjs`); fs.writeFileSync(f, `export default ${JSON.stringify({ base, out: path.join(out, name), chapters })};`); return f; };
  const good = beatsFile('dry-good', [{ name: 'c', beats: [{ goto: '/a', ready: { role: 'navigation' } }, { name: 'nav', click: { role: 'link', name: 'REPORTS' }, expectPath: '/b' }] }]);
  const broken = beatsFile('dry-broken', [{ name: 'c', beats: [{ goto: '/a' }, { name: 'gone', click: { role: 'button', name: 'Export' } }] }]);
  let dr = await node([runMjs, good, '--dry-run']);
  assert.ok(dr.status === 0 && /1 chapter\(s\), 2 target\(s\) resolved, 0 miss/.test(dr.out), `dry run on a good file: exit ${dr.status}\n${dr.out}`);
  dr = await node([runMjs, broken, '--dry-run']);
  assert.ok(dr.status === 1 && /MISS beat "gone": click/.test(dr.out), `dry run on a broken file: exit ${dr.status}\n${dr.out}`);
  //     The dry run seeds localStorage like a take: the consent key removes the modal over #go.
  const consent = path.join(out, 'consent.beats.mjs');
  fs.writeFileSync(consent, `export default ${JSON.stringify({ base, out: path.join(out, 'consent'), localStorage: { consent: 'yes' }, chapters: [{ name: 'c', beats: [{ goto: '/consent' }, { name: 'go', click: '#go' }] }] })};`);
  dr = await node([runMjs, consent, '--dry-run']);
  assert.ok(dr.status === 0, `dry run with a seeded consent key: exit ${dr.status}\n${dr.out}`);
  //     The selector lint suggests only a locator that finds this very element: not the header's
  //     Home link for the footer's, and searchbox (its real role) for a search field.
  const navs = path.join(out, 'navs.beats.mjs');
  fs.writeFileSync(navs, `export default ${JSON.stringify({ base, out: path.join(out, 'navs'), chapters: [{ name: 'c', beats: [{ goto: '/navs' },
    { name: 'foot', mark: { label: 'home', on: 'footer a' } }, { name: 'find', mark: { label: 'find', on: '#s' } }] }] })};`);
  dr = await node([runMjs, navs, '--dry-run']);
  const lints = dr.out.split('\n').filter(l => /lint:/.test(l));
  assert.ok(dr.status === 0 && !lints.some(l => /beat "foot"/.test(l)) && lints.some(l => /beat "find".*\{ role: "searchbox", name: "Find" \}/.test(l)) && !lints.some(l => /textbox/.test(l)),
    `lint suggestions: ${JSON.stringify(lints)}`);
  //     A failure that is not a miss says what it is, plainly: no ANSI, no call log, counted apart.
  const wrongPath = beatsFile('dry-wrong', [{ name: 'c', beats: [{ goto: '/a' }, { name: 'bare', click: 'text=REPORTS', expectPath: '/b' }] }]);
  dr = await node([runMjs, wrongPath, '--dry-run']);
  assert.ok(dr.status === 1 && /FAIL Error: .*expected path \/b, got \/news/.test(dr.out) && !/\x1b\[|Call log/.test(dr.out) && /1 target\(s\) resolved, 0 miss\(es\), 1 other failure/.test(dr.out),
    `dry run on a failing (not missing) beat: exit ${dr.status}\n${dr.out}`);
  //     The dry run really clicks: a chapter that signs out revokes the session it used. run.mjs
  //     checks the session again after the dry run and re-mints it, so the take still films.
  const signout = path.join(out, 'signout.beats.mjs');
  fs.writeFileSync(signout, `export default ${JSON.stringify({ base, out: path.join(out, 'signout'), state: path.join(out, 'signout-state.json'), probe: '/home2',
    login: { email: 'a@example.test', password: 'x', loginPath: '/login2', loggedInSel: '#me' }, capture: { mode: 'screencast' },
    chapters: [{ name: 'c', beats: [{ goto: '/home2', ready: '#me' }, { goto: '/logout2' }] }] })};`);
  dr = await node([runMjs, signout]);
  assert.ok(dr.status === 0 && (dr.out.match(/session: minted/g) || []).length === 2, `a chapter that signs out: exit ${dr.status}\n${dr.out}`);
  dr = await node([runMjs, broken]);
  assert.ok(dr.status === 1 && !fs.existsSync(path.join(out, 'dry-broken')), `a broken file filmed: exit ${dr.status}\n${dr.out}`);
  //     And on the ferry example beside this skill, when it is there: green, in seconds.
  const ferry = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../compose/examples/ferry');
  let ferryDry = 'skipped (no compose example beside this skill)';
  if (fs.existsSync(path.join(ferry, 'beats.mjs'))) {
    const free = await new Promise(res => { const t = http.createServer().listen(0, () => { const p = t.address().port; t.close(() => res(p)); }); });
    const app = spawn(process.execPath, ['serve.mjs', String(free)], { cwd: ferry, stdio: ['ignore', 'pipe', 'inherit'] });
    try {
      const port = await new Promise((res, rej) => { setTimeout(() => rej(new Error('ferry app did not start in 15s')), 15000).unref(); app.stdout.on('data', d => { const m = String(d).match(/ferry on (\d+)/); if (m) res(m[1]); }); app.on('exit', () => rej(new Error('ferry app exited'))); });
      const t0 = Date.now();
      dr = await new Promise(res => execFile(process.execPath, [runMjs, 'beats.mjs', '--dry-run'], { cwd: ferry, encoding: 'utf8', env: { ...process.env, PORT: port } },
        (err, stdout, stderr) => res({ status: err ? err.code : 0, out: stdout + stderr })));
      ferryDry = `${((Date.now() - t0) / 1000).toFixed(1)}s`;
      assert.ok(dr.status === 0 && / 0 miss/.test(dr.out), `ferry dry run: exit ${dr.status}\n${dr.out}`);
    } finally { app.kill(); }
  }

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
    //  The field is at margin 200px: the type cue and the click it starts with carry its rect.
    const into = ev(t).events.find(x => x.kind === 'click');
    for (const c of [cue, into]) assert.ok(c.rect && c.rect.x === 200 && c.rect.y === 200 && c.rect.w > 0 && c.rect.h > 0 && 'cam' in c, `${m}: ${c.kind} rect ${JSON.stringify(c)}`);
    assert.ok(ty[m][1] > 200, `${m}: typed text did not land (luma ${ty[m][1]})`);
    assert.ok(t.dur > 1.0 + 1.5, `${m}: type beat too fast for 11 chars at 10 cps (${t.dur.toFixed(2)}s)`);
    assert.ok(t.frames >= 30, `${m}: hidden-cursor take produced only ${t.frames} frames`);
  }
  //  The type cue's rect is measured after the typing: a field that widens as it fills is pointed
  //  at as it ends up, and one that hides gets rect null (nothing to point at), not a stale box.
  const cues = async (pg, sel, text) => ev(await capture({ base, out, chapter: `cue-${pg.slice(1)}`, capture: SC, cursor: { hidden: true },
    beats: [{ goto: pg }, { type: { into: sel, text, cps: 20 } }, { hold: 200 }] })).events.filter(x => x.kind === 'click' || x.kind === 'type');
  const [gc, gt] = await cues('/grow', '#g', 'ferry'), [hc, ht] = await cues('/hide', '#h', 'go');
  assert.ok(gc.rect.w === 100 && gt.rect.w === 200, `widening field: click ${JSON.stringify(gc.rect)}, type ${JSON.stringify(gt.rect)}`);
  assert.ok(hc.rect && hc.rect.w > 0 && ht.rect === null, `hiding field: click ${JSON.stringify(hc.rect)}, type ${JSON.stringify(ht.rect)}`);
  //  Names: a placeholder names a field with no label; aria-label wins over it, cut under 40.
  assert.ok(gc.name === 'Search sailings' && gc.role === 'textbox' && gt.name === 'Search sailings', `placeholder name ${gc.name}/${gt.name}, role ${gc.role}`);
  assert.ok(hc.name === 'Departure port for the outbound\u2026' && hc.name.length < 40, `aria-label name ${JSON.stringify(hc.name)}`);
  //  A chain target on a field that hides as it is typed into: its type cue reads the rect through
  //  the handle pinned at resolve time, so it is null at once, not after Playwright's 30s wait
  //  for the chain's visible-only locator. And a button named by its image's alt text is named.
  let tq = Date.now();
  const hz = ev(await capture({ base, out, chapter: 'cue-hide-chain', capture: SC, cursor: { hidden: true },
    beats: [{ goto: '/hide' }, { type: { into: [{ placeholder: 'short' }, '#h'], text: 'go', cps: 20 } }, { hold: 200 }] })).events.find(x => x.kind === 'type');
  tq = (Date.now() - tq) / 1000;
  assert.ok(hz.rect === null && hz.name === hc.name && tq < 20, `hiding chain field: type cue ${JSON.stringify(hz)}, take ${tq.toFixed(1)}s`);
  const ib = ev(await capture({ base, out, chapter: 'cue-imgbtn', capture: SC, cursor: { hidden: true }, beats: [{ goto: '/imgbtn' }, { click: '#b' }, { hold: 200 }] })).events.find(x => x.kind === 'click');
  assert.ok(ib.name === 'Save' && ib.role === 'button', `img-alt button cue ${JSON.stringify(ib)}`);
  //  A second match appearing between resolving a target and clicking it is a miss naming the chain.
  await assert.rejects(capture({ base, out, chapter: 'dup', capture: SC, beats: [{ goto: '/dup' }, { name: 'go', click: { role: 'button', name: 'Go' } }] }),
    e => /beat "go": click target role=button\[name="Go"\] matched more than one visible element by the time it was clicked/.test(e.message) || assert.fail(`dup: ${e.message}`));
  //  A click while zoomed in screencast mode records its rect in the frame the camera box is in
  //  (CSS px from the scroll the zoom started at): #w at top 2000 after a 1700 scroll is at 300.
  const zc = ev(await capture({ base, out, chapter: 'zoom-click-sc', capture: SC, cursor: { hidden: true },
    beats: [{ goto: '/tall' }, { scroll: 1700 }, { zoom: { on: '#w', scale: 2, ms: 400 } }, { click: '#w' }, { hold: 200 }] })).events;
  const zck = zc.find(x => x.kind === 'click');
  assert.ok(zck && zck.cam?.s === 2 && JSON.stringify(zck.rect) === JSON.stringify({ x: 290, y: 300, w: 700, h: 400 }), `zoomed screencast click ${JSON.stringify(zck)}`);

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

  //     A take that signs out and then falls back re-films from a live session, not the one it
  //     revoked: the hard timeout trips after /logout2, and the screencast re-film still finds #me.
  const reState = path.join(out, 'refilm-state.json'), reLogin = { ...login, loginPath: '/login2', loggedInSel: '#me' };
  await ensureState({ base, state: reState, login: reLogin, probe: '/home2' });
  const refilm = ev(await capture({ base, out, chapter: 'refilm', state: reState, login: reLogin, probe: '/home2', capture: { timeoutMs: 4000, blur: false },
    beats: [{ goto: '/home2', ready: '#me' }, { goto: '/logout2', hold: 8000 }] }));
  assert.match(refilm.capture.fallback ?? '', /hard timeout/, `refilm take did not fall back: ${JSON.stringify(refilm.capture)}`);

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

  //     The default wall-time cap: 10 minutes for a short chapter, 120x the estimated footage for a long one.
  assert.equal(timeoutFor([{ goto: '/a', hold: 2000 }]), 600000, 'short chapter cap');
  assert.equal(timeoutFor([{ goto: '/a', hold: 19500 }]), 2400000, 'long chapter cap (20s of footage)');
  assert.equal(timeoutFor([{ goto: '/a', hold: 9500 }], 2), 2400000, 'cap follows pace');

  // 14. A mark's id lands on its event as written and is absent where the beat gave none; a
  //     numeric or repeated id fails before anything is filmed.
  const idMarks = ev(await capture({ base, out, chapter: 'markid', capture: SC, beats: [{ goto: '/a' },
    { mark: { id: '4.10', label: 'named', on: 'h1' } }, { mark: { label: 'plain', on: 'h1' } }] })).events.filter(e => e.kind === 'mark');
  assert.deepEqual(idMarks.map(m => m.id), ['4.10', undefined], `mark ids ${JSON.stringify(idMarks.map(m => m.id))}`);
  await assert.rejects(capture({ base, out, chapter: 'markid-num', capture: SC, beats: [{ goto: '/a' }, { mark: { id: 4.1, label: 'x', on: 'h1' } }] }), /must be a non-empty string/);
  await assert.rejects(capture({ base, out, chapter: 'markid-dup', capture: SC, beats: [{ goto: '/a' },
    { mark: { id: '1', label: 'x', on: 'h1' } }, { mark: { id: '1', label: 'y', on: 'h1' } }] }), /used twice/);
  //     A mark taller than the open area is boxed to the part on screen and clear of the fixed bar
  //     (top 100 to the bar at 580), flagged on its event, and named in a lint.
  const tall = ev(await capture({ base, out, chapter: 'markclip', capture: SC, beats: [{ goto: '/tallbar' }, { mark: { label: 't', on: '#t' } }] }))
    .events.find(e => e.kind === 'mark');
  assert.ok(tall.rect.y >= 100 && tall.rect.y + tall.rect.h <= 580, `tall mark not boxed to the open area: ${JSON.stringify(tall.rect)}`);
  assert.deepEqual(tall.clipped && tall.clipped.h, 900, `tall mark not flagged clipped: ${JSON.stringify(tall.clipped)}`);
  // 13. Inventory on a page that re-renders under it finishes, counting what it skipped instead of
  //     timing out on a vanished node; and the beats form runs without --state.
  let invSkipped;
  { const b = await chromium.launch(); try {
      const pg = await b.newPage(); await pg.goto(`${base}/swap`);
      const t0 = Date.now(), items = await inventory(pg);
      assert.ok(Date.now() - t0 < 60000, `inventory on /swap took ${Date.now() - t0}ms`);
      assert.ok(items.skipped > 0, 'inventory on /swap skipped no re-rendered node (the page did not swap under it)');
      invSkipped = `${items.length} kept, ${items.skipped} skipped`;
    } finally { await b.close(); } }
  const invBeats = path.join(out, 'inv.beats.mjs');
  fs.writeFileSync(invBeats, `export default { base: '${base}', out: '${out}', chapters: [{ name: 'inv', beats: [{ goto: '/a' }] }] };`);
  // Async: a sync child would block this process's own server, which the child needs.
  const invOut = await new Promise((res, rej) => execFile(process.execPath, [path.join(import.meta.dirname, 'inventory.mjs'), invBeats, 'inv'],
    (e, so, se) => (e ? rej(new Error(`inventory beats form failed: ${se || e.message}`)) : res(so))));
  assert.match(invOut, /targets on inv after beat/, `inventory beats form without --state: ${invOut.slice(0, 200)}`);

  // 15. Blur averaging survives a sub-frame with alpha among opaque ones (rig backlog R8): the
  //     averaged frame is written, opaque and the right size. As one tmix stream it was not.
  const bsub = path.join(out, 'blur-rgba'); fs.mkdirSync(bsub, { recursive: true });
  for (let k = 0; k < 6; k++) execFileSync(FFMPEG, ['-v', 'error', '-y', '-f', 'lavfi', '-i', `color=c=0x${(0x202020 + k * 0x101010).toString(16)}:s=64x40`,
    '-frames:v', '1', ...(k === 4 ? ['-vf', 'format=rgba,geq=r=r(X\\,Y):g=g(X\\,Y):b=b(X\\,Y):a=if(eq(Y\\,10)\\,128\\,255)', '-pix_fmt', 'rgba'] : ['-pix_fmt', 'rgb24']),
    path.join(bsub, `${String(k).padStart(2, '0')}.png`)]);
  const bout = path.join(out, 'blur-rgba.png');
  execFileSync(FFMPEG, blurArgs(bsub, 6, '', bout));
  assert.ok(fs.existsSync(bout), 'blur averaging wrote no frame for a sub-frame set with one rgba among rgb24');
  const bprobe = JSON.parse(execFileSync(FFPROBE, ['-v', 'error', '-show_entries', 'stream=width,height,pix_fmt', '-of', 'json', bout]).toString()).streams[0];
  assert.deepEqual([bprobe.width, bprobe.height, bprobe.pix_fmt], [64, 40, 'rgb24'], `blur average ${JSON.stringify(bprobe)}`);

  // 16. Overlapping poses never remove the same init script twice: a stand-in CDP that, like Chrome,
  //     fails "Script not found" on a second removal, and replies after a delay so calls overlap.
  { const scripts = new Set(); let next = 1;
    const cdp = { send: async (m, p) => {
      await new Promise(r => setTimeout(r, 5));
      if (m === 'Page.addScriptToEvaluateOnNewDocument') { scripts.add(next); return { identifier: next++ }; }
      if (m === 'Page.removeScriptToEvaluateOnNewDocument') { if (!scripts.delete(p.identifier)) throw new Error('Protocol error (Page.removeScriptToEvaluateOnNewDocument): Script not found'); return {}; }
      return {};
    } };
    const pose = poser(cdp);
    await pose({ x: 0, y: 0, cs: 1 }, true);                                   // one registered, as after a first frame
    await Promise.all([2, 3, 4].map(i => pose({ x: i, y: i, cs: i }, true)));     // then a navigation and frames overlap
    assert.equal(scripts.size, 1, `overlapping poses left ${scripts.size} init scripts registered (want 1)`);
  }

  const f2 = v => v.toFixed(2);
  console.log(`selfcheck OK: springs ${JSON.stringify(springs)}; pre-aim holds the fixed point; retarget keeps velocity; settles exact; ms 0 cuts; click lands at ${press.toFixed(3)}s; shake 100ms`);
  console.log(`selfcheck OK: main ${r.frames} frames/${r.dur.toFixed(2)}s 2560x1440@60 mp4 ${n} frames luma head ${head} tail ${tail}; anim ${md5.length} frames 0 repeats; blur spans ${JSON.stringify(spans)} inside camera moves, up to ${bb.maxSamples} samples ${bb.maxGap}px apart, capped run filled ${capped.filled} frames`);
  console.log(`selfcheck OK: lazy import stays deterministic; SSE runs on under auto, falls back to ${fb.mode} under pause, one message each; screencast hold ${h.frames} frames; scroll-zoom luma ${zl.det}/${zl.sc}; guard threw`);
  console.log(`selfcheck OK: mark id carried as written, absent when not given; numeric and repeated ids refused; a mark taller than the open area boxed to it (${Math.round(tall.rect.h)} of 900px) and flagged`);
  console.log(`selfcheck OK: inventory on a re-rendering page ${invSkipped}; beats form without --state runs`);
  console.log(`selfcheck OK: blur averaging writes an opaque frame from one rgba sub-frame among rgb24 ones`);
  console.log(`selfcheck OK: overlapping poses are serialised: one init script left, no double removal`);
  console.log(`selfcheck OK: locator chain falls through to entry 2 and is recorded; a miss names the chain and nearest candidates and films nothing; dry run 0/1; ferry dry run ${ferryDry}`);
  console.log(`selfcheck OK: cursor under 2x zoom det ${cs.det.map(f2)} sc ${cs.sc.map(f2)} (zoomed, after nav); ring per click ${JSON.stringify(ripple)}; type det ${f2(ty.det[0])}s sc ${f2(ty.sc[0])}s; pace ${f2(p1.dur)}s -> ${f2(p2.dur)}s; loggedInSel re-mints; sandbox errors ${sandboxErrs}`);
} finally {
  server.close(); fs.rmSync(out, { recursive: true, force: true });
}

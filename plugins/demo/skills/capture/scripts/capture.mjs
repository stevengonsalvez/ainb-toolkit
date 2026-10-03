// ABOUTME: Screen-capture rig for product demos. Drives a real app with real clicks and films it,
// emitting footage plus an events file that a compositor (HyperFrames) uses to place annotations.
//
// Two ways to film, both measured rather than assumed:
//  - deterministic (default): chrome-headless-shell under HeadlessExperimental.beginFrame with
//    virtual time. Every frame is rendered on demand at exactly n/fps of page time, as a lossless
//    PNG at --force-device-scale-factor (2560x1440 for a 1280x720 viewport). Camera and cursor are
//    posed per frame from a spring solver (motion.mjs). Costs several times real time.
//  - screencast (fallback): CDP Page.startScreencast in real time. Emits ONLY on repaint and always
//    at CSS-viewport size (1280x720 JPEG), so a hold needs the drifting cursor to keep frames coming.
//    Used when deterministic capture cannot proceed (no beginFrame in the browser, page time
//    stuck, a hard timeout, or network 'pause' meeting a request that never ends); the rig says
//    why and re-films the chapter.
// Both:
//  - Zoom uses Emulation.setDeviceMetricsOverride's viewport clip. CSS transform on <html>
//    re-rasters crisply but makes the root the containing block for position:fixed, which throws
//    fixed chrome into mid-frame.
//  - Never select by bare text. A bare text selector for a nav label matched an article headline
//    and navigated away from the nav entirely. Scope every selector.
import fs from 'fs'; import path from 'path'; import { execFile } from 'child_process';
// Browsers come from $PLAYWRIGHT_BROWSERS_PATH when set, else Playwright's own default.
import { chromium } from '@playwright/test';
import { Camera, Cursor, tilt, CAMERA_REF_MS, CLICK_LEAD_MS } from './motion.mjs';
import { resolve, lintTarget, inventory, identify, describeChain, LocatorMiss } from './locate.mjs';
import { estimate } from './narrative.mjs';

const smoothstep = p => p * p * (3 - 2 * p);
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
const ffbin = name => process.env[name.toUpperCase()] || (fs.existsSync(`/usr/bin/${name}`) ? `/usr/bin/${name}` : name);

// String paths match on a segment boundary: '/reports' accepts '/reports' and '/reports/x',
// never '/reports-archive'. (A pathname carries no '?' or '#', so '/' is the only boundary.)
const onPath = (expected, got) => expected instanceof RegExp ? expected.test(got)
  : got === expected || got.startsWith(expected.endsWith('/') ? expected : expected + '/');

// A mis-click must fail the take, not quietly film the wrong screen.
export function checkPath(expected, url, name = '?') {
  const got = new URL(url).pathname;
  const ok = onPath(expected, got);
  if (!ok) throw new Error(`beat "${name}": expected path ${expected}, got ${got}`);
}

const wall = { now: () => Date.now(), sleep: (page, ms) => page.waitForTimeout(ms) };

// Resolve when no request has been in flight for `quiet` ms, or after `cap` ms, on `clock`
// (wall time, or footage time under deterministic capture, where virtual time stands still while
// a fetch is in flight). Fixed settle delays were too short after navigation and ended takes on
// the app's loading splash. Prefer a beat's `ready` selector; this is the fallback.
function networkQuiet(page, { quiet = 500, cap = 8000 } = {}, clock = wall) {
  let inflight = 0, last = clock.now();
  const skip = r => ['websocket', 'eventsource'].includes(r.resourceType());
  const up = r => { if (!skip(r)) { inflight++; last = clock.now(); } };
  const down = r => { if (!skip(r)) { inflight = Math.max(0, inflight - 1); last = clock.now(); } };
  page.on('request', up); page.on('requestfinished', down); page.on('requestfailed', down);
  // Listeners attach now (before the action); the quiet window starts when awaited.
  return async () => {
    const start = clock.now(); last = Math.max(last, start);
    // ponytail: long-poll requests hold the count up, so such pages always hit the cap; give those beats a `ready` selector.
    while (clock.now() - start < cap && (inflight > 0 || clock.now() - last < quiet)) await clock.sleep(page, 50);
    page.off('request', up); page.off('requestfinished', down); page.off('requestfailed', down);
    if (clock.now() - start >= cap) console.warn(`network not quiet after ${cap}ms; add a \`ready\` selector to this beat`);
  };
}

// Drive the real login form and save storageState. Never hand-write a token
// into a state file: it fails silently and films the /login page instead.
// Defaults match the first SPA this was built on: #email is input[type=text], a cookie modal covers the
// submit button, and type() (not fill()) is what the controlled inputs accept.
export async function mintState({ base, email, password, state, loginPath = '/login',
  emailSel = '#email', passwordSel = '#password', loggedInSel,
  submitSel = 'role=button[name=/^(log in|sign in)$/i]', dismissSel = '#rcc-decline-button' }) {
  const browser = await chromium.launch();
  try {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await page.goto(base + loginPath);
    await page.locator(emailSel).waitFor({ timeout: 20000 });
    if (dismissSel && await page.locator(dismissSel).isVisible()) await page.locator(dismissSel).click();
    await page.locator(emailSel).type(email);
    await page.locator(passwordSel).type(password);
    await page.locator(submitSel).click();
    await page.waitForURL(u => !onPath(loginPath, u.pathname), { timeout: 20000 })
      .catch(() => { throw new Error(`login as ${email} did not leave ${loginPath}`); });
    if (loggedInSel) await page.locator(loggedInSel).first().waitFor({ timeout: 20000 })
      .catch(() => { throw new Error(`login as ${email}: ${loggedInSel} never appeared`); });
    fs.mkdirSync(path.dirname(state), { recursive: true });
    await ctx.storageState({ path: state });
  } finally { await browser.close(); }
}

// Reuse `state` if it still looks logged in, otherwise mint a fresh one. "Logged in" means
// `login.loggedInSel` is visible when set; otherwise only "the probe did not land on loginPath",
// which reuses a dead session on apps that send logged-out users somewhere else.
export async function ensureState({ base, state, login, probe = '/home' }) {
  if (fs.existsSync(state)) {
    const browser = await chromium.launch();
    let alive;
    try {
      const page = await (await browser.newContext({ storageState: state })).newPage();
      const quiet = networkQuiet(page);
      await page.goto(base + probe); await quiet(); await page.waitForTimeout(1000);
      alive = login.loggedInSel
        // isVisible() does not wait: an SPA still rendering its shell would read as logged out.
        ? await page.locator(login.loggedInSel).first().waitFor({ state: 'visible', timeout: 5000 }).then(() => true, () => false)
        : !onPath(login.loginPath ?? '/login', new URL(page.url()).pathname);
    } finally { await browser.close(); }
    if (alive) return 'reused';
  }
  await mintState({ base, state, ...login });
  return 'minted';
}

// Init script: cursor, click feedback and localStorage seeding, run in every document.
// Exported so the self-check can drive it on a bare page.
// `follow`: the pointer follows mousemove (screencast). Under deterministic capture the rig
// poses it every frame through window.__demoSet instead, from the spring solver.
export function overlay({ ls, hidden, ringColor, follow = true }) {
  // e.g. consent keys: a consent banner otherwise covers the lower third of every frame.
  // Storage throws in sandboxed documents; skipping it there must not stop the cursor mounting.
  for (const [k, v] of Object.entries(ls)) try { localStorage.setItem(k, v); } catch {}
  // Top frame only: in an iframe the overlay filmed a second cursor inside the iframe.
  if (window !== window.top) return;
  const mount = () => {
    if (document.getElementById('__cur')) return;
    // window.__demoPose is set by a second init script that the rig re-registers whenever the
    // camera or pointer moves, so a page that loads mid-zoom mounts the pointer already at its
    // position and counter-scale instead of at (0,0) and 2x for a frame or two.
    const pose = window.__demoPose || { x: 0, y: 0, cs: 1 };
    const d = document.createElement('div'); d.id = '__cur';
    // A hidden cursor still moves: in screencast mode its repaints keep frames coming during a hold.
    // `scale: var(--__demo-cs)` is the camera's counter-scale (under a name no app uses), so the
    // pointer keeps its size under a zoom; it composes with `translate`, the pointer position,
    // about the arrow's tip. `transform` is left free for the click shrink, `rotate` for tilt.
    d.style.cssText = 'position:fixed;top:0;left:0;width:20px;height:26px;pointer-events:none;z-index:2147483647;' + (follow ? 'transition:translate .05s linear;' : '') + 'will-change:translate;transform-origin:0 0;scale:var(--__demo-cs,1);filter:drop-shadow(0 1px 2px rgba(0,0,0,.45));background:no-repeat center/contain url("data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' width=\'20\' height=\'26\' viewBox=\'0 0 18 24\'%3E%3Cpath d=\'M2 2 L2 18 L6.5 13.8 L9.2 20 L11.8 19 L9.1 13 L14.5 13 Z\' fill=\'white\' stroke=\'black\' stroke-width=\'1.4\' stroke-linejoin=\'round\'/%3E%3C/svg%3E")' + (hidden ? ';opacity:0.004' : '');
    d.style.translate = `${pose.x}px ${pose.y}px`;
    const ring = document.createElement('div'); ring.id = '__ring';
    // A thin dark outline keeps the default white ring visible on a white page.
    ring.style.cssText = `position:fixed;top:0;left:0;width:52px;height:52px;border-radius:50%;border:2px solid ${ringColor};box-shadow:0 0 0 1px rgba(0,0,0,.25);scale:var(--__demo-cs,1);pointer-events:none;z-index:2147483646;opacity:0`;
    for (const el of [d, ring]) el.style.setProperty('--__demo-cs', String(pose.cs));
    document.body.appendChild(ring); document.body.appendChild(d);
    window.__demoSet = (x, y, cs, rot) => {
      d.style.translate = `${x}px ${y}px`; d.style.rotate = `${rot}deg`;
      for (const el of [d, ring]) el.style.setProperty('--__demo-cs', String(cs));
    };
    if (follow) addEventListener('mousemove', e => { d.style.translate = `${e.clientX}px ${e.clientY}px`; }, { passive: true });
    if (hidden) return;
    // Click feedback (Cap's, see motion.mjs): the pointer shrinks to 0.8 and back over 130ms each
    // way, and a ring expands with a cubic ease-out over 0.6s while fading as (1-t)^1.5. Web
    // Animations run on the document timeline, which is virtual time under deterministic capture.
    // Each click cancels the last, so every ring starts from its smallest size.
    const K = 12, ringFrames = Array.from({ length: K + 1 }, (_, i) => {
      const t = i / K;
      return { offset: t, transform: `scale(${(0.3 + 1.4 * (1 - (1 - t) ** 3)).toFixed(4)})`, opacity: ((1 - t) ** 1.5).toFixed(4) };
    });
    addEventListener('mousedown', e => {
      ring.style.left = `${e.clientX - 26}px`; ring.style.top = `${e.clientY - 26}px`;
      for (const a of [...ring.getAnimations(), ...d.getAnimations()]) a.cancel();
      ring.animate(ringFrames, { duration: 600, easing: 'linear' });
      d.animate([{ transform: 'scale(1)', easing: 'ease-in-out' }, { transform: 'scale(0.8)', easing: 'ease-in-out' }, { transform: 'scale(1)' }], { duration: 260 });
    }, true);
  };
  document.readyState === 'loading' ? addEventListener('DOMContentLoaded', mount) : mount();
}

// Raised when deterministic capture cannot proceed; capture() then re-films in screencast mode.
class Fallback extends Error {}

// pace multiplies every filmed duration (zoom/wide ms, hold, settle, cursor glides); 2 = twice as slow.
// cursor.speed is px/s; cursor.ring is the click ring's CSS colour; cursor.tilt tilts the pointer.
// capture: { mode: 'deterministic' | 'screencast', dpr: 2, fps: 60, blur, network, unstickMs, stallMs, timeoutMs }.
// A mark's id names it for compose, so it must be a string (4.10 as a number is 4.1) and unique in
// its chapter. Checked before anything is filmed, dry runs included.
function checkMarkIds(beats, chapter) {
  const seen = new Set();
  for (const b of beats || []) {
    const id = b?.mark?.id;
    if (id == null) continue;
    if (typeof id !== 'string' || !id) throw new Error(`chapter "${chapter}", beat "${b.name ?? '?'}": mark id must be a non-empty string, got ${JSON.stringify(id)} (write '4.10', not 4.10)`);
    if (seen.has(id)) throw new Error(`chapter "${chapter}": mark id "${id}" is used twice`);
    seen.add(id);
  }
}

// ffmpeg arguments averaging a blurred frame's N sub-frames (sub/00.png ...) into `out`, with the
// gap `fill` appended. Each sub-frame is its own input, normalised to rgb24, then mixed. A CDP
// screenshot can come back with alpha (a 1px unpainted seam mid-scroll, on the transparent default
// background); as one image2 stream that format change rebuilt the graph, tmix restarted its count,
// select=eq(n,N-1) never fired and ffmpeg exited 0 having written no frame.
export function blurArgs(sub, N, fill, out) {
  const ins = [], fmt = [], mix = [];
  for (let k = 0; k < N; k++) { ins.push('-i', path.join(sub, `${String(k).padStart(2, '0')}.png`)); fmt.push(`[${k}]format=rgb24[a${k}]`); mix.push(`[a${k}]`); }
  return ['-v', 'error', '-y', ...ins, '-filter_complex', `${fmt.join(';')};${mix.join('')}mix=inputs=${N}${fill}`, '-update', '1', out];
}

// The default wall-time cap scales with the footage: deterministic capture with blur ran 35x to
// 61x real time on a heavy app (its waits for data are not in the estimate), so 120x, 10 min at least.
export const timeoutFor = (beats, pace = 1) => Math.max(600000, Math.round(estimate(beats, pace).dur * 120000));

export async function capture(opts) {
  checkMarkIds(opts.beats, opts.chapter);
  const cap = { mode: 'deterministic', dpr: 2, fps: 60, blur: {}, network: 'auto', unstickMs: 1500, stallMs: 10000,
    timeoutMs: timeoutFor(opts.beats, opts.pace), ...opts.capture, chapter: opts.chapter };
  if (cap.blur !== false) cap.blur = { samples: 4, max: 64, spacing: 1.5, shutter: 0.5, threshold: 2, ...cap.blur };
  if (cap.mode !== 'deterministic') return film({ ...opts, cap });
  try { return await film({ ...opts, cap }); } catch (e) {
    if (!(e instanceof Fallback)) throw e;
    console.warn(`chapter "${opts.chapter}": deterministic capture stopped (${e.message}); re-filming it in screencast mode (viewport-size JPEG, 30fps).`);
    // The failed take really ran its beats: one that signs out has revoked the session it was
    // given, so check it again (and re-mint it) before the re-film starts from it.
    if (opts.login && opts.state) console.warn(`chapter "${opts.chapter}": session for the re-film: ${await ensureState(opts)}`);
    return film({ ...opts, cap: { ...cap, mode: 'screencast', fallback: e.message } });
  }
}

async function film({ base, state, out, viewport = { width: 1280, height: 720 }, beats, chapter,
  localStorage: ls = {}, pace = 1, cursor = {}, cap }) {
  const { width: W, height: H } = viewport;
  if (!beats[0]?.goto) throw new Error(`chapter "${chapter}": first beat must be a goto (filming starts once it has painted)`);
  const dir = path.join(out, chapter), dry = cap.mode === 'dry';
  if (!dry) { fs.rmSync(dir, { recursive: true, force: true }); fs.mkdirSync(path.join(dir, 'cfr'), { recursive: true }); }
  const det = cap.mode === 'deterministic';
  const P = ms => ms * pace;
  const overlayArgs = { ls, hidden: !!cursor.hidden, ringColor: cursor.ring || '#FFFFFF', follow: !det };
  const rec = dry ? await dryRun({ W, H, state, overlayArgs }) : det ? await deterministic({ W, H, cap, dir, state, overlayArgs }) : await screencast({ W, H, dir, state, overlayArgs });
  const { page } = rec;
  Object.assign(rec, { speed: cursor.speed || 0, pace }); rec.cursorTilt = cursor.tilt;
  // targets: which locator each beat's targets resolved to; lints: selectors where a role or test
  // id would do (checked on a dry run); timing: wall ms per beat (the dry run's table).
  const events = [], targets = [], lints = [], timing = [], lint = dry || !!cap.lint;
  try {
    const run = (async () => {
      // Targets are resolved fresh every beat: nav bars change with context
      // (one item vanished from the nav after another was clicked), so cached handles go stale.
      // A target is a selector or a locator chain (locate.mjs); which entry matched is recorded in
      // events.json `targets`, and a miss fails the take at once, naming the nearest candidates,
      // rather than filming on. The wait runs on the take's clock, like `ready`.
      const find = async (target, use, beat, waitMs = 5000) => {
        const hit = await resolve(page, target, { use, beat, waitMs, now: rec.ms, sleep: ms => rec.sleep(ms) });
        targets.push({ beat, use, matched: hit.matched, ...(hit.of > 1 && { index: hit.index, of: hit.of }) });
        if (lint) { const w = await lintTarget(page, target, hit).catch(() => null); if (w && !lints.some(l => l.endsWith(w))) lints.push(`beat "${beat}": ${use} ${w}`); }
        return hit.loc;
      };
      const rectOf = loc => loc.evaluate(n => { const r = n.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; });
      // A click or type cue's target: its rect, in the same CSS px as a mark's, or null when it has
      // no box (display:none, zero size), so a consumer has nothing to point at; and its role and
      // accessible name as the accessibility tree has them (locate.mjs identify(), the same source
      // the lint and inventory use), the name cut at a word under 40 characters, so a consumer can
      // say "Open Fares" rather than "Click here". Either may be null. The rect is read through an
      // element handle pinned when the target resolved: a field that hides while it is typed into
      // no longer matches a chain's visible-only locator, and reading through that would wait out
      // Playwright's 30s default.
      const boxOf = h => h.evaluate(n => { const b = n.getBoundingClientRect(); return { x: b.x, y: b.y, w: b.width, h: b.height }; })
        .then(r => (r.w > 0 && r.h > 0 ? r : null), () => null);
      const nameOf = async loc => {
        const { role, name } = await identify(loc).catch(() => ({ role: null, name: null }));
        const c = Array.from(name || '');                    // by code point: never split a surrogate pair
        if (c.length <= 39) return { name, role };
        const cut = c.slice(0, 38).join(''), sp = cut.lastIndexOf(' ');
        return { name: `${(sp > 22 ? cut.slice(0, sp) : cut).trimEnd()}…`, role };
      };
      // A second element matching the target can appear between resolving it and acting on it (a
      // re-render during the glide): Playwright then throws a strict-mode error; say it as a miss.
      const act = (p, target, use, beat) => p.catch(e => {
        if (/strict mode violation/.test(e.message)) throw new LocatorMiss(`beat "${beat}": ${use} target ${describeChain(target)} matched more than one visible element by the time it was ${use === 'type' ? 'typed into' : 'clicked'} (one appeared after it resolved); make it more specific`);
        throw e;
      });
      const boxFor = (r, s) => {
        const vw = W / s, vh = H / s;
        return { x: clamp(r.x + r.w / 2 - vw / 2, 0, Math.max(0, W - vw)),
                 y: clamp(r.y + r.h / 2 - vh / 2, 0, Math.max(0, H - vh)), w: vw, h: vh, s };
      };
      // isVisible() does not wait, so this polls on the take's own clock: footage time under
      // deterministic capture, where Playwright's wall-clock timeouts would run ~10x short.
      const ready = (target, capMs, name) => find(target, 'ready', name, capMs);
      const clock = { now: rec.ms, sleep: (_, ms) => rec.sleep(ms) };
      let lastMark = null;

      for (const [i, step] of beats.entries()) {
        const name = step.name || `#${i}`, beatT0 = Date.now();
        lastMark = null;
        let quiet = null;
        if (step.goto || step.click) quiet = step.ready ? null : networkQuiet(page, { cap: step.readyCap }, clock);
        if (step.goto) await page.goto(base + step.goto, { waitUntil: 'domcontentloaded', timeout: rec.T(30000) });
        if (step.click) {
          const el = await find(step.click, 'click', name), pin = await el.elementHandle();
          const r = await act(el.boundingBox(), step.click, 'click', name);
          if (r) await rec.glideTo(r.x + r.width / 2, r.y + r.height / 2, P(300), true);
          // Sound cue for compose, as the press lands, with its target's rect and the camera box
          // in force (as a mark has them). Clicks before filming starts are not recorded.
          if (rec.filming) { const t = rec.now(); events.push({ t, kind: 'click', rect: await boxOf(pin), ...await nameOf(el), cam: rec.cam }); }
          await act(el.click({ timeout: rec.T(8000) }), step.click, 'click', name);
          await pin.dispose();
        }
        if (step.goto || step.click) {
          if (step.ready) await ready(step.ready, step.readyCap ?? 15000, name);
          else await quiet();
          await rec.sleep(P(step.settle ?? 400));
        }
        if (step.expectPath) checkPath(step.expectPath, page.url(), name);
        // Start filming only once the first page is ready: starting before paint
        // put a white about:blank frame plus ~85 black splash frames at the head.
        if (!rec.filming) await rec.start();
        // A number (or a numeric string, as before) scrolls the window by that many px. A target
        // scrolls whatever contains it (a dialog or panel the window cannot move) into view, and
        // nothing moves when it is already fully in view and not covered.
        const px = typeof step.scroll === 'number' ? step.scroll : /^-?\d+$/.test(String(step.scroll ?? '')) ? Number(step.scroll) : null;
        if (px != null) { await page.evaluate(y => window.scrollBy({ top: y, behavior: 'smooth' }), px); await rec.sleep(700); }
        else if (step.scroll) {
          const loc = await find(step.scroll, 'scroll', name);
          const moved = await loc.evaluate(n => {
            const r = n.getBoundingClientRect();
            // In view means inside the window AND not covered: a fixed or sticky bar (an app's bottom
            // nav) over the target's top or bottom edge means it still has to move.
            const hit = (x, y) => { const e = document.elementFromPoint(x, y); return !!e && (e === n || n.contains(e)); };
            const cx = r.left + r.width / 2, inset = Math.min(4, r.height / 4);
            const clear = hit(cx, r.top + inset) && hit(cx, r.bottom - inset);
            if (clear && r.top >= 0 && r.left >= 0 && r.bottom <= innerHeight && r.right <= innerWidth) return false;
            n.scrollIntoView({ block: r.height > innerHeight ? 'start' : 'center', behavior: 'smooth' });
            return true;
          });
          // Smooth scrolling takes longer the further it goes (measured 342ms for 400px, 1125ms for
          // 4600px), so wait until the target holds still for two checks, at most 3s.
          for (let last = null, still = 0, t0 = rec.ms(); moved && still < 2 && rec.ms() - t0 < 3000;) {
            await rec.sleep(50);
            const y = await loc.evaluate(n => Math.round(n.getBoundingClientRect().top));
            still = y === last ? still + 1 : 0; last = y;
          }
        }
        // Typed key by key so the viewer sees it being entered; fill() would paste it in one frame.
        // Typing can fetch (search-as-you-type), so it waits like a click: ready, else network quiet, then settle.
        if (step.type) {
          const { into, text, cps = 12 } = step.type;
          const el = await find(into, 'type', name), pin = await el.elementHandle(), named = await nameOf(el);
          const r = await act(el.boundingBox(), into, 'type', name);
          if (r) await rec.glideTo(r.x + r.width / 2, r.y + r.height / 2, P(300), true);
          const typed = step.ready ? null : networkQuiet(page, { cap: step.readyCap }, clock);
          const tc = rec.now(), cam = rec.cam;
          events.push({ t: tc, kind: 'click', rect: await boxOf(pin), ...named, cam });
          await act(el.click({ timeout: rec.T(8000) }), into, 'type', name);
          const t0 = rec.now();
          for (const ch of String(text)) { await page.keyboard.type(ch); await rec.sleep(1000 / cps); }
          // measured after the typing: a field that widens on focus or input is pointed at as it ends up
          events.push({ t: t0, kind: 'type', dur: rec.now() - t0, chars: String(text).length, rect: await boxOf(pin), ...named, cam: rec.cam });
          await pin.dispose();
          if (step.ready) await ready(step.ready, step.readyCap ?? 15000, name);
          else await typed();
          await rec.sleep(P(step.settle ?? 400));
        }
        // Each camera move is logged as a `camera` event (start t0, end t1): compose plays it at 1x
        // and lights a spotlight only once it has ended.
        if (step.zoom) {
          const r = await rectOf(await find(step.zoom.on, 'zoom', name));
          // Zooming while zoomed: the override may have moved the scroll since camScroll was read.
          if (rec.cam) { const sc = await page.evaluate(() => ({ x: scrollX, y: scrollY })); r.x += sc.x - rec.camScroll.x; r.y += sc.y - rec.camScroll.y; }
          const t0 = rec.now(), to = boxFor(r, step.zoom.scale ?? 2);
          await rec.glide(to, P(step.zoom.ms ?? 700));
          events.push({ t: t0, kind: 'camera', t0, t1: rec.now(), cam: to });
        }
        // `wide: 0` is a cut back to the full view, not "no wide".
        if (step.wide != null && step.wide !== false) {
          const t0 = rec.now();
          await rec.glide({ x: 0, y: 0, w: W, h: H, s: 1 }, P(step.wide === true ? 700 : step.wide));
          events.push({ t: t0, kind: 'camera', t0, t1: rec.now(), cam: null });
        }
        // A mark is the handoff to the compositor: what to point at, and when.
        if (step.mark) {
          const on = await find(step.mark.on, 'mark', name);
          lastMark = await rectOf(on);
          // A mark boxes only what is on screen: the longest run of its height inside the window and
          // not under a fixed or sticky bar (an app's bottom nav), sampled down its middle every 4px.
          // One taller than that run is boxed to it, flagged `clipped` and named in a lint, rather
          // than drawn on through the bar. Mark a smaller element, or scroll or zoom out, to clear it.
          const open = await on.evaluate(n => {
            const r = n.getBoundingClientRect(), cx = r.left + r.width / 2, a = Math.max(0, r.top), b = Math.min(innerHeight, r.bottom);
            let best = null, from = null;
            for (let y = a; y <= b; y += 4) {
              const e = y < b ? document.elementFromPoint(cx, y) : null, hit = !!e && (e === n || n.contains(e));
              if (hit && from == null) from = y;
              if ((!hit || y + 4 > b) && from != null) { const to = hit ? b : y; if (!best || to - from > best.to - best.from) best = { from, to }; from = null; }
            }
            return best;
          });
          let clipped;
          if (open && (open.from > lastMark.y + 4 || open.to < lastMark.y + lastMark.h - 4)) {
            clipped = { h: Math.round(lastMark.h), open: Math.round(open.to - open.from) };
            lastMark = { ...lastMark, y: open.from, h: open.to - open.from };
            lints.push(`beat "${name}": mark is ${clipped.h}px tall but only ${clipped.open}px of it is on screen and clear of fixed bars; boxed to that part`);
          }
          // `id` names the mark for compose (a beat-paced cut orders beats by it); kept as written.
          events.push({ t: rec.now(), kind: 'mark', ...(step.mark.id != null && { id: step.mark.id }),
            label: step.mark.label, rect: lastMark, ...(clipped && { clipped }), cam: rec.cam });
        }
        if (step.hold) await rec.hold(P(step.hold), lastMark);
        timing.push({ beat: name, ms: Date.now() - beatT0 });
      }
      await rec.hold(P(500), null);
    })();
    run.catch(() => {});                       // a stall rejects `rec.failed` first; this one then dies with the browser
    await Promise.race([run, rec.failed]);
    // cap.inventory: what a beat could target on the page the beats ended on (inventory.mjs)
    if (dry) return { dry: true, chapter, targets, lints, timing, ...(cap.inventory && { inventory: await inventory(page) }) };
    const r = await rec.stop();
    const capInfo = { mode: cap.mode, ...(cap.fallback && { requested: 'deterministic', fallback: cap.fallback }),
      ...(det && { network: cap.netNote ? 'advance' : cap.network === 'advance' ? 'advance' : 'pause', ...(cap.netNote && { networkNote: cap.netNote }) }),
      ...(det && { blur: cap.blur && { ...cap.blur, spans: r.blurSpans, ...r.blurStats } }) };
    // poses go last, one [frame, x, y, s] per line: indented like the rest they cost one line per number
    const body = JSON.stringify({ chapter, viewport, dpr: r.dpr, fps: r.fps, capture: capInfo, dur: r.dur, frames: r.frames, events, targets }, null, 1);
    fs.writeFileSync(path.join(dir, 'events.json'), r.poses?.length
      ? `${body.slice(0, -2)},\n "poses": [\n${r.poses.map((p) => `  ${JSON.stringify(p)}`).join(',\n')}\n ]\n}` : body);
    if (lints.length) for (const w of lints) console.warn(`  lint ${chapter}: ${w}`);
    return { frames: r.frames, dur: r.dur, events: events.filter(e => e.kind === 'mark').length, dir, mode: cap.mode, fps: r.fps, dpr: r.dpr };
  } catch (e) { e.targets = targets; throw e; }   // what resolved before it failed, for the dry run's count
  finally { await rec.close(); }
}

// The camera's metrics override zooms the overlay with the page (measured 1.5x bigger at scale
// 1.5), so each pose sets the pointer's counter-scale and position in the current document (one
// Runtime.evaluate), and the init script the next document reads at mount is re-registered only
// when it matters: the counter-scale changed, or `register` (a navigation is under way).
//
// Calls are serialised: the frame loop and a navigation can pose at once, and two overlapping calls
// read the same previous script id, so both removed it and the second removal failed "Script not
// found", which ended the take (seen on single-persona chapters with several navigations).
export function poser(cdp) {
  let id = null, cs = null, tail = Promise.resolve();
  return (pose, register = false) => (tail = tail.catch(() => {}).then(async () => {
    if (register || pose.cs !== cs) {
      cs = pose.cs;
      const prev = id;
      id = (await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: `window.__demoPose = ${JSON.stringify(pose)};` })).identifier;
      if (prev) await cdp.send('Page.removeScriptToEvaluateOnNewDocument', { identifier: prev });
    }
    await cdp.send('Runtime.evaluate', { expression: `window.__demoSet?.(${pose.x}, ${pose.y}, ${pose.cs}, ${pose.rot || 0})` }).catch(() => {});
  }));
}

// ---------- dry run: the beats at speed, no frames ----------
// The same beat loop drives a plain page: every target and every `ready` resolves for real and
// clicks and typing happen, so a broken target fails here, but nothing is filmed or posed and every
// wait for show (hold, settle, glide, the gap between keys) is cut to at most 20ms.
async function dryRun({ W, H, state, overlayArgs }) {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: W, height: H }, storageState: state });
  const page = await ctx.newPage();
  // The same init script as a take: it seeds `localStorage` (a consent key that keeps a banner
  // away), so the page the dry run clicks through is the page the take films. Cursor hidden.
  await page.addInitScript(overlay, { ...overlayArgs, hidden: true });
  const rec = {
    page, filming: false, cam: null, camScroll: { x: 0, y: 0 }, speed: 0, pace: 1,
    failed: new Promise(() => {}),
    T: ms => ms, ms: () => Date.now(), now: () => 0,
    sleep: ms => page.waitForTimeout(Math.min(ms, 20)),
    async start() { rec.filming = true; },
    async glide(to) { rec.cam = to.s === 1 ? null : to; },
    async glideTo() {}, async hold() {},
    close: () => browser.close(),
  };
  return rec;
}

// ---------- screencast recorder (real time, the fallback) ----------
async function screencast({ W, H, dir, state, overlayArgs }) {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: W, height: H }, deviceScaleFactor: 1, storageState: state });
  const page = await ctx.newPage();
  await page.addInitScript(overlay, overlayArgs);
  const cdp = await ctx.newCDPSession(page);
  await cdp.send('Page.enable');
  const pose = poser(cdp);
  const frames = [];
  let t0 = null;
  cdp.on('Page.screencastFrame', async e => {
    if (t0 === null) t0 = e.metadata.timestamp;
    frames.push({ buf: Buffer.from(e.data, 'base64'), t: e.metadata.timestamp });
    try { await cdp.send('Page.screencastFrameAck', { sessionId: e.sessionId }); } catch {}
  });
  let cx = W / 2, cy = H / 2, drift = 1, mx = 0, my = 0;
  // ms is already paced; a cursor.speed glide is distance / speed, paced here.
  const moveTo = async (x, y, ms) => {
    // One mouse.move step is one rendered frame, measured at 16.7ms (steps 18 took 300ms at any distance).
    const t = rec.speed ? Math.hypot(x - mx, y - my) / rec.speed * 1000 * rec.pace : ms;
    await page.mouse.move(x, y, { steps: Math.max(1, Math.round(t / 16.7)) });
    mx = x; my = y;
  };
  const rec = {
    page, cdp, filming: false, cam: null, camScroll: { x: 0, y: 0 }, speed: 0, pace: 1,
    failed: new Promise(() => {}),
    T: ms => ms,
    // Wall clock, not frames.at(-1): frame delivery lagged the screen by ~1s at 46s into a take.
    now: () => (t0 === null ? 0 : Date.now() / 1000 - t0),
    ms: () => Date.now(),            // the clock waits run on
    sleep: ms => page.waitForTimeout(ms),
    async start() {
      rec.filming = true;
      // Park the cursor first, or frame 0 shows it at the (0,0) mount position.
      await page.mouse.move(cx, cy); mx = cx; my = cy; await page.waitForTimeout(100);
      await cdp.send('Page.startScreencast', { format: 'jpeg', quality: 90, everyNthFrame: 1 });
    },
    // cam and rects are viewport-relative, but the override's viewport x/y are document-relative:
    // after a 520px scroll, y=0 filmed the blank page top. Add the scroll, read once while unzoomed
    // (an active override moves scrollX/Y itself, so re-reading mid-glide compounds).
    async setCam(v) {
      const prev = rec.cam; rec.cam = v;
      const p = pose({ x: mx, y: my, cs: v ? 1 / v.s : 1 });
      if (!v) { await Promise.all([cdp.send('Emulation.clearDeviceMetricsOverride'), p]); return; }
      if (!prev) rec.camScroll = await page.evaluate(() => ({ x: scrollX, y: scrollY }));
      await Promise.all([cdp.send('Emulation.setDeviceMetricsOverride', {
        width: W, height: H, deviceScaleFactor: 1, mobile: false,
        viewport: { x: v.x + rec.camScroll.x, y: v.y + rec.camScroll.y, width: v.w, height: v.h, scale: v.s },
      }), p]);
    },
    // Ease the camera between two viewport boxes so the push-in reads as a move, not a cut.
    // Each step is its own override; the screencast repaints on each.
    async glide(to, ms) {
      const from = rec.cam || { x: 0, y: 0, w: W, h: H, s: 1 };
      const steps = Math.max(6, Math.round(ms / 45));
      for (let i = 1; i <= steps; i++) {
        const e = smoothstep(i / steps);
        await rec.setCam({
          x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e,
          w: from.w + (to.w - from.w) * e, h: from.h + (to.h - from.h) * e,
          s: from.s + (to.s - from.s) * e,
        });
        await page.waitForTimeout(30);
      }
      if (to.s === 1) await rec.setCam(null);   // clear the override, or the page stays under a scale-1 emulation
    },
    // cursor.speed unset keeps the fixed 300ms click glide and 220ms pause before the press.
    async glideTo(x, y, ms, click) { await moveTo(x, y, ms); if (click) await page.waitForTimeout(ms * 220 / 300); },
    async hold(ms) {
      const end = Date.now() + ms;
      // Drift inside the camera box: a cursor moving outside the zoomed region repaints nothing
      // visible, the screencast stops emitting, and the mp4 froze on the pre-zoom frame for 2.4s.
      const b = rec.cam || { x: 0, y: 0, w: W, h: H, s: 1 };
      const lo = b.x + b.w * 0.30, hi = b.x + b.w * 0.72, ymid = b.y + b.h * 0.55;
      if (cx < lo || cx > hi || Math.abs(cy - ymid) > b.h * 0.3) { cx = (lo + hi) / 2; cy = ymid; await moveTo(cx, cy, 200 * rec.pace); }
      while (Date.now() < end) {
        cx += 1.6 / b.s * drift; if (cx > hi || cx < lo) drift = -drift;
        cy += 0.4 / b.s * drift;
        await page.mouse.move(cx, cy); mx = cx; my = cy;
        await page.waitForTimeout(60);
      }
    },
    async stop() {
      await cdp.send('Page.stopScreencast');
      // Resample to 30fps here: output frame k shows the last frame captured at or before k/30, and
      // cfr/ holds one hard link per output frame for a plain image2 encode. An ffmpeg concat list
      // with per-frame durations was version-dependent: ffmpeg 6.1 honoured the durations, 8.1
      // ignored them and squeezed an 11.1s take into 8.9s, so every mark landed late.
      frames.forEach((f, i) => fs.writeFileSync(path.join(dir, `f${String(i).padStart(5, '0')}.jpg`), f.buf));
      const pad = i => `${String(i).padStart(5, '0')}.jpg`;
      const n = frames.length ? Math.ceil((frames.at(-1).t - t0) * 30) + 1 : 0;
      for (let k = 0, j = 0; k < n; k++) {
        while (j + 1 < frames.length && frames[j + 1].t - t0 <= k / 30) j++;
        fs.linkSync(path.join(dir, `f${pad(j)}`), path.join(dir, 'cfr', pad(k)));
      }
      return { frames: frames.length, dur: frames.length ? frames.at(-1).t - t0 : 0, fps: 30, dpr: 1 };
    },
    close: () => browser.close(),
  };
  return rec;
}

// ---------- deterministic recorder (beginFrame + virtual time) ----------
// Rules that follow from virtual time (measured, see SKILL.md):
//  - The pump below is the ONLY thing that produces frames, and page time advances only inside
//    it. Playwright actions are awaited while it runs; never use page.waitForTimeout (wall time),
//    use rec.sleep (footage time). An awaited page.mouse.move hangs: its ack needs a frame.
//  - pauseIfNetworkFetchesPending freezes page time while a fetch is in flight, so network
//    latency is edited out of the footage. A request that never ends (SSE) freezes it for good:
//    that is the stall this recorder detects and falls back on.
async function deterministic({ W, H, cap, dir, state, overlayArgs }) {
  const { dpr, fps } = cap, FI = 1000 / fps, blur = cap.blur;
  const fail = m => { throw new Fallback(m); };
  // Playwright 1.62 launches chrome-headless-shell for headless Chromium: the one build that still
  // has beginFrame (removed from full Chrome 147+). The density must come from the launch flag:
  // an emulated deviceScaleFactor reports 2 but beginFrame returns 1x pixels (measured).
  const browser = await chromium.launch({ args: ['--deterministic-mode', `--force-device-scale-factor=${dpr}`, `--window-size=${W},${H}`] });
  let page, cdp, ctx;
  try {
    ctx = await browser.newContext({ viewport: null, storageState: state });
    // beginFrame control is a property of the target, set when it is created, inside this
    // context (so it carries the storage state): find the context's CDP id from a scratch page.
    const scratch = await ctx.newPage();
    const s = await ctx.newCDPSession(scratch);
    const { targetInfo } = await s.send('Target.getTargetInfo'); await s.detach();
    const made = ctx.waitForEvent('page');
    await (await browser.newBrowserCDPSession()).send('Target.createTarget',
      { url: 'about:blank', browserContextId: targetInfo.browserContextId, enableBeginFrameControl: true });
    page = await made; await scratch.close();
    cdp = await ctx.newCDPSession(page);
    await cdp.send('Page.enable');
    await cdp.send('Emulation.setVirtualTimePolicy', { policy: 'pause' });
  } catch (e) { await browser.close(); fail(`beginFrame unavailable in this browser: ${e.message.split('\n')[0]}`); }
  await page.addInitScript(overlay, overlayArgs);
  const pose = poser(cdp);
  // Requests in flight, for naming whatever holds virtual time when it stalls.
  const pending = new Map();
  // A main-frame navigation under way: the pose init script follows the pointer until it commits,
  // so the new document mounts the pointer where it is.
  let navigating = false;
  page.on('request', r => {
    if (r.resourceType() !== 'websocket') pending.set(r, Date.now());
    if (r.isNavigationRequest() && r.frame() === page.mainFrame()) navigating = true;
  });
  for (const ev of ['requestfinished', 'requestfailed']) page.on(ev, r => pending.delete(r));

  const camera = new Camera(W, H), cursor = new Cursor(W / 2, H / 2, W, H);
  let failure = null, rejectFailed;
  const failed = new Promise((_, rej) => { rejectFailed = rej; });
  failed.catch(() => {});
  const started = Date.now();
  let ticks = Number(process.hrtime.bigint()) / 1e6;      // renderer TimeTicks = CLOCK_MONOTONIC ms
  let vt = 0, st = 0;                                     // page (virtual) ms and solver ms, since launch
  // Page time advances only here, by `dt` virtual ms. pauseIfNetworkFetchesPending edits network
  // latency out of the footage, but it never expires while a request stays open: an SSE stream,
  // and also a dynamic import() of a module (measured: a lazy-loaded route chunk held it for good,
  // even a 0ms one). network 'auto' (the default) then forces this frame through with policy
  // 'advance', and once the stalls look like a stream rather than a one-off (below), films the
  // rest of the chapter under 'advance': page time runs on regardless of the
  // network, and a load shows for however long it takes in wall time, about a tenth of its real
  // length. 'pause' never forces: it falls back to screencast instead. 'advance' always forces.
  // Which request holds page time is not reported, so a stream is recognised by its behaviour:
  // a request still in flight at two stalls, or stalls on three frames running (which also
  // covers a holder no request event shows, such as a worker's).
  let expiries = 0, net = cap.network === 'advance' ? 'advance' : 'pause', lastStall = null, frame = 0, run = 0;
  cdp.on('Emulation.virtualTimeBudgetExpired', () => expiries++);
  const inFlight = () => [...pending.entries()].sort((a, b) => a[1] - b[1]).map(([r]) => r);
  const describe = rs => rs.length ? `the ${rs[0].resourceType()} request to ${rs[0].url().slice(0, 120)}${rs.length > 1 ? ` (and ${rs.length - 1} more)` : ''} never finished` : 'no visible request was in flight';
  const budget = async (policy, dt, ms) => {
    const want = expiries + 1, t0 = Date.now();
    await cdp.send('Emulation.setVirtualTimePolicy', { policy, budget: dt });
    while (expiries < want) { if (Date.now() - t0 > ms) return false; await new Promise(r => setTimeout(r, 1)); }
    return true;
  };
  const advance = async dt => {
    if (dt <= 0) return;
    frame++;
    const policy = net === 'advance' ? 'advance' : 'pauseIfNetworkFetchesPending';
    if (!(await budget(policy, dt, policy === 'advance' || cap.network === 'pause' ? cap.stallMs : cap.unstickMs))) {
      if (policy === 'advance') throw new Fallback(`page time stopped advancing for ${cap.stallMs / 1000}s even without waiting on the network (${describe(inFlight())})`);
      if (cap.network === 'pause') throw new Fallback(`virtual time stalled for ${cap.stallMs / 1000}s: ${describe(inFlight())}, which holds page time still (long-lived streams such as SSE do this)`);
      const now = inFlight(), held = lastStall ? now.filter(r => lastStall.reqs.has(r)) : [];
      run = lastStall && lastStall.frame === frame - 1 ? run + 1 : 1;
      if (held.length || run >= 3) {
        net = 'advance';
        cap.netNote = held.length ? `${describe(held)} and held page time at two stalls` : `page time stalled on ${run} frames running (${describe(now)})`;
        console.warn(`chapter "${cap.chapter}": ${cap.netNote}; filming the rest of it with page time running regardless of the network (network latency no longer edited out)`);
      }
      lastStall = { frame, reqs: new Set(now) };
      if (!(await budget('advance', dt, cap.stallMs))) throw new Fallback(`page time stopped advancing for ${cap.stallMs / 1000}s (${describe(inFlight())})`);
    }
    vt += dt;
  };
  const step = to => { const dt = (to - st) / 1000; if (dt > 0) { camera.step(dt); cursor.step(st / 1000, dt); } st = to; };
  let applied = { cam: null, x: NaN, y: NaN, cs: NaN, rot: NaN }, camScroll = { x: 0, y: 0 };
  const screen = (cam = camera, cur = cursor) => {
    const b = cam.box(), p = cur.pos();
    return { b, x: (p.x - (b.s > 1 ? b.x : 0)) * b.s, y: (p.y - (b.s > 1 ? b.y : 0)) * b.s };
  };
  // How far anything on screen moves over this frame's shutter, in output (device) px: the camera
  // (the frame corner that moves most) or the pointer, whichever is further. Taken from the
  // solver stepped ahead on copies, so it is the motion the samples will really span.
  const shutterMotion = () => {
    const a = screen(), cam = camera.clone(), cur = cursor.clone(), dt = blur.shutter * FI / 1000;
    cam.step(dt); cur.step(st / 1000, dt);
    const b = screen(cam, cur);
    let d = Math.hypot(b.x - a.x, b.y - a.y);
    for (const [fx, fy] of [[0, 0], [1, 0], [0, 1], [1, 1]]) {
      const px = b.b.x + fx * b.b.w, py = b.b.y + fy * b.b.h;            // page point at the later corner
      d = Math.max(d, Math.hypot(fx * W - (px - a.b.x) * a.b.s, fy * H - (py - a.b.y) * a.b.s));
    }
    return { d: d * dpr };
  };
  // The camera's move across one gap between samples, as an output-pixel map D = k S + (ox, oy)
  // (scale about the origin plus a shift: radial for a zoom, linear for a pan), and `reach`, the
  // furthest it moves a frame corner (a vector, not a sum of the two parts). Of the first and the
  // last gap of the shutter, the larger: a spring speeds up or slows down across it, and the fill
  // has to span the widest gap (the narrower ones get at most that difference extra).
  const gapWarp = N => {
    const g = blur.shutter * FI / 1000 / N, cam = camera.clone(), map = (a, b) => {
      const k = b.s / a.s, ox = (a.x - b.x) * b.s * dpr, oy = (a.y - b.y) * b.s * dpr;
      const reach = Math.max(...[[0, 0], [W * dpr, 0], [0, H * dpr], [W * dpr, H * dpr]].map(([X, Y]) => Math.hypot((k - 1) * X + ox, (k - 1) * Y + oy)));
      return { k, ox, oy, reach };
    };
    const a0 = cam.box(); cam.step(g); const first = map(a0, cam.box());
    cam.step(g * Math.max(0, N - 2)); const a1 = cam.box(); cam.step(g); const last = map(a1, cam.box());
    return first.reach >= last.reach ? first : last;
  };
  // Gap fill: average K copies of the blurred frame, each warped by j/K of that map, so every
  // sample spreads continuously across the gap to the next (copies at most 0.5px apart).
  // Pixels the camera does not move (the fixed point of a zoom) stay as sharp as the samples.
  const fillGraph = w => {
    const K = Math.ceil(w.reach / 0.5), WW = W * dpr, HH = H * dpr, parts = [];
    for (let j = 0; j < K; j++) {
      const f = j / K, kk = 1 + (w.k - 1) * f, src = ([X, Y]) => [((X - w.ox * f) / kk).toFixed(3), ((Y - w.oy * f) / kk).toFixed(3)];
      const [p0, p1, p2, p3] = [[0, 0], [WW, 0], [0, HH], [WW, HH]].map(src);
      parts.push(`[f${j}]perspective=x0=${p0[0]}:y0=${p0[1]}:x1=${p1[0]}:y1=${p1[1]}:x2=${p2[0]}:y2=${p2[1]}:x3=${p3[0]}:y3=${p3[1]}:interpolation=linear[g${j}]`);
    }
    return `,format=gbrp,split=${K}${Array.from({ length: K }, (_, j) => `[f${j}]`).join('')};${parts.join(';')};${Array.from({ length: K }, (_, j) => `[g${j}]`).join('')}mix=inputs=${K}`;
  };
  // Pose camera and pointer for page time `to`, then draw. The pointer is posed directly (exact)
  // and a real mouseMoved follows it once per output frame, so hover states match what is filmed.
  const apply = async (mouse) => {
    const b = camera.box(), zoomed = b.s > 1 + 1e-6;
    const key = zoomed ? [b.x, b.y, b.s].map(v => v.toFixed(5)).join() : null;
    if (key !== applied.cam) {
      // Under --force-device-scale-factor the override's viewport x/y are DEVICE pixels (measured:
      // x 300 at dpr 2 framed CSS x 150, at scale 1.5, 2 and 3 alike), width/height and scale are not.
      if (zoomed) await cdp.send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 0, mobile: false,
        viewport: { x: (b.x + camScroll.x) * dpr, y: (b.y + camScroll.y) * dpr, width: b.w, height: b.h, scale: b.s } });
      else await cdp.send('Emulation.clearDeviceMetricsOverride');
      applied.cam = key;
    }
    const p = cursor.pos(), cs = 1 / b.s, rot = cursor.tiltAmt ? tilt(cursor.vx, cursor.tiltAmt) : 0;
    if (Math.abs(p.x - applied.x) > 0.01 || Math.abs(p.y - applied.y) > 0.01 || cs !== applied.cs || Math.abs(rot - applied.rot) > 0.01 || renav) {
      await pose({ x: +p.x.toFixed(2), y: +p.y.toFixed(2), cs, rot: +rot.toFixed(2) }, navigating || renav);
      // Cap's renderer thins its cursor path to 60fps and drops moves under 1/1920 of the screen; here the
      // real pointer moves at most once per output frame, and only when it moved.
      if (mouse && (Math.hypot(p.x - applied.x, p.y - applied.y) > 0.5 || renav)) cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: p.x, y: p.y }).catch(() => {});
      applied = { ...applied, x: p.x, y: p.y, cs, rot }; renav = false;
    }
  };
  let renav = false;
  // A new document: re-pose the pointer in it, and prime the pipeline again before filming (the
  // first ~24 frames after a load repeat; frames of the page before it must not count).
  page.on('framenavigated', f => { if (f === page.mainFrame()) { renav = true; navigating = false; primed = 0; } });
  const draw = async (to, grab) => {
    await advance(to - vt);
    ticks += to - (draw.last ?? to - FI); draw.last = to;
    const r = await cdp.send('HeadlessExperimental.beginFrame', { frameTimeTicks: ticks, interval: FI,
      // optimizeForSpeed: 7.8 -> 10.7 PNG frames/s and still lossless (measured).
      ...(grab ? { screenshot: { format: 'png', optimizeForSpeed: true } } : {}) });
    if (grab && !r.screenshotData) throw new Fallback('beginFrame returned no image (the renderer never became ready)');
    return grab ? Buffer.from(r.screenshotData, 'base64') : null;
  };

  let tNext = FI, recording = false, n = 0, primed = 0, prevPng = null, waiters = [], pumping = true;
  const blurFrames = [], stats = { maxSamples: 0, maxGap: 0, filled: 0, peakTempMB: 0 };
  // The camera's pose on each frame where it changed, [frame, x, y, s] in the same space as the
  // camera events' boxes: compose moves its spotlight and crop with the content it films.
  const poses = [];
  // ffmpeg averages each blurred frame in the background while capture goes on, two at a time:
  // mix over its N sub-frames (blurArgs), then the gap fill on that one average.
  // Every job settles; a failure stops the take at once through `abort` (filming on at 40x
  // real time after ffmpeg has failed wastes the wait), and its sub-frames are removed either way.
  // A take that falls back is re-filmed into the same directory, so close() kills and awaits every
  // job first; a job that ends after that is ignored rather than writing into the new take.
  const QMAX = 4, queue = [], busy = [], kids = new Set();
  let cancelled = false, tempBytes = 0;
  const abort = e => { if (failure || closing) return; failure = e; pumping = false; rejectFailed(e); for (const w of waiters) w.reject(e); };
  // A browser or renderer that dies leaves CDP calls pending for good (measured: a killed browser
  // hung the frame loop until the hard timeout), so its death ends the take at once, as a fallback.
  let closing = false;
  browser.on('disconnected', () => abort(new Fallback('the browser exited mid-take')));
  page.on('crash', () => abort(new Fallback('the page crashed mid-take')));
  const average = item => { queue.push(item); drain(); };
  const drain = () => {
    while (!cancelled && !failure && busy.length < 2 && queue.length) {
      const { sub, N, out, fill, bytes } = queue.shift();
      let kid;
      const job = new Promise(res => {
        kid = execFile(ffbin('ffmpeg'), blurArgs(sub, N, fill, out), e => {
          kids.delete(kid);
          let err = null;
          if (!cancelled) {
            if (e) err = new Error(`motion blur averaging failed for ${out}: ${String(e.message).split('\n').slice(-2).join(' ')}`);
            else if (!fs.existsSync(out)) err = new Error(`motion blur averaging wrote no frame to ${out} (ffmpeg exited 0)`);
          }
          try { fs.rmSync(sub, { recursive: true, force: true }); } catch (r) { err ??= r; }
          tempBytes -= bytes;
          if (err && !cancelled) abort(err);
          res();
        });
        kids.add(kid);
      });
      busy.push(job); job.then(() => { busy.splice(busy.indexOf(job), 1); drain(); });
    }
  };
  const averaged = async () => {
    while (!failure && (queue.length || busy.length)) await Promise.all(busy);
    if (failure) throw failure;
  };
  const cancelBlur = async () => {
    cancelled = true; queue.length = 0; for (const k of kids) k.kill('SIGKILL'); await Promise.all([...busy]);
    try { fs.rmSync(path.join(dir, 'sub'), { recursive: true, force: true }); } catch {}
  };
  const name = k => `${String(k).padStart(5, '0')}.png`;
  const pump = (async () => {
    while (pumping) {
      if (Date.now() - started > cap.timeoutMs) throw new Fallback(`hard timeout: the chapter took over ${cap.timeoutMs / 1000}s of wall time (raise capture.timeoutMs)`);
      // On the frame grid, not vt + FI: a blurred frame's sub-frames carry vt part way into the
      // next interval, and stepping from there drifted page time half a frame ahead per blurred frame.
      const t = tNext; tNext += FI;
      step(t); await apply(true);
      if (!recording) { await draw(t, false); primed++; }
      else {
        const sm = blur ? shutterMotion() : { d: 0 };
        const pb = camera.box(), pose = [n, ...[pb.x, pb.y, pb.s].map((v) => +v.toFixed(4))];
        if (!poses.length || pose.slice(1).some((v, i) => v !== poses.at(-1)[i + 1])) poses.push(pose);
        let buf = await draw(t, true);
        if (n === 0) {                                     // the size check, once: a 1x frame means DSF did not apply
          const w = buf.readUInt32BE(16), h = buf.readUInt32BE(20);
          if (w !== Math.round(W * dpr) || h !== Math.round(H * dpr)) throw new Fallback(`frames came back ${w}x${h}, not ${W * dpr}x${H * dpr}`);
        }
        if (blur && sm.d > blur.threshold) {
          // Motion blur: average renders spread over the shutter (0.5 of the frame interval: a 180
          // degree shutter). Static pixels average to themselves, so only what moves smears. The
          // sample count comes from how far things move over the shutter, so that neighbouring
          // samples sit at most `spacing` output px apart (up to `max` samples): at about 4px
          // apart a fast zoom filmed striated copies of every glyph instead of a smear (looked
          // at). Glyph edges still land on whole pixels in each sample, so a camera move also gets
          // the gap fill above, which turns the remaining steps into a continuous smear.
          const N = clamp(Math.ceil(sm.d / blur.spacing), blur.samples, blur.max), gap = sm.d / N;
          // The fill follows the camera's own gap, so a frame the pointer leads gets none.
          const w = gapWarp(N), fill = w.reach > 0.5 ? fillGraph(w) : '';   // under 0.5px: nothing to fill
          stats.maxSamples = Math.max(stats.maxSamples, N); stats.maxGap = Math.max(stats.maxGap, +gap.toFixed(2)); if (fill) stats.filled++;
          // Backpressure: each waiting frame holds up to `max` full-size PNGs on disk, so rendering
          // waits while QMAX frames are already queued for ffmpeg.
          while (queue.length >= QMAX && !failure) await Promise.race(busy);
          if (failure) break;
          const sub = path.join(dir, 'sub', String(n)), put = (k, png) => {
            fs.writeFileSync(path.join(sub, `${String(k).padStart(2, '0')}.png`), png);
            tempBytes += png.length; stats.peakTempMB = Math.max(stats.peakTempMB, Math.round(tempBytes / 1e6));
            return png.length;
          };
          fs.mkdirSync(sub, { recursive: true });
          let bytes = put(0, buf);
          for (let k = 1; k < N; k++) {
            const tk = t + k * blur.shutter * FI / N;
            step(tk); await apply(false);
            bytes += put(k, await draw(tk, true));
          }
          average({ sub, N, out: path.join(dir, 'cfr', name(n)), fill, bytes });
          blurFrames.push(n); prevPng = null;
        } else if (prevPng && buf.equals(prevPng)) fs.linkSync(path.join(dir, 'cfr', name(n - 1)), path.join(dir, 'cfr', name(n)));
        else { fs.writeFileSync(path.join(dir, 'cfr', name(n)), buf); prevPng = buf; }
        n++;
      }
      waiters = waiters.filter(w => !w.done() || (w.resolve(), false));
    }
  })();
  pump.catch(e => { failure = e instanceof Fallback ? e : new Fallback(`capture failed: ${e.message.split('\n')[0]}`); pumping = false; rejectFailed(failure); for (const w of waiters) w.reject(failure); });
  const until = done => failure ? Promise.reject(failure) : new Promise((resolve, reject) => waiters.push({ done, resolve, reject }));
  // Footage time of the next frame to be filmed: what an event logged now first appears in.
  const footNow = () => recording ? n / fps : 0;
  const ts = ms => ms / CLICK_LEAD_MS;

  const rec = {
    page, cdp, filming: false, failed, speed: 0, pace: 1,
    set cursorTilt(v) { cursor.tiltAmt = v === true ? 0.15 : +v || 0; },
    get cam() { const b = camera.box(); return b.s > 1 + 1e-6 ? b : null; },
    get camScroll() { return camScroll; },
    // Playwright's own timeouts are wall time, which runs several times slower than footage here.
    T: ms => ms * 10,
    now: footNow,
    ms: () => vt,                    // the clock waits run on: page time, which stands still while a fetch is in flight
    sleep: ms => { const end = vt + Math.max(FI, ms); return until(() => vt >= end - 1e-6); },
    async start() {
      rec.filming = true;
      // The first ~24 beginFrames after a load repeat the same content while the pipeline primes.
      await until(() => primed >= 30);
      recording = true;
      await until(() => n >= 1);
    },
    // zoom.ms 700 plays Cap's camera spring unscaled; the beat moves on once it has settled.
    async glide(to, ms) {
      if (!rec.cam && to.s > 1) camScroll = await page.evaluate(() => ({ x: scrollX, y: scrollY }));
      camera.aim(to, ms / CAMERA_REF_MS);
      await until(() => camera.settled());
    },
    // The pointer glides on its spring. For a click the target is set CLICK_LEAD_MS (scaled)
    // ahead of the press and the spring stiffens just before it, so it lands, then presses.
    // cursor.speed sets the glide time to distance / speed (at least 250ms) instead of 500ms.
    async glideTo(x, y, ms, click) {
      const d = Math.hypot(x - cursor.x.to, y - cursor.y.to);
      const glide = rec.speed ? Math.max(250, d / rec.speed * 1000) * rec.pace : CLICK_LEAD_MS * rec.pace;
      if (click) { const press = cursor.click(st / 1000, x, y, ts(glide)) * 1000; await until(() => st >= press - 1e-6); }
      else { cursor.aim(st / 1000, x, y, ts(glide)); await until(() => cursor.settled()); }
    },
    // No drift: frames are rendered on demand, so a still page still films. The pointer parks
    // beside the mark just made (off its lower right corner, kept inside the camera box) so it
    // never sits on what the spotlight will point at.
    async hold(ms, mark) {
      const end = vt + ms;
      if (mark) {
        const b = camera.target(), m = 18 / b.s;
        const x = clamp(mark.x + mark.w + m, b.x + m, b.x + b.w - 3 * m), y = clamp(mark.y + mark.h + m, b.y + m, b.y + b.h - 3 * m);
        cursor.aim(st / 1000, x, y, ts(Math.min(ms, CLICK_LEAD_MS * rec.pace)));
      }
      await until(() => vt >= end - 1e-6);
    },
    async stop() {
      pumping = false; await pump.catch(() => {});
      if (failure) throw failure;
      await averaged(); fs.rmSync(path.join(dir, 'sub'), { recursive: true, force: true });
      // Every frame must be on disk: encode.sh reads cfr/ as a sequence and stops at the first gap.
      const gapAt = Array.from({ length: n }, (_, k) => k).find(k => !fs.existsSync(path.join(dir, 'cfr', name(k))));
      if (gapAt !== undefined) throw new Error(`frame ${gapAt} of ${n} is missing from ${path.join(dir, 'cfr')}`);
      const spans = [];
      for (const k of blurFrames) { if (spans.length && spans.at(-1)[1] === k - 1) spans.at(-1)[1] = k; else spans.push([k, k]); }
      return { frames: n, dur: (n - 1) / fps, fps, dpr, blurSpans: spans, blurStats: stats, poses };
    },
    // The frame loop may be stuck in a call to a dead browser: wait for it a few seconds at most.
    close: async () => {
      closing = true; pumping = false;
      let wait;
      await Promise.race([pump.catch(() => {}), new Promise(r => { wait = setTimeout(r, 3000); })]);
      clearTimeout(wait);                                   // else node lingers out the 3 s
      await cancelBlur(); await browser.close().catch(() => {});
    },
  };
  return rec;
}

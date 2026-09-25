// ABOUTME: Screen-capture rig for product demos. Drives a real app with real
// clicks, films it via CDP screencast, and emits footage plus an events file
// that a compositor (HyperFrames) uses to place annotations.
//
// Why the pieces are the way they are, all measured rather than assumed:
//  - CDP screencast emits ONLY on repaint. A settled page produces no frames,
//    so the clip ends early. The synthetic cursor drifting during a hold keeps
//    the compositor busy; it is load-bearing, not decoration.
//  - Screencast always emits at CSS-viewport size. deviceScaleFactor 1/2/3 and
//    maxWidth 2560/3840 all produced 1280x720. So you cannot "record at 2x and
//    crop" -- zoom must happen in the browser.
//  - Zoom uses Emulation.setDeviceMetricsOverride's viewport clip. CSS
//    transform on <html> re-rasters crisply but makes the root the containing
//    block for position:fixed, which throws fixed chrome into mid-frame.
//  - Never select by bare text. A bare text selector for a nav label matched an
//    article headline and navigated away from the nav entirely. Scope every selector.
import fs from 'fs'; import path from 'path';
// Browsers come from $PLAYWRIGHT_BROWSERS_PATH when set, else Playwright's own default.
import { chromium } from '@playwright/test';

const smoothstep = p => p * p * (3 - 2 * p);
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

// A mis-click must fail the take, not quietly film the wrong screen.
export function checkPath(expected, url, name = '?') {
  const got = new URL(url).pathname;
  const ok = expected instanceof RegExp ? expected.test(got) : got.startsWith(expected);
  if (!ok) throw new Error(`beat "${name}": expected path ${expected}, got ${got}`);
}

// Resolve when no request has been in flight for `quiet` ms, or after `cap` ms.
// Fixed settle delays were too short after navigation and ended takes on the
// app's loading splash. Prefer a beat's `ready` selector; this is the fallback.
function networkQuiet(page, { quiet = 500, cap = 8000 } = {}) {
  let inflight = 0, last = Date.now();
  const skip = r => ['websocket', 'eventsource'].includes(r.resourceType());
  const up = r => { if (!skip(r)) { inflight++; last = Date.now(); } };
  const down = r => { if (!skip(r)) { inflight = Math.max(0, inflight - 1); last = Date.now(); } };
  page.on('request', up); page.on('requestfinished', down); page.on('requestfailed', down);
  // Listeners attach now (before the action); the quiet window starts when awaited.
  return async () => {
    const start = Date.now(); last = Math.max(last, start);
    // ponytail: long-poll requests hold the count up, so such pages always hit the cap; give those beats a `ready` selector.
    while (Date.now() - start < cap && (inflight > 0 || Date.now() - last < quiet)) await page.waitForTimeout(50);
    page.off('request', up); page.off('requestfinished', down); page.off('requestfailed', down);
    if (Date.now() - start >= cap) console.warn(`network not quiet after ${cap}ms; add a \`ready\` selector to this beat`);
  };
}

// Drive the real login form and save storageState. Never hand-write a token
// into a state file: it fails silently and films the /login page instead.
// Defaults match the first SPA this was built on: #email is input[type=text], a cookie modal covers the
// submit button, and type() (not fill()) is what the controlled inputs accept.
export async function mintState({ base, email, password, state, loginPath = '/login',
  emailSel = '#email', passwordSel = '#password',
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
    await page.waitForURL(u => !u.pathname.startsWith(loginPath), { timeout: 20000 })
      .catch(() => { throw new Error(`login as ${email} did not leave ${loginPath}`); });
    fs.mkdirSync(path.dirname(state), { recursive: true });
    await ctx.storageState({ path: state });
  } finally { await browser.close(); }
}

// Reuse `state` if it still gets past the login page, otherwise mint a fresh one.
export async function ensureState({ base, state, login, probe = '/home' }) {
  if (fs.existsSync(state)) {
    const browser = await chromium.launch();
    const ctx = await browser.newContext({ storageState: state });
    const page = await ctx.newPage();
    const quiet = networkQuiet(page);
    await page.goto(base + probe); await quiet(); await page.waitForTimeout(1000);
    const got = new URL(page.url()).pathname;
    await browser.close();
    if (!got.startsWith(login.loginPath ?? '/login')) return 'reused';
  }
  await mintState({ base, state, ...login });
  return 'minted';
}

export async function capture({ base, state, out, viewport = { width: 1280, height: 720 }, beats, chapter, localStorage: ls = {} }) {
  const { width: W, height: H } = viewport;
  if (!beats[0]?.goto) throw new Error(`chapter "${chapter}": first beat must be a goto (filming starts once it has painted)`);
  const dir = path.join(out, chapter);
  fs.rmSync(dir, { recursive: true, force: true }); fs.mkdirSync(dir, { recursive: true });

  const browser = await chromium.launch();
  try {
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: 1, storageState: state });
  const page = await ctx.newPage();

  await page.addInitScript(ls => {
    // e.g. consent keys: a consent banner otherwise covers the lower third of every frame.
    for (const [k, v] of Object.entries(ls)) localStorage.setItem(k, v);
    const mount = () => {
      if (document.getElementById('__cur')) return;
      const d = document.createElement('div'); d.id = '__cur';
      d.style.cssText = 'position:fixed;top:0;left:0;width:20px;height:26px;pointer-events:none;z-index:2147483647;transition:transform .05s linear;will-change:transform;background:no-repeat center/contain url("data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' width=\'20\' height=\'26\' viewBox=\'0 0 18 24\'%3E%3Cpath d=\'M2 2 L2 18 L6.5 13.8 L9.2 20 L11.8 19 L9.1 13 L14.5 13 Z\' fill=\'white\' stroke=\'black\' stroke-width=\'1.4\' stroke-linejoin=\'round\'/%3E%3C/svg%3E")';
      document.body.appendChild(d);
      const ring = document.createElement('div'); ring.id = '__ring';
      ring.style.cssText = 'position:fixed;top:0;left:0;width:0;height:0;border-radius:50%;border:2px solid #1ABC9C;pointer-events:none;z-index:2147483646;opacity:0';
      document.body.appendChild(ring);
      addEventListener('mousemove', e => { d.style.transform = `translate(${e.clientX}px,${e.clientY}px)`; }, { passive: true });
      // Click ripple, so a viewer can see WHERE the click landed.
      addEventListener('mousedown', e => {
        ring.style.cssText += `;left:${e.clientX - 26}px;top:${e.clientY - 26}px;width:52px;height:52px;opacity:1;transition:none`;
        requestAnimationFrame(() => { ring.style.transition = 'opacity .5s ease, transform .5s ease'; ring.style.transform = 'scale(1.7)'; ring.style.opacity = '0'; });
      }, true);
    };
    document.readyState === 'loading' ? addEventListener('DOMContentLoaded', mount) : mount();
  }, ls);

  const cdp = await ctx.newCDPSession(page);
  const frames = []; const events = [];
  let t0 = null, filming = false;
  cdp.on('Page.screencastFrame', async e => {
    if (t0 === null) t0 = e.metadata.timestamp;
    frames.push({ buf: Buffer.from(e.data, 'base64'), t: e.metadata.timestamp });
    try { await cdp.send('Page.screencastFrameAck', { sessionId: e.sessionId }); } catch {}
  });

  // Wall clock, not frames.at(-1): frame delivery lagged the screen by ~1s at 46s into a take.
  const now = () => (t0 === null ? 0 : Date.now() / 1000 - t0);
  let cam = null;                                  // null == full frame
  // cam and rects are viewport-relative, but the override's viewport x/y are document-relative:
  // after a 520px scroll, y=0 filmed the blank page top. Add the scroll, read once while unzoomed
  // (an active override moves scrollX/Y itself, so re-reading mid-glide compounds).
  let camScroll = { x: 0, y: 0 };
  const setCam = async v => {
    const prev = cam; cam = v;
    if (!v) { await cdp.send('Emulation.clearDeviceMetricsOverride'); return; }
    if (!prev) camScroll = await page.evaluate(() => ({ x: scrollX, y: scrollY }));
    await cdp.send('Emulation.setDeviceMetricsOverride', {
      width: W, height: H, deviceScaleFactor: 1, mobile: false,
      viewport: { x: v.x + camScroll.x, y: v.y + camScroll.y, width: v.w, height: v.h, scale: v.s },
    });
  };

  let cx = W / 2, cy = H / 2, drift = 1;
  const hold = async ms => {
    const end = Date.now() + ms;
    // Drift inside the camera box: a cursor moving outside the zoomed region repaints nothing
    // visible, the screencast stops emitting, and the mp4 froze on the pre-zoom frame for 2.4s.
    const b = cam || { x: 0, y: 0, w: W, h: H, s: 1 };
    const lo = b.x + b.w * 0.30, hi = b.x + b.w * 0.72, ymid = b.y + b.h * 0.55;
    if (cx < lo || cx > hi || Math.abs(cy - ymid) > b.h * 0.3) { cx = (lo + hi) / 2; cy = ymid; await page.mouse.move(cx, cy, { steps: 12 }); }
    while (Date.now() < end) {
      cx += 1.6 / b.s * drift; if (cx > hi || cx < lo) drift = -drift;
      cy += 0.4 / b.s * drift;
      await page.mouse.move(cx, cy);
      await page.waitForTimeout(60);
    }
  };

  // Targets are resolved fresh every beat: nav bars change with context
  // (one item vanished from the nav after another was clicked), so cached handles go stale.
  const rectOf = async (sel, beat) => {
    const el = page.locator(sel).first();
    if (!(await el.count())) throw new Error(`beat "${beat}": selector ${sel} matched nothing`);
    return el.evaluate(n => { const r = n.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; });
  };

  // Ease the camera between two viewport boxes so the push-in reads as a move,
  // not a cut. Each step is its own override; the screencast repaints on each.
  const glide = async (to, ms) => {
    const from = cam || { x: 0, y: 0, w: W, h: H, s: 1 };
    const steps = Math.max(6, Math.round(ms / 45));
    for (let i = 1; i <= steps; i++) {
      const e = smoothstep(i / steps);
      await setCam({
        x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e,
        w: from.w + (to.w - from.w) * e, h: from.h + (to.h - from.h) * e,
        s: from.s + (to.s - from.s) * e,
      });
      await page.waitForTimeout(30);
    }
  };
  const boxFor = (r, s) => {
    const vw = W / s, vh = H / s;
    return { x: clamp(r.x + r.w / 2 - vw / 2, 0, Math.max(0, W - vw)),
             y: clamp(r.y + r.h / 2 - vh / 2, 0, Math.max(0, H - vh)), w: vw, h: vh, s };
  };

  for (const [i, step] of beats.entries()) {
    const name = step.name || `#${i}`;
    let quiet = null;
    if (step.goto || step.click) quiet = step.ready ? null : networkQuiet(page, { cap: step.readyCap });
    if (step.goto) await page.goto(base + step.goto, { waitUntil: 'domcontentloaded' });
    if (step.click) {
      const el = page.locator(step.click).first();
      if (!(await el.count())) throw new Error(`beat "${name}": selector ${step.click} matched nothing`);
      const r = await el.boundingBox();
      if (r) { await page.mouse.move(r.x + r.width / 2, r.y + r.height / 2, { steps: 18 }); await page.waitForTimeout(220); }
      await el.click({ timeout: 8000 });
    }
    if (step.goto || step.click) {
      if (step.ready) await page.locator(step.ready).first().waitFor({ state: 'visible', timeout: step.readyCap ?? 15000 });
      else await quiet();
      await page.waitForTimeout(step.settle ?? 400);
    }
    if (step.expectPath) checkPath(step.expectPath, page.url(), name);
    // Start filming only once the first page is ready: starting before paint
    // put a white about:blank frame plus ~85 black splash frames at the head.
    if (!filming) {
      filming = true;
      // Park the cursor first, or frame 0 shows it at the (0,0) mount position.
      await page.mouse.move(cx, cy); await page.waitForTimeout(100);
      await cdp.send('Page.startScreencast', { format: 'jpeg', quality: 90, everyNthFrame: 1 });
    }
    if (step.scroll) { await page.evaluate(y => window.scrollBy({ top: y, behavior: 'smooth' }), step.scroll); await page.waitForTimeout(700); }
    if (step.zoom) {
      const r = await rectOf(step.zoom.on, name);
      // Zooming while zoomed: the override may have moved the scroll since camScroll was read.
      if (cam) { const sc = await page.evaluate(() => ({ x: scrollX, y: scrollY })); r.x += sc.x - camScroll.x; r.y += sc.y - camScroll.y; }
      await glide(boxFor(r, step.zoom.scale ?? 2), step.zoom.ms ?? 700);
    }
    // Clear the override at the end, or the page stays under a scale-1 emulation.
    if (step.wide)   { await glide({ x: 0, y: 0, w: W, h: H, s: 1 }, step.wide === true ? 700 : step.wide); await setCam(null); }
    // A mark is the handoff to the compositor: what to point at, and when.
    if (step.mark)   events.push({ t: now(), kind: 'mark', label: step.mark.label, rect: await rectOf(step.mark.on, name), cam });
    if (step.hold)   await hold(step.hold);
  }

  await hold(500);
  await cdp.send('Page.stopScreencast');

  // List only frames >=1/60s apart so every duration is exact. Clamping each duration to 16ms
  // instead ran the mp4 1.2s long over 50s (849 clamped frames) and put marks early.
  frames.forEach((f, i) => fs.writeFileSync(path.join(dir, `f${String(i).padStart(5, '0')}.jpg`), f.buf));
  const keep = [];
  frames.forEach((f, i) => { if (!keep.length || f.t - frames[keep.at(-1)].t >= 1 / 60 || i === frames.length - 1) keep.push(i); });
  let list = '';
  keep.forEach((i, k) => {
    const next = keep[k + 1] !== undefined ? frames[keep[k + 1]].t : frames[i].t + 0.033;
    list += `file 'f${String(i).padStart(5, '0')}.jpg'\nduration ${Math.max(0.001, next - frames[i].t).toFixed(4)}\n`;
  });
  if (keep.length) list += `file 'f${String(keep.at(-1)).padStart(5, '0')}.jpg'\n`;
  fs.writeFileSync(path.join(dir, 'list.txt'), list);
  const dur = frames.length ? frames.at(-1).t - t0 : 0;
  fs.writeFileSync(path.join(dir, 'events.json'), JSON.stringify({ chapter, viewport, dur, frames: frames.length, events }, null, 1));
  return { frames: frames.length, dur, events: events.length, dir };
  } finally { await browser.close(); }
}

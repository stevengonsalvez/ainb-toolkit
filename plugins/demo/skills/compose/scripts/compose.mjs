#!/usr/bin/env node
// compose.mjs <config.json> [segment ...]
// Generates one standalone HyperFrames project per chapter, plus title / switch / end cards.
// Everything app-specific comes from the config. Nothing here knows what app was filmed.
import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, copyFileSync, existsSync } from 'node:fs';
import { dirname, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig, segmentNames, seams, seamsOf, screenRect, VERTICAL, eventsPath, r3, esc, grayFrames, mad, hexToRgba } from './config.mjs';
import { audioSettings, narrationClips, fitNarration, beatGrid } from './audio.mjs';
import { cues as captionCues } from './captions.mjs';

const cfgPath = process.argv[2];
if (!cfgPath) { console.error('usage: compose.mjs <config.json> [segment ...]'); process.exit(2); }
const C = loadConfig(cfgPath);
const SKILL = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const W = C.dw, H = C.dh, SAFE = C.layout.safeMargin;   // design px, see the document section
const F = (x) => r3(x * C.pace);          // fade and card-motion timings scale with pace

// ---------- project scaffold ----------
// ponytail: one standalone project per segment so each renders alone (render memory) and lint stays clean
function project(name, html) {
  const d = `${C.out}/projects/${name}`;
  mkdirSync(`${d}/assets/fonts`, { recursive: true });
  mkdirSync(`${d}/assets/footage`, { recursive: true });
  for (const f of ['hyperframes.json', 'package.json', 'gsap.min.js']) copyFileSync(`${SKILL}/assets/template/${f}`, `${d}/${f}`);
  writeFileSync(`${d}/meta.json`, JSON.stringify({ id: name, name, createdAt: new Date(0).toISOString() }, null, 1));
  for (const f of C.fontFiles) copyFileSync(f, `${d}/assets/fonts/${basename(f)}`);
  // Grain tile for the backdrop: fixed-seed noise, so every render of it is identical. A bitmap
  // tile costs nothing per frame; an SVG feTurbulence grain cost ~0.3s a frame at 1440p (measured).
  const grain = `${C.out}/work/grain.png`;
  if (!existsSync(grain)) execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=gray:s=256x256',
    '-vf', 'noise=alls=64:allf=u:all_seed=7,format=gray', '-frames:v', '1', grain]);
  copyFileSync(grain, `${d}/assets/grain.png`);
  writeFileSync(`${d}/index.html`, html);
  return d;
}

// ---------- footage analysis ----------
// Every external command is argv, never a shell string: config values reach these paths.
function freezes(mp4) {
  const out = spawnSync(C.ffmpeg, ['-hide_banner', '-nostats', '-i', mp4, '-vf', 'freezedetect=n=0.002:d=2', '-map', '0:v', '-f', 'null', '-'],
    { encoding: 'utf8', maxBuffer: 1 << 26 }).stderr;
  const s = [...out.matchAll(/freeze_start: ([\d.]+)/g)].map((m) => +m[1]);
  const e = [...out.matchAll(/freeze_end: ([\d.]+)/g)].map((m) => +m[1]);
  return s.map((a, i) => [a, e[i] ?? 1e9]);
}

// DEFECT 1 guard: a hold must not run past a camera move. Returns the first time after t+0.3
// where the frame differs from the t+0.3 pose (mean abs luma diff > 2 at 160x90). The scan
// covers the longest hold allowed (pace can raise hold.max), so an unseen move cannot slip in.
function stableUntil(mp4, t) {
  const t0 = t + 0.3, f = grayFrames(C.ffmpeg, mp4, { t: t0, len: Math.max(2.6, C.hold.max + 0.4), fps: 10 });
  for (let k = 1; k < f.n; k++) if (mad(f.at(k), f.at(0)) > 2) return t0 + k / 10;
  return t0 + f.n / 10;
}

// When the camera move capture logged as ending at t1 has really landed in the footage. t1 is
// logged after the last pose plus a 30ms wait, and that pose reaches the footage 16-63ms later
// (measured), so every frame-to-frame change (mean abs luma diff > 0.5 at 160x90; the drifting
// cursor alone measures under 0.1) up to SETTLE_WINDOW after t1 counts as the camera landing,
// with room for a slow landing under load. Only changes after that window are the page itself
// moving: they no longer delay the spotlight (an animated page used to, by ~0.4s) and are warned about.
const SETTLE_WINDOW = 0.25;
function settledAt(mp4, t1, name, fps) {
  const a = Math.max(0, t1 - 0.1), f = grayFrames(C.ffmpeg, mp4, { t: a, len: t1 + SETTLE_WINDOW + 0.15 - a });
  const tk = (k) => Math.ceil(a * fps) / fps + k / fps;   // the take's own rate (events.json fps)
  let settle = t1, moving = false;
  for (let k = 1; k < f.n; k++) {
    if (mad(f.at(k), f.at(k - 1)) <= 0.5) continue;
    if (tk(k) <= t1 + SETTLE_WINDOW) settle = Math.max(settle, tk(k)); else moving = true;
  }
  if (moving) console.warn(`  warn ${name}: the frame keeps changing more than ${SETTLE_WINDOW}s after the camera move that ended at ${r3(t1)}s. That is the page moving, not the camera; the spotlight starts at ${r3(settle)}s regardless`);
  return settle;
}

// subtract intervals `cuts` from [0,dur] -> kept ranges
function keep(dur, cuts) {
  cuts = cuts.filter(([a, b]) => b - a > 0.05).sort((x, y) => x[0] - y[0]);
  const out = []; let cur = 0;
  for (const [a, b] of cuts) { if (a > cur) out.push([cur, a]); cur = Math.max(cur, b); }
  if (cur < dur) out.push([cur, dur]);
  return out;
}

// ---------- document ----------
// Everything is laid out in design px (W x H: 1280x720 or 1080x1080) inside #stage, which CSS
// zoom scales to the canvas, so type and geometry rasterise at master size. Layers, back to front:
// #bg backdrop and grain (shared by every segment, so a crossfade between two segments only moves
// content), then #content: cards, and the framed window holding the footage, spotlight and labels.
const T = C.theme, FR = C.frame, Z = C.zoom;
const SR = screenRect(C), WS = SR.ws, PAD = SR.pad, PADY = SR.padY, SCW = SR.sw, SCH = SR.sh;   // the screen, see config.mjs
const BACK = FR ?? { backdrop: 'glow', grain: 0.045 };
const faces = C.fontFaces.join('\n');
const tint = (hex, a) => hexToRgba(hex, a);
const backdrop = {
  solid: T.bg,
  gradient: `linear-gradient(155deg, color-mix(in oklab, ${T.bg} 90%, white), ${T.bg} 55%, color-mix(in oklab, ${T.bg} 88%, black))`,
};
backdrop.glow = `radial-gradient(55% 70% at 12% 8%, ${tint(T.accent, 0.20)}, transparent 70%),
  radial-gradient(50% 65% at 92% 96%, ${tint(T.highlight, 0.14)}, transparent 70%), ${backdrop.gradient}`;
// Continuous-curvature (squircle, superellipse n=4) outline for the window, as a polygon:
// clip-path, not overflow + corner-shape, which drops the spotlight's backdrop-filter mask (measured).
function squircle(w, h, r, k = 10) {
  const sp = (v) => Math.sign(v) * Math.sqrt(Math.abs(v));          // superellipse n=4: |x|^4 + |y|^4 = 1
  const pts = [];
  // clockwise from the left edge: corner centres with their quarter of the angle range
  for (const [cx, cy, a0] of [[r, r, Math.PI], [w - r, r, 1.5 * Math.PI], [w - r, h - r, 0], [r, h - r, 0.5 * Math.PI]]) {
    for (let i = 0; i <= k; i++) { const a = a0 + (Math.PI / 2) * (i / k); pts.push([cx + r * sp(Math.cos(a)), cy + r * sp(Math.sin(a))]); }
  }
  return `polygon(${pts.map(([x, y]) => `${r3(x)}px ${r3(y)}px`).join(', ')})`;
}
const WW = SCW * WS, WH = SCH * WS, R = FR ? FR.radius : 0, SH = FR ? FR.shadow : 0;
const ink = (a) => tint(T.text, a);
const shadow = SH ? `0 0 0 1px ${ink(0.08 * SH)}, 0 1px 2px ${ink(0.16 * SH)}, 0 10px 24px ${ink(0.14 * SH)}, 0 36px 80px ${ink(0.22 * SH)}` : 'none';
const SP = C.spotlight, FE = SP.feather, VS = VERTICAL.safe, VERT = C.format === 'vertical';
const band = (dir, a, b) => `linear-gradient(${dir}, transparent calc(var(${a}) - ${FE}px), #000 var(${a}), #000 calc(var(${a}) + var(${b})), transparent calc(var(${a}) + var(${b}) + ${FE}px))`;
const STYLE = `
${faces}
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: ${C.width}px; height: ${C.height}px; overflow: hidden; background: ${T.bg}; }
#root { position: relative; width: 100%; height: 100%; overflow: hidden; background: ${T.bg};
  font-family: ${C.bodyStack}; color: ${T.text}; }
#stage { position: absolute; left: 0; top: 0; width: ${W}px; height: ${H}px; zoom: ${Z}; }
/* A png-sequence render forces the root and body transparent, and concat.sh flattens any
   transparent pixel to black (measured without this). Invariant: every visible element sits on
   an opaque layer; this full-bleed fill is that layer for the root. concat.sh warns otherwise. */
#bg { position: absolute; inset: 0; background: ${backdrop[BACK.backdrop]}; }
#grain { position: absolute; inset: 0; opacity: ${BACK.grain}; background: url(assets/grain.png) repeat; background-size: ${r3(256 / Z)}px; }
#content { position: absolute; inset: 0; }
.winwrap { position: absolute; left: ${r3(PAD)}px; top: ${r3(PADY)}px; width: ${r3(WW)}px; height: ${r3(WH)}px; }
.winshadow { position: absolute; inset: 0; border-radius: ${R}px; corner-shape: squircle; box-shadow: ${shadow}; background: ${T.surface}; }
.win { position: absolute; inset: 0; ${R ? `clip-path: ${squircle(WW, WH, R)};` : ''} }
/* zoom, not transform: scale(): under a scaled ancestor Chrome mirrors the spotlight's
   backdrop-filter at the unscaled bounds (whole words reflected at the edges, measured). */
.screen { position: absolute; left: 0; top: 0; width: ${SCW}px; height: ${SCH}px; zoom: ${r3(WS)}; background: ${T.bg}; }
.cam { position: absolute; left: 0; top: 0; }
.foot { position: absolute; inset: 0; width: 100%; height: 100%; }
.sl { position: absolute; inset: 0; opacity: 0; visibility: hidden; pointer-events: none; --x: 0px; --y: 0px; --w: 0px; --h: 0px; }
.scrim { position: absolute; inset: 0; background: ${C.scrim}; ${SP.blur ? `backdrop-filter: blur(${SP.blur}px) saturate(0.8);` : ''}
  mask-image: linear-gradient(#000, #000), ${band('90deg', '--x', '--w')}, ${band('180deg', '--y', '--h')};
  mask-composite: subtract, intersect, add; }
.ring { position: absolute; left: var(--x); top: var(--y); width: var(--w); height: var(--h); border-radius: 12px; overflow: hidden;
  box-shadow: 0 0 0 1.5px ${C.accentEdge}, 0 0 22px 2px ${C.accentGlow}; }
.sweep { position: absolute; top: -20%; bottom: -20%; left: 0; width: 45%; opacity: 0;
  background: linear-gradient(100deg, transparent, rgba(255,255,255,0.30) 50%, transparent); }
.lab { position: absolute; opacity: 0; white-space: nowrap; background: ${T.surface}; border: 1px solid ${C.accentEdge};
  border-left: 5px solid ${T.accent}; border-radius: 10px; padding: 11px 18px 11px 14px;
  font-family: ${C.displayStack}; font-weight: 600; font-size: 22px; line-height: 24px; color: ${T.text};
  box-shadow: 0 1px 2px rgba(0,0,0,0.20), 0 10px 28px rgba(0,0,0,0.30); }
.card { position: absolute; inset: 0; }
.ghost { position: absolute; right: -0.04em; bottom: -0.2em; font-family: ${C.displayStack}; font-weight: 700;
  font-size: ${Math.round(Math.min(W, H) * 0.56)}px; line-height: 1; letter-spacing: -0.04em; white-space: nowrap; color: ${T.text}; opacity: 0.055; }
.hair { position: absolute; left: ${SAFE}px; right: ${SAFE}px; height: 1px; background: ${ink(0.14)}; transform-origin: 0 50%; }
.cbox { position: absolute; left: ${Math.round(SAFE * 1.75)}px; right: ${Math.round(SAFE * 1.75)}px; top: 0; bottom: 0;
  display: flex; flex-direction: column; justify-content: center; align-items: flex-start; }
.kicker { display: flex; align-items: center; gap: 14px; font-family: ${C.bodyStack}; font-weight: 600; font-size: 18px;
  letter-spacing: 0.18em; text-transform: uppercase; color: ${T.accent}; }
.kbar { width: 30px; height: 3px; border-radius: 2px; background: ${T.accent}; transform-origin: 0 50%; }
.ttl { font-family: ${C.displayStack}; font-weight: 700; font-size: ${W > H ? 76 : 70}px; line-height: 1.04;
  letter-spacing: -0.025em; color: ${T.text}; margin-top: 18px; max-width: ${Math.round(W * 0.72)}px; text-wrap: balance; }
.wm { display: inline-block; overflow: hidden; vertical-align: top; padding-bottom: 0.1em; margin-bottom: -0.1em; }
.w { display: inline-block; }
.rule { width: 84px; height: 4px; border-radius: 2px; background: ${T.accent}; margin-top: 26px; transform-origin: 0 50%; }
.sub { font-weight: 500; font-size: 26px; line-height: 1.3; color: ${T.muted}; margin-top: 22px; max-width: ${Math.round(W * 0.6)}px; }
.sub b { color: ${T.highlight}; font-weight: 600; }
#fade { position: absolute; inset: 0; background: ${T.bg}; opacity: 0; pointer-events: none; }
${VERT ? `/* vertical: the headline band above the window and the caption band below it, both inside the
   platforms' safe zones (VERTICAL.safe: clear of their top bar, bottom captions UI and side rail) */
.vhead { position: absolute; left: ${VS.left}px; right: ${VS.right}px; top: ${VS.top}px; opacity: 0; }
.vtitle { font-family: ${C.displayStack}; font-weight: 700; font-size: 60px; line-height: 1.05; letter-spacing: -0.02em;
  color: ${T.text}; margin-top: 16px; text-wrap: balance; }
.vcap { position: absolute; left: ${VS.left}px; right: ${VS.right}px; bottom: ${VS.bottom}px; height: 0; }
.cue { position: absolute; left: 50%; bottom: 0; transform: translateX(-50%); opacity: 0; width: max-content; max-width: 100%;
  padding: 14px 26px; border-radius: 18px; background: color-mix(in oklab, ${T.text} 88%, transparent);
  font-family: ${C.bodyStack}; font-weight: 600; font-size: 40px; line-height: 1.25; color: #FFFFFF; text-align: center; text-wrap: balance; }
` : ''}`;

// A segment renders ceil(duration * fps) frames (measured: 3.067s rendered 93 frames, not 92), so a
// duration that is meant to be whole frames is written rounded DOWN to the millisecond.
const fdur = (d) => (Math.abs(d * C.fps - Math.round(d * C.fps)) < 1e-6 ? Math.floor(d * 1000 + 1e-6) / 1000 : r3(d));

function doc(id, dur, body, script) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=${C.width}, height=${C.height}" />
<script src="gsap.min.js"></script>
<style>${STYLE}</style>
</head>
<body>
<div id="root" data-composition-id="${id}" data-start="0" data-duration="${fdur(dur)}" data-width="${C.width}" data-height="${C.height}">
<div id="stage">
<div id="bg"></div>
<div id="grain"></div>
<div id="content">
${body}
</div>
<div id="fade"></div>
</div>
</div>
<script>
const tl = gsap.timeline({ paused: true });
${script}
window.__timelines["${id}"] = tl;
</script>
</body>
</html>
`;
}

// The segment's own halves of its seams (concat.sh dissolves the overlap): the incoming half
// resolves #content out of a blur (or, for a whip, out of a push from the right), the outgoing
// half throws it the same way. concat.sh dissolves a blur seam and wipes a whip (soft-edged, right
// to left, with the push). Filters and transforms are cleared at rest: a lingering
// blur(0px) or 3D transform keeps a costly layer, and can resample the footage.
function seamLines(name, total) {
  const { in: a, out: b } = seamsOf(C, name), out = [];
  const pose = { blur: { filter: 'blur(10px)', scale: 1.02 }, whip: { filter: 'blur(16px)', x: W * 0.24 } };
  if (a.dur) {
    out.push(`tl.fromTo("#content", ${JSON.stringify(pose[a.kind])}, { filter: "blur(0px)", x: 0, scale: 1, duration: ${r3(a.dur)}, ease: "${a.kind === 'whip' ? 'power3.out' : 'power2.out'}" }, 0);`);
    out.push(`tl.set("#content", { filter: "none" }, ${r3(a.dur)});`);
  }
  if (b.dur) {
    const p = b.kind === 'whip' ? { filter: 'blur(16px)', x: -W * 0.24 } : { filter: 'blur(10px)', scale: 0.985 };
    out.push(`tl.fromTo("#content", { filter: "blur(0px)", x: 0, scale: 1 }, { ...${JSON.stringify(p)}, duration: ${r3(b.dur)}, ease: "${b.kind === 'whip' ? 'power3.in' : 'power2.in'}", immediateRender: false }, ${r3(total - b.dur)});`);
  }
  return out;
}

const words = (s, cls) => esc(s).split(/\s+/).filter(Boolean).map((w) => (cls === 'wm' ? `<span class="wm"><span class="w">${w}</span></span>` : `<span class="w">${w}</span>`)).join(' ');
const ghostWord = (s) => String(s).split(/\s+/).sort((a, b) => b.length - a.length)[0] || '';

// Vertical only: captions burned into the segment itself, in the caption band. The narration's
// words, the spoken one picked out, or without narration each spotlight's label while it is lit
// (captions.mjs groups them, the same cues as the .vtt).
function captionLayer(id, plan) {
  if (!VERT) return { html: '', lines: [] };
  const { cues: cs } = captionCues(C, [{ name: id, start: 0, plan }], A);
  const lines = [], word = `color-mix(in oklab, ${T.highlight} 45%, white)`;
  const html = cs.map((c, i) => {
    const el = `#${id}-c${i}`;
    lines.push(`tl.set("${el}", { opacity: 1 }, ${r3(c.start)});`, `tl.set("${el}", { opacity: 0 }, ${r3(c.end)});`);
    if (!c.words) return `<div class="cue" id="${id}-c${i}">${esc(c.text)}</div>`;
    c.words.forEach((w, k) => {
      lines.push(`tl.set("${el}w${k}", { color: "${word}" }, ${r3(w.start)});`, `tl.set("${el}w${k}", { color: "#FFFFFF" }, ${r3(c.words[k + 1]?.start ?? c.end)});`);
    });
    return `<div class="cue" id="${id}-c${i}">${c.words.map((w, k) => `<span id="${id}-c${i}w${k}">${esc(w.text)}</span>`).join(' ')}</div>`;
  }).join('\n');
  return { html: `<div class="vcap">${html}</div>`, lines };
}

// Text card (title / switch / end). Edge-anchored type over the shared backdrop, an oversized
// ghost word drifting behind it, a hairline; each kind enters differently (house motion rules:
// no shared ease or direction across cards). The seam halves are the card's exits.
function cardDoc(id, c, kind, narration = []) {
  const dur = c.dur, last = segmentNames(C).at(-1) === id;
  const body = `<section id="${id}-card" class="card clip" data-start="0" data-duration="${fdur(dur)}">
  <div class="ghost" id="${id}-ghost">${esc(ghostWord(c.title))}</div>
  <div class="hair" id="${id}-hair" style="top:${H - SAFE}px"></div>
  <div class="cbox" id="${id}-box">
    <div class="kicker" id="${id}-kick"><span class="kbar" id="${id}-kbar"></span><span>${esc(c.kicker)}</span></div>
    <div class="ttl" id="${id}-ttl">${words(c.title, kind === 'switch' ? 'w' : 'wm')}</div>
    <div class="rule" id="${id}-rule"></div>
    <div class="sub" id="${id}-sub">${c.sub}</div>
  </div>
</section>`;
  const s = [], q = (x) => `"#${id}-${x}"`;
  s.push(`tl.fromTo(${q('ghost')}, { x: ${W * 0.03}, opacity: 0 }, { x: ${-W * 0.03}, opacity: 0.055, duration: ${r3(dur)}, ease: "sine.out" }, 0);`);
  s.push(`tl.fromTo(${q('hair')}, { scaleX: 0 }, { scaleX: 1, duration: ${F(1.1)}, ease: "power2.inOut" }, ${F(0.1)});`);
  s.push(`tl.fromTo(${q('kbar')}, { scaleX: 0 }, { scaleX: 1, duration: ${F(0.5)}, ease: "power3.out" }, ${F(0.2)});`);
  // Filter tweens leave blur(0px), a costly layer, so filters are cleared once the last of them
  // has ended. Staggered word tweens end late on long titles: count the stagger in.
  const n = String(c.title).split(/\s+/).filter(Boolean).length;
  let clear = 0;
  const at = (t0, d, st = 0) => { clear = Math.max(clear, t0 + d + st * (n - 1)); return t0; };
  if (kind === 'title') {
    s.push(`tl.fromTo(${q('kick')}, { opacity: 0, x: -18, filter: "blur(6px)" }, { opacity: 1, x: 0, filter: "blur(0px)", duration: ${F(0.9)}, ease: "expo.out" }, ${at(F(0.2), F(0.9))});`);
    s.push(`tl.fromTo("#${id}-ttl .w", { yPercent: 105, filter: "blur(10px)" }, { yPercent: 0, filter: "blur(0px)", duration: ${F(0.8)}, ease: "expo.out", stagger: ${F(0.07)} }, ${at(F(0.3), F(0.8), F(0.07))});`);
  } else if (kind === 'switch') {
    s.push(`tl.fromTo(${q('kick')}, { opacity: 0, x: 40 }, { opacity: 1, x: 0, duration: ${F(0.5)}, ease: "power3.out" }, ${F(0.15)});`);
    s.push(`tl.fromTo("#${id}-ttl .w", { opacity: 0, x: 70, filter: "blur(12px)" }, { opacity: 1, x: 0, filter: "blur(0px)", duration: ${F(0.6)}, ease: "power4.out", stagger: ${F(0.05)} }, ${at(F(0.22), F(0.6), F(0.05))});`);
  } else {
    s.push(`tl.fromTo(${q('kick')}, { opacity: 0 }, { opacity: 1, duration: ${F(0.6)}, ease: "sine.out" }, ${F(0.2)});`);
    s.push(`tl.fromTo(${q('ttl')}, { opacity: 0, scale: 1.06, filter: "blur(14px)", transformOrigin: "0% 50%" }, { opacity: 1, scale: 1, filter: "blur(0px)", duration: ${F(1.0)}, ease: "power2.out" }, ${at(F(0.25), F(1.0))});`);
  }
  s.push(`tl.fromTo(${q('rule')}, { scaleX: 0 }, { scaleX: 1, duration: ${F(0.55)}, ease: "power2.out" }, ${F(0.55)});`);
  s.push(`tl.fromTo(${q('sub')}, { opacity: 0, y: 10, filter: "blur(6px)" }, { opacity: 1, y: 0, filter: "blur(0px)", duration: ${F(0.6)}, ease: "power2.out" }, ${at(F(0.7), F(0.6))});`);
  s.push(`tl.set(["#${id}-ttl", "#${id}-ttl .w", ${q('sub')}, ${q('kick')}], { filter: "none" }, ${r3(clear)});`);
  s.push(...seamLines(id, dur));
  // the film's last frame resolves to the backdrop colour: the one exit the house rules allow
  if (last) s.push(`tl.fromTo("#fade", { opacity: 0 }, { opacity: 1, duration: ${F(0.6)}, ease: "power1.in", immediateRender: false }, ${r3(dur - F(0.6))});`);
  const cap = captionLayer(id, { narration, spots: [] });
  return doc(id, dur, body + cap.html, [...s, ...cap.lines].join('\n'));
}

// ---------- chapter analysis (source time, independent of speed) ----------
function analyze(cfg) {
  const name = cfg.name;
  const mp4 = `${C.takes}/${name}.mp4`;
  if (!existsSync(mp4)) throw new Error(`${name}: no footage at ${mp4}`);
  const ev = JSON.parse(readFileSync(eventsPath(C.takes, name), 'utf8'));
  const dur = +execFileSync(C.ffprobe, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', mp4]).toString().trim();
  const fz = freezes(mp4);
  const marks = ev.events.filter((e) => e.kind === 'mark');
  if (!marks.length) throw new Error(`${name}: events.json has no marks`);
  // labels default to the capture's own mark labels
  const labels = cfg.labels ?? marks.map((m) => m.label);
  if (marks.length !== labels.length) throw new Error(`${name}: ${marks.length} marks vs ${labels.length} labels`);
  for (const [i, l] of labels.entries()) {
    if (l.trim().split(/\s+/).length > C.layout.maxLabelWords) console.warn(`  warn ${name} m${i}: label over ${C.layout.maxLabelWords} words: "${l}"`);
  }

  // spotlight windows in SOURCE time. `pace` stretches hold.min/max, but only as far as the
  // footage stays still: past that the frame moves under the cut-out (defect 1). At pace 1 this
  // is exactly the unpaced rule, hold.min floor included.
  const minRaw = C.hold.min / C.pace;
  const holdFor = (settle, T) => {
    const stable = settle - T - 0.15;
    const base = Math.max(minRaw, Math.min(C.hold.max / C.pace, stable));
    return Math.min(Math.max(C.hold.min, Math.min(C.hold.max, stable)), Math.max(base, stable));
  };
  const spots = marks.map((m, i) => {
    const settle = stableUntil(mp4, m.t);
    return { m, i, T: m.t, hold: holdFor(settle, m.t), label: labels[i], settle };
  });
  for (let i = 0; i + 1 < spots.length; i++) {
    const a = spots[i], b = spots[i + 1];
    if (a.T + a.hold + 0.3 > b.T - 0.25) {
      // too close: first fades out as the second fades in; push the second only if the gap is short
      if (b.T - a.T < minRaw - 0.05) {
        const T2 = a.T + minRaw - 0.05;
        b.hold = holdFor(b.settle, T2);
        b.shift = r3(T2 - b.T); b.T = T2;
      }
      a.hold = Math.min(a.hold, b.T - a.T - 0.25);
    }
  }
  // camera moves (zoom and wide glides), logged by demo:capture; older takes have none
  const moves = ev.events.filter((e) => e.kind === 'camera').map((e) => [e.t0, e.t1]);
  // A spotlight fades in fadeLead before its mark, or once the camera move into it has settled in
  // the footage, whichever is later: a cut-out fading in over a moving frame points at nothing.
  for (const s of spots) {
    const mv = moves.filter(([a]) => a < s.T).at(-1);
    s.from = mv && mv[1] > s.T - C.fadeLead - 0.3 ? Math.max(s.T - C.fadeLead, settledAt(mp4, mv[1], name, ev.fps ?? 30)) : s.T - C.fadeLead;
  }

  // cuts: dead-hold trims outside protected windows, plus configured cuts
  const prot = spots.map((s) => [s.T - 0.6, s.T + s.hold + 0.6]);
  const cuts = [...(cfg.cuts || [])];
  for (const [a0, b0] of fz) {
    if (b0 - a0 <= C.deadHold) continue;
    let pieces = [[a0, Math.min(b0, dur)]];
    for (const [pa, pb] of prot) pieces = pieces.flatMap(([u, v]) => (pb <= u || pa >= v) ? [[u, v]] : [[u, pa], [pb, v]].filter(([x, y]) => y > x));
    for (const [u, v] of pieces) if (v - u > 1.4) cuts.push([u + 0.5, v - 0.5]);
  }
  const kept = keep(dur - 0.03, cuts);
  const vp = ev.viewport || { width: 1280, height: 720 };
  return { cfg, name, mp4, dur, spots, moves, kept, srcW: vp.width, srcH: vp.height, fps: ev.fps ?? 30, dpr: ev.dpr ?? 1, CARD: cfg.cardDur ?? C.chapterCardDur,
    poses: ev.poses || null,
    cues: ev.events.filter((e) => ['click', 'type', 'camera'].includes(e.kind)).map((e) => (e.kind === 'camera' ? { ...e, dur: e.t1 - e.t0 } : e)) };
}

// ---------- the capture camera ----------
// demo:capture logs the in-browser camera's pose on each frame it changed ([frame, x, y, s],
// `poses` in events.json; takes filmed before that have none). camAt is the pose on the frame
// showing source time t, a page rect's frame rect under it is (rect - cam) * s, and a camera at
// scale 1 is no camera, as in capture.
function camAt(an, t) {
  const P = an.poses, k = Math.round(t * an.fps);
  let lo = 0, hi = P.length - 1;
  if (k < P[0][0]) return { x: 0, y: 0, s: 1 };
  while (lo < hi) { const m = (lo + hi + 1) >> 1; if (P[m][0] <= k) lo = m; else hi = m - 1; }
  const [, x, y, s] = P[lo];
  return s > 1 + 1e-6 ? { x, y, s } : { x: 0, y: 0, s: 1 };
}
const onFrame = (r, c) => ({ x: (r.x - c.x) * c.s, y: (r.y - c.y) * c.s, w: r.w * c.s, h: r.h * c.s });

// ---------- speed ramp ----------
// Footage time is re-mapped in two steps: source t -> kept time u (cuts removed) -> output time.
// Output time is built from pieces over u, each with a slowness k = output s per source s that
// runs linearly from k0 to k1, so a ramp is a smooth change of speed rather than a jump.
// Proof windows (fadeLead before a mark through the end of its hold) and every camera move play
// at 1x, so a zoom keeps its designed easing; everything between them plays at speed.travel,
// with a ramp of rampMs of output time each side.
function retime(an, sp, freezes = []) {
  const U = []; let acc = 0;
  for (const [a, b] of an.kept) { U.push(acc); acc += b - a; }
  const uEnd = acc;
  const toU = (t) => {
    for (const [i, [a, b]] of an.kept.entries()) { if (t < b) return U[i] + Math.max(0, t - a); }
    return uEnd;
  };
  const kp = 1, kt = 1 / sp.travel;
  // 1x windows in u (proof windows and camera moves), merged when they touch
  const win = [];
  const spans = [...an.spots.map((s) => [s.T - C.fadeLead, s.T + s.hold]), ...an.moves]
    .map(([a, b]) => [Math.max(0, toU(a)), Math.min(uEnd, toU(b))]).filter(([a, b]) => b > a).sort((x, y) => x[0] - y[0]);
  for (const w of spans) {
    if (win.length && w[0] <= win.at(-1)[1]) win.at(-1)[1] = Math.max(win.at(-1)[1], w[1]); else win.push(w);
  }
  const pieces = [];
  const piece = (u0, u1, k0, k1) => { if (u1 - u0 > 1e-6) pieces.push({ u0, u1, k0, k1 }); };
  // source length of one full ramp, chosen so the ramp lasts rampMs of OUTPUT time
  const rs = kp === kt ? 0 : (2 * sp.rampMs / 1000) / (kp + kt);
  const slope = rs ? (kt - kp) / rs : 0;       // dk per source second, going from proof to travel
  const gap = (g0, g1, left, right) => {       // left/right: a proof window borders that side
    const g = g1 - g0;
    if (!rs) return piece(g0, g1, kt, kt);
    if (left && right) {
      if (g >= 2 * rs) { piece(g0, g0 + rs, kp, kt); piece(g0 + rs, g1 - rs, kt, kt); piece(g1 - rs, g1, kt, kp); }
      else { const km = kp + slope * g / 2; piece(g0, g0 + g / 2, kp, km); piece(g0 + g / 2, g1, km, kp); }
    } else if (right) {                        // head of the chapter: already travelling
      if (g >= rs) { piece(g0, g1 - rs, kt, kt); piece(g1 - rs, g1, kt, kp); }
      else piece(g0, g1, kp + slope * g, kp);
    } else {                                   // tail: ramp up and leave
      if (g >= rs) { piece(g0, g0 + rs, kp, kt); piece(g0 + rs, g1, kt, kt); }
      else piece(g0, g1, kp, kp + slope * g);
    }
  };
  let cur = 0;
  for (const [i, [w0, w1]] of win.entries()) {
    gap(cur, w0, i > 0, true);
    piece(w0, w1, kp, kp);
    cur = w1;
  }
  gap(cur, uEnd, true, false);
  // Split at cut boundaries so each piece maps one kept range, and at narration freezes, then
  // lay pieces end to end.
  for (const b of [...U.slice(1), ...freezes.map((f) => toU(f.t))]) {
    const i = pieces.findIndex((p) => p.u0 < b - 1e-6 && b < p.u1 - 1e-6);
    if (i < 0) continue;
    const p = pieces[i], kb = p.k0 + (p.k1 - p.k0) * (b - p.u0) / (p.u1 - p.u0);
    pieces.splice(i, 1, { u0: p.u0, u1: b, k0: p.k0, k1: kb }, { u0: b, u1: p.u1, k0: kb, k1: p.k1 });
  }
  // Frame phase: at a constant whole-number speed v, source frames land evenly spaced on the
  // output grid, sp = fps / (srcFps * v) output frames apart (1/v for a 30fps take; 1/(2v) for a
  // 60fps one, whose every other frame otherwise sat exactly on the half). If one sits on a half frame, float noise flips the fps
  // filter's rounding and a 1x proof window stutters (a duplicated then a dropped frame,
  // measured). So each constant piece is nudged off its NOMINAL start by under 1/60s (clamped
  // at 0) to keep every phase clear of the half, and each ramp is stretched (`sc`) to run from
  // where the previous piece really ended to its own nominal end. Nudges never accumulate and
  // the composition keeps the nominal length.
  let nominal = 0, end = 0;
  for (const p of pieces) {
    const len = (p.u1 - p.u0) * (p.k0 + p.k1) / 2, start = nominal;
    nominal += len;
    const v = 1 / p.k0;
    if (p.k0 === p.k1 && Math.abs(v - Math.round(v)) < 1e-9) {
      const q = Math.round(v), i = U.findLastIndex((x) => x <= p.u0 + 1e-9);
      const base = C.fps * (start + p.k0 * (U[i] - an.kept[i][0] - p.u0));
      const sp = C.fps / (an.fps * q);
      const want = (sp / 2 + 0.5) % sp, have = ((base % sp) + sp) % sp;
      let d = want - have; if (d > sp / 2) d -= sp; if (d < -sp / 2) d += sp;
      p.o0 = Math.max(0, start + d / C.fps); p.sc = 1;
    } else {
      p.o0 = end; p.sc = len > 0 ? Math.max(0, (nominal - end) / len) : 1;
    }
    end = p.o0 + len * p.sc;
  }
  // Narration freezes (audio.mjs fitNarration): whole frames of output inserted at a source point.
  // Every piece from there on starts that much later, and the fps filter repeats the frame before
  // the jump. Whole frames leave the frame phases above untouched.
  // A freeze at the very end of the kept footage (a hold reaching the end of the take) has no piece
  // after it to push: it holds the last frame instead (renderFootage's tpad), as `tail`, plus 0.5s
  // more so the chapter's closing fade starts after the spotlight's hold, not on top of it.
  let held = 0;
  for (const p of pieces) { held = freezes.reduce((a, f) => a + (toU(f.t) <= p.u0 + 1e-9 ? f.d : 0), 0); p.o0 += held; }
  let tail = freezes.reduce((a, f) => a + (toU(f.t) >= uEnd - 1e-9 ? f.d : 0), 0);
  nominal += held + tail;
  if (tail) { tail += 0.5; nominal += 0.5; }
  const outOfU = (u) => {
    const p = pieces.find((q) => u < q.u1) ?? pieces.at(-1);
    const x = Math.min(u, p.u1) - p.u0;
    return p.o0 + p.sc * (p.k0 * x + (p.k1 - p.k0) * x * x / (2 * (p.u1 - p.u0))) + (u >= uEnd - 1e-9 && tail ? tail - 0.5 : 0);
  };
  return { pieces, tail, footDur: nominal, toOut: (t) => outOfU(toU(t)), kept: an.kept, U };
}

// Write the re-timed footage: cuts dropped, pieces re-timed, resampled to C.fps and scaled to the
// take's CSS viewport (srcW x srcH, rounded down to even as encode.sh does: 4:2:0 needs it),
// which is what the composition lays out. A deterministic take is
// 2x its viewport at 60fps, so this is a lanczos downsample, a sharpness gain over filming at 1x
// (supersampling). Lossless (x264 -qp 0, libx264rgb for an RGB take, so no colour conversion):
// concat.sh makes the one lossy encode.
function renderFootage(an, rt, out, scale) {
  const f = (x) => x.toFixed(6);
  const sel = an.kept.map(([a, b]) => `between(t,${f(a)},${f(b)})`).join('+');
  let u = `T-${f(an.kept.at(-1)[0])}+${f(rt.U.at(-1))}`;
  for (let i = an.kept.length - 2; i >= 0; i--) u = `if(lt(T,${f(an.kept[i][1])}),T-${f(an.kept[i][0])}+${f(rt.U[i])},${u})`;
  let o = '0';
  for (let i = rt.pieces.length - 1; i >= 0; i--) {
    const p = rt.pieces[i], x = `(ld(0)-${f(p.u0)})`;
    const e = `${f(p.o0)}+${f(p.sc * p.k0)}*${x}+${f(p.sc * (p.k1 - p.k0) / (2 * (p.u1 - p.u0)))}*${x}*${x}`;
    o = i === rt.pieces.length - 1 ? e : `if(lt(ld(0),${f(p.u1)}),${e},${o})`;
  }
  const pix = execFileSync(C.ffprobe, ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=pix_fmt', '-of', 'csv=p=0', an.mp4]).toString().trim();
  execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-i', an.mp4,
    '-vf', `select='${sel}',setpts='(st(0,${u});${o})/TB',fps=${C.fps},scale=${Math.round(an.srcW * scale) >> 1 << 1}:${Math.round(an.srcH * scale) >> 1 << 1}:flags=lanczos,tpad=stop_mode=clone:stop_duration=${f(0.2 + rt.tail)}`,
    '-an', '-c:v', /^(gbr|rgb|bgr)/.test(pix) ? 'libx264rgb' : 'libx264', '-qp', '0', '-preset', 'veryfast', out]);
}

// ---------- output framing ----------
// Footage keeps its own aspect. When the output aspect differs (square), each proof window gets a
// view {s, x, y}: footage scaled by s and placed at x, y, chosen so the spotlit rect fits with room
// for its label. The view is still inside a window, so spotlights stay put; it eases between windows.
// Vertical zooms past the cover scale onto a small target, as far as the take's own pixels go
// (a 2x take at 2 screen px per CSS px), so a button reads at phone size without upscaling.
function viewFor(an, fr) {
  const sMin = Math.min(SCW / an.srcW, SCH / an.srcH), cover = Math.max(SCW / an.srcW, SCH / an.srcH);
  const sMax = VERT ? Math.max(cover, an.dpr / (Z * WS)) : cover;
  if (sMax - sMin < 1e-6) return { s: sMin, x: 0, y: 0 };
  const LH = C.layout.labelHeight, GAP = C.layout.labelGap;
  const s = Math.max(sMin, Math.min(sMax, (SCW - 2 * SAFE) / fr.w, (SCH - 2 * SAFE - LH - GAP) / fr.h));
  const fw = an.srcW * s, fh = an.srcH * s, cx = fr.x + fr.w / 2, cy = fr.y + fr.h / 2;
  const x = fw <= SCW ? (SCW - fw) / 2 : Math.min(0, Math.max(SCW - fw, SCW / 2 - cx * s));
  const y = fh <= SCH ? (SCH - fh) / 2 : Math.min(0, Math.max(SCH - fh, SCH / 2 - cy * s));
  return { s: r3(s), x: r3(x), y: r3(y) };
}

// ---------- vertical: the crop follows the target ----------
// The crop (the view of the footage in the vertical window) follows the current target box on a
// critically damped spring, stepped once a frame (omega 9.43 rad/s, the natural frequency of
// Cap's screen spring, cited as a constant), so it never overshoots or jitters. Targets: each
// click and each typed field (its rect under the camera that filmed it), switched PREPAN before
// the press so the crop is already there when the pointer glides in (it glides for 0.5s before
// a press) and it never enters from off-frame; and each group of spotlights, switched PREPAN
// before it lights. While a spotlight is up, from its first fade-in to the end of its last
// fade-out, the crop is pinned to that group's view: the cut-out and the still-check both
// assume a still frame. A spring that has not quite arrived when a pin starts is eased onto the
// pin's view over the last BLEND before it (a few px on ferry), never cut. Views clamp to the
// footage's edges (viewFor).
const PREPAN = 0.8, OMEGA = 9.43, BLEND = 0.2;
function followCrop(an, groups, toComp, total) {
  const cam = `"#${an.name}-cam"`, targets = [], pins = [];
  for (const e of an.cues) if ((e.kind === 'click' || e.kind === 'type') && e.rect) {
    const c = an.poses ? camAt(an, e.t) : (e.cam || { x: 0, y: 0, s: 1 });
    targets.push({ t: toComp(e.t) - PREPAN, view: viewFor(an, onFrame(e.rect, c)) });
  }
  for (const g of groups) {
    const a = g[0], z = g.at(-1);
    targets.push({ t: a.cf - PREPAN, view: a.view });
    pins.push({ from: a.cf, to: z.ct + z.hold + F(0.3), view: a.view });
  }
  targets.sort((a, b) => a.t - b.t);
  const out = [], st = { ...targets[0].view }, vel = { x: 0, y: 0, s: 0 };
  let last = null, jump = 0, maxScale = 0;
  const smooth = (x) => x * x * (3 - 2 * x);
  const sub = 4, dt = 1 / C.fps / sub;
  for (let f = 0; f <= Math.ceil(total * C.fps); f++) {
    const t = f / C.fps, pin = pins.find((p) => t >= p.from - 1e-9 && t <= p.to + 1e-9);
    if (pin) {
      jump = Math.max(jump, Math.hypot(st.x - pin.view.x, st.y - pin.view.y));
      Object.assign(st, pin.view); vel.x = vel.y = vel.s = 0;
    } else {
      // (shown below: the spring, eased onto the next pin's view as that pin nears)
      const goal = (targets.filter((q) => q.t <= t).at(-1) ?? targets[0]).view;
      for (let k = 0; k < sub; k++) for (const ch of ['x', 'y', 's']) {
        vel[ch] += (OMEGA * OMEGA * (goal[ch] - st[ch]) - 2 * OMEGA * vel[ch]) * dt;
        st[ch] += vel[ch] * dt;
      }
    }
    const next = pin ? null : pins.find((p) => p.from > t && p.from - t < BLEND);
    const w = next ? smooth(1 - (next.from - t) / BLEND) : 0, sh = (ch) => st[ch] + ((next ? next.view[ch] : 0) - st[ch]) * w;
    maxScale = Math.max(maxScale, sh('s'));
    const v = { x: r3(sh('x')), y: r3(sh('y')), s: +sh('s').toFixed(5) };
    if (last && Math.abs(v.x - last.x) < 0.05 && Math.abs(v.y - last.y) < 0.05 && Math.abs(v.s - last.s) < 1e-5) continue;
    out.push(`tl.set(${cam}, { x: ${v.x}, y: ${v.y}, scale: ${v.s} }, ${f ? (t - 1e-4).toFixed(6) : 0});`);
    last = v;
  }
  // how far the spring still was from a pin's view when the pin began: eased in over BLEND, but a
  // large one is a fast slide just before the spotlight
  if (jump > 24) console.warn(`  warn ${an.name}: the crop's spring was still ${r3(jump)}px of footage short of a spotlight's view as it lit, eased in over ${BLEND}s (more time before the mark would help)`);
  return { lines: out, maxScale, jump };
}

// ---------- chapter ----------
function chapter(an, sp) {
  const { name, cfg } = an;
  const fit = fitFor(an, sp);
  const rt = retime(an, sp, fit.freezes);
  // A held line keeps its spotlight up: holds become output time, the source span kept for check.mjs.
  for (const s of an.spots) { s.srcHold = s.hold; s.hold = r3(rt.toOut(s.T + s.hold) - rt.toOut(s.T)); }
  const footDur = r3(rt.footDur);
  const pad = padToBeat(name, an.CARD + footDur);
  for (const p of fit.placed) if (p.slot !== 'intro') { p.at += pad; p.lit += pad; }
  // With a bed, total is whole frames ending on a beat; the chapter card takes up the difference.
  const total = an.CARD + footDur + pad, CARD = total - footDur;
  const toComp = (t) => CARD + rt.toOut(t);
  // and back: the source time on screen at composition time t (the latest that has played by t)
  const fromComp = (t) => { let lo = 0, hi = an.dur; for (let i = 0; i < 40; i++) { const m = (lo + hi) / 2; if (toComp(m) <= t) lo = m; else hi = m; } return lo; };
  TOTALS[name] = total;
  const seam = seamsOf(C, name);
  const idx = C.chapters.findIndex((c) => c.name === name) + 1;
  // A film that ends on this chapter fades to the backdrop colour, as an end card would; that
  // fade, or the seam into the next segment, is the tail no spotlight may reach into.
  const last = segmentNames(C).at(-1) === name, tail = seam.out.dur || (last ? F(0.6) : 0);

  // frame position of a rect: (rect - cam) * cam.s  (see demo-capture handoff contract)
  for (const s of an.spots) {
    const { rect, cam } = s.m, c = cam || { x: 0, y: 0, s: 1 };
    s.fr = { x: (rect.x - c.x) * c.s, y: (rect.y - c.y) * c.s, w: rect.w * c.s, h: rect.h * c.s };
  }
  // Spots whose windows overlap share one view (their union), so no spotlight moves while lit.
  // Grouped in OUTPUT time, where the camera move is scheduled: travel speed shrinks the gaps,
  // and a source-time split left moves with no room (end before start).
  for (const s of an.spots) { s.ct = toComp(s.T); s.cf = toComp(s.from); }
  // The tail seam throws the window out, so nothing may still be lit, or fading out, inside it.
  const lastLit = total - tail - F(0.3);
  for (const s of an.spots) {
    if (s.ct + s.hold <= lastLit) continue;
    console.warn(`  warn ${name} m${s.i}: hold cut from ${r3(s.hold)}s to ${r3(lastLit - s.ct)}s so it has faded before the ${last ? 'final fade' : `${seam.out.kind} into the next segment`}`);
    s.hold = Math.max(0.2, lastLit - s.ct);
  }
  const groups = [];
  for (const s of an.spots) {
    const g = groups.at(-1), prev = g?.at(-1);
    if (prev && s.cf < prev.ct + prev.hold + F(0.3) + 0.1) g.push(s); else groups.push([s]);
  }
  for (const g of groups) {
    const x0 = Math.min(...g.map((s) => s.fr.x)), y0 = Math.min(...g.map((s) => s.fr.y));
    const x1 = Math.max(...g.map((s) => s.fr.x + s.fr.w)), y1 = Math.max(...g.map((s) => s.fr.y + s.fr.h));
    const v = viewFor(an, { x: x0, y: y0, w: x1 - x0, h: y1 - y0 });
    for (const s of g) s.view = v;
  }
  // The spotlight glides to the next mark (moves and reshapes) when that one lights within
  // spotlight.glide of this hold ending, inside the same view: across a square re-frame the
  // camera moves under it, so there it fades out and irises in instead. A glide takes at least
  // GLIDE: when the next mark lights sooner (pace > 1, or a spotlight waiting for the camera),
  // this hold ends early to make room, and its label leaves as the glide starts. If that would
  // leave the hold under HOLD_MIN, too short for the still-check's two stills, it does not glide.
  // A glide stands in for the next spotlight's fade-in: it arrives when that fade-in would have
  // finished, so the next mark is fully lit at the same moment either way (and a narration anchor
  // placed on that moment still lands on it).
  // Each run of glides is one spotlight element, so one run's fade-out never touches the next.
  const GLIDE = F(0.35), HOLD_MIN = 0.7, same = (a, b) => JSON.stringify(a.view) === JSON.stringify(b.view);
  let run = 0;
  for (const [k, s] of an.spots.entries()) {
    const n = an.spots[k + 1];
    s.run = run;
    s.glide = false;
    if (!n || !(SP.glide > 0) || !same(s, n) || n.cf - (s.ct + s.hold) > SP.glide) { run++; continue; }
    const start = Math.min(s.ct + s.hold, n.cf + F(0.25) - GLIDE);
    // nor while this mark's narration line is still being spoken
    const said = Math.max(-Infinity, ...fit.placed.filter((p) => p.slot === s.i).map((p) => p.at + p.dur));
    if (start - s.ct < HOLD_MIN || start < said) { run++; continue; }
    s.hold = start - s.ct; s.glide = true; n.glided = true;
  }

  const LH = C.layout.labelHeight, GAP = C.layout.labelGap;
  const report = [];
  // the cut-out for a frame rect under view v: 8px of air, kept 6px inside the frame
  const boxOf = (fr, v) => {
    const x = Math.max(6, fr.x * v.s + v.x - 8), y = Math.max(6, fr.y * v.s + v.y - 8);
    return [x, y, Math.min(SCW - 6, fr.x * v.s + v.x + fr.w * v.s + 8) - x, Math.min(SCH - 6, fr.y * v.s + v.y + fr.h * v.s + 8) - y];
  };
  const labels = an.spots.map((s) => {
    let [x, y, w, h] = boxOf(s.fr, s.view);
    const lw = s.label.length * 12.2 + 44;
    // DEFECT 2 guard: a label must not cover its own spotlight. Try each side outside the
    // cut-out inside the safe margin; if nothing fits, crop the cut-out instead of overlapping.
    const cands = [
      ['below', SCH - SAFE - (y + h + GAP) >= LH, { left: Math.min(Math.max(x, SAFE), SCW - SAFE - lw), top: y + h + GAP }],
      ['above', y - GAP - LH >= SAFE, { left: Math.min(Math.max(x, SAFE), SCW - SAFE - lw), top: y - GAP - LH }],
      ['right', SCW - SAFE - (x + w + GAP) >= lw, { left: x + w + GAP, top: Math.min(Math.max(y, SAFE), SCH - SAFE - LH) }],
      ['left', x - GAP - lw >= SAFE, { left: x - GAP - lw, top: Math.min(Math.max(y, SAFE), SCH - SAFE - LH) }],
    ];
    let pick = cands.find((k) => k[1]);
    if (!pick) {
      h = SCH - SAFE - LH - GAP - y;
      pick = ['below-cropped', true, { left: Math.min(Math.max(x, SAFE), SCW - SAFE - lw), top: y + h + GAP }];
    }
    s.box = [x, y, w, h].map(r3); s.dir = pick[0];
    report.push({
      i: s.i, label: s.label, srcT: r3(s.m.t), shift: s.shift || 0, compT: r3(s.ct), litFrom: r3(s.cf),
      fadeIn: F(0.25), glided: !!s.glided, hold: r3(s.hold), srcHold: r3(s.srcHold),
      place: pick[0], box: [x, y, w, h].map(Math.round),
      labBox: [pick[2].left, pick[2].top, lw, LH].map(Math.round), view: s.view,
    });
    // vertical with no narration: the burned caption IS the label, at a size a phone can read, so
    // the small one by the spotlight stays laid out (check.mjs measures it) but is not drawn
    const dup = VERT && !fit.placed.length ? ';display:none' : '';
    return `<div id="${name}-l${s.i}" class="lab" style="left:${r3(pick[2].left)}px;top:${r3(pick[2].top)}px${dup}">${esc(s.label)}</div>`;
  }).join('\n');

  // Chapter card: a ghost numeral behind, persona kicker, title words rising out of their line
  // masks. It leaves as the window arrives (the two overlap: the arrival is the card's exit).
  const firstLit = Math.min(...an.spots.map((s) => s.cf));
  const ent = r3(Math.max(1 / C.fps, Math.min(F(0.9), firstLit - CARD - 0.1)));
  const cardEnd = r3(CARD + F(0.25));
  const card = `<section id="${name}-card" class="card clip" data-start="0" data-duration="${cardEnd}" data-track-index="2">
  <div class="ghost" id="${name}-ghost">${String(idx).padStart(2, '0')}</div>
  <div class="cbox" id="${name}-box">
    <div class="kicker" id="${name}-kick"><span class="kbar" id="${name}-kbar"></span><span>${esc(cfg.persona || C.defaultPersona || '')}</span></div>
    <div class="ttl" id="${name}-ttl">${words(cfg.title, 'wm')}</div>
    <div class="rule" id="${name}-rule"></div>
  </div>
</section>`;
  const q = (x) => `"#${name}-${x}"`, ww = q('ww');
  const lines = [
    `tl.fromTo(${q('ghost')}, { y: 60, opacity: 0 }, { y: 0, opacity: 0.055, duration: ${F(1.4)}, ease: "sine.out" }, 0);`,
    `tl.fromTo(${q('kbar')}, { scaleX: 0 }, { scaleX: 1, duration: ${F(0.45)}, ease: "power3.out" }, ${F(0.12)});`,
    `tl.fromTo(${q('kick')}, { opacity: 0, x: -24 }, { opacity: 1, x: 0, duration: ${F(0.5)}, ease: "power3.out" }, ${F(0.15)});`,
    `tl.fromTo("#${name}-ttl .w", { yPercent: 108 }, { yPercent: 0, duration: ${F(0.7)}, ease: "power4.out", stagger: ${F(0.06)} }, ${F(0.22)});`,
    `tl.fromTo(${q('rule')}, { scaleX: 0 }, { scaleX: 1, duration: ${F(0.5)}, ease: "power2.out" }, ${F(0.45)});`,
    `tl.fromTo(${q('box')}, { opacity: 1, y: 0, filter: "blur(0px)" }, { opacity: 0, y: -28, filter: "blur(8px)", duration: ${r3(cardEnd - CARD + F(0.2))}, ease: "power2.in", immediateRender: false }, ${r3(CARD - F(0.2))});`,
    `tl.fromTo(${q('ghost')}, { opacity: 0.055 }, { opacity: 0, duration: ${r3(cardEnd - CARD + F(0.2))}, ease: "power2.in", immediateRender: false }, ${r3(CARD - F(0.2))});`,
  ];
  // The window arrives tilted and eases flat before the first spotlight lights; the transform is
  // then reset to 2D identity so the footage is never resampled through a 3D layer.
  const tilt = FR ? FR.tilt : 0;
  const from = tilt ? `{ opacity: 0, y: 36, scale: 0.94, rotationX: ${r3(tilt * 0.55)}, rotationY: ${-tilt}, transformPerspective: 1400, transformOrigin: "50% 60%" }` : '{ opacity: 0, scale: 1.03 }';
  lines.push(`tl.fromTo(${ww}, ${from}, { opacity: 1, y: 0, scale: 1, rotationX: 0, rotationY: 0, duration: ${ent}, ease: "power3.out" }, ${r3(CARD)});`);
  lines.push(`tl.set(${ww}, { transformPerspective: 0, rotationX: 0, rotationY: 0, y: 0, scale: 1 }, ${r3(CARD + ent)});`);
  // Framing (square): one set at 0, then an eased move between consecutive groups while nothing is lit.
  const cam = `#${name}-cam`, V = (v) => `x: ${v.x}, y: ${v.y}, scale: ${v.s}`;
  lines.push(`tl.set("${cam}", { ${V(groups[0][0].view)}, transformOrigin: "0 0" }, 0);`);
  let maxScale = Math.max(...an.spots.map((s) => s.view.s));
  if (VERT) { const f = followCrop(an, groups, toComp, total); lines.push(...f.lines); maxScale = Math.max(maxScale, f.maxScale); }
  else for (let i = 1; i < groups.length; i++) {
    const a = groups[i - 1].at(-1), b = groups[i][0];
    if (JSON.stringify(a.view) === JSON.stringify(b.view)) continue;
    const t0 = a.ct + a.hold + F(0.3), t1 = b.cf;
    lines.push(`tl.fromTo("${cam}", { ${V(a.view)} }, { ${V(b.view)}, duration: ${r3(Math.max(0.05, t1 - t0))}, ease: "power2.inOut", immediateRender: false }, ${r3(Math.min(t0, t1 - 0.05))});`);
  }
  // Spotlight: one feathered cut-out per run of glides, its rect in CSS vars on .sl. Every tween is a
  // fromTo with explicit start values: workers seek frames out of order, so a .to() would read
  // its start from whatever frame that worker rendered last.
  const vars = (b) => `"--x": "${b[0]}px", "--y": "${b[1]}px", "--w": "${b[2]}px", "--h": "${b[3]}px"`;
  const iris = (b) => { const dx = b[2] * 0.06 + 6, dy = b[3] * 0.06 + 6; return [b[0] - dx, b[1] - dy, b[2] + 2 * dx, b[3] + 2 * dy].map(r3); };
  for (const [k, s] of an.spots.entries()) {
    const end = r3(s.ct + s.hold), sl = q(`sl${s.run}`);
    if (s.glided && an.poses) {
      // The glide travels with the content: the cut-out moves across the PAGE, from the last
      // mark's rect to this one's, and each frame draws that page rect where the capture camera
      // filmed it that frame (the per-frame poses in events.json), so a camera move carries the
      // hole with the content under it. An eased tween in frame space slid over the content
      // while the camera moved (measured in SKILL.md). Progress follows the camera spring: how
      // far the camera has come from its pose at the last mark to its pose at this one (centre
      // distance plus log zoom), never going back. The camera often rests mid-glide, zoomed out
      // between two marks, and a hole tied to it alone stopped half way across two cards, so the
      // old power3 ease of time is a floor. A small correction, shrinking to nothing at each end,
      // keeps the two end boxes exactly the marks' own (a box can be cropped for a label).
      const p = an.spots[k - 1], g0 = p.ct + p.hold, arrive = s.cf + F(0.25);
      const camC = (t) => camAt(an, fromComp(t)), cA = camC(g0), cB = camC(arrive);
      const centre = (c) => [c.x + an.srcW / c.s / 2, c.y + an.srcH / c.s / 2];
      const dist = (a, b) => { const [ax, ay] = centre(a), [bx, by] = centre(b); return Math.hypot((ax - bx) / an.srcW, (ay - by) / an.srcH) + Math.abs(Math.log(a.s / b.s)); };
      const lerp = (a, b, u) => ({ x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u, w: a.w + (b.w - a.w) * u, h: a.h + (b.h - a.h) * u });
      const at = (u, c) => boxOf(onFrame(lerp(p.m.rect, s.m.rect, u), c), s.view);
      const e0 = p.box.map((v, i) => v - at(0, cA)[i]), e1 = s.box.map((v, i) => v - at(1, cB)[i]);
      const trace = [];
      let u = 0;
      for (let f = Math.ceil(g0 * C.fps); f <= Math.floor(arrive * C.fps); f++) {
        const t = f / C.fps, c = camC(t), dA = dist(c, cA), dB = dist(c, cB);
        const x = Math.min(1, Math.max(0, (t - g0) / Math.max(1e-6, arrive - g0)));
        const eased = x < 0.5 ? 4 * x ** 3 : 1 - (-2 * x + 2) ** 3 / 2; // power3.inOut, as the tween was
        u = Math.max(u, eased, dA + dB > 1e-9 ? dA / (dA + dB) : 0);
        const b = at(u, c).map((v, i) => r3(v + (1 - u) * e0[i] + u * e1[i]));
        // COMPOSE_TRACE=1 writes, per glide frame, this hole and the page rect it rides, and what
        // the old frame-space tween drew and the page rect at its progress, for SKILL.md's numbers
        if (process.env.COMPOSE_TRACE) trace.push({ t: r3(t), u: r3(u), cam: r3(dA + dB > 1e-9 ? dA / (dA + dB) : 0), hole: b, content: at(u, c).map(r3), tween: p.box.map((v, i) => r3(v + (s.box[i] - v) * eased)), under: at(eased, c).map(r3) });
        // set a hair before the frame's own time, so float error never lands it a frame late
        lines.push(`tl.set(${sl}, { ${vars(b)} }, ${(t - 1e-4).toFixed(6)});`);
      }
      lines.push(`tl.set(${sl}, { ${vars(s.box)} }, ${r3(arrive)});`);
      if (trace.length) writeFileSync(`${C.out}/work/${name}-glide-m${s.i}.json`, JSON.stringify(trace));
    } else if (s.glided) {
      // no camera poses in this take (filmed before they were logged): an eased tween
      const p = an.spots[k - 1], pe = p.ct + p.hold, arrive = s.cf + F(0.25), d = Math.max(1 / C.fps, arrive - pe);
      lines.push(`tl.fromTo(${sl}, { ${vars(p.box)} }, { ${vars(s.box)}, duration: ${r3(d)}, ease: "power3.inOut", immediateRender: false }, ${r3(arrive - d)});`);
    } else {
      lines.push(`tl.set(${sl}, { visibility: "visible" }, ${r3(s.cf)});`);
      lines.push(`tl.fromTo(${sl}, { opacity: 0 }, { opacity: 1, duration: ${F(0.25)}, ease: "power1.out", immediateRender: false }, ${r3(s.cf)});`);
      lines.push(`tl.fromTo(${sl}, { ${vars(iris(s.box))} }, { ${vars(s.box)}, duration: ${F(0.5)}, ease: "expo.out", immediateRender: false }, ${r3(s.cf)});`);
      if (SP.sweep) lines.push(`tl.fromTo(${q(`sw${s.run}`)}, { xPercent: -110, opacity: 1 }, { xPercent: 240, opacity: 1, duration: ${F(0.8)}, ease: "power2.inOut", immediateRender: false }, ${r3(s.cf + F(0.1))});`);
    }
    const o = { below: '0% 0%', 'below-cropped': '0% 0%', above: '0% 100%', right: '0% 50%', left: '100% 50%' }[s.dir];
    const dy = { 'below-cropped': -10, below: -10, above: 10 }[s.dir] ?? 0, dx = { right: -10, left: 10 }[s.dir] ?? 0;
    lines.push(`tl.fromTo("#${name}-l${s.i}", { opacity: 0, scale: 0.88, x: ${dx}, y: ${dy}, transformOrigin: "${o}" }, { opacity: 1, scale: 1, x: 0, y: 0, duration: ${F(0.45)}, ease: "back.out(1.7)", immediateRender: false }, ${r3(Math.max(s.cf, s.ct - F(0.1)))});`);
    lines.push(`tl.fromTo("#${name}-l${s.i}", { opacity: 1 }, { opacity: 0, duration: ${F(0.2)}, ease: "power2.in", immediateRender: false }, ${end});`);
    if (!s.glide) {
      lines.push(`tl.fromTo(${sl}, { opacity: 1 }, { opacity: 0, duration: ${F(0.3)}, ease: "power1.in", immediateRender: false }, ${end});`);
      lines.push(`tl.set(${sl}, { visibility: "hidden" }, ${r3(end + F(0.3))});`);
    }
  }
  lines.push(...seamLines(name, total));
  if (last) lines.push(`tl.fromTo("#fade", { opacity: 0 }, { opacity: 1, duration: ${F(0.6)}, ease: "power1.in", immediateRender: false }, ${r3(total - F(0.6))});`);

  const win = `<div class="winwrap" id="${name}-ww"><div class="winshadow"></div><div class="win"><div class="screen">
<div id="${name}-cam" class="cam" style="width:${an.srcW}px;height:${an.srcH}px">
<video id="${name}-v" class="foot clip" src="assets/footage/${name}.mp4" data-start="${r3(CARD)}" data-duration="${footDur}" data-media-start="0" data-track-index="0" muted playsinline></video>
</div>
${[...new Set(an.spots.map((s) => s.run))].map((r) => `<div class="sl" id="${name}-sl${r}"><div class="scrim"></div><div class="ring"><div class="sweep" id="${name}-sw${r}"></div></div></div>`).join('\n')}
${labels}
</div></div></div>`;
  // Vertical: the chapter title stays up in the headline band once the window is in, and the
  // captions run in the caption band.
  const narration = fit.placed.map(({ slot, at, lit, dur, file, text, anchor, words }) => ({ slot, at: r3(at), ...(lit != null && { lit: r3(lit) }), dur, file, text, anchor, words }));
  const cap = captionLayer(name, { narration, spots: report });
  const head = VERT ? `<div class="vhead" id="${name}-vh"><div class="kicker"><span class="kbar"></span><span>${esc(cfg.persona || C.defaultPersona || '')}</span></div><div class="vtitle">${esc(cfg.title)}</div></div>` : '';
  if (VERT) lines.push(`tl.fromTo("#${name}-vh", { opacity: 0, y: 24 }, { opacity: 1, y: 0, duration: ${F(0.6)}, ease: "power3.out" }, ${r3(CARD)});`);
  const d = project(name, doc(name, total, [card, win, head, cap.html].filter(Boolean).join('\n'), [...lines, ...cap.lines].join('\n')));
  // Footage is written at the pixel size it is shown at (window scale, zoom, largest view), capped
  // at the take's own: a 2x take enters a 1440p master at native density, lanczos-scaled once.
  const shown = Z * WS * Math.max(1, maxScale);
  renderFootage(an, rt, `${d}/assets/footage/${name}.mp4`, Math.min(an.dpr, shown));
  const meta = { name, kind: 'chapter', start: startOf(name), total: GRID ? total : r3(total), srcDur: r3(an.dur), cardDur: CARD, srcW: an.srcW, srcH: an.srcH,
    speed: sp, kept: an.kept.map((k) => k.map(r3)), cuts: r3(an.dur - rt.kept.reduce((a, [x, y]) => a + y - x, 0)),
    footDur, settledFrom: r3(CARD + ent), tailFrom: r3(total - tail), spots: report,
    // narration freezes as [start, length] in composition seconds; check.mjs maps stills through them
    freezes: [...new Set(fit.freezes.map((f) => f.t))].map((t) => {
      const d = fit.freezes.filter((f) => f.t === t).reduce((a, f) => a + f.d, 0);
      return [r3(toComp(t) - d), r3(d)];
    }),
    // sound cues and narration for audio.mjs, in composition seconds
    // A move a narration freeze lands inside starts once the freeze ends, so its whoosh does too.
    cues: an.cues.filter((e) => an.kept.some(([a, b]) => e.t >= a && e.t < b)).map((e) => {
      const at = toComp(e.t) + fit.freezes.reduce((a, f) => a + (e.dur && f.t > e.t && f.t <= e.t + e.dur ? f.d : 0), 0);
      return { kind: e.kind, at: r3(at), ...(e.dur != null && { dur: r3(toComp(e.t + e.dur) - at) }), ...(e.chars && { chars: e.chars }) };
    }),
    narration };
  writeFileSync(`${C.out}/work/${name}.plan.json`, JSON.stringify(meta, null, 1));
  return meta;
}

// ---------- run ----------
mkdirSync(`${C.out}/work`, { recursive: true });
const want = process.argv.slice(3);
const names = want.length ? want : segmentNames(C);
for (const n of names) if (!C.cards[n] && !C.chapters.some((c) => c.name === n)) throw new Error(`unknown segment "${n}"`);

// Narration and the music's beat grid are settled before any picture is timed (audio.mjs).
const A = audioSettings(C);
const NAR = narrationClips(C);
const GRID = beatGrid(C);
const fitFor = (an, sp) => fitNarration(an.spots.map((s) => ({ T: s.T, hold: s.hold, from: s.from, fade: F(0.25) })), NAR[an.name] || { marks: [] },
  (fz) => { const r = retime(an, sp, fz); return (t) => an.CARD + r.toOut(t); }, A?.narration, C.fps);
// Segment lengths and starts so far, this run's or an earlier run's plan, for where each segment starts.
const PLANS = Object.fromEntries(segmentNames(C).map((n) => {
  const p = `${C.out}/work/${n}.plan.json`;
  return [n, existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : null];
}));
const TOTALS = Object.fromEntries(segmentNames(C).map((n) => [n, PLANS[n]?.total ?? null]));
// A segment starts where the previous one ends less the seam between them: a transition overlaps
// the two (concat.sh), so with transitions on every later start moves earlier by the seams before it.
const SEAM = Object.fromEntries(segmentNames(C).map((n, i) => [n, seams(C)[i].dur]));
const OUT = Object.fromEntries(segmentNames(C).map((n, i, a) => [n, SEAM[a[i + 1]] ?? 0]));
const startOf = (n) => {
  let start = 0;
  for (const m of segmentNames(C)) { start -= SEAM[m]; if (m === n) return start; if (TOTALS[m] == null) return null; start += TOTALS[m]; }
  return null;
};
// With a music bed, each segment's leading card grows by under one beat so the next segment
// starts, to the frame, on a beat: every cut lands on the music. With a transition the cut is the
// moment the next segment starts to come in, `out` (its seam) before this one ends; the last
// segment's end is the film's.
// Starts are counted in whole frames (each segment renders whole frames, seams are whole frames),
// so the padded segment ends exactly on the frame nearest the beat.
const padAt = (start, total, out = 0) => {
  if (!GRID) return 0;
  const s0 = Math.round(start * C.fps), cut = total - out;
  return (Math.round(GRID.after(s0 / C.fps + cut - 1e-3) * C.fps) - s0) / C.fps - cut;
};
function padToBeat(n, total) {
  if (!GRID) return 0;
  const start = startOf(n);
  if (start == null) { console.warn(`warn: ${n} not snapped to the beat: an earlier segment has no plan yet`); return 0; }
  return padAt(start, total, OUT[n]);
}
// A card's length before any beat padding: a narrated card stays up until its line has finished.
const cardDur = (n) => {
  const c = C.cards[n], clip = NAR[n]?.card, N = A?.narration;
  return clip ? r3(Math.max(c.dur, N.lead + clip.dur + N.tail + F(0.4))) : c.dur;
};

// A chapter's `speed` keys override the global ones; `travel` can be raised by targetDuration.
const speedFor = (cfg, travel) => ({ ...C.speed, travel, ...(cfg.speed || {}) });
const analyses = new Map();
const analysis = (cfg) => analyses.get(cfg.name) ?? analyses.set(cfg.name, analyze(cfg)).get(cfg.name);
let travel = C.speed.travel;
if (C.targetDuration) {
  // Whole-video length at a given travel speed, computed from the plan: nothing is rendered.
  // Chapters not filmed yet cannot be measured: leave them out, say so, and keep going.
  const filmed = C.chapters.filter((c) => existsSync(`${C.takes}/${c.name}.mp4`));
  for (const c of C.chapters) if (!filmed.includes(c)) console.warn(`warn: targetDuration leaves out ${c.name}: no footage at ${C.takes}/${c.name}.mp4`);
  // Cards with their narration, chapters with their narration freezes, and each segment's beat pad.
  const length = (v) => segmentNames(C).reduce((t, n) => {
    const c = C.chapters.find((x) => x.name === n);
    if (c && !filmed.includes(c)) return t;
    t -= SEAM[n];                                    // a seam overlaps this segment with the last
    const an = c && analysis(c), sp = c && speedFor(c, v);
    // the same arithmetic as chapter() and the card branch: a pad decides on a beat, and a
    // millisecond either side of one is a whole beat of difference
    const foot = c ? r3(retime(an, sp, fitFor(an, sp).freezes).footDur) : 0, base = c ? an.CARD + foot : cardDur(n), pad = padAt(t, base, OUT[n]);
    return t + (GRID ? base + pad : c ? an.CARD + foot : r3(base));
  }, 0);
  // ponytail: bisection on travel alone; proof windows, cards and holds are never sped up to hit it.
  if (length(travel) > C.targetDuration) {
    let lo = travel, hi = Math.max(travel, 4);
    if (length(hi) > C.targetDuration) lo = hi;
    for (let k = 0; k < 40 && hi - lo > 0.001; k++) { const m = (lo + hi) / 2; if (length(m) > C.targetDuration) lo = m; else hi = m; }
    travel = r3(Math.max(lo, hi));
  }
  const planned = r3(length(travel));
  console.log(`targetDuration ${C.targetDuration}s: speed.travel ${travel}x (cap 4x), planned ${planned}s${planned > C.targetDuration + 0.05 ? ', not reachable: cards, proof windows, holds and narration are never sped up' : ''}`);
}

// With a music bed every segment's start decides its pad, so a segment whose start has moved since
// its plan (an earlier one was re-cut) is composed again even when not named: its cut stays on a beat.
const order = GRID ? segmentNames(C) : names;
for (const n of order) {
  const start = startOf(n);
  if (GRID && !names.includes(n)) {
    if (PLANS[n] && start != null && Math.abs((PLANS[n].start ?? -1) - start) < 1e-3) continue;
    console.log(`${n}: composed again, it now starts at ${start == null ? '?' : r3(start)}s and its cut must stay on a beat`);
  }
  const card = C.cards[n];
  if (card) {
    const clip = NAR[n]?.card, N = A?.narration, base = cardDur(n);
    card.dur = GRID ? base + padToBeat(n, base) : r3(base);
    TOTALS[n] = card.dur;
    const narration = clip ? [{ slot: 'card', at: N.lead, dur: clip.dur, file: clip.file, text: clip.text, anchor: clip.anchor, words: clip.words }] : [];
    project(n, cardDoc(n, card, n === 'title-card' ? 'title' : n === 'end-card' ? 'end' : 'switch', narration));
    writeFileSync(`${C.out}/work/${n}.plan.json`, JSON.stringify({ name: n, kind: 'card', start, total: card.dur, spots: [], narration }, null, 1));
    console.log(`${n}: card ${r3(card.dur)}s`);
    continue;
  }
  const cfg = C.chapters.find((c) => c.name === n);
  const m = chapter(analysis(cfg), speedFor(cfg, travel));
  console.log(`${n}: total ${m.total}s (src ${m.srcDur}, cut ${m.cuts}, travel ${m.speed.travel}x) spots ${m.spots.map((s) => `${s.place}${s.shift ? '+' + s.shift : ''}/${s.hold}`).join(' ')}`);
  // where each narrated mark's anchor word starts against its spotlight being fully lit; 0 by construction
  const lines = m.narration.filter((l) => typeof l.slot === 'number');
  if (lines.length) console.log(`  anchors ${lines.map((l) => { const s = m.spots.find((q) => q.i === l.slot); return `m${l.slot} ${r3(l.at + l.anchor - Math.max(s.compT, s.litFrom + s.fadeIn))}s`; }).join(', ')}`);
}
if (C.targetDuration && segmentNames(C).every((n) => TOTALS[n] != null)) {
  console.log(`targetDuration ${C.targetDuration}s: composed ${r3(segmentNames(C).reduce((a, n) => a + TOTALS[n], 0))}s`);
}

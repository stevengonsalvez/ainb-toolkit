#!/usr/bin/env node
// compose.mjs <config.json> [segment ...]
// Generates one standalone HyperFrames project per chapter, plus title / switch / end cards.
// Everything app-specific comes from the config. Nothing here knows what app was filmed.
import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, copyFileSync, existsSync } from 'node:fs';
import { dirname, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig, segmentNames, eventsPath, r3, esc } from './config.mjs';

const cfgPath = process.argv[2];
if (!cfgPath) { console.error('usage: compose.mjs <config.json> [segment ...]'); process.exit(2); }
const C = loadConfig(cfgPath);
const SKILL = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const W = C.width, H = C.height, SAFE = C.layout.safeMargin;
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
  const fw = 160 * 90, t0 = t + 0.3;
  const buf = execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-ss', String(t0), '-i', mp4, '-t', String(Math.max(2.6, C.hold.max + 0.4)),
    '-vf', 'fps=10,scale=160:90,format=gray', '-f', 'rawvideo', '-'], { maxBuffer: 1 << 26 });
  const n = Math.floor(buf.length / fw);
  for (let k = 1; k < n; k++) {
    let d = 0;
    for (let p = 0; p < fw; p++) d += Math.abs(buf[k * fw + p] - buf[p]);
    if (d / fw > 2) return t0 + k / 10;
  }
  return t0 + n / 10;
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
const T = C.theme;
const faces = C.fontFaces.join('\n');
const STYLE = `
${faces}
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: ${W}px; height: ${H}px; overflow: hidden; background: ${T.bg}; }
#root { position: relative; width: 100%; height: 100%; overflow: hidden; background: ${T.bg};
  font-family: ${C.bodyStack}; color: ${T.text}; }
.cam { position: absolute; left: 0; top: 0; }
.foot { position: absolute; inset: 0; width: 100%; height: 100%; }
.card { position: absolute; inset: 0; background: ${T.bg}; display: flex; flex-direction: column;
  align-items: center; justify-content: center; text-align: center; }
.card .inner { display: flex; flex-direction: column; align-items: center; }
.kicker { font-family: ${C.bodyStack}; font-weight: 600; font-size: 18px;
  letter-spacing: 0.18em; text-transform: uppercase; color: ${T.accent}; }
.ttl { font-family: ${C.displayStack}; font-weight: 700; font-size: 64px;
  letter-spacing: -0.02em; color: ${T.text}; margin-top: 14px; }
.rule { width: 72px; height: 4px; border-radius: 2px; background: ${T.accent}; margin-top: 22px; }
.sub { font-weight: 500; font-size: 24px; color: ${T.muted}; margin-top: 20px; }
.sub b { color: ${T.highlight}; font-weight: 600; }
.spot { position: absolute; border-radius: 12px; opacity: 0; pointer-events: none;
  box-shadow: 0 0 0 2px ${T.accent}, 0 0 22px 3px ${C.accentGlow}, 0 0 0 3000px ${C.scrim}; }
.lab { position: absolute; opacity: 0; white-space: nowrap; background: ${T.surface}; border: 1px solid ${C.accentEdge};
  border-left: 5px solid ${T.accent}; border-radius: 10px; padding: 11px 18px 11px 14px;
  font-family: ${C.displayStack}; font-weight: 600; font-size: 22px; line-height: 24px; color: ${T.text};
  box-shadow: 0 8px 24px rgba(0,0,0,0.55); }
#fade { position: absolute; inset: 0; background: ${T.bg}; opacity: 0; pointer-events: none; }
`;

function doc(id, dur, body, script) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=${W}, height=${H}" />
<script src="gsap.min.js"></script>
<style>${STYLE}</style>
</head>
<body>
<div id="root" data-composition-id="${id}" data-start="0" data-duration="${r3(dur)}" data-width="${W}" data-height="${H}">
${body}
<div id="fade"></div>
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

// Text-only card composition (title / switch / end).
function cardDoc(id, c) {
  const dur = c.dur;
  const body = `<section id="${id}-card" class="card clip" data-start="0" data-duration="${dur}">
  <div class="inner" id="${id}-inner">
    <div class="kicker">${esc(c.kicker)}</div>
    <div class="ttl">${esc(c.title)}</div>
    <div class="rule" id="${id}-rule"></div>
    <div class="sub">${c.sub}</div>
  </div>
</section>`;
  const script = `tl.fromTo("#${id}-inner", { opacity: 0, y: 18 }, { opacity: 1, y: 0, duration: ${F(0.6)}, ease: "power3.out" }, ${F(0.15)});
tl.fromTo("#${id}-rule", { scaleX: 0 }, { scaleX: 1, duration: ${F(0.5)}, ease: "power2.out" }, ${F(0.35)});
tl.fromTo("#fade", { opacity: 0 }, { opacity: 1, duration: ${F(0.4)}, ease: "power1.in" }, ${r3(dur - F(0.4))});`;
  return doc(id, dur, body, script);
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
  return { cfg, name, mp4, dur, spots, kept, srcW: vp.width, srcH: vp.height, CARD: cfg.cardDur ?? C.chapterCardDur };
}

// ---------- speed ramp ----------
// Footage time is re-mapped in two steps: source t -> kept time u (cuts removed) -> output time.
// Output time is built from pieces over u, each with a slowness k = output s per source s that
// runs linearly from k0 to k1, so a ramp is a smooth change of speed rather than a jump.
// Proof windows (fadeLead before a mark through the end of its hold) play at 1x;
// everything between them plays at speed.travel, with a ramp of rampMs of output time each side.
function retime(an, sp) {
  const U = []; let acc = 0;
  for (const [a, b] of an.kept) { U.push(acc); acc += b - a; }
  const uEnd = acc;
  const toU = (t) => {
    for (const [i, [a, b]] of an.kept.entries()) { if (t < b) return U[i] + Math.max(0, t - a); }
    return uEnd;
  };
  const kp = 1, kt = 1 / sp.travel;
  // proof windows in u, merged when they touch
  const win = [];
  for (const s of an.spots) {
    const w = [Math.max(0, toU(s.T - C.fadeLead)), Math.min(uEnd, toU(s.T + s.hold))];
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
  // Split at cut boundaries so each piece maps one kept range, then lay pieces end to end.
  for (const b of U.slice(1)) {
    const i = pieces.findIndex((p) => p.u0 < b - 1e-6 && b < p.u1 - 1e-6);
    if (i < 0) continue;
    const p = pieces[i], kb = p.k0 + (p.k1 - p.k0) * (b - p.u0) / (p.u1 - p.u0);
    pieces.splice(i, 1, { u0: p.u0, u1: b, k0: p.k0, k1: kb }, { u0: b, u1: p.u1, k0: kb, k1: p.k1 });
  }
  // Frame phase: at a constant whole-number speed v, source frames land on v evenly spaced
  // phases of the 30fps output grid. If one sits on a half frame, float noise flips the fps
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
      const base = 30 * (start + p.k0 * (U[i] - an.kept[i][0] - p.u0));
      const want = (1 / (2 * q) + 0.5) % (1 / q), have = ((base % (1 / q)) + 1 / q) % (1 / q);
      let d = want - have; if (d > 0.5 / q) d -= 1 / q; if (d < -0.5 / q) d += 1 / q;
      p.o0 = Math.max(0, start + d / 30); p.sc = 1;
    } else {
      p.o0 = end; p.sc = len > 0 ? Math.max(0, (nominal - end) / len) : 1;
    }
    end = p.o0 + len * p.sc;
  }
  const outOfU = (u) => {
    const p = pieces.find((q) => u < q.u1) ?? pieces.at(-1);
    const x = Math.min(u, p.u1) - p.u0;
    return p.o0 + p.sc * (p.k0 * x + (p.k1 - p.k0) * x * x / (2 * (p.u1 - p.u0)));
  };
  return { pieces, footDur: nominal, toOut: (t) => outOfU(toU(t)), kept: an.kept, U };
}

// Write the re-timed footage: cuts dropped, pieces re-timed, resampled to 30fps.
function renderFootage(an, rt, out) {
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
  execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-i', an.mp4,
    '-vf', `select='${sel}',setpts='(st(0,${u});${o})/TB',fps=30,tpad=stop_mode=clone:stop_duration=0.2,format=yuv420p`,
    '-an', '-c:v', 'libx264', '-crf', '14', '-preset', 'veryfast', out]);
}

// ---------- output framing ----------
// Footage keeps its own aspect. When the output aspect differs (square), each proof window gets a
// view {s, x, y}: footage scaled by s and placed at x, y, chosen so the spotlit rect fits with room
// for its label. The view is still inside a window, so spotlights stay put; it eases between windows.
function viewFor(an, fr) {
  const sMin = Math.min(W / an.srcW, H / an.srcH), sMax = Math.max(W / an.srcW, H / an.srcH);
  if (sMax - sMin < 1e-6) return { s: sMin, x: 0, y: 0 };
  const LH = C.layout.labelHeight, GAP = C.layout.labelGap;
  const s = Math.max(sMin, Math.min(sMax, (W - 2 * SAFE) / fr.w, (H - 2 * SAFE - LH - GAP) / fr.h));
  const fw = an.srcW * s, fh = an.srcH * s, cx = fr.x + fr.w / 2, cy = fr.y + fr.h / 2;
  const x = fw <= W ? (W - fw) / 2 : Math.min(0, Math.max(W - fw, W / 2 - cx * s));
  const y = fh <= H ? (H - fh) / 2 : Math.min(0, Math.max(H - fh, H / 2 - cy * s));
  return { s: r3(s), x: r3(x), y: r3(y) };
}

// ---------- chapter ----------
function chapter(an, sp) {
  const { name, cfg, CARD } = an;
  const rt = retime(an, sp);
  const toComp = (t) => CARD + rt.toOut(t);
  const footDur = r3(rt.footDur);
  const total = CARD + footDur;

  const card = `<section id="${name}-card" class="card clip" data-start="0" data-duration="${CARD}" data-track-index="2">
  <div class="inner" id="${name}-inner">
    <div class="kicker">${esc(cfg.persona || C.defaultPersona || '')}</div>
    <div class="ttl">${esc(cfg.title)}</div>
    <div class="rule" id="${name}-rule"></div>
  </div>
</section>`;

  // frame position of a rect: (rect - cam) * cam.s  (see demo-capture handoff contract)
  for (const s of an.spots) {
    const { rect, cam } = s.m, c = cam || { x: 0, y: 0, s: 1 };
    s.fr = { x: (rect.x - c.x) * c.s, y: (rect.y - c.y) * c.s, w: rect.w * c.s, h: rect.h * c.s };
  }
  // Spots whose windows overlap share one view (their union), so no spotlight moves while lit.
  // Grouped in OUTPUT time, where the camera move is scheduled: travel speed shrinks the gaps,
  // and a source-time split left moves with no room (end before start).
  for (const s of an.spots) s.ct = toComp(s.T);
  const groups = [];
  for (const s of an.spots) {
    const g = groups.at(-1), prev = g?.at(-1);
    if (prev && s.ct - C.fadeLead < prev.ct + prev.hold + F(0.3) + 0.1) g.push(s); else groups.push([s]);
  }
  for (const g of groups) {
    const x0 = Math.min(...g.map((s) => s.fr.x)), y0 = Math.min(...g.map((s) => s.fr.y));
    const x1 = Math.max(...g.map((s) => s.fr.x + s.fr.w)), y1 = Math.max(...g.map((s) => s.fr.y + s.fr.h));
    const v = viewFor(an, { x: x0, y: y0, w: x1 - x0, h: y1 - y0 });
    for (const s of g) s.view = v;
  }

  const LH = C.layout.labelHeight, GAP = C.layout.labelGap;
  const report = [];
  const overlays = an.spots.map((s) => {
    const fr = s.fr, v = s.view;
    let x = fr.x * v.s + v.x - 8, y = fr.y * v.s + v.y - 8, w = fr.w * v.s + 16, h = fr.h * v.s + 16;
    const x2 = Math.min(W - 6, x + w), y2 = Math.min(H - 6, y + h);
    x = Math.max(6, x); y = Math.max(6, y); w = x2 - x; h = y2 - y;
    const lw = s.label.length * 12.2 + 44;
    // DEFECT 2 guard: a label must not cover its own spotlight. Try each side outside the
    // cut-out inside the safe margin; if nothing fits, crop the cut-out instead of overlapping.
    const cands = [
      ['below', H - SAFE - (y + h + GAP) >= LH, { left: Math.min(Math.max(x, SAFE), W - SAFE - lw), top: y + h + GAP }],
      ['above', y - GAP - LH >= SAFE, { left: Math.min(Math.max(x, SAFE), W - SAFE - lw), top: y - GAP - LH }],
      ['right', W - SAFE - (x + w + GAP) >= lw, { left: x + w + GAP, top: Math.min(Math.max(y, SAFE), H - SAFE - LH) }],
      ['left', x - GAP - lw >= SAFE, { left: x - GAP - lw, top: Math.min(Math.max(y, SAFE), H - SAFE - LH) }],
    ];
    let pick = cands.find((k) => k[1]);
    if (!pick) {
      h = H - SAFE - LH - GAP - y;
      pick = ['below-cropped', true, { left: Math.min(Math.max(x, SAFE), W - SAFE - lw), top: y + h + GAP }];
    }
    const ct = s.ct;
    report.push({
      i: s.i, label: s.label, srcT: r3(s.m.t), shift: s.shift || 0, compT: r3(ct), hold: r3(s.hold),
      place: pick[0], box: [x, y, w, h].map(Math.round),
      labBox: [pick[2].left, pick[2].top, lw, LH].map(Math.round), view: v,
    });
    s.ct = ct; s.dir = pick[0];
    return `<div id="${name}-s${s.i}" class="spot" style="left:${r3(x)}px;top:${r3(y)}px;width:${r3(w)}px;height:${r3(h)}px"></div>
<div id="${name}-l${s.i}" class="lab" style="left:${r3(pick[2].left)}px;top:${r3(pick[2].top)}px">${esc(s.label)}</div>`;
  }).join('\n');

  const lines = [
    `tl.fromTo("#${name}-inner", { opacity: 0, y: 18 }, { opacity: 1, y: 0, duration: ${F(0.5)}, ease: "power3.out" }, ${F(0.1)});`,
    `tl.fromTo("#${name}-rule", { scaleX: 0 }, { scaleX: 1, duration: ${F(0.45)}, ease: "power2.out" }, ${F(0.3)});`,
    `tl.to("#${name}-inner", { opacity: 0, duration: ${F(0.3)}, ease: "power1.in" }, ${r3(CARD - F(0.35))});`,
    `tl.fromTo("#fade", { opacity: 1 }, { opacity: 0, duration: ${F(0.35)}, ease: "power1.out", immediateRender: false }, ${r3(CARD)});`,
    `tl.fromTo("#fade", { opacity: 0 }, { opacity: 1, duration: ${F(0.35)}, ease: "power1.in", immediateRender: false }, ${r3(total - F(0.35))});`,
  ];
  // Framing: one set at 0, then an eased move between consecutive groups while nothing is lit.
  const cam = `#${name}-cam`, V = (v) => `x: ${v.x}, y: ${v.y}, scale: ${v.s}`;
  lines.push(`tl.set("${cam}", { ${V(groups[0][0].view)}, transformOrigin: "0 0" }, 0);`);
  for (let i = 1; i < groups.length; i++) {
    const a = groups[i - 1].at(-1), b = groups[i][0];
    if (JSON.stringify(a.view) === JSON.stringify(b.view)) continue;
    const t0 = a.ct + a.hold + F(0.3), t1 = b.ct - C.fadeLead;
    lines.push(`tl.to("${cam}", { ${V(b.view)}, duration: ${r3(Math.max(0.05, t1 - t0))}, ease: "power2.inOut" }, ${r3(Math.min(t0, t1 - 0.05))});`);
  }
  for (const s of an.spots) {
    const dy = { 'below-cropped': -8, below: -8, above: 8, right: 0, left: 0 }[s.dir] ?? 0;
    const dx = { right: -8, left: 8 }[s.dir] || 0;
    lines.push(`tl.fromTo("#${name}-s${s.i}", { opacity: 0 }, { opacity: 1, duration: ${F(0.25)}, ease: "power1.out" }, ${r3(s.ct - C.fadeLead)});`);
    lines.push(`tl.fromTo("#${name}-l${s.i}", { opacity: 0, x: ${dx}, y: ${dy} }, { opacity: 1, x: 0, y: 0, duration: ${F(0.3)}, ease: "power2.out" }, ${r3(s.ct - F(0.1))});`);
    lines.push(`tl.to(["#${name}-s${s.i}", "#${name}-l${s.i}"], { opacity: 0, duration: ${F(0.3)}, ease: "power1.in" }, ${r3(s.ct + s.hold)});`);
  }

  const vid = `<div id="${name}-cam" class="cam" style="width:${an.srcW}px;height:${an.srcH}px">
<video id="${name}-v" class="foot clip" src="assets/footage/${name}.mp4" data-start="${r3(CARD)}" data-duration="${footDur}" data-media-start="0" data-track-index="0" muted playsinline></video>
</div>`;
  const d = project(name, doc(name, total, `${vid}\n${card}\n${overlays}`, lines.join('\n')));
  renderFootage(an, rt, `${d}/assets/footage/${name}.mp4`);
  const meta = { name, kind: 'chapter', total: r3(total), srcDur: r3(an.dur), cardDur: CARD, srcW: an.srcW, srcH: an.srcH,
    speed: sp, kept: an.kept.map((k) => k.map(r3)), cuts: r3(an.dur - rt.kept.reduce((a, [x, y]) => a + y - x, 0)),
    footDur, spots: report };
  writeFileSync(`${C.out}/work/${name}.plan.json`, JSON.stringify(meta, null, 1));
  return meta;
}

// ---------- run ----------
mkdirSync(`${C.out}/work`, { recursive: true });
const want = process.argv.slice(3);
const names = want.length ? want : segmentNames(C);
for (const n of names) if (!C.cards[n] && !C.chapters.some((c) => c.name === n)) throw new Error(`unknown segment "${n}"`);

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
  const length = (v) => Object.values(C.cards).reduce((a, c) => a + c.dur, 0)
    + filmed.reduce((a, c) => { const an = analysis(c); return a + an.CARD + retime(an, speedFor(c, v)).footDur; }, 0);
  // ponytail: bisection on travel alone; proof windows, cards and holds are never sped up to hit it.
  if (length(travel) > C.targetDuration) {
    let lo = travel, hi = Math.max(travel, 4);
    if (length(hi) > C.targetDuration) lo = hi;
    for (let k = 0; k < 40 && hi - lo > 0.001; k++) { const m = (lo + hi) / 2; if (length(m) > C.targetDuration) lo = m; else hi = m; }
    travel = r3(Math.max(lo, hi));
  }
  console.log(`targetDuration ${C.targetDuration}s: speed.travel ${travel}x (cap 4x), planned ${r3(length(travel))}s`);
}

for (const n of names) {
  const card = C.cards[n];
  if (card) {
    project(n, cardDoc(n, card));
    writeFileSync(`${C.out}/work/${n}.plan.json`, JSON.stringify({ name: n, kind: 'card', total: card.dur, spots: [] }, null, 1));
    console.log(`${n}: card ${card.dur}s`);
    continue;
  }
  const cfg = C.chapters.find((c) => c.name === n);
  const m = chapter(analysis(cfg), speedFor(cfg, travel));
  console.log(`${n}: total ${m.total}s (src ${m.srcDur}, cut ${m.cuts}, travel ${m.speed.travel}x) spots ${m.spots.map((s) => `${s.place}${s.shift ? '+' + s.shift : ''}/${s.hold}`).join(' ')}`);
}

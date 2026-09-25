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
// where the frame differs from the t+0.3 pose (mean abs luma diff > 2 at 160x90).
function stableUntil(mp4, t) {
  const fw = 160 * 90, t0 = t + 0.3;
  const buf = execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-ss', String(t0), '-i', mp4, '-t', '2.6',
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
.foot { position: absolute; inset: 0; width: ${W}px; height: ${H}px; object-fit: contain; }
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
  const script = `tl.fromTo("#${id}-inner", { opacity: 0, y: 18 }, { opacity: 1, y: 0, duration: 0.6, ease: "power3.out" }, 0.15);
tl.fromTo("#${id}-rule", { scaleX: 0 }, { scaleX: 1, duration: 0.5, ease: "power2.out" }, 0.35);
tl.fromTo("#fade", { opacity: 0 }, { opacity: 1, duration: 0.4, ease: "power1.in" }, ${r3(dur - 0.4)});`;
  return doc(id, dur, body, script);
}

// ---------- chapter ----------
function chapter(cfg) {
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
  const CARD = cfg.cardDur ?? C.chapterCardDur;

  // spotlight windows in SOURCE time
  const spots = marks.map((m, i) => {
    const settle = stableUntil(mp4, m.t);
    const hold = Math.max(C.hold.min, Math.min(C.hold.max, settle - m.t - 0.15));
    return { m, i, T: m.t, hold, label: labels[i], settle };
  });
  for (let i = 0; i + 1 < spots.length; i++) {
    const a = spots[i], b = spots[i + 1];
    if (a.T + a.hold + 0.3 > b.T - 0.25) {
      // too close: first fades out as the second fades in; push the second only if the gap is short
      if (b.T - a.T < C.hold.min - 0.05) {
        const T2 = a.T + C.hold.min - 0.05;
        b.hold = Math.max(C.hold.min, Math.min(C.hold.max, b.settle - T2 - 0.15));
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
  const toComp = (t) => { // source -> composition time
    let acc = CARD;
    for (const [a, b] of kept) { if (t < b) return acc + Math.max(0, t - a); acc += b - a; }
    return acc;
  };
  const footDur = kept.reduce((s, [a, b]) => s + b - a, 0);
  const total = CARD + footDur;

  const vids = kept.map(([a, b], i) => `<video id="${name}-v${i}" class="foot clip" src="assets/footage/${name}.mp4" data-start="${r3(toComp(a))}" data-duration="${r3(b - a)}" data-media-start="${r3(a)}" data-track-index="0" muted playsinline></video>`).join('\n');

  const card = `<section id="${name}-card" class="card clip" data-start="0" data-duration="${CARD}" data-track-index="2">
  <div class="inner" id="${name}-inner">
    <div class="kicker">${esc(cfg.persona || C.defaultPersona || '')}</div>
    <div class="ttl">${esc(cfg.title)}</div>
    <div class="rule" id="${name}-rule"></div>
  </div>
</section>`;

  const LH = C.layout.labelHeight, GAP = C.layout.labelGap;
  const report = [];
  const overlays = spots.map((s) => {
    const { rect, cam } = s.m;
    const c = cam || { x: 0, y: 0, s: 1 };
    // frame position of a rect: (rect - cam) * cam.s  (see demo-capture handoff contract)
    let x = (rect.x - c.x) * c.s - 8, y = (rect.y - c.y) * c.s - 8, w = rect.w * c.s + 16, h = rect.h * c.s + 16;
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
    const ct = toComp(s.T);
    report.push({
      i: s.i, label: s.label, srcT: r3(s.m.t), shift: s.shift || 0, compT: r3(ct), hold: r3(s.hold),
      place: pick[0], box: [x, y, w, h].map(Math.round),
      labBox: [pick[2].left, pick[2].top, lw, LH].map(Math.round),
    });
    s.ct = ct; s.dir = pick[0];
    return `<div id="${name}-s${s.i}" class="spot" style="left:${r3(x)}px;top:${r3(y)}px;width:${r3(w)}px;height:${r3(h)}px"></div>
<div id="${name}-l${s.i}" class="lab" style="left:${r3(pick[2].left)}px;top:${r3(pick[2].top)}px">${esc(s.label)}</div>`;
  }).join('\n');

  const lines = [
    `tl.fromTo("#${name}-inner", { opacity: 0, y: 18 }, { opacity: 1, y: 0, duration: 0.5, ease: "power3.out" }, 0.1);`,
    `tl.fromTo("#${name}-rule", { scaleX: 0 }, { scaleX: 1, duration: 0.45, ease: "power2.out" }, 0.3);`,
    `tl.to("#${name}-inner", { opacity: 0, duration: 0.3, ease: "power1.in" }, ${r3(CARD - 0.35)});`,
    `tl.fromTo("#fade", { opacity: 1 }, { opacity: 0, duration: 0.35, ease: "power1.out", immediateRender: false }, ${r3(CARD)});`,
    `tl.fromTo("#fade", { opacity: 0 }, { opacity: 1, duration: 0.35, ease: "power1.in", immediateRender: false }, ${r3(total - 0.35)});`,
  ];
  for (const s of spots) {
    const dy = { 'below-cropped': -8, below: -8, above: 8, right: 0, left: 0 }[s.dir] ?? 0;
    const dx = { right: -8, left: 8 }[s.dir] || 0;
    lines.push(`tl.fromTo("#${name}-s${s.i}", { opacity: 0 }, { opacity: 1, duration: 0.25, ease: "power1.out" }, ${r3(s.ct - C.fadeLead)});`);
    lines.push(`tl.fromTo("#${name}-l${s.i}", { opacity: 0, x: ${dx}, y: ${dy} }, { opacity: 1, x: 0, y: 0, duration: 0.3, ease: "power2.out" }, ${r3(s.ct - 0.1)});`);
    lines.push(`tl.to(["#${name}-s${s.i}", "#${name}-l${s.i}"], { opacity: 0, duration: 0.3, ease: "power1.in" }, ${r3(s.ct + s.hold)});`);
  }

  const d = project(name, doc(name, total, `${vids}\n${card}\n${overlays}`, lines.join('\n')));
  copyFileSync(mp4, `${d}/assets/footage/${name}.mp4`);
  const meta = { name, kind: 'chapter', total: r3(total), srcDur: r3(dur), cardDur: CARD, kept: kept.map((k) => k.map(r3)), cuts: r3(dur - footDur), spots: report };
  writeFileSync(`${C.out}/work/${name}.plan.json`, JSON.stringify(meta, null, 1));
  return meta;
}

// ---------- run ----------
mkdirSync(`${C.out}/work`, { recursive: true });
const want = process.argv.slice(3);
for (const n of want.length ? want : segmentNames(C)) {
  const card = C.cards[n];
  if (card) {
    project(n, cardDoc(n, card));
    writeFileSync(`${C.out}/work/${n}.plan.json`, JSON.stringify({ name: n, kind: 'card', total: card.dur, spots: [] }, null, 1));
    console.log(`${n}: card ${card.dur}s`);
    continue;
  }
  const cfg = C.chapters.find((c) => c.name === n);
  if (!cfg) throw new Error(`unknown segment "${n}"`);
  const m = chapter(cfg);
  console.log(`${n}: total ${m.total}s (src ${m.srcDur}, cut ${m.cuts}) spots ${m.spots.map((s) => `${s.place}${s.shift ? '+' + s.shift : ''}/${s.hold}`).join(' ')}`);
}

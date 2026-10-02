#!/usr/bin/env node
// check.mjs <config.json> [chapter ...]
// The quality gate. For every mark it renders a still at compT+0.5 and at the end of the hold,
// and reports hit or miss per mark. Exits 1 if any mark misses.
//
// Four tests per mark, each aimed at a failure this rig has actually produced:
//   lit     the cut-out region is undimmed and the surrounding ring is dimmed
//           -> the spotlight exists, is on screen at the rect, at the right composition time
//   content the region under the cut-out carries UI detail, not flat background
//           -> the cut-out landed on something, not on empty page
//   stable  the region does not change between the two stills
//           -> DEFECT 1: the hold does not run past a camera move
//   label   the label box does not intersect the spotlight box
//           -> DEFECT 2: a label never covers its own spotlight
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync, readdirSync } from 'node:fs';
import { loadConfig, segmentNames, screenRect, frameCount, r3, hexToRgb, grayFrames } from './config.mjs';

const cfgPath = process.argv[2];
if (!cfgPath) { console.error('usage: check.mjs <config.json> [chapter ...]'); process.exit(2); }
const C = loadConfig(cfgPath);
// Measured in the screen's design px, the space compose lays out in: a rendered frame is cropped
// to the footage's screen (inside the framed window, or the whole frame when full bleed) and
// scaled to it, so every threshold below means the same thing at draft and at the 1440p master.
// The screen is the design canvas for landscape and square, the window between the bands for vertical.
const SR = screenRect(C), W = SR.sw, H = SR.sh, K = C.check, SCREEN = SR.canvas;

// Captions on the contact tiles need drawtext (libfreetype), which some ffmpeg builds lack, a
// Homebrew one included. They are for human eyes only: the verdict never depends on them.
const drawtext = / drawtext /.test(execFileSync(C.ffmpeg, ['-hide_banner', '-filters']).toString());
if (!drawtext) console.warn(`warn: ${C.ffmpeg} has no drawtext filter, so contact tiles carry no captions. For captions set FFMPEG (or "ffmpeg" in the config) to a full build, e.g. /usr/bin/ffmpeg.`);

// One frame as luma: of a video at time t, or of an image when t is null.
function grayFrame(file, t, w = W, h = H, crop) {
  const f = grayFrames(C.ffmpeg, file, { t, w, h, crop });
  if (!f.n) throw new Error(`no frame at ${t}s of ${file}`);
  return f.at(0);
}
// A rendered segment is a lossless mp4 (render.sh), frame k (0-based) at k / C.fps. The seek time
// is 0.4 frame early: a seek returns the first frame at or after it, and container timestamps
// round, so aiming at the frame's own nominal time can land on the next one.
const segFrame = (n, t) => Math.max(0, (Math.min(n - 1, Math.round(t * C.fps)) - 0.4) / C.fps);

// The source frame as the composition frames it: scaled by view.s, placed at view.x/y, and
// `bg` where the footage does not reach. Identity when the output matches the footage.
function framed(src, sw, sh, v, bg) {
  if (v.s === 1 && v.x === 0 && v.y === 0 && sw === W && sh === H) return src;
  const out = Buffer.alloc(W * H, bg);
  for (let y = 0; y < H; y++) {
    const sy = Math.floor((y - v.y) / v.s);
    if (sy < 0 || sy >= sh) continue;
    for (let x = 0; x < W; x++) {
      const sx = Math.floor((x - v.x) / v.s);
      if (sx >= 0 && sx < sw) out[y * W + x] = src[sy * sw + sx];
    }
  }
  return out;
}
const bgLuma = (([r, g, b]) => Math.round(0.299 * r + 0.587 * g + 0.114 * b))(hexToRgb(C.theme.bg));

// mean and standard deviation of luma inside a box, clipped to the frame.
// `ex` is an optional rect whose pixels are skipped (used to keep the label out of the ring).
function stats(buf, [bx, by, bw, bh], ex) {
  const x0 = Math.max(0, Math.round(bx)), y0 = Math.max(0, Math.round(by));
  const x1 = Math.min(W, Math.round(bx + bw)), y1 = Math.min(H, Math.round(by + bh));
  let n = 0, s = 0, s2 = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    if (ex && x >= ex[0] && x < ex[0] + ex[2] && y >= ex[1] && y < ex[1] + ex[3]) continue;
    const v = buf[y * W + x]; n++; s += v; s2 += v * v; }
  if (!n) return { n: 0, mean: 0, sd: 0 };
  const mean = s / n;
  return { n, mean, sd: Math.sqrt(Math.max(0, s2 / n - mean * mean)) };
}

// mean absolute difference inside a box between two frames
function diff(a, b, [bx, by, bw, bh]) {
  const x0 = Math.max(0, Math.round(bx)), y0 = Math.max(0, Math.round(by));
  const x1 = Math.min(W, Math.round(bx + bw)), y1 = Math.min(H, Math.round(by + bh));
  let n = 0, s = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { const i = y * W + x; s += Math.abs(a[i] - b[i]); n++; }
  return n ? s / n : 0;
}

// A ring outside the box: four bands, each `pad` deep, offset `off` clear of the edge.
// `off` must clear the spotlight's outer glow (2px spread + 22px blur) and the feather of the
// cut-out (spotlight.feather, at most 24px, so config.mjs caps it), or they read as "not dimmed"
// and every mark fails. The label rect is excluded for the same reason.
function ringMean(buf, [x, y, w, h], lab, off = 34, pad = 30) {
  const bands = [
    [x - off - pad, y, pad, h], [x + w + off, y, pad, h],
    [x, y - off - pad, w, pad], [x, y + h + off, w, pad],
  ];
  let n = 0, s = 0;
  for (const b of bands) { const st = stats(buf, b, lab); n += st.n; s += st.mean * st.n; }
  return n ? s / n : 0;
}

// The source time shown at composition time `out` of a spot: proof windows play at 1x, less any
// narration freeze (plan.freezes, [start, length] in composition seconds) between the mark and
// `out`. Inside a freeze the footage shows the frame before it, so read just before its point.
function sourceAt(plan, s, out) {
  let held = 0, inside = false;
  for (const [f0, d] of plan.freezes || []) {
    held += Math.max(0, Math.min(out, f0 + d) - Math.max(s.compT, f0));
    if (out > f0 && out < f0 + d) inside = true;
  }
  return s.srcT + (s.shift || 0) + (out - s.compT) - held - (inside ? 0.02 : 0);
}

const overlaps = (a, b) => a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3];

function checkChapter(name) {
  const planPath = `${C.out}/work/${name}.plan.json`;
  if (!existsSync(planPath)) throw new Error(`${name}: no plan, run compose.mjs first`);
  const plan = JSON.parse(readFileSync(planPath, 'utf8'));
  if (plan.kind === 'card') return [];
  const seg = `${C.out}/out/seg/${name}.mp4`;
  if (!existsSync(seg)) throw new Error(`${name}: no rendered segment at ${seg}, run render.sh first`);
  const nSeg = frameCount(C, seg);
  const src = `${C.takes}/${name}.mp4`;
  const stillDir = `${C.out}/work/stills/${name}`;
  rmSync(stillDir, { recursive: true, force: true }); mkdirSync(stillDir, { recursive: true });

  const rows = [];
  for (const s of plan.spots) {
    // inset past the 2px border and the glow so the border itself is not measured
    const box = [s.box[0] + 6, s.box[1] + 6, s.box[2] - 12, s.box[3] - 12];
    // Still A: 0.5s after the mark, or later if the spotlight only started at litFrom (it waits for
    // the camera to settle): sampling mid-fade read a correct render as "no scrim".
    // Still B is 0.05s before the fade-out. A must stay at least 0.1s before B: a later A sat in the
    // fade-out (a false "no scrim") and ran the drift test backwards. A hold too short for that is
    // reported as such, and the scrim and drift tests, which cannot be read there, are skipped.
    const need = (s.litFrom ?? s.compT) + (s.fadeIn ?? 0.25) + 0.1 - s.compT;
    const short = need > s.hold - 0.15, a = Math.min(Math.max(0.5, need), s.hold - 0.15);
    const at = [r3(s.compT + a), r3(s.compT + s.hold - 0.05)];
    const atSrc = at.map((t) => r3(sourceAt(plan, s, t)));
    const why = [];
    if (short) why.push(`lit too briefly to check: fully lit at +${r3(need - 0.1)}s, fades out at +${r3(s.hold)}s`);
    // Never read a still inside a transition: the window is still arriving (tilt, entrance)
    // before settledFrom, and the seam into the next segment starts at tailFrom.
    if (at[0] < (plan.settledFrom ?? 0) || at[1] > (plan.tailFrom ?? Infinity)) why.push(`still inside a transition (${at[0]}-${at[1]}s; window settles ${plan.settledFrom}s, seam ${plan.tailFrom}s)`);

    const ren = at.map((t) => grayFrame(seg, segFrame(nSeg, t), W, H, SCREEN));
    const sw = plan.srcW ?? W, sh = plan.srcH ?? H, view = s.view ?? { s: 1, x: 0, y: 0 };
    const raw = atSrc.map((t) => framed(grayFrame(src, t, sw, sh), sw, sh, view, bgLuma));

    // lit: undimmed inside, dimmed outside, measured against the same frame of the source
    const litR = [0, 1].map((k) => stats(ren[k], box).mean / Math.max(1, stats(raw[k], box).mean));
    const dimR = [0, 1].map((k) => ringMean(ren[k], s.box, s.labBox) / Math.max(1, ringMean(raw[k], s.box, s.labBox)));
    if (!short && Math.min(...litR) < K.litRatio) why.push(`dim cut-out ${r3(Math.min(...litR))}`);
    if (!short && Math.max(...dimR) > K.dimRatio) why.push(`no scrim ${r3(Math.max(...dimR))}`);

    // content: the cut-out is over UI, not flat background
    const sd = Math.max(...raw.map((f) => stats(f, box).sd));
    if (sd < K.contentSd) why.push(`flat cut-out sd ${r3(sd)}`);

    // stable: the frame under the cut-out has not moved by the end of the hold
    const drift = diff(raw[0], raw[1], box);
    if (!short && drift > K.driftMax) why.push(`drift ${r3(drift)}`);

    // label clear of its own spotlight
    if (overlaps(s.labBox, s.box)) why.push('label covers spotlight');

    rows.push({ name, i: s.i, label: s.label, compT: s.compT, hold: s.hold, place: s.place,
      lit: r3(Math.min(...litR)), dim: r3(Math.max(...dimR)), sd: r3(sd), drift: r3(drift),
      ok: !why.length, why: why.join('; ') });

    // contact tiles for eyeballing alongside the numbers, named 000.png, 001.png, ... in mark order,
    // cropped to the screen like the readings, so a tile shows exactly the boxes the numbers measured
    for (const [k, t] of at.entries()) {
      const cap = drawtext ? `,drawtext=text='m${s.i} ${'ab'[k]} t=${t}':x=6:y=6:fontsize=18:fontcolor=cyan:box=1:boxcolor=black` : '';
      execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-ss', String(segFrame(nSeg, t)), '-i', seg, '-frames:v', '1',
        '-vf', `crop=${SCREEN[2]}:${SCREEN[3]}:${SCREEN[0]}:${SCREEN[1]},scale=${W / 2}:${H / 2}${cap}`, '-update', '1', `${stillDir}/${String(2 * rows.length - 2 + k).padStart(3, '0')}.png`]);
    }
  }
  // An image2 sequence, not -pattern_type glob, which some builds do not support.
  const tiles = readdirSync(stillDir).length;
  // '%' in the path is doubled: ffmpeg reads the input as a %03d sequence pattern.
  if (tiles) execFileSync(C.ffmpeg, ['-loglevel', 'error', '-y', '-i', `${stillDir.replace(/%/g, '%%')}/%03d.png`,
    '-vf', `tile=2x${Math.ceil(tiles / 2)}`, '-frames:v', '1', '-update', '1', `${C.out}/work/stills-${name}.png`]);
  return rows;
}

const want = process.argv.slice(3);
const names = want.length ? want : segmentNames(C).filter((n) => !C.cards[n]);
const all = names.flatMap(checkChapter);
console.log('chapter                  m  compT   hold  place          lit   dim   sd    drift  result');
for (const r of all) {
  console.log(`${r.name.padEnd(24)} ${String(r.i).padEnd(2)} ${String(r.compT).padEnd(6)} ${String(r.hold).padEnd(5)} ${r.place.padEnd(14)} ${String(r.lit).padEnd(5)} ${String(r.dim).padEnd(5)} ${String(r.sd).padEnd(5)} ${String(r.drift).padEnd(6)} ${r.ok ? 'hit' : 'MISS ' + r.why}`);
}
const miss = all.filter((r) => !r.ok);
writeFileSync(`${C.out}/work/check.json`, JSON.stringify(all, null, 1));
console.log(`\n${all.length - miss.length}/${all.length} marks hit. Sheets: ${C.out}/work/stills-<chapter>.png`);
process.exit(miss.length ? 1 : 0);

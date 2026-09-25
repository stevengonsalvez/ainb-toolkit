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
import { loadConfig, segmentNames, r3 } from './config.mjs';

const cfgPath = process.argv[2];
if (!cfgPath) { console.error('usage: check.mjs <config.json> [chapter ...]'); process.exit(2); }
const C = loadConfig(cfgPath);
const W = C.width, H = C.height, K = C.check;

function grayFrame(mp4, t) {
  const buf = execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-ss', String(t), '-i', mp4,
    '-frames:v', '1', '-vf', `scale=${W}:${H},format=gray`, '-f', 'rawvideo', '-'], { maxBuffer: 1 << 28 });
  if (buf.length < W * H) throw new Error(`no frame at ${t}s of ${mp4}`);
  return buf;
}

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
// `off` must clear the spotlight's outer glow (3px spread + 22px blur), or the glow reads as
// "not dimmed" and every mark fails. The label rect is excluded for the same reason.
function ringMean(buf, [x, y, w, h], lab, off = 34, pad = 30) {
  const bands = [
    [x - off - pad, y, pad, h], [x + w + off, y, pad, h],
    [x, y - off - pad, w, pad], [x, y + h + off, w, pad],
  ];
  let n = 0, s = 0;
  for (const b of bands) { const st = stats(buf, b, lab); n += st.n; s += st.mean * st.n; }
  return n ? s / n : 0;
}

const overlaps = (a, b) => a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3];

function checkChapter(name) {
  const planPath = `${C.out}/work/${name}.plan.json`;
  if (!existsSync(planPath)) throw new Error(`${name}: no plan, run compose.mjs first`);
  const plan = JSON.parse(readFileSync(planPath, 'utf8'));
  if (plan.kind === 'card') return [];
  const seg = `${C.out}/out/seg/${name}.mp4`;
  if (!existsSync(seg)) throw new Error(`${name}: no rendered segment at ${seg}, run render.sh first`);
  const src = `${C.takes}/${name}.mp4`;
  const stillDir = `${C.out}/work/stills/${name}`;
  rmSync(stillDir, { recursive: true, force: true }); mkdirSync(stillDir, { recursive: true });

  const rows = [];
  for (const s of plan.spots) {
    // inset past the 2px border and the glow so the border itself is not measured
    const box = [s.box[0] + 6, s.box[1] + 6, s.box[2] - 12, s.box[3] - 12];
    const at = [r3(s.compT + 0.5), r3(s.compT + s.hold - 0.05)];
    const atSrc = [r3(s.srcT + (s.shift || 0) + 0.5), r3(s.srcT + (s.shift || 0) + s.hold - 0.05)];
    const why = [];

    const ren = at.map((t) => grayFrame(seg, t));
    const raw = atSrc.map((t) => grayFrame(src, t));

    // lit: undimmed inside, dimmed outside, measured against the same frame of the source
    const litR = [0, 1].map((k) => stats(ren[k], box).mean / Math.max(1, stats(raw[k], box).mean));
    const dimR = [0, 1].map((k) => ringMean(ren[k], s.box, s.labBox) / Math.max(1, ringMean(raw[k], s.box, s.labBox)));
    if (Math.min(...litR) < K.litRatio) why.push(`dim cut-out ${r3(Math.min(...litR))}`);
    if (Math.max(...dimR) > K.dimRatio) why.push(`no scrim ${r3(Math.max(...dimR))}`);

    // content: the cut-out is over UI, not flat background
    const sd = Math.max(...raw.map((f) => stats(f, box).sd));
    if (sd < K.contentSd) why.push(`flat cut-out sd ${r3(sd)}`);

    // stable: the frame under the cut-out has not moved by the end of the hold
    const drift = diff(raw[0], raw[1], box);
    if (drift > K.driftMax) why.push(`drift ${r3(drift)}`);

    // label clear of its own spotlight
    if (overlaps(s.labBox, s.box)) why.push('label covers spotlight');

    rows.push({ name, i: s.i, label: s.label, compT: s.compT, hold: s.hold, place: s.place,
      lit: r3(Math.min(...litR)), dim: r3(Math.max(...dimR)), sd: r3(sd), drift: r3(drift),
      ok: !why.length, why: why.join('; ') });

    // contact tiles for eyeballing alongside the numbers
    for (const [k, t] of at.entries()) {
      try {
        execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-ss', String(t), '-i', seg, '-frames:v', '1',
          '-vf', `scale=640:360,drawtext=text='m${s.i} ${'ab'[k]} t=${t}':x=6:y=6:fontsize=18:fontcolor=cyan:box=1:boxcolor=black`,
          `${stillDir}/${String(s.i).padStart(2, '0')}${'ab'[k]}.png`], { stdio: ['ignore', 'ignore', 'pipe'] });
      } catch (e) {
        if (/drawtext/.test(e.stderr)) throw new Error(`${C.ffmpeg} has no drawtext filter. Set FFMPEG (or "ffmpeg" in the config) to a full build, e.g. /usr/bin/ffmpeg`);
        throw e;
      }
    }
  }
  const tiles = readdirSync(stillDir).length;
  if (tiles) execFileSync(C.ffmpeg, ['-loglevel', 'error', '-y', '-pattern_type', 'glob', '-i', `${stillDir}/*.png`,
    '-vf', `tile=2x${Math.ceil(tiles / 2)}`, '-frames:v', '1', `${C.out}/work/stills-${name}.png`]);
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

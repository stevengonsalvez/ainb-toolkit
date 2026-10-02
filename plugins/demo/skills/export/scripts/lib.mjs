// ABOUTME: Shared pieces of demo:export: reading a composed demo (compose config, plans,
// events), the README loop picker, the interactive step builder, and the checks both share.
// Everything here only READS demo:capture and demo:compose output; it never writes into them.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
// The compose skill's own config reader, so segment order and paths match the render exactly.
import { loadConfig, segmentNames, eventsPath, grayFrames, mad } from '../../compose/scripts/config.mjs';

export { loadConfig };
export const SKILL = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const r3 = (x) => Math.round(x * 1000) / 1000;

// ffmpeg resolution, as in the other skills: $FFMPEG, else the distro build at /usr/bin, else PATH.
// export.mjs sets $FFMPEG from the compose config first, so the config's `ffmpeg` key wins.
const ffbin = (name) => process.env[name.toUpperCase()] || (existsSync(`/usr/bin/${name}`) ? `/usr/bin/${name}` : name);
export const FFMPEG = () => ffbin('ffmpeg');
let encoders;
export const hasEncoder = (enc) => {
  try { encoders ??= execFileSync(FFMPEG(), ['-hide_banner', '-encoders'], { encoding: 'utf8' }).split('\n').map((l) => l.split(/\s+/)[2]); }
  catch { encoders = []; }
  return encoders.includes(enc);
};
export const which = (bin) => { try { return execFileSync('sh', ['-c', 'command -v "$0"', bin], { encoding: 'utf8' }).trim() || null; } catch { return null; } };

// The composed demo as one timeline, in composition seconds from the start of the final mp4.
// Segment starts come from each plan (newer compose writes `start`), else from summing the
// totals in render order. Each spotlight is lit from `lit` (it fades in there) to `end` (its
// fade-out has finished), and `settled` once both the cut-out and its label are fully in (the
// label starts at compT - 0.1 pace, or at lit if later, and takes 0.3 pace: compose.mjs's
// timings). A chapter's footage runs from after its card and fade-in to before its closing fade.
export function timeline(C) {
  const segs = []; let at = 0;
  for (const name of segmentNames(C)) {
    const p = `${C.out}/work/${name}.plan.json`;
    if (!existsSync(p)) throw new Error(`${name}: no plan at ${p}; run demo:compose first`);
    const plan = JSON.parse(readFileSync(p, 'utf8'));
    const start = plan.start ?? at;
    at = start + plan.total;
    if (plan.kind !== 'chapter') { segs.push({ name, kind: plan.kind, start, total: plan.total }); continue; }
    const fade = 0.35 * C.pace, out = 0.3 * C.pace;
    const spots = plan.spots.map((s) => {
      const lit = s.litFrom ?? s.compT - C.fadeLead;
      const labIn = Math.max(lit, s.compT - 0.1 * C.pace) + 0.3 * C.pace, cutIn = lit + (s.fadeIn ?? 0.25 * C.pace);
      return { i: s.i, label: s.label, hold: s.hold, lit: r3(start + lit), at: r3(start + s.compT),
        settled: r3(start + Math.min(s.compT + s.hold - 0.05, Math.max(labIn, cutIn) + 0.1)),
        end: r3(start + s.compT + s.hold + out) };
    });
    segs.push({ name, kind: 'chapter', start, total: plan.total, title: C.chapters.find((c) => c.name === name)?.title ?? name,
      a0: r3(start + plan.cardDur + fade), a1: r3(start + plan.total - fade), spots, narration: plan.narration || [] });
  }
  return { segs, total: r3(at), chapters: segs.filter((s) => s.kind === 'chapter') };
}

// A range [a, b] cuts a spotlight when it overlaps one without containing all of it.
export const cutSpots = ([a, b], spots) => spots.filter((s) => s.lit < b && s.end > a && !(s.lit >= a - 1e-6 && s.end <= b + 1e-6));

// The README loop: a stretch of one chapter that contains whole spotlights only (it starts and
// ends between them, inside the chapter's footage, never mid-fade), as long as min..max seconds.
// It leads in `lead` before the first spotlight so the camera move into it is in the loop, and
// tails `tail` after the last. Compose crossfades close spotlights (one fades out as the next
// fades in), so a span whose first spotlight lights before the previous one has gone, or whose
// last is still lit when the next lights, cuts one: it is skipped. Scored by how many
// spotlights it holds, how close it runs to the middle of the range, `seam(a, b)`, how alike its
// first and last frames are (0 = identical), and `motion(a, b)`, how much the frame moves at
// either end (a loop that stops mid zoom-out jumps on restart however alike the frames are).
export function pickLoop(chapters, { min = 8, max = 12, lead = 1.2, tail = 0.6, seam = () => 0, motion = () => 0 } = {}) {
  const cands = [];
  for (const ch of chapters) {
    const S = ch.spots;
    for (let i = 0; i < S.length; i++) for (let j = i; j < S.length; j++) {
      const lo = i ? S[i - 1].end : ch.a0, hi = j + 1 < S.length ? S[j + 1].lit : ch.a1;
      if (lo > S[i].lit + 1e-6 || hi < S[j].end - 1e-6) continue;   // crossfaded with a neighbour
      let a = Math.max(lo, S[i].lit - lead), b = Math.min(hi, S[j].end + tail);
      // Growing to min only moves a down (not below lo) and b up (not past hi), so the span keeps
      // its spotlights whole and its neighbours out; selfcheck.mjs holds that over random plans.
      if (b - a < min) { a = Math.max(lo, b - min); }
      if (b - a < min) { b = Math.min(hi, a + min); }
      if (b - a > max + 1e-6) continue;
      cands.push({ chapter: ch.name, title: ch.title, a: r3(a), b: r3(b), spots: S.slice(i, j + 1), short: b - a < min - 1e-6 });
    }
  }
  if (!cands.length) return null;
  const mid = (min + max) / 2;
  for (const c of cands) {
    c.seam = seam(c.a, c.b); c.motion = motion(c.a, c.b);
    c.score = (c.short ? -100 : 0) + 10 * c.spots.length - Math.abs(c.b - c.a - mid) - 0.2 * c.seam - 0.5 * c.motion;
  }
  const best = cands.sort((x, y) => y.score - x.score)[0];
  const cut = cutSpots([best.a, best.b], chapters.find((c) => c.name === best.chapter).spots);
  if (cut.length) throw new Error(`loop picker: ${best.a}s to ${best.b}s cuts "${cut[0].label}" (a bug: please report it)`);
  return best;
}

// Mean absolute luma difference between the frames at a and b of a video (0..255).
const frames = new Map();                            // seam and motion read the same end frames
const frameAt = (video, t) => {
  const k = `${video}@${r3(Math.max(0, t))}`;
  if (!frames.has(k)) frames.set(k, grayFrames(FFMPEG(), video, { t: Math.max(0, t) }).at(0));
  return frames.get(k);
};
export const seamOf = (video) => (a, b) => mad(frameAt(video, a), frameAt(video, b - 0.04));
// How much the picture moves over the first and the last 1/15 s of a loop: the sum of the two.
export const motionOf = (video) => (a, b) => mad(frameAt(video, a), frameAt(video, a + 1 / 15)) + mad(frameAt(video, b - 0.04 - 1 / 15), frameAt(video, b - 0.04));

// A mark's or event's rect (page CSS px) on the take's frame, in frame (device) px: through the
// camera box when zoomed, times the take's pixel density.
export function onFrame(rect, cam, dpr) {
  const c = cam || { x: 0, y: 0, s: 1 };
  return { x: (rect.x - c.x) * c.s * dpr, y: (rect.y - c.y) * c.s * dpr, w: rect.w * c.s * dpr, h: rect.h * c.s * dpr };
}
// The part of a box inside a W x H frame, or null when none of it is.
export function clipTo(b, W, H) {
  const x0 = Math.max(0, b.x), y0 = Math.max(0, b.y), x1 = Math.min(W, b.x + b.w), y1 = Math.min(H, b.y + b.h);
  return x1 - x0 >= 1 && y1 - y0 >= 1 ? { x: x0, y: y0, w: x1 - x0, h: y1 - y0 } : null;
}
// Hotspot copy: under 60 characters (Arcade: over 60 cuts completion 12%), cut at a word.
export function shortLabel(s, max = 59) {
  s = String(s).replace(/\s+/g, ' ').trim();
  if (s.length <= max) return s;
  const cut = s.slice(0, max - 1), sp = cut.lastIndexOf(' ');
  return `${(sp > max * 0.6 ? cut.slice(0, sp) : cut).replace(/[\s,.;:]+$/, '')}…`;
}

// Interactive steps, in demo order: every mark (it has a rect and a label), plus every click or
// type cue that carries a `rect` (takes filmed before demo:capture recorded one have none; those
// are counted and skipped). A type beat is filmed as a click into the field
// then the type cue: one step, at the click's frame and rect (the field before it widened or hid
// while typing). Each step points at the take frame that first shows it and the camera box in
// force there (the cue's own `cam` when it has one).
export function steps(C, tl) {
  const out = []; let skipped = 0;
  for (const ch of tl.chapters) {
    const ev = JSON.parse(readFileSync(eventsPath(C.takes, ch.name), 'utf8'));
    const dpr = ev.dpr ?? 1, fps = ev.fps ?? 30, vp = ev.viewport || { width: 1280, height: 720 };
    let cam = null, mark = 0, click = null;      // click: the step the cue just before made, if a click
    const said = (i) => ch.narration.find((l) => l.slot === i)?.text;
    for (const e of [...ev.events].sort((x, y) => x.t - y.t)) {
      const after = click; click = null;
      if (e.kind === 'camera') { cam = e.cam; continue; }
      if (e.kind === 'mark') {
        // narration, else compose's label for this spotlight (config `labels` override the
        // capture's), else the capture's own
        out.push({ chapter: ch.name, title: ch.title, kind: 'mark', t: e.t, frame: Math.round(e.t * fps), rect: e.rect, cam: e.cam, dpr, fps, vp,
          text: said(mark) || ch.spots.find((s) => s.i === mark)?.label || e.label, mark: mark++ });
      } else if (e.kind === 'click' || e.kind === 'type') {
        if (e.kind === 'type' && after && e.t - after.t < 1) { Object.assign(after, { kind: 'type', text: e.label || 'Type here' }); continue; }
        if (!e.rect) { skipped++; continue; }
        out.push({ chapter: ch.name, title: ch.title, kind: e.kind, t: e.t, frame: Math.max(0, Math.round(e.t * fps) - 1), rect: e.rect,
          cam: e.cam !== undefined ? e.cam : cam, dpr, fps, vp, text: e.label || (e.kind === 'type' ? 'Type here' : 'Click here') });
        if (e.kind === 'click') click = out.at(-1);
      }
    }
  }
  return { steps: out, skipped };
}

// Arcade's benchmarks: 9-12 steps finish most often; past step 7 viewers drop off, so the payoff
// should land by then.
export function lint(stepList, payoffIndex) {
  const warn = [];
  if (stepList.length < 9 || stepList.length > 12) warn.push(`${stepList.length} steps; 9 to 12 finish most often`);
  if (payoffIndex >= 7) warn.push(`the payoff is step ${payoffIndex + 1}; past step 7 most viewers have left`);
  return warn;
}

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
// fade-out has finished); a chapter's footage runs from after its card and fade-in to before its
// closing fade.
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
    const spots = plan.spots.map((s) => ({
      i: s.i, label: s.label, hold: s.hold,
      lit: r3(start + (s.litFrom ?? s.compT - C.fadeLead)), at: r3(start + s.compT),
      settled: r3(start + Math.min(s.compT + s.hold - 0.1, Math.max(s.compT + 0.5, (s.litFrom ?? s.compT) + (s.fadeIn ?? 0.25) + 0.1))),
      end: r3(start + s.compT + s.hold + out),
    }));
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
// tails `tail` after the last. Scored by how many spotlights it holds, how close it runs to the
// middle of the range, and `seam(a, b)`, how alike its first and last frames are (0 = identical),
// so the loop jumps as little as possible when it restarts.
export function pickLoop(chapters, { min = 8, max = 12, lead = 1.2, tail = 0.6, seam = () => 0 } = {}) {
  const cands = [];
  for (const ch of chapters) {
    const S = ch.spots;
    for (let i = 0; i < S.length; i++) for (let j = i; j < S.length; j++) {
      const lo = i ? S[i - 1].end : ch.a0, hi = j + 1 < S.length ? S[j + 1].lit : ch.a1;
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
  for (const c of cands) c.score = (c.short ? -100 : 0) + 10 * c.spots.length - Math.abs(c.b - c.a - mid) - 0.2 * seam(c.a, c.b);
  return cands.sort((x, y) => y.score - x.score)[0];
}

// Mean absolute luma difference between the frames at a and b of a video (0..255).
export const seamOf = (video) => (a, b) => mad(grayFrames(FFMPEG(), video, { t: a }).at(0), grayFrames(FFMPEG(), video, { t: Math.max(0, b - 0.04) }).at(0));

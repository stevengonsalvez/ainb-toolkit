// ABOUTME: Narrative lint for a beats file: the pacing rules from demo research that map onto
// beats, checked against the timeline the beats will film (estimated from their own durations, at
// pace). Warnings only; run.mjs prints them with the dry run.
//   - the payoff: each chapter's first mark on screen by 3 s (a hook inside 3 s keeps viewers)
//   - no static frame over 2 s: a hold that long with no mark in its beat
//   - narration at 120 to 160 words a minute over the time until the next mark (compose freezes
//     the footage to fit a longer line, so the take runs slow; a sparser one leaves silence)
//   - at most 5 chapters and 120 s in all (retention falls off past two minutes)
import fs from 'fs'; import path from 'path';

// Seconds each part of a beat takes on film, from capture.mjs's defaults (screencast timings; the
// deterministic click lead is within a frame or two of them). `ready` and network waits are 0 here.
export function estimate(beats, pace = 1) {
  const P = (ms) => (ms * pace) / 1000;
  let t = 0;
  const marks = [], beatsOut = [];
  for (const [i, b] of beats.entries()) {
    const t0 = t;
    if (i > 0 && b.goto) t += P(b.settle ?? 400);
    if (b.click) t += P(520) + P(b.settle ?? 400);
    if (b.scroll) t += 0.7;
    if (b.type) t += P(520) + String(b.type.text).length / (b.type.cps ?? 12) + P(b.settle ?? 400);
    if (b.zoom) t += P(b.zoom.ms ?? 700);
    if (b.wide) t += P(b.wide === true ? 700 : b.wide);
    if (b.mark) marks.push({ t, beat: b.name || `#${i}`, label: b.mark.label });
    if (b.hold) t += P(b.hold);
    beatsOut.push({ beat: b.name || `#${i}`, t0, t1: t, hold: b.hold ? P(b.hold) : 0, mark: !!b.mark });
  }
  return { dur: t + P(500), marks, beats: beatsOut };
}

const words = (s) => String(s).replace(/\{@[^}]*\}/g, '').split(/\s+/).filter(Boolean).length;
const r1 = (x) => Math.round(x * 10) / 10;

// cfg: the beats file's default export. compose: that demo's compose config (for narration), or null.
export function narrativeLint(cfg, compose = null) {
  const warn = [];
  let total = 0;
  for (const ch of cfg.chapters) {
    const e = estimate(ch.beats, ch.pace ?? cfg.pace ?? 1);
    total += e.dur;
    if (!e.marks.length) warn.push(`${ch.name}: no mark, so nothing is pointed at; give it one, or fold it into another chapter`);
    else if (e.marks[0].t > 3) warn.push(`${ch.name}: first mark ("${e.marks[0].label}") at about ${r1(e.marks[0].t)}s; put the payoff on screen by 3s (cut or shorten what comes before it)`);
    for (const b of e.beats) if (b.hold > 2 && !b.mark) warn.push(`${ch.name}: beat "${b.beat}" holds ${r1(b.hold)}s with no mark; over 2s of a still frame loses viewers (shorten it, or mark what to look at)`);
    const lines = compose?.chapters?.find((c) => c.name === ch.name)?.narration?.marks || [];
    lines.forEach((line, k) => {
      const m = e.marks[k];
      if (!line || !m) return;
      const win = (e.marks[k + 1]?.t ?? e.dur) - m.t, wpm = (words(line) / win) * 60;
      if (wpm > 160) warn.push(`${ch.name}: narration for "${m.label}" runs ${Math.round(wpm)} wpm over the ${r1(win)}s before the next mark (aim 120 to 160): hold the mark longer or say less; compose will freeze the footage to fit`);
      else if (wpm < 120 && win > 3) warn.push(`${ch.name}: narration for "${m.label}" runs ${Math.round(wpm)} wpm over ${r1(win)}s (aim 120 to 160): a long silence; say more or hold less`);
    });
  }
  if (cfg.chapters.length > 5) warn.push(`${cfg.chapters.length} chapters; one idea each, and past 5 the story fragments: merge or cut`);
  if (total > 120) warn.push(`about ${Math.round(total)}s of footage before cards; viewers fall off past two minutes: cut a chapter`);
  return warn;
}

// The compose config a beats file names (`compose: './demo.config.json'`, relative to the beats
// file), or null.
export function composeFor(cfg, beatsFile) {
  if (!cfg.compose) return null;
  const p = path.resolve(path.dirname(beatsFile), cfg.compose);
  return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : null;
}

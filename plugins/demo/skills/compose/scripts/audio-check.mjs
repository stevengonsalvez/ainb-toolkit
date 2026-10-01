#!/usr/bin/env node
// audio-check.mjs: the sound layer's timing logic on synthetic input, no TTS, no render, a second.
// node audio-check.mjs   (exit 1 on the first failure)
import assert from 'node:assert/strict';
import { parseLine, align, fitNarration, locateAnchor } from './audio.mjs';

// 1. `{@name}` marks the word after it; without one the first word is the anchor.
assert.deepEqual(parseLine('Click {@save}Save and it syncs.'), { words: ['Click', 'Save', 'and', 'it', 'syncs.'], anchor: 1, text: 'Click Save and it syncs.' });
assert.equal(parseLine('Only six {@cars} cars left.').anchor, 2);
assert.equal(parseLine('No anchor here.').anchor, 0);

// 2. Script spelling kept, times taken from matching heard words, a misheard word interpolated.
const heard = [{ text: 'Scary', start: 0.05, end: 0.4 }, { text: 'Ferries', start: 0.4, end: 0.9 }, { text: 'sail.', start: 1.0, end: 1.4 }];
const al = align(['Skerry', 'Ferries', 'sail.'], heard, 1.5);
assert.deepEqual(al.map((w) => w.text), ['Skerry', 'Ferries', 'sail.']);
assert.equal(al[1].start, 0.4); assert.equal(al[2].start, 1.0);
assert.ok(al[0].start === 0 && al[0].end === 0.4, `unmatched first word fills the gap before its neighbour: ${JSON.stringify(al[0])}`);

// 3. fitNarration on a plain timeline (comp = source + 2s card, plus freezes): every anchor lands
//    on its spotlight, lines never overlap, and a hold lasts until its line (plus tail) is over.
const N = { lead: 0.3, gap: 0.35, tail: 0.35 };
const timeline = (fz) => (t) => 2 + t + fz.reduce((a, f) => a + (f.t <= t + 1e-9 ? f.d : 0), 0);
const spots = [{ T: 1.0, hold: 1.5 }, { T: 2.8, hold: 1.5 }];
const clips = { intro: { dur: 2.5 }, marks: [{ dur: 3.0, anchor: 0.6 }, { dur: 1.0, anchor: 0.2 }] };
const { freezes, placed } = fitNarration(spots, clips, timeline, N);
const toComp = timeline(freezes);
for (const p of placed.filter((x) => typeof x.slot === 'number')) assert.ok(Math.abs(p.at + p.anchor - toComp(spots[p.slot].T)) < 1e-9, `m${p.slot} anchor off its spotlight`);
for (let i = 1; i < placed.length; i++) assert.ok(placed[i].at >= placed[i - 1].at + placed[i - 1].dur + N.gap - 1e-9, `line ${i} overlaps the one before`);
for (const p of placed.filter((x) => typeof x.slot === 'number')) assert.ok(toComp(spots[p.slot].T + spots[p.slot].hold) >= p.at + p.dur + N.tail - 1e-9, `m${p.slot} hold ends before its line`);
for (const f of freezes) assert.ok(Math.abs(f.d * 30 - Math.round(f.d * 30)) < 1e-6, `freeze ${f.d}s is not whole frames`);

// 3b. A spotlight that waits for the camera (from > T - fade) is fully lit at from + fade; the
//     anchor follows it, and a first-mark freeze goes where the spotlight starts.
{
  const sp = [{ T: 1.0, hold: 1.5, from: 1.2, fade: 0.25 }];
  const r = fitNarration(sp, { intro: { dur: 3.0 }, marks: [{ dur: 1.0, anchor: 0.3 }] }, timeline, N);
  const tc = timeline(r.freezes), p = r.placed.find((x) => x.slot === 0);
  assert.ok(Math.abs(p.at + p.anchor - (tc(1.2) + 0.25)) < 1e-9, 'anchor is not on the settled spotlight');
  assert.equal(r.freezes[0].t, 1.2);
}

// 4. locateAnchor finds where a tail clip starts inside a line. Synthetic speech: tone syllables in
//    different bands with a little noise; the tail is the same syllables generated again with fresh
//    noise and a 10% longer first syllable, so it matches the envelope, never the samples.
const SR = 48000;
let seed = 3; const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
function syl(out, at, len, hz, amp) {
  for (let i = 0; i < len * SR; i++) { const t = i / SR, e = Math.sin(Math.PI * t / len) ** 2; out[Math.round(at * SR) + i] += amp * e * (0.85 * Math.sin(2 * Math.PI * hz * t) + 0.15 * (rnd() * 2 - 1)); }
}
const plan = [[0.12, 300, 0.8], [0.09, 900, 0.5], [0.15, 450, 1], [0.08, 2400, 0.4], [0.2, 600, 0.9], [0.1, 1500, 0.6], [0.14, 350, 0.8]];
const line = new Float32Array(SR * 3), tail = new Float32Array(SR * 2);
let t = 0.1; const at = [];
for (const [len, hz, amp] of plan) { at.push(t); syl(line, t, len, hz, amp); t += len + 0.04; }
const k = 3; let u = 0.05;
for (const [q, [len, hz, amp]] of plan.slice(k).entries()) { syl(tail, u, len * (q ? 1 : 1.1), hz, amp); u += len * (q ? 1 : 1.1) + 0.04; }
const truth = at[k], got = locateAnchor(line, tail, truth - 0.2);
assert.ok(Math.abs(got.at - truth) <= 0.015 && got.r > 0.8, `anchor at ${got.at} (r ${got.r}), expected ${truth}`);

console.log(`audio-check OK: anchors on spotlights, ${freezes.length} freezes in whole frames, located tail at ${got.at}s (truth ${truth.toFixed(3)}, r ${got.r.toFixed(3)})`);

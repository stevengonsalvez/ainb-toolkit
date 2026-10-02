#!/usr/bin/env node
// audio-check.mjs: the sound layer's timing logic on synthetic input, no TTS, no render, a second.
// node audio-check.mjs   (exit 1 on the first failure)
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseLine, align, fitNarration, locateAnchor, fitGrid, audioSettings, narrationClips, loudness } from './audio.mjs';
import { clipSpans, resolveBeats } from './config.mjs';
import { execFileSync } from 'node:child_process';
import { vtt } from './captions.mjs';

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

// 3c. A spotlight that starts before its mark (no camera to wait for: from = T - fade) and a
//     first-mark freeze: the freeze goes where the fade starts, so the fade, and the anchor word
//     with it, come after the freeze rather than the spotlight sitting lit through it.
{
  const sp = [{ T: 1.0, hold: 1.5, from: 0.75, fade: 0.25 }];
  const r = fitNarration(sp, { intro: { dur: 3.0 }, marks: [{ dur: 1.0, anchor: 0.3 }] }, timeline, N);
  const tc = timeline(r.freezes), p = r.placed.find((x) => x.slot === 0);
  assert.equal(r.freezes[0].t, 0.75, 'first-mark freeze is not at the start of the fade');
  assert.ok(Math.abs(p.at + p.anchor - (tc(0.75) + 0.25)) < 1e-9 && Math.abs(tc(0.75) + 0.25 - tc(1.0)) < 1e-9, 'anchor is not on the fade end');
}

// 3d. Caption text is escaped: '&', '<' and '-->' would otherwise be read as markup or timing.
{
  const out = vtt([{ start: 0, end: 1, text: 'Fares & <b>tax</b> --> more' }]);
  assert.ok(out.includes('Fares &amp; &lt;b&gt;tax&lt;/b&gt; --&gt; more'), out);
  assert.equal(out.split('-->').length, 2, 'a cue text --> reads as a second timing line');
}

// 3e. The beat grid is fitted to the bed's onsets, not taken from the detector: a detector that is
//     1.4% fast (as hyperframes beats was on a 100 BPM tick bed) still yields the true period and
//     phase, and onsets with no beat in them are refused (contrast under 2.5).
{
  const hop = 0.005, n = 60 / hop;
  const ticks = new Float32Array(n), noise = new Float32Array(n);
  let q = 7; const rnd = () => ((q = (q * 48271) % 2147483647) / 2147483647);
  for (let k = 0; k < n; k++) { noise[k] = 3 * rnd(); ticks[k] = 0.3 * rnd(); }
  for (let t = 0.1; t < 60; t += 0.6) ticks[Math.round(t / hop)] += 20;
  const fast = Array.from({ length: 100 }, (_, k) => 0.2 + k * 0.6 / 1.014);
  const g = fitGrid(ticks, fast);
  assert.ok(Math.abs(g.period - 0.6) < 0.0002 && Math.abs(g.phase - 0.1) < 0.006 && g.contrast > 2.5, `grid ${JSON.stringify(g)}`);
  assert.ok(fitGrid(noise, fast).contrast < 2.5, 'a beatless bed passed as a beat');
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

// 6. Deepgram: its own default voice, no speed, an unknown engine refused, and without
//    DEEPGRAM_API_KEY a run stops before any request, naming the variable.
const dgC = (narration) => ({ audio: { narration }, configDir: '.', format: 'landscape' });
assert.equal(audioSettings(dgC({ tts: 'deepgram' })).narration.voice, 'aura-2-thalia-en');
assert.equal(audioSettings(dgC({})).narration.voice, 'af_heart');
assert.throws(() => audioSettings(dgC({ tts: 'deepgram', speed: 1.2 })), /speed/);
assert.throws(() => audioSettings(dgC({ tts: 'elevenlabs' })), /hyperframes" or "deepgram/);
const out = mkdtempSync(join(tmpdir(), 'audio-check-')), key = process.env.DEEPGRAM_API_KEY, realFetch = globalThis.fetch;
delete process.env.DEEPGRAM_API_KEY;
globalThis.fetch = () => { throw new Error('a request was made'); };
await assert.rejects(narrationClips({ ...dgC({ tts: 'deepgram' }), out, cards: {}, chapters: [{ name: 'c', narration: { marks: ['Hello there.'] } }] }), /DEEPGRAM_API_KEY/);
globalThis.fetch = realFetch; rmSync(out, { recursive: true, force: true });
assert.throws(() => audioSettings(dgC({ tts: 'deepgram', voice: 'af_heart' })), /not a Deepgram Aura voice/);

// 7. Deepgram over a scripted network (no request leaves the machine): a 200 that is not a WAV is
//    never cached; a dropped connection, a 429 with Retry-After and a listen 503 are retried; an
//    anchor word the recogniser did not hear is warned about.
process.env.DEEPGRAM_API_KEY = 'test-key'; process.env.DEMO_DG_BACKOFF_MS = '1';
const wav = (() => {                                       // 0.6s of a 220Hz tone, 48kHz 16-bit mono
  const n = 28800, b = Buffer.alloc(44 + 2 * n);
  b.write('RIFF', 0); b.writeUInt32LE(36 + 2 * n, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(48000, 24); b.writeUInt32LE(96000, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(2 * n, 40);
  for (let i = 0; i < n; i++) b.writeInt16LE(Math.round(8000 * Math.sin(2 * Math.PI * 220 * i / 48000)), 44 + 2 * i);
  return b;
})();
const heardAll = [['only', 0.05], ['six', 0.2], ['cars', 0.32], ['left', 0.45]].map(([word, start]) => ({ word, start, end: start + 0.1 }));
const reply = (status, body, type, headers = {}) => new Response(body, { status, headers: { 'content-type': type, ...headers } });
const net = async (script) => {
  const calls = [], dir = mkdtempSync(join(tmpdir(), 'audio-check-')), warns = [], warn = console.warn;
  globalThis.fetch = async (url) => { calls.push(String(url).includes('/listen') ? 'listen' : 'speak'); const f = script.shift(); return f(); };
  console.warn = (m) => warns.push(String(m));
  try {
    const r = await narrationClips({ ...dgC({ tts: 'deepgram' }), out: dir, ffmpeg: 'ffmpeg', ffprobe: 'ffprobe', cards: {}, chapters: [{ name: 'c', narration: { marks: ['Only six {@cars}cars left.'] } }] });
    return { r, calls, warns, cached: readdirSync(`${dir}/work/audio/tts`) };
  } catch (e) { return { e, calls, warns, cached: readdirSync(`${dir}/work/audio/tts`) }; }
  finally { console.warn = warn; globalThis.fetch = realFetch; rmSync(dir, { recursive: true, force: true }); }
};
const html = () => reply(200, '<html>maintenance</html>', 'text/html');
let run = await net([html, html, html, html]);
assert.match(String(run.e), /not a WAV \(text\/html.*gave up after 4/, 'a 200 HTML body must be refused, not cached');
assert.ok(!run.cached.some((f) => f.endsWith('.wav')), `an HTML body was cached: ${run.cached}`);
run = await net([() => { throw new TypeError('fetch failed', { cause: { code: 'ECONNRESET' } }); }, () => reply(429, 'slow down', 'text/plain', { 'retry-after': '0' }),
  () => reply(200, wav, 'audio/wav'), () => reply(503, 'busy', 'text/plain'), () => reply(200, JSON.stringify({ results: { channels: [{ alternatives: [{ words: heardAll }] }] } }), 'application/json')]);
assert.ok(!run.e, `retries should have carried it: ${run.e}`);
assert.deepEqual(run.calls, ['speak', 'speak', 'speak', 'listen', 'listen']);
assert.equal(run.r.c.marks[0].anchor, 0.32);
assert.ok(!run.warns.some((w) => /did not hear/.test(w)), 'a heard anchor must not be warned about');
run = await net([() => reply(200, wav, 'audio/wav'), () => reply(200, JSON.stringify({ results: { channels: [{ alternatives: [{ words: [] }] }] } }), 'application/json')]);
assert.ok(run.warns.some((w) => /did not hear the anchor word "cars"/.test(w)), `an unheard anchor must be warned about: ${run.warns}`);
if (key) process.env.DEEPGRAM_API_KEY = key; else delete process.env.DEEPGRAM_API_KEY;

// 8. Beat-paced clips laid back to back in whole frames: under HyperFrames' rule (shown while
//    start <= t < start + duration, added in floating point) exactly one clip is on every frame
//    around every cut, over 2000 random timelines at 30 and 60fps.
{
  let seed2 = 11, bad = 0, cuts = 0; const r2 = () => ((seed2 = (seed2 * 16807) % 2147483647) / 2147483647);
  for (let n = 0; n < 2000; n++) {
    const fps = r2() < 0.5 ? 30 : 60, spans = [];
    let f = Math.round(2.5 * fps);
    for (let k = 0; k < 6; k++) { const d = Math.ceil((1.5 + r2() * 4 + 0.6) * fps - 1e-6); spans.push([f, f + d]); f += d; }
    const A = clipSpans(spans, fps).map((a) => ({ s: +a.start, d: +a.duration }));
    for (let k = 1; k < spans.length; k++) {
      cuts++;
      for (const fr of [spans[k][0] - 1, spans[k][0]]) if (A.filter((a) => fr / fps >= a.s && fr / fps < a.s + a.d).length !== 1) { bad++; break; }
    }
  }
  assert.equal(bad, 0, `${bad} of ${cuts} cuts have a frame with no clip or two`);
}
// 9. Silence measures -inf, which compares (a silent clip passes the ceiling), not NaN.
{
  const d = mkdtempSync(join(tmpdir(), 'audio-check-')), f = join(d, 'silent.wav');
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-t', '2', f]);
  const L = loudness({ ffmpeg: process.env.FFMPEG || 'ffmpeg' }, f);
  assert.ok(L.TP === -Infinity && L.TP <= -1, `silence read ${JSON.stringify(L)}`);
  rmSync(d, { recursive: true, force: true });
}

// 10. A beat from another take: { take, mark } and { take, index } resolve in that take, the rest in
//     the chapter's own, a split may pair beats from both, and a miss names the take it looked in.
{
  // one spot list per take, as compose's analysis cache gives it
  const takes = {}, spotsOf = (n) => takes[n] ??= ({ athlete: ['5.1', '5.2', '5.5'], coach: ['5.4'], plain: [null, null] }[n] || []).map((id, i) => ({ i, m: { id, t: i }, label: `${n} ${i}` }));
  const cfg = { name: 'athlete', beats: [{ mark: '5.1' }, { mark: '5.2' }, { take: 'coach', mark: '5.4' }, { mark: '5.5' }, { take: 'plain', index: 1 }, { split: ['5.5', '5.4'] }] };
  const items = resolveBeats(cfg, spotsOf);
  assert.deepEqual(items.map((b) => [b.id, b.src, b.spot?.label]), [['5.1', 'athlete', 'athlete 0'], ['5.2', 'athlete', 'athlete 1'], ['5.4', 'coach', 'coach 0'],
    ['5.5', 'athlete', 'athlete 2'], ['plain:1', 'plain', 'plain 1'], ['b5', undefined, undefined]]);
  assert.deepEqual(items[5].parts.map((p) => p.src), ['athlete', 'coach']);
  items[2].spot.label = 'relabelled';
  assert.equal(resolveBeats({ name: 'coach' }, spotsOf)[0].spot.label, 'coach 0', "a label set on a borrowed beat must not reach that take's own chapter");
  assert.throws(() => resolveBeats({ name: 'athlete', beats: [{ take: 'coach', mark: '5.2' }] }, spotsOf), /no mark "5.2" in take coach \(marks 0-0 by index, ids 5.4\)/);
  // ids are unique per take, so a borrowed one can match this take's own: refused, not resolved by order
  assert.throws(() => resolveBeats({ name: 'coach', beats: [{ mark: '5.4' }, { take: 'athlete', mark: '5.2' }, { take: 'other', index: 0 }] },
    (n) => (n === 'other' ? [{ i: 0, m: { id: '5.4' } }] : spotsOf(n))), /two beats have id 5.4; give one its own "id"/);
}

console.log(`audio-check OK: anchors on spotlights, ${freezes.length} freezes in whole frames, located tail at ${got.at}s (truth ${truth.toFixed(3)}, r ${got.r.toFixed(3)})`);

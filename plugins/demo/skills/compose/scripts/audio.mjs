#!/usr/bin/env node
// audio.mjs <config.json>
// The sound layer of the finished cut: UI sound effects timed from the capture's own events,
// an optional music bed ducked under narration, optional narration, a loudness-mastered mix
// muxed into out/<name>.mp4, and the caption files (captions.mjs). concat.sh runs it last.
//
// compose.mjs also imports two things from here, because they have to be settled before the
// picture is timed: the narration clips (a beat holds until its line finishes, and the spotlight
// lights on the line's anchor word) and the music's beat grid (cuts land on beats).
//
// Everything is mixed in memory at 48kHz and mastered by ffmpeg. The sound effects are
// synthesised here rather than shipped as files: no asset to licence, and the same on every
// ffmpeg build.
import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync, copyFileSync, renameSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, isAbsolute, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig, segmentNames, r3 } from './config.mjs';
import { writeCaptions, burnCaptions } from './captions.mjs';

const SR = 48000;
const HF = ['--yes', 'hyperframes@0.8.40'];
const dB = (x) => 10 ** (x / 20);

// Defaults for the `audio` block. `audio: false` turns the sound layer off (captions still get written).
export function audioSettings(C) {
  if (C.audio === false) return null;
  const a = C.audio || {}, abs = (p) => (isAbsolute(p) ? p : resolve(C.configDir, p));
  const music = a.music?.file ? { level: -18, duck: 11, fadeIn: 1.5, fadeOut: 2.5, start: 0, snap: true, ...a.music, file: abs(a.music.file) } : null;
  if (music && !existsSync(music.file)) throw new Error(`audio.music.file not found: ${music.file}`);
  if (music && !(music.duck >= 0 && music.duck <= 30)) throw new Error('audio.music.duck must be between 0 and 30 dB');
  return {
    sfx: a.sfx === false ? null : { level: 0, click: true, type: true, zoom: true, mark: true, ...(a.sfx || {}) },
    music,
    narration: narrationSettings(a.narration || {}),
    loudness: { target: -14, truePeak: -1, tolerance: 1, ...(a.loudness || {}) },
    // vertical burns its captions into the picture by default (compose.mjs); burn: false turns it off
    captions: { burn: C.format === 'vertical', maxWords: 7, ...(a.captions || {}) },
  };
}

// `tts`: "hyperframes" (default, local) or "deepgram" (Aura-2 over HTTPS, the key from
// DEEPGRAM_API_KEY, never from a config file). Each voice's own default differs.
const TTS = { hyperframes: { voice: 'af_heart' }, deepgram: { voice: 'aura-2-thalia-en' } };
function narrationSettings(n) {
  const tts = n.tts ?? 'hyperframes';
  if (!TTS[tts]) throw new Error(`audio.narration.tts must be "hyperframes" or "deepgram", not "${tts}"`);
  const N = { tts, speed: 1, model: 'medium.en', lead: 0.3, gap: 0.35, tail: 0.35, level: -16, ...TTS[tts], ...n };
  // ponytail: Aura-2 speaks at its own pace; refuse a speed rather than resample the voice
  if (tts === 'deepgram' && N.speed !== 1) throw new Error('audio.narration.speed is not supported with tts "deepgram" (leave it at 1)');
  if (tts === 'deepgram' && !/^aura-/.test(N.voice)) throw new Error(`audio.narration.voice "${N.voice}" is not a Deepgram Aura voice (e.g. aura-2-thalia-en)`);
  return N;
}

// ---------- narration ----------
// `{@name}` in a line marks the word the spotlight lights on: the word right after it.
// Without one, the spotlight lights on the first word.
export function parseLine(text) {
  const words = [];
  let anchor = 0;
  for (const tok of String(text).trim().split(/\s+/)) {
    const m = tok.match(/^\{@[^}]*\}(.*)$/);
    if (m) { anchor = words.length; if (m[1]) words.push(m[1]); } else if (tok) words.push(tok);
  }
  return { words, anchor: Math.min(anchor, Math.max(0, words.length - 1)), text: words.join(' ') };
}

// Timing for every script word, from the recogniser's words. The script's own spelling is kept
// (captions should read as written); times come from the longest common run of matching words,
// and an unmatched word gets its share of the gap between its matched neighbours by length.
export function align(script, heard, dur) {
  const n = (w) => w.toLowerCase().replace(/[^a-z0-9]/g, '');
  const a = script.map(n), b = heard.map((w) => n(w.text));
  const L = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i--) for (let j = b.length - 1; j >= 0; j--)
    L[i][j] = a[i] && a[i] === b[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
  const at = new Array(a.length).fill(null);
  for (let i = 0, j = 0; i < a.length && j < b.length;) {
    if (a[i] && a[i] === b[j]) { at[i] = heard[j]; i++; j++; } else if (L[i + 1][j] >= L[i][j + 1]) i++; else j++;
  }
  // `heard`: the recogniser heard this word; the rest are interpolated
  const out = script.map((text, i) => ({ text, start: at[i]?.start, end: at[i]?.end, ...(at[i] && { heard: true }) }));
  for (let i = 0; i < out.length;) {
    if (out[i].start != null) { i++; continue; }
    let k = i; while (k < out.length && out[k].start == null) k++;
    const t0 = i ? out[i - 1].end : 0, t1 = k < out.length ? out[k].start : dur;
    const len = out.slice(i, k).reduce((s, w) => s + w.text.length + 1, 0);
    let t = t0;
    for (let q = i; q < k; q++) { const d = (t1 - t0) * (out[q].text.length + 1) / len; out[q].start = r3(t); out[q].end = r3(t + d); t += d; }
    i = k;
  }
  return out;
}

const probe = (C, f) => +execFileSync(C.ffprobe, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f]).toString().trim();

function hf(args, cwd) {
  const r = spawnSync('npx', [...HF, ...args], { cwd, encoding: 'utf8', maxBuffer: 1 << 26 });
  // --json prints one object, pretty or on one line, possibly after progress lines
  const out = (r.stdout || '').trim(), parse = (x) => { try { return JSON.parse(x); } catch { return null; } };
  const j = parse(out) ?? parse(out.slice(out.lastIndexOf('\n{') + 1)) ?? out.split('\n').reverse().map(parse).find(Boolean);
  if (r.status !== 0 || !j?.ok) throw new Error(`hyperframes ${args[0]} failed: ${j?.error || (r.stderr || r.stdout || '').slice(-600)}`);
  return j;
}

// One Deepgram request: up to 4 attempts, 60s each, on a network failure, a 429 or 5xx, or a
// response `accept` refuses (a 200 that is not what was asked for); the wait honours Retry-After
// (capped at 30s), else 1, 2, 4s. `accept(response)` returns the result or throws.
const backoff = () => +(process.env.DEMO_DG_BACKOFF_MS ?? 1000);   // the self-check shortens it
async function dg(what, url, init, accept) {
  for (let attempt = 1; ; attempt++) {
    let why, wait = backoff() * 2 ** (attempt - 1);
    try {
      const r = await fetch(url, { ...init, headers: { Authorization: `Token ${process.env.DEEPGRAM_API_KEY}`, ...init.headers }, signal: AbortSignal.timeout(60e3) });
      if (r.ok) {
        try { return await accept(r); } catch (e) { why = `${what}: ${e.message}`; }
      } else {
        why = `${what} ${r.status}: ${(await r.text()).slice(0, 300)}`;
        if (r.status !== 429 && r.status < 500) throw new Error(why);
        const ra = r.headers.get('retry-after');
        if (ra != null) wait = Math.min(30e3, Number.isFinite(+ra) ? +ra * 1000 : Math.max(0, Date.parse(ra) - Date.now()));
      }
    } catch (e) {
      if (why && e.message === why) throw e;              // a refusal that retrying will not change
      why = `${what}: ${e.name === 'TimeoutError' ? 'no answer in 60s' : e.cause?.code || e.message}`;
    }
    if (attempt === 4) throw new Error(`${why} (gave up after 4 attempts)`);
    console.warn(`  warn: ${why}; retrying`);
    await new Promise((res) => setTimeout(res, wait));
  }
}
// Speak `text` into `out` (a wav). HyperFrames runs locally; Deepgram is one request per clip,
// 48kHz 16-bit mono WAV, written to the cache only once it is one: a 200 carrying anything else
// (an HTML error page, an empty or cut-off body) would otherwise be cached as the line for good.
async function speak(N, text, out, dir) {
  if (N.tts === 'hyperframes') {
    writeFileSync(`${out}.txt`, text);
    hf(['tts', '--text-file', `${out}.txt`, '-o', out, '-v', N.voice, '-s', String(N.speed), '--json'], dir);
    return;
  }
  const url = `https://api.deepgram.com/v1/speak?model=${encodeURIComponent(N.voice)}&encoding=linear16&sample_rate=${SR}&container=wav`;
  const buf = await dg(`Deepgram speak (voice ${N.voice})`, url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ text }) }, async (r) => {
    const type = r.headers.get('content-type') || '', b = Buffer.from(await r.arrayBuffer());
    if (!type.startsWith('audio/') || b.length <= 44 || b.toString('ascii', 0, 4) !== 'RIFF' || b.toString('ascii', 8, 12) !== 'WAVE')
      throw new Error(`not a WAV (${type || 'no content-type'}, ${b.length} bytes)`);
    return b;
  });
  writeFileSync(`${out}.part`, buf); renameSync(`${out}.part`, out);
}
// Word times for a Deepgram clip from Deepgram's own recogniser (nova-3, in the voice's language),
// as { text, start, end }. No smart_format: lines written for a voice spell numbers out ("two
// twenty"), and smart_format would hear them back as digits ("2:20").
async function listen(file, voice) {
  const lang = voice.split('-').at(-1);
  return dg(`Deepgram listen (${basename(file)})`, `https://api.deepgram.com/v1/listen?model=nova-3&language=${encodeURIComponent(lang)}`,
    { method: 'POST', headers: { 'Content-Type': 'audio/wav' }, body: readFileSync(file) }, async (r) => {
      const j = await r.json(), words = j?.results?.channels?.[0]?.alternatives?.[0]?.words;
      if (!Array.isArray(words)) throw new Error(`no word list in the answer: ${JSON.stringify(j).slice(0, 200)}`);
      return words.map((w) => ({ text: w.word, start: w.start, end: w.end }));
    });
}
// The file a line is spoken into. HyperFrames keys keep their old recipe (text, voice, speed and
// the recogniser model), so existing caches stay valid; a Deepgram clip is keyed by what it is
// made of only (text, voice, rate), sha256, so changing the recogniser never re-bills a line.
const clipKey = (N, text) => N.tts === 'hyperframes'
  ? createHash('sha1').update(JSON.stringify([text, N.voice, N.speed, N.model])).digest('hex').slice(0, 16)
  : `dg-${createHash('sha256').update(JSON.stringify(['deepgram', text, N.voice, SR])).digest('hex').slice(0, 24)}`;

// One clip per narrated line and its word times, both cached: `hyperframes tts` and `hyperframes
// transcribe` (medium.en by default: on a word with a known start small.en was 0.5s early and
// medium.en within 5ms), or Deepgram speak and listen. `only`: the segments whose lines are
// needed (all when unset).
export async function narrationClips(C, only = null) {
  const A = audioSettings(C);
  if (!A) return {};
  const N = A.narration, lines = [];
  for (const [id, c] of Object.entries(C.cards)) if (c.narration) lines.push({ seg: id, slot: 'card', ...parseLine(c.narration) });
  for (const ch of C.chapters) {
    if (!ch.narration) continue;
    if (typeof ch.narration !== 'object') throw new Error(`${ch.name}: narration must be { "intro": "...", "marks": ["...", ...] }`);
    if (ch.narration.intro) lines.push({ seg: ch.name, slot: 'intro', ...parseLine(ch.narration.intro) });
    (ch.narration.marks || []).forEach((t, i) => t && lines.push({ seg: ch.name, slot: i, ...parseLine(t) }));
  }
  if (only) lines.splice(0, lines.length, ...lines.filter((l) => only.includes(l.seg)));
  if (!lines.length) return {};
  const dir = `${C.out}/work/audio/tts`;
  mkdirSync(dir, { recursive: true });
  for (const l of lines) { l.key = clipKey(N, l.text); l.file = `${dir}/${l.key}.wav`; }
  // before anything is spoken: a line not in the cache needs the key
  if (N.tts === 'deepgram' && !process.env.DEEPGRAM_API_KEY && lines.some((l) => !existsSync(l.file) || !existsSync(`${dir}/${l.key}.words.json`)))
    throw new Error('audio.narration.tts "deepgram" needs the DEEPGRAM_API_KEY environment variable (it is never read from the config)');
  for (const l of lines) if (!existsSync(l.file)) await speak(N, l.text, l.file, dir);
  for (const l of lines) {
    const words = `${dir}/${l.key}.words.json`;
    if (existsSync(words)) continue;
    if (N.tts === 'deepgram') { writeFileSync(words, JSON.stringify(await listen(l.file, N.voice))); continue; }
    // One clip per run: transcribing several clips laid end to end put words 0.3s out.
    const job = `${dir}/${l.key}`;
    mkdirSync(job, { recursive: true });
    const r = hf(['transcribe', l.file, '--json', '-m', N.model, '-d', job], job);
    copyFileSync(r.transcriptPath || `${job}/transcript.json`, words);
    rmSync(job, { recursive: true, force: true });
  }
  const out = {};
  for (const l of lines) {
    const dur = probe(C, l.file);
    const words = align(l.words, JSON.parse(readFileSync(`${dir}/${l.key}.words.json`, 'utf8')), dur);
    (out[l.seg] ??= { marks: [] });
    const clip = { file: l.file, dur: r3(dur), words, anchor: await anchorTime(C, l, words, dir), text: l.text };
    if (typeof l.slot === 'number') out[l.seg].marks[l.slot] = clip; else out[l.seg][l.slot] = clip;
  }
  return out;
}

// When the anchor word starts in the line, to about a frame. The recogniser's word starts are not
// good enough: against stop-consonant bursts in 13 test lines they were off by -121ms to +183ms
// (worst where no pause comes before the word). So the words from the anchor on are spoken again
// on their own, and that clip's opening 0.15s is slid along the line near the recogniser's guess
// until the three-band loudness envelopes correlate best. Measured on the same 13 lines: -8ms to
// +24ms from the burst, correlation 0.93 or more. (A 0.35s template missed one line by 33ms at
// r 0.69: the words after the anchor are spoken differently on their own.) The first word needs
// none of this: it starts where the sound does.
const HOP = 0.005;
function envelope(x) {
  const a = (f) => 1 - Math.exp(-2 * Math.PI * f / SR), hop = HOP * SR, n = Math.floor(x.length / hop);
  return [[0, 500], [500, 2500], [2500, 8000]].map(([lo, hi]) => {
    const y = new Float32Array(x.length);
    for (let i = 0, l1 = 0, l2 = 0; i < x.length; i++) { l1 += a(hi) * (x[i] - l1); if (lo) l2 += a(lo) * (x[i] - l2); y[i] = l1 - l2; }
    return Float32Array.from({ length: n }, (_, k) => {
      let e = 0; for (let i = k * hop; i < Math.min(y.length, k * hop + 4 * hop); i++) e += y[i] * y[i];
      return 10 * Math.log10(e / (4 * hop) + 1e-10);
    });
  });
}
export const onsetOf = (x) => { let pk = 0; for (const v of x) pk = Math.max(pk, Math.abs(v)); return Math.max(0, x.findIndex((v) => Math.abs(v) > pk / 100)) / SR; };
// Where `tail` (mono, SR) starts inside `full`, searched from 0.3s before `guess` to 0.5s after.
export function locateAnchor(full, tail, guess) {
  const F = envelope(full), S = envelope(tail);
  const k0 = Math.round(onsetOf(tail) / HOP), K = Math.round(0.15 / HOP);
  let best = { r: -2, at: guess };
  for (let o = Math.max(0, Math.round((guess - 0.3) / HOP)); o <= Math.round((guess + 0.5) / HOP); o++) {
    let sxy = 0, sx = 0, sy = 0, sxx = 0, syy = 0, n = 0;
    for (let b = 0; b < 3; b++) for (let k = 0; k < K; k++) {
      const x = S[b][k0 + k], y = F[b][o + k];
      if (x === undefined || y === undefined) continue;
      sxy += x * y; sx += x; sy += y; sxx += x * x; syy += y * y; n++;
    }
    const r = (sxy - sx * sy / n) / Math.sqrt((sxx - sx * sx / n) * (syy - sy * sy / n));
    if (r > best.r) best = { r, at: o * HOP };
  }
  return best;
}
async function anchorTime(C, l, words, dir) {
  // Deepgram: its recogniser's own word start. The tail match below needs the tail spoken the way
  // the line spoke it, and Aura-2 does not: on 14 anchors it matched below r 0.8 on 3 and locked
  // onto the wrong word on 3 (up to 390ms out), where listen's starts sat on the word's audible
  // onset within about 20ms on 13 (SKILL.md). A word it did not hear has only an interpolated
  // time, which the spotlight would light on: said, never silent.
  if (l.anchor && audioSettings(C).narration.tts === 'deepgram') {
    if (!words[l.anchor].heard) console.warn(`  warn: "${l.text}": the recogniser did not hear the anchor word "${words[l.anchor].text}"; its time (${words[l.anchor].start}s) is interpolated, so the spotlight may light off it. Reword the line or move the anchor`);
    return r3(words[l.anchor].start);
  }
  const full = decode(C, ['-i', l.file], 1);
  if (!l.anchor) return r3(onsetOf(full));
  // The spoken line (l.key) does not change when the anchor moves to another word; its timing does.
  const k = `${dir}/${l.key}.a${l.anchor}`, cache = `${k}.json`;
  if (existsSync(cache)) return JSON.parse(readFileSync(cache, 'utf8')).at;
  const N = audioSettings(C).narration, tail = `${k}.tail.wav`;
  if (!existsSync(tail)) await speak(N, l.words.slice(l.anchor).join(' '), tail, dir);
  const guess = words[l.anchor].start, best = locateAnchor(full, decode(C, ['-i', tail], 1), guess);
  // ponytail: a weak match keeps the recogniser's guess and says so; 0.8 sits well under the 13 measured (0.93 to 0.99)
  const res = best.r >= 0.8 ? { at: r3(best.at), r: r3(best.r), heard: guess } : { at: guess, r: r3(best.r), heard: guess, fallback: true };
  if (res.fallback) console.warn(`  warn: "${l.text}": anchor match weak (r ${res.r}), using the recogniser's time`);
  writeFileSync(cache, JSON.stringify(res));
  return res.at;
}


// Fit one chapter's narration to its picture. `timeline(freezes)` re-times the chapter with
// those freezes ({ t: source seconds, d: output seconds }) and returns source t -> composition t.
// A spot is { T, hold, from, fade }: its spotlight fades in from source time `from` over `fade`
// output seconds, so it is fully lit at the later of T and that fade's end. Each mark's line is
// placed so its anchor word starts as the spotlight is fully lit. Where a line would start before
// the previous one has finished, or would outlast its own hold, the footage freezes on a still
// frame for whole frames until it fits: at the end of the previous hold (the previous spotlight
// stays up), or, for the first mark, where its spotlight starts to fade in (the pose it lights on),
// so the fade, the bell and the anchor word all come after the freeze, never before it.
export function fitNarration(spots, clips, timeline, N, fps = 30) {
  const fz = [], placed = [];
  const frames = (d) => Math.ceil(d * fps - 1e-6) / fps;
  const lit = (toComp, s) => Math.max(toComp(s.T), s.from == null ? -Infinity : toComp(s.from) + s.fade);
  let prevEnd = 0;
  if (clips.intro) { placed.push({ slot: 'intro', at: N.lead, ...clips.intro }); prevEnd = N.lead + clips.intro.dur; }
  for (const [i, s] of spots.entries()) {
    const c = clips.marks?.[i];
    if (!c) continue;
    let toComp = timeline(fz), start = lit(toComp, s) - c.anchor;
    const need = prevEnd + N.gap - start;
    if (need > 0) {
      fz.push({ t: i ? spots[i - 1].T + spots[i - 1].hold : s.from ?? s.T, d: frames(need) });
      toComp = timeline(fz); start = lit(toComp, s) - c.anchor;
    }
    const over = start + c.dur + N.tail - toComp(s.T + s.hold);
    if (over > 0) fz.push({ t: s.T + s.hold, d: frames(over) });
    placed.push({ slot: i, at: start, lit: lit(toComp, s), ...c });
    prevEnd = start + c.dur;
  }
  return { freezes: fz, placed };
}

// ---------- music beats ----------
// The bed's beat grid in VIDEO seconds, or null when there is no bed, `snap` is off, or the bed has
// no beat steady enough to cut on (said once, and the cuts are simply not snapped).
// `hyperframes beats` gives the tempo; the grid itself is then fitted to the bed's own onsets, a
// steady period and phase, because the detector's beats can drift: on a 100 BPM tick bed it
// reported 101.4 BPM, which walked its beats 0.8s off the ticks over a minute. Fitted on four beds
// (100 BPM ticks, 100 BPM pad and kick, 128 BPM four-on-the-floor kick, a drone with no beat):
// every tempo exact to 0.01 BPM, phase within 15ms of the measured onsets, and the drone refused.
const ONSET_HOP = 0.005, MIN_CONTRAST = 2.5;
export function beatGrid(C) {
  const A = audioSettings(C);
  if (!A?.music || !A.music.snap) return null;
  const dir = `${C.out}/work/audio/beats`, name = basename(A.music.file);
  const json = `${dir}/beats/${name}.json`, fitted = `${dir}/grid.json`;
  // The grid is cached by the bed's content, not its name or mtime: a bed replaced under the same
  // name with an older mtime (cp -p, a checkout, an unzip) kept the old bed's grid and put cuts
  // 200ms off the new beat (measured, 100 then 120 BPM). sha256 costs 20ms for a 17 MB bed and
  // 135ms for 120 MB.
  const key = createHash('sha256').update(readFileSync(A.music.file)).digest('hex');
  const cached = existsSync(fitted) ? JSON.parse(readFileSync(fitted, 'utf8')) : null;
  if (cached?.key !== key) {
    rmSync(dir, { recursive: true, force: true }); mkdirSync(dir, { recursive: true });
    copyFileSync(A.music.file, `${dir}/${name}`);
    writeFileSync(`${dir}/index.html`, `<!doctype html><html><head><meta charset="UTF-8"></head><body>
<div id="root" data-composition-id="beats" data-start="0" data-duration="1" data-width="320" data-height="180">
<audio id="music" data-timeline-role="music" src="${name}" data-start="0" data-duration="1"></audio>
</div><script>window.__timelines = {};</script></body></html>\n`);
    let grid;
    try {
      hf(['beats', dir, '--json'], dir);
      const beats = JSON.parse(readFileSync(json, 'utf8')).beats.map((b) => b.time);
      grid = fitGrid(onsetEnvelope(decode(C, ['-i', A.music.file], 1)), beats);
    } catch (e) { grid = { error: String(e.message).split('\n')[0] }; }
    writeFileSync(fitted, JSON.stringify({ ...grid, key }));
  }
  const g = JSON.parse(readFileSync(fitted, 'utf8'));
  if (g.error || !(g.contrast >= MIN_CONTRAST)) {
    console.warn(`warn: ${basename(A.music.file)}: no steady beat to cut on (${g.error || `contrast ${r3(g.contrast)}, needs ${MIN_CONTRAST}`}); cuts are not snapped`);
    return null;
  }
  // The bed loops from its own start (mix), so pass q's beats sit at q * len + phase + j * period,
  // for any length of video.
  const len = probe(C, A.music.file), off = A.music.start;
  const near = (t) => {
    const out = [], q0 = Math.floor((t + off) / len);
    for (let q = q0 - 1; q <= q0 + 1; q++) {
      const j0 = Math.floor((t + off - q * len - g.phase) / g.period);
      for (let j = Math.max(0, j0 - 1); j <= j0 + 2; j++) {
        const b = g.phase + j * g.period;
        if (b < len) out.push(q * len + b - off);
      }
    }
    return out.filter((v) => v > 0);
  };
  return {
    bpm: r3(60 / g.period),
    after: (t) => Math.min(...near(t).filter((v) => v >= t)),
    nearest: (t) => near(t).reduce((a, v) => (Math.abs(v - t) < Math.abs(a - t) ? v : a), Infinity),
  };
}
// Onset strength: the rise in log energy from one 5ms hop to the next.
export function onsetEnvelope(x) {
  const h = Math.round(ONSET_HOP * SR), n = Math.floor(x.length / h), e = new Float32Array(n), o = new Float32Array(n);
  for (let k = 0; k < n; k++) { let s = 0; for (let i = k * h; i < (k + 1) * h; i++) s += x[i] * x[i]; e[k] = 10 * Math.log10(s / h + 1e-10); }
  for (let k = 1; k < n; k++) o[k] = Math.max(0, e[k] - e[k - 1]);
  return o;
}
// The steady grid (period within 4% of the detector's median beat gap, any phase) that sits on the
// most onset strength, coarse then fine; `contrast` is that grid's strength over the same grid at
// the median other phase, near 1 when there is no beat to find.
export function fitGrid(o, beats) {
  if (beats.length < 4) throw new Error('fewer than 4 beats detected');
  const gaps = beats.slice(1).map((b, i) => b - beats[i]).sort((a, b) => a - b), p0 = gaps[gaps.length >> 1], dur = o.length * ONSET_HOP;
  const at = (t) => { const x = t / ONSET_HOP, k = Math.floor(x), f = x - k; return (o[k] ?? 0) * (1 - f) + (o[k + 1] ?? 0) * f; };
  const score = (p, ph) => { let s = 0, m = 0; for (let t = ph; t < dur; t += p) { s += at(t); m++; } return s / m; };
  const search = (pa, pb, ps, fs) => {
    let best = { s: -1 };
    for (let p = pa; p <= pb; p += ps) for (let ph = 0; ph < p; ph += fs) { const s = score(p, ph); if (s > best.s) best = { s, p, ph }; }
    return best;
  };
  let b = search(p0 * 0.96, p0 * 1.04, 0.0005, ONSET_HOP);
  b = search(b.p - 0.0006, b.p + 0.0006, 0.00002, 0.001);
  const others = [];
  for (let ph = 0; ph < b.p; ph += ONSET_HOP) if (Math.abs(ph - b.ph) > 0.05 && Math.abs(ph - b.ph) < b.p - 0.05) others.push(score(b.p, ph));
  others.sort((x, y) => x - y);
  return { period: b.p, phase: b.ph, detected: r3(60 / p0), contrast: r3(Math.min(1e6, b.s / (others[others.length >> 1] || 1e-9))) };
}

// ---------- sound effects ----------
// Small deterministic synths. Peaks are about 1 before `gain`.
function rng(seed) { return () => { seed = (seed + 0x6D2B79F5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t ^= t + Math.imul(t ^ (t >>> 7), 61 | t); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
const R = rng(7);
function add(buf, at, len, gain, f) {
  const i0 = Math.round(at * SR);
  for (let i = 0; i < len * SR && i0 + i < buf.length; i++) if (i0 + i >= 0) buf[i0 + i] += gain * f(i / SR);
}
// A soft tick: a filtered noise transient over a short tonal knock.
function tick(buf, at, gain, hz, len = 0.05) {
  let lp = 0;
  add(buf, at, len, gain, (t) => { lp += 0.35 * ((R() * 2 - 1) - lp); return 0.7 * lp * Math.exp(-t * 350) + 0.6 * Math.sin(2 * Math.PI * hz * t) * Math.exp(-t * 90); });
}
// Air moving past: noise whose brightness and level rise and fall over the move.
function whoosh(buf, at, dur, gain) {
  let lp = 0, lp2 = 0, hp = 0;
  add(buf, at, dur, gain, (t) => {
    const e = Math.sin(Math.PI * Math.min(1, t / dur)) ** 2, a = 1 - Math.exp(-2 * Math.PI * (500 + 3000 * e) / SR);
    lp += a * ((R() * 2 - 1) - lp); lp2 += a * (lp - lp2); hp += 0.02 * (lp2 - hp);   // two poles: no hiss above the sweep
    return 2.4 * e * (lp2 - hp);
  });
}
// A gentle bell: E6 with a quieter octave and fifth, 4ms attack, about a second of decay.
function ping(buf, at, gain) {
  add(buf, at, 1.1, gain, (t) => Math.min(1, t / 0.004) * (0.6 * Math.sin(2 * Math.PI * 1318.5 * t) * Math.exp(-t * 5)
    + 0.2 * Math.sin(2 * Math.PI * 2637 * t) * Math.exp(-t * 9) + 0.15 * Math.sin(2 * Math.PI * 1975.5 * t) * Math.exp(-t * 7)));
}

// Peak level of each cue in dBFS before mastering, plus audio.sfx.level.
const LEVEL = { click: -24, key: -33, whoosh: -30, ping: -28 };

// ---------- mix ----------
function decode(C, args, ch) {
  const buf = execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', ...args, '-ac', String(ch), '-ar', String(SR), '-f', 'f32le', '-'], { maxBuffer: 1 << 30 });
  return new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4);
}
function writeWav(C, path, chans) {
  const n = chans[0].length, inter = new Float32Array(n * chans.length);
  for (let i = 0; i < n; i++) for (let c = 0; c < chans.length; c++) inter[i * chans.length + c] = chans[c][i];
  execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-f', 'f32le', '-ar', String(SR), '-ac', String(chans.length), '-i', '-', '-c:a', 'pcm_f32le', path],
    { input: Buffer.from(inter.buffer) });
}
// Integrated loudness (LUFS) and true peak (dBTP) of a file's audio, by ffmpeg's EBU R128 meter.
export function loudness(C, file) {
  const s = spawnSync(C.ffmpeg, ['-nostdin', '-hide_banner', '-nostats', '-i', file, '-map', '0:a', '-af', 'ebur128=peak=true', '-f', 'null', '-'], { encoding: 'utf8', maxBuffer: 1 << 26 }).stderr;
  const sum = s.slice(s.lastIndexOf('Summary:'));
  const num = (re) => { const m = sum.match(re); return m ? +m[1] : NaN; };
  return { I: num(/I:\s+(-?[\d.]+|-inf) LUFS/), TP: num(/Peak:\s+(-?[\d.]+|-inf) dBFS/) };
}

// When a spot is fully lit: its fade-in starts at litFrom (after the camera settles) or fadeLead
// before compT, whichever is later.
export const litAt = (sp) => Math.max(sp.compT, sp.litFrom == null ? -Infinity : sp.litFrom + sp.fadeIn);

// Where each segment starts in the final video and how long it is: concat.sh writes them to
// work/timeline.json from the rendered frame counts, with every seam's overlap already taken off.
function segments(C) {
  const tl = `${C.out}/work/timeline.json`;
  if (!existsSync(tl)) throw new Error(`no ${tl}; run concat.sh, which writes it before calling audio.mjs`);
  const at = Object.fromEntries(JSON.parse(readFileSync(tl, 'utf8')).segments.map((s) => [s.name, s]));
  return segmentNames(C).map((n) => {
    const p = `${C.out}/work/${n}.plan.json`;
    if (!at[n] || !existsSync(p)) throw new Error(`${n}: not in the timeline or no plan; run compose.mjs, render.sh and concat.sh first`);
    return { name: n, start: at[n].start, dur: at[n].dur, plan: JSON.parse(readFileSync(p, 'utf8')) };
  });
}

export function mix(C) {
  const A = audioSettings(C), segs = segments(C), final = `${C.out}/out/${C.name}.mp4`;
  // The VIDEO stream's length: the file's own grows with an earlier mix's AAC padding.
  const total = +execFileSync(C.ffprobe, ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=duration', '-of', 'csv=p=0', final]).toString().trim();
  const report = { file: final, duration: r3(total) };
  const caps = writeCaptions(C, segs, A);
  Object.assign(report, caps);
  if (!A) { console.log(`audio off; captions ${caps.captions}, chapters ${caps.chapters}`); return report; }

  const n = Math.ceil(total * SR), work = `${C.out}/work/audio`;
  mkdirSync(work, { recursive: true });
  const sfx = new Float32Array(n), voice = new Float32Array(n);
  const counts = { click: 0, key: 0, whoosh: 0, ping: 0 };

  if (A.sfx) {
    const g = (k) => dB(LEVEL[k] + A.sfx.level);
    for (const s of segs) {
      for (const c of s.plan.cues || []) {
        const at = s.start + c.at;
        if (c.kind === 'click' && A.sfx.click) { tick(sfx, at, g('click'), 1700 * (0.95 + 0.1 * R())); counts.click++; }
        if (c.kind === 'type' && A.sfx.type && c.chars) {
          // one soft key every 2 or 3 characters, pitch varied +-5% so repeats do not sound looped
          for (let k = 0; k < c.chars; k += 2 + Math.floor(R() * 2)) { tick(sfx, at + c.dur * k / c.chars, g('key'), 2600 * (0.95 + 0.1 * R()), 0.03); counts.key++; }
        }
        if (c.kind === 'camera' && A.sfx.zoom) { whoosh(sfx, at, Math.max(0.25, c.dur), g('whoosh')); counts.whoosh++; }
      }
      if (A.sfx.mark) for (const sp of s.plan.spots || []) { ping(sfx, s.start + litAt(sp), g('ping')); counts.ping++; }
    }
  }

  // narration: every placed line at its composition time, then levelled as one stem
  const lines = [];
  for (const s of segs) for (const l of s.plan.narration || []) {
    lines.push({ ...l, abs: s.start + l.at, seg: s.name });
    const pcm = decode(C, ['-i', l.file], 1), i0 = Math.round((s.start + l.at) * SR);
    for (let i = 0; i < pcm.length && i0 + i < n; i++) if (i0 + i >= 0) voice[i0 + i] += pcm[i];
  }
  if (lines.length) {
    writeWav(C, `${work}/voice-raw.wav`, [voice]);
    const g = dB(A.narration.level - loudness(C, `${work}/voice-raw.wav`).I);
    for (let i = 0; i < n; i++) voice[i] *= g;
  }

  // music: looped to length, levelled, faded in and out, ducked under every line
  let mL = null, mR = null;
  if (A.music) {
    const M = A.music;
    // looped from the file's own start, so every pass begins where the beat grid says it does
    const pcm = decode(C, ['-stream_loop', '-1', '-i', M.file, '-t', String(M.start + total)], 2), o = Math.round(M.start * SR);
    mL = new Float32Array(n); mR = new Float32Array(n);
    for (let i = 0; i < n && 2 * (o + i) + 1 < pcm.length; i++) { mL[i] = pcm[2 * (o + i)]; mR[i] = pcm[2 * (o + i) + 1]; }
    writeWav(C, `${work}/music-raw.wav`, [mL, mR]);
    const lvl = dB(M.level - loudness(C, `${work}/music-raw.wav`).I);
    // duck windows: ramp down 0.25s before a line, back up over 0.6s after; close lines merge
    const ATT = 0.25, REL = 0.6, win = [];
    for (const l of lines.sort((a, b) => a.abs - b.abs)) {
      const w = [l.abs - ATT, l.abs + l.dur + REL];
      if (win.length && w[0] < win.at(-1)[1] + 0.5) win.at(-1)[1] = Math.max(win.at(-1)[1], w[1]); else win.push(w);
    }
    report.ducks = win.map((w) => w.map(r3));
    for (let i = 0, k = 0; i < n; i++) {
      const t = i / SR;
      while (k < win.length && win[k][1] < t) k++;
      let duck = 0;
      if (k < win.length && t >= win[k][0]) duck = Math.min(1, (t - win[k][0]) / ATT, (win[k][1] - t) / REL);
      const fade = Math.min(1, M.fadeIn > 0 ? t / M.fadeIn : 1, M.fadeOut > 0 ? (total - t) / M.fadeOut : 1);
      const gn = lvl * dB(-M.duck * duck) * Math.max(0, fade) ** 2;
      mL[i] *= gn; mR[i] *= gn;
    }
  }

  const L = new Float32Array(n), Rt = new Float32Array(n);
  for (let i = 0; i < n; i++) { const c = sfx[i] + voice[i]; L[i] = c + (mL ? mL[i] : 0); Rt[i] = c + (mR ? mR[i] : 0); }
  // Nothing to hear (every effect off, no narration, no music): leave the video silent, drop any
  // track an earlier mix left, and skip the loudness gate, which cannot measure silence.
  let peak = 0;
  for (let i = 0; i < n; i++) peak = Math.max(peak, Math.abs(L[i]), Math.abs(Rt[i]));
  if (!peak) {
    const tmp = `${C.out}/out/.${C.name}.audio.mp4`;
    execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-i', final, '-map', '0:v', '-c', 'copy', '-movflags', '+faststart', tmp]);
    renameSync(tmp, final);
    Object.assign(report, { silent: true, ok: true });
    writeFileSync(`${C.out}/out/${C.name}.audio.json`, JSON.stringify(report, null, 1));
    console.log(`audio: nothing to mix, video left silent; captions ${caps.captions}  chapters ${caps.chapters}`);
    return report;
  }
  writeWav(C, `${work}/mix.wav`, [L, Rt]);

  // Master. A mix with narration or music is a programme: measure its integrated loudness, apply
  // the gain that reaches the target, and catch the few peaks that gain pushes over the ceiling
  // with a limiter set 1 dB under it (sample peaks; the margin covers inter-sample peaks). A second
  // pass corrects what the limiter took off. Sound effects alone are left at their own low level:
  // normalising sparse ticks to -14 LUFS would push each one to near full scale.
  const programme = !!(lines.length || A.music);
  const T = A.loudness;
  let master = `${work}/mix.wav`;
  if (programme) {
    let g = T.target - loudness(C, master).I;
    for (let k = 0; k < 3; k++) {
      execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-i', `${work}/mix.wav`, '-af',
        `volume=${r3(g)}dB,alimiter=limit=${r3(dB(T.truePeak - 1))}:level=false:attack=1:release=60`, '-c:a', 'pcm_f32le', `${work}/master.wav`]);
      const d = T.target - loudness(C, `${work}/master.wav`).I;
      if (Math.abs(d) < 0.15) break;
      g += d;
    }
    report.gain = r3(g);
    master = `${work}/master.wav`;
  }

  // Mux: the picture is copied, never re-encoded.
  const tmp = `${C.out}/out/.${C.name}.audio.mp4`;
  execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-i', final, '-i', master, '-map', '0:v', '-map', '1:a',
    '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-shortest', '-movflags', '+faststart', tmp]);
  renameSync(tmp, final);

  // Measure what a viewer gets: the AAC in the final file, decoded.
  const got = loudness(C, final);
  report.lufs = got.I; report.truePeak = got.TP; report.programme = programme; report.sfx = counts; report.lines = lines.length;
  report.music = A.music ? basename(A.music.file) : null;
  // how far each cut sits from the nearest beat, in ms (cards are padded so it should be ~0)
  const grid = beatGrid(C);
  if (grid) report.cutsToBeats = segs.slice(1).concat({ start: total }).map((s) => Math.round(1000 * Math.abs(grid.nearest(s.start) - s.start)));
  const fails = [];
  // A cut more than a frame off the beat means a segment was rendered from a stale plan.
  if (grid && report.cutsToBeats.some((ms) => ms > 1000 / C.fps)) fails.push(`cuts off the beat by ${report.cutsToBeats.join(', ')} ms: re-run compose.mjs and render.sh`);
  if (programme && !(Math.abs(got.I - T.target) <= T.tolerance)) fails.push(`loudness ${got.I} LUFS, target ${T.target} +-${T.tolerance}`);
  if (!(got.TP <= T.truePeak)) fails.push(`true peak ${got.TP} dBTP over ${T.truePeak}`);
  report.ok = !fails.length;

  // Listen-proxy: one waveform row per stem (sfx, narration, music) and the final mix, top to bottom.
  if (A.sfx || lines.length || A.music) {
    writeWav(C, `${work}/sfx.wav`, [sfx]); writeWav(C, `${work}/voice.wav`, [voice]);
    writeWav(C, `${work}/music.wav`, [mL || new Float32Array(n)]);
    const rows = [['sfx.wav', '0x6FA8DC'], ['voice.wav', '0x93C47D'], ['music.wav', '0xF6B26B'], [null, '0xE6E6E6']];
    const ins = rows.flatMap(([f]) => ['-i', f ? `${work}/${f}` : final]);
    const fc = rows.map(([, col], i) => `[${i}:a]aformat=channel_layouts=mono,showwavespic=s=1600x110:scale=sqrt:colors=${col}[w${i}]`).join(';')
      + `;${rows.map((_, i) => `[w${i}]`).join('')}vstack=inputs=${rows.length}[st];color=c=0x15171C:s=1600x${110 * rows.length}[bg];[bg][st]overlay`;
    execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', ...ins, '-filter_complex', fc, '-frames:v', '1', '-update', '1', `${C.out}/out/${C.name}-audio.png`]);
  }

  // a vertical cut has its captions in the picture already (compose.mjs), so it is never burned twice
  if (A.captions.burn && C.format !== 'vertical') report.burned = burnCaptions(C, segs, A, final);
  writeFileSync(`${C.out}/out/${C.name}.audio.json`, JSON.stringify(report, null, 1));
  const lvl = programme ? `${got.I} LUFS (target ${T.target})` : `${got.I} LUFS (effects only, not normalised)`;
  console.log(`audio: ${lvl}, true peak ${got.TP} dBTP; clicks ${counts.click}, keys ${counts.key}, whooshes ${counts.whoosh}, pings ${counts.ping}, lines ${lines.length}${A.music ? `, music ${report.music}` : ''}`);
  console.log(`captions: ${caps.captions}  chapters: ${caps.chapters}${report.burned ? `  burned: ${report.burned}` : ''}`);
  if (fails.length) { console.error(`audio check FAILED: ${fails.join('; ')}`); return { ...report, fails }; }
  return report;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const cfgPath = process.argv[2];
  if (!cfgPath) { console.error('usage: audio.mjs <config.json>'); process.exit(2); }
  const r = mix(loadConfig(cfgPath));
  process.exit(r.fails ? 1 : 0);
}

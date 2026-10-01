#!/usr/bin/env node
// ABOUTME: demo:export. Turns a composed demo into what people actually see outside a video
// player: a README bundle (looping GIF + WebP + poster + <picture> snippet) and an interactive,
// click-through HTML walkthrough built from the same capture.
// Usage:
//   node export.mjs readme      <compose-config.json> [--width 960] [--fps 15] [--quality 90]
//                               [--from S --to S] [--budget 5] [--out DIR]
//   node export.mjs interactive <compose-config.json> [--payoff "mark label"] [--inline auto|yes|no] [--out DIR]
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { loadConfig, timeline, pickLoop, cutSpots, seamOf, onFrame, clipTo, shortLabel, steps, lint, FFMPEG, hasEncoder, which, r3 } from './lib.mjs';

const [cmd, cfgPath, ...rest] = process.argv.slice(2);
if (!['readme', 'interactive'].includes(cmd) || !cfgPath) {
  console.error('usage: export.mjs readme|interactive <compose-config.json> [options] (see SKILL.md)'); process.exit(2);
}
const opt = {};
for (let i = 0; i < rest.length; i++) {
  if (!rest[i].startsWith('--')) { console.error(`unexpected argument ${rest[i]}`); process.exit(2); }
  opt[rest[i].slice(2)] = rest[i + 1]; i++;
}
const C = loadConfig(cfgPath);
const tl = timeline(C);
const video = `${C.out}/out/${C.name}.mp4`;
const MB = (f) => r3(statSync(f).size / 1e6);
const ff = (args) => execFileSync(FFMPEG(), ['-nostdin', '-loglevel', 'error', '-y', ...args]);
const pct = (p) => p.replace(/%/g, '%%');           // ffmpeg reads an image2 path as a pattern
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

if (cmd === 'readme') readme(); else interactive();

function readme() {
  if (!existsSync(video)) throw new Error(`no final video at ${video}; run demo:compose's concat.sh first`);
  const width = +(opt.width ?? 960), fps = +(opt.fps ?? 15), budget = +(opt.budget ?? 5);
  const out = opt.out ?? `${C.out}/export/readme`;
  mkdirSync(out, { recursive: true });
  const all = tl.chapters.flatMap((c) => c.spots);
  let loop;
  if (opt.from != null || opt.to != null) {
    const a = +opt.from, b = +opt.to;
    if (!(b > a)) throw new Error('--from and --to: give both, with --to after --from');
    const cut = cutSpots([a, b], all);
    if (cut.length) throw new Error(`--from ${a} --to ${b} cuts the spotlight "${cut[0].label}" (lit ${cut[0].lit}s to ${cut[0].end}s): start before it lights or end after it fades`);
    loop = { a, b, spots: all.filter((s) => s.lit >= a && s.end <= b), title: tl.chapters.find((c) => c.a0 <= a && b <= c.a1 + 1)?.title ?? C.name };
  } else {
    loop = pickLoop(tl.chapters, { seam: seamOf(video) });
    if (!loop) throw new Error('no chapter has a spotlight to loop; pass --from and --to');
    if (loop.short) console.warn(`warn: no 8-12s stretch holds whole spotlights; the loop runs ${r3(loop.b - loop.a)}s`);
  }
  const hero = loop.spots.at(-1);
  const work = mkdtempSync(join(tmpdir(), 'demo-export-'));
  try {
    // Frames once, at the loop's size and rate; the GIF and the WebP are both made from them.
    ff(['-ss', String(loop.a), '-t', String(r3(loop.b - loop.a)), '-i', video, '-vf', `fps=${fps},scale=${width}:-2:flags=lanczos`, `${pct(work)}/f%04d.png`]);
    const frames = readdirSync(work).filter((f) => /^f\d+\.png$/.test(f)).sort().map((f) => join(work, f));
    const gif = join(out, 'demo.gif');
    let q = +(opt.quality ?? 90), w = width, tool;
    for (;;) {                                         // step quality, then width, down until the GIF fits
      tool = gifEncode(frames, work, gif, { fps, quality: q, width: w, srcWidth: width });
      if (MB(gif) <= budget || (q <= 60 && w <= 640)) break;
      if (q > 60) q -= 10; else w -= 160;
      console.warn(`  GIF over ${budget} MB; trying quality ${q}, width ${w}`);
    }
    if (MB(gif) > budget) throw new Error(`GIF is ${MB(gif)} MB, over the ${budget} MB budget even at quality ${q} and ${w}px; pass --from/--to for a shorter loop or a larger --budget`);
    // Animated WebP: ffmpeg's libwebp encoder when the build has one, else libwebp's own img2webp
    // (Homebrew's ffmpeg 9 ships without libwebp), else none, said once.
    let webp = join(out, 'demo.webp');
    if (hasEncoder('libwebp_anim')) {
      ff(['-framerate', String(fps), '-i', `${pct(work)}/f%04d.png`, '-c:v', 'libwebp_anim', '-lossless', '0', '-q:v', '75', '-compression_level', '4', '-preset', 'picture', '-loop', '0', webp]);
    } else if (which('img2webp')) {
      execFileSync('img2webp', ['-loop', '0', '-lossy', '-q', '75', '-m', '4', '-d', String(Math.round(1000 / fps)), ...frames, '-o', webp], { stdio: ['ignore', 'ignore', 'pipe'] });
    } else { webp = null; console.warn(`warn: no WebP: ${FFMPEG()} has no libwebp encoder and img2webp is not installed (the webp package has it); the snippet offers the GIF only`); }
    const poster = join(out, 'poster.png');
    ff(['-ss', String(hero.settled), '-i', video, '-frames:v', '1', '-vf', `scale=${width}:-2:flags=lanczos`, '-update', '1', poster]);
    const h = Math.round(width * 9 / 16 / 2) * 2;
    const alt = `${loop.title}: ${loop.spots.map((s) => s.label).join(', ')}`;
    const snippet = `<picture>
  <source media="(prefers-reduced-motion: reduce)" srcset="poster.png">
${webp ? '  <source type="image/webp" srcset="demo.webp">\n' : ''}  <img src="demo.gif" width="${width}" height="${h}" alt="${esc(alt)}">
</picture>
`;
    writeFileSync(join(out, 'picture.html'), snippet);
    const bundle = { video, loop: { from: loop.a, to: loop.b, seconds: r3(loop.b - loop.a), chapter: loop.chapter ?? null,
      spots: loop.spots.map(({ label, lit, end }) => ({ label, lit, end })) }, poster: { at: hero.settled, label: hero.label },
      settings: { width, fps, quality: q, gifWidth: w, budgetMB: budget, gif: tool }, sizesMB: { gif: MB(gif), webp: webp && MB(webp), poster: MB(poster) }, alt };
    writeFileSync(join(out, 'bundle.json'), JSON.stringify(bundle, null, 1));
    console.log(`loop ${loop.a}s to ${loop.b}s (${r3(loop.b - loop.a)}s, ${loop.spots.length} spotlights, ${frames.length} frames)`);
    console.log(`demo.gif ${MB(gif)} MB (${tool}, quality ${q}, ${w}px)${webp ? `, demo.webp ${MB(webp)} MB` : ''}, poster.png ${MB(poster)} MB at ${hero.settled}s`);
    console.log(`${out}/picture.html:\n${snippet}`);
  } finally { rmSync(work, { recursive: true, force: true }); }
}

// gifski when it is installed (libimagequant with temporal dithering: the cleanest GIF there is),
// else ffmpeg's palette pair, which is coarser on gradients, said once.
function gifEncode(frames, work, gif, { fps, quality, width, srcWidth }) {
  if (which('gifski')) {
    execFileSync('gifski', ['--quiet', '--fps', String(fps), '--quality', String(quality), '--width', String(width), '-o', gif, ...frames]);
    return 'gifski';
  }
  if (!gifEncode.warned) { console.warn('warn: gifski not found, so the GIF comes from ffmpeg palettegen/paletteuse (coarser gradients, larger file). Install gifski: brew install gifski, or cargo install gifski'); gifEncode.warned = true; }
  const scale = width < srcWidth ? `scale=${width}:-2:flags=lanczos,` : '';
  ff(['-framerate', String(fps), '-i', `${pct(work)}/f%04d.png`, '-vf', `${scale}split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle`, '-loop', '0', gif]);
  return 'ffmpeg';
}

function interactive() {
  const out = opt.out ?? `${C.out}/export/interactive`;
  mkdirSync(out, { recursive: true });
  const { steps: S, skipped } = steps(C, tl);
  if (!S.length) throw new Error('no marks in the takes: nothing to build steps from');
  if (skipped) console.warn(`warn: ${skipped} click/type cues carry no target rect, so they are not steps (demo:capture records only their time)`);
  const imgs = [], hot = [];
  for (const [k, s] of S.entries()) {
    const png = `${C.takes}/${s.chapter}/cfr/${String(s.frame).padStart(5, '0')}.png`;
    // The lossless take at its own density, never the lossy final: from the PNG frame when the
    // take keeps them, else decoded from the take's lossless mp4. Stored as WebP q90 (ffmpeg's
    // libwebp, else cwebp) when available: 0.307 MB against 0.829 MB of PNG for the ferry steps.
    const raw = existsSync(png) ? png : join(out, `.step-${k}.png`);
    if (raw !== png) ff(['-ss', String(r3(s.frame / s.fps)), '-i', `${C.takes}/${s.chapter}.mp4`, '-frames:v', '1', '-update', '1', raw]);
    // The frame's real size, from its PNG header: the box is scaled onto it, so a take filmed at
    // another density than its events claim still gets its hotspot in the right place.
    const ihdr = readFileSync(raw).subarray(16, 24), W = ihdr.readUInt32BE(0), H = ihdr.readUInt32BE(4);
    const fit = W / (s.vp.width * s.dpr);
    const stem = join(out, `step-${String(k + 1).padStart(2, '0')}`);
    let file = `${stem}.webp`;
    if (hasEncoder('libwebp')) ff(['-i', raw, '-frames:v', '1', '-c:v', 'libwebp', '-lossless', '0', '-q:v', '90', '-update', '1', file]);
    else if (which('cwebp')) execFileSync('cwebp', ['-quiet', '-q', '90', raw, '-o', file]);
    else { file = `${stem}.png`; ff(['-i', raw, '-frames:v', '1', '-update', '1', file]); }
    if (raw !== png) rmSync(raw);
    const box = clipTo(onFrame(s.rect, s.cam, s.dpr * fit), W, H);
    if (!box) throw new Error(`step ${k + 1} (${s.chapter} "${s.text}"): its target is entirely outside the frame`);
    hot.push({ ...box, W, H });
    imgs.push(file);
  }
  const total = imgs.reduce((a, f) => a + statSync(f).size, 0) / 1e6;
  const inline = opt.inline === 'yes' || (opt.inline !== 'no' && total <= 12);
  const payoff = opt.payoff ? S.findIndex((s) => s.text.startsWith(opt.payoff)) : S.length - 1;
  if (opt.payoff && payoff < 0) throw new Error(`--payoff "${opt.payoff}" matches no step label`);
  const warns = lint(S, payoff);
  const data = S.map((s, k) => {
    const label = shortLabel(s.text);
    if (label !== s.text) console.warn(`warn: step ${k + 1} label cut to 59 characters: "${s.text}"`);
    const f = imgs[k], h = hot[k];
    return { label, chapter: s.title, src: inline ? `data:image/${f.endsWith('.webp') ? 'webp' : 'png'};base64,${readFileSync(f).toString('base64')}` : f.split('/').pop(),
      x: r3(h.x / h.W * 100), y: r3(h.y / h.H * 100), w: r3(h.w / h.W * 100), h: r3(h.h / h.H * 100), ar: `${h.W} / ${h.H}` };
  });
  const title = C.cards['title-card']?.title || C.name;
  writeFileSync(join(out, 'index.html'), page(title, data));
  if (inline) for (const f of imgs) rmSync(f);
  writeFileSync(join(out, 'steps.json'), JSON.stringify({ steps: data.map(({ src, ...d }, k) => ({ ...d, file: inline ? null : src,
    frame: S[k].frame, chapter: S[k].chapter, box: hot[k] })), inline, imagesMB: r3(total), payoff: payoff + 1, warnings: warns }, null, 1));
  for (const w of warns) console.warn(`lint: ${w}`);
  console.log(`${S.length} steps, ${inline ? 'images inlined' : 'images beside it'} (${r3(total)} MB of step images), page ${MB(join(out, 'index.html'))} MB -> ${out}/index.html`);
}

// One self-contained page: no scripts or styles from anywhere else, works from file://.
function page(title, data) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}: interactive walkthrough</title>
<style>
:root { --bg: #111317; --fg: #f4f4f5; --muted: #a1a1aa; --accent: #2dd4bf; --panel: #1c1f26; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.4 system-ui, sans-serif; min-height: 100vh; display: flex; flex-direction: column; align-items: center; padding: 16px; gap: 12px; }
h1 { font-size: 18px; font-weight: 600; margin: 0; align-self: stretch; max-width: 1280px; margin-inline: auto; width: 100%; }
h1 small { color: var(--muted); font-weight: 400; margin-left: 8px; }
.stage { position: relative; width: 100%; max-width: 1280px; border-radius: 12px; overflow: hidden; box-shadow: 0 20px 60px rgba(0,0,0,.5); background: #000; }
.stage img { display: block; width: 100%; height: auto; }
.hot { position: absolute; border: 2px solid var(--accent); border-radius: 10px; background: rgba(45,212,191,.08); cursor: pointer; padding: 0; box-shadow: 0 0 0 9999px rgba(0,0,0,.35); }
.hot::after { content: ""; position: absolute; inset: -2px; border-radius: 10px; border: 2px solid var(--accent); animation: pulse 1.6s ease-out infinite; }
@keyframes pulse { from { opacity: .9; transform: scale(1); } to { opacity: 0; transform: scale(1.08); } }
.tip { position: absolute; max-width: min(360px, 80%); background: var(--panel); color: var(--fg); border: 1px solid #2f343e; border-left: 4px solid var(--accent); border-radius: 8px; padding: 8px 12px; font-size: 15px; pointer-events: none; }
nav { display: flex; align-items: center; gap: 12px; width: 100%; max-width: 1280px; }
nav button.step { background: var(--panel); color: var(--fg); border: 1px solid #2f343e; border-radius: 8px; padding: 8px 14px; font: inherit; cursor: pointer; }
nav button.step:disabled { opacity: .4; cursor: default; }
.dots { display: flex; gap: 6px; flex: 1; justify-content: center; flex-wrap: wrap; }
.dots button { width: 12px; height: 12px; border-radius: 50%; border: 0; padding: 0; background: #3f4450; cursor: pointer; }
.dots button[aria-current="step"] { background: var(--accent); transform: scale(1.25); }
.count { color: var(--muted); font-variant-numeric: tabular-nums; min-width: 4.5em; text-align: right; }
:focus { outline: none; }
:focus-visible { outline: 3px solid #facc15; outline-offset: 3px; }
@media (prefers-reduced-motion: reduce) { .hot::after { animation: none; } .dots button { transition: none; } }
@media (max-width: 600px) { body { padding: 8px; } .tip { font-size: 13px; padding: 6px 9px; } nav button.step { padding: 6px 10px; } }
</style>
</head>
<body>
<h1>${esc(title)}<small id="chapter"></small></h1>
<div class="stage" id="stage"><img id="pic" alt=""><button class="hot" id="hot" type="button"></button><div class="tip" id="tip" role="status" aria-live="polite"></div></div>
<nav aria-label="Walkthrough steps">
<button class="step" id="prev" type="button">&larr; Back</button>
<div class="dots" id="dots"></div>
<span class="count" id="count"></span>
<button class="step" id="next" type="button">Next &rarr;</button>
</nav>
<script>
const steps = ${JSON.stringify(data).replace(/</g, '\\u003c')};
let at = 0;
const $ = (id) => document.getElementById(id);
const dots = steps.map((s, k) => { const b = document.createElement('button'); b.type = 'button'; b.setAttribute('aria-label', 'Step ' + (k + 1) + ': ' + s.label); b.onclick = () => go(k); $('dots').appendChild(b); return b; });
// Labels sit below the hotspot, or above it when it reaches the bottom of the frame.
function go(k) {
  at = Math.max(0, Math.min(steps.length - 1, k));
  const s = steps[at], hot = $('hot'), tip = $('tip');
  $('pic').src = s.src; $('pic').alt = 'Step ' + (at + 1) + ' of ' + steps.length + ': ' + s.label;
  $('stage').style.aspectRatio = s.ar;
  Object.assign(hot.style, { left: s.x + '%', top: s.y + '%', width: s.w + '%', height: s.h + '%' });
  hot.setAttribute('aria-label', (at + 1 < steps.length ? 'Next: ' : 'Done: ') + s.label);
  tip.textContent = s.label;
  const below = s.y + s.h < 78;
  Object.assign(tip.style, { left: Math.min(s.x, 60) + '%', top: below ? 'calc(' + (s.y + s.h) + '% + 10px)' : '', bottom: below ? '' : 'calc(' + (100 - s.y) + '% + 10px)' });
  $('chapter').textContent = s.chapter;
  $('count').textContent = (at + 1) + ' / ' + steps.length;
  $('prev').disabled = at === 0; $('next').disabled = at === steps.length - 1;
  dots.forEach((d, j) => { if (j === at) d.setAttribute('aria-current', 'step'); else d.removeAttribute('aria-current'); });
}
$('hot').onclick = () => go(at + 1);
$('prev').onclick = () => go(at - 1);
$('next').onclick = () => go(at + 1);
addEventListener('keydown', (e) => {
  if (e.key === 'ArrowRight' || (e.key === 'Enter' && e.target === document.body)) { e.preventDefault(); go(at + 1); }
  else if (e.key === 'ArrowLeft') { e.preventDefault(); go(at - 1); }
  else if (e.key === 'Home') go(0);
  else if (e.key === 'End') go(steps.length - 1);
});
go(0);
</script>
</body>
</html>
`;
}

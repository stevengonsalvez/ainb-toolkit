#!/usr/bin/env node
// ABOUTME: demo:export. Turns a composed demo into what people actually see outside a video
// player: a README bundle (looping GIF + WebP + poster + <picture> snippet).
// Usage:
//   node export.mjs readme      <compose-config.json> [--width 960] [--fps 15] [--quality 90]
//                               [--from S --to S] [--budget 5] [--out DIR]
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { loadConfig, timeline, pickLoop, cutSpots, seamOf, FFMPEG, hasEncoder, which, r3 } from './lib.mjs';

const [cmd, cfgPath, ...rest] = process.argv.slice(2);
if (cmd !== 'readme' || !cfgPath) {
  console.error('usage: export.mjs readme <compose-config.json> [options] (see SKILL.md)'); process.exit(2);
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

readme();

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

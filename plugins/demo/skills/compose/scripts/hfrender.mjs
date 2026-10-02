#!/usr/bin/env node
// hfrender.mjs <config.json> <project dir> <out.mp4> <log>
// One HyperFrames project to one lossless RGB mp4: rendered as PNG frames, checked, packed. Used by
// render.sh for every segment and by captions.mjs for the burned-caption cut.
//
// Disk: before it captures, HyperFrames refuses unless the free space on the output's filesystem
// is at least the raw RGBA size of every frame over 0.9 (width x height x 4 bytes a frame, so
// 14.7 MB a frame at 1440p and about 1 GB per second at 60fps), although the PNGs it writes are
// about a tenth of that. --low-memory-mode does not lift the check (measured: refused the same).
// So when a project would not fit, it is rendered in time chunks that do, each its own copy of the
// project re-timed to a window of the timeline, packed, and joined losslessly.
import { spawnSync, execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, rmSync, readdirSync, statfsSync, renameSync, openSync, readSync, closeSync, cpSync } from 'node:fs';
import { dirname, basename, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig } from './config.mjs';

const gb = (b) => `${(b / 1e9).toFixed(1)} GB`;
// A duration of whole frames is written rounded down to the millisecond (a segment renders
// ceil(duration * fps) frames); times inside the document keep six places so a window boundary
// never lands a footage frame on its neighbour.
const ms = (d, fps) => (Math.abs(d * fps - Math.round(d * fps)) < 1e-6 ? Math.floor(d * 1000 + 1e-6) / 1000 : Math.round(d * 1000) / 1000);
const t6 = (x) => String(Math.round(x * 1e6) / 1e6);

// The project's own index.html, re-timed to the window [a, a + len) of its timeline: the root
// lasts len, every timed clip moves by -a (a clip already running at a starts at 0, later into its
// media; one wholly outside the window starts after it ends, so it never shows), and the registered
// timeline is a paused wrapper that plays the original from a to a + len.
export function windowed(html, a, len, fps) {
  let root = true;
  html = html.replace(/<[a-z]+\b[^>]*\bdata-start="[^"]*"[^>]*>/g, (tag) => {
    const get = (k) => { const m = tag.match(new RegExp(`\\b${k}="([^"]*)"`)); return m ? +m[1] : null; };
    const set = (t, k, v) => t.replace(new RegExp(`\\b${k}="[^"]*"`), `${k}="${v}"`);
    if (root) { root = false; return set(tag, 'data-duration', ms(len, fps)); }   // the composition root comes first
    const s = get('data-start') - a, d = get('data-duration'), e = s + d, media = get('data-media-start');
    if (e <= 0 || s >= len) return set(set(tag, 'data-start', t6(len + 1)), 'data-duration', '0.1');
    let t = set(tag, 'data-start', t6(Math.max(0, s)));
    t = set(t, 'data-duration', t6(Math.min(e, len) - Math.max(0, s)));
    if (s < 0 && media != null) t = set(t, 'data-media-start', t6(media - s));
    return t;
  });
  return html.replace(/window\.__timelines\["([^"]+)"\] = tl;/,
    (_, id) => `window.__timelines["${id}"] = gsap.timeline({ paused: true }).add(tl.tweenFromTo(${t6(a)}, ${t6(a + len)}, { ease: "none" }), 0);`);
}

// Frames with an alpha channel, read from each PNG's colour-type byte. The #bg invariant
// (compose.mjs): a frame comes out RGBA only where some pixel is transparent, and the pack below
// keeps RGB, so those pixels turn black.
function alphaFrames(d) {
  let n = 0;
  for (const f of readdirSync(d)) if (/^frame_\d+\.png$/.test(f)) {
    const b = Buffer.alloc(26), fd = openSync(`${d}/${f}`, 'r'); readSync(fd, b, 0, 26, 0); closeSync(fd);
    if (b[25] === 4 || b[25] === 6) n++;
  }
  return n;
}

export function renderToMp4(C, dir, out, log) {
  const html = readFileSync(`${dir}/index.html`, 'utf8');
  const dur = +html.match(/data-composition-id="[^"]*"[^>]*\bdata-duration="([^"]*)"/)[1];
  const frames = Math.ceil(dur * C.fps - 1e-6), per = C.width * C.height * 4;
  const st = statfsSync(dirname(out)), free = st.bavail * st.bsize;
  // 0.9 is HyperFrames' own margin; 0.8 more leaves room for the PNGs and anything else writing meanwhile
  const fit = Math.floor(free * 0.9 * 0.8 / per), size0 = +process.env.HF_CHUNK_FRAMES || fit;
  if (size0 < C.fps) throw new Error(`${basename(dir)}: ${gb(free)} free on ${dirname(out)}, under the ${gb(C.fps * per / 0.72)} HyperFrames needs to capture one second at ${C.width}x${C.height}. Free disk space or use quality "draft"`);
  const n = Math.ceil(frames / Math.min(frames, size0)), size = Math.ceil(frames / n);
  if (n > 1) console.log(`  ${basename(dir)}: ${frames} frames need ${gb(frames * per / 0.9)} free for HyperFrames' disk check, ${gb(free)} is free${size0 === fit ? '' : ` (HF_CHUNK_FRAMES=${size0})`}: rendering ${n} chunks of up to ${size} frames`);
  const workers = String(C.workers), PER = Math.ceil(10 * C.width * C.height * C.fps / (1280 * 720 * 30));
  const parts = [];
  let logText = '', alpha = 0;
  for (let k = 0; k < n; k++) {
    const f0 = k * size, f1 = Math.min(frames, f0 + size), want = f1 - f0;
    const pdir = n > 1 ? `${dir}.chunk${k}` : dir, png = `${out}.part${k}`;
    if (n > 1) {
      rmSync(pdir, { recursive: true, force: true });
      cpSync(dir, pdir, { recursive: true });
      writeFileSync(`${pdir}/index.html`, windowed(html, f0 / C.fps, want / C.fps, C.fps));
    }
    rmSync(png, { recursive: true, force: true });
    // the timeout scales with the chunk and its pixel rate (PER: seconds per second, 10 at 720p30)
    const r = spawnSync('npx', ['--yes', 'hyperframes@0.8.40', 'render', '--fps', String(C.fps), '--workers', workers,
      '--format', 'png-sequence', '--video-frame-format', 'png', '--output', resolve(png)],
      { cwd: pdir, encoding: 'utf8', maxBuffer: 1 << 28, timeout: (120 + PER * Math.ceil(want / C.fps)) * 1000 });
    logText += `${r.stdout}\n${r.stderr}\n`;
    writeFileSync(log, logText);
    if (r.status !== 0) throw new Error(`${basename(dir)}: render failed${r.error ? ` (${r.error.code})` : ''}${n > 1 ? ` in chunk ${k + 1} of ${n}` : ''}, see ${log}`);
    // A segment must hold its planned length in frames: concat and check.mjs turn frames into time.
    const got = readdirSync(png).filter((f) => /^frame_\d+\.png$/.test(f)).length;
    if (got !== want) throw new Error(`${basename(dir)}: ${got} frames${n > 1 ? ` in chunk ${k + 1}` : ''}, wanted ${want}`);
    alpha += alphaFrames(png);
    // Packed bit-exact into lossless RGB H.264 (verified: PSNR inf against the PNGs), 7x smaller
    // than the PNGs at 1440p60. A keyframe every 30 frames keeps each still-check seek short:
    // x264's default 250 decoded up to 4s of lossless 1440p60 a still (ferry check 45.7s, now 29.1s).
    execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-framerate', String(C.fps), '-i', `${png.replace(/%/g, '%%')}/frame_%06d.png`,
      '-c:v', 'libx264rgb', '-qp', '0', '-preset', 'veryfast', '-g', '30', '-pix_fmt', 'rgb24', `${png}.mp4`]);
    rmSync(png, { recursive: true, force: true });
    if (n > 1) rmSync(pdir, { recursive: true, force: true });
    parts.push(`${png}.mp4`);
  }
  if (alpha) console.warn(`warn: ${basename(dir)}: ${alpha} frames have transparent pixels; they render black. Every visible element must sit on an opaque layer (the #bg fill).`);
  if (n === 1) renameSync(parts[0], out);
  else {
    // identical streams, so the concat demuxer joins them without re-encoding
    const list = `${out}.parts.txt`;
    writeFileSync(list, parts.map((p) => `file '${resolve(p).replace(/'/g, "'\\''")}'`).join('\n') + '\n');
    execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', list, '-c', 'copy', out]);
    for (const p of [...parts, list]) rmSync(p, { force: true });
  }
  return { frames, chunks: n };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [cfg, dir, out, log] = process.argv.slice(2);
  try { renderToMp4(loadConfig(cfg), dir, out, log); } catch (e) { console.error(e.message); process.exit(1); }
}

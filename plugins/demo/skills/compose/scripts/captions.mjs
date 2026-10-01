// captions.mjs: caption files for the finished cut, used by audio.mjs.
//   out/<name>.captions.vtt  narration, word timed, grouped into short cues; without narration,
//                            each spotlight's label for as long as it is lit
//   out/<name>.chapters.vtt  one cue per segment, titled from the config
//   out/<name>-captions.mp4  only with audio.captions.burn: the same video with the captions
//                            burned in, the spoken word highlighted, rendered through HyperFrames
import { execFileSync } from 'node:child_process';
import { writeFileSync, mkdirSync, copyFileSync, rmSync } from 'node:fs';
import { dirname, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { r3, esc } from './config.mjs';
import { renderToMp4 } from './hfrender.mjs';

const SKILL = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const stamp = (t) => {
  const ms = Math.max(0, Math.round(t * 1000));
  const p = (x, n = 2) => String(x).padStart(n, '0');
  return `${p(Math.floor(ms / 3600000))}:${p(Math.floor(ms / 60000) % 60)}:${p(Math.floor(ms / 1000) % 60)}.${p(ms % 1000, 3)}`;
};
// Cue text is not raw: '&' and '<' are markup in WebVTT, and '-->' would end the cue's timing line.
const cueText = (t) => String(t).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\n+/g, ' ');
export const vtt = (cues) => `WEBVTT\n\n${cues.map((c, i) => `${i + 1}\n${stamp(c.start)} --> ${stamp(c.end)}\n${cueText(c.text)}\n`).join('\n')}`;

// Word-timed cues from the narration, or label cues when nothing is narrated.
export function cues(C, segs, A) {
  const max = A?.captions.maxWords ?? 7, out = [];
  const words = segs.flatMap((s) => (s.plan.narration || []).flatMap((l, li) =>
    l.words.map((w, wi) => ({ ...w, start: s.start + l.at + w.start, end: s.start + l.at + w.end, line: `${s.name}/${li}`, last: wi === l.words.length - 1 }))));
  if (words.length) {
    // Each sentence of each line splits into the fewest even cues that keep to maxWords and 42
    // characters, so a long sentence never leaves one word stranded on a cue of its own.
    const sentences = [];
    for (const w of words) {
      const cur = sentences.at(-1), prev = cur?.at(-1);
      if (!cur || prev.line !== w.line || /[.?!]$/.test(prev.text) || w.start - prev.end > 0.6) sentences.push([w]); else cur.push(w);
    }
    for (const ws of sentences) {
      const chars = ws.reduce((a, w) => a + w.text.length + 1, 0);
      const k = Math.max(Math.ceil(ws.length / max), Math.ceil(chars / 42));
      for (let q = 0; q < k; q++) {
        const part = ws.slice(Math.round(q * ws.length / k), Math.round((q + 1) * ws.length / k));
        if (part.length) out.push({ words: part, text: part.map((x) => x.text).join(' ') });
      }
    }
    for (const [i, c] of out.entries()) {
      c.start = c.words[0].start;
      // hold a cue at least 0.8s, but never into the next one
      c.end = Math.min(Math.max(c.words.at(-1).end, c.start + 0.8), out[i + 1]?.words[0].start ?? Infinity);
    }
    return { kind: 'narration', cues: out };
  }
  for (const s of segs) for (const sp of s.plan.spots || []) {
    out.push({ start: s.start + (sp.litFrom ?? sp.compT - C.fadeLead), end: s.start + sp.compT + sp.hold, text: sp.label });
  }
  return { kind: 'labels', cues: out };
}

export function writeCaptions(C, segs, A) {
  const { kind, cues: cs } = cues(C, segs, A);
  const base = `${C.out}/out/${C.name}`;
  writeFileSync(`${base}.captions.vtt`, vtt(cs));
  const title = (n) => C.cards[n]?.title ?? C.chapters.find((c) => c.name === n)?.title ?? n;
  writeFileSync(`${base}.chapters.vtt`, vtt(segs.map((s) => ({ start: s.start, end: s.start + s.dur, text: title(s.name) }))));
  return { captions: `${base}.captions.vtt (${cs.length} ${kind} cues)`, chapters: `${base}.chapters.vtt (${segs.length})` };
}

// Captions burned into a copy of the final video: one HyperFrames project holding the video
// plus a caption box, the spoken word picked out in the highlight colour.
export function burnCaptions(C, segs, A, final) {
  const { kind, cues: cs } = cues(C, segs, A);
  const W = C.width, H = C.height, T = C.theme;
  const total = r3(+execFileSync(C.ffprobe, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', final]).toString().trim());
  const d = `${C.out}/work/captions-burn`;
  rmSync(d, { recursive: true, force: true });
  mkdirSync(`${d}/assets/fonts`, { recursive: true });
  for (const f of ['hyperframes.json', 'package.json', 'gsap.min.js']) copyFileSync(`${SKILL}/assets/template/${f}`, `${d}/${f}`);
  for (const f of C.fontFiles) copyFileSync(f, `${d}/assets/fonts/${basename(f)}`);
  // A keyframe every second (HyperFrames warns that a sparse GOP freezes frames), lossless so the
  // burned cut stays one encode away from the final.
  execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-i', final, '-an', '-c:v', 'libx264', '-qp', '0', '-preset', 'veryfast',
    '-g', String(C.fps), '-keyint_min', String(C.fps), `${d}/assets/final.mp4`]);
  writeFileSync(`${d}/meta.json`, JSON.stringify({ id: 'captions', name: 'captions', createdAt: new Date(0).toISOString() }, null, 1));
  const lines = [];
  const body = cs.map((c, i) => {
    lines.push(`tl.set("#c${i}", { opacity: 1 }, ${r3(c.start)});`, `tl.set("#c${i}", { opacity: 0 }, ${r3(c.end)});`);
    if (!c.words) return `<div id="c${i}" class="cap">${esc(c.text)}</div>`;
    c.words.forEach((w, k) => {
      lines.push(`tl.set("#c${i}w${k}", { color: "${T.highlight}" }, ${r3(w.start)});`);
      lines.push(`tl.set("#c${i}w${k}", { color: "#FFFFFF" }, ${r3(c.words[k + 1]?.start ?? c.end)});`);
    });
    return `<div id="c${i}" class="cap">${c.words.map((w, k) => `<span id="c${i}w${k}">${esc(w.text)}</span>`).join(' ')}</div>`;
  }).join('\n');
  writeFileSync(`${d}/index.html`, `<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=${W}, height=${H}" />
<script src="gsap.min.js"></script>
<style>
${C.fontFaces.join('\n')}
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: ${W}px; height: ${H}px; overflow: hidden; background: #000; }
#root { position: relative; width: 100%; height: 100%; overflow: hidden; background: #000; }
/* png-sequence renders the root transparent: an opaque full-bleed layer, as in compose.mjs */
#bg { position: absolute; inset: 0; background: #000; }
.foot { position: absolute; inset: 0; width: 100%; height: 100%; }
.cap { position: absolute; left: 50%; bottom: ${C.layout.safeMargin}px; transform: translateX(-50%); opacity: 0;
  max-width: ${W - 2 * C.layout.safeMargin}px; padding: 10px 20px; border-radius: 10px; background: rgba(0,0,0,0.72);
  font-family: ${C.displayStack}; font-weight: 600; font-size: ${Math.round(H / 22)}px; line-height: 1.25;
  color: #FFFFFF; text-align: center; white-space: nowrap; }
</style>
</head>
<body>
<div id="root" data-composition-id="captions" data-start="0" data-duration="${total}" data-width="${W}" data-height="${H}">
<div id="bg"></div>
<video id="final" class="foot clip" src="assets/final.mp4" data-start="0" data-duration="${total}" data-media-start="0" data-track-index="0" muted playsinline></video>
${body}
</div>
<script>
const tl = gsap.timeline({ paused: true });
${lines.join('\n')}
window.__timelines["captions"] = tl;
</script>
</body>
</html>
`);
  // Rendered as PNG frames, packed losslessly (in chunks if the disk is short, hfrender.mjs) and
  // encoded once, the same way concat.sh encodes the final; the audio is copied from the final.
  const out = `${C.out}/out/${C.name}-captions.mp4`, log = `${C.out}/work/render-captions.log`, burn = `${d}/burn.mp4`;
  renderToMp4(C, d, burn, log);
  execFileSync(C.ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-i', burn, '-i', final,
    '-map', '0:v', '-map', '1:a?', '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', String(C.crf), '-tune', 'animation', '-c:a', 'copy', '-movflags', '+faststart', out]);
  return `${out} (${cs.length} ${kind} cues)`;
}

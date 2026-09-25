#!/usr/bin/env node
// ABOUTME: Runs every chapter of a beats file, then encodes each to mp4.
// Usage: node run.mjs <beats.mjs> [chapter ...]   (names filter which chapters run)
import path from 'path'; import { pathToFileURL, fileURLToPath } from 'url'; import { execFileSync } from 'child_process';
import { capture, ensureState } from './capture.mjs';

const [file, ...only] = process.argv.slice(2);
if (!file) { console.error('usage: node run.mjs <beats.mjs> [chapter ...]'); process.exit(2); }
const cfg = (await import(pathToFileURL(path.resolve(file)))).default;
const here = path.dirname(fileURLToPath(import.meta.url));

if (cfg.login) console.log(`session: ${await ensureState(cfg)}`);
for (const ch of cfg.chapters.filter(c => !only.length || only.includes(c.name))) {
  // A chapter's `pace` and `cursor` override the file-level ones.
  const r = await capture({ ...cfg, chapter: ch.name, beats: ch.beats,
    pace: ch.pace ?? cfg.pace, cursor: { ...cfg.cursor, ...ch.cursor } });
  const mp4 = `${r.dir}.mp4`;
  execFileSync(path.join(here, 'encode.sh'), [r.dir, mp4], { stdio: 'inherit' });
  console.log(`${ch.name}: ${r.frames} frames, ${r.dur.toFixed(1)}s, ${r.events} marks -> ${mp4}`);
}

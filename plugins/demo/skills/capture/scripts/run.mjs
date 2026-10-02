#!/usr/bin/env node
// ABOUTME: Runs every chapter of a beats file, then encodes each to mp4. A dry run goes first: the
// beats at speed with no frames, every target resolved, so a broken one fails in seconds instead
// of mid-film.
// Usage: node run.mjs <beats.mjs> [chapter ...] [--dry-run | --no-dry-run]
//   --dry-run     only the dry run: a table per chapter, exit 1 on any miss
//   --no-dry-run  film without it
import path from 'path'; import { pathToFileURL, fileURLToPath } from 'url'; import { execFileSync } from 'child_process';
import { capture, ensureState } from './capture.mjs';
import { narrativeLint, composeFor } from './narrative.mjs';

const argv = process.argv.slice(2), flags = argv.filter(a => a.startsWith('--')), [file, ...only] = argv.filter(a => !a.startsWith('--'));
const bad = flags.find(f => !['--dry-run', '--no-dry-run'].includes(f));
if (!file || bad || flags.length > 1) { console.error(`${bad ? `unknown option ${bad}\n` : ''}usage: node run.mjs <beats.mjs> [chapter ...] [--dry-run | --no-dry-run]`); process.exit(2); }
const cfg = (await import(pathToFileURL(path.resolve(file)))).default;
const here = path.dirname(fileURLToPath(import.meta.url));
const chapters = cfg.chapters.filter(c => !only.length || only.includes(c.name));
// A chapter's `pace`, `cursor` and `capture` override the file-level ones.
const opts = (ch, extra = {}) => ({ ...cfg, chapter: ch.name, beats: ch.beats, pace: ch.pace ?? cfg.pace,
  cursor: { ...cfg.cursor, ...ch.cursor }, capture: { ...cfg.capture, ...ch.capture, ...extra } });

if (cfg.login) console.log(`session: ${await ensureState(cfg)}`);

if (!flags.includes('--no-dry-run')) {
  const t0 = Date.now();
  let misses = 0, n = 0;
  for (const ch of chapters) {
    try {
      const r = await capture(opts(ch, { mode: 'dry' }));
      console.log(`${ch.name}`);
      for (const { beat, ms } of r.timing) {
        const rows = r.targets.filter(t => t.beat === beat);
        if (!rows.length) { console.log(`  ${beat.padEnd(14)} ${''.padEnd(6)} ${'(no target)'.padEnd(52)} ${String(ms).padStart(5)} ms`); continue; }
        rows.forEach((t, k) => {
          const via = t.of > 1 ? `${t.matched} (chain entry ${t.index + 1} of ${t.of})` : t.matched;
          console.log(`  ${(k ? '' : beat).padEnd(14)} ${t.use.padEnd(6)} ${via.padEnd(52)} ${k ? '' : `${String(ms).padStart(5)} ms`}`);
          n++;
        });
      }
      for (const w of r.lints) console.log(`  lint: ${w}`);
    } catch (e) {
      misses++;
      console.log(`${ch.name}\n  MISS ${e.message}`);
    }
  }
  // Pacing, from the beats themselves (and the narration, when the beats file names its compose
  // config): warnings, never a failure.
  for (const w of narrativeLint({ ...cfg, chapters }, composeFor(cfg, path.resolve(file)))) console.log(`narrative: ${w}`);
  console.log(`dry run: ${chapters.length} chapter(s), ${n} target(s) resolved, ${misses} miss(es), ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  if (misses) process.exit(1);
  if (flags.includes('--dry-run')) process.exit(0);
}

for (const ch of chapters) {
  const t0 = Date.now();
  const r = await capture(opts(ch));
  const wall = (Date.now() - t0) / 1000;
  const mp4 = `${r.dir}.mp4`;
  execFileSync(path.join(here, 'encode.sh'), [r.dir, mp4], { stdio: 'inherit' });
  console.log(`${ch.name}: ${r.mode} ${r.fps}fps x${r.dpr}, ${r.frames} frames, ${r.dur.toFixed(1)}s, ${r.events} marks, filmed in ${wall.toFixed(0)}s -> ${mp4}`);
}

#!/usr/bin/env node
// ABOUTME: Lists what a beat could target on a page: every interactive element, landmark, heading,
// table and anything with an id or test id, with its role, accessible name, test id, rect (CSS px)
// and the locator chain to write for it (steadiest first). The draft procedure in SKILL.md reads it.
// Usage: node inventory.mjs <url> [--state session-state.json] [--json]
//        node inventory.mjs <beats.mjs> <chapter> [beat] [--json]
//          replays the chapter's beats (a dry run, no frames) up to and including `beat` (a name or
//          index; all of them when omitted), then lists the page it is on.
import path from 'path'; import { pathToFileURL } from 'url';
import { chromium } from '@playwright/test';
import { capture, ensureState } from './capture.mjs';
import { inventory, source } from './locate.mjs';

// A logged-in page needs the session: --state takes the file a beats file's `state` names
// (run.mjs mints it), and the beats form uses the beats file's own.
const argv = process.argv.slice(2), json = argv.includes('--json'), si = argv.indexOf('--state'), state = si >= 0 ? argv[si + 1] : undefined;
const [a, chapter, upto] = argv.filter((x, i) => x !== '--json' && (si < 0 || (i !== si && i !== si + 1)));
if (!a || (si >= 0 && !state) || (!/^https?:/.test(a) && !chapter)) { console.error('usage: node inventory.mjs <url> [--state session-state.json] [--json] | <beats.mjs> <chapter> [beat] [--json]'); process.exit(2); }
let items, where = a;
if (/^https?:/.test(a)) {
  const browser = await chromium.launch();
  try {
    const page = await (await browser.newContext({ viewport: { width: 1280, height: 720 }, storageState: state })).newPage();
    await page.goto(a, { waitUntil: 'networkidle', timeout: 30000 });
    items = await inventory(page);
  } finally { await browser.close(); }
} else {
  const cfg = (await import(pathToFileURL(path.resolve(a)))).default;
  const ch = cfg.chapters.find(c => c.name === chapter);
  if (!ch) { console.error(`no chapter "${chapter}" in ${a} (${cfg.chapters.map(c => c.name).join(', ')})`); process.exit(2); }
  const k = upto == null ? ch.beats.length - 1 : /^\d+$/.test(upto) ? +upto : ch.beats.findIndex(b => b.name === upto);
  if (k < 0 || k >= ch.beats.length) { console.error(`no beat "${upto}" in chapter ${chapter}`); process.exit(2); }
  if (cfg.login) await ensureState(cfg);
  const r = await capture({ ...cfg, chapter, beats: ch.beats.slice(0, k + 1), capture: { ...cfg.capture, ...ch.capture, mode: 'dry', inventory: true } });
  items = r.inventory; where = `${chapter} after beat ${ch.beats[k].name || `#${k}`}`;
}
if (json) { console.log(JSON.stringify(items, null, 1)); process.exit(0); }
console.log(`${items.length} targets on ${where}${items.skipped ? ` (skipped ${items.skipped} re-rendered node${items.skipped > 1 ? 's' : ''})` : ''}`);
for (const it of items) {
  const what = `${it.role || it.tag}${it.name ? ` "${it.name}"` : ''}`, r = it.rect;
  console.log(`  ${what.slice(0, 44).padEnd(44)} ${`${r.x},${r.y} ${r.w}x${r.h}`.padEnd(18)} ${it.chain.length ? `[${it.chain.map(source).join(', ')}]` : `(text: ${it.text || 'none'})`}`);
}

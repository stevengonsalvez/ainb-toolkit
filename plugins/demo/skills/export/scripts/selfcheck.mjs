#!/usr/bin/env node
// ABOUTME: demo:export self-check. Exits non-zero if the loop picker can cut a spotlight, a
// hotspot can land outside its step image, or a GIF over budget gets through. Pure checks on
// random inputs, then both exports end to end on a synthetic demo in a directory whose name has
// a space and a `%`. Every guard is also fed the input it must refuse.
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { pickLoop, cutSpots, onFrame, clipTo, shortLabel, lint, FFMPEG, SKILL, r3, loadConfig, timeline } from './lib.mjs';

let fails = 0;
const ok = (cond, what) => { console.log(`${cond ? 'ok  ' : 'FAIL'} ${what}`); if (!cond) fails++; };
let seed = 7;
const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);

// 1. The loop never cuts a spotlight, stays in its chapter's footage and within 12 s. Times are
// whole milliseconds, as timeline() gives them. About a third of neighbours crossfade (the next
// lights up to 0.3 s before the last has faded), as compose does with close marks.
{
  const pick = (ch) => { try { return pickLoop([ch], { seam: () => rnd() * 30, motion: () => rnd() * 10 }); } catch { return 'threw'; } };
  let bad = 0, picked = 0;
  for (let n = 0; n < 3000; n++) {
    const a0 = r3(rnd() * 3), spots = []; let t = r3(a0 + 0.5 + rnd() * 2);
    for (let k = 0, m = 1 + Math.floor(rnd() * 5); k < m; k++) {
      const lit = t, end = r3(lit + 1 + rnd() * 2.5);
      spots.push({ label: `s${k}`, lit, end }); t = r3(end + rnd() * 4 - (rnd() < 0.35 ? 1.3 : 0));
      if (t < lit + 0.5) t = r3(lit + 0.5);
    }
    const ch = { name: 'c', title: 'C', a0, a1: r3(Math.max(t, spots.at(-1).end) + rnd() * 2), spots };
    const L = pick(ch);
    if (!L) continue;
    picked++;
    if (L === 'threw' || cutSpots([L.a, L.b], spots).length || L.a < ch.a0 - 1e-6 || L.b > ch.a1 + 1e-6 || L.b - L.a > 12 + 1e-6) bad++;
  }
  ok(picked > 1500 && bad === 0, `loop picker: ${picked} random chapters, some crossfading, ${bad} loops cut a spotlight or left the footage`);
  // Seven spotlights 1.75 s apart, each held 1.6 s and fading 0.3 s: every neighbour overlaps.
  const xf = Array.from({ length: 7 }, (_, k) => ({ label: `m${k}`, lit: r3(4 + 1.75 * k), end: r3(4 + 1.75 * k + 1.9) }));
  const L7 = pick({ name: 'c', title: 'C', a0: 2, a1: 20, spots: xf });
  ok(L7 !== 'threw' && (!L7 || !cutSpots([L7.a, L7.b], xf).length), `seven crossfading spotlights: ${L7 && L7 !== 'threw' ? `${L7.a}s to ${L7.b}s` : L7 || 'no loop'}, none cut`);
  const s = [{ label: 'x', lit: 5, end: 7 }];
  ok(cutSpots([6, 10], s).length === 1 && cutSpots([4, 6.5], s).length === 1 && !cutSpots([4, 8], s).length && !cutSpots([7, 9], s).length,
    'cutSpots flags a range that starts or ends inside a spotlight, passes one that holds it or misses it');
}

// 2. A hotspot is the event rect through the camera, times the density, clipped to the frame.
{
  const b = onFrame({ x: 110, y: 70, w: 50, h: 20 }, { x: 100, y: 50, s: 2 }, 2);
  ok(b.x === 40 && b.y === 80 && b.w === 200 && b.h === 80, `onFrame: (rect - cam) x zoom x dpr gives ${JSON.stringify(b)}`);
  let bad = 0;
  for (let n = 0; n < 5000; n++) {
    const W = 2560, H = 1440, r = { x: rnd() * 4000 - 1000, y: rnd() * 2500 - 600, w: rnd() * 2000, h: rnd() * 1000 };
    const c = clipTo(r, W, H);
    if (c && (c.x < 0 || c.y < 0 || c.x + c.w > W + 1e-6 || c.y + c.h > H + 1e-6 || c.w < 1 || c.h < 1)) bad++;
    if (!c && Math.min(W, r.x + r.w) - Math.max(0, r.x) >= 1 && Math.min(H, r.y + r.h) - Math.max(0, r.y) >= 1) bad++;
  }
  ok(bad === 0, `clipTo: 5000 random boxes, ${bad} outside the frame or wrongly dropped`);
  ok(shortLabel('Departures, deck space and fares for every crossing today on one board').length < 60 && shortLabel('Short') === 'Short', 'hotspot labels stay under 60 characters');
  ok(lint(Array(10)).length === 0 && lint(Array(5)).length === 1 && lint(Array(10), 8).length === 1, 'lint: 9-12 steps pass, 5 steps warn, payoff at step 9 warns');
}

// 3. Both exports end to end on a synthetic demo.
const root = mkdtempSync(join(tmpdir(), 'export check 100%-'));
try {
  const ff = (args) => execFileSync(FFMPEG(), ['-nostdin', '-loglevel', 'error', '-y', ...args]);
  const w = (p, o) => { mkdirSync(join(p, '..'), { recursive: true }); writeFileSync(p, typeof o === 'string' ? o : JSON.stringify(o)); };
  // A 1 s title card then a 14 s chapter: 2 s chapter card, spotlights at 4, 7.5 and 11 s.
  w(join(root, 'demo.config.json'), { name: 'fixture', takes: './takes', out: './compose',
    cards: { title: { title: 'Fixture', dur: 1 } }, chapters: [{ name: 'one', title: 'Chapter one' }] });
  w(join(root, 'compose/work/title-card.plan.json'), { kind: 'card', total: 1 });
  const spot = (i, label, compT) => ({ i, label, compT, litFrom: compT, fadeIn: 0.25, hold: 1.75 });
  w(join(root, 'compose/work/one.plan.json'), { kind: 'chapter', total: 14, cardDur: 2,
    spots: [spot(0, 'First proof', 3), spot(1, 'Second proof', 6.5), spot(2, 'Third proof', 10)] });
  mkdirSync(join(root, 'compose/out'), { recursive: true });
  ff(['-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30:duration=15', '-pix_fmt', 'yuv420p', join(root, 'compose/out/fixture.mp4')]);
  // The take: no cfr frames kept, so steps decode from its mp4 at 2x of a 640x360 viewport.
  mkdirSync(join(root, 'takes'));
  ff(['-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30:duration=12', '-pix_fmt', 'yuv420p', join(root, 'takes/one.mp4')]);
  const mark = (t, label, rect, cam = null) => ({ t, kind: 'mark', label, rect, cam });
  const events = (extra = []) => ({ viewport: { width: 640, height: 360 }, dpr: 2, fps: 30, events: [
    mark(3, 'capture label one', { x: 20, y: 30, w: 200, h: 80 }),
    { t: 4, kind: 'click', rect: { x: 600, y: 300, w: 80, h: 100 }, label: 'Open it' },
    { t: 5, kind: 'click' },
    { t: 6, kind: 'camera', cam: { x: 320, y: 180, s: 2 } },
    mark(6.5, 'capture label two', { x: 400, y: 200, w: 100, h: 50 }, { x: 320, y: 180, s: 2 }), ...extra] });
  w(join(root, 'takes/one/events.json'), events());

  const run = (...args) => spawnSync(process.execPath, [join(SKILL, 'scripts/export.mjs'), ...args], { cwd: root, encoding: 'utf8' });
  const cfg = join(root, 'demo.config.json');

  let r = run('readme', cfg, '--width', '320');
  const bundle = r.status === 0 && JSON.parse(readFileSync(join(root, 'compose/export/readme/bundle.json'), 'utf8'));
  ok(r.status === 0, `readme exits 0${r.status ? `: ${r.stderr.trim()}` : ''}`);
  if (bundle) {
    const all = [3, 6.5, 10].map((t) => ({ label: t, lit: 1 + t, end: 1 + t + 1.75 + 0.3 }));
    ok(!cutSpots([bundle.loop.from, bundle.loop.to], all).length && bundle.loop.seconds >= 8 && bundle.loop.seconds <= 12,
      `readme loop ${bundle.loop.from}s to ${bundle.loop.to}s holds whole spotlights only`);
    ok(bundle.sizesMB.gif <= bundle.settings.budgetMB, `GIF ${bundle.sizesMB.gif} MB within its ${bundle.settings.budgetMB} MB budget`);
    ok(/prefers-reduced-motion: reduce\)" srcset="poster.png"/.test(readFileSync(join(root, 'compose/export/readme/picture.html'), 'utf8')), 'snippet sends reduced-motion viewers the poster');
  }
  // The snippet states the GIF's real size, read back from the GIF; a square demo stays square.
  const sized = (dir) => {
    const g = readFileSync(join(dir, 'demo.gif')).subarray(6, 10), m = readFileSync(join(dir, 'picture.html'), 'utf8').match(/width="(\d+)" height="(\d+)"/);
    return { gif: [g.readUInt16LE(0), g.readUInt16LE(2)], snippet: m && [+m[1], +m[2]] };
  };
  let z = sized(join(root, 'compose/export/readme'));
  ok(String(z.gif) === '320,180' && String(z.snippet) === String(z.gif), `16:9 snippet size ${z.snippet} matches the GIF ${z.gif}`);
  ff(['-f', 'lavfi', '-i', 'testsrc2=size=360x360:rate=30:duration=15', '-pix_fmt', 'yuv420p', join(root, 'compose/out/square.mp4')]);
  w(join(root, 'square.config.json'), { ...JSON.parse(readFileSync(cfg, 'utf8')), name: 'square', format: 'square' });
  r = run('readme', join(root, 'square.config.json'), '--width', '320', '--out', join(root, 'sq'));
  z = r.status === 0 ? sized(join(root, 'sq')) : {};
  ok(String(z.gif) === '320,320' && String(z.snippet) === String(z.gif), `square snippet size ${z.snippet} matches the GIF ${z.gif}${r.status ? `: ${r.stderr.trim()}` : ''}`);
  r = run('readme', cfg, '--width', '320', '--budget', '0.001', '--out', join(root, 'over'));
  ok(r.status !== 0 && /over the 0.001 MB budget/.test(r.stderr), 'a GIF over its budget fails the export');
  r = run('readme', cfg, '--width', '700', '--budget', '0.001', '--out', join(root, 'floor'));
  ok(r.status !== 0 && /\b640px/.test(r.stderr), `stepping width down stops at 640 px: ${r.stderr.trim().split('\n').at(-1)}`);
  r = run('readme', cfg, '--from', '5', '--to', '9', '--out', join(root, 'cut'));
  ok(r.status !== 0 && /cuts the spotlight/.test(r.stderr), '--from/--to that cut a spotlight fail the export');
  r = run('readme', cfg, '--from', '0', '--to', '2', '--out', join(root, 'nospot'));
  ok(r.status === 1 && /holds no whole spotlight/.test(r.stderr) && !existsSync(join(root, 'nospot/demo.gif')), `--from/--to holding no spotlight fail before encoding: ${r.stderr.trim()}`);
  for (const [args, what] of [[['readme', cfg, '--form', '5'], 'a misspelt option'], [['readme', cfg, '--width', 'abc'], 'a width that is not a number'],
    [['readme', cfg, '--width'], 'an option with no value'], [['interactive', cfg, '--inline', 'maybe'], 'an --inline that is not auto, yes or no']]) {
    r = run(...args);
    ok(r.status === 2 && /usage:/.test(r.stderr), `${what} is refused (exit ${r.status}: ${r.stderr.split('\n')[0]})`);
  }
  // The config's own "ffmpeg" wins, as in demo:compose; a missing one is named.
  w(join(root, 'noff.config.json'), { ...JSON.parse(readFileSync(cfg, 'utf8')), ffmpeg: '/nonexistent/ffmpeg' });
  r = run('readme', join(root, 'noff.config.json'));
  ok(r.status === 1 && /ffmpeg not found \(tried \/nonexistent\/ffmpeg\)/.test(r.stderr), `a missing ffmpeg is named: ${r.stderr.trim()}`);
  // The poster waits for the label too: it starts at compT - 0.1 pace (or lit) and takes 0.3
  // pace. At pace 3 that is 0.9 s, well past the old fixed compT + 0.5 s.
  w(join(root, 'pace3.config.json'), { ...JSON.parse(readFileSync(cfg, 'utf8')), pace: 3 });
  const p3 = timeline(loadConfig(join(root, 'pace3.config.json'))).chapters[0].spots;
  ok(p3.every((sp) => sp.settled >= Math.max(sp.lit, sp.at - 0.3) + 0.9 - 1e-6 && sp.settled < sp.end), `at pace 3 the poster frame has the label fully in: ${p3.map((sp) => `${sp.at} -> ${sp.settled}`).join(', ')}`);

  r = run('interactive', cfg, '--inline', 'no');
  ok(r.status === 0, `interactive exits 0${r.status ? `: ${r.stderr.trim()}` : ''}`);
  if (r.status === 0) {
    const out = join(root, 'compose/export/interactive'), st = JSON.parse(readFileSync(join(out, 'steps.json'), 'utf8'));
    ok(st.steps.length === 3 && /no target rect/.test(r.stderr), `3 steps (2 marks, 1 click with a rect); the click without one is skipped and said`);
    ok(st.steps[0].label === 'First proof' && st.steps[2].label === 'Second proof', `step labels are compose's spotlight labels, not the capture's: ${st.steps.map((x) => x.label)}`);
    let bad = 0;
    for (const s of st.steps) {
      const { W, H } = s.box;
      const img = spawnSync(FFMPEG(), ['-nostdin', '-i', join(out, s.file)], { encoding: 'utf8' }).stderr.match(/, (\d+)x(\d+)/);
      if (!img || +img[1] !== W || +img[2] !== H) bad++;
      if (s.box.x < 0 || s.box.y < 0 || s.box.x + s.box.w > W + 1e-6 || s.box.y + s.box.h > H + 1e-6) bad++;
    }
    ok(bad === 0, 'every hotspot lies inside its step image, and each step image is the frame size the box was fitted to');
    const second = st.steps[2].box;
    // (400 - 320) x zoom 2 x dpr 2 = 320; (200 - 180) x 4 = 80; 100 x 4 = 400; 50 x 4 = 200
    ok(second.x === 320 && second.y === 80 && second.w === 400 && second.h === 200, `the zoomed mark maps through the camera: ${JSON.stringify(second)}`);
  }
  w(join(root, 'takes/one/events.json'), events([mark(8, 'Off screen', { x: 5000, y: 5000, w: 10, h: 10 })]));
  r = run('interactive', cfg, '--out', join(root, 'off'));
  ok(r.status !== 0 && /entirely outside the frame/.test(r.stderr), 'a hotspot outside its step image fails the export');
} finally { rmSync(root, { recursive: true, force: true }); }

console.log(fails ? `${fails} check(s) failed` : 'all checks passed');
process.exit(fails ? 1 : 0);

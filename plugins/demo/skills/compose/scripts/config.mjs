// Config loading and defaults. Every app-specific value lives in the config file;
// the defaults below are deliberately brand-neutral placeholders.
import { readFileSync, existsSync } from 'node:fs';
import { dirname, resolve, isAbsolute, basename } from 'node:path';

export const r3 = (x) => Math.round(x * 1000) / 1000;
export const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/'/g, '&#39;');

// capture writes either <takes>/<chapter>-events.json or <takes>/<chapter>/events.json
export function eventsPath(takes, name) {
  const flat = `${takes}/${name}-events.json`;
  if (existsSync(flat)) return flat;
  const nested = `${takes}/${name}/events.json`;
  if (existsSync(nested)) return nested;
  throw new Error(`${name}: no events.json (looked at ${flat} and ${nested})`);
}

const titleCase = (s) => s.replace(/[-_]+/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());

function hexToRgba(hex, a) {
  const h = hex.replace('#', '');
  const n = h.length === 3 ? h.split('').map((c) => c + c).join('') : h;
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(n.slice(i, i + 2), 16));
  return `rgba(${r},${g},${b},${a})`;
}

const GENERIC = 'ui-sans-serif, system-ui, sans-serif';

// A named font-family without an @font-face is a hyperframes lint error, so a config with
// no font files falls back to the generic stack and emits no @font-face at all.
function fontStack(spec, dir, faces, files) {
  if (!spec || !spec.file) return GENERIC;
  const file = isAbsolute(spec.file) ? spec.file : resolve(dir, spec.file);
  if (!existsSync(file)) throw new Error(`font file not found: ${file}`);
  files.add(file);
  const family = spec.family || basename(file).replace(/\.\w+$/, '');
  faces.push(`@font-face { font-family: '${family}'; font-weight: ${spec.weight ?? '400 700'}; src: url('assets/fonts/${basename(file)}') format('woff2'); }`);
  return `'${family}', ${GENERIC}`;
}

export function loadConfig(path) {
  const dir = dirname(resolve(path));
  const raw = JSON.parse(readFileSync(path, 'utf8'));
  const abs = (p) => (isAbsolute(p) ? p : resolve(dir, p));

  const theme = {
    bg: '#101114', surface: '#1B1D22', accent: '#C8CDD6', highlight: '#9AA3B2',
    text: '#FFFFFF', muted: '#B5BAC4', ...(raw.theme || {}),
  };
  const faces = [], files = new Set();
  const displayStack = fontStack(raw.theme?.fonts?.display, dir, faces, files);
  const bodyStack = fontStack(raw.theme?.fonts?.body, dir, faces, files);

  // pace multiplies card durations, hold min/max and fade timings. It never touches footage speed.
  const pace = raw.pace ?? 1;
  const chapters = (raw.chapters || []).map((c) => {
    if (typeof c === 'string') c = { name: c };
    return { ...c, title: c.title ?? titleCase(c.name), ...(c.cardDur != null && { cardDur: c.cardDur * pace }) };
  });
  if (!chapters.length) throw new Error('config: chapters is empty');

  const cards = {};
  const cardDefaults = { kicker: '', sub: '', dur: 3 };
  if (raw.cards?.title) cards['title-card'] = { ...cardDefaults, ...raw.cards.title };
  for (const s of raw.cards?.switches || []) {
    const id = s.id || `switch-${s.before}`;
    cards[id] = { ...cardDefaults, dur: 2.5, ...s };
  }
  if (raw.cards?.end) cards['end-card'] = { ...cardDefaults, ...raw.cards.end };
  for (const c of Object.values(cards)) c.dur = r3(c.dur * pace);

  // Output size: a format preset, overridable by explicit width/height. The footage stays 16:9;
  // square follows the spotlit element (see compose.mjs viewFor).
  const FORMATS = { landscape: [1280, 720], square: [1080, 1080] };
  const format = raw.format || 'landscape';
  if (format === 'vertical') throw new Error('config: format "vertical" is not supported: 16:9 footage cropped to 9:16 cannot keep wide marks readable. Use "landscape" or "square".');
  if (!FORMATS[format]) throw new Error(`config: unknown format "${format}" (landscape or square)`);

  const speed = { travel: 2, proof: 1, rampMs: 250, ...(raw.speed || {}) };
  for (const c of [speed, ...chapters.map((ch) => ch.speed || {})]) {
    for (const k of ['travel', 'proof']) if (c[k] != null && !(c[k] >= 0.1 && c[k] <= 4)) throw new Error(`config: speed.${k} must be between 0.1 and 4`);
  }

  return {
    name: raw.name || 'demo',
    takes: abs(raw.takes),
    out: abs(raw.out || './compose'),
    // env, then config, then PATH. Any build works; without drawtext (libfreetype) check.mjs
    // tiles lose their captions and it says so.
    ffmpeg: process.env.FFMPEG || raw.ffmpeg || 'ffmpeg',
    ffprobe: process.env.FFPROBE || raw.ffprobe || 'ffprobe',
    format,
    width: raw.width || FORMATS[format][0],
    height: raw.height || FORMATS[format][1],
    pace, speed,
    targetDuration: raw.targetDuration,
    chapterCardDur: r3((raw.chapterCardDur ?? 2.0) * pace),
    defaultPersona: raw.defaultPersona || '',
    fadeLead: r3((raw.fadeLead ?? 0.25) * pace), // spotlight fades in this long before t
    deadHold: raw.deadHold ?? 2.0,           // freezes longer than this get trimmed
    hold: Object.fromEntries(Object.entries({ min: 1.5, max: 2.2, ...(raw.hold || {}) }).map(([k, v]) => [k, v * pace])),
    layout: { safeMargin: 64, labelHeight: 48, labelGap: 14, maxLabelWords: 6, ...(raw.layout || {}) },
    check: { litRatio: 0.80, dimRatio: 0.62, contentSd: 8, driftMax: 12, ...(raw.check || {}) },
    theme, displayStack, bodyStack, fontFaces: faces, fontFiles: [...files],
    accentGlow: hexToRgba(theme.accent, 0.40),
    accentEdge: hexToRgba(theme.accent, 0.55),
    scrim: raw.scrim || 'rgba(0,0,0,0.60)',
    chapters, cards,
  };
}

// Full ordered segment list: title card, chapters with their switch cards, end card.
export function segmentNames(C) {
  const out = [];
  if (C.cards['title-card']) out.push('title-card');
  for (const ch of C.chapters) {
    for (const [id, c] of Object.entries(C.cards)) if (c.before === ch.name) out.push(id);
    out.push(ch.name);
  }
  if (C.cards['end-card']) out.push('end-card');
  return out;
}

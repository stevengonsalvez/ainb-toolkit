// Config loading and defaults. Every app-specific value lives in the config file;
// the defaults below are deliberately brand-neutral placeholders.
import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, resolve, isAbsolute, basename } from 'node:path';

export const r3 = (x) => Math.round(x * 1000) / 1000;
export const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/'/g, '&#39;');

// capture writes either <takes>/<chapter>-events.json or <takes>/<chapter>/events.json; with
// `optional`, a chapter with no take (slides, or only borrowed beats) gives null instead of a throw
export function eventsPath(takes, name, optional = false) {
  const flat = `${takes}/${name}-events.json`;
  if (existsSync(flat)) return flat;
  const nested = `${takes}/${name}/events.json`;
  if (existsSync(nested)) return nested;
  if (optional) return null;
  throw new Error(`${name}: no events.json (looked at ${flat} and ${nested})`);
}

// Luma frames of a video or image scaled to w x h: `len` seconds from `t` (every frame, or `fps`
// per second), or the single frame at `t` (or of an image) when `len` is unset. The one ffmpeg
// frame reader for compose.mjs and check.mjs; argv, never a shell string.
// `crop` [x, y, w, h] in the file's pixels is applied before the scale.
export function grayFrames(ffmpeg, file, { t, len, fps, w = 160, h = 90, crop } = {}) {
  const buf = execFileSync(ffmpeg, ['-nostdin', '-loglevel', 'error', ...(t == null ? [] : ['-ss', String(t)]), '-i', file,
    ...(len == null ? ['-frames:v', '1'] : ['-t', String(len)]),
    '-vf', `${fps ? `fps=${fps},` : ''}${crop ? `crop=${crop[2]}:${crop[3]}:${crop[0]}:${crop[1]},` : ''}scale=${w}:${h},format=gray`, '-f', 'rawvideo', '-'], { maxBuffer: 1 << 28 });
  const fw = w * h;
  return { n: Math.floor(buf.length / fw), at: (k) => buf.subarray(k * fw, (k + 1) * fw) };
}
// mean absolute luma difference between two such frames
export function mad(a, b) {
  let d = 0;
  for (let p = 0; p < a.length; p++) d += Math.abs(a[p] - b[p]);
  return d / a.length;
}

const ffbin = (name) => process.env[name.toUpperCase()] || (existsSync(`/usr/bin/${name}`) ? `/usr/bin/${name}` : name);

const titleCase = (s) => s.replace(/[-_]+/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());

export function hexToRgb(hex) {
  const h = hex.replace('#', '');
  const n = h.length === 3 ? h.split('').map((c) => c + c).join('') : h;
  return [0, 2, 4].map((i) => parseInt(n.slice(i, i + 2), 16));
}
export const hexToRgba = (hex, a) => `rgba(${hexToRgb(hex).join(',')},${a})`;

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

  // Output size. Everything is laid out in a design space (1280x720 landscape, 1080x1080 square,
  // 1080x1920 vertical) and scaled to the canvas with CSS zoom, so text and geometry rasterise at
  // master size rather than being upscaled. quality "final" (default) is the master: 2560x1440,
  // 1440x1440 or 1080x1920 at 60fps, so a 2x take enters at native pixels. "draft" is 1280x720,
  // 1080x1080 or 720x1280 at 30fps for iteration.
  // Explicit width/height override the canvas; the design space keeps the format's height.
  const DESIGN = { landscape: [1280, 720], square: [1080, 1080], vertical: [1080, 1920] };
  const MASTER = { landscape: [2560, 1440], square: [1440, 1440], vertical: [1080, 1920] };
  const DRAFT = { ...DESIGN, vertical: [720, 1280] };
  const format = raw.format || 'landscape';
  if (!DESIGN[format]) throw new Error(`config: unknown format "${format}" (landscape, square or vertical)`);
  const quality = raw.quality || 'final';
  if (!['final', 'draft'].includes(quality)) throw new Error(`config: unknown quality "${quality}" (final or draft)`);
  const [cw0, ch0] = quality === 'draft' ? DRAFT[format] : MASTER[format];
  const width = raw.width || (raw.height ? Math.round(raw.height * cw0 / ch0) : cw0);
  const height = raw.height || (raw.width ? Math.round(raw.width * ch0 / cw0) : ch0);
  if (width % 2 || height % 2) throw new Error('config: width and height must be even (4:2:0 delivery)');
  const zoom = height / DESIGN[format][1];

  // The framed window: footage in a rounded window with a soft shadow on a backdrop from the theme.
  // `frame: false` is full-bleed footage, as before. Lengths are design px.
  const frame = raw.frame === false ? null : { style: 'window', padding: 80, radius: 24, shadow: 1, backdrop: 'glow', grain: 0.045, tilt: 9, ...(raw.frame || {}) };
  if (frame) {
    if (frame.style !== 'window') throw new Error(`config: frame.style "${frame.style}" is not a style (window)`);
    if (!['glow', 'gradient', 'solid'].includes(frame.backdrop)) throw new Error(`config: frame.backdrop "${frame.backdrop}" (glow, gradient or solid)`);
    if (!(frame.padding >= 0 && frame.padding < DESIGN[format][0] / 4)) throw new Error('config: frame.padding must be between 0 and a quarter of the design width');
  }
  // Spotlight: feathered cut-out. It glides to the next mark when that one lights within `glide`
  // seconds; otherwise it fades out and irises in on the next. `blur` softens what it dims.
  const spotlight = { feather: 18, glide: 2.5, sweep: true, blur: 2, ...(raw.spotlight || {}) };
  if (!(spotlight.feather >= 0 && spotlight.feather <= 24)) throw new Error('config: spotlight.feather must be 0-24 (design px): the still-check reads the dim ring 34px out');
  // Seams between segments: a blur crossfade, and a push with motion blur ("whip") where one
  // chapter hands over to the next chapter or a switch card. Seconds; false = hard cuts.
  const transitions = raw.transitions === false ? null : { blur: 0.5, whip: 0.4, ...(raw.transitions || {}) };
  for (const [k, v] of Object.entries(transitions || {})) {
    if (!['blur', 'whip'].includes(k)) throw new Error(`config: transitions.${k} is not a transition (blur, whip)`);
    if (!(typeof v === 'number' && v >= 0 && v <= 1)) throw new Error(`config: transitions.${k} must be seconds between 0 and 1`);
  }

  // cut "beats": one still per mark, held for its narration line plus beats.pad, jump cuts, silent
  // cards of beats.cardHold, slide and split beats (chapters[].beats). "continuous" is the footage.
  const cut = raw.cut ?? 'continuous';
  if (!['continuous', 'beats'].includes(cut)) throw new Error(`config: cut must be "continuous" or "beats", not "${cut}"`);
  const beats = { pad: 0.6, lead: 0, cardHold: 2.5, hold: 3, fade: 0, min: 3, max: 6, lineMax: 7, ...(raw.beats || {}) };
  for (const [k, v] of Object.entries(beats)) {
    if (!['pad', 'lead', 'cardHold', 'hold', 'fade', 'min', 'max', 'lineMax'].includes(k)) throw new Error(`config: beats.${k} is not a setting`);
    if (!(typeof v === 'number' && Number.isFinite(v) && v >= 0)) throw new Error(`config: beats.${k} must be a number of seconds >= 0`);
  }
  if (!(Number.isInteger(beats.fade) && beats.fade <= 4)) throw new Error('config: beats.fade is a micro-fade in whole frames, 0 (hard cut) to 4');
  const SLIDES = { title: ['title'], end: ['title'], tiles: ['tiles'], pricing: ['tiers'], steps: ['steps'], devices: [] };
  const strs = (x) => Array.isArray(x) && x.length && x.every((v) => typeof v === 'string');
  for (const ch of chapters) {
    if (ch.beats && !(Array.isArray(ch.beats) && ch.beats.length)) throw new Error(`config: ${ch.name}: beats must be a list of at least one beat`);
    for (const [i, b] of (ch.beats || []).entries()) {
      const at = `config: ${ch.name} beat ${i}`;
      const kinds = ['mark', 'index', 'slide', 'split'].filter((k) => b[k] != null);
      if (kinds.length !== 1) throw new Error(`${at} needs exactly one of mark, index, slide or split`);
      if (b.index != null && !(Number.isInteger(b.index) && b.index >= 0)) throw new Error(`${at}: index must be a whole number >= 0`);
      if (b.take != null && !(typeof b.take === 'string' && b.take && (b.mark != null || b.index != null))) throw new Error(`${at}: take names another take in takes, with the mark or index to show from it`);
      if (b.split != null && !(Array.isArray(b.split) && b.split.length === 2)) throw new Error(`${at}: split takes two earlier beats, e.g. ["2.3", "2.4"]`);
      if (b.slide == null) continue;
      if (!SLIDES[b.slide]) throw new Error(`${at}: slide "${b.slide}" is not one of ${Object.keys(SLIDES).join(', ')}`);
      for (const k of SLIDES[b.slide]) if (b[k] == null) throw new Error(`${at}: a ${b.slide} slide needs ${k}`);
      if (b.slide === 'tiles' && !strs(b.tiles)) throw new Error(`${at}: tiles is a list of words`);
      if (b.slide === 'steps' && !strs(b.steps)) throw new Error(`${at}: steps is a list of words`);
      if (b.slide === 'pricing' && !(Array.isArray(b.tiers) && b.tiers.length && b.tiers.every((t) => typeof t?.name === 'string' && (t.points == null || strs(t.points)))))
        throw new Error(`${at}: tiers is a list of { name, price, points: [...], highlight }`);
      if (b.slide === 'devices' && !['phone', 'tablet', 'web'].some((k) => b[k] != null)) throw new Error(`${at}: a devices slide needs at least one of web, tablet, phone`);
      for (const k of ['phone', 'tablet', 'web']) if (b[k] != null) { b[k] = abs(b[k]); if (!existsSync(b[k])) throw new Error(`${at}: ${k} image not found: ${b[k]}`); }
    }
  }
  if (cut !== 'beats' && chapters.some((c) => c.beats)) throw new Error('config: chapters[].beats needs "cut": "beats"');

  // Proof windows always play at 1x: the spotlight timing and the still-check both assume it.
  const speed = { travel: 2, rampMs: 250, ...(raw.speed || {}) };
  for (const c of [speed, ...chapters.map((ch) => ch.speed || {})]) {
    for (const k of Object.keys(c)) if (!['travel', 'rampMs'].includes(k)) throw new Error(`config: speed.${k} is not a setting (speed takes travel and rampMs; proof windows always play at 1x)`);
    if (c.travel != null && !(c.travel >= 0.1 && c.travel <= 4)) throw new Error('config: speed.travel must be between 0.1 and 4');
    if (c.rampMs != null && !(typeof c.rampMs === 'number' && c.rampMs >= 0)) throw new Error('config: speed.rampMs must be a number >= 0');
  }

  return {
    name: raw.name || 'demo',
    takes: abs(raw.takes),
    out: abs(raw.out || './compose'),
    // config, then $FFMPEG/$FFPROBE, then the distro build at /usr/bin, then PATH (Homebrew on
    // macOS, where /usr/bin is read-only). Any build works; without drawtext (libfreetype)
    // check.mjs tiles lose their captions and it says so.
    ffmpeg: raw.ffmpeg || ffbin('ffmpeg'),
    ffprobe: raw.ffprobe || ffbin('ffprobe'),
    format, quality, frame, spotlight, transitions,
    // Output frame rate: render.sh passes it to hyperframes, concat.sh reads the PNGs at it,
    // check.mjs maps times to frames with it, and compose retimes footage onto its grid. Set by
    // quality, not a setting of its own: 60 for final (a 60fps take plays every frame at 1x), 30 for draft.
    fps: quality === 'draft' ? 30 : 60,
    width, height, zoom,
    // design space: what compose lays out and check measures in
    dw: Math.round(width / zoom), dh: DESIGN[format][1],
    // hyperframes capture workers. Auto picks 1 at 1440p (its calibration sees a slow frame);
    // 4 measured 3.4x faster on 8 cores.
    workers: raw.workers ?? 4,
    crf: raw.crf ?? 16,
    pace, speed, cut, beats,
    // each chapter also as its own mp4, own loudness pass (audio.mjs); on by default in beat mode
    clips: raw.clips ?? cut === 'beats',
    targetDuration: raw.targetDuration,
    chapterCardDur: r3((raw.chapterCardDur ?? 2.0) * pace),
    defaultPersona: raw.defaultPersona || '',
    fadeLead: r3((raw.fadeLead ?? 0.25) * pace), // spotlight fades in this long before t, or once the zoom settles
    deadHold: raw.deadHold ?? 2.0,           // freezes longer than this get trimmed
    hold: Object.fromEntries(Object.entries({ min: 1.5, max: 2.2, ...(raw.hold || {}) }).map(([k, v]) => [k, v * pace])),
    layout: { safeMargin: 64, labelHeight: 48, labelGap: 14, maxLabelWords: 6, ...(raw.layout || {}) },
    check: { litRatio: 0.80, dimRatio: 0.62, contentSd: 8, driftMax: 12, alignMax: 7, glideStep: 0.2, calloutMin: 12, cutEdge: 0.9, ...(raw.check || {}) },
    theme, displayStack, bodyStack, fontFaces: faces, fontFiles: [...files],
    accentGlow: hexToRgba(theme.accent, 0.40),
    accentEdge: hexToRgba(theme.accent, 0.55),
    scrim: raw.scrim || 'rgba(0,0,0,0.60)',
    chapters, cards,
    audio: raw.audio ?? {}, configDir: dir,   // read by audio.mjs
  };
}

// HyperFrames shows a clip at time p when start <= p < start + duration. Back-to-back clips laid
// out in whole frames [f0, f1) are written as start = f0/fps rounded DOWN to the microsecond and
// duration ending 1us before f1/fps (also rounded down), so frame f1 (p = f1/fps) is at or past the
// next clip's start and past this one's end even after start + duration is added in floating
// point (7.866666 + 4.483334 came to 12.350000000000001, past p = 12.35): exactly one clip on every
// frame. Rounding start and duration on their own (to the ms, one up, one down) left a blank frame
// at about one hard cut in five. spans: [[f0, f1], ...] -> attributes.
// A chapter's beats in order, each filmed one resolved to its spot: by id ("mark": "4.2") or index
// ({ "index": 2 }) in the chapter's own take, or in another one named by "take" (a persona switch
// filmed as its own take, played between this chapter's beats with no seam). A bare number is an
// index only in a take whose marks have no ids, where it cannot be mistaken for one. Splits point
// at two earlier filmed beats. spotsOf(take) lists a take's spots ({ i, m: { id } }); each beat
// gets its own copy, so a label set here does not reach that take's own chapter.
export function resolveBeats(cfg, spotsOf) {
  const seen = {};
  const take = (name) => seen[name] ??= (() => {
    const spots = spotsOf(name), ids = spots.map((s) => s.m.id).filter((x) => x != null);
    const dup = ids.filter((x, i) => ids.indexOf(x) !== i);
    if (dup.length) throw new Error(`${cfg.name}: take ${name} has more than one mark with id ${[...new Set(dup)].join(', ')}`);
    return { spots, ids, known: `marks 0-${spots.length - 1} by index${ids.length ? `, ids ${ids.join(', ')}` : ', no ids'}` };
  })();
  const items = (cfg.beats || take(cfg.name).spots.map((s) => ({ index: s.i }))).map((b, i) => ({ ...b, i }));
  for (const b of items) {
    if (b.mark == null && b.index == null) continue;
    b.src = b.take ?? cfg.name;
    const { spots, ids, known } = take(b.src), where = b.take ? `take ${b.take}` : 'the take';
    if (typeof b.mark === 'number' && ids.length) throw new Error(`${cfg.name} beat ${b.i}: "mark": ${b.mark} in a take whose marks have ids; name it by id, or by index with { "index": ${b.mark} } (${known})`);
    const idx = b.index ?? (typeof b.mark === 'number' ? b.mark : null);
    const spot = idx != null ? spots[idx] : spots.find((s) => s.m.id === String(b.mark));
    if (!spot) throw new Error(`${cfg.name} beat ${b.i}: no mark ${JSON.stringify(b.mark ?? b.index)} in ${where} (${known})`);
    b.spot = { ...spot };
  }
  for (const b of items) b.id = String(b.id ?? (b.spot ? b.spot.m.id ?? (b.take ? `${b.take}:${b.spot.i}` : b.spot.i) : `b${b.i}`));
  // ids are unique per take, not per chapter: a borrowed mark can share one with this take's own,
  // and a split naming it would take whichever came first
  const ids = items.map((b) => b.id), twice = ids.filter((x, i) => ids.indexOf(x) !== i);
  if (twice.length) throw new Error(`${cfg.name}: two beats have id ${[...new Set(twice)].join(', ')}; give one its own "id"`);
  for (const b of items) if (b.split) {
    b.parts = b.split.map((ref) => items.find((x) => x.id === String(ref) && x.i < b.i && x.spot));
    if (b.parts.some((x) => !x)) throw new Error(`${cfg.name} beat ${b.i}: split ${JSON.stringify(b.split)} must name two earlier filmed beats`);
  }
  return items;
}

export function clipSpans(spans, fps) {
  const us = (f) => Math.floor(f * 1e6 / fps + 1e-6);
  return spans.map(([f0, f1]) => ({ start: (us(f0) / 1e6).toFixed(6), duration: ((us(f1) - us(f0) - 1) / 1e6).toFixed(6) }));
}

// Frames in a video, counted from its packets (exact for the packed segments).
export function frameCount(C, file) {
  return +execFileSync(C.ffprobe, ['-v', 'error', '-count_packets', '-select_streams', 'v:0', '-show_entries', 'stream=nb_read_packets', '-of', 'csv=p=0', file]).toString();
}
// The seam into each segment: blur crossfade, or whip where a chapter hands over to another
// chapter or a switch card. Duration snapped to whole frames; 0 with transitions off.
export function seams(C) {
  const names = segmentNames(C), isCh = (n) => !C.cards[n];
  const snap = (d) => Math.round(d * C.fps) / C.fps;
  return names.map((n, i) => {
    if (!i || !C.transitions) return { kind: 'cut', dur: 0 };
    const kind = isCh(names[i - 1]) && (isCh(n) || C.cards[n]?.before) ? 'whip' : 'blur';
    return { kind, dur: snap(C.transitions[kind]) };
  });
}
// Where the footage "screen" sits: inside the framed window (padded, scaled by ws) or full
// bleed. Design px, plus the same rect in canvas px for reading rendered frames.
// sw x sh is the screen's own size in design px (what compose lays spotlights and labels out in,
// and check.mjs measures in), shown at ws inside the window. Landscape and square show the whole
// design canvas, scaled into the padded window. Vertical has a window of its own between the
// headline band and the caption band (VERTICAL), at 1:1, and the crop follows the target in it.
export const VERTICAL = { top: 520, height: 820, safe: { top: 220, bottom: 420, left: 60, right: 120 } };
export function screenRect(C) {
  const z = C.zoom;
  if (C.format === 'vertical') {
    const pad = C.frame ? 40 : 0, sw = C.dw - 2 * pad, sh = VERTICAL.height, padY = VERTICAL.top;
    return { pad, padY, ws: 1, sw, sh, canvas: [Math.round(pad * z), Math.round(padY * z), Math.round(sw * z), Math.round(sh * z)] };
  }
  const pad = C.frame ? C.frame.padding : 0, ws = (C.dw - 2 * pad) / C.dw, padY = (C.dh - C.dh * ws) / 2;
  return { pad, padY, ws, sw: C.dw, sh: C.dh, canvas: [Math.round(pad * z), Math.round(padY * z), Math.round(C.dw * ws * z), Math.round(C.dh * ws * z)] };
}
// Head and tail transitions of one segment.
export function seamsOf(C, name) {
  const names = segmentNames(C), all = seams(C), i = names.indexOf(name);
  return { in: all[i] ?? { kind: 'cut', dur: 0 }, out: all[i + 1] ?? { kind: 'cut', dur: 0 } };
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

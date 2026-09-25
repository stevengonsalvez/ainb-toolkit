---
name: capture
description: Film a real web app, logged in or public, SPA or multi-page, as clean re-recordable product footage. Drives real clicks through Playwright, records via CDP screencast, does sharp in-browser camera zooms, and emits per-chapter mp4 plus an events.json (timed marks with element rects and camera box) for a compositor. Use when asked to "record a product demo", "film the app", "capture a walkthrough", "screen-record a user flow", "make demo footage", "record the feature in the browser", or to re-shoot a demo chapter after the UI changed. Capture only; for spotlights, callouts, chapter cards, transitions and final assembly hand the output to demo:compose, which renders it through HyperFrames.
---

# demo:capture

Capture real product footage from a live app. Compose it elsewhere.

Pairs with **demo:compose** (the sibling skill in this plugin): it takes the take directory this
skill writes, plus one config carrying the brand and copy, and produces the finished cut.

```
beats.mjs ──▶ run.mjs ──▶ capture.mjs ──▶ <out>/<chapter>/ frames + cfr/ + events.json
                              │                         │
                        mintState (real login)     encode.sh ──▶ <chapter>.mp4
                                                        │
                                          montage.sh (grade the take)  ──▶ demo:compose
```

## Use / do not use

- USE for: authenticated SPA flows, public multi-page apps, feature walkthroughs, re-shooting one chapter after a UI change.
- DO NOT use for annotation, spotlight, labels, chapter cards, transitions, music, final cut. That is `demo:compose`, which renders through HyperFrames (`hyperframes`, `hyperframes-core`, `hyperframes-keyframes`, `hyperframes-animation`). HyperFrames renders video FROM HTML and cannot drive an authenticated SPA, which is why capture is a separate step.
- Keep footage free of annotations. Annotations then stay re-timeable without re-recording. The only things burned in are the synthetic cursor and click ripple.

## Run

Skill dir: this skill's own directory, referred to below as `$SKILL_DIR`. It pins `@playwright/test@1.62.0`.
First run only, from that directory: `npm ci`, then
`PLAYWRIGHT_BROWSERS_PATH="$PW" npx playwright install chromium`, where `$PW` is a writable directory you keep
(for example `~/.local/pw-browsers`). Neither `node_modules` nor the browsers ship with the plugin.

```bash
cd "$SKILL_DIR"
npm run check                                   # self-check, ~15s, no app needed
node scripts/run.mjs /path/to/beats.mjs [chapter ...]   # capture + encode each chapter
scripts/montage.sh <out>/<chapter>.mp4          # 4x3 contact sheet; LOOK at it
```

- Browsers: Playwright reads `PLAYWRIGHT_BROWSERS_PATH` when it is set and otherwise uses its own default (`~/.cache/ms-playwright` on Linux). Export `PLAYWRIGHT_BROWSERS_PATH="$PW"` in the shell that runs the rig and keep that directory stable; the scripts never set it for you. The installed revision must match `node_modules/playwright-core/browsers.json` (1.62.0 wants chromium 1234). On mismatch: `PLAYWRIGHT_BROWSERS_PATH="$PW" npx playwright install chromium`. Prefer a directory you control over `~/.cache/ms-playwright`, which other tooling clears: measured wiped twice on one machine with 34G free, so not disk pressure.
- Write beats files and `out` under a scratch dir, never in a project repo.
- After every take: open the montage. Check head is not blank/black, tail is not a splash, zoom frames are sharp.

## Beats file

Values below are one app's; only `base`, `out` and `chapters` are required.

```js
export default {
  base: 'http://localhost:5173',
  out: '/scratch/takes',
  state: '/scratch/session-state.json',        // only with `login`: reused if it still gets past
                                               // the login page, else re-minted
  viewport: { width: 1280, height: 720 },      // optional, default 1280x720
  localStorage: { someConsentKey: 'true' },    // optional, set before every document
  login: { email: 'demo@example.test', password: '…' },  // OMIT for an app with no login
  pace: 1,                                     // optional filming pace, see below
  cursor: { speed: 1200, hidden: false },      // optional, see below
  chapters: [{ name: 'home-to-detail', pace: 1.3, cursor: { hidden: true },  // per-chapter overrides
               beats: [ /* ... */ ] }],
};
```

`login` overrides, with the defaults the rig ships: `loginPath '/login'`, `emailSel '#email'`,
`passwordSel '#password'`, `submitSel 'role=button[name=/^(log in|sign in)$/i]'`,
`dismissSel '#rcc-decline-button'` (the decline button id react-cookie-consent renders). Set whichever the app
needs.

`login.loggedInSel` (optional): a selector for an element that exists only when logged in, such
as an avatar menu. Without it a saved session counts as valid unless the probe (`probe`, default
`/home`) lands on `loginPath`, so an app that sends logged-out visitors to a landing page instead
reuses a dead session and films that page. With it set, the session is reused only if the element
becomes visible within 5s, and `mintState` also waits for it after submitting the form.

Drop `login` and `state` entirely when the app is public: the rig then films straight from
`base` with a fresh context.

A beat is an object; keys run in this fixed order within one beat:

| key | value | effect |
|-----|-------|--------|
| `name` | string | used in error messages |
| `goto` | path | navigate. FIRST beat of a chapter must be a `goto` |
| `click` | scoped selector | glide cursor to target, click |
| `ready` | selector | after goto/click/type, wait until visible (preferred) |
| `readyCap` | ms | cap for `ready`, or for network-quiet fallback (8000) |
| `settle` | ms | extra wait after ready/quiet, default 400 |
| `expectPath` | string path or RegExp | assert pathname; throws and fails the take. A string matches that path or anything below it: `/reports` accepts `/reports/7`, never `/reports-archive` |
| `scroll` | px | smooth `scrollBy` |
| `type` | `{into, text, cps=12}` | glide to the field, click it, type `text` key by key at `cps` characters per second (`type()`, never `fill()`, so the viewer sees it typed), then wait like a click: `ready`, else network quiet, then `settle` |
| `zoom` | `{on, scale=2, ms=700}` | ease camera onto element centre |
| `wide` | `true` or ms | ease camera back to full frame |
| `mark` | `{label, on}` | push an event into events.json (after zoom/wide) |
| `hold` | ms | keep filming with cursor drift |

Order: goto, click, wait (ready or network quiet), settle, expectPath, [filming starts here on beat 0], scroll, type, zoom, wide, mark, hold.

## Filming pace

How fast things happen **in front of the camera**. Changing it means re-filming. To re-pace
footage you already have (speed up navigation, stretch holds) use demo:compose's playback
controls (`speed`, `pace`, `targetDuration`) instead: no re-shoot.

- `pace` (default 1): multiplies every filmed duration in the take: zoom and wide `ms`, `hold`,
  `settle`, the pause before a click, the end-of-take hold, and cursor glides. `2` films
  everything twice as slowly, `0.7` brisker. Set it on the beats file, override per chapter.
  Page load waits (`ready`, network quiet) are the app's own time and are not scaled.
- `cursor.speed` (px/s, optional): glide the pointer at a constant speed, so a long move takes
  longer than a short one. Unset keeps the rig's original feel: every click glide takes 300ms
  and every re-centre before a hold 200ms, whatever the distance (one `mouse.move` step is one
  rendered frame, measured 16.7ms). `pace` scales either.
- `cursor.hidden` (default false): films no pointer and no click ripple. The pointer element
  is still there at near-zero opacity and still drifts, because that drift is what keeps the
  screencast emitting during a hold (fact 1). Measured: a hidden-cursor take still produced
  frames through a 1.5s hold.
- `type.cps` sets typing speed per beat and is not scaled by `pace`.

Merge rule: a chapter's `pace` replaces the file's; a chapter's `cursor` keys override the
file's `cursor` keys one by one.

## Measured facts (do not re-learn these)

1. **Screencast emits only on repaint.** A settled page produces almost no frames. The synthetic cursor drifting during `hold` is load-bearing: a 7.5s hold gave 1 frame without it, 244 with it. Never remove the drift.
2. **Screencast always emits at CSS-viewport size.** deviceScaleFactor 1, 2, 3 and maxWidth 2560, 3840 all produced 1280x720 JPEGs; `maxWidth` only clamps down. "Record at 2x and crop later" is impossible.
3. **Zoom must happen in the browser.** Same element, four approaches:
   - ffmpeg crop + upscale in post: visibly soft text.
   - CSS `transform: scale()` on `<html>`: sharp, but root becomes containing block for `position:fixed`; fixed bottom nav landed mid-frame.
   - `Emulation.setPageScaleFactor`: sharp, but zooms about the visual-viewport origin; centring on a target was wrong.
   - `Emulation.setDeviceMetricsOverride` with `viewport: {x, y, width, height, scale}`: sharp, correctly framed, fixed chrome behaves. **This is the camera.** Crispness is decided at capture time; no editor or compositor recovers it.
   - Its `viewport` x/y are **document**-relative, while `getBoundingClientRect` is viewport-relative. After a 520px scroll, `y: 0` filmed the blank page top; `y: 520` framed the target. The rig adds the scroll (read once while unzoomed) and `wide` clears the override. `npm run check` asserts a scroll-then-zoom lands on its target (luma 255 fixed, 101 with the offset removed).
   - While zoomed, the drifting cursor must stay inside the camera box. Drifting outside it repaints nothing visible, the screencast stops emitting, and the mp4 froze on the pre-zoom frame for ~2.4s.
4. **Never select by bare text.** Measured: a bare `text=<nav label>` matched an article headline elsewhere on the page and navigated away. Scope every selector to its container (`<nav-selector> >> text=<label>`, e.g. `nav.fixed.bottom-0 >> text=REPORTS` or `header nav >> text=Fares`) and set `expectPath` on every navigating beat so a mis-click fails the take instead of filming the wrong screen.
5. **Nav bars are context-dependent.** Measured on one app: after clicking one nav item, another item was gone from the nav. Targets are resolved fresh per beat; never cache handles across beats.
6. **`addInitScript` overlays survive SPA route changes** (cursor verified present after three client-side navigations).
7. **Login: never hand-write a token into storageState.** It fails silently and films the login page. `mintState` drives the real form and throws unless the final pathname has left `loginPath`. Quirks it already handles, each found on a real app: an `#email` field that is `input[type=text]` rather than `type=email`, a cookie modal covering the submit button (dismissed via `dismissSel` first), and controlled React inputs that need `type()` rather than `fill()`.
8. **ffmpeg is `$FFMPEG` (and `$FFPROBE`), else the one on PATH.** Capture only encodes and tiles, which any build does. Some PATH builds (a measured Homebrew one) lack drawtext; demo:compose's still-check then writes its contact tiles without captions and still gives its verdict. Point `FFMPEG` at a full build such as the distro's `/usr/bin/ffmpeg` for captions.
9. **Browsers live in `$PLAYWRIGHT_BROWSERS_PATH` when set** (see Run).
10. **The overlay mounts in the top frame only.** Init scripts run in every frame; before this, a page with an iframe filmed a second cursor inside it. Seeding `localStorage` is skipped where storage throws (sandboxed documents) instead of aborting the cursor.

## Defects the rig already handles

- **Black/white head frames**: screencast used to start before first paint (white about:blank + ~85 black splash frames). Now filming starts only after beat 0's goto is ready + settled, and the cursor is parked before the first frame. `npm run check` asserts frame-0 luma is neither blank nor black; moving `startScreencast` before the goto makes it fail with `luma 255`.
- **Chapter ending on a splash**: fixed settle delays were too short. After goto/click the rig waits for `ready`, else network quiet (no request in flight for 500ms, capped at 8s; websockets/SSE ignored). Long-poll pages always hit the cap and warn: give those beats a `ready` selector.

## Handoff contract: events.json

One per chapter, written next to the frames at `<out>/<chapter>/events.json`; `<chapter>.mp4` sits beside the chapter dir at `<out>/<chapter>.mp4`. (`demo:compose` also accepts a flattened `<out>/<chapter>-events.json`.)

```json
{
  "chapter": "home-to-reports",
  "viewport": { "width": 1280, "height": 720 },
  "dur": 10.85,
  "frames": 477,
  "events": [
    { "t": 2.205, "kind": "mark", "label": "bottom nav",
      "rect": { "x": 0, "y": 655, "w": 1265, "h": 65 },
      "cam":  { "x": 312.5, "y": 360, "w": 640, "h": 360, "s": 2 } }
  ]
}
```

- `dur`: seconds, first to last captured frame. The mp4 has `ceil(dur * 30) + 1` frames: capture.mjs resamples to 30fps itself (frame k shows the last frame captured at or before k/30) and writes `cfr/` as hard links, which `encode.sh` encodes as a plain image sequence. It used to hand ffmpeg a concat list of per-frame durations instead; measured on a 4.4s take with zoom glides, that ran 0.17s short on ffmpeg 6.1 and 0.73s short on ffmpeg 8.1 (an 11.1s ferry take came out 8.9s long), putting marks late by growing amounts. `npm run check` now asserts the mp4 length matches the take.
- `frames`: captured JPEG count (variable rate; the mp4 is resampled to 30fps).
- `t`: seconds from the first frame, which is mp4 time 0. Taken from the wall clock: the last delivered frame lagged the screen by ~1s late in a 50s take.
- `kind`: currently always `"mark"`.
- `rect`: element box in page CSS px (layout viewport, `getBoundingClientRect`); unaffected by the camera.
- `cam`: camera at that moment. `null` = full frame. Otherwise `{x, y, w, h}` visible region in CSS px and `s` scale.
- Frame position of a rect: `screenX = (rect.x - cam.x) * cam.s`, `screenY = (rect.y - cam.y) * cam.s`, size `* cam.s`. With `cam: null` it is `rect` as-is. (Checked on the sample: `(655 - 360) * 2 = 590`, where the nav's top edge sits in the zoomed frame.)
- Downstream: `demo:compose` reads this file directly. Its `labels` default to the `label` written here, so a good capture label is a usable on-screen label. If composing by hand instead, place the mp4 as a video clip and time/position overlays from `events[]`; clip timing (`data-start`, `data-duration`, `data-media-start`) is owned by `hyperframes-core`.

## Worked examples

**Authenticated SPA with a fixed bottom nav** (verified end to end, 2026-09-14):

```js
const nav = 'nav.fixed.bottom-0';
export default {
  base: 'http://localhost:5173',
  state: '/scratch/demo/session-state.json',
  out: '/scratch/demo/takes',
  login: { email: 'demo@example.test', password: '…' },
  chapters: [{ name: 'home-to-reports', beats: [
    { name: 'land', goto: '/home', expectPath: '/home', hold: 1500 },
    { zoom: { on: nav, scale: 2, ms: 900 }, mark: { label: 'bottom nav', on: nav }, hold: 1500 },
    { wide: 700, hold: 600 },
    { name: 'reports', click: `${nav} >> text=REPORTS`, expectPath: '/reports', hold: 2000 },
  ] }],
};
```

Result: `session: minted`, then `home-to-reports: 477 frames, 10.8s, 1 marks`. Zoomed frames sharp with nav at the frame bottom; tail on the loaded page.

**Public multi-page app, no login** (verified end to end, 2026-09-21). No `login`, no `state`:

```js
export default {
  base: 'http://127.0.0.1:7744',
  out: '/scratch/ferry/takes',
  chapters: [{ name: 'fares', beats: [
    { name: 'land', goto: '/board', expectPath: '/board', ready: '#board', hold: 900 },
    { name: 'to-fares', click: 'header nav >> text=Fares', expectPath: '/fares', ready: '#fares', hold: 1400 },
    { zoom: { on: '#fares', scale: 1.5, ms: 800 }, mark: { label: 'Single and return per ticket', on: '#fares' }, hold: 1800 },
    { wide: 700, hold: 800 },
  ] }],
};
```

Result: `fares: 370 frames, 10.3s, 2 marks`. Both marks passed `demo:compose`'s still-check.

The full example, a made-up ferry operator's three-page app with its server, beats file and
compose config, ships in `../compose/examples/ferry/`. Copy it to a scratch directory, run
`node serve.mjs`, then `node scripts/run.mjs <copy>/beats.mjs` from this skill's directory.
Takes land in `<copy>/takes/`, where the compose config expects them.

## Files

- `scripts/capture.mjs`: `capture()`, `mintState()`, `ensureState()`, `checkPath()`. Edit here to change camera, cursor, waits.
- `scripts/run.mjs`: runs chapters from a beats file, encodes each.
- `scripts/encode.sh`: `cfr/` (the 30fps frame sequence) to H.264 mp4.
- `scripts/montage.sh`: contact sheet for grading a take.
- `scripts/selfcheck.mjs`: local throwaway server; asserts path guard (including a sibling path such as `/reports-archive`), zoom framing, events.json schema, non-blank head, non-splash tail, hold frame count, bare-text mis-click failing, one cursor on a page with an iframe, the cursor mounting where storage throws, every click ripple starting at scale 1, a `type` beat typing key by key with a hidden cursor still emitting frames, `pace: 2` lengthening a hold, and `loggedInSel` re-minting a dead session.

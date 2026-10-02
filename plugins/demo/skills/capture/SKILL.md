---
name: capture
description: Film a real web app, logged in or public, SPA or multi-page, as clean re-recordable product footage. Drives real clicks through Playwright and films it deterministically (every frame rendered on demand, 2560x1440 lossless at exactly 60fps, with a screencast fallback that says when it is used), with spring-physics camera zooms and cursor, real motion blur, and emits per-chapter mp4 plus an events.json (timed marks with element rects and camera box) for a compositor. Use when asked to "record a product demo", "film the app", "capture a walkthrough", "screen-record a user flow", "make demo footage", "record the feature in the browser", or to re-shoot a demo chapter after the UI changed. Capture only; for spotlights, callouts, chapter cards, transitions and final assembly hand the output to demo:compose, which renders it through HyperFrames.
---

# demo:capture

Capture real product footage from a live app. Compose it elsewhere.

Pairs with **demo:compose** (the sibling skill in this plugin): it takes the take directory this
skill writes, plus one config carrying the brand and copy, and produces the finished cut.

```
beats.mjs ──▶ run.mjs ──▶ capture.mjs ──▶ <out>/<chapter>/ cfr/ + events.json
                              │      ▲                  │
                 mintState (login)   motion.mjs     encode.sh ──▶ <chapter>.mp4
                                     (springs)
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
npm run check                                   # self-check, ~8 min, no app needed
node scripts/run.mjs /path/to/beats.mjs [chapter ...]   # capture + encode each chapter
scripts/montage.sh <out>/<chapter>.mp4          # 4x3 contact sheet; LOOK at it
```

- Browsers: Playwright reads `PLAYWRIGHT_BROWSERS_PATH` when it is set and otherwise uses its own default (`~/.cache/ms-playwright` on Linux). Export `PLAYWRIGHT_BROWSERS_PATH="$PW"` in the shell that runs the rig and keep that directory stable; the scripts never set it for you. The installed revision must match `node_modules/playwright-core/browsers.json` (1.62.0 wants chromium 1234). On mismatch: `PLAYWRIGHT_BROWSERS_PATH="$PW" npx playwright install chromium`. Prefer a directory you control over `~/.cache/ms-playwright`, which other tooling clears: measured wiped twice on one machine with 34G free, so not disk pressure.
- Write beats files and `out` under a scratch dir, never in a project repo.
- After every take: open the montage. Check head is not blank/black, tail is not a splash, zoom frames are sharp.
- `run.mjs` prints each chapter's mode, fps, density and wall time, e.g.
  `fares: deterministic 60fps x2, 659 frames, 11.0s, 2 marks, filmed in 210s`. A chapter that fell back
  says `screencast 30fps x1` and the line above it gives the cause.

## Capture modes

```
capture.mode
  deterministic (default) ──▶ beginFrame + virtual time ──▶ PNG 2560x1440 @ exactly 60fps
        │  a request holds page time: network 'auto' forces it on (see below)
        │  no beginFrame / page time stuck even when forced / hard timeout / wrong frame size
        ▼  (one warning naming the cause, chapter re-filmed from scratch)
  screencast ──────────────▶ CDP screencast ──▶ JPEG 1280x720, resampled to 30fps
```

- **deterministic**: chrome-headless-shell runs under `HeadlessExperimental.beginFrame` with
  virtual time (`pauseIfNetworkFetchesPending`). The rig renders every frame on demand at exactly
  `n / fps` of page time, so CSS animations, `requestAnimationFrame` and timers all step on the
  footage clock. Frames come back at `--force-device-scale-factor`: 2560x1440 lossless PNG for a
  1280x720 viewport. Network latency is edited out (page time stands still while a fetch is in
  flight). Camera and cursor are posed every frame by the spring solver (`motion.mjs`). Costs
  several times real time: see the measured facts.
- **Requests that hold page time.** `pauseIfNetworkFetchesPending` waits for every request in
  flight, and two kinds never let it go: a stream that stays open (SSE), and, measured, any
  dynamic `import()` of a module, even an instant one, so every code-split route. With
  `network: 'auto'` (the default) a frame that waits `unstickMs` (1.5s of wall time) is forced
  through with policy `advance`; a lazy route then costs 1.5s once and the take stays fully
  deterministic. Chrome does not say which request holds page time, so a stream is recognised by
  behaviour: a request still in flight at two stalls, or stalls on three frames running (which
  also catches a holder no request event shows). Then the rest of the chapter runs under `advance` (page time moves on regardless of the network, so a
  load shows for its wall time, roughly a tenth of its real length), the rig says so once, and
  `capture.network` / `capture.networkNote` in events.json record it. `network: 'pause'` never
  forces and falls back to screencast after `stallMs` instead; `'advance'` forces from the start.
- **Why `auto` is the default.** Almost every modern SPA lazy-loads its routes, and under strict
  `pause` each of those loads freezes page time for good: a real app's first deterministic take
  fell back to screencast on its first route change. `auto` keeps those apps deterministic, edits
  network latency out everywhere else, and only gives that up (saying so) when a stream really
  holds page time. Use `pause` when the footage must never show a load at anything but its edited
  length, and accept a screencast fallback on apps that need it.
- **screencast**: the real-time path. It is used when deterministic capture cannot proceed: the
  browser has no beginFrame, page time stops even when forced, the chapter passes `timeoutMs` of
  wall time, frames come back at the wrong size, or `network: 'pause'` meets a request that never
  finishes. The rig prints one line naming the cause, re-films the
  chapter in screencast mode and records both in `events.json` (`capture.mode`,
  `capture.requested`, `capture.fallback`). It never hands over a broken take. Set
  `capture: { mode: 'screencast' }` to choose it outright.
- **Websockets do not stall it** (measured: a page receiving a frame every 200ms of wall time
  filmed a 2s hold deterministically, and a real SPA holding a Supabase realtime websocket and a
  Vite HMR socket filmed a home, click, lazy route, zoom chapter deterministically: 7.5s in 164s,
  network still `pause`). Their messages arrive on the wall clock, which runs several times slower
  than page time here, so live pushes land sooner in the footage than they would for a real viewer.

```js
capture: {
  mode: 'deterministic',  // or 'screencast'
  dpr: 2, fps: 60,        // pixel density and frame rate (deterministic only)
  blur: { samples: 4, max: 64, spacing: 1.5, shutter: 0.5, threshold: 2 },  // on by default; false for drafts, spacing 4 in between
  network: 'auto',        // or 'pause' / 'advance': requests that hold page time, see above
  unstickMs: 1500,        // wall ms a frame waits on the network before 'auto' forces it
  stallMs: 10000,         // wall ms before falling back: page time stuck, or any wait under 'pause'
  timeoutMs: 600000,      // wall ms a chapter may take before falling back
}
```

**Motion blur** (deterministic only, ON by default). Pick the setting by how final the take is.
Measured on the ferry example (8 cores, no GPU, one take at a time):

| setting | capture time | a 5-minute demo films in | fast moves look |
|---|---|---|---|
| `capture: { blur: false }` (drafts) | about 6.5x real time | about 33 minutes | sharp, stepping frame to frame |
| `capture: { blur: { spacing: 4 } }` (middle ground) | about 17x | about 1 hour 25 minutes | smeared, faint steps up close |
| default (final takes) | about 35x | about 2 hours 55 minutes | smooth smear |

Screencast mode films at 1x. Set the option file-wide or per chapter: the footage is the same 2x,
60fps and deterministic in every case, only fast moves differ. Fact 14 has the per-chapter numbers.

How it works. Before each frame the rig steps copies of the spring solver across the shutter
(`shutter` of the frame interval, 0.5: a 180 degree shutter) and measures how far anything on
screen moves over it: the frame corner the camera moves most, or the pointer. Past `threshold`
output px, the frame is rendered enough times that the samples sit at most `spacing` (1.5) output
px apart, from `samples` (4) up to `max` (64), and averaged. Static pixels average to themselves,
so a hold stays exactly as sharp as without blur.

Two things the samples alone leave behind, both looked at on a fast ferry zoom (frame 380 of
fares, 2560x1440): at the old spacing of about 4px every glyph showed as a stack of striated
copies, and even at 1.5px each sample lands its glyph edges on whole pixels, so faint steps remain.
So a frame the camera moves also gets a gap fill: the averaged frame is mixed with copies of
itself warped (linear interpolation) by fractions of one gap's camera move: a scale about the
zoom's fixed point plus a shift, so radial for a zoom and linear for a pan. The gap it spans is the
wider of the shutter's first and last (a spring speeds up or slows down across it), and the copies
sit at most 0.5px apart at the frame corner that move moves furthest. The fixed point of a zoom,
which barely moves, stays as sharp as the samples. A frame where only the pointer moves gets no
fill.

Averaging runs in ffmpeg alongside the capture, two frames at a time; while four blurred frames
wait, rendering waits too, so temporary sub-frames stay bounded (16 MB at most on the ferry
takes). A job that fails, or exits 0 without writing its frame, stops the take at once.

Measured with the anisotropy of the glyph region (structure tensor, smaller over larger
eigenvalue: 0 is a perfect smear, the unblurred frame scores 0.84), at the same camera pose in
each take: at peak speed (frame 380) 0.226 at the old spacing without fill, 0.207 at `spacing: 4`,
0.180 at the default; slowing down near the end of the zoom (10 frames later) 0.399, 0.349 and
0.348. Looked at: the old frames show stacked copies (two clear edges per glyph while slowing
down), the default a continuous smear. The default ferry
takes peak at 47 and 64 samples per frame, at most 1.5px apart (1.94px on the fares frames that hit
the cap, gap-filled too). `events.json` records `capture.blur.spans` (blurred frame ranges) and
`maxSamples`, `maxGap`, `filled` (frames that got the gap fill) and `peakTempMB`.

Rules the deterministic path imposes, all measured:
- Page time only moves inside the rig's frame loop. Beats are fine as written; custom code
  around the rig must wait with footage time, never `page.waitForTimeout` (wall time).
- Page code that busy-waits on `Date.now()` / `performance.now()` hangs: the clock does not
  advance inside a task.
- Playwright's own timeouts are wall time, so the rig multiplies its click and goto timeouts by 10
  there, and polls `ready` on the footage clock (`readyCap` is footage ms in both modes).

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
  cursor: { speed: 1200, hidden: false, ring: '#FFFFFF', tilt: false },  // optional, see below
  capture: { mode: 'deterministic' },          // optional, see Capture modes
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
| `zoom` | `{on, scale=2, ms=700}` | move the camera onto the element centre on a spring (see Motion); the beat goes on once it has settled. `ms: 0` is a cut |
| `wide` | `true` or ms | camera back to full frame, same spring |
| `mark` | `{label, on}` | push an event into events.json (after zoom/wide) |
| `hold` | ms | keep filming. Deterministic: the pointer parks just off the lower right corner of the mark made in this beat (inside the camera box) and stays still. Screencast: the pointer drifts, which keeps frames coming (fact 1) |

Order: goto, click, wait (ready or network quiet), settle, expectPath, [filming starts here on beat 0], scroll, type, zoom, wide, mark, hold.

## Motion

Camera and pointer are springs. Constants and observable behaviour are taken from Cap's published
renderer (the open-source Screen Studio alternative, commit 97c0a45; paths cited in `motion.mjs`);
the implementation is written independently. No Cap code was copied: Cap's renderer is AGPLv3 and
this plugin is Apache-2.0, so `motion.mjs` integrates its own damped harmonic oscillator
(`m x'' = -k (x - target) - c x'`, semi-implicit Euler in 0.25ms sub-steps), and `npm run check`
checks it against the oscillator's theory: the damping ratio its overshoot implies matches each
profile's within 0.005 (camera 0.943), and it peaks within 2% of the predicted time. Under
deterministic capture the springs are solved per frame, so a re-film of the same beats moves
identically. Screencast mode keeps the older eased glide.

- **Camera**: scale and framing centre are three springs (stiffness 200, damping 40, mass 2.25;
  damping ratio 0.94, no visible overshoot). A new target keeps the current velocity, so a zoom
  that retargets mid-move bends instead of stopping and restarting. Zooming in from wide snaps the
  centre to the target first, so the zoom scales straight into it with no pan while magnified;
  going wide keeps the last centre. `zoom.ms` 700 plays these constants as they are; another value
  scales the spring's duration (stiffness / k^2, damping / k, for k = ms / 700). A 2x zoom at the
  default settles to a quarter of a pixel in 48 frames (0.8s), and the beat goes on then.
- **Pointer**: a spring (470 / 70 / 3). For a click the target jumps to the click point 500ms
  ahead of the press, the spring stiffens to 530 / 40 / 1 for the last 175ms, and the press waits
  until a forward simulation has it within half a pixel (measured: 0.5s for an 800px move). A
  move that reverses the last one inside 100ms with both legs under 0.015 of the screen diagonal
  is dropped as jitter, and a move under 1/1920 of it is not made. The real mouse follows the
  drawn pointer once per frame, so hover states match what is filmed.
- **Click feedback**: the pointer shrinks to 0.8 and back over 130ms each way; a ring of
  `cursor.ring` expands on a cubic ease-out over 0.6s while fading as (1-t)^1.5. Web Animations,
  so it runs on virtual time and every take shows it identically.
- **Tilt** (`cursor.tilt`, off by default; `true` = 0.15, or a number): the pointer leans with its
  horizontal speed, 0.4s of travel times 0.03 degrees per px times the amount, at most 20 degrees.

## Filming pace

How fast things happen **in front of the camera**. Changing it means re-filming. To re-pace
footage you already have (speed up navigation, stretch holds) use demo:compose's playback
controls (`speed`, `pace`, `targetDuration`) instead: no re-shoot.

- `pace` (default 1): multiplies every filmed duration in the take: zoom and wide `ms` (so the
  springs' durations), `hold`, `settle`, the pause before a click, the end-of-take hold, and cursor
  glides. `2` films
  everything twice as slowly, `0.7` brisker. Set it on the beats file, override per chapter.
  Page load waits (`ready`, network quiet) are the app's own time and are not scaled.
- `cursor.speed` (px/s, optional): a glide takes distance / speed, so a long move takes longer than
  a short one. Deterministic: that time (at least 250ms) replaces the 500ms click lead and scales
  the pointer spring to match. Screencast: a constant-speed glide. Unset: deterministic glides
  take 500ms whatever the distance; screencast keeps its 300ms click glide plus 220ms pause and
  200ms re-centre (one `mouse.move` step is one rendered frame, measured 16.7ms). `pace` scales
  every case.
- `cursor.hidden` (default false): films no pointer and no click feedback. The pointer element
  is still there at near-zero opacity and, in screencast mode, still drifts, because that drift is
  what keeps the screencast emitting during a hold (fact 1). Measured: a hidden-cursor screencast
  take still produced frames through a 1.5s hold.
- `cursor.ring` (CSS colour, default `#FFFFFF`): the click ring. Neutral by default, with a
  faint dark outline so it reads on a white page; set it to the brand you are filming.
- The pointer keeps its own size under a zoom and carries a soft drop shadow. The camera's
  metrics override zooms the overlay with the page (measured 1.5x bigger at scale 1.5), so
  every camera pose also sets a counter-scale (`--__demo-cs`, on the pointer and ring only), in the
  page and in an init script the next document reads when its overlay mounts: a page that loads
  while zoomed mounts the pointer at its size and position from its first frame. `npm run check`
  measures the pointer's area under a 2x zoom at 1.00x its unzoomed area deterministic and 0.88x
  screencast, and 1.00x after a click navigates while zoomed (5.14x and 5.10x before any
  counter-scale).
- `type.cps` sets typing speed per beat and is not scaled by `pace`.

Merge rule: a chapter's `pace` replaces the file's; a chapter's `cursor` keys override the
file's `cursor` keys one by one.

## Measured facts (do not re-learn these)

1. **Screencast mode: it emits only on repaint.** A settled page produces almost no frames. The synthetic cursor drifting during `hold` is load-bearing there: a 7.5s hold gave 1 frame without it, 244 with it. Never remove the drift from screencast mode. Deterministic mode renders every frame on demand and needs no drift.
2. **Screencast mode: it always emits at CSS-viewport size.** deviceScaleFactor 1, 2, 3 and maxWidth 2560, 3840 all produced 1280x720 JPEGs; `maxWidth` only clamps down. Density needs deterministic mode (fact 11).
3. **Zoom must happen in the browser.** Same element, four approaches:
   - ffmpeg crop + upscale in post: visibly soft text.
   - CSS `transform: scale()` on `<html>`: sharp, but root becomes containing block for `position:fixed`; fixed bottom nav landed mid-frame.
   - `Emulation.setPageScaleFactor`: sharp, but zooms about the visual-viewport origin; centring on a target was wrong.
   - `Emulation.setDeviceMetricsOverride` with `viewport: {x, y, width, height, scale}`: sharp, correctly framed, fixed chrome behaves. **This is the camera.** Crispness is decided at capture time; no editor or compositor recovers it.
   - Its `viewport` x/y are **document**-relative, while `getBoundingClientRect` is viewport-relative. After a 520px scroll, `y: 0` filmed the blank page top; `y: 520` framed the target. The rig adds the scroll (read once while unzoomed) and `wide` clears the override. `npm run check` asserts a scroll-then-zoom lands on its target (luma 255 fixed, 101 with the offset removed).
   - Screencast mode: while zoomed, the drifting cursor must stay inside the camera box. Drifting outside it repaints nothing visible, the screencast stops emitting, and the mp4 froze on the pre-zoom frame for ~2.4s.
   - Deterministic mode: under `--force-device-scale-factor` the override's viewport x/y are **device** pixels while width, height and scale stay CSS (measured: x 300 at density 2 framed CSS x 150, at scale 1.5, 2 and 3 alike). The rig multiplies x/y by the density there; `npm run check` asserts a scroll-then-zoom lands in both modes.
4. **Never select by bare text.** Measured: a bare `text=<nav label>` matched an article headline elsewhere on the page and navigated away. Scope every selector to its container (`<nav-selector> >> text=<label>`, e.g. `nav.fixed.bottom-0 >> text=REPORTS` or `header nav >> text=Fares`) and set `expectPath` on every navigating beat so a mis-click fails the take instead of filming the wrong screen.
5. **Nav bars are context-dependent.** Measured on one app: after clicking one nav item, another item was gone from the nav. Targets are resolved fresh per beat; never cache handles across beats.
6. **`addInitScript` overlays survive SPA route changes** (cursor verified present after three client-side navigations).
7. **Login: never hand-write a token into storageState.** It fails silently and films the login page. `mintState` drives the real form and throws unless the final pathname has left `loginPath`. Quirks it already handles, each found on a real app: an `#email` field that is `input[type=text]` rather than `type=email`, a cookie modal covering the submit button (dismissed via `dismissSel` first), and controlled React inputs that need `type()` rather than `fill()`.
8. **ffmpeg is resolved, not hardcoded.** `$FFMPEG`/`$FFPROBE` win, then the distro build at `/usr/bin`, then PATH (Homebrew on macOS, where `/usr/bin` is read-only). Capture needs only `signalstats`, `scale` and libx264, which every common build has; it does not use drawtext. Some builds (Homebrew's default) lack drawtext; demo:compose's still-check then writes its contact tiles without captions and still gives its verdict.
9. **Browsers live in `$PLAYWRIGHT_BROWSERS_PATH` when set** (see Run).
10. **The overlay mounts in the top frame only.** Init scripts run in every frame; before this, a page with an iframe filmed a second cursor inside it. Seeding `localStorage` is skipped where storage throws (sandboxed documents) instead of aborting the cursor.

11. **Deterministic capture needs chrome-headless-shell and the density flag.** `HeadlessExperimental.beginFrame` is gone from full Chrome 147+ and survives in the headless shell, which Playwright 1.62 launches for headless Chromium (Chrome for Testing 151, revision 1234). The density must come from `--force-device-scale-factor`: an emulated deviceScaleFactor reports 2 but beginFrame returns 1280x720 pixels. The rig checks the first frame's size and falls back if it is wrong.
12. **Deterministic frames are exact.** `npm run check`: 2560x1440, `avg_frame_rate 60/1`, frame count = duration x 60 + 1, and 0 repeated frames out of 122 on a page animating every frame. The first ~24 beginFrames after a load repeat while the pipeline primes, so the rig draws 30 before filming. The PNGs survive `encode.sh` bit-exact (libx264rgb `-qp 0`, PSNR inf against the frame). Identical consecutive frames (a still hold) are hard links, so a hold costs no disk.
13. **An open SSE stream and any dynamic `import()` hold virtual time for good; a websocket does not.** Under `pauseIfNetworkFetchesPending` page time stood still until something forced it: a 0ms and an 800ms lazy module alike, and a lazy route of a real SPA (its first deterministic take fell back to screencast before `network: 'auto'` existed). `npm run check` asserts all three outcomes: the lazy module stays deterministic under `auto`, the SSE page films on under `auto` and says so once, and falls back to screencast under `pause` and says so once. A websocket pushing every 200ms did not hold it.
14. **Deterministic capture costs wall time, most of it motion blur.** The ferry example on 8 cores without a GPU, one run at a time: departures (12.5s of footage) filmed in 407s with the default blur, 209s with `blur: { spacing: 4 }`, 84s with `blur: false`, 12s in screencast mode; fares (10.9 to 11.0s) in 403s, 197s, 69s and 11s. So about 35x, 17x and 6.5x real time. The default renders 248 of departures' 753 frames again at up to 47 samples, with the averaging running alongside on the same cores. Running the gap fill on tmix's last output only (it used to fill all N outputs and keep the last, identical result) took the default from 530s and 459s, and `spacing: 4` from 259s and 265s. A 5-minute demo: about 2 hours 55 minutes with the default, 1 hour 25 minutes at `spacing: 4`, 33 minutes with `blur: false`.

## Defects the rig already handles

- **Black/white head frames**: screencast used to start before first paint (white about:blank + ~85 black splash frames). Now filming starts only after beat 0's goto is ready + settled, and the cursor is parked before the first frame. `npm run check` asserts frame-0 luma is neither blank nor black; moving `startScreencast` before the goto makes it fail with `luma 255`.
- **Chapter ending on a splash**: fixed settle delays were too short. After goto/click the rig waits for `ready`, else network quiet (no request in flight for 500ms, capped at 8s; websockets/SSE ignored). Long-poll pages always hit the cap and warn: give those beats a `ready` selector.

## Handoff contract: events.json

One per chapter, written next to the frames at `<out>/<chapter>/events.json`; `<chapter>.mp4` sits beside the chapter dir at `<out>/<chapter>.mp4`. (`demo:compose` also accepts a flattened `<out>/<chapter>-events.json`.)

```json
{
  "chapter": "home-to-reports",
  "viewport": { "width": 1280, "height": 720 },
  "dpr": 2, "fps": 60,
  "capture": { "mode": "deterministic", "blur": { "samples": 4, "shutter": 0.5, "spans": [[34, 51]], "maxSamples": 33, "maxGap": 1.5, "filled": 18 } },
  "dur": 10.85,
  "frames": 652,
  "events": [
    { "t": 2.205, "kind": "mark", "label": "bottom nav",
      "rect": { "x": 0, "y": 655, "w": 1265, "h": 65 },
      "cam":  { "x": 312.5, "y": 360, "w": 640, "h": 360, "s": 2 } },
    { "t": 1.29, "kind": "camera", "t0": 1.29, "t1": 1.884,
      "cam":  { "x": 312.5, "y": 360, "w": 640, "h": 360, "s": 2 } },
    { "t": 3.4, "kind": "click",
      "rect": { "x": 1012, "y": 668, "w": 96, "h": 40 }, "cam": null }
  ],
  "poses": [[0, 0, 0, 1], [75, 0, 1.4984, 1.0106], [76, 0, 5.3117, 1.0385]]
}
```

- `dpr`, `fps`: the take's pixel density and frame rate: 2 and 60 deterministic, 1 and 30 screencast. The mp4 is `viewport x dpr` pixels. Everything else in this file (rects, cam) stays in CSS px of the viewport, whatever the density. Takes from before these fields existed are 1 and 30.
- `capture`: the mode actually used. After a fallback it also holds `requested` and `fallback`, the cause. `blur.spans` lists blurred frames as `[first, last]` index pairs.
- `dur`: seconds, first to last frame. Deterministic: the mp4 has exactly `dur * fps + 1` frames, one per rendered frame. Screencast: it has `ceil(dur * 30) + 1` frames: capture.mjs resamples to 30fps itself (frame k shows the last frame captured at or before k/30) and writes `cfr/` as hard links, which `encode.sh` encodes as a plain image sequence. It used to hand ffmpeg a concat list of per-frame durations instead; measured on a 4.4s take with zoom glides, that ran 0.17s short on ffmpeg 6.1 and 0.73s short on ffmpeg 8.1 (an 11.1s ferry take came out 8.9s long), putting marks late by growing amounts. `npm run check` now asserts the mp4 length matches the take.
- `frames`: frames filmed. Deterministic: the mp4's frame count. Screencast: captured JPEGs (variable rate; the mp4 is resampled to 30fps).
- `t`: seconds from the first frame, which is mp4 time 0. Deterministic: the time of the first frame that shows the event. Screencast: taken from the wall clock, because the last delivered frame lagged the screen by ~1s late in a 50s take.
- `kind`: `"mark"`, `"camera"`, or a sound cue: `"click"` (as the press lands, from a `click` beat or the click a `type` beat starts with; clicks before filming starts are not recorded) and `"type"` (`t` first key, `dur` seconds of typing, `chars` count). Both carry `rect`, the target
element (the field, for a type), and `cam`, the camera box in force, in the same CSS px as a
mark's, so a consumer can point at what was clicked or typed into. A click's rect is taken as the
press lands; a type cue's after the typing, so a field that widens as it fills is measured as it
ends up. `rect` is `null` when the target has no box (display:none, zero size). Takes filmed
before this have cues without either field: treat both as optional. A consumer that reads only marks filters on `kind`. A `camera` event is one zoom or wide glide: `t0` and `t1` its
  start and end, `cam` the box it ends on (`null` for a wide). demo:compose plays
  every camera move at 1x and fades a spotlight in only once the move into it has settled.
  Deterministic: `t1` is the frame the spring settled on, exactly. Screencast: the last pose
  reaches the footage 1-2 frames after `t1`. Takes filmed before camera events existed have none,
  and compose keeps the older zoom timing for them. Fields below describe a `mark`.
- `poses` (deterministic takes only): the camera on every frame it changed, `[frame, x, y, s]`, the
  frame's index in the mp4, the visible region's top left in CSS px and the scale (a frame not
  listed keeps the pose before it; `s` 1 is full frame). Read at the frame's own time (a blurred
  frame's first sub-frame). demo:compose moves a gliding spotlight and the vertical crop with the
  content through it. The ferry departures take (753 frames) logs 268. Screencast takes and takes
  filmed before it have none, and compose falls back to `cam` and the camera events.
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

- `scripts/capture.mjs`: `capture()`, `mintState()`, `ensureState()`, `checkPath()`; the deterministic and screencast recorders and the fallback between them. Edit here to change waits and beats.
- `scripts/motion.mjs`: the spring solver for camera and pointer, and click and tilt constants. Edit here to change how things move.
- `scripts/run.mjs`: runs chapters from a beats file, encodes each.
- `scripts/encode.sh`: `cfr/` (the constant-rate frame sequence, at the take's `fps`) to a
  lossless H.264 mp4: libx264rgb `-qp 0` for deterministic PNGs, libx264 `-qp 0` for screencast
  JPEGs (their own 4:2:0 pixels); both measured bit-exact (PSNR inf). It is an intermediate:
  demo:compose makes the only lossy encode. Browsers cannot play the lossless profiles, ffmpeg
  and the montage can.
- `scripts/montage.sh`: contact sheet for grading a take.
- `scripts/selfcheck.mjs`: local throwaway server; asserts the springs (a retarget keeps velocity, a zoom from wide is pre-aimed, the camera settles exactly, a planned click lands within half a pixel), path guard (including a sibling path such as `/reports-archive`), zoom framing, events.json schema, 2560x1440 at exactly 60fps with every frame in the mp4, 0 repeated frames on an animated page, the SSE fallback with its one message, motion blur only inside camera moves with samples at most 1.5px apart and camera frames gap-filled (also when capped), a failing blur job failing the take, non-blank head, non-splash tail, screencast hold frame count, scroll-then-zoom in both modes, bare-text mis-click failing, one cursor on a page with an iframe, the cursor mounting where storage throws, every click restarting its feedback, a `type` beat typing key by key in both modes with a hidden cursor, `pace: 2` lengthening a hold, `loggedInSel` re-minting a dead session, and the pointer keeping its size under a 2x zoom and after navigating while zoomed, in both modes, with the click ring taking `cursor.ring`.

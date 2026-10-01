---
name: export
description: Turn a finished demo into what people see outside a video player - a README bundle (a looping GIF, an animated WebP and a poster PNG plus a ready `<picture>` snippet that sends reduced-motion readers the poster) and an interactive click-through HTML walkthrough built from the capture's lossless frames, one self-contained file that works offline. The loop is picked from the compose plan so it holds whole spotlights only; the walkthrough's hotspots come from the capture's mark rects. Use when asked to "make a GIF of the demo", "put the demo in the README", "export a poster", "make an animated WebP", "make an interactive demo", "make a click-through walkthrough", "make an Arcade-style demo", or "share the demo without a video". Reads demo:capture and demo:compose output only; it never films or renders.
---

# demo:export

Two exports from one composed demo. Film with demo:capture, cut with demo:compose, then:

```
compose out/<name>.mp4 ──┐
compose work/*.plan.json ┼─▶ export.mjs readme ──▶ demo.gif + demo.webp + poster.png
                         │                         picture.html, bundle.json
capture takes/<ch>/      │
  events.json (marks) ───┼─▶ export.mjs interactive ──▶ index.html (self-contained)
  cfr/%05d.png (2x) ─────┘                               steps.json
```

## Run

```bash
S="$SKILL_DIR"   # this skill's own directory
node "$S/scripts/export.mjs" readme      my.config.json   # compose/export/readme/
node "$S/scripts/export.mjs" interactive my.config.json   # compose/export/interactive/
npm --prefix "$S" run check                               # self-check, ~21 s
```

`my.config.json` is the same file demo:compose ran on: the export reads the segment order, the
plans in `<out>/work/`, the final `<out>/out/<name>.mp4` and the takes it points at. Run it after
`concat.sh`. On the compose skill's ferry example (`examples/ferry/`), after its quick start:

```bash
node "$S/scripts/export.mjs" readme ferry.config.json && node "$S/scripts/export.mjs" interactive ferry.config.json
```

Exit status is non-zero on any failure; every warning names its fix.

## readme: GIF, WebP, poster, snippet

| option | default | |
|---|---|---|
| `--width` | 960 | output width in px; height keeps 16:9 |
| `--fps` | 15 | frame rate of the GIF and WebP |
| `--quality` | 90 | gifski quality to start from |
| `--budget` | 5 | GIF size limit in MB |
| `--from` / `--to` | picked | loop range in seconds of the final mp4 |
| `--out` | `<out>/export/readme` | |

**The loop.** One chapter, 8 to 12 s, starting and ending between spotlights so no spotlight is
cut: each runs from its fade-in to the end of its fade-out, and the loop must hold all of it or
none. It leads 1.2 s before its first spotlight (the camera move into it is in the loop) and
tails 0.6 s after its last. Candidates score by spotlights held, closeness to 10 s, and the seam:
the mean luma difference between the loop's first and last frame, so the restart jumps least.
A `--from`/`--to` that cuts a spotlight is refused with the spotlight's lit range.

**GIF** via gifski when installed (libimagequant, temporal dithering). Without it the export
warns once and uses ffmpeg `palettegen=stats_mode=diff` + `paletteuse=dither=bayer:bayer_scale=3`,
coarser on gradients. Install: `brew install gifski` or `cargo install gifski`. Over budget,
the export steps quality down by 10 to 60, then width down by 160 to 640, then fails.

**WebP** via ffmpeg's `libwebp_anim` when the build has it, else `img2webp` (libwebp's own
tool, the `webp` package). Ubuntu's ffmpeg 6.1 has libwebp; Homebrew's ffmpeg 9 does not, so
there `img2webp` makes it (q75, method 4). With neither, the snippet offers the GIF only and
says so. Encoders merge unchanged frames into longer ones, so a 151-frame loop holds 111 WebP
and 140 GIF frames and still plays 10.07 to 10.12 s.

**Poster**: the loop's last spotlight, fully lit (after its fade-in, before its fade-out).

**Snippet** (`picture.html`), paste into a README or page beside the three files:

```html
<picture>
  <source media="(prefers-reduced-motion: reduce)" srcset="poster.png">
  <source type="image/webp" srcset="demo.webp">
  <img src="demo.gif" width="960" height="540" alt="The live board: Next sailing runs late, Six car spaces left, Four sailings, status each">
</picture>
```

The alt text is the chapter title and the labels the loop shows.

Measured on the ferry example (30.2 s final, 1280x720), gifski 1.34, libwebp 1.6, defaults:

| | ffmpeg 6.1 (libwebp) | ffmpeg 9 + img2webp |
|---|---|---|
| loop picked | departures, 5.492 to 15.508 s | same |
| demo.gif | 3.369 MB (gifski q90, 960 px) | same |
| demo.webp | 1.152 MB | 1.212 MB |
| poster.png | 0.101 MB, at 13.458 s | 0.109 MB |
| wall time | 13.0 s | 10.9 to 13.6 s |

The loop holds 3 spotlights in 10.0 s (151 frames at 15 fps).

## interactive: click-through walkthrough

| option | default | |
|---|---|---|
| `--payoff` | last step | label (prefix) of the step that shows the payoff; linted |
| `--inline` | `auto` | `yes` embeds the images, `no` writes them beside the page; `auto` embeds up to 12 MB |
| `--out` | `<out>/export/interactive` | |

**Steps.** One per mark in demo order (every mark has a rect and a label), plus each click or
type cue that carries a `rect`. demo:capture records only the time of clicks and types today, so
those are counted, skipped and named in a warning. The label is the narration line for that
mark when the demo has narration, else the mark's label, cut at a word to under 60 characters
(longer hotspot copy loses about 12% completion in Arcade's benchmarks).

**Step images** come from the lossless take, never the lossy final: the frame at the mark from
`takes/<ch>/cfr/`, else decoded from the take's mp4, at the take's own density (2560x1440 for a
deterministic 2x take). Stored as WebP q90 (ffmpeg libwebp, else `cwebp`), else PNG. Ferry:
0.307 MB of WebP for five steps against 0.829 MB of PNG.

**Hotspots**: the mark rect in page CSS px, through the camera box in force at the mark
(zoom `s`, origin `x`,`y`), times the take's density, fitted to the frame's real size from its
PNG header and clipped to it. A target wholly outside its frame fails the export.

**The page**: one HTML file, no network. Hotspot with a pulsing ring (still under
`prefers-reduced-motion`), label below or above it, Back/Next, progress dots
(`aria-current="step"`), step count, a live region announcing each label. Keys: Right or Enter
next, Left back, Home, End. Visible focus ring on every control (`:focus-visible`). Works from
390 px wide up.

**Lint** (warnings, not failures): fewer than 9 or more than 12 steps (Arcade: 9 to 12 finish
most often), and a payoff after step 7 (most viewers have left by then).

Measured on the ferry example: 5 steps (3 departures marks, 2 fares marks; 1 click skipped),
images inlined, `index.html` 0.416 MB, 1.4 to 2.2 s. Checked with Playwright at 1280 and 390
wide: every hotspot and label inside its step image, stepped through by hotspot clicks and Right
alternately, Left, Home, and a focused dot plus Enter all land on the right step, no console
errors, no horizontal scroll.

## Self-check

`npm run check` (no dependencies; ffmpeg and the encoders above). It fails if:

- the loop picker cuts a spotlight or leaves the chapter's footage, over 3000 random chapters;
- a hotspot lands outside its step image (5000 random boxes through `clipTo`, then an end-to-end
  export whose step images are measured against their boxes, and a mark off screen that must fail);
- a GIF over its budget gets through, or a `--from`/`--to` that cuts a spotlight is accepted.

The end-to-end part builds a synthetic demo (ffmpeg `testsrc2`) in a temp directory whose name
holds a space and `%`, and runs both exports on it. Each guard was checked by breaking it: the
matching check goes red.

## Limits

- Click and type cues carry no target rect yet, so walkthroughs step through marks only.
  Recording `rect` on those events in demo:capture makes them steps with no change here.
- The loop stays inside one chapter; a demo whose chapters are all shorter than 8 s gets a
  shorter loop and a warning.
- Hotspots are rectangles; a rotated or clipped element shows its bounding box.

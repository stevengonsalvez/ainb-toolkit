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
npm --prefix "$S" run check                               # self-check, ~48 s
```

`my.config.json` is the same file demo:compose ran on: the export reads the segment order, the
plans in `<out>/work/`, the final `<out>/out/<name>.mp4` and the takes it points at. Run it after
`concat.sh`. On the compose skill's ferry example (`examples/ferry/`), after its quick start:

```bash
node "$S/scripts/export.mjs" readme ferry.config.json && node "$S/scripts/export.mjs" interactive ferry.config.json
```

Exit status is 2 for a bad command line (an unknown option, a value out of range), 1 for any
other failure; every warning and error names its fix. ffmpeg is the config's `ffmpeg`, as in
demo:compose, else `$FFMPEG`, else `/usr/bin/ffmpeg`, else the one on PATH.

## readme: GIF, WebP, poster, snippet

| option | default | |
|---|---|---|
| `--width` | 960 | output width in px (160 to 4096); height keeps the demo's aspect |
| `--fps` | 15 | frame rate of the GIF and WebP (1 to 50) |
| `--quality` | 90 | gifski quality to start from (1 to 100) |
| `--budget` | 5 | size limit in MB for each of the GIF, WebP and poster |
| `--from` / `--to` | picked | loop range in seconds of the final mp4; must hold a whole spotlight |
| `--out` | `<out>/export/readme` | |

**The loop.** One chapter, 8 to 12 s, starting and ending between spotlights so no spotlight is
cut: each runs from its fade-in to the end of its fade-out, and the loop must hold all of it or
none. It leads 1.2 s before its first spotlight (the camera move into it is in the loop) and
tails 0.6 s after its last. Compose crossfades close spotlights (one fades out as the next fades
in), so a stretch that would start or end inside such an overlap is skipped; a chapter made only
of crossfades longer than 12 s has no loop, and the export says to pass `--from`/`--to`.
Candidates score by spotlights held, closeness to 10 s, the seam (mean luma difference between
the first and last frame) and the motion at either end (luma change over the first and last
1/15 s), so the restart neither jumps nor stops mid zoom. A `--from`/`--to` that cuts a
spotlight, or holds none, is refused before anything is encoded.

**GIF** via gifski when installed (libimagequant, temporal dithering). Without it the export
warns once and uses ffmpeg `palettegen=stats_mode=diff` + `paletteuse=dither=bayer:bayer_scale=3`,
coarser on gradients. Install: `brew install gifski` or `cargo install gifski`. Over budget,
the export steps gifski's quality down by 10 to 60 (the ffmpeg palette has no quality knob), then
width down by 160 to 640 (or to `--width`, when that is smaller), then fails. The WebP and the
poster are held to the same budget. The snippet carries the size the GIF came out at, read from
its header, so a square demo gets a square `<img>`. On the
ferry loop the ffmpeg fallback is 5.024 MB at 960 px, just over budget, so it steps to 800 px:
3.868 MB, 18.0 s.

**WebP** via ffmpeg's `libwebp_anim` when the build has it, else `img2webp` (libwebp's own
tool, the `webp` package). Ubuntu's ffmpeg 6.1 has libwebp; Homebrew's ffmpeg 9 does not, so
there `img2webp` makes it (q75, method 4). With neither, the snippet offers the GIF only and
says so. Encoders merge unchanged frames into longer ones, so a 151-frame loop holds 111 WebP
and 140 GIF frames and still plays 10.07 to 10.12 s.

**Poster**: the loop's last spotlight, fully lit: after both the cut-out's fade-in and its
label's (compose starts the label at the mark minus 0.1 x pace and runs it 0.3 x pace), before
its fade-out.

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
| poster.png | 0.101 MB, at 13.358 s | 0.109 MB |
| wall time | 16.0 s | 13.9 to 16.5 s |

The loop holds 3 spotlights in 10.0 s (151 frames at 15 fps). Its ends move 0.89 (luma change,
of 255, summed over both ends); ends placed mid camera move on this demo measure 6 to 25, so
the motion weight (0.5) costs such a loop 3 to 12 points against 10 per spotlight held.

## interactive: click-through walkthrough

| option | default | |
|---|---|---|
| `--payoff` | last step | label (prefix) of the step that shows the payoff; linted |
| `--inline` | `auto` | `yes` embeds the images, `no` writes them beside the page; `auto` embeds up to 12 MB |
| `--out` | `<out>/export/interactive` | |

**Steps.** One per mark in demo order (every mark has a rect and a label), plus each click or
type cue with a target (demo:capture records the clicked or typed-into element's rect and the
camera box on each). A type beat is filmed as a click into the field then the type cue; the two
make one step at the click's frame and rect (the field before it widened or hid). Cue steps are
labelled from the target's accessible name and role as demo:capture recorded them: "Open Fares"
for a link, "Click Save" otherwise, "Type in Search" for a field; takes filmed before names were
recorded read "Click here" and "Type here". Cues that point at nothing are not steps, each case said in a
warning: no `rect` at all (the take predates demo:capture recording targets: re-film it),
`rect: null` (the target had no box when filmed: display:none or zero size), or a rect wholly
outside its frame (below the fold, outside the camera box). The label is the narration line for that
mark when the demo has narration, else compose's label for that spotlight (so the config's
`labels` overrides apply), else the capture's, cut at a word to under 60 characters
(longer hotspot copy loses about 12% completion in Arcade's benchmarks).

**Step images** come from the lossless take, never the lossy final: the frame at the mark from
`takes/<ch>/cfr/`, else decoded from the take's mp4 (seeking half a frame early, so a 60 fps
take gives the marked frame and not the next), at the take's own density (2560x1440 for a
deterministic 2x take). Stored as WebP q90 (ffmpeg libwebp, else `cwebp`), else PNG with a
warning to install the `webp` package. Ferry: 0.307 MB of WebP for five steps against 0.829 MB
of PNG. Each run first removes the step images, page and `steps.json` an earlier run left.

**Hotspots**: the mark rect in page CSS px, through the camera box in force at the mark
(zoom `s`, origin `x`,`y`), times the take's density, fitted to the frame's real size from its
PNG header and clipped to it. A mark wholly outside its frame fails the export (a mark is
what the demo is about); a click or type is dropped instead, as above.

**The page**: one HTML file, no network. Hotspot with a pulsing ring (still under
`prefers-reduced-motion`); its label sits below it, else above, else inside its lower edge
(a hotspot as tall as the frame), measured at the rendered size so it never leaves the frame.
Back/Next (Next becomes Start over on the last step, as does the last hotspot), progress dots
with 24 px targets (`aria-current="step"`), step count, a live region announcing each label.
Ends use `aria-disabled`, so keyboard focus stays put. Keys: Right or Enter next, Left back,
Home, End. Visible focus ring on every control (`:focus-visible`). Works from 390 px wide up.

**Lint** (warnings, not failures): fewer than 9 or more than 12 steps (Arcade: 9 to 12 finish
most often), and a payoff after step 7 (most viewers have left by then).

Measured on the ferry example, filmed with the current demo:capture: 6 steps (3 departures
marks; in fares the click on the Fares nav link, then 2 marks), images inlined (0.401 MB),
`index.html` 0.542 MB, 2.4 s. Takes filmed before click targets were recorded give 5 steps and
warn about the skipped click (0.417 MB, 1.4 to 2.2 s). Checked with Playwright at 1280 and 390
wide: every hotspot and label inside its step image (also with a hotspot as tall as the frame,
and one 8% tall at the top), stepped through by hotspot clicks and Right alternately; Left,
Home, End, Start over and Enter on a focused control all land on the right step, focus stays on
Back at step 1, dots measure 24 px, no console errors, no horizontal scroll.

## Self-check

`npm run check` (no dependencies; ffmpeg and the encoders above). It fails if:

- the loop picker cuts a spotlight or leaves the chapter's footage, over 3000 random chapters
  with crossfading neighbours, or on seven spotlights that all crossfade;
- a hotspot lands outside its step image (5000 random boxes through `clipTo`, then an end-to-end
  export whose step images are measured against their boxes, and a mark off screen that must fail);
- a GIF over its budget gets through, the width steps below 640 px, or a `--from`/`--to` that cuts
  a spotlight or holds none is accepted (the last before anything is encoded);
- the snippet's size differs from the GIF's, 16:9 or square;
- a step from a 60 fps take shows the frame after its mark (frames 1, 4 and 7, each its own grey);
- a step label is the capture's when compose has one, a step image from an earlier run survives,
  the poster lands before the label is in at pace 3, the config's `ffmpeg` is ignored, or a
  misspelt option, non-number or bad choice runs instead of exiting 2.

The end-to-end part builds a synthetic demo (ffmpeg `testsrc2`) in a temp directory whose name
holds a space and `%`, and runs both exports on it. Each guard was checked by breaking it: the
matching check goes red.

## Limits

- demo:export reads demo:compose's config loader from `../compose/scripts/`, so it runs from
  the plugin's `skills/` directory with compose beside it, as the plugin installs it.
- Click and type steps say only what the target is called ("Open Fares"), not why. Put a mark
  on anything that needs words.
- The loop stays inside one chapter; a demo whose chapters are all shorter than 8 s gets a
  shorter loop and a warning.
- Hotspots are rectangles; a rotated or clipped element shows its bounding box.

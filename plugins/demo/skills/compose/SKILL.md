---
name: compose
description: Turn captured product footage into a finished silent demo video - spotlight plus short label at each proof moment, chapter title cards, persona-switch and end cards, dead-hold trims and a mechanical still-check. Takes a demo:capture take directory (per-chapter mp4 plus events.json) and one JSON config carrying the brand, chapter titles, card copy and any label overrides; everything else is derived from the capture. Use when asked to "compose the demo", "assemble the captured chapters", "add spotlights and callouts to the footage", "put title cards on the demo", "cut the demo together", "make the walkthrough video from the takes", or to re-cut one chapter after re-shooting it. Renders through HyperFrames. Does not record anything; pair it with demo:capture.
---

# demo:compose

Assemble captured chapters into one demo video. Capture it elsewhere.

```
demo:capture takes/ ──▶ compose.mjs ──▶ projects/<segment>/  (HyperFrames)
  <ch>.mp4                  ▲              │
  <ch>-events.json      config.json     render.sh ──▶ out/seg/<segment>.mp4
                        (brand, copy)      │
                                        check.mjs  ──▶ hit / miss per mark  ◀── THE GATE
                                           │
                                        concat.sh ──▶ out/<name>.mp4 + montage
```

Pairs with **demo:capture** (the sibling skill in this plugin), which produces the take
directory this skill consumes. Rendering is **HyperFrames**: load `hyperframes-core` before
editing the generated HTML, and `hyperframes-keyframes` / `hyperframes-animation` before
changing the motion. The generated composition already satisfies the core contract (standalone
root, one paused GSAP timeline keyed to `data-composition-id`, `@font-face` for every named
family, clip timing on the `<video>` and not on an ancestor).

## Run

```bash
S="$SKILL_DIR"   # this skill's own directory
node "$S/scripts/compose.mjs" my.config.json            # generate every segment project
bash "$S/scripts/render.sh"  my.config.json             # render each one, foreground, resumable
node "$S/scripts/check.mjs"  my.config.json             # THE GATE: hit/miss per mark, exit 1 on miss
bash "$S/scripts/concat.sh"  my.config.json             # final silent mp4 + contact sheet
```

Every command takes optional segment names to limit the work (`compose.mjs cfg.json consent`).
`render.sh` skips a segment whose mp4 is newer than its `index.html`, so a killed run resumes.
Renders run one at a time in the foreground under `timeout 590`: a harness that kills long
background tasks for low memory will otherwise take the whole batch out.

A worked example is `examples/ferry/`: a made-up ferry operator's three-page app
(`serve.mjs`, `app/`), the `beats.mjs` that films it with demo:capture, and
`ferry.config.json` with its fonts. Every path in it is relative to that directory, so copy
the directory somewhere writable and run it end to end:

```bash
cp -r "$S/examples/ferry" /scratch/ferry && cd /scratch/ferry   # CAPTURE_DIR: the demo:capture skill dir
node serve.mjs &                                            # app on 127.0.0.1:7744
node "$CAPTURE_DIR/scripts/run.mjs" beats.mjs               # takes/departures.mp4, takes/fares.mp4
node "$S/scripts/compose.mjs" ferry.config.json && bash "$S/scripts/render.sh" ferry.config.json
node "$S/scripts/check.mjs" ferry.config.json && bash "$S/scripts/concat.sh" ferry.config.json
```

## Config

Only `takes` and `chapters` are required. Everything below shows the default where there is one.

```jsonc
{
  "name": "my-demo",                  // final file is out/<name>.mp4
  "takes": "/scratch/takes",          // demo:capture output dir (required)
  "out": "./compose",                 // work dir: projects/, out/, work/
  "format": "landscape",              // or "square"; see Playback pace and format
  "width": 1280, "height": 720,       // default from format; set to override it
  "theme": {
    "bg": "#101114", "surface": "#1B1D22", "accent": "#C8CDD6",
    "highlight": "#9AA3B2", "text": "#FFFFFF", "muted": "#B5BAC4",
    "fonts": {                        // omit entirely to use the generic sans stack
      "display": { "file": "fonts/x.woff2", "family": "X", "weight": "600 700" },
      "body":    { "file": "fonts/y.woff2", "family": "Y", "weight": "500 600" }
    }
  },
  "scrim": "rgba(0,0,0,0.60)",        // what the spotlight dims everything else to
  "cards": {
    "title":  { "kicker": "…", "title": "…", "sub": "…", "dur": 3 },
    "switches": [ { "id": "switch-card", "before": "<chapter>", "kicker": "…", "title": "…", "sub": "…", "dur": 2.5 } ],
    "end":    { "kicker": "…", "title": "…", "sub": "…", "dur": 3 }
  },
  "chapterCardDur": 2.0,
  "defaultPersona": "",               // per-chapter `persona` overrides it
  "chapters": [
    { "name": "<chapter>",            // must match <chapter>.mp4 in takes (required)
      "title": "The live board",      // default: chapter name, title-cased
      "persona": "Foot passenger",
      "labels": ["…"],                // default: the capture's own mark labels. One per mark.
      "cuts": [[10.98, 11.2]],        // extra source-time cuts, e.g. a splash screen
      "cardDur": 2.0,
      "speed": { "travel": 1 } }      // per-chapter override of the global speed
  ],
  "speed":  { "travel": 2, "rampMs": 250 },
  "pace": 1,
  "targetDuration": 45,               // optional, seconds, whole video
  "hold":   { "min": 1.5, "max": 2.2 },
  "fadeLead": 0.25,                   // spotlight fades in this long before the mark
  "deadHold": 2.0,                    // freezes longer than this get trimmed
  "layout": { "safeMargin": 64, "labelHeight": 48, "labelGap": 14, "maxLabelWords": 6 },
  "check":  { "litRatio": 0.80, "dimRatio": 0.62, "contentSd": 8, "driftMax": 12 }
}
```

Paths in the config (`takes`, `out`, font `file`) resolve against the config file's own
directory. `sub` on a card is raw HTML so `<b>` can pick out a word in the highlight colour;
every other string is escaped.

## Playback pace and format

How fast the **finished video** plays, re-timed from footage you already have: no re-shoot.
This is separate from demo:capture's filming `pace`, which changes what the camera records.

```
source   ──travel──╮ proof window ╭──travel──╮ proof window ╭──
speed      2x    ramp    1x     ramp   2x   ramp    1x     ramp
                    mark t - fadeLead ... end of hold
```

- **Speed ramp, on by default.** Inside each proof window (from `fadeLead` before a mark to the
  end of its hold) footage always plays at 1x. Everything else, navigation, loading,
  cursor travel, plays at `speed.travel` (2x). Speed changes over `speed.rampMs` (250ms of
  output time) each side, so it reads as a ramp and never as a jump cut. A gap too short for
  two full ramps gets a shallower peak instead. Marks and spotlights land on the re-timed
  footage; the still-check runs on it. Chapter cards and holds are never sped up.
  `"speed": { "travel": 1 }` turns the ramp off and plays everything at 1x, exactly as before
  the ramp existed. Set `speed` globally, override any key per chapter with `chapters[].speed`.
  `speed.travel` must be between 0.1 and 4, `speed.rampMs` a number >= 0 (0 = hard speed
  change). There is no proof-speed setting: the spotlight timing and the still-check both rely
  on proof windows playing at 1x, so any other `speed` key is refused.
- **`pace`** (default 1): one multiplier on card durations (title, switch, end, chapter
  cards), `hold.min`/`hold.max`, `fadeLead` and every fade and card-motion timing. `1.3` gives
  a calmer cut, `0.8` a brisker one. It does not change footage speed. A long `hold.min` can
  outlast a camera move; if the still-check then reports drift, lower `pace` or re-mark.
- **`targetDuration`** (seconds, optional): raises the global `speed.travel`, capped at 4x,
  until the whole video (cards included) fits, and prints `speed.travel` and the planned length.
  It never speeds up proof windows, cards or holds, so a target shorter than those can reach is
  reported, not met. Chapters with their own `speed.travel` keep it.
- **`format`**: `"landscape"` 1280x720 (default), `"square"` 1080x1080. Footage stays 16:9.
  For square, each proof window gets its own framing: footage scaled and placed so the spotlit
  rect (from `events.json` `rect` and `cam`) fits with room for its label, between the
  cover scale (fills the square, crops the sides) and the contain scale (whole frame, bands
  above and below in `theme.bg`). Framing holds still while a spotlight is lit and eases between
  windows; overlapping windows share one framing. `"vertical"` is refused: 16:9 cropped to 9:16
  cannot keep a wide mark readable, and a broken vertical is worse than none.

Measured on the ferry example, filmed fresh (two chapters, five marks, 3s title and end cards):

| settings | video length | still-check |
|---|---|---|
| `speed.travel: 1` | 31.17s | 5/5 |
| default (2x travel ramp) | 26.13s | 5/5 |
| `format: "square"`, default ramp | 26.13s | 5/5 |

The ferry app is quick, so travel is a small share of it; the saving grows with loading and
navigation time.

How it works: `compose.mjs` writes each chapter's footage already cut and re-timed (one ffmpeg
pass: `select` for the kept ranges, `setpts` with the piecewise speed curve, `fps=30`), so the
HyperFrames project holds one plain `<video>`. At a constant whole-number speed it nudges each
piece by under 1/60s so source frames never sit on a half frame, which otherwise made a 1x
window duplicate then drop a frame.

## Style rules the generator holds to

Measured on a 5:36 ten-chapter demo, 47 marks. Change them in config, not in code.

- **Spotlight**: dim everything except the mark's rect (default 60% black scrim, rounded
  cut-out, accent edge and glow). Fades in 250ms before `t`, holds 1.5 to 2.5s, fades out.
- **Labels**: at most 6 words, sentence case, placed clear of the cut-out inside a 64px safe
  margin. Over-long labels warn rather than fail. Rewrite the capture's label candidates for
  clarity; never claim something the footage does not show.
- **Chapter cards** about 2s (persona line plus chapter title), **title and end cards** about 3s.
- **Silent**, and no annotation is ever burned into the footage. Everything is an overlay on
  top of an untouched capture, so a relabel is a re-render and never a re-shoot.
- Navigation clicks stay in, played at `speed.travel`. Only dead holds over 2s and configured
  cuts are trimmed.

## Two defects this generator already fixes

Both were found by looking at stills, not by reading code. Do not "simplify" them away.

1. **A hold must not run past a camera move.** The cut-out is placed for the frame at `t`. If
   the hold outlives a zoom, a `wide`, or a navigation, the frame changes underneath and the
   cut-out lands on nothing. `stableUntil()` samples the footage at 10fps from `t+0.3` and ends
   the hold at the first frame that differs from the mark pose, capped at `hold.max`.
2. **A label must not cover its own spotlight.** Placement tries below, above, right, left, each
   fully outside the cut-out and inside the safe margin. When nothing fits, the cut-out's bottom
   is cropped (`below-cropped`) so the label sits under it. Overlap is then re-asserted
   geometrically by `check.mjs`, so a regression fails the gate.

## The still-check is the gate, not an extra

`check.mjs` renders two stills per mark, at `compT + 0.5` and at the end of the hold, and runs
four tests against the rendered segment and the untouched source frame. It prints one line per
mark and exits 1 if any mark misses.

| test      | what it measures                                            | what it catches                      |
|-----------|-------------------------------------------------------------|--------------------------------------|
| `lit`     | cut-out luma / same region in the source, both stills        | spotlight missing, or mistimed       |
| `dim`     | ring outside the cut-out / same ring in the source           | scrim not applied                    |
| `sd`      | luma spread under the cut-out                                | cut-out landed on empty background   |
| `drift`   | cut-out region, still A vs still B, in the source            | defect 1: hold outran a camera move  |
| label     | label box vs spotlight box, geometric                        | defect 2: label over its spotlight   |

The ring samples 34px clear of the box edge and skips the label rect. Closer in, the spotlight's
own 22px glow reads as "not dimmed" and every mark fails.

It also writes `work/stills-<chapter>.png`, a 2-wide tile of every still with its mark index and
time drawn on. **Look at it.** The numbers say the geometry is right; the sheet says the label
reads and the frame is the one you meant.

A failing mark is a config problem, not a code problem. Usual fixes, in order: shorten the
label, add a `cuts` entry to remove the drifting span, re-mark the chapter in `demo:capture`
with a tighter `hold` before the next camera move.

## Files

- `scripts/config.mjs`: config load, defaults, font stacks, segment ordering.
- `scripts/compose.mjs`: one standalone HyperFrames project per segment. Separate projects keep
  each render small and lint clean.
- `scripts/render.sh`, `scripts/concat.sh`: render loop and final encode.
- ffmpeg and ffprobe, everywhere: env `FFMPEG`/`FFPROBE`, then config `"ffmpeg"`/`"ffprobe"`,
  then whatever is on PATH. Every step, the still-check verdict included, runs on a plain build.
  The one cosmetic extra is the caption on each contact tile (`drawtext`, libfreetype), which
  some builds lack (a measured Homebrew 8.1 did): `check.mjs` then prints one warning and writes
  the tiles uncaptioned. For captions, point `FFMPEG` at a full build such as `/usr/bin/ffmpeg`.
- `scripts/check.mjs`: the gate. For square output it frames the source frame with the same
  view as the composition before comparing.
- `assets/template/`: `hyperframes.json`, `package.json`, and a vendored `gsap.min.js` so a
  render needs no CDN.
- `examples/ferry/`: a runnable example, a made-up app with its server, beats file, config and
  fonts, every path relative to that directory.

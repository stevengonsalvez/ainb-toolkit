---
name: compose
description: Turn captured product footage into a finished demo video - spotlight plus short label at each proof moment, chapter title cards, persona-switch and end cards, dead-hold trims and a mechanical still-check, plus a sound layer timed from the capture's own events (UI sound effects, an optional ducked music bed with cuts on the beat, optional narration whose anchor words fire the spotlights, a loudness-checked mix) and WebVTT captions and chapters. Takes a demo:capture take directory (per-chapter mp4 plus events.json) and one JSON config carrying the brand, chapter titles, card copy and any label overrides; everything else is derived from the capture. Use when asked to "compose the demo", "assemble the captured chapters", "add spotlights and callouts to the footage", "put title cards on the demo", "cut the demo together", "make the walkthrough video from the takes", or to re-cut one chapter after re-shooting it, or to "add narration", "add a voiceover", "add music", "add sound effects" or "add captions" to a demo. Renders through HyperFrames. Does not record anything; pair it with demo:capture.
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
bash "$S/scripts/concat.sh"  my.config.json             # final mp4 with sound, captions, contact sheet
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
  },                                  // any card also takes "narration": "…" (see Sound)
  "chapterCardDur": 2.0,
  "defaultPersona": "",               // per-chapter `persona` overrides it
  "chapters": [
    { "name": "<chapter>",            // must match <chapter>.mp4 in takes (required)
      "title": "The live board",      // default: chapter name, title-cased
      "persona": "Foot passenger",
      "labels": ["…"],                // default: the capture's own mark labels. One per mark.
      "cuts": [[10.98, 11.2]],        // extra source-time cuts, e.g. a splash screen
      "cardDur": 2.0,
      "speed": { "travel": 1 },       // per-chapter override of the global speed
      "narration": { "intro": "…",    // spoken over the chapter card; see Sound
        "marks": ["The {@next}next sailing runs late.", null] } }  // one per mark, null = none
  ],
  "speed":  { "travel": 2, "rampMs": 250 },
  "pace": 1,
  "targetDuration": 45,               // optional, seconds, whole video
  "hold":   { "min": 1.5, "max": 2.2 },
  "fadeLead": 0.25,                   // spotlight fades in this long before the mark
  "deadHold": 2.0,                    // freezes longer than this get trimmed
  "layout": { "safeMargin": 64, "labelHeight": 48, "labelGap": 14, "maxLabelWords": 6 },
  "check":  { "litRatio": 0.80, "dimRatio": 0.62, "contentSd": 8, "driftMax": 12 },
  "audio": {                          // optional; "audio": false turns the sound layer off
    "sfx":       { "level": 0, "click": true, "type": true, "zoom": true, "mark": true },  // or false
    "music":     { "file": "bed.mp3", "level": -18, "duck": 11, "fadeIn": 1.5, "fadeOut": 2.5,
                   "start": 0, "snap": true },          // no file, no music
    "narration": { "voice": "af_heart", "speed": 1, "model": "medium.en",
                   "lead": 0.3, "gap": 0.35, "tail": 0.35, "level": -16 },
    "loudness":  { "target": -14, "truePeak": -1, "tolerance": 1 },
    "captions":  { "burn": false, "maxWords": 7 }
  }
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
  a calmer cut, `0.8` a brisker one. It does not change footage speed. A paced hold stops where
  the footage stops being still (the next camera move), so a spotlight never outlives its pose;
  at `pace: 1` holds are exactly the unpaced rule.
- **`targetDuration`** (seconds, optional): raises the global `speed.travel`, capped at 4x,
  until the whole video (cards included) fits, and prints `speed.travel` and the planned length.
  It never speeds up proof windows, cards or holds, so a target shorter than those can reach is
  reported, not met. Chapters with their own `speed.travel` keep it. It measures every chapter
  that has footage, even when the command names only some, so a partial re-run picks the same
  speed; chapters not filmed yet are left out with a warning.
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

## Sound, narration and captions

`concat.sh` ends by running `scripts/audio.mjs`, which mixes the sound, muxes it into
`out/<name>.mp4` (picture copied, not re-encoded), checks the loudness and writes the captions.
Everything is timed from what capture recorded, not inferred from the picture:

```
events.json ─▶ compose.mjs ─▶ plan.json cues (click, type, zoom, wide) + spots ─┐
narration ───▶ hyperframes tts ─▶ transcribe ─▶ anchor match ─▶ freezes ────────┼─▶ audio.mjs ─▶ <name>.mp4
music file ──▶ hyperframes beats ─▶ card padding, every cut on a beat ──────────┘    captions.vtt, chapters.vtt
```

- **Sound effects**, on by default and quiet: a soft tick on each click, a key tick every 2 or 3
  typed characters (pitch varied 5%), a whoosh as long as each zoom or wide, a bell on each
  spotlight as it is fully lit. They are synthesised in `audio.mjs`, so there is no sound file to
  licence (HyperFrames' own library is under the Pixabay licence, which does not allow shipping
  the files themselves). Peaks before mastering: tick -24, key -33, whoosh -30, bell -28 dBFS,
  all moved by `sfx.level` dB; any kind can be set `false`, or `"sfx": false` for none. Clicks,
  typing and moves come from capture's `click`/`type`/`zoom`/`wide` events, so a take filmed
  before those existed gets only the bells.
- **Music bed**, only when `audio.music.file` names one (bring your own, licensed). Levelled to
  `level` LUFS, faded in and out so it ends with the last card, looped if short, and ducked
  `duck` dB (default 11) under every narration line: down over 0.25s before a line, back up over
  0.6s after, lines closer than 1.35s share one duck. With `snap` (default) `hyperframes beats`
  finds the beats and each segment's leading card grows by under one beat, so every cut lands on
  a beat to the frame. Measured on the ferry example with a 100 BPM bed: all four cuts within 4ms
  of a detected beat, duck depth 11.00 dB.
- **Narration**, only when lines are configured: `narration` on a card (spoken over it; the card
  stays up until the line ends) and on a chapter (`intro` over the chapter card, `marks` one line
  per mark, `null` to skip one). `hyperframes tts` (Kokoro, local) speaks each line once and caches
  it under `work/audio/tts` by text, voice and model. Every narrated beat **holds until its line has
  finished**: where a line would outlast its spotlight or start before the previous one ends, the
  footage freezes on the still mark pose (at the end of the previous hold, or just before the first
  mark) for whole frames until it fits. The still-check keeps passing because the plan records each
  hold's source span (`srcHold`) beside its output length.
- **Anchors**: `{@name}` in a line marks the word right after it; the line is placed so that word
  starts exactly as the spotlight is fully lit (without one, the first word does). `hyperframes
  transcribe` alone is not precise enough for this: against stop-consonant bursts in 13 test lines
  its word starts were -121ms to +183ms out, worst where no pause comes before the word. So the
  words from the anchor on are spoken again on their own and that clip's first 0.15s is matched
  against the line's loudness envelope near the recogniser's guess: -8ms to +24ms on the same 13
  lines, inside one 30fps frame. On the finished ferry cut, burst against spotlight was -23ms to
  +8ms at all five anchors. A weak match (correlation under 0.8) falls back to the recogniser's
  time and says so.
- **Loudness**: a mix with narration or music is mastered to `loudness.target` (-14 LUFS
  integrated) by measured gain plus a limiter 1 dB under `truePeak` (-1 dBTP), corrected once,
  then measured again on the AAC in the final file. `audio.mjs` exits 1, failing `concat.sh`, when
  that measurement is more than `tolerance` LU off or over the ceiling. Sound effects on their own
  are not normalised: lifting sparse ticks to -14 LUFS puts each one near full scale, so they keep
  their own low level and only the ceiling is checked.

  | ferry example, measured on the final file | integrated | true peak |
  |---|---|---|
  | effects only (default) | -38.4 LUFS | -25.3 dBTP |
  | effects + music bed | -14.0 LUFS | -1.8 dBTP |
  | effects + music + narration | -14.0 LUFS | -1.2 dBTP |

- **Captions**, always: `out/<name>.captions.vtt` (narration, each sentence split into the fewest
  even cues of at most `maxWords` words and 42 characters; without narration, each spotlight's
  label while it is lit) and `out/<name>.chapters.vtt` (one cue per segment, titled from the
  config). `"captions": { "burn": true }` also writes `out/<name>-captions.mp4` with the captions
  burned in and the spoken word in `theme.highlight`, rendered through HyperFrames: for social
  cuts that autoplay muted. Word highlights follow the recogniser's word times, so they can sit
  up to about 0.2s off; anchors do not.
- **Listen-proxy**: `out/<name>-audio.png` stacks four waveforms: effects, narration, music, final
  mix. Look at it for clipping, the ducks and where each sound sits. `out/<name>.audio.json` holds
  the measurements, cue counts and duck windows.

Narration setup, once per machine: `hyperframes tts` needs Kokoro in a Python it can use, and the
first run downloads the Kokoro model and whisper `medium.en`.

```bash
uv venv --python 3.12 ~/.local/share/hf-tts && uv pip install --python ~/.local/share/hf-tts/bin/python kokoro-onnx soundfile
export HYPERFRAMES_PYTHON=~/.local/share/hf-tts/bin/python
```

`examples/ferry/ferry.narrated.config.json` is the ferry example with narration and burned-in
captions (out dir `compose-narrated`). Run it exactly like `ferry.config.json`; the first compose
takes a few minutes for speech and timing, later ones reuse the cache.
`node "$S/scripts/audio-check.mjs"` checks the timing logic (anchors, holds, freezes, envelope
match) on synthetic input in about a second.

## Style rules the generator holds to

Measured on a 5:36 ten-chapter demo, 47 marks. Change them in config, not in code.

- **Spotlight**: dim everything except the mark's rect (default 60% black scrim, rounded
  cut-out, accent edge and glow). Fades in 250ms before `t`, holds 1.5 to 2.5s, fades out.
- **Labels**: at most 6 words, sentence case, placed clear of the cut-out inside a 64px safe
  margin. Over-long labels warn rather than fail. Rewrite the capture's label candidates for
  clarity; never claim something the footage does not show.
- **Chapter cards** about 2s (persona line plus chapter title), **title and end cards** about 3s.
- No annotation is ever burned into the footage. Everything is an overlay on top of an
  untouched capture, so a relabel is a re-render and never a re-shoot. Sound is a layer of its
  own (see above), so re-mixing is `node scripts/audio.mjs <config>` and never a re-render.
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
- `scripts/render.sh`, `scripts/concat.sh`: render loop and final encode; `concat.sh` then runs `audio.mjs`.
- `scripts/audio.mjs`: sound effects, music, narration timing (also imported by `compose.mjs`), mix,
  loudness check. `scripts/captions.mjs`: caption and chapter files, burned-in captions.
  `scripts/audio-check.mjs`: their timing logic on synthetic input.
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

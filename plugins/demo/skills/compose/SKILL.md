---
name: compose
description: Turn captured product footage into a finished demo video - a 1440p60 master with the app in a framed window on a themed backdrop, a feathered spotlight that glides between proof moments with a short label at each, blur and push transitions, chapter title cards, persona-switch and end cards, dead-hold trims and a mechanical still-check, an optional 9:16 vertical social cut whose crop follows the action with headline and burned captions, plus a sound layer timed from the capture's own events (UI sound effects, an optional ducked music bed with cuts on the beat, optional narration whose anchor words fire the spotlights, a loudness-checked mix) and WebVTT captions and chapters. Takes a demo:capture take directory (per-chapter mp4 plus events.json) and one JSON config carrying the brand, chapter titles, card copy and any label overrides; everything else is derived from the capture. Use when asked to "compose the demo", "assemble the captured chapters", "add spotlights and callouts to the footage", "put title cards on the demo", "cut the demo together", "make the walkthrough video from the takes", or to re-cut one chapter after re-shooting it, or to "add narration", "add a voiceover", "add music", "add sound effects" or "add captions" to a demo, or to "make a vertical cut", "make a 9:16 version for socials", "make a reel or short of the demo". Renders through HyperFrames. Does not record anything; pair it with demo:capture.
---

# demo:compose

Assemble captured chapters into one demo video. Capture it elsewhere.

```
demo:capture takes/ ──▶ compose.mjs ──▶ projects/<segment>/  (HyperFrames)
  <ch>.mp4                  ▲              │
  <ch>-events.json      config.json     render.sh ──▶ out/seg/<segment>.mp4
                        (brand, copy)      │      (PNG frames, packed lossless)
                                        check.mjs  ──▶ hit / miss per mark  ◀── THE GATE
                                           │
                                        concat.sh ──▶ out/<name>.mp4 + montage  (seams dissolved; the ONE lossy encode)
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
`render.sh` skips a segment whose `out/seg/<segment>.mp4` is newer than its `index.html`, so a
killed run resumes. A segment is rendered aside and swapped in only once it succeeds, so a failed
re-render keeps the previous one, and it must hold its planned length times the frame rate
(60fps final, 30fps draft, passed to HyperFrames as `--fps`) or render.sh fails it.
Renders run one at a time in the foreground with `workers` capture processes (default 4) under a
timeout of 120s plus 10s per second of segment at 720p30, scaled by pixel rate (80s per second at
the 1440p60 master): a harness that kills long background tasks for low memory will otherwise
take the whole batch out. The render itself is `scripts/hfrender.mjs` (render.sh and the
burned-caption cut both use it); its timeout is node's own, so it holds on stock macOS too.

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

At the default 1440p60 master the ferry renders in about 15 minutes on an 8-core host without a
GPU (measured under load, see The look); `"quality": "draft"` in the config makes it about 3.

## Config

Only `takes` and `chapters` are required. Everything below shows the default where there is one.

```jsonc
{
  "name": "my-demo",                  // final file is out/<name>.mp4
  "takes": "/scratch/takes",          // demo:capture output dir (required)
  "out": "./compose",                 // work dir: projects/, out/, work/
  "format": "landscape",              // or "square" or "vertical"; see Playback pace and format
  "quality": "final",                 // 2560x1440 (square 1440x1440, vertical 1080x1920) at 60fps; "draft" = 1280x720 (1080x1080, 720x1280) at 30fps
  "width": 2560, "height": 1440,      // default from format and quality; set one to override the canvas
  "frame": {                          // the framed window; false = full-bleed footage
    "style": "window", "padding": 80, "radius": 24, "shadow": 1,
    "backdrop": "glow",               // "glow" (gradient plus accent light), "gradient" or "solid"
    "grain": 0.045, "tilt": 9 },      // tilt: degrees the window arrives at, eased flat
  "spotlight": { "feather": 18, "glide": 2.5, "sweep": true, "blur": 2 },
  "transitions": { "blur": 0.5, "whip": 0.4 },  // seam lengths in seconds; false = hard cuts
  "workers": 4,                       // hyperframes capture processes
  "crf": 16,                          // the one lossy encode
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
  "cut": "continuous",                // or "beats": one still per mark, held for its line; see Beat-paced cut
  "beats":  { "pad": 0.6, "lead": 0, "cardHold": 2.5, "hold": 3, "fade": 0, "min": 3, "max": 6, "lineMax": 7 },
  "clips": false,                     // each chapter also as its own mp4 (default true with "cut": "beats")
  "pace": 1,
  "targetDuration": 45,               // optional, seconds, whole video
  "hold":   { "min": 1.5, "max": 2.2 },
  "fadeLead": 0.25,                   // spotlight fades in this long before the mark (or once the zoom settles)
  "deadHold": 2.0,                    // freezes longer than this get trimmed
  "layout": { "safeMargin": 64, "labelHeight": 48, "labelGap": 14, "maxLabelWords": 6 },
  "check":  { "litRatio": 0.80, "dimRatio": 0.62, "contentSd": 8, "driftMax": 12, "alignMax": 7, "glideStep": 0.2, "calloutMin": 12 },
  "audio": {                          // optional; "audio": false turns the sound layer off
    "sfx":       { "level": 0, "click": true, "type": true, "zoom": true, "mark": true },  // or false
    "music":     { "file": "bed.mp3", "level": -18, "duck": 11, "fadeIn": 1.5, "fadeOut": 2.5,
                   "start": 0, "snap": true },          // no file, no music
    "narration": { "tts": "hyperframes", // or "deepgram" (Aura-2; key from DEEPGRAM_API_KEY)
                   "voice": "af_heart",   // deepgram default "aura-2-thalia-en"
                   "speed": 1, "model": "medium.en",
                   "lead": 0.3, "gap": 0.35, "tail": 0.35, "level": -16 },
    "loudness":  { "target": -14, "truePeak": -1, "tolerance": 1 },
    "captions":  { "burn": false, "maxWords": 7 }   // burn: true by default for vertical (in the picture)
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
  end of its hold) and during every camera move (each zoom and wide, from the `camera` events
  demo:capture logs) footage always plays at 1x, so a zoom keeps the easing it was filmed with.
  Everything else, navigation, loading, cursor travel, plays at `speed.travel` (2x). Speed changes over `speed.rampMs` (250ms of
  output time) each side, so it reads as a ramp and never as a jump cut. A gap too short for
  two full ramps gets a shallower peak instead. Marks and spotlights land on the re-timed
  footage; the still-check runs on it. Chapter cards and holds are never sped up.
  `"speed": { "travel": 1 }` turns the ramp off and plays everything at 1x, exactly as before
  the ramp existed. Set `speed` globally, override any key per chapter with `chapters[].speed`.
  `speed.travel` must be between 0.1 and 4, `speed.rampMs` a number >= 0 (0 = hard speed
  change). Measured on the ferry example: before camera moves were protected, the zooms into
  marks played at 1.06-1.20x on average and the wides at 1.59-1.76x; all eight now play at
  1.00x. Takes filmed before demo:capture logged camera events keep the old timing. There is no proof-speed setting: the spotlight timing and the still-check both rely
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
- **`format`**: `"landscape"` (default), `"square"`. At `quality: "final"` (default) that is a
  2560x1440 or 1440x1440 master at 60fps; `"draft"` gives 1280x720 or 1080x1080 at 30fps, about
  8x less render work, for iterating on copy and timing. Footage stays 16:9.
  For square, each proof window gets its own framing: footage scaled and placed so the spotlit
  rect (from `events.json` `rect` and `cam`) fits with room for its label, between the
  cover scale (fills the square, crops the sides) and the contain scale (whole frame, bands
  above and below in `theme.bg`). Framing holds still while a spotlight is lit and eases between
  windows; overlapping windows share one framing.
- **`format: "vertical"`**, the social cut: 1080x1920 at 60fps (720x1280 at 30 as a draft),
  laid out at 1:1 in three bands. Top: the chapter's persona and title as a headline, from 220px
  down (clear of the platforms' top bar). Middle: the window, 1000x820 at y 520, cropping the
  16:9 footage. Bottom: burned captions, the lowest edge 420px above the bottom (clear of the
  caption and action UI), 60px in from the left and 120px from the right (the side rail). The
  captions are the narration's words with the spoken one picked out (captions.mjs cues), or
  without narration each spotlight's label while it is lit; the small label by the spotlight is
  then not drawn, the caption is the label at a size a phone reads. Title, switch and end cards
  fill the 9:16 frame and carry their narration as captions. In-picture captions are the
  vertical default of `audio.captions.burn`: the .vtt is then not written (uploaded beside the
  video a platform shows them twice) and concat.sh burns nothing more; `"burn": false` leaves
  the picture without them, keeps the labels by the spotlights and writes the .vtt. A caption
  wraps anywhere rather than run past the safe width (a 91-character URL label wrapped to four
  lines inside it, looked at), and compose warns on a caption over about 80 characters (the band
  under the window holds two lines; that URL rose over the window's bottom edge) and on a chapter
  title over about 100, where the headline reaches the window.
  The crop follows the current target on a critically damped spring (omega 9.43 rad/s, Cap's
  screen spring as a constant): each click and typed field, switched 0.8s before the press so
  the crop is already there when the pointer glides in and nothing enters from off-frame, and
  each group of spotlights, switched 0.8s before it lights. Presses less than 0.8s apart share
  one view, of their union (open a menu, pick an option): each switching on its own pulled the
  crop toward the second before the first landed, the first press 2,503px off the crop on a probe
  with two clicks 0.3s apart; now both inside. From a spotlight's fade-in to the end of its
  fade-out the crop is pinned to the spotlight's view, the spring eased onto it over the last
  0.2s rather than cut (it was 3.1px and 4.3px short on ferry, a visible snap before), and a
  press that lands outside a pinned crop is warned about: the crop does not follow the pointer.
  From rest the spring never overshoots, but a retarget while it still moves can carry it past
  the goal, so every frame is clamped onto the footage: ferry's fares showed an 85px strip of
  backdrop beside the footage for a moment before; now none. Views zoom past the cover scale onto
  a small target, up to 2 design px per CSS px for a 2x take (the take's own pixels at the
  1080x1920 master). The limit is in design px, so a draft frames exactly as the master: it was
  in canvas px, and a 96x40 button zoomed 3x in the draft against 2x at the master; now 2x in both.
  A spotlight's cut-out and label live inside the crop, so they move with it.

Measured on the ferry example, filmed fresh (two chapters, five marks, 3s title and end cards),
with camera moves at 1x:

| settings | video length | still-check |
|---|---|---|
| `speed.travel: 1` | 31.60s | 5/5 |
| default (2x travel ramp) | 28.00s | 5/5 |
| `format: "square"`, default ramp | 28.00s | 5/5 |
| `format: "vertical"`, default ramp, with the transitions below (landscape: 28.75s) | 28.77s | 5/5 |
| `format: "vertical"`, narrated | 34.60s | 5/5 |

Playing the camera moves at 1x added about 1.5s to the default cut (26.4s before).

The ferry app is quick, so travel is a small share of it; the saving grows with loading and
navigation time.

How it works: `compose.mjs` writes each chapter's footage already cut and re-timed (one ffmpeg
pass: `select` for the kept ranges, `setpts` with the piecewise speed curve, `fps` at the output
rate, a lanczos scale to the pixel size the footage is shown at, written lossless), so the
HyperFrames project holds one plain `<video>`. Shown size is the take's CSS viewport times the
window scale, the canvas zoom and the largest square view, capped at the take's own pixels, so
the browser at most scales it down (between square views). A deterministic take (demo:capture's default: 2560x1440 at 60fps,
`dpr` and `fps` in its events.json) enters the default framed 1440p60 master at 2240x1260 (one
lanczos downsample, x0.875) and full bleed (`frame: false`) at its native 2560x1440, and at 1x
every source frame plays. At `quality: "draft"` it is downsampled to the 720p30 window. An RGB
take is written with libx264rgb, so no colour conversion happens before concat.sh's single encode.
Rects and camera boxes stay in CSS px, whatever the density. At a constant whole-number speed it
nudges each piece by under 1/60s so source frames never sit on a half frame, which otherwise made a 1x
window duplicate then drop a frame. The spacing it keeps clear is the take's own: at 30fps output a
60fps take lands two source frames per output frame at 1x, and assuming 30 put one of each pair on the half
(measured on ferry, a source-index marker per frame: 1 duplicate-and-drop pair per chapter inside
1x windows, 0 once the take's fps is used).

## Beat-paced cut

`"cut": "beats"` paces the film one line per screen instead of playing the footage. One beat is
one screen, one callout and one line:

```
lines spoken and measured first ─▶ beat = lead + line + pad (whole frames) ─▶ jump cut ─▶ next beat
chapter card (cardHold, silent) ─▶ beat ─▶ beat ─▶ ... ─▶ seam into the next chapter
```

- **A filmed beat** is the still of its mark's settled frame (the frame at the mark, extracted
  once at the size it is shown, lanczos), in the framed window, with its spotlight irising in and
  its callout (the mark's label) popping in at the cut. It holds for its narration line plus
  `beats.pad` (0.6s), the line starting `beats.lead` (0) after the cut; a beat with no line holds
  `beats.hold` (3s). Nothing is sped up and nothing travels on screen: beats meet in hard cuts, or
  a `beats.fade` micro-fade of 1 to 4 frames. The first filmed beat after a chapter card brings
  the window in (tilted, eased flat over 0.6s) and lights after it. Compose warns when a beat
  falls outside `beats.min`-`beats.max` (3-6s) and when a line runs over `beats.lineMax` (7s):
  split it. The last beat holds through the seam into the next segment, so its pad stays clear
  of the transition; with a music bed the card takes the beat pad, or with no card the last beat.
- **A chapter card** holds `beats.cardHold` (2.5s) with no narration (`narration.intro` is not
  spoken, and compose says so); `"card": false` on a chapter leaves it out.
- **`chapters[].beats`** orders a chapter's beats; without it each filmed mark is one beat, in
  order. Each entry is one of:
  - `{ "mark": 2 }` or `{ "mark": "4.2" }`: a filmed mark, by index or by the mark's `id` in
    events.json, with an optional `label` overriding the callout;
  - `{ "split": ["2.3", "2.4"] }`: two earlier filmed beats side by side, each callout under its
    window (a half-size pane drops the scrim's backdrop blur, see compose.mjs);
  - `{ "slide": ... }`: a screen with no app, styled from the theme like the cards, with an
    optional `label` callout and `title`:
    `"title"` (`kicker`, `title`, `sub`, a `note` such as "Example data"), `"tiles"` (`tiles`: a
    word or two each), `"devices"` (`web`, `tablet`, `phone`: image files shown in a browser
    window, a tablet and a phone), `"pricing"` (`tiers`: `name`, `price`, `points`, `highlight`),
    `"steps"` (`steps`: numbered, joined by a line drawn in), `"end"` (`title`, `url`, `sub`).
  A chapter of slides only needs no footage. `narration.marks[i]` is the line of beat `i`.
- **Clips**: `"clips": true` (the default here) also writes each chapter as its own mp4 in
  `out/clips/`: its segment's lossless render given the one lossy encode the film gets, and its
  slice of the film's stems (the music faded over 0.3s at the clip's ends), mastered on its own to
  the same loudness target and checked the same way (a clip off target fails audio.mjs).
- **The still-check** reads every filmed beat like a mark (lit, dim, align, with the still's own
  source frame for both stills), checks its callout is drawn (`callout`: mean luma difference
  under the label against the source dimmed by that still's scrim ratio, gate `check.calloutMin`
  12), and checks every beat's line ends at least `pad` before its cut. Slides and splits are
  gated on timing only.

Measured on `examples/ferry/ferry.beats.config.json` (four chapters, 12 beats: three slides, a
split, five filmed, three more slides; HyperFrames' local voice), 720p30 draft: 43.9s, render
155s (3.4s per output second), still-check 5/5 marks and 12/12 beats, -14.0 LUFS, four clips at
-14.0 to -14.1 LUFS. The 1440p60 master (fresh clone): 43.7s, render 1174s (26.9s per output
second, under load; four segments of 251-374s, a slide segment costing about what a filmed one
does), 460 MB of `out/seg/`, 13 MB final, clips 2.3 to 3.9 MB, still-check 5/5 and 12/12, -14.1
LUFS and every clip -14.0 to -14.1. With a music bed every cut sits on a beat (0ms) and the bed
ducks under all 12 lines. Falsified: the callout hidden reads 1.1 and 1.5 where drawn ones read 111 to 125, both
miss; a beat cut 0.2s before its line ends misses ("line ends 8.595s, after its cut at 8.4s").
Looked at: every slide kind, the split, a filmed beat after a card, a 3-frame micro-fade.

## The look

All config-driven, and the defaults are the premium look. Layout is in design px (1280x720, or
1080x1080 square) inside a stage that CSS `zoom` scales to the canvas, so type, cards, labels and
spotlight geometry rasterise at master size instead of being upscaled (HyperFrames'
`--resolution` supersampling was measured slower).

- **Framed window** (`frame`): the footage sits in a window inset by `padding` (80 design px:
  2240x1260 of the 2560x1440 master), with squircle corners (a superellipse clip-path; CSS
  `corner-shape` with `overflow: hidden` silently broke the spotlight's mask), a layered soft
  shadow tinted from `theme.text`, on a backdrop from the theme: `glow` is a diagonal gradient of
  `theme.bg` with soft accent and highlight light in opposite corners, plus a fixed-seed grain
  tile against 8-bit banding. The window arrives with the chapter: rising, scaling from 0.94 and
  tilted `tilt` degrees in 3D, eased flat before the first spotlight lights, then reset to a 2D
  identity transform so the footage is never resampled through a 3D layer. `frame: false` is
  full bleed, as before, on the same backdrop for the cards.
- **Transitions** (`transitions`): each seam joins the two segments' own halves, rendered by
  HyperFrames, with `xfade` in concat.sh: a blur crossfade (content blurs 10px and eases scale,
  dissolved; 0.5s) and, where one chapter hands over to the next chapter or a switch card, a
  whip (content pushed a quarter of the frame left out of, and in from the right through, a 16px
  blur, joined by a soft-edged wipe travelling the same way; 0.4s). A plain dissolve under the
  push read as a fade with a drift: the outgoing half only moves fast once it is mostly gone. The backdrop
  is identical in every segment, so only content moves. Seams overlap, so the ferry cut runs
  28.75s against 30.17s with hard cuts. Picked over one master composition by measurement: a
  HyperFrames transition needs both scenes in one composition, and one composition of a whole
  film at 1440p60 renders as one unresumable job, where per-segment renders resume and a seam
  costs one `xfade` (concat of the ferry master: 82s).
- **Cards**: edge-anchored type over the backdrop, an oversized ghost word (the chapter number
  on chapter cards) drifting at 5.5% opacity behind, a hairline, and an entrance per kind: title
  words rise out of a blur on expo out, chapter words rise out of line masks on power4, switch
  cards push in from the right, the end card resolves from a blur and scale. Each card leaves
  through its seam; the film's last segment, end card or chapter, fades out to `theme.bg`.

Measured on the ferry example (two chapters, five marks), 8-core host with no GPU, under a load
average of 12 to 20 from other renders (so wall times are upper bounds):

| output | render.sh | per output second | `out/seg/` | final mp4 | still-check |
|---|---|---|---|---|---|
| before: 720p30, full bleed, hard cuts | 61s | 2.0s | 70 MB of PNG | 4.0 MB, 30.17s | 5/5 |
| default: 1440p60 framed | 881s | 30.6s | 349 MB | 14 MB, 28.75s | 5/5 |
| `frame: false`, 1440p60 | 973s | 33.8s | 329 MB | 14 MB | 5/5 |
| `format: "square"`, 1440x1440 at 60 | 701s | 24.4s | 193 MB | 7.3 MB | 5/5 |
| `quality: "draft"`, 720p30 framed | 203s | 7.1s | 65 MB | 4.3 MB | 5/5 |
| `format: "vertical"`, 1080x1920 at 60 | 532s | 18.5s | 219 MB | 7.7 MB, 28.75s | 5/5 |
| `format: "vertical"`, draft 720x1280 at 30 | 138s | 4.8s | 61 MB | 3.5 MB | 5/5 |

`out/seg/` sizes above were packed with x264's default keyframe interval; render.sh now packs with a
keyframe every 30 frames, about 20% more (the default ferry run: 435 MB). So a 5-minute
film takes about 2.5 hours at the master on this host, under load, and about 35
minutes as a draft: iterate in draft, render the master once. A bare 1440p60 window
probe (no blur, grain or tilt) captured at 12.2s per second with 4 workers and 41s with the
single worker HyperFrames picks on its own, so `workers` matters more than any effect. The
dimming blur costs about 7% (fares: 397s against 370s), because the spotlight layer is hidden
whenever nothing is lit. Peak RSS of any one process was 0.49 GB.

Text sharpness of the final mp4, by capture-pro's measure (mean gradient over edge pixels of the
same fares-table crop, resampled to 2x its CSS size), against the 720p30 master this replaces:

| crop | before (720p30) | default (framed 1440p60) | `frame: false` | draft (framed 720p30) |
|---|---|---|---|---|
| zoomed, mark "Resident fare needs proof" | 54.6 | 68.7 (+26%) | 114.1 (+109%) | 49.8 |
| wide, the whole fares table at 1x | 41.0 | 59.8 (+46%) | 74.3 (+81%) | 45.2 |

Full bleed keeps every capture pixel; the window shows them at 0.875, still well past the old
master. A draft looks like the old master, softer where zoomed because the window is smaller.

## Sound, narration and captions

`concat.sh` ends by running `scripts/audio.mjs`, which mixes the sound, muxes it into
`out/<name>.mp4` (picture copied, not re-encoded), checks the loudness and writes the captions.
Everything is timed from what capture recorded, not inferred from the picture:

```
events.json ─▶ compose.mjs ─▶ plan.json cues (click, type, camera) + spots ──────┐
narration ───▶ hyperframes tts ─▶ transcribe ─▶ anchor match ─▶ freezes ────────┼─▶ audio.mjs ─▶ <name>.mp4
          └──▶ deepgram speak ─▶ deepgram listen ─▶ anchor word start ──┘
music file ──▶ hyperframes beats ─▶ card padding, every cut on a beat ──────────┘    captions.vtt, chapters.vtt
```

- **Sound effects**, on by default and quiet: a soft tick on each click, a key tick every 2 or 3
  typed characters (pitch varied 5%), a whoosh as long as each zoom or wide, a bell on each
  spotlight as it is fully lit. They are synthesised in `audio.mjs`, so there is no sound file to
  licence (HyperFrames' own library is under the Pixabay licence, which does not allow shipping
  the files themselves). Peaks before mastering: tick -24, key -33, whoosh -30, bell -28 dBFS,
  all moved by `sfx.level` dB; any kind can be set `false` (`zoom` covers both camera moves),
  or `"sfx": false` for none. Clicks and typing come from capture's `click` and `type` events,
  moves from its `camera` events, so a take filmed before those existed gets only the bells.
- **Music bed**, only when `audio.music.file` names one (bring your own, licensed). Levelled to
  `level` LUFS, faded in and out so it ends with the last card, looped if short, and ducked
  `duck` dB (default 11) under every narration line: down over 0.25s before a line, back up over
  0.6s after, lines closer than 1.35s share one duck. With `snap` (default) each segment's
  leading card grows by under one beat so every cut lands on a beat, to the nearest frame (so
  within half a frame, 16.7ms at 30fps). `hyperframes beats` only seeds the tempo: on a 100 BPM
  tick bed it reported 101.4 BPM, which walked its beats 0.8s off the ticks within a minute. The
  grid is a steady period and phase fitted to the bed's own onsets, and a bed with no beat steady
  enough (fit contrast under 2.5) gets a warning and unsnapped cuts rather than a failure. The
  fitted grid is cached under `work/audio/beats` by the bed's content (sha256: 20ms for a 17 MB
  bed), so a bed replaced under the same name is fitted again (keyed by name and mtime, a 120 BPM
  bed copied over a 100 BPM one with an older mtime kept the old grid, 200ms off the beat). Every
  segment is whole frames (a duration that is not renders one frame too many), and starts are
  counted in frames, so a fresh compose lands its cuts on the first run. Re-cutting one chapter
  moves every later start, so with a bed `compose.mjs` also composes again each later segment
  whose start has moved, and `audio.mjs` fails when a cut sits more than a frame off the grid,
  which only a segment rendered from a stale plan can do: re-run `compose.mjs` and `render.sh`.
  With transitions a cut is the frame the next segment starts to come in (its seam overlaps the
  end of this one), so the pad aims that frame at the beat, and `audio.mjs` places every sound at
  the segment starts `concat.sh` records in `work/timeline.json`, seams already taken off.

  | bed (ferry example, measured) | detector | fitted | cuts off the beat | result |
  |---|---|---|---|---|
  | 100 BPM ticks, frame-quantised onsets | 101.4 BPM | 100.00 BPM | 15, 15, 15, 15 ms | snapped |
  | 100 BPM pad, kick and hats | 100 BPM | 100.00 BPM | 0, 0, 0, 0 ms | snapped |
  | 128 BPM four-on-the-floor kick | 127.9 BPM | 128.00 BPM | 14, 7, 12, 3 ms | snapped |
  | pink-noise drone, no beat | 245.9 BPM | contrast 1.22 | n/a | warned, not snapped |

  Duck depth measured 11.00 dB.
- **Narration**, only when lines are configured: `narration` on a card (spoken over it; the card
  stays up until the line ends) and on a chapter (`intro` over the chapter card, `marks` one line
  per mark, `null` to skip one). `hyperframes tts` (Kokoro, local; or Deepgram, below) speaks each line once and caches
  it under `work/audio/tts` by text, voice and model. Every narrated beat **holds until its line has
  finished**: where a line would outlast its spotlight or start before the previous one ends, the
  footage freezes on a still frame for whole frames until it fits: at the end of the previous hold
  (its spotlight stays up), or for the first mark where its spotlight starts to fade in, or, when a
  hold reaches the end of the take, on its last frame. The plan records every freeze (`freezes`, in
  composition seconds) and the still-check maps its stills through them to the source frame shown.
  Changing a line or moving its `{@anchor}` re-times it; the cache is keyed by text, voice, model
  and anchor.
- **Anchors**: `{@name}` in a line marks the word right after it; the line is placed so that word
  starts exactly as the spotlight is fully lit (without one, the first word does). `hyperframes
  transcribe` alone is not precise enough for this: against stop-consonant bursts in 13 test lines
  its word starts were -121ms to +183ms out, worst where no pause comes before the word. So the
  words from the anchor on are spoken again on their own and that clip's first 0.15s is matched
  against the line's loudness envelope near the recogniser's guess: -8ms to +24ms on the same 13
  lines, inside one 30fps frame. On the finished narrated ferry cut, burst against the spotlight
  being fully lit was -23ms to +8ms at all five anchors. A weak match (correlation under 0.8)
  falls back to the recogniser's time and says so.
- **Deepgram voices** (`"tts": "deepgram"`): Aura-2 over HTTPS, one request per line, 48kHz WAV.
  Every request (speak and listen) gets up to 4 attempts of 60s each, retried on a dropped
  connection, a 429 or a 5xx (waiting as long as Retry-After asks, at most 30s, else 1, 2, 4s),
  and a clip is cached only once it is a WAV: a 200 carrying an HTML page or a cut-off body is
  refused and retried, never kept as the line. The key is read from `DEEPGRAM_API_KEY` only, never from a config file;
  without it a run that has a line to speak stops before speaking anything and names the variable,
  and a run whose lines are all cached needs no key. Each clip is cached by sha256 of text, voice
  and rate (`work/audio/tts/dg-*.wav`), so a re-render, a re-timing or a new anchor never re-bills
  a line. `voice` is any Aura model (anything else, such as the local default `af_heart` left in,
  is refused before a request); a `speed` other than 1 is refused (Aura-2 has its own pace). Word times
  come from Deepgram's recogniser (nova-3, `/v1/listen`, cached beside the clip), and the anchor
  is its word start: the tail match above needs the tail spoken as the line spoke it, and Aura-2
  re-speaks it differently. The recogniser listens in the voice's language (the `-en` of the
  model), without smart formatting, so a number spelled out in the line is heard back as words.
  An anchor word it did not hear has only an interpolated time, and compose warns: reword the
  line or move the anchor. Compose speaks only the lines of the segments it was asked for, unless
  their lengths decide other segments' timing (a music bed, `targetDuration`). Measured on 14 anchors (the ferry's five and nine more lines), each
  estimate read against the word's audible onset on a spectrogram: listen within about 20ms on
  13, the 14th ("the block", at the b's closure) 110ms early; `hyperframes transcribe` up to
  270ms early; the tail match under r 0.8 on 3 and on the wrong word on 3 (up to 390ms). The
  ferry narrated cut with `"tts": "deepgram"`: 5/5, -14.1 LUFS, -1.9 dBTP, anchors placed at the
  spotlight's lit time. Four voices auditioned on one 13-word line (crude autocorrelation pitch,
  pauses over 150ms): thalia (default) 5.2s, f0 216Hz, 9.5 semitones of range, a short comma
  pause; apollo 6.6s, 150Hz, 10.5, the slowest; draco (British) 5.7s, 109Hz, 7.6, the flattest;
  pandora (British) 5.4s, 198Hz, 8.9, the longest comma pause. Pick by ear: it is a config value.
- **Loudness**: a mix with narration or music is mastered to `loudness.target` (-14 LUFS
  integrated) by measured gain plus a limiter 1 dB under `truePeak` (-1 dBTP), corrected once,
  then measured again on the AAC in the final file. `audio.mjs` exits 1, failing `concat.sh`, when
  that measurement is more than `tolerance` LU off or over the ceiling. Sound effects on their own
  are not normalised: lifting sparse ticks to -14 LUFS puts each one near full scale, so they keep
  their own low level and only the ceiling is checked. A mix with nothing in it (every effect off,
  no narration, no music) leaves the video silent and skips the gate.

  | ferry example, fresh clone, 60fps 2x takes, plain ffmpeg 8.1, measured on the final file | integrated | true peak |
  |---|---|---|
  | effects only (`ferry.config.json`) | -37.7 LUFS | -25.4 dBTP |
  | effects + a 100 BPM music bed | -14.0 LUFS | -1.7 dBTP |
  | effects + narration (`ferry.narrated.config.json`) | -14.0 LUFS | -1.9 dBTP |

- **Captions**, always: `out/<name>.captions.vtt` (narration, each sentence split into the fewest
  even cues of at most `maxWords` words and 42 characters; without narration, each spotlight's
  label while it is lit) and `out/<name>.chapters.vtt` (one cue per segment, titled from the
  config). `"captions": { "burn": true }` also writes `out/<name>-captions.mp4` with the captions
  burned in and the spoken word in `theme.highlight`, rendered through HyperFrames: for social
  cuts that autoplay muted. Word highlights follow the recogniser's word times, so they can sit
  up to about 0.2s off; anchors do not. `format: "vertical"` draws them into the picture itself
  instead (`burn` defaults to true there, with no .vtt; false leaves them out and writes it).
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

- **Spotlight**: dim everything except the mark's rect (default 60% black scrim, softened by a
  2px blur, `spotlight.blur`), through a cut-out feathered over 18px outside the rect, with a thin
  accent edge and glow. It irises in (from 6% larger, expo out over 0.5s) with one light sweep
  across the lit rect (`spotlight.sweep`). When the next mark lights within `spotlight.glide`
  (2.5s) of this hold ending and the square or vertical view does not change between them, the
  cut-out does not fade out: it glides, moving and reshaping onto the next rect over the gap with
  the camera move, arriving when the next spotlight's fade-in would have finished (so a narration
  anchor timed to that moment still lands on it). The glide rides the filmed camera: the cut-out
  travels across the page, from one mark's rect to the next, and each frame draws that page rect
  where the capture camera had it on that frame (`poses` in events.json), so the content under
  the hole never slides. Its progress is the length of the camera's path so far over the whole
  path's (centre distance plus log zoom, frame to frame), with the old power3 ease of time as a
  floor: the camera often rests zoomed out between two marks, and a hole tied to the camera alone
  parked half way across two cards for 1s. The path length never jumps; the first version took
  the ratio of distances to the two end poses, which snapped the hole half way in one frame when
  the camera ends where it started (a zoom out and back between two marks: step 0.50 of the path
  on a probe take, now 0.05). The pose is the one on the source frame actually shown: the
  re-timed footage gives each output frame the last source frame before the middle of the next
  output interval (ffmpeg's `fps`, round=near), which on an index-coded take matched 292 of 339
  frames and the rest within one; reading the frame at the re-timed time matched 37, one to two
  frames behind at 2x. Measured on ferry (three glides, design px of the 1280-wide screen): the
  eased frame-space tween it replaces slid over the content by up to 258px (mean 111) on one glide
  and 114 and 192px on the others; now 0 by construction (the correction that keeps the end
  boxes exact came to 0px), and mid-glide the still-check reads the rendered hole on its planned
  box (below). When the camera is 99% of the way to the next mark the hole is 1.4, 3.3 and 9.6px
  from its final box, where the tween was 42.4, 12.3 and 146.1px off: it arrives with the content,
  not after it. `COMPOSE_TRACE=1` writes the per-frame
  trace (`work/<chapter>-glide-m<i>.json`). A take without `poses` keeps the eased tween. A glide lasts at least 0.35s: if the next mark lights
  sooner (pace above 1, or a spotlight waiting for the camera), this hold ends early to make room
  and its label leaves as the glide starts; if that would leave the hold under 0.7s, too short
  for the two stills, or cut into the mark's narration line, it fades instead. Across a square re-frame the camera moves under the cut-out, so there it always fades
  out and irises in. Each run of glides is its own element, so one mark's fade-out can never touch
  the next (a shared one hid a mark lit within 0.3s of the last hold, found in review). It fades in 250ms before `t`, or once the zoom into the mark has
  settled in the footage if that is later, holds 1.5 to 2.5s, fades out. Fading in 250ms before
  `t` regardless put 51% of each ferry zoom's motion under the fading-in cut-out; now 0.7%, the
  frame that completes the move. Settled means the camera event's end (from demo:capture), then
  every frame-to-frame change up to 0.25s after it, which is the camera landing (from a
  screencast take the logged end trails the last pose by a 30ms wait, and the pose reaches the
  footage 16-63ms later; a deterministic take logs the exact frame the spring settled on; the
  window leaves room for a slow landing under load). Changes past 0.25s are the page itself
  moving: they do not delay the spotlight (they used to, by ~0.4s on a board with a blinking
  badge; now 0.18-0.22s, bounded by the window) and compose warns about them. `plan.json`
  records when each spotlight starts as `litFrom` and its fade as `fadeIn`.
- **Labels**: at most 6 words, sentence case, placed clear of the cut-out inside a 64px safe
  margin, popping in on a spring (back out, from 0.88 scale toward the cut-out). Over-long labels warn rather than fail. Rewrite the capture's label candidates for
  clarity; never claim something the footage does not show.
- **Chapter cards** about 2s (persona line plus chapter title), **title and end cards** about 3s.
  Lengths are design px throughout (720 lines landscape, 1080 square); the canvas scales them.
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

`check.mjs` renders two stills per mark. Still A is at `compT + 0.5`, or `litFrom + fadeIn +
0.1` if later, so a spotlight that waited for the camera is not read mid-fade, and always at
least 0.1s before still B, which is 0.05s before the fade-out. A hold too short for that window
misses as "lit too briefly to check" instead of a false scrim or drift reading (measured: hold
0.4s on the ferry board). A spotlight that glides in arrives at `litFrom + fadeIn`, when its fade-in
would have finished, so the stills read it the same way.
It runs five tests against the rendered segment and the untouched source frame. It prints one
line per mark and exits 1 if any mark misses.

Every reading happens in the design space compose lays out in: the rendered frame is cropped to
the footage's screen inside the framed window (the whole frame when `frame: false`) and scaled to
1280x720 (1080x1080 square, the 1000x820 window for vertical), so the thresholds below mean the same at draft and at the master,
framed or not. A still is also a miss if it falls inside a transition: before the window has
settled (its arrival and tilt, `settledFrom` in plan.json) or after the seam into the next
segment begins (`tailFrom`). Compose ends any hold before that seam, and warns when it cuts one.

| test      | what it measures                                            | what it catches                      |
|-----------|-------------------------------------------------------------|--------------------------------------|
| `lit`     | cut-out luma / same region in the source, both stills        | spotlight missing, or mistimed       |
| `dim`     | ring outside the cut-out / same ring in the source           | scrim not applied                    |
| `sd`      | luma spread under the cut-out                                | cut-out landed on empty background   |
| `drift`   | cut-out region, still A vs still B, in the source            | defect 1: hold outran a camera move  |
| `align`   | mean luma difference, render vs source framed through the mark's view, under the cut-out | crop or camera not yet where the spotlight was laid out (still moving) |
| label     | label box vs spotlight box, geometric                        | defect 2: label over its spotlight   |
| glide     | largest share of the glide's path in one frame (plan); lit, dim and align of the hole at the glide's middle frame | a glide that snaps, or a hole not drawn where planned |

The ring samples 34px clear of the box edge and skips the label rect. Closer in, the spotlight's
own 22px glow reads as "not dimmed" and every mark fails; so would the feather, which is why
config refuses `spotlight.feather` over 24. The thresholds did not move for the new look, and
were not loosened: with the feathered, blurred scrim the ferry reads lit 1.00 and dim
0.397-0.399, against 1.00 and 0.396-0.397 from the old hard-edged one (the scrim is 60% black,
so a clean dim reads 0.40; the gate is 0.62).

`align` (gate `check.alignMax`, 7 of 255, set from ferry readings, not derived) was added with the vertical crop, which moves under the
footage: `lit` and `dim` are ratios that hold over a shifted page, and `drift` reads the source,
so a crop still sliding while a spotlight was up passed every other test (falsified: crop retargeted 0.2s
into each hold, both marks still hit). With `align` those two miss at 11.1 and 9.0. Correct
renders on ferry read 0.47-0.56 (landscape draft), 1.7-3.0 (vertical master) and 2.4-4.3
(vertical draft, the 720-wide render scaled up to the 1000px design window, so text edges soften).
The source side is a nearest-neighbour scale of the 1x-sized read, so dense small text reads
higher than ferry's; raise `alignMax` for such an app rather than trusting 7 blindly. It is read
only on stills past the light sweep (`sweepTo` in plan.json, 0.9s after the spotlight starts),
which brightens the cut-out: a spotlight that waited for the camera put still A inside it, about 8
on dark UI. If both stills fall inside, still B is used.

A glided spotlight is also checked mid-glide. No frame may cover more than `check.glideStep`
(0.2) of the path, or 1.5x the steepest frame of the power3 ease on a short glide: ferry's glides
peak at 0.06-0.12, a probe with the old progress (the camera ending where it started) at 0.50, a
miss. And the glide's middle frame is read like a still: ferry's holes read lit 1.00, dim 0.40,
align 0.27 and 0.76. With the per-frame sets removed from the rendered project, so the hole
waited at the last mark, both glides miss (align 30.6 and 11.5); lit and dim alone still passed
(0.88 and 0.96, dim 0.48 and 0.60), which is why align is read there too.

It also writes `work/stills-<chapter>.png`, a 2-wide tile of every still with its mark index and
time drawn on. **Look at it.** The numbers say the geometry is right; the sheet says the label
reads and the frame is the one you meant.

A failing mark is a config problem, not a code problem. Usual fixes, in order: shorten the
label, add a `cuts` entry to remove the drifting span, re-mark the chapter in `demo:capture`
with a tighter `hold` before the next camera move.

## Encode chain

A footage frame used to be lossy-compressed seven times (screencast JPEG, x264 crf18, x264
crf14, HyperFrames' JPEG frame extraction, JPEG page capture and crf16 encode, then concat at
crf20). Now every intermediate is lossless and the only lossy step a viewer sees is the last:

```
screencast JPEG                       capture, the one source
  ─▶ take mp4         x264 -qp 0      bit-exact against the JPEGs
  ─▶ retimed footage  x264 -qp 0      bit-exact
  ─▶ segment frames   PNG             --format png-sequence --video-frame-format png
  ─▶ segment mp4      x264rgb -qp 0   packed by render.sh, bit-exact against the PNGs
  ─▶ final mp4        x264 crf 16     slow, tune animation, yuv420p, BT.709 tags, faststart
```

The table below was measured at 720p30 with the final at crf 14. At the 1440p60 master the crf
was re-measured on the ferry fares segment, against the same 4:2:0 conversion encoded losslessly
(so it isolates the crf):

| crf | luma PSNR | SSIM | text crop PSNR | size (10.8s) |
|---|---|---|---|---|
| 12 | 55.0 dB | 0.9985 | 54.9 dB | 7.3 MB |
| 14 | 53.4 dB | 0.9978 | 53.4 dB | 5.8 MB |
| **16** (default) | 52.0 dB | 0.9970 | 52.0 dB | 4.6 MB |
| 18 | 50.6 dB | 0.9959 | 50.4 dB | 3.6 MB |
| 20 | 49.2 dB | 0.9946 | 48.9 dB | 2.7 MB |

Every row is past visually lossless; 16 keeps 52 dB on text for 20% less than 14. Set `crf`
lower for an archival master.

HyperFrames' output options, measured on one ferry capture, four segments, the same final
encode (text crop inside each cut-out against the source screencast frame, RGB):

| segments | render.sh | `out/seg/` | crop PSNR / SSIM |
|---|---|---|---|
| before: mp4 `--quality looks`, concat crf 20 | 33.6s | 3.0 MB | 38.07 dB / 0.98847 |
| mp4 `--quality delivery` | 44.9s | 4.2 MB | 40.99 dB / 0.99367 |
| mp4 `--crf 0` | 42.9s | 13 MB | 41.22 dB / 0.99437 |
| mov (ProRes 4444) | 85.8s | 190 MB | 43.34 dB / 0.99672 |
| **png-sequence** (used) | 61.9s | 100 MB | 46.66 dB / 0.99678 |
| ceiling: png-sequence, final at x264 -qp 0 | | | 48.41 dB / 0.99826 |

- mp4 keeps HyperFrames' fast BeginFrame capture, but it captures mp4 pages as JPEG q95 and no
  flag turns that off. There is no non-alpha lossless output, and an alpha format (png-sequence,
  mov) falls back to the slower capture path, hence the extra render time.
- png-sequence is an alpha format: it makes the composition root and body transparent, and a
  frame comes out RGBA wherever a pixel is transparent (RGB only when every pixel is opaque:
  0 of 840 ferry frames had alpha, 90 of 90 did with the `#bg` fill removed). The pack
  drops the alpha, so a transparent pixel becomes black. The invariant: every visible element of
  a template sits on an opaque layer; the full-bleed `#bg` child is that layer for the root.
  `render.sh` counts frames with an alpha channel and warns if there are any.
- The PNGs carry sRGB colour, so `concat.sh` has no input matrix to guess: it converts once to
  BT.709 limited range with explicit tags.
- The takes and retimed footage use a lossless H.264 profile that browsers cannot play;
  ffmpeg, this skill and the montage read them fine. Watch the final mp4.
- render.sh packs each segment's PNGs into a lossless RGB mp4 and deletes them: at 1440p60 the
  ferry's PNGs were 3.3 GB for 30s of video (fares: 1011 MB of PNG, 141 MB packed, PSNR infinite
  against every PNG checked). A keyframe every 30 frames keeps each still-check seek short: with
  x264's default of 250 the ferry check took 45.7s, now 29.1s, for 20% more disk (fares 115 MB at
  250). So `out/seg/` holds well under 1 GB per minute at the master, where PNGs would have been
  6.6 GB. It is scratch: delete it once the final mp4 is good.
  **Free disk while rendering**: before capturing, HyperFrames refuses unless free space on the
  `out` filesystem is at least the raw RGBA size of the render's frames over 0.9 (width x height
  x 4 bytes a frame: about 1 GB per second at the 1440p60 master, so the ferry's 13.3s chapter
  asks for 13.1 GB and a 34s chapter would ask for 33 GB; about 0.12 GB per second at draft),
  although the PNGs it writes are about a tenth of that. `--low-memory-mode` does not lift the
  check (measured: a 40s 1440p60 render was refused the same with it on). So `hfrender.mjs`
  measures the free space first and, when a segment would not fit, renders it in time chunks that
  do, using 80% of what the check allows, and says so in one line, as in this ferry run forced
  into chunks with `HF_CHUNK_FRAMES=300` (an override for testing, which the line also names):
  `fares: 649 frames need 10.6 GB free for HyperFrames' disk check, 25.0 GB is free: rendering
  3 chunks of up to 217 frames`.
  Each chunk is a copy of the project re-timed to a window of its timeline; the packed chunks join
  without re-encoding. A chunk matches the whole render as closely as two whole renders match
  each other: at the master, forced into 300-frame chunks, the ferry's departures and fares came
  out 552 of 799 and 506 of 649 frames bit-exact against the whole render, the rest at 77 dB or
  better, and two whole draft renders of fares differ the same way (276 of 324 bit-exact, the
  rest about 86 dB); the chunked film passed the still-check 5/5. A chunk costs about 5s of
  start-up (draft fares, 3 chunks: 48s against 45s). What the render really used at its peak,
  sampling free space every second through the ferry master: 3.1 GB, during the 13.3s chapter
  HyperFrames asked 13.1 GB for.

At 720p the gap to the ceiling was crf 14; what remains below the ceiling is the 4:2:0 conversion and
the full-to-limited range change, which any BT.709 4:2:0 delivery pays.

## Files

- `scripts/config.mjs`: config load, defaults, font stacks, segment ordering.
- `scripts/compose.mjs`: one standalone HyperFrames project per segment. Separate projects keep
  each render small and lint clean.
- `scripts/hfrender.mjs`: one project to one lossless mp4, in time chunks when the disk is short.
- `scripts/render.sh`, `scripts/concat.sh`: render loop (PNG sequences, packed losslessly) and
  the seams plus the one final encode (see Encode chain). concat.sh also writes
  `work/timeline.json`: where each segment starts in the final cut, with its seam.
- `scripts/audio.mjs`: sound effects, music, narration timing (also imported by `compose.mjs`), mix,
  loudness check. `scripts/captions.mjs`: caption and chapter files, burned-in captions (vertical
  draws its own in the composition from the same cues).
  `scripts/audio-check.mjs`: their timing logic on synthetic input.
- ffmpeg and ffprobe, everywhere: config `"ffmpeg"`/`"ffprobe"`, then env `FFMPEG`/`FFPROBE`,
  then the distro build at `/usr/bin`, then PATH (Homebrew on macOS, where `/usr/bin` is
  read-only). Every step, the still-check verdict included, runs on a plain build. The one
  cosmetic extra is the caption on each contact tile (`drawtext`, libfreetype), which some
  builds lack (Homebrew's default formula, measured on 8.1): `check.mjs` then prints one warning
  and writes the tiles uncaptioned. Linux hosts pick `/usr/bin/ffmpeg` first, which has it.
- `render.sh` and `concat.sh` are `#!/bin/bash`, which is bash 3.2 on macOS: they use no bash-4
  features (no `mapfile`, associative arrays or case-changing expansions). The sound layer is
  Node, and needs no `timeout` binary.
- `examples/ferry/ferry.beats.config.json`, `examples/ferry/slides/`: the ferry in beat mode, with
  one slide of each kind (the device images are the ferry app at web, tablet and phone sizes).
- `scripts/check.mjs`: the gate. For square and vertical output it frames the source frame with
  the same view as the composition before comparing.
- `assets/template/`: `hyperframes.json`, `package.json`, and a vendored `gsap.min.js` so a
  render needs no CDN.
- `examples/ferry/`: a runnable example, a made-up app with its server, beats file, config and
  fonts, every path relative to that directory.

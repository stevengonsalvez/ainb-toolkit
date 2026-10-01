#!/bin/bash
# concat.sh <config.json>
# Concatenates the rendered segments in config order into the final silent mp4 and a contact sheet.
# This is the ONE lossy encode in the chain: x264 crf 14, preset slow, tune animation (flat UI,
# sharp text), 4:2:0, BT.709 limited range with explicit tags, faststart for the web.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
CFG=$(realpath "$1")
# Config values are read as plain lines, never eval'd: a name or path can hold shell syntax.
{ read -r R; read -r NAME; read -r FFMPEG; read -r FFPROBE; read -r FPS; } < <(cd "$D" && node -e '
const m = await import("./config.mjs"); const c = m.loadConfig(process.argv[1]);
console.log([c.out, c.name, c.ffmpeg, c.ffprobe, c.fps].join("\n"));' "$CFG")
# Portable across bash 3.2 (macOS /bin/bash): a read loop, no bash-4 array builtins.
NAMES=()
while IFS= read -r n; do [ -n "$n" ] && NAMES+=("$n"); done < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);console.log(m.segmentNames(c).join("\n"))' "$CFG")
[ ${#NAMES[@]} -gt 0 ] || { echo "no segments in config"; exit 1; }

# Each segment is a PNG sequence (render.sh). They are joined with the concat filter, one
# image2 input per segment, so no frame list and no per-frame durations are involved.
IN=()
for n in "${NAMES[@]}"; do
  [ -f "$R/out/seg/$n/frame_000001.png" ] || { echo "missing segment: $n"; exit 1; }
  # '%' in the path is doubled: ffmpeg reads the input as a %06d sequence pattern.
  p=$R/out/seg/$n; IN+=(-framerate "$FPS" -i "${p//%/%%}/frame_%06d.png")
done
OUT=$R/out/$NAME.mp4
# Guard for the #bg invariant (compose.mjs): hyperframes writes a frame as RGB when every pixel
# is opaque and as RGBA only when some pixel is transparent (measured: 0 of 840 ferry frames
# RGBA; 90 of 90 with #bg removed). The encode below drops alpha, so those pixels turn black.
# Reading each PNG's colour-type byte costs a few ms for the whole film.
T=$(node -e 'const fs = require("fs"); let n = 0;
for (const d of process.argv.slice(1)) for (const f of fs.readdirSync(d)) if (/^frame_\d+\.png$/.test(f)) {
  const b = Buffer.alloc(26), fd = fs.openSync(`${d}/${f}`, "r"); fs.readSync(fd, b, 0, 26, 0); fs.closeSync(fd);
  if (b[25] === 4 || b[25] === 6) n++;                 // PNG colour types with an alpha channel
} console.log(n)' "${NAMES[@]/#/$R/out/seg/}")
[ "$T" = 0 ] || echo "warn: $T frames have transparent pixels; they render black. Every visible element must sit on an opaque layer (the #bg fill)." >&2
# The PNGs are sRGB colour (RGB, or RGBA flattened to black above), so there is no input matrix
# to guess: convert once to BT.709 limited range. setparams writes the BT.709 tags: the -color_*
# output options alone left primaries and transfer "unknown" (ffmpeg 8.1).
"$FFMPEG" -loglevel error -y "${IN[@]}" -an \
  -filter_complex "concat=n=${#NAMES[@]}:v=1:a=0,scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv" \
  -c:v libx264 -preset slow -crf 14 -tune animation -movflags +faststart "$OUT"
DUR=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$OUT")
"$FFMPEG" -loglevel error -y -i "$OUT" -vf "fps=12/${DUR%.*},scale=320:-1,tile=4x3" -frames:v 1 -update 1 "$R/out/$NAME-montage.png"
echo "$OUT  ${DUR}s  $(du -h "$OUT" | cut -f1)"
echo "$R/out/$NAME-montage.png"

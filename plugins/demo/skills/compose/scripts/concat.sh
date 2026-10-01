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
mapfile -t NAMES < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);console.log(m.segmentNames(c).join("\n"))' "$CFG")

# Each segment is a PNG sequence (render.sh). They are joined with the concat filter, one
# image2 input per segment, so no frame list and no per-frame durations are involved.
IN=()
for n in "${NAMES[@]}"; do
  [ -f "$R/out/seg/$n/frame_000001.png" ] || { echo "missing segment: $n"; exit 1; }
  IN+=(-framerate "$FPS" -i "$R/out/seg/$n/frame_%06d.png")
done
OUT=$R/out/$NAME.mp4
# The PNGs are RGB (sRGB), so there is no input matrix to guess: convert once to BT.709 limited
# range. setparams writes the BT.709 tags: the -color_* output options alone left primaries and
# transfer "unknown" (ffmpeg 8.1).
"$FFMPEG" -loglevel error -y "${IN[@]}" -an \
  -filter_complex "concat=n=${#NAMES[@]}:v=1:a=0,scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv" \
  -c:v libx264 -preset slow -crf 14 -tune animation -movflags +faststart "$OUT"
DUR=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$OUT")
"$FFMPEG" -loglevel error -y -i "$OUT" -vf "fps=12/${DUR%.*},scale=320:-1,tile=4x3" -frames:v 1 "$R/out/$NAME-montage.png"
echo "$OUT  ${DUR}s  $(du -h "$OUT" | cut -f1)"
echo "$R/out/$NAME-montage.png"

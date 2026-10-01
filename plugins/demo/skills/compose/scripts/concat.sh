#!/bin/bash
# concat.sh <config.json>
# Concatenates the rendered segments in config order into the final silent mp4 and a contact sheet.
# This is the ONE lossy encode in the chain: x264 crf 14, preset slow, tune animation (flat UI,
# sharp text), 4:2:0, BT.709 limited range with explicit tags, faststart for the web.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
CFG=$(realpath "$1")
# Config values are read as plain lines, never eval'd: a name or path can hold shell syntax.
{ read -r R; read -r NAME; read -r FFMPEG; read -r FFPROBE; } < <(cd "$D" && node -e '
const m = await import("./config.mjs"); const c = m.loadConfig(process.argv[1]);
console.log([c.out, c.name, c.ffmpeg, c.ffprobe].join("\n"));' "$CFG")
mapfile -t NAMES < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);console.log(m.segmentNames(c).join("\n"))' "$CFG")

L=$R/work/concat.txt; : > "$L"
for n in "${NAMES[@]}"; do
  [ -s "$R/out/seg/$n.mov" ] || { echo "missing segment: $n"; exit 1; }
  printf "file '%s'\n" "$R/out/seg/$n.mov" >> "$L"
done
OUT=$R/out/$NAME.mp4
# hyperframes 0.8.40 writes its ProRes untagged, converted from RGB with the BT.601 matrix
# (measured: read as 601 the crop matches the source at 67.9 dB, as 709 at 52.6 dB), so the
# input matrix is stated rather than left to a default. setparams writes the BT.709 tags: the
# -color_* output options alone left primaries and transfer "unknown" (ffmpeg 8.1).
"$FFMPEG" -loglevel error -y -f concat -safe 0 -i "$L" -an \
  -vf "scale=in_color_matrix=bt601:in_range=tv:out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv" \
  -c:v libx264 -preset slow -crf 14 -tune animation -movflags +faststart "$OUT"
DUR=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$OUT")
"$FFMPEG" -loglevel error -y -i "$OUT" -vf "fps=12/${DUR%.*},scale=320:-1,tile=4x3" -frames:v 1 "$R/out/$NAME-montage.png"
echo "$OUT  ${DUR}s  $(du -h "$OUT" | cut -f1)"
echo "$R/out/$NAME-montage.png"

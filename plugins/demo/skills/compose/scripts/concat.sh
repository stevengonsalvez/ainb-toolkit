#!/bin/bash
# concat.sh <config.json>
# Concatenates the rendered segments in config order into the final silent mp4 and a contact sheet.
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
  [ -s "$R/out/seg/$n.mp4" ] || { echo "missing segment: $n"; exit 1; }
  printf "file '%s'\n" "$R/out/seg/$n.mp4" >> "$L"
done
OUT=$R/out/$NAME.mp4
"$FFMPEG" -loglevel error -y -f concat -safe 0 -i "$L" -an -c:v libx264 -preset medium -crf 20 \
  -pix_fmt yuv420p -movflags +faststart "$OUT"
DUR=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$OUT")
"$FFMPEG" -loglevel error -y -i "$OUT" -vf "fps=12/${DUR%.*},scale=320:-1,tile=4x3" -frames:v 1 "$R/out/$NAME-montage.png"
echo "$OUT  ${DUR}s  $(du -h "$OUT" | cut -f1)"
echo "$R/out/$NAME-montage.png"

#!/bin/bash
# concat.sh <config.json>
# Concatenates the rendered segments in config order into the final silent mp4 and a contact sheet.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
CFG=$(realpath "$1")
eval "$(cd "$D" && node -e '
const m = await import("./config.mjs"); const c = m.loadConfig(process.argv[1]);
console.log(`R=${JSON.stringify(c.out)}; NAME=${JSON.stringify(c.name)}`);' "$CFG")"
mapfile -t NAMES < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);console.log(m.segmentNames(c).join("\n"))' "$CFG")

L=$R/work/concat.txt; : > "$L"
for n in "${NAMES[@]}"; do
  [ -s "$R/out/seg/$n.mp4" ] || { echo "missing segment: $n"; exit 1; }
  printf "file '%s'\n" "$R/out/seg/$n.mp4" >> "$L"
done
OUT=$R/out/$NAME.mp4
/usr/bin/ffmpeg -loglevel error -y -f concat -safe 0 -i "$L" -an -c:v libx264 -preset medium -crf 20 \
  -pix_fmt yuv420p -movflags +faststart "$OUT"
/usr/bin/ffmpeg -loglevel error -y -i "$OUT" -vf "fps=12/$(/usr/bin/ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT" | cut -d. -f1),scale=320:-1,tile=4x3" -frames:v 1 "$R/out/$NAME-montage.png"
echo "$OUT  $(/usr/bin/ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")s  $(du -h "$OUT" | cut -f1)"
echo "$R/out/$NAME-montage.png"

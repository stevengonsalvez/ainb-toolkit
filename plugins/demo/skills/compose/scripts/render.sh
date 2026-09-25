#!/bin/bash
# render.sh <config.json> [segment ...]
# Renders each segment project one at a time, in the foreground, with a timeout.
# Skips a segment whose output is newer than its index.html, so a killed run resumes.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
CFG=$(realpath "$1"); shift
{ read -r R; read -r FFPROBE; } < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);console.log(c.out + "\n" + c.ffprobe)' "$CFG")
mkdir -p "$R/out/seg" "$R/work"
if [ $# -eq 0 ]; then
  mapfile -t NAMES < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);console.log(m.segmentNames(c).join("\n"))' "$CFG")
else
  NAMES=("$@")
fi
for n in "${NAMES[@]}"; do
  o=$R/out/seg/$n.mp4
  if [ -s "$o" ] && [ "$o" -nt "$R/projects/$n/index.html" ]; then echo "$n: up to date"; continue; fi
  s=$(date +%s)
  ( cd "$R/projects/$n" && timeout 590 npx --yes hyperframes@0.8.40 render --quality looks --output "$o" > "$R/work/render-$n.log" 2>&1 ) \
    || { echo "$n: FAILED"; tail -20 "$R/work/render-$n.log"; exit 1; }
  echo "$n: ok $(( $(date +%s) - s ))s $("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$o")s"
done

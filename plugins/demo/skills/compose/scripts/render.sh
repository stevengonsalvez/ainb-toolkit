#!/bin/bash
# render.sh <config.json> [segment ...]
# Renders each segment project one at a time, in the foreground, with a timeout.
# Skips a segment whose output is newer than its index.html, so a killed run resumes.
# Each segment is a directory of PNG frames (--format png-sequence, footage frames extracted as
# PNG): lossless, and concat.sh makes the one lossy encode. It beat ProRes 4444 .mov on time,
# size and quality, and an mp4 segment costs 2 dB to HyperFrames' JPEG page capture (SKILL.md).
# The timeout scales with the segment: a fixed 590s cut off chapters over about 4 minutes.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
CFG=$(realpath "$1"); shift
read -r R < <(cd "$D" && node -e 'const m=await import("./config.mjs");console.log(m.loadConfig(process.argv[1]).out)' "$CFG")
mkdir -p "$R/out/seg" "$R/work"
if [ $# -eq 0 ]; then
  mapfile -t NAMES < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);console.log(m.segmentNames(c).join("\n"))' "$CFG")
else
  NAMES=("$@")
fi
for n in "${NAMES[@]}"; do
  o=$R/out/seg/$n
  if [ -d "$o" ] && [ "$o" -nt "$R/projects/$n/index.html" ]; then echo "$n: up to date"; continue; fi
  dur=$(node -e 'console.log(Math.ceil(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).total))' "$R/work/$n.plan.json")
  s=$(date +%s)
  # Rendered aside and moved into place, so a killed render never leaves a half segment that looks done.
  rm -rf "$o.part" "$o"
  ( cd "$R/projects/$n" && timeout $((120 + 10 * dur)) npx --yes hyperframes@0.8.40 render --format png-sequence --video-frame-format png --output "$o.part" > "$R/work/render-$n.log" 2>&1 ) \
    || { echo "$n: FAILED"; tail -20 "$R/work/render-$n.log"; exit 1; }
  mv "$o.part" "$o"
  echo "$n: ok $(( $(date +%s) - s ))s $(ls "$o" | wc -l | awk '{printf "%.3f", $1 / 30}')s"
done

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
{ read -r R; read -r FPS; } < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);console.log(c.out + "\n" + c.fps)' "$CFG")
mkdir -p "$R/out/seg" "$R/work"
if [ $# -eq 0 ]; then
  mapfile -t NAMES < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);console.log(m.segmentNames(c).join("\n"))' "$CFG")
else
  NAMES=("$@")
fi
for n in "${NAMES[@]}"; do
  o=$R/out/seg/$n
  if [ -d "$o" ] && [ "$o" -nt "$R/projects/$n/index.html" ]; then echo "$n: up to date"; continue; fi
  { read -r dur; read -r want; } < <(node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    console.log(Math.ceil(p.total) + "\n" + p.total * process.argv[2])' "$R/work/$n.plan.json" "$FPS")
  s=$(date +%s)
  # Rendered aside and swapped in only on success: a killed or failed render leaves the previous
  # good segment in place and never a half segment that looks done.
  rm -rf "$o.part"
  ( cd "$R/projects/$n" && timeout $((120 + 10 * dur)) npx --yes hyperframes@0.8.40 render --fps "$FPS" --format png-sequence --video-frame-format png --output "$o.part" > "$R/work/render-$n.log" 2>&1 ) \
    || { echo "$n: FAILED"; tail -20 "$R/work/render-$n.log"; exit 1; }
  # A segment must hold its planned length in frames (total * fps, rounded either way): concat
  # and check.mjs both turn frame numbers into time.
  got=$(find "$o.part" -maxdepth 1 -name 'frame_*.png' | wc -l)
  awk -v g="$got" -v w="$want" 'BEGIN { exit !(g - w < 1.001 && w - g < 1.001) }' \
    || { echo "$n: FAILED: $got frames, plan wants $want"; exit 1; }
  rm -rf "$o"; mv "$o.part" "$o"
  echo "$n: ok $(( $(date +%s) - s ))s $(awk -v g="$got" -v f="$FPS" 'BEGIN { printf "%.3f", g / f }')s"
done

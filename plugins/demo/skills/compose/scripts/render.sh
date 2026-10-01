#!/bin/bash
# render.sh <config.json> [segment ...]
# Renders each segment project one at a time, in the foreground, through hfrender.mjs: PNG frames
# (--format png-sequence, footage frames extracted as PNG), checked for length and alpha, packed
# losslessly into out/seg/<segment>.mp4, in time chunks when the disk is short (see hfrender.mjs).
# concat.sh makes the one lossy encode. png-sequence beat ProRes 4444 .mov on time, size and
# quality, and an mp4 segment costs 2 dB to HyperFrames' JPEG page capture (SKILL.md).
# Skips a segment whose output is newer than its index.html, so a killed run resumes. Each render
# has a timeout scaled to its length and pixel rate, and workers are explicit: at 1440p
# HyperFrames' own calibration sees a slow frame and drops to 1.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
CFG=$(realpath "$1"); shift
{ read -r R; } < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);
console.log(c.out)' "$CFG")
mkdir -p "$R/out/seg" "$R/work"
if [ $# -eq 0 ]; then
  # Portable across bash 3.2 (macOS /bin/bash): a read loop, no bash-4 array builtins.
  NAMES=()
  while IFS= read -r n; do [ -n "$n" ] && NAMES+=("$n"); done < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);console.log(m.segmentNames(c).join("\n"))' "$CFG")
else
  NAMES=("$@")
fi
[ ${#NAMES[@]} -gt 0 ] || { echo "no segments in config"; exit 1; }
for n in "${NAMES[@]}"; do
  o=$R/out/seg/$n
  if [ -f "$o.mp4" ] && [ "$o.mp4" -nt "$R/projects/$n/index.html" ]; then echo "$n: up to date"; continue; fi
  s=$(date +%s)
  # Rendered aside and swapped in only on success: a killed or failed render leaves the previous
  # good segment in place and never a half segment that looks done.
  rm -f "$o.next.mp4"
  node "$D/hfrender.mjs" "$CFG" "$R/projects/$n" "$o.next.mp4" "$R/work/render-$n.log" \
    || { echo "$n: FAILED"; tail -20 "$R/work/render-$n.log"; exit 1; }
  mv "$o.next.mp4" "$o.mp4"
  echo "$n: ok $(( $(date +%s) - s ))s"
done

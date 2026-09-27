#!/bin/bash
# render.sh <config.json> [segment ...]
# Renders each segment project one at a time, in the foreground, with a timeout.
# Skips a segment whose output is newer than its index.html, so a killed run resumes.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
CFG=$(realpath "$1"); shift
eval "$(cd "$D" && node -e '
const m = await import("./config.mjs"); const c = m.loadConfig(process.argv[1]);
console.log(`R=${JSON.stringify(c.out)}; FFPROBE=${JSON.stringify(c.ffprobe)}`);' "$CFG")"
mkdir -p "$R/out/seg" "$R/work"
if [ $# -eq 0 ]; then
  # Portable across bash 3.2 (macOS /bin/bash): no mapfile.
  NAMES=()
  while IFS= read -r n; do [ -n "$n" ] && NAMES+=("$n"); done < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);console.log(m.segmentNames(c).join("\n"))' "$CFG")
else
  NAMES=("$@")
fi
[ ${#NAMES[@]} -gt 0 ] || { echo "no segments in config"; exit 1; }
# timeout is GNU coreutils: absent on stock macOS. Prefer gtimeout, else run unguarded.
tmo() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"; else shift; "$@"; fi; }
for n in "${NAMES[@]}"; do
  o=$R/out/seg/$n.mp4
  if [ -s "$o" ] && [ "$o" -nt "$R/projects/$n/index.html" ]; then echo "$n: up to date"; continue; fi
  s=$(date +%s)
  ( cd "$R/projects/$n" && tmo 590 npx --yes hyperframes@0.8.40 render --quality looks --output "$o" > "$R/work/render-$n.log" 2>&1 ) \
    || { echo "$n: FAILED"; tail -20 "$R/work/render-$n.log"; exit 1; }
  echo "$n: ok $(( $(date +%s) - s ))s $("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$o")s"
done

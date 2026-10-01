#!/bin/bash
# render.sh <config.json> [segment ...]
# Renders each segment project one at a time, in the foreground, with a timeout.
# Skips a segment whose output is newer than its index.html, so a killed run resumes.
# Each segment renders as PNG frames (--format png-sequence, footage frames extracted as PNG),
# then is packed losslessly into out/seg/<segment>.mp4; concat.sh makes the one lossy encode.
# png-sequence beat ProRes 4444 .mov on time, size and quality, and an mp4 segment costs 2 dB to
# HyperFrames' JPEG page capture (SKILL.md).
# The timeout scales with the segment and its pixel rate: a fixed 590s cut off chapters over about 4 minutes.
# Workers are explicit: at 1440p hyperframes' auto calibration sees a slow frame and drops to 1.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
CFG=$(realpath "$1"); shift
# PER: timeout seconds per second of segment, scaled by pixels per second against 720p30, where
# 10 was the measured headroom. A 1440p60 master is 8x the pixel rate.
{ read -r R; read -r FPS; read -r WK; read -r PER; read -r FFMPEG; } < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);
console.log([c.out, c.fps, c.workers, Math.ceil(10 * c.width * c.height * c.fps / (1280 * 720 * 30)), c.ffmpeg].join("\n"))' "$CFG")
mkdir -p "$R/out/seg" "$R/work"
if [ $# -eq 0 ]; then
  # Portable across bash 3.2 (macOS /bin/bash): a read loop, no bash-4 array builtins.
  NAMES=()
  while IFS= read -r n; do [ -n "$n" ] && NAMES+=("$n"); done < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);console.log(m.segmentNames(c).join("\n"))' "$CFG")
else
  NAMES=("$@")
fi
[ ${#NAMES[@]} -gt 0 ] || { echo "no segments in config"; exit 1; }
# timeout is GNU coreutils: absent on stock macOS. Prefer it, then gtimeout (Homebrew coreutils),
# else run unguarded and say so once.
if command -v timeout >/dev/null 2>&1; then TMO=timeout
elif command -v gtimeout >/dev/null 2>&1; then TMO=gtimeout
else TMO=; echo "warn: no timeout or gtimeout on PATH, so renders run without a time limit (brew install coreutils adds gtimeout)" >&2
fi
tmo() { if [ -n "$TMO" ]; then "$TMO" "$@"; else shift; "$@"; fi; }
for n in "${NAMES[@]}"; do
  o=$R/out/seg/$n
  if [ -f "$o.mp4" ] && [ "$o.mp4" -nt "$R/projects/$n/index.html" ]; then echo "$n: up to date"; continue; fi
  { read -r dur; read -r want; } < <(node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    console.log(Math.ceil(p.total) + "\n" + p.total * process.argv[2])' "$R/work/$n.plan.json" "$FPS")
  s=$(date +%s)
  # Rendered aside and swapped in only on success: a killed or failed render leaves the previous
  # good segment in place and never a half segment that looks done.
  rm -rf "$o.part" "$o.part.mp4"
  ( cd "$R/projects/$n" && tmo $((120 + PER * dur)) npx --yes hyperframes@0.8.40 render --fps "$FPS" --workers "$WK" --format png-sequence --video-frame-format png --output "$o.part" > "$R/work/render-$n.log" 2>&1 ) \
    || { echo "$n: FAILED"; tail -20 "$R/work/render-$n.log"; exit 1; }
  # A segment must hold its planned length in frames (total * fps, rounded either way): concat
  # and check.mjs both turn frame numbers into time.
  got=$(find "$o.part" -maxdepth 1 -name 'frame_*.png' | wc -l)
  awk -v g="$got" -v w="$want" 'BEGIN { exit !(g - w < 1.001 && w - g < 1.001) }' \
    || { echo "$n: FAILED: $got frames, plan wants $want"; exit 1; }
  # Guard for the #bg invariant (compose.mjs): hyperframes writes a frame as RGB when every pixel
  # is opaque and as RGBA only when some pixel is transparent (measured: 0 of 840 ferry frames
  # RGBA; 90 of 90 with #bg removed). The pack below keeps RGB only, so those pixels turn black.
  # Reading each PNG's colour-type byte costs a few ms per segment.
  T=$(node -e 'const fs = require("fs"); let n = 0; const d = process.argv[1];
for (const f of fs.readdirSync(d)) if (/^frame_\d+\.png$/.test(f)) {
  const b = Buffer.alloc(26), fd = fs.openSync(`${d}/${f}`, "r"); fs.readSync(fd, b, 0, 26, 0); fs.closeSync(fd);
  if (b[25] === 4 || b[25] === 6) n++;                 // PNG colour types with an alpha channel
} console.log(n)' "$o.part")
  [ "$T" = 0 ] || echo "warn: $n: $T frames have transparent pixels; they render black. Every visible element must sit on an opaque layer (the #bg fill)." >&2
  # Packed bit-exact into lossless RGB H.264 (verified: PSNR inf against the PNGs), which is 9x
  # smaller than the PNGs at 1440p60 (fares: 1011 MB of PNG, 115 MB packed, 12s to pack).
  # '%' in the path is doubled: ffmpeg reads the input as a %06d sequence pattern.
  "$FFMPEG" -nostdin -loglevel error -y -framerate "$FPS" -i "${o//%/%%}.part/frame_%06d.png" \
    -c:v libx264rgb -qp 0 -preset veryfast -pix_fmt rgb24 "$o.part.mp4" \
    || { echo "$n: FAILED to pack"; exit 1; }
  rm -rf "$o.part" "$o"; mv "$o.part.mp4" "$o.mp4"
  echo "$n: ok $(( $(date +%s) - s ))s $(awk -v g="$got" -v f="$FPS" 'BEGIN { printf "%.3f", g / f }')s"
done

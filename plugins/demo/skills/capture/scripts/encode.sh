#!/usr/bin/env bash
# ABOUTME: Encode one chapter's frames (list.txt, variable frame durations) to a 30fps mp4.
# Usage: encode.sh <chapter-dir> [out.mp4]
# Uses only fps/scale/format and libx264, so any ffmpeg build works; drawtext is not needed here.
set -euo pipefail
dir=${1:?chapter dir}; out=${2:-$dir.mp4}
# ffmpeg: $FFMPEG, else the distro build at /usr/bin, else PATH
# (Homebrew on macOS, where /usr/bin is read-only).
FFMPEG=${FFMPEG:-$([ -x /usr/bin/ffmpeg ] && echo /usr/bin/ffmpeg || command -v ffmpeg || true)}
: "${FFMPEG:?ffmpeg not found: install it or set FFMPEG}"
"$FFMPEG" -v error -y -f concat -safe 0 -i "$dir/list.txt" \
  -vf "fps=30,scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p" \
  -c:v libx264 -crf 18 -preset medium -movflags +faststart "$out"

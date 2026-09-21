#!/usr/bin/env bash
# ABOUTME: Encode one chapter's frames (list.txt, variable frame durations) to a 30fps mp4.
# Usage: encode.sh <chapter-dir> [out.mp4]
# /usr/bin/ffmpeg on purpose: the ffmpeg on PATH (linuxbrew) lacks libass/drawtext.
set -euo pipefail
dir=${1:?chapter dir}; out=${2:-$dir.mp4}
/usr/bin/ffmpeg -v error -y -f concat -safe 0 -i "$dir/list.txt" \
  -vf "fps=30,scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p" \
  -c:v libx264 -crf 18 -preset medium -movflags +faststart "$out"

#!/usr/bin/env bash
# ABOUTME: Encode one chapter's 30fps frame sequence (cfr/, written by capture.mjs) to an mp4.
# Usage: encode.sh <chapter-dir> [out.mp4]
# ffmpeg is $FFMPEG, else the one on PATH. Encoding needs no libass/drawtext, so any build works.
set -euo pipefail
FFMPEG=${FFMPEG:-ffmpeg}
dir=${1:?chapter dir}; out=${2:-$dir.mp4}
"$FFMPEG" -v error -y -framerate 30 -i "$dir/cfr/%05d.jpg" \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p" \
  -c:v libx264 -crf 18 -preset medium -movflags +faststart "$out"

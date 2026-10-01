#!/usr/bin/env bash
# ABOUTME: Encode one chapter's 30fps frame sequence (cfr/, written by capture.mjs) to an mp4.
# Usage: encode.sh <chapter-dir> [out.mp4]
# ffmpeg is $FFMPEG, else the one on PATH. Encoding needs no libass/drawtext, so any build works.
# Lossless (x264 -qp 0, the JPEGs' own 4:2:0 full-range pixels, no conversion): this is an
# intermediate, and demo:compose's concat.sh makes the only lossy encode a viewer sees.
# Browsers cannot play a lossless H.264 profile; ffmpeg, compose and the montage read it fine.
set -euo pipefail
FFMPEG=${FFMPEG:-ffmpeg}
dir=${1:?chapter dir}; out=${2:-$dir.mp4}
# '%' in the directory is doubled: ffmpeg reads the input as a %05d sequence pattern.
"$FFMPEG" -v error -y -framerate 30 -i "${dir//%/%%}/cfr/%05d.jpg" \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
  -c:v libx264 -qp 0 -preset veryfast -movflags +faststart "$out"

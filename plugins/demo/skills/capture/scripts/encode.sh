#!/usr/bin/env bash
# ABOUTME: Encode one chapter's 30fps frame sequence (cfr/, written by capture.mjs) to an mp4.
# Usage: encode.sh <chapter-dir> [out.mp4]
# Uses only scale and libx264, so any ffmpeg build works; drawtext is not needed here.
# Lossless (x264 -qp 0, the JPEGs' own 4:2:0 full-range pixels, no conversion): this is an
# intermediate, and demo:compose's concat.sh makes the only lossy encode a viewer sees.
# Browsers cannot play a lossless H.264 profile; ffmpeg, compose and the montage read it fine.
set -euo pipefail
# ffmpeg: $FFMPEG, else the distro build at /usr/bin, else PATH
# (Homebrew on macOS, where /usr/bin is read-only).
FFMPEG=${FFMPEG:-$([ -x /usr/bin/ffmpeg ] && echo /usr/bin/ffmpeg || command -v ffmpeg || true)}
: "${FFMPEG:?ffmpeg not found: install it or set FFMPEG}"
dir=${1:?chapter dir}; out=${2:-$dir.mp4}
# '%' in the directory is doubled: ffmpeg reads the input as a %05d sequence pattern.
"$FFMPEG" -v error -y -framerate 30 -i "${dir//%/%%}/cfr/%05d.jpg" \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
  -c:v libx264 -qp 0 -preset veryfast -movflags +faststart "$out"

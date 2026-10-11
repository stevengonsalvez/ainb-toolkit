#!/usr/bin/env bash
# ABOUTME: Encode one chapter's constant-rate frame sequence (cfr/, written by capture.mjs) to an mp4.
# Usage: encode.sh <chapter-dir> [out.mp4]
# Uses only scale and libx264/libx264rgb, so any ffmpeg build works; drawtext is not needed here.
# Lossless: this is an intermediate, and demo:compose's concat.sh makes the only lossy encode a
# viewer sees. Deterministic takes are PNG (RGB): libx264rgb -qp 0 keeps them bit-exact, with no
# RGB to YUV conversion. Screencast takes are JPEG: libx264 -qp 0 keeps their own 4:2:0 pixels.
# Browsers cannot play either lossless profile; ffmpeg, compose and the montage read them fine.
set -euo pipefail
# ffmpeg: $FFMPEG, else the distro build at /usr/bin, else PATH
# (Homebrew on macOS, where /usr/bin is read-only).
FFMPEG=${FFMPEG:-$([ -x /usr/bin/ffmpeg ] && echo /usr/bin/ffmpeg || command -v ffmpeg || true)}
: "${FFMPEG:?ffmpeg not found: install it or set FFMPEG}"
dir=${1:?chapter dir}; out=${2:-$dir.mp4}
# The take's frame rate is in its events.json ("fps": 60 on a line of its own); takes from before
# it was recorded are 30fps.
fps=$(sed -n 's/^ *"fps": *\([0-9][0-9]*\).*/\1/p' "$dir/events.json" | head -n 1)
fps=${fps:-30}
if [ -f "$dir/cfr/00000.png" ]; then ext=png; codec=libx264rgb; else ext=jpg; codec=libx264; fi
# '%' in the directory is doubled: ffmpeg reads the input as a %05d sequence pattern.
"$FFMPEG" -v error -y -framerate "$fps" -i "${dir//%/%%}/cfr/%05d.$ext" \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
  -c:v "$codec" -qp 0 -preset veryfast -movflags +faststart "$out"

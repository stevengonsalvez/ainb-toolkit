#!/usr/bin/env bash
# ABOUTME: Contact sheet of an mp4 for grading a take at a glance: evenly spaced frames, tiled.
# Usage: montage.sh <in.mp4> [out.png] [cols] [rows]
set -euo pipefail
in=${1:?mp4}; out=${2:-${in%.mp4}-montage.png}; cols=${3:-4}; rows=${4:-3}
n=$(( cols * rows ))
total=$(/usr/bin/ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$in")
step=$(( total / n > 0 ? total / n : 1 ))
/usr/bin/ffmpeg -v error -y -i "$in" \
  -vf "select='not(mod(n\,$step))',scale=480:-2,tile=${cols}x${rows}:padding=4" -frames:v 1 -fps_mode vfr "$out"
echo "$out"

#!/bin/bash
# concat.sh <config.json>
# Concatenates the rendered segments in config order into the final silent mp4 and a contact sheet.
# This is the ONE lossy encode in the chain: x264 crf 16 (config "crf"), preset slow, tune animation (flat UI,
# sharp text), 4:2:0, BT.709 limited range with explicit tags, faststart for the web.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
CFG=$(realpath "$1")
# Config values are read as plain lines, never eval'd: a name or path can hold shell syntax.
{ read -r R; read -r NAME; read -r FFMPEG; read -r FFPROBE; read -r FPS; read -r CRF; } < <(cd "$D" && node -e '
const m = await import("./config.mjs"); const c = m.loadConfig(process.argv[1]);
console.log([c.out, c.name, c.ffmpeg, c.ffprobe, c.fps, c.crf].join("\n"));' "$CFG")
# Portable across bash 3.2 (macOS /bin/bash): a read loop, no bash-4 array builtins.
NAMES=()
while IFS= read -r n; do [ -n "$n" ] && NAMES+=("$n"); done < <(cd "$D" && node -e 'const m=await import("./config.mjs");const c=m.loadConfig(process.argv[1]);console.log(m.segmentNames(c).join("\n"))' "$CFG")
[ ${#NAMES[@]} -gt 0 ] || { echo "no segments in config"; exit 1; }

# Each segment is a lossless RGB mp4 (render.sh), one input each. Seams (config.mjs seams)
# overlap: the tail of one segment and the head of the next were rendered as the two halves of
# the transition, and xfade joins them: a dissolve for a blur seam, a soft-edged wipe right to
# left (with the push) for a whip. A 0s seam is a plain concat. work/timeline.json records where
# each segment starts in the final cut (for anything timed against it, such as audio).
IN=()
for n in "${NAMES[@]}"; do
  [ -f "$R/out/seg/$n.mp4" ] || { echo "missing segment: $n (run render.sh)"; exit 1; }
  IN+=(-i "$R/out/seg/$n.mp4")
done
GRAPH=$(cd "$D" && node -e '
const fs = await import("node:fs"); const cp = await import("node:child_process"); const m = await import("./config.mjs"); const c = m.loadConfig(process.argv[1]);
const names = m.segmentNames(c), seams = m.seams(c);
let f = "", acc = 0; const tl = [];
names.forEach((n, i) => {
  const frames = +cp.execFileSync(c.ffprobe, ["-v", "error", "-count_packets", "-select_streams", "v:0", "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", `${c.out}/out/seg/${n}.mp4`]).toString();
  const d = Math.round(seams[i].dur * c.fps);          // overlap in frames
  const start = acc - d; tl.push({ name: n, start: start / c.fps, dur: frames / c.fps, seam: seams[i].kind, seamDur: d / c.fps });
  if (i) f += d ? `[a${i - 1}][${i}:v]xfade=transition=${seams[i].kind === "whip" ? "smoothleft" : "fade"}:duration=${d / c.fps}:offset=${start / c.fps}[a${i}];`
                : `[a${i - 1}][${i}:v]concat=n=2:v=1:a=0[a${i}];`;
  else f += `[0:v]null[a0];`;
  acc = start + frames;
});
fs.writeFileSync(`${c.out}/work/timeline.json`, JSON.stringify({ fps: c.fps, total: acc / c.fps, segments: tl }, null, 1));
console.log(f + `[a${names.length - 1}]`);' "$CFG")
OUT=$R/out/$NAME.mp4
# The segments are sRGB colour (RGB, packed from the PNGs by render.sh), so there is no input matrix
# to guess: convert once to BT.709 limited range. setparams writes the BT.709 tags: the -color_*
# output options alone left primaries and transfer "unknown" (ffmpeg 8.1).
"$FFMPEG" -loglevel error -y "${IN[@]}" -an \
  -filter_complex "${GRAPH}scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv" \
  -c:v libx264 -preset slow -crf "$CRF" -tune animation -movflags +faststart "$OUT"
DUR=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$OUT")
"$FFMPEG" -loglevel error -y -i "$OUT" -vf "fps=12/${DUR%.*},scale=320:-1,tile=4x3" -frames:v 1 -update 1 "$R/out/$NAME-montage.png"
echo "$OUT  ${DUR}s  $(du -h "$OUT" | cut -f1)"
echo "$R/out/$NAME-montage.png"

#!/usr/bin/env bash
# Renders tagline.html to transparent video files (WebM VP9 alpha + ProRes 4444 MOV).
# Requires: playwright (python3 -m pip install playwright && playwright install chromium), ffmpeg.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
FRAMES_DIR="$ROOT/build/frames"
OUT_DIR="$ROOT/build"

mkdir -p "$FRAMES_DIR"

# Capturing below the final 1080p output resolution keeps screenshot overhead
# low enough to sample the animation at a usable frame rate in real time; the
# scale filter below upscales when encoding (the text is soft/blurred anyway).
python3 "$HERE/capture_frames.py" "$FRAMES_DIR" 1280 720
python3 "$HERE/build_concat_list.py" "$FRAMES_DIR"

cd "$FRAMES_DIR"

ffmpeg -y -f concat -safe 0 -i list.txt \
  -vf "scale=1920:1080:flags=lanczos,fps=30,format=yuva420p" \
  -c:v libvpx-vp9 -pix_fmt yuva420p -auto-alt-ref 0 -b:v 3M \
  "$OUT_DIR/tagline_transparent.webm"

ffmpeg -y -f concat -safe 0 -i list.txt \
  -vf "scale=1920:1080:flags=lanczos,fps=30,format=yuva444p10le" \
  -c:v prores_ks -profile:v 4 -pix_fmt yuva444p10le \
  "$OUT_DIR/tagline_transparent_prores4444.mov"

echo "Done:"
echo "  $OUT_DIR/tagline_transparent.webm"
echo "  $OUT_DIR/tagline_transparent_prores4444.mov"

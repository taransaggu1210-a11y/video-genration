#!/usr/bin/env bash
# Composite an overlay video onto the base background as a rounded "UI card"
# with a gold gradient border, swiping up from the bottom, holding, then
# swiping back down. Requires ffmpeg/ffprobe and the PNGs in ./assets
# (regenerate them with make_assets.py if you need a different card size,
# border thickness, or corner radius).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE=""
OVERLAY=""
OUT=""
START=2.0        # seconds into the base video when the card starts swiping up
SWIPE_DUR=0.6    # seconds the swipe-up / swipe-down transitions take

usage() {
  echo "Usage: $0 --base BASE.mp4 --overlay OVERLAY.mp4 --out OUT.mp4 [--start 2.0] [--swipe-dur 0.6]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --overlay) OVERLAY="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --start) START="$2"; shift 2 ;;
    --swipe-dur) SWIPE_DUR="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$BASE" && -n "$OVERLAY" && -n "$OUT" ]] || usage

BASE_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$BASE")
BASE_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$BASE")
BASE_DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$BASE")
OVERLAY_DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OVERLAY")

INNER_W=1152
INNER_H=$(python3 -c "print(round(${INNER_W}*9/16))")
BORDER=4
CARD_W=$((INNER_W + 2 * BORDER))
CARD_H=$((INNER_H + 2 * BORDER))
X=$(( (BASE_W - CARD_W) / 2 ))
Y_TARGET=$(( (BASE_H - CARD_H) / 2 ))
Y_HIDDEN=$BASE_H

T_IN_END=$(python3 -c "print(${START}+${SWIPE_DUR})")
T_OUT_START=$(python3 -c "print(${START}+${OVERLAY_DUR})")
T_OUT_END=$(python3 -c "print(${T_OUT_START}+${SWIPE_DUR})")

Y_EXPR="if(lt(t,${START}),${Y_HIDDEN}, if(lt(t,${T_IN_END}), ${Y_HIDDEN}-(${Y_HIDDEN}-${Y_TARGET})*(1-pow(1-(t-${START})/${SWIPE_DUR},3)), if(lt(t,${T_OUT_START}),${Y_TARGET}, if(lt(t,${T_OUT_END}), ${Y_TARGET}+(${Y_HIDDEN}-${Y_TARGET})*pow((t-${T_OUT_START})/${SWIPE_DUR},3), ${Y_HIDDEN}))))"

ffmpeg -y \
  -i "$BASE" \
  -i "$OVERLAY" \
  -loop 1 -i "${SCRIPT_DIR}/assets/gold_border.png" \
  -loop 1 -i "${SCRIPT_DIR}/assets/inner_mask.png" \
  -filter_complex "
[1:v]fps=30,scale=${INNER_W}:${INNER_H}:flags=lanczos,format=yuva420p[tsc];
[3:v]format=gray[mask];
[tsc][mask]alphamerge[trnd];
[trnd]tpad=stop_duration=${SWIPE_DUR}:stop_mode=clone[tpad];
[tpad]setpts=PTS+${START}/TB[tdelay];
[2:v]format=rgba[cardbg];
[cardbg][tdelay]overlay=x=${BORDER}:y=${BORDER}:format=auto[card];
[0:v][card]overlay=x=${X}:y='${Y_EXPR}':eof_action=pass[vout]
" \
  -map "[vout]" -map 0:a \
  -c:v libx264 -pix_fmt yuv420p -crf 18 -preset medium \
  -c:a aac -b:a 192k \
  -t "$BASE_DUR" \
  "$OUT"

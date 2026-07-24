#!/usr/bin/env bash
# Like compose_swipe_card.sh, but the overlay plays full-frame (letterboxed
# to the card's 16:9) and dynamically zooms into a specified crop window for
# a portion of its runtime, then zooms back out to full-frame. Useful for
# "show the whole recording, but zoom into this UI element while it's being
# used, then zoom back out" edits.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE=""
OVERLAY=""
OUT=""
START=2.0
SWIPE_DUR=0.6
SWIPE_DOWN_AT=""

# The tight crop to zoom into, in the overlay's native resolution: W:H:X:Y
ZOOM_CROP=""
ZOOM_IN_START=""
ZOOM_IN_END=""
ZOOM_OUT_START=""
ZOOM_OUT_END=""

usage() {
  echo "Usage: $0 --base BASE.mp4 --overlay OVERLAY.mp4 --out OUT.mp4 --zoom-crop W:H:X:Y --zoom-in-start S --zoom-in-end S --zoom-out-start S --zoom-out-end S [--start 2.0] [--swipe-dur 0.6] [--swipe-down-at SECONDS]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --overlay) OVERLAY="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --start) START="$2"; shift 2 ;;
    --swipe-dur) SWIPE_DUR="$2"; shift 2 ;;
    --swipe-down-at) SWIPE_DOWN_AT="$2"; shift 2 ;;
    --zoom-crop) ZOOM_CROP="$2"; shift 2 ;;
    --zoom-in-start) ZOOM_IN_START="$2"; shift 2 ;;
    --zoom-in-end) ZOOM_IN_END="$2"; shift 2 ;;
    --zoom-out-start) ZOOM_OUT_START="$2"; shift 2 ;;
    --zoom-out-end) ZOOM_OUT_END="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$BASE" && -n "$OVERLAY" && -n "$OUT" && -n "$ZOOM_CROP" && -n "$ZOOM_IN_START" && -n "$ZOOM_IN_END" && -n "$ZOOM_OUT_START" && -n "$ZOOM_OUT_END" ]] || usage

IFS=':' read -r ZW ZH ZX ZY <<< "$ZOOM_CROP"

BASE_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$BASE")
BASE_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$BASE")
BASE_DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$BASE")
OVERLAY_DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OVERLAY")
OVERLAY_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$OVERLAY")
OVERLAY_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$OVERLAY")

INNER_W=1408
INNER_H=$(python3 -c "print(round(${INNER_W}*9/16))")
BORDER=2
CARD_W=$((INNER_W + 2 * BORDER))
CARD_H=$((INNER_H + 2 * BORDER))
X=$(( (BASE_W - CARD_W) / 2 ))
Y_TARGET=$(( (BASE_H - CARD_H) / 2 ))
Y_HIDDEN=$BASE_H

T_IN_END=$(python3 -c "print(${START}+${SWIPE_DUR})")
if [[ -n "$SWIPE_DOWN_AT" ]]; then
  T_OUT_START="$SWIPE_DOWN_AT"
else
  T_OUT_START=$(python3 -c "print(${START}+${OVERLAY_DUR})")
fi
T_OUT_END=$(python3 -c "print(${T_OUT_START}+${SWIPE_DUR})")

Y_EXPR="if(lt(t,${START}),${Y_HIDDEN}, if(lt(t,${T_IN_END}), ${Y_HIDDEN}-(${Y_HIDDEN}-${Y_TARGET})*(1-pow(1-(t-${START})/${SWIPE_DUR},3)), if(lt(t,${T_OUT_START}),${Y_TARGET}, if(lt(t,${T_OUT_END}), ${Y_TARGET}+(${Y_HIDDEN}-${Y_TARGET})*pow((t-${T_OUT_START})/${SWIPE_DUR},3), ${Y_HIDDEN}))))"

ZOOM_IN_DUR=$(python3 -c "print(${ZOOM_IN_END}-${ZOOM_IN_START})")
ZOOM_OUT_DUR=$(python3 -c "print(${ZOOM_OUT_END}-${ZOOM_OUT_START})")
Z="if(lt(t,${ZOOM_IN_START}),0, if(lt(t,${ZOOM_IN_END}),1-pow(1-(t-${ZOOM_IN_START})/${ZOOM_IN_DUR},3), if(lt(t,${ZOOM_OUT_START}),1, if(lt(t,${ZOOM_OUT_END}),1-pow((t-${ZOOM_OUT_START})/${ZOOM_OUT_DUR},3), 0))))"

# The crop filter's w/h are only evaluated once (at init) in this ffmpeg build,
# so a time-varying crop SIZE doesn't work -- only x/y are re-evaluated per
# frame. Instead: pad the source to the card's 16:9 aspect once (static), then
# dynamically SCALE the whole padded canvas by a per-frame zoom factor (scale
# supports eval=frame), and take a FIXED-size (card-size) crop whose x/y pans
# to the target region as the scale grows. This reaches the same visual
# result -- full frame at zoom=0, filling the target box at zoom=1 -- without
# needing crop's w/h to be dynamic.
PAD_W=$OVERLAY_W
PAD_H=$(python3 -c "print(round(${OVERLAY_W}*9/16))")
PAD_OFF_Y=$(python3 -c "print((${PAD_H}-${OVERLAY_H})/2)")
ZY_PADDED=$(python3 -c "print(${ZY}+${PAD_OFF_Y})")

S_WIDE=$(python3 -c "print(${INNER_W}/${PAD_W})")
S_TIGHT=$(python3 -c "print(${INNER_W}/${ZW})")
S="(${S_WIDE}+(${S_TIGHT}-${S_WIDE})*(${Z}))"

SCALE_W_EXPR="trunc(${PAD_W}*${S}/2)*2"
SCALE_H_EXPR="trunc(${PAD_H}*${S}/2)*2"
CROP_X_EXPR="${ZX}*(${Z})*(${S})"
CROP_Y_EXPR="${ZY_PADDED}*(${Z})*(${S})"

ffmpeg -y \
  -i "$BASE" \
  -i "$OVERLAY" \
  -loop 1 -i "${SCRIPT_DIR}/assets/gold_border.png" \
  -loop 1 -i "${SCRIPT_DIR}/assets/inner_mask.png" \
  -filter_complex "
[1:v]pad=${PAD_W}:${PAD_H}:0:${PAD_OFF_Y}:color=black,scale=w='${SCALE_W_EXPR}':h='${SCALE_H_EXPR}':eval=frame,crop=w=${INNER_W}:h=${INNER_H}:x='${CROP_X_EXPR}':y='${CROP_Y_EXPR}',fps=30,format=yuva420p[tsc];
[3:v]format=gray[mask];
[tsc][mask]alphamerge[trnd];
[trnd]tpad=stop_duration=${SWIPE_DUR}:stop_mode=clone[tpad];
[tpad]setpts=PTS+${START}/TB[tdelay];
[2:v]format=rgba[cardbg];
[cardbg][tdelay]overlay=x=${BORDER}:y=${BORDER}:format=auto[card];
[0:v][card]overlay=x=${X}:y='${Y_EXPR}':eof_action=pass[vout]
" \
  -map "[vout]" -map 0:a \
  -c:v libx264 -pix_fmt yuv420p -crf 14 -preset slow \
  -c:a aac -b:a 256k \
  -t "$BASE_DUR" \
  "$OUT"

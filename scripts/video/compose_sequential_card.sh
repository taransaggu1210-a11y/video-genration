#!/usr/bin/env bash
# Like compose_swipe_card.sh, but plays two overlay clips back-to-back inside
# the same still card: overlay1 from the swipe-up until --switch-at (output
# timeline), then overlay2 from --switch-at for its own full duration. The
# card swipes up once at --start and (by default) never swipes back down --
# pass --swipe-down-at to add one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE=""
OVERLAY1=""
OVERLAY2=""
OUT=""
START=2.0
SWIPE_DUR=0.6
SWITCH_AT=""     # output-timeline second overlay2 takes over from overlay1
SWIPE_DOWN_AT=""
PAD_TOP=""; PAD_BOTTOM=""; PAD_LEFT=""; PAD_RIGHT=""

usage() {
  echo "Usage: $0 --base BASE.mp4 --overlay1 A.mp4 --overlay2 B.mp4 --switch-at SECONDS --out OUT.mp4 [--start 2.0] [--swipe-dur 0.6] [--swipe-down-at SECONDS] [--pad-top PX --pad-bottom PX --pad-left PX --pad-right PX]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --overlay1) OVERLAY1="$2"; shift 2 ;;
    --overlay2) OVERLAY2="$2"; shift 2 ;;
    --switch-at) SWITCH_AT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --start) START="$2"; shift 2 ;;
    --swipe-dur) SWIPE_DUR="$2"; shift 2 ;;
    --swipe-down-at) SWIPE_DOWN_AT="$2"; shift 2 ;;
    --pad-top) PAD_TOP="$2"; shift 2 ;;
    --pad-bottom) PAD_BOTTOM="$2"; shift 2 ;;
    --pad-left) PAD_LEFT="$2"; shift 2 ;;
    --pad-right) PAD_RIGHT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$BASE" && -n "$OVERLAY1" && -n "$OVERLAY2" && -n "$OUT" && -n "$SWITCH_AT" ]] || usage

BASE_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$BASE")
BASE_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$BASE")
BASE_DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$BASE")
OVERLAY2_DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OVERLAY2")

# how long overlay1 actually plays before the switch
OVERLAY1_SHOWN_DUR=$(python3 -c "print(${SWITCH_AT}-${START})")

BORDER=$(python3 -c "print(max(2, round(${BASE_W}*0.00125)))")
if [[ -n "$PAD_TOP" && -n "$PAD_BOTTOM" && -n "$PAD_LEFT" && -n "$PAD_RIGHT" ]]; then
  CARD_W=$((BASE_W - PAD_LEFT - PAD_RIGHT))
  CARD_H=$((BASE_H - PAD_TOP - PAD_BOTTOM))
  X=$PAD_LEFT
  Y_TARGET=$PAD_TOP
else
  INNER_W=$(python3 -c "print(round(${BASE_W}*0.94/2)*2)")
  INNER_H=$(python3 -c "print(round(${INNER_W}*9/16))")
  CARD_W=$((INNER_W + 2 * BORDER))
  CARD_H=$((INNER_H + 2 * BORDER))
  X=$(( (BASE_W - CARD_W) / 2 ))
  Y_TARGET=$(( (BASE_H - CARD_H) / 2 ))
fi
INNER_W=$((CARD_W - 2 * BORDER))
INNER_H=$((CARD_H - 2 * BORDER))
INNER_W=$((INNER_W - INNER_W % 2))
INNER_H=$((INNER_H - INNER_H % 2))
Y_HIDDEN=$BASE_H

ASSET_DIR="$(mktemp -d)"
trap 'rm -rf "$ASSET_DIR"' EXIT
python3 "${SCRIPT_DIR}/make_assets.py" "$INNER_W" "$BORDER" "$ASSET_DIR" "$INNER_H" >/dev/null

T_IN_END=$(python3 -c "print(${START}+${SWIPE_DUR})")
if [[ -n "$SWIPE_DOWN_AT" ]]; then
  T_OUT_START="$SWIPE_DOWN_AT"
else
  T_OUT_START=$(python3 -c "print(${START}+${OVERLAY1_SHOWN_DUR}+${OVERLAY2_DUR})")
fi
T_OUT_END=$(python3 -c "print(${T_OUT_START}+${SWIPE_DUR})")

Y_EXPR="if(lt(t,${START}),${Y_HIDDEN}, if(lt(t,${T_IN_END}), ${Y_HIDDEN}-(${Y_HIDDEN}-${Y_TARGET})*(1-pow(1-(t-${START})/${SWIPE_DUR},3)), if(lt(t,${T_OUT_START}),${Y_TARGET}, if(lt(t,${T_OUT_END}), ${Y_TARGET}+(${Y_HIDDEN}-${Y_TARGET})*pow((t-${T_OUT_START})/${SWIPE_DUR},3), ${Y_HIDDEN}))))"

ffmpeg -y \
  -i "$BASE" \
  -i "$OVERLAY1" \
  -i "$OVERLAY2" \
  -loop 1 -i "${ASSET_DIR}/gold_border.png" \
  -loop 1 -i "${ASSET_DIR}/inner_mask.png" \
  -filter_complex "
[1:v]trim=0:${OVERLAY1_SHOWN_DUR},setpts=PTS-STARTPTS,fps=30,scale=${INNER_W}:${INNER_H}:flags=lanczos:force_original_aspect_ratio=decrease,pad=${INNER_W}:${INNER_H}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,format=yuva420p[v1proc];
[2:v]fps=30,scale=${INNER_W}:${INNER_H}:flags=lanczos:force_original_aspect_ratio=decrease,pad=${INNER_W}:${INNER_H}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,format=yuva420p[v2proc];
[v1proc][v2proc]concat=n=2:v=1:a=0[vseq];
[4:v]format=gray[mask];
[vseq][mask]alphamerge[trnd];
[trnd]tpad=stop_duration=${SWIPE_DUR}:stop_mode=clone[tpad];
[tpad]setpts=PTS+${START}/TB[tdelay];
[3:v]format=rgba[cardbg];
[cardbg][tdelay]overlay=x=${BORDER}:y=${BORDER}:format=rgb[card];
[0:v][card]overlay=x=${X}:y='${Y_EXPR}':eof_action=pass:format=rgb[vout]
" \
  -map "[vout]" -map 0:a \
  -c:v libx264 -pix_fmt yuv420p -crf 14 -preset slow \
  -c:a aac -b:a 256k \
  -t "$BASE_DUR" \
  "$OUT"

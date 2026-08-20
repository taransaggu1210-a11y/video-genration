#!/usr/bin/env bash
# General N-clip version of compose_sequential_card.sh: plays any number of
# overlay clips back-to-back inside one still card, crossfading (or hard
# cutting) between them at the given switch points. The card swipes up once
# at --start and (by default) never swipes back down -- pass --swipe-down-at
# to add one.
#
# Usage:
#   compose_multi_card.sh --base BASE.mp4 --out OUT.mp4 \
#     --clip A.mp4 --clip B.mp4 --clip C.mp4 \
#     --switch-at 7.5 --switch-at 32 \
#     [--start 2.0] [--swipe-dur 0.6] [--transition-dur 0.6] [--swipe-down-at S] \
#     [--pad-top PX --pad-bottom PX --pad-left PX --pad-right PX]
#
# --switch-at must appear exactly (number of --clip) - 1 times, in order --
# the output-timeline second each clip hands off to the next.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE=""
OUT=""
START=2.0
SWIPE_DUR=0.6
TRANSITION_DUR=0
SWIPE_DOWN_AT=""
PAD_TOP=""; PAD_BOTTOM=""; PAD_LEFT=""; PAD_RIGHT=""
CLIPS=()
SWITCHES=()

usage() {
  echo "Usage: $0 --base BASE.mp4 --out OUT.mp4 --clip A.mp4 [--clip B.mp4 ...] --switch-at S [--switch-at S ...] [--start 2.0] [--swipe-dur 0.6] [--transition-dur 0.6] [--swipe-down-at SECONDS] [--pad-top PX --pad-bottom PX --pad-left PX --pad-right PX]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --clip) CLIPS+=("$2"); shift 2 ;;
    --switch-at) SWITCHES+=("$2"); shift 2 ;;
    --start) START="$2"; shift 2 ;;
    --swipe-dur) SWIPE_DUR="$2"; shift 2 ;;
    --transition-dur) TRANSITION_DUR="$2"; shift 2 ;;
    --swipe-down-at) SWIPE_DOWN_AT="$2"; shift 2 ;;
    --pad-top) PAD_TOP="$2"; shift 2 ;;
    --pad-bottom) PAD_BOTTOM="$2"; shift 2 ;;
    --pad-left) PAD_LEFT="$2"; shift 2 ;;
    --pad-right) PAD_RIGHT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

N=${#CLIPS[@]}
[[ -n "$BASE" && -n "$OUT" && "$N" -ge 1 && "${#SWITCHES[@]}" -eq $((N - 1)) ]] || usage

BASE_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$BASE")
BASE_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$BASE")
BASE_DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$BASE")
LAST_CLIP_DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "${CLIPS[$((N - 1))]}")

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

# input indices: 0=base, 1..N=clips, N+1=border, N+2=mask
BORDER_IN=$((N + 1))
MASK_IN=$((N + 2))

# --- per-clip processed chains + each clip's shown duration ---
FILTER=""
SHOWN=()
PREV_T="$START"
for ((i = 0; i < N - 1; i++)); do
  d=$(python3 -c "print(${SWITCHES[$i]}-${PREV_T})")
  SHOWN+=("$d")
  PREV_T="${SWITCHES[$i]}"
  FILTER+="[$((i + 1)):v]trim=0:${d},setpts=PTS-STARTPTS,fps=30,scale=${INNER_W}:${INNER_H}:flags=lanczos:force_original_aspect_ratio=decrease,pad=${INNER_W}:${INNER_H}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1[p${i}];
"
done
SHOWN+=("$LAST_CLIP_DUR")
FILTER+="[${N}:v]fps=30,scale=${INNER_W}:${INNER_H}:flags=lanczos:force_original_aspect_ratio=decrease,pad=${INNER_W}:${INNER_H}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1[p$((N - 1))];
"

# --- chain the clips together, either hard-cut (concat) or xfade ---
if python3 -c "exit(0 if ${TRANSITION_DUR} > 0 else 1)"; then
  CUR="p0"
  CUM="${SHOWN[0]}"
  for ((i = 1; i < N; i++)); do
    OFFSET=$(python3 -c "print(${CUM}-${TRANSITION_DUR})")
    NEXT="m${i}"
    FILTER+="[${CUR}][p${i}]xfade=transition=fade:duration=${TRANSITION_DUR}:offset=${OFFSET}[${NEXT}];
"
    CUR="$NEXT"
    CUM=$(python3 -c "print(${OFFSET}+${TRANSITION_DUR}+${SHOWN[$i]}-${TRANSITION_DUR})")
  done
  TOTAL_SHOWN="$CUM"
  FILTER+="[${CUR}]format=yuva420p[vseq];
"
else
  INPUTS=""
  for ((i = 0; i < N; i++)); do INPUTS+="[p${i}]"; done
  FILTER+="${INPUTS}concat=n=${N}:v=1:a=0,format=yuva420p[vseq];
"
  TOTAL_SHOWN=0
  for d in "${SHOWN[@]}"; do TOTAL_SHOWN=$(python3 -c "print(${TOTAL_SHOWN}+${d})"); done
fi

T_IN_END=$(python3 -c "print(${START}+${SWIPE_DUR})")
if [[ -n "$SWIPE_DOWN_AT" ]]; then
  T_OUT_START="$SWIPE_DOWN_AT"
else
  T_OUT_START=$(python3 -c "print(${START}+${TOTAL_SHOWN})")
fi
T_OUT_END=$(python3 -c "print(${T_OUT_START}+${SWIPE_DUR})")

Y_EXPR="if(lt(t,${START}),${Y_HIDDEN}, if(lt(t,${T_IN_END}), ${Y_HIDDEN}-(${Y_HIDDEN}-${Y_TARGET})*(1-pow(1-(t-${START})/${SWIPE_DUR},3)), if(lt(t,${T_OUT_START}),${Y_TARGET}, if(lt(t,${T_OUT_END}), ${Y_TARGET}+(${Y_HIDDEN}-${Y_TARGET})*pow((t-${T_OUT_START})/${SWIPE_DUR},3), ${Y_HIDDEN}))))"

FILTER+="[${BORDER_IN}:v]format=rgba[cardbg];
[${MASK_IN}:v]format=gray[mask];
[vseq][mask]alphamerge[trnd];
[trnd]tpad=stop_duration=${SWIPE_DUR}:stop_mode=clone[tpad];
[tpad]setpts=PTS+${START}/TB[tdelay];
[cardbg][tdelay]overlay=x=${BORDER}:y=${BORDER}:format=rgb[card];
[0:v][card]overlay=x=${X}:y='${Y_EXPR}':eof_action=pass:format=rgb[vout]"

CLIP_INPUT_ARGS=()
for c in "${CLIPS[@]}"; do CLIP_INPUT_ARGS+=(-i "$c"); done

ffmpeg -y \
  -i "$BASE" \
  "${CLIP_INPUT_ARGS[@]}" \
  -loop 1 -i "${ASSET_DIR}/gold_border.png" \
  -loop 1 -i "${ASSET_DIR}/inner_mask.png" \
  -filter_complex "$FILTER" \
  -map "[vout]" -map 0:a \
  -c:v libx264 -pix_fmt yuv420p -crf 14 -preset slow \
  -c:a aac -b:a 256k \
  -t "$BASE_DUR" \
  "$OUT"

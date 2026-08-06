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
SWIPE_DOWN_AT="" # output-timeline second the swipe-down begins; default = START + overlay duration
TRIM_START=""    # seconds to trim off the start of the overlay before compositing
TRIM_DUR=""      # seconds of overlay to keep after trimming (default: to end of clip)
CROP=""          # optional "w:h:x:y" crop (in the overlay's native resolution) applied before scaling, i.e. a zoom
PAD_TOP=""; PAD_BOTTOM=""; PAD_LEFT=""; PAD_RIGHT=""  # exact card padding in px; overrides the proportional sizing

usage() {
  echo "Usage: $0 --base BASE.mp4 --overlay OVERLAY.mp4 --out OUT.mp4 [--start 2.0] [--swipe-dur 0.6] [--swipe-down-at SECONDS] [--trim-start SECONDS] [--trim-dur SECONDS] [--crop W:H:X:Y] [--pad-top PX --pad-bottom PX --pad-left PX --pad-right PX]"
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
    --trim-start) TRIM_START="$2"; shift 2 ;;
    --trim-dur) TRIM_DUR="$2"; shift 2 ;;
    --crop) CROP="$2"; shift 2 ;;
    --pad-top) PAD_TOP="$2"; shift 2 ;;
    --pad-bottom) PAD_BOTTOM="$2"; shift 2 ;;
    --pad-left) PAD_LEFT="$2"; shift 2 ;;
    --pad-right) PAD_RIGHT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$BASE" && -n "$OVERLAY" && -n "$OUT" ]] || usage

BASE_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$BASE")
BASE_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$BASE")
BASE_DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$BASE")
OVERLAY_FULL_DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OVERLAY")

TRIM_START="${TRIM_START:-0}"
if [[ -n "$TRIM_DUR" ]]; then
  OVERLAY_DUR="$TRIM_DUR"
else
  OVERLAY_DUR=$(python3 -c "print(${OVERLAY_FULL_DUR}-${TRIM_START})")
fi

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
# yuv420p requires even dimensions; an odd INNER_H/INNER_W makes ffmpeg's
# scale+pad silently round to a different size than the (odd) mask PNG,
# breaking alphamerge. Round down to even -- at most 1px absorbed into the
# bottom/right gap, imperceptible.
INNER_W=$((INNER_W - INNER_W % 2))
INNER_H=$((INNER_H - INNER_H % 2))
Y_HIDDEN=$BASE_H

# Regenerate the border/mask assets sized for this base resolution's card
# (cheap, ~1s) so the card looks identical regardless of BASE_W.
ASSET_DIR="$(mktemp -d)"
trap 'rm -rf "$ASSET_DIR"' EXIT
python3 "${SCRIPT_DIR}/make_assets.py" "$INNER_W" "$BORDER" "$ASSET_DIR" "$INNER_H" >/dev/null

T_IN_END=$(python3 -c "print(${START}+${SWIPE_DUR})")
if [[ -n "$SWIPE_DOWN_AT" ]]; then
  T_OUT_START="$SWIPE_DOWN_AT"
else
  T_OUT_START=$(python3 -c "print(${START}+${OVERLAY_DUR})")
fi
T_OUT_END=$(python3 -c "print(${T_OUT_START}+${SWIPE_DUR})")

Y_EXPR="if(lt(t,${START}),${Y_HIDDEN}, if(lt(t,${T_IN_END}), ${Y_HIDDEN}-(${Y_HIDDEN}-${Y_TARGET})*(1-pow(1-(t-${START})/${SWIPE_DUR},3)), if(lt(t,${T_OUT_START}),${Y_TARGET}, if(lt(t,${T_OUT_END}), ${Y_TARGET}+(${Y_HIDDEN}-${Y_TARGET})*pow((t-${T_OUT_START})/${SWIPE_DUR},3), ${Y_HIDDEN}))))"

if [[ -n "$CROP" ]]; then
  CROP_FILTER="crop=${CROP},"
else
  CROP_FILTER=""
fi

OVERLAY_INPUT_ARGS=(-ss "$TRIM_START" -i "$OVERLAY")
if [[ -n "$TRIM_DUR" ]]; then
  OVERLAY_INPUT_ARGS=(-ss "$TRIM_START" -t "$TRIM_DUR" -i "$OVERLAY")
fi

ffmpeg -y \
  -i "$BASE" \
  "${OVERLAY_INPUT_ARGS[@]}" \
  -loop 1 -i "${ASSET_DIR}/gold_border.png" \
  -loop 1 -i "${ASSET_DIR}/inner_mask.png" \
  -filter_complex "
[1:v]${CROP_FILTER}fps=30,scale=${INNER_W}:${INNER_H}:flags=lanczos:force_original_aspect_ratio=decrease,pad=${INNER_W}:${INNER_H}:(ow-iw)/2:(oh-ih)/2:color=black,format=yuva420p[tsc];
[3:v]format=gray[mask];
[tsc][mask]alphamerge[trnd];
[trnd]tpad=stop_duration=${SWIPE_DUR}:stop_mode=clone[tpad];
[tpad]setpts=PTS+${START}/TB[tdelay];
[2:v]format=rgba[cardbg];
[cardbg][tdelay]overlay=x=${BORDER}:y=${BORDER}:format=rgb[card];
[0:v][card]overlay=x=${X}:y='${Y_EXPR}':eof_action=pass:format=rgb[vout]
" \
  -map "[vout]" -map 0:a \
  -c:v libx264 -pix_fmt yuv420p -crf 14 -preset slow \
  -c:a aac -b:a 256k \
  -t "$BASE_DUR" \
  "$OUT"

#!/usr/bin/env bash
# vhs_audio_cleanup.sh
#
# Heavier standalone audio cleanup pass: mains-hum notch + SoX noisered,
# for tapes whose line noise/hum isn't fully handled by denoise.sh's light
# NOISERED_ENABLE pass. Video is always copied bit-exact; audio stays PCM.
#
# Not wired into the pipeline — run by hand against any archival/stabilized/
# viewer MKV that still sounds noisy after the normal denoise step.
#
# Usage:
#   vhs_audio_cleanup.sh INPUT.mkv OUTPUT.mkv
#
# Environment overrides:
#   HUM_ENABLE      1|0 (default 1)              -- notch mains hum + harmonics
#   HUM_HZ          mains hum fundamental (default 60; use 50 for PAL sources)
#   NOISE_SS        noise sample start (default 00:00:00)
#   NOISE_T         noise sample duration (default 00:00:01.0)
#   NR_AMOUNT       SoX noisered amount (default 0.25)
#   NORM_DB         SoX norm target dBFS; "off" disables (default -1)
#   THREADS         ffmpeg -threads (default nproc)
#   FFMPEG_BIN      ffmpeg binary (default: first found in PATH)
#   SOX_BIN         sox binary (default: first found in PATH)
#
set -euo pipefail

usage() {
  cat <<'USAGE'
USAGE:
  vhs_audio_cleanup.sh INPUT.mkv OUTPUT.mkv

Example:
  HUM_HZ=50 NR_AMOUNT=0.3 vhs_audio_cleanup.sh in.mkv out.mkv

Notes:
  - Always outputs PCM (pcm_s16le) and copies video bit-exact (-c:v copy).
  - HUM_ENABLE=1 (default) notches HUM_HZ and its 2nd/3rd harmonics.
  - INPUT and OUTPUT may be the same path: output is built in a temp file
    beside OUTPUT and atomically renamed into place.
USAGE
}

if [[ $# -lt 2 ]]; then usage; exit 1; fi

IN=$1
OUT=$2

HUM_ENABLE="${HUM_ENABLE:-1}"
HUM_HZ="${HUM_HZ:-60}"

NOISE_SS="${NOISE_SS:-00:00:00}"
NOISE_T="${NOISE_T:-00:00:01.0}"
NR_AMOUNT="${NR_AMOUNT:-0.25}"

NORM_DB="${NORM_DB:--1}"
THREADS="${THREADS:-$(nproc)}"

HPF_ENABLE="${HPF_ENABLE:-1}"
HPF_HZ="${HPF_HZ:-20}"

TS_REBASE="${TS_REBASE:-1}"
FORCE_AR="${FORCE_AR:-48000}"
FORCE_AC="${FORCE_AC:-2}"

[[ -f "$IN" ]] || { echo "ERROR: Input not found: $IN" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

FFMPEG_BIN=${FFMPEG_BIN:-$(command -v ffmpeg || true)}
SOX_BIN=${SOX_BIN:-$(command -v sox || true)}

if [[ -z "$FFMPEG_BIN" || ! -x "$FFMPEG_BIN" ]]; then
  echo "ERROR: ffmpeg not found in PATH (set FFMPEG_BIN)" >&2
  exit 1
fi
if [[ -z "$SOX_BIN" || ! -x "$SOX_BIN" ]]; then
  echo "ERROR: sox not found in PATH. Install with: sudo apt-get install sox" >&2
  exit 1
fi

AF_CHAIN=()
if [[ "$HPF_ENABLE" == "1" ]]; then
  AF_CHAIN+=("highpass=f=${HPF_HZ}")
fi
if [[ "$TS_REBASE" == "1" ]]; then
  AF_CHAIN+=("aresample=async=0:first_pts=0" "asetpts=N/SR/TB")
fi

AF_OPT=()
if [[ ${#AF_CHAIN[@]} -gt 0 ]]; then
  AF_OPT=(-af "$(IFS=,; echo "${AF_CHAIN[*]}")")
fi

AC_OPT=()
AR_OPT=()
if [[ -n "${FORCE_AC:-}" && "${FORCE_AC}" != "0" ]]; then AC_OPT=(-ac "$FORCE_AC"); fi
if [[ -n "${FORCE_AR:-}" && "${FORCE_AR}" != "0" ]]; then AR_OPT=(-ar "$FORCE_AR"); fi

workdir=$(mktemp -d)
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

full_wav="$workdir/full.wav"
hum_wav="$workdir/hum.wav"
sample_wav="$workdir/noise_sample.wav"
noise_prof="$workdir/noise.prof"
clean_wav="$workdir/clean.wav"
norm_wav="$clean_wav"

echo "Audio cleanup (hum notch + noisered, PCM)"
echo "  IN:          $IN"
echo "  OUT:         $OUT"
echo "  HUM_ENABLE:  $HUM_ENABLE (Hz=$HUM_HZ)"
echo "  NOISE_SS/T:  $NOISE_SS / $NOISE_T"
echo "  NR_AMOUNT:   $NR_AMOUNT"
echo "  NORM_DB:     $NORM_DB"
echo "  THREADS:     $THREADS"
echo

# 1) Extract full audio as 48 kHz stereo WAV for deterministic processing.
"$FFMPEG_BIN" -hide_banner -nostdin -y \
  -fflags +genpts -i "$IN" \
  -vn -map 0:a:0 \
  "${AF_OPT[@]}" \
  "${AC_OPT[@]}" "${AR_OPT[@]}" \
  -c:a pcm_s16le \
  -threads "$THREADS" \
  "$full_wav"

# 2) Optional mains-hum notch (fundamental + 2nd/3rd harmonics).
stage_in="$full_wav"
if [[ "$HUM_ENABLE" == "1" ]]; then
  "$SOX_BIN" "$full_wav" "$hum_wav" \
    bandreject "$HUM_HZ" 2q \
    bandreject "$((HUM_HZ * 2))" 2q \
    bandreject "$((HUM_HZ * 3))" 2q
  stage_in="$hum_wav"
fi

# 3) Broadband noise reduction via SoX noiseprof/noisered.
"$FFMPEG_BIN" -hide_banner -nostdin -y \
  -fflags +genpts \
  -ss "$NOISE_SS" -t "$NOISE_T" \
  -i "$IN" \
  -vn -map 0:a:0 \
  "${AF_OPT[@]}" \
  "${AC_OPT[@]}" "${AR_OPT[@]}" \
  -c:a pcm_s16le \
  -threads "$THREADS" \
  "$sample_wav"
"$SOX_BIN" "$sample_wav" -n noiseprof "$noise_prof"
"$SOX_BIN" "$stage_in" "$clean_wav" noisered "$noise_prof" "$NR_AMOUNT"

# 4) Optional normalization.
case "${NORM_DB,,}" in
  ""|"off"|"none"|"0") ;;
  *)
    norm_wav="$workdir/norm.wav"
    "$SOX_BIN" "$clean_wav" "$norm_wav" norm "$NORM_DB"
    ;;
esac

# 5) Mux: copy video bit-exact, replace audio with cleaned PCM. Build in a
#    temp file beside OUTPUT so INPUT == OUTPUT is safe (atomic rename).
out_tmp="$(dirname "$OUT")/.$(basename "$OUT").cleanup.tmp.mkv"
"$FFMPEG_BIN" -hide_banner -nostdin -y \
  -fflags +genpts -i "$IN" \
  -fflags +genpts -i "$norm_wav" \
  -map 0:v:0 -map 1:a:0 \
  -c:v copy \
  -c:a pcm_s16le \
  -avoid_negative_ts make_zero \
  -shortest \
  "$out_tmp"
mv -f "$out_tmp" "$OUT"

echo
echo "Done. Output: $OUT"

#!/usr/bin/env bash
# test_audio_cleanup.sh
#
# Self-contained correctness test for vhs_audio_cleanup.sh. Builds a
# synthetic noisy+hummy MKV entirely via ffmpeg lavfi (no fixtures on disk),
# runs the cleanup script, and checks: output exists, audio is PCM,
# duration is preserved, and 60Hz hum energy is measurably reduced.
#
# Usage: ./test_audio_cleanup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SH="$SCRIPT_DIR/vhs_audio_cleanup.sh"

FFMPEG_BIN=${FFMPEG_BIN:-$(command -v ffmpeg)}
DUR=3

workdir=$(mktemp -d)
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

noisy="$workdir/test_noisy.mkv"
clean="$workdir/test_clean.mkv"

# The hum tone is delayed to start AFTER the 1s noise-sample window
# vhs_audio_cleanup.sh uses to build its noiseprof (NOISE_T default
# 00:00:01.0). If it started from t=0, noisered's own profile would
# capture the hum and partially suppress it too, making it impossible to
# tell whether the dedicated hum-notch stage did anything -- confirmed by
# testing this in practice with HUM_ENABLE=0.
echo "Building synthetic test input (tone + delayed 60Hz hum + broadband noise)..."
"$FFMPEG_BIN" -hide_banner -nostdin -y -loglevel error \
  -f lavfi -i "sine=frequency=440:duration=${DUR}" \
  -f lavfi -i "sine=frequency=60:duration=$((DUR - 1))" \
  -f lavfi -i "anoisesrc=duration=${DUR}:amplitude=0.05" \
  -f lavfi -i "color=c=black:s=64x64:d=${DUR}" \
  -filter_complex "[1:a]adelay=1000|1000[hum];[0:a][hum][2:a]amix=inputs=3:duration=first:dropout_transition=0[aout]" \
  -map 3:v -map "[aout]" \
  -c:v libx264 -pix_fmt yuv420p \
  -c:a pcm_s16le \
  -t "$DUR" \
  "$noisy"

fail() { echo "Test failed: $1" >&2; exit 1; }

# Measure RMS only within the window where the synthetic hum lives (1s-3s),
# and skip sox's own norm stage for this test (NORM_DB=off): peak
# normalization would rescale the whole clip's amplitude and swamp the
# before/after hum comparison independent of whether the notch worked.
hum_rms() {
  "$FFMPEG_BIN" -hide_banner -nostdin -loglevel info -ss 1 -t 2 -i "$1" \
    -af "bandpass=f=60:width_type=q:w=2,astats" -f null - 2>&1 \
    | grep -m1 "RMS level dB" | awk '{print $NF}'
}

echo "Running vhs_audio_cleanup.sh..."
NORM_DB=off "$CLEANUP_SH" "$noisy" "$clean"

[[ -f "$clean" ]] || fail "output file not created"

if ! ffprobe -hide_banner -loglevel error -select_streams a:0 -show_entries stream=codec_name \
     -of default=noprint_wrappers=1:nokey=1 "$clean" | grep -q '^pcm_s16le$'; then
  fail "output audio is not pcm_s16le"
fi

in_dur=$(ffprobe -hide_banner -loglevel error -select_streams v:0 -show_entries stream=duration \
  -of default=noprint_wrappers=1:nokey=1 "$noisy")
out_dur=$(ffprobe -hide_banner -loglevel error -select_streams v:0 -show_entries stream=duration \
  -of default=noprint_wrappers=1:nokey=1 "$clean")
delta=$(echo "$in_dur $out_dur" | awk '{d=$1-$2; if (d<0) d=-d; print d}')
if (( $(echo "$delta > 0.2" | bc -l) )); then
  fail "duration drifted: in=$in_dur out=$out_dur delta=$delta"
fi

before=$(hum_rms "$noisy")
after=$(hum_rms "$clean")
echo "60Hz-band RMS: before=${before} dB  after=${after} dB"
if [[ -z "$before" || -z "$after" ]]; then
  fail "could not measure 60Hz RMS (astats output missing)"
fi
# RMS is in dBFS (negative, closer to 0 = louder). Cleanup must make it
# quieter (more negative) by a clearly-real margin. Threshold is set well
# above what noisered's generic broadband suppression achieves on its own
# (observed ~3dB with HUM_ENABLE=0) so this only passes when the dedicated
# notch stage actually ran (observed ~37dB with HUM_ENABLE=1).
improved=$(echo "$before $after" | awk '{print ($2 < $1 - 15.0)}')
if [[ "$improved" != "1" ]]; then
  fail "60Hz hum not measurably reduced (before=$before after=$after, need >=15dB drop)"
fi

echo "Test passed"

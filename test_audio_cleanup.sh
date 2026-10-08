#!/usr/bin/env bash
# test_audio_cleanup.sh
#
# Self-contained correctness test for vhs_audio_cleanup.sh. Builds a
# synthetic noisy+hummy MKV entirely via ffmpeg lavfi (no fixtures on disk),
# runs the cleanup script, and checks: output exists, audio is PCM,
# duration is preserved, and 60Hz hum energy is measurably reduced. A second
# case feeds audio shorter than the video and checks no video frames are lost.
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

is_number() { [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; }

# Video stream duration in seconds, using the same fallback chain as
# vhs_fix_sync.sh: stream duration, DURATION tag, duration_ts * time_base,
# then format duration. ffmpeg-made MKV reports stream duration as N/A.
video_duration() {
  local f=$1 d tag dts tb
  d=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration \
        -of default=nk=1:nw=1 "$f" | head -n1 || true)
  if is_number "$d"; then echo "$d"; return 0; fi

  tag=$(ffprobe -v error -select_streams v:0 -show_entries stream_tags=DURATION \
          -of default=nk=1:nw=1 "$f" | head -n1 || true)
  if [[ "$tag" =~ ^([0-9]+):([0-9]+):([0-9.]+)$ ]]; then
    awk -v h="${BASH_REMATCH[1]}" -v m="${BASH_REMATCH[2]}" -v s="${BASH_REMATCH[3]}" \
      'BEGIN { printf "%.8f\n", h * 3600 + m * 60 + s }'
    return 0
  fi

  dts=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration_ts \
          -of default=nk=1:nw=1 "$f" | head -n1 || true)
  tb=$(ffprobe -v error -select_streams v:0 -show_entries stream=time_base \
         -of default=nk=1:nw=1 "$f" | head -n1 || true)
  if is_number "$dts" && [[ "$tb" =~ ^([0-9]+)/([0-9]+)$ && "${BASH_REMATCH[2]}" != 0 ]]; then
    awk -v dts="$dts" -v n="${BASH_REMATCH[1]}" -v d="${BASH_REMATCH[2]}" \
      'BEGIN { printf "%.8f\n", dts * n / d }'
    return 0
  fi

  d=$(ffprobe -v error -show_entries format=duration \
        -of default=nk=1:nw=1 "$f" | head -n1 || true)
  if is_number "$d"; then echo "$d"; return 0; fi
  return 1
}

video_packets() {
  ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets \
    -of default=nk=1:nw=1 "$1"
}

# Video must come through whole: same duration (within 0.2s) and same packet
# count as the input. Non-numeric durations fail instead of passing as delta 0.
check_video_preserved() {
  local label=$1 src=$2 dst=$3 in_dur out_dur delta in_pk out_pk
  in_dur=$(video_duration "$src" || true)
  out_dur=$(video_duration "$dst" || true)
  is_number "$in_dur" || fail "$label: could not read input video duration (got '${in_dur}')"
  is_number "$out_dur" || fail "$label: could not read output video duration (got '${out_dur}')"
  delta=$(echo "$in_dur $out_dur" | awk '{d=$1-$2; if (d<0) d=-d; print d}')
  if (( $(echo "$delta > 0.2" | bc -l) )); then
    fail "$label: duration drifted: in=$in_dur out=$out_dur delta=$delta"
  fi
  in_pk=$(video_packets "$src")
  out_pk=$(video_packets "$dst")
  if [[ "$in_pk" != "$out_pk" ]]; then
    fail "$label: video packets changed: in=$in_pk out=$out_pk"
  fi
}

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

check_video_preserved "tone+hum clip" "$noisy" "$clean"

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

# Audio shorter than video: -shortest at the audio end would drop video frames.
echo "Building synthetic input with audio shorter than video (3s audio, 5s video)..."
short_audio="$workdir/test_short_audio.mkv"
short_audio_clean="$workdir/test_short_audio_clean.mkv"
"$FFMPEG_BIN" -hide_banner -nostdin -y -loglevel error \
  -f lavfi -i "sine=frequency=440:duration=3" \
  -f lavfi -i "color=c=black:s=64x64:r=30:d=5" \
  -map 1:v -map 0:a \
  -c:v libx264 -pix_fmt yuv420p \
  -c:a pcm_s16le \
  "$short_audio"

echo "Running vhs_audio_cleanup.sh on short-audio input..."
NORM_DB=off "$CLEANUP_SH" "$short_audio" "$short_audio_clean"
check_video_preserved "short-audio clip" "$short_audio" "$short_audio_clean"

echo "Test passed"

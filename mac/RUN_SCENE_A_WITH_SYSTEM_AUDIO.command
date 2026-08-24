#!/bin/bash
set -euo pipefail

WORKROOT="$HOME/Library/Application Support/WaifuX Intel Scene Experimental"
BRIDGE="$WORKROOT/bin/waifux-system-audio-bridge"
AUDIO_FILE="$WORKROOT/live-audio-spectrum.txt"
RUNNER="${RUN_SCENE_A_PATH:-$HOME/Downloads/RUN_SCENE_A.command}"
GAIN="${WAIFUX_AUDIO_GAIN:-10}"
MODE="${WAIFUX_AUDIO_MODE:-fft}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this on macOS."
[[ "$(uname -m)" == "x86_64" ]] || fail "This test is intended for Intel macOS."
[[ -x "$BRIDGE" ]] || fail "System audio bridge not found: $BRIDGE. Run BUILD_SYSTEM_AUDIO_BRIDGE.command first."
[[ -f "$RUNNER" ]] || fail "RUN_SCENE_A.command not found: $RUNNER"

mkdir -p "$WORKROOT"
rm -f "$AUDIO_FILE"

BRIDGE_PID=""
cleanup() {
  if [[ -n "${BRIDGE_PID:-}" ]] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
  rm -f "$AUDIO_FILE"
}
trap cleanup EXIT INT TERM

echo "=== Starting macOS system-audio bridge ==="
echo "Mode:      $MODE"
echo "Gain:      ${GAIN}x"
echo "Spectrum:  $AUDIO_FILE"
echo

WAIFUX_AUDIO_MODE="$MODE" WAIFUX_AUDIO_GAIN="$GAIN" "$BRIDGE" "$AUDIO_FILE" &
BRIDGE_PID=$!

# Give ScreenCaptureKit time to start and/or show the first TCC prompt.
sleep 2
if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
  wait "$BRIDGE_PID" || true
  fail "Audio bridge exited. If permission was denied, enable Terminal under Privacy & Security > Screen & System Audio Recording, restart Terminal, and run again."
fi

echo
echo "=== Starting Scene renderer with live audio ==="
echo "Play music with a clear bass/drum beat."
if [[ "$MODE" == "fft" ]]; then
  echo "The bridge will print L/R FFT peaks plus representative frequency bands roughly twice per second."
else
  echo "The bridge will print L/R RMS envelope values roughly twice per second."
fi
echo "Press Ctrl+C here to stop both processes."
echo

export WAIFUX_AUDIO_FILE="$AUDIO_FILE"
export SCENE_MODE=full
unset WAIFUX_AUDIO_TEST || true

bash "$RUNNER" "$@"

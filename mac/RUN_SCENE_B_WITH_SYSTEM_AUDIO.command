#!/bin/bash
set -euo pipefail

WORKROOT="$HOME/Library/Application Support/WaifuX Intel Scene Experimental"
BRIDGE="$WORKROOT/bin/waifux-system-audio-bridge"
AUDIO_FILE="$WORKROOT/live-audio-spectrum.txt"
RUNNER="${RUN_SCENE_B_PATH:-$HOME/Downloads/RUN_SCENE_B.command}"
GAIN="${WAIFUX_AUDIO_GAIN:-8}"
MODE="${WAIFUX_AUDIO_MODE:-fft}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this on macOS."
[[ "$(uname -m)" == "x86_64" ]] || fail "This test is intended for Intel macOS."
[[ -x "$BRIDGE" ]] || fail "System audio bridge not found: $BRIDGE. Build it first."
[[ -f "$RUNNER" ]] || fail "RUN_SCENE_B.command not found: $RUNNER"

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

echo "=== Starting macOS system-audio bridge for Tier B ==="
echo "Analysis:  $MODE"
echo "Gain:      ${GAIN}x"
echo "Spectrum:  $AUDIO_FILE"
echo

WAIFUX_AUDIO_MODE="$MODE" WAIFUX_AUDIO_GAIN="$GAIN" "$BRIDGE" "$AUDIO_FILE" &
BRIDGE_PID=$!

sleep 2
if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
  wait "$BRIDGE_PID" || true
  fail "Audio bridge exited. Check Screen & System Audio Recording permission."
fi

echo
echo "=== Starting Tier B Scene with live 16-band audio ==="
echo "Use music with obvious bass/drums for the first test."
echo "Watch the FFT band values and the wallpaper at the same time."
echo "Press Ctrl+C here to stop both processes."
echo

export WAIFUX_AUDIO_FILE="$AUDIO_FILE"
export SCENE_MODE=full
unset WAIFUX_AUDIO_TEST || true

bash "$RUNNER" "$@"

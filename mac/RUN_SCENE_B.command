#!/bin/bash
set -euo pipefail

WORKROOT="$HOME/Library/Application Support/WaifuX Intel Scene Experimental"
BIN="$WORKROOT/bin/linux-wallpaper-engine"
DEFAULT_TEST="$HOME/Desktop/WaifuX-Scene-Testset/B-audio-effects-3034129787"
TEST_ROOT="${1:-$DEFAULT_TEST}"
MODE="${SCENE_MODE:-full}"
FPS="${SCENE_FPS:-30}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this on macOS."
[[ "$(uname -m)" == "x86_64" ]] || fail "This test is intended for an Intel Mac."
[[ -x "$BIN" ]] || fail "Experimental renderer not found. Build the Intel Scene renderer first."
[[ -d "$TEST_ROOT" ]] || fail "Tier B scene folder not found: $TEST_ROOT"

chmod -RN "$TEST_ROOT" 2>/dev/null || true
chmod -R u+rwX "$TEST_ROOT" 2>/dev/null || true

PKG="$(find "$TEST_ROOT" -type f -name 'scene.pkg' -print -quit)"
[[ -n "$PKG" ]] || fail "No scene.pkg found under: $TEST_ROOT"

ASSETS="$TEST_ROOT/core-assets"
ARGS=(-p "$PKG" -m winit -l debug)
if [[ -d "$ASSETS" ]]; then
  ARGS+=(--assets-path "$ASSETS")
fi

echo "=== WaifuX Intel Scene Tier B Audio-Responsive Test ==="
echo "Renderer: $BIN"
echo "Scene:    $PKG"
echo "Mode:     $MODE"
echo "FPS:      $FPS"
if [[ -d "$ASSETS" ]]; then
  echo "Assets:   $ASSETS"
else
  echo "Assets:   (none; full effects may miss Wallpaper Engine core assets)"
fi
if [[ -n "${WAIFUX_AUDIO_FILE:-}" ]]; then
  echo "Audio:    live spectrum file: $WAIFUX_AUDIO_FILE"
elif [[ -n "${WAIFUX_AUDIO_TEST:-}" ]]; then
  echo "Audio:    synthetic test: $WAIFUX_AUDIO_TEST"
else
  echo "Audio:    no external spectrum source"
fi

echo
echo "The renderer opens a fullscreen Tier B test surface."
echo "Return to this Terminal and press Ctrl+C to stop it."
echo

export WGPU_BACKEND=metal
export RUST_BACKTRACE=1

if [[ "$MODE" == "full" ]]; then
  exec "$BIN" "${ARGS[@]}" --target-fps "$FPS"
else
  exec "$BIN" "${ARGS[@]}" --no-effects
fi

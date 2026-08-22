#!/bin/bash
set -euo pipefail

WORKROOT="$HOME/Library/Application Support/WaifuX Intel Scene Experimental"
BIN="$WORKROOT/bin/linux-wallpaper-engine"
DEFAULT_TEST="$HOME/Desktop/WaifuX-Scene-Testset/A-basic-2947302287"
TEST_ROOT="${1:-$DEFAULT_TEST}"
MODE="${SCENE_MODE:-static}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this on macOS."
[[ "$(uname -m)" == "x86_64" ]] || fail "This test is intended for an Intel Mac."
[[ -x "$BIN" ]] || fail "Experimental renderer not found. Run BUILD_SCENE_EXPERIMENTAL.command first."
[[ -d "$TEST_ROOT" ]] || fail "Scene test folder not found: $TEST_ROOT"

# Archives produced on Windows can occasionally extract with restrictive
# directory mode/ACL metadata on macOS. Normalize best-effort before walking
# the scene tree so core-assets and shader files remain readable.
chmod -RN "$TEST_ROOT" 2>/dev/null || true
chmod -R u+rwX "$TEST_ROOT" 2>/dev/null || true

PKG="$(find "$TEST_ROOT" -type f -name 'scene.pkg' -print -quit)"
[[ -n "$PKG" ]] || fail "No scene.pkg found under: $TEST_ROOT"

ASSETS="$TEST_ROOT/core-assets"
ARGS=(-p "$PKG" -m winit -l debug)
if [[ -d "$ASSETS" ]]; then
  ARGS+=(--assets-path "$ASSETS")
fi

echo "=== WaifuX Intel Scene Tier A Test ==="
echo "Renderer: $BIN"
echo "Scene:    $PKG"
echo "Mode:     $MODE"
if [[ -d "$ASSETS" ]]; then
  echo "Assets:   $ASSETS"
else
  echo "Assets:   (none; static mode may work, full effects can miss WE core headers)"
fi
echo
echo "The renderer opens a fullscreen test surface."
echo "Return to this Terminal and press Ctrl+C to stop it."
echo

export WGPU_BACKEND=metal
export RUST_BACKTRACE=1

if [[ "$MODE" == "full" ]]; then
  exec "$BIN" "${ARGS[@]}" --target-fps 30
else
  exec "$BIN" "${ARGS[@]}" --no-effects
fi

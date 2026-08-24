#!/bin/bash
set -euo pipefail

WORKROOT="$HOME/Library/Application Support/WaifuX Intel Scene Experimental"
BIN_DIR="$WORKROOT/bin"
SRC_DIR="$WORKROOT/bridge-src"
SRC="$SRC_DIR/SystemAudioLevelBridge.swift"
OUT="$BIN_DIR/waifux-system-audio-bridge"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_SRC="$SCRIPT_DIR/SystemAudioLevelBridge.swift"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this on macOS."
[[ "$(uname -m)" == "x86_64" ]] || fail "This build is intended for Intel macOS."
command -v xcrun >/dev/null 2>&1 || fail "xcrun not found. Install Xcode Command Line Tools."
xcrun --find swiftc >/dev/null 2>&1 || fail "swiftc not found. Install Xcode Command Line Tools."

mkdir -p "$BIN_DIR" "$SRC_DIR"

if [[ -f "$LOCAL_SRC" ]]; then
  cp "$LOCAL_SRC" "$SRC"
elif [[ -f "$HOME/Downloads/SystemAudioLevelBridge.swift" ]]; then
  cp "$HOME/Downloads/SystemAudioLevelBridge.swift" "$SRC"
else
  fail "SystemAudioLevelBridge.swift not found next to this script or in ~/Downloads."
fi

echo "=== Building WaifuX macOS system-audio bridge ==="
echo "Source: $SRC"
echo "Output: $OUT"

# This source uses an explicit @main async entry point. With a single Swift
# source file, swiftc otherwise treats the file as a script and reports that
# @main cannot coexist with top-level code. -parse-as-library selects the
# correct compilation mode for an explicit @main type.
xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O \
  -framework Foundation \
  -framework ScreenCaptureKit \
  -framework CoreMedia \
  -framework AudioToolbox \
  "$SRC" \
  -o "$OUT"

chmod 755 "$OUT"

echo
echo "=== Verification ==="
file "$OUT"
file "$OUT" | grep -q "x86_64" || fail "Bridge binary is not x86_64."

echo
echo "System-audio bridge build complete."
echo "Standalone capture test:"
echo "  WAIFUX_AUDIO_GAIN=6 \"$OUT\" \"$WORKROOT/live-audio-spectrum.txt\""
echo
echo "While music is playing, the bridge should print changing L/R values."
echo "First launch may require macOS Screen & System Audio Recording permission."

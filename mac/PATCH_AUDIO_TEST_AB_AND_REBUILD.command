#!/bin/bash
set -euo pipefail

SCRIPT_VERSION="2026-08-24-ab1"
WORKROOT="$HOME/Library/Application Support/WaifuX Intel Scene Experimental"
SRC="$WORKROOT/src/linux-wallpaperengine"
BIN_DIR="$WORKROOT/bin"
OUT_BIN="$BIN_DIR/linux-wallpaper-engine"
APP_RS="$SRC/src/scene/renderer/app.rs"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this on macOS."
[[ "$(uname -m)" == "x86_64" ]] || fail "This rebuild is intended for Intel macOS."
[[ -d "$SRC/.git" ]] || fail "Experimental source tree not found."
[[ -f "$APP_RS" ]] || fail "app.rs not found: $APP_RS"
command -v python3 >/dev/null 2>&1 || fail "python3 is required."
command -v cargo >/dev/null 2>&1 || fail "cargo is not available. Run: source \"$HOME/.cargo/env\""

cd "$SRC"
echo "=== WaifuX deterministic audio A/B test patch $SCRIPT_VERSION ==="

BACKUP_DIR="$WORKROOT/source-backups/audio-ab1-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$APP_RS" "$BACKUP_DIR/app.rs"
echo "Backup: $BACKUP_DIR"

python3 - "$APP_RS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
start_marker = "        // Stage-1 audio validation: deterministic synthetic 16-band spectrum."
end_marker = "\n\n        render_pass::write_effect_uniforms("

start = text.find(start_marker)
if start < 0:
    raise SystemExit("Stage-1 audio test block not found in app.rs")
end = text.find(end_marker, start)
if end < 0:
    raise SystemExit("Could not find end of Stage-1 audio test block")

replacement = '''        // Stage-1 audio validation: deterministic A/B spectrum modes.
        // WAIFUX_AUDIO_TEST=zero   -> all 16 bands = 0.0
        // WAIFUX_AUDIO_TEST=one    -> all 16 bands = 1.0 (maximum normalized response)
        // WAIFUX_AUDIO_TEST=square -> alternate zero/one every second
        // WAIFUX_AUDIO_TEST=1      -> alias for square
        if let Ok(mode) = std::env::var("WAIFUX_AUDIO_TEST") {
            let level = match mode.as_str() {
                "zero" | "0" => Some(0.0f32),
                "one" => Some(1.0f32),
                "square" | "1" => {
                    let phase = (elapsed.floor() as u64) & 1;
                    Some(if phase == 0 { 0.0 } else { 1.0 })
                }
                _ => None,
            };
            if let Some(level) = level {
                params.audio_spectrum_left.fill(level);
                params.audio_spectrum_right.fill(level);
            }
        }'''

text = text[:start] + replacement + text[end:]
path.write_text(text)
print("Replaced subtle synthetic spectrum with deterministic zero/one/square A/B modes")
PY

echo
echo "=== cargo check (x86_64) ==="
export CARGO_TERM_COLOR=always
cargo check --release --target x86_64-apple-darwin

echo
echo "=== cargo build (x86_64) ==="
cargo build --release --target x86_64-apple-darwin

BUILT="$SRC/target/x86_64-apple-darwin/release/linux-wallpaper-engine"
[[ -f "$BUILT" ]] || fail "Build completed but binary was not produced."
mkdir -p "$BIN_DIR"
cp "$BUILT" "$OUT_BIN"
chmod 755 "$OUT_BIN"

echo
echo "=== Verification ==="
file "$OUT_BIN"
file "$OUT_BIN" | grep -q "x86_64" || fail "Rebuilt binary is not x86_64."

echo
echo "Audio A/B test rebuild complete."
echo "Run these separately and compare screenshots:"
echo "  WAIFUX_AUDIO_TEST=zero SCENE_MODE=full bash ~/Downloads/RUN_SCENE_A.command 2>&1 | tee ~/Desktop/scene-a-audio-zero.log"
echo "  WAIFUX_AUDIO_TEST=one  SCENE_MODE=full bash ~/Downloads/RUN_SCENE_A.command 2>&1 | tee ~/Desktop/scene-a-audio-one.log"
echo
echo "Optional obvious alternating test:"
echo "  WAIFUX_AUDIO_TEST=square SCENE_MODE=full bash ~/Downloads/RUN_SCENE_A.command"

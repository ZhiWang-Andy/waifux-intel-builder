#!/bin/bash
set -euo pipefail

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

echo "=== Adding live audio spectrum file input ==="
BACKUP_DIR="$WORKROOT/source-backups/live-audio-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$APP_RS" "$BACKUP_DIR/app.rs"
echo "Backup: $BACKUP_DIR"

python3 - "$APP_RS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if 'fn read_live_audio_spectrum(' not in text:
    marker = 'pub use super::surface::InitAppSurface;\n'
    helper = r'''

fn read_live_audio_spectrum(path: &str) -> Option<([f32; 16], [f32; 16])> {
    let metadata = std::fs::metadata(path).ok()?;
    let modified = metadata.modified().ok()?;
    if modified.elapsed().ok()? > std::time::Duration::from_millis(1200) {
        return None;
    }

    let raw = std::fs::read_to_string(path).ok()?;
    let values: Vec<f32> = raw
        .split_whitespace()
        .filter_map(|token| token.parse::<f32>().ok())
        .collect();
    if values.len() != 32 {
        return None;
    }

    let mut left = [0.0f32; 16];
    let mut right = [0.0f32; 16];
    left.copy_from_slice(&values[0..16]);
    right.copy_from_slice(&values[16..32]);
    Some((left, right))
}
'''
    if marker not in text:
        raise SystemExit('InitAppSurface marker not found in app.rs')
    text = text.replace(marker, marker + helper, 1)

if 'Live macOS system-audio bridge input' not in text:
    marker = '\n\n        render_pass::write_effect_uniforms(\n'
    live = r'''

        // Live macOS system-audio bridge input. The helper writes exactly
        // 32 floats: 16 left bands followed by 16 right bands. A stale or
        // malformed file intentionally falls back to silence instead of
        // keeping an old spectrum forever.
        if let Ok(audio_path) = std::env::var("WAIFUX_AUDIO_FILE") {
            if let Some((left, right)) = read_live_audio_spectrum(&audio_path) {
                params.audio_spectrum_left = left;
                params.audio_spectrum_right = right;
            } else {
                params.audio_spectrum_left.fill(0.0);
                params.audio_spectrum_right.fill(0.0);
            }
        }
'''
    pos = text.find(marker)
    if pos < 0:
        raise SystemExit('render_pass::write_effect_uniforms marker not found in app.rs')
    text = text[:pos] + live + text[pos:]

path.write_text(text)
print('Live audio file reader added/verified')
PY

echo
echo "=== cargo check (x86_64) ==="
export CARGO_TERM_COLOR=always
cargo check --release --target x86_64-apple-darwin

echo
echo "=== cargo build (x86_64) ==="
cargo build --release --target x86_64-apple-darwin

BUILT="$SRC/target/x86_64-apple-darwin/release/linux-wallpaper-engine"
[[ -f "$BUILT" ]] || fail "Build completed but renderer binary was not produced."
mkdir -p "$BIN_DIR"
cp "$BUILT" "$OUT_BIN"
chmod 755 "$OUT_BIN"

echo
echo "=== Verification ==="
file "$OUT_BIN"
file "$OUT_BIN" | grep -q "x86_64" || fail "Rebuilt binary is not x86_64."

echo
echo "Live audio file input rebuild complete."
echo "The renderer now reads WAIFUX_AUDIO_FILE on every frame."

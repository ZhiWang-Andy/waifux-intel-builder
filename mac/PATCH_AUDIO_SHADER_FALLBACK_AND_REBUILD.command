#!/bin/bash
set -euo pipefail

WORKROOT="$HOME/Library/Application Support/WaifuX Intel Scene Experimental"
SRC="$WORKROOT/src/linux-wallpaperengine"
BIN_DIR="$WORKROOT/bin"
OUT_BIN="$BIN_DIR/linux-wallpaper-engine"
PIPELINE_RS="$SRC/src/scene/renderer/post_processor/pipeline_handler.rs"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this on macOS."
[[ "$(uname -m)" == "x86_64" ]] || fail "This rebuild is intended for Intel macOS."
[[ -d "$SRC/.git" ]] || fail "Experimental source tree not found. Run BUILD_SCENE_EXPERIMENTAL.command first."
[[ -f "$PIPELINE_RS" ]] || fail "pipeline_handler.rs not found: $PIPELINE_RS"
command -v cargo >/dev/null 2>&1 || fail "cargo is not available. Run: source \"$HOME/.cargo/env\""
command -v python3 >/dev/null 2>&1 || fail "python3 is required."

cd "$SRC"

echo "=== Patching Wallpaper Engine AUDIOPROCESSING compatibility fallback ==="
python3 - "$PIPELINE_RS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

needle = "    pipeline_helpers::apply_texture_combos(&mut defines, pass_textures);\n"
patch = '''    pipeline_helpers::apply_texture_combos(&mut defines, pass_textures);\n\n    // Experimental macOS/Metal compatibility fallback:\n    // Wallpaper Engine pulse/shake vertex shaders use CreateAudioResponse()\n    // with fixed-size array parameters. With the current wgpu 28 / Naga GLSL\n    // frontend this can reach shader-module creation as an unresolved function\n    // call. Disable only this optional audio-processing combo so the shader uses\n    // its built-in time-based fallback path while preserving the rest of the\n    // effect pipeline (waterwaves, pulse animation, masks, etc.).\n    if vert_source.contains(\"CreateAudioResponse\") {\n        let audio_enabled = defines\n            .get(\"AUDIOPROCESSING\")\n            .map(|v| v != \"0\")\n            .unwrap_or(false);\n        if audio_enabled {\n            log::warn!(\n                \"AUDIOPROCESSING={} uses CreateAudioResponse array parameters; forcing AUDIOPROCESSING=0 for experimental Naga/Metal compatibility\",\n                defines.get(\"AUDIOPROCESSING\").map(String::as_str).unwrap_or(\"?\")\n            );\n            defines.insert(\"AUDIOPROCESSING\".to_string(), \"0\".to_string());\n        }\n    }\n'''

if "forcing AUDIOPROCESSING=0 for experimental Naga/Metal compatibility" not in text:
    if needle not in text:
        raise SystemExit("Expected apply_texture_combos line was not found")
    text = text.replace(needle, patch, 1)
else:
    print("Audio shader fallback patch is already present")

path.write_text(text)
print("Patched optional audio-responsive combo to use time-based pulse fallback")
PY

echo
echo "=== Rebuilding x86_64 renderer ==="
export CARGO_TERM_COLOR=always
cargo build --release --target x86_64-apple-darwin

BUILT="$SRC/target/x86_64-apple-darwin/release/linux-wallpaper-engine"
[[ -f "$BUILT" ]] || fail "Build finished but renderer binary was not produced."

mkdir -p "$BIN_DIR"
cp "$BUILT" "$OUT_BIN"
chmod 755 "$OUT_BIN"

echo
echo "=== Verification ==="
file "$OUT_BIN"
file "$OUT_BIN" | grep -q "x86_64" || fail "Rebuilt binary is not x86_64."

echo
echo "Audio compatibility fallback rebuild complete."
echo "This temporarily disables AUDIOPROCESSING only for shaders that use CreateAudioResponse."
echo "Waterwaves and time-based pulse effects remain enabled."
echo
echo "Next run:"
echo "  SCENE_MODE=full bash ~/Downloads/RUN_SCENE_A.command 2>&1 | tee ~/Desktop/scene-a-full-audio-fallback.log"

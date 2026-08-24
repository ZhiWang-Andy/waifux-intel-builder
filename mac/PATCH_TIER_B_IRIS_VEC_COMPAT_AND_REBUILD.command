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
[[ -d "$SRC/.git" ]] || fail "Experimental source tree not found."
[[ -f "$PIPELINE_RS" ]] || fail "pipeline_handler.rs not found: $PIPELINE_RS"
command -v cargo >/dev/null 2>&1 || fail "cargo not found. Run: source \"$HOME/.cargo/env\""
command -v python3 >/dev/null 2>&1 || fail "python3 is required."

cd "$SRC"

echo "=== Tier B: patching Wallpaper Engine GLSL implicit vec4 -> vec2 conversion ==="
python3 - "$PIPELINE_RS" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "WE GLSL compat: iris_follow_cursor vec4->vec2"

if marker in text:
    print("Tier B iris vector compatibility patch already present")
    raise SystemExit(0)

# Wallpaper Engine's workshop shader relies on HLSL-style implicit vector
# truncation in an expression that becomes GLSL after preprocessing:
#
#   vec2 da = v_PointerUV * (g_Scale * g_Scale_FollowCursor_Multiplier) * 0.001;
#
# In the generated shader v_PointerUV is vec4 while the scale expression is
# vec2. Naga's GLSL validator correctly rejects vec4 * vec2. Preserve the WE
# intent by explicitly selecting the XY components, but only for this shader.
pattern = re.compile(
    r'(\n\s*let \(vert_processed, frag_processed, layout\) =\s*\n\s*preprocess_pair\([^;]+;\s*\n)',
    re.DOTALL,
)
m = pattern.search(text)
if not m:
    raise SystemExit("Could not locate preprocess_pair result in pipeline_handler.rs")

insertion = m.group(1) + r'''
    let mut frag_processed = frag_processed;
    if frag_path.ends_with("iris_follow_cursor.frag") {
        let old = "v_PointerUV * (g_Scale * g_Scale_FollowCursor_Multiplier)";
        let new = "v_PointerUV.xy * (g_Scale * g_Scale_FollowCursor_Multiplier)";
        if frag_processed.contains(old) {
            frag_processed = frag_processed.replace(old, new);
            log::info!("WE GLSL compat: iris_follow_cursor vec4->vec2 via v_PointerUV.xy");
        } else {
            log::warn!("WE GLSL compat: iris_follow_cursor target expression was not found after preprocessing");
        }
    }
'''

text = text[:m.start()] + insertion + text[m.end():]
path.write_text(text)
print("Applied explicit v_PointerUV.xy compatibility rewrite")
PY

echo
echo "=== cargo check (x86_64) ==="
export CARGO_TERM_COLOR=always
cargo check --release --target x86_64-apple-darwin

echo
echo "=== cargo build (x86_64) ==="
cargo build --release --target x86_64-apple-darwin

BUILT="$SRC/target/x86_64-apple-darwin/release/linux-wallpaper-engine"
[[ -f "$BUILT" ]] || fail "Build succeeded but renderer binary was not produced."

mkdir -p "$BIN_DIR"
cp "$BUILT" "$OUT_BIN"
chmod 755 "$OUT_BIN"

echo
echo "=== Verification ==="
file "$OUT_BIN"
file "$OUT_BIN" | grep -q "x86_64" || fail "Rebuilt renderer is not x86_64."

echo
echo "Tier B iris vector compatibility rebuild complete."
echo "Re-run:"
echo "  SCENE_MODE=full bash ~/Downloads/RUN_SCENE_B.command 2>&1 | tee ~/Desktop/scene-b-no-audio-2.log"
echo
echo "Expected new marker before the next shader stage:"
echo "  WE GLSL compat: iris_follow_cursor vec4->vec2 via v_PointerUV.xy"

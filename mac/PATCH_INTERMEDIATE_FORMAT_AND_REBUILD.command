#!/bin/bash
set -euo pipefail

WORKROOT="$HOME/Library/Application Support/WaifuX Intel Scene Experimental"
SRC="$WORKROOT/src/linux-wallpaperengine"
BIN_DIR="$WORKROOT/bin"
OUT_BIN="$BIN_DIR/linux-wallpaper-engine"
LOAD_RS="$SRC/src/scene/renderer/load.rs"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this on macOS."
[[ "$(uname -m)" == "x86_64" ]] || fail "This rebuild is intended for Intel macOS."
[[ -d "$SRC/.git" ]] || fail "Experimental source tree not found. Run BUILD_SCENE_EXPERIMENTAL.command first."
[[ -f "$LOAD_RS" ]] || fail "load.rs not found: $LOAD_RS"
command -v cargo >/dev/null 2>&1 || fail "cargo is not available. Run: source \"$HOME/.cargo/env\""
command -v python3 >/dev/null 2>&1 || fail "python3 is required."

cd "$SRC"

echo "=== Patching intermediate render-target format ==="
python3 - "$LOAD_RS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

marker = "copy pipeline target=Rgba8UnormSrgb"
if marker in text:
    print("Intermediate-format patch is already present")
    raise SystemExit(0)

old_sig = '''fn create_pipeline_with_blend(
    app: &WgpuApp,
    bindgroup_layout: &BindGroupLayout,
    blend: BlendState,
) -> RenderPipeline {'''
new_sig = '''fn create_pipeline_with_blend(
    app: &WgpuApp,
    bindgroup_layout: &BindGroupLayout,
    target_format: TextureFormat,
    blend: BlendState,
) -> RenderPipeline {'''
if old_sig not in text:
    raise SystemExit("Expected create_pipeline_with_blend signature not found")
text = text.replace(old_sig, new_sig, 1)

# The first pipeline draws the final image to the swapchain surface, so it must
# match the surface format (BGRA8 on this Mac). The second pipeline is used only
# for source -> ping-pong copies, whose textures are always RGBA8 sRGB.
first = '''        create_pipeline_with_blend(
            app,
            bindgroup_layout,
            BlendState {'''
first_new = '''        create_pipeline_with_blend(
            app,
            bindgroup_layout,
            app.surface.config.format,
            BlendState {'''
if first not in text:
    raise SystemExit("Expected final image pipeline call not found")
text = text.replace(first, first_new, 1)

second = '''        create_pipeline_with_blend(
            app,
            bindgroup_layout,
            BlendState {'''
second_new = '''        create_pipeline_with_blend(
            app,
            bindgroup_layout,
            TextureFormat::Rgba8UnormSrgb,
            BlendState {'''
if second not in text:
    raise SystemExit("Expected intermediate copy pipeline call not found")
text = text.replace(second, second_new, 1)

old_target = '''                    format: app.surface.config.format,
                    blend: Some(blend),'''
new_target = '''                    format: target_format,
                    blend: Some(blend),'''
if old_target not in text:
    raise SystemExit("Expected pipeline target format line not found")
text = text.replace(old_target, new_target, 1)

# Add a one-time diagnostic marker near pipeline creation.
needle = '''    let (image, copy) = (
'''
replacement = '''    eprintln!(
        "[scene-experimental] final pipeline target={:?}; copy pipeline target=Rgba8UnormSrgb",
        app.surface.config.format
    );
    let (image, copy) = (
'''
if needle not in text:
    raise SystemExit("Expected create_pipelines tuple marker not found")
text = text.replace(needle, replacement, 1)

path.write_text(text)
print("Patched final-vs-intermediate render pipeline formats")
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
echo "Intermediate render-target format rebuild complete."
echo "Final pass stays on the macOS surface format; effect ping-pong/copy passes use Rgba8UnormSrgb."
echo
echo "Next run:"
echo "  SCENE_MODE=full bash ~/Downloads/RUN_SCENE_A.command 2>&1 | tee ~/Desktop/scene-a-full-format-fixed.log"

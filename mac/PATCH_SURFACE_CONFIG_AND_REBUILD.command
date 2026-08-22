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
[[ -d "$SRC/.git" ]] || fail "Experimental source tree not found. Run BUILD_SCENE_EXPERIMENTAL.command first."
[[ -f "$APP_RS" ]] || fail "app.rs not found: $APP_RS"
command -v cargo >/dev/null 2>&1 || fail "cargo is not available. Run: source \"$HOME/.cargo/env\""
command -v python3 >/dev/null 2>&1 || fail "python3 is required."

cd "$SRC"

echo "=== Patching wgpu surface configuration ==="
python3 - "$APP_RS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = "        let surface = AppSurface::new(surface, &instance, &adapter, size);\n"
new = (
    "        let surface = AppSurface::new(surface, &instance, &adapter, size);\n"
    "        // wgpu requires a Surface to be configured before the first\n"
    "        // get_current_texture()/presentation attempt. Linux often emits\n"
    "        // a resize event first, which happened to configure it indirectly;\n"
    "        // AppKit can request the first redraw before any resize event.\n"
    "        surface.surface.configure(&device, &surface.config);\n"
    "        eprintln!(\"[scene-experimental] surface configured: {}x{} {:?} {:?}\",\n"
    "            surface.config.width, surface.config.height,\n"
    "            surface.config.format, surface.config.present_mode);\n"
)

if "surface.surface.configure(&device, &surface.config);" not in text:
    if old not in text:
        raise SystemExit("Expected AppSurface::new line was not found")
    text = text.replace(old, new, 1)
else:
    print("Surface configure patch is already present")

path.write_text(text)
print("Patched surface configuration before the first presentation")
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
echo "Surface fix rebuild complete."
echo "Next run:"
echo "  bash ~/Downloads/RUN_SCENE_A.command 2>&1 | tee ~/Desktop/scene-a-after-surface.log"

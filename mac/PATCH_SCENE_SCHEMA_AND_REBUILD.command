#!/bin/bash
set -euo pipefail

WORKROOT="$HOME/Library/Application Support/WaifuX Intel Scene Experimental"
SRC="$WORKROOT/src/linux-wallpaperengine"
BIN_DIR="$WORKROOT/bin"
OUT_BIN="$BIN_DIR/linux-wallpaper-engine"
SCENE_RS="$SRC/src/scene/loader/scene.rs"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this on macOS."
[[ "$(uname -m)" == "x86_64" ]] || fail "This rebuild is intended for Intel macOS."
[[ -d "$SRC/.git" ]] || fail "Experimental source tree not found. Run BUILD_SCENE_EXPERIMENTAL.command first."
[[ -f "$SCENE_RS" ]] || fail "scene.rs not found: $SCENE_RS"
command -v cargo >/dev/null 2>&1 || fail "cargo is not available. Run: source \"$HOME/.cargo/env\""
command -v python3 >/dev/null 2>&1 || fail "python3 is required."

cd "$SRC"

echo "=== Patching Wallpaper Engine user-bound scalar schema ==="
python3 - "$SCENE_RS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = "    pub cameraparallaxamount: f64,"
new = "    pub cameraparallaxamount: BindUserProperty<f64>,"

if new not in text:
    if old not in text:
        raise SystemExit("Expected cameraparallaxamount field was not found")
    text = text.replace(old, new, 1)

# General derives Default, so BindUserProperty<T> also needs a Default impl.
marker = "impl<T: DeserializeOwned> BindUserProperty<T> {"
impl_default = '''impl<T: Default> Default for BindUserProperty<T> {
    fn default() -> Self {
        BindUserProperty::Value(T::default())
    }
}

'''
if impl_default not in text:
    if marker not in text:
        raise SystemExit("BindUserProperty implementation marker was not found")
    text = text.replace(marker, impl_default + marker, 1)

path.write_text(text)
print("Patched cameraparallaxamount to accept either a plain number or {user,value} binding")
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
echo "Schema fix rebuild complete."
echo "Next run:"
echo "  bash ~/Downloads/RUN_SCENE_A.command"

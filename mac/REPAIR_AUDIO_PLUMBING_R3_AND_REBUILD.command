#!/bin/bash
set -euo pipefail

SCRIPT_VERSION="2026-08-24-r3"
WORKROOT="$HOME/Library/Application Support/WaifuX Intel Scene Experimental"
SRC="$WORKROOT/src/linux-wallpaperengine"
BIN_DIR="$WORKROOT/bin"
OUT_BIN="$BIN_DIR/linux-wallpaper-engine"
APP_RS="$SRC/src/scene/renderer/app.rs"
PARAM_RS="$SRC/src/scene/renderer/post_processor/effect_param.rs"
RENDER_RS="$SRC/src/scene/renderer/render_pass.rs"
WINIT_RS="$SRC/src/scene/adapters/winit_adapter.rs"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this on macOS."
[[ "$(uname -m)" == "x86_64" ]] || fail "This repair is intended for Intel macOS."
[[ -d "$SRC/.git" ]] || fail "Experimental source tree not found."
for f in "$APP_RS" "$PARAM_RS" "$RENDER_RS" "$WINIT_RS"; do
  [[ -f "$f" ]] || fail "Required source file not found: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 is required."
command -v cargo >/dev/null 2>&1 || fail "cargo is not available. Run: source \"$HOME/.cargo/env\""

echo "=== WaifuX audio plumbing repair $SCRIPT_VERSION ==="
cd "$SRC"

BACKUP_DIR="$WORKROOT/source-backups/audio-r3-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$APP_RS" "$PARAM_RS" "$RENDER_RS" "$WINIT_RS" "$BACKUP_DIR/"
echo "Backup: $BACKUP_DIR"

python3 - "$APP_RS" "$PARAM_RS" "$RENDER_RS" "$WINIT_RS" <<'PY'
from pathlib import Path
import re
import sys

app_path = Path(sys.argv[1])
param_path = Path(sys.argv[2])
render_path = Path(sys.argv[3])
winit_path = Path(sys.argv[4])

app = app_path.read_text()
param = param_path.read_text()
render = render_path.read_text()
winit = winit_path.read_text()

# Preconditions: the earlier audio-plumbing patch should already have added
# these definitions. If it did not, stop rather than making a half-patched tree.
required = [
    (app, "pub audio_spectrum_left: [f32; 16]", "UserParams audio fields"),
    (param, "pub audio_spectrum_left: [f32; 16]", "SystemUniforms audio fields"),
    (param, "pub fn write_f32_array", "float-array uniform writer"),
]
for text, needle, label in required:
    if needle not in text:
        raise SystemExit(f"Missing prerequisite: {label}. Re-run the full R3 plumbing script first.")

# 1) Repair winit cursor handling. Never reconstruct UserParams because doing
# so both requires every new field and would wipe live audio spectrum state.
if "app.user_params.cursor_position = [nx, ny];" not in winit:
    pattern = re.compile(
        r'app\.user_params\s*=\s*\n\s*crate::scene::renderer::app::UserParams\s*\{\s*\n\s*cursor_position:\s*\[nx, ny\],\s*\n\s*\};',
        re.MULTILINE,
    )
    winit, n = pattern.subn('app.user_params.cursor_position = [nx, ny];', winit, count=1)
    if n != 1:
        raise SystemExit("Could not find the old UserParams cursor initializer in winit_adapter.rs")
winit_path.write_text(winit)

# 2) Normalize the two SystemUniforms initializers in render_pass.rs.
# Remove any previously duplicated audio lines, then add exactly one pair after
# cursor_position in each initializer.
render = re.sub(
    r'^\s*audio_spectrum_left:\s*user_params\.audio_spectrum_left,\s*\n',
    '', render, flags=re.MULTILINE,
)
render = re.sub(
    r'^\s*audio_spectrum_right:\s*user_params\.audio_spectrum_right,\s*\n',
    '', render, flags=re.MULTILINE,
)

block_re = re.compile(r'let sys = SystemUniforms \{\n(?P<body>.*?)\n(?P<indent>\s*)\};', re.DOTALL)
matches = list(block_re.finditer(render))
if len(matches) != 2:
    raise SystemExit(f"Expected exactly 2 SystemUniforms initializers, found {len(matches)}")

parts = []
last = 0
for m in matches:
    parts.append(render[last:m.start()])
    whole = m.group(0)
    body = m.group('body')
    cursor_matches = [line for line in body.splitlines() if 'cursor_position: user_params.cursor_position,' in line]
    if len(cursor_matches) != 1:
        raise SystemExit("Expected exactly one cursor_position field in a SystemUniforms initializer")
    cursor_line = cursor_matches[0]
    indent = cursor_line[:len(cursor_line) - len(cursor_line.lstrip())]
    replacement = (
        cursor_line + '\n' +
        indent + 'audio_spectrum_left: user_params.audio_spectrum_left,\n' +
        indent + 'audio_spectrum_right: user_params.audio_spectrum_right,'
    )
    whole = whole.replace(cursor_line, replacement, 1)
    parts.append(whole)
    last = m.end()
parts.append(render[last:])
render = ''.join(parts)
render_path.write_text(render)

# 3) Deterministic verification before invoking rustc.
if render.count('audio_spectrum_left: user_params.audio_spectrum_left,') != 2:
    raise SystemExit("Repair verification failed: left spectrum initializer count != 2")
if render.count('audio_spectrum_right: user_params.audio_spectrum_right,') != 2:
    raise SystemExit("Repair verification failed: right spectrum initializer count != 2")
if 'crate::scene::renderer::app::UserParams {' in winit:
    # There may be other legitimate constructors in the file in future, but at
    # the pinned source this specifically signals that the cursor initializer
    # was not repaired.
    cursor_region = winit[winit.find('WindowEvent::CursorMoved'):]
    if 'crate::scene::renderer::app::UserParams {' in cursor_region:
        raise SystemExit("Repair verification failed: cursor path still reconstructs UserParams")

print("Source repair verified:")
print("  winit cursor preserves audio fields")
print("  render_pass has exactly 2 audio-spectrum initializer pairs")
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
echo "R3 repair/build complete."
echo "Next test:"
echo "  WAIFUX_AUDIO_TEST=1 SCENE_MODE=full bash ~/Downloads/RUN_SCENE_A.command 2>&1 | tee ~/Desktop/scene-a-audio-test.log"

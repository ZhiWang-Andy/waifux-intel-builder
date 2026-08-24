#!/bin/bash
set -euo pipefail

WORKROOT="$HOME/Library/Application Support/WaifuX Intel Scene Experimental"
SRC="$WORKROOT/src/linux-wallpaperengine"
BIN_DIR="$WORKROOT/bin"
OUT_BIN="$BIN_DIR/linux-wallpaper-engine"
PIPELINE_RS="$SRC/src/scene/renderer/post_processor/pipeline_handler.rs"
PARAM_RS="$SRC/src/scene/renderer/post_processor/effect_param.rs"
APP_RS="$SRC/src/scene/renderer/app.rs"
RENDER_RS="$SRC/src/scene/renderer/render_pass.rs"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this on macOS."
[[ "$(uname -m)" == "x86_64" ]] || fail "This rebuild is intended for Intel macOS."
[[ -d "$SRC/.git" ]] || fail "Experimental source tree not found. Run BUILD_SCENE_EXPERIMENTAL.command first."
for f in "$PIPELINE_RS" "$PARAM_RS" "$APP_RS" "$RENDER_RS"; do
  [[ -f "$f" ]] || fail "Required source file not found: $f"
done
command -v cargo >/dev/null 2>&1 || fail "cargo is not available. Run: source \"$HOME/.cargo/env\""
command -v python3 >/dev/null 2>&1 || fail "python3 is required."

cd "$SRC"

echo "=== Patching audio-responsive shader plumbing (synthetic test source) ==="
python3 - "$PIPELINE_RS" "$PARAM_RS" "$APP_RS" "$RENDER_RS" <<'PY'
from pathlib import Path
import sys

pipeline_path = Path(sys.argv[1])
param_path = Path(sys.argv[2])
app_path = Path(sys.argv[3])
render_path = Path(sys.argv[4])

# 1) Keep AUDIOPROCESSING enabled, but rewrite the fixed-size array-parameter
# helper that Naga rejected. The helper reads the global uniform arrays instead.
p = pipeline_path.read_text()
if "rewrote CreateAudioResponse fixed-size array parameters" not in p:
    needle = '    let vert_source = std::str::from_utf8(vert_raw).ok()?;\n'
    replacement = '''    let vert_source_raw = std::str::from_utf8(vert_raw).ok()?;
    let mut vert_source_storage = vert_source_raw.to_string();
    if vert_source_storage.contains("CreateAudioResponse") {
        let old_sig = "float CreateAudioResponse(float bufferLeft[16], float bufferRight[16])";
        if vert_source_storage.contains(old_sig) {
            vert_source_storage = vert_source_storage.replace(old_sig, "float CreateAudioResponse()");
            vert_source_storage = vert_source_storage.replace("bufferLeft[", "g_AudioSpectrum16Left[");
            vert_source_storage = vert_source_storage.replace("bufferRight[", "g_AudioSpectrum16Right[");
            vert_source_storage = vert_source_storage.replace(
                "CreateAudioResponse(g_AudioSpectrum16Left, g_AudioSpectrum16Right)",
                "CreateAudioResponse()",
            );
            log::info!("rewrote CreateAudioResponse fixed-size array parameters for Naga/Metal");
        }
    }
    let vert_source = vert_source_storage.as_str();
'''
    if needle not in p:
        raise SystemExit("Expected vert_source line not found in pipeline_handler.rs")
    p = p.replace(needle, replacement, 1)

# Undo the earlier temporary AUDIOPROCESSING=0 compatibility fallback.
p = p.replace(
    'AUDIOPROCESSING={} uses CreateAudioResponse array parameters; forcing AUDIOPROCESSING=0 for experimental Naga/Metal compatibility',
    'AUDIOPROCESSING={} retained; CreateAudioResponse parameters rewritten for Naga/Metal',
)
p = p.replace('            defines.insert("AUDIOPROCESSING".to_string(), "0".to_string());\n', '')
pipeline_path.write_text(p)

# 2) Add float-array uniform writing and 16-band system spectrum fields.
e = param_path.read_text()
if "pub fn write_f32_array" not in e:
    marker = '    pub fn write_vec2(&self, buf: &mut [u8], name: &str, value: [f32; 2]) -> bool {\n'
    method = '''    pub fn write_f32_array(&self, buf: &mut [u8], name: &str, values: &[f32]) -> bool {
        let Some(&(off, size)) = self.offsets.get(name) else { return false; };
        if values.is_empty() { return false; }
        let stride = size as usize / values.len();
        if stride < 4 || off as usize + size as usize > buf.len() { return false; }
        for (i, value) in values.iter().enumerate() {
            let start = off as usize + i * stride;
            buf[start..start + 4].copy_from_slice(&value.to_le_bytes());
        }
        true
    }

'''
    if marker not in e:
        raise SystemExit("write_vec2 marker not found in effect_param.rs")
    e = e.replace(marker, method + marker, 1)

if 'self.write_f32_array(buf, "g_AudioSpectrum16Left"' not in e:
    marker = '        self.write_vec2(buf, "g_ParallaxPosition", sys.cursor_position);\n'
    insertion = marker + '        self.write_f32_array(buf, "g_AudioSpectrum16Left", &sys.audio_spectrum_left);\n        self.write_f32_array(buf, "g_AudioSpectrum16Right", &sys.audio_spectrum_right);\n'
    if marker not in e:
        raise SystemExit("g_ParallaxPosition marker not found in effect_param.rs")
    e = e.replace(marker, insertion, 1)

if "pub audio_spectrum_left: [f32; 16]" not in e:
    marker = '    pub cursor_position: [f32; 2],\n'
    insertion = marker + '    pub audio_spectrum_left: [f32; 16],\n    pub audio_spectrum_right: [f32; 16],\n'
    if marker not in e:
        raise SystemExit("SystemUniforms cursor field not found")
    e = e.replace(marker, insertion, 1)

if "audio_spectrum_left: [0.0; 16]" not in e:
    marker = '            cursor_position: [0.0, 0.0],\n'
    insertion = marker + '            audio_spectrum_left: [0.0; 16],\n            audio_spectrum_right: [0.0; 16],\n'
    if marker not in e:
        raise SystemExit("SystemUniforms default constructor marker not found")
    e = e.replace(marker, insertion, 1)
param_path.write_text(e)

# 3) Extend UserParams and add a deterministic synthetic spectrum only when
# WAIFUX_AUDIO_TEST=1. Normal runs remain unchanged (all-zero spectrum).
a = app_path.read_text()
if "pub audio_spectrum_left: [f32; 16]" not in a:
    marker = '    pub cursor_position: [f32; 2],\n'
    insertion = marker + '    pub audio_spectrum_left: [f32; 16],\n    pub audio_spectrum_right: [f32; 16],\n'
    if marker not in a:
        raise SystemExit("UserParams cursor field not found in app.rs")
    a = a.replace(marker, insertion, 1)

if "audio_spectrum_left: [0.0; 16]" not in a:
    marker = '            cursor_position: [0.5, 0.5],\n'
    insertion = marker + '            audio_spectrum_left: [0.0; 16],\n            audio_spectrum_right: [0.0; 16],\n'
    if marker not in a:
        raise SystemExit("UserParams default marker not found in app.rs")
    a = a.replace(marker, insertion, 1)

if "Stage-1 audio validation" not in a:
    marker = '        params.cursor_position = self.compute_parallax_cursor();\n'
    insertion = marker + '''

        // Stage-1 audio validation: deterministic synthetic 16-band spectrum.
        // This proves the AUDIOPROCESSING shader branch + uniform plumbing on
        // Intel Metal before wiring a real macOS system-output capture source.
        if std::env::var("WAIFUX_AUDIO_TEST").map(|v| v != "0").unwrap_or(false) {
            let beat = ((elapsed * 3.0).sin() * 0.5 + 0.5).powf(1.35);
            for i in 0..16 {
                let low_weight = ((16 - i) as f32 / 16.0).powf(0.65);
                let ripple = ((elapsed * 5.0 + i as f32 * 0.43).sin() * 0.12 + 0.88).max(0.0);
                let value = (0.08 + 0.92 * beat) * low_weight * ripple;
                params.audio_spectrum_left[i] = value.clamp(0.0, 1.0);
                params.audio_spectrum_right[i] = (value * 0.94).clamp(0.0, 1.0);
            }
        }
'''
    if marker not in a:
        raise SystemExit("UserParams render marker not found in app.rs")
    a = a.replace(marker, insertion, 1)
app_path.write_text(a)

# 4) Feed the spectra into both buffered-uniform and immediate/push-constant paths.
r = render_path.read_text()
if "audio_spectrum_left: user_params.audio_spectrum_left" not in r:
    marker = '                    cursor_position: user_params.cursor_position,\n'
    insertion = marker + '                    audio_spectrum_left: user_params.audio_spectrum_left,\n                    audio_spectrum_right: user_params.audio_spectrum_right,\n'
    if marker not in r:
        raise SystemExit("Buffered SystemUniforms marker not found")
    r = r.replace(marker, insertion, 1)

if r.count("audio_spectrum_left: user_params.audio_spectrum_left") < 2:
    marker = '        cursor_position: user_params.cursor_position,\n'
    insertion = marker + '        audio_spectrum_left: user_params.audio_spectrum_left,\n        audio_spectrum_right: user_params.audio_spectrum_right,\n'
    if marker not in r:
        raise SystemExit("Immediate SystemUniforms marker not found")
    r = r.replace(marker, insertion, 1)
render_path.write_text(r)

print("Audio shader rewrite + synthetic 16-band spectrum plumbing applied")
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
echo "Audio shader plumbing test rebuild complete."
echo "Normal run remains unchanged."
echo "Synthetic audio test run:"
echo "  WAIFUX_AUDIO_TEST=1 SCENE_MODE=full bash ~/Downloads/RUN_SCENE_A.command 2>&1 | tee ~/Desktop/scene-a-audio-test.log"
echo
echo "Expected log markers:"
echo "  rewrote CreateAudioResponse fixed-size array parameters for Naga/Metal"
echo "  AUDIOPROCESSING=3 retained"

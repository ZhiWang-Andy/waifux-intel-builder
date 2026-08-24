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

# ---------------------------------------------------------------------------
# 1) Naga compatibility: keep AUDIOPROCESSING enabled, but rewrite the one
#    Wallpaper Engine GLSL pattern Naga rejects: fixed-size array parameters.
#    The function instead reads the already-declared global uniform arrays.
# ---------------------------------------------------------------------------
p = pipeline_path.read_text()
old_source = '''    let frag_source = std::str::from_utf8(frag_raw).ok()?;\n    let vert_source = std::str::from_utf8(vert_raw).ok()?;\n'''
new_source = '''    let frag_source = std::str::from_utf8(frag_raw).ok()?;\n    let vert_source_raw = std::str::from_utf8(vert_raw).ok()?;\n    let mut vert_source_storage = vert_source_raw.to_string();\n\n    // Wallpaper Engine pulse/shake shaders pass two fixed-size float[16]\n    // arrays into CreateAudioResponse(). Naga's GLSL frontend currently\n    // rejects that function-call shape on this path. Specialize the helper\n    // to read the existing global uniform arrays directly instead.\n    if vert_source_storage.contains(\"CreateAudioResponse\") {\n        let old_sig = \"float CreateAudioResponse(float bufferLeft[16], float bufferRight[16])\";\n        if vert_source_storage.contains(old_sig) {\n            vert_source_storage = vert_source_storage.replace(old_sig, \"float CreateAudioResponse()\");\n            vert_source_storage = vert_source_storage.replace(\"bufferLeft[\", \"g_AudioSpectrum16Left[\");\n            vert_source_storage = vert_source_storage.replace(\"bufferRight[\", \"g_AudioSpectrum16Right[\");\n            vert_source_storage = vert_source_storage.replace(\n                \"CreateAudioResponse(g_AudioSpectrum16Left, g_AudioSpectrum16Right)\",\n                \"CreateAudioResponse()\",\n            );\n            log::info!(\"rewrote CreateAudioResponse fixed-size array parameters for Naga/Metal\");\n        }\n    }\n    let vert_source = vert_source_storage.as_str();\n'''
if "rewrote CreateAudioResponse fixed-size array parameters" not in p:
    if old_source not in p:
        raise SystemExit("Expected shader-source block not found in pipeline_handler.rs")
    p = p.replace(old_source, new_source, 1)

# Undo the earlier temporary AUDIOPROCESSING=0 fallback, but only if that
# experimental patch is present in the user's current working source tree.
old_fallback = '''            log::warn!(\n                \"AUDIOPROCESSING={} uses CreateAudioResponse array parameters; forcing AUDIOPROCESSING=0 for experimental Naga/Metal compatibility\",\n                defines.get(\"AUDIOPROCESSING\").map(String::as_str).unwrap_or(\"?\")\n            );\n            defines.insert(\"AUDIOPROCESSING\".to_string(), \"0\".to_string());\n'''
new_fallback = '''            log::info!(\n                \"AUDIOPROCESSING={} retained; CreateAudioResponse parameters are rewritten for Naga/Metal\",\n                defines.get(\"AUDIOPROCESSING\").map(String::as_str).unwrap_or(\"?\")\n            );\n'''
if old_fallback in p:
    p = p.replace(old_fallback, new_fallback, 1)
elif "AUDIOPROCESSING={} retained; CreateAudioResponse parameters are rewritten" not in p:
    print("NOTE: old AUDIOPROCESSING fallback block was not present; continuing")
pipeline_path.write_text(p)

# ---------------------------------------------------------------------------
# 2) Uniform writer: support float arrays using the same 16-byte stride that
#    UniformLayout::type_size() already assigns to GLSL arrays.
# ---------------------------------------------------------------------------
e = param_path.read_text()
method_marker = '''    pub fn write_f32(&self, buf: &mut [u8], name: &str, value: f32) -> bool {\n        self.write(buf, name, &value.to_le_bytes())\n    }\n'''
method_patch = '''    pub fn write_f32(&self, buf: &mut [u8], name: &str, value: f32) -> bool {\n        self.write(buf, name, &value.to_le_bytes())\n    }\n\n    pub fn write_f32_array(&self, buf: &mut [u8], name: &str, values: &[f32]) -> bool {\n        let Some(&(off, size)) = self.offsets.get(name) else { return false; };\n        if values.is_empty() { return false; }\n        let stride = size as usize / values.len();\n        if stride < 4 || off as usize + size as usize > buf.len() { return false; }\n        for (i, value) in values.iter().enumerate() {\n            let start = off as usize + i * stride;\n            buf[start..start + 4].copy_from_slice(&value.to_le_bytes());\n        }\n        true\n    }\n'''
if "pub fn write_f32_array" not in e:
    if method_marker not in e:
        raise SystemExit("write_f32 method marker not found in effect_param.rs")
    e = e.replace(method_marker, method_patch, 1)

cursor_marker = '''        self.write_vec2(buf, \"g_ParallaxPosition\", sys.cursor_position);\n\n        for (name, res) in &sys.tex_resolutions {\n'''
cursor_patch = '''        self.write_vec2(buf, \"g_ParallaxPosition\", sys.cursor_position);\n        self.write_f32_array(buf, \"g_AudioSpectrum16Left\", &sys.audio_spectrum_left);\n        self.write_f32_array(buf, \"g_AudioSpectrum16Right\", &sys.audio_spectrum_right);\n\n        for (name, res) in &sys.tex_resolutions {\n'''
if "g_AudioSpectrum16Left" not in e:
    if cursor_marker not in e:
        raise SystemExit("Parallax uniform marker not found in effect_param.rs")
    e = e.replace(cursor_marker, cursor_patch, 1)

sys_field = '''    /// Normalized cursor position in [0, 1] range, (0,0) = top-left (UV space)\n    pub cursor_position: [f32; 2],\n'''
sys_patch = '''    /// Normalized cursor position in [0, 1] range, (0,0) = top-left (UV space)\n    pub cursor_position: [f32; 2],\n    pub audio_spectrum_left: [f32; 16],\n    pub audio_spectrum_right: [f32; 16],\n'''
if "pub audio_spectrum_left" not in e:
    if sys_field not in e:
        raise SystemExit("SystemUniforms cursor field marker not found")
    e = e.replace(sys_field, sys_patch, 1)

with_res_old = '''            tex_resolutions: BTreeMap::new(),\n            cursor_position: [0.0, 0.0],\n'''
with_res_new = '''            tex_resolutions: BTreeMap::new(),\n            cursor_position: [0.0, 0.0],\n            audio_spectrum_left: [0.0; 16],\n            audio_spectrum_right: [0.0; 16],\n'''
if "audio_spectrum_left: [0.0; 16]" not in e:
    if with_res_old not in e:
        raise SystemExit("SystemUniforms::with_resolution marker not found")
    e = e.replace(with_res_old, with_res_new, 1)
param_path.write_text(e)

# ---------------------------------------------------------------------------
# 3) UserParams + synthetic test spectrum. This is intentionally gated by
#    WAIFUX_AUDIO_TEST=1 so normal rendering remains unchanged.
# ---------------------------------------------------------------------------
a = app_path.read_text()
user_field = '''pub struct UserParams {\n    pub cursor_position: [f32; 2],\n}\n'''
user_patch = '''pub struct UserParams {\n    pub cursor_position: [f32; 2],\n    pub audio_spectrum_left: [f32; 16],\n    pub audio_spectrum_right: [f32; 16],\n}\n'''
if "pub audio_spectrum_left" not in a:
    if user_field not in a:
        raise SystemExit("UserParams struct marker not found in app.rs")
    a = a.replace(user_field, user_patch, 1)

default_old = '''        Self {\n            cursor_position: [0.5, 0.5],\n        }\n'''
default_new = '''        Self {\n            cursor_position: [0.5, 0.5],\n            audio_spectrum_left: [0.0; 16],\n            audio_spectrum_right: [0.0; 16],\n        }\n'''
if "audio_spectrum_left: [0.0; 16]" not in a:
    if default_old not in a:
        raise SystemExit("UserParams default marker not found in app.rs")
    a = a.replace(default_old, default_new, 1)

render_marker = '''        let mut params = self.user_params.clone();\n        params.cursor_position = self.compute_parallax_cursor();\n\n        render_pass::write_effect_uniforms(\n'''
render_patch = '''        let mut params = self.user_params.clone();\n        params.cursor_position = self.compute_parallax_cursor();\n\n        // Stage-1 audio validation: deterministic synthetic 16-band spectrum.\n        // This proves the AUDIOPROCESSING shader branch + uniform plumbing on\n        // Intel Metal before we add ScreenCaptureKit system-output capture.\n        if std::env::var(\"WAIFUX_AUDIO_TEST\").map(|v| v != \"0\").unwrap_or(false) {\n            let beat = ((elapsed * 3.0).sin() * 0.5 + 0.5).powf(1.35);\n            for i in 0..16 {\n                let low_weight = ((16 - i) as f32 / 16.0).powf(0.65);\n                let ripple = ((elapsed * 5.0 + i as f32 * 0.43).sin() * 0.12 + 0.88).max(0.0);\n                let value = (0.08 + 0.92 * beat) * low_weight * ripple;\n                params.audio_spectrum_left[i] = value.clamp(0.0, 1.0);\n                params.audio_spectrum_right[i] = (value * 0.94).clamp(0.0, 1.0);\n            }\n        }\n\n        render_pass::write_effect_uniforms(\n'''
if "Stage-1 audio validation" not in a:
    if render_marker not in a:
        raise SystemExit("render UserParams marker not found in app.rs")
    a = a.replace(render_marker, render_patch, 1)
app_path.write_text(a)

# ---------------------------------------------------------------------------
# 4) Feed UserParams spectrum into both uniform-buffer and immediate paths.
# ---------------------------------------------------------------------------
r = render_path.read_text()
sys_old = '''                let sys = SystemUniforms {\n                    screen_resolution: screen_res,\n                    tex_resolutions: step.bindgroup.tex_resolutions.clone(),\n                    cursor_position: user_params.cursor_position,\n                };\n'''
sys_new = '''                let sys = SystemUniforms {\n                    screen_resolution: screen_res,\n                    tex_resolutions: step.bindgroup.tex_resolutions.clone(),\n                    cursor_position: user_params.cursor_position,\n                    audio_spectrum_left: user_params.audio_spectrum_left,\n                    audio_spectrum_right: user_params.audio_spectrum_right,\n                };\n'''
if "audio_spectrum_left: user_params.audio_spectrum_left" not in r:
    if sys_old not in r:
        raise SystemExit("Buffered SystemUniforms constructor not found in render_pass.rs")
    r = r.replace(sys_old, sys_new, 1)

sys2_old = '''    let sys = SystemUniforms {\n        screen_resolution: screen_res,\n        tex_resolutions: step.bindgroup.tex_resolutions.clone(),\n        cursor_position: user_params.cursor_position,\n    };\n'''
sys2_new = '''    let sys = SystemUniforms {\n        screen_resolution: screen_res,\n        tex_resolutions: step.bindgroup.tex_resolutions.clone(),\n        cursor_position: user_params.cursor_position,\n        audio_spectrum_left: user_params.audio_spectrum_left,\n        audio_spectrum_right: user_params.audio_spectrum_right,\n    };\n'''
# The first constructor above is indented more deeply; this matches build_immediates_data.
if r.count("audio_spectrum_left: user_params.audio_spectrum_left") < 2:
    if sys2_old not in r:
        raise SystemExit("Immediate SystemUniforms constructor not found in render_pass.rs")
    r = r.replace(sys2_old, sys2_new, 1)
render_path.write_text(r)

print("Audio shader rewrite + 16-band synthetic spectrum plumbing applied")
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

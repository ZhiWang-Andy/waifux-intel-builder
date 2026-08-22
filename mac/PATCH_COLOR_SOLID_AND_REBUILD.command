#!/bin/bash
set -euo pipefail

WORKROOT="$HOME/Library/Application Support/WaifuX Intel Scene Experimental"
SRC="$WORKROOT/src/linux-wallpaperengine"
BIN_DIR="$WORKROOT/bin"
OUT_BIN="$BIN_DIR/linux-wallpaper-engine"
SCENE_RS="$SRC/src/scene/loader/scene.rs"
OBJECT_RS="$SRC/src/scene/loader/object_loader.rs"
DRAW_RS="$SRC/src/scene/renderer/draw.rs"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this on macOS."
[[ "$(uname -m)" == "x86_64" ]] || fail "This rebuild is intended for Intel macOS."
[[ -d "$SRC/.git" ]] || fail "Experimental source tree not found. Run BUILD_SCENE_EXPERIMENTAL.command first."
[[ -f "$SCENE_RS" ]] || fail "scene.rs not found: $SCENE_RS"
[[ -f "$OBJECT_RS" ]] || fail "object_loader.rs not found: $OBJECT_RS"
[[ -f "$DRAW_RS" ]] || fail "draw.rs not found: $DRAW_RS"
command -v cargo >/dev/null 2>&1 || fail "cargo is not available. Run: source \"$HOME/.cargo/env\""
command -v python3 >/dev/null 2>&1 || fail "python3 is required."

cd "$SRC"

echo "=== Patching Scene layer color/tint + solid background support ==="
python3 - "$SCENE_RS" "$OBJECT_RS" "$DRAW_RS" <<'PY'
from pathlib import Path
import sys

scene_path = Path(sys.argv[1])
object_path = Path(sys.argv[2])
draw_path = Path(sys.argv[3])

# ---------------------------------------------------------------------------
# 1) User-bound vector properties: {"user":"...", "value":"r g b"}
# ---------------------------------------------------------------------------
scene = scene_path.read_text()
old = '''            Vectors::Object(_) => None,
'''
new = '''            Vectors::Object(value) => {
                // Wallpaper Engine user-bound vector/color property, e.g.
                // {"user":"layer7color","value":"0.10 0.20 0.30"}.
                // Resolve the embedded default `value` so static rendering uses
                // the same visible color as Wallpaper Engine before any UI override.
                let inner = value.get("value").unwrap_or(value);
                match inner {
                    Value::Number(n) => n.as_f64().map(|v| Vec3::splat(v as f32)),
                    Value::String(s) => Vectors::Vectors(s.clone()).parse(),
                    Value::Object(_) => Vectors::Object(inner.clone()).parse(),
                    _ => None,
                }
            }
'''
if "Wallpaper Engine user-bound vector/color property" not in scene:
    if old not in scene:
        raise SystemExit("Expected Vectors::Object(_) branch was not found in scene.rs")
    scene = scene.replace(old, new, 1)
else:
    print("User-bound vector/color patch already present")
scene_path.write_text(scene)

# ---------------------------------------------------------------------------
# 2) Object loader: retain per-layer tint and synthesize solid layers without
#    requiring proprietary materials/util/solidlayer.json on disk.
# ---------------------------------------------------------------------------
obj = object_path.read_text()

field_needle = '''    /// Optional puppet mesh extracted from a `.mdl` file.\n    pub mesh: Option<PuppetMesh>,\n'''
field_patch = '''    /// Optional puppet mesh extracted from a `.mdl` file.\n    pub mesh: Option<PuppetMesh>,\n    /// Wallpaper Engine per-layer RGBA multiplier. RGB includes `brightness`;\n    /// A contains object alpha. Applied during source texture upload so post\n    /// effects operate on the correctly tinted image.\n    pub tint: [f32; 4],\n'''
if "pub tint: [f32; 4]" not in obj:
    if field_needle not in obj:
        raise SystemExit("TextureObject mesh field pattern not found")
    obj = obj.replace(field_needle, field_patch, 1)

helper_marker = '''impl ObjectMap {\n    pub fn with_clear_color'''
helpers = r'''fn bound_f64(value: Option<&Value>) -> Option<f64> {
    let value = value?;
    if let Some(v) = value.as_f64() {
        return Some(v);
    }
    let inner = value.get("value")?;
    if let Some(v) = inner.as_f64() {
        return Some(v);
    }
    inner.as_str()?.parse::<f64>().ok()
}

fn object_tint(object: &Object) -> [f32; 4] {
    let color = object
        .color
        .as_ref()
        .and_then(|c| c.parse())
        .unwrap_or(Vec3::ONE);
    let brightness = object.brightness.unwrap_or(1.0) as f32;
    let alpha = bound_f64(object.alpha.as_ref()).unwrap_or(1.0) as f32;
    [
        (color.x * brightness).max(0.0),
        (color.y * brightness).max(0.0),
        (color.z * brightness).max(0.0),
        alpha.clamp(0.0, 1.0),
    ]
}

fn make_solid_texture(object: &Object) -> Rc<Tex> {
    let tint = object_tint(object);
    let r = (tint[0].clamp(0.0, 1.0) * 255.0).round() as u8;
    let g = (tint[1].clamp(0.0, 1.0) * 255.0).round() as u8;
    let b = (tint[2].clamp(0.0, 1.0) * 255.0).round() as u8;
    let a = (tint[3].clamp(0.0, 1.0) * 255.0).round() as u8;
    log::debug!(
        "solidlayer '{}': synthesized 1x1 rgba({},{},{},{})",
        object.name, r, g, b, a,
    );
    Rc::new(Tex {
        texv: String::new(),
        texi: String::new(),
        texb: String::new(),
        size: 4,
        actual_mip_count: 1,
        dimension: [1, 1],
        image_count: 1,
        mipmap_count: 1,
        lz4: false,
        decompressed_size: 4,
        extension: "solid".into(),
        payload: vec![r, g, b, a],
        mip_levels: Vec::new(),
    })
}

'''
if "fn object_tint(object: &Object)" not in obj:
    if helper_marker not in obj:
        raise SystemExit("ObjectMap impl marker not found")
    obj = obj.replace(helper_marker, helpers + helper_marker, 1)

# Solid layers declare model.solidlayer=true. Resolve them before material JSON
# lookup so the renderer does not depend on materials/util/solidlayer.json.
early_marker = '''        // ── load material JSON ────────────────────────────────────\n'''
early_patch = '''        // ── native solidlayer synthesis ─────────────────────────────\n        // `models/util/solidlayer.json` sets solidlayer=true but its material\n        // lives in Wallpaper Engine's shared assets. A solid layer needs no\n        // material or texture at all, so synthesize its 1x1 RGBA source here.\n        if model.solidlayer == Some(true) {\n            return Some(make_solid_texture(object));\n        }\n\n        // ── load material JSON ────────────────────────────────────\n'''
if "native solidlayer synthesis" not in obj:
    if early_marker not in obj:
        raise SystemExit("Material-load marker not found in resolve_texture")
    obj = obj.replace(early_marker, early_patch, 1)

# Replace the old duplicated solidlayer RGBA construction with the shared helper.
old_solid_start = '''        if is_solidlayer {\n            let color_vec = object\n'''
if old_solid_start in obj:
    start = obj.index(old_solid_start)
    end_marker = '''        // ── normal texture lookup ─────────────────────────────────\n'''
    end = obj.index(end_marker, start)
    replacement = '''        if is_solidlayer {\n            return Some(make_solid_texture(object));\n        }\n\n'''
    obj = obj[:start] + replacement + obj[end:]

# Attach the resolved tint to each normal TextureObject. Solid textures are
# already synthesized with their final RGBA value, so they use neutral tint.
construct_needle = '''            return Some(ObjectType::Texture(TextureObject {\n                transform,\n'''
construct_patch = '''            let tint = if texture.extension == "solid" {\n                [1.0, 1.0, 1.0, 1.0]\n            } else {\n                object_tint(object)\n            };\n            if tint != [1.0, 1.0, 1.0, 1.0] {\n                log::debug!(\n                    "object '{}' tint rgba=({:.4},{:.4},{:.4},{:.4})",\n                    object.name, tint[0], tint[1], tint[2], tint[3]\n                );\n            }\n\n            return Some(ObjectType::Texture(TextureObject {\n                transform,\n'''
if "object '{}' tint rgba=" not in obj:
    if construct_needle not in obj:
        raise SystemExit("TextureObject construction marker not found")
    obj = obj.replace(construct_needle, construct_patch, 1)

mesh_needle = '''                visible,\n                mesh,\n            }));\n'''
mesh_patch = '''                visible,\n                mesh,\n                tint,\n            }));\n'''
if "                tint,\n            }));" not in obj:
    if mesh_needle not in obj:
        raise SystemExit("TextureObject final fields marker not found")
    obj = obj.replace(mesh_needle, mesh_patch, 1)

object_path.write_text(obj)

# ---------------------------------------------------------------------------
# 3) Renderer: apply static layer tint to decoded RGBA source pixels before
#    effects. This is deliberately per-object; multiple scene layers can share
#    one .tex while using different Wallpaper Engine color properties.
# ---------------------------------------------------------------------------
draw = draw_path.read_text()

use_old = 'use std::{collections::BTreeMap, rc::Rc};\n'
use_new = 'use std::{borrow::Cow, collections::BTreeMap, rc::Rc};\n'
if "borrow::Cow" not in draw:
    if use_old not in draw:
        raise SystemExit("draw.rs std import pattern not found")
    draw = draw.replace(use_old, use_new, 1)

write_marker = '''        queue.write_texture(\n            TexelCopyTextureInfo {\n                texture: &texture,\n                mip_level: 0,\n'''
tint_block = '''        // Wallpaper Engine image layers multiply the decoded texture by\n        // object.color * object.brightness and object.alpha. Do this on a\n        // per-object copy of level 0 so shared source textures can have\n        // different colors. Post-process effects then receive the correctly\n        // tinted source. BCn/R8/RG88 remain on their native GPU paths.\n        let level0_payload: Cow<'_, [u8]> = if !is_bcn\n            && !matches!(ext, "r8" | "rg88")\n            && tex_obj.texture.payload.len() == (w as usize * h as usize * 4)\n        {\n            let t = tex_obj.tint;\n            let needs_tint = (t[0] - 1.0).abs() > 0.0001\n                || (t[1] - 1.0).abs() > 0.0001\n                || (t[2] - 1.0).abs() > 0.0001\n                || (t[3] - 1.0).abs() > 0.0001;\n            if needs_tint {\n                let mut rgba = tex_obj.texture.payload.clone();\n                for px in rgba.chunks_exact_mut(4) {\n                    px[0] = ((px[0] as f32 * t[0]).clamp(0.0, 255.0)).round() as u8;\n                    px[1] = ((px[1] as f32 * t[1]).clamp(0.0, 255.0)).round() as u8;\n                    px[2] = ((px[2] as f32 * t[2]).clamp(0.0, 255.0)).round() as u8;\n                    px[3] = ((px[3] as f32 * t[3]).clamp(0.0, 255.0)).round() as u8;\n                }\n                log::debug!(\n                    "upload_texture: applying layer tint rgba=({:.4},{:.4},{:.4},{:.4})",\n                    t[0], t[1], t[2], t[3]\n                );\n                Cow::Owned(rgba)\n            } else {\n                Cow::Borrowed(&tex_obj.texture.payload)\n            }\n        } else {\n            if tex_obj.tint != [1.0, 1.0, 1.0, 1.0] {\n                log::warn!(\n                    "upload_texture: tint not yet applied to native format '{}'",\n                    ext\n                );\n            }\n            Cow::Borrowed(&tex_obj.texture.payload)\n        };\n\n        queue.write_texture(\n            TexelCopyTextureInfo {\n                texture: &texture,\n                mip_level: 0,\n'''
if "upload_texture: applying layer tint" not in draw:
    if write_marker not in draw:
        raise SystemExit("Level-0 queue.write_texture marker not found")
    draw = draw.replace(write_marker, tint_block, 1)

payload_old = '''            &tex_obj.texture.payload,\n            TexelCopyBufferLayout {\n'''
payload_new = '''            level0_payload.as_ref(),\n            TexelCopyBufferLayout {\n'''
# Only replace the first occurrence: this is level 0; mip uploads below must
# continue using each level_data unchanged.
if "            level0_payload.as_ref(),\n" not in draw:
    if payload_old not in draw:
        raise SystemExit("Level-0 payload argument not found")
    draw = draw.replace(payload_old, payload_new, 1)

draw_path.write_text(draw)

print("Color/tint + solid background compatibility patch applied")
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
echo "Color/tint + solid background rebuild complete."
echo "No additional Wallpaper Engine material files are required for solidlayer."
echo
echo "Next run:"
echo "  SCENE_MODE=full bash ~/Downloads/RUN_SCENE_A.command 2>&1 | tee ~/Desktop/scene-a-full-color.log"

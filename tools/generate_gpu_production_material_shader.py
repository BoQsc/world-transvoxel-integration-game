#!/usr/bin/env python3
"""Generate the resident RD shader from the accepted production material source."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "addons/world_transvoxel_gameworld/material/wt_game_terrain_palette.gdshader"
TARGET = ROOT / "addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render_production.glsl"


VERTEX_SOURCE = r'''#[vertex]
#version 450

#define MAX_VIEWS 2

struct WtSceneDataMatrices {
	mat4 projection_matrix;
	mat4 inv_projection_matrix;
	mat3x4 inv_view_matrix;
	mat3x4 view_matrix;
#ifdef USE_DOUBLE_PRECISION
	vec4 inv_view_precision;
#endif
	mat4 projection_matrix_view[MAX_VIEWS];
};

layout(set = 0, binding = 0, std140) uniform SceneDataBlock {
	WtSceneDataMatrices data;
} scene_data_block;

layout(location = 0) in vec4 vertex_position;
layout(location = 1) in vec4 vertex_normal;
layout(location = 2) in ivec4 vertex_meta;

layout(push_constant, std430) uniform Params {
	ivec4 view;
} params;

layout(location = 0) out vec3 world_position;
layout(location = 1) out vec3 world_normal;
layout(location = 2) out vec4 generated_material_weights_low;
layout(location = 3) out vec4 generated_material_weights_high;
layout(location = 4) out vec4 authored_material_weights_low;
layout(location = 5) out vec4 authored_material_weights_high;

int material_weight_slot(int material) {
	if (material == 1) return 0;
	if (material == 2) return 1;
	if (material == 3) return 2;
	if (material == 4) return 3;
	if (material == 5) return 4;
	if (material == 7) return 5;
	if (material == 8) return 6;
	if (material == 10) return 7;
	return -1;
}

void main() {
	mat4 view_matrix = transpose(mat4(
		scene_data_block.data.view_matrix[0],
		scene_data_block.data.view_matrix[1],
		scene_data_block.data.view_matrix[2],
		vec4(0.0, 0.0, 0.0, 1.0)
	));
	mat4 projection = scene_data_block.data.projection_matrix;
	if (params.view.y > 1) {
		projection = scene_data_block.data.projection_matrix_view[params.view.x];
	}
	world_position = vertex_position.xyz;
	world_normal = normalize(vertex_normal.xyz);
	gl_Position = projection * view_matrix * vec4(world_position, 1.0);
	generated_material_weights_low = vec4(0.0);
	generated_material_weights_high = vec4(0.0);
	authored_material_weights_low = vec4(0.0);
	authored_material_weights_high = vec4(0.0);
	int slot = material_weight_slot(vertex_meta.x);
	if (slot < 0) {
		return;
	}
	if (vertex_meta.y != 0) {
		if (slot < 4) authored_material_weights_low[slot] = 1.0;
		else authored_material_weights_high[slot - 4] = 1.0;
	} else {
		if (slot < 4) generated_material_weights_low[slot] = 1.0;
		else generated_material_weights_high[slot - 4] = 1.0;
	}
}
'''


FRAGMENT_PREAMBLE = r'''#[fragment]
#version 450

layout(location = 0) in vec3 world_position;
layout(location = 1) in vec3 world_normal;
layout(location = 2) in vec4 generated_material_weights_low;
layout(location = 3) in vec4 generated_material_weights_high;
layout(location = 4) in vec4 authored_material_weights_low;
layout(location = 5) in vec4 authored_material_weights_high;
layout(location = 0) out vec4 output_color;

layout(set = 1, binding = 0, std140) uniform ProductionMaterialParams {
	vec4 feature_flags;
	vec4 scalar_0;
	vec4 scalar_1;
	vec4 scalar_2;
	vec4 world_size;
	vec4 road_grades[18];
} material_params;
layout(set = 1, binding = 1) uniform sampler2D checker_texture;
layout(set = 1, binding = 2) uniform sampler2DArray terrain_albedo_array;
layout(set = 1, binding = 3) uniform sampler2DArray terrain_normal_array;
layout(set = 1, binding = 4) uniform sampler2DArray terrain_roughness_array;
layout(set = 1, binding = 5) uniform sampler2D clean_albedo_texture;

#define procedural_ore_worldspace_blend_enabled (material_params.feature_flags.x > 0.5)
#define procedural_rolling_exterior_surface_enabled (material_params.feature_flags.y > 0.5)
#define procedural_road_worldspace_blend_enabled (material_params.feature_flags.z > 0.5)
#define procedural_four_biome_world_enabled (material_params.feature_flags.w > 0.5)
#define procedural_seed_phase material_params.scalar_0.x
#define procedural_ore_blend_width material_params.scalar_0.y
#define procedural_road_half_width material_params.scalar_0.z
#define procedural_road_shoulder_width material_params.scalar_0.w
#define procedural_surface_cover_full_depth material_params.scalar_1.x
#define procedural_surface_cover_fade_depth material_params.scalar_1.y
#define procedural_surface_cover_normal_start material_params.scalar_1.z
#define procedural_surface_cover_normal_end material_params.scalar_1.w
#define procedural_surface_biome_height_blend_width material_params.scalar_2.x
#define procedural_surface_biome_noise_blend_width material_params.scalar_2.y
#define procedural_world_size_xz material_params.world_size.xy
'''


FRAGMENT_CONSTANTS = r'''
const vec4 material_1_color = vec4(0.24, 0.25, 0.24, 1.0);
const vec4 material_2_color = vec4(0.28, 0.39, 0.20, 1.0);
const vec4 material_3_color = vec4(0.36, 0.35, 0.33, 1.0);
const vec4 material_4_color = vec4(0.56, 0.49, 0.35, 1.0);
const vec4 material_5_color = vec4(0.68, 0.70, 0.66, 1.0);
const vec4 material_7_color = vec4(0.31, 0.32, 0.31, 1.0);
const vec4 material_8_color = vec4(0.48, 0.29, 0.13, 1.0);
const vec4 material_10_color = vec4(0.09, 0.10, 0.11, 1.0);
const bool clean_visual_enabled = false;
const bool clean_texture_enabled = false;
const vec4 clean_albedo_color = vec4(0.72, 0.65, 0.50, 1.0);
const float clean_texture_world_scale = 0.125;
const bool clean_triplanar_enabled = true;
const float clean_triplanar_blend_sharpness = 4.0;
const bool clean_material_variation_enabled = false;
const float clean_material_variation_strength = 0.08;
const float clean_roughness = 1.0;
const float clean_specular = 0.0;
const float PRODUCTION_TEXTURE_WORLD_SCALE = 0.125;
const float PRODUCTION_TRIPLANAR_BLEND_SHARPNESS = 4.0;
'''


def extract_function_block(source: str) -> str:
    start = source.index("float material_layer(")
    end = source.index("void fragment()")
    return source[start:end].rstrip()


def transform_fragment(source: str) -> str:
    fragment = source[source.index("void fragment()"):].strip()
    fragment = fragment.replace(
        "void fragment() {",
        "vec3 production_fragment_albedo() {\n\tvec3 output_albedo = vec3(0.0);",
        1,
    )
    discarded_prefixes = ("NORMAL =", "METALLIC =", "SPECULAR =", "ROUGHNESS =")
    kept = [
        line for line in fragment.splitlines()
        if not line.strip().startswith(discarded_prefixes)
    ]
    fragment = "\n".join(kept).replace("ALBEDO =", "output_albedo =")
    closing = fragment.rfind("}")
    fragment = fragment[:closing] + "\treturn output_albedo;\n" + fragment[closing:]
    return fragment


def generated_source(source: str) -> str:
    road_aliases = "\n".join(
        f"#define procedural_road_grade_{index} material_params.road_grades[{index}].xy"
        for index in range(18)
    )
    source_hash = hashlib.sha256(source.encode("utf-8")).hexdigest()
    return (
        f"// Generated by tools/generate_gpu_production_material_shader.py\n"
        f"// production_material_source_sha256={source_hash}\n\n"
        + VERTEX_SOURCE
        + "\n"
        + FRAGMENT_PREAMBLE
        + road_aliases
        + "\n"
        + FRAGMENT_CONSTANTS
        + "\n"
        + extract_function_block(source)
        + "\n\n"
        + transform_fragment(source)
        + r'''

void main() {
	vec3 albedo = clamp(production_fragment_albedo(), vec3(0.0), vec3(1.0));
	vec3 unit_normal = normalize(world_normal);
	float light = 0.28 + 0.72 * abs(dot(
		unit_normal, normalize(vec3(0.35, 0.70, 0.62))
	));
	output_color = vec4(albedo * light, 1.0);
}
'''
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = SOURCE.read_text(encoding="utf-8")
    generated = generated_source(source)
    if args.check:
        if not TARGET.exists() or TARGET.read_text(encoding="utf-8") != generated:
            raise SystemExit("GPU production material shader is stale")
        print("GPU_PRODUCTION_MATERIAL_SHADER_PASS")
        return 0
    TARGET.write_text(generated, encoding="utf-8", newline="\n")
    print(f"generated {TARGET.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

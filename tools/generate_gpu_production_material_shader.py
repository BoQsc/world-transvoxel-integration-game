#!/usr/bin/env python3
"""Generate the resident RD shader from the accepted production material source."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "addons/world_transvoxel_gameworld/material/wt_game_terrain_palette.gdshader"
TARGET = ROOT / "addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render_production.glsl"
WATER_SOURCE = ROOT / "addons/world_transvoxel_gameworld/material/wt_game_static_water.gdshader"
WATER_TARGET = ROOT / "addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render_water.glsl"


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
layout(set = 3, binding = 0, std430) readonly buffer ActivationFlags {
	uint values[];
} activation_flags;

layout(location = 0) in vec3 vertex_position;
layout(location = 1) in vec2 vertex_normal;
layout(location = 2) in uvec2 vertex_meta;

layout(push_constant, std430) uniform Params {
	ivec4 view;
	vec4 quantization_min;
	vec4 quantization_extent;
} params;

layout(location = 0) out vec3 world_position;
layout(location = 1) out vec3 world_normal;
layout(location = 2) out vec4 generated_material_weights_low;
layout(location = 3) out vec4 generated_material_weights_high;
layout(location = 4) out vec4 authored_material_weights_low;
layout(location = 5) out vec4 authored_material_weights_high;
layout(location = 6) out vec3 world_view_direction;

const uint ACTIVE_BIT = 0x80000000u;

bool resident_vertex_visible(uint state, uvec2 meta) {
	if ((state & ACTIVE_BIT) == 0u) return false;
	uint meshlet_tag = meta.y >> 8;
	return meshlet_tag == 0u || meshlet_tag > 8u ||
		(state & (1u << (meshlet_tag - 1u))) != 0u;
}

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
	world_position = vertex_position;
	vec2 octahedral = vertex_normal;
	vec3 decoded_normal = vec3(
		octahedral,
		1.0 - abs(octahedral.x) - abs(octahedral.y)
	);
	if (decoded_normal.z < 0.0) {
		decoded_normal.xy = (1.0 - abs(decoded_normal.yx)) *
			sign(decoded_normal.xy);
	}
	world_normal = normalize(decoded_normal);
	vec3 view_position = (view_matrix * vec4(world_position, 1.0)).xyz;
	world_view_direction = normalize(
		transpose(mat3(view_matrix)) * -view_position
	);
	gl_Position = projection * vec4(view_position, 1.0);
	if (params.view.z >= 0 && !resident_vertex_visible(
			activation_flags.values[params.view.z], vertex_meta
	)) {
		gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
	}
	generated_material_weights_low = vec4(0.0);
	generated_material_weights_high = vec4(0.0);
	authored_material_weights_low = vec4(0.0);
	authored_material_weights_high = vec4(0.0);
	int slot = material_weight_slot(int(vertex_meta.x));
	if (slot < 0) {
		return;
	}
	if ((vertex_meta.y & 0xffu) != 0u) {
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
layout(location = 6) in vec3 world_view_direction;
layout(location = 0) out vec4 output_color;

layout(set = 1, binding = 0, std140) uniform ProductionMaterialParams {
	vec4 feature_flags;
	vec4 scalar_0;
	vec4 scalar_1;
	vec4 scalar_2;
	vec4 world_size;
	vec4 road_grades[18];
	vec4 ambient_light;
	vec4 directional_light;
	vec4 directional_direction;
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

struct ProductionMaterialResponse {
	vec3 albedo;
	float roughness;
	float specular;
	float metallic;
};
'''


def extract_function_block(source: str) -> str:
    start = source.index("float material_layer(")
    end = source.index("void fragment()")
    return source[start:end].rstrip()


def transform_fragment(source: str) -> str:
    fragment = source[source.index("void fragment()"):].strip()
    fragment = fragment.replace(
        "void fragment() {",
        (
            "ProductionMaterialResponse production_fragment_material() {\n"
            "\tProductionMaterialResponse result;\n"
            "\tresult.albedo = vec3(0.0);\n"
            "\tresult.roughness = 1.0;\n"
            "\tresult.specular = 0.0;\n"
            "\tresult.metallic = 0.0;"
        ),
        1,
    )
    discarded_prefixes = ("NORMAL =",)
    kept = [
        line for line in fragment.splitlines()
        if not line.strip().startswith(discarded_prefixes)
    ]
    fragment = "\n".join(kept)
    fragment = fragment.replace("ALBEDO =", "result.albedo =")
    fragment = fragment.replace("ROUGHNESS =", "result.roughness =")
    fragment = fragment.replace("SPECULAR =", "result.specular =")
    fragment = fragment.replace("METALLIC =", "result.metallic =")
    closing = fragment.rfind("}")
    fragment = fragment[:closing] + "\treturn result;\n" + fragment[closing:]
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
	ProductionMaterialResponse material = production_fragment_material();
	vec3 albedo = clamp(material.albedo, vec3(0.0), vec3(1.0));
	vec3 unit_normal = normalize(world_normal);
	vec3 unit_view = normalize(world_view_direction);
	vec3 unit_light = normalize(material_params.directional_direction.xyz);
	vec3 half_direction = normalize(unit_light + unit_view);
	float n_dot_l = max(dot(unit_normal, unit_light), 0.0);
	float n_dot_v = max(dot(unit_normal, unit_view), 0.0);
	float l_dot_h = max(dot(unit_light, half_direction), 0.0);
	float roughness = clamp(material.roughness, 0.0, 1.0);
	float fd90 = 0.5 + 2.0 * l_dot_h * l_dot_h * roughness;
	float light_scatter = 1.0 + (fd90 - 1.0) * pow(1.0 - n_dot_l, 5.0);
	float view_scatter = 1.0 + (fd90 - 1.0) * pow(1.0 - n_dot_v, 5.0);
	float diffuse_burley = n_dot_l * light_scatter * view_scatter;
	vec3 ambient_response = material_params.ambient_light.rgb *
		material_params.ambient_light.a;
	vec3 directional_response = material_params.directional_light.rgb *
		material_params.directional_light.a * diffuse_burley;
	output_color = vec4(albedo * (ambient_response + directional_response), 1.0);
}
'''
    )


def generated_water_source(source: str) -> str:
    source_hash = hashlib.sha256(source.encode("utf-8")).hexdigest()
    return f'''// Generated by tools/generate_gpu_production_material_shader.py
// production_water_source_sha256={source_hash}

#[vertex]
#version 450

#define MAX_VIEWS 2

struct WtSceneDataMatrices {{
\tmat4 projection_matrix;
\tmat4 inv_projection_matrix;
\tmat3x4 inv_view_matrix;
\tmat3x4 view_matrix;
#ifdef USE_DOUBLE_PRECISION
\tvec4 inv_view_precision;
#endif
\tmat4 projection_matrix_view[MAX_VIEWS];
}};

layout(set = 0, binding = 0, std140) uniform SceneDataBlock {{
\tWtSceneDataMatrices data;
}} scene_data_block;
layout(set = 3, binding = 0, std430) readonly buffer ActivationFlags {{
\tuint values[];
}} activation_flags;

layout(location = 0) in vec3 vertex_position;
layout(location = 1) in vec2 vertex_normal;
layout(location = 2) in uvec2 vertex_meta;

layout(push_constant, std430) uniform Params {{
\tivec4 view;
\tivec4 viewport;
\tvec4 quantization_min;
\tvec4 quantization_extent;
}} params;

layout(location = 0) out vec3 world_normal;
layout(location = 1) out vec3 world_view_direction;
layout(location = 2) out vec3 view_normal;

const uint ACTIVE_BIT = 0x80000000u;

bool resident_vertex_visible(uint state, uvec2 meta) {{
\tif ((state & ACTIVE_BIT) == 0u) return false;
\tuint meshlet_tag = meta.y >> 8;
\treturn meshlet_tag == 0u || meshlet_tag > 8u ||
\t\t(state & (1u << (meshlet_tag - 1u))) != 0u;
}}

void main() {{
\tmat4 view_matrix = transpose(mat4(
\t\tscene_data_block.data.view_matrix[0],
\t\tscene_data_block.data.view_matrix[1],
\t\tscene_data_block.data.view_matrix[2],
\t\tvec4(0.0, 0.0, 0.0, 1.0)
\t));
\tmat4 projection = scene_data_block.data.projection_matrix;
\tif (params.view.y > 1) {{
\t\tprojection = scene_data_block.data.projection_matrix_view[params.view.x];
\t}}
\tvec3 world_position = vertex_position;
\tvec3 view_position = (view_matrix * vec4(world_position, 1.0)).xyz;
\tvec2 octahedral = vertex_normal;
\tvec3 decoded_normal = vec3(
\t\toctahedral,
\t\t1.0 - abs(octahedral.x) - abs(octahedral.y)
\t);
\tif (decoded_normal.z < 0.0) {{
\t\tdecoded_normal.xy = (1.0 - abs(decoded_normal.yx)) *
\t\t\tsign(decoded_normal.xy);
\t}}
\tworld_normal = normalize(decoded_normal);
\tview_normal = normalize(mat3(view_matrix) * world_normal);
\tworld_view_direction = normalize(
\t\ttranspose(mat3(view_matrix)) * -view_position
\t);
\tgl_Position = projection * vec4(view_position, 1.0);
\tif (params.view.z >= 0 && !resident_vertex_visible(
\t\t\tactivation_flags.values[params.view.z], vertex_meta
\t)) {{
\t\tgl_Position = vec4(2.0, 2.0, 2.0, 1.0);
\t}}
}}

#[fragment]
#version 450

layout(location = 0) in vec3 world_normal;
layout(location = 1) in vec3 world_view_direction;
layout(location = 2) in vec3 view_normal;
layout(location = 0) out vec4 output_color;

layout(push_constant, std430) uniform Params {{
\tivec4 view;
\tivec4 viewport;
\tvec4 quantization_min;
\tvec4 quantization_extent;
}} params;

layout(set = 1, binding = 0, std140) uniform ProductionWaterParams {{
\tvec4 deep_color;
\tvec4 edge_color;
\tvec4 response;
}} water_params;

layout(set = 2, binding = 0) uniform sampler2D opaque_scene;

void main() {{
\tfloat signed_facing = dot(
\t\tnormalize(world_normal), normalize(world_view_direction)
\t);
\tfloat facing = abs(signed_facing);
\tfloat fresnel = pow(1.0 - facing, 5.0);
\tvec3 tint = mix(water_params.deep_color.rgb, water_params.edge_color.rgb, fresnel);
\tfloat tint_strength = mix(
\t\twater_params.response.x, water_params.response.y, fresnel
\t);
\tif (signed_facing < 0.0) {{
\t\ttint = water_params.deep_color.rgb;
\t\ttint_strength = max(tint_strength, 0.58);
\t}}
\tvec2 screen_uv = gl_FragCoord.xy / vec2(params.viewport.xy);
\tvec2 offset = view_normal.xy * water_params.response.z * (0.35 + 0.65 * fresnel);
\tvec2 sample_uv = clamp(screen_uv + offset, vec2(0.001), vec2(0.999));
\tvec3 background = textureLod(opaque_scene, sample_uv, 0.0).rgb;
\toutput_color = vec4(mix(background, tint, tint_strength), 1.0);
}}
'''


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = SOURCE.read_text(encoding="utf-8")
    generated = generated_source(source)
    water_source = WATER_SOURCE.read_text(encoding="utf-8")
    generated_water = generated_water_source(water_source)
    if args.check:
        if not TARGET.exists() or TARGET.read_text(encoding="utf-8") != generated:
            raise SystemExit("GPU production material shader is stale")
        if not WATER_TARGET.exists() \
                or WATER_TARGET.read_text(encoding="utf-8") != generated_water:
            raise SystemExit("GPU production water shader is stale")
        print("GPU_PRODUCTION_MATERIAL_SHADER_PASS")
        return 0
    TARGET.write_text(generated, encoding="utf-8", newline="\n")
    WATER_TARGET.write_text(generated_water, encoding="utf-8", newline="\n")
    print(f"generated {TARGET.relative_to(ROOT)}")
    print(f"generated {WATER_TARGET.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

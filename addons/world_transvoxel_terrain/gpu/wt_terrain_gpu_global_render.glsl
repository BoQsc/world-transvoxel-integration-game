#[vertex]
#version 450

#define MAX_VIEWS 2

// Leading fields of Godot 4.7 RenderSceneDataRD::UBO. The bound engine UBO may
// be larger; only these matrix fields are consumed by this proof shader.
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

layout(location = 0) out vec3 normal;
layout(location = 1) flat out int material_id;

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
	vec3 world_position = vertex_position;
	vec2 octahedral = vertex_normal;
	vec3 decoded_normal = vec3(
		octahedral,
		1.0 - abs(octahedral.x) - abs(octahedral.y)
	);
	if (decoded_normal.z < 0.0) {
		decoded_normal.xy = (1.0 - abs(decoded_normal.yx)) *
			sign(decoded_normal.xy);
	}
	gl_Position = projection * view_matrix * vec4(world_position, 1.0);
	if (params.view.z >= 0 && activation_flags.values[params.view.z] == 0u) {
		gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
	}
	normal = normalize(decoded_normal);
	material_id = int(vertex_meta.x);
}

#[fragment]
#version 450

layout(location = 0) in vec3 normal;
layout(location = 1) flat in int material_id;
layout(location = 0) out vec4 output_color;

vec3 material_color(int id) {
	if (id == 2) return vec3(0.46, 0.34, 0.22);
	if (id == 3) return vec3(0.30, 0.66, 0.22);
	if (id == 9) return vec3(0.08, 0.42, 0.72);
	return vec3(0.62, 0.66, 0.70);
}

void main() {
	vec3 unit_normal = normalize(normal);
	float light = 0.28 + 0.72 * abs(dot(
		unit_normal, normalize(vec3(0.35, 0.70, 0.62))
	));
	output_color = vec4(material_color(material_id) * light, 1.0);
}

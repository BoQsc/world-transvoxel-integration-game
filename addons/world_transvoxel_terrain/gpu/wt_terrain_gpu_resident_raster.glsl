#[vertex]
#version 450

layout(location = 0) in vec4 vertex_position;
layout(location = 1) in vec4 vertex_normal;
layout(location = 2) in ivec4 vertex_meta;

layout(push_constant, std430) uniform Params {
	vec4 center_extent;
} params;

layout(location = 0) out vec3 normal;
layout(location = 1) flat out int material_id;

void main() {
	vec3 center = params.center_extent.xyz;
	float extent = params.center_extent.w;
	vec3 relative = (vertex_position.xyz - center) / extent;
	float depth = clamp((center.z + extent - vertex_position.z) / (2.0 * extent), 0.0, 1.0);
	gl_Position = vec4(relative.x, -relative.y, depth, 1.0);
	normal = vertex_normal.xyz;
	material_id = vertex_meta.x;
}

#[fragment]
#version 450

layout(location = 0) in vec3 normal;
layout(location = 1) flat in int material_id;
layout(location = 0) out vec4 output_color;

vec3 material_color(int id) {
	if (id == 2) return vec3(0.46, 0.34, 0.22);
	if (id == 3) return vec3(0.32, 0.58, 0.24);
	if (id == 9) return vec3(0.12, 0.46, 0.68);
	return vec3(0.62, 0.66, 0.70);
}

void main() {
	vec3 unit_normal = normalize(normal);
	float light = 0.30 + 0.70 * abs(dot(unit_normal, normalize(vec3(0.35, 0.70, 0.62))));
	output_color = vec4(material_color(material_id) * light, 1.0);
}

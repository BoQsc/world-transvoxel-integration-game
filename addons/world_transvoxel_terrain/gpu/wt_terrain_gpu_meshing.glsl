#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(push_constant, std430) uniform ArenaOffsets {
	ivec4 input_a;
	ivec4 input_b;
	ivec4 output_a;
	ivec4 output_b;
} arena;

layout(set = 0, binding = 0, std430) readonly buffer FieldValues {
	vec4 values[];
} field_values;
layout(set = 0, binding = 1, std430) readonly buffer FieldMeta {
	ivec4 values[];
} field_meta;
layout(set = 0, binding = 2, std430) readonly buffer CellHeaders {
	ivec4 values[];
} cell_headers;
layout(set = 0, binding = 3, std430) readonly buffer CellOrigins {
	vec4 values[];
} cell_origins;
layout(set = 0, binding = 4, std430) readonly buffer CellOptions {
	vec4 values[];
} cell_options;
layout(set = 0, binding = 5, std430) readonly buffer SampleReferences {
	int values[];
} sample_references;
layout(set = 0, binding = 6, std430) readonly buffer Config {
	ivec4 values[];
} config;
layout(set = 0, binding = 7, std430) readonly buffer RegularCellClass {
	int values[];
} regular_cell_class;
layout(set = 0, binding = 8, std430) readonly buffer RegularCellData {
	int values[];
} regular_cell_data;
layout(set = 0, binding = 9, std430) readonly buffer RegularVertexData {
	int values[];
} regular_vertex_data;
layout(set = 0, binding = 10, std430) readonly buffer TransitionCellClass {
	int values[];
} transition_cell_class;
layout(set = 0, binding = 11, std430) readonly buffer TransitionCellData {
	int values[];
} transition_cell_data;
layout(set = 0, binding = 12, std430) readonly buffer TransitionVertexData {
	int values[];
} transition_vertex_data;

layout(set = 0, binding = 13, std430) buffer OutputPositions {
	vec4 values[];
} output_positions;
layout(set = 0, binding = 14, std430) writeonly buffer OutputNormals {
	vec4 values[];
} output_normals;
layout(set = 0, binding = 15, std430) writeonly buffer OutputVertexMeta {
	ivec4 values[];
} output_vertex_meta;
layout(set = 0, binding = 16, std430) writeonly buffer OutputReuse {
	ivec4 values[];
} output_reuse;
layout(set = 0, binding = 17, std430) writeonly buffer OutputIndices {
	int values[];
} output_indices;
layout(set = 0, binding = 18, std430) writeonly buffer OutputCellMeta {
	ivec4 values[];
} output_cell_meta;
layout(set = 0, binding = 19, std430) writeonly buffer OutputIdentity {
	ivec4 values[];
} output_identity;

struct DrawIndexedIndirectCommand {
	uint index_count;
	uint instance_count;
	uint first_index;
	int vertex_offset;
	uint first_instance;
};
layout(set = 0, binding = 20, std430) buffer OutputDrawCommands {
	DrawIndexedIndirectCommand values[];
} output_draw_commands;

const int CELL_REGULAR = 0;
const int CELL_TRANSITION = 1;
const int STATUS_EMPTY = 0;
const int STATUS_OK = 1;
const int STATUS_FAILURE = 2;
const int MAX_VERTICES = 12;
const int MAX_INDICES = 36;
const int PAGE_DIMENSION = 19;
const int PAGE_SAMPLE_COUNT = 6859;
const float NO_STATIC_WATER_DENSITY = 3.0e38;
const int STATIC_WATER_MATERIAL = 9;

vec3 normalized_or_zero(vec3 value) {
	float squared_length = dot(value, value);
	return squared_length > 0.0 ? value * inversesqrt(squared_length) : vec3(0.0);
}

float regularized_alpha(float density_a, float density_b, float isovalue) {
	float denominator = density_b - density_a;
	if (denominator == 0.0) {
		return -1.0;
	}
	return clamp((isovalue - density_a) / denominator, 1.0 / 32.0, 31.0 / 32.0);
}

void transition_basis(int orientation, out vec3 axis_u, out vec3 axis_v, out vec3 axis_w) {
	if (orientation == 0) {
		axis_u = vec3(0.0, 1.0, 0.0);
		axis_v = vec3(0.0, 0.0, 1.0);
		axis_w = vec3(1.0, 0.0, 0.0);
	} else if (orientation == 1) {
		axis_u = vec3(0.0, 1.0, 0.0);
		axis_v = vec3(0.0, 0.0, -1.0);
		axis_w = vec3(-1.0, 0.0, 0.0);
	} else if (orientation == 2) {
		axis_u = vec3(0.0, 0.0, 1.0);
		axis_v = vec3(1.0, 0.0, 0.0);
		axis_w = vec3(0.0, 1.0, 0.0);
	} else if (orientation == 3) {
		axis_u = vec3(0.0, 0.0, 1.0);
		axis_v = vec3(-1.0, 0.0, 0.0);
		axis_w = vec3(0.0, -1.0, 0.0);
	} else if (orientation == 4) {
		axis_u = vec3(1.0, 0.0, 0.0);
		axis_v = vec3(0.0, 1.0, 0.0);
		axis_w = vec3(0.0, 0.0, 1.0);
	} else {
		axis_u = vec3(1.0, 0.0, 0.0);
		axis_v = vec3(0.0, -1.0, 0.0);
		axis_w = vec3(0.0, 0.0, -1.0);
	}
}

void transition_basis_i(int orientation, out ivec3 axis_u, out ivec3 axis_v, out ivec3 axis_w) {
	vec3 u;
	vec3 v;
	vec3 w;
	transition_basis(orientation, u, v, w);
	axis_u = ivec3(u);
	axis_v = ivec3(v);
	axis_w = ivec3(w);
}

bool page_source_sample(ivec3 point, out vec2 densities, out ivec2 material) {
	int config_base = arena.input_b.z;
	int page_count = config.values[config_base].z;
	int selected_spacing = 0x7fffffff;
	bool found = false;
	for (int page_index = 0; page_index < page_count; ++page_index) {
		vec4 page_origin = cell_origins.values[arena.input_a.w + page_index];
		vec4 page_options = cell_options.values[arena.input_b.x + page_index];
		int spacing = int(round(page_origin.w));
		ivec3 difference = point - ivec3(round(page_origin.xyz));
		if (spacing <= 0 || any(notEqual(difference % spacing, ivec3(0)))) {
			continue;
		}
		ivec3 coordinate = difference / spacing;
		int sample_minimum = int(round(page_options.z));
		int sample_maximum = int(round(page_options.w));
		if (any(lessThan(coordinate, ivec3(sample_minimum))) ||
				any(greaterThan(coordinate, ivec3(sample_maximum))) ||
				spacing >= selected_spacing) {
			continue;
		}
		ivec3 local = coordinate - ivec3(sample_minimum);
		int sample_index = int(round(page_options.x)) +
			(local.z * PAGE_DIMENSION + local.y) * PAGE_DIMENSION + local.x;
		vec4 packed_density = field_values.values[arena.input_a.x + sample_index];
		ivec4 packed_material = field_meta.values[arena.input_a.y + sample_index];
		densities = packed_density.xy;
		material = packed_material.xy;
		selected_spacing = spacing;
		found = true;
	}
	return found;
}

bool water_occupied(vec2 densities, ivec2 material) {
	return material.x == STATIC_WATER_MATERIAL && densities.x >= 0.0;
}

float suppressed_water_density(float terrain_density) {
	return -clamp(abs(terrain_density), 0.01, 1.0);
}

bool water_field_sample(ivec3 point, out float density, out ivec2 material) {
	vec2 source_density;
	ivec2 source_material;
	if (!page_source_sample(point, source_density, source_material)) {
		return false;
	}
	material = ivec2(
		STATIC_WATER_MATERIAL,
		source_material.y != 0 && source_material.x == STATIC_WATER_MATERIAL ? 1 : 0
	);
	if (source_density.y < NO_STATIC_WATER_DENSITY) {
		density = source_density.y;
		return true;
	}
	if (water_occupied(source_density, source_material)) {
		for (int step = 1; step <= 256; step *= 2) {
			vec2 first_density;
			ivec2 first_material;
			if (!page_source_sample(
					point + ivec3(0, step, 0), first_density, first_material)) {
				continue;
			}
			for (int offset = step; offset <= 256; offset += step) {
				vec2 above_density;
				ivec2 above_material;
				if (!page_source_sample(
						point + ivec3(0, offset, 0), above_density, above_material)) {
					break;
				}
				if (water_occupied(above_density, above_material)) continue;
				density = above_density.x >= 0.0 ?
					-float(offset) + 0.5 * float(step) :
					suppressed_water_density(source_density.x);
				return true;
			}
			density = suppressed_water_density(source_density.x);
			return true;
		}
		density = suppressed_water_density(source_density.x);
		return true;
	}
	if (source_density.x < 0.0) {
		density = suppressed_water_density(source_density.x);
		return true;
	}
	for (int step = 1; step <= 256; step *= 2) {
		vec2 first_density;
		ivec2 first_material;
		if (!page_source_sample(
				point - ivec3(0, step, 0), first_density, first_material)) {
			continue;
		}
		for (int offset = step; offset <= 256; offset += step) {
			vec2 below_density;
			ivec2 below_material;
			if (!page_source_sample(
					point - ivec3(0, offset, 0), below_density, below_material)) {
				break;
			}
			if (water_occupied(below_density, below_material)) {
				density = float(offset) - 0.5 * float(step);
				return true;
			}
			if (below_density.x < 0.0) break;
		}
		density = suppressed_water_density(source_density.x);
		return true;
	}
	density = suppressed_water_density(source_density.x);
	return true;
}

bool field_scalar(ivec3 point, int surface_mode, out float density, out ivec2 material) {
	if (surface_mode == 1) return water_field_sample(point, density, material);
	vec2 source_density;
	if (!page_source_sample(point, source_density, material)) return false;
	density = source_density.x;
	return true;
}

bool page_cell_sample(
	ivec3 point,
	int gradient_step,
	int surface_mode,
	out vec4 field_sample,
	out ivec2 material
) {
	float center;
	float negative_x;
	float positive_x;
	float negative_y;
	float positive_y;
	float negative_z;
	float positive_z;
	ivec2 ignored;
	if (!field_scalar(point, surface_mode, center, material) ||
			!field_scalar(point - ivec3(gradient_step, 0, 0), surface_mode, negative_x, ignored) ||
			!field_scalar(point + ivec3(gradient_step, 0, 0), surface_mode, positive_x, ignored) ||
			!field_scalar(point - ivec3(0, gradient_step, 0), surface_mode, negative_y, ignored) ||
			!field_scalar(point + ivec3(0, gradient_step, 0), surface_mode, positive_y, ignored) ||
			!field_scalar(point - ivec3(0, 0, gradient_step), surface_mode, negative_z, ignored) ||
			!field_scalar(point + ivec3(0, 0, gradient_step), surface_mode, positive_z, ignored)) {
		return false;
	}
	field_sample = vec4(center, 0.5 * vec3(
		positive_x - negative_x,
		positive_y - negative_y,
		positive_z - negative_z
	));
	return true;
}

int transition_face_for_cell(int transition_index, int transition_mask, out int face_cell) {
	int remaining = transition_index;
	for (int face = 0; face < 6; ++face) {
		if ((transition_mask & (1 << face)) == 0) continue;
		if (remaining < 256) {
			face_cell = remaining;
			return face;
		}
		remaining -= 256;
	}
	face_cell = 0;
	return -1;
}

ivec3 transition_face_origin(int face, ivec3 axis_u, ivec3 axis_v, int extent) {
	ivec3 origin = ivec3(0);
	if (face == 1) origin.x = extent;
	if (face == 3) origin.y = extent;
	if (face == 5) origin.z = extent;
	if (axis_u.x < 0 || axis_v.x < 0) origin.x = extent;
	if (axis_u.y < 0 || axis_v.y < 0) origin.y = extent;
	if (axis_u.z < 0 || axis_v.z < 0) origin.z = extent;
	return origin;
}

void main() {
	uint cell_index_u = gl_GlobalInvocationID.x;
	int config_base = arena.input_b.z;
	int cell_count = config.values[config_base].x;
	if (cell_index_u >= uint(cell_count)) {
		return;
	}
	int cell_index = int(cell_index_u);
	bool compact_surface = arena.output_b.y != 0;
	int local_vertex_base = cell_index * MAX_VERTICES;
	int local_index_base = cell_index * MAX_INDICES;
	int vertex_base = arena.output_a.x + local_vertex_base;
	int index_base = arena.output_a.y + local_index_base;
	int cell_meta_index = arena.output_a.z + cell_index;
	int draw_index = arena.output_b.x + (compact_surface ? 0 : cell_index);
	if (!compact_surface) {
		output_draw_commands.values[draw_index] = DrawIndexedIndirectCommand(
			0u, 0u, uint(local_index_base), local_vertex_base, 0u
		);
	}
	for (int index = 0; index < MAX_VERTICES; ++index) {
		output_positions.values[vertex_base + index] = vec4(0.0);
		output_normals.values[vertex_base + index] = vec4(0.0);
		output_vertex_meta.values[vertex_base + index] = ivec4(0);
		output_reuse.values[vertex_base + index] = ivec4(0, cell_index, index, 1);
	}
	if (!compact_surface) {
		for (int index = 0; index < MAX_INDICES; ++index) {
			output_indices.values[index_base + index] = -1;
		}
	}
	if (cell_index == 0) {
		output_identity.values[arena.output_a.w] = config.values[config_base + 1];
		output_identity.values[arena.output_a.w + 1] = config.values[config_base + 2];
		output_identity.values[arena.output_a.w + 2] = config.values[config_base + 3];
	}

	bool page_field_mode = config.values[config_base].w == 1;
	ivec4 header = ivec4(0, 0, 0, 8);
	vec4 origin_and_spacing = vec4(0.0);
	vec4 options = vec4(0.0, 0.0, 0.0, 0.0);
	int cell_type = CELL_REGULAR;
	int orientation = 0;
	int reference_offset = 0;
	int input_sample_count = 8;
	ivec3 chunk_origin = ivec3(0);
	ivec3 page_axis_u = ivec3(0);
	ivec3 page_axis_v = ivec3(0);
	if (page_field_mode) {
		ivec4 chunk_identity = config.values[config_base + 1];
		int coarse_spacing = 1 << chunk_identity.w;
		int extent = 16 * coarse_spacing;
		chunk_origin = chunk_identity.xyz * extent;
		if (cell_index < 4096) {
			ivec3 cell_coordinate = ivec3(
				cell_index % 16,
				(cell_index / 16) % 16,
				cell_index / 256
			);
			origin_and_spacing = vec4(
				vec3(chunk_origin + cell_coordinate * coarse_spacing),
				float(coarse_spacing)
			);
		} else {
			int face_cell = 0;
			int transition_mask = config.values[config_base + 3].w;
			int face = transition_face_for_cell(
				cell_index - 4096, transition_mask, face_cell
			);
			if (face < 0 || coarse_spacing < 2) {
				output_cell_meta.values[cell_meta_index] = ivec4(STATUS_FAILURE, 0, 0, 0);
				return;
			}
			cell_type = CELL_TRANSITION;
			orientation = face;
			input_sample_count = 9;
			ivec3 axis_w;
			transition_basis_i(orientation, page_axis_u, page_axis_v, axis_w);
			ivec3 local_origin = transition_face_origin(
				face, page_axis_u, page_axis_v, extent
			) + page_axis_u * ((face_cell % 16) * coarse_spacing) +
				page_axis_v * ((face_cell / 16) * coarse_spacing);
			origin_and_spacing = vec4(
				vec3(chunk_origin + local_origin),
				float(coarse_spacing / 2)
			);
			options.x = float(coarse_spacing) * 0.25;
		}
	} else {
		header = cell_headers.values[arena.input_a.z + cell_index];
		origin_and_spacing = cell_origins.values[arena.input_a.w + cell_index];
		options = cell_options.values[arena.input_b.x + cell_index];
		cell_type = header.x;
		orientation = header.y;
		reference_offset = header.z;
		input_sample_count = header.w;
	}
	float spacing = origin_and_spacing.w;
	float transition_width = options.x;
	float isovalue = options.y;
	if ((cell_type != CELL_REGULAR && cell_type != CELL_TRANSITION) ||
		(cell_type == CELL_REGULAR && input_sample_count != 8) ||
		(cell_type == CELL_TRANSITION && input_sample_count != 9) ||
		spacing <= 0.0 ||
		(cell_type == CELL_TRANSITION && (transition_width <= 0.0 || orientation < 0 || orientation > 5))) {
		output_cell_meta.values[cell_meta_index] = ivec4(STATUS_FAILURE, 0, 0, 0);
		return;
	}

	vec4 samples[13];
	ivec2 materials[13];
	vec3 positions[13];
	for (int index = 0; index < input_sample_count; ++index) {
		if (page_field_mode) {
			ivec3 sample_point;
			if (cell_type == CELL_REGULAR) {
				sample_point = ivec3(round(origin_and_spacing.xyz)) + ivec3(
					(index & 1) != 0 ? int(round(spacing)) : 0,
					(index & 2) != 0 ? int(round(spacing)) : 0,
					(index & 4) != 0 ? int(round(spacing)) : 0
				);
			} else {
				sample_point = ivec3(round(origin_and_spacing.xyz)) +
					page_axis_u * ((index % 3) * int(round(spacing))) +
					page_axis_v * ((index / 3) * int(round(spacing)));
			}
			if (!page_cell_sample(
					sample_point,
					int(round(spacing)),
					config.values[config_base + 3].z,
					samples[index],
					materials[index]
				)) {
				output_cell_meta.values[cell_meta_index] = ivec4(STATUS_FAILURE, 0, 0, 0);
				return;
			}
		} else {
			int source_index = sample_references.values[
				arena.input_b.y + reference_offset + index
			];
			samples[index] = field_values.values[arena.input_a.x + source_index];
			materials[index] = field_meta.values[arena.input_a.y + source_index].xy;
		}
	}

	int case_code = 0;
	int class_code = 0;
	int geometry_counts = 0;
	int class_data_offset = 0;
	int vertex_data_offset = 0;
	bool reverse_winding = false;
	if (cell_type == CELL_REGULAR) {
		for (int index = 0; index < 8; ++index) {
			positions[index] = origin_and_spacing.xyz + vec3(
				(index & 1) != 0 ? spacing : 0.0,
				(index & 2) != 0 ? spacing : 0.0,
				(index & 4) != 0 ? spacing : 0.0
			);
			if (samples[index].x < isovalue) {
				case_code |= 1 << index;
			}
		}
		if (case_code == 0 || case_code == 255) {
			output_cell_meta.values[cell_meta_index] = ivec4(STATUS_EMPTY, case_code, 0, 0);
			return;
		}
		class_code = regular_cell_class.values[case_code];
		class_data_offset = class_code * 16;
		geometry_counts = regular_cell_data.values[class_data_offset];
		vertex_data_offset = case_code * 12;
	} else {
		vec3 axis_u;
		vec3 axis_v;
		vec3 axis_w;
		transition_basis(orientation, axis_u, axis_v, axis_w);
		for (int index = 0; index < 9; ++index) {
			float u = float(index % 3);
			float v = float(index / 3);
			positions[index] = origin_and_spacing.xyz +
				axis_u * (u * spacing) + axis_v * (v * spacing);
		}
		const int aliases[4] = int[4](0, 2, 6, 8);
		for (int alias_index = 0; alias_index < 4; ++alias_index) {
			int source_index = aliases[alias_index];
			int topology_index = 9 + alias_index;
			samples[topology_index] = samples[source_index];
			materials[topology_index] = materials[source_index];
			positions[topology_index] = positions[source_index] + axis_w * transition_width;
			if (page_field_mode) {
				ivec3 sample_point = ivec3(round(positions[source_index]));
				if (!page_cell_sample(
						sample_point,
						int(round(spacing * 2.0)),
						config.values[config_base + 3].z,
						samples[topology_index],
						materials[topology_index]
					)) {
					output_cell_meta.values[cell_meta_index] = ivec4(STATUS_FAILURE, 0, 0, 0);
					return;
				}
			}
		}
		const int case_samples[9] = int[9](0, 1, 2, 5, 8, 7, 6, 3, 4);
		for (int bit = 0; bit < 9; ++bit) {
			if (samples[case_samples[bit]].x < isovalue) {
				case_code |= 1 << bit;
			}
		}
		if (case_code == 0 || case_code == 511) {
			output_cell_meta.values[cell_meta_index] = ivec4(STATUS_EMPTY, case_code, 0, 0);
			return;
		}
		class_code = transition_cell_class.values[case_code];
		reverse_winding = (class_code & 0x80) != 0;
		class_code &= 0x7f;
		if (class_code >= 56) {
			output_cell_meta.values[cell_meta_index] = ivec4(STATUS_FAILURE, case_code, 0, 0);
			return;
		}
		class_data_offset = class_code * 37;
		geometry_counts = transition_cell_data.values[class_data_offset];
		vertex_data_offset = case_code * 12;
	}

	int vertex_count = geometry_counts >> 4;
	int source_index_count = (geometry_counts & 0x0f) * 3;
	if (vertex_count > MAX_VERTICES || source_index_count > MAX_INDICES) {
		output_cell_meta.values[cell_meta_index] = ivec4(STATUS_FAILURE, case_code, 0, 0);
		return;
	}
	for (int vertex_index = 0; vertex_index < vertex_count; ++vertex_index) {
		int edge_code = cell_type == CELL_REGULAR
			? regular_vertex_data.values[vertex_data_offset + vertex_index]
			: transition_vertex_data.values[vertex_data_offset + vertex_index];
		int endpoint_a = (edge_code >> 4) & 0x0f;
		int endpoint_b = edge_code & 0x0f;
		int topology_count = cell_type == CELL_REGULAR ? 8 : 13;
		if (endpoint_a >= topology_count || endpoint_b >= topology_count) {
			output_cell_meta.values[cell_meta_index] = ivec4(STATUS_FAILURE, case_code, 0, 0);
			return;
		}
		float alpha = regularized_alpha(samples[endpoint_a].x, samples[endpoint_b].x, isovalue);
		if (alpha < 0.0) {
			output_cell_meta.values[cell_meta_index] = ivec4(STATUS_FAILURE, case_code, 0, 0);
			return;
		}
		vec3 position = mix(positions[endpoint_a], positions[endpoint_b], alpha);
		vec3 normal = normalized_or_zero(mix(samples[endpoint_a].yzw, samples[endpoint_b].yzw, alpha));
		int solid_endpoint = samples[endpoint_a].x < isovalue ? endpoint_a : endpoint_b;
		int output_index = vertex_base + vertex_index;
		output_positions.values[output_index] = vec4(position, 1.0);
		output_normals.values[output_index] = vec4(normal, 0.0);
		output_vertex_meta.values[output_index] = ivec4(
			materials[solid_endpoint].x,
			materials[solid_endpoint].y,
			endpoint_a,
			endpoint_b
		);
		output_reuse.values[output_index].x = (edge_code >> 8) & 0xff;
	}

	int emitted_indices[MAX_INDICES];
	int output_index_count = 0;
	for (int triangle = 0; triangle < source_index_count; triangle += 3) {
		int first = cell_type == CELL_REGULAR
			? regular_cell_data.values[class_data_offset + triangle + 1]
			: transition_cell_data.values[class_data_offset + triangle + 1];
		int second = cell_type == CELL_REGULAR
			? regular_cell_data.values[class_data_offset + triangle + 2]
			: transition_cell_data.values[class_data_offset + triangle + 2];
		int third = cell_type == CELL_REGULAR
			? regular_cell_data.values[class_data_offset + triangle + 3]
			: transition_cell_data.values[class_data_offset + triangle + 3];
		if (reverse_winding) {
			int swap = first;
			first = third;
			third = swap;
		}
		vec3 p0 = output_positions.values[vertex_base + first].xyz;
		vec3 p1 = output_positions.values[vertex_base + second].xyz;
		vec3 p2 = output_positions.values[vertex_base + third].xyz;
		vec3 edge_a = p1 - p0;
		vec3 edge_b = p2 - p0;
		vec3 edge_c = p2 - p1;
		if (dot(edge_a, edge_a) == 0.0 || dot(edge_b, edge_b) == 0.0 ||
			dot(edge_c, edge_c) == 0.0 || dot(cross(edge_a, edge_b), cross(edge_a, edge_b)) == 0.0) {
			continue;
		}
		emitted_indices[output_index_count] = first;
		emitted_indices[output_index_count + 1] = second;
		emitted_indices[output_index_count + 2] = third;
		output_index_count += 3;
	}
	if (output_index_count == 0) {
		output_cell_meta.values[cell_meta_index] = ivec4(STATUS_EMPTY, case_code, 0, 0);
		return;
	}
	output_cell_meta.values[cell_meta_index] = ivec4(
		STATUS_OK, case_code, vertex_count, output_index_count
	);
	if (compact_surface) {
		uint compact_base = atomicAdd(
			output_draw_commands.values[draw_index].index_count,
			uint(output_index_count)
		);
		for (int index = 0; index < output_index_count; ++index) {
			output_indices.values[
				arena.output_a.y + int(compact_base) + index
			] = local_vertex_base + emitted_indices[index];
		}
	} else {
		for (int index = 0; index < output_index_count; ++index) {
			output_indices.values[index_base + index] = emitted_indices[index];
		}
		output_draw_commands.values[draw_index] = DrawIndexedIndirectCommand(
			uint(output_index_count), 1u, uint(local_index_base), local_vertex_base, 0u
		);
	}
}

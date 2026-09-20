#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(push_constant, std430) uniform ArenaOffsets {
	ivec4 input_a;
	ivec4 input_b;
	ivec4 output_a;
	ivec4 output_b;
	ivec4 compact_output;
	ivec4 resident_status;
	vec4 quantization_min;
	vec4 quantization_extent;
} arena;

layout(set = 0, binding = 0, std430) readonly buffer FieldValues {
	float values[];
} field_values;
layout(set = 0, binding = 1, std430) readonly buffer FieldMeta {
	int values[];
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
	uint values[];
} output_positions;
layout(set = 0, binding = 14, std430) writeonly buffer OutputNormals {
	uint values[];
} output_normals;
layout(set = 0, binding = 15, std430) writeonly buffer OutputVertexMeta {
	uint values[];
} output_vertex_meta;
layout(set = 0, binding = 16, std430) writeonly buffer OutputReuse {
	uint values[];
} output_reuse;
layout(set = 0, binding = 17, std430) writeonly buffer OutputIndices {
	int values[];
} output_indices;
layout(set = 0, binding = 18, std430) writeonly buffer OutputCellMeta {
	uint values[];
} output_cell_meta;
layout(set = 0, binding = 19, std430) writeonly buffer OutputIdentity {
	uint values[];
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
layout(set = 0, binding = 21, std430) buffer ResidentStatus {
	uint values[];
} resident_status;

const int CELL_REGULAR = 0;
const int CELL_TRANSITION = 1;
const int STATUS_EMPTY = 0;
const int STATUS_OK = 1;
const int STATUS_FAILURE = 2;
const int MAX_VERTICES = 12;
const int MAX_INDICES = 36;
const int PAGE_DIMENSION = 19;
const int PAGE_SAMPLE_COUNT = 6859;
const int CHUNK_CELLS = 16;
const int AXIS_EDGE_COUNT = CHUNK_CELLS * (CHUNK_CELLS + 1) * (CHUNK_CELLS + 1);
const int CHUNK_EDGE_COUNT = 3 * AXIS_EDGE_COUNT;
const float POSITION_SNAP_SCALE = 65536.0;
const float NO_STATIC_WATER_DENSITY = 3.0e38;
const int STATIC_WATER_MATERIAL = 9;
const int REGULAR_BRICK_CELLS = 512;
const int TRANSITION_BRICK_CELLS = 64;

int meshlet_for_cell(int cell_index) {
	if (cell_index < 4096) {
		int x = cell_index % 16;
		int y = (cell_index / 16) % 16;
		int z = cell_index / 256;
		return (x / 8) + (y / 8) * 2 + (z / 8) * 4;
	}
	int remaining = cell_index - 4096;
	int transition_mask = config.values[arena.input_b.z + 3].w;
	int face_ordinal = 0;
	for (int face = 0; face < 6; ++face) {
		if ((transition_mask & (1 << face)) == 0) continue;
		if (remaining < 256) {
			int u = remaining % 16;
			int v = remaining / 16;
			return 8 + face_ordinal * 4 + (u / 8) + (v / 8) * 2;
		}
		remaining -= 256;
		++face_ordinal;
	}
	return 31;
}

int meshlet_vertex_base(int meshlet) {
	return meshlet < 8
		? meshlet * REGULAR_BRICK_CELLS * MAX_VERTICES
		: 8 * REGULAR_BRICK_CELLS * MAX_VERTICES +
			(meshlet - 8) * TRANSITION_BRICK_CELLS * MAX_VERTICES;
}

int meshlet_index_base(int meshlet) {
	return meshlet < 8
		? meshlet * REGULAR_BRICK_CELLS * MAX_INDICES
		: 8 * REGULAR_BRICK_CELLS * MAX_INDICES +
			(meshlet - 8) * TRANSITION_BRICK_CELLS * MAX_INDICES;
}

vec4 field_sample_at(int sample_index, bool page_field_mode) {
	int base = arena.input_a.x;
	if (!page_field_mode) {
		base += sample_index * 4;
		return vec4(
			field_values.values[base],
			field_values.values[base + 1],
			field_values.values[base + 2],
			field_values.values[base + 3]
		);
	}
	int page_sample_count = config.values[arena.input_b.z].z * PAGE_SAMPLE_COUNT;
	if (sample_index < page_sample_count) {
		base += sample_index * 2;
		return vec4(
			field_values.values[base], field_values.values[base + 1], 0.0, 0.0
		);
	}
	base += page_sample_count * 2 + (sample_index - page_sample_count) * 4;
	return vec4(
		field_values.values[base],
		field_values.values[base + 1],
		field_values.values[base + 2],
		field_values.values[base + 3]
	);
}

ivec2 field_material_at(int sample_index, bool page_field_mode) {
	int stride = page_field_mode ? 2 : 4;
	int base = arena.input_a.y + sample_index * stride;
	return ivec2(field_meta.values[base], field_meta.values[base + 1]);
}

vec3 normalized_or_zero(vec3 value) {
	float squared_length = dot(value, value);
	return squared_length > 0.0 ? value * inversesqrt(squared_length) : vec3(0.0);
}

vec2 octahedral_normal(vec3 normal) {
	vec3 unit_normal = normalized_or_zero(normal);
	unit_normal /= max(
		abs(unit_normal.x) + abs(unit_normal.y) + abs(unit_normal.z), 1.0e-8
	);
	vec2 encoded = unit_normal.xy;
	if (unit_normal.z < 0.0) {
		encoded = (1.0 - abs(encoded.yx)) * sign(encoded.xy);
	}
	return clamp(encoded, vec2(-1.0), vec2(1.0));
}

void store_legacy_position(int index, vec4 value) {
	int base = index * 4;
	output_positions.values[base] = floatBitsToUint(value.x);
	output_positions.values[base + 1] = floatBitsToUint(value.y);
	output_positions.values[base + 2] = floatBitsToUint(value.z);
	output_positions.values[base + 3] = floatBitsToUint(value.w);
}

void store_legacy_normal(int index, vec4 value) {
	int base = index * 4;
	output_normals.values[base] = floatBitsToUint(value.x);
	output_normals.values[base + 1] = floatBitsToUint(value.y);
	output_normals.values[base + 2] = floatBitsToUint(value.z);
	output_normals.values[base + 3] = floatBitsToUint(value.w);
}

void store_legacy_vertex_meta(int index, ivec4 value) {
	int base = index * 4;
	output_vertex_meta.values[base] = uint(value.x);
	output_vertex_meta.values[base + 1] = uint(value.y);
	output_vertex_meta.values[base + 2] = uint(value.z);
	output_vertex_meta.values[base + 3] = uint(value.w);
}

void store_legacy_reuse(int index, ivec4 value) {
	int base = index * 4;
	output_reuse.values[base] = uint(value.x);
	output_reuse.values[base + 1] = uint(value.y);
	output_reuse.values[base + 2] = uint(value.z);
	output_reuse.values[base + 3] = uint(value.w);
}

void store_legacy_identity(int index, ivec4 value) {
	int base = index * 4;
	output_identity.values[base] = uint(value.x);
	output_identity.values[base + 1] = uint(value.y);
	output_identity.values[base + 2] = uint(value.z);
	output_identity.values[base + 3] = uint(value.w);
}

void store_cell_meta(bool compact_surface, int index, ivec4 value) {
	if (compact_surface) {
		if (value.x == STATUS_FAILURE) {
			int cell_index = index - arena.output_a.z;
			int meshlet = meshlet_for_cell(cell_index);
			atomicAdd(
				resident_status.values[arena.resident_status.x + meshlet * 4 + 2], 1u
			);
		}
	} else {
		int base = index * 4;
		output_cell_meta.values[base] = uint(value.x);
		output_cell_meta.values[base + 1] = uint(value.y);
		output_cell_meta.values[base + 2] = uint(value.z);
		output_cell_meta.values[base + 3] = uint(value.w);
	}
}

float regularized_alpha(float density_a, float density_b, float isovalue) {
	float denominator = density_b - density_a;
	if (denominator == 0.0) {
		return -1.0;
	}
	return clamp((isovalue - density_a) / denominator, 1.0 / 32.0, 31.0 / 32.0);
}

vec3 interpolate_edge_position(vec3 endpoint_a, vec3 endpoint_b, float alpha) {
	vec3 position = endpoint_a;
	if (endpoint_a.x != endpoint_b.x) {
		position.x = endpoint_a.x + (endpoint_b.x - endpoint_a.x) * alpha;
	}
	if (endpoint_a.y != endpoint_b.y) {
		position.y = endpoint_a.y + (endpoint_b.y - endpoint_a.y) * alpha;
	}
	if (endpoint_a.z != endpoint_b.z) {
		position.z = endpoint_a.z + (endpoint_b.z - endpoint_a.z) * alpha;
	}
	return position;
}

vec3 snap_position(vec3 position) {
	return round(position * POSITION_SNAP_SCALE) / POSITION_SNAP_SCALE;
}

bool position_precedes(vec3 a, vec3 b) {
	if (a.x != b.x) return a.x < b.x;
	if (a.y != b.y) return a.y < b.y;
	return a.z < b.z;
}

void face_distance_and_inward(
	vec3 position,
	int face,
	float extent,
	out float distance,
	out vec3 inward
) {
	if (face == 0) {
		distance = position.x;
		inward = vec3(1.0, 0.0, 0.0);
	} else if (face == 1) {
		distance = extent - position.x;
		inward = vec3(-1.0, 0.0, 0.0);
	} else if (face == 2) {
		distance = position.y;
		inward = vec3(0.0, 1.0, 0.0);
	} else if (face == 3) {
		distance = extent - position.y;
		inward = vec3(0.0, -1.0, 0.0);
	} else if (face == 4) {
		distance = position.z;
		inward = vec3(0.0, 0.0, 1.0);
	} else {
		distance = extent - position.z;
		inward = vec3(0.0, 0.0, -1.0);
	}
}

vec3 deform_chunk_position(
	vec3 position,
	vec3 normal,
	int transition_mask,
	float cell_size,
	float width,
	float extent,
	int primary_transition_face
) {
	vec3 primary = position;
	float transition_factor = 1.0;
	if (primary_transition_face >= 0) {
		float primary_distance;
		vec3 primary_inward;
		face_distance_and_inward(
			position,
			primary_transition_face,
			extent,
			primary_distance,
			primary_inward
		);
		transition_factor = clamp(primary_distance / width, 0.0, 1.0);
		primary = position - primary_inward * primary_distance;
	}

	int near_face_mask = 0;
	if (primary.x < cell_size) near_face_mask |= 1 << 0;
	if (primary.x > extent - cell_size) near_face_mask |= 1 << 1;
	if (primary.y < cell_size) near_face_mask |= 1 << 2;
	if (primary.y > extent - cell_size) near_face_mask |= 1 << 3;
	if (primary.z < cell_size) near_face_mask |= 1 << 4;
	if (primary.z > extent - cell_size) near_face_mask |= 1 << 5;

	int vertex_border_mask = 0;
	if (primary.x == 0.0) vertex_border_mask |= 1 << 0;
	if (primary.x == extent) vertex_border_mask |= 1 << 1;
	if (primary.y == 0.0) vertex_border_mask |= 1 << 2;
	if (primary.y == extent) vertex_border_mask |= 1 << 3;
	if (primary.z == 0.0) vertex_border_mask |= 1 << 4;
	if (primary.z == extent) vertex_border_mask |= 1 << 5;

	bool has_active_transition = (near_face_mask & transition_mask) != 0;
	bool touches_same_lod_face = (vertex_border_mask & ~transition_mask) != 0;
	if (!has_active_transition || touches_same_lod_face) {
		return primary;
	}

	vec3 offset = vec3(0.0);
	if (primary.x < cell_size) {
		offset.x = width * (1.0 - primary.x / cell_size);
	} else if (primary.x > extent - cell_size) {
		offset.x = -width * (1.0 - (extent - primary.x) / cell_size);
	}
	if (primary.y < cell_size) {
		offset.y = width * (1.0 - primary.y / cell_size);
	} else if (primary.y > extent - cell_size) {
		offset.y = -width * (1.0 - (extent - primary.y) / cell_size);
	}
	if (primary.z < cell_size) {
		offset.z = width * (1.0 - primary.z / cell_size);
	} else if (primary.z > extent - cell_size) {
		offset.z = -width * (1.0 - (extent - primary.z) / cell_size);
	}
	float normal_offset = dot(normal, offset);
	vec3 projected = offset - normal * normal_offset;
	return primary + transition_factor * projected;
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
		densities = field_sample_at(sample_index, true).xy;
		material = field_material_at(sample_index, true);
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

bool page_edge_index(
	int page_index,
	ivec3 endpoint_a,
	ivec3 endpoint_b,
	out int edge_index,
	out bool reversed
) {
	edge_index = 0;
	reversed = false;
	vec4 page_origin = cell_origins.values[arena.input_a.w + page_index];
	int spacing = int(round(page_origin.w));
	if (spacing <= 0) return false;
	ivec3 difference = endpoint_b - endpoint_a;
	int axis = -1;
	for (int candidate = 0; candidate < 3; ++candidate) {
		if (difference[candidate] == 0) continue;
		if (axis >= 0 || abs(difference[candidate]) != spacing) return false;
		axis = candidate;
	}
	if (axis < 0) return false;
	reversed = difference[axis] < 0;
	ivec3 start = reversed ? endpoint_b : endpoint_a;
	ivec3 relative = start - ivec3(round(page_origin.xyz));
	if (any(notEqual(relative % spacing, ivec3(0)))) return false;
	ivec3 coordinate = relative / spacing;
	if (any(lessThan(coordinate, ivec3(0))) ||
			any(greaterThan(coordinate, ivec3(CHUNK_CELLS))) ||
			coordinate[axis] >= CHUNK_CELLS) {
		return false;
	}
	int local = 0;
	if (axis == 0) {
		local = (coordinate.z * (CHUNK_CELLS + 1) + coordinate.y) *
			CHUNK_CELLS + coordinate.x;
	} else if (axis == 1) {
		local = (coordinate.z * CHUNK_CELLS + coordinate.y) *
			(CHUNK_CELLS + 1) + coordinate.x;
	} else {
		local = (coordinate.z * (CHUNK_CELLS + 1) + coordinate.y) *
			(CHUNK_CELLS + 1) + coordinate.x;
	}
	edge_index = axis * AXIS_EDGE_COUNT + local;
	return edge_index >= 0 && edge_index < CHUNK_EDGE_COUNT;
}

bool page_surface_shift_record(
	int page_index,
	int edge_index,
	float isovalue,
	out int unit_offset,
	out vec4 sample_a,
	out vec4 sample_b,
	out ivec2 material_a,
	out ivec2 material_b
) {
	ivec4 header = cell_headers.values[arena.input_a.z + page_index];
	if (header.w != 1 || intBitsToFloat(header.z) != isovalue || header.y <= 0) {
		return false;
	}
	int low = 0;
	int high = header.y;
	while (low < high) {
		int middle = low + (high - low) / 2;
		int reference = arena.input_b.y + header.x + middle * 4;
		int candidate = sample_references.values[reference];
		if (candidate < edge_index) low = middle + 1;
		else high = middle;
	}
	if (low >= header.y) return false;
	int reference = arena.input_b.y + header.x + low * 4;
	if (sample_references.values[reference] != edge_index) return false;
	unit_offset = sample_references.values[reference + 1];
	int sample_a_index = sample_references.values[reference + 2];
	int sample_b_index = sample_references.values[reference + 3];
	sample_a = field_sample_at(sample_a_index, true);
	sample_b = field_sample_at(sample_b_index, true);
	material_a = field_material_at(sample_a_index, true);
	material_b = field_material_at(sample_b_index, true);
	return true;
}

bool resolve_surface_shift_edge(
	ivec3 endpoint_a,
	ivec3 endpoint_b,
	float isovalue,
	out ivec3 resolved_a,
	out ivec3 resolved_b,
	out vec4 sample_a,
	out vec4 sample_b,
	out ivec2 material_a,
	out ivec2 material_b
) {
	bool found = false;
	int page_count = config.values[arena.input_b.z].z;
	for (int page_index = 0; page_index < page_count; ++page_index) {
		int edge_index;
		bool reversed;
		if (!page_edge_index(
				page_index, endpoint_a, endpoint_b, edge_index, reversed)) {
			continue;
		}
		int unit_offset;
		vec4 candidate_sample_a;
		vec4 candidate_sample_b;
		ivec2 candidate_material_a;
		ivec2 candidate_material_b;
		if (!page_surface_shift_record(
				page_index,
				edge_index,
				isovalue,
				unit_offset,
				candidate_sample_a,
				candidate_sample_b,
				candidate_material_a,
				candidate_material_b
			)) {
			return false;
		}
		ivec3 difference = endpoint_b - endpoint_a;
		int axis = difference.x != 0 ? 0 : (difference.y != 0 ? 1 : 2);
		ivec3 coarse_start = reversed ? endpoint_b : endpoint_a;
		ivec3 candidate_a = coarse_start;
		candidate_a[axis] += unit_offset;
		ivec3 candidate_b = candidate_a;
		candidate_b[axis] += 1;
		if (reversed) {
			ivec3 swapped_endpoint = candidate_a;
			candidate_a = candidate_b;
			candidate_b = swapped_endpoint;
			vec4 swapped_sample = candidate_sample_a;
			candidate_sample_a = candidate_sample_b;
			candidate_sample_b = swapped_sample;
			ivec2 swapped_material = candidate_material_a;
			candidate_material_a = candidate_material_b;
			candidate_material_b = swapped_material;
		}
		if (found && (any(notEqual(resolved_a, candidate_a)) ||
				any(notEqual(resolved_b, candidate_b)) ||
				any(notEqual(sample_a, candidate_sample_a)) ||
				any(notEqual(sample_b, candidate_sample_b)) ||
				any(notEqual(material_a, candidate_material_a)) ||
				any(notEqual(material_b, candidate_material_b)))) {
			return false;
		}
		resolved_a = candidate_a;
		resolved_b = candidate_b;
		sample_a = candidate_sample_a;
		sample_b = candidate_sample_b;
		material_a = candidate_material_a;
		material_b = candidate_material_b;
		found = true;
	}
	return found &&
		((sample_a.x < isovalue) != (sample_b.x < isovalue));
}

bool resolve_material_volume_edge(
	ivec3 endpoint_a,
	ivec3 endpoint_b,
	float isovalue,
	int surface_mode,
	out ivec3 resolved_a,
	out ivec3 resolved_b,
	out vec4 sample_a,
	out vec4 sample_b,
	out ivec2 material_a,
	out ivec2 material_b
) {
	ivec3 difference = endpoint_b - endpoint_a;
	int edge_length = abs(difference.x) + abs(difference.y) +
		abs(difference.z);
	if (edge_length <= 0 ||
			!page_cell_sample(
				endpoint_a, edge_length, surface_mode, sample_a, material_a
			) ||
			!page_cell_sample(
				endpoint_b, edge_length, surface_mode, sample_b, material_b
			)) {
		return false;
	}
	resolved_a = endpoint_a;
	resolved_b = endpoint_b;
	return (sample_a.x < isovalue) != (sample_b.x < isovalue);
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
	bool page_field_mode = config.values[config_base].w == 1;
	int meshlet = page_field_mode ? meshlet_for_cell(cell_index) : 0;
	if (compact_surface && page_field_mode && meshlet < 8 &&
			(arena.resident_status.y & (1 << meshlet)) == 0) {
		return;
	}
	int local_vertex_base = cell_index * MAX_VERTICES;
	int local_index_base = cell_index * MAX_INDICES;
	int vertex_base = arena.output_a.x + local_vertex_base;
	int index_base = (compact_surface ? arena.compact_output.w : arena.output_a.y) +
		local_index_base;
	int cell_meta_index = arena.output_a.z + cell_index;
	int draw_index = arena.output_b.x + (compact_surface ? meshlet : cell_index);
	if (!compact_surface) {
		output_draw_commands.values[draw_index] = DrawIndexedIndirectCommand(
			0u, 0u, uint(local_index_base), local_vertex_base, 0u
		);
	}
	if (!compact_surface) {
		for (int index = 0; index < MAX_VERTICES; ++index) {
			store_legacy_position(vertex_base + index, vec4(0.0));
			store_legacy_normal(vertex_base + index, vec4(0.0));
			store_legacy_vertex_meta(vertex_base + index, ivec4(0));
			store_legacy_reuse(
				vertex_base + index,
				ivec4(0, cell_index, index, 1)
			);
		}
		for (int index = 0; index < MAX_INDICES; ++index) {
			output_indices.values[index_base + index] = -1;
		}
	}
	if (!compact_surface && cell_index == 0) {
		store_legacy_identity(
			arena.output_a.w,
			config.values[config_base + 1]
		);
		store_legacy_identity(
			arena.output_a.w + 1,
			config.values[config_base + 2]
		);
		store_legacy_identity(
			arena.output_a.w + 2,
			config.values[config_base + 3]
		);
	}

	int surface_mode = config.values[config_base + 3].z;
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
				store_cell_meta(compact_surface, cell_meta_index, ivec4(STATUS_FAILURE, 0, 0, 0));
				return;
			}
			// Extract every face represented by cached support. Publication masks
			// inactive face meshlets through their indirect instance count, so a
			// later LOD topology change does not require another extraction.
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
		store_cell_meta(compact_surface, cell_meta_index, ivec4(STATUS_FAILURE, 0, 0, 0));
		return;
	}

	vec4 samples[13];
	ivec2 materials[13];
	vec3 positions[13];
	ivec3 endpoint_grid_points[13];
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
					surface_mode,
					samples[index],
					materials[index]
				)) {
				store_cell_meta(compact_surface, cell_meta_index, ivec4(STATUS_FAILURE, 0, 0, 0));
				return;
			}
			endpoint_grid_points[index] = sample_point;
		} else {
			int source_index = sample_references.values[
				arena.input_b.y + reference_offset + index
			];
			samples[index] = field_sample_at(source_index, false);
			materials[index] = field_material_at(source_index, false);
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
			store_cell_meta(compact_surface, cell_meta_index, ivec4(STATUS_EMPTY, case_code, 0, 0));
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
				endpoint_grid_points[topology_index] = endpoint_grid_points[source_index];
			}
			if (page_field_mode) {
				ivec3 sample_point = ivec3(round(positions[source_index]));
				if (!page_cell_sample(
						sample_point,
						int(round(spacing * 2.0)),
						surface_mode,
						samples[topology_index],
						materials[topology_index]
					)) {
					store_cell_meta(compact_surface, cell_meta_index, ivec4(STATUS_FAILURE, 0, 0, 0));
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
			store_cell_meta(compact_surface, cell_meta_index, ivec4(STATUS_EMPTY, case_code, 0, 0));
			return;
		}
		class_code = transition_cell_class.values[case_code];
		reverse_winding = (class_code & 0x80) != 0;
		class_code &= 0x7f;
		if (class_code >= 56) {
			store_cell_meta(compact_surface, cell_meta_index, ivec4(STATUS_FAILURE, case_code, 0, 0));
			return;
		}
		class_data_offset = class_code * 37;
		geometry_counts = transition_cell_data.values[class_data_offset];
		vertex_data_offset = case_code * 12;
	}

	int vertex_count = geometry_counts >> 4;
	int source_index_count = (geometry_counts & 0x0f) * 3;
	if (vertex_count > MAX_VERTICES || source_index_count > MAX_INDICES) {
		store_cell_meta(compact_surface, cell_meta_index, ivec4(STATUS_FAILURE, case_code, 0, 0));
		return;
	}
	vec3 emitted_positions[MAX_VERTICES];
	vec3 emitted_normals[MAX_VERTICES];
	ivec2 emitted_materials[MAX_VERTICES];
	for (int vertex_index = 0; vertex_index < vertex_count; ++vertex_index) {
		int edge_code = cell_type == CELL_REGULAR
			? regular_vertex_data.values[vertex_data_offset + vertex_index]
			: transition_vertex_data.values[vertex_data_offset + vertex_index];
		int endpoint_a = (edge_code >> 4) & 0x0f;
		int endpoint_b = edge_code & 0x0f;
		int topology_count = cell_type == CELL_REGULAR ? 8 : 13;
		if (endpoint_a >= topology_count || endpoint_b >= topology_count) {
			store_cell_meta(compact_surface, cell_meta_index, ivec4(STATUS_FAILURE, case_code, 0, 0));
			return;
		}
		vec4 sample_a = samples[endpoint_a];
		vec4 sample_b = samples[endpoint_b];
		ivec2 material_a = materials[endpoint_a];
		ivec2 material_b = materials[endpoint_b];
		vec3 position_a = positions[endpoint_a];
		vec3 position_b = positions[endpoint_b];
		if (page_field_mode) {
			ivec3 grid_difference = endpoint_grid_points[endpoint_b] -
				endpoint_grid_points[endpoint_a];
			int edge_length = abs(grid_difference.x) + abs(grid_difference.y) +
				abs(grid_difference.z);
			if (edge_length > 1) {
				ivec3 resolved_a;
				ivec3 resolved_b;
				bool resolved = surface_mode == 1 ?
					resolve_material_volume_edge(
						endpoint_grid_points[endpoint_a],
						endpoint_grid_points[endpoint_b],
						isovalue,
						surface_mode,
						resolved_a,
						resolved_b,
						sample_a,
						sample_b,
						material_a,
						material_b
					) :
					resolve_surface_shift_edge(
						endpoint_grid_points[endpoint_a],
						endpoint_grid_points[endpoint_b],
						isovalue,
						resolved_a,
						resolved_b,
						sample_a,
						sample_b,
						material_a,
						material_b
					);
				if (!resolved) {
					store_cell_meta(compact_surface, cell_meta_index, ivec4(STATUS_FAILURE, case_code, 0, 0));
					return;
				}
				vec3 endpoint_a_offset = position_a -
					vec3(endpoint_grid_points[endpoint_a]);
				vec3 endpoint_b_offset = position_b -
					vec3(endpoint_grid_points[endpoint_b]);
				position_a = vec3(resolved_a) + endpoint_a_offset;
				position_b = vec3(resolved_b) + endpoint_b_offset;
			}
		}
		// The CPU authority canonicalizes every shared edge before deduplication.
		// Keep both GPU copies of an edge on the same arithmetic path even when
		// Transvoxel table records name its endpoints in opposite orders.
		if (position_precedes(position_b, position_a)) {
			vec3 swapped_position = position_a;
			position_a = position_b;
			position_b = swapped_position;
			vec4 swapped_sample = sample_a;
			sample_a = sample_b;
			sample_b = swapped_sample;
			ivec2 swapped_material = material_a;
			material_a = material_b;
			material_b = swapped_material;
		}
		float alpha = regularized_alpha(sample_a.x, sample_b.x, isovalue);
		if (alpha < 0.0) {
			store_cell_meta(compact_surface, cell_meta_index, ivec4(STATUS_FAILURE, case_code, 0, 0));
			return;
		}
		vec3 position = interpolate_edge_position(position_a, position_b, alpha);
		vec3 normal = normalized_or_zero(mix(sample_a.yzw, sample_b.yzw, alpha));
		ivec2 surface_material = sample_a.x < isovalue ? material_a : material_b;
		if (page_field_mode) {
			float coarse_cell_size = cell_type == CELL_TRANSITION ? spacing * 2.0 : spacing;
			float extent = float(CHUNK_CELLS) * coarse_cell_size;
			float width = coarse_cell_size * 0.25;
			vec3 local_position = snap_position(position - vec3(chunk_origin));
			local_position = deform_chunk_position(
				local_position,
				normal,
				config.values[config_base + 3].y,
				coarse_cell_size,
				width,
				extent,
				cell_type == CELL_TRANSITION ? orientation : -1
			);
			position = vec3(chunk_origin) + snap_position(local_position);
		}
		int output_index = vertex_base + vertex_index;
		emitted_positions[vertex_index] = position;
		emitted_normals[vertex_index] = normal;
		emitted_materials[vertex_index] = surface_material;
		if (!compact_surface) {
			store_legacy_position(output_index, vec4(position, 1.0));
			store_legacy_normal(output_index, vec4(normal, 0.0));
			store_legacy_vertex_meta(
				output_index,
				ivec4(
					surface_material.x,
					surface_material.y,
					endpoint_a,
					endpoint_b
				)
			);
			output_reuse.values[output_index * 4] = uint((edge_code >> 8) & 0xff);
		}
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
		vec3 p0 = emitted_positions[first];
		vec3 p1 = emitted_positions[second];
		vec3 p2 = emitted_positions[third];
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
		store_cell_meta(compact_surface, cell_meta_index, ivec4(STATUS_EMPTY, case_code, 0, 0));
		return;
	}
	store_cell_meta(
		compact_surface,
		cell_meta_index,
		ivec4(STATUS_OK, case_code, vertex_count, output_index_count)
	);
	if (compact_surface) {
		int compact_vertex_offset = page_field_mode ? meshlet_vertex_base(meshlet) : 0;
		int compact_index_offset = page_field_mode ? meshlet_index_base(meshlet) : 0;
		int status_base = arena.resident_status.x + meshlet * 4;
		uint compact_vertex_base = atomicAdd(
			resident_status.values[status_base + 1],
			uint(vertex_count)
		) + uint(compact_vertex_offset);
		uint compact_index_base = atomicAdd(
			output_draw_commands.values[draw_index].index_count,
			uint(output_index_count)
		) + uint(compact_index_offset);
		atomicAdd(
			resident_status.values[status_base],
			uint(output_index_count)
		);
		for (int vertex_index = 0; vertex_index < vertex_count; ++vertex_index) {
			int compact_vertex_index = int(compact_vertex_base) + vertex_index;
			int packed_position_index = arena.compact_output.x +
				compact_vertex_index * 3;
			output_positions.values[packed_position_index] = floatBitsToUint(
				emitted_positions[vertex_index].x
			);
			output_positions.values[packed_position_index + 1] = floatBitsToUint(
				emitted_positions[vertex_index].y
			);
			output_positions.values[packed_position_index + 2] = floatBitsToUint(
				emitted_positions[vertex_index].z
			);
			output_normals.values[
				arena.compact_output.y + compact_vertex_index
			] = packSnorm2x16(octahedral_normal(emitted_normals[vertex_index]));
			ivec2 material = emitted_materials[vertex_index];
			output_vertex_meta.values[
				arena.compact_output.z + compact_vertex_index
			] = (uint(material.x) & 0xffffu) |
				((uint(material.y) & 0xffu) << 16) |
				((uint(meshlet + 1) & 0xffu) << 24);
		}
		for (int index = 0; index < output_index_count; ++index) {
			output_indices.values[
				arena.compact_output.w + int(compact_index_base) + index
			] = int(compact_vertex_base) + emitted_indices[index];
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

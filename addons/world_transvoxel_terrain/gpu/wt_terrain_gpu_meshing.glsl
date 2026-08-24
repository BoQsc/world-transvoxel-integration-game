#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

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
layout(set = 0, binding = 20, std430) writeonly buffer OutputDrawCommands {
	DrawIndexedIndirectCommand values[];
} output_draw_commands;

const int CELL_REGULAR = 0;
const int CELL_TRANSITION = 1;
const int STATUS_EMPTY = 0;
const int STATUS_OK = 1;
const int STATUS_FAILURE = 2;
const int MAX_VERTICES = 12;
const int MAX_INDICES = 36;

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

void main() {
	uint cell_index_u = gl_GlobalInvocationID.x;
	int cell_count = config.values[0].x;
	if (cell_index_u >= uint(cell_count)) {
		return;
	}
	int cell_index = int(cell_index_u);
	int vertex_base = cell_index * MAX_VERTICES;
	int index_base = cell_index * MAX_INDICES;
	output_draw_commands.values[cell_index] = DrawIndexedIndirectCommand(
		0u, 0u, uint(index_base), vertex_base, 0u
	);
	for (int index = 0; index < MAX_VERTICES; ++index) {
		output_positions.values[vertex_base + index] = vec4(0.0);
		output_normals.values[vertex_base + index] = vec4(0.0);
		output_vertex_meta.values[vertex_base + index] = ivec4(0);
		output_reuse.values[vertex_base + index] = ivec4(0, cell_index, index, 1);
	}
	for (int index = 0; index < MAX_INDICES; ++index) {
		output_indices.values[index_base + index] = -1;
	}
	if (cell_index == 0) {
		output_identity.values[0] = config.values[1];
		output_identity.values[1] = config.values[2];
		output_identity.values[2] = config.values[3];
	}

	ivec4 header = cell_headers.values[cell_index];
	vec4 origin_and_spacing = cell_origins.values[cell_index];
	vec4 options = cell_options.values[cell_index];
	int cell_type = header.x;
	int orientation = header.y;
	int reference_offset = header.z;
	int input_sample_count = header.w;
	float spacing = origin_and_spacing.w;
	float transition_width = options.x;
	float isovalue = options.y;
	if ((cell_type != CELL_REGULAR && cell_type != CELL_TRANSITION) ||
		(cell_type == CELL_REGULAR && input_sample_count != 8) ||
		(cell_type == CELL_TRANSITION && input_sample_count != 9) ||
		spacing <= 0.0 ||
		(cell_type == CELL_TRANSITION && (transition_width <= 0.0 || orientation < 0 || orientation > 5))) {
		output_cell_meta.values[cell_index] = ivec4(STATUS_FAILURE, 0, 0, 0);
		return;
	}

	vec4 samples[13];
	ivec2 materials[13];
	vec3 positions[13];
	for (int index = 0; index < input_sample_count; ++index) {
		int source_index = sample_references.values[reference_offset + index];
		samples[index] = field_values.values[source_index];
		materials[index] = field_meta.values[source_index].xy;
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
			output_cell_meta.values[cell_index] = ivec4(STATUS_EMPTY, case_code, 0, 0);
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
		}
		const int case_samples[9] = int[9](0, 1, 2, 5, 8, 7, 6, 3, 4);
		for (int bit = 0; bit < 9; ++bit) {
			if (samples[case_samples[bit]].x < isovalue) {
				case_code |= 1 << bit;
			}
		}
		if (case_code == 0 || case_code == 511) {
			output_cell_meta.values[cell_index] = ivec4(STATUS_EMPTY, case_code, 0, 0);
			return;
		}
		class_code = transition_cell_class.values[case_code];
		reverse_winding = (class_code & 0x80) != 0;
		class_code &= 0x7f;
		if (class_code >= 56) {
			output_cell_meta.values[cell_index] = ivec4(STATUS_FAILURE, case_code, 0, 0);
			return;
		}
		class_data_offset = class_code * 37;
		geometry_counts = transition_cell_data.values[class_data_offset];
		vertex_data_offset = case_code * 12;
	}

	int vertex_count = geometry_counts >> 4;
	int source_index_count = (geometry_counts & 0x0f) * 3;
	if (vertex_count > MAX_VERTICES || source_index_count > MAX_INDICES) {
		output_cell_meta.values[cell_index] = ivec4(STATUS_FAILURE, case_code, 0, 0);
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
			output_cell_meta.values[cell_index] = ivec4(STATUS_FAILURE, case_code, 0, 0);
			return;
		}
		float alpha = regularized_alpha(samples[endpoint_a].x, samples[endpoint_b].x, isovalue);
		if (alpha < 0.0) {
			output_cell_meta.values[cell_index] = ivec4(STATUS_FAILURE, case_code, 0, 0);
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
		output_indices.values[index_base + output_index_count] = first;
		output_indices.values[index_base + output_index_count + 1] = second;
		output_indices.values[index_base + output_index_count + 2] = third;
		output_index_count += 3;
	}
	if (output_index_count == 0) {
		output_cell_meta.values[cell_index] = ivec4(STATUS_EMPTY, case_code, 0, 0);
		return;
	}
	output_cell_meta.values[cell_index] = ivec4(
		STATUS_OK, case_code, vertex_count, output_index_count
	);
	output_draw_commands.values[cell_index] = DrawIndexedIndirectCommand(
		uint(output_index_count), 1u, uint(index_base), vertex_base, 0u
	);
}

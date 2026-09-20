#[compute]
#version 450

// Packs the 44 fixed-capacity extraction meshlets into exact resident buffers.
// The already validated status records are copied to a stable resident slot so
// the existing cohort commit can switch visibility atomically after this pass.
layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(push_constant, std430) uniform CompactOffsets {
	ivec4 source_offsets; // position uint, normal uint, meta uint, index int
	ivec4 source_state;   // indirect command, status uint, meshlet count, unused
	ivec4 destination_state; // status uint, unused...
} compact;

layout(set = 0, binding = 0, std430) readonly buffer SourcePositions {
	uint values[];
} source_positions;
layout(set = 0, binding = 1, std430) readonly buffer SourceNormals {
	uint values[];
} source_normals;
layout(set = 0, binding = 2, std430) readonly buffer SourceMeta {
	uint values[];
} source_meta;
layout(set = 0, binding = 3, std430) readonly buffer SourceIndices {
	int values[];
} source_indices;

struct DrawIndexedIndirectCommand {
	uint index_count;
	uint instance_count;
	uint first_index;
	int vertex_offset;
	uint first_instance;
};
layout(set = 0, binding = 4, std430) readonly buffer SourceCommands {
	DrawIndexedIndirectCommand values[];
} source_commands;
layout(set = 0, binding = 5, std430) buffer ResidentStatus {
	uint values[];
} resident_status;
layout(set = 0, binding = 6, std430) writeonly buffer DestinationPositions {
	uint values[];
} destination_positions;
layout(set = 0, binding = 7, std430) writeonly buffer DestinationNormals {
	uint values[];
} destination_normals;
layout(set = 0, binding = 8, std430) writeonly buffer DestinationMeta {
	uint values[];
} destination_meta;
layout(set = 0, binding = 9, std430) writeonly buffer DestinationIndices {
	int values[];
} destination_indices;
layout(set = 0, binding = 10, std430) writeonly buffer DestinationCommands {
	DrawIndexedIndirectCommand values[];
} destination_commands;

const uint REGULAR_MESHLET_COUNT = 8u;
const uint REGULAR_VERTEX_CAPACITY = 512u * 12u;
const uint TRANSITION_VERTEX_CAPACITY = 64u * 12u;
const uint REGULAR_INDEX_CAPACITY = 512u * 36u;
const uint TRANSITION_INDEX_CAPACITY = 64u * 36u;

shared uint vertex_counts[44];
shared uint index_counts[44];
shared uint vertex_prefixes[44];
shared uint index_prefixes[44];
shared uint total_vertices;
shared uint total_indices;

uint source_vertex_base(uint meshlet) {
	return meshlet < REGULAR_MESHLET_COUNT
		? meshlet * REGULAR_VERTEX_CAPACITY
		: REGULAR_MESHLET_COUNT * REGULAR_VERTEX_CAPACITY +
			(meshlet - REGULAR_MESHLET_COUNT) * TRANSITION_VERTEX_CAPACITY;
}

uint source_index_base(uint meshlet) {
	return meshlet < REGULAR_MESHLET_COUNT
		? meshlet * REGULAR_INDEX_CAPACITY
		: REGULAR_MESHLET_COUNT * REGULAR_INDEX_CAPACITY +
			(meshlet - REGULAR_MESHLET_COUNT) * TRANSITION_INDEX_CAPACITY;
}

uint meshlet_for_compact_offset(uint offset, bool vertex_offset) {
	uint meshlet_count = uint(compact.source_state.z);
	for (uint meshlet = 0u; meshlet < meshlet_count; ++meshlet) {
		uint begin = vertex_offset ? vertex_prefixes[meshlet] : index_prefixes[meshlet];
		uint count = vertex_offset ? vertex_counts[meshlet] : index_counts[meshlet];
		if (offset >= begin && offset < begin + count) return meshlet;
	}
	return 0u;
}

void main() {
	uint lane = gl_LocalInvocationID.x;
	uint meshlet_count = uint(compact.source_state.z);
	if (lane < meshlet_count) {
		uint status_base = uint(compact.source_state.y) + lane * 4u;
		index_counts[lane] = resident_status.values[status_base];
		vertex_counts[lane] = resident_status.values[status_base + 1u];
	}
	barrier();
	if (lane == 0u) {
		uint vertex_total = 0u;
		uint index_total = 0u;
		for (uint meshlet = 0u; meshlet < meshlet_count; ++meshlet) {
			vertex_prefixes[meshlet] = vertex_total;
			index_prefixes[meshlet] = index_total;
			vertex_total += vertex_counts[meshlet];
			index_total += index_counts[meshlet];
		}
		total_vertices = vertex_total;
		total_indices = index_total;
	}
	barrier();
	for (uint output_vertex = lane; output_vertex < total_vertices; output_vertex += 256u) {
		uint meshlet = meshlet_for_compact_offset(output_vertex, true);
		uint local_vertex = output_vertex - vertex_prefixes[meshlet];
		uint source_vertex = source_vertex_base(meshlet) + local_vertex;
		uint source_position = uint(compact.source_offsets.x) + source_vertex * 3u;
		uint destination_position = output_vertex * 3u;
		destination_positions.values[destination_position] =
			source_positions.values[source_position];
		destination_positions.values[destination_position + 1u] =
			source_positions.values[source_position + 1u];
		destination_positions.values[destination_position + 2u] =
			source_positions.values[source_position + 2u];
		destination_normals.values[output_vertex] =
			source_normals.values[uint(compact.source_offsets.y) + source_vertex];
		destination_meta.values[output_vertex] =
			source_meta.values[uint(compact.source_offsets.z) + source_vertex];
	}
	for (uint output_index = lane; output_index < total_indices; output_index += 256u) {
		uint meshlet = meshlet_for_compact_offset(output_index, false);
		uint local_index = output_index - index_prefixes[meshlet];
		int source_value = source_indices.values[
			uint(compact.source_offsets.w) + source_index_base(meshlet) + local_index
		];
		destination_indices.values[output_index] = source_value -
			int(source_vertex_base(meshlet)) + int(vertex_prefixes[meshlet]);
	}
	if (lane < meshlet_count) {
		destination_commands.values[lane] = DrawIndexedIndirectCommand(
			index_counts[lane], 1u, index_prefixes[lane], 0, 0u
		);
	}
	if (lane < 44u) {
		uint source_status = uint(compact.source_state.y) + lane * 4u;
		uint destination_status = uint(compact.destination_state.x) + lane * 4u;
		resident_status.values[destination_status] = resident_status.values[source_status];
		resident_status.values[destination_status + 1u] =
			resident_status.values[source_status + 1u];
		resident_status.values[destination_status + 2u] =
			resident_status.values[source_status + 2u];
		resident_status.values[destination_status + 3u] =
			resident_status.values[source_status + 3u];
	}
}

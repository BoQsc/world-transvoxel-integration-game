#[compute]
#version 450

// One workgroup owns the complete visibility transaction. Extraction dispatches
// precede this command in the same RenderingDevice queue, so their status words
// are visible before any activation flag changes.
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer ResidentStatus {
	uint values[];
} resident_status;
layout(set = 0, binding = 1, std430) buffer ActivationFlags {
	uint values[];
} activation_flags;
layout(set = 0, binding = 2, std430) readonly buffer CohortDescriptor {
	int values[];
} cohort;
layout(set = 0, binding = 3, std430) buffer ResidentSummary {
	uint values[];
} resident_summary;

shared uint cohort_valid;

void main() {
	uint lane = gl_LocalInvocationID.x;
	uint candidate_count = uint(cohort.values[0]);
	uint retirement_count = uint(cohort.values[1]);
	if (lane == 0u) cohort_valid = 1u;
	barrier();
	for (uint index = lane; index < candidate_count; index += 64u) {
		int slot = cohort.values[4 + int(index)];
		uint index_total = 0u;
		uint vertex_total = 0u;
		uint failure_total = 0u;
		if (slot < 0) {
			atomicAnd(cohort_valid, 0u);
			continue;
		}
		for (int meshlet = 0; meshlet < 32; ++meshlet) {
			int status_base = slot * 128 + meshlet * 4;
			uint index_count = resident_status.values[status_base];
			uint vertex_count = resident_status.values[status_base + 1];
			uint failure_count = resident_status.values[status_base + 2];
			index_total += index_count;
			vertex_total += vertex_count;
			failure_total += failure_count;
			if (failure_count != 0u ||
					((index_count == 0u) != (vertex_count == 0u))) {
				atomicAnd(cohort_valid, 0u);
			}
		}
		int summary_base = slot * 5;
		resident_summary.values[summary_base] = index_total;
		resident_summary.values[summary_base + 1] = vertex_total;
		resident_summary.values[summary_base + 2] = failure_total;
		resident_summary.values[summary_base + 4] = uint(slot);
	}
	memoryBarrierBuffer();
	barrier();
	for (uint index = lane; index < candidate_count; index += 64u) {
		int slot = cohort.values[4 + int(index)];
		resident_summary.values[slot * 5 + 3] = cohort_valid;
		if (cohort_valid != 0u) activation_flags.values[slot] = 1u;
	}
	if (cohort_valid == 0u) return;
	for (uint index = lane; index < retirement_count; index += 64u) {
		int slot = cohort.values[4 + int(candidate_count + index)];
		activation_flags.values[slot] = 0u;
	}
}

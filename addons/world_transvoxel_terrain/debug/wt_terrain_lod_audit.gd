@tool
extends RefCounted
class_name WtTerrainLodAudit

const WatertightnessProbe := preload(
	"res://addons/world_transvoxel_terrain/debug/wt_terrain_watertightness_probe.gd"
)


static func collect(
	terrain_world: Node,
	topology_center: Vector3 = Vector3.ZERO,
	topology_radius: float = 0.0,
	topology_at_lod_seam: bool = false
) -> Dictionary:
	var states: Array = []
	if terrain_world != null and terrain_world.has_method("query_active_chunk_states"):
		states = terrain_world.call("query_active_chunk_states")
	var lod_counts := {}
	var visual_mismatches: Array[String] = []
	var collision_mismatches: Array[String] = []
	var coverage := {}
	var coverage_lods := {}
	var overlap_examples: Array[String] = []
	var visual_records := 0
	var collision_records := 0
	for value in states:
		var state := value as RefCounted
		if state == null or not bool(state.call("is_present")):
			continue
		var coordinate: Vector3i = state.call("get_chunk_coordinate")
		var lod := int(state.call("get_lod"))
		var key := "%s@L%d" % [str(coordinate), lod]
		var generation := int(state.call("get_generation"))
		lod_counts[str(lod)] = int(lod_counts.get(str(lod), 0)) + 1
		if bool(state.call("is_visual_required")):
			visual_records += 1
			var render_generation := int(state.call("get_render_generation"))
			if not bool(state.call("is_visual_ready")) or \
					render_generation not in [0, generation] or \
					int(state.call("get_staged_render_generation")) != 0:
				visual_mismatches.append(key)
			_accumulate_lod0_coverage(
				coordinate, lod, key, coverage, coverage_lods, overlap_examples
			)
		if bool(state.call("is_collision_required")):
			collision_records += 1
			var collision_generation := int(state.call("get_collision_generation"))
			if not bool(state.call("is_collision_ready")) or \
					collision_generation not in [0, generation] or \
					int(state.call("get_staged_collision_generation")) != 0:
				collision_mismatches.append(key)
	var backend: Node = null
	if terrain_world != null and terrain_world.has_method("get_backend_terrain"):
		backend = terrain_world.call("get_backend_terrain")
	var topology := {"enabled": false, "ok": true}
	var lod_seam := _find_closest_horizontal_lod_seam(coverage_lods, topology_center)
	if topology_radius > 0.0:
		var audit_center := topology_center
		if topology_at_lod_seam:
			if not bool(lod_seam.get("found", false)):
				topology = {"enabled": true, "ok": false, "error": "lod_seam_not_found"}
			else:
				audit_center = lod_seam.get("_center", topology_center)
		if not topology.has("error"):
			topology = WatertightnessProbe.collect(
				backend, "cpu_large_terrain_lod_seam" if topology_at_lod_seam else "cpu_large_terrain_acceptance", audit_center, topology_radius
			)
	lod_seam.erase("_center")
	return {
		"status": "PASS" if visual_mismatches.is_empty() and \
				collision_mismatches.is_empty() and overlap_examples.is_empty() and \
				bool(topology.get("ok", false)) else "FAIL",
		"active_records": states.size(),
		"visual_records": visual_records,
		"collision_records": collision_records,
		"lod_counts": lod_counts,
		"visual_generation_mismatches": visual_mismatches,
		"collision_generation_mismatches": collision_mismatches,
		"lod0_coverage_cells": coverage.size(),
		"coverage_overlap_count": overlap_examples.size(),
		"coverage_overlap_examples": overlap_examples,
		"lod_seam": lod_seam,
		"topology": topology,
		"implementation": "production_addon_lod_audit_v1",
	}


static func _accumulate_lod0_coverage(
	coordinate: Vector3i,
	lod: int,
	owner: String,
	coverage: Dictionary,
	coverage_lods: Dictionary,
	overlap_examples: Array[String]
) -> void:
	var scale := 1 << lod
	var minimum := coordinate * scale
	for z in range(minimum.z, minimum.z + scale):
		for y in range(minimum.y, minimum.y + scale):
			for x in range(minimum.x, minimum.x + scale):
				var key := "%d,%d,%d" % [x, y, z]
				var cell := Vector3i(x, y, z)
				if not coverage_lods.has(cell):
					coverage_lods[cell] = {"lod": lod, "owner": owner}
				if coverage.has(key):
					if overlap_examples.size() < 16:
						overlap_examples.append("%s:%s|%s" % [key, str(coverage[key]), owner])
				else:
					coverage[key] = owner


static func _find_closest_horizontal_lod_seam(coverage_lods: Dictionary, target: Vector3) -> Dictionary:
	var best := {}
	var best_distance := INF
	var directions: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.BACK]
	for value in coverage_lods.keys():
		var cell: Vector3i = value
		var record := coverage_lods[cell] as Dictionary
		for direction: Vector3i in directions:
			var neighbor: Vector3i = cell + direction
			if not coverage_lods.has(neighbor):
				continue
			var neighbor_record := coverage_lods[neighbor] as Dictionary
			if int(record.get("lod", -1)) == int(neighbor_record.get("lod", -1)):
				continue
			var center := Vector3(
				float(cell.x + (1 if direction.x != 0 else 0)) * 16.0 if direction.x != 0 else (float(cell.x) + 0.5) * 16.0,
				(float(cell.y) + 0.5) * 16.0,
				float(cell.z + (1 if direction.z != 0 else 0)) * 16.0 if direction.z != 0 else (float(cell.z) + 0.5) * 16.0
			)
			var distance := center.distance_squared_to(target)
			if distance < best_distance:
				best_distance = distance
				best = {
					"found": true,
					"center": {"x": center.x, "y": center.y, "z": center.z},
					"lod_a": int(record.get("lod", -1)),
					"lod_b": int(neighbor_record.get("lod", -1)),
					"owner_a": str(record.get("owner", "")),
					"owner_b": str(neighbor_record.get("owner", "")),
					"_center": center,
				}
	return best if not best.is_empty() else {"found": false}

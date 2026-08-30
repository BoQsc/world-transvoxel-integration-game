extends RefCounted

const CAPACITY := 96
const CHUNK_EXTENT := 16.0
const MAXIMUM_RAY_CANDIDATES := 4096

var samples: Array = []
var dropped_samples := 0
var _started_us := Time.get_ticks_usec()
var publication_inspection_enabled := false
var _inspected_labels := {}


func capture(
	label: String, frame: int, game_world: Node, terrain: Node,
	player: CharacterBody3D, ray: Dictionary = {}
) -> void:
	if samples.size() >= CAPACITY:
		dropped_samples += 1
		return
	var started := Time.get_ticks_usec()
	var support: Dictionary = player.call("get_streaming_collision_status")
	var keys: Array[Vector3i] = []
	for item in Dictionary(support.get("readiness", {})).get("probe_chunks", []):
		var key: Vector3i = item.get("coordinate", Vector3i.ZERO)
		if not keys.has(key):
			keys.append(key)
	var ray_inventory := {}
	if not ray.is_empty():
		ray_inventory = ray_chunks(ray.origin, ray.end)
		for key in ray_inventory.get("chunks", []):
			if not keys.has(key):
				keys.append(key)
	var states: Array = []
	var seen := {}
	for key in keys:
		for lod in range(4):
			var scale := float(1 << lod)
			var coordinate := Vector3i(
				floori(float(key.x) / scale), floori(float(key.y) / scale),
				floori(float(key.z) / scale)
			)
			var id := "%d:%d:%d:%d" % [coordinate.x, coordinate.y, coordinate.z, lod]
			if not seen.has(id):
				seen[id] = true
				states.append(chunk_snapshot(terrain, coordinate, lod))
	var gpu: Dictionary = terrain.call("get_gpu_resident_render_status")
	var wait: Dictionary = gpu.get("last_activation_cohort_wait", {})
	var wait_summary := _scalar_fields(wait)
	wait_summary["waiting_member"] = wait.get("waiting_member", {})
	var event := {
		"label": label, "frame": frame,
		"elapsed_us": started - _started_us,
		"player_position": player.global_position,
		"support": support, "ray": ray, "ray_inventory": ray_inventory,
		"support_is_last_movement_attempt": true,
		"states": states,
		"viewers": game_world.call("get_causal_trace_context"),
		"pipeline": _scalar_fields(terrain.call("get_runtime_metrics")),
		"gpu": _scalar_fields(gpu),
		"gpu_native": _scalar_fields(gpu.get("native_metrics", {})),
		"gpu_activation_wait": wait_summary,
	}
	if publication_inspection_enabled and not _inspected_labels.has(label):
		for state in states:
			if not ray.is_empty() and not ray_inventory.get("chunks", []).has(state.coordinate):
				continue
			if state.lod != 0 or not state.get("is_visual_required", false) or \
				state.get("is_visual_ready", false) or not state.get("is_collision_required", false):
				continue
			var backend: Node = terrain.call("get_backend_terrain")
			if backend != null and backend.has_method("inspect_gpu_resident_publication"):
				event["publication_inspection"] = backend.call(
					"inspect_gpu_resident_publication", state.coordinate, state.lod
				)
				_inspected_labels[label] = true
				break
	var serialized: Dictionary = _json_value(event)
	serialized["capture_us"] = Time.get_ticks_usec() - started
	samples.append(serialized)


func summary() -> Dictionary:
	return {
		"enabled": true,
		"schema": "world_transvoxel.runtime_readiness_probe.v1",
		"diagnostic_only_not_performance_baseline": true,
		"started_ticks_us": _started_us,
		"capacity": CAPACITY, "dropped_samples": dropped_samples,
		"samples": samples.duplicate(true),
	}


static func chunk_snapshot(terrain: Object, coordinate: Vector3i, lod: int) -> Dictionary:
	var state: RefCounted = terrain.call("query_chunk_state", coordinate, lod)
	var result := {"coordinate": coordinate, "lod": lod, "is_present": false}
	if state == null:
		return result
	for method in [
		"is_present", "get_generation", "is_visual_required", "is_visual_ready",
		"is_collision_required", "is_collision_ready", "get_render_generation",
		"get_staged_render_generation", "get_collision_generation",
		"get_staged_collision_generation",
	]:
		result[method] = state.call(method)
	return result


static func ray_chunks(origin: Vector3, end: Vector3) -> Dictionary:
	if not origin.is_finite() or not end.is_finite():
		return {"complete": false, "reason": "nonfinite_ray", "chunks": []}
	# Include both sides when the ray lies exactly on a chunk face.
	var bounds := AABB(origin, Vector3.ZERO).expand(end).grow(0.0001)
	var low := Vector3i((bounds.position / CHUNK_EXTENT).floor())
	var high := Vector3i((bounds.end / CHUNK_EXTENT).floor())
	var size := high - low + Vector3i.ONE
	if float(size.x) * float(size.y) * float(size.z) > MAXIMUM_RAY_CANDIDATES:
		return {"complete": false, "reason": "ray_candidate_capacity", "chunks": []}
	var keys: Array[Vector3i] = []
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var key := Vector3i(x, y, z)
				var box := AABB(Vector3(key) * CHUNK_EXTENT, Vector3.ONE * CHUNK_EXTENT)
				if box.has_point(origin) or box.intersects_segment(origin, end) != null:
					keys.append(key)
	return {"complete": true, "chunks": keys}


static func _scalar_fields(value: Dictionary) -> Dictionary:
	var result := {}
	for key in value:
		if typeof(value[key]) in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING]:
			result[key] = value[key]
	return result


static func _json_value(value: Variant) -> Variant:
	if value is Vector3 or value is Vector3i:
		return {"x": value.x, "y": value.y, "z": value.z}
	if value is Dictionary:
		var result := {}
		for key in value:
			result[key] = _json_value(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item in value:
			result.append(_json_value(item))
		return result
	return value

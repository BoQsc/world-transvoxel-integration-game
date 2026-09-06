extends "res://tests/gpu_resident_multichunk_relocation_smoke.gd"

const EditOperation := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd")
const EditBatch := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd")
const OUTPUT_PATH := "res://.godot/world_transvoxel_captures/gpu_instant_critical_path/result.json"
const HOT_EDIT_COUNT := 6

var _frames: Array[Dictionary] = []
var _phase := "startup"
var _last_tick_us := 0
var _maximum_queues := {}
var _trace_enabled := true


func _run() -> void:
	_trace_enabled = not OS.get_cmdline_user_args().has("--gpu-critical-path-trace-off")
	_setup_viewport()
	_world = TerrainWorld.new()
	_world.terrain_profile = _terrain_profile()
	_world.runtime_profile = _runtime_profile()
	var generation: Resource = _generation_profile()
	generation.world_chunk_count_x = 8
	generation.world_chunk_count_y = 2
	generation.world_chunk_count_z = 4
	_world.generation_profile = generation
	_world.storage_profile = _storage_profile()
	_world.runtime_gpu_resident_render_candidate_enabled = true
	_world.runtime_gpu_resident_background_refinement_enabled = false
	_world.runtime_gpu_resident_viewer_refinement_enabled = true
	_world.runtime_gpu_resident_chunk_capacity = 256
	root.add_child(_world)
	if not _world.start_backend_world() or not await _wait_for_state("running"):
		_fail("critical-path world did not start")
		return
	_world.set_debug_gpu_resident_lifecycle_history_enabled(_trace_enabled)
	_world.set_debug_gpu_stage_timing_enabled(_trace_enabled)
	if not _world.update_viewer(1, 1, Vector3(8, 8, 8), 1, 0) \
			or not _world.update_collision_viewer(2, 1, Vector3(8, 8, 8), 0):
		_fail("initial interaction viewers were rejected")
		return
	if not await _wait_for_target(Vector3i.ZERO, 0, -1, 1200):
		_fail("initial interaction chunk did not become ready")
		return
	if _trace_enabled and not _world.begin_cpu_causal_trace():
		_fail("native causal trace did not start")
		return
	var trace_started_us := Time.get_ticks_usec()
	_last_tick_us = trace_started_us
	var metrics_before := _measurement_snapshot()
	var edits: Array[Dictionary] = []
	_phase = "hot_edit"
	for index in range(HOT_EDIT_COUNT):
		var center := Vector3(6.0 + float(index % 3) * 2.0, 8.0, 6.0 + float(index / 3) * 3.0)
		var operation := EditOperation.new()
		operation.mode = EditOperation.Mode.CONSTRUCT if index % 2 == 0 else EditOperation.Mode.CARVE
		operation.brush_shape = EditOperation.BrushShape.SPHERE
		operation.center = center
		operation.radius = 2.25
		operation.material_id = 3
		operation.density_value = 1.0
		var batch := EditBatch.new()
		batch.add_operation(operation)
		var revision: int = int(_world.get_world_revision()) + 1
		var submitted_us := Time.get_ticks_usec()
		var submitted_frame := _frames.size()
		if not _world.submit_edit_batch(batch, 7100 + index):
			_fail("hot edit %d was rejected" % index)
			return
		var returned_us := Time.get_ticks_usec()
		var ready := await _wait_for_target(Vector3i.ZERO, 0, revision, 600)
		if not ready:
			_fail("hot edit %d did not reach visual/collision readiness" % index)
			return
		edits.append({
			"index": index,
			"revision": revision,
			"mode": "construct" if index % 2 == 0 else "dig",
			"submission_us": returned_us - submitted_us,
			"ready_us": Time.get_ticks_usec() - submitted_us,
			"ready_frames": _frames.size() - submitted_frame,
			"submitted_ticks_usec": submitted_us,
			"ready_ticks_usec": Time.get_ticks_usec(),
		})

	_phase = "cold_approach"
	var cold_position := Vector3(104, 8, 8)
	var camera := root.get_camera_3d()
	if camera != null:
		camera.position = Vector3(104, 42, 82)
		camera.look_at(cold_position, Vector3.UP)
	var cold_started_us := Time.get_ticks_usec()
	var cold_started_frame := _frames.size()
	if not _world.update_viewer(1, 2, cold_position, 1, 0) \
			or not _world.update_collision_viewer(2, 2, cold_position, 0):
		_fail("cold approach viewers were rejected")
		return
	if not await _wait_for_target(Vector3i(6, 0, 0), 0, -1, 1200):
		_fail("cold approach target did not become ready")
		return
	var cold_ready_us := Time.get_ticks_usec() - cold_started_us
	var cold_ready_frames := _frames.size() - cold_started_frame
	if _trace_enabled:
		_world.end_cpu_causal_trace()
	var native: Dictionary = _world.get_cpu_causal_trace_events(0, 65536) \
		if _trace_enabled else {"events": []}
	var metrics_after := _measurement_snapshot()
	var gpu_status: Dictionary = _world.get_gpu_resident_render_status()
	var lifecycle: Array = gpu_status.get("recent_lifecycle_events", [])
	var retained_lifecycle := []
	for event_value in lifecycle:
		var event := Dictionary(event_value)
		if int(event.get("ticks_usec", 0)) >= trace_started_us:
			retained_lifecycle.append(event)
	var result := {
		"schema": "world_transvoxel.gpu_instant_critical_path.v1",
		"driver": RenderingServer.get_current_rendering_driver_name().to_lower(),
		"trace_enabled": _trace_enabled,
		"trace_started_ticks_usec": trace_started_us,
		"hot_edit_count": HOT_EDIT_COUNT,
		"hot_edits": edits,
		"cold_approach_ready_us": cold_ready_us,
		"cold_approach_ready_frames": cold_ready_frames,
		"frames": _frames,
		"maximum_queues": _maximum_queues,
		"metrics_before": metrics_before,
		"metrics_after": metrics_after,
		"native_trace": native,
		"gpu_lifecycle": retained_lifecycle,
		"acceptance": {
			"submission_p99_target_us": 1000,
			"hot_visual_target_frames": 2,
			"cold_cached_target_us": 100000,
		},
	}
	var required_native := {
		"edit_journal_committed": 0,
		"edit_dirty_page_admitted": 0,
		"collision_payload_prepared": 0,
		"collision_sink_applied": 0,
	}
	for event_value in Array(native.get("events", [])):
		var kind := str(Dictionary(event_value).get("kind", ""))
		if required_native.has(kind):
			required_native[kind] = int(required_native[kind]) + 1
	var required_gpu := {"CAPTURE_SUBMITTED": 0, "SURFACE_PREPARED": 0, "ACTIVE": 0, "FIRST_DRAW": 0}
	for event_value in retained_lifecycle:
		var action := str(Dictionary(event_value).get("action", ""))
		if required_gpu.has(action):
			required_gpu[action] = int(required_gpu[action]) + 1
	result["native_event_counts"] = required_native
	result["gpu_event_counts"] = required_gpu
	_write_result(result)
	if _trace_enabled:
		for count in required_native.values():
			if int(count) <= 0:
				_fail("critical native timeline is incomplete: %s" % str(required_native))
				return
		for count in required_gpu.values():
			if int(count) <= 0:
				_fail("critical GPU timeline is incomplete: %s" % str(required_gpu))
				return
	print("GPU_INSTANT_CRITICAL_PATH_SMOKE_PASS edits=%d cold_us=%d native=%s gpu=%s" % [HOT_EDIT_COUNT, cold_ready_us, str(required_native), str(required_gpu)])
	_world.stop_backend_world()
	await _wait_for_state("stopped")
	quit(0)


func _wait_for_target(key: Vector3i, lod: int, revision: int, limit: int) -> bool:
	for _index in range(limit):
		await process_frame
		_observe_frame()
		var visual_ready := false
		for state_value in _world.get_debug_gpu_processing_states():
			var state := Dictionary(state_value)
			var identity := Dictionary(state.get("identity", {}))
			if str(state.get("stage", "")) == "visible" \
					and int(identity.get("page_x", -999)) == key.x \
					and int(identity.get("page_y", -999)) == key.y \
					and int(identity.get("page_z", -999)) == key.z \
					and int(identity.get("lod", -1)) == lod \
					and (revision < 0 or int(identity.get("world_revision", -1)) == revision):
				visual_ready = true
		var chunk_state: RefCounted = _world.query_chunk_state(key, lod)
		var collision_ready := chunk_state != null and bool(chunk_state.call("is_collision_ready"))
		if visual_ready and collision_ready and (revision < 0 or _world.get_world_revision() >= revision):
			return true
	return false


func _observe_frame() -> void:
	var now := Time.get_ticks_usec()
	var frame_us := now - _last_tick_us if _last_tick_us > 0 else 0
	_last_tick_us = now
	var runtime: Dictionary = _world.get_runtime_metrics()
	var gpu: Dictionary = _world.get_gpu_resident_render_status()
	var sample := {
		"phase": _phase,
		"ticks_usec": now,
		"frame_us": frame_us,
		"scheduler_queued": int(runtime.get("scheduler_queued_jobs", 0)),
		"storage_queued": int(runtime.get("storage_queued_requests", 0)),
		"mesh_active": int(runtime.get("mesh_worker_active_jobs", 0)),
		"mesh_queued": int(runtime.get("mesh_worker_queued_jobs", 0)),
		"gpu_oldest_inactive_age_frames": int(gpu.get("oldest_inactive_age_frames", 0)),
	}
	_frames.append(sample)
	for key in ["scheduler_queued", "storage_queued", "mesh_active", "mesh_queued", "gpu_oldest_inactive_age_frames"]:
		_maximum_queues[key] = maxi(int(_maximum_queues.get(key, 0)), int(sample[key]))


func _measurement_snapshot() -> Dictionary:
	var runtime: Dictionary = _world.get_runtime_metrics()
	var gpu: Dictionary = _world.get_gpu_resident_render_status()
	var effect: Dictionary = gpu.get("effect_status", {})
	var arena: Dictionary = effect.get("arena_status", {})
	return {
		"world_revision": _world.get_world_revision(),
		"edit_queried_chunks": int(runtime.get("edit_queried_chunks", 0)),
		"edit_replaced_chunks": int(runtime.get("edit_replaced_chunks", 0)),
		"mesh_prepare_time_ns_total": int(runtime.get("mesh_prepare_time_ns_total", 0)),
		"native_packed_bytes_total": int(effect.get("native_packed_bytes_total", 0)),
		"arena_uploaded_bytes": int(arena.get("uploaded_bytes", 0)),
		"arena_counter_readback_bytes": int(effect.get("arena_counter_readback_bytes", 0)),
		"geometry_readback_bytes": int(effect.get("geometry_readback_bytes", 0)),
		"counter_readback_bytes": int(effect.get("counter_readback_bytes", 0)),
		"draw_frames": int(effect.get("draw_frames", 0)),
		"indirect_draw_calls": int(effect.get("indirect_draw_calls", 0)),
	}


func _write_result(result: Dictionary) -> void:
	var absolute := ProjectSettings.globalize_path(OUTPUT_PATH)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(result, "  ") + "\n")
		file.close()


func _fail(message: String) -> void:
	push_error("GPU_INSTANT_CRITICAL_PATH_SMOKE_FAIL: " + message)
	quit(1)

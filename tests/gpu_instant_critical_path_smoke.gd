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
var _single_brick_edits := false


func _run() -> void:
	_trace_enabled = not OS.get_cmdline_user_args().has("--gpu-critical-path-trace-off")
	_single_brick_edits = OS.get_cmdline_user_args().has(
		"--gpu-critical-path-single-brick"
	)
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
	var visual_deadline_miss := {}
	_phase = "hot_edit"
	for index in range(HOT_EDIT_COUNT):
		var center := Vector3(
			2.5 + float(index % 3) * 0.25,
			2.5,
			2.5 + float(index / 3) * 0.25
		) if _single_brick_edits else Vector3(
			6.0 + float(index % 3) * 2.0,
			8.0,
			6.0 + float(index / 3) * 3.0
		)
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
		var first_draw_ticks_usec := _first_draw_ticks_usec(revision, Vector3i.ZERO, 0)
		if _trace_enabled and first_draw_ticks_usec <= 0:
			_fail("hot edit %d has no render-thread first-draw timestamp" % index)
			return
		var visual_first_draw_us := first_draw_ticks_usec - submitted_us \
			if first_draw_ticks_usec > 0 else -1
		if _trace_enabled and visual_first_draw_us > 33334:
			if visual_deadline_miss.is_empty():
				visual_deadline_miss = {
					"index": index,
					"visual_first_draw_us": visual_first_draw_us,
				}
		edits.append({
			"index": index,
			"revision": revision,
			"mode": "construct" if index % 2 == 0 else "dig",
			"submission_us": returned_us - submitted_us,
			"ready_us": Time.get_ticks_usec() - submitted_us,
			"ready_frames": _frames.size() - submitted_frame,
			"submitted_ticks_usec": submitted_us,
			"ready_ticks_usec": Time.get_ticks_usec(),
			"visual_first_draw_ticks_usec": first_draw_ticks_usec,
			"visual_first_draw_us": visual_first_draw_us,
		})
	# Allow the final independently published collision to release its completed
	# shared frontend marker; edit latency above is measured before this audit.
	var hot_metrics_after := _measurement_snapshot()
	var hot_detached := 0
	# This verifies eventual marker disposal after readiness was already measured;
	# loaded-edit latency and its two-frame visual gate are recorded above.
	for _audit_frame in range(32):
		hot_detached = int(hot_metrics_after.get(
			"completed_split_replacements_detached", 0
		)) - int(metrics_before.get("completed_split_replacements_detached", 0))
		if hot_detached >= HOT_EDIT_COUNT:
			break
		await process_frame
		_observe_frame()
		hot_metrics_after = _measurement_snapshot()
	var hot_regional_publications := int(hot_metrics_after.get(
		"regional_visibility_publications", 0
	)) - int(metrics_before.get("regional_visibility_publications", 0))
	var hot_same_callback_precommits := int(hot_metrics_after.get(
		"same_callback_edit_precommits", 0
	)) - int(metrics_before.get("same_callback_edit_precommits", 0))
	var hot_empty_collision_generations := int(hot_metrics_after.get(
		"empty_collision_generations", 0
	))
	var target_state: RefCounted = _world.query_chunk_state(Vector3i.ZERO, 0)
	var target_generations := {
		"application": target_state.call("get_generation"),
		"render": target_state.call("get_render_generation"),
		"staged_render": target_state.call("get_staged_render_generation"),
		"collision": target_state.call("get_collision_generation"),
		"staged_collision": target_state.call("get_staged_collision_generation"),
	} if target_state != null else {}
	var final_generation_exact := not target_generations.is_empty() \
			and int(target_generations["application"]) > 0 \
			and int(target_generations["render"]) == int(target_generations["application"]) \
			and int(target_generations["collision"]) == int(target_generations["application"]) \
			and int(target_generations["staged_render"]) == 0 \
			and int(target_generations["staged_collision"]) == 0
	if hot_same_callback_precommits != HOT_EDIT_COUNT \
			or hot_regional_publications != 0 \
			or int(hot_metrics_after.get("pending_chunk_replacements", -1)) != 0 \
			or not final_generation_exact:
		_fail("hot edits did not close split publication: precommits=%d detached=%d regional=%d empty_collision_generations=%d target=%s gpu_active=%d gpu_incomplete=%d effect_events=%d priority_events=%d budget_stops=%d" % [
			hot_same_callback_precommits, hot_detached, hot_regional_publications,
			hot_empty_collision_generations, str(target_generations),
			int(hot_metrics_after.get("gpu_active_chunks", 0)),
			int(hot_metrics_after.get("gpu_incomplete_chunks", 0)),
			int(hot_metrics_after.get("effect_event_count", 0)),
			int(hot_metrics_after.get("priority_event_count", 0)),
			int(hot_metrics_after.get("effect_event_budget_stops", 0)),
		])
		return

	_phase = "cold_approach"
	var cold_position := Vector3(104, 8, 8)
	var cold_key := Vector3i(6, 0, 0)
	var camera := root.get_camera_3d()
	if camera != null:
		camera.position = Vector3(104, 42, 82)
		camera.look_at(cold_position, Vector3.UP)
	var warm_before: Dictionary = _world.get_runtime_metrics()
	var warm_started_us := Time.get_ticks_usec()
	var warm_started_frame := _frames.size()
	var cold_warm_keys: Array[Vector3i] = []
	for z_offset in range(-1, 2):
		for y_offset in range(-1, 2):
			for x_offset in range(-1, 2):
				cold_warm_keys.append(
					cold_key + Vector3i(x_offset, y_offset, z_offset)
				)
	if not _world.update_foreground_priority_lease(9001, 1, 1, cold_warm_keys):
		_fail("cold approach interaction warm lease was rejected")
		return
	var warm_ready := false
	for _index in range(1200):
		await process_frame
		_observe_frame()
		var warm_now: Dictionary = _world.get_runtime_metrics()
		var warmed_count := (
			int(warm_now.get("interaction_warm_completions", 0))
			- int(warm_before.get("interaction_warm_completions", 0))
			+ int(warm_now.get("interaction_warm_cache_hits", 0))
			- int(warm_before.get("interaction_warm_cache_hits", 0))
		)
		if warmed_count >= cold_warm_keys.size():
			warm_ready = true
			break
	if not warm_ready:
		_fail("cold approach interaction page did not warm")
		return
	var warm_after: Dictionary = _world.get_runtime_metrics()
	if int(warm_after.get("interaction_warm_rejections", 0)) != int(
		warm_before.get("interaction_warm_rejections", 0)
	):
		_fail("cold approach interaction shell exceeded its reserved warm lane")
		return
	var cold_warm_settle_us := Time.get_ticks_usec() - warm_started_us
	var cold_warm_settle_frames := _frames.size() - warm_started_frame
	var cold_started_us := Time.get_ticks_usec()
	var cold_started_frame := _frames.size()
	if not _world.update_viewer(1, 2, cold_position, 1, 0) \
			or not _world.update_collision_viewer(2, 2, cold_position, 0):
		_fail("cold approach viewers were rejected")
		return
	if not await _wait_for_target(cold_key, 0, -1, 1200):
		_fail("cold approach target did not become ready")
		return
	var cold_ready_us := Time.get_ticks_usec() - cold_started_us
	var cold_ready_frames := _frames.size() - cold_started_frame
	if cold_ready_us > 100000:
		_fail("cached cold approach missed 100 ms readiness: %d us" % cold_ready_us)
		return
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
		"edit_layout": "single_brick" if _single_brick_edits else "cross_brick",
		"trace_started_ticks_usec": trace_started_us,
		"hot_edit_count": HOT_EDIT_COUNT,
		"hot_edits": edits,
		"hot_metrics_after": hot_metrics_after,
		"hot_same_callback_precommits": hot_same_callback_precommits,
		"hot_completed_split_replacements_detached": hot_detached,
		"hot_regional_visibility_publications": hot_regional_publications,
		"hot_empty_collision_generations": hot_empty_collision_generations,
		"cold_approach_ready_us": cold_ready_us,
		"cold_approach_ready_frames": cold_ready_frames,
		"cold_warm_settle_us": cold_warm_settle_us,
		"cold_warm_settle_frames": cold_warm_settle_frames,
		"cold_warm_key_count": cold_warm_keys.size(),
		"frames": _frames,
		"maximum_queues": _maximum_queues,
		"metrics_before": metrics_before,
		"metrics_after": metrics_after,
		"native_trace": native,
		"gpu_lifecycle": retained_lifecycle,
		"acceptance": {
			"submission_p99_target_us": 1000,
			"hot_visual_target_frames": 2,
			"hot_visual_target_us": 33334,
			"cold_cached_target_us": 100000,
		},
		"visual_deadline_miss": visual_deadline_miss,
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
	if not visual_deadline_miss.is_empty():
		_fail("hot edit %d missed two-frame visual publication: %d us" % [
			int(visual_deadline_miss["index"]),
			int(visual_deadline_miss["visual_first_draw_us"]),
		])
		return
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


func _first_draw_ticks_usec(revision: int, key: Vector3i, lod: int) -> int:
	var gpu_status: Dictionary = _world.get_gpu_resident_render_status()
	for event_value in Array(gpu_status.get("recent_lifecycle_events", [])):
		var event := Dictionary(event_value)
		if str(event.get("action", "")) != "FIRST_DRAW":
			continue
		var identity := Dictionary(event.get("identity", {}))
		if int(identity.get("world_revision", -1)) == revision \
				and int(identity.get("page_x", -999)) == key.x \
				and int(identity.get("page_y", -999)) == key.y \
				and int(identity.get("page_z", -999)) == key.z \
				and int(identity.get("lod", -1)) == lod:
			return int(event.get("effect_ticks_usec", event.get("ticks_usec", 0)))
	return 0


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
		"completed_split_replacements_detached": int(runtime.get(
			"completed_split_replacements_detached", 0
		)),
		"regional_visibility_publications": int(runtime.get(
			"regional_visibility_publications", 0
		)),
		"same_callback_edit_precommits": int(gpu.get(
			"same_callback_edit_precommits", 0
		)),
		"empty_collision_generations": int(runtime.get(
			"empty_collision_generations", 0
		)),
		"pending_chunk_replacements": int(runtime.get(
			"pending_chunk_replacements", 0
		)),
		"gpu_active_chunks": int(gpu.get("active_chunks", 0)),
		"gpu_incomplete_chunks": int(gpu.get("incomplete_chunks", 0)),
		"effect_event_budget_stops": int(gpu.get("effect_event_budget_stops", 0)),
		"effect_event_count": int(effect.get("event_count", 0)),
		"priority_event_count": int(effect.get("priority_event_count", 0)),
		"edit_queried_chunks": int(runtime.get("edit_queried_chunks", 0)),
		"edit_replaced_chunks": int(runtime.get("edit_replaced_chunks", 0)),
		"mesh_prepare_time_ns_total": int(runtime.get("mesh_prepare_time_ns_total", 0)),
		"native_packed_bytes_total": int(effect.get("native_packed_bytes_total", 0)),
		"arena_uploaded_bytes": int(arena.get("uploaded_bytes", 0)),
		"arena_counter_readback_bytes": int(effect.get("arena_counter_readback_bytes", 0)),
		"geometry_readback_bytes": int(effect.get("geometry_readback_bytes", 0)),
		"counter_readback_bytes": int(effect.get("counter_readback_bytes", 0)),
		"interaction_warm_requests": int(runtime.get("interaction_warm_requests", 0)),
		"interaction_warm_admissions": int(runtime.get("interaction_warm_admissions", 0)),
		"interaction_warm_coalesced": int(runtime.get("interaction_warm_coalesced", 0)),
		"interaction_warm_cache_hits": int(runtime.get("interaction_warm_cache_hits", 0)),
		"interaction_warm_completions": int(runtime.get("interaction_warm_completions", 0)),
		"interaction_warm_rejections": int(runtime.get("interaction_warm_rejections", 0)),
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

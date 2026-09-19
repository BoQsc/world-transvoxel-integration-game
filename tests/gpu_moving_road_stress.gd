extends "res://tests/gpu_resident_multichunk_relocation_smoke.gd"

const EditOperation := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd")
const EditBatch := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd")
const MaterialProfile := preload("res://addons/world_transvoxel_terrain/material/wt_terrain_material_profile.gd")
const ReferenceScene := preload("res://addons/world_transvoxel_terrain/debug/wt_terrain_reference_scene.gd")
const GameMaterialApplicator := preload("res://addons/world_transvoxel_gameworld/material/wt_game_terrain_material_applicator.gd")
const OUTPUT_PATH := "res://.godot/world_transvoxel_captures/gpu_moving_road_stress/result.json"
const STRESS_CAPTURE_ROOT := "res://.godot/world_transvoxel_captures/gpu_moving_road_stress"
const FRAMES_PER_WAYPOINT := 4
const OUTBOUND_WAYPOINTS := 12
const FRAME_TARGET_US := 16667

var _samples: Array[Dictionary] = []
var _phase := "startup"
var _last_ticks_usec := 0
var _current_target := Vector3i.ZERO
var _viewer_revision := 0
var _edit_attempts := 0
var _edit_submission_failures := 0
var _maximums := {}
var _reference_scene: Node
var _material_applicator: Node
var _target_activations: Array[Dictionary] = []
var _causal_trace_enabled := false
var _causal_trace_started_ticks_usec := 0
var _editing_enabled := true
var _largest_publication_inspection: Dictionary = {}
var _visual_lookahead_chunks := 3


func _setup_viewport() -> void:
	root.size = Vector2i(640, 480)
	root.content_scale_size = Vector2i(640, 480)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.02, 0.025, 0.03, 1.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.72, 0.76, 0.80)
	environment.ambient_light_energy = 0.55
	_world_environment = WorldEnvironment.new()
	_world_environment.environment = environment
	root.add_child(_world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, 35.0, 0.0)
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.light_energy = 1.25
	sun.shadow_enabled = false
	root.add_child(sun)
	var camera := Camera3D.new()
	camera.position = Vector3(8, 12, 28)
	root.add_child(camera)
	camera.look_at(Vector3(8, 8, 8), Vector3.UP)
	camera.current = true


func _run() -> void:
	_causal_trace_enabled = OS.get_environment("WT_GPU_MOVING_ROAD_TRACE") == "1"
	_editing_enabled = OS.get_environment("WT_GPU_MOVING_ROAD_EDITING") != "0"
	_visual_lookahead_chunks = clampi(int(OS.get_environment(
		"WT_GPU_MOVING_ROAD_VISUAL_LOOKAHEAD_CHUNKS"
	)) if OS.has_environment("WT_GPU_MOVING_ROAD_VISUAL_LOOKAHEAD_CHUNKS") else 3, 0, 8)
	_setup_viewport()
	_world = TerrainWorld.new()
	_world.terrain_profile = _terrain_profile()
	var runtime: Resource = RuntimeProfile.create_builtin(RuntimeProfile.Preset.BALANCED)
	runtime.profile_id = &"gpu_moving_road_stress"
	runtime.viewer_radius_chunks = 2
	runtime.maximum_lod = 2
	runtime.lod_refinement_radius_chunks = 1
	runtime.active_chunk_capacity = 384
	runtime.render_entry_capacity = 256
	runtime.mesh_entry_capacity = 256
	runtime.collision_entry_capacity = 128
	runtime.decoded_page_entry_capacity = 256
	runtime.procedural_generation_worker_count = clampi(int(OS.get_environment(
		"WT_GPU_MOVING_ROAD_STORAGE_WORKERS"
	)) if OS.has_environment("WT_GPU_MOVING_ROAD_STORAGE_WORKERS") else 2, 1, 8)
	runtime.meshing_worker_count = clampi(int(OS.get_environment(
		"WT_GPU_MOVING_ROAD_MESH_WORKERS"
	)) if OS.has_environment("WT_GPU_MOVING_ROAD_MESH_WORKERS") else 4, 1, 8)
	_world.runtime_profile = runtime
	var generation := _generation_profile()
	generation.profile_id = &"gpu_moving_road_stress"
	generation.source_revision = 640399
	generation.world_chunk_count_x = 16
	generation.world_chunk_count_y = 4
	generation.world_chunk_origin_y = 0
	generation.world_chunk_count_z = 6
	_world.generation_profile = generation
	_world.storage_profile = _storage_profile()
	_world.material_profile = MaterialProfile.new()
	_world.runtime_gpu_resident_render_candidate_enabled = true
	_world.runtime_gpu_resident_background_refinement_enabled = true
	_world.runtime_gpu_resident_viewer_refinement_enabled = true
	_world.runtime_gpu_meshing_shadow_capacity = 8
	_world.runtime_gpu_resident_request_capacity = 16
	_world.runtime_gpu_resident_chunk_capacity = 256
	_world.name = "TerrainWorld"
	_reference_scene = ReferenceScene.new()
	_reference_scene.name = "WtTerrainReferenceScene"
	_reference_scene.refresh_on_ready = false
	_reference_scene.add_child(_world)
	root.add_child(_reference_scene)
	_material_applicator = GameMaterialApplicator.new()
	_material_applicator.auto_apply = false
	_material_applicator.reference_scene_path = NodePath("../WtTerrainReferenceScene")
	root.add_child(_material_applicator)
	if not _world.start_backend_world() or not await _wait_for_state("running"):
		_fail("world did not start")
		return
	var material_summary: Dictionary = _material_applicator.apply_materials_now()
	if not bool(material_summary.get("native_render_material_override", false)) or not bool(material_summary.get("production_texture_active", false)):
		_fail("production terrain material did not initialize: %s" % material_summary)
		return
	_world.set_debug_gpu_resident_lifecycle_history_enabled(
		OS.get_environment("WT_GPU_MOVING_ROAD_LIFECYCLE_HISTORY") == "1"
	)
	_world.set_debug_gpu_stage_timing_enabled(
		OS.get_environment("WT_GPU_MOVING_ROAD_STAGE_TIMING") == "1"
	)
	_last_ticks_usec = Time.get_ticks_usec()
	var road := _road_waypoints()
	if not await _move_viewers(road[0]):
		return
	if not await _settle(1200):
		_fail("initial road shell did not settle: %s" % JSON.stringify(
			_settle_failure_summary()
		))
		return
	# Keep the native trace to a deterministic two-edit window. A full moving
	# route legitimately emits more lifecycle events than the bounded native
	# trace buffer and used to turn this diagnostic mode into a runtime failure.
	var causal_trace: Dictionary = {}
	var metrics_before := _snapshot_metrics()
	_phase = "cold_outbound_editing"
	for index in range(road.size()):
		if not await _move_viewers(road[index]):
			return
		for local_frame in range(FRAMES_PER_WAYPOINT):
			if _causal_trace_enabled and index == 1 and local_frame == 0:
				if not _world.begin_cpu_causal_trace():
					_fail("native causal trace did not start")
					return
				_causal_trace_started_ticks_usec = Time.get_ticks_usec()
			if _editing_enabled and local_frame == 0 and index > 0:
				_submit_moving_edit(road[index], index)
			if _editing_enabled and index == 6 and local_frame == 1:
				_submit_burst_edit(road[index])
			await process_frame
			_observe_frame()
			if _causal_trace_enabled and index == 2 and \
					local_frame == FRAMES_PER_WAYPOINT - 1:
				_world.end_cpu_causal_trace()
				causal_trace = _world.get_cpu_causal_trace_events(0, 65536)
	await _capture("cold_outbound")
	_phase = "cold_outbound_settle"
	var outbound_settle_started := Time.get_ticks_usec()
	var outbound_settle_frames := await _settle_count(300)
	var outbound_settle_us := Time.get_ticks_usec() - outbound_settle_started
	var outbound_metrics := _snapshot_metrics()
	_phase = "cached_return"
	for reverse_index in range(road.size() - 1, -1, -1):
		if not await _move_viewers(road[reverse_index]):
			return
		for _local_frame in range(FRAMES_PER_WAYPOINT):
			await process_frame
			_observe_frame()
	await _capture("cached_return")
	_phase = "cached_return_settle"
	var return_settle_started := Time.get_ticks_usec()
	var return_settle_frames := await _settle_count(1200)
	var return_settle_us := Time.get_ticks_usec() - return_settle_started
	var final_metrics := _snapshot_metrics()
	var frame_times: Array[int] = []
	var outbound_frames: Array[int] = []
	var return_frames: Array[int] = []
	var coverage_gap_frames := 0
	var collision_pending_frames := 0
	var coverage_activation_frames: Array[int] = []
	var lod0_activation_frames: Array[int] = []
	var collision_activation_frames: Array[int] = []
	for sample in _samples:
		var frame_us := int(sample.frame_us)
		if frame_us > 0:
			frame_times.append(frame_us)
			if sample.phase == "cold_outbound_editing": outbound_frames.append(frame_us)
			if sample.phase == "cached_return": return_frames.append(frame_us)
		if sample.phase in ["cold_outbound_editing", "cached_return"]:
			coverage_gap_frames += 0 if bool(sample.visual_coverage) else 1
			collision_pending_frames += 0 if bool(sample.collision_ready) else 1
	var unresolved_coverage_targets := 0
	var unresolved_lod0_targets := 0
	var unresolved_collision_targets := 0
	for activation in _target_activations:
		if activation.coverage_ready_frame == null:
			unresolved_coverage_targets += 1
		else:
			coverage_activation_frames.append(int(activation.coverage_ready_frame))
		if activation.lod0_ready_frame == null:
			unresolved_lod0_targets += 1
		else:
			lod0_activation_frames.append(int(activation.lod0_ready_frame))
		if activation.collision_ready_frame == null:
			unresolved_collision_targets += 1
		else:
			collision_activation_frames.append(int(activation.collision_ready_frame))
	var edit_commits := int(final_metrics.runtime.get("edit_commits", 0)) - int(metrics_before.runtime.get("edit_commits", 0))
	var edit_rejections := int(final_metrics.runtime.get("edit_rejections", 0)) - int(metrics_before.runtime.get("edit_rejections", 0))
	var result := {
		"schema": "world_transvoxel.gpu_moving_road_stress.v2",
		"driver": RenderingServer.get_current_rendering_driver_name().to_lower(),
		"route": {
			"waypoints": road.size(),
			"frames_per_waypoint": FRAMES_PER_WAYPOINT,
			"nominal_speed_world_units_per_second": 16.0 * 60.0 / FRAMES_PER_WAYPOINT,
			"cold_outbound": true,
			"cached_return": true,
		},
		"editing": {
			"enabled": _editing_enabled,
			"attempts": _edit_attempts,
			"submission_failures": _edit_submission_failures,
			"commits": edit_commits,
			"runtime_rejections": edit_rejections,
			"moving_interval_frames": FRAMES_PER_WAYPOINT,
			"burst_operations": 8,
		},
		"frames": {
			"count": frame_times.size(),
			"p50_us": _percentile(frame_times, 0.50),
			"p95_us": _percentile(frame_times, 0.95),
			"p99_us": _percentile(frame_times, 0.99),
			"maximum_us": frame_times.max() if not frame_times.is_empty() else 0,
			"outbound_p99_us": _percentile(outbound_frames, 0.99),
			"cached_return_p99_us": _percentile(return_frames, 0.99),
			"over_16_7ms": frame_times.filter(func(value: int) -> bool: return value > FRAME_TARGET_US).size(),
		},
		"seamlessness": {
			"visual_coverage_gap_frames": coverage_gap_frames,
			"collision_pending_frames": collision_pending_frames,
			"outbound_settle_frames": outbound_settle_frames,
			"outbound_settle_us": outbound_settle_us,
			"cached_return_settle_frames": return_settle_frames,
			"cached_return_settle_us": return_settle_us,
		},
		"target_activation": {
			"records": _target_activations,
			# Compatibility aliases retain the former hierarchical-coverage meaning.
			"visual_p99_frames": _percentile(coverage_activation_frames, 0.99),
			"coverage_p99_frames": _percentile(coverage_activation_frames, 0.99),
			"lod0_p99_frames": _percentile(lod0_activation_frames, 0.99),
			"collision_p99_frames": _percentile(collision_activation_frames, 0.99),
			"unresolved_visual_targets": unresolved_coverage_targets,
			"unresolved_coverage_targets": unresolved_coverage_targets,
			"unresolved_lod0_targets": unresolved_lod0_targets,
			"unresolved_collision_targets": unresolved_collision_targets,
		},
		"maximums": _maximums,
		"causal_trace_enabled": _causal_trace_enabled,
		"causal_trace_started_ticks_usec": _causal_trace_started_ticks_usec,
		"causal_trace": causal_trace,
		"largest_publication_inspection": _largest_publication_inspection,
		"metrics_before": metrics_before,
		"metrics_outbound": outbound_metrics,
		"metrics_final": final_metrics,
		"samples": _samples,
		"acceptance": {
			"trace_complete": not _samples.is_empty(),
			"no_submission_failures": _edit_submission_failures == 0,
			"all_accepted_edits_committed": edit_commits == _edit_attempts,
			"no_runtime_edit_rejections": edit_rejections == 0,
			"no_visual_coverage_gaps": coverage_gap_frames == 0,
			"no_collision_pending_frames": collision_pending_frames == 0,
			"all_targets_visually_resolved": unresolved_coverage_targets == 0,
			"all_targets_have_lod0": unresolved_lod0_targets == 0,
			"all_targets_collision_resolved": unresolved_collision_targets == 0,
			"visual_activation_within_2_frames": unresolved_coverage_targets == 0 and _percentile(coverage_activation_frames, 0.99) <= 2,
			"coverage_activation_within_2_frames": unresolved_coverage_targets == 0 and _percentile(coverage_activation_frames, 0.99) <= 2,
			"lod0_activation_within_2_frames": unresolved_lod0_targets == 0 and _percentile(lod0_activation_frames, 0.99) <= 2,
			"collision_activation_before_next_frame": unresolved_collision_targets == 0 and _percentile(collision_activation_frames, 0.99) <= 1,
			"no_geometry_readback": int(final_metrics.gpu.get("geometry_readback_bytes", -1)) == 0,
			"production_material_parity": bool(final_metrics.gpu.get("production_terrain_material_parity", false)),
			"frame_p95_target_us": 16667,
			"frame_p99_target_us": 25000,
			"frame_p95_pass": _percentile(frame_times, 0.95) <= 16667,
			"frame_p99_pass": _percentile(frame_times, 0.99) <= 25000,
		},
	}
	_write_result(result)
	if _samples.is_empty() or int(final_metrics.gpu.get("geometry_readback_bytes", -1)) != 0:
		_fail("measurement integrity failed")
		return
	print("GPU_MOVING_ROAD_STRESS_COMPLETE driver=%s edits=%d/%d rejected=%d coverage_gaps=%d collision_pending=%d coverage_p99_frames=%d lod0_p99_frames=%d frame_p95_us=%d frame_p99_us=%d outbound_settle_us=%d return_settle_us=%d" % [
		result.driver, edit_commits, _edit_attempts, edit_rejections,
		coverage_gap_frames, collision_pending_frames,
		int(result.target_activation.coverage_p99_frames),
		int(result.target_activation.lod0_p99_frames),
		int(result.frames.p95_us), int(result.frames.p99_us),
		outbound_settle_us, return_settle_us,
	])
	_world.stop_backend_world()
	await _wait_for_state("stopped")
	quit(0)


func _road_waypoints() -> Array[Vector3]:
	var result: Array[Vector3] = []
	for index in range(OUTBOUND_WAYPOINTS):
		result.append(Vector3(8.0 + float(index) * 16.0, 8.0, 24.0 + float((index % 4) - 2) * 4.0))
	return result


func _move_viewers(position: Vector3) -> bool:
	_viewer_revision += 1
	_current_target = Vector3i(floori(position.x / 16.0), 0, floori(position.z / 16.0))
	var prediction_direction := -1.0 if _phase == "cached_return" else 1.0
	var predictive_position := position + Vector3(
		16.0 * float(_visual_lookahead_chunks) * prediction_direction, 0.0, 0.0
	)
	var collision_predictive_position := position + Vector3(
		32.0 * prediction_direction, 0.0, 0.0
	)
	var camera := root.get_camera_3d()
	if camera != null:
		camera.position = position + Vector3(0, 28, 34)
		camera.look_at(position, Vector3.UP)
	var primary_visual_ok: bool = _world.update_viewer(
		1, _viewer_revision, position, 2, 2
	)
	var predictive_visual_ok: bool = _world.update_viewer(
		64, _viewer_revision, predictive_position, 1, 0
	)
	var primary_collision_ok: bool = _world.update_collision_viewer(
		2, _viewer_revision, position, 1
	)
	var predictive_collision_ok: bool = _world.update_collision_viewer(
		3, _viewer_revision, collision_predictive_position, 1
	)
	if not primary_visual_ok or not predictive_visual_ok \
			or not primary_collision_ok or not predictive_collision_ok:
		print("GPU_MOVING_ROAD_VIEWER_REJECTION_METRICS %s" % JSON.stringify(
			_world.get_runtime_metrics()
		))
		_fail("viewer update rejected at %s: visual=%s predictive_visual=%s collision=%s predictive_collision=%s" % [
			position, primary_visual_ok, predictive_visual_ok,
			primary_collision_ok, predictive_collision_ok,
		])
		return false
	# Only exact tool/ray centers define foreground visual topology. The support
	# shell below still reserves collision and storage priority around motion,
	# while native code owns the separate bounded prewarm halo. Expanding all
	# support cells into InteractionFocus here turns every waypoint into a large
	# LOD0 publication cohort and does not match the production game path.
	var focus_keys: Array = [_current_target]
	var support_keys: Array = []
	for z in range(_current_target.z - 1, _current_target.z + 2):
		for y in range(_current_target.y - 1, _current_target.y + 2):
			for x in range(_current_target.x - 1, _current_target.x + 2):
				var key := Vector3i(x, y, z)
				support_keys.append(key)
	var collision_predictive_target := Vector3i(
		floori(collision_predictive_position.x / 16.0),
		0,
		floori(collision_predictive_position.z / 16.0)
	)
	for z in range(collision_predictive_target.z - 1, collision_predictive_target.z + 2):
		for y in range(collision_predictive_target.y - 1, collision_predictive_target.y + 2):
			for x in range(collision_predictive_target.x - 1, collision_predictive_target.x + 2):
				var key := Vector3i(x, y, z)
				if not support_keys.has(key):
					support_keys.append(key)
	var predictive_target := Vector3i(
		floori(predictive_position.x / 16.0),
		0,
		floori(predictive_position.z / 16.0)
	)
	if not focus_keys.has(predictive_target):
		focus_keys.append(predictive_target)
	if not _world.update_foreground_priority_lease(
		9002, _viewer_revision, 0, support_keys
	) or not _world.update_foreground_priority_lease(
		9003, _viewer_revision, 1, focus_keys
	):
		_fail("interaction focus lease rejected at %s" % position)
		return false
	if _phase in ["cold_outbound_editing", "cached_return"]:
		_target_activations.append({
			"phase": _phase,
			"target": _current_target,
			"requested_ticks_usec": Time.get_ticks_usec(),
			"requested_sample_index": _samples.size(),
			"coverage_ready_frame": null,
			"coverage_ready_us": null,
			"lod0_ready_frame": null,
			"lod0_ready_us": null,
			# Compatibility alias for the former hierarchical-coverage field.
			"visual_ready_frame": null,
			"visual_ready_us": null,
			"collision_ready_frame": null,
			"collision_ready_us": null,
		})
	return true


func _submit_moving_edit(position: Vector3, index: int) -> void:
	var operation := EditOperation.new()
	operation.mode = EditOperation.Mode.CARVE if index % 2 == 0 else EditOperation.Mode.CONSTRUCT
	operation.brush_shape = EditOperation.BrushShape.SPHERE
	operation.center = position + Vector3(0, -0.5, 0)
	operation.radius = 2.5
	operation.material_id = 3
	operation.density_value = 1.0
	var batch := EditBatch.new()
	batch.add_operation(operation)
	_edit_attempts += 1
	if not _world.submit_edit_batch(batch, 9000 + _edit_attempts):
		_edit_submission_failures += 1


func _submit_burst_edit(position: Vector3) -> void:
	var batch := EditBatch.new()
	for index in range(8):
		var angle := TAU * float(index) / 8.0
		var operation := EditOperation.new()
		operation.mode = EditOperation.Mode.CARVE if index % 2 == 0 else EditOperation.Mode.CONSTRUCT
		operation.brush_shape = EditOperation.BrushShape.SPHERE
		operation.center = position + Vector3(cos(angle) * 5.0, -1.0, sin(angle) * 5.0)
		operation.radius = 2.75
		operation.material_id = 3
		operation.density_value = 1.0
		batch.add_operation(operation)
	_edit_attempts += 1
	if not _world.submit_edit_batch(batch, 9900):
		_edit_submission_failures += 1


func _observe_frame() -> void:
	var now := Time.get_ticks_usec()
	var runtime: Dictionary = _world.get_runtime_metrics()
	var gpu_status: Dictionary = _world.get_gpu_resident_render_status()
	var effect: Dictionary = gpu_status.get("effect_status", {})
	var arena: Dictionary = effect.get("arena_status", {})
	var state: RefCounted = _world.query_chunk_state(_current_target, 0)
	var collision_ready := _has_exact_collision(_current_target)
	var sample := {
		"phase": _phase,
		"ticks_usec": now,
		"frame_us": now - _last_ticks_usec,
		"target": _current_target,
		"visual_coverage": _has_visual_coverage(_current_target),
		"lod0_visual_ready": _has_exact_lod0_visual(_current_target),
		"collision_ready": collision_ready,
		"scheduler_queued": int(runtime.get("scheduler_queued_jobs", 0)),
		"storage_queued": int(runtime.get("storage_queued_requests", 0)),
		"storage_active": int(runtime.get("storage_active_requests", 0)),
		"mesh_queued": int(runtime.get("mesh_worker_queued_jobs", 0)),
		"mesh_active": int(runtime.get("mesh_worker_active_jobs", 0)),
		"pending_replacements": int(runtime.get("pending_chunk_replacements", 0)),
		"gpu_queued": int(effect.get("queued_request_count", 0)),
		"gpu_inflight": int(effect.get("inflight_extraction_count", 0)),
		"gpu_resident_entries": int(effect.get("resident_entry_count", 0)),
		"gpu_uploaded_bytes": int(arena.get("uploaded_bytes", 0)),
		"decoded_bytes": int(runtime.get("page_cache_decoded_resident_bytes", 0)),
		"render_bytes": int(runtime.get("resource_cache_render_resident_bytes", 0)),
		"collision_bytes": int(runtime.get("resource_cache_collision_resident_bytes", 0)),
	}
	if not bool(sample.visual_coverage) or not bool(sample.collision_ready):
		sample["target_diagnostic"] = _target_diagnostic(state)
	_last_ticks_usec = now
	_samples.append(sample)
	_update_target_activations(now)
	if not bool(sample.lod0_visual_ready) and _samples.size() % 8 == 0:
		_capture_largest_publication_inspection()
	for key in ["scheduler_queued", "storage_queued", "storage_active", "mesh_queued", "mesh_active", "pending_replacements", "gpu_queued", "gpu_inflight", "gpu_resident_entries", "gpu_uploaded_bytes", "decoded_bytes", "render_bytes", "collision_bytes"]:
		_maximums[key] = maxi(int(_maximums.get(key, 0)), int(sample[key]))


func _target_diagnostic(state: RefCounted) -> Dictionary:
	var result := {"record_present": state != null}
	if state != null:
		result.merge({
			"generation": int(state.call("get_generation")),
			"visual_required": bool(state.call("is_visual_required")),
			"visual_ready": bool(state.call("is_visual_ready")),
			"render_generation": int(state.call("get_render_generation")),
			"staged_render_generation": int(state.call("get_staged_render_generation")),
			"collision_required": bool(state.call("is_collision_required")),
			"collision_ready": bool(state.call("is_collision_ready")),
			"collision_generation": int(state.call("get_collision_generation")),
			"staged_collision_generation": int(state.call("get_staged_collision_generation")),
		})
	var backend: Node = _world.get_backend_terrain()
	if backend != null and backend.has_method("inspect_gpu_resident_publication"):
		result["publication"] = backend.call(
			"inspect_gpu_resident_publication", _current_target, 0
		)
	return result


func _capture_largest_publication_inspection() -> void:
	var backend: Node = _world.get_backend_terrain()
	if backend == null or not backend.has_method("inspect_gpu_resident_publication"):
		return
	var inspection: Dictionary = backend.call("inspect_gpu_resident_publication",
		_current_target, 0
	)
	var selected_count := Array(inspection.get("selected", [])).size()
	var largest_count := Array(
		_largest_publication_inspection.get("selected", [])
	).size()
	if selected_count > largest_count:
		inspection["phase"] = _phase
		inspection["target"] = _current_target
		inspection["sample_index"] = _samples.size()
		_largest_publication_inspection = inspection


func _update_target_activations(now: int) -> void:
	for activation in _target_activations:
		var key: Vector3i = activation.target
		var frame_latency := _samples.size() - int(activation.requested_sample_index)
		if activation.coverage_ready_frame == null and _has_visual_coverage(key):
			activation.coverage_ready_frame = frame_latency
			activation.coverage_ready_us = now - int(activation.requested_ticks_usec)
			activation.visual_ready_frame = frame_latency
			activation.visual_ready_us = now - int(activation.requested_ticks_usec)
		if activation.lod0_ready_frame == null and _has_exact_lod0_visual(key):
			activation.lod0_ready_frame = frame_latency
			activation.lod0_ready_us = now - int(activation.requested_ticks_usec)
		if activation.collision_ready_frame == null:
			if _has_exact_collision(key):
				activation.collision_ready_frame = frame_latency
				activation.collision_ready_us = now - int(activation.requested_ticks_usec)


func _has_visual_coverage(key: Vector3i) -> bool:
	for lod in range(0, 3):
		var scale := 1 << lod
		var ancestor := Vector3i(
			floori(float(key.x) / float(scale)),
			floori(float(key.y) / float(scale)),
			floori(float(key.z) / float(scale))
		)
		var state: RefCounted = _world.query_chunk_state(ancestor, lod)
		if state != null:
			# A superseded draw remains valid spatial coverage until its atomic
			# replacement publishes. A ready zero-generation record is a proven
			# empty chunk and also supplies complete coverage.
			if int(state.call("get_render_generation")) > 0:
				return true
			if bool(state.call("is_visual_ready")) and \
					int(state.call("get_staged_render_generation")) == 0:
				return true
	return false


func _has_exact_collision(key: Vector3i) -> bool:
	var state: RefCounted = _world.query_chunk_state(key, 0)
	if state == null or not bool(state.call("is_collision_ready")):
		return false
	var generation := int(state.call("get_generation"))
	return generation > 0 and \
		int(state.call("get_collision_generation")) == generation


func _has_exact_lod0_visual(key: Vector3i) -> bool:
	var state: RefCounted = _world.query_chunk_state(key, 0)
	if state == null or not bool(state.call("is_visual_ready")):
		return false
	var generation := int(state.call("get_generation"))
	return generation > 0 and \
		int(state.call("get_render_generation")) == generation and \
		int(state.call("get_staged_render_generation")) == 0


func _settle(limit: int) -> bool:
	return await _settle_count(limit) >= 0


func _settle_count(limit: int) -> int:
	for frame in range(limit):
		await process_frame
		_observe_frame()
		var runtime: Dictionary = _world.get_runtime_metrics()
		var gpu: Dictionary = _world.get_gpu_resident_render_status()
		var effect: Dictionary = gpu.get("effect_status", {})
		if int(runtime.get("scheduler_queued_jobs", 0)) == 0 and int(runtime.get("storage_queued_requests", 0)) == 0 and int(runtime.get("storage_active_requests", 0)) == 0 and int(runtime.get("mesh_worker_queued_jobs", 0)) == 0 and int(runtime.get("mesh_worker_active_jobs", 0)) == 0 and int(runtime.get("pending_chunk_replacements", 0)) == 0 and int(runtime.get("pending_chunk_retirements", 0)) == 0 and int(runtime.get("collision_required_not_ready_chunk_records", 0)) == 0 and int(effect.get("queued_request_count", 0)) == 0 and int(effect.get("inflight_extraction_count", 0)) == 0:
			return frame + 1
	return -1


func _snapshot_metrics() -> Dictionary:
	var runtime: Dictionary = _world.get_runtime_metrics()
	var status: Dictionary = _world.get_gpu_resident_render_status()
	var effect: Dictionary = status.get("effect_status", {})
	return {"runtime": runtime, "gpu": effect, "resident": status}


func _settle_failure_summary() -> Dictionary:
	var snapshot := _snapshot_metrics()
	var runtime: Dictionary = snapshot.runtime
	var resident: Dictionary = snapshot.resident
	var effect: Dictionary = snapshot.gpu
	var wait: Dictionary = resident.get("last_activation_cohort_wait", {})
	return {
		"scheduler": int(runtime.get("scheduler_queued_jobs", 0)),
		"storage": [int(runtime.get("storage_queued_requests", 0)), int(runtime.get("storage_active_requests", 0))],
		"mesh": [int(runtime.get("mesh_worker_queued_jobs", 0)), int(runtime.get("mesh_worker_active_jobs", 0))],
		"pending_replacements": int(runtime.get("pending_chunk_replacements", 0)),
		"pending_retirements": int(runtime.get("pending_chunk_retirements", 0)),
		"collision_not_ready": int(runtime.get("collision_required_not_ready_chunk_records", 0)),
		"gpu": {
			"queued": int(effect.get("queued_request_count", 0)),
			"inflight": int(effect.get("inflight_extraction_count", 0)),
			"resident": int(effect.get("resident_entry_count", 0)),
		},
		"controller": {
			"tracked": int(resident.get("tracked_chunks", 0)),
			"active": int(resident.get("active_chunks", 0)),
			"prepared_inactive": int(resident.get("prepared_inactive_chunks", 0)),
			"incomplete": int(resident.get("incomplete_chunks", 0)),
		},
		"activation_wait": {
			"status": str(wait.get("status", "")),
			"error": str(wait.get("error", "")),
			"replacements": int(wait.get("replacement_count", 0)),
			"retirements": int(wait.get("retirement_count", 0)),
			"waiting_member": wait.get("waiting_member", {}),
			"record_present": bool(wait.get("waiting_member_record_present", false)),
			"route_present": bool(wait.get("waiting_member_group_present", false)),
		},
	}


func _percentile(values: Array[int], fraction: float) -> int:
	if values.is_empty(): return 0
	var ordered := values.duplicate()
	ordered.sort()
	return ordered[clampi(ceili(float(ordered.size()) * fraction) - 1, 0, ordered.size() - 1)]


func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var absolute_root := ProjectSettings.globalize_path(STRESS_CAPTURE_ROOT)
	DirAccess.make_dir_recursive_absolute(absolute_root)
	root.get_texture().get_image().save_png(absolute_root.path_join("%s_%s.png" % [RenderingServer.get_current_rendering_driver_name().to_lower(), label]))


func _write_result(result: Dictionary) -> void:
	var absolute := ProjectSettings.globalize_path(OUTPUT_PATH)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(result, "  ") + "\n")
		file.close()


func _fail(message: String) -> void:
	push_error("GPU_MOVING_ROAD_STRESS_FAIL: " + message)
	if _world != null: _world.stop_backend_world()
	quit(1)

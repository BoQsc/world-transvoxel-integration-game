extends "res://tests/gpu_resident_multichunk_relocation_smoke.gd"

const EditOperation := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd")
const EditBatch := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd")

func _run() -> void:
	_setup_viewport()
	_world = TerrainWorld.new()
	_world.terrain_profile = _terrain_profile()
	_world.runtime_profile = _runtime_profile()
	var generation: Resource = _generation_profile()
	generation.world_chunk_count_y = 4
	_world.generation_profile = generation
	_world.storage_profile = _storage_profile()
	_world.runtime_gpu_resident_render_candidate_enabled = true
	# Require the first edited surface at the interaction point to remain LOD0.
	_world.runtime_gpu_resident_background_refinement_enabled = false
	_world.runtime_gpu_resident_viewer_refinement_enabled = true
	_world.runtime_gpu_resident_chunk_capacity = 256
	root.add_child(_world)
	if not _world.start_backend_world() or not await _wait_for_state("running"):
		_fail("first edit world did not start")
		return
	if not _world.update_viewer(1, 1, Vector3(8, 8, 8), 1, 2):
		_fail("first edit viewer rejected")
		return
	var edit_center := Vector3(56, 8, 56)
	# Warm one region, then relocate to an edge chunk with a different transition
	# capacity class. This reproduces the human fly-then-edit path.
	var initial_visible := false
	for _frame in range(900):
		await process_frame
		if int(_world.get_gpu_resident_render_status().get("active_chunks", 0)) > 0:
			initial_visible = true
			break
	if not initial_visible:
		_fail("first edit fixture never published its warm-up coverage")
		return
	if not _world.update_viewer(1, 2, edit_center, 1, 2):
		_fail("relocated first edit viewer rejected")
		return
	var full_resolution_ready := false
	for _frame in range(900):
		await process_frame
		for state_value in _world.get_debug_gpu_processing_states():
			var state := Dictionary(state_value)
			var identity := Dictionary(state.get("identity", {}))
			if state.get("stage", "") == "visible" and int(identity.get("lod", -1)) == 0 and int(identity.get("page_x", -1)) == 3 and int(identity.get("page_y", -1)) == 0 and int(identity.get("page_z", -1)) == 3:
				full_resolution_ready = true
		if full_resolution_ready:
			break
	if not full_resolution_ready:
		var nearby_states: Array = []
		for state_value in _world.get_debug_gpu_processing_states():
			var state := Dictionary(state_value)
			var identity := Dictionary(state.get("identity", {}))
			if absi(int(identity.get("page_x", -99)) - 3) <= 1 \
					and absi(int(identity.get("page_y", -99))) <= 1 \
					and absi(int(identity.get("page_z", -99)) - 3) <= 1:
				nearby_states.append(state)
		print("GPU_RESIDENT_FULL_QUALITY_EDIT_STARTUP_DIAGNOSTIC " + JSON.stringify({
			"nearby_states": nearby_states,
			"render_status": _world.get_gpu_resident_render_status(),
			"runtime_metrics": _world.get_runtime_metrics(),
		}))
		_fail("first edit fixture did not provide full-resolution interaction coverage")
		return
	var operation := EditOperation.new()
	var prepare_before := int(_world.get_runtime_metrics().get("mesh_prepare_time_ns_total", 0))
	operation.mode = EditOperation.Mode.CONSTRUCT
	operation.brush_shape = EditOperation.BrushShape.SPHERE
	operation.center = edit_center
	operation.radius = 4.0
	operation.material_id = 3
	operation.density_value = 1.0
	var batch := EditBatch.new()
	batch.add_operation(operation)
	var submitted_us := Time.get_ticks_usec()
	var stage_first_seen := {}
	if not _world.submit_edit_batch(batch, 6601):
		_fail("first edit rejected")
		return
	var commit_frame := -1
	var first_visual_frame := -1
	var first_visual_lod := -1
	var prepare_at_feedback := 0
	for frame in range(900):
		await process_frame
		if commit_frame < 0 and _world.get_world_revision() == 1:
			commit_frame = frame
			stage_first_seen["committed"] = {"frame": frame, "elapsed_us": Time.get_ticks_usec() - submitted_us}
		for state_value in _world.get_debug_gpu_processing_states():
			var state := Dictionary(state_value)
			var identity := Dictionary(state.get("identity", {}))
			if int(identity.get("world_revision", 0)) == 1:
				var stage := str(state.get("stage", "unknown"))
				if not stage_first_seen.has(stage):
					stage_first_seen[stage] = {"frame": frame, "elapsed_us": Time.get_ticks_usec() - submitted_us}
			if state.get("stage", "") == "visible" and int(identity.get("world_revision", 0)) == 1:
				var minimum: Vector3 = state.get("bounds_min", Vector3.INF)
				var maximum: Vector3 = state.get("bounds_max", -Vector3.INF)
				if minimum.x <= edit_center.x and minimum.y <= edit_center.y \
						and minimum.z <= edit_center.z and maximum.x >= edit_center.x \
						and maximum.y >= edit_center.y and maximum.z >= edit_center.z:
					first_visual_frame = frame
					first_visual_lod = int(identity.get("lod", -1))
		if first_visual_frame >= 0:
			prepare_at_feedback = int(_world.get_runtime_metrics().get("mesh_prepare_time_ns_total", 0)) - prepare_before
			break
	if commit_frame < 0 or first_visual_frame < 0 or first_visual_lod != 0:
		_fail("first edit did not publish full-quality feedback: commit=%d visual=%d lod=%d" % [commit_frame, first_visual_frame, first_visual_lod])
		return
	var activation_display_frame := int(Dictionary(stage_first_seen.get(
		"activation_queued", {}
	)).get("frame", -1))
	if activation_display_frame < 0 or activation_display_frame - commit_frame > 2:
		_fail("relocated edit missed the two-display-frame activation bound: commit=%d activation=%d" % [
			commit_frame, activation_display_frame,
		])
		return
	print("GPU_RESIDENT_FULL_QUALITY_EDIT_TIMELINE " + JSON.stringify(stage_first_seen))
	var refined := false
	for _frame in range(900):
		await process_frame
		for state_value in _world.get_debug_gpu_processing_states():
			var state := Dictionary(state_value)
			var identity := Dictionary(state.get("identity", {}))
			if state.get("stage", "") == "visible" and int(identity.get("world_revision", 0)) == 1 \
					and int(identity.get("lod", -1)) == 0 and int(identity.get("page_x", -1)) == 3 \
					and int(identity.get("page_y", -1)) == 0 and int(identity.get("page_z", -1)) == 3:
				refined = true
		if refined:
			break
	if not refined:
		_fail("first edit content published but refinement stopped")
		return
	var first_draws: Array = _world.get_gpu_resident_render_status().get(
		"recent_incremental_first_draws", []
	)
	if first_draws.is_empty():
		_fail("incremental first draw was not retained for self-reporting")
		return
	print("GPU_RESIDENT_FULL_QUALITY_EDIT_SMOKE_PASS commit=%d display_activation_after_commit=%d controller_visible_after_commit=%d first_lod=%d refined=1 prepare_until_feedback_us=%d" % [commit_frame, activation_display_frame - commit_frame, first_visual_frame - commit_frame, first_visual_lod, prepare_at_feedback / 1000])
	_world.stop_backend_world()
	await _wait_for_state("stopped")
	quit(0)

func _fail(message: String) -> void:
	push_error("GPU_RESIDENT_FULL_QUALITY_EDIT_SMOKE_FAIL: " + message)
	quit(1)

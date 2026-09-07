extends "res://tests/gpu_resident_multichunk_relocation_smoke.gd"

const EditOperation := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd")
const EditBatch := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd")
var _checked_frames := 0
var _maximum_pending_retirements := 0

func _run() -> void:
	_setup_viewport()
	_world = TerrainWorld.new()
	_world.terrain_profile = _terrain_profile()
	_world.runtime_profile = _runtime_profile()
	_world.generation_profile = _generation_profile()
	_world.storage_profile = _storage_profile()
	_world.runtime_gpu_resident_render_candidate_enabled = true
	_world.runtime_gpu_meshing_shadow_capacity = 3
	_world.runtime_gpu_resident_chunk_capacity = 32
	root.add_child(_world)
	if not _world.start_backend_world() or not await _wait_for_state("running"):
		_fail("rapid edit world did not start")
		return
	if not _world.update_viewer(1, 1, Vector3(8, 8, 8), 1, 0) \
			or not _world.update_collision_viewer(2, 1, Vector3(8, 8, 8), 0) \
			or not await _wait_for_resident_state(2, 0):
		_fail("rapid edit initial chunks did not settle")
		return
	# Keep the edited pair loaded through viewer 1 while viewer 3 creates an
	# unrelated LOD retirement backlog. The edit cohort must not join it.
	if not _world.update_viewer(3, 1, Vector3(40, 8, 40), 1, 0):
		_fail("background viewer admission was rejected")
		return
	for _frame in range(180):
		await process_frame
	if not _world.update_viewer(3, 2, Vector3(56, 8, 56), 1, 0):
		_fail("background viewer relocation was rejected")
		return
	# Every brush straddles x=16, so both visible halves must have one revision.
	# Submit the next edit after commit, without waiting for visual completion.
	for revision in range(1, 13):
		var background_position := Vector3(40, 8, 40) \
			if revision % 2 == 0 else Vector3(56, 8, 56)
		if not _world.update_viewer(3, 2 + revision, background_position, 1, 0):
			_fail("background viewer churn was rejected")
			return
		var operation := EditOperation.new()
		operation.mode = EditOperation.Mode.CONSTRUCT if revision % 2 == 1 else EditOperation.Mode.CARVE
		operation.brush_shape = EditOperation.BrushShape.SPHERE
		operation.center = Vector3(16, 8, 8)
		operation.radius = 3.0 + float(revision % 3) * 0.25
		operation.material_id = 3
		operation.density_value = 1.0
		var batch := EditBatch.new()
		batch.add_operation(operation)
		if not _world.submit_edit_batch(batch, 6500 + revision):
			_fail("rapid edit submission rejected")
			return
		var committed := false
		for _frame in range(1200):
			await process_frame
			if not _check_edit_pair():
				return
			if _world.get_world_revision() == revision:
				committed = true
				break
		if not committed:
			_fail("rapid edit commit timed out")
			return
		for _frame in range(4):
			await process_frame
			if not _check_edit_pair():
				return
	var settled := false
	for _frame in range(2400):
		await process_frame
		if not _check_edit_pair():
			return
		if _visible_pair() == [12, 12]:
			settled = true
			break
	if not settled:
		_fail("rapid edit final revision did not become visible: %s" % str(_world.get_gpu_resident_render_status()))
		return
	var resident_status: Dictionary = _world.get_gpu_resident_render_status()
	var native_metrics: Dictionary = resident_status.get("native_metrics", {})
	var same_layout_cohorts := int(native_metrics.get(
		"same_layout_edit_activation_cohorts", 0
	))
	var same_layout_chunks := int(native_metrics.get(
		"same_layout_edit_activation_chunks", 0
	))
	var same_callback_precommits := int(resident_status.get(
		"same_callback_edit_precommits", 0
	))
	var retired_chunks := int(native_metrics.get("retired_chunks", 0))
	if same_layout_cohorts <= 0 or same_layout_chunks < 2 \
			or retired_chunks <= 0:
		_fail("rapid edit did not use the loaded same-layout cohort: %s" % str(native_metrics))
		return
	var effect_status: Dictionary = resident_status.get("effect_status", {})
	var arena_status: Dictionary = effect_status.get("arena_status", {})
	var readback_requests := int(arena_status.get("counter_readback_requests", 0))
	var readback_bytes := int(arena_status.get("counter_readback_bytes", -1))
	if int(arena_status.get("incremental_dispatch_count", 0)) <= 0 \
			or int(arena_status.get("incremental_copy_fallback_count", -1)) != 0 \
			or readback_bytes <= 0 \
			or readback_bytes % 20 != 0 \
			or readback_bytes > readback_requests * 20:
		_fail("rapid edit did not use incremental meshlets and 20-byte summaries: %s" % str(arena_status))
		return
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var capture := "res://.godot/world_transvoxel_captures/gpu_resident_rapid_edit"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(capture))
	image.save_png(capture.path_join(RenderingServer.get_current_rendering_driver_name() + ".png"))
	if not _world.stop_backend_world() or not await _wait_for_state("stopped"):
		_fail("rapid edit world did not stop")
		return
	print("GPU_RESIDENT_RAPID_EDIT_SMOKE_PASS edits=12 checked_frames=%d mixed_revisions=0 same_layout_cohorts=%d same_layout_chunks=%d same_callback_precommits=%d maximum_pending_retirements=%d retired_chunks=%d incremental_dispatches=%d copy_fallbacks=0 regenerated_cells=%d last_upload_bytes=%d readback_bytes=%d" % [
		_checked_frames,
		same_layout_cohorts,
		same_layout_chunks,
		same_callback_precommits,
		_maximum_pending_retirements,
		retired_chunks,
		int(arena_status.get("incremental_dispatch_count", 0)),
		int(arena_status.get("regenerated_cell_count", 0)),
		int(arena_status.get("last_dispatch_uploaded_bytes", 0)),
		int(arena_status.get("counter_readback_bytes", 0)),
	])
	quit(0)

func _visible_pair() -> Array:
	var revisions := [-1, -1]
	for state_value in _world.get_debug_gpu_processing_states():
		var state := Dictionary(state_value)
		if state.get("stage", "") != "visible":
			continue
		var identity := Dictionary(state.get("identity", {}))
		var x := int(identity.get("page_x", -1))
		if x in [0, 1] and int(identity.get("page_y", -1)) == 0 \
				and int(identity.get("page_z", -1)) == 0 and int(identity.get("lod", -1)) == 0:
			revisions[x] = int(identity.get("world_revision", -1))
	return revisions

func _check_edit_pair() -> bool:
	_checked_frames += 1
	_maximum_pending_retirements = maxi(
		_maximum_pending_retirements,
		int(_world.get_runtime_metrics().get("pending_chunk_retirements", 0))
	)
	var revisions := _visible_pair()
	if revisions[0] < 0 or revisions[0] != revisions[1]:
		_fail("rapid edit exposed mixed visible revisions: %s frame=%d" % [str(revisions), _checked_frames])
		return false
	return true

func _fail(message: String) -> void:
	push_error("GPU_RESIDENT_RAPID_EDIT_SMOKE_FAIL: " + message)
	quit(1)

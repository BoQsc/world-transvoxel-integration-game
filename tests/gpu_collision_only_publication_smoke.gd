extends "res://tests/gpu_resident_production_visual_parity_smoke.gd"


func _run() -> void:
	Engine.max_fps = 120
	_setup_viewport()
	_setup_world()
	_world.runtime_viewer_capacity = 2
	# A full relocation retains the old inventory until its replacement is ready.
	_world.runtime_gpu_resident_chunk_capacity = 256
	if not _world.start_backend_world() or not await _wait_for_state("running"):
		_fail("collision-only publication world did not start")
		return
	var backend: Node = _world.get_backend_terrain()
	if not _world.update_viewer(1, 1, Vector3(24, 30, 24), 2, 2) \
			or not await _wait_for_complete_lod_inventory():
		_fail("initial visual inventory did not settle")
		return
	if not _world.update_collision_viewer(2, 1, Vector3(24, 24, 24), 1) \
			or not _world.update_viewer(1, 2, Vector3(152, 30, 24), 2, 2):
		_fail("mixed visual and collision demand was rejected")
		return
	var observed_exclusions := {}
	var observed_overlap := false
	var shared_peak := 0
	# Inspect real shared staging records during a retained-parent replacement.
	for _frame in range(600):
		await process_frame
		var snapshot: Dictionary = backend.call(
			"inspect_gpu_resident_publication", Vector3i(1, 1, 1), 0
		)
		if int(snapshot.get("open_viewer_plan_publications", 1)) != 0:
			continue
		if not snapshot.has("visual_candidates"):
			_fail("native inspection lacks the exact visual candidate inventory")
			return
		var visual: Array = snapshot.visual_candidates
		var shared: Array = Array(snapshot.pending_replacements) + Array(snapshot.ready_replacements)
		shared_peak = maxi(shared_peak, shared.size())
		for value in shared:
			var key: Dictionary = value
			var coordinate := Vector3i(key.page_x, key.page_y, key.page_z)
			var state: RefCounted = _world.query_chunk_state(coordinate, key.lod)
			if state == null or not state.call("is_present"):
				continue
			if not state.call("is_visual_required"):
				if visual.has(key):
					_fail("collision-only record admitted to visual coverage: %s" % str(key))
					return
				observed_exclusions[str(key)] = true
				for parent in visual:
					if int(parent.lod) <= int(key.lod):
						continue
					var scale := float(1 << (int(parent.lod) - int(key.lod)))
					if Vector3i((Vector3(coordinate) / scale).floor()) == \
							Vector3i(parent.page_x, parent.page_y, parent.page_z):
						observed_overlap = true
			elif not visual.has(key):
				_fail("required visual candidate was filtered out: %s" % str(key))
				return
		if observed_overlap:
			break
	if not observed_overlap:
		_fail("fixture did not exercise overlapping collision-only publication: shared_peak=%d exclusions=%s" \
			% [shared_peak, str(observed_exclusions)])
		return
	if not await _wait_collision_publication_idle():
		_fail("collision-only demand prevented visual inventory from draining: idle=%s wait=%s metrics=%s" % [
			str(_world.get_cold_idle_summary()),
			str(_world.get_gpu_resident_render_status().get("last_activation_cohort_wait", {})),
			str(_world.get_runtime_metrics())])
		return
	var status: Dictionary = _world.get_gpu_resident_render_status()
	var audit: Dictionary = LodAudit.collect(_world)
	if int(status.get("application_wait_expirations", -1)) != 0 \
			or int(status.get("rejected_chunks", -1)) != 0 \
			or str(audit.get("status", "")) != "PASS" \
			or int(audit.get("coverage_overlap_count", -1)) != 0:
		_fail("mixed visual/collision publication failed: %s %s" % [str(status), str(audit)])
		return
	_world.end_gpu_resident_render_publication()
	if not _world.stop_backend_world() or not await _wait_for_state("stopped"):
		_fail("collision-only publication world did not stop")
		return
	_reference_scene.queue_free()
	_material_applicator.queue_free()
	await process_frame
	print("GPU_COLLISION_ONLY_PUBLICATION_PASS exclusions=%d parent_overlap=1 visual_preserved=1 drained=1" \
		% observed_exclusions.size())
	quit(0)


func _wait_collision_publication_idle() -> bool:
	for _frame in range(900):
		var idle: Dictionary = _world.get_cold_idle_summary()
		var status: Dictionary = _world.get_gpu_resident_render_status()
		if bool(idle.get("cold_idle", false)) and int(status.get("rejected_chunks", -1)) == 0 \
				and int(status.get("active_chunks", -1)) == \
				int(Dictionary(status.get("effect_status", {})).get("active_entry_count", -2)):
			return true
		await process_frame
	return false


func _fail(message: String) -> void:
	if _world != null:
		_world.end_gpu_resident_render_publication()
		_world.stop_backend_world()
		await _wait_for_state("stopped")
	push_error("GPU_COLLISION_ONLY_PUBLICATION_FAIL: " + message)
	quit(1)

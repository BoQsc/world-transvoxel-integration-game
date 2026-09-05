extends "res://tests/gpu_resident_multichunk_relocation_smoke.gd"

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
	_world.runtime_gpu_resident_chunk_capacity = 256
	root.add_child(_world)
	if not _world.start_backend_world() or not await _wait_for_state("running"):
		_fail("automatic LOD world did not start")
		return
	var revision := 0
	for position in [Vector3(8, 8, 8), Vector3(56, 8, 56), Vector3(8, 8, 8)]:
		revision += 1
		if not _world.update_viewer(1, revision, position, 1, 2):
			_fail("automatic LOD viewer rejected")
			return
		var ready_frame := -1
		for frame in range(300):
			await process_frame
			for value in _world.get_debug_gpu_processing_states():
				var state := Dictionary(value)
				var identity := Dictionary(state.get("identity", {}))
				if state.get("stage", "") == "visible" and int(identity.get("lod", -1)) == 0 \
						and int(identity.get("page_x", -1)) == int(position.x / 16) \
						and int(identity.get("page_y", -1)) == int(position.y / 16) \
						and int(identity.get("page_z", -1)) == int(position.z / 16):
					ready_frame = frame
			if ready_frame >= 0:
				break
		if ready_frame < 0:
			_fail("viewer %d never refined without an edit" % revision)
			return
		print("GPU_RESIDENT_AUTOMATIC_LOD_STEP viewer=%d ready_frames=%d" % [revision, ready_frame])
	if _world.get_world_revision() != 0:
		_fail("fixture unexpectedly edited terrain")
		return
	_world.stop_backend_world()
	await _wait_for_state("stopped")
	print("GPU_RESIDENT_AUTOMATIC_LOD_SMOKE_PASS edits=0 relocations=2")
	quit(0)

func _fail(message: String) -> void:
	push_error("GPU_RESIDENT_AUTOMATIC_LOD_SMOKE_FAIL: " + message)
	quit(1)

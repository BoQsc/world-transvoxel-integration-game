extends "res://tests/gpu_moving_road_stress.gd"

const RapidEditOperation := preload(
	"res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd"
)
const RapidEditBatch := preload(
	"res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd"
)


func _run() -> void:
	_setup_viewport()
	_world = TerrainWorld.new()
	_world.terrain_profile = _terrain_profile()
	var runtime: Resource = RuntimeProfile.create_builtin(RuntimeProfile.Preset.BALANCED)
	runtime.viewer_radius_chunks = 1
	runtime.maximum_lod = 0
	runtime.lod_refinement_radius_chunks = 1
	runtime.active_chunk_capacity = 128
	runtime.render_entry_capacity = 96
	runtime.mesh_entry_capacity = 96
	runtime.collision_entry_capacity = 64
	runtime.decoded_page_entry_capacity = 96
	runtime.procedural_generation_worker_count = 2
	runtime.meshing_worker_count = 4
	_world.runtime_profile = runtime
	var generation := _generation_profile()
	generation.world_chunk_count_x = 4
	generation.world_chunk_count_y = 2
	generation.world_chunk_count_z = 4
	_world.generation_profile = generation
	_world.storage_profile = _storage_profile()
	_world.material_profile = MaterialProfile.new()
	_world.runtime_gpu_resident_render_candidate_enabled = true
	_world.runtime_gpu_meshing_shadow_capacity = 8
	_world.runtime_gpu_resident_request_capacity = 16
	_world.runtime_gpu_resident_chunk_capacity = 96
	_reference_scene = ReferenceScene.new()
	_reference_scene.refresh_on_ready = false
	_reference_scene.add_child(_world)
	root.add_child(_reference_scene)
	if not _world.start_backend_world() or not await _wait_for_state("running"):
		_fail("rapid collision world did not start")
		return
	var center := Vector3(8.0, 8.0, 8.0)
	if not _world.update_viewer(1, 1, center, 1, 0) or not \
			_world.update_collision_viewer(2, 1, center, 1):
		_fail("rapid collision viewers were rejected")
		return
	if not await _settle(1200):
		_fail("rapid collision initial shell did not settle")
		return
	await physics_frame
	var positions := [
		Vector3(4.0, 8.0, 4.0), Vector3(12.0, 8.0, 4.0),
		Vector3(4.0, 8.0, 12.0), Vector3(12.0, 8.0, 12.0),
	]
	var before_hits: Array[Dictionary] = []
	for position in positions:
		before_hits.append(_vertical_hit(position))
	var revision_before := int(_world.get_backend_world_revision())
	for index in range(positions.size()):
		var operation := RapidEditOperation.new()
		operation.mode = RapidEditOperation.Mode.CARVE
		operation.brush_shape = RapidEditOperation.BrushShape.SPHERE
		operation.center = positions[index]
		operation.radius = 2.75
		operation.material_id = 1
		operation.density_value = 1.0
		var batch := RapidEditBatch.new()
		batch.add_operation(operation)
		if not _world.submit_edit_batch(batch, 7300 + index):
			_fail("rapid collision edit %d was rejected" % index)
			return
	var revision_target := revision_before + positions.size()
	for _frame in range(1200):
		if int(_world.get_backend_world_revision()) >= revision_target:
			break
		await process_frame
	if int(_world.get_backend_world_revision()) < revision_target:
		_fail("rapid collision edits did not commit")
		return
	if not await _settle(1200):
		_fail("rapid collision replacements did not settle")
		return
	await physics_frame
	var failures: Array = []
	var after_hits: Array[Dictionary] = []
	for index in range(positions.size()):
		var before: Dictionary = before_hits[index]
		var after := _vertical_hit(positions[index])
		after_hits.append(after)
		if bool(before.get("hit", false)) and bool(after.get("hit", false)) and \
				float(after.get("y", 0.0)) > float(before.get("y", 0.0)) - 1.0:
			failures.append({
				"position": positions[index], "before": before, "after": after,
			})
	var evidence := {
		"revision_before": revision_before,
		"revision_after": int(_world.get_backend_world_revision()),
		"before_hits": before_hits,
		"after_hits": after_hits,
		"failures": failures,
		"runtime": _world.get_runtime_metrics(),
	}
	_write_rapid_collision_evidence(evidence)
	if not failures.is_empty():
		_fail("superseded collision patches left stale solid surfaces: %s" % \
			JSON.stringify(failures))
		return
	print("GPU_RAPID_COLLISION_SUPERSESSION_SMOKE_PASS edits=4 stale_surfaces=0")
	_world.stop_backend_world()
	await _wait_for_state("stopped")
	quit(0)


func _write_rapid_collision_evidence(evidence: Dictionary) -> void:
	var path := ProjectSettings.globalize_path(
		"res://.godot/world_transvoxel_captures/gpu_rapid_collision_supersession.json"
	)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(evidence, "\t"))
		file.close()


func _vertical_hit(position: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		position + Vector3.UP * 7.0,
		position + Vector3.DOWN * 10.0,
		1
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := root.world_3d.direct_space_state.intersect_ray(query)
	return {
		"hit": not hit.is_empty(),
		"y": float(Vector3(hit.get("position", Vector3.ZERO)).y) if not hit.is_empty() else -INF,
		"collider": str(hit.get("collider")) if not hit.is_empty() else "",
	}

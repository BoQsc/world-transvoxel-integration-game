extends "res://tests/gpu_resident_multichunk_relocation_smoke.gd"

const EditOperation := preload(
	"res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd"
)
const EditBatch := preload(
	"res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd"
)

const SUPPORT_XZ := Vector2(2.0, 2.0)
const EDIT_XZ := Vector2(8.0, 8.0)


func _run() -> void:
	_setup_viewport()
	_world = TerrainWorld.new()
	_world.terrain_profile = _terrain_profile()
	_world.runtime_profile = _runtime_profile()
	_world.generation_profile = _generation_profile()
	_world.storage_profile = _storage_profile()
	_world.runtime_gpu_resident_render_candidate_enabled = true
	_world.runtime_gpu_meshing_shadow_capacity = 3
	_world.runtime_gpu_resident_chunk_capacity = 12
	root.add_child(_world)
	if not _world.start_backend_world() or not await _wait_for_state("running"):
		_fail("collision continuity world did not start")
		return
	if not _world.update_viewer(1, 1, Vector3(8, 8, 8), 1, 0) \
			or not _world.update_collision_viewer(2, 1, Vector3(8, 8, 8), 0) \
			or not await _wait_for_resident_state(2, 0):
		_fail("collision continuity fixture did not settle")
		return
	for _frame in range(3):
		await physics_frame
	var support := _vertical_hit(SUPPORT_XZ)
	var edit_hit := _vertical_hit(EDIT_XZ)
	if support.is_empty() or edit_hit.is_empty():
		_fail("fixture did not expose two standing surfaces")
		return
	var operation := EditOperation.new()
	operation.mode = EditOperation.Mode.CARVE
	operation.brush_shape = EditOperation.BrushShape.SPHERE
	operation.center = Vector3(EDIT_XZ.x, float(edit_hit.position.y) - 0.5, EDIT_XZ.y)
	operation.radius = 3.0
	operation.density_value = 1.0
	var batch := EditBatch.new()
	batch.add_operation(operation)
	if not _world.submit_edit_batch(batch, 6751):
		_fail("collision continuity carve was rejected")
		return
	var committed := false
	var replacement_ready := false
	for frame in range(600):
		await physics_frame
		if _vertical_hit(SUPPORT_XZ).is_empty():
			_fail("unmodified player support disappeared at frame %d" % frame)
			return
		if int(_world.get_runtime_metrics().get("collision_resources", 0)) < 1:
			_fail("collision resource set became empty at frame %d" % frame)
			return
		committed = committed or _world.get_world_revision() == 1
		var state: RefCounted = _world.query_chunk_state(Vector3i(0, 0, 0), 0)
		if state != null and bool(state.call("is_collision_ready")) \
				and int(state.call("get_collision_generation")) \
				== int(state.call("get_generation")) \
				and int(state.call("get_staged_collision_generation")) == 0:
			replacement_ready = committed
		if committed and replacement_ready:
			break
	if not committed or not replacement_ready:
		_fail("edited collision generation did not become authoritative")
		return
	print(("GPU_COLLISION_CONTINUITY_EDIT_SMOKE_PASS support_frames=600 " \
		+ "support_y=%.3f edit_y=%.3f collision_resources=%d") % [
		float(support.position.y), float(edit_hit.position.y),
		int(_world.get_runtime_metrics().get("collision_resources", 0)),
	])
	_world.stop_backend_world()
	await _wait_for_state("stopped")
	quit(0)


func _vertical_hit(xz: Vector2) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(xz.x, 48.0, xz.y), Vector3(xz.x, -32.0, xz.y)
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return _world.get_world_3d().direct_space_state.intersect_ray(query)


func _fail(message: String) -> void:
	push_error("GPU_COLLISION_CONTINUITY_EDIT_SMOKE_FAIL: " + message)
	quit(1)

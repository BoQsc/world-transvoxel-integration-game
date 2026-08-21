extends SceneTree

const MARKER := "WT_RUNTIME_ARTIFACT_BOTTOM_BOUNDARY_PASS"
const PROTECTED_POINT := Vector3i(16, -112, 16)
const EDITABLE_POINT := Vector3i(16, -111, 16)

var _samples := {}


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	if not ClassDB.class_exists(&"WorldTransvoxelTerrain"):
		_fail("WorldTransvoxelTerrain class is unavailable")
		return
	var terrain = ClassDB.instantiate(&"WorldTransvoxelTerrain")
	var config = ClassDB.instantiate(&"WorldTransvoxelConfig")
	if terrain == null or config == null:
		_fail("WorldTransvoxelTerrain/config could not be instantiated")
		return
	terrain.set("configuration", config)
	root.add_child(terrain)
	terrain.authoritative_sample_ready.connect(_on_sample_ready)
	var object_root := "user://worlds/runtime_artifact_bottom_boundary_%d" % Time.get_ticks_usec()
	var started := bool(terrain.call(
		"start_procedural_world_preset_with_vertical_origin_and_bottom_boundary",
		2,
		16,
		-8,
		2,
		19023,
		190327,
		"four_biomes_lakes_caves_roads",
		2,
		16,
		object_root
	))
	if not started or not await _wait_for_running(terrain):
		_fail("procedural bedrock world failed to start: %s" % terrain.call("get_world_error"))
		return

	var protected_before = await _query_sample(terrain, PROTECTED_POINT)
	var editable_before = await _query_sample(terrain, EDITABLE_POINT)
	if protected_before == null or editable_before == null:
		_fail("initial authoritative samples were unavailable")
		return
	if int(protected_before.call("get_material")) != 7:
		_fail("protected boundary sample is not bedrock material 7")
		return
	var protected_density_before := float(protected_before.call("get_density"))
	var editable_density_before := float(editable_before.call("get_density"))
	var initial_revision := int(terrain.call("get_world_revision"))
	var transaction = terrain.call("begin_edit_transaction", 9101)
	if transaction == null or not bool(transaction.call(
		"set_density_sphere", Vector3(EDITABLE_POINT), 2.25, 1.75
	)):
		_fail("boundary-crossing edit command was rejected")
		return
	if not bool(terrain.call("commit_edit_transaction", transaction)):
		_fail("boundary-crossing edit transaction failed: %s" % terrain.call("get_world_error"))
		return
	if not await _wait_for_revision(terrain, initial_revision + 1):
		_fail("boundary-crossing edit did not commit")
		return

	var protected_after = await _query_sample(terrain, PROTECTED_POINT)
	var editable_after = await _query_sample(terrain, EDITABLE_POINT)
	if protected_after == null or editable_after == null:
		_fail("post-edit authoritative samples were unavailable")
		return
	var protected_density_after := float(protected_after.call("get_density"))
	var editable_density_after := float(editable_after.call("get_density"))
	if not is_equal_approx(protected_density_before, protected_density_after) or \
			int(protected_after.call("get_material")) != 7:
		_fail("protected bedrock sample changed after edit")
		return
	if is_equal_approx(editable_density_before, editable_density_after) or \
			not is_equal_approx(editable_density_after, 1.75):
		_fail("adjacent unprotected sample did not receive the edit")
		return

	if not bool(terrain.call("stop_world")):
		_fail("world stop failed")
		return
	print(
		"%s protected_y=-112 material=7 editable_y=-111 density=%.2f revision=%d"
		% [MARKER, editable_density_after, int(terrain.call("get_world_revision"))]
	)
	terrain.queue_free()
	await process_frame
	quit(0)


func _wait_for_running(terrain: Object) -> bool:
	for _frame in range(900):
		if bool(terrain.call("is_world_running")):
			return true
		await process_frame
	return false


func _wait_for_revision(terrain: Object, revision: int) -> bool:
	for _frame in range(900):
		if int(terrain.call("get_world_revision")) >= revision:
			return true
		await process_frame
	return false


func _query_sample(terrain: Object, point: Vector3i):
	var request_id := int(terrain.call("request_authoritative_sample", point, 0))
	if request_id <= 0:
		return null
	for _frame in range(900):
		if _samples.has(request_id):
			var sample = _samples[request_id]
			_samples.erase(request_id)
			return sample
		await process_frame
	return null


func _on_sample_ready(request_id: int, sample: RefCounted) -> void:
	_samples[request_id] = sample


func _fail(message: String) -> void:
	push_error("WT_RUNTIME_ARTIFACT_BOTTOM_BOUNDARY_FAIL: " + message)
	quit(1)

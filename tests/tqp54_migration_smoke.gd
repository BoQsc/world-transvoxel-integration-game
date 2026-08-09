extends SceneTree

const MARKER := "WT_TQP54_MIGRATION_GODOT_PASS"
const TerrainWorld := preload("res://addons/world_transvoxel_terrain/runtime/wt_terrain_world.gd")
const TerrainProfile := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_profile.gd")
const RuntimeProfile := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_runtime_profile.gd")
const StorageProfile := preload("res://addons/world_transvoxel_terrain/storage/wt_terrain_storage_profile.gd")
const EditOperation := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd")
const EditBatch := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd")
const GameMaterialApplicator := preload("res://addons/world_transvoxel_gameworld/material/wt_game_terrain_material_applicator.gd")

var committed_revisions: Array[int] = []
var sample_results: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	if GameMaterialApplicator == null:
		_fail("game presentation boundary did not load")
		return
	_remove_fixture_journal()
	var world = TerrainWorld.new()
	world.terrain_profile = TerrainProfile.new()
	world.runtime_profile = RuntimeProfile.create_builtin(RuntimeProfile.Preset.BALANCED)
	world.storage_profile = _fixture_storage_profile()
	root.add_child(world)
	world.authoritative_sample_ready.connect(_on_sample_ready)
	world.edit_committed.connect(_on_edit_committed)

	if not world.start_world() or not await _wait_for_state(world, "running"):
		_fail("world start failed: %s" % world.get_last_error())
		return
	if world.get_api_generation() != 1 or world.get_world_revision() != 12:
		_fail("initial generation or fixture revision drifted")
		return
	if not world.update_viewer(1, 1, Vector3(8, 8, 8), 0, 0):
		_fail("render viewer update failed: %s" % world.get_last_error())
		return
	if not world.update_collision_viewer(2, 1, Vector3(8, 8, 8), 0):
		_fail("collision viewer update failed: %s" % world.get_last_error())
		return
	if world.update_viewer(1, 1, Vector3(9, 8, 8), 0, 0):
		_fail("stale viewer revision was accepted")
		return
	if not await _wait_for_settled(world, 1, 1):
		_fail("render/collision world did not settle: %s" % str(world.get_cold_idle_summary()))
		return
	var readiness: Dictionary = world.get_readiness_snapshot()
	if not _readiness_contract_ok(readiness):
		_fail("readiness contract incomplete: %s" % str(readiness))
		return
	var chunk: Dictionary = world.get_chunk_readiness(Vector3i.ZERO, 0)
	if str(chunk.get("render_state", "")) != "ready" or \
			str(chunk.get("collision_state", "")) != "ready":
		_fail("origin chunk is not render/collision ready: %s" % str(chunk))
		return

	var invalid = EditOperation.new()
	invalid.radius = 0.0
	var invalid_batch = EditBatch.new()
	if not invalid_batch.add_operation(invalid) or invalid_batch.is_valid() or \
			world.submit_edit_batch(invalid_batch, 5399):
		_fail("invalid edit submission was not rejected")
		return
	if not world.submit_edit_batch(_construct_batch(), 5400):
		_fail("construct edit submission failed: %s" % world.get_last_error())
		return
	if not await _wait_for_commit(world, 13):
		_fail("construct edit did not commit")
		return
	if not FileAccess.file_exists(_journal_path()):
		_fail("edit journal was not persisted")
		return
	var edited = await _query_sample(world, Vector3i(12, 8, 8))
	if edited == null or float(edited.call("get_density")) != -1.5 or \
			int(edited.call("get_material")) != 3 or \
			int(edited.call("get_world_revision")) != 13:
		_fail("edited authoritative sample mismatch")
		return

	if not world.stop_world() or not await _wait_for_state(world, "stopped"):
		_fail("world stop failed")
		return
	if not world.start_world() or not await _wait_for_state(world, "running"):
		_fail("world restart failed: %s" % world.get_last_error())
		return
	if world.get_api_generation() != 3 or world.get_world_revision() != 13:
		_fail("restart generation or journal revision mismatch")
		return
	var replayed = await _query_sample(world, Vector3i(12, 8, 8))
	if replayed == null or float(replayed.call("get_density")) != -1.5 or \
			int(replayed.call("get_material")) != 3 or \
			int(replayed.call("get_world_revision")) != 13:
		_fail("replayed authoritative sample mismatch")
		return
	if not world.stop_world() or not await _wait_for_state(world, "stopped"):
		_fail("final world stop failed")
		return

	_remove_fixture_journal()
	print("%s render=1 collision=1 edit=committed journal=replayed failure=closed generation=3" % MARKER)
	world.queue_free()
	await process_frame
	quit(0)


func _fixture_storage_profile() -> Resource:
	var storage = StorageProfile.new()
	storage.world_manifest_path = "res://build/production-lifecycle-fixture/streaming.wtworld"
	storage.object_root_path = "res://build/production-lifecycle-fixture"
	storage.edit_journal_path = _journal_path()
	storage.snapshot_directory = "res://build/production-lifecycle-fixture/snapshots"
	storage.allow_res_paths_for_test_fixtures = true
	return storage


func _construct_batch() -> Resource:
	var operation = EditOperation.new()
	operation.mode = EditOperation.Mode.CONSTRUCT
	operation.center = Vector3(12, 8, 8)
	operation.radius = 1.5
	operation.material_id = 3
	operation.density_value = 1.0
	var batch = EditBatch.new()
	batch.add_operation(operation)
	return batch


func _readiness_contract_ok(readiness: Dictionary) -> bool:
	return int(readiness.get("api_generation", 0)) == 1 and \
		readiness.has("render") and readiness.has("collision") and \
		readiness.has("edit") and readiness.has("query")


func _wait_for_state(world: Node, expected: String) -> bool:
	for _frame in range(900):
		if world.get_world_state_name() == expected:
			await process_frame
			return true
		await process_frame
	return false


func _wait_for_settled(world: Node, render_count: int, collision_count: int) -> bool:
	for _frame in range(900):
		var summary: Dictionary = world.get_cold_idle_summary()
		if bool(summary.get("cold_idle", false)) and \
				int(summary.get("render_resources", -1)) == render_count and \
				int(summary.get("collision_resources", -1)) == collision_count:
			return true
		await process_frame
	return false


func _wait_for_commit(world: Node, revision: int) -> bool:
	for _frame in range(900):
		if committed_revisions.has(revision) and world.get_world_revision() == revision:
			return true
		await process_frame
	return false


func _query_sample(world: Node, point: Vector3i):
	var request_id: int = world.request_authoritative_sample(point, 0)
	if request_id <= 0:
		return null
	for _frame in range(900):
		if sample_results.has(request_id):
			return sample_results[request_id]
		await process_frame
	return null


func _on_edit_committed(revision: int) -> void:
	committed_revisions.append(revision)


func _on_sample_ready(request_id: int, sample: RefCounted) -> void:
	sample_results[request_id] = sample


func _journal_path() -> String:
	return "res://build/production-lifecycle-fixture/world.wtedit"


func _remove_fixture_journal() -> void:
	var path := ProjectSettings.globalize_path(_journal_path())
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _fail(message: String) -> void:
	push_error("WT_TQP54_MIGRATION_GODOT_FAIL: " + message)
	quit(1)

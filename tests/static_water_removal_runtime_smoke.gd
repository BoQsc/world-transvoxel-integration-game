extends SceneTree

const MARKER := "WT_STATIC_WATER_REMOVAL_RUNTIME_PASS"
const TerrainWorld := preload(
	"res://addons/world_transvoxel_terrain/runtime/wt_terrain_world.gd"
)
const TerrainProfile := preload(
	"res://addons/world_transvoxel_terrain/api/wt_terrain_profile.gd"
)
const RuntimeProfile := preload(
	"res://addons/world_transvoxel_terrain/api/wt_terrain_runtime_profile.gd"
)
const GenerationProfile := preload(
	"res://addons/world_transvoxel_terrain/generation/wt_terrain_generation_profile.gd"
)
const StorageProfile := preload(
	"res://addons/world_transvoxel_terrain/storage/wt_terrain_storage_profile.gd"
)
const EditOperation := preload(
	"res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd"
)
const EditBatch := preload(
	"res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd"
)

var committed_revisions: Array[int] = []


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var world := TerrainWorld.new()
	world.terrain_profile = _terrain_profile()
	world.runtime_profile = _runtime_profile()
	world.generation_profile = _generation_profile()
	world.storage_profile = _storage_profile()
	root.add_child(world)
	world.edit_committed.connect(_on_edit_committed)

	if not world.start_backend_world() or not await _wait_for_state(world, "running"):
		_fail("static-water world failed to start: %s" % world.get_last_error())
		return

	if not await _submit_and_verify(world, EditOperation.Mode.PLACE_STATIC_WATER, 1):
		return
	if not await _submit_and_verify(world, EditOperation.Mode.REMOVE_STATIC_WATER, 2):
		return

	if not world.stop_backend_world() or not await _wait_for_state(world, "stopped"):
		_fail("static-water world did not stop cleanly")
		return
	print(
		"%s revisions=2 water_place=1 water_remove=1 terrain_carve=0 workers=1"
		% MARKER
	)
	world.queue_free()
	await process_frame
	quit(0)


func _submit_and_verify(world: Node, mode: EditOperation.Mode, revision: int) -> bool:
	var operation := EditOperation.new()
	operation.mode = mode
	operation.brush_shape = EditOperation.BrushShape.SPHERE
	operation.center = Vector3(8.0, 12.0, 8.0)
	operation.radius = 2.0
	operation.material_id = 9
	var batch := EditBatch.new()
	if not batch.add_operation(operation):
		_fail("water operation could not be added to the batch")
		return false
	if not world.submit_edit_batch(batch, 9909):
		_fail("water operation was rejected: %s" % world.get_last_error())
		return false
	var expected_mode := str(operation.get_mode_name())
	var summary: Dictionary = world.get_last_edit_submission_summary()
	var operation_summaries: Array = summary.get("operation_summaries", [])
	if not bool(summary.get("submitted", false)) or \
			int(summary.get("backend_command_count", 0)) != 1 or \
			int(summary.get("transaction_command_count", 0)) != 1 or \
			operation_summaries.size() != 1 or \
			str(operation_summaries[0].get("operation", "")) != expected_mode:
		_fail("water operation used the wrong backend command: %s" % str(summary))
		return false
	if not await _wait_for_commit(world, revision):
		_fail("water operation did not commit revision %d" % revision)
		return false
	return true


func _terrain_profile() -> Resource:
	var profile := TerrainProfile.new()
	profile.horizontal_cells = 16
	profile.vertical_cells = 16
	profile.profile_id = &"static_water_removal_runtime_smoke"
	return profile


func _runtime_profile() -> Resource:
	var profile := RuntimeProfile.create_builtin(RuntimeProfile.Preset.LOW_POWER)
	profile.procedural_generation_worker_count = 1
	return profile


func _generation_profile() -> Resource:
	var profile := GenerationProfile.new()
	profile.source_mode = GenerationProfile.SourceMode.FLAT
	profile.profile_id = &"static_water_removal_runtime_smoke"
	profile.procedural_preset_id = &"flat"
	profile.source_revision = 190329
	profile.world_chunk_count_x = 1
	profile.world_chunk_count_y = 1
	profile.world_chunk_count_z = 1
	return profile


func _storage_profile() -> Resource:
	var root_path := "user://static-water-removal-runtime-smoke-%d" % Time.get_ticks_usec()
	var profile := StorageProfile.new()
	profile.profile_id = &"static_water_removal_runtime_smoke"
	profile.object_root_path = root_path
	profile.world_manifest_path = root_path.path_join("world.wtworld")
	profile.edit_journal_path = root_path.path_join("world.wtedit")
	profile.snapshot_directory = root_path.path_join("snapshots")
	return profile


func _wait_for_state(world: Node, expected: String) -> bool:
	for _frame in range(900):
		if world.get_world_state_name() == expected:
			await process_frame
			return true
		await process_frame
	return false


func _wait_for_commit(world: Node, revision: int) -> bool:
	for _frame in range(900):
		if committed_revisions.has(revision) and world.get_world_revision() == revision:
			return true
		await process_frame
	return false


func _on_edit_committed(revision: int) -> void:
	committed_revisions.append(revision)


func _fail(message: String) -> void:
	push_error("WT_STATIC_WATER_REMOVAL_RUNTIME_FAIL: " + message)
	quit(1)

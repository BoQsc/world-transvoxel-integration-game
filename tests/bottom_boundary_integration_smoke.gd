extends SceneTree

const MARKER := "WT_BOTTOM_BOUNDARY_INTEGRATION_PASS"
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

var sample_results: Dictionary = {}
var committed_revisions: Array[int] = []


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var world = TerrainWorld.new()
	world.terrain_profile = _terrain_profile()
	world.runtime_profile = _runtime_profile()
	world.generation_profile = _generation_profile()
	world.storage_profile = _storage_profile()
	root.add_child(world)
	world.authoritative_sample_ready.connect(_on_sample_ready)
	world.edit_committed.connect(_on_edit_committed)

	if not world.start_backend_world() or not await _wait_for_state(world, "running"):
		_fail("G23 bedrock world failed to start: %s" % world.get_last_error())
		return

	var protected_point := Vector3i(1024, -112, 1024)
	var editable_point := Vector3i(1024, -111, 1024)
	var protected_before = await _query_sample(world, protected_point)
	var editable_before = await _query_sample(world, editable_point)
	if protected_before == null or editable_before == null or \
			float(protected_before.call("get_density")) >= 0.0 or \
			int(protected_before.call("get_material")) != 7:
		_fail("native G23 bedrock sample is missing")
		return

	var protected_density := float(protected_before.call("get_density"))
	var batch = EditBatch.new()
	var carve = EditOperation.new()
	carve.mode = EditOperation.Mode.CARVE
	carve.brush_shape = EditOperation.BrushShape.SPHERE
	carve.center = Vector3(editable_point)
	carve.radius = 4.0
	batch.add_operation(carve)
	if not world.submit_edit_batch(batch, 7301) or not await _wait_for_commit(world, 1):
		_fail("boundary-crossing carve did not commit: %s" % world.get_last_error())
		return

	var protected_after = await _query_sample(world, protected_point)
	var editable_after = await _query_sample(world, editable_point)
	if protected_after == null or editable_after == null or \
			float(protected_after.call("get_density")) != protected_density or \
			int(protected_after.call("get_material")) != 7:
		_fail("protected bedrock sample changed after carve")
		return
	if float(editable_after.call("get_density")) <= 0.0 or \
			float(editable_after.call("get_density")) == float(editable_before.call("get_density")):
		_fail("editable sample above bedrock was not carved")
		return

	if not world.stop_backend_world() or not await _wait_for_state(world, "stopped"):
		_fail("G23 bedrock world did not stop cleanly")
		return
	print(
		"%s source_revision=190326 protected_y=-112 editable_y=-111 material=7 revision=1"
		% MARKER
	)
	world.queue_free()
	await process_frame
	quit(0)


func _terrain_profile() -> Resource:
	var profile = TerrainProfile.new()
	profile.horizontal_cells = 2048
	profile.vertical_cells = 256
	profile.vertical_origin_cell = -128
	return profile


func _runtime_profile() -> Resource:
	var profile = RuntimeProfile.create_builtin(RuntimeProfile.Preset.LOW_POWER)
	profile.procedural_generation_worker_count = 1
	return profile


func _generation_profile() -> Resource:
	var profile = GenerationProfile.new()
	profile.profile_id = &"g23_bottom_boundary_integration_smoke"
	profile.seed = 19023
	profile.procedural_preset_id = &"four_biomes_lakes_caves_roads"
	profile.source_revision = 190326
	profile.world_chunk_count_x = 128
	profile.world_chunk_count_y = 16
	profile.world_chunk_origin_y = -8
	profile.world_chunk_count_z = 128
	profile.bottom_boundary_policy = GenerationProfile.BottomBoundaryPolicy.BEDROCK
	profile.bottom_boundary_thickness_cells = 16
	return profile


func _storage_profile() -> Resource:
	var root_path := "user://bottom-boundary-integration-smoke-%d" % Time.get_ticks_usec()
	var profile = StorageProfile.new()
	profile.profile_id = &"bottom_boundary_integration_smoke"
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


func _query_sample(world: Node, point: Vector3i):
	var request_id: int = world.request_authoritative_sample(point, 0)
	if request_id <= 0:
		return null
	for _frame in range(900):
		if sample_results.has(request_id):
			return sample_results[request_id]
		await process_frame
	return null


func _on_sample_ready(request_id: int, sample: RefCounted) -> void:
	sample_results[request_id] = sample


func _on_edit_committed(revision: int) -> void:
	committed_revisions.append(revision)


func _fail(message: String) -> void:
	push_error("WT_BOTTOM_BOUNDARY_INTEGRATION_FAIL: " + message)
	quit(1)

extends SceneTree

const MARKER := "WT_PROCEDURAL_LAKE_SHORELINE_RUNTIME_PASS"
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

var sample_results: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var world := TerrainWorld.new()
	world.terrain_profile = _terrain_profile()
	world.runtime_profile = _runtime_profile()
	world.generation_profile = _generation_profile()
	world.storage_profile = _storage_profile()
	root.add_child(world)
	world.authoritative_sample_ready.connect(_on_sample_ready)

	if not world.start_backend_world() or not await _wait_for_state(world, "running"):
		_fail("four-biome shoreline world failed to start: %s" % world.get_last_error())
		return

	var basin_water = await _query_sample(world, Vector3i(650, 10, 1370))
	var former_wall_air = await _query_sample(world, Vector3i(868, 17, 1387))
	var contained_boundary = await _query_sample(world, Vector3i(868, 14, 1387))
	if basin_water == null or former_wall_air == null or contained_boundary == null:
		_fail("authoritative shoreline samples were not returned")
		return
	if float(basin_water.call("get_density")) <= 0.0 or \
			int(basin_water.call("get_material")) != 9:
		_fail("gravel lake center no longer exposes volumetric water")
		return
	if float(former_wall_air.call("get_density")) <= 0.0 or \
			int(former_wall_air.call("get_material")) == 9:
		_fail("former gravel-lake wall location still exposes water")
		return
	if float(contained_boundary.call("get_density")) >= 0.0 or \
			int(contained_boundary.call("get_material")) == 9:
		_fail("gravel-lake lateral closure is not contained by solid terrain")
		return

	if not world.stop_backend_world() or not await _wait_for_state(world, "stopped"):
		_fail("four-biome shoreline world did not stop cleanly")
		return
	print(
		"%s source_revision=190327 center_water=1 exposed_wall=0 contained_boundary=1 workers=1"
		% MARKER
	)
	world.queue_free()
	await process_frame
	quit(0)


func _terrain_profile() -> Resource:
	var profile := TerrainProfile.new()
	profile.horizontal_cells = 2048
	profile.vertical_cells = 256
	profile.vertical_origin_cell = -128
	profile.profile_id = &"procedural_lake_shoreline_runtime_smoke"
	return profile


func _runtime_profile() -> Resource:
	var profile := RuntimeProfile.create_builtin(RuntimeProfile.Preset.LOW_POWER)
	profile.procedural_generation_worker_count = 1
	return profile


func _generation_profile() -> Resource:
	var profile := GenerationProfile.new()
	profile.profile_id = &"procedural_lake_shoreline_runtime_smoke"
	profile.seed = 19023
	profile.procedural_preset_id = &"four_biomes_lakes_caves_roads"
	profile.source_revision = 190327
	profile.world_chunk_count_x = 128
	profile.world_chunk_count_y = 16
	profile.world_chunk_origin_y = -8
	profile.world_chunk_count_z = 128
	profile.bottom_boundary_policy = GenerationProfile.BottomBoundaryPolicy.BEDROCK
	profile.bottom_boundary_thickness_cells = 16
	return profile


func _storage_profile() -> Resource:
	var root_path := "user://procedural-lake-shoreline-smoke-%d" % Time.get_ticks_usec()
	var profile := StorageProfile.new()
	profile.profile_id = &"procedural_lake_shoreline_runtime_smoke"
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


func _fail(message: String) -> void:
	push_error("WT_PROCEDURAL_LAKE_SHORELINE_RUNTIME_FAIL: " + message)
	quit(1)

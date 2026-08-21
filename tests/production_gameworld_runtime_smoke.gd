extends SceneTree

const MARKER := "WT_PRODUCTION_GAMEWORLD_RUNTIME_PASS"
const GameWorldNode := preload(
	"res://addons/world_transvoxel_gameworld/wt_game_world_node.gd"
)
const TerrainProfile := preload(
	"res://addons/world_transvoxel_terrain/api/wt_terrain_profile.gd"
)
const GenerationProfile := preload(
	"res://addons/world_transvoxel_terrain/generation/wt_terrain_generation_profile.gd"
)
const StorageProfile := preload(
	"res://addons/world_transvoxel_terrain/storage/wt_terrain_storage_profile.gd"
)


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var generation = GenerationProfile.new()
	generation.source_mode = GenerationProfile.SourceMode.FLAT
	generation.procedural_preset_id = &"flat"
	generation.world_chunk_count_x = 1
	generation.world_chunk_count_y = 1
	generation.world_chunk_count_z = 1

	var storage = StorageProfile.new()
	var object_root := "user://worlds/production_runtime_smoke_%d" % Time.get_ticks_usec()
	storage.profile_id = &"production_runtime_smoke"
	storage.object_root_path = object_root
	storage.world_manifest_path = object_root.path_join("world.wtworld")
	storage.edit_journal_path = object_root.path_join("world.wtedit")
	storage.snapshot_directory = object_root.path_join("snapshots")

	var game_world := GameWorldNode.new()
	game_world.player_driven_viewer_enabled = false
	game_world.startup_requires_cold_idle = true
	game_world.runtime_active_chunk_capacity = 8
	game_world.runtime_viewer_capacity = 2
	game_world.runtime_demand_capacity_per_viewer = 8
	game_world.runtime_render_entry_capacity = 8
	game_world.runtime_collision_entry_capacity = 8
	game_world.runtime_procedural_generation_worker_count = 1
	game_world.configure_game_world(
		&"production_runtime_smoke",
		generation,
		storage,
		[Vector3(8.0, 8.0, 8.0)],
		0,
		1,
		Vector3(8.0, 8.0, 8.0),
		0,
		TerrainProfile.new()
	)
	root.add_child(game_world)

	var runtime_scene = game_world.setup_standard_world()
	if runtime_scene == null or runtime_scene.get_script() == null:
		_fail("production runtime scene did not instantiate")
		return
	if str(runtime_scene.get_script().resource_path) != \
			"res://addons/world_transvoxel_terrain/runtime/wt_terrain_runtime_scene.gd":
		_fail("GameWorld instantiated a non-production terrain scene")
		return
	if runtime_scene.find_child("DebugOverlay", true, false) != null:
		_fail("production runtime scene contains a debug overlay")
		return
	if not await game_world.start_world():
		_fail("production GameWorld start failed: %s" % game_world.get_last_error())
		return
	var summary: Dictionary = game_world.get_game_world_summary()
	if str(summary.get("terrain_scene", "")) != "production_runtime":
		_fail("production runtime identity is absent: %s" % str(summary))
		return
	if not await game_world.stop_world():
		_fail("production GameWorld stop failed: %s" % game_world.get_last_error())
		return
	print("%s render=1 collision=1 debug_scene=false workers=1" % MARKER)
	quit(0)


func _fail(message: String) -> void:
	push_error("WT_PRODUCTION_GAMEWORLD_RUNTIME_FAIL: " + message)
	quit(1)

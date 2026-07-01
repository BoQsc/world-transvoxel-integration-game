extends SceneTree

const MARKER := "WT_INTEGRATION_GAME_G57_PASS"
const GameWorldNode := preload("res://addons/world_transvoxel_game_world/wt_game_world_node.gd")
const GenerationProfile := preload("res://addons/world_transvoxel_terrain/generation/wt_terrain_generation_profile.gd")
const StorageProfile := preload("res://addons/world_transvoxel_terrain/storage/wt_terrain_storage_profile.gd")
const PlayerStub := preload("res://scripts/g57_player_stub.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _assert_no_dense_files("before_start"):
		return
	var game_world = GameWorldNode.new()
	game_world.name = "WorldTransvoxelGameWorld"
	game_world.human_input_enabled = false
	root.add_child(game_world)
	var start := Vector3(1032.0, 24.0, 1032.0)
	var player := _create_player(start)
	game_world.configure_game_world(
		&"g57_integration_2k",
		_generation_profile(),
		_storage_profile(),
		[Vector3(1032.0, 8.0, 1032.0)],
		2,
		25,
		start
	)
	game_world.attach_player(player, start)
	if not await game_world.start_world():
		_fail("game-world addon did not start: %s" % game_world.get_last_error())
		return
	var terrain_world: Node = game_world.get_terrain_world()
	if terrain_world == null:
		_fail("terrain world missing")
		return
	player.global_position += Vector3(32.0, 0.0, 0.0)
	if not bool(game_world.update_player_viewer(true)):
		_fail("player viewer update rejected")
		return
	if not await game_world.wait_for_cold_idle(25, 25):
		_fail("terrain did not settle after player viewer update")
		return
	var before_revision := int(terrain_world.call("get_backend_world_revision"))
	if not bool(game_world.submit_sphere_edit(&"carve", Vector3(1032.0, 8.0, 1032.0), 1.8, -1, 1.0)):
		_fail("game-world edit bridge rejected carve: %s" % str(game_world.get_last_edit_summary()))
		return
	if not await game_world.wait_for_world_revision(before_revision + 1):
		_fail("game-world edit did not commit")
		return
	if not await game_world.wait_for_cold_idle(25, 25):
		_fail("terrain did not settle after edit")
		return
	var summary: Dictionary = game_world.get_game_world_summary()
	if not _verify_summary(summary):
		return
	if not _assert_no_dense_files("after_runtime"):
		return
	print("%s repo=world-transvoxel-integration-game addon=%s api_version=%d validation_internals=0 player_viewer_updates=%d edit_replacements=%d render_resources=%d collision_resources=%d active_records=%d dense_world_files=0" % [
		MARKER,
		str(summary.get("addon_id", "")),
		int(summary.get("api_version", 0)),
		int(summary.get("player_viewer_updates", 0)),
		int(summary.get("edit_replacements", 0)),
		int(summary.get("render_resources", 0)),
		int(summary.get("collision_resources", 0)),
		int(summary.get("active_chunk_records", 0)),
	])
	await process_frame
	quit(0)


func _generation_profile() -> Resource:
	var generation = GenerationProfile.new()
	generation.profile_id = &"g57_integration_2k"
	generation.source_mode = GenerationProfile.SourceMode.DETERMINISTIC_REFERENCE
	generation.seed = 57057
	generation.source_revision = 570057
	generation.world_chunk_count_x = 128
	generation.world_chunk_count_z = 128
	return generation


func _storage_profile() -> Resource:
	var storage = StorageProfile.new()
	storage.profile_id = &"g57_integration_2k"
	storage.world_manifest_path = "res://build/g57-integration-game/g57_integration_2k/procedural.wtseed"
	storage.object_root_path = "res://build/g57-integration-game/g57_integration_2k"
	storage.edit_journal_path = "res://build/g57-integration-game/g57_integration_2k/world.wtedit"
	storage.snapshot_directory = "res://build/g57-integration-game/g57_integration_2k/snapshots"
	storage.allow_res_paths_for_test_fixtures = true
	return storage


func _create_player(start: Vector3) -> CharacterBody3D:
	var player := CharacterBody3D.new()
	player.name = "IntegrationPlayer"
	player.set_script(PlayerStub)
	player.position = start
	var shape := CapsuleShape3D.new()
	shape.radius = 0.45
	shape.height = 1.8
	var collision := CollisionShape3D.new()
	collision.name = "PlayerCollision"
	collision.shape = shape
	player.add_child(collision)
	return player


func _verify_summary(summary: Dictionary) -> bool:
	if str(summary.get("addon_id", "")) != "world_transvoxel_game_world" or int(summary.get("api_version", 0)) != 1:
		_fail("addon identity invalid: %s" % str(summary))
		return false
	for key in ["active_chunk_records", "render_resources", "collision_resources"]:
		if int(summary.get(key, 0)) != 25:
			_fail("resource mismatch: %s" % str(summary))
			return false
	for key in ["queued_render", "queued_collision", "pending_chunk_retirements", "render_fading_resources"]:
		if int(summary.get(key, 0)) != 0:
			_fail("unsettled terrain: %s" % str(summary))
			return false
	if int(summary.get("player_viewer_updates", 0)) < 2 or int(summary.get("edit_replacements", 0)) <= 0:
		_fail("integration counters invalid: %s" % str(summary))
		return false
	return true


func _assert_no_dense_files(stage: String) -> bool:
	for path in [
		"res://build/g57-integration-game/g57_integration_2k/world.wtworld",
		"res://build/g57-integration-game/g57_integration_2k/streaming.wtworld",
		"res://build/g57-integration-game/g57_integration_2k/procedural.wtseed",
	]:
		if FileAccess.file_exists(path):
			_fail("dense/procedural descriptor exists at %s: %s" % [stage, path])
			return false
	return true


func _fail(message: String) -> void:
	push_error("WT_INTEGRATION_GAME_G57_FAIL: " + message)
	quit(1)

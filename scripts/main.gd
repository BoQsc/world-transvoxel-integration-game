extends Node3D

const MARKER := "WT_PRODUCTION_GAME_P2_PASS"
const ADDON_ID := "world_transvoxel_gameworld"
const COMPACT_PROFILE := &"g19_compact_2k_on_demand"
const FLAT_PROFILE := &"flat_baseline"
const GameWorldNode := preload("res://addons/world_transvoxel_gameworld/wt_game_world_node.gd")
const GenerationProfile := preload("res://addons/world_transvoxel_terrain/generation/wt_terrain_generation_profile.gd")
const StorageProfile := preload("res://addons/world_transvoxel_terrain/storage/wt_terrain_storage_profile.gd")
const PlayerScript := preload("res://scripts/wt_production_player.gd")

var game_world: Node
var player: CharacterBody3D
var telemetry_label: Label
var profile_selector: OptionButton
var crosshair: Label
var selected_profile: StringName = COMPACT_PROFILE
var autonomous := false
var expected_resources := 25
var edit_point := Vector3.ZERO


func _ready() -> void:
	var args := Array(OS.get_cmdline_user_args())
	autonomous = args.has("--p2-autonomous")
	selected_profile = StringName(_arg_value(args, "--p2-profile", str(COMPACT_PROFILE)))
	_build_hud()
	call_deferred("_start_profile")


func _start_profile() -> void:
	var settings := _profile_settings(selected_profile)
	expected_resources = int(settings["expected_resources"])
	edit_point = settings["edit_point"]
	game_world = GameWorldNode.new()
	game_world.name = "WtGameWorld"
	game_world.human_input_enabled = not autonomous
	add_child(game_world)
	player = _create_player(settings["start"])
	player.game_world = game_world
	player.edit_point = edit_point
	game_world.configure_game_world(
		selected_profile,
		_generation_profile(selected_profile),
		_storage_profile(selected_profile),
		settings["viewers"],
		int(settings["radius"]),
		expected_resources,
		settings["start"]
	)
	game_world.attach_player(player, settings["start"])
	if not await game_world.start_world():
		_fail("gameworld did not start: %s" % game_world.get_last_error())
		return
	_update_telemetry()
	if autonomous:
		await _run_autonomous_proof()


func _run_autonomous_proof() -> void:
	if not _verify_scene_contract():
		return
	var terrain_world: Node = game_world.get_terrain_world()
	if terrain_world == null:
		_fail("terrain world missing")
		return
	if not bool(player.call("autonomous_translate", Vector3(16.0, 0.0, 0.0))):
		_fail("player traversal method failed")
		return
	if not bool(game_world.update_player_viewer(true)):
		_fail("player viewer update failed")
		return
	if not await game_world.wait_for_cold_idle(expected_resources, expected_resources):
		_fail("terrain did not settle after traversal")
		return
	var before_revision := int(terrain_world.call("get_backend_world_revision"))
	if not bool(player.call("submit_edit_input", &"carve", edit_point)):
		_fail("player edit input path rejected carve")
		return
	if not await game_world.wait_for_world_revision(before_revision + 1):
		_fail("terrain edit did not commit")
		return
	if not await game_world.wait_for_cold_idle(expected_resources, expected_resources):
		_fail("terrain did not return to cold idle")
		return
	if not FileAccess.file_exists(_storage_root(selected_profile) + "/world.wtedit"):
		_fail("edit journal missing")
		return
	_update_telemetry()
	var summary: Dictionary = game_world.get_game_world_summary()
	if not _verify_summary(summary):
		return
	print("%s profile=%s addon=%s api_version=%d launch=project_godot player=1 camera=1 crosshair=1 profile_selector=1 telemetry=1 input_edit=1 traversal=1 edit_committed=1 storage_journal=1 cold_idle=1 render_resources=%d collision_resources=%d active_records=%d validation_internals=0" % [
		MARKER,
		str(selected_profile),
		str(summary.get("addon_id", "")),
		int(summary.get("api_version", 0)),
		int(summary.get("render_resources", 0)),
		int(summary.get("collision_resources", 0)),
		int(summary.get("active_chunk_records", 0)),
	])
	await get_tree().process_frame
	get_tree().quit(0)


func _build_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "GameHUD"
	add_child(canvas)
	crosshair = Label.new()
	crosshair.name = "Crosshair"
	crosshair.text = "+"
	crosshair.position = Vector2(636, 356)
	canvas.add_child(crosshair)
	telemetry_label = Label.new()
	telemetry_label.name = "TelemetryLabel"
	telemetry_label.position = Vector2(12, 12)
	telemetry_label.text = "terrain: starting"
	canvas.add_child(telemetry_label)
	profile_selector = OptionButton.new()
	profile_selector.name = "ProfileSelector"
	profile_selector.position = Vector2(12, 44)
	profile_selector.add_item("flat_baseline")
	profile_selector.add_item("g19_compact_2k_on_demand")
	canvas.add_child(profile_selector)


func _create_player(start: Vector3) -> CharacterBody3D:
	var p := CharacterBody3D.new()
	p.name = "ProductionPlayer"
	p.set_script(PlayerScript)
	p.position = start
	var shape := CapsuleShape3D.new()
	shape.radius = 0.45
	shape.height = 1.8
	var collision := CollisionShape3D.new()
	collision.name = "PlayerCollision"
	collision.shape = shape
	p.add_child(collision)
	var camera := Camera3D.new()
	camera.name = "FirstPersonCamera"
	camera.current = true
	camera.position = Vector3(0.0, 1.6, 0.0)
	p.add_child(camera)
	return p


func _profile_settings(profile_id: StringName) -> Dictionary:
	if profile_id == FLAT_PROFILE:
		return {"start": Vector3(8, 12, 8), "viewers": [Vector3(8, 8, 8)], "radius": 0, "expected_resources": 1, "edit_point": Vector3(8, 8, 8)}
	return {"start": Vector3(1032, 24, 1032), "viewers": [Vector3(1032, 8, 1032)], "radius": 2, "expected_resources": 25, "edit_point": Vector3(1032, 8, 1032)}


func _generation_profile(profile_id: StringName) -> Resource:
	var generation = GenerationProfile.new()
	generation.profile_id = profile_id
	generation.seed = 19019
	generation.source_revision = 190019
	generation.world_chunk_count_x = 128
	generation.world_chunk_count_z = 128
	generation.source_mode = GenerationProfile.SourceMode.DETERMINISTIC_REFERENCE
	if profile_id == FLAT_PROFILE:
		generation.seed = 101
		generation.source_revision = 101
		generation.world_chunk_count_x = 8
		generation.world_chunk_count_z = 8
		generation.source_mode = GenerationProfile.SourceMode.FLAT
	return generation


func _storage_profile(profile_id: StringName) -> Resource:
	var storage = StorageProfile.new()
	storage.profile_id = profile_id
	var root_path := _storage_root(profile_id)
	storage.world_manifest_path = "%s/procedural.wtseed" % root_path
	if profile_id == FLAT_PROFILE:
		storage.world_manifest_path = "%s/streaming.wtworld" % root_path
	storage.object_root_path = root_path
	storage.edit_journal_path = "%s/world.wtedit" % root_path
	storage.snapshot_directory = "%s/snapshots" % root_path
	storage.allow_res_paths_for_test_fixtures = true
	return storage


func _storage_root(profile_id: StringName) -> String:
	if profile_id == FLAT_PROFILE:
		return "res://build/production-lifecycle-fixture"
	return "res://build/p2-production-game/%s" % str(profile_id)


func _update_telemetry() -> void:
	var summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
	telemetry_label.text = "profile=%s active=%d render=%d collision=%d edits=%d" % [
		str(selected_profile),
		int(summary.get("active_chunk_records", 0)),
		int(summary.get("render_resources", 0)),
		int(summary.get("collision_resources", 0)),
		int(summary.get("edit_replacements", 0)),
	]


func _verify_scene_contract() -> bool:
	return player != null and player.has_node("FirstPersonCamera") and crosshair != null and 			profile_selector != null and profile_selector.item_count >= 2 and telemetry_label != null and 			player.has_method("submit_edit_input")


func _verify_summary(summary: Dictionary) -> bool:
	if str(summary.get("addon_id", "")) != ADDON_ID or int(summary.get("api_version", 0)) != 1:
		_fail("addon identity invalid: %s" % str(summary))
		return false
	if int(summary.get("render_resources", 0)) != expected_resources or int(summary.get("collision_resources", 0)) != expected_resources:
		_fail("resource mismatch: %s" % str(summary))
		return false
	for key in ["queued_render", "queued_collision", "pending_chunk_retirements", "render_fading_resources"]:
		if int(summary.get(key, 0)) != 0:
			_fail("terrain not cold idle: %s" % str(summary))
			return false
	return true


func _arg_value(args: Array, key: String, default_value: String) -> String:
	var index := args.find(key)
	if index >= 0 and index + 1 < args.size():
		return str(args[index + 1])
	return default_value


func _fail(message: String) -> void:
	push_error("WT_PRODUCTION_GAME_P2_FAIL: " + message)
	if autonomous:
		get_tree().quit(1)

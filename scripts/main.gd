extends Node3D

const MARKER := "WT_PRODUCTION_GAME_P2_PASS"
const ADDON_ID := "world_transvoxel_gameworld"
const COMPACT_PROFILE := &"g19_compact_2k_on_demand"
const FLAT_PROFILE := &"flat_baseline"
const GameWorldNode := preload("res://addons/world_transvoxel_gameworld/wt_game_world_node.gd")
const GenerationProfile := preload("res://addons/world_transvoxel_terrain/generation/wt_terrain_generation_profile.gd")
const StorageProfile := preload("res://addons/world_transvoxel_terrain/storage/wt_terrain_storage_profile.gd")
const MaterialApplicator := preload("res://addons/world_transvoxel_terrain/material/wt_terrain_material_applicator.gd")
const FullMapVisual := preload("res://addons/world_transvoxel_terrain/visual/wt_terrain_full_map_visual.gd")
const PlayerScript := preload("res://scripts/wt_production_player.gd")

var playtest_profile_id: StringName = COMPACT_PROFILE
var game_world: Node
var player: CharacterBody3D
var telemetry_label: Label
var profile_selector: OptionButton
var crosshair: Label
var material_applicator: Node
var full_map_visual: MeshInstance3D
var selected_profile: StringName = COMPACT_PROFILE
var autonomous := false
var expected_resources := 25
var expected_max_resources := 81
var expected_maximum_lod := 1
var edit_point := Vector3.ZERO


func _ready() -> void:
	var args := Array(OS.get_cmdline_user_args())
	autonomous = args.has("--p2-autonomous")
	selected_profile = StringName(_arg_value(args, "--p2-profile", str(COMPACT_PROFILE)))
	playtest_profile_id = selected_profile
	_build_hud()
	call_deferred("_start_profile")


func _start_profile() -> void:
	var settings := _profile_settings(selected_profile)
	playtest_profile_id = selected_profile
	expected_resources = int(settings["expected_resources"])
	expected_max_resources = int(settings["expected_max_resources"])
	expected_maximum_lod = int(settings["maximum_lod"])
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
		settings["start"],
		expected_maximum_lod
	)
	game_world.attach_player(player, settings["start"])
	if not await game_world.start_world():
		_fail("gameworld did not start: %s" % game_world.get_last_error())
		return
	_configure_presentation(settings)
	await get_tree().process_frame
	if material_applicator != null:
		material_applicator.call("apply_materials_now")
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
	var presentation: Dictionary = _presentation_summary()
	if not _verify_presentation(presentation):
		return
	print("%s profile=%s addon=%s api_version=%d launch=project_godot player=1 camera=1 crosshair=1 profile_selector=1 telemetry=1 input_edit=1 traversal=1 edit_committed=1 storage_journal=1 cold_idle=1 maximum_lod=%d render_resources=%d collision_resources=%d active_records=%d material=1 materialized=%d production_texture_active=%d full_map_visual=%d full_map_blocks_x=%d full_map_blocks_z=%d presentation=terrain_1_0 validation_internals=0" % [
		MARKER,
		str(selected_profile),
		str(summary.get("addon_id", "")),
		int(summary.get("api_version", 0)),
		int(summary.get("viewer_maximum_lod", 0)),
		int(summary.get("render_resources", 0)),
		int(summary.get("collision_resources", 0)),
		int(summary.get("active_chunk_records", 0)),
		int(presentation.get("materialized_instances", 0)),
		1 if bool(presentation.get("production_texture_active", false)) else 0,
		1 if bool(presentation.get("full_map_enabled", false)) else 0,
		int(presentation.get("full_map_blocks_x", 0)),
		int(presentation.get("full_map_blocks_z", 0)),
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
	if not autonomous:
		telemetry_label.visible = false
		profile_selector.visible = false


func _configure_presentation(_settings: Dictionary) -> void:
	material_applicator = MaterialApplicator.new()
	material_applicator.name = "TerrainMaterialApplicator"
	material_applicator.reference_scene_path = NodePath("../WtGameWorldTerrain")
	game_world.add_child(material_applicator)
	material_applicator.call("apply_materials_now")

	full_map_visual = FullMapVisual.new()
	full_map_visual.name = "FullMapTerrainVisual"
	full_map_visual.enabled = selected_profile == COMPACT_PROFILE
	full_map_visual.enabled_profile_id = COMPACT_PROFILE
	full_map_visual.auto_detect_parent_profile = true
	full_map_visual.chunk_count_x = 128
	full_map_visual.chunk_count_z = 128
	full_map_visual.chunk_size = 16.0
	full_map_visual.grid_segments_x = 128
	full_map_visual.grid_segments_z = 128
	full_map_visual.seed = 19019
	add_child(full_map_visual)


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
		return {"start": Vector3(8, 12, 8), "viewers": [Vector3(8, 8, 8)], "radius": 0, "maximum_lod": 0, "expected_resources": 1, "expected_max_resources": 1, "edit_point": Vector3(8, 8, 8)}
	return {"start": Vector3(1032, 24, 1032), "viewers": [Vector3(1032, 8, 1032)], "radius": 2, "maximum_lod": 1, "expected_resources": 25, "expected_max_resources": 81, "edit_point": Vector3(1032, 8, 1032)}


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
	telemetry_label.text = "profile=%s lod=%d active=%d render=%d collision=%d edits=%d" % [
		str(selected_profile),
		int(summary.get("viewer_maximum_lod", 0)),
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
	if int(summary.get("viewer_maximum_lod", -1)) != expected_maximum_lod:
		_fail("maximum LOD mismatch: %s" % str(summary))
		return false
	for key in ["active_chunk_records", "render_resources", "collision_resources"]:
		if int(summary.get(key, 0)) < expected_resources or int(summary.get(key, 0)) > expected_max_resources:
			_fail("resource mismatch: %s" % str(summary))
			return false
	if selected_profile == FLAT_PROFILE and int(summary.get("active_chunk_records", 0)) != expected_resources:
		_fail("resource mismatch: %s" % str(summary))
		return false
	for key in ["queued_render", "queued_collision", "pending_chunk_retirements", "render_fading_resources"]:
		if int(summary.get(key, 0)) != 0:
			_fail("terrain not cold idle: %s" % str(summary))
			return false
	return true


func _presentation_summary() -> Dictionary:
	var material_summary := {}
	if material_applicator != null and material_applicator.has_method("get_material_quality_summary"):
		material_summary = material_applicator.call("get_material_quality_summary")
	var full_map_summary := {}
	if full_map_visual != null and full_map_visual.has_method("get_full_terrain_visual_summary"):
		full_map_summary = full_map_visual.call("get_full_terrain_visual_summary")
	return {
		"materialized_instances": int(material_summary.get("materialized_instances", 0)),
		"production_texture_active": bool(material_summary.get("production_texture_active", false)),
		"quality_implementation": str(material_summary.get("quality_implementation", "")),
		"full_map_enabled": bool(full_map_summary.get("enabled", false)),
		"full_map_blocks_x": int(full_map_summary.get("coverage_blocks_x", 0)),
		"full_map_blocks_z": int(full_map_summary.get("coverage_blocks_z", 0)),
		"full_map_layer": str(full_map_summary.get("visual_layer_kind", "")),
	}


func _verify_presentation(summary: Dictionary) -> bool:
	if int(summary.get("materialized_instances", 0)) < expected_resources:
		_fail("terrain materials not applied to active render meshes: %s" % str(summary))
		return false
	if not bool(summary.get("production_texture_active", false)):
		_fail("production terrain texture pipeline inactive: %s" % str(summary))
		return false
	if str(summary.get("quality_implementation", "")) != "terrain_material_texture_pipeline_v1":
		_fail("terrain material implementation mismatch: %s" % str(summary))
		return false
	if selected_profile == COMPACT_PROFILE:
		if not bool(summary.get("full_map_enabled", false)):
			_fail("compact 2K full-map visual is not active: %s" % str(summary))
			return false
		if int(summary.get("full_map_blocks_x", 0)) != 2048 or int(summary.get("full_map_blocks_z", 0)) != 2048:
			_fail("compact 2K full-map visual coverage mismatch: %s" % str(summary))
			return false
		if str(summary.get("full_map_layer", "")) != "full_map_deterministic_procedural_lod":
			_fail("compact 2K full-map visual layer mismatch: %s" % str(summary))
			return false
	else:
		if bool(summary.get("full_map_enabled", false)):
			_fail("flat baseline must not enable compact full-map visual: %s" % str(summary))
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

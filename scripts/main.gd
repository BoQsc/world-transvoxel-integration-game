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
const HUMAN_CLEAN_TERRAIN_ALBEDO := "res://assets/terrain_textures/coast_sand_01_diff_1k.jpg"
const HUMAN_CLEAN_TERRAIN_COLOR := Color(0.72, 0.65, 0.50, 1.0)

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
var human_visual_capture_path := ""
var human_visual_capture_mode := "ground"
var human_visual_capture_wait_frames := 90
var expected_resources := 25
var expected_max_resources := 81
var expected_maximum_lod := 1
var edit_point := Vector3.ZERO


func _ready() -> void:
	var args := Array(OS.get_cmdline_user_args())
	autonomous = args.has("--p2-autonomous")
	human_visual_capture_path = _arg_value(args, "--human-visual-capture", "")
	human_visual_capture_mode = _arg_value(args, "--human-visual-capture-mode", "ground")
	human_visual_capture_wait_frames = int(_arg_value(args, "--human-visual-capture-wait-frames", "90"))
	selected_profile = StringName(_arg_value(args, "--p2-profile", str(COMPACT_PROFILE)))
	playtest_profile_id = selected_profile
	if autonomous:
		_clear_autonomous_profile_outputs(selected_profile)
	else:
		if human_visual_capture_path.is_empty():
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		_clear_human_storage()
	_configure_game_lighting()
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
	game_world.human_input_enabled = false
	game_world.startup_requires_cold_idle = bool(settings.get("startup_requires_cold_idle", true))
	game_world.startup_minimum_render_resources = int(settings.get("startup_minimum_render_resources", expected_resources))
	game_world.startup_minimum_collision_resources = int(settings.get("startup_minimum_collision_resources", expected_resources))
	game_world.runtime_active_chunk_capacity = int(settings.get("runtime_active_chunk_capacity", 0))
	game_world.runtime_demand_capacity_per_viewer = int(settings.get("runtime_demand_capacity_per_viewer", 0))
	game_world.runtime_render_entry_capacity = int(settings.get("runtime_render_entry_capacity", 0))
	game_world.runtime_collision_entry_capacity = int(settings.get("runtime_collision_entry_capacity", 0))
	game_world.runtime_lod_refinement_radius_chunks = int(settings.get("runtime_lod_refinement_radius_chunks", 0))
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
	await get_tree().physics_frame
	if not _stabilize_player_spawn():
		return
	_configure_presentation(settings)
	await get_tree().process_frame
	if material_applicator != null:
		material_applicator.call("apply_materials_now")
	_update_telemetry()
	if not autonomous:
		game_world.human_input_enabled = true
		player.call("set_human_input_enabled", true)
		if not human_visual_capture_path.is_empty():
			call_deferred("_capture_human_visual")
	if autonomous:
		await _run_autonomous_proof()


func _run_autonomous_proof() -> void:
	if not _verify_scene_contract():
		return
	var terrain_world: Node = game_world.get_terrain_world()
	if terrain_world == null:
		_fail("terrain world missing")
		return
	await get_tree().physics_frame
	var spawn_summary := _playable_spawn_summary()
	if not _verify_playable_spawn(spawn_summary):
		return
	if not bool(player.call("autonomous_translate", Vector3(16.0, 0.0, 0.0))):
		_fail("player traversal method failed")
		return
	if not bool(game_world.update_player_viewer(true)):
		_fail("player viewer update failed")
		return
	if not await _wait_for_current_profile_settled("after traversal"):
		return
	var before_revision := int(terrain_world.call("get_backend_world_revision"))
	if not bool(player.call("submit_edit_input", &"carve", edit_point)):
		_fail("player edit input path rejected carve")
		return
	if not await game_world.wait_for_world_revision(before_revision + 1):
		_fail("terrain edit did not commit")
		return
	if not await _wait_for_current_profile_settled("after edit"):
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
	print("%s profile=%s addon=%s api_version=%d launch=project_godot player=1 camera=1 crosshair=1 profile_selector=1 telemetry=1 input_edit=1 traversal=1 edit_committed=1 storage_journal=1 streaming_settled=1 spawn_floor_hit=%d spawn_above_floor=%d maximum_lod=%d render_resources=%d collision_resources=%d active_records=%d material=1 materialized=%d production_texture_active=%d native_render_material_override=%d full_map_visual=%d full_map_blocks_x=%d full_map_blocks_z=%d local_detail_exclusion=%d presentation=terrain_1_0 validation_internals=0" % [
		MARKER,
		str(selected_profile),
		str(summary.get("addon_id", "")),
		int(summary.get("api_version", 0)),
		1 if bool(spawn_summary.get("spawn_floor_hit", false)) else 0,
		1 if float(spawn_summary.get("spawn_clearance", 0.0)) > 1.0 else 0,
		int(summary.get("viewer_maximum_lod", 0)),
		int(summary.get("render_resources", 0)),
		int(summary.get("collision_resources", 0)),
		int(summary.get("active_chunk_records", 0)),
		int(presentation.get("materialized_instances", 0)),
		1 if bool(presentation.get("production_texture_active", false)) else 0,
		1 if bool(presentation.get("native_render_material_override", false)) else 0,
		1 if bool(presentation.get("full_map_enabled", false)) else 0,
		int(presentation.get("full_map_blocks_x", 0)),
		int(presentation.get("full_map_blocks_z", 0)),
		1 if bool(presentation.get("local_detail_exclusion", false)) else 0,
	])
	await get_tree().process_frame
	get_tree().quit(0)


func _wait_for_current_profile_settled(context: String) -> bool:
	var settled := false
	if selected_profile == FLAT_PROFILE:
		settled = await game_world.wait_for_cold_idle(expected_resources, expected_resources)
	else:
		settled = await game_world.wait_for_streaming_settled(
			expected_resources,
			expected_resources,
			expected_max_resources
		)
	if settled:
		return true
	var summary := {}
	if game_world != null and game_world.has_method("get_last_settle_summary"):
		summary = game_world.call("get_last_settle_summary")
	_fail("terrain did not reach gameplay-settled state %s: %s" % [context, str(summary)])
	return false


func _build_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "GameHUD"
	add_child(canvas)
	crosshair = Label.new()
	crosshair.name = "Crosshair"
	crosshair.text = "+"
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.offset_left = -4.0
	crosshair.offset_top = -10.0
	crosshair.offset_right = 4.0
	crosshair.offset_bottom = 10.0
	crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	canvas.add_child(crosshair)
	if not autonomous:
		return
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


func _configure_presentation(_settings: Dictionary) -> void:
	material_applicator = MaterialApplicator.new()
	material_applicator.name = "TerrainMaterialApplicator"
	material_applicator.reference_scene_path = NodePath("../WtGameWorldTerrain")
	material_applicator.visual_mode = &"production" if autonomous else &"clean"
	if not autonomous:
		material_applicator.clean_albedo_texture_path = HUMAN_CLEAN_TERRAIN_ALBEDO
		material_applicator.clean_albedo_color = HUMAN_CLEAN_TERRAIN_COLOR
		material_applicator.clean_texture_world_scale = 0.22
	game_world.add_child(material_applicator)
	material_applicator.call("apply_materials_now")

	full_map_visual = FullMapVisual.new()
	full_map_visual.name = "FullMapTerrainVisual"
	full_map_visual.enabled = false
	full_map_visual.enabled_profile_id = COMPACT_PROFILE
	full_map_visual.auto_detect_parent_profile = true
	full_map_visual.chunk_count_x = 128
	full_map_visual.chunk_count_z = 128
	full_map_visual.chunk_size = 16.0
	full_map_visual.grid_segments_x = 128
	full_map_visual.grid_segments_z = 128
	full_map_visual.seed = 19019
	full_map_visual.visual_mode = &"material_id" if autonomous else &"clean"
	if not autonomous:
		full_map_visual.clean_albedo_texture_path = HUMAN_CLEAN_TERRAIN_ALBEDO
		full_map_visual.clean_albedo_color = HUMAN_CLEAN_TERRAIN_COLOR
		full_map_visual.clean_texture_world_scale = 0.22
		full_map_visual.vertical_offset = -0.75
	var viewer_position: Vector3 = _settings["viewers"][0]
	full_map_visual.local_detail_exclusion_enabled = false
	full_map_visual.local_detail_exclusion_center = Vector2(viewer_position.x, viewer_position.z)
	full_map_visual.local_detail_exclusion_half_extent = Vector2(
		float(_settings.get("detail_exclusion_half_extent", 96.0)),
		float(_settings.get("detail_exclusion_half_extent", 96.0))
	)
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
	camera.far = 5000.0
	camera.position = Vector3(0.0, 1.6, 0.0)
	p.add_child(camera)
	return p


func _profile_settings(profile_id: StringName) -> Dictionary:
	if profile_id == FLAT_PROFILE:
		return {"start": Vector3(8, 12, 8), "viewers": [Vector3(8, 8, 8)], "radius": 0, "maximum_lod": 0, "expected_resources": 1, "expected_max_resources": 1, "edit_point": Vector3(8, 8, 8), "detail_exclusion_half_extent": 0.0}
	return {"start": Vector3(1032, 52, 1032), "viewers": [Vector3(1032, 52, 1032)], "radius": 8, "maximum_lod": 3, "expected_resources": 32, "expected_max_resources": 1024, "startup_requires_cold_idle": false, "startup_minimum_render_resources": 32, "startup_minimum_collision_resources": 32, "runtime_active_chunk_capacity": 1024, "runtime_demand_capacity_per_viewer": 8192, "runtime_render_entry_capacity": 1024, "runtime_collision_entry_capacity": 1024, "runtime_lod_refinement_radius_chunks": 1, "edit_point": Vector3(1032, 38, 1032), "detail_exclusion_half_extent": 0.0}


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
		if autonomous:
			return "res://build/production-lifecycle-fixture"
		return "res://build/human-playtest/%s" % str(profile_id)
	if not autonomous:
		return "res://build/human-playtest/%s" % str(profile_id)
	return "res://build/p2-production-game/%s" % str(profile_id)


func _update_telemetry() -> void:
	if telemetry_label == null:
		return
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


func _configure_game_lighting() -> void:
	var world_environment := WorldEnvironment.new()
	world_environment.name = "HumanPlaytestWorldEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.56, 0.70, 0.92)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.86, 0.88, 0.82)
	environment.ambient_light_energy = 0.75
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "HumanPlaytestSun"
	sun.rotation_degrees = Vector3(-48.0, 35.0, 0.0)
	sun.light_energy = 1.35
	sun.shadow_enabled = false
	add_child(sun)


func _clear_human_storage() -> void:
	var root := ProjectSettings.globalize_path("res://build/human-playtest")
	if DirAccess.dir_exists_absolute(root):
		_remove_tree(root)


func _clear_profile_storage(profile_id: StringName) -> void:
	var root := ProjectSettings.globalize_path(_storage_root(profile_id))
	if DirAccess.dir_exists_absolute(root):
		_remove_tree(root)


func _clear_autonomous_profile_outputs(profile_id: StringName) -> void:
	if profile_id != FLAT_PROFILE:
		_clear_profile_storage(profile_id)
		return
	var root := ProjectSettings.globalize_path(_storage_root(profile_id))
	var edit_path := root.path_join("world.wtedit")
	if FileAccess.file_exists(edit_path):
		DirAccess.remove_absolute(edit_path)
	var snapshots_path := root.path_join("snapshots")
	if DirAccess.dir_exists_absolute(snapshots_path):
		_remove_tree(snapshots_path)


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			var child := path.path_join(entry)
			if directory.current_is_dir():
				_remove_tree(child)
			else:
				DirAccess.remove_absolute(child)
		entry = directory.get_next()
	directory.list_dir_end()
	DirAccess.remove_absolute(path)


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
		"native_render_material_override": bool(material_summary.get("native_render_material_override", false)),
		"quality_implementation": str(material_summary.get("quality_implementation", "")),
		"clean_material_variation_enabled": bool(material_summary.get("clean_material_variation_enabled", false)),
		"clean_material_variation_strength": float(material_summary.get("clean_material_variation_strength", 0.0)),
		"full_map_enabled": bool(full_map_summary.get("enabled", false)),
		"full_map_blocks_x": int(full_map_summary.get("coverage_blocks_x", 0)),
		"full_map_blocks_z": int(full_map_summary.get("coverage_blocks_z", 0)),
		"full_map_layer": str(full_map_summary.get("visual_layer_kind", "")),
		"local_detail_exclusion": bool(full_map_summary.get("local_detail_exclusion_enabled", false)),
		"local_detail_exclusion_cells": int(full_map_summary.get("local_detail_exclusion_cells", 0)),
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
	if not bool(summary.get("native_render_material_override", false)):
		_fail("terrain material is not installed through native render override: %s" % str(summary))
		return false
	if bool(summary.get("full_map_enabled", false)):
		_fail("playable terrain must not depend on compact full-map visual: %s" % str(summary))
		return false
	return true


func _playable_spawn_summary() -> Dictionary:
	var result := {
		"spawn_floor_hit": false,
		"spawn_clearance": 0.0,
		"collision_floor_y": -99999.0,
		"spawn_y": player.global_position.y if player != null else -99999.0,
	}
	if player == null:
		return result
	var query := PhysicsRayQueryParameters3D.create(
		player.global_position + Vector3(0.0, 16.0, 0.0),
		player.global_position + Vector3(0.0, -96.0, 0.0)
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	if player is CollisionObject3D:
		query.exclude = [(player as CollisionObject3D).get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var hit_position: Vector3 = hit["position"]
		result["spawn_floor_hit"] = true
		result["collision_floor_y"] = hit_position.y
		result["spawn_clearance"] = player.global_position.y - hit_position.y
	return result


func _stabilize_player_spawn() -> bool:
	var summary := _playable_spawn_summary()
	if not bool(summary.get("spawn_floor_hit", false)):
		_fail("playable spawn has no collision floor below it before human enable: %s" % str(summary))
		return false
	var floor_y := float(summary.get("collision_floor_y", player.global_position.y - 2.0))
	player.global_position.y = floor_y + 2.0
	player.velocity = Vector3.ZERO
	return true


func _verify_playable_spawn(summary: Dictionary) -> bool:
	if not bool(summary.get("spawn_floor_hit", false)):
		_fail("playable spawn has no collision floor below it: %s" % str(summary))
		return false
	var clearance := float(summary.get("spawn_clearance", 0.0))
	if clearance <= 1.0 or clearance > 40.0:
		_fail("playable spawn clearance is invalid: %s" % str(summary))
		return false
	return true


func _arg_value(args: Array, key: String, default_value: String) -> String:
	var index := args.find(key)
	if index >= 0 and index + 1 < args.size():
		return str(args[index + 1])
	return default_value


func _capture_human_visual() -> void:
	await _apply_capture_camera_mode()
	for _frame in range(30):
		await get_tree().process_frame
	var image := get_viewport().get_texture().get_image()
	image.save_png(human_visual_capture_path)
	var summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
	var presentation: Dictionary = _presentation_summary()
	print("WT_HUMAN_VISUAL_CAPTURE_SUMMARY ", JSON.stringify({
		"mode": human_visual_capture_mode,
		"profile": str(selected_profile),
		"viewer_radius_chunks": int(summary.get("viewer_radius_chunks", 0)),
		"viewer_maximum_lod": int(summary.get("viewer_maximum_lod", 0)),
		"runtime_demand_capacity_per_viewer": int(summary.get("runtime_demand_capacity_per_viewer", 0)),
		"runtime_lod_refinement_radius_chunks": int(summary.get("runtime_lod_refinement_radius_chunks", 0)),
		"active_chunk_records": int(summary.get("active_chunk_records", 0)),
		"render_resources": int(summary.get("render_resources", 0)),
		"collision_resources": int(summary.get("collision_resources", 0)),
		"full_map_enabled": bool(presentation.get("full_map_enabled", false)),
		"materialized_instances": int(presentation.get("materialized_instances", 0)),
		"native_render_material_override": bool(presentation.get("native_render_material_override", false)),
		"clean_material_variation_enabled": bool(presentation.get("clean_material_variation_enabled", false)),
		"clean_material_variation_strength": float(presentation.get("clean_material_variation_strength", 0.0)),
		"capture_path": human_visual_capture_path,
	}))
	get_tree().quit(0)


func _apply_capture_camera_mode() -> void:
	if player == null:
		return
	if player.has_method("set_human_input_enabled"):
		player.call("set_human_input_enabled", false)
	var camera := player.get_node_or_null("FirstPersonCamera") as Camera3D
	if camera == null:
		return
	camera.far = 5000.0
	var capture_position := player.global_position
	var capture_target := Vector3(1032.0, 8.0, 1032.0)
	match human_visual_capture_mode:
		"topdown":
			capture_position = Vector3(1032.0, 420.0, 1032.0)
			capture_target = Vector3(1032.0, 8.0, 1032.1)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"aerial":
			capture_position = Vector3(1032.0, 220.0, 920.0)
			capture_target = Vector3(1032.0, 8.0, 1032.0)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"high_oblique":
			capture_position = Vector3(1032.0, 140.0, 820.0)
			capture_target = Vector3(1032.0, 8.0, 1032.0)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"local_overlap":
			capture_position = Vector3(1032.0, 72.0, 972.0)
			capture_target = Vector3(1032.0, 6.0, 1048.0)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		_:
			return
	camera.fov = 75.0
	camera.far = 5000.0
	var up_vector := Vector3.UP
	if human_visual_capture_mode == "topdown":
		up_vector = Vector3.FORWARD
	camera.look_at_from_position(capture_position, capture_target, up_vector)
	camera.current = true
	camera.make_current()
	if game_world != null and game_world.has_method("update_player_viewer"):
		game_world.call("update_player_viewer", true)
	for _frame in range(maxi(human_visual_capture_wait_frames, 0)):
		await get_tree().process_frame
	if material_applicator != null:
		material_applicator.call("apply_materials_now")


func _fail(message: String) -> void:
	push_error("WT_PRODUCTION_GAME_P2_FAIL: " + message)
	if autonomous or not human_visual_capture_path.is_empty():
		get_tree().quit(1)

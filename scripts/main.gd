extends Node3D

const MARKER := "WT_PRODUCTION_GAME_P2_PASS"
const ADDON_ID := "world_transvoxel_gameworld"
const COMPACT_PROFILE := &"g19_compact_2k_on_demand"
const FLAT_PROFILE := &"flat_baseline"
const DEFAULT_HUMAN_PROFILE := FLAT_PROFILE
const DEFAULT_AUTONOMOUS_PROFILE := COMPACT_PROFILE
const GameWorldNode := preload("res://addons/world_transvoxel_gameworld/wt_game_world_node.gd")
const GenerationProfile := preload("res://addons/world_transvoxel_terrain/generation/wt_terrain_generation_profile.gd")
const StorageProfile := preload("res://addons/world_transvoxel_terrain/storage/wt_terrain_storage_profile.gd")
const MaterialApplicator := preload("res://addons/world_transvoxel_terrain/material/wt_terrain_material_applicator.gd")
const FullMapVisual := preload("res://addons/world_transvoxel_terrain/visual/wt_terrain_full_map_visual.gd")
const PlayerScript := preload("res://scripts/wt_production_player.gd")
const EditOperation := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd")
const EditBatch := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd")
const WatertightnessProbe := preload("res://addons/world_transvoxel_terrain/debug/wt_terrain_watertightness_probe.gd")
const HUMAN_CLEAN_TERRAIN_ALBEDO := "res://assets/terrain_textures/coast_sand_01_diff_1k.jpg"
const HUMAN_CLEAN_TERRAIN_COLOR := Color(0.72, 0.65, 0.50, 1.0)

var playtest_profile_id: StringName = DEFAULT_HUMAN_PROFILE
var game_world: Node
var player: CharacterBody3D
var telemetry_label: Label
var profile_selector: OptionButton
var crosshair: Label
var material_applicator: Node
var full_map_visual: MeshInstance3D
var selected_profile: StringName = DEFAULT_HUMAN_PROFILE
var autonomous := false
var human_visual_capture_path := ""
var human_visual_capture_mode := "ground"
var human_visual_capture_wait_frames := 90
var expected_resources := 25
var expected_max_resources := 81
var expected_maximum_lod := 1
var edit_point := Vector3.ZERO
var world_environment: WorldEnvironment
var environment_resource: Environment
var sun_light: DirectionalLight3D
var terrain_overhead_light: OmniLight3D
var terrain_probe_light: SpotLight3D
var terrain_static_lights: Array = []
var terrain_static_light_markers: Array = []
var lighting_preset_index := 0
var initial_lighting_preset := 0
var local_terrain_lights_enabled := false
var interaction_inspection_applied := false
var interaction_inspection_operation_count := 0
var last_watertightness_summary := {}


func _ready() -> void:
	var args := Array(OS.get_cmdline_user_args())
	autonomous = args.has("--p2-autonomous")
	human_visual_capture_path = _arg_value(args, "--human-visual-capture", "")
	human_visual_capture_mode = _arg_value(args, "--human-visual-capture-mode", "ground")
	human_visual_capture_wait_frames = int(_arg_value(args, "--human-visual-capture-wait-frames", "90"))
	initial_lighting_preset = int(_arg_value(args, "--human-lighting-preset", "0"))
	var default_profile := str(DEFAULT_AUTONOMOUS_PROFILE if autonomous else DEFAULT_HUMAN_PROFILE)
	selected_profile = StringName(_arg_value(args, "--p2-profile", default_profile))
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
	game_world.runtime_render_apply_budget = int(settings.get("runtime_render_apply_budget", 0))
	game_world.runtime_collision_apply_budget = int(settings.get("runtime_collision_apply_budget", 0))
	game_world.runtime_collision_activation_distance = float(settings.get("runtime_collision_activation_distance", 0.0))
	game_world.runtime_collision_deactivation_distance = float(settings.get("runtime_collision_deactivation_distance", 0.0))
	add_child(game_world)
	player = _create_player(settings["start"])
	player.game_world = game_world
	player.edit_point = edit_point
	player.human_command_target = self
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
	if not await _stabilize_player_spawn():
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


func _process(_delta: float) -> void:
	_update_terrain_inspection_lights()


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
	if not await _run_repeated_edit_health_proof(terrain_world):
		return
	if not await _run_interaction_raycast_proof(terrain_world):
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
	print("%s profile=%s addon=%s api_version=%d launch=project_godot player=1 camera=1 crosshair=1 profile_selector=1 telemetry=1 input_edit=1 traversal=1 edit_committed=1 repeated_edits=1 interaction_raycast=1 storage_journal=1 streaming_settled=1 spawn_floor_hit=%d spawn_above_floor=%d maximum_lod=%d render_resources=%d collision_resources=%d active_records=%d edit_commits=%d edit_failures=%d material=1 materialized=%d production_texture_active=%d native_render_material_override=%d full_map_visual=%d full_map_blocks_x=%d full_map_blocks_z=%d local_detail_exclusion=%d presentation=terrain_1_0 validation_internals=0" % [
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
		int(summary.get("edit_commit_count", 0)),
		int(summary.get("edit_failure_count", 0)),
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


func _run_repeated_edit_health_proof(terrain_world: Node) -> bool:
	var operations := [
		{"mode": &"carve", "center": edit_point + Vector3(4.0, 0.0, 0.0)},
		{"mode": &"construct", "center": edit_point + Vector3(-4.0, 0.0, 0.0)},
		{"mode": &"carve", "center": edit_point + Vector3(0.0, 0.0, 4.0)},
	]
	for index in range(operations.size()):
		var operation: Dictionary = operations[index]
		var before_revision := int(terrain_world.call("get_backend_world_revision"))
		if not bool(player.call("submit_edit_input", operation["mode"], operation["center"])):
			_fail("repeated edit input path rejected operation %d" % index)
			return false
		if not await game_world.wait_for_world_revision(before_revision + 1):
			_fail("repeated edit operation %d did not commit" % index)
			return false
		if not await _wait_for_current_profile_settled("after repeated edit %d" % index):
			return false
		var summary: Dictionary = game_world.get_game_world_summary()
		if int(summary.get("edit_failure_count", 0)) != 0:
			_fail("backend rejected a repeated edit: %s" % str(summary))
			return false
	return true


func _run_interaction_raycast_proof(terrain_world: Node) -> bool:
	var approximate_target := edit_point + Vector3(18.0, 0.0, 18.0)
	player.global_position = approximate_target + Vector3(-26.0, 18.0, -54.0)
	player.velocity = Vector3.ZERO
	if not bool(game_world.update_player_viewer(true)):
		_fail("interaction proof viewer update failed")
		return false
	if not await _wait_for_current_profile_settled("before interaction raycast proof"):
		return false
	await get_tree().physics_frame
	var target := _find_collision_surface_near([
		approximate_target,
		edit_point + Vector3(24.0, 0.0, 0.0),
		edit_point + Vector3(0.0, 0.0, 24.0),
		edit_point + Vector3(-24.0, 0.0, 0.0),
	])
	if is_inf(target.x):
		var no_surface_summary: Dictionary = game_world.get_game_world_summary()
		_fail("interaction proof could not find nearby terrain collision surface: %s" % str(no_surface_summary))
		return false
	player.global_position = target + Vector3(-26.0, 18.0, -54.0)
	player.velocity = Vector3.ZERO
	if not bool(game_world.update_player_viewer(true)):
		_fail("interaction proof precise viewer update failed")
		return false
	if not await _wait_for_current_profile_settled("before precise interaction raycast proof"):
		return false
	if not bool(player.call("autonomous_look_at", target)):
		_fail("interaction proof could not aim camera")
		return false
	await get_tree().physics_frame
	var before_revision := int(terrain_world.call("get_backend_world_revision"))
	if not bool(player.call("autonomous_submit_interaction", &"carve")):
		var interaction_summary: Dictionary = player.call("get_last_interaction_summary")
		_fail("interaction raycast path rejected carve: %s" % str(interaction_summary))
		return false
	var summary_after_submit: Dictionary = player.call("get_last_interaction_summary")
	if not bool(summary_after_submit.get("ray_hit", false)):
		_fail("interaction raycast did not hit terrain collision: %s" % str(summary_after_submit))
		return false
	if not bool(summary_after_submit.get("accepted", false)):
		_fail("interaction raycast edit was not accepted: %s" % str(summary_after_submit))
		return false
	if not await game_world.wait_for_world_revision(before_revision + 1):
		_fail("interaction raycast edit did not commit")
		return false
	if not await _wait_for_current_profile_settled("after interaction raycast edit"):
		return false
	var game_summary: Dictionary = game_world.get_game_world_summary()
	if int(game_summary.get("edit_failure_count", 0)) != 0:
		_fail("backend rejected interaction raycast edit: %s" % str(game_summary))
		return false
	return true


func _find_collision_surface_near(points: Array) -> Vector3:
	for point in points:
		var probe: Vector3 = point
		var query := PhysicsRayQueryParameters3D.create(
			probe + Vector3(0.0, 180.0, 0.0),
			probe + Vector3(0.0, -240.0, 0.0)
		)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		if player is CollisionObject3D:
			query.exclude = [(player as CollisionObject3D).get_rid()]
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			return hit["position"]
	return Vector3(INF, INF, INF)


func _wait_for_current_profile_settled(context: String) -> bool:
	var settled := false
	if expected_maximum_lod == 0:
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
		return {
			"start": Vector3(1032, 18, 1032),
			"viewers": [Vector3(1032, 18, 1032)],
			"radius": 8,
			"maximum_lod": 3,
			"expected_resources": 32,
			"expected_max_resources": 1024,
			"startup_requires_cold_idle": false,
			"startup_minimum_render_resources": 32,
			"startup_minimum_collision_resources": 32,
			"runtime_active_chunk_capacity": 1024,
			"runtime_demand_capacity_per_viewer": 8192,
			"runtime_render_entry_capacity": 1024,
			"runtime_collision_entry_capacity": 1024,
			"runtime_lod_refinement_radius_chunks": 1,
			"runtime_render_apply_budget": 8,
			"runtime_collision_apply_budget": 8,
			"runtime_collision_activation_distance": 192.0,
			"runtime_collision_deactivation_distance": 256.0,
			"edit_point": Vector3(1032, 8, 1032),
			"detail_exclusion_half_extent": 0.0,
		}
	return {
		"start": Vector3(1184, 142, 1008),
		"viewers": [Vector3(1184, 142, 1008)],
		"radius": 8,
		"maximum_lod": 3,
		"expected_resources": 32,
		"expected_max_resources": 1024,
		"startup_requires_cold_idle": false,
		"startup_minimum_render_resources": 32,
		"startup_minimum_collision_resources": 32,
		"runtime_active_chunk_capacity": 1024,
		"runtime_demand_capacity_per_viewer": 8192,
		"runtime_render_entry_capacity": 1024,
		"runtime_collision_entry_capacity": 1024,
		"runtime_lod_refinement_radius_chunks": 1,
		"runtime_render_apply_budget": 8,
		"runtime_collision_apply_budget": 8,
		"runtime_collision_activation_distance": 192.0,
		"runtime_collision_deactivation_distance": 256.0,
		"edit_point": Vector3(1184, 119, 1008),
		"detail_exclusion_half_extent": 0.0,
	}


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
		generation.world_chunk_count_x = 128
		generation.world_chunk_count_z = 128
		generation.source_mode = GenerationProfile.SourceMode.FLAT
	return generation


func _storage_profile(profile_id: StringName) -> Resource:
	var storage = StorageProfile.new()
	storage.profile_id = profile_id
	var root_path := _storage_root(profile_id)
	storage.world_manifest_path = "%s/procedural.wtseed" % root_path
	storage.object_root_path = root_path
	storage.edit_journal_path = "%s/world.wtedit" % root_path
	storage.snapshot_directory = "%s/snapshots" % root_path
	storage.allow_res_paths_for_test_fixtures = true
	return storage


func _storage_root(profile_id: StringName) -> String:
	if profile_id == FLAT_PROFILE:
		if autonomous:
			return "res://build/p2-production-game/%s" % str(profile_id)
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
	world_environment = WorldEnvironment.new()
	world_environment.name = "HumanPlaytestWorldEnvironment"
	environment_resource = Environment.new()
	environment_resource.background_mode = Environment.BG_COLOR
	environment_resource.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world_environment.environment = environment_resource
	add_child(world_environment)

	sun_light = DirectionalLight3D.new()
	sun_light.name = "HumanPlaytestSun"
	sun_light.shadow_enabled = false
	add_child(sun_light)

	terrain_overhead_light = OmniLight3D.new()
	terrain_overhead_light.name = "TerrainInspectionOverheadLight"
	terrain_overhead_light.omni_range = 28.0
	terrain_overhead_light.light_energy = 2.2
	terrain_overhead_light.visible = false
	add_child(terrain_overhead_light)

	terrain_probe_light = SpotLight3D.new()
	terrain_probe_light.name = "TerrainInspectionProbeLight"
	terrain_probe_light.spot_range = 42.0
	terrain_probe_light.spot_angle = 46.0
	terrain_probe_light.light_energy = 3.0
	terrain_probe_light.visible = false
	add_child(terrain_probe_light)

	_create_static_terrain_inspection_lights()

	_apply_lighting_preset(initial_lighting_preset)
	set_process(true)


func handle_human_command(command: StringName) -> bool:
	match command:
		&"cycle_lighting":
			_apply_lighting_preset((lighting_preset_index + 1) % 4)
			return true
		&"toggle_local_lights":
			_set_local_terrain_lights_enabled(not local_terrain_lights_enabled)
			return true
	return false


func _apply_lighting_preset(index: int) -> void:
	lighting_preset_index = int(clamp(index, 0, 3))
	if environment_resource == null or sun_light == null:
		return
	match lighting_preset_index:
		0:
			environment_resource.background_color = Color(0.56, 0.70, 0.92)
			environment_resource.ambient_light_color = Color(0.86, 0.88, 0.82)
			environment_resource.ambient_light_energy = 0.75
			sun_light.rotation_degrees = Vector3(-48.0, 35.0, 0.0)
			sun_light.light_color = Color(1.0, 0.96, 0.88)
			sun_light.light_energy = 1.35
			_set_local_terrain_lights_enabled(false)
		1:
			environment_resource.background_color = Color(0.42, 0.50, 0.66)
			environment_resource.ambient_light_color = Color(0.58, 0.62, 0.68)
			environment_resource.ambient_light_energy = 0.42
			sun_light.rotation_degrees = Vector3(-13.0, 62.0, 0.0)
			sun_light.light_color = Color(1.0, 0.72, 0.46)
			sun_light.light_energy = 1.55
			_set_local_terrain_lights_enabled(false)
		2:
			environment_resource.background_color = Color(0.50, 0.55, 0.58)
			environment_resource.ambient_light_color = Color(0.78, 0.80, 0.78)
			environment_resource.ambient_light_energy = 0.95
			sun_light.rotation_degrees = Vector3(-70.0, 20.0, 0.0)
			sun_light.light_color = Color(0.84, 0.88, 0.92)
			sun_light.light_energy = 0.28
			_set_local_terrain_lights_enabled(false)
		_:
			environment_resource.background_color = Color(0.04, 0.05, 0.07)
			environment_resource.ambient_light_color = Color(0.10, 0.12, 0.16)
			environment_resource.ambient_light_energy = 0.18
			sun_light.rotation_degrees = Vector3(-58.0, -25.0, 0.0)
			sun_light.light_color = Color(0.50, 0.62, 1.0)
			sun_light.light_energy = 0.18
			_set_local_terrain_lights_enabled(true)
	if not autonomous and human_visual_capture_path.is_empty():
		print("human_lighting_preset=%d local_lights=%s" % [
			lighting_preset_index,
			"on" if local_terrain_lights_enabled else "off",
		])


func _set_local_terrain_lights_enabled(enabled: bool) -> void:
	local_terrain_lights_enabled = enabled
	if terrain_overhead_light != null:
		terrain_overhead_light.visible = enabled
	if terrain_probe_light != null:
		terrain_probe_light.visible = enabled
	for light in terrain_static_lights:
		if light is Light3D:
			(light as Light3D).visible = enabled
	for marker in terrain_static_light_markers:
		if marker is Node3D:
			(marker as Node3D).visible = enabled


func _update_terrain_inspection_lights() -> void:
	if player == null or not local_terrain_lights_enabled:
		return
	var base := player.global_position
	var forward := -player.global_transform.basis.z
	var camera := player.get_node_or_null("FirstPersonCamera") as Camera3D
	if camera != null:
		forward = -camera.global_transform.basis.z
	if terrain_overhead_light != null:
		terrain_overhead_light.global_position = base + Vector3(0.0, 7.5, 0.0)
	if terrain_probe_light != null:
		terrain_probe_light.global_position = base + Vector3(0.0, 4.5, 0.0) - forward * 5.0
		terrain_probe_light.look_at(base + forward * 10.0, Vector3.UP)


func _create_static_terrain_inspection_lights() -> void:
	terrain_static_lights.clear()
	terrain_static_light_markers.clear()
	var points := _terrain_inspection_light_points()
	for index in range(points.size()):
		var entry: Dictionary = points[index]
		var position: Vector3 = entry["position"]
		var color: Color = entry["color"]
		var light := OmniLight3D.new()
		light.name = "TerrainInspectionStaticLight%02d" % index
		light.position = position
		light.light_color = color
		light.light_energy = float(entry.get("energy", 1.55))
		light.omni_range = float(entry.get("range", 92.0))
		light.shadow_enabled = false
		light.visible = false
		add_child(light)
		terrain_static_lights.append(light)

		var marker := MeshInstance3D.new()
		marker.name = "TerrainInspectionLightMarker%02d" % index
		var sphere := SphereMesh.new()
		sphere.radius = 2.2
		sphere.height = 4.4
		marker.mesh = sphere
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = color
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 2.5
		marker.material_override = material
		marker.position = position
		marker.visible = false
		add_child(marker)
		terrain_static_light_markers.append(marker)


func _terrain_inspection_light_points() -> Array:
	if selected_profile == FLAT_PROFILE:
		return [
			{"position": Vector3(960, 22, 960), "color": Color(1.0, 0.48, 0.30), "range": 75.0},
			{"position": Vector3(1032, 22, 960), "color": Color(0.35, 0.72, 1.0), "range": 75.0},
			{"position": Vector3(1104, 22, 960), "color": Color(0.45, 1.0, 0.55), "range": 75.0},
			{"position": Vector3(960, 22, 1032), "color": Color(1.0, 0.86, 0.35), "range": 75.0},
			{"position": Vector3(1104, 22, 1032), "color": Color(0.86, 0.48, 1.0), "range": 75.0},
			{"position": Vector3(960, 22, 1104), "color": Color(0.35, 1.0, 0.92), "range": 75.0},
			{"position": Vector3(1032, 22, 1104), "color": Color(1.0, 0.62, 0.40), "range": 75.0},
			{"position": Vector3(1104, 22, 1104), "color": Color(0.58, 0.66, 1.0), "range": 75.0},
		]
	return [
		{"position": Vector3(1184, 136, 1008), "color": Color(1.0, 0.45, 0.28), "range": 115.0, "energy": 1.9},
		{"position": Vector3(1032, 81, 1032), "color": Color(0.35, 0.68, 1.0), "range": 105.0, "energy": 1.6},
		{"position": Vector3(860, 88, 1220), "color": Color(0.55, 1.0, 0.48), "range": 100.0, "energy": 1.5},
		{"position": Vector3(1400, 95, 700), "color": Color(1.0, 0.90, 0.36), "range": 105.0, "energy": 1.5},
		{"position": Vector3(1250, 106, 950), "color": Color(0.92, 0.45, 1.0), "range": 100.0, "energy": 1.55},
		{"position": Vector3(980, 66, 1160), "color": Color(0.38, 1.0, 0.95), "range": 95.0, "energy": 1.45},
		{"position": Vector3(1110, 84, 880), "color": Color(1.0, 0.62, 0.32), "range": 95.0, "energy": 1.45},
		{"position": Vector3(760, 48, 760), "color": Color(0.52, 0.62, 1.0), "range": 90.0, "energy": 1.35},
		{"position": Vector3(1510, 57, 1120), "color": Color(1.0, 0.34, 0.40), "range": 95.0, "energy": 1.35},
		{"position": Vector3(1320, 50, 1260), "color": Color(0.70, 1.0, 0.38), "range": 90.0, "energy": 1.35},
		{"position": Vector3(920, 66, 900), "color": Color(0.38, 0.82, 1.0), "range": 90.0, "energy": 1.35},
		{"position": Vector3(1200, 67, 1160), "color": Color(1.0, 0.78, 0.45), "range": 95.0, "energy": 1.4},
		{"position": Vector3(1184, 108, 1060), "color": Color(0.78, 0.48, 1.0), "range": 95.0, "energy": 1.45},
		{"position": Vector3(1080, 87, 980), "color": Color(0.48, 1.0, 0.70), "range": 90.0, "energy": 1.4},
	]


func _clear_human_storage() -> void:
	var root := ProjectSettings.globalize_path("res://build/human-playtest")
	if DirAccess.dir_exists_absolute(root):
		_remove_tree(root)


func _clear_profile_storage(profile_id: StringName) -> void:
	var root := ProjectSettings.globalize_path(_storage_root(profile_id))
	if DirAccess.dir_exists_absolute(root):
		_remove_tree(root)


func _clear_autonomous_profile_outputs(profile_id: StringName) -> void:
	_clear_profile_storage(profile_id)


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
	if expected_maximum_lod == 0 and int(summary.get("active_chunk_records", 0)) != expected_resources:
		_fail("resource mismatch: %s" % str(summary))
		return false
	for key in ["queued_render", "queued_collision", "pending_chunk_retirements", "render_fading_resources"]:
		if int(summary.get(key, 0)) != 0:
			_fail("terrain not cold idle: %s" % str(summary))
			return false
	if int(summary.get("edit_failure_count", 0)) != 0:
		_fail("terrain edit failure count is nonzero: %s" % str(summary))
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
		"clean_roughness": float(material_summary.get("clean_roughness", 0.0)),
		"clean_specular": float(material_summary.get("clean_specular", 1.0)),
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
		player.global_position + Vector3(0.0, 96.0, 0.0),
		player.global_position + Vector3(0.0, -180.0, 0.0)
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
	var summary := {}
	for _frame in range(180):
		summary = _playable_spawn_summary()
		if bool(summary.get("spawn_floor_hit", false)):
			break
		if game_world != null and game_world.has_method("update_player_viewer"):
			game_world.call("update_player_viewer", true)
		await get_tree().physics_frame
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
	if _capture_requires_interaction_inspection():
		if not await _apply_interaction_inspection_edits():
			return
	await _apply_capture_camera_mode()
	for _frame in range(30):
		await get_tree().process_frame
	last_watertightness_summary = _collect_watertightness_summary()
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
		"runtime_render_apply_budget": int(summary.get("runtime_render_apply_budget", 0)),
		"runtime_collision_apply_budget": int(summary.get("runtime_collision_apply_budget", 0)),
		"runtime_collision_activation_distance": float(summary.get("runtime_collision_activation_distance", 0.0)),
		"runtime_collision_deactivation_distance": float(summary.get("runtime_collision_deactivation_distance", 0.0)),
		"active_chunk_records": int(summary.get("active_chunk_records", 0)),
		"render_resources": int(summary.get("render_resources", 0)),
		"collision_resources": int(summary.get("collision_resources", 0)),
		"edit_submission_count": int(summary.get("edit_submission_count", 0)),
		"edit_accept_count": int(summary.get("edit_accept_count", 0)),
		"edit_commit_count": int(summary.get("edit_commit_count", 0)),
		"edit_failure_count": int(summary.get("edit_failure_count", 0)),
		"edit_lod_retention_zones": int(summary.get("edit_lod_retention_zones", 0)),
		"edit_lod_retention_active_viewers": int(summary.get("edit_lod_retention_active_viewers", 0)),
		"edit_lod_retention_plans": int(summary.get("edit_lod_retention_plans", 0)),
		"edit_lod_retention_fallbacks": int(summary.get("edit_lod_retention_fallbacks", 0)),
		"full_map_enabled": bool(presentation.get("full_map_enabled", false)),
		"materialized_instances": int(presentation.get("materialized_instances", 0)),
		"native_render_material_override": bool(presentation.get("native_render_material_override", false)),
		"clean_material_variation_enabled": bool(presentation.get("clean_material_variation_enabled", false)),
		"clean_material_variation_strength": float(presentation.get("clean_material_variation_strength", 0.0)),
		"clean_roughness": float(presentation.get("clean_roughness", 0.0)),
		"clean_specular": float(presentation.get("clean_specular", 1.0)),
		"lighting_preset": lighting_preset_index,
		"local_terrain_lights_enabled": local_terrain_lights_enabled,
		"interaction_inspection_applied": interaction_inspection_applied,
		"interaction_inspection_operation_count": interaction_inspection_operation_count,
		"watertightness": last_watertightness_summary,
		"capture_path": human_visual_capture_path,
	}))
	if _capture_requires_watertightness_probe() and not bool(last_watertightness_summary.get("ok", false)):
		push_error("WT_WATERTIGHTNESS_FAIL: %s" % JSON.stringify(last_watertightness_summary))
		get_tree().quit(1)
		return
	get_tree().quit(0)


func _capture_requires_interaction_inspection() -> bool:
	return human_visual_capture_mode.begins_with("edit_") or \
		human_visual_capture_mode.begins_with("small_edit_") or \
		human_visual_capture_mode.begins_with("watertight_") or \
		human_visual_capture_mode == "interaction_near" or \
		human_visual_capture_mode == "interaction_far" or \
		human_visual_capture_mode == "interaction_aerial"


func _capture_requires_watertightness_probe() -> bool:
	return human_visual_capture_mode.begins_with("watertight_")


func _apply_interaction_inspection_edits() -> bool:
	if interaction_inspection_applied:
		return true
	var terrain_world: Node = game_world.get_terrain_world() if game_world != null else null
	if terrain_world == null:
		_fail("terrain world unavailable for interaction inspection")
		return false
	var before_revision := int(terrain_world.call("get_backend_world_revision"))
	var batch = EditBatch.new()
	for operation in _interaction_inspection_operations():
		if not batch.add_operation(operation):
			_fail("failed to add interaction inspection operation")
			return false
	interaction_inspection_operation_count = batch.get_operation_count()
	if interaction_inspection_operation_count <= 0:
		_fail("interaction inspection produced no operations")
		return false
	if not bool(terrain_world.call("submit_edit_batch", batch, 7717)):
		_fail("interaction inspection edit batch rejected: %s" % str(terrain_world.call("get_last_error")))
		return false
	if not await game_world.wait_for_world_revision(before_revision + 1):
		_fail("interaction inspection edit did not commit")
		return false
	if not await _wait_for_current_profile_settled("after interaction inspection edits"):
		return false
	if material_applicator != null:
		material_applicator.call("apply_materials_now")
	interaction_inspection_applied = true
	return true


func _interaction_inspection_operations() -> Array:
	var operations: Array = []
	if human_visual_capture_mode.begins_with("watertight_"):
		var center := _watertightness_edit_center()
		operations.append(_edit_operation(&"carve", center, 7.5, 1, 1.0))
		operations.append(_edit_operation(&"carve", center + Vector3(5.25, 0.0, 0.0), 5.5, 1, 1.0))
		operations.append(_edit_operation(&"carve", center + Vector3(0.0, -4.5, 5.25), 5.0, 1, 1.0))
		operations.append(_edit_operation(&"construct", center + Vector3(-4.5, 1.5, 4.5), 4.25, 4, 1.0))
		operations.append(_edit_operation(&"paint", center + Vector3(2.0, -1.5, -4.0), 6.0, 7, 1.0))
		return operations
	if human_visual_capture_mode.begins_with("small_edit_"):
		var center := edit_point
		operations.append(_edit_operation(&"carve", center, 1.8, 1, 1.0))
		operations.append(_edit_operation(&"carve", center + Vector3(2.4, 0.0, 0.0), 1.8, 1, 1.0))
		operations.append(_edit_operation(&"carve", center + Vector3(0.0, 0.0, 2.4), 1.8, 1, 1.0))
		operations.append(_edit_operation(&"carve", center + Vector3(2.4, 0.0, 2.4), 1.8, 1, 1.0))
		return operations
	if selected_profile == FLAT_PROFILE:
		operations.append(_edit_operation(&"carve", Vector3(1010, 8, 1010), 18.0, 1, 1.0))
		operations.append(_edit_operation(&"construct", Vector3(1058, 10, 1018), 14.0, 4, 1.0))
		operations.append(_edit_operation(&"carve", Vector3(1120, 8, 1100), 24.0, 1, 1.0))
		operations.append(_edit_operation(&"paint", Vector3(980, 9, 1090), 20.0, 7, 1.0))
		return operations
	operations.append(_edit_operation(&"carve", Vector3(1184, 119, 1008), 26.0, 1, 1.0))
	operations.append(_edit_operation(&"construct", Vector3(1230, 94, 982), 17.0, 4, 1.0))
	operations.append(_edit_operation(&"paint", Vector3(1128, 84, 1048), 30.0, 7, 1.0))
	operations.append(_edit_operation(&"carve", Vector3(860, 72, 1220), 24.0, 1, 1.0))
	operations.append(_edit_operation(&"construct", Vector3(900, 72, 1182), 15.0, 3, 1.0))
	operations.append(_edit_operation(&"carve", Vector3(1400, 64, 700), 28.0, 1, 1.0))
	operations.append(_edit_operation(&"paint", Vector3(1320, 46, 1260), 26.0, 4, 1.0))
	return operations


func _edit_operation(
	mode_name: StringName,
	center: Vector3,
	radius: float,
	material_id: int,
	density_value: float
) -> Resource:
	var operation = EditOperation.new()
	operation.mode = _edit_mode(mode_name)
	operation.brush_shape = EditOperation.BrushShape.SPHERE
	operation.center = center
	operation.radius = radius
	operation.material_id = material_id
	operation.density_value = density_value
	return operation


func _edit_mode(mode_name: StringName) -> int:
	match mode_name:
		&"construct", &"place":
			return EditOperation.Mode.CONSTRUCT
		&"fill":
			return EditOperation.Mode.FILL
		&"paint":
			return EditOperation.Mode.PAINT
		&"restore_to_base":
			return EditOperation.Mode.RESTORE_TO_BASE
		_:
			return EditOperation.Mode.CARVE


func _watertightness_edit_center() -> Vector3:
	if selected_profile == FLAT_PROFILE:
		return Vector3(1040.0, 8.0, 1040.0)
	return Vector3(1184.0, 119.0, 1008.0)


func _watertightness_probe_center() -> Vector3:
	if human_visual_capture_mode.begins_with("watertight_"):
		return _watertightness_edit_center()
	if human_visual_capture_mode.begins_with("small_edit_"):
		return edit_point + Vector3(1.2, 0.0, 1.2)
	if selected_profile == FLAT_PROFILE:
		return Vector3(1040.0, 8.0, 1040.0)
	return Vector3(1184.0, 119.0, 1008.0)


func _watertightness_probe_radius() -> float:
	if human_visual_capture_mode.begins_with("small_edit_"):
		return 18.0
	if human_visual_capture_mode.begins_with("watertight_"):
		return 36.0
	return 56.0


func _collect_watertightness_summary() -> Dictionary:
	if not _capture_requires_interaction_inspection():
		return {
			"enabled": false,
			"ok": true,
		}
	var terrain_world: Node = game_world.get_terrain_world() if game_world != null else null
	if terrain_world == null or not terrain_world.has_method("get_backend_terrain"):
		return {
			"enabled": true,
			"ok": false,
			"error": "terrain_world_unavailable",
		}
	var backend: Node = terrain_world.call("get_backend_terrain")
	if backend == null:
		return {
			"enabled": true,
			"ok": false,
			"error": "backend_unavailable",
		}
	return WatertightnessProbe.collect(
		backend,
		human_visual_capture_mode,
		_watertightness_probe_center(),
		_watertightness_probe_radius()
	)


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
			capture_target = Vector3(1032.0, 40.0, 1032.1)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"aerial":
			capture_position = Vector3(1120.0, 250.0, 760.0)
			capture_target = Vector3(1160.0, 78.0, 1020.0)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"high_oblique":
			capture_position = Vector3(1160.0, 190.0, 760.0)
			capture_target = Vector3(1184.0, 116.0, 1008.0)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"local_overlap":
			capture_position = Vector3(1180.0, 150.0, 940.0)
			capture_target = Vector3(1184.0, 118.0, 1008.0)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"watertight_boundary_near":
			capture_target = _watertightness_edit_center()
			capture_position = capture_target + Vector3(-14.0, 21.0, -58.0)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"small_edit_near":
			capture_target = edit_point + Vector3(1.2, 0.0, 1.2)
			capture_position = edit_point + Vector3(-8.0, 18.0, -46.0)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"small_edit_mid":
			capture_target = edit_point + Vector3(1.2, 0.0, 1.2)
			capture_position = edit_point + Vector3(-44.0, 72.0, -190.0)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"small_edit_far":
			capture_target = edit_point + Vector3(1.2, 0.0, 1.2)
			capture_position = edit_point + Vector3(-130.0, 145.0, -410.0)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"edit_near", "interaction_near":
			capture_position = Vector3(1176.0, 154.0, 922.0)
			capture_target = Vector3(1188.0, 115.0, 1015.0)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"edit_far", "interaction_far":
			capture_position = Vector3(1070.0, 210.0, 730.0)
			capture_target = Vector3(860.0, 72.0, 1220.0)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"edit_aerial", "interaction_aerial":
			capture_position = Vector3(1120.0, 330.0, 640.0)
			capture_target = Vector3(1130.0, 72.0, 1035.0)
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

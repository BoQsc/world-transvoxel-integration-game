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
var runtime_render_apply_budget_override := -1
var runtime_collision_apply_budget_override := -1
var lod_movement_direct_only := false
var lod_movement_operation_limit := -1
var lod_movement_gap_only_probe := false
var maximum_lod_override := -1
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
var last_edit_persistence_summary := {}
var last_edit_stability_summary := {}
var last_lod_movement_summary := {}
var last_edit_during_load_summary := {}
var last_manifold_stress_summary := {}
var last_tunnel_summary := {}
var edit_persistence_operations: Array = []
var authoritative_sample_batches := {}
var authoritative_sample_failures := {}


func _ready() -> void:
	var args := Array(OS.get_cmdline_user_args())
	autonomous = args.has("--p2-autonomous")
	human_visual_capture_path = _arg_value(args, "--human-visual-capture", "")
	human_visual_capture_mode = _arg_value(args, "--human-visual-capture-mode", "ground")
	human_visual_capture_wait_frames = int(_arg_value(args, "--human-visual-capture-wait-frames", "90"))
	runtime_render_apply_budget_override = int(_arg_value(args, "--runtime-render-apply-budget", "-1"))
	runtime_collision_apply_budget_override = int(_arg_value(args, "--runtime-collision-apply-budget", "-1"))
	lod_movement_direct_only = args.has("--p2-lod-movement-direct-only")
	lod_movement_operation_limit = int(_arg_value(args, "--p2-lod-movement-operation-limit", "-1"))
	lod_movement_gap_only_probe = args.has("--p2-lod-movement-gap-only-probe")
	maximum_lod_override = int(_arg_value(args, "--p2-maximum-lod", "-1"))
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
	if runtime_render_apply_budget_override >= 0:
		settings["runtime_render_apply_budget"] = runtime_render_apply_budget_override
	if runtime_collision_apply_budget_override >= 0:
		settings["runtime_collision_apply_budget"] = runtime_collision_apply_budget_override
	if maximum_lod_override >= 0:
		settings["maximum_lod"] = maximum_lod_override
		if maximum_lod_override == 0:
			settings["radius"] = 4
			settings["expected_resources"] = settings.get("startup_minimum_render_resources", 32)
			settings["expected_max_resources"] = 1024
			settings["runtime_lod_refinement_radius_chunks"] = 0
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
	game_world.runtime_streaming_burst_render_apply_budget = int(settings.get("runtime_streaming_burst_render_apply_budget", 0))
	game_world.runtime_streaming_burst_collision_apply_budget = int(settings.get("runtime_streaming_burst_collision_apply_budget", 0))
	game_world.runtime_streaming_burst_frames = int(settings.get("runtime_streaming_burst_frames", 0))
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
			"runtime_streaming_burst_render_apply_budget": 128,
			"runtime_streaming_burst_collision_apply_budget": 128,
			"runtime_streaming_burst_frames": 30,
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
		"runtime_streaming_burst_render_apply_budget": 128,
		"runtime_streaming_burst_collision_apply_budget": 128,
		"runtime_streaming_burst_frames": 30,
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
		"runtime_streaming_burst_render_apply_budget": int(summary.get("runtime_streaming_burst_render_apply_budget", 0)),
		"runtime_streaming_burst_collision_apply_budget": int(summary.get("runtime_streaming_burst_collision_apply_budget", 0)),
		"runtime_streaming_burst_frames": int(summary.get("runtime_streaming_burst_frames", 0)),
		"streaming_burst_frames_remaining": int(summary.get("streaming_burst_frames_remaining", 0)),
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
		"edit_persistence": _edit_persistence_summary(),
		"edit_stability": _edit_stability_summary(),
		"lod_movement": _lod_movement_summary(),
		"edit_during_load": _edit_during_load_summary(),
		"manifold_stress": _manifold_stress_summary(),
		"tunnel": _tunnel_summary(),
		"capture_path": human_visual_capture_path,
	}))
	var watertightness_accepted := bool(last_watertightness_summary.get("ok", false))
	if human_visual_capture_mode == "edit_lod_movement_gate" and lod_movement_gap_only_probe:
		watertightness_accepted = _is_lod_movement_probe_ready(last_watertightness_summary)
	if human_visual_capture_mode == "edit_during_load_oracle":
		watertightness_accepted = _is_open_gap_free_probe(last_watertightness_summary)
	if human_visual_capture_mode == "edit_manifold_stress_gate":
		watertightness_accepted = _is_open_gap_free_probe(last_watertightness_summary)
	if human_visual_capture_mode == "edit_tunnel_gate":
		watertightness_accepted = _is_open_gap_free_probe(last_watertightness_summary)
	if _capture_requires_watertightness_probe() and not watertightness_accepted:
		push_error("WT_WATERTIGHTNESS_FAIL: %s" % JSON.stringify(last_watertightness_summary))
		get_tree().quit(1)
		return
	get_tree().quit(0)


func _capture_requires_interaction_inspection() -> bool:
	return human_visual_capture_mode.begins_with("edit_") or \
		human_visual_capture_mode.begins_with("small_edit_") or \
		human_visual_capture_mode.begins_with("watertight_") or \
		human_visual_capture_mode == "edit_persistence_reload_oracle" or \
		human_visual_capture_mode == "edit_stability_gate" or \
		human_visual_capture_mode == "edit_lod_movement_gate" or \
		human_visual_capture_mode == "edit_tunnel_gate" or \
		human_visual_capture_mode == "interaction_near" or \
		human_visual_capture_mode == "interaction_far" or \
		human_visual_capture_mode == "interaction_aerial"


func _capture_requires_watertightness_probe() -> bool:
	return human_visual_capture_mode.begins_with("watertight_") or \
		human_visual_capture_mode == "edit_persistence_reload_oracle" or \
		human_visual_capture_mode == "edit_stability_gate" or \
		human_visual_capture_mode == "edit_lod_movement_gate" or \
		human_visual_capture_mode == "edit_during_load_oracle" or \
		human_visual_capture_mode == "edit_manifold_stress_gate" or \
		human_visual_capture_mode == "edit_tunnel_gate"


func _apply_interaction_inspection_edits() -> bool:
	if interaction_inspection_applied:
		return true
	var terrain_world: Node = game_world.get_terrain_world() if game_world != null else null
	if terrain_world == null:
		_fail("terrain world unavailable for interaction inspection")
		return false
	if human_visual_capture_mode == "edit_lod_movement_gate":
		return await _run_edit_lod_movement_gate(terrain_world)
	if human_visual_capture_mode == "edit_during_load_oracle":
		return await _run_edit_during_load_oracle(terrain_world)
	if human_visual_capture_mode == "edit_manifold_stress_gate":
		return await _run_manifold_stress_gate(terrain_world)
	if human_visual_capture_mode == "edit_tunnel_gate":
		return await _run_tunnel_gate(terrain_world)
	if human_visual_capture_mode == "edit_stability_gate":
		return await _run_edit_stability_gate(terrain_world)
	if _capture_requires_sequential_interaction_edits():
		return await _apply_sequential_interaction_inspection_edits(terrain_world)
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


func _capture_requires_sequential_interaction_edits() -> bool:
	return human_visual_capture_mode == "watertight_many_small_near" or \
		human_visual_capture_mode == "watertight_rapid_small_near" or \
		human_visual_capture_mode == "watertight_rapid_small_reload_near" or \
		human_visual_capture_mode == "edit_persistence_reload_oracle"


func _apply_sequential_interaction_inspection_edits(terrain_world: Node) -> bool:
	var operations := _sequential_interaction_inspection_operations()
	edit_persistence_operations = operations.duplicate()
	interaction_inspection_operation_count = operations.size()
	if interaction_inspection_operation_count <= 0:
		_fail("sequential interaction inspection produced no operations")
		return false
	for index in range(operations.size()):
		var before_revision := int(terrain_world.call("get_backend_world_revision"))
		var batch = EditBatch.new()
		if not batch.add_operation(operations[index]):
			_fail("failed to add sequential interaction inspection operation %d" % index)
			return false
		if not bool(terrain_world.call("submit_edit_batch", batch, 7717)):
			_fail("sequential interaction inspection edit %d rejected: %s" % [
				index,
				str(terrain_world.call("get_last_error")),
			])
			return false
		if not await game_world.wait_for_world_revision(before_revision + 1):
			_fail("sequential interaction inspection edit %d did not commit" % index)
			return false
		if human_visual_capture_mode == "watertight_many_small_near":
			if index % 8 == 7:
				if not await _wait_for_current_profile_settled("after sequential interaction edit %d" % index):
					return false
		else:
			for _frame in range(2):
				await get_tree().process_frame
	if not await _wait_for_current_profile_settled("after sequential interaction inspection edits"):
		return false
	var before_reload_snapshot := {}
	if _capture_requires_edit_persistence_oracle():
		before_reload_snapshot = await _collect_edit_persistence_snapshot(terrain_world, "before reload")
		if not bool(before_reload_snapshot.get("ok", false)):
			return false
	if _capture_exercises_edit_reload_path():
		if not await _exercise_edit_reload_path():
			return false
	if _capture_requires_edit_persistence_oracle():
		var after_reload_snapshot := await _collect_edit_persistence_snapshot(terrain_world, "after reload")
		if not bool(after_reload_snapshot.get("ok", false)):
			return false
		if not _compare_edit_persistence_snapshots(before_reload_snapshot, after_reload_snapshot):
			return false
	if material_applicator != null:
		material_applicator.call("apply_materials_now")
	interaction_inspection_applied = true
	return true


func _capture_exercises_edit_reload_path() -> bool:
	return human_visual_capture_mode == "watertight_rapid_small_reload_near" or \
		human_visual_capture_mode == "edit_persistence_reload_oracle"


func _capture_requires_edit_persistence_oracle() -> bool:
	return human_visual_capture_mode == "watertight_rapid_small_reload_near" or \
		human_visual_capture_mode == "edit_persistence_reload_oracle"


func _run_edit_stability_gate(terrain_world: Node) -> bool:
	var operations := _edit_stability_gate_operations()
	edit_persistence_operations = operations.duplicate()
	interaction_inspection_operation_count = operations.size()
	last_edit_stability_summary = {
		"enabled": true,
		"ok": false,
		"profile": str(selected_profile),
		"seed_count": _edit_stability_gate_seeds().size(),
		"operation_count": operations.size(),
	}
	if operations.is_empty():
		_fail("edit stability gate produced no operations")
		return false
	var mode_counts := {}
	for index in range(operations.size()):
		var operation: Resource = operations[index]
		var mode_name := str(operation.call("get_mode_name"))
		mode_counts[mode_name] = int(mode_counts.get(mode_name, 0)) + 1
		var before_revision := int(terrain_world.call("get_backend_world_revision"))
		var batch = EditBatch.new()
		if not batch.add_operation(operation):
			_fail("failed to add edit stability operation %d" % index)
			return false
		if not bool(terrain_world.call("submit_edit_batch", batch, 8841)):
			_fail("edit stability operation %d rejected: %s" % [
				index,
				str(terrain_world.call("get_last_error")),
			])
			return false
		if not await game_world.wait_for_world_revision(before_revision + 1):
			_fail("edit stability operation %d did not commit" % index)
			return false
		if index % 12 == 11:
			if not await _wait_for_current_profile_settled("after edit stability operation %d" % index):
				return false
		else:
			for _frame in range(2):
				await get_tree().process_frame
	if not await _wait_for_current_profile_settled("after edit stability operations"):
		return false
	var before_reload_snapshot := await _collect_edit_persistence_snapshot(terrain_world, "edit stability before reload")
	if not bool(before_reload_snapshot.get("ok", false)):
		return false
	if not _edit_stability_snapshot_has_material_diversity(before_reload_snapshot):
		return false
	if not await _exercise_edit_reload_path():
		return false
	var after_reload_snapshot := await _collect_edit_persistence_snapshot(terrain_world, "edit stability after reload")
	if not bool(after_reload_snapshot.get("ok", false)):
		return false
	if not _compare_edit_persistence_snapshots(before_reload_snapshot, after_reload_snapshot):
		return false
	var runtime_summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
	if int(runtime_summary.get("collision_resources", 0)) <= 0:
		_fail("edit stability gate has no collision resources after reload: %s" % str(runtime_summary))
		return false
	last_edit_stability_summary = {
		"enabled": true,
		"ok": true,
		"profile": str(selected_profile),
		"seed_count": _edit_stability_gate_seeds().size(),
		"operation_count": operations.size(),
		"mode_counts": mode_counts,
		"sample_count": int(last_edit_persistence_summary.get("sample_count", 0)),
		"air_sample_count": int(last_edit_persistence_summary.get("before_air_sample_count", 0)),
		"density_mismatches": int(last_edit_persistence_summary.get("density_mismatches", -1)),
		"material_mismatches": int(last_edit_persistence_summary.get("material_mismatches", -1)),
		"max_abs_density_delta": float(last_edit_persistence_summary.get("max_abs_density_delta", -1.0)),
		"render_resources": int(runtime_summary.get("render_resources", 0)),
		"collision_resources": int(runtime_summary.get("collision_resources", 0)),
		"active_chunk_records": int(runtime_summary.get("active_chunk_records", 0)),
	}
	if material_applicator != null:
		material_applicator.call("apply_materials_now")
	interaction_inspection_applied = true
	return true


func _edit_stability_gate_seeds() -> Array:
	return [615197, 382091, 928371]


func _edit_stability_gate_operations() -> Array:
	var operations: Array = []
	var seeds := _edit_stability_gate_seeds()
	var center := _edit_stability_gate_center()
	var horizontal_radius_limit := 18.0
	var vertical_offset_min := -8.0
	var vertical_offset_max := 4.0
	if selected_profile == FLAT_PROFILE:
		horizontal_radius_limit = 7.5
		vertical_offset_min = -2.0
		vertical_offset_max = 2.5
	for seed_index in range(seeds.size()):
		var rng := RandomNumberGenerator.new()
		rng.seed = int(seeds[seed_index])
		for index in range(32):
			var angle := rng.randf_range(0.0, TAU)
			var horizontal_radius := rng.randf_range(0.0, horizontal_radius_limit)
			var offset := Vector3(
				cos(angle) * horizontal_radius,
				rng.randf_range(vertical_offset_min, vertical_offset_max),
				sin(angle) * horizontal_radius
			)
			var pattern := index % 8
			var mode := &"carve"
			var material_id := 1
			var radius := rng.randf_range(1.6, 2.8)
			if selected_profile == FLAT_PROFILE:
				radius = rng.randf_range(1.4, 2.2)
			if pattern == 5:
				mode = &"construct"
				material_id = 3 + seed_index
				radius = rng.randf_range(1.8, 3.2)
				if selected_profile == FLAT_PROFILE:
					radius = rng.randf_range(1.5, 2.4)
			elif pattern == 6:
				mode = &"paint"
				material_id = 7 + seed_index
				radius = rng.randf_range(2.0, 3.5)
				if selected_profile == FLAT_PROFILE:
					radius = rng.randf_range(1.8, 2.6)
			elif pattern == 7:
				mode = &"fill"
				material_id = 4 + seed_index
				radius = rng.randf_range(1.8, 3.0)
				if selected_profile == FLAT_PROFILE:
					radius = rng.randf_range(1.5, 2.4)
			operations.append(_edit_operation(
				mode,
				center + offset,
				radius,
				material_id,
				1.0
			))
	return operations


func _edit_stability_snapshot_has_material_diversity(snapshot: Dictionary) -> bool:
	var histogram: Dictionary = snapshot.get("material_histogram", {})
	if histogram.keys().size() < 2:
		last_edit_stability_summary = {
			"enabled": true,
			"ok": false,
			"error": "material_diversity_missing",
			"material_histogram": histogram,
		}
		_fail("edit stability gate did not observe mixed material edits: %s" % JSON.stringify(last_edit_stability_summary))
		return false
	return true


func _run_edit_during_load_oracle(terrain_world: Node) -> bool:
	if player == null or game_world == null:
		_fail("edit-during-load oracle requires player and game world")
		return false
	var backend: Node = terrain_world.call("get_backend_terrain")
	if backend == null:
		_fail("edit-during-load oracle backend unavailable")
		return false
	var center := _edit_during_load_oracle_center()
	var far_position := center + Vector3(520.0, 46.0, 520.0)
	var near_position := center + Vector3(-16.0, 18.0, -42.0)
	if selected_profile == FLAT_PROFILE:
		far_position = center + Vector3(420.0, 28.0, 420.0)
		near_position = center + Vector3(-14.0, 16.0, -38.0)
	last_edit_during_load_summary = {
		"enabled": true,
		"ok": false,
		"profile": str(selected_profile),
	}

	await _set_capture_camera_pose(far_position, center)
	var far_settle_notes := []
	if not await _wait_for_lod_movement_visual_ready(
		backend,
		"edit-during-load far eviction",
		far_settle_notes
	):
		last_edit_during_load_summary["error"] = "far_evict_not_ready"
		return false

	player.global_position = near_position
	player.velocity = Vector3.ZERO
	if not bool(player.call("autonomous_look_at", center)):
		last_edit_during_load_summary["error"] = "look_at_failed"
		_fail("edit-during-load oracle look_at failed")
		return false
	if not bool(game_world.update_player_viewer(true)):
		last_edit_during_load_summary["error"] = "near_viewer_update_failed"
		_fail("edit-during-load oracle near viewer update failed")
		return false
	var busy_before_edit := await _wait_for_streaming_busy("before edit-during-load submissions", 60)
	if not bool(busy_before_edit.get("ok", false)):
		last_edit_during_load_summary["error"] = "streaming_not_observed_before_edit"
		last_edit_during_load_summary["pre_edit_streaming"] = busy_before_edit
		return false

	var operations := _edit_during_load_oracle_operations()
	edit_persistence_operations = operations.duplicate()
	interaction_inspection_operation_count = operations.size()
	if operations.is_empty():
		last_edit_during_load_summary["error"] = "no_operations"
		_fail("edit-during-load oracle produced no operations")
		return false

	var streaming_batches := 0
	var busy_observations := [busy_before_edit]
	var operation_index := 0
	var batch_size := 8
	while operation_index < operations.size():
		var before_batch_summary: Dictionary = game_world.get_game_world_summary()
		if _is_streaming_busy_summary(before_batch_summary):
			streaming_batches += 1
			busy_observations.append(_streaming_summary(before_batch_summary))
		var before_revision := int(terrain_world.call("get_backend_world_revision"))
		var batch = EditBatch.new()
		for _local_index in range(batch_size):
			if operation_index >= operations.size():
				break
			if not batch.add_operation(operations[operation_index]):
				last_edit_during_load_summary["error"] = "batch_add_failed"
				last_edit_during_load_summary["failed_operation"] = operation_index
				_fail("failed to add edit-during-load operation %d" % operation_index)
				return false
			operation_index += 1
		if not bool(terrain_world.call("submit_edit_batch", batch, 9029)):
			last_edit_during_load_summary["error"] = "edit_batch_rejected"
			last_edit_during_load_summary["failed_operation"] = operation_index
			last_edit_during_load_summary["last_error"] = str(terrain_world.call("get_last_error"))
			_fail("edit-during-load batch rejected: %s" % str(terrain_world.call("get_last_error")))
			return false
		if not await game_world.wait_for_world_revision(before_revision + 1):
			last_edit_during_load_summary["error"] = "revision_not_committed"
			last_edit_during_load_summary["failed_operation"] = operation_index
			_fail("edit-during-load batch did not commit")
			return false
		await get_tree().process_frame
	if streaming_batches <= 0:
		last_edit_during_load_summary["error"] = "no_batch_submitted_while_streaming"
		last_edit_during_load_summary["pre_edit_streaming"] = busy_before_edit
		_fail("edit-during-load oracle did not submit any batch while streaming was busy")
		return false

	var after_commit_snapshot := await _collect_edit_persistence_snapshot(
		terrain_world,
		"edit-during-load after commit before visual-ready"
	)
	if not bool(after_commit_snapshot.get("ok", false)):
		last_edit_during_load_summary["error"] = "after_commit_snapshot_failed"
		return false

	var load_settle_notes := []
	if not await _wait_for_edit_during_load_visual_ready(
		backend,
		"edit-during-load after streaming completion",
		load_settle_notes
	):
		last_edit_during_load_summary["error"] = "post_edit_visual_not_ready"
		return false
	var after_load_snapshot := await _collect_edit_persistence_snapshot(
		terrain_world,
		"edit-during-load after visual-ready"
	)
	if not bool(after_load_snapshot.get("ok", false)):
		last_edit_during_load_summary["error"] = "after_load_snapshot_failed"
		return false
	if not _compare_edit_persistence_snapshots(after_commit_snapshot, after_load_snapshot):
		last_edit_during_load_summary["error"] = "changed_after_late_load"
		last_edit_during_load_summary["persistence"] = last_edit_persistence_summary.duplicate(true)
		return false
	var after_load_persistence := last_edit_persistence_summary.duplicate(true)

	if not await _exercise_edit_reload_path():
		last_edit_during_load_summary["error"] = "reload_path_failed"
		return false
	var after_reload_snapshot := await _collect_edit_persistence_snapshot(
		terrain_world,
		"edit-during-load after reload"
	)
	if not bool(after_reload_snapshot.get("ok", false)):
		last_edit_during_load_summary["error"] = "after_reload_snapshot_failed"
		return false
	if not _compare_edit_persistence_snapshots(after_commit_snapshot, after_reload_snapshot):
		last_edit_during_load_summary["error"] = "changed_after_reload"
		last_edit_during_load_summary["persistence"] = last_edit_persistence_summary.duplicate(true)
		return false
	var after_reload_persistence := last_edit_persistence_summary.duplicate(true)

	last_edit_during_load_summary = {
		"enabled": true,
		"ok": true,
		"profile": str(selected_profile),
		"operation_count": operations.size(),
		"batch_size": batch_size,
		"streaming_batches": streaming_batches,
		"busy_observations": busy_observations,
		"far_settle_notes": far_settle_notes,
		"load_settle_notes": load_settle_notes,
		"after_commit_sample_count": int(after_commit_snapshot.get("sample_count", 0)),
		"after_commit_air_sample_count": int(after_commit_snapshot.get("air_sample_count", 0)),
		"after_load_persistence": after_load_persistence,
		"after_reload_persistence": after_reload_persistence,
	}
	if material_applicator != null:
		material_applicator.call("apply_materials_now")
	interaction_inspection_applied = true
	return true


func _edit_during_load_oracle_operations() -> Array:
	var operations: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 742901
	var center := _edit_during_load_oracle_center()
	var horizontal_radius_limit := 18.0
	var vertical_offset_min := -9.0
	var vertical_offset_max := 2.5
	if selected_profile == FLAT_PROFILE:
		horizontal_radius_limit = 9.0
		vertical_offset_min = -2.0
		vertical_offset_max = 2.5
	for index in range(64):
		var angle := rng.randf_range(0.0, TAU)
		var horizontal_radius := rng.randf_range(0.0, horizontal_radius_limit)
		var offset := Vector3(
			cos(angle) * horizontal_radius,
			rng.randf_range(vertical_offset_min, vertical_offset_max),
			sin(angle) * horizontal_radius
		)
		var mode := &"carve"
		var material_id := 1
		var radius := rng.randf_range(1.35, 2.8)
		if selected_profile == FLAT_PROFILE:
			radius = rng.randf_range(1.2, 2.2)
		var pattern := index % 16
		if pattern == 12:
			mode = &"construct"
			material_id = 4
			radius = rng.randf_range(1.6, 3.0)
		elif pattern == 13:
			mode = &"fill"
			material_id = 5
			radius = rng.randf_range(1.6, 3.2)
		elif pattern == 14:
			mode = &"paint"
			material_id = 7
			radius = rng.randf_range(2.0, 3.5)
		operations.append(_edit_operation(mode, center + offset, radius, material_id, 1.0))
	return operations


func _wait_for_streaming_busy(context: String, max_frames: int) -> Dictionary:
	for frame in range(max_frames):
		var summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
		if _is_streaming_busy_summary(summary):
			var observed := _streaming_summary(summary)
			observed["ok"] = true
			observed["context"] = context
			observed["frame"] = frame
			return observed
		await get_tree().process_frame
	var timeout_summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
	var result := _streaming_summary(timeout_summary)
	result["ok"] = false
	result["context"] = context
	result["error"] = "streaming_busy_not_observed"
	_fail("streaming busy state was not observed %s: %s" % [context, JSON.stringify(result)])
	return result


func _is_streaming_busy_summary(summary: Dictionary) -> bool:
	if int(summary.get("queued_render", 0)) != 0:
		return true
	if int(summary.get("queued_collision", 0)) != 0:
		return true
	if int(summary.get("scheduler_queued_jobs", 0)) != 0:
		return true
	if int(summary.get("scheduler_queued_completions", 0)) != 0:
		return true
	if int(summary.get("pending_chunk_retirements", 0)) != 0:
		return true
	if int(summary.get("render_fading_resources", 0)) != 0:
		return true
	if int(summary.get("staged_render_resources", 0)) != 0:
		return true
	if summary.has("fully_ready_chunk_records") and \
			int(summary.get("fully_ready_chunk_records", 0)) < int(summary.get("active_chunk_records", 0)):
		return true
	if summary.has("visual_ready_chunk_records") and \
			int(summary.get("visual_ready_chunk_records", 0)) < int(summary.get("active_chunk_records", 0)):
		return true
	return false


func _streaming_summary(summary: Dictionary) -> Dictionary:
	return {
		"queued_render": int(summary.get("queued_render", 0)),
		"queued_collision": int(summary.get("queued_collision", 0)),
		"scheduler_queued_jobs": int(summary.get("scheduler_queued_jobs", 0)),
		"scheduler_queued_completions": int(summary.get("scheduler_queued_completions", 0)),
		"pending_chunk_retirements": int(summary.get("pending_chunk_retirements", 0)),
		"render_fading_resources": int(summary.get("render_fading_resources", 0)),
		"staged_render_resources": int(summary.get("staged_render_resources", 0)),
		"active_chunk_records": int(summary.get("active_chunk_records", 0)),
		"visual_ready_chunk_records": int(summary.get("visual_ready_chunk_records", 0)),
		"fully_ready_chunk_records": int(summary.get("fully_ready_chunk_records", 0)),
		"render_resources": int(summary.get("render_resources", 0)),
		"collision_resources": int(summary.get("collision_resources", 0)),
	}


func _run_manifold_stress_gate(terrain_world: Node) -> bool:
	if player == null or game_world == null:
		_fail("manifold stress gate requires player and game world")
		return false
	var backend: Node = terrain_world.call("get_backend_terrain")
	if backend == null:
		_fail("manifold stress gate backend unavailable")
		return false
	var operations := _manifold_stress_operations()
	edit_persistence_operations = operations.duplicate()
	interaction_inspection_operation_count = operations.size()
	last_manifold_stress_summary = {
		"enabled": true,
		"ok": false,
		"profile": str(selected_profile),
		"operation_count": operations.size(),
	}
	if operations.is_empty():
		last_manifold_stress_summary["error"] = "no_operations"
		_fail("manifold stress gate produced no operations")
		return false

	var mode_counts := {}
	var batch_size := 8
	var operation_index := 0
	var interim_summaries := []
	var persistence_summaries := []
	var transition_summaries := []
	var stress_path := _manifold_stress_path()
	var stress_path_index := 0
	if not await _set_manifold_stress_camera("initial_close"):
		last_manifold_stress_summary["error"] = "initial_camera_failed"
		return false
	var initial_settle_notes := []
	if not await _wait_for_manifold_stress_visual_ready(
		backend,
		"before manifold stress edits",
		initial_settle_notes
	):
		last_manifold_stress_summary["error"] = "initial_visual_not_ready"
		return false

	while operation_index < operations.size():
		var before_revision := int(terrain_world.call("get_backend_world_revision"))
		var batch = EditBatch.new()
		for _local_index in range(batch_size):
			if operation_index >= operations.size():
				break
			var operation: Resource = operations[operation_index]
			var mode_name := str(operation.call("get_mode_name"))
			mode_counts[mode_name] = int(mode_counts.get(mode_name, 0)) + 1
			if not batch.add_operation(operation):
				last_manifold_stress_summary["error"] = "batch_add_failed"
				last_manifold_stress_summary["failed_operation"] = operation_index
				_fail("failed to add manifold stress operation %d" % operation_index)
				return false
			operation_index += 1
		if not bool(terrain_world.call("submit_edit_batch", batch, 9407)):
			last_manifold_stress_summary["error"] = "edit_batch_rejected"
			last_manifold_stress_summary["failed_operation"] = operation_index
			last_manifold_stress_summary["last_error"] = str(terrain_world.call("get_last_error"))
			_fail("manifold stress batch rejected: %s" % str(terrain_world.call("get_last_error")))
			return false
		if not await game_world.wait_for_world_revision(before_revision + 1):
			last_manifold_stress_summary["error"] = "revision_not_committed"
			last_manifold_stress_summary["failed_operation"] = operation_index
			_fail("manifold stress batch did not commit")
			return false
		await get_tree().process_frame
		if operation_index % 32 == 0 or operation_index >= operations.size():
			var checkpoint_settle_notes := []
			if not await _wait_for_manifold_stress_visual_ready(
				backend,
				"manifold stress after operation %d before movement" % operation_index,
				checkpoint_settle_notes
			):
				last_manifold_stress_summary["error"] = "interim_pre_move_not_ready"
				last_manifold_stress_summary["failed_operation"] = operation_index
				return false
			var before_move_snapshot := await _collect_edit_persistence_snapshot(
				terrain_world,
				"manifold stress after operation %d" % operation_index
			)
			if not bool(before_move_snapshot.get("ok", false)):
				last_manifold_stress_summary["error"] = "interim_snapshot_failed"
				return false
			var step: Dictionary = stress_path[stress_path_index % stress_path.size()]
			var transition := await _exercise_manifold_stress_step(
				backend,
				step,
				"interim_%d" % operation_index
			)
			transition_summaries.append(transition)
			if not bool(transition.get("ok", false)):
				last_manifold_stress_summary["error"] = "interim_transition_failed"
				last_manifold_stress_summary["failed_transition"] = transition
				_fail("manifold stress interim transition failed: %s" % JSON.stringify(transition))
				return false
			var after_move_snapshot := await _collect_edit_persistence_snapshot(
				terrain_world,
				"manifold stress after operation %d movement" % operation_index
			)
			if not bool(after_move_snapshot.get("ok", false)):
				last_manifold_stress_summary["error"] = "interim_after_move_snapshot_failed"
				return false
			if not _compare_edit_persistence_snapshots(before_move_snapshot, after_move_snapshot):
				last_manifold_stress_summary["error"] = "interim_persistence_changed"
				last_manifold_stress_summary["failed_operation"] = operation_index
				last_manifold_stress_summary["persistence"] = last_edit_persistence_summary.duplicate(true)
				return false
			interim_summaries.append({
				"operation_index": operation_index,
				"path_label": str(step.get("label", "step")),
				"pre_move_settle_notes": checkpoint_settle_notes,
				"sample_count": int(last_edit_persistence_summary.get("sample_count", 0)),
				"air_sample_count": int(after_move_snapshot.get("air_sample_count", 0)),
				"density_mismatches": int(last_edit_persistence_summary.get("density_mismatches", -1)),
				"material_mismatches": int(last_edit_persistence_summary.get("material_mismatches", -1)),
				"max_abs_density_delta": float(last_edit_persistence_summary.get("max_abs_density_delta", -1.0)),
			})
			stress_path_index += 1

	var baseline_snapshot := await _collect_edit_persistence_snapshot(
		terrain_world,
		"manifold stress baseline"
	)
	if not bool(baseline_snapshot.get("ok", false)):
		last_manifold_stress_summary["error"] = "baseline_snapshot_failed"
		return false
	if int(baseline_snapshot.get("air_sample_count", 0)) <= 0:
		last_manifold_stress_summary["error"] = "no_carved_air_samples"
		_fail("manifold stress gate did not sample carved air")
		return false

	for step in stress_path:
		var final_transition := await _exercise_manifold_stress_step(
			backend,
			step,
			"final_%s" % str(step.get("label", "step"))
		)
		transition_summaries.append(final_transition)
		if not bool(final_transition.get("ok", false)):
			last_manifold_stress_summary["error"] = "final_transition_failed"
			last_manifold_stress_summary["failed_transition"] = final_transition
			_fail("manifold stress final transition failed: %s" % JSON.stringify(final_transition))
			return false
		var after_step_snapshot := await _collect_edit_persistence_snapshot(
			terrain_world,
			"manifold stress after %s" % str(step.get("label", "step"))
		)
		if not bool(after_step_snapshot.get("ok", false)):
			last_manifold_stress_summary["error"] = "final_after_step_snapshot_failed"
			return false
		if not _compare_edit_persistence_snapshots(baseline_snapshot, after_step_snapshot):
			last_manifold_stress_summary["error"] = "final_persistence_changed"
			last_manifold_stress_summary["failed_step"] = str(step.get("label", "step"))
			last_manifold_stress_summary["persistence"] = last_edit_persistence_summary.duplicate(true)
			return false
		persistence_summaries.append({
			"label": str(step.get("label", "step")),
			"sample_count": int(last_edit_persistence_summary.get("sample_count", 0)),
			"density_mismatches": int(last_edit_persistence_summary.get("density_mismatches", -1)),
			"material_mismatches": int(last_edit_persistence_summary.get("material_mismatches", -1)),
			"max_abs_density_delta": float(last_edit_persistence_summary.get("max_abs_density_delta", -1.0)),
		})

	if not await _exercise_edit_reload_path():
		last_manifold_stress_summary["error"] = "reload_path_failed"
		return false
	var after_reload_snapshot := await _collect_edit_persistence_snapshot(
		terrain_world,
		"manifold stress after reload"
	)
	if not bool(after_reload_snapshot.get("ok", false)):
		last_manifold_stress_summary["error"] = "after_reload_snapshot_failed"
		return false
	if not _compare_edit_persistence_snapshots(baseline_snapshot, after_reload_snapshot):
		last_manifold_stress_summary["error"] = "reload_persistence_changed"
		last_manifold_stress_summary["persistence"] = last_edit_persistence_summary.duplicate(true)
		return false
	var runtime_summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
	last_manifold_stress_summary = {
		"enabled": true,
		"ok": true,
		"profile": str(selected_profile),
		"operation_count": operations.size(),
		"batch_size": batch_size,
		"mode_counts": mode_counts,
		"interim_summaries": interim_summaries,
		"persistence_summaries": persistence_summaries,
		"transition_summaries": transition_summaries,
		"reload_persistence": last_edit_persistence_summary.duplicate(true),
		"baseline_sample_count": int(baseline_snapshot.get("sample_count", 0)),
		"baseline_air_sample_count": int(baseline_snapshot.get("air_sample_count", 0)),
		"render_resources": int(runtime_summary.get("render_resources", 0)),
		"collision_resources": int(runtime_summary.get("collision_resources", 0)),
		"active_chunk_records": int(runtime_summary.get("active_chunk_records", 0)),
	}
	if material_applicator != null:
		material_applicator.call("apply_materials_now")
	interaction_inspection_applied = true
	return true


func _run_tunnel_gate(terrain_world: Node) -> bool:
	if player == null or game_world == null:
		_fail("tunnel gate requires player and game world")
		return false
	var backend: Node = terrain_world.call("get_backend_terrain")
	if backend == null:
		_fail("tunnel gate backend unavailable")
		return false
	var operations := _tunnel_gate_operations()
	edit_persistence_operations = operations.duplicate()
	interaction_inspection_operation_count = operations.size()
	last_tunnel_summary = {
		"enabled": true,
		"ok": false,
		"profile": str(selected_profile),
		"operation_count": operations.size(),
	}
	if operations.is_empty():
		last_tunnel_summary["error"] = "no_operations"
		_fail("tunnel gate produced no operations")
		return false
	if not await _set_tunnel_camera("entry"):
		last_tunnel_summary["error"] = "initial_camera_failed"
		return false
	var initial_notes := []
	if not await _wait_for_tunnel_visual_ready(backend, "before tunnel edits", initial_notes):
		last_tunnel_summary["error"] = "initial_visual_not_ready"
		return false

	var operation_index := 0
	var batch_size := 4
	while operation_index < operations.size():
		var before_revision := int(terrain_world.call("get_backend_world_revision"))
		var batch = EditBatch.new()
		for _local_index in range(batch_size):
			if operation_index >= operations.size():
				break
			if not batch.add_operation(operations[operation_index]):
				last_tunnel_summary["error"] = "batch_add_failed"
				last_tunnel_summary["failed_operation"] = operation_index
				_fail("failed to add tunnel operation %d" % operation_index)
				return false
			operation_index += 1
		if not bool(terrain_world.call("submit_edit_batch", batch, 9619)):
			last_tunnel_summary["error"] = "edit_batch_rejected"
			last_tunnel_summary["failed_operation"] = operation_index
			last_tunnel_summary["last_error"] = str(terrain_world.call("get_last_error"))
			_fail("tunnel edit batch rejected: %s" % str(terrain_world.call("get_last_error")))
			return false
		if not await game_world.wait_for_world_revision(before_revision + 1):
			last_tunnel_summary["error"] = "revision_not_committed"
			last_tunnel_summary["failed_operation"] = operation_index
			_fail("tunnel edit batch did not commit")
			return false
		for _frame in range(2):
			await get_tree().process_frame

	var preload_summaries := []
	for step in _tunnel_gate_path():
		var preload_label := str(step.get("label", "step"))
		await _set_capture_camera_pose(step.get("position", player.global_position), step.get("target", _tunnel_gate_center()))
		var preload_notes := []
		var preload_center: Vector3 = step.get("probe_center", _tunnel_gate_center())
		var preload_radius := float(step.get("probe_radius", _tunnel_probe_radius()))
		if not await _wait_for_tunnel_visual_ready(
			backend,
			"tunnel preload %s" % preload_label,
			preload_notes,
			preload_center,
			preload_radius
		):
			last_tunnel_summary["error"] = "preload_visual_not_ready"
			last_tunnel_summary["failed_preload"] = preload_label
			return false
		preload_summaries.append({
			"label": preload_label,
			"settle_notes": preload_notes,
		})

	var baseline_snapshot := await _collect_edit_persistence_snapshot(terrain_world, "tunnel baseline")
	if not bool(baseline_snapshot.get("ok", false)):
		last_tunnel_summary["error"] = "baseline_snapshot_failed"
		return false
	if int(baseline_snapshot.get("air_sample_count", 0)) <= 0:
		last_tunnel_summary["error"] = "no_carved_air_samples"
		_fail("tunnel gate did not sample carved air")
		return false

	var probe_summaries := []
	for step in _tunnel_gate_path():
		var step_summary := await _exercise_tunnel_step(backend, step)
		probe_summaries.append(step_summary)
		if not bool(step_summary.get("ok", false)):
			last_tunnel_summary["error"] = "tunnel_probe_failed"
			last_tunnel_summary["failed_step"] = step_summary
			_fail("tunnel gate probe failed: %s" % JSON.stringify(step_summary))
			return false
		var after_step_snapshot := await _collect_edit_persistence_snapshot(
			terrain_world,
			"tunnel after %s" % str(step.get("label", "step"))
		)
		if not bool(after_step_snapshot.get("ok", false)):
			last_tunnel_summary["error"] = "after_step_snapshot_failed"
			return false
		if not _compare_edit_persistence_snapshots(baseline_snapshot, after_step_snapshot):
			last_tunnel_summary["error"] = "persistence_changed"
			last_tunnel_summary["persistence"] = last_edit_persistence_summary.duplicate(true)
			return false

	var runtime_summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
	last_tunnel_summary = {
		"enabled": true,
		"ok": true,
		"profile": str(selected_profile),
		"operation_count": operations.size(),
		"batch_size": batch_size,
		"preload_summaries": preload_summaries,
		"probe_summaries": probe_summaries,
		"sample_count": int(last_edit_persistence_summary.get("sample_count", 0)),
		"air_sample_count": int(baseline_snapshot.get("air_sample_count", 0)),
		"density_mismatches": int(last_edit_persistence_summary.get("density_mismatches", -1)),
		"material_mismatches": int(last_edit_persistence_summary.get("material_mismatches", -1)),
		"max_abs_density_delta": float(last_edit_persistence_summary.get("max_abs_density_delta", -1.0)),
		"render_resources": int(runtime_summary.get("render_resources", 0)),
		"collision_resources": int(runtime_summary.get("collision_resources", 0)),
		"active_chunk_records": int(runtime_summary.get("active_chunk_records", 0)),
	}
	if material_applicator != null:
		material_applicator.call("apply_materials_now")
	interaction_inspection_applied = true
	return true


func _tunnel_gate_operations() -> Array:
	var operations: Array = []
	_append_tunnel_carve_chain(
		operations,
		_tunnel_gate_center(),
		_tunnel_gate_direction(),
		4.2,
		42,
		1.45,
		0.35,
		true
	)
	if selected_profile == FLAT_PROFILE:
		operations.clear()
		_append_tunnel_carve_chain(
			operations,
			_tunnel_gate_center(),
			_tunnel_gate_direction(),
			3.4,
			42,
			1.25,
			0.35,
			true
		)
	_append_tunnel_carve_chain(
		operations,
		_tunnel_descending_start(),
		_tunnel_descending_direction(),
		_tunnel_descending_radius(),
		_tunnel_descending_step_count(),
		_tunnel_descending_spacing(),
		0.22,
		false
	)
	return operations


func _append_tunnel_carve_chain(
	operations: Array,
	center_or_start: Vector3,
	direction: Vector3,
	radius: float,
	step_count: int,
	spacing: float,
	wobble_scale: float,
	centered: bool
) -> void:
	var start_distance := -float(step_count - 1) * spacing * 0.5 if centered else 0.0
	for index in range(step_count):
		var distance := start_distance + float(index) * spacing
		var side_wobble := Vector3(
			0.0,
			sin(float(index) * 0.47) * wobble_scale,
			cos(float(index) * 0.31) * wobble_scale
		)
		if not centered:
			side_wobble = Vector3(
				sin(float(index) * 0.37) * wobble_scale,
				cos(float(index) * 0.53) * wobble_scale * 0.35,
				cos(float(index) * 0.29) * wobble_scale
			)
		operations.append(_edit_operation(
			&"carve",
			center_or_start + direction * distance + side_wobble,
			radius,
			1,
			1.0
		))


func _tunnel_gate_path() -> Array:
	var center := _tunnel_gate_center()
	var direction := _tunnel_gate_direction()
	var descending_start := _tunnel_descending_start()
	var descending_direction := _tunnel_descending_direction()
	var descending_length := float(_tunnel_descending_step_count() - 1) * _tunnel_descending_spacing()
	var descending_mid := descending_start + descending_direction * descending_length * 0.50
	var descending_deep := descending_start + descending_direction * descending_length
	return [
		{"label": "entry", "position": center - direction * 18.0, "target": center - direction * 8.0, "probe_center": center, "probe_radius": _tunnel_probe_radius()},
		{"label": "middle", "position": center - direction * 2.0, "target": center + direction * 8.0, "probe_center": center, "probe_radius": _tunnel_probe_radius()},
		{"label": "exit", "position": center + direction * 18.0, "target": center + direction * 28.0, "probe_center": center, "probe_radius": _tunnel_probe_radius()},
		{
			"label": "descending_entry",
			"position": descending_start - descending_direction * 7.0 + Vector3(0.0, 1.5, 0.0),
			"target": descending_start + descending_direction * 6.0,
			"probe_center": descending_start + descending_direction * 8.0,
			"probe_radius": _tunnel_descending_probe_radius(),
		},
		{
			"label": "descending_middle",
			"position": descending_mid - descending_direction * 3.0 + Vector3(0.0, 1.0, 0.0),
			"target": descending_mid + descending_direction * 8.0,
			"probe_center": descending_mid,
			"probe_radius": _tunnel_descending_probe_radius(),
		},
		{
			"label": "descending_deep",
			"position": descending_deep - descending_direction * 8.0 + Vector3(0.0, 1.0, 0.0),
			"target": descending_deep,
			"probe_center": descending_deep - descending_direction * 4.0,
			"probe_radius": _tunnel_descending_probe_radius(),
		},
	]


func _set_tunnel_camera(label: String) -> bool:
	for step in _tunnel_gate_path():
		if str(step.get("label", "")) == label:
			await _set_capture_camera_pose(step.get("position", player.global_position), step.get("target", _tunnel_gate_center()))
			return true
	return false


func _exercise_tunnel_step(backend: Node, step: Dictionary) -> Dictionary:
	var label := str(step.get("label", "step"))
	await _set_capture_camera_pose(step.get("position", player.global_position), step.get("target", _tunnel_gate_center()))
	var notes := []
	var probe_center: Vector3 = step.get("probe_center", _tunnel_gate_center())
	var probe_radius := float(step.get("probe_radius", _tunnel_probe_radius()))
	if not await _wait_for_tunnel_visual_ready(
		backend,
		"tunnel %s" % label,
		notes,
		probe_center,
		probe_radius
	):
		var summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
		return {
			"ok": false,
			"label": label,
			"error": "visual_not_ready",
			"summary": summary,
			"settle_notes": notes,
		}
	var probe := WatertightnessProbe.collect(
		backend,
		"edit_tunnel_gate_%s" % label,
		probe_center,
		probe_radius
	)
	var digest := _open_gap_probe_digest(probe)
	digest["ok"] = _is_open_gap_free_probe(probe)
	digest["label"] = label
	digest["settle_notes"] = notes
	if not bool(digest.get("ok", false)):
		digest["error"] = "open_gap_or_orientation_conflict"
	return digest


func _wait_for_tunnel_visual_ready(
	backend: Node,
	context: String,
	settle_notes: Array,
	probe_center: Vector3 = Vector3.INF,
	probe_radius: float = -1.0
) -> bool:
	var last_summary := {}
	var last_probe := {}
	if probe_center == Vector3.INF:
		probe_center = _tunnel_gate_center()
	if probe_radius <= 0.0:
		probe_radius = _tunnel_probe_radius()
	var frame_limit := maxi(180, human_visual_capture_wait_frames)
	for frame in range(frame_limit):
		var summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
		last_summary = summary
		if _is_lod_movement_visual_ready_summary(summary):
			if frame % 15 != 0 and frame != frame_limit - 1:
				await get_tree().process_frame
				continue
			var probe := WatertightnessProbe.collect(
				backend,
				"edit_tunnel_gate_visual_ready",
				probe_center,
				probe_radius
			)
			last_probe = _open_gap_probe_digest(probe)
			if _is_open_gap_free_probe(probe):
				if int(probe.get("zero_area_triangles", 0)) != 0:
					settle_notes.append({
						"context": context,
						"safe_near_zero_area_triangles": int(probe.get("zero_area_triangles", 0)),
						"zero_area_interior_triangles": int(probe.get("zero_area_interior_triangles", 0)),
						"zero_area_chunk_face_triangles": int(probe.get("zero_area_chunk_face_triangles", 0)),
						"minimum_area_squared": float(probe.get("minimum_area_squared", -1.0)),
					})
				return true
		await get_tree().process_frame
	_save_diagnostic_failure_capture(context)
	_fail("tunnel visual-ready wait failed %s: summary=%s probe=%s" % [
		context,
		str(last_summary),
		str(last_probe),
	])
	return false


func _manifold_stress_operations() -> Array:
	var operations: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 924017
	var center := _manifold_stress_center()
	var horizontal_radius_limit := 34.0
	var vertical_offset_min := -18.0
	var vertical_offset_max := 5.0
	if selected_profile == FLAT_PROFILE:
		horizontal_radius_limit = 13.0
		vertical_offset_min = -3.5
		vertical_offset_max = 3.5
	for index in range(128):
		var angle := rng.randf_range(0.0, TAU)
		var horizontal_radius := rng.randf_range(0.0, horizontal_radius_limit)
		var offset := Vector3(
			cos(angle) * horizontal_radius,
			rng.randf_range(vertical_offset_min, vertical_offset_max),
			sin(angle) * horizontal_radius
		)
		var mode := &"carve"
		var material_id := 1
		var radius := rng.randf_range(1.3, 3.8)
		if selected_profile == FLAT_PROFILE:
			radius = rng.randf_range(1.1, 2.4)
		var pattern := index % 20
		if pattern == 14 or pattern == 15:
			mode = &"construct"
			material_id = 4 + (index % 3)
			radius = rng.randf_range(1.8, 3.6)
			if selected_profile == FLAT_PROFILE:
				radius = rng.randf_range(1.4, 2.6)
		elif pattern == 16:
			mode = &"fill"
			material_id = 6
			radius = rng.randf_range(1.7, 3.4)
			if selected_profile == FLAT_PROFILE:
				radius = rng.randf_range(1.3, 2.5)
		elif pattern == 17 or pattern == 18:
			mode = &"paint"
			material_id = 7 + (index % 4)
			radius = rng.randf_range(2.2, 4.4)
			if selected_profile == FLAT_PROFILE:
				radius = rng.randf_range(1.8, 3.0)
		operations.append(_edit_operation(mode, center + offset, radius, material_id, 1.0))
	return operations


func _manifold_stress_path() -> Array:
	var center := _manifold_stress_center()
	var target := center + Vector3(0.0, -4.0, 0.0)
	if selected_profile == FLAT_PROFILE:
		target = center + Vector3(0.0, -2.0, 0.0)
	return [
		{"label": "close", "position": center + Vector3(-12.0, 18.0, -36.0), "target": target},
		{"label": "mid", "position": center + Vector3(-72.0, 58.0, -156.0), "target": target},
		{"label": "far", "position": center + Vector3(-142.0, 92.0, -304.0), "target": target},
		{"label": "cross", "position": center + Vector3(118.0, 76.0, 164.0), "target": target},
		{"label": "return_close", "position": center + Vector3(18.0, 22.0, -42.0), "target": target},
	]


func _set_manifold_stress_camera(label: String) -> bool:
	var path := _manifold_stress_path()
	var step: Dictionary = path[0]
	if label != "initial_close":
		for candidate in path:
			if str(candidate.get("label", "")) == label:
				step = candidate
				break
	await _set_capture_camera_pose(step.get("position", player.global_position), step.get("target", _manifold_stress_center()))
	return true


func _exercise_manifold_stress_step(backend: Node, step: Dictionary, context: String) -> Dictionary:
	if player == null or game_world == null:
		return {"ok": false, "error": "player_or_game_world_unavailable", "context": context}
	var label := str(step.get("label", "step"))
	var position: Vector3 = step.get("position", player.global_position)
	var target: Vector3 = step.get("target", _manifold_stress_center())
	player.global_position = position
	player.velocity = Vector3.ZERO
	if not bool(player.call("autonomous_look_at", target)):
		return {"ok": false, "label": label, "context": context, "error": "look_at_failed"}
	if not bool(game_world.update_player_viewer(true)):
		return {"ok": false, "label": label, "context": context, "error": "viewer_update_failed"}
	var transient_failures := []
	var transient_frames := [1, 8, 20]
	var max_queued_render := 0
	var max_queued_collision := 0
	var max_scheduler_jobs := 0
	var max_pending_retirements := 0
	for frame in range(32):
		await get_tree().process_frame
		var summary: Dictionary = game_world.get_game_world_summary()
		max_queued_render = maxi(max_queued_render, int(summary.get("queued_render", 0)))
		max_queued_collision = maxi(max_queued_collision, int(summary.get("queued_collision", 0)))
		max_scheduler_jobs = maxi(max_scheduler_jobs, int(summary.get("scheduler_queued_jobs", 0)))
		max_pending_retirements = maxi(max_pending_retirements, int(summary.get("pending_chunk_retirements", 0)))
		if transient_frames.has(frame):
			var transient_probe := WatertightnessProbe.collect(
				backend,
				"edit_manifold_stress_%s_frame_%d" % [label, frame],
				_manifold_stress_center(),
				_manifold_stress_probe_radius()
			)
			if not _is_open_gap_free_probe(transient_probe):
				transient_failures.append(_open_gap_probe_digest(transient_probe))
	if not transient_failures.is_empty():
		return {
			"ok": false,
			"label": label,
			"context": context,
			"error": "transient_open_gap_or_nonmanifold",
			"transient_failures": transient_failures,
			"max_queued_render": max_queued_render,
			"max_queued_collision": max_queued_collision,
			"max_scheduler_queued_jobs": max_scheduler_jobs,
			"max_pending_retirements": max_pending_retirements,
		}
	var settle_notes := []
	if not await _wait_for_manifold_stress_visual_ready(
		backend,
		"manifold stress %s %s" % [context, label],
		settle_notes
	):
		var timeout_summary: Dictionary = game_world.get_game_world_summary()
		return {
			"ok": false,
			"label": label,
			"context": context,
			"error": "visual_streaming_not_ready",
			"summary": timeout_summary,
		}
	var settled_probe := WatertightnessProbe.collect(
		backend,
		"edit_manifold_stress_%s_settled" % label,
		_manifold_stress_center(),
		_manifold_stress_probe_radius()
	)
	if not _is_open_gap_free_probe(settled_probe):
		return {
			"ok": false,
			"label": label,
			"context": context,
			"error": "settled_open_gap_or_nonmanifold",
			"settled_probe": _open_gap_probe_digest(settled_probe),
		}
	var digest := _open_gap_probe_digest(settled_probe)
	digest["ok"] = true
	digest["label"] = label
	digest["context"] = context
	digest["max_queued_render"] = max_queued_render
	digest["max_queued_collision"] = max_queued_collision
	digest["max_scheduler_queued_jobs"] = max_scheduler_jobs
	digest["max_pending_retirements"] = max_pending_retirements
	digest["transient_probe_failure_count"] = transient_failures.size()
	digest["settle_notes"] = settle_notes
	return digest


func _wait_for_manifold_stress_visual_ready(
	backend: Node,
	context: String,
	settle_notes: Array
) -> bool:
	var last_summary := {}
	var last_probe := {}
	var frame_limit := maxi(180, human_visual_capture_wait_frames)
	for frame in range(frame_limit):
		var summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
		last_summary = summary
		if _is_lod_movement_visual_ready_summary(summary):
			if frame % 15 != 0 and frame != frame_limit - 1:
				await get_tree().process_frame
				continue
			var probe := WatertightnessProbe.collect(
				backend,
				"edit_manifold_stress_visual_ready",
				_manifold_stress_center(),
				_manifold_stress_probe_radius()
			)
			last_probe = _open_gap_probe_digest(probe)
			if _is_open_gap_free_probe(probe):
				if int(probe.get("zero_area_triangles", 0)) != 0:
					settle_notes.append({
						"context": context,
						"safe_near_zero_area_triangles": int(probe.get("zero_area_triangles", 0)),
						"zero_area_interior_triangles": int(probe.get("zero_area_interior_triangles", 0)),
						"zero_area_chunk_face_triangles": int(probe.get("zero_area_chunk_face_triangles", 0)),
						"minimum_area_squared": float(probe.get("minimum_area_squared", -1.0)),
					})
				return true
		await get_tree().process_frame
	_save_diagnostic_failure_capture(context)
	_fail("manifold stress visual-ready wait failed %s: summary=%s probe=%s" % [
		context,
		str(last_summary),
		str(last_probe),
	])
	return false


func _open_gap_probe_digest(probe: Dictionary) -> Dictionary:
	return {
		"ok": bool(probe.get("ok", false)),
		"boundary_edges": int(probe.get("boundary_edges", -1)),
		"interior_boundary_edges": int(probe.get("interior_boundary_edges", -1)),
		"chunk_face_boundary_edges": int(probe.get("chunk_face_boundary_edges", -1)),
		"unknown_boundary_edges": int(probe.get("unknown_boundary_edges", -1)),
		"nonmanifold_edges": int(probe.get("nonmanifold_edges", -1)),
		"nonmanifold_chunk_face_edges": int(probe.get("nonmanifold_chunk_face_edges", -1)),
		"nonmanifold_interior_edges": int(probe.get("nonmanifold_interior_edges", -1)),
		"nonmanifold_unknown_edges": int(probe.get("nonmanifold_unknown_edges", -1)),
		"orientation_conflict_edges": int(probe.get("orientation_conflict_edges", -1)),
		"orientation_conflict_chunk_face_edges": int(probe.get("orientation_conflict_chunk_face_edges", -1)),
		"orientation_conflict_interior_edges": int(probe.get("orientation_conflict_interior_edges", -1)),
		"orientation_conflict_unknown_edges": int(probe.get("orientation_conflict_unknown_edges", -1)),
		"triangles_in_region": int(probe.get("triangles_in_region", -1)),
		"zero_area_triangles": int(probe.get("zero_area_triangles", -1)),
		"zero_area_chunk_face_triangles": int(probe.get("zero_area_chunk_face_triangles", -1)),
		"zero_area_interior_triangles": int(probe.get("zero_area_interior_triangles", -1)),
		"zero_area_unknown_triangles": int(probe.get("zero_area_unknown_triangles", -1)),
		"zero_edge_triangles": int(probe.get("zero_edge_triangles", -1)),
		"repeated_point_key_triangles": int(probe.get("repeated_point_key_triangles", -1)),
		"repeated_point_key_interior_triangles": int(probe.get("repeated_point_key_interior_triangles", -1)),
		"repeated_point_key_unknown_triangles": int(probe.get("repeated_point_key_unknown_triangles", -1)),
		"minimum_area_squared": float(probe.get("minimum_area_squared", -1.0)),
		"minimum_edge_length_squared": float(probe.get("minimum_edge_length_squared", -1.0)),
		"boundary_examples": probe.get("boundary_examples", []),
		"interior_boundary_examples": probe.get("interior_boundary_examples", []),
		"nonmanifold_examples": probe.get("nonmanifold_examples", []),
		"orientation_conflict_examples": probe.get("orientation_conflict_examples", []),
		"zero_area_examples": probe.get("zero_area_examples", []),
		"repeated_point_key_examples": probe.get("repeated_point_key_examples", []),
	}


func _run_edit_lod_movement_gate(terrain_world: Node) -> bool:
	var operations := _edit_lod_movement_gate_operations()
	if lod_movement_operation_limit >= 0 and lod_movement_operation_limit < operations.size():
		operations = operations.slice(0, lod_movement_operation_limit)
	edit_persistence_operations = operations.duplicate()
	interaction_inspection_operation_count = operations.size()
	last_lod_movement_summary = {
		"enabled": true,
		"ok": false,
		"profile": str(selected_profile),
		"direct_operation_count": operations.size(),
	}
	if operations.is_empty():
		if lod_movement_direct_only:
			last_lod_movement_summary = {
				"enabled": true,
				"ok": true,
				"profile": str(selected_profile),
				"direct_only": true,
				"direct_operation_count": 0,
				"mode_counts": {},
			}
			interaction_inspection_applied = true
			return true
		_fail("LOD movement gate produced no operations")
		return false
	var mode_counts := {}
	for index in range(operations.size()):
		var operation: Resource = operations[index]
		var mode_name := str(operation.call("get_mode_name"))
		mode_counts[mode_name] = int(mode_counts.get(mode_name, 0)) + 1
		var before_revision := int(terrain_world.call("get_backend_world_revision"))
		var batch = EditBatch.new()
		if not batch.add_operation(operation):
			_fail("failed to add LOD movement operation %d" % index)
			return false
		if not bool(terrain_world.call("submit_edit_batch", batch, 8843)):
			_fail("LOD movement operation %d rejected: %s" % [
				index,
				str(terrain_world.call("get_last_error")),
			])
			return false
		if not await game_world.wait_for_world_revision(before_revision + 1):
			_fail("LOD movement operation %d did not commit" % index)
			return false
		if index % 16 == 15:
			if not await _wait_for_current_profile_settled("after LOD movement edit %d" % index):
				return false
		else:
			for _frame in range(2):
				await get_tree().process_frame
	if not await _wait_for_current_profile_settled("after LOD movement direct edits"):
		return false
	if lod_movement_direct_only:
		last_lod_movement_summary = {
			"enabled": true,
			"ok": true,
			"profile": str(selected_profile),
			"direct_only": true,
			"direct_operation_count": operations.size(),
			"mode_counts": mode_counts,
		}
		interaction_inspection_applied = true
		return true
	var interaction_result: Dictionary = await _run_lod_movement_player_interactions(terrain_world)
	if not bool(interaction_result.get("ok", false)):
		last_lod_movement_summary = {
			"enabled": true,
			"ok": false,
			"error": "interaction_path_failed",
			"interaction_result": interaction_result,
		}
		_fail("LOD movement gate interaction path failed: %s" % JSON.stringify(interaction_result))
		return false
	var interaction_operations: Array = interaction_result.get("operations", [])
	for operation in interaction_operations:
		edit_persistence_operations.append(operation)
	interaction_inspection_operation_count = edit_persistence_operations.size()
	var baseline_snapshot := await _collect_edit_persistence_snapshot(terrain_world, "LOD movement baseline")
	if not bool(baseline_snapshot.get("ok", false)):
		return false
	if not _edit_stability_snapshot_has_material_diversity(baseline_snapshot):
		return false
	var backend: Node = terrain_world.call("get_backend_terrain")
	if backend == null:
		_fail("LOD movement gate backend unavailable")
		return false
	var transition_summaries := []
	var persistence_summaries := []
	for step in _edit_lod_movement_path():
		var transition: Dictionary = await _exercise_lod_movement_step(backend, step)
		transition_summaries.append(transition)
		if not bool(transition.get("ok", false)):
			last_lod_movement_summary = {
				"enabled": true,
				"ok": false,
				"error": "movement_step_failed",
				"failed_step": transition,
				"transition_summaries": transition_summaries,
			}
			_fail("LOD movement gate step failed: %s" % JSON.stringify(transition))
			return false
		var after_snapshot := await _collect_edit_persistence_snapshot(
			terrain_world,
			"LOD movement after %s" % str(step.get("label", "step"))
		)
		if not bool(after_snapshot.get("ok", false)):
			return false
		if not _compare_edit_persistence_snapshots(baseline_snapshot, after_snapshot):
			last_lod_movement_summary = {
				"enabled": true,
				"ok": false,
				"error": "persistence_changed_after_lod_movement",
				"failed_step": str(step.get("label", "step")),
				"persistence": last_edit_persistence_summary,
				"transition_summaries": transition_summaries,
			}
			return false
		persistence_summaries.append({
			"label": str(step.get("label", "step")),
			"sample_count": int(last_edit_persistence_summary.get("sample_count", 0)),
			"density_mismatches": int(last_edit_persistence_summary.get("density_mismatches", -1)),
			"material_mismatches": int(last_edit_persistence_summary.get("material_mismatches", -1)),
			"max_abs_density_delta": float(last_edit_persistence_summary.get("max_abs_density_delta", -1.0)),
		})
	if not await _save_lod_movement_gate_captures():
		return false
	var runtime_summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
	last_lod_movement_summary = {
		"enabled": true,
		"ok": true,
		"profile": str(selected_profile),
		"direct_operation_count": operations.size(),
		"interaction_operation_count": interaction_operations.size(),
		"total_operation_count": edit_persistence_operations.size(),
		"mode_counts": mode_counts,
		"interaction_strict_settle_notes": interaction_result.get("strict_settle_notes", []),
		"sample_count": int(last_edit_persistence_summary.get("sample_count", 0)),
		"density_mismatches": int(last_edit_persistence_summary.get("density_mismatches", -1)),
		"material_mismatches": int(last_edit_persistence_summary.get("material_mismatches", -1)),
		"max_abs_density_delta": float(last_edit_persistence_summary.get("max_abs_density_delta", -1.0)),
		"transition_summaries": transition_summaries,
		"persistence_summaries": persistence_summaries,
		"render_resources": int(runtime_summary.get("render_resources", 0)),
		"collision_resources": int(runtime_summary.get("collision_resources", 0)),
		"active_chunk_records": int(runtime_summary.get("active_chunk_records", 0)),
	}
	if material_applicator != null:
		material_applicator.call("apply_materials_now")
	interaction_inspection_applied = true
	return true


func _edit_lod_movement_gate_operations() -> Array:
	var operations: Array = []
	var seeds := [615197, 382091, 928371, 470039]
	var center := _edit_lod_movement_gate_center()
	var horizontal_radius_limit := 30.0
	var vertical_offset_min := -14.0
	var vertical_offset_max := -2.0
	if selected_profile == FLAT_PROFILE:
		horizontal_radius_limit = 8.5
		vertical_offset_min = -2.2
		vertical_offset_max = 2.8
	for seed_index in range(seeds.size()):
		var rng := RandomNumberGenerator.new()
		rng.seed = int(seeds[seed_index])
		for index in range(32):
			var angle := rng.randf_range(0.0, TAU)
			var horizontal_radius := rng.randf_range(0.0, horizontal_radius_limit)
			var offset := Vector3(
				cos(angle) * horizontal_radius,
				rng.randf_range(vertical_offset_min, vertical_offset_max),
				sin(angle) * horizontal_radius
			)
			var pattern := index % 12
			var mode := &"carve"
			var material_id := 1
			var radius := rng.randf_range(1.4, 3.6)
			if selected_profile == FLAT_PROFILE:
				radius = rng.randf_range(1.3, 2.2)
			if pattern == 8:
				mode = &"construct"
				material_id = 3 + seed_index
				radius = rng.randf_range(2.0, 4.2)
				if selected_profile == FLAT_PROFILE:
					radius = rng.randf_range(1.5, 2.5)
			elif pattern == 9:
				mode = &"fill"
				material_id = 4 + seed_index
				radius = rng.randf_range(1.8, 3.8)
				if selected_profile == FLAT_PROFILE:
					radius = rng.randf_range(1.5, 2.4)
			elif pattern == 10:
				mode = &"paint"
				material_id = 7 + seed_index
				radius = rng.randf_range(2.0, 4.5)
				if selected_profile == FLAT_PROFILE:
					radius = rng.randf_range(1.8, 2.8)
			operations.append(_edit_operation(
				mode,
				center + offset,
				radius,
				material_id,
				1.0
			))
	return operations


func _run_lod_movement_player_interactions(terrain_world: Node) -> Dictionary:
	if player == null or game_world == null:
		return {"ok": false, "error": "player_or_game_world_unavailable"}
	var backend: Node = terrain_world.call("get_backend_terrain")
	if backend == null:
		return {"ok": false, "error": "backend_unavailable"}
	var center := _edit_lod_movement_gate_center()
	var approximates := [
		center + Vector3(-18.0, 0.0, -18.0),
		center + Vector3(18.0, 0.0, -12.0),
		center + Vector3(-8.0, 0.0, 22.0),
		center + Vector3(24.0, 0.0, 18.0),
	]
	var target := _find_collision_surface_near(approximates)
	if is_inf(target.x):
		return {"ok": false, "error": "no_collision_surface_for_interaction"}
	var interaction_operations := []
	var interaction_summaries := []
	var strict_settle_notes := []
	var use_direct_surface_edits := selected_profile == FLAT_PROFILE
	for index in range(4):
		var offset := Vector3(
			float((index % 3) - 1) * 7.5,
			0.0,
			float((index / 2) - 0.5) * 8.0
		)
		var aim_target := target + offset
		var camera_position := aim_target + Vector3(-14.0, 13.0, -32.0)
		player.global_position = camera_position
		player.velocity = Vector3.ZERO
		if not bool(game_world.update_player_viewer(true)):
			return {"ok": false, "error": "viewer_update_failed_before_interaction", "index": index}
		if not await _wait_for_lod_movement_visual_ready(
			backend,
			"before LOD movement player interaction %d" % index,
			strict_settle_notes
		):
			return {"ok": false, "error": "not_visual_ready_before_interaction", "index": index}
		var mode := &"carve" if index % 3 != 2 else &"construct"
		var before_revision := int(terrain_world.call("get_backend_world_revision"))
		var interaction_summary: Dictionary = player.call("get_last_interaction_summary")
		if use_direct_surface_edits:
			var edit_target := _find_collision_surface_near([aim_target, target, center])
			if is_inf(edit_target.x):
				return {"ok": false, "error": "no_collision_surface_for_direct_interaction", "index": index}
			if not bool(player.call("submit_edit_input", mode, edit_target, false)):
				var rejected_direct_summary: Dictionary = player.call("get_last_interaction_summary")
				return {
					"ok": false,
					"error": "direct_interaction_rejected",
					"index": index,
					"summary": rejected_direct_summary,
				}
			interaction_summary = player.call("get_last_interaction_summary")
			if not bool(interaction_summary.get("accepted", false)):
				return {
					"ok": false,
					"error": "direct_interaction_not_accepted",
					"index": index,
					"summary": interaction_summary,
				}
		else:
			if not bool(player.call("autonomous_look_at", aim_target)):
				return {"ok": false, "error": "look_at_failed", "index": index}
			await get_tree().physics_frame
			if not bool(player.call("autonomous_submit_interaction", mode)):
				var rejected_summary: Dictionary = player.call("get_last_interaction_summary")
				return {
					"ok": false,
					"error": "interaction_rejected",
					"index": index,
					"summary": rejected_summary,
				}
			interaction_summary = player.call("get_last_interaction_summary")
			if not bool(interaction_summary.get("ray_hit", false)) or not bool(interaction_summary.get("accepted", false)):
				return {
					"ok": false,
					"error": "interaction_not_accepted",
					"index": index,
					"summary": interaction_summary,
				}
		if not await game_world.wait_for_world_revision(before_revision + 1):
			return {"ok": false, "error": "interaction_revision_not_committed", "index": index}
		if not await _wait_for_lod_movement_visual_ready(
			backend,
			"after LOD movement player interaction %d" % index,
			strict_settle_notes
		):
			return {"ok": false, "error": "not_visual_ready_after_interaction", "index": index}
		var edit_position: Vector3 = interaction_summary.get("position", aim_target)
		var material_id := 1 if mode == &"carve" else 4
		interaction_operations.append(_edit_operation(
			mode,
			edit_position,
			float(player.get("edit_radius")),
			material_id,
			1.0
		))
		interaction_summaries.append(interaction_summary)
	return {
		"ok": true,
		"operation_count": interaction_operations.size(),
		"operations": interaction_operations,
		"summaries": interaction_summaries,
		"strict_settle_notes": strict_settle_notes,
	}


func _edit_lod_movement_path() -> Array:
	var center := _edit_lod_movement_gate_center()
	var target := center + Vector3(0.0, -4.0, 0.0)
	return [
		{"label": "close", "position": center + Vector3(-12.0, 18.0, -36.0), "target": target},
		{"label": "mid", "position": center + Vector3(-68.0, 54.0, -146.0), "target": target},
		{"label": "far", "position": center + Vector3(-132.0, 86.0, -286.0), "target": target},
		{"label": "return_close", "position": center + Vector3(16.0, 20.0, -40.0), "target": target},
	]


func _wait_for_lod_movement_visual_ready(
	backend: Node,
	context: String,
	strict_settle_notes: Array
) -> bool:
	var last_summary := {}
	var last_probe := {}
	var frame_limit := maxi(120, human_visual_capture_wait_frames)
	for frame in range(frame_limit):
		var summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
		last_summary = summary
		if _is_lod_movement_visual_ready_summary(summary):
			if frame % 15 != 0 and frame != frame_limit - 1:
				await get_tree().process_frame
				continue
			var probe := WatertightnessProbe.collect(
				backend,
				"edit_lod_movement_gate_visual_ready",
				_edit_lod_movement_gate_center(),
				_edit_lod_movement_probe_radius()
			)
			last_probe = {
				"ok": bool(probe.get("ok", false)),
				"boundary_edges": int(probe.get("boundary_edges", -1)),
				"interior_boundary_edges": int(probe.get("interior_boundary_edges", -1)),
				"chunk_face_boundary_edges": int(probe.get("chunk_face_boundary_edges", -1)),
				"unknown_boundary_edges": int(probe.get("unknown_boundary_edges", -1)),
				"nonmanifold_edges": int(probe.get("nonmanifold_edges", -1)),
				"nonmanifold_chunk_face_edges": int(probe.get("nonmanifold_chunk_face_edges", -1)),
				"nonmanifold_interior_edges": int(probe.get("nonmanifold_interior_edges", -1)),
				"nonmanifold_unknown_edges": int(probe.get("nonmanifold_unknown_edges", -1)),
				"orientation_conflict_edges": int(probe.get("orientation_conflict_edges", -1)),
				"orientation_conflict_chunk_face_edges": int(probe.get("orientation_conflict_chunk_face_edges", -1)),
				"orientation_conflict_interior_edges": int(probe.get("orientation_conflict_interior_edges", -1)),
				"orientation_conflict_unknown_edges": int(probe.get("orientation_conflict_unknown_edges", -1)),
				"triangles_in_region": int(probe.get("triangles_in_region", -1)),
				"zero_area_triangles": int(probe.get("zero_area_triangles", -1)),
				"zero_area_chunk_face_triangles": int(probe.get("zero_area_chunk_face_triangles", -1)),
				"zero_area_interior_triangles": int(probe.get("zero_area_interior_triangles", -1)),
				"zero_area_unknown_triangles": int(probe.get("zero_area_unknown_triangles", -1)),
				"zero_edge_triangles": int(probe.get("zero_edge_triangles", -1)),
				"repeated_point_key_triangles": int(probe.get("repeated_point_key_triangles", -1)),
				"repeated_point_key_chunk_face_triangles": int(probe.get("repeated_point_key_chunk_face_triangles", -1)),
				"repeated_point_key_interior_triangles": int(probe.get("repeated_point_key_interior_triangles", -1)),
				"repeated_point_key_unknown_triangles": int(probe.get("repeated_point_key_unknown_triangles", -1)),
				"minimum_area_squared": float(probe.get("minimum_area_squared", -1.0)),
				"minimum_edge_length_squared": float(probe.get("minimum_edge_length_squared", -1.0)),
				"boundary_examples": probe.get("boundary_examples", []),
				"interior_boundary_examples": probe.get("interior_boundary_examples", []),
				"nonmanifold_examples": probe.get("nonmanifold_examples", []),
				"orientation_conflict_examples": probe.get("orientation_conflict_examples", []),
				"zero_area_examples": probe.get("zero_area_examples", []),
				"repeated_point_key_examples": probe.get("repeated_point_key_examples", []),
			}
			if _is_lod_movement_probe_ready(probe):
				if int(summary.get("pending_chunk_retirements", 0)) != 0 or \
						int(summary.get("fully_ready_chunk_records", 0)) < int(summary.get("active_chunk_records", 0)):
					strict_settle_notes.append({
						"context": context,
						"pending_chunk_retirements": int(summary.get("pending_chunk_retirements", 0)),
						"active_chunk_records": int(summary.get("active_chunk_records", 0)),
						"visual_ready_chunk_records": int(summary.get("visual_ready_chunk_records", 0)),
						"fully_ready_chunk_records": int(summary.get("fully_ready_chunk_records", 0)),
						"render_resources": int(summary.get("render_resources", 0)),
						"collision_resources": int(summary.get("collision_resources", 0)),
					})
				return true
		await get_tree().process_frame
	_save_diagnostic_failure_capture(context)
	_fail("LOD movement visual-ready wait failed %s: summary=%s probe=%s" % [context, str(last_summary), str(last_probe)])
	return false


func _is_lod_movement_visual_ready_summary(summary: Dictionary) -> bool:
	if not bool(summary.get("backend_running", summary.get("world_running", true))):
		return false
	if int(summary.get("queued_render", 0)) != 0:
		return false
	if int(summary.get("queued_collision", 0)) != 0:
		return false
	if int(summary.get("scheduler_queued_jobs", 0)) != 0:
		return false
	if int(summary.get("scheduler_queued_completions", 0)) != 0:
		return false
	if int(summary.get("scheduler_failed_records", 0)) != 0:
		return false
	if int(summary.get("page_sample_failures", 0)) != 0:
		return false
	if int(summary.get("page_mesh_failures", 0)) != 0:
		return false
	if int(summary.get("pending_chunk_retirements", 0)) != 0:
		return false
	if int(summary.get("render_fading_resources", 0)) != 0:
		return false
	if int(summary.get("staged_render_resources", 0)) != 0:
		return false
	if int(summary.get("render_resources", 0)) <= 0:
		return false
	if int(summary.get("collision_resources", 0)) <= 0:
		return false
	if summary.has("fully_ready_chunk_records") and \
			int(summary.get("fully_ready_chunk_records", 0)) < int(summary.get("active_chunk_records", 0)):
		return false
	return true


func _wait_for_edit_during_load_visual_ready(
	backend: Node,
	context: String,
	settle_notes: Array
) -> bool:
	var last_summary := {}
	var last_probe := {}
	var frame_limit := maxi(120, human_visual_capture_wait_frames)
	for frame in range(frame_limit):
		var summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
		last_summary = summary
		if _is_lod_movement_visual_ready_summary(summary):
			if frame % 15 != 0 and frame != frame_limit - 1:
				await get_tree().process_frame
				continue
			var probe := WatertightnessProbe.collect(
				backend,
				"edit_during_load_visual_ready",
				_edit_during_load_oracle_center(),
				_watertightness_probe_radius()
			)
			last_probe = {
				"ok": bool(probe.get("ok", false)),
				"boundary_edges": int(probe.get("boundary_edges", -1)),
				"interior_boundary_edges": int(probe.get("interior_boundary_edges", -1)),
				"chunk_face_boundary_edges": int(probe.get("chunk_face_boundary_edges", -1)),
				"unknown_boundary_edges": int(probe.get("unknown_boundary_edges", -1)),
				"nonmanifold_edges": int(probe.get("nonmanifold_edges", -1)),
				"nonmanifold_interior_edges": int(probe.get("nonmanifold_interior_edges", -1)),
				"nonmanifold_unknown_edges": int(probe.get("nonmanifold_unknown_edges", -1)),
				"zero_area_triangles": int(probe.get("zero_area_triangles", -1)),
				"zero_area_chunk_face_triangles": int(probe.get("zero_area_chunk_face_triangles", -1)),
				"zero_area_interior_triangles": int(probe.get("zero_area_interior_triangles", -1)),
				"zero_area_unknown_triangles": int(probe.get("zero_area_unknown_triangles", -1)),
				"zero_edge_triangles": int(probe.get("zero_edge_triangles", -1)),
				"repeated_point_key_triangles": int(probe.get("repeated_point_key_triangles", -1)),
				"repeated_point_key_interior_triangles": int(probe.get("repeated_point_key_interior_triangles", -1)),
				"repeated_point_key_unknown_triangles": int(probe.get("repeated_point_key_unknown_triangles", -1)),
				"triangles_in_region": int(probe.get("triangles_in_region", -1)),
				"zero_area_examples": probe.get("zero_area_examples", []),
				"boundary_examples": probe.get("boundary_examples", []),
				"interior_boundary_examples": probe.get("interior_boundary_examples", []),
				"nonmanifold_examples": probe.get("nonmanifold_examples", []),
				"repeated_point_key_examples": probe.get("repeated_point_key_examples", []),
			}
			if _is_open_gap_free_probe(probe):
				if int(probe.get("zero_area_interior_triangles", 0)) != 0 or \
						int(probe.get("zero_area_chunk_face_triangles", 0)) != 0:
					settle_notes.append({
						"context": context,
						"safe_near_zero_area_triangles": int(probe.get("zero_area_triangles", 0)),
						"zero_area_interior_triangles": int(probe.get("zero_area_interior_triangles", 0)),
						"zero_area_chunk_face_triangles": int(probe.get("zero_area_chunk_face_triangles", 0)),
						"minimum_area_squared": float(probe.get("minimum_area_squared", -1.0)),
					})
				return true
		await get_tree().process_frame
	_save_diagnostic_failure_capture(context)
	_fail("edit-during-load visual-ready wait failed %s: summary=%s probe=%s" % [
		context,
		str(last_summary),
		str(last_probe),
	])
	return false


func _exercise_lod_movement_step(backend: Node, step: Dictionary) -> Dictionary:
	if player == null or game_world == null:
		return {"ok": false, "error": "player_or_game_world_unavailable"}
	var label := str(step.get("label", "step"))
	var position: Vector3 = step.get("position", player.global_position)
	var target: Vector3 = step.get("target", _edit_lod_movement_gate_center())
	player.global_position = position
	player.velocity = Vector3.ZERO
	if not bool(player.call("autonomous_look_at", target)):
		return {"ok": false, "label": label, "error": "look_at_failed"}
	if not bool(game_world.update_player_viewer(true)):
		return {"ok": false, "label": label, "error": "viewer_update_failed"}
	var transient_probe_failures := []
	var transient_frames := [1, 12]
	var max_queued_render := 0
	var max_queued_collision := 0
	var max_pending_retirements := 0
	var max_render_fading := 0
	var min_render_resources := 9223372036854775807
	var min_collision_resources := 9223372036854775807
	var max_scheduler_jobs := 0
	for frame in range(30):
		await get_tree().process_frame
		var summary: Dictionary = game_world.get_game_world_summary()
		max_queued_render = maxi(max_queued_render, int(summary.get("queued_render", 0)))
		max_queued_collision = maxi(max_queued_collision, int(summary.get("queued_collision", 0)))
		max_pending_retirements = maxi(max_pending_retirements, int(summary.get("pending_chunk_retirements", 0)))
		max_render_fading = maxi(max_render_fading, int(summary.get("render_fading_resources", 0)))
		min_render_resources = mini(min_render_resources, int(summary.get("render_resources", 0)))
		min_collision_resources = mini(min_collision_resources, int(summary.get("collision_resources", 0)))
		max_scheduler_jobs = maxi(max_scheduler_jobs, int(summary.get("scheduler_queued_jobs", 0)))
		if transient_frames.has(frame):
			var transient_probe := WatertightnessProbe.collect(
				backend,
				"edit_lod_movement_gate_%s_frame_%d" % [label, frame],
				_edit_lod_movement_gate_center(),
				_edit_lod_movement_probe_radius()
			)
			if not _is_lod_movement_probe_ready(transient_probe):
				transient_probe_failures.append({
					"frame": frame,
					"boundary_edges": int(transient_probe.get("boundary_edges", -1)),
					"interior_boundary_edges": int(transient_probe.get("interior_boundary_edges", -1)),
					"chunk_face_boundary_edges": int(transient_probe.get("chunk_face_boundary_edges", -1)),
					"unknown_boundary_edges": int(transient_probe.get("unknown_boundary_edges", -1)),
					"nonmanifold_edges": int(transient_probe.get("nonmanifold_edges", -1)),
					"nonmanifold_chunk_face_edges": int(transient_probe.get("nonmanifold_chunk_face_edges", -1)),
					"nonmanifold_interior_edges": int(transient_probe.get("nonmanifold_interior_edges", -1)),
					"nonmanifold_unknown_edges": int(transient_probe.get("nonmanifold_unknown_edges", -1)),
					"zero_area_triangles": int(transient_probe.get("zero_area_triangles", -1)),
					"zero_area_chunk_face_triangles": int(transient_probe.get("zero_area_chunk_face_triangles", -1)),
					"zero_area_interior_triangles": int(transient_probe.get("zero_area_interior_triangles", -1)),
					"zero_area_unknown_triangles": int(transient_probe.get("zero_area_unknown_triangles", -1)),
					"repeated_point_key_triangles": int(transient_probe.get("repeated_point_key_triangles", -1)),
					"repeated_point_key_chunk_face_triangles": int(transient_probe.get("repeated_point_key_chunk_face_triangles", -1)),
					"repeated_point_key_interior_triangles": int(transient_probe.get("repeated_point_key_interior_triangles", -1)),
					"repeated_point_key_unknown_triangles": int(transient_probe.get("repeated_point_key_unknown_triangles", -1)),
					"triangles_in_region": int(transient_probe.get("triangles_in_region", -1)),
					"examples": transient_probe.get("boundary_examples", []),
					"interior_boundary_examples": transient_probe.get("interior_boundary_examples", []),
					"nonmanifold_examples": transient_probe.get("nonmanifold_examples", []),
					"repeated_point_key_examples": transient_probe.get("repeated_point_key_examples", []),
				})
	var strict_settle_notes := []
	if not await _wait_for_lod_movement_visual_ready(
		backend,
		"after LOD movement step %s" % label,
		strict_settle_notes
	):
		var timeout_summary: Dictionary = game_world.get_game_world_summary()
		return {
			"ok": false,
			"label": label,
			"error": "visual_streaming_not_ready",
			"summary": timeout_summary,
		}
	var settled_probe := WatertightnessProbe.collect(
		backend,
		"edit_lod_movement_gate_%s_settled" % label,
		_edit_lod_movement_gate_center(),
		_edit_lod_movement_probe_radius()
	)
	if not _is_lod_movement_probe_ready(settled_probe):
		return {
			"ok": false,
			"label": label,
			"error": "settled_watertightness_failure",
			"settled_probe": settled_probe,
		}
	return {
		"ok": true,
		"label": label,
		"max_queued_render": max_queued_render,
		"max_queued_collision": max_queued_collision,
		"max_pending_retirements": max_pending_retirements,
		"max_render_fading_resources": max_render_fading,
		"min_render_resources": min_render_resources,
		"min_collision_resources": min_collision_resources,
		"max_scheduler_queued_jobs": max_scheduler_jobs,
		"transient_probe_failures": transient_probe_failures,
		"transient_probe_failure_count": transient_probe_failures.size(),
		"strict_settle_notes": strict_settle_notes,
		"settled_boundary_edges": int(settled_probe.get("boundary_edges", -1)),
		"settled_interior_boundary_edges": int(settled_probe.get("interior_boundary_edges", -1)),
		"settled_chunk_face_boundary_edges": int(settled_probe.get("chunk_face_boundary_edges", -1)),
		"settled_unknown_boundary_edges": int(settled_probe.get("unknown_boundary_edges", -1)),
		"settled_nonmanifold_edges": int(settled_probe.get("nonmanifold_edges", -1)),
		"settled_nonmanifold_chunk_face_edges": int(settled_probe.get("nonmanifold_chunk_face_edges", -1)),
		"settled_nonmanifold_interior_edges": int(settled_probe.get("nonmanifold_interior_edges", -1)),
		"settled_nonmanifold_unknown_edges": int(settled_probe.get("nonmanifold_unknown_edges", -1)),
		"settled_orientation_conflict_edges": int(settled_probe.get("orientation_conflict_edges", -1)),
		"settled_orientation_conflict_chunk_face_edges": int(settled_probe.get("orientation_conflict_chunk_face_edges", -1)),
		"settled_orientation_conflict_interior_edges": int(settled_probe.get("orientation_conflict_interior_edges", -1)),
		"settled_orientation_conflict_unknown_edges": int(settled_probe.get("orientation_conflict_unknown_edges", -1)),
		"settled_zero_area_triangles": int(settled_probe.get("zero_area_triangles", -1)),
		"settled_zero_area_chunk_face_triangles": int(settled_probe.get("zero_area_chunk_face_triangles", -1)),
		"settled_zero_area_interior_triangles": int(settled_probe.get("zero_area_interior_triangles", -1)),
		"settled_zero_area_unknown_triangles": int(settled_probe.get("zero_area_unknown_triangles", -1)),
		"settled_zero_edge_triangles": int(settled_probe.get("zero_edge_triangles", -1)),
		"settled_repeated_point_key_triangles": int(settled_probe.get("repeated_point_key_triangles", -1)),
		"settled_repeated_point_key_chunk_face_triangles": int(settled_probe.get("repeated_point_key_chunk_face_triangles", -1)),
		"settled_repeated_point_key_interior_triangles": int(settled_probe.get("repeated_point_key_interior_triangles", -1)),
		"settled_repeated_point_key_unknown_triangles": int(settled_probe.get("repeated_point_key_unknown_triangles", -1)),
		"settled_triangles_in_region": int(settled_probe.get("triangles_in_region", -1)),
	}


func _is_lod_movement_probe_ready(probe: Dictionary) -> bool:
	if bool(probe.get("ok", false)):
		return true
	if not lod_movement_gap_only_probe:
		return false
	return int(probe.get("interior_boundary_edges", -1)) == 0 and \
		int(probe.get("unknown_boundary_edges", -1)) == 0 and \
		int(probe.get("nonmanifold_edges", -1)) == 0 and \
		int(probe.get("orientation_conflict_edges", -1)) == 0 and \
		int(probe.get("zero_area_interior_triangles", 0)) == 0 and \
		int(probe.get("zero_area_unknown_triangles", 0)) == 0 and \
		int(probe.get("repeated_point_key_interior_triangles", 0)) == 0 and \
		int(probe.get("repeated_point_key_unknown_triangles", 0)) == 0 and \
		int(probe.get("zero_edge_triangles", -1)) == 0 and \
		int(probe.get("triangles_in_region", 0)) > 0


func _is_open_gap_free_probe(probe: Dictionary) -> bool:
	if bool(probe.get("ok", false)):
		return true
	var boundary_edges := int(probe.get("boundary_edges", -1))
	var chunk_face_boundary_edges := int(probe.get("chunk_face_boundary_edges", 0))
	return int(probe.get("interior_boundary_edges", boundary_edges)) == 0 and \
		int(probe.get("unknown_boundary_edges", 0)) == 0 and \
		boundary_edges == chunk_face_boundary_edges and \
		int(probe.get("nonmanifold_edges", -1)) == 0 and \
		int(probe.get("orientation_conflict_edges", -1)) == 0 and \
		int(probe.get("zero_area_unknown_triangles", 0)) == 0 and \
		int(probe.get("repeated_point_key_interior_triangles", 0)) == 0 and \
		int(probe.get("repeated_point_key_unknown_triangles", 0)) == 0 and \
		int(probe.get("zero_edge_triangles", -1)) == 0 and \
		int(probe.get("triangles_in_region", 0)) > 0


func _save_lod_movement_gate_captures() -> bool:
	if human_visual_capture_path.is_empty():
		return true
	var steps := _edit_lod_movement_path()
	for step in steps:
		var label := str(step.get("label", "step"))
		if label != "close" and label != "mid" and label != "far":
			continue
		var output_path := _capture_variant_path(label)
		await _set_capture_camera_pose(step.get("position", player.global_position), step.get("target", _edit_lod_movement_gate_center()))
		var image := get_viewport().get_texture().get_image()
		var error := image.save_png(output_path)
		if error != OK:
			_fail("failed to save LOD movement %s capture to %s" % [label, output_path])
			return false
	return true


func _capture_variant_path(label: String) -> String:
	var dot_index := human_visual_capture_path.rfind(".")
	if dot_index > 0:
		return human_visual_capture_path.substr(0, dot_index) + "_" + label + ".png"
	return human_visual_capture_path + "_" + label + ".png"


func _save_diagnostic_failure_capture(label: String) -> void:
	if human_visual_capture_path.is_empty():
		return
	var safe_label := label.replace(" ", "_").replace("/", "_").replace("\\", "_").replace(":", "_")
	var output_path := _capture_variant_path("failure_" + safe_label)
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(output_path)
	if error != OK:
		push_error("WT_DIAGNOSTIC_CAPTURE_FAIL: %s error=%d" % [output_path, int(error)])


func _set_capture_camera_pose(position: Vector3, target: Vector3) -> void:
	if player == null:
		return
	var camera := player.get_node_or_null("FirstPersonCamera") as Camera3D
	if camera == null:
		return
	player.global_position = position
	player.velocity = Vector3.ZERO
	camera.far = 5000.0
	camera.fov = 75.0
	camera.look_at_from_position(position, target, Vector3.UP)
	camera.current = true
	camera.make_current()
	if game_world != null and game_world.has_method("update_player_viewer"):
		game_world.call("update_player_viewer", true)
	for _frame in range(12):
		await get_tree().process_frame


func _sequential_interaction_inspection_operations() -> Array:
	var operations: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 615197
	var center := _watertightness_edit_center()
	for index in range(96):
		var angle := rng.randf_range(0.0, TAU)
		var horizontal_radius := rng.randf_range(0.0, 16.0)
		var offset := Vector3(
			cos(angle) * horizontal_radius,
			rng.randf_range(-8.0, 3.0),
			sin(angle) * horizontal_radius
		)
		if index % 5 == 0:
			offset += Vector3(0.0, rng.randf_range(-2.0, 2.0), rng.randf_range(-5.0, 5.0))
		operations.append(_edit_operation(
			&"carve",
			center + offset,
			rng.randf_range(1.4, 2.4),
			1,
			1.0
		))
	return operations


func _edit_persistence_points() -> Array:
	var points: Array = []
	var seen := {}
	var operations: Array = edit_persistence_operations
	if operations.is_empty():
		operations = _sequential_interaction_inspection_operations()
	for operation in operations:
		var center: Vector3 = operation.get("center")
		var radius := float(operation.get("radius"))
		var offsets := [
			Vector3.ZERO,
			Vector3(radius * 0.50, 0.0, 0.0),
			Vector3(-radius * 0.50, 0.0, 0.0),
			Vector3(0.0, radius * 0.50, 0.0),
			Vector3(0.0, -radius * 0.50, 0.0),
			Vector3(0.0, 0.0, radius * 0.50),
			Vector3(0.0, 0.0, -radius * 0.50),
		]
		for offset_index in range(offsets.size()):
			var offset: Vector3 = offsets[offset_index]
			var position: Vector3 = center + offset
			var point := Vector3i(
				int(round(position.x)),
				int(round(position.y)),
				int(round(position.z))
			)
			var key := _grid_point_key(point)
			if not seen.has(key):
				seen[key] = true
				points.append(point)
	return points


func _collect_edit_persistence_snapshot(terrain_world: Node, context: String) -> Dictionary:
	var points := _edit_persistence_points()
	if points.is_empty():
		_fail("edit persistence oracle has no sample points")
		return {"ok": false, "error": "no_sample_points"}
	_ensure_authoritative_sample_connections(terrain_world)
	var request_id := int(terrain_world.call("request_authoritative_samples", points, 0))
	if request_id <= 0:
		var error := str(terrain_world.call("get_last_error")) if terrain_world.has_method("get_last_error") else "unknown"
		_fail("edit persistence oracle query rejected %s: %s" % [context, error])
		return {"ok": false, "error": "query_rejected", "context": context}
	for _frame in range(600):
		if authoritative_sample_failures.has(request_id):
			var failure_error := str(authoritative_sample_failures[request_id])
			authoritative_sample_failures.erase(request_id)
			var diagnostics := await _diagnose_authoritative_sample_points(terrain_world, points, 8)
			_fail("edit persistence oracle query failed %s: %s diagnostics=%s" % [
				context,
				failure_error,
				JSON.stringify(diagnostics),
			])
			return {
				"ok": false,
				"error": failure_error,
				"context": context,
				"diagnostics": diagnostics,
			}
		if authoritative_sample_batches.has(request_id):
			var samples: Array = authoritative_sample_batches[request_id]
			authoritative_sample_batches.erase(request_id)
			return _samples_to_persistence_snapshot(samples, context)
		await get_tree().process_frame
	_fail("edit persistence oracle query timed out %s request=%d" % [context, request_id])
	return {"ok": false, "error": "query_timeout", "context": context}


func _diagnose_authoritative_sample_points(
	terrain_world: Node,
	points: Array,
	failure_limit: int
) -> Dictionary:
	var failures := []
	var checked_count := 0
	var ok_count := 0
	for point in points:
		var request_point: Vector3i = point
		var request_id := int(terrain_world.call("request_authoritative_samples", [request_point], 0))
		checked_count += 1
		if request_id <= 0:
			var error := str(terrain_world.call("get_last_error")) if terrain_world.has_method("get_last_error") else "request_rejected"
			failures.append(_authoritative_sample_point_failure(request_point, error))
		else:
			var resolved := false
			for _frame in range(120):
				if authoritative_sample_failures.has(request_id):
					var failure_error := str(authoritative_sample_failures[request_id])
					authoritative_sample_failures.erase(request_id)
					failures.append(_authoritative_sample_point_failure(request_point, failure_error))
					resolved = true
					break
				if authoritative_sample_batches.has(request_id):
					authoritative_sample_batches.erase(request_id)
					ok_count += 1
					resolved = true
					break
				await get_tree().process_frame
			if not resolved:
				failures.append(_authoritative_sample_point_failure(request_point, "diagnostic_timeout"))
		if failures.size() >= failure_limit:
			break
	return {
		"point_count": points.size(),
		"checked_count": checked_count,
		"ok_checked_count": ok_count,
		"bounds": _authoritative_sample_point_bounds(points),
		"failures": failures,
	}


func _authoritative_sample_point_failure(point: Vector3i, error: String) -> Dictionary:
	return {
		"point": _grid_point_key(point),
		"chunk_guess_lod0": "%d,%d,%d" % [
			floori(float(point.x) / 16.0),
			floori(float(point.y) / 16.0),
			floori(float(point.z) / 16.0),
		],
		"error": error,
	}


func _authoritative_sample_point_bounds(points: Array) -> Dictionary:
	if points.is_empty():
		return {}
	var first: Vector3i = points[0]
	var min_point := first
	var max_point := first
	for point in points:
		var typed_point: Vector3i = point
		min_point = Vector3i(
			mini(min_point.x, typed_point.x),
			mini(min_point.y, typed_point.y),
			mini(min_point.z, typed_point.z)
		)
		max_point = Vector3i(
			maxi(max_point.x, typed_point.x),
			maxi(max_point.y, typed_point.y),
			maxi(max_point.z, typed_point.z)
		)
	return {
		"min": _grid_point_key(min_point),
		"max": _grid_point_key(max_point),
	}


func _samples_to_persistence_snapshot(samples: Array, context: String) -> Dictionary:
	var sample_map := {}
	var air_sample_count := 0
	var material_histogram := {}
	var world_revision_min := 9223372036854775807
	var world_revision_max := -1
	for sample in samples:
		if sample == null:
			continue
		var point: Vector3i = sample.call("get_grid_point")
		var material := int(sample.call("get_material"))
		var density := float(sample.call("get_density"))
		var world_revision := int(sample.call("get_world_revision"))
		if density > 0.0:
			air_sample_count += 1
		material_histogram[material] = int(material_histogram.get(material, 0)) + 1
		world_revision_min = mini(world_revision_min, world_revision)
		world_revision_max = maxi(world_revision_max, world_revision)
		sample_map[_grid_point_key(point)] = {
			"point": point,
			"density": density,
			"material": material,
			"world_revision": world_revision,
		}
	return {
		"ok": true,
		"context": context,
		"sample_count": sample_map.size(),
		"air_sample_count": air_sample_count,
		"material_histogram": material_histogram,
		"world_revision_min": world_revision_min,
		"world_revision_max": world_revision_max,
		"samples": sample_map,
	}


func _compare_edit_persistence_snapshots(before: Dictionary, after: Dictionary) -> bool:
	var before_samples: Dictionary = before.get("samples", {})
	var after_samples: Dictionary = after.get("samples", {})
	var density_mismatches := 0
	var material_mismatches := 0
	var missing_after := 0
	var max_abs_density_delta := 0.0
	var examples := []
	for key in before_samples.keys():
		if not after_samples.has(key):
			missing_after += 1
			if examples.size() < 8:
				examples.append("%s missing_after" % str(key))
			continue
		var before_sample: Dictionary = before_samples[key]
		var after_sample: Dictionary = after_samples[key]
		var density_delta := absf(float(before_sample["density"]) - float(after_sample["density"]))
		max_abs_density_delta = maxf(max_abs_density_delta, density_delta)
		var material_changed := int(before_sample["material"]) != int(after_sample["material"])
		var density_changed := density_delta > 0.000001
		if density_changed:
			density_mismatches += 1
		if material_changed:
			material_mismatches += 1
		if (density_changed or material_changed) and examples.size() < 8:
			examples.append("%s density_before=%.9f density_after=%.9f material_before=%d material_after=%d" % [
				str(key),
				float(before_sample["density"]),
				float(after_sample["density"]),
				int(before_sample["material"]),
				int(after_sample["material"]),
			])
	last_edit_persistence_summary = {
		"enabled": true,
		"ok": density_mismatches == 0 and material_mismatches == 0 and missing_after == 0,
		"sample_count": before_samples.size(),
		"before_air_sample_count": int(before.get("air_sample_count", 0)),
		"after_air_sample_count": int(after.get("air_sample_count", 0)),
		"before_world_revision_min": int(before.get("world_revision_min", -1)),
		"before_world_revision_max": int(before.get("world_revision_max", -1)),
		"after_world_revision_min": int(after.get("world_revision_min", -1)),
		"after_world_revision_max": int(after.get("world_revision_max", -1)),
		"density_mismatches": density_mismatches,
		"material_mismatches": material_mismatches,
		"missing_after": missing_after,
		"max_abs_density_delta": max_abs_density_delta,
		"examples": examples,
	}
	if not bool(last_edit_persistence_summary["ok"]):
		_fail("edit persistence oracle mismatch: %s" % JSON.stringify(last_edit_persistence_summary))
		return false
	if int(last_edit_persistence_summary["before_air_sample_count"]) <= 0:
		_fail("edit persistence oracle did not sample carved air: %s" % JSON.stringify(last_edit_persistence_summary))
		return false
	return true


func _edit_persistence_summary() -> Dictionary:
	if last_edit_persistence_summary.is_empty():
		return {
			"enabled": false,
			"ok": true,
		}
	return last_edit_persistence_summary


func _edit_stability_summary() -> Dictionary:
	if last_edit_stability_summary.is_empty():
		return {
			"enabled": false,
			"ok": true,
		}
	return last_edit_stability_summary


func _lod_movement_summary() -> Dictionary:
	if last_lod_movement_summary.is_empty():
		return {
			"enabled": false,
			"ok": true,
		}
	return last_lod_movement_summary


func _edit_during_load_summary() -> Dictionary:
	if last_edit_during_load_summary.is_empty():
		return {
			"enabled": false,
			"ok": true,
		}
	return last_edit_during_load_summary


func _manifold_stress_summary() -> Dictionary:
	if last_manifold_stress_summary.is_empty():
		return {
			"enabled": false,
			"ok": true,
		}
	return last_manifold_stress_summary


func _tunnel_summary() -> Dictionary:
	if last_tunnel_summary.is_empty():
		return {
			"enabled": false,
			"ok": true,
		}
	return last_tunnel_summary


func _ensure_authoritative_sample_connections(terrain_world: Node) -> void:
	var ready_callable := Callable(self, "_on_authoritative_samples_ready")
	if not terrain_world.is_connected("authoritative_samples_ready", ready_callable):
		terrain_world.connect("authoritative_samples_ready", ready_callable)
	var failed_callable := Callable(self, "_on_authoritative_samples_failed")
	if not terrain_world.is_connected("authoritative_samples_failed", failed_callable):
		terrain_world.connect("authoritative_samples_failed", failed_callable)


func _on_authoritative_samples_ready(request_id: int, samples: Array) -> void:
	authoritative_sample_batches[request_id] = samples


func _on_authoritative_samples_failed(request_id: int, error: String) -> void:
	authoritative_sample_failures[request_id] = error


func _grid_point_key(point: Vector3i) -> String:
	return "%d,%d,%d" % [point.x, point.y, point.z]


func _exercise_edit_reload_path() -> bool:
	if player == null or game_world == null:
		_fail("cannot exercise edit reload path without player and game world")
		return false
	var center := _edit_reload_test_center()
	var far_position := center + Vector3(480.0, 20.0, 480.0)
	var near_position := center + Vector3(-10.0, 14.0, -34.0)
	player.global_position = far_position
	player.velocity = Vector3.ZERO
	if not bool(game_world.update_player_viewer(true)):
		_fail("edit reload path far viewer update failed")
		return false
	if not await _wait_for_reload_visual_ready("after moving away from edited area"):
		return false
	player.global_position = near_position
	player.velocity = Vector3.ZERO
	if not bool(game_world.update_player_viewer(true)):
		_fail("edit reload path return viewer update failed")
		return false
	if not await _wait_for_reload_visual_ready("after returning to edited area"):
		return false
	return true


func _wait_for_reload_visual_ready(context: String) -> bool:
	for _frame in range(360):
		var summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
		if int(summary.get("render_resources", 0)) >= expected_resources and \
				int(summary.get("queued_render", 0)) == 0:
			for _settle_frame in range(30):
				await get_tree().process_frame
			return true
		await get_tree().process_frame
	var timeout_summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
	_fail("terrain did not reach visual-ready reload state %s: %s" % [context, str(timeout_summary)])
	return false


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


func _edit_stability_gate_center() -> Vector3:
	if selected_profile == FLAT_PROFILE:
		return Vector3(1040.0, 12.0, 1040.0)
	return _watertightness_edit_center()


func _edit_lod_movement_gate_center() -> Vector3:
	if selected_profile == FLAT_PROFILE:
		return Vector3(1040.0, 12.0, 1040.0)
	return _watertightness_edit_center()


func _edit_during_load_oracle_center() -> Vector3:
	if selected_profile == FLAT_PROFILE:
		return Vector3(1040.0, 12.0, 1040.0)
	return _watertightness_edit_center()


func _manifold_stress_center() -> Vector3:
	if selected_profile == FLAT_PROFILE:
		return Vector3(1040.0, 12.0, 1040.0)
	return _watertightness_edit_center()


func _tunnel_gate_center() -> Vector3:
	if selected_profile == FLAT_PROFILE:
		return Vector3(1040.0, 12.0, 1040.0)
	return _watertightness_edit_center()


func _tunnel_gate_direction() -> Vector3:
	var direction := Vector3(1.0, -0.08, 0.35)
	if selected_profile == FLAT_PROFILE:
		direction = Vector3(1.0, 0.0, 0.28)
	return direction.normalized()


func _tunnel_descending_start() -> Vector3:
	if selected_profile == FLAT_PROFILE:
		return _tunnel_gate_center() + Vector3(-18.0, 4.0, -14.0)
	return _tunnel_gate_center() + Vector3(-28.0, 4.0, -18.0)


func _tunnel_descending_direction() -> Vector3:
	var direction := Vector3(0.72, -0.42, 0.38)
	if selected_profile == FLAT_PROFILE:
		direction = Vector3(0.78, -0.24, 0.36)
	return direction.normalized()


func _tunnel_descending_radius() -> float:
	return 1.85 if selected_profile == FLAT_PROFILE else 2.15


func _tunnel_descending_step_count() -> int:
	return 56 if selected_profile == FLAT_PROFILE else 68


func _tunnel_descending_spacing() -> float:
	return 0.95 if selected_profile == FLAT_PROFILE else 1.05


func _tunnel_descending_probe_radius() -> float:
	return 16.0 if selected_profile == FLAT_PROFILE else 26.0


func _edit_lod_movement_probe_radius() -> float:
	return 14.0 if selected_profile == FLAT_PROFILE else 56.0


func _manifold_stress_probe_radius() -> float:
	return 18.0 if selected_profile == FLAT_PROFILE else 68.0


func _tunnel_probe_radius() -> float:
	return 24.0 if selected_profile == FLAT_PROFILE else 72.0


func _edit_reload_test_center() -> Vector3:
	if human_visual_capture_mode == "edit_lod_movement_gate":
		return _edit_lod_movement_gate_center()
	if human_visual_capture_mode == "edit_during_load_oracle":
		return _edit_during_load_oracle_center()
	if human_visual_capture_mode == "edit_manifold_stress_gate":
		return _manifold_stress_center()
	if human_visual_capture_mode == "edit_tunnel_gate":
		return _tunnel_gate_center()
	if human_visual_capture_mode == "edit_stability_gate":
		return _edit_stability_gate_center()
	return _watertightness_edit_center()


func _watertightness_probe_center() -> Vector3:
	if human_visual_capture_mode == "edit_lod_movement_gate":
		return _edit_lod_movement_gate_center()
	if human_visual_capture_mode == "edit_during_load_oracle":
		return _edit_during_load_oracle_center()
	if human_visual_capture_mode == "edit_manifold_stress_gate":
		return _manifold_stress_center()
	if human_visual_capture_mode == "edit_tunnel_gate":
		return _tunnel_gate_center()
	if human_visual_capture_mode == "edit_stability_gate":
		return _edit_stability_gate_center()
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
	if human_visual_capture_mode == "edit_lod_movement_gate":
		return _edit_lod_movement_probe_radius()
	if human_visual_capture_mode == "edit_during_load_oracle":
		return 14.0 if selected_profile == FLAT_PROFILE else 56.0
	if human_visual_capture_mode == "edit_manifold_stress_gate":
		return _manifold_stress_probe_radius()
	if human_visual_capture_mode == "edit_tunnel_gate":
		return _tunnel_probe_radius()
	if human_visual_capture_mode == "edit_stability_gate":
		return 11.0 if selected_profile == FLAT_PROFILE else 48.0
	if human_visual_capture_mode == "watertight_many_small_near" or \
		human_visual_capture_mode == "watertight_rapid_small_near" or \
		human_visual_capture_mode == "watertight_rapid_small_reload_near" or \
		human_visual_capture_mode == "edit_persistence_reload_oracle":
		return 48.0
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
		"watertight_many_small_near", "watertight_rapid_small_near", "watertight_rapid_small_reload_near", "edit_persistence_reload_oracle", "edit_stability_gate", "edit_lod_movement_gate", "edit_during_load_oracle", "edit_manifold_stress_gate", "edit_tunnel_gate":
			var target_center := _watertightness_edit_center()
			if human_visual_capture_mode == "edit_stability_gate":
				target_center = _edit_stability_gate_center()
			elif human_visual_capture_mode == "edit_lod_movement_gate":
				target_center = _edit_lod_movement_gate_center()
			elif human_visual_capture_mode == "edit_during_load_oracle":
				target_center = _edit_during_load_oracle_center()
			elif human_visual_capture_mode == "edit_manifold_stress_gate":
				target_center = _manifold_stress_center()
			elif human_visual_capture_mode == "edit_tunnel_gate":
				target_center = _tunnel_gate_center()
			if human_visual_capture_mode == "edit_tunnel_gate":
				var tunnel_path := _tunnel_gate_path()
				var tunnel_step: Dictionary = tunnel_path[1] if tunnel_path.size() > 1 else {}
				capture_position = tunnel_step.get("position", target_center + Vector3(-10.0, 14.0, -34.0))
				capture_target = tunnel_step.get("target", target_center)
			else:
				capture_target = target_center + Vector3(0.0, -4.0, 0.0)
				capture_position = capture_target + Vector3(-10.0, 14.0, -34.0)
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

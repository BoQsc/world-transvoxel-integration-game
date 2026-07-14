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
const PlayerScript := preload("res://scripts/wt_production_player.gd")
const EditOperation := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd")
const EditBatch := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd")
const WatertightnessProbe := preload("res://addons/world_transvoxel_terrain/debug/wt_terrain_watertightness_probe.gd")
const HUMAN_CLEAN_TERRAIN_ALBEDO := "res://assets/terrain_textures/coast_sand_01_diff_1k.jpg"
const HUMAN_CLEAN_TERRAIN_COLOR := Color(0.72, 0.65, 0.50, 1.0)
const HUMAN_ARTIFACT_CAPTURE_ROOT := "res://.godot/world_transvoxel_captures/human_artifact_marks"

var playtest_profile_id: StringName = DEFAULT_HUMAN_PROFILE
var game_world: Node
var player: CharacterBody3D
var telemetry_label: Label
var launch_command_label: Label
var test_context_label: Label
var controls_hint_label: Label
var profile_selector: OptionButton
var crosshair: Label
var loading_overlay: CanvasLayer
var loading_label: Label
var material_applicator: Node
var selected_profile: StringName = DEFAULT_HUMAN_PROFILE
var human_launch_command_line := ""
var human_test_context_line := ""
var human_controls_hint_line := ""
var autonomous := false
var human_visual_capture_path := ""
var human_visual_capture_mode := "ground"
var human_visual_capture_wait_frames := 90
var human_playtest_preset := ""
var human_artifact_marker_smoke := false
var human_preserve_storage := false
var human_artifact_replay_marker_path := ""
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
var human_artifact_marker_busy := false
var human_artifact_mark_index := 0
var interaction_inspection_applied := false
var interaction_inspection_operation_count := 0
var last_watertightness_summary := {}
var last_edit_persistence_summary := {}
var last_edit_stability_summary := {}
var last_lod_movement_summary := {}
var last_multisite_lod_summary := {}
var last_edit_during_load_summary := {}
var last_manifold_stress_summary := {}
var last_tunnel_summary := {}
var last_streaming_fly_summary := {}
var edit_persistence_operations: Array = []
var authoritative_sample_batches := {}
var authoritative_sample_failures := {}


func _ready() -> void:
	var args := Array(OS.get_cmdline_user_args())
	autonomous = args.has("--p2-autonomous")
	human_visual_capture_path = _arg_value(args, "--human-visual-capture", "")
	human_visual_capture_mode = _arg_value(args, "--human-visual-capture-mode", "ground")
	human_visual_capture_wait_frames = int(_arg_value(args, "--human-visual-capture-wait-frames", "90"))
	human_playtest_preset = _arg_value(args, "--human-playtest-preset", "")
	human_artifact_marker_smoke = args.has("--human-artifact-marker-smoke")
	human_preserve_storage = args.has("--human-preserve-storage")
	human_artifact_replay_marker_path = _arg_value(args, "--human-artifact-replay-marker", "")
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
	human_launch_command_line = _human_launch_command_text(args)
	human_test_context_line = _human_test_context_text()
	human_controls_hint_line = "controls: LMB dig | RMB place | WASD move | Space jump/up | Tilde+F fly | Tilde+M mark | Tilde+L lights"
	if autonomous:
		_clear_autonomous_profile_outputs(selected_profile)
	else:
		if human_visual_capture_path.is_empty():
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		if not human_preserve_storage and human_artifact_replay_marker_path.is_empty():
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
	game_world.player_viewer_update_distance = float(settings.get("player_viewer_update_distance", 8.0))
	var predictive_viewer_enabled := bool(settings.get("player_predictive_viewer_enabled", false))
	if autonomous and human_visual_capture_path.is_empty():
		predictive_viewer_enabled = false
	game_world.player_predictive_viewer_enabled = predictive_viewer_enabled
	game_world.player_predictive_viewer_distance = float(settings.get("player_predictive_viewer_distance", 0.0))
	game_world.player_focus_viewer_enabled = predictive_viewer_enabled and bool(settings.get("player_focus_viewer_enabled", false))
	game_world.player_focus_viewer_distance = float(settings.get("player_focus_viewer_distance", 0.0))
	game_world.startup_requires_cold_idle = bool(settings.get("startup_requires_cold_idle", true))
	game_world.startup_minimum_render_resources = int(settings.get("startup_minimum_render_resources", expected_resources))
	game_world.startup_minimum_collision_resources = int(settings.get("startup_minimum_collision_resources", expected_resources))
	game_world.runtime_active_chunk_capacity = int(settings.get("runtime_active_chunk_capacity", 0))
	game_world.runtime_viewer_capacity = int(settings.get("runtime_viewer_capacity", 0))
	game_world.runtime_demand_capacity_per_viewer = int(settings.get("runtime_demand_capacity_per_viewer", 0))
	game_world.runtime_render_entry_capacity = int(settings.get("runtime_render_entry_capacity", 0))
	game_world.runtime_collision_entry_capacity = int(settings.get("runtime_collision_entry_capacity", 0))
	game_world.runtime_lod_refinement_radius_chunks = int(settings.get("runtime_lod_refinement_radius_chunks", 0))
	game_world.runtime_render_apply_budget = int(settings.get("runtime_render_apply_budget", 0))
	game_world.runtime_collision_apply_budget = int(settings.get("runtime_collision_apply_budget", 0))
	game_world.runtime_render_transition_frames = int(settings.get("runtime_render_transition_frames", 0))
	game_world.runtime_shader_fade_parameter_enabled = bool(settings.get("runtime_shader_fade_parameter_enabled", false))
	game_world.runtime_global_coarse_lod_coverage = bool(settings.get("runtime_global_coarse_lod_coverage", false))
	game_world.runtime_streaming_burst_render_apply_budget = int(settings.get("runtime_streaming_burst_render_apply_budget", 0))
	game_world.runtime_streaming_burst_collision_apply_budget = int(settings.get("runtime_streaming_burst_collision_apply_budget", 0))
	game_world.runtime_streaming_burst_frames = int(settings.get("runtime_streaming_burst_frames", 0))
	game_world.runtime_edit_burst_render_apply_budget = int(settings.get("runtime_edit_burst_render_apply_budget", 0))
	game_world.runtime_edit_burst_collision_apply_budget = int(settings.get("runtime_edit_burst_collision_apply_budget", 0))
	game_world.runtime_edit_burst_frames = int(settings.get("runtime_edit_burst_frames", 0))
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
	if not autonomous:
		if not await _wait_for_human_startup_visual_ready():
			return
		_set_human_loading_visible(false)
	_update_telemetry()
	if not human_artifact_replay_marker_path.is_empty():
		call_deferred("_run_human_artifact_replay_marker")
		return
	if human_artifact_marker_smoke:
		call_deferred("_run_human_artifact_marker_smoke")
		return
	if not autonomous:
		if not human_playtest_preset.is_empty():
			if not await _apply_human_playtest_preset():
				return
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
	if not _verify_standard_edit_metadata(&"carve"):
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
	print("%s profile=%s addon=%s api_version=%d launch=project_godot player=1 camera=1 crosshair=1 profile_selector=1 telemetry=1 input_edit=1 traversal=1 edit_committed=1 repeated_edits=1 interaction_raycast=1 storage_journal=1 streaming_settled=1 spawn_floor_hit=%d spawn_above_floor=%d maximum_lod=%d render_resources=%d collision_resources=%d active_records=%d edit_commits=%d edit_failures=%d material=1 materialized=%d production_texture_active=%d native_render_material_override=%d presentation=terrain_1_0 validation_internals=0" % [
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


func _wait_for_human_startup_visual_ready() -> bool:
	var frame_limit := 900
	var last_summary := {}
	for _frame in range(frame_limit):
		var summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
		last_summary = summary
		if _is_lod_movement_visual_ready_summary(summary):
			return true
		await get_tree().process_frame
	_fail("human-visible startup terrain did not reach strict ready state: %s" % str(last_summary))
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
	crosshair.visible = autonomous
	canvas.add_child(crosshair)
	if not autonomous:
		_build_human_test_context_label(canvas)
		_build_human_controls_hint_label(canvas)
		_build_human_launch_command_label(canvas)
	_build_loading_overlay()
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


func _build_human_launch_command_label(canvas: CanvasLayer) -> void:
	launch_command_label = Label.new()
	launch_command_label.name = "LaunchCommandLabel"
	launch_command_label.text = human_launch_command_line
	launch_command_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	launch_command_label.offset_left = 8.0
	launch_command_label.offset_top = -30.0
	launch_command_label.offset_right = 1880.0
	launch_command_label.offset_bottom = -8.0
	launch_command_label.clip_text = true
	launch_command_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	launch_command_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_style_human_static_label(launch_command_label)
	canvas.add_child(launch_command_label)


func _build_human_test_context_label(canvas: CanvasLayer) -> void:
	test_context_label = Label.new()
	test_context_label.name = "TestContextLabel"
	test_context_label.text = human_test_context_line
	test_context_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	test_context_label.offset_left = 8.0
	test_context_label.offset_top = 8.0
	test_context_label.offset_right = 900.0
	test_context_label.offset_bottom = 30.0
	test_context_label.clip_text = true
	test_context_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	test_context_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_style_human_static_label(test_context_label)
	canvas.add_child(test_context_label)


func _build_human_controls_hint_label(canvas: CanvasLayer) -> void:
	controls_hint_label = Label.new()
	controls_hint_label.name = "ControlsHintLabel"
	controls_hint_label.text = human_controls_hint_line
	controls_hint_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	controls_hint_label.offset_left = -980.0
	controls_hint_label.offset_top = 8.0
	controls_hint_label.offset_right = -8.0
	controls_hint_label.offset_bottom = 30.0
	controls_hint_label.clip_text = true
	controls_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	controls_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_style_human_static_label(controls_hint_label)
	canvas.add_child(controls_hint_label)


func _style_human_static_label(label: Label) -> void:
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.72))
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)


func _build_loading_overlay() -> void:
	if autonomous:
		return
	loading_overlay = CanvasLayer.new()
	loading_overlay.name = "StartupLoadingOverlay"
	loading_overlay.layer = 100
	add_child(loading_overlay)
	var cover := ColorRect.new()
	cover.name = "StartupLoadingCover"
	cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	cover.color = Color(0.03, 0.035, 0.04, 1.0)
	loading_overlay.add_child(cover)
	loading_label = Label.new()
	loading_label.name = "StartupLoadingLabel"
	loading_label.text = "Loading terrain..."
	loading_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	loading_overlay.add_child(loading_label)


func _set_human_loading_visible(visible: bool) -> void:
	if autonomous:
		return
	if loading_overlay != null:
		loading_overlay.visible = visible
	if crosshair != null:
		crosshair.visible = not visible


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
			"viewers": [Vector3(1024, 18, 1024)],
			"radius": 10,
			"maximum_lod": 3,
			"expected_resources": 32,
			"expected_max_resources": 4096,
			"player_viewer_update_distance": 2.0,
			"player_predictive_viewer_enabled": false,
			"player_predictive_viewer_distance": 0.0,
			"player_focus_viewer_enabled": false,
			"player_focus_viewer_distance": 0.0,
			"startup_requires_cold_idle": false,
			"startup_minimum_render_resources": 32,
			"startup_minimum_collision_resources": 32,
			"runtime_active_chunk_capacity": 4096,
			"runtime_viewer_capacity": 2,
			"runtime_demand_capacity_per_viewer": 10000,
			"runtime_render_entry_capacity": 4096,
			"runtime_collision_entry_capacity": 4096,
			"runtime_lod_refinement_radius_chunks": 1,
			"runtime_render_apply_budget": 8,
			"runtime_collision_apply_budget": 8,
			"runtime_render_transition_frames": 0,
			"runtime_shader_fade_parameter_enabled": false,
			"runtime_global_coarse_lod_coverage": true,
			"runtime_streaming_burst_render_apply_budget": 128,
			"runtime_streaming_burst_collision_apply_budget": 128,
			"runtime_streaming_burst_frames": 30,
			"runtime_edit_burst_render_apply_budget": 128,
			"runtime_edit_burst_collision_apply_budget": 128,
			"runtime_edit_burst_frames": 240,
			"runtime_collision_activation_distance": 192.0,
			"runtime_collision_deactivation_distance": 256.0,
			"edit_point": Vector3(1032, 8, 1032),
		}
	return {
		"start": Vector3(1184, 142, 1008),
		"viewers": [Vector3(1024, 142, 1024)],
		"radius": 10,
		"maximum_lod": 3,
			"expected_resources": 32,
			"expected_max_resources": 4096,
			"player_viewer_update_distance": 2.0,
			"player_predictive_viewer_enabled": false,
			"player_predictive_viewer_distance": 0.0,
			"player_focus_viewer_enabled": false,
			"player_focus_viewer_distance": 0.0,
		"startup_requires_cold_idle": false,
		"startup_minimum_render_resources": 32,
		"startup_minimum_collision_resources": 32,
		"runtime_active_chunk_capacity": 4096,
			"runtime_viewer_capacity": 2,
		"runtime_demand_capacity_per_viewer": 10000,
		"runtime_render_entry_capacity": 4096,
		"runtime_collision_entry_capacity": 4096,
		"runtime_lod_refinement_radius_chunks": 1,
		"runtime_render_apply_budget": 8,
		"runtime_collision_apply_budget": 8,
		"runtime_render_transition_frames": 0,
		"runtime_shader_fade_parameter_enabled": false,
		"runtime_global_coarse_lod_coverage": true,
		"runtime_streaming_burst_render_apply_budget": 128,
		"runtime_streaming_burst_collision_apply_budget": 128,
		"runtime_streaming_burst_frames": 30,
		"runtime_edit_burst_render_apply_budget": 128,
		"runtime_edit_burst_collision_apply_budget": 128,
		"runtime_edit_burst_frames": 240,
		"runtime_collision_activation_distance": 192.0,
		"runtime_collision_deactivation_distance": 256.0,
		"edit_point": Vector3(1184, 119, 1008),
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


func _verify_standard_edit_metadata(expected_mode: StringName) -> bool:
	if game_world == null or not game_world.has_method("get_last_edit_summary"):
		_fail("gameworld does not expose last edit summary")
		return false
	var edit_summary: Dictionary = game_world.call("get_last_edit_summary")
	if not bool(edit_summary.get("accepted", false)):
		_fail("standard edit metadata check saw rejected edit: %s" % JSON.stringify(edit_summary))
		return false
	var terrain_summary_value = edit_summary.get("terrain_summary", {})
	if not (terrain_summary_value is Dictionary):
		_fail("standard edit metadata missing terrain summary: %s" % JSON.stringify(edit_summary))
		return false
	var terrain_summary: Dictionary = terrain_summary_value
	var operations_value = terrain_summary.get("operation_summaries", [])
	if not (operations_value is Array):
		_fail("standard edit metadata operation_summaries is not an array: %s" % JSON.stringify(terrain_summary))
		return false
	var operations: Array = operations_value
	if operations.is_empty():
		_fail("standard edit metadata operation_summaries is empty: %s" % JSON.stringify(terrain_summary))
		return false
	var operation_value = operations[0]
	if not (operation_value is Dictionary):
		_fail("standard edit metadata first operation is not a dictionary: %s" % JSON.stringify(terrain_summary))
		return false
	var operation: Dictionary = operation_value
	if str(operation.get("operation", "")) != str(expected_mode):
		_fail("standard edit metadata operation mismatch: %s" % JSON.stringify(operation))
		return false
	if str(operation.get("brush_shape", "")) != "sphere":
		_fail("standard edit metadata brush is not sphere: %s" % JSON.stringify(operation))
		return false
	if float(operation.get("radius", 0.0)) <= 0.0:
		_fail("standard edit metadata radius is invalid: %s" % JSON.stringify(operation))
		return false
	if not operation.has("affected_aabb"):
		_fail("standard edit metadata missing affected_aabb: %s" % JSON.stringify(operation))
		return false
	return true


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
		&"mark_artifact":
			call_deferred("_run_human_artifact_mark_from_input")
			return true
	return false


func _run_human_artifact_mark_from_input() -> void:
	await _capture_human_artifact_mark("human")


func _run_human_artifact_marker_smoke() -> void:
	var ok := await _capture_human_artifact_mark("smoke")
	if ok:
		print("WT_HUMAN_ARTIFACT_MARK_SMOKE_PASS")
		get_tree().quit(0)
	else:
		push_error("WT_HUMAN_ARTIFACT_MARK_SMOKE_FAIL")
		get_tree().quit(1)


func _run_human_artifact_replay_marker() -> void:
	var marker := _load_human_artifact_marker_json(human_artifact_replay_marker_path)
	if marker.is_empty():
		push_error("WT_HUMAN_ARTIFACT_REPLAY_MARKER_LOAD_FAIL path=%s" % human_artifact_replay_marker_path)
		get_tree().quit(1)
		return
	await _apply_human_artifact_marker_pose(marker)
	for _index in range(180):
		await get_tree().physics_frame
	_update_telemetry()
	var ok := await _capture_human_artifact_mark("replay")
	if ok:
		print("WT_HUMAN_ARTIFACT_REPLAY_MARKER_PASS")
		get_tree().quit(0)
	else:
		push_error("WT_HUMAN_ARTIFACT_REPLAY_MARKER_FAIL")
		get_tree().quit(1)


func _load_human_artifact_marker_json(path: String) -> Dictionary:
	var absolute_path := path
	if not absolute_path.is_absolute_path():
		absolute_path = ProjectSettings.globalize_path(path)
	var file := FileAccess.open(absolute_path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}


func _apply_human_artifact_marker_pose(marker: Dictionary) -> void:
	if player == null:
		return
	var player_summary: Dictionary = marker.get("player", {})
	var camera_summary: Dictionary = marker.get("camera", {})
	if player_summary.has("position"):
		player.global_position = _vector3_from_summary(player_summary["position"])
	elif camera_summary.has("position"):
		player.global_position = _vector3_from_summary(camera_summary["position"]) - Vector3(0.0, 1.6, 0.0)
	var camera := player.get_node_or_null("FirstPersonCamera") as Camera3D
	if camera != null and camera_summary.has("rotation"):
		var camera_rotation := _vector3_from_summary(camera_summary["rotation"])
		player.global_rotation = Vector3(0.0, camera_rotation.y, 0.0)
		if player.has_method("set_fly_mode_enabled"):
			player.call("set_fly_mode_enabled", true)
		player.set("pitch", camera_rotation.x)
		camera.rotation = Vector3(camera_rotation.x, 0.0, 0.0)
		camera.current = true
		camera.make_current()
	if game_world != null and game_world.has_method("update_player_viewer"):
		game_world.call("update_player_viewer", false)
	await get_tree().process_frame


func _capture_human_artifact_mark(source: String) -> bool:
	if human_artifact_marker_busy:
		print("WT_HUMAN_ARTIFACT_MARK_BUSY")
		return false
	human_artifact_marker_busy = true
	human_artifact_mark_index += 1
	var root := _human_artifact_capture_root()
	var marker_id := _human_artifact_marker_id(source)
	var screenshot_path := root.path_join("%s.png" % marker_id)
	var json_path := root.path_join("%s.json" % marker_id)
	var image_error := ERR_UNAVAILABLE
	var sky_summary := {"available": false, "reason": "viewport_image_unavailable"}
	if DisplayServer.get_name() != "headless":
		var viewport_texture := get_viewport().get_texture()
		if viewport_texture != null:
			var image := viewport_texture.get_image()
			if image != null and image.get_width() > 0 and image.get_height() > 0:
				image_error = image.save_png(screenshot_path)
				sky_summary = _screen_sky_pixel_summary(image)
	var terrain_world: Node = game_world.get_terrain_world() if game_world != null else null
	var backend: Node = null
	if terrain_world != null and terrain_world.has_method("get_backend_terrain"):
		backend = terrain_world.call("get_backend_terrain")
	var target_summary := _human_artifact_interaction_target()
	var sky_pixel_rays := _human_artifact_sky_pixel_rays(sky_summary)
	var render_ray_hits := _human_artifact_render_ray_hits(backend, sky_pixel_rays)
	var probe_specs := _human_artifact_probe_specs(target_summary)
	probe_specs.append_array(_human_artifact_sky_pixel_probe_specs(sky_pixel_rays))
	probe_specs.append_array(_human_artifact_render_hit_probe_specs(render_ray_hits))
	var probes := _collect_human_artifact_probes(backend, probe_specs)
	var precise_probes := _collect_human_artifact_precise_probes(backend, probe_specs)
	var problematic_probes := []
	for probe in probes:
		if _human_artifact_probe_is_problematic(probe):
			problematic_probes.append(probe)
	var problematic_precise_probes := []
	for probe in precise_probes:
		if _human_artifact_precise_probe_is_problematic(probe):
			problematic_precise_probes.append(probe)
	var runtime_summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
	var summary := {
		"marker_id": marker_id,
		"source": source,
		"profile": str(selected_profile),
		"screenshot_path": screenshot_path,
		"json_path": json_path,
		"screenshot_error": image_error,
		"camera": _human_artifact_camera_summary(),
		"player": _human_artifact_player_summary(),
		"interaction_target": target_summary,
		"last_interaction": _human_artifact_last_interaction(),
		"runtime": runtime_summary,
		"presentation": _presentation_summary(),
		"screen_sky_pixels": sky_summary,
		"sky_pixel_rays": sky_pixel_rays,
		"render_ray_hits": render_ray_hits,
		"chunk_neighborhood": _human_artifact_chunk_neighborhood(terrain_world, render_ray_hits),
		"render_seam_diagnostics": _human_artifact_render_seam_diagnostics(backend, render_ray_hits),
		"probe_count": probes.size(),
		"problematic_probe_count": problematic_probes.size(),
		"problematic_probes": problematic_probes,
		"probes": probes,
		"precise_probe_count": precise_probes.size(),
		"problematic_precise_probe_count": problematic_precise_probes.size(),
		"problematic_precise_probes": problematic_precise_probes,
		"precise_probes": precise_probes,
	}
	var file := FileAccess.open(json_path, FileAccess.WRITE)
	var file_ok := file != null
	if file_ok:
		file.store_string(JSON.stringify(summary))
		file.close()
	print("WT_HUMAN_ARTIFACT_MARK_SUMMARY ", JSON.stringify({
		"marker_id": marker_id,
		"profile": str(selected_profile),
		"screenshot_path": screenshot_path,
		"json_path": json_path,
		"screenshot_error": image_error,
		"json_written": file_ok,
		"crosshair_sky_pixels": int(sky_summary.get("crosshair_sky_pixels", 0)),
		"center_sky_pixels": int(sky_summary.get("center_sky_pixels", 0)),
		"whole_sky_pixels": int(sky_summary.get("whole_sky_pixels", 0)),
		"isolated_crosshair_sky_pixels": int(sky_summary.get("isolated_crosshair_sky_pixels", 0)),
		"isolated_center_sky_pixels": int(sky_summary.get("isolated_center_sky_pixels", 0)),
		"isolated_sky_pixels": int(sky_summary.get("isolated_sky_pixels", 0)),
		"sky_pixel_rays": sky_pixel_rays.size(),
		"render_ray_hits": render_ray_hits.size(),
		"probe_count": probes.size(),
		"problematic_probe_count": problematic_probes.size(),
		"precise_probe_count": precise_probes.size(),
		"problematic_precise_probe_count": problematic_precise_probes.size(),
	}))
	if not file_ok:
		push_error("failed to write human artifact mark json: %s" % json_path)
	if image_error != OK and not (source == "smoke" and image_error == ERR_UNAVAILABLE):
		push_error("failed to write human artifact mark screenshot: %s error=%d" % [screenshot_path, image_error])
	human_artifact_marker_busy = false
	return file_ok and (image_error == OK or (source == "smoke" and image_error == ERR_UNAVAILABLE))


func _human_artifact_capture_root() -> String:
	var root := ProjectSettings.globalize_path(HUMAN_ARTIFACT_CAPTURE_ROOT)
	DirAccess.make_dir_recursive_absolute(root)
	return root


func _human_artifact_marker_id(source: String) -> String:
	var stamp := Time.get_datetime_string_from_system(false)
	stamp = stamp.replace("-", "")
	stamp = stamp.replace(":", "")
	stamp = stamp.replace(" ", "_")
	return "%s_%03d_%s" % [stamp, human_artifact_mark_index, source]


func _human_artifact_camera_summary() -> Dictionary:
	var camera := player.get_node_or_null("FirstPersonCamera") as Camera3D if player != null else null
	if camera == null:
		return {"available": false}
	return {
		"available": true,
		"position": _vector3_summary(camera.global_position),
		"forward": _vector3_summary(-camera.global_transform.basis.z),
		"rotation": _vector3_summary(camera.global_rotation),
		"fov": camera.fov,
	}


func _human_artifact_player_summary() -> Dictionary:
	if player == null:
		return {"available": false}
	return {
		"available": true,
		"position": _vector3_summary(player.global_position),
		"rotation": _vector3_summary(player.global_rotation),
		"fly_mode": bool(player.call("is_fly_mode_enabled")) if player.has_method("is_fly_mode_enabled") else false,
	}


func _human_artifact_interaction_target() -> Dictionary:
	if player == null or not player.has_method("get_interaction_target_summary"):
		return {"available": false}
	var target: Dictionary = player.call("get_interaction_target_summary")
	return _human_artifact_normalize_interaction(target)


func _human_artifact_last_interaction() -> Dictionary:
	if player == null or not player.has_method("get_last_interaction_summary"):
		return {"available": false}
	var interaction: Dictionary = player.call("get_last_interaction_summary")
	return _human_artifact_normalize_interaction(interaction)


func _human_artifact_normalize_interaction(input: Dictionary) -> Dictionary:
	var result := input.duplicate(true)
	if result.has("position") and result["position"] is Vector3:
		result["position"] = _vector3_summary(result["position"])
	return result


func _human_artifact_probe_specs(target_summary: Dictionary) -> Array:
	var specs := []
	if bool(target_summary.get("ray_hit", false)) and target_summary.has("position"):
		specs.append({
			"label": "ray_hit",
			"center": _vector3_from_summary(target_summary["position"]),
		})
	var last_interaction := _human_artifact_last_interaction()
	if last_interaction.has("position"):
		specs.append({
			"label": "last_interaction",
			"center": _vector3_from_summary(last_interaction["position"]),
		})
	var camera := player.get_node_or_null("FirstPersonCamera") as Camera3D if player != null else null
	if camera != null:
		var camera_position := camera.global_position
		var camera_forward := -camera.global_transform.basis.z
		for distance in [4.0, 8.0, 16.0, 32.0, 64.0]:
			specs.append({
				"label": "camera_forward_%03d" % int(distance),
				"center": camera_position + camera_forward * distance,
			})
	if player != null:
		specs.append({
			"label": "player_position",
			"center": player.global_position,
		})
	return specs


func _human_artifact_sky_pixel_rays(sky_summary: Dictionary) -> Array:
	var camera := player.get_node_or_null("FirstPersonCamera") as Camera3D if player != null else null
	if camera == null or get_world_3d() == null:
		return []
	var pixel_summaries := _human_artifact_sky_pixel_examples(sky_summary)
	var reports := []
	var direct_space_state := get_world_3d().direct_space_state
	for index in range(pixel_summaries.size()):
		var pixel: Dictionary = pixel_summaries[index]
		var screen_point := Vector2(float(pixel.get("x", 0.0)), float(pixel.get("y", 0.0)))
		var origin := camera.project_ray_origin(screen_point)
		var direction := camera.project_ray_normal(screen_point).normalized()
		var end := origin + direction * 512.0
		var query := PhysicsRayQueryParameters3D.create(origin, end)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		if player is CollisionObject3D:
			query.exclude = [(player as CollisionObject3D).get_rid()]
		var hit := direct_space_state.intersect_ray(query)
		var report := {
			"index": index,
			"pixel": pixel,
			"screen_point": {"x": screen_point.x, "y": screen_point.y},
			"origin": _vector3_summary(origin),
			"direction": _vector3_summary(direction),
			"max_distance": 512.0,
			"physics_hit": not hit.is_empty(),
		}
		if not hit.is_empty():
			var hit_position: Vector3 = hit.get("position", origin)
			report["hit_position"] = _vector3_summary(hit_position)
			report["hit_distance"] = origin.distance_to(hit_position)
			report["hit_normal"] = _vector3_summary(hit.get("normal", Vector3.ZERO))
			var collider = hit.get("collider", null)
			report["hit_collider"] = str(collider.name) if collider is Node else str(collider)
		reports.append(report)
	return reports


func _human_artifact_sky_pixel_examples(sky_summary: Dictionary) -> Array:
	var pixels := []
	var seen := {}
	var group_keys := [
		"isolated_crosshair_examples",
		"isolated_lower_center_examples",
		"isolated_examples",
		"crosshair_examples",
		"lower_center_examples",
	]
	if int(sky_summary.get("whole_sky_pixels", 0)) <= 256:
		group_keys.append("examples")
	for group_key in group_keys:
		var group: Array = sky_summary.get(group_key, [])
		for value in group:
			if not value is Dictionary:
				continue
			var pixel: Dictionary = value
			var key := "%d,%d" % [int(pixel.get("x", 0)), int(pixel.get("y", 0))]
			if seen.has(key):
				continue
			seen[key] = true
			pixels.append(pixel)
			if pixels.size() >= 12:
				return pixels
	return pixels


func _human_artifact_sky_pixel_probe_specs(sky_pixel_rays: Array) -> Array:
	var specs := []
	var ray_limit := mini(4, sky_pixel_rays.size())
	for index in range(ray_limit):
		var ray: Dictionary = sky_pixel_rays[index]
		var label_prefix := "sky_pixel_%02d" % index
		if bool(ray.get("physics_hit", false)) and ray.has("hit_position"):
			specs.append({
				"label": "%s_hit" % label_prefix,
				"center": _vector3_from_summary(ray["hit_position"]),
			})
		var origin := _vector3_from_summary(ray.get("origin", {}))
		var direction := _vector3_from_summary(ray.get("direction", {})).normalized()
		if direction.length_squared() == 0.0:
			continue
		for distance in [4.0, 8.0, 16.0, 32.0, 64.0]:
			specs.append({
				"label": "%s_d%03d" % [label_prefix, int(distance)],
				"center": origin + direction * distance,
			})
	return specs


func _human_artifact_render_hit_probe_specs(render_ray_hits: Array) -> Array:
	var specs := []
	var ray_limit := mini(12, render_ray_hits.size())
	var seen := {}
	for index in range(ray_limit):
		var hit: Dictionary = render_ray_hits[index]
		for kind in ["any", "front_like", "back_like"]:
			var hit_key := "render_%s_hit" % kind
			var position_key := "render_%s_position" % kind
			if not bool(hit.get(hit_key, false)) or not hit.has(position_key):
				continue
			var center := _vector3_from_summary(hit[position_key])
			var dedupe := "%s:%0.5f,%0.5f,%0.5f" % [kind, center.x, center.y, center.z]
			if seen.has(dedupe):
				continue
			seen[dedupe] = true
			specs.append({
				"label": "render_hit_%02d_%s" % [index, kind],
				"center": center,
			})
	return specs


func _human_artifact_render_ray_hits(backend: Node, sky_pixel_rays: Array) -> Array:
	if backend == null:
		return []
	var reports := []
	for ray in sky_pixel_rays:
		var origin := _vector3_from_summary(ray.get("origin", {}))
		var direction := _vector3_from_summary(ray.get("direction", {})).normalized()
		if direction.length_squared() == 0.0:
			continue
		var max_distance := float(ray.get("max_distance", 512.0))
		if bool(ray.get("physics_hit", false)) and ray.has("hit_distance"):
			max_distance = minf(max_distance, float(ray.get("hit_distance", max_distance)) + 1.0)
		var report := {
			"index": int(ray.get("index", reports.size())),
			"pixel": ray.get("pixel", {}),
			"origin": _vector3_summary(origin),
			"direction": _vector3_summary(direction),
			"max_distance": max_distance,
			"physics_hit": bool(ray.get("physics_hit", false)),
			"physics_hit_distance": float(ray.get("hit_distance", -1.0)),
			"physics_hit_collider": str(ray.get("hit_collider", "")),
			"tested_mesh_instances": 0,
			"tested_surfaces": 0,
			"tested_triangles": 0,
			"render_any_hit": false,
			"render_front_like_hit": false,
			"render_back_like_hit": false,
		}
		_collect_render_ray_hit_for_node(backend, origin, direction, max_distance, report)
		reports.append(report)
	return reports


func _collect_render_ray_hit_for_node(
	node: Node,
	origin: Vector3,
	direction: Vector3,
	max_distance: float,
	report: Dictionary
) -> void:
	if node is MeshInstance3D:
		_accumulate_render_ray_hit(
			node as MeshInstance3D,
			origin,
			direction,
			max_distance,
			report
		)
	for child in node.get_children():
		if child is Node:
			_collect_render_ray_hit_for_node(child, origin, direction, max_distance, report)


func _accumulate_render_ray_hit(
	instance: MeshInstance3D,
	origin: Vector3,
	direction: Vector3,
	max_distance: float,
	report: Dictionary
) -> void:
	if not instance.is_visible_in_tree():
		return
	var mesh := instance.mesh
	if mesh == null or not (mesh is ArrayMesh):
		return
	var array_mesh := mesh as ArrayMesh
	var world_aabb := instance.global_transform * array_mesh.get_aabb()
	if not _ray_intersects_aabb(origin, direction, world_aabb.grow(0.25), max_distance):
		return
	report["tested_mesh_instances"] = int(report.get("tested_mesh_instances", 0)) + 1
	var transform := instance.global_transform
	for surface_index in range(array_mesh.get_surface_count()):
		report["tested_surfaces"] = int(report.get("tested_surfaces", 0)) + 1
		var arrays: Array = array_mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_INDEX:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if vertices.is_empty():
			continue
		if indices.is_empty():
			for vertex_index in range(0, vertices.size() - 2, 3):
				_accumulate_render_ray_triangle(
					transform,
					vertices,
					vertex_index,
					vertex_index + 1,
					vertex_index + 2,
					origin,
					direction,
					max_distance,
					str(instance.name),
					report
				)
		else:
			for index_offset in range(0, indices.size() - 2, 3):
				_accumulate_render_ray_triangle(
					transform,
					vertices,
					int(indices[index_offset]),
					int(indices[index_offset + 1]),
					int(indices[index_offset + 2]),
					origin,
					direction,
					max_distance,
					str(instance.name),
					report
				)


func _accumulate_render_ray_triangle(
	transform: Transform3D,
	vertices: PackedVector3Array,
	index_a: int,
	index_b: int,
	index_c: int,
	origin: Vector3,
	direction: Vector3,
	max_distance: float,
	owner: String,
	report: Dictionary
) -> void:
	report["tested_triangles"] = int(report.get("tested_triangles", 0)) + 1
	if index_a < 0 or index_b < 0 or index_c < 0 or \
			index_a >= vertices.size() or index_b >= vertices.size() or index_c >= vertices.size():
		return
	var a: Vector3 = transform * vertices[index_a]
	var b: Vector3 = transform * vertices[index_b]
	var c: Vector3 = transform * vertices[index_c]
	var hit := _ray_triangle_intersection(origin, direction, a, b, c, max_distance)
	if hit.is_empty():
		return
	hit["owner"] = owner
	hit["triangle_indices"] = [index_a, index_b, index_c]
	hit["triangle_vertices"] = [
		_vector3_summary(a),
		_vector3_summary(b),
		_vector3_summary(c),
	]
	_update_render_ray_hit(report, "any", hit)
	var normal := _vector3_from_summary(hit.get("normal", {}))
	var facing_dot := normal.dot(direction)
	if facing_dot < -0.0001:
		_update_render_ray_hit(report, "front_like", hit)
	elif facing_dot > 0.0001:
		_update_render_ray_hit(report, "back_like", hit)


func _update_render_ray_hit(report: Dictionary, kind: String, hit: Dictionary) -> void:
	var key := "render_%s" % kind
	var distance_key := "%s_distance" % key
	if bool(report.get("%s_hit" % key, false)) and \
			float(report.get(distance_key, INF)) <= float(hit.get("distance", INF)):
		return
	report["%s_hit" % key] = true
	report[distance_key] = float(hit.get("distance", INF))
	report["%s_owner" % key] = str(hit.get("owner", ""))
	report["%s_position" % key] = hit.get("position", {})
	report["%s_normal" % key] = hit.get("normal", {})
	report["%s_normal_dot_ray" % key] = float(hit.get("normal_dot_ray", 0.0))
	report["%s_triangle_indices" % key] = hit.get("triangle_indices", [])
	report["%s_triangle_vertices" % key] = hit.get("triangle_vertices", [])


func _human_artifact_chunk_neighborhood(terrain_world: Node, render_ray_hits: Array) -> Array:
	if terrain_world == null or not terrain_world.has_method("query_chunk_state"):
		return []
	var seen := {}
	var output := []
	for hit in render_ray_hits:
		if not hit is Dictionary:
			continue
		var positions := []
		for kind in ["render_any", "render_front_like", "render_back_like"]:
			var hit_key := "%s_hit" % kind
			var position_key := "%s_position" % kind
			if bool(hit.get(hit_key, false)) and hit.has(position_key):
				positions.append(_vector3_from_summary(hit[position_key]))
		for position in positions:
			for lod in range(0, 4):
				var extent := float(16 * int(1 << lod))
				var center := Vector3i(
					floori(position.x / extent),
					floori(position.y / extent),
					floori(position.z / extent)
				)
				for dz in range(-1, 2):
					for dy in range(-1, 2):
						for dx in range(-1, 2):
							var key := Vector3i(center.x + dx, center.y + dy, center.z + dz)
							var dedupe := "%d:%d,%d,%d" % [lod, key.x, key.y, key.z]
							if seen.has(dedupe):
								continue
							seen[dedupe] = true
							var state: RefCounted = terrain_world.call("query_chunk_state", key, lod)
							var summary := {
								"coordinate": {"x": key.x, "y": key.y, "z": key.z},
								"lod": lod,
								"present": false,
								"visual_ready": false,
								"collision_required": false,
								"collision_ready": false,
								"fully_ready": false,
								"generation": 0,
							}
							if state != null:
								summary["present"] = bool(state.call("is_present")) if state.has_method("is_present") else false
								summary["visual_ready"] = bool(state.call("is_visual_ready")) if state.has_method("is_visual_ready") else false
								summary["collision_required"] = bool(state.call("is_collision_required")) if state.has_method("is_collision_required") else false
								summary["collision_ready"] = bool(state.call("is_collision_ready")) if state.has_method("is_collision_ready") else false
								summary["fully_ready"] = bool(state.call("is_fully_ready")) if state.has_method("is_fully_ready") else false
								summary["generation"] = int(state.call("get_generation")) if state.has_method("get_generation") else 0
							output.append(summary)
	return output


func _human_artifact_render_seam_diagnostics(backend: Node, render_ray_hits: Array) -> Array:
	if backend == null:
		return []
	var output := []
	var seen := {}
	for hit in render_ray_hits:
		if not hit is Dictionary:
			continue
		if not bool(hit.get("render_any_hit", false)):
			continue
		var owner_name := str(hit.get("render_any_owner", ""))
		var owner_info := _parse_human_artifact_render_chunk_name(owner_name)
		if owner_info.is_empty():
			continue
		var hit_position := _vector3_from_summary(hit.get("render_any_position", {}))
		var face := _human_artifact_nearest_chunk_face(owner_info, hit_position)
		if face.is_empty():
			continue
		var diagnostic_key := "%s:%d:%s" % [
			owner_name,
			int(face.get("axis", -1)),
			str(face.get("side", ""))
		]
		if seen.has(diagnostic_key):
			continue
		seen[diagnostic_key] = true
		var coordinate: Vector3i = owner_info.get("coordinate", Vector3i.ZERO)
		var lod := int(owner_info.get("lod", 0))
		var axis := int(face.get("axis", 0))
		var side := int(face.get("side", 0))
		var neighbor_coordinate := coordinate
		neighbor_coordinate[axis] += side
		var neighbor_name := _human_artifact_render_chunk_name(neighbor_coordinate, lod)
		var owner_summary := _human_artifact_mesh_seam_summary(
			backend,
			owner_name,
			face,
			hit_position,
			4.0
		)
		var neighbor_summary := _human_artifact_mesh_seam_summary(
			backend,
			neighbor_name,
			face,
			hit_position,
			4.0
		)
		output.append({
			"hit_index": int(hit.get("index", -1)),
			"owner": owner_name,
			"neighbor": neighbor_name,
			"lod": lod,
			"coordinate": {"x": coordinate.x, "y": coordinate.y, "z": coordinate.z},
			"neighbor_coordinate": {
				"x": neighbor_coordinate.x,
				"y": neighbor_coordinate.y,
				"z": neighbor_coordinate.z
			},
			"face": {
				"axis": axis,
				"axis_name": _human_artifact_axis_name(axis),
				"side": side,
				"plane": float(face.get("plane", 0.0)),
			},
			"hit_position": _vector3_summary(hit_position),
			"owner_seam": owner_summary,
			"neighbor_seam": neighbor_summary,
			"edge_comparison": _human_artifact_compare_seam_edges(owner_summary, neighbor_summary),
		})
		if output.size() >= 8:
			break
	return output


func _parse_human_artifact_render_chunk_name(owner_name: String) -> Dictionary:
	const PREFIX := "WT_Render_"
	if not owner_name.begins_with(PREFIX):
		return {}
	var rest := owner_name.substr(PREFIX.length())
	var parts := rest.split("_")
	if parts.size() != 4:
		return {}
	var lod_part := str(parts[3])
	if not lod_part.begins_with("L"):
		return {}
	return {
		"coordinate": Vector3i(int(parts[0]), int(parts[1]), int(parts[2])),
		"lod": int(lod_part.substr(1)),
	}


func _human_artifact_render_chunk_name(coordinate: Vector3i, lod: int) -> String:
	return "WT_Render_%d_%d_%d_L%d" % [coordinate.x, coordinate.y, coordinate.z, lod]


func _human_artifact_nearest_chunk_face(chunk_info: Dictionary, position: Vector3) -> Dictionary:
	var coordinate: Vector3i = chunk_info.get("coordinate", Vector3i.ZERO)
	var lod := int(chunk_info.get("lod", 0))
	var extent := float(16 * int(1 << lod))
	var minimum := Vector3(coordinate.x * extent, coordinate.y * extent, coordinate.z * extent)
	var maximum := minimum + Vector3(extent, extent, extent)
	var best_axis := -1
	var best_side := 0
	var best_plane := 0.0
	var best_distance := INF
	for axis in range(3):
		var min_distance := absf(position[axis] - minimum[axis])
		if min_distance < best_distance:
			best_axis = axis
			best_side = -1
			best_plane = minimum[axis]
			best_distance = min_distance
		var max_distance := absf(position[axis] - maximum[axis])
		if max_distance < best_distance:
			best_axis = axis
			best_side = 1
			best_plane = maximum[axis]
			best_distance = max_distance
	if best_axis < 0 or best_distance > 0.35:
		return {}
	return {
		"axis": best_axis,
		"axis_name": _human_artifact_axis_name(best_axis),
		"side": best_side,
		"plane": best_plane,
		"distance": best_distance,
	}


func _human_artifact_mesh_seam_summary(
	backend: Node,
	owner_name: String,
	face: Dictionary,
	focus: Vector3,
	window_radius: float
) -> Dictionary:
	var result := {
		"owner": owner_name,
		"found": false,
		"error": "",
		"surface_count": 0,
		"vertex_count": 0,
		"index_count": 0,
		"near_triangles_count": 0,
		"seam_edge_count": 0,
		"unique_seam_edge_count": 0,
		"near_triangles": [],
		"seam_edges": [],
	}
	var instance := _human_artifact_find_mesh_instance_by_name(backend, owner_name)
	if instance == null:
		result["error"] = "mesh_instance_not_found"
		return result
	var mesh := instance.mesh
	if mesh == null or not (mesh is ArrayMesh):
		result["found"] = true
		result["error"] = "array_mesh_not_found"
		return result
	result["found"] = true
	var array_mesh := mesh as ArrayMesh
	result["surface_count"] = array_mesh.get_surface_count()
	var transform := instance.global_transform
	var axis := int(face.get("axis", 0))
	var plane := float(face.get("plane", 0.0))
	var edge_keys := {}
	for surface_index in range(array_mesh.get_surface_count()):
		var arrays: Array = array_mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices := PackedInt32Array()
		if arrays.size() > Mesh.ARRAY_INDEX:
			indices = arrays[Mesh.ARRAY_INDEX]
		result["vertex_count"] = int(result["vertex_count"]) + vertices.size()
		result["index_count"] = int(result["index_count"]) + indices.size()
		if indices.is_empty():
			for vertex_index in range(0, vertices.size() - 2, 3):
				_human_artifact_accumulate_seam_triangle(
					result,
					edge_keys,
					surface_index,
					vertex_index,
					vertex_index + 1,
					vertex_index + 2,
					transform * vertices[vertex_index],
					transform * vertices[vertex_index + 1],
					transform * vertices[vertex_index + 2],
					axis,
					plane,
					focus,
					window_radius
				)
		else:
			for index_offset in range(0, indices.size() - 2, 3):
				var index_a := int(indices[index_offset])
				var index_b := int(indices[index_offset + 1])
				var index_c := int(indices[index_offset + 2])
				if index_a < 0 or index_b < 0 or index_c < 0 or \
						index_a >= vertices.size() or index_b >= vertices.size() or index_c >= vertices.size():
					continue
				_human_artifact_accumulate_seam_triangle(
					result,
					edge_keys,
					surface_index,
					index_a,
					index_b,
					index_c,
					transform * vertices[index_a],
					transform * vertices[index_b],
					transform * vertices[index_c],
					axis,
					plane,
					focus,
					window_radius
				)
	result["unique_seam_edge_count"] = edge_keys.size()
	return result


func _human_artifact_accumulate_seam_triangle(
	result: Dictionary,
	edge_keys: Dictionary,
	surface_index: int,
	index_a: int,
	index_b: int,
	index_c: int,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	axis: int,
	plane: float,
	focus: Vector3,
	window_radius: float
) -> void:
	var near_count := 0
	if _human_artifact_on_face_plane(a, axis, plane):
		near_count += 1
	if _human_artifact_on_face_plane(b, axis, plane):
		near_count += 1
	if _human_artifact_on_face_plane(c, axis, plane):
		near_count += 1
	if near_count == 0:
		return
	var centroid := (a + b + c) / 3.0
	if not _human_artifact_triangle_in_face_window(a, b, c, centroid, axis, focus, window_radius):
		return
	result["near_triangles_count"] = int(result["near_triangles_count"]) + 1
	if Array(result["near_triangles"]).size() < 24:
		result["near_triangles"].append({
			"surface": surface_index,
			"indices": [index_a, index_b, index_c],
			"near_face_vertex_count": near_count,
			"centroid": _vector3_summary(centroid),
			"vertices": [_vector3_summary(a), _vector3_summary(b), _vector3_summary(c)],
		})
	var triangle_vertices := [a, b, c]
	var triangle_indices := [index_a, index_b, index_c]
	for edge_index in range(3):
		var start_vertex: Vector3 = triangle_vertices[edge_index]
		var end_vertex: Vector3 = triangle_vertices[(edge_index + 1) % 3]
		if not _human_artifact_on_face_plane(start_vertex, axis, plane) or \
				not _human_artifact_on_face_plane(end_vertex, axis, plane):
			continue
		var edge_key := _human_artifact_seam_edge_key(start_vertex, end_vertex, axis)
		result["seam_edge_count"] = int(result["seam_edge_count"]) + 1
		edge_keys[edge_key] = true
		if Array(result["seam_edges"]).size() < 32:
			result["seam_edges"].append({
				"key": edge_key,
				"indices": [triangle_indices[edge_index], triangle_indices[(edge_index + 1) % 3]],
				"start": _vector3_summary(start_vertex),
				"end": _vector3_summary(end_vertex),
			})


func _human_artifact_find_mesh_instance_by_name(root: Node, owner_name: String) -> MeshInstance3D:
	if root == null:
		return null
	if root is MeshInstance3D and str(root.name) == owner_name:
		return root as MeshInstance3D
	for child in root.get_children():
		if child is Node:
			var found := _human_artifact_find_mesh_instance_by_name(child, owner_name)
			if found != null:
				return found
	return null


func _human_artifact_compare_seam_edges(owner_summary: Dictionary, neighbor_summary: Dictionary) -> Dictionary:
	var owner_keys := {}
	for edge in owner_summary.get("seam_edges", []):
		if edge is Dictionary:
			owner_keys[str(edge.get("key", ""))] = true
	var neighbor_keys := {}
	for edge in neighbor_summary.get("seam_edges", []):
		if edge is Dictionary:
			neighbor_keys[str(edge.get("key", ""))] = true
	var missing_from_neighbor := []
	for key in owner_keys.keys():
		if not neighbor_keys.has(key) and missing_from_neighbor.size() < 16:
			missing_from_neighbor.append(key)
	var missing_from_owner := []
	for key in neighbor_keys.keys():
		if not owner_keys.has(key) and missing_from_owner.size() < 16:
			missing_from_owner.append(key)
	var matched := 0
	for key in owner_keys.keys():
		if neighbor_keys.has(key):
			matched += 1
	return {
		"owner_unique_edges": owner_keys.size(),
		"neighbor_unique_edges": neighbor_keys.size(),
		"matched_edges": matched,
		"missing_from_neighbor_count": maxi(0, owner_keys.size() - matched),
		"missing_from_owner_count": maxi(0, neighbor_keys.size() - matched),
		"missing_from_neighbor_samples": missing_from_neighbor,
		"missing_from_owner_samples": missing_from_owner,
		"exact_match": owner_keys.size() == neighbor_keys.size() and \
			missing_from_neighbor.is_empty() and missing_from_owner.is_empty(),
	}


func _human_artifact_on_face_plane(point: Vector3, axis: int, plane: float) -> bool:
	return absf(point[axis] - plane) <= 0.0001


func _human_artifact_triangle_in_face_window(
	a: Vector3,
	b: Vector3,
	c: Vector3,
	centroid: Vector3,
	axis: int,
	focus: Vector3,
	window_radius: float
) -> bool:
	return _human_artifact_point_in_face_window(a, axis, focus, window_radius) or \
		_human_artifact_point_in_face_window(b, axis, focus, window_radius) or \
		_human_artifact_point_in_face_window(c, axis, focus, window_radius) or \
		_human_artifact_point_in_face_window(centroid, axis, focus, window_radius)


func _human_artifact_point_in_face_window(
	point: Vector3,
	axis: int,
	focus: Vector3,
	window_radius: float
) -> bool:
	for component in range(3):
		if component == axis:
			continue
		if absf(point[component] - focus[component]) > window_radius:
			return false
	return true


func _human_artifact_seam_edge_key(a: Vector3, b: Vector3, axis: int) -> String:
	var point_a := _human_artifact_face_point_key(a, axis)
	var point_b := _human_artifact_face_point_key(b, axis)
	if point_a <= point_b:
		return "%s|%s" % [point_a, point_b]
	return "%s|%s" % [point_b, point_a]


func _human_artifact_face_point_key(point: Vector3, axis: int) -> String:
	var values := []
	for component in range(3):
		if component == axis:
			continue
		values.append(str(int(round(point[component] * 10000.0))))
	return ",".join(values)


func _human_artifact_axis_name(axis: int) -> String:
	match axis:
		0:
			return "x"
		1:
			return "y"
		2:
			return "z"
	return "unknown"


func _ray_triangle_intersection(
	origin: Vector3,
	direction: Vector3,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	max_distance: float
) -> Dictionary:
	var edge_ab := b - a
	var edge_ac := c - a
	var normal := edge_ab.cross(edge_ac)
	var normal_length := normal.length()
	if normal_length <= 0.00000001:
		return {}
	normal /= normal_length
	var h := direction.cross(edge_ac)
	var determinant := edge_ab.dot(h)
	if absf(determinant) <= 0.0000001:
		return {}
	var inverse_determinant := 1.0 / determinant
	var s := origin - a
	var u := s.dot(h) * inverse_determinant
	if u < -0.000001 or u > 1.000001:
		return {}
	var q := s.cross(edge_ab)
	var v := direction.dot(q) * inverse_determinant
	if v < -0.000001 or u + v > 1.000001:
		return {}
	var distance := edge_ac.dot(q) * inverse_determinant
	if distance <= 0.0001 or distance > max_distance:
		return {}
	return {
		"distance": distance,
		"position": _vector3_summary(origin + direction * distance),
		"normal": _vector3_summary(normal),
		"normal_dot_ray": normal.dot(direction),
		"u": u,
		"v": v,
	}


func _ray_intersects_aabb(
	origin: Vector3,
	direction: Vector3,
	aabb: AABB,
	max_distance: float
) -> bool:
	var minimum := aabb.position
	var maximum := aabb.position + aabb.size
	var tmin := 0.0
	var tmax := max_distance
	for axis in range(3):
		var origin_axis := origin[axis]
		var direction_axis := direction[axis]
		if absf(direction_axis) < 0.0000001:
			if origin_axis < minimum[axis] or origin_axis > maximum[axis]:
				return false
			continue
		var inverse_direction := 1.0 / direction_axis
		var t1 := (minimum[axis] - origin_axis) * inverse_direction
		var t2 := (maximum[axis] - origin_axis) * inverse_direction
		if t1 > t2:
			var swap := t1
			t1 = t2
			t2 = swap
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return false
	return tmax >= 0.0 and tmin <= max_distance


func _collect_human_artifact_probes(backend: Node, probe_specs: Array) -> Array:
	var probes := []
	for spec in probe_specs:
		var center: Vector3 = spec.get("center", Vector3.ZERO)
		var label := str(spec.get("label", "unknown"))
		for radius in [3.0, 6.0, 12.0, 24.0]:
			var probe := WatertightnessProbe.collect(
				backend,
				"human_artifact_%s_r%02d" % [label, int(radius)],
				center,
				radius
			)
			var digest := _open_gap_probe_digest(probe)
			digest["label"] = label
			digest["center"] = _vector3_summary(center)
			digest["radius"] = radius
			digest["open_gap_free"] = _is_open_gap_free_probe(probe)
			probes.append(digest)
	return probes


func _collect_human_artifact_precise_probes(backend: Node, probe_specs: Array) -> Array:
	var probes := []
	var selected_specs := _human_artifact_precise_probe_specs(probe_specs)
	for spec in selected_specs:
		var center: Vector3 = spec.get("center", Vector3.ZERO)
		var label := str(spec.get("label", "unknown"))
		for radius in [3.0, 6.0, 12.0]:
			var probe: Dictionary = WatertightnessProbe.collect_precise(
				backend,
				"human_artifact_precise_%s_r%02d" % [label, int(radius)],
				center,
				radius,
				1048576,
				2
			)
			var digest := _open_gap_probe_digest(probe)
			digest["label"] = label
			digest["center"] = _vector3_summary(center)
			digest["radius"] = radius
			digest["point_key_scale"] = int(probe.get("point_key_scale", 0))
			digest["chunk_face_tolerance_keys"] = int(probe.get("chunk_face_tolerance_keys", 0))
			digest["open_gap_free"] = _is_open_gap_free_probe(probe)
			probes.append(digest)
	return probes


func _human_artifact_precise_probe_specs(probe_specs: Array) -> Array:
	var selected := []
	var seen := {}
	for spec in probe_specs:
		var label := str(spec.get("label", "unknown"))
		if label != "ray_hit" and label != "last_interaction" and not label.begins_with("sky_pixel_"):
			continue
		var center: Vector3 = spec.get("center", Vector3.ZERO)
		var key := "%s:%0.3f,%0.3f,%0.3f" % [label, center.x, center.y, center.z]
		if seen.has(key):
			continue
		seen[key] = true
		selected.append(spec)
		if selected.size() >= 20:
			break
	return selected


func _human_artifact_probe_is_problematic(probe: Dictionary) -> bool:
	if int(probe.get("triangles_in_region", 0)) <= 0:
		return false
	return not bool(probe.get("open_gap_free", false))


func _human_artifact_precise_probe_is_problematic(probe: Dictionary) -> bool:
	if int(probe.get("triangles_in_region", 0)) <= 0:
		return false
	if not bool(probe.get("open_gap_free", false)):
		return true
	if int(probe.get("chunk_face_boundary_edges", 0)) > 0:
		return true
	if float(probe.get("minimum_area_squared", INF)) > 0.0 and \
			float(probe.get("minimum_area_squared", INF)) < 0.00000025:
		return true
	return false


func _screen_sky_pixel_summary(image: Image, stride: int = 1) -> Dictionary:
	var width := image.get_width()
	var height := image.get_height()
	stride = maxi(1, stride)
	var sample_weight := stride * stride
	var center_left := int(width * 0.20)
	var center_right := int(width * 0.80)
	var center_top := int(height * 0.20)
	var center_bottom := int(height * 0.80)
	var lower_center_top := int(height * 0.55)
	var lower_center_bottom := int(height * 0.95)
	var terrain_band_left := int(width * 0.05)
	var terrain_band_right := int(width * 0.95)
	var terrain_band_top := int(height * 0.20)
	var terrain_band_bottom := int(height * 0.95)
	var crosshair_half_size := 128
	var cross_left := maxi(0, width / 2 - crosshair_half_size)
	var cross_right := mini(width, width / 2 + crosshair_half_size)
	var cross_top := maxi(0, height / 2 - crosshair_half_size)
	var cross_bottom := mini(height, height / 2 + crosshair_half_size)
	var whole_sky_pixels := 0
	var center_sky_pixels := 0
	var lower_center_sky_pixels := 0
	var terrain_band_sky_pixels := 0
	var crosshair_sky_pixels := 0
	var isolated_sky_pixels := 0
	var isolated_center_sky_pixels := 0
	var isolated_lower_center_sky_pixels := 0
	var isolated_terrain_band_sky_pixels := 0
	var isolated_crosshair_sky_pixels := 0
	var examples := []
	var crosshair_examples := []
	var lower_center_examples := []
	var terrain_band_examples := []
	var isolated_examples := []
	var isolated_lower_center_examples := []
	var isolated_terrain_band_examples := []
	var isolated_crosshair_examples := []
	for y in range(0, height, stride):
		for x in range(0, width, stride):
			var color := image.get_pixel(x, y)
			if not _is_sky_like_pixel(color):
				continue
			whole_sky_pixels += sample_weight
			if examples.size() < 8:
				examples.append(_pixel_summary(x, y, color))
			var isolated := _is_isolated_sky_pixel(image, x, y)
			if isolated:
				isolated_sky_pixels += sample_weight
				if isolated_examples.size() < 8:
					isolated_examples.append(_pixel_summary(x, y, color))
			if x >= center_left and x < center_right and y >= center_top and y < center_bottom:
				center_sky_pixels += sample_weight
				if isolated:
					isolated_center_sky_pixels += sample_weight
			if x >= center_left and x < center_right and y >= lower_center_top and y < lower_center_bottom:
				lower_center_sky_pixels += sample_weight
				if lower_center_examples.size() < 8:
					lower_center_examples.append(_pixel_summary(x, y, color))
				if isolated:
					isolated_lower_center_sky_pixels += sample_weight
					if isolated_lower_center_examples.size() < 8:
						isolated_lower_center_examples.append(_pixel_summary(x, y, color))
			if x >= terrain_band_left and x < terrain_band_right and y >= terrain_band_top and y < terrain_band_bottom:
				terrain_band_sky_pixels += sample_weight
				if terrain_band_examples.size() < 8:
					terrain_band_examples.append(_pixel_summary(x, y, color))
				if isolated:
					isolated_terrain_band_sky_pixels += sample_weight
					if isolated_terrain_band_examples.size() < 8:
						isolated_terrain_band_examples.append(_pixel_summary(x, y, color))
			if x >= cross_left and x < cross_right and y >= cross_top and y < cross_bottom:
				crosshair_sky_pixels += sample_weight
				if crosshair_examples.size() < 8:
					crosshair_examples.append(_pixel_summary(x, y, color))
				if isolated:
					isolated_crosshair_sky_pixels += sample_weight
					if isolated_crosshair_examples.size() < 8:
						isolated_crosshair_examples.append(_pixel_summary(x, y, color))
	return {
		"width": width,
		"height": height,
		"stride": stride,
		"whole_sky_pixels": whole_sky_pixels,
		"center_sky_pixels": center_sky_pixels,
		"lower_center_sky_pixels": lower_center_sky_pixels,
		"terrain_band_sky_pixels": terrain_band_sky_pixels,
		"crosshair_sky_pixels": crosshair_sky_pixels,
		"isolated_sky_pixels": isolated_sky_pixels,
		"isolated_center_sky_pixels": isolated_center_sky_pixels,
		"isolated_lower_center_sky_pixels": isolated_lower_center_sky_pixels,
		"isolated_terrain_band_sky_pixels": isolated_terrain_band_sky_pixels,
		"isolated_crosshair_sky_pixels": isolated_crosshair_sky_pixels,
		"examples": examples,
		"crosshair_examples": crosshair_examples,
		"lower_center_examples": lower_center_examples,
		"terrain_band_examples": terrain_band_examples,
		"isolated_examples": isolated_examples,
		"isolated_lower_center_examples": isolated_lower_center_examples,
		"isolated_terrain_band_examples": isolated_terrain_band_examples,
		"isolated_crosshair_examples": isolated_crosshair_examples,
	}


func _is_sky_like_pixel(color: Color) -> bool:
	return color.b >= 0.65 and \
		color.g >= 0.45 and \
		color.r <= 0.72 and \
		color.b >= color.r + 0.10 and \
		color.b >= color.g + 0.02


func _is_isolated_sky_pixel(image: Image, x: int, y: int) -> bool:
	var sky_neighbor_count := 0
	var left := maxi(0, x - 2)
	var right := mini(image.get_width() - 1, x + 2)
	var top := maxi(0, y - 2)
	var bottom := mini(image.get_height() - 1, y + 2)
	for yy in range(top, bottom + 1):
		for xx in range(left, right + 1):
			if _is_sky_like_pixel(image.get_pixel(xx, yy)):
				sky_neighbor_count += 1
				if sky_neighbor_count > 6:
					return false
	return true


func _pixel_summary(x: int, y: int, color: Color) -> Dictionary:
	return {
		"x": x,
		"y": y,
		"r": color.r,
		"g": color.g,
		"b": color.b,
	}


func _vector3_summary(value: Vector3) -> Dictionary:
	return {
		"x": value.x,
		"y": value.y,
		"z": value.z,
	}


func _vector3_from_summary(value) -> Vector3:
	if value is Vector3:
		return value
	if value is Dictionary:
		return Vector3(
			float(value.get("x", 0.0)),
			float(value.get("y", 0.0)),
			float(value.get("z", 0.0))
		)
	return Vector3.ZERO


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
	return {
		"materialized_instances": int(material_summary.get("materialized_instances", 0)),
		"production_texture_active": bool(material_summary.get("production_texture_active", false)),
		"native_render_material_override": bool(material_summary.get("native_render_material_override", false)),
		"quality_implementation": str(material_summary.get("quality_implementation", "")),
		"clean_material_variation_enabled": bool(material_summary.get("clean_material_variation_enabled", false)),
		"clean_material_variation_strength": float(material_summary.get("clean_material_variation_strength", 0.0)),
		"clean_roughness": float(material_summary.get("clean_roughness", 0.0)),
		"clean_specular": float(material_summary.get("clean_specular", 1.0)),
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


func _human_launch_command_text(user_args: Array) -> String:
	var displayed_args := PackedStringArray()
	var has_profile := false
	for index in range(user_args.size()):
		var value := str(user_args[index])
		displayed_args.append(_quote_command_arg(value))
		if value == "--p2-profile":
			has_profile = true
	if not has_profile:
		displayed_args.append("--p2-profile")
		displayed_args.append(_quote_command_arg(str(selected_profile)))
	var project_path := ProjectSettings.globalize_path("res://").trim_suffix("/")
	var command := "godot --path %s" % _quote_command_arg(project_path)
	if not displayed_args.is_empty():
		command = "%s -- %s" % [command, " ".join(displayed_args)]
	return "launch: %s" % command


func _human_test_context_text() -> String:
	var test_name := "human_playtest"
	if not human_visual_capture_path.is_empty():
		test_name = "visual_capture:%s" % human_visual_capture_mode
	elif not human_playtest_preset.is_empty():
		test_name = "human_playtest:%s" % human_playtest_preset
	var storage_mode := "preserve"
	if not human_preserve_storage and human_artifact_replay_marker_path.is_empty():
		storage_mode = "fresh"
	return "test: %s | profile: %s | storage: %s" % [
		test_name,
		str(selected_profile),
		storage_mode,
	]


func _quote_command_arg(value: String) -> String:
	if value.is_empty():
		return "\"\""
	if value.find(" ") < 0 and value.find("\t") < 0 and value.find("\"") < 0:
		return value
	return "\"%s\"" % value.replace("\"", "\\\"")


func _apply_human_playtest_preset() -> bool:
	match human_playtest_preset:
		"edit_tunnel_gate", "tunnel_gate", "descending_tunnel":
			return await _apply_human_tunnel_playtest()
		_:
			_fail("unknown human playtest preset: %s" % human_playtest_preset)
			return false


func _apply_human_tunnel_playtest() -> bool:
	if player == null or game_world == null:
		_fail("human tunnel playtest requires player and game world")
		return false
	var terrain_world: Node = game_world.get_terrain_world()
	if terrain_world == null:
		_fail("human tunnel playtest terrain world unavailable")
		return false
	var backend: Node = terrain_world.call("get_backend_terrain")
	if backend == null:
		_fail("human tunnel playtest backend unavailable")
		return false
	var operations := _tunnel_gate_operations()
	if operations.is_empty():
		_fail("human tunnel playtest produced no operations")
		return false
	edit_persistence_operations = operations.duplicate()
	interaction_inspection_operation_count = operations.size()
	last_tunnel_summary = {
		"enabled": true,
		"ok": false,
		"profile": str(selected_profile),
		"operation_count": operations.size(),
		"human_playtest_preset": true,
	}
	if not await _submit_tunnel_operations_for_playtest(terrain_world, operations):
		return false
	var preload_summaries := []
	for step in _tunnel_gate_path():
		var preload_label := str(step.get("label", "step"))
		await _set_capture_camera_pose(step.get("position", player.global_position), step.get("target", _tunnel_gate_center()))
		var preload_notes := []
		var preload_center: Vector3 = step.get("probe_center", _tunnel_gate_center())
		var preload_radius := float(step.get("probe_radius", _tunnel_probe_radius()))
		if not await _wait_for_tunnel_visual_ready(
			backend,
			"human tunnel preload %s" % preload_label,
			preload_notes,
			preload_center,
			preload_radius,
			"human_tunnel_playtest",
			true
		):
			last_tunnel_summary["error"] = "preload_visual_not_ready"
			last_tunnel_summary["failed_preload"] = preload_label
			return false
		preload_summaries.append({
			"label": preload_label,
			"settle_notes": preload_notes,
		})
	if not await _place_player_at_tunnel_playtest_start():
		last_tunnel_summary["error"] = "player_start_failed"
		return false
	if material_applicator != null:
		material_applicator.call("apply_materials_now")
	last_tunnel_summary = {
		"enabled": true,
		"ok": true,
		"profile": str(selected_profile),
		"operation_count": operations.size(),
		"human_playtest_preset": true,
		"preload_summaries": preload_summaries,
	}
	interaction_inspection_applied = true
	return true


func _submit_tunnel_operations_for_playtest(terrain_world: Node, operations: Array) -> bool:
	var operation_index := 0
	var batch_size := 4
	while operation_index < operations.size():
		var before_revision := int(terrain_world.call("get_backend_world_revision"))
		var batch = EditBatch.new()
		for _local_index in range(batch_size):
			if operation_index >= operations.size():
				break
			if not batch.add_operation(operations[operation_index]):
				_fail("failed to add human tunnel operation %d" % operation_index)
				last_tunnel_summary["error"] = "batch_add_failed"
				last_tunnel_summary["failed_operation"] = operation_index
				return false
			operation_index += 1
		if not bool(terrain_world.call("submit_edit_batch", batch, 9721)):
			last_tunnel_summary["error"] = "edit_batch_rejected"
			last_tunnel_summary["failed_operation"] = operation_index
			last_tunnel_summary["last_error"] = str(terrain_world.call("get_last_error"))
			_fail("human tunnel edit batch rejected: %s" % str(terrain_world.call("get_last_error")))
			return false
		if not await game_world.wait_for_world_revision(before_revision + 1):
			last_tunnel_summary["error"] = "revision_not_committed"
			last_tunnel_summary["failed_operation"] = operation_index
			_fail("human tunnel edit batch did not commit")
			return false
		for _frame in range(2):
			await get_tree().process_frame
	return true


func _place_player_at_tunnel_playtest_start() -> bool:
	var path := _tunnel_gate_path()
	if path.is_empty():
		return false
	var step: Dictionary = path[3] if path.size() > 3 else path[0]
	var position: Vector3 = step.get("position", _tunnel_gate_center() + Vector3(-8.0, 5.0, -8.0))
	var target: Vector3 = step.get("target", _tunnel_gate_center())
	player.global_position = position
	player.velocity = Vector3.ZERO
	if player.has_method("set_fly_mode_enabled"):
		player.call("set_fly_mode_enabled", false)
	if player.has_method("set_view_target"):
		player.call("set_view_target", target)
	elif player.has_method("autonomous_look_at"):
		player.call("autonomous_look_at", target)
	if game_world != null and game_world.has_method("update_player_viewer"):
		game_world.call("update_player_viewer", true)
	for _frame in range(30):
		await get_tree().process_frame
	return true


func _capture_human_visual() -> void:
	if human_visual_capture_mode == "streaming_fly_gap_gate":
		if not await _run_streaming_fly_gap_gate():
			return
	elif human_visual_capture_mode == "post_edit_streaming_fly_gap_gate":
		if not await _run_post_edit_streaming_fly_gap_gate():
			return
	else:
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
	var watertightness_acceptance := _watertightness_acceptance_summary(last_watertightness_summary)
	print("WT_HUMAN_VISUAL_CAPTURE_SUMMARY ", JSON.stringify({
		"mode": human_visual_capture_mode,
		"profile": str(selected_profile),
		"viewer_radius_chunks": int(summary.get("viewer_radius_chunks", 0)),
		"viewer_maximum_lod": int(summary.get("viewer_maximum_lod", 0)),
		"player_viewer_update_distance": float(summary.get("player_viewer_update_distance", 0.0)),
		"player_viewer_coalesce_while_streaming": bool(summary.get("player_viewer_coalesce_while_streaming", false)),
		"player_viewer_coalesced_updates": int(summary.get("player_viewer_coalesced_updates", 0)),
		"player_viewer_last_coalesce_reason": str(summary.get("player_viewer_last_coalesce_reason", "none")),
		"player_predictive_viewer_enabled": bool(summary.get("player_predictive_viewer_enabled", false)),
		"player_predictive_viewer_distance": float(summary.get("player_predictive_viewer_distance", 0.0)),
		"player_predictive_viewer_updates": int(summary.get("player_predictive_viewer_updates", 0)),
		"player_focus_viewer_enabled": bool(summary.get("player_focus_viewer_enabled", false)),
		"player_focus_viewer_distance": float(summary.get("player_focus_viewer_distance", 0.0)),
		"player_focus_viewer_updates": int(summary.get("player_focus_viewer_updates", 0)),
		"runtime_viewer_capacity": int(summary.get("runtime_viewer_capacity", 0)),
		"runtime_demand_capacity_per_viewer": int(summary.get("runtime_demand_capacity_per_viewer", 0)),
		"runtime_lod_refinement_radius_chunks": int(summary.get("runtime_lod_refinement_radius_chunks", 0)),
		"runtime_render_apply_budget": int(summary.get("runtime_render_apply_budget", 0)),
		"runtime_collision_apply_budget": int(summary.get("runtime_collision_apply_budget", 0)),
		"runtime_render_transition_frames": int(summary.get("runtime_render_transition_frames", 0)),
		"runtime_shader_fade_parameter_enabled": bool(summary.get("runtime_shader_fade_parameter_enabled", false)),
		"runtime_streaming_burst_render_apply_budget": int(summary.get("runtime_streaming_burst_render_apply_budget", 0)),
		"runtime_streaming_burst_collision_apply_budget": int(summary.get("runtime_streaming_burst_collision_apply_budget", 0)),
		"runtime_streaming_burst_frames": int(summary.get("runtime_streaming_burst_frames", 0)),
		"runtime_edit_burst_render_apply_budget": int(summary.get("runtime_edit_burst_render_apply_budget", 0)),
		"runtime_edit_burst_collision_apply_budget": int(summary.get("runtime_edit_burst_collision_apply_budget", 0)),
		"runtime_edit_burst_frames": int(summary.get("runtime_edit_burst_frames", 0)),
		"streaming_burst_frames_remaining": int(summary.get("streaming_burst_frames_remaining", 0)),
		"runtime_collision_activation_distance": float(summary.get("runtime_collision_activation_distance", 0.0)),
		"runtime_collision_deactivation_distance": float(summary.get("runtime_collision_deactivation_distance", 0.0)),
		"active_chunk_records": int(summary.get("active_chunk_records", 0)),
		"visual_ready_chunk_records": int(summary.get("visual_ready_chunk_records", 0)),
		"fully_ready_chunk_records": int(summary.get("fully_ready_chunk_records", 0)),
		"pending_chunk_retirements": int(summary.get("pending_chunk_retirements", 0)),
		"pending_chunk_replacements": int(summary.get("pending_chunk_replacements", 0)),
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
		"edited_exact_region": _edited_exact_region_contract_summary(
			summary,
			_declared_exact_region_radius_for_mode(human_visual_capture_mode)
		),
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
		"watertightness_acceptance": watertightness_acceptance,
		"edit_persistence": _edit_persistence_summary(),
		"edit_stability": _edit_stability_summary(),
		"lod_movement": _lod_movement_summary(),
		"multisite_lod": _multisite_lod_summary(),
		"edit_during_load": _edit_during_load_summary(),
		"manifold_stress": _manifold_stress_summary(),
		"tunnel": _tunnel_summary(),
		"streaming_fly": _streaming_fly_summary(),
		"capture_path": human_visual_capture_path,
	}))
	var watertightness_accepted := bool(watertightness_acceptance.get("accepted_for_mode", false))
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
		human_visual_capture_mode == "edit_multisite_lod_gate" or \
		human_visual_capture_mode == "edit_tunnel_gate" or \
		human_visual_capture_mode == "edit_tunnel_crawl_gate" or \
		human_visual_capture_mode == "edit_tunnel_transient_crawl_gate" or \
		human_visual_capture_mode == "edit_tunnel_upward_lod_gate" or \
		human_visual_capture_mode == "interaction_near" or \
		human_visual_capture_mode == "interaction_far" or \
		human_visual_capture_mode == "interaction_aerial"


func _capture_requires_watertightness_probe() -> bool:
	return human_visual_capture_mode.begins_with("watertight_") or \
		human_visual_capture_mode == "edit_persistence_reload_oracle" or \
		human_visual_capture_mode == "edit_stability_gate" or \
		human_visual_capture_mode == "edit_lod_movement_gate" or \
		human_visual_capture_mode == "edit_multisite_lod_gate" or \
		human_visual_capture_mode == "edit_during_load_oracle" or \
		human_visual_capture_mode == "edit_manifold_stress_gate" or \
		human_visual_capture_mode == "edit_tunnel_gate" or \
		human_visual_capture_mode == "edit_tunnel_crawl_gate" or \
		human_visual_capture_mode == "edit_tunnel_transient_crawl_gate" or \
		human_visual_capture_mode == "edit_tunnel_upward_lod_gate"


func _watertightness_acceptance_summary(probe: Dictionary) -> Dictionary:
	var boundary := "exact_topology"
	var accepted := bool(probe.get("ok", false))
	if human_visual_capture_mode == "edit_lod_movement_gate" and lod_movement_gap_only_probe:
		boundary = "lod_movement_gap_only"
		accepted = _is_lod_movement_probe_ready(probe)
	elif human_visual_capture_mode == "edit_multisite_lod_gate" and lod_movement_gap_only_probe:
		boundary = "lod_movement_gap_only"
		accepted = _is_lod_movement_probe_ready(probe)
	elif human_visual_capture_mode == "edit_during_load_oracle":
		boundary = "open_gap_only"
		accepted = _is_open_gap_free_probe(probe)
	elif human_visual_capture_mode == "edit_manifold_stress_gate":
		boundary = "open_gap_only"
		accepted = _is_open_gap_free_probe(probe)
	elif human_visual_capture_mode == "edit_tunnel_gate" or \
			human_visual_capture_mode == "edit_tunnel_crawl_gate" or \
			human_visual_capture_mode == "edit_tunnel_transient_crawl_gate" or \
			human_visual_capture_mode == "edit_tunnel_upward_lod_gate":
		boundary = "open_gap_only"
		accepted = _is_open_gap_free_probe(probe)
	return {
		"accepted_for_mode": accepted,
		"boundary": boundary,
		"raw_probe_ok": bool(probe.get("ok", false)),
		"boundary_edges": int(probe.get("boundary_edges", -1)),
		"interior_boundary_edges": int(probe.get("interior_boundary_edges", -1)),
		"unknown_boundary_edges": int(probe.get("unknown_boundary_edges", -1)),
		"nonmanifold_edges": int(probe.get("nonmanifold_edges", -1)),
		"orientation_conflict_edges": int(probe.get("orientation_conflict_edges", -1)),
		"orientation_conflict_chunk_face_edges": int(probe.get("orientation_conflict_chunk_face_edges", 0)),
		"orientation_conflict_interior_edges": int(probe.get("orientation_conflict_interior_edges", 0)),
		"orientation_conflict_unknown_edges": int(probe.get("orientation_conflict_unknown_edges", 0)),
	}


func _apply_interaction_inspection_edits() -> bool:
	if interaction_inspection_applied:
		return true
	var terrain_world: Node = game_world.get_terrain_world() if game_world != null else null
	if terrain_world == null:
		_fail("terrain world unavailable for interaction inspection")
		return false
	if human_visual_capture_mode == "edit_lod_movement_gate":
		return await _run_edit_lod_movement_gate(terrain_world)
	if human_visual_capture_mode == "edit_multisite_lod_gate":
		return await _run_edit_multisite_lod_gate(terrain_world)
	if human_visual_capture_mode == "edit_during_load_oracle":
		return await _run_edit_during_load_oracle(terrain_world)
	if human_visual_capture_mode == "edit_manifold_stress_gate":
		return await _run_manifold_stress_gate(terrain_world)
	if human_visual_capture_mode == "edit_tunnel_gate":
		return await _run_tunnel_gate(terrain_world)
	if human_visual_capture_mode == "edit_tunnel_crawl_gate":
		return await _run_tunnel_crawl_gate(terrain_world)
	if human_visual_capture_mode == "edit_tunnel_transient_crawl_gate":
		return await _run_tunnel_transient_crawl_gate(terrain_world)
	if human_visual_capture_mode == "edit_tunnel_upward_lod_gate":
		return await _run_tunnel_upward_lod_gate(terrain_world)
	if human_visual_capture_mode == "edit_stability_gate":
		return await _run_edit_stability_gate(terrain_world)
	if _capture_requires_sequential_interaction_edits():
		return await _apply_sequential_interaction_inspection_edits(terrain_world)
	var before_revision := int(terrain_world.call("get_backend_world_revision"))
	var batch = EditBatch.new()
	var operations := _interaction_inspection_operations()
	for operation in operations:
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
	return await _run_tunnel_gate_path(
		terrain_world,
		_tunnel_gate_path(),
		"edit_tunnel_gate",
		"tunnel gate"
	)


func _run_tunnel_crawl_gate(terrain_world: Node) -> bool:
	return await _run_tunnel_gate_path(
		terrain_world,
		_tunnel_crawl_path(),
		"edit_tunnel_crawl_gate",
		"tunnel crawl gate"
	)


func _run_tunnel_upward_lod_gate(terrain_world: Node) -> bool:
	return await _run_tunnel_gate_path(
		terrain_world,
		_tunnel_upward_lod_path(),
		"edit_tunnel_upward_lod_gate",
		"tunnel upward LOD gate"
	)


func _run_tunnel_transient_crawl_gate(terrain_world: Node) -> bool:
	if player == null or game_world == null:
		_fail("tunnel transient crawl gate requires player and game world")
		return false
	var backend: Node = terrain_world.call("get_backend_terrain")
	if backend == null:
		_fail("tunnel transient crawl gate backend unavailable")
		return false
	var path := _tunnel_crawl_path()
	var operations := _tunnel_gate_operations()
	edit_persistence_operations = operations.duplicate()
	interaction_inspection_operation_count = operations.size()
	last_tunnel_summary = {
		"enabled": true,
		"ok": false,
		"profile": str(selected_profile),
		"operation_count": operations.size(),
		"gate_mode": "edit_tunnel_transient_crawl_gate",
	}
	if operations.is_empty():
		last_tunnel_summary["error"] = "no_operations"
		_fail("tunnel transient crawl gate produced no operations")
		return false
	if path.is_empty():
		last_tunnel_summary["error"] = "empty_path"
		_fail("tunnel transient crawl gate produced no camera path")
		return false

	var first_step: Dictionary = path[0]
	await _set_capture_camera_pose(first_step.get("position", player.global_position), first_step.get("target", _tunnel_gate_center()))
	var initial_notes := []
	if not await _wait_for_tunnel_visual_ready(
		backend,
		"before tunnel transient crawl edits",
		initial_notes,
		Vector3.INF,
		-1.0,
		"edit_tunnel_transient_crawl_gate"
	):
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
				_fail("failed to add tunnel transient crawl operation %d" % operation_index)
				return false
			operation_index += 1
		if not bool(terrain_world.call("submit_edit_batch", batch, 9621)):
			last_tunnel_summary["error"] = "edit_batch_rejected"
			last_tunnel_summary["failed_operation"] = operation_index
			last_tunnel_summary["last_error"] = str(terrain_world.call("get_last_error"))
			_fail("tunnel transient crawl edit batch rejected: %s" % str(terrain_world.call("get_last_error")))
			return false
		if not await game_world.wait_for_world_revision(before_revision + 1):
			last_tunnel_summary["error"] = "revision_not_committed"
			last_tunnel_summary["failed_operation"] = operation_index
			_fail("tunnel transient crawl edit batch did not commit")
			return false
		for _frame in range(2):
			await get_tree().process_frame

	var start_notes := []
	var start_center: Vector3 = first_step.get("probe_center", _tunnel_gate_center())
	var start_radius := float(first_step.get("probe_radius", _tunnel_crawl_probe_radius()))
	await _set_capture_camera_pose(first_step.get("position", player.global_position), first_step.get("target", _tunnel_gate_center()))
	if not await _wait_for_tunnel_visual_ready(
		backend,
		"tunnel transient crawl start",
		start_notes,
		start_center,
		start_radius,
		"edit_tunnel_transient_crawl_gate",
		true
	):
		last_tunnel_summary["error"] = "start_visual_not_ready"
		return false

	var baseline_snapshot := await _collect_edit_persistence_snapshot(terrain_world, "tunnel transient crawl baseline")
	if not bool(baseline_snapshot.get("ok", false)):
		last_tunnel_summary["error"] = "baseline_snapshot_failed"
		return false
	if int(baseline_snapshot.get("air_sample_count", 0)) <= 0:
		last_tunnel_summary["error"] = "no_carved_air_samples"
		_fail("tunnel transient crawl gate did not sample carved air")
		return false

	var transient_probe_summaries := []
	for step in path:
		var step_summary := await _exercise_tunnel_transient_crawl_step(
			backend,
			step,
			"edit_tunnel_transient_crawl_gate"
		)
		transient_probe_summaries.append(step_summary)
		if not bool(step_summary.get("ok", false)):
			last_tunnel_summary["error"] = "transient_probe_failed"
			last_tunnel_summary["failed_step"] = step_summary
			_fail("tunnel transient crawl probe failed: %s" % JSON.stringify(step_summary))
			return false
		var after_step_snapshot := await _collect_edit_persistence_snapshot(
			terrain_world,
			"tunnel transient crawl after %s" % str(step.get("label", "step"))
		)
		if not bool(after_step_snapshot.get("ok", false)):
			last_tunnel_summary["error"] = "after_step_snapshot_failed"
			return false
		if not _compare_edit_persistence_snapshots(baseline_snapshot, after_step_snapshot):
			last_tunnel_summary["error"] = "persistence_changed"
			last_tunnel_summary["persistence"] = last_edit_persistence_summary.duplicate(true)
			return false

	var runtime_summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
	var exact_region := _edited_exact_region_contract_summary(
		runtime_summary,
		_tunnel_crawl_probe_radius()
	)
	if not bool(exact_region.get("ok", false)):
		last_tunnel_summary = {
			"enabled": true,
			"ok": false,
			"profile": str(selected_profile),
			"operation_count": operations.size(),
			"gate_mode": "edit_tunnel_transient_crawl_gate",
			"error": "edited_exact_region_not_retained",
			"edited_exact_region": exact_region,
		}
		_fail("tunnel transient crawl exact-region contract failed: %s" % JSON.stringify(exact_region))
		return false
	last_tunnel_summary = {
		"enabled": true,
		"ok": true,
		"profile": str(selected_profile),
		"operation_count": operations.size(),
		"batch_size": batch_size,
		"gate_mode": "edit_tunnel_transient_crawl_gate",
		"start_settle_notes": start_notes,
		"transient_probe_frames": _tunnel_transient_probe_frames(),
		"transient_probe_summaries": transient_probe_summaries,
		"sample_count": int(last_edit_persistence_summary.get("sample_count", 0)),
		"air_sample_count": int(baseline_snapshot.get("air_sample_count", 0)),
		"density_mismatches": int(last_edit_persistence_summary.get("density_mismatches", -1)),
		"material_mismatches": int(last_edit_persistence_summary.get("material_mismatches", -1)),
		"max_abs_density_delta": float(last_edit_persistence_summary.get("max_abs_density_delta", -1.0)),
		"edited_exact_region": exact_region,
		"render_resources": int(runtime_summary.get("render_resources", 0)),
		"collision_resources": int(runtime_summary.get("collision_resources", 0)),
		"active_chunk_records": int(runtime_summary.get("active_chunk_records", 0)),
	}
	if material_applicator != null:
		material_applicator.call("apply_materials_now")
	interaction_inspection_applied = true
	return true


func _run_tunnel_gate_path(
	terrain_world: Node,
	path: Array,
	probe_mode_prefix: String,
	gate_label: String
) -> bool:
	if player == null or game_world == null:
		_fail("%s requires player and game world" % gate_label)
		return false
	var backend: Node = terrain_world.call("get_backend_terrain")
	if backend == null:
		_fail("%s backend unavailable" % gate_label)
		return false
	var operations := _tunnel_gate_operations()
	edit_persistence_operations = operations.duplicate()
	interaction_inspection_operation_count = operations.size()
	last_tunnel_summary = {
		"enabled": true,
		"ok": false,
		"profile": str(selected_profile),
		"operation_count": operations.size(),
		"gate_mode": probe_mode_prefix,
	}
	if operations.is_empty():
		last_tunnel_summary["error"] = "no_operations"
		_fail("%s produced no operations" % gate_label)
		return false
	if path.is_empty():
		last_tunnel_summary["error"] = "empty_path"
		_fail("%s produced no camera path" % gate_label)
		return false
	var first_step: Dictionary = path[0]
	await _set_capture_camera_pose(first_step.get("position", player.global_position), first_step.get("target", _tunnel_gate_center()))
	if player == null:
		last_tunnel_summary["error"] = "initial_camera_failed"
		return false
	var initial_notes := []
	if not await _wait_for_tunnel_visual_ready(
		backend,
		"before %s edits" % gate_label,
		initial_notes,
		Vector3.INF,
		-1.0,
		probe_mode_prefix
	):
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
				_fail("failed to add %s operation %d" % [gate_label, operation_index])
				return false
			operation_index += 1
		if not bool(terrain_world.call("submit_edit_batch", batch, 9619)):
			last_tunnel_summary["error"] = "edit_batch_rejected"
			last_tunnel_summary["failed_operation"] = operation_index
			last_tunnel_summary["last_error"] = str(terrain_world.call("get_last_error"))
			_fail("%s edit batch rejected: %s" % [gate_label, str(terrain_world.call("get_last_error"))])
			return false
		if not await game_world.wait_for_world_revision(before_revision + 1):
			last_tunnel_summary["error"] = "revision_not_committed"
			last_tunnel_summary["failed_operation"] = operation_index
			_fail("%s edit batch did not commit" % gate_label)
			return false
		for _frame in range(2):
			await get_tree().process_frame

	var preload_summaries := []
	for step in path:
		var preload_label := str(step.get("label", "step"))
		await _set_capture_camera_pose(step.get("position", player.global_position), step.get("target", _tunnel_gate_center()))
		var preload_notes := []
		var preload_center: Vector3 = step.get("probe_center", _tunnel_gate_center())
		var preload_radius := float(step.get("probe_radius", _tunnel_probe_radius()))
		if not await _wait_for_tunnel_visual_ready(
			backend,
			"%s preload %s" % [gate_label, preload_label],
			preload_notes,
			preload_center,
			preload_radius,
			probe_mode_prefix,
			true
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
		_fail("%s did not sample carved air" % gate_label)
		return false

	var probe_summaries := []
	for step in path:
		var step_summary := await _exercise_tunnel_step(
			backend,
			step,
			probe_mode_prefix,
			bool(step.get("save_capture", false))
		)
		probe_summaries.append(step_summary)
		if not bool(step_summary.get("ok", false)):
			last_tunnel_summary["error"] = "tunnel_probe_failed"
			last_tunnel_summary["failed_step"] = step_summary
			_fail("%s probe failed: %s" % [gate_label, JSON.stringify(step_summary)])
			return false
		var after_step_snapshot := await _collect_edit_persistence_snapshot(
			terrain_world,
			"%s after %s" % [gate_label, str(step.get("label", "step"))]
		)
		if not bool(after_step_snapshot.get("ok", false)):
			last_tunnel_summary["error"] = "after_step_snapshot_failed"
			return false
		if not _compare_edit_persistence_snapshots(baseline_snapshot, after_step_snapshot):
			last_tunnel_summary["error"] = "persistence_changed"
			last_tunnel_summary["persistence"] = last_edit_persistence_summary.duplicate(true)
			return false

	var runtime_summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
	var exact_region := _edited_exact_region_contract_summary(
		runtime_summary,
		_declared_exact_region_radius_for_mode(probe_mode_prefix)
	)
	if not bool(exact_region.get("ok", false)):
		last_tunnel_summary = {
			"enabled": true,
			"ok": false,
			"profile": str(selected_profile),
			"operation_count": operations.size(),
			"gate_mode": probe_mode_prefix,
			"error": "edited_exact_region_not_retained",
			"edited_exact_region": exact_region,
		}
		_fail("%s exact-region contract failed: %s" % [gate_label, JSON.stringify(exact_region)])
		return false
	last_tunnel_summary = {
		"enabled": true,
		"ok": true,
		"profile": str(selected_profile),
		"operation_count": operations.size(),
		"batch_size": batch_size,
		"gate_mode": probe_mode_prefix,
		"preload_summaries": preload_summaries,
		"probe_summaries": probe_summaries,
		"sample_count": int(last_edit_persistence_summary.get("sample_count", 0)),
		"air_sample_count": int(baseline_snapshot.get("air_sample_count", 0)),
		"density_mismatches": int(last_edit_persistence_summary.get("density_mismatches", -1)),
		"material_mismatches": int(last_edit_persistence_summary.get("material_mismatches", -1)),
		"max_abs_density_delta": float(last_edit_persistence_summary.get("max_abs_density_delta", -1.0)),
		"edited_exact_region": exact_region,
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


func _tunnel_crawl_path() -> Array:
	var path: Array = []
	var center: Vector3 = _tunnel_gate_center()
	var direction: Vector3 = _tunnel_gate_direction()
	var main_spacing: float = 1.25 if selected_profile == FLAT_PROFILE else 1.45
	var main_half_length: float = float(42 - 1) * main_spacing * 0.5
	var main_start: float = -main_half_length + 3.0
	var main_end: float = main_half_length - 3.0
	for index in range(9):
		var main_ratio: float = float(index) / 8.0
		var main_distance: float = main_start + (main_end - main_start) * main_ratio
		var main_target_distance: float = min(main_distance + 5.0, main_half_length - 1.0)
		if main_target_distance <= main_distance + 0.1:
			main_target_distance = max(main_distance - 5.0, -main_half_length + 1.0)
		var main_centerline: Vector3 = center + direction * main_distance
		path.append({
			"label": "main_crawl_%02d" % index,
			"position": main_centerline + Vector3(0.0, 0.45, 0.0),
			"target": center + direction * main_target_distance + Vector3(0.0, 0.30, 0.0),
			"probe_center": main_centerline,
			"probe_radius": _tunnel_crawl_probe_radius(),
			"save_capture": true,
		})

	var descending_start: Vector3 = _tunnel_descending_start()
	var descending_direction: Vector3 = _tunnel_descending_direction()
	var descending_length: float = float(_tunnel_descending_step_count() - 1) * _tunnel_descending_spacing()
	var descending_start_distance: float = 3.0
	var descending_end_distance: float = max(descending_start_distance + 1.0, descending_length - 3.0)
	for index in range(7):
		var descending_ratio: float = float(index) / 6.0
		var descending_distance: float = descending_start_distance + (descending_end_distance - descending_start_distance) * descending_ratio
		var descending_target_distance: float = min(descending_distance + 3.8, descending_length)
		if descending_target_distance <= descending_distance + 0.1:
			descending_target_distance = max(descending_distance - 3.8, 0.0)
		var descending_centerline: Vector3 = descending_start + descending_direction * descending_distance
		path.append({
			"label": "descending_crawl_%02d" % index,
			"position": descending_centerline + Vector3(0.0, 0.22, 0.0),
			"target": descending_start + descending_direction * descending_target_distance + Vector3(0.0, 0.15, 0.0),
			"probe_center": descending_centerline,
			"probe_radius": _tunnel_crawl_probe_radius(),
			"save_capture": true,
		})
	return path


func _tunnel_upward_lod_path() -> Array:
	var center: Vector3 = _tunnel_gate_center()
	var descending_start: Vector3 = _tunnel_descending_start()
	var descending_direction: Vector3 = _tunnel_descending_direction()
	var descending_length: float = float(_tunnel_descending_step_count() - 1) * _tunnel_descending_spacing()
	var descending_mid: Vector3 = descending_start + descending_direction * descending_length * 0.52
	var descending_deep: Vector3 = descending_start + descending_direction * descending_length * 0.82
	var probe_radius := _tunnel_descending_probe_radius()
	return [
		{
			"label": "close_descending",
			"position": descending_mid - descending_direction * 4.0 + Vector3(0.0, 1.2, 0.0),
			"target": descending_mid + descending_direction * 6.0,
			"probe_center": descending_mid,
			"probe_radius": probe_radius,
			"save_capture": true,
		},
		{
			"label": "surface_oblique",
			"position": descending_start + Vector3(-28.0, 23.0, -44.0),
			"target": descending_mid,
			"probe_center": descending_mid,
			"probe_radius": probe_radius,
			"save_capture": true,
		},
		{
			"label": "upward_low",
			"position": descending_mid + Vector3(-42.0, 76.0, -64.0),
			"target": descending_mid,
			"probe_center": descending_mid,
			"probe_radius": probe_radius,
			"save_capture": true,
		},
		{
			"label": "upward_mid",
			"position": descending_mid + Vector3(-72.0, 138.0, -108.0),
			"target": descending_mid,
			"probe_center": descending_mid,
			"probe_radius": probe_radius,
			"save_capture": true,
		},
		{
			"label": "upward_high",
			"position": descending_mid + Vector3(-118.0, 238.0, -172.0),
			"target": descending_mid,
			"probe_center": descending_mid,
			"probe_radius": probe_radius,
			"save_capture": true,
		},
		{
			"label": "deep_return",
			"position": descending_deep - descending_direction * 7.0 + Vector3(0.0, 1.1, 0.0),
			"target": descending_deep + descending_direction * 4.0,
			"probe_center": descending_deep,
			"probe_radius": probe_radius,
			"save_capture": true,
		},
	]


func _set_tunnel_camera(label: String) -> bool:
	for step in _tunnel_gate_path():
		if str(step.get("label", "")) == label:
			await _set_capture_camera_pose(step.get("position", player.global_position), step.get("target", _tunnel_gate_center()))
			return true
	return false


func _exercise_tunnel_step(
	backend: Node,
	step: Dictionary,
	probe_mode_prefix: String = "edit_tunnel_gate",
	save_capture: bool = false
) -> Dictionary:
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
		probe_radius,
		probe_mode_prefix,
		true
	):
		var summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
		return {
			"ok": false,
			"label": label,
			"error": "visual_not_ready",
			"summary": summary,
			"settle_notes": notes,
		}
	if save_capture and not _save_tunnel_step_capture(label):
		return {
			"ok": false,
			"label": label,
			"error": "step_capture_failed",
			"settle_notes": notes,
		}
	var probe := WatertightnessProbe.collect(
		backend,
		"%s_%s" % [probe_mode_prefix, label],
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


func _exercise_tunnel_transient_crawl_step(
	backend: Node,
	step: Dictionary,
	probe_mode_prefix: String
) -> Dictionary:
	var label := str(step.get("label", "step"))
	var probe_center: Vector3 = step.get("probe_center", _tunnel_gate_center())
	var probe_radius := float(step.get("probe_radius", _tunnel_crawl_probe_radius()))
	await _set_capture_camera_pose_with_wait(
		step.get("position", player.global_position),
		step.get("target", _tunnel_gate_center()),
		0
	)
	var frame_probes := []
	var frame_indices: Array = _tunnel_transient_probe_frames()
	var current_frame := 0
	var capture_saved := false
	for frame_value in frame_indices:
		var target_frame := int(frame_value)
		while current_frame < target_frame:
			await get_tree().process_frame
			current_frame += 1
		var runtime_summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
		var probe := WatertightnessProbe.collect(
			backend,
			"%s_%s_frame_%02d" % [probe_mode_prefix, label, target_frame],
			probe_center,
			probe_radius
		)
		var digest := _open_gap_probe_digest(probe)
		digest["ok"] = _is_open_gap_free_probe(probe)
		digest["label"] = label
		digest["frame"] = target_frame
		digest["queued_render"] = int(runtime_summary.get("queued_render", 0))
		digest["queued_collision"] = int(runtime_summary.get("queued_collision", 0))
		digest["scheduler_queued_jobs"] = int(runtime_summary.get("scheduler_queued_jobs", 0))
		digest["pending_chunk_retirements"] = int(runtime_summary.get("pending_chunk_retirements", 0))
		digest["render_resources"] = int(runtime_summary.get("render_resources", 0))
		digest["collision_resources"] = int(runtime_summary.get("collision_resources", 0))
		digest["active_chunk_records"] = int(runtime_summary.get("active_chunk_records", 0))
		frame_probes.append(digest)
		if target_frame == 1:
			capture_saved = _save_tunnel_step_capture("transient_%s_frame_%02d" % [label, target_frame])
			if not capture_saved:
				return {
					"ok": false,
					"label": label,
					"error": "step_capture_failed",
					"frame_probes": frame_probes,
				}
		if not bool(digest.get("ok", false)):
			_save_diagnostic_failure_capture("transient_%s_frame_%02d" % [label, target_frame])
			digest["error"] = "transient_open_gap_or_orientation_conflict"
			return {
				"ok": false,
				"label": label,
				"failed_frame": target_frame,
				"failed_probe": digest,
				"frame_probes": frame_probes,
			}
	return {
		"ok": true,
		"label": label,
		"capture_saved": capture_saved,
		"frame_probes": frame_probes,
	}


func _tunnel_transient_probe_frames() -> Array:
	return [0, 1, 3, 8, 16, 32]


func _save_tunnel_step_capture(label: String) -> bool:
	if human_visual_capture_path.is_empty():
		return true
	var safe_label := label.replace(" ", "_").replace("/", "_").replace("\\", "_").replace(":", "_")
	var output_path := _capture_variant_path("step_" + safe_label)
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(output_path)
	if error != OK:
		_fail("failed to save tunnel step capture %s to %s" % [label, output_path])
		return false
	return true


func _wait_for_tunnel_visual_ready(
	backend: Node,
	context: String,
	settle_notes: Array,
	probe_center: Vector3 = Vector3.INF,
	probe_radius: float = -1.0,
	probe_mode_prefix: String = "edit_tunnel_gate",
	require_edited_exact_region: bool = false
) -> bool:
	var last_summary := {}
	var last_probe := {}
	var last_exact_region := {}
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
				"%s_visual_ready" % probe_mode_prefix,
				probe_center,
				probe_radius
			)
			last_probe = _open_gap_probe_digest(probe)
			if _is_open_gap_free_probe(probe):
				if require_edited_exact_region:
					var exact_region := _edited_exact_region_contract_summary(summary, probe_radius)
					last_exact_region = exact_region
					if not bool(exact_region.get("ok", false)):
						await get_tree().process_frame
						continue
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
		str({"probe": last_probe, "edited_exact_region": last_exact_region}),
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
		"edges": int(probe.get("edges", -1)),
		"matched_edges": int(probe.get("matched_edges", -1)),
		"maximum_edge_use": int(probe.get("maximum_edge_use", -1)),
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
		"normal_agreement_positive": int(probe.get("normal_agreement_positive", -1)),
		"normal_agreement_negative": int(probe.get("normal_agreement_negative", -1)),
		"normal_agreement_near_zero": int(probe.get("normal_agreement_near_zero", -1)),
		"winding_mixed": bool(probe.get("winding_mixed", false)),
		"winding_minority": int(probe.get("winding_minority", -1)),
		"lod0_triangles_in_region": int(probe.get("lod0_triangles_in_region", -1)),
		"lod0_boundary_edges": int(probe.get("lod0_boundary_edges", -1)),
		"lod0_interior_boundary_edges": int(probe.get("lod0_interior_boundary_edges", -1)),
		"lod0_chunk_face_boundary_edges": int(probe.get("lod0_chunk_face_boundary_edges", -1)),
		"lod0_orientation_conflict_edges": int(probe.get("lod0_orientation_conflict_edges", -1)),
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
	var interaction_result: Dictionary = {
		"ok": true,
		"direct_only": true,
		"operation_count": 0,
		"operations": [],
		"summaries": [],
		"strict_settle_notes": [],
	}
	if not lod_movement_direct_only:
		interaction_result = await _run_lod_movement_player_interactions(terrain_world)
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
	var final_capture_settle_notes := []
	if not await _wait_for_lod_movement_visual_ready(
		backend,
		"after LOD movement gate captures",
		final_capture_settle_notes
	):
		last_lod_movement_summary = {
			"enabled": true,
			"ok": false,
			"profile": str(selected_profile),
			"error": "post_capture_visual_streaming_not_ready",
			"transition_summaries": transition_summaries,
			"final_capture_settle_notes": final_capture_settle_notes,
		}
		return false
	var runtime_summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
	var exact_region := _edited_exact_region_contract_summary(
		runtime_summary,
		_edit_lod_movement_probe_radius()
	)
	if not bool(exact_region.get("ok", false)):
		last_lod_movement_summary = {
			"enabled": true,
			"ok": false,
			"profile": str(selected_profile),
			"error": "edited_exact_region_not_retained",
			"edited_exact_region": exact_region,
			"transition_summaries": transition_summaries,
		}
		_fail("LOD movement exact-region contract failed: %s" % JSON.stringify(exact_region))
		return false
	last_lod_movement_summary = {
		"enabled": true,
		"ok": true,
		"profile": str(selected_profile),
		"direct_only": lod_movement_direct_only,
		"direct_operation_count": operations.size(),
		"interaction_operation_count": interaction_operations.size(),
		"total_operation_count": edit_persistence_operations.size(),
		"mode_counts": mode_counts,
		"interaction_strict_settle_notes": interaction_result.get("strict_settle_notes", []),
		"final_capture_settle_notes": final_capture_settle_notes,
		"sample_count": int(last_edit_persistence_summary.get("sample_count", 0)),
		"density_mismatches": int(last_edit_persistence_summary.get("density_mismatches", -1)),
		"material_mismatches": int(last_edit_persistence_summary.get("material_mismatches", -1)),
		"max_abs_density_delta": float(last_edit_persistence_summary.get("max_abs_density_delta", -1.0)),
		"transition_summaries": transition_summaries,
		"persistence_summaries": persistence_summaries,
		"edited_exact_region": exact_region,
		"render_resources": int(runtime_summary.get("render_resources", 0)),
		"collision_resources": int(runtime_summary.get("collision_resources", 0)),
		"active_chunk_records": int(runtime_summary.get("active_chunk_records", 0)),
	}
	if material_applicator != null:
		material_applicator.call("apply_materials_now")
	interaction_inspection_applied = true
	return true


func _run_edit_multisite_lod_gate(terrain_world: Node) -> bool:
	var backend: Node = terrain_world.call("get_backend_terrain")
	if backend == null:
		_fail("multi-site LOD gate backend unavailable")
		return false
	var site_a_hint := _edit_lod_movement_gate_center()
	var site_a := _resolve_multisite_lod_surface(site_a_hint)
	if is_inf(site_a.x):
		_fail("multi-site LOD gate could not resolve site A surface")
		return false
	var site_a_operations := _edit_multisite_lod_site_operations(site_a, 734591, 0)
	if not await _submit_multisite_lod_operations(terrain_world, site_a_operations, "site A"):
		return false
	var site_b_hint := _edit_multisite_lod_second_site_hint()
	player.global_position = site_b_hint + Vector3(-18.0, 44.0, -42.0)
	player.velocity = Vector3.ZERO
	if not bool(player.call("autonomous_look_at", site_b_hint)):
		_fail("multi-site LOD gate could not aim at site B")
		return false
	if not bool(game_world.update_player_viewer(true)):
		_fail("multi-site LOD gate viewer update failed at site B")
		return false
	if not await _wait_for_current_profile_settled("before multi-site LOD site B edits"):
		return false
	var site_b := _resolve_multisite_lod_surface(site_b_hint)
	if is_inf(site_b.x):
		_fail("multi-site LOD gate could not resolve site B surface")
		return false
	var site_b_operations := _edit_multisite_lod_site_operations(site_b, 184337, 1)
	if not await _submit_multisite_lod_operations(terrain_world, site_b_operations, "site B"):
		return false
	edit_persistence_operations.clear()
	edit_persistence_operations.append_array(site_a_operations)
	edit_persistence_operations.append_array(site_b_operations)
	interaction_inspection_operation_count = edit_persistence_operations.size()
	var baseline_snapshot := await _collect_edit_persistence_snapshot(
		terrain_world,
		"multi-site LOD baseline"
	)
	if not bool(baseline_snapshot.get("ok", false)):
		return false
	var transition_summaries := []
	var persistence_summaries := []
	for site in [
		{"label": "site_b", "center": site_b},
		{"label": "site_a", "center": site_a},
	]:
		var site_label := str(site["label"])
		var center: Vector3 = site["center"]
		for step in _edit_multisite_lod_path(center):
			var transition := await _exercise_multisite_lod_step(
				backend,
				site_label,
				center,
				step
			)
			transition_summaries.append(transition)
			if not bool(transition.get("ok", false)):
				last_multisite_lod_summary = {
					"enabled": true,
					"ok": false,
					"error": "movement_step_failed",
					"failed_step": transition,
					"transition_summaries": transition_summaries,
				}
				_fail("multi-site LOD step failed: %s" % JSON.stringify(transition))
				return false
			var after_snapshot := await _collect_edit_persistence_snapshot(
				terrain_world,
				"multi-site LOD after %s %s" % [site_label, str(step.get("label", "step"))]
			)
			if not bool(after_snapshot.get("ok", false)):
				return false
			if not _compare_edit_persistence_snapshots(baseline_snapshot, after_snapshot):
				last_multisite_lod_summary = {
					"enabled": true,
					"ok": false,
					"error": "persistence_changed_after_multisite_lod",
					"failed_site": site_label,
					"failed_step": str(step.get("label", "step")),
					"persistence": last_edit_persistence_summary,
					"transition_summaries": transition_summaries,
				}
				return false
			persistence_summaries.append({
				"site": site_label,
				"label": str(step.get("label", "step")),
				"sample_count": int(last_edit_persistence_summary.get("sample_count", 0)),
				"density_mismatches": int(last_edit_persistence_summary.get("density_mismatches", -1)),
				"material_mismatches": int(last_edit_persistence_summary.get("material_mismatches", -1)),
				"max_abs_density_delta": float(last_edit_persistence_summary.get("max_abs_density_delta", -1.0)),
			})
	var runtime_summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
	var exact_region := _edited_exact_region_contract_summary(
		runtime_summary,
		_edit_lod_movement_probe_radius(),
		2
	)
	last_multisite_lod_summary = {
		"enabled": true,
		"ok": true,
		"profile": str(selected_profile),
		"site_count": 2,
		"operation_count": edit_persistence_operations.size(),
		"site_a": _vector3_summary(site_a),
		"site_b": _vector3_summary(site_b),
		"sample_count": int(last_edit_persistence_summary.get("sample_count", 0)),
		"density_mismatches": int(last_edit_persistence_summary.get("density_mismatches", -1)),
		"material_mismatches": int(last_edit_persistence_summary.get("material_mismatches", -1)),
		"max_abs_density_delta": float(last_edit_persistence_summary.get("max_abs_density_delta", -1.0)),
		"retention_zones": int(runtime_summary.get("edit_lod_retention_zones", 0)),
		"retention_active_viewers": int(runtime_summary.get("edit_lod_retention_active_viewers", 0)),
		"retention_fallbacks": int(runtime_summary.get("edit_lod_retention_fallbacks", 0)),
		"edited_exact_region": exact_region,
		"pending_chunk_retirements": int(runtime_summary.get("pending_chunk_retirements", 0)),
		"pending_chunk_replacements": int(runtime_summary.get("pending_chunk_replacements", 0)),
		"render_resources": int(runtime_summary.get("render_resources", 0)),
		"collision_resources": int(runtime_summary.get("collision_resources", 0)),
		"transition_summaries": transition_summaries,
		"persistence_summaries": persistence_summaries,
	}
	if int(last_multisite_lod_summary.get("retention_fallbacks", 0)) != 0:
		last_multisite_lod_summary["ok"] = false
		last_multisite_lod_summary["error"] = "retention_fallback"
		_fail("multi-site LOD retention fallback: %s" % JSON.stringify(last_multisite_lod_summary))
		return false
	if not bool(exact_region.get("ok", false)):
		last_multisite_lod_summary["ok"] = false
		last_multisite_lod_summary["error"] = "edited_exact_region_not_retained"
		_fail("multi-site LOD exact-region contract failed: %s" % JSON.stringify(last_multisite_lod_summary))
		return false
	if material_applicator != null:
		material_applicator.call("apply_materials_now")
	interaction_inspection_applied = true
	return true


func _resolve_multisite_lod_surface(hint: Vector3) -> Vector3:
	return _find_collision_surface_near([
		hint,
		hint + Vector3(16.0, 0.0, 0.0),
		hint + Vector3(-16.0, 0.0, 0.0),
		hint + Vector3(0.0, 0.0, 16.0),
		hint + Vector3(0.0, 0.0, -16.0),
	])


func _submit_multisite_lod_operations(
	terrain_world: Node,
	operations: Array,
	label: String
) -> bool:
	for index in range(operations.size()):
		var before_revision := int(terrain_world.call("get_backend_world_revision"))
		var batch = EditBatch.new()
		if not batch.add_operation(operations[index]):
			_fail("failed to add multi-site LOD operation %s %d" % [label, index])
			return false
		if not bool(terrain_world.call("submit_edit_batch", batch, 9301)):
			_fail("multi-site LOD operation %s %d rejected: %s" % [
				label,
				index,
				str(terrain_world.call("get_last_error")),
			])
			return false
		if not await game_world.wait_for_world_revision(before_revision + 1):
			_fail("multi-site LOD operation %s %d did not commit" % [label, index])
			return false
		if index % 16 == 15:
			if not await _wait_for_current_profile_settled("after multi-site LOD %s edit %d" % [label, index]):
				return false
		else:
			for _frame in range(2):
				await get_tree().process_frame
	if not await _wait_for_current_profile_settled("after multi-site LOD %s edits" % label):
		return false
	return true


func _edit_multisite_lod_site_operations(
	center: Vector3,
	seed: int,
	site_index: int
) -> Array:
	var operations: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var horizontal_radius_limit := 22.0
	var vertical_offset_min := -14.0
	var vertical_offset_max := 1.5
	if selected_profile == FLAT_PROFILE:
		horizontal_radius_limit = 9.0
		vertical_offset_min = -2.5
		vertical_offset_max = 2.5
	for index in range(48):
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
		var radius := rng.randf_range(1.4, 3.4)
		if selected_profile == FLAT_PROFILE:
			radius = rng.randf_range(1.2, 2.1)
		if pattern == 8:
			mode = &"construct"
			material_id = 3 + site_index
			radius = rng.randf_range(1.7, 3.8)
			if selected_profile == FLAT_PROFILE:
				radius = rng.randf_range(1.4, 2.4)
		elif pattern == 9:
			mode = &"fill"
			material_id = 5 + site_index
			radius = rng.randf_range(1.6, 3.4)
			if selected_profile == FLAT_PROFILE:
				radius = rng.randf_range(1.4, 2.3)
		elif pattern == 10:
			mode = &"paint"
			material_id = 7 + site_index
			radius = rng.randf_range(1.8, 4.0)
			if selected_profile == FLAT_PROFILE:
				radius = rng.randf_range(1.6, 2.6)
		operations.append(_edit_operation(
			mode,
			center + offset,
			radius,
			material_id,
			1.0
		))
	return operations


func _edit_multisite_lod_path(center: Vector3) -> Array:
	var target := center + Vector3(0.0, -3.0, 0.0)
	return [
		{"label": "close", "position": center + Vector3(-12.0, 18.0, -36.0), "target": target},
		{"label": "mid", "position": center + Vector3(-78.0, 62.0, -164.0), "target": target},
		{"label": "far", "position": center + Vector3(-148.0, 96.0, -324.0), "target": target},
	]


func _exercise_multisite_lod_step(
	backend: Node,
	site_label: String,
	center: Vector3,
	step: Dictionary
) -> Dictionary:
	if player == null or game_world == null:
		return {"ok": false, "site": site_label, "error": "player_or_game_world_unavailable"}
	var label := str(step.get("label", "step"))
	var position: Vector3 = step.get("position", player.global_position)
	var target: Vector3 = step.get("target", center)
	player.global_position = position
	player.velocity = Vector3.ZERO
	if not bool(player.call("autonomous_look_at", target)):
		return {"ok": false, "site": site_label, "label": label, "error": "look_at_failed"}
	if not bool(game_world.update_player_viewer(true)):
		return {"ok": false, "site": site_label, "label": label, "error": "viewer_update_failed"}
	var transient_probe_failures := []
	var transient_frames := [1, 12]
	var max_queued_render := 0
	var max_queued_collision := 0
	var max_pending_retirements := 0
	var max_pending_replacements := 0
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
		max_pending_replacements = maxi(max_pending_replacements, int(summary.get("pending_chunk_replacements", 0)))
		max_render_fading = maxi(max_render_fading, int(summary.get("render_fading_resources", 0)))
		min_render_resources = mini(min_render_resources, int(summary.get("render_resources", 0)))
		min_collision_resources = mini(min_collision_resources, int(summary.get("collision_resources", 0)))
		max_scheduler_jobs = maxi(max_scheduler_jobs, int(summary.get("scheduler_queued_jobs", 0)))
		if transient_frames.has(frame):
			var transient_probe := WatertightnessProbe.collect(
				backend,
				"edit_multisite_lod_gate_%s_%s_frame_%d" % [site_label, label, frame],
				center,
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
					"nonmanifold_interior_edges": int(transient_probe.get("nonmanifold_interior_edges", -1)),
					"nonmanifold_unknown_edges": int(transient_probe.get("nonmanifold_unknown_edges", -1)),
					"zero_area_interior_triangles": int(transient_probe.get("zero_area_interior_triangles", -1)),
					"zero_area_unknown_triangles": int(transient_probe.get("zero_area_unknown_triangles", -1)),
					"repeated_point_key_interior_triangles": int(transient_probe.get("repeated_point_key_interior_triangles", -1)),
					"repeated_point_key_unknown_triangles": int(transient_probe.get("repeated_point_key_unknown_triangles", -1)),
					"triangles_in_region": int(transient_probe.get("triangles_in_region", -1)),
					"boundary_examples": transient_probe.get("boundary_examples", []),
					"interior_boundary_examples": transient_probe.get("interior_boundary_examples", []),
					"nonmanifold_examples": transient_probe.get("nonmanifold_examples", []),
				})
	var strict_settle_notes := []
	if not await _wait_for_lod_movement_visual_ready(
		backend,
		"after multi-site LOD %s %s" % [site_label, label],
		strict_settle_notes,
		center,
		_edit_lod_movement_probe_radius()
	):
		var timeout_summary: Dictionary = game_world.get_game_world_summary()
		return {
			"ok": false,
			"site": site_label,
			"label": label,
			"error": "visual_streaming_not_ready",
			"summary": timeout_summary,
		}
	var settled_probe := WatertightnessProbe.collect(
		backend,
		"edit_multisite_lod_gate_%s_%s_settled" % [site_label, label],
		center,
		_edit_lod_movement_probe_radius()
	)
	if not _is_lod_movement_probe_ready(settled_probe):
		return {
			"ok": false,
			"site": site_label,
			"label": label,
			"error": "settled_watertightness_failure",
			"settled_probe": settled_probe,
		}
	return {
		"ok": true,
		"site": site_label,
		"label": label,
		"max_queued_render": max_queued_render,
		"max_queued_collision": max_queued_collision,
		"max_pending_retirements": max_pending_retirements,
		"max_pending_replacements": max_pending_replacements,
		"max_render_fading_resources": max_render_fading,
		"max_scheduler_queued_jobs": max_scheduler_jobs,
		"min_render_resources": min_render_resources,
		"min_collision_resources": min_collision_resources,
		"strict_settle_notes": strict_settle_notes,
		"transient_probe_failure_count": transient_probe_failures.size(),
		"transient_probe_failures": transient_probe_failures,
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
		"settled_zero_area_interior_triangles": int(settled_probe.get("zero_area_interior_triangles", -1)),
		"settled_zero_area_unknown_triangles": int(settled_probe.get("zero_area_unknown_triangles", -1)),
		"settled_repeated_point_key_interior_triangles": int(settled_probe.get("repeated_point_key_interior_triangles", -1)),
		"settled_repeated_point_key_unknown_triangles": int(settled_probe.get("repeated_point_key_unknown_triangles", -1)),
		"settled_zero_edge_triangles": int(settled_probe.get("zero_edge_triangles", -1)),
		"settled_triangles_in_region": int(settled_probe.get("triangles_in_region", -1)),
	}


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


func _run_post_edit_streaming_fly_gap_gate() -> bool:
	var terrain_world: Node = game_world.get_terrain_world() if game_world != null else null
	if terrain_world == null:
		_fail("post-edit streaming fly gap gate requires terrain world")
		return false
	var operations := _post_edit_streaming_fly_operations()
	if operations.is_empty():
		_fail("post-edit streaming fly gap gate produced no operations")
		return false
	if not await _submit_post_edit_streaming_fly_operations(terrain_world, operations):
		return false
	if not await _wait_for_streaming_fly_visual_ready(
		"after post-edit streaming fly operations",
		maxi(240, human_visual_capture_wait_frames)
	):
		return false
	edit_persistence_operations = operations.duplicate()
	interaction_inspection_operation_count = operations.size()
	interaction_inspection_applied = true
	return await _run_streaming_fly_gap_gate(true)


func _run_streaming_fly_gap_gate(post_edit: bool = false) -> bool:
	if player == null or game_world == null:
		_fail("streaming fly gap gate requires player and game world")
		return false
	var camera := player.get_node_or_null("FirstPersonCamera") as Camera3D
	if camera == null:
		_fail("streaming fly gap gate requires camera")
		return false
	if player.has_method("set_human_input_enabled"):
		player.call("set_human_input_enabled", false)
	if player.has_method("set_fly_mode_enabled"):
		player.call("set_fly_mode_enabled", false)
	camera.fov = 75.0
	camera.far = 5000.0
	var path := _post_edit_streaming_fly_gap_path() if post_edit else _streaming_fly_gap_path()
	if path.size() < 2:
		_fail("streaming fly gap path is empty")
		return false
	await _set_capture_camera_pose_with_wait(
		path[0].get("position", player.global_position),
		path[0].get("target", _watertightness_probe_center()),
		16 if post_edit else 120
	)
	if not await _wait_for_streaming_fly_visual_ready(
		"before streaming fly gap gate",
		maxi(240, human_visual_capture_wait_frames)
	):
		return false
	var samples := []
	var failures := []
	var max_pending_retirements := 0
	var max_pending_replacements := 0
	var max_staged_render := 0
	var max_queued_render := 0
	var max_scheduler_jobs := 0
	var min_render_resources := 9223372036854775807
	var min_visual_ready_records := 9223372036854775807
	var min_non_retiring_visual_ready_records := 9223372036854775807
	var max_non_retiring_visual_deficit := 0
	var max_pending_retirement_records_missing := 0
	var max_render_fading_resources := 0
	var sample_index := 0
	var terrain_world_for_probe: Node = game_world.get_terrain_world() if game_world != null else null
	var backend_for_probe: Node = null
	if terrain_world_for_probe != null and terrain_world_for_probe.has_method("get_backend_terrain"):
		backend_for_probe = terrain_world_for_probe.call("get_backend_terrain")
	for segment_index in range(1, path.size()):
		var previous: Dictionary = path[segment_index - 1]
		var current: Dictionary = path[segment_index]
		var frames := int(current.get("frames", 48))
		var gap_sensitive := bool(current.get("gap_sensitive", true))
		var gap_sensitive_start_frame := int(current.get("gap_sensitive_start_frame", 0))
		for frame in range(frames + 1):
			var t := 0.0 if frames <= 0 else float(frame) / float(frames)
			var position: Vector3 = previous.get("position", player.global_position).lerp(
				current.get("position", player.global_position),
				t
			)
			var target: Vector3 = previous.get("target", _watertightness_probe_center()).lerp(
				current.get("target", _watertightness_probe_center()),
				t
			)
			player.global_position = position
			player.velocity = Vector3.ZERO
			camera.look_at_from_position(position, target, Vector3.UP)
			camera.current = true
			camera.make_current()
			if game_world != null and game_world.has_method("update_player_viewer"):
				game_world.call("update_player_viewer", false)
			await get_tree().process_frame
			var summary: Dictionary = game_world.get_game_world_summary()
			max_pending_retirements = maxi(
				max_pending_retirements,
				int(summary.get("pending_chunk_retirements", 0))
			)
			max_pending_replacements = maxi(
				max_pending_replacements,
				int(summary.get("pending_chunk_replacements", 0))
			)
			max_staged_render = maxi(
				max_staged_render,
				int(summary.get("staged_render_resources", 0))
			)
			max_queued_render = maxi(max_queued_render, int(summary.get("queued_render", 0)))
			max_scheduler_jobs = maxi(
				max_scheduler_jobs,
				int(summary.get("scheduler_queued_jobs", 0))
			)
			min_render_resources = mini(
				min_render_resources,
				int(summary.get("render_resources", 0))
			)
			min_visual_ready_records = mini(
				min_visual_ready_records,
				int(summary.get("visual_ready_chunk_records", 0))
			)
			min_non_retiring_visual_ready_records = mini(
				min_non_retiring_visual_ready_records,
				int(summary.get(
					"non_retiring_visual_ready_chunk_records",
					summary.get("visual_ready_chunk_records", 0)
				))
			)
			max_non_retiring_visual_deficit = maxi(
				max_non_retiring_visual_deficit,
				_streaming_fly_non_retiring_visual_deficit(summary)
			)
			max_pending_retirement_records_missing = maxi(
				max_pending_retirement_records_missing,
				int(summary.get("pending_retirement_records_missing", 0))
			)
			max_render_fading_resources = maxi(
				max_render_fading_resources,
				int(summary.get("render_fading_resources", 0))
			)
			if frame == 0 and segment_index > 1:
				continue
			if not _streaming_fly_should_sample_frame(frame, frames, post_edit):
				continue
			var sample_gap_sensitive := gap_sensitive and frame >= gap_sensitive_start_frame
			var image := get_viewport().get_texture().get_image()
			var sky := _screen_sky_pixel_summary(image, 4 if post_edit else 1)
			var visual_gap := sample_gap_sensitive and _streaming_fly_sky_gap_detected(sky, post_edit)
			var coverage_gap := sample_gap_sensitive and _streaming_fly_coverage_gap_detected(summary)
			var geometry_probe := {}
			var geometry_gap := false
			var run_geometry_probe := sample_gap_sensitive and (
				visual_gap or coverage_gap or _streaming_fly_should_probe_geometry_frame(frame, frames)
			)
			if run_geometry_probe:
				var probe_center := _find_collision_surface_near([
					target,
					target + Vector3(16.0, 0.0, 0.0),
					target + Vector3(-16.0, 0.0, 0.0),
					target + Vector3(0.0, 0.0, 16.0),
					target + Vector3(0.0, 0.0, -16.0),
				])
				if is_inf(probe_center.x):
					geometry_gap = true
					geometry_probe = {
						"ok": false,
						"error": "surface_unresolved",
						"triangles_in_region": 0,
						"center": _vector3_summary(target),
						"radius": 48.0,
					}
				else:
					geometry_probe = WatertightnessProbe.collect(
						backend_for_probe,
						"post_edit_streaming_fly_%02d" % sample_index,
						probe_center,
						48.0
					)
					geometry_gap = not _is_open_gap_free_probe(geometry_probe)
			var gap := visual_gap or coverage_gap or geometry_gap
			var label := "%02d_%s_f%03d" % [
				sample_index,
				str(current.get("label", "segment")),
				frame,
			]
			var capture_path := _capture_variant_path("streaming_fly_" + label)
			var save_capture := gap or _streaming_fly_should_save_capture_frame(frame, frames)
			var image_error := OK
			if save_capture:
				image_error = image.save_png(capture_path)
			else:
				capture_path = ""
			var sample := {
				"label": label,
				"segment": str(current.get("label", "segment")),
				"frame": frame,
				"position": _vector3_summary(position),
				"target": _vector3_summary(target),
				"gap_detected": gap,
				"visual_gap_detected": visual_gap,
				"coverage_gap_detected": coverage_gap,
				"geometry_gap_detected": geometry_gap,
				"gap_sensitive": sample_gap_sensitive,
				"capture_path": capture_path,
				"capture_saved": save_capture and image_error == OK,
				"sky": sky,
				"geometry_probe": _open_gap_probe_digest(geometry_probe) if not geometry_probe.is_empty() else {},
				"active_chunk_records": int(summary.get("active_chunk_records", 0)),
				"visual_ready_chunk_records": int(summary.get("visual_ready_chunk_records", 0)),
				"fully_ready_chunk_records": int(summary.get("fully_ready_chunk_records", 0)),
				"non_retiring_chunk_records": int(summary.get("non_retiring_chunk_records", 0)),
				"non_retiring_visual_ready_chunk_records": int(summary.get("non_retiring_visual_ready_chunk_records", 0)),
				"non_retiring_fully_ready_chunk_records": int(summary.get("non_retiring_fully_ready_chunk_records", 0)),
				"non_retiring_visual_deficit": _streaming_fly_non_retiring_visual_deficit(summary),
				"pending_retirement_records": int(summary.get("pending_retirement_records", 0)),
				"pending_retirement_records_missing": int(summary.get("pending_retirement_records_missing", 0)),
				"staged_swap_coverage_retained": _streaming_fly_staged_swap_coverage_retained(summary),
				"render_resources": int(summary.get("render_resources", 0)),
				"queued_render": int(summary.get("queued_render", 0)),
				"pending_chunk_retirements": int(summary.get("pending_chunk_retirements", 0)),
				"pending_chunk_replacements": int(summary.get("pending_chunk_replacements", 0)),
				"render_fading_resources": int(summary.get("render_fading_resources", 0)),
				"staged_render_resources": int(summary.get("staged_render_resources", 0)),
				"scheduler_queued_jobs": int(summary.get("scheduler_queued_jobs", 0)),
				"streaming_burst_frames_remaining": int(summary.get("streaming_burst_frames_remaining", 0)),
			}
			if gap:
				var terrain_world: Node = game_world.get_terrain_world() if game_world != null else null
				var backend: Node = null
				if terrain_world != null and terrain_world.has_method("get_backend_terrain"):
					backend = terrain_world.call("get_backend_terrain")
				var sky_pixel_rays := _human_artifact_sky_pixel_rays(sky)
				var render_ray_hits := _human_artifact_render_ray_hits(backend, sky_pixel_rays)
				sample["sky_pixel_rays"] = sky_pixel_rays
				sample["render_ray_hits"] = render_ray_hits
				sample["chunk_neighborhood"] = _human_artifact_chunk_neighborhood(
					terrain_world,
					render_ray_hits
				)
				sample["render_seam_diagnostics"] = _human_artifact_render_seam_diagnostics(
					backend,
					render_ray_hits
				)
			samples.append(sample)
			if gap or image_error != OK:
				failures.append(sample)
				last_streaming_fly_summary = {
					"enabled": true,
					"ok": false,
					"profile": str(selected_profile),
					"sample_count": samples.size(),
					"failure_count": failures.size(),
					"post_edit": post_edit,
					"fail_fast": true,
					"max_pending_chunk_retirements": max_pending_retirements,
					"max_pending_chunk_replacements": max_pending_replacements,
					"max_staged_render_resources": max_staged_render,
					"max_queued_render": max_queued_render,
					"max_scheduler_queued_jobs": max_scheduler_jobs,
					"min_render_resources": min_render_resources,
					"min_visual_ready_chunk_records": min_visual_ready_records,
					"min_non_retiring_visual_ready_chunk_records": min_non_retiring_visual_ready_records,
					"max_non_retiring_visual_deficit": max_non_retiring_visual_deficit,
					"max_pending_retirement_records_missing": max_pending_retirement_records_missing,
					"max_render_fading_resources": max_render_fading_resources,
					"failure_examples": failures.slice(0, mini(4, failures.size())),
					"samples": samples,
					"implementation": "post_edit_streaming_fly_gap_gate_v5_fail_fast" if post_edit else "streaming_fly_gap_gate_v4_fail_fast",
				}
				_write_streaming_fly_summary_json(last_streaming_fly_summary)
				if material_applicator != null:
					material_applicator.call("apply_materials_now")
				_fail(
					"streaming fly gap gate first failure label=%s visual=%s coverage=%s geometry=%s capture=%s" %
					[label, str(visual_gap), str(coverage_gap), str(geometry_gap), capture_path]
				)
				return false
			sample_index += 1
	var ok := failures.is_empty()
	var final_settle_summary := {}
	if ok:
		ok = await _wait_for_streaming_fly_visual_ready(
			"after streaming fly gap gate",
			maxi(240, human_visual_capture_wait_frames)
		)
		final_settle_summary = game_world.get_game_world_summary() if game_world != null else {}
		if material_applicator != null:
			material_applicator.call("apply_materials_now")
	last_streaming_fly_summary = {
		"enabled": true,
		"ok": ok,
		"profile": str(selected_profile),
		"sample_count": samples.size(),
		"failure_count": failures.size(),
		"post_edit": post_edit,
		"max_pending_chunk_retirements": max_pending_retirements,
		"max_pending_chunk_replacements": max_pending_replacements,
		"max_staged_render_resources": max_staged_render,
		"max_queued_render": max_queued_render,
		"max_scheduler_queued_jobs": max_scheduler_jobs,
		"min_render_resources": min_render_resources,
		"min_visual_ready_chunk_records": min_visual_ready_records,
		"min_non_retiring_visual_ready_chunk_records": min_non_retiring_visual_ready_records,
		"max_non_retiring_visual_deficit": max_non_retiring_visual_deficit,
		"max_pending_retirement_records_missing": max_pending_retirement_records_missing,
		"max_render_fading_resources": max_render_fading_resources,
		"failure_examples": failures.slice(0, mini(4, failures.size())),
		"final_settle_summary": {
			"active_chunk_records": int(final_settle_summary.get("active_chunk_records", 0)),
			"visual_ready_chunk_records": int(final_settle_summary.get("visual_ready_chunk_records", 0)),
			"fully_ready_chunk_records": int(final_settle_summary.get("fully_ready_chunk_records", 0)),
			"render_resources": int(final_settle_summary.get("render_resources", 0)),
			"collision_resources": int(final_settle_summary.get("collision_resources", 0)),
			"queued_render": int(final_settle_summary.get("queued_render", 0)),
			"queued_collision": int(final_settle_summary.get("queued_collision", 0)),
			"pending_chunk_retirements": int(final_settle_summary.get("pending_chunk_retirements", 0)),
			"pending_chunk_replacements": int(final_settle_summary.get("pending_chunk_replacements", 0)),
			"staged_render_resources": int(final_settle_summary.get("staged_render_resources", 0)),
			"scheduler_queued_jobs": int(final_settle_summary.get("scheduler_queued_jobs", 0)),
			"scheduler_queued_completions": int(final_settle_summary.get("scheduler_queued_completions", 0)),
		},
		"samples": samples,
		"implementation": "post_edit_streaming_fly_gap_gate_v4" if post_edit else "streaming_fly_gap_gate_v3",
	}
	_write_streaming_fly_summary_json(last_streaming_fly_summary)
	if material_applicator != null:
		material_applicator.call("apply_materials_now")
	if not ok:
		_fail("streaming fly gap gate found visible terrain gaps: %s" % JSON.stringify(last_streaming_fly_summary))
		return false
	return true


func _streaming_fly_should_sample_frame(frame: int, frames: int, post_edit: bool = false) -> bool:
	if post_edit:
		return true
	return frame == 0 or frame == 1 or frame == 3 or frame == 8 or \
		frame == 16 or frame == 32 or frame == frames


func _streaming_fly_should_probe_geometry_frame(frame: int, frames: int) -> bool:
	return frame == 0 or frame == 8 or frame == 16 or frame == 32 or frame == frames


func _streaming_fly_should_save_capture_frame(frame: int, frames: int) -> bool:
	return frame == 0 or frame == 1 or frame == 3 or frame == 8 or \
		frame == 16 or frame == 32 or frame == frames


func _submit_post_edit_streaming_fly_operations(
	terrain_world: Node,
	operations: Array
) -> bool:
	var operation_index := 0
	# This gate models one intentionally edited terrain feature before the
	# streaming/fly pass. Submit it as one transaction so the runtime remeshes
	# the final edited field instead of chasing many intermediate revisions.
	var batch_size := maxi(1, operations.size())
	while operation_index < operations.size():
		var before_revision := int(terrain_world.call("get_backend_world_revision"))
		var batch = EditBatch.new()
		for _local_index in range(batch_size):
			if operation_index >= operations.size():
				break
			if not batch.add_operation(operations[operation_index]):
				_fail("failed to add post-edit streaming fly operation %d" % operation_index)
				return false
			operation_index += 1
		if not bool(terrain_world.call("submit_edit_batch", batch, 9442)):
			_fail("post-edit streaming fly batch rejected at operation %d: %s" % [
				operation_index,
				str(terrain_world.call("get_last_error")),
			])
			return false
		if not await game_world.wait_for_world_revision(before_revision + 1):
			_fail("post-edit streaming fly batch did not commit at operation %d" % operation_index)
			return false
		await get_tree().process_frame
	return true


func _post_edit_streaming_fly_operations() -> Array:
	var operations: Array = []
	var center := _edit_lod_movement_gate_center()
	var rng := RandomNumberGenerator.new()
	rng.seed = 913337 if selected_profile == COMPACT_PROFILE else 913338
	var large_radius := 9.5
	var random_radius_min := 3.0
	var random_radius_max := 7.5
	var horizontal_limit := 24.0
	var depth_step := 3.5
	if selected_profile == FLAT_PROFILE:
		large_radius = 5.5
		random_radius_min = 2.0
		random_radius_max = 4.5
		horizontal_limit = 12.0
		depth_step = 1.5
	for index in range(10):
		var diagonal := Vector3(
			float(index) * 1.8,
			-float(index) * depth_step,
			float(index) * 1.25
		)
		operations.append(_edit_operation(&"carve", center + diagonal, large_radius, 1, 1.0))
	for index in range(56):
		var angle := rng.randf_range(0.0, TAU)
		var distance := rng.randf_range(0.0, horizontal_limit)
		var depth := rng.randf_range(-32.0, 4.0)
		if selected_profile == FLAT_PROFILE:
			depth = rng.randf_range(-8.0, 3.0)
		var offset := Vector3(cos(angle) * distance, depth, sin(angle) * distance)
		var radius := rng.randf_range(random_radius_min, random_radius_max)
		operations.append(_edit_operation(&"carve", center + offset, radius, 1, 1.0))
	return operations


func _wait_for_streaming_fly_visual_ready(context: String, frame_limit: int) -> bool:
	var last_summary := {}
	for _frame in range(frame_limit):
		var summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
		last_summary = summary
		if _is_lod_movement_visual_ready_summary(summary):
			return true
		await get_tree().process_frame
	_fail("streaming fly visual-ready wait failed %s: %s" % [context, str(last_summary)])
	return false


func _wait_for_streaming_fly_start_coverage_ready(context: String, frame_limit: int) -> bool:
	var last_summary := {}
	for _frame in range(frame_limit):
		var summary: Dictionary = game_world.get_game_world_summary() if game_world != null else {}
		last_summary = summary
		if _is_streaming_fly_start_coverage_ready(summary):
			return true
		await get_tree().process_frame
	_fail("streaming fly start coverage wait failed %s: %s" % [context, str(last_summary)])
	return false


func _is_streaming_fly_start_coverage_ready(summary: Dictionary) -> bool:
	if not bool(summary.get("backend_running", summary.get("world_running", true))):
		return false
	if int(summary.get("queued_render", 0)) != 0:
		return false
	if int(summary.get("application_sink_failures", 0)) != 0:
		return false
	if int(summary.get("application_queue_rejections", 0)) != 0:
		return false
	return not _streaming_fly_coverage_gap_detected(summary)


func _streaming_fly_sky_gap_detected(sky: Dictionary, post_edit: bool = false) -> bool:
	if post_edit:
		# In post-edit fly captures the camera intentionally sweeps near the
		# horizon. Terrain-band sky there can be ordinary horizon sky, so treat
		# only center/lower-center leaks as visual gap evidence and leave broad
		# band sky for diagnostics.
		return int(sky.get("lower_center_sky_pixels", 0)) > 256 or \
			int(sky.get("isolated_center_sky_pixels", 0)) > 4 or \
			int(sky.get("isolated_lower_center_sky_pixels", 0)) > 4
	return int(sky.get("crosshair_sky_pixels", 0)) > 0 or \
		int(sky.get("lower_center_sky_pixels", 0)) > 16 or \
		int(sky.get("isolated_center_sky_pixels", 0)) > 4 or \
		int(sky.get("isolated_lower_center_sky_pixels", 0)) > 4 or \
		int(sky.get("isolated_terrain_band_sky_pixels", 0)) > 8


func _streaming_fly_coverage_gap_detected(summary: Dictionary) -> bool:
	var staged_swap_coverage_retained := _streaming_fly_staged_swap_coverage_retained(summary)
	var expected_count := int(summary.get("expected_resource_count", 0))
	if expected_count > 0:
		if int(summary.get("render_resources", 0)) < expected_count:
			return true
		if int(summary.get("visual_ready_chunk_records", 0)) < expected_count and \
				not staged_swap_coverage_retained:
			return true
	if int(summary.get("application_sink_failures", 0)) != 0:
		return true
	if int(summary.get("application_queue_rejections", 0)) != 0:
		return true
	if int(summary.get("pending_retirement_records_missing", 0)) != 0:
		return true
	if int(summary.get("render_fading_resources", 0)) != 0:
		return true
	if _streaming_fly_non_retiring_visual_deficit(summary) != 0 and \
			not staged_swap_coverage_retained:
		return true
	return false


func _streaming_fly_staged_swap_coverage_retained(summary: Dictionary) -> bool:
	if int(summary.get("pending_retirement_records_missing", 0)) != 0:
		return false
	if int(summary.get("pending_retirement_records", 0)) <= 0:
		return false
	return int(summary.get("pending_chunk_retirements", 0)) > 0 or \
		int(summary.get("pending_chunk_replacements", 0)) > 0 or \
		int(summary.get("staged_render_resources", 0)) > 0


func _streaming_fly_non_retiring_visual_deficit(summary: Dictionary) -> int:
	var non_retiring := int(summary.get(
		"non_retiring_chunk_records",
		summary.get("active_chunk_records", 0)
	))
	var non_retiring_visual := int(summary.get(
		"non_retiring_visual_ready_chunk_records",
		summary.get("visual_ready_chunk_records", 0)
	))
	return maxi(0, non_retiring - non_retiring_visual)


func _write_streaming_fly_summary_json(summary: Dictionary) -> void:
	if human_visual_capture_path.is_empty():
		return
	var dot_index := human_visual_capture_path.rfind(".")
	var output_path := human_visual_capture_path + "_streaming_fly.json"
	if dot_index > 0:
		output_path = human_visual_capture_path.substr(0, dot_index) + "_streaming_fly.json"
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if file == null:
		push_error("failed to write streaming fly summary json: %s" % output_path)
		return
	file.store_string(JSON.stringify(summary, "\t"))


func _streaming_fly_gap_path() -> Array:
	if selected_profile == FLAT_PROFILE:
		return [
			{"label": "flat_start", "position": Vector3(920.0, 74.0, 920.0), "target": Vector3(1032.0, 8.0, 1032.0)},
			{"label": "flat_cross", "position": Vector3(1160.0, 74.0, 940.0), "target": Vector3(1040.0, 8.0, 1032.0), "frames": 48},
			{"label": "flat_return", "position": Vector3(980.0, 68.0, 1190.0), "target": Vector3(1040.0, 8.0, 1040.0), "frames": 48},
		]
	return [
		{"label": "mountain_start", "position": Vector3(930.0, 185.0, 850.0), "target": Vector3(1090.0, 78.0, 990.0)},
		{"label": "ridge_cross", "position": Vector3(1140.0, 178.0, 930.0), "target": Vector3(1220.0, 92.0, 1060.0), "frames": 54},
		{"label": "peak_sweep", "position": Vector3(1390.0, 166.0, 1110.0), "target": Vector3(1184.0, 84.0, 1008.0), "frames": 54},
		{"label": "valley_return", "position": Vector3(1040.0, 152.0, 1240.0), "target": Vector3(980.0, 62.0, 1110.0), "frames": 54},
		{"label": "low_slope", "position": Vector3(1184.0, 138.0, 1008.0), "target": Vector3(1212.0, 72.0, 1024.0), "frames": 42},
	]


func _post_edit_streaming_fly_gap_path() -> Array:
	var center := _edit_lod_movement_gate_center()
	if selected_profile == FLAT_PROFILE:
		return [
			{"label": "hole_exit_start", "position": center + Vector3(-10.0, 13.0, -22.0), "target": center + Vector3(4.0, -4.0, 4.0)},
			{"label": "emerge_fast", "position": center + Vector3(68.0, 18.0, -54.0), "target": center + Vector3(112.0, -2.0, -78.0), "frames": 12, "gap_sensitive_start_frame": 5},
			{"label": "surface_sweep_a", "position": center + Vector3(210.0, 22.0, -126.0), "target": center + Vector3(280.0, -3.0, -150.0), "frames": 24, "gap_sensitive_start_frame": 8},
			{"label": "surface_sweep_b", "position": center + Vector3(326.0, 21.0, 72.0), "target": center + Vector3(380.0, -2.0, 96.0), "frames": 24},
			{"label": "far_surface_sweep_a", "position": center + Vector3(470.0, 22.0, -240.0), "target": center + Vector3(540.0, -3.0, -270.0), "frames": 30, "gap_sensitive_start_frame": 4},
			{"label": "far_surface_sweep_b", "position": center + Vector3(-360.0, 24.0, 300.0), "target": center + Vector3(-430.0, -3.0, 330.0), "frames": 36, "gap_sensitive_start_frame": 4},
			{"label": "return_to_hole", "position": center + Vector3(-28.0, 16.0, -30.0), "target": center + Vector3(0.0, -6.0, 0.0), "frames": 20, "gap_sensitive": false},
		]
	return [
		{"label": "hole_exit_start", "position": center + Vector3(-12.0, 18.0, -30.0), "target": center + Vector3(6.0, -12.0, 6.0)},
		{"label": "emerge_fast", "position": center + Vector3(82.0, 24.0, -66.0), "target": center + Vector3(142.0, -4.0, -94.0), "frames": 12, "gap_sensitive_start_frame": 5},
		{"label": "surface_sweep_a", "position": center + Vector3(260.0, 28.0, -145.0), "target": center + Vector3(340.0, 0.0, -170.0), "frames": 24, "gap_sensitive_start_frame": 8},
		{"label": "surface_sweep_b", "position": center + Vector3(350.0, 24.0, 92.0), "target": center + Vector3(410.0, -6.0, 118.0), "frames": 24},
		{"label": "far_surface_sweep_a", "position": center + Vector3(520.0, 30.0, -260.0), "target": center + Vector3(600.0, -10.0, -292.0), "frames": 30, "gap_sensitive_start_frame": 4},
		{"label": "far_surface_sweep_b", "position": center + Vector3(-420.0, 32.0, 330.0), "target": center + Vector3(-500.0, -10.0, 360.0), "frames": 36, "gap_sensitive_start_frame": 4},
		{"label": "surface_return", "position": center + Vector3(56.0, 22.0, 212.0), "target": center + Vector3(-4.0, -12.0, 8.0), "frames": 20},
		{"label": "hole_revisit", "position": center + Vector3(-34.0, 18.0, -28.0), "target": center + Vector3(0.0, -16.0, 0.0), "frames": 20, "gap_sensitive": false},
	]


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
	strict_settle_notes: Array,
	probe_center: Vector3 = Vector3(INF, INF, INF),
	probe_radius: float = -1.0
) -> bool:
	var last_summary := {}
	var last_probe := {}
	var frame_limit := maxi(120, human_visual_capture_wait_frames)
	var center := _edit_lod_movement_gate_center() if is_inf(probe_center.x) else probe_center
	var radius := _edit_lod_movement_probe_radius() if probe_radius < 0.0 else probe_radius
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
				center,
				radius
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
				var exact_region := _edited_exact_region_contract_summary(summary, radius)
				last_probe["edited_exact_region"] = exact_region
				if not bool(exact_region.get("ok", false)):
					await get_tree().process_frame
					continue
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
	if int(summary.get("pending_chunk_replacements", 0)) != 0:
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


func _declared_exact_region_radius_for_mode(mode: String) -> float:
	if mode == "edit_lod_movement_gate" or mode == "edit_multisite_lod_gate":
		return _edit_lod_movement_probe_radius()
	if mode == "edit_manifold_stress_gate":
		return _manifold_stress_probe_radius()
	if mode == "edit_tunnel_crawl_gate" or mode == "edit_tunnel_transient_crawl_gate":
		return _tunnel_crawl_probe_radius()
	if mode == "edit_tunnel_upward_lod_gate":
		return _tunnel_descending_probe_radius()
	if mode == "edit_tunnel_gate" or mode == "human_tunnel_playtest":
		return _tunnel_probe_radius()
	return -1.0


func _edited_exact_region_contract_summary(
	summary: Dictionary,
	declared_radius: float,
	required_active_retention_viewers: int = 1
) -> Dictionary:
	var result := {
		"ok": true,
		"applies": declared_radius > 0.0,
		"implementation": "edited_exact_region_profile_contract_v1",
		"declared_radius": declared_radius,
		"required_active_retention_viewers": required_active_retention_viewers,
		"edit_commit_count": int(summary.get("edit_commit_count", 0)),
		"retention_zones": int(summary.get("edit_lod_retention_zones", 0)),
		"retention_active_viewers": int(summary.get("edit_lod_retention_active_viewers", 0)),
		"retention_plans": int(summary.get("edit_lod_retention_plans", 0)),
		"retention_fallbacks": int(summary.get("edit_lod_retention_fallbacks", 0)),
		"pending_chunk_retirements": int(summary.get("pending_chunk_retirements", 0)),
		"pending_chunk_replacements": int(summary.get("pending_chunk_replacements", 0)),
		"queued_render": int(summary.get("queued_render", 0)),
		"queued_collision": int(summary.get("queued_collision", 0)),
	}
	var failures := []
	if declared_radius <= 0.0:
		result["failures"] = failures
		result["ok"] = true
		return result
	if int(result["edit_commit_count"]) <= 0:
		failures.append("no_committed_edits")
	if required_active_retention_viewers > 0 and \
			int(result["retention_active_viewers"]) < required_active_retention_viewers:
		failures.append("insufficient_active_retention_viewers")
	if int(result["retention_fallbacks"]) != 0:
		failures.append("retention_fallback")
	if int(result["pending_chunk_retirements"]) != 0:
		failures.append("pending_chunk_retirements")
	if int(result["pending_chunk_replacements"]) != 0:
		failures.append("pending_chunk_replacements")
	if int(result["queued_render"]) != 0:
		failures.append("queued_render")
	if int(result["queued_collision"]) != 0:
		failures.append("queued_collision")
	result["failures"] = failures
	result["ok"] = failures.is_empty()
	return result


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
		int(probe.get("orientation_conflict_interior_edges", 0)) == 0 and \
		int(probe.get("orientation_conflict_unknown_edges", 0)) == 0 and \
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
	# This predicate is intentionally limited to open-gap evidence. Orientation
	# conflicts are still captured in probe diagnostics, but they are winding/
	# normal-order problems, not proof that terrain is missing or that sky can
	# leak through the mesh.
	return int(probe.get("interior_boundary_edges", boundary_edges)) == 0 and \
		int(probe.get("unknown_boundary_edges", 0)) == 0 and \
		boundary_edges == chunk_face_boundary_edges and \
		int(probe.get("nonmanifold_edges", -1)) == 0 and \
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
	await _set_capture_camera_pose_with_wait(position, target, 12)


func _set_capture_camera_pose_with_wait(position: Vector3, target: Vector3, wait_frames: int) -> void:
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
	for _frame in range(maxi(0, wait_frames)):
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


func _multisite_lod_summary() -> Dictionary:
	if last_multisite_lod_summary.is_empty():
		return {
			"enabled": false,
			"ok": true,
		}
	return last_multisite_lod_summary


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


func _streaming_fly_summary() -> Dictionary:
	if last_streaming_fly_summary.is_empty():
		return {
			"enabled": false,
			"ok": true,
		}
	return last_streaming_fly_summary


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


func _edit_multisite_lod_second_site_hint() -> Vector3:
	if selected_profile == FLAT_PROFILE:
		return Vector3(1120.0, 12.0, 944.0)
	return Vector3(860.0, 72.0, 1220.0)


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


func _tunnel_crawl_probe_radius() -> float:
	return 10.0 if selected_profile == FLAT_PROFILE else 18.0


func _edit_lod_movement_probe_radius() -> float:
	return 14.0 if selected_profile == FLAT_PROFILE else 56.0


func _manifold_stress_probe_radius() -> float:
	return 18.0 if selected_profile == FLAT_PROFILE else 68.0


func _tunnel_probe_radius() -> float:
	return 24.0 if selected_profile == FLAT_PROFILE else 72.0


func _edit_reload_test_center() -> Vector3:
	if human_visual_capture_mode == "edit_lod_movement_gate":
		return _edit_lod_movement_gate_center()
	if human_visual_capture_mode == "edit_multisite_lod_gate":
		return _edit_lod_movement_gate_center()
	if human_visual_capture_mode == "edit_during_load_oracle":
		return _edit_during_load_oracle_center()
	if human_visual_capture_mode == "edit_manifold_stress_gate":
		return _manifold_stress_center()
	if human_visual_capture_mode == "edit_tunnel_gate" or \
		human_visual_capture_mode == "edit_tunnel_crawl_gate" or \
		human_visual_capture_mode == "edit_tunnel_transient_crawl_gate" or \
		human_visual_capture_mode == "edit_tunnel_upward_lod_gate":
		return _tunnel_gate_center()
	if human_visual_capture_mode == "edit_stability_gate":
		return _edit_stability_gate_center()
	return _watertightness_edit_center()


func _watertightness_probe_center() -> Vector3:
	if human_visual_capture_mode == "edit_lod_movement_gate":
		return _edit_lod_movement_gate_center()
	if human_visual_capture_mode == "edit_multisite_lod_gate":
		return _edit_lod_movement_gate_center()
	if human_visual_capture_mode == "edit_during_load_oracle":
		return _edit_during_load_oracle_center()
	if human_visual_capture_mode == "edit_manifold_stress_gate":
		return _manifold_stress_center()
	if human_visual_capture_mode == "edit_tunnel_gate" or \
		human_visual_capture_mode == "edit_tunnel_crawl_gate" or \
		human_visual_capture_mode == "edit_tunnel_transient_crawl_gate" or \
		human_visual_capture_mode == "edit_tunnel_upward_lod_gate":
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
	if human_visual_capture_mode == "edit_multisite_lod_gate":
		return _edit_lod_movement_probe_radius()
	if human_visual_capture_mode == "edit_during_load_oracle":
		return 14.0 if selected_profile == FLAT_PROFILE else 56.0
	if human_visual_capture_mode == "edit_manifold_stress_gate":
		return _manifold_stress_probe_radius()
	if human_visual_capture_mode == "edit_tunnel_gate" or \
		human_visual_capture_mode == "edit_tunnel_crawl_gate" or \
		human_visual_capture_mode == "edit_tunnel_transient_crawl_gate" or \
		human_visual_capture_mode == "edit_tunnel_upward_lod_gate":
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
		"streaming_ridge_settled":
			capture_position = Vector3(1140.0, 178.0, 930.0)
			capture_target = Vector3(1220.0, 92.0, 1060.0)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"watertight_boundary_near":
			capture_target = _watertightness_edit_center()
			capture_position = capture_target + Vector3(-14.0, 21.0, -58.0)
			player.global_position = capture_position
			player.rotation = Vector3.ZERO
		"watertight_many_small_near", "watertight_rapid_small_near", "watertight_rapid_small_reload_near", "edit_persistence_reload_oracle", "edit_stability_gate", "edit_lod_movement_gate", "edit_multisite_lod_gate", "edit_during_load_oracle", "edit_manifold_stress_gate", "edit_tunnel_gate", "edit_tunnel_crawl_gate", "edit_tunnel_transient_crawl_gate":
			var target_center := _watertightness_edit_center()
			if human_visual_capture_mode == "edit_stability_gate":
				target_center = _edit_stability_gate_center()
			elif human_visual_capture_mode == "edit_lod_movement_gate":
				target_center = _edit_lod_movement_gate_center()
			elif human_visual_capture_mode == "edit_multisite_lod_gate":
				target_center = _edit_lod_movement_gate_center()
			elif human_visual_capture_mode == "edit_during_load_oracle":
				target_center = _edit_during_load_oracle_center()
			elif human_visual_capture_mode == "edit_manifold_stress_gate":
				target_center = _manifold_stress_center()
			elif human_visual_capture_mode == "edit_tunnel_gate" or \
				human_visual_capture_mode == "edit_tunnel_crawl_gate" or \
				human_visual_capture_mode == "edit_tunnel_transient_crawl_gate" or \
				human_visual_capture_mode == "edit_tunnel_upward_lod_gate":
				target_center = _tunnel_gate_center()
			if human_visual_capture_mode == "edit_tunnel_gate" or \
				human_visual_capture_mode == "edit_tunnel_crawl_gate" or \
				human_visual_capture_mode == "edit_tunnel_transient_crawl_gate" or \
				human_visual_capture_mode == "edit_tunnel_upward_lod_gate":
				var tunnel_path := _tunnel_gate_path()
				if human_visual_capture_mode == "edit_tunnel_crawl_gate" or human_visual_capture_mode == "edit_tunnel_transient_crawl_gate":
					tunnel_path = _tunnel_crawl_path()
				elif human_visual_capture_mode == "edit_tunnel_upward_lod_gate":
					tunnel_path = _tunnel_upward_lod_path()
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

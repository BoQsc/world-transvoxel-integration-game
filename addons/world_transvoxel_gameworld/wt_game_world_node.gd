extends Node3D

const ADDON_ID := "world_transvoxel_gameworld"
const API_VERSION := 1
const ReferenceScene := preload("res://addons/world_transvoxel_terrain/debug/wt_terrain_reference_scene.tscn")
const EditOperation := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd")
const EditBatch := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd")

@export var human_input_enabled: bool = false
@export var player_driven_viewer_enabled: bool = true
@export var player_viewer_update_distance: float = 8.0
@export var debug_overlay_enabled: bool = false
@export var startup_requires_cold_idle: bool = true
@export_range(0, 65536, 1) var startup_minimum_render_resources: int = 0
@export_range(0, 65536, 1) var startup_minimum_collision_resources: int = 0
@export_range(0, 65536, 1) var runtime_active_chunk_capacity: int = 0
@export_range(0, 65536, 1) var runtime_demand_capacity_per_viewer: int = 0
@export_range(0, 65536, 1) var runtime_render_entry_capacity: int = 0
@export_range(0, 65536, 1) var runtime_collision_entry_capacity: int = 0
@export_range(0, 65536, 1) var runtime_lod_refinement_radius_chunks: int = 0

var _profile_id: StringName = &""
var _generation_profile: Resource
var _storage_profile: Resource
var _viewer_positions: Array = []
var _viewer_radius_chunks := 0
var _viewer_maximum_lod := 0
var _expected_resource_count := 0
var _player_start_position := Vector3.ZERO
var _reference_scene: Node
var _player: Node
var _viewer_revision := 1000
var _player_viewer_id := 1
var _last_player_viewer_position := Vector3(INF, INF, INF)
var _accepted_player_viewer_updates := 0
var _last_error := ""
var _last_edit_summary := {}
var _last_cold_idle_summary: Dictionary = {}


func configure_game_world(
	profile_id: StringName,
	generation_profile: Resource,
	storage_profile: Resource,
	viewer_positions: Array,
	viewer_radius_chunks: int,
	expected_resource_count: int,
	player_start_position: Vector3,
	viewer_maximum_lod: int = 0
) -> void:
	_profile_id = profile_id
	_generation_profile = generation_profile
	_storage_profile = storage_profile
	_viewer_positions = viewer_positions
	_viewer_radius_chunks = viewer_radius_chunks
	_viewer_maximum_lod = viewer_maximum_lod
	_expected_resource_count = expected_resource_count
	_player_start_position = player_start_position


func setup_standard_world() -> Node:
	if _reference_scene != null:
		return _reference_scene
	_reference_scene = ReferenceScene.instantiate()
	_reference_scene.name = "WtGameWorldTerrain"
	add_child(_reference_scene)
	if _reference_scene.has_method("set_debug_overlay_enabled"):
		_reference_scene.call("set_debug_overlay_enabled", debug_overlay_enabled)
	_reference_scene.ensure_reference_defaults()
	_apply_profiles()
	return _reference_scene


func attach_player(player: Node, start_position: Vector3) -> void:
	_player = player
	if _player.get_parent() == null:
		add_child(_player)
	_player.global_position = start_position
	if _player.has_method("set_human_input_enabled"):
		_player.call("set_human_input_enabled", human_input_enabled)


func start_world() -> bool:
	setup_standard_world()
	if not _reference_scene.start_reference_backend_world():
		return _fail("backend start failed")
	if not await _wait_for_world_state("running"):
		return _fail("terrain world did not reach running state")
	if not _submit_initial_viewers():
		return false
	if _player != null and player_driven_viewer_enabled:
		update_player_viewer(true)
	if startup_requires_cold_idle:
		if not await wait_for_cold_idle(_expected_resource_count, _expected_resource_count):
			return _fail("terrain did not settle: %s" % str(_last_cold_idle_summary))
	else:
		if not await wait_for_minimum_resources(
			startup_minimum_render_resources,
			startup_minimum_collision_resources
		):
			return _fail("terrain did not reach startup minimum resources: %s" % str(_last_cold_idle_summary))
	return true


func update_player_viewer(force: bool = false) -> bool:
	if not player_driven_viewer_enabled or _reference_scene == null or _player == null:
		return false
	var position: Vector3 = _player.global_position
	if not force and not _should_update_player_viewer(position):
		return false
	_viewer_revision += 1
	if not bool(_reference_scene.call(
		"update_reference_viewer", _player_viewer_id, _viewer_revision, position, _viewer_radius_chunks, _viewer_maximum_lod
	)):
		return _fail("player viewer update failed")
	_last_player_viewer_position = position
	_accepted_player_viewer_updates += 1
	return true


func submit_sphere_edit(
	mode_name: StringName,
	center: Vector3,
	radius: float,
	material_id: int = 1,
	density_value: float = 1.0
) -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null:
		return _fail("terrain world unavailable")
	var operation = EditOperation.new()
	operation.mode = _operation_mode(mode_name)
	operation.brush_shape = EditOperation.BrushShape.SPHERE
	operation.center = center
	operation.radius = radius
	operation.material_id = material_id
	operation.density_value = density_value
	var batch = EditBatch.new()
	batch.add_operation(operation)
	var accepted := bool(terrain_world.call("submit_edit_batch", batch, 56056))
	_last_edit_summary = {
		"accepted": accepted,
		"mode": str(mode_name),
		"center": center,
		"radius": radius,
		"material_id": material_id,
		"terrain_summary": terrain_world.call("get_last_edit_submission_summary"),
		"error": str(terrain_world.call("get_last_error")),
	}
	if not accepted:
		_last_error = str(_last_edit_summary.get("error", "edit rejected"))
	return accepted


func wait_for_cold_idle(render_count: int, collision_count: int) -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null:
		return false
	for _frame in range(900):
		var summary: Dictionary = terrain_world.call("get_cold_idle_summary")
		_last_cold_idle_summary = summary
		if bool(summary.get("cold_idle", false)) and \
				int(summary.get("render_resources", -1)) >= render_count and \
				int(summary.get("collision_resources", -1)) >= collision_count:
			await get_tree().process_frame
			return true
		await get_tree().process_frame
	return false


func wait_for_minimum_resources(render_count: int, collision_count: int) -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null:
		return false
	for _frame in range(900):
		var summary: Dictionary = terrain_world.call("get_cold_idle_summary")
		_last_cold_idle_summary = summary
		if bool(summary.get("world_running", false)) and \
				int(summary.get("queued_render", 0)) == 0 and \
				int(summary.get("queued_collision", 0)) == 0 and \
				int(summary.get("render_resources", -1)) >= render_count and \
				int(summary.get("collision_resources", -1)) >= collision_count:
			await get_tree().process_frame
			return true
		await get_tree().process_frame
	return false


func wait_for_world_revision(target_revision: int) -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null:
		return false
	for _frame in range(900):
		if int(terrain_world.call("get_backend_world_revision")) >= target_revision:
			await get_tree().process_frame
			return true
		await get_tree().process_frame
	return false


func get_reference_scene() -> Node:
	return _reference_scene


func get_terrain_world() -> Node:
	if _reference_scene == null or not _reference_scene.has_method("get_terrain_world"):
		return null
	return _reference_scene.call("get_terrain_world")


func get_last_error() -> String:
	return _last_error


func get_last_edit_summary() -> Dictionary:
	return _last_edit_summary


func get_game_world_summary() -> Dictionary:
	var terrain_world := get_terrain_world()
	var metrics: Dictionary = {}
	if terrain_world != null:
		metrics = terrain_world.call("get_runtime_metrics")
	return {
		"addon_id": ADDON_ID,
		"api_version": API_VERSION,
		"profile_id": str(_profile_id),
		"standard_world_node": true,
		"terrain_node_ready": _reference_scene != null and terrain_world != null,
		"player_attached": _player != null,
		"player_human_input_enabled": _player != null and bool(_player.get("human_input_enabled")),
		"player_driven_viewer_enabled": player_driven_viewer_enabled,
		"player_viewer_updates": _accepted_player_viewer_updates,
		"viewer_positions": _viewer_positions.size(),
		"viewer_radius_chunks": _viewer_radius_chunks,
		"viewer_maximum_lod": _viewer_maximum_lod,
		"runtime_demand_capacity_per_viewer": runtime_demand_capacity_per_viewer,
		"runtime_lod_refinement_radius_chunks": runtime_lod_refinement_radius_chunks,
		"expected_resource_count": _expected_resource_count,
		"active_chunk_records": int(metrics.get("active_chunk_records", 0)),
		"render_resources": int(metrics.get("render_resources", 0)),
		"collision_resources": int(metrics.get("collision_resources", 0)),
		"queued_render": int(metrics.get("queued_render", 0)),
		"queued_collision": int(metrics.get("queued_collision", 0)),
		"pending_chunk_retirements": int(metrics.get("pending_chunk_retirements", 0)),
		"render_fading_resources": int(metrics.get("render_fading_resources", 0)),
		"edit_replacements": int(metrics.get("edit_replacements", 0)),
		"last_error": _last_error,
	}


func _apply_profiles() -> void:
	var terrain_world := get_terrain_world()
	if terrain_world == null:
		return
	terrain_world.generation_profile = _generation_profile
	terrain_world.storage_profile = _storage_profile
	terrain_world.runtime_active_chunk_capacity = runtime_active_chunk_capacity
	terrain_world.runtime_demand_capacity_per_viewer = runtime_demand_capacity_per_viewer
	terrain_world.runtime_render_entry_capacity = runtime_render_entry_capacity
	terrain_world.runtime_collision_entry_capacity = runtime_collision_entry_capacity
	terrain_world.runtime_lod_refinement_radius_chunks = runtime_lod_refinement_radius_chunks


func _submit_initial_viewers() -> bool:
	var viewer_id := 1
	for position in _viewer_positions:
		if not bool(_reference_scene.call("update_reference_viewer", viewer_id, viewer_id, position, _viewer_radius_chunks, _viewer_maximum_lod)):
			return _fail("initial viewer update failed: %s" % _terrain_world_error())
		viewer_id += 1
	return viewer_id > 1


func _wait_for_world_state(expected: String) -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null:
		return false
	for _frame in range(900):
		if terrain_world.call("get_world_state_name") == expected:
			await get_tree().process_frame
			return true
		await get_tree().process_frame
	return false


func _should_update_player_viewer(position: Vector3) -> bool:
	if is_inf(_last_player_viewer_position.x):
		return true
	var delta := Vector2(
		position.x - _last_player_viewer_position.x,
		position.z - _last_player_viewer_position.z
	)
	return delta.length() >= player_viewer_update_distance


func _operation_mode(mode_name: StringName) -> int:
	match mode_name:
		&"carve":
			return EditOperation.Mode.CARVE
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


func _fail(message: String) -> bool:
	_last_error = message
	push_error("WT_GAMEWORLD_FAIL: " + message)
	return false


func _terrain_world_error() -> String:
	var terrain_world := get_terrain_world()
	if terrain_world != null and terrain_world.has_method("get_last_error"):
		return str(terrain_world.call("get_last_error"))
	return "terrain world unavailable"

extends Node3D

const ADDON_ID := "world_transvoxel_gameworld"
const API_VERSION := 1
const COLLISION_INVOKER_CHUNK_EXTENT := 16.0
const ReferenceScene := preload("res://addons/world_transvoxel_terrain/debug/wt_terrain_reference_scene.tscn")
const EditOperation := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd")
const EditBatch := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd")

@export var human_input_enabled: bool = false
@export var player_driven_viewer_enabled: bool = true
@export var player_viewer_update_distance: float = 8.0
# The native runtime already keeps the latest queued revision for each viewer.
# Holding the player position here while streaming is busy makes demand stale.
@export var player_viewer_coalesce_while_streaming: bool = false
@export var player_predictive_viewer_enabled: bool = false
@export_range(0.0, 1000000.0, 0.01) var player_predictive_viewer_distance: float = 0.0
@export var player_focus_viewer_enabled: bool = false
@export_range(0.0, 1000000.0, 0.01) var player_focus_viewer_distance: float = 0.0
@export var player_collision_invoker_enabled: bool = false
@export_range(0, 16, 1) var player_collision_invoker_radius_chunks: int = 2
@export_range(0.0, 1000000.0, 0.01) var player_collision_prediction_distance: float = 16.0
@export var debug_overlay_enabled: bool = false
@export var startup_requires_cold_idle: bool = true
@export_range(1, 7200, 1) var startup_world_state_timeout_frames: int = 900
@export_range(0, 65536, 1) var startup_minimum_render_resources: int = 0
@export_range(0, 65536, 1) var startup_minimum_collision_resources: int = 0
@export_range(0, 65536, 1) var runtime_active_chunk_capacity: int = 0
@export_range(0, 1024, 1) var runtime_viewer_capacity: int = 0
@export_range(0, 65536, 1) var runtime_demand_capacity_per_viewer: int = 0
@export_range(0, 65536, 1) var runtime_render_entry_capacity: int = 0
@export_range(0, 65536, 1) var runtime_collision_entry_capacity: int = 0
@export_range(0, 65536, 1) var runtime_lod_refinement_radius_chunks: int = 0
@export_range(0, 128, 1) var runtime_render_apply_budget: int = 0
@export_range(0, 128, 1) var runtime_collision_apply_budget: int = 0
@export_range(0, 240, 1) var runtime_render_transition_frames: int = 0
@export var runtime_shader_fade_parameter_enabled: bool = false
@export var runtime_global_coarse_lod_coverage: bool = false
@export_range(0, 128, 1) var runtime_streaming_burst_render_apply_budget: int = 0
@export_range(0, 128, 1) var runtime_streaming_burst_collision_apply_budget: int = 0
@export_range(0, 600, 1) var runtime_streaming_burst_frames: int = 0
@export_range(0, 128, 1) var runtime_edit_burst_render_apply_budget: int = 0
@export_range(0, 128, 1) var runtime_edit_burst_collision_apply_budget: int = 0
@export_range(0, 600, 1) var runtime_edit_burst_frames: int = 0
@export_range(0.0, 1000000.0, 0.01) var runtime_collision_activation_distance: float = 0.0
@export_range(0.0, 1000000.0, 0.01) var runtime_collision_deactivation_distance: float = 0.0

var _profile_id: StringName = &""
var _terrain_profile: Resource
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
var _player_predictive_viewer_id := 64
var _player_focus_viewer_id := 65
var _player_collision_viewer_id := 66
var _last_player_viewer_position := Vector3(INF, INF, INF)
var _last_predictive_viewer_position := Vector3(INF, INF, INF)
var _last_focus_viewer_position := Vector3(INF, INF, INF)
var _last_collision_viewer_position := Vector3(INF, INF, INF)
var _accepted_player_viewer_updates := 0
var _accepted_predictive_viewer_updates := 0
var _accepted_focus_viewer_updates := 0
var _accepted_collision_viewer_updates := 0
var _coalesced_player_viewer_updates := 0
var _last_player_viewer_coalesce_reason := "none"
var _last_error := ""
var _last_edit_summary := {}
var _last_cold_idle_summary: Dictionary = {}
var _edit_submission_count := 0
var _edit_accept_count := 0
var _edit_commit_count := 0
var _edit_failure_count := 0
var _last_edit_committed_revision := 0
var _last_edit_failure_error := "ok"
var _streaming_burst_frames_remaining := 0


func configure_game_world(
	profile_id: StringName,
	generation_profile: Resource,
	storage_profile: Resource,
	viewer_positions: Array,
	viewer_radius_chunks: int,
	expected_resource_count: int,
	player_start_position: Vector3,
	viewer_maximum_lod: int = 0,
	terrain_profile: Resource = null
) -> void:
	_profile_id = profile_id
	_terrain_profile = terrain_profile
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
	_connect_terrain_world_signals()
	return _reference_scene


func _process(_delta: float) -> void:
	if _streaming_burst_frames_remaining <= 0:
		return
	_streaming_burst_frames_remaining -= 1
	if _streaming_burst_frames_remaining == 0:
		_apply_live_apply_budgets(runtime_render_apply_budget, runtime_collision_apply_budget)


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
		return _fail("backend start failed: %s" % _terrain_world_error())
	if not await _wait_for_world_state("running"):
		return _fail("terrain world did not reach running state: state=%s error=%s timeout_frames=%d" % [
			_terrain_world_state(),
			_terrain_world_error(),
			startup_world_state_timeout_frames,
		])
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
		return true
	if not force and player_viewer_coalesce_while_streaming:
		var coalesce_reason := _player_viewer_streaming_debt_reason()
		if not coalesce_reason.is_empty():
			_coalesced_player_viewer_updates += 1
			_last_player_viewer_coalesce_reason = coalesce_reason
			return true
	var previous_position := _last_player_viewer_position
	_viewer_revision += 1
	if not bool(_reference_scene.call(
		"update_reference_viewer", _player_viewer_id, _viewer_revision, position, _viewer_radius_chunks, _viewer_maximum_lod
	)):
		return _fail("player viewer update failed: %s" % _terrain_world_error())
	_last_player_viewer_position = position
	_accepted_player_viewer_updates += 1
	if not _update_player_collision_invoker(position, previous_position, force):
		return false
	if not _update_predictive_player_viewer(position, previous_position, force):
		return false
	if not _update_focus_player_viewer(force):
		return false
	_begin_streaming_burst()
	return true


func _player_viewer_streaming_debt_reason() -> String:
	var terrain_world := get_terrain_world()
	if terrain_world == null:
		return ""
	var metrics: Dictionary = terrain_world.call("get_runtime_metrics")
	if int(metrics.get("pending_chunk_retirements", 0)) > 0:
		return "pending_chunk_retirements"
	if int(metrics.get("pending_chunk_replacements", 0)) > 0:
		return "pending_chunk_replacements"
	if int(metrics.get("staged_render_resources", 0)) > 0:
		return "staged_render_resources"
	if int(metrics.get("queued_render", 0)) > 0:
		return "queued_render"
	if int(metrics.get("scheduler_queued_completions", 0)) > 0:
		return "scheduler_queued_completions"
	if int(metrics.get("scheduler_queued_jobs", 0)) > 0:
		return "scheduler_queued_jobs"
	if int(metrics.get("scheduler_sampling_records", 0)) > 0:
		return "scheduler_sampling_records"
	if int(metrics.get("scheduler_meshing_records", 0)) > 0:
		return "scheduler_meshing_records"
	var non_retiring_records := int(metrics.get("non_retiring_chunk_records", 0))
	var non_retiring_visual_ready := int(metrics.get("non_retiring_visual_ready_chunk_records", 0))
	if non_retiring_visual_ready < non_retiring_records:
		return "visual_ready_deficit"
	return ""


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
	_edit_submission_count += 1
	var operation = EditOperation.new()
	operation.mode = _operation_mode(mode_name)
	operation.brush_shape = EditOperation.BrushShape.SPHERE
	operation.center = center
	operation.radius = radius
	operation.material_id = material_id
	operation.density_value = density_value
	var batch = EditBatch.new()
	if not batch.add_operation(operation):
		_last_edit_summary = {
			"accepted": false,
			"submission_index": _edit_submission_count,
			"mode": str(mode_name),
			"center": center,
			"radius": radius,
			"material_id": material_id,
			"error": "failed to add edit operation",
		}
		return _fail("failed to add edit operation")
	var before_revision := int(terrain_world.call("get_backend_world_revision"))
	var accepted := bool(terrain_world.call("submit_edit_batch", batch, 56056))
	if accepted:
		_edit_accept_count += 1
		_begin_edit_burst()
	_last_edit_summary = {
		"accepted": accepted,
		"submission_index": _edit_submission_count,
		"mode": str(mode_name),
		"center": center,
		"radius": radius,
		"material_id": material_id,
		"before_world_revision": before_revision,
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
	for _frame in range(startup_world_state_timeout_frames):
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
	for _frame in range(startup_world_state_timeout_frames):
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


func wait_for_streaming_settled(
	render_count: int,
	collision_count: int,
	active_record_limit: int = 0
) -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null:
		return false
	for _frame in range(startup_world_state_timeout_frames):
		var metrics: Dictionary = terrain_world.call("get_runtime_metrics")
		var summary := _streaming_settled_summary(metrics)
		_last_cold_idle_summary = summary
		if _is_streaming_settled(summary, render_count, collision_count, active_record_limit):
			await get_tree().process_frame
			metrics = terrain_world.call("get_runtime_metrics")
			summary = _streaming_settled_summary(metrics)
			_last_cold_idle_summary = summary
			return _is_streaming_settled(summary, render_count, collision_count, active_record_limit)
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


func wait_for_edit_commits(target_count: int) -> bool:
	for _frame in range(900):
		if _edit_commit_count >= target_count:
			await get_tree().process_frame
			return true
		if _edit_failure_count > 0:
			return false
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


func get_last_settle_summary() -> Dictionary:
	return _last_cold_idle_summary.duplicate(true)


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
		"player_viewer_update_distance": player_viewer_update_distance,
		"player_viewer_coalesce_while_streaming": player_viewer_coalesce_while_streaming,
		"player_viewer_updates": _accepted_player_viewer_updates,
		"player_viewer_coalesced_updates": _coalesced_player_viewer_updates,
		"player_viewer_last_coalesce_reason": _last_player_viewer_coalesce_reason,
		"player_predictive_viewer_enabled": player_predictive_viewer_enabled,
		"player_predictive_viewer_distance": player_predictive_viewer_distance,
		"player_predictive_viewer_updates": _accepted_predictive_viewer_updates,
		"player_focus_viewer_enabled": player_focus_viewer_enabled,
		"player_focus_viewer_distance": player_focus_viewer_distance,
		"player_focus_viewer_updates": _accepted_focus_viewer_updates,
		"player_collision_invoker_enabled": player_collision_invoker_enabled,
		"player_collision_invoker_radius_chunks": player_collision_invoker_radius_chunks,
		"player_collision_prediction_distance": player_collision_prediction_distance,
		"player_collision_viewer_updates": _accepted_collision_viewer_updates,
		"viewer_positions": _viewer_positions.size(),
		"viewer_radius_chunks": _viewer_radius_chunks,
		"viewer_maximum_lod": _viewer_maximum_lod,
		"runtime_viewer_capacity": runtime_viewer_capacity,
		"runtime_demand_capacity_per_viewer": runtime_demand_capacity_per_viewer,
		"runtime_lod_refinement_radius_chunks": runtime_lod_refinement_radius_chunks,
		"runtime_render_apply_budget": runtime_render_apply_budget,
		"runtime_collision_apply_budget": runtime_collision_apply_budget,
		"runtime_render_transition_frames": runtime_render_transition_frames,
		"runtime_shader_fade_parameter_enabled": runtime_shader_fade_parameter_enabled,
		"runtime_global_coarse_lod_coverage": runtime_global_coarse_lod_coverage,
		"runtime_streaming_burst_render_apply_budget": runtime_streaming_burst_render_apply_budget,
		"runtime_streaming_burst_collision_apply_budget": runtime_streaming_burst_collision_apply_budget,
		"runtime_streaming_burst_frames": runtime_streaming_burst_frames,
		"runtime_edit_burst_render_apply_budget": runtime_edit_burst_render_apply_budget,
		"runtime_edit_burst_collision_apply_budget": runtime_edit_burst_collision_apply_budget,
		"runtime_edit_burst_frames": runtime_edit_burst_frames,
		"streaming_burst_frames_remaining": _streaming_burst_frames_remaining,
		"runtime_collision_activation_distance": runtime_collision_activation_distance,
		"runtime_collision_deactivation_distance": runtime_collision_deactivation_distance,
		"expected_resource_count": _expected_resource_count,
		"active_chunk_records": int(metrics.get("active_chunk_records", 0)),
		"visual_ready_chunk_records": int(metrics.get("visual_ready_chunk_records", 0)),
		"fully_ready_chunk_records": int(metrics.get("fully_ready_chunk_records", 0)),
		"non_retiring_chunk_records": int(metrics.get("non_retiring_chunk_records", 0)),
		"non_retiring_visual_ready_chunk_records": int(metrics.get("non_retiring_visual_ready_chunk_records", 0)),
		"non_retiring_fully_ready_chunk_records": int(metrics.get("non_retiring_fully_ready_chunk_records", 0)),
		"pending_retirement_records": int(metrics.get("pending_retirement_records", 0)),
		"pending_retirement_records_missing": int(metrics.get("pending_retirement_records_missing", 0)),
		"render_resources": int(metrics.get("render_resources", 0)),
		"collision_resources": int(metrics.get("collision_resources", 0)),
		"queued_render": int(metrics.get("queued_render", 0)),
		"queued_collision": int(metrics.get("queued_collision", 0)),
		"application_submitted_render": int(metrics.get("application_submitted_render", 0)),
		"application_applied_render": int(metrics.get("application_applied_render", 0)),
		"application_stale_render": int(metrics.get("application_stale_render", 0)),
		"application_submitted_collision": int(metrics.get("application_submitted_collision", 0)),
		"application_applied_collision": int(metrics.get("application_applied_collision", 0)),
		"application_stale_collision": int(metrics.get("application_stale_collision", 0)),
		"application_unrequired_collision": int(metrics.get("application_unrequired_collision", 0)),
		"application_sink_failures": int(metrics.get("application_sink_failures", 0)),
		"application_queue_rejections": int(metrics.get("application_queue_rejections", 0)),
		"pending_chunk_retirements": int(metrics.get("pending_chunk_retirements", 0)),
		"pending_chunk_replacements": int(metrics.get("pending_chunk_replacements", 0)),
		"render_fading_resources": int(metrics.get("render_fading_resources", 0)),
		"staged_render_resources": int(metrics.get("staged_render_resources", 0)),
		"scheduler_sampling_records": int(metrics.get("scheduler_sampling_records", 0)),
		"scheduler_meshing_records": int(metrics.get("scheduler_meshing_records", 0)),
		"scheduler_ready_records": int(metrics.get("scheduler_ready_records", 0)),
		"scheduler_failed_records": int(metrics.get("scheduler_failed_records", 0)),
		"scheduler_queued_jobs": int(metrics.get("scheduler_queued_jobs", 0)),
		"scheduler_queued_completions": int(metrics.get("scheduler_queued_completions", 0)),
		"page_sample_failures": int(metrics.get("page_sample_failures", 0)),
		"page_mesh_failures": int(metrics.get("page_mesh_failures", 0)),
		"page_last_failure_key": Vector4i(
			int(metrics.get("page_last_failure_key_x", 0)),
			int(metrics.get("page_last_failure_key_y", 0)),
			int(metrics.get("page_last_failure_key_z", 0)),
			int(metrics.get("page_last_failure_key_lod", 0))
		),
		"edit_replacements": int(metrics.get("edit_replacements", 0)),
		"edit_lod_retention_zones": int(metrics.get("edit_lod_retention_zones", 0)),
		"edit_lod_retention_active_viewers": int(metrics.get("edit_lod_retention_active_viewers", 0)),
		"edit_lod_retention_plans": int(metrics.get("edit_lod_retention_plans", 0)),
		"edit_lod_retention_fallbacks": int(metrics.get("edit_lod_retention_fallbacks", 0)),
		"edit_submission_count": _edit_submission_count,
		"edit_accept_count": _edit_accept_count,
		"edit_commit_count": _edit_commit_count,
		"edit_failure_count": _edit_failure_count,
		"last_edit_committed_revision": _last_edit_committed_revision,
		"last_edit_failure_error": _last_edit_failure_error,
		"last_error": _last_error,
	}


func _streaming_settled_summary(metrics: Dictionary) -> Dictionary:
	var summary := {
		"world_running": bool(metrics.get("world_running", false)),
		"queued_render": int(metrics.get("queued_render", 0)),
		"queued_collision": int(metrics.get("queued_collision", 0)),
		"pending_chunk_retirements": int(metrics.get("pending_chunk_retirements", 0)),
		"pending_chunk_replacements": int(metrics.get("pending_chunk_replacements", 0)),
		"render_fading_resources": int(metrics.get("render_fading_resources", 0)),
		"staged_render_resources": int(metrics.get("staged_render_resources", 0)),
		"active_chunk_records": int(metrics.get("active_chunk_records", 0)),
		"visual_ready_chunk_records": int(metrics.get("visual_ready_chunk_records", 0)),
		"fully_ready_chunk_records": int(metrics.get("fully_ready_chunk_records", 0)),
		"render_resources": int(metrics.get("render_resources", 0)),
		"collision_resources": int(metrics.get("collision_resources", 0)),
		"scheduler_sampling_records": int(metrics.get("scheduler_sampling_records", 0)),
		"scheduler_meshing_records": int(metrics.get("scheduler_meshing_records", 0)),
		"scheduler_ready_records": int(metrics.get("scheduler_ready_records", 0)),
		"scheduler_failed_records": int(metrics.get("scheduler_failed_records", 0)),
		"scheduler_queued_jobs": int(metrics.get("scheduler_queued_jobs", 0)),
		"scheduler_queued_completions": int(metrics.get("scheduler_queued_completions", 0)),
		"page_sample_failures": int(metrics.get("page_sample_failures", 0)),
		"page_mesh_failures": int(metrics.get("page_mesh_failures", 0)),
		"page_last_failure_key": Vector4i(
			int(metrics.get("page_last_failure_key_x", 0)),
			int(metrics.get("page_last_failure_key_y", 0)),
			int(metrics.get("page_last_failure_key_z", 0)),
			int(metrics.get("page_last_failure_key_lod", 0))
		),
		"edit_lod_retention_zones": int(metrics.get("edit_lod_retention_zones", 0)),
		"edit_lod_retention_active_viewers": int(metrics.get("edit_lod_retention_active_viewers", 0)),
		"edit_lod_retention_plans": int(metrics.get("edit_lod_retention_plans", 0)),
		"edit_lod_retention_fallbacks": int(metrics.get("edit_lod_retention_fallbacks", 0)),
		"implementation": "gameworld_streaming_settled_v1",
	}
	summary["streaming_settled"] = _is_streaming_settled(summary, 0, 0, 0)
	return summary


func _is_streaming_settled(
	summary: Dictionary,
	render_count: int,
	collision_count: int,
	active_record_limit: int
) -> bool:
	var active_records := int(summary.get("active_chunk_records", 0))
	if not bool(summary.get("world_running", false)):
		return false
	if int(summary.get("queued_render", 0)) != 0:
		return false
	if int(summary.get("queued_collision", 0)) != 0:
		return false
	if int(summary.get("pending_chunk_retirements", 0)) != 0:
		return false
	if int(summary.get("pending_chunk_replacements", 0)) != 0:
		return false
	if int(summary.get("render_fading_resources", 0)) != 0:
		return false
	if int(summary.get("staged_render_resources", 0)) != 0:
		return false
	if int(summary.get("render_resources", 0)) < render_count:
		return false
	if int(summary.get("collision_resources", 0)) < collision_count:
		return false
	if int(summary.get("visual_ready_chunk_records", 0)) < render_count:
		return false
	if int(summary.get("scheduler_failed_records", 0)) != 0:
		return false
	if int(summary.get("page_sample_failures", 0)) != 0:
		return false
	if int(summary.get("page_mesh_failures", 0)) != 0:
		return false
	if active_records <= 0:
		return false
	if active_record_limit > 0 and active_records > active_record_limit:
		return false
	return true


func _apply_profiles() -> void:
	var terrain_world := get_terrain_world()
	if terrain_world == null:
		return
	if _terrain_profile != null:
		terrain_world.terrain_profile = _terrain_profile
	terrain_world.generation_profile = _generation_profile
	terrain_world.storage_profile = _storage_profile
	terrain_world.runtime_active_chunk_capacity = runtime_active_chunk_capacity
	terrain_world.runtime_viewer_capacity = runtime_viewer_capacity
	terrain_world.runtime_demand_capacity_per_viewer = runtime_demand_capacity_per_viewer
	terrain_world.runtime_render_entry_capacity = runtime_render_entry_capacity
	terrain_world.runtime_collision_entry_capacity = runtime_collision_entry_capacity
	terrain_world.runtime_lod_refinement_radius_chunks = runtime_lod_refinement_radius_chunks
	terrain_world.runtime_render_apply_budget = runtime_render_apply_budget
	terrain_world.runtime_collision_apply_budget = runtime_collision_apply_budget
	terrain_world.runtime_render_transition_frames = runtime_render_transition_frames
	terrain_world.runtime_shader_fade_parameter_enabled = runtime_shader_fade_parameter_enabled
	terrain_world.runtime_global_coarse_lod_coverage = runtime_global_coarse_lod_coverage
	terrain_world.runtime_collision_activation_distance = runtime_collision_activation_distance
	terrain_world.runtime_collision_deactivation_distance = runtime_collision_deactivation_distance


func _begin_streaming_burst() -> void:
	if runtime_streaming_burst_frames <= 0:
		return
	var render_budget := runtime_streaming_burst_render_apply_budget
	var collision_budget := runtime_streaming_burst_collision_apply_budget
	if render_budget <= runtime_render_apply_budget and collision_budget <= runtime_collision_apply_budget:
		return
	if not _apply_live_apply_budgets(
		maxi(runtime_render_apply_budget, render_budget),
		maxi(runtime_collision_apply_budget, collision_budget)
	):
		return
	_streaming_burst_frames_remaining = runtime_streaming_burst_frames


func _begin_edit_burst() -> void:
	var frames := runtime_edit_burst_frames
	var render_budget := runtime_edit_burst_render_apply_budget
	var collision_budget := runtime_edit_burst_collision_apply_budget
	if frames <= 0:
		_begin_streaming_burst()
		return
	if render_budget <= runtime_render_apply_budget and collision_budget <= runtime_collision_apply_budget:
		return
	if not _apply_live_apply_budgets(
		maxi(runtime_render_apply_budget, render_budget),
		maxi(runtime_collision_apply_budget, collision_budget)
	):
		return
	_streaming_burst_frames_remaining = maxi(_streaming_burst_frames_remaining, frames)


func _apply_live_apply_budgets(render_budget: int, collision_budget: int) -> bool:
	var backend := _get_backend_terrain()
	if backend == null:
		return false
	if backend.has_method("set_render_apply_budget"):
		backend.call("set_render_apply_budget", render_budget)
	if backend.has_method("set_collision_apply_budget"):
		backend.call("set_collision_apply_budget", collision_budget)
	return true


func _get_backend_terrain() -> Node:
	var terrain_world := get_terrain_world()
	if terrain_world == null or not terrain_world.has_method("get_backend_terrain"):
		return null
	return terrain_world.call("get_backend_terrain")


func _connect_terrain_world_signals() -> void:
	var terrain_world := get_terrain_world()
	if terrain_world == null:
		return
	var committed := Callable(self, "_on_terrain_edit_committed")
	if terrain_world.has_signal("edit_committed") and not terrain_world.is_connected("edit_committed", committed):
		terrain_world.connect("edit_committed", committed)
	var failed := Callable(self, "_on_terrain_edit_failed")
	if terrain_world.has_signal("edit_failed") and not terrain_world.is_connected("edit_failed", failed):
		terrain_world.connect("edit_failed", failed)


func _on_terrain_edit_committed(world_revision: int) -> void:
	_edit_commit_count += 1
	_last_edit_committed_revision = world_revision
	_last_edit_failure_error = "ok"
	_begin_edit_burst()


func _on_terrain_edit_failed(error: String) -> void:
	_edit_failure_count += 1
	_last_edit_failure_error = error
	_last_error = error


func _submit_initial_viewers() -> bool:
	# Viewer 1 is reserved for the live player viewer. Startup viewers are
	# persistent world-coverage viewers and must not be overwritten when the
	# player moves.
	var viewer_id := 2 if player_driven_viewer_enabled else 1
	for position in _viewer_positions:
		if not bool(_reference_scene.call("update_reference_viewer", viewer_id, viewer_id, position, _viewer_radius_chunks, _viewer_maximum_lod)):
			return _fail("initial viewer update failed: %s" % _terrain_world_error())
		viewer_id += 1
	return viewer_id > (2 if player_driven_viewer_enabled else 1)


func _wait_for_world_state(expected: String) -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null:
		return false
	for _frame in range(startup_world_state_timeout_frames):
		if terrain_world.call("get_world_state_name") == expected:
			await get_tree().process_frame
			return true
		await get_tree().process_frame
	return false


func _should_update_player_viewer(position: Vector3) -> bool:
	if is_inf(_last_player_viewer_position.x):
		return true
	return position.distance_to(_last_player_viewer_position) >= player_viewer_update_distance


func _update_predictive_player_viewer(
	position: Vector3,
	previous_position: Vector3,
	force: bool
) -> bool:
	if not player_predictive_viewer_enabled or player_predictive_viewer_distance <= 0.0:
		return true
	var movement := Vector3.ZERO
	if not is_inf(previous_position.x):
		movement = position - previous_position
	var direction := Vector3.ZERO
	if movement.length_squared() > 0.0001:
		direction = movement.normalized()
	var predicted_position := position
	if direction.length_squared() > 0.0:
		predicted_position += direction * player_predictive_viewer_distance
	if not force and not _should_update_predictive_player_viewer(predicted_position):
		return true
	_viewer_revision += 1
	if not bool(_reference_scene.call(
		"update_reference_viewer", _player_predictive_viewer_id, _viewer_revision, predicted_position, _viewer_radius_chunks, _viewer_maximum_lod
	)):
		return _fail("predictive player viewer update failed: %s" % _terrain_world_error())
	_last_predictive_viewer_position = predicted_position
	_accepted_predictive_viewer_updates += 1
	return true


func _should_update_predictive_player_viewer(position: Vector3) -> bool:
	if is_inf(_last_predictive_viewer_position.x):
		return true
	return position.distance_to(_last_predictive_viewer_position) >= player_viewer_update_distance


func _update_player_collision_invoker(
	position: Vector3,
	previous_position: Vector3,
	force: bool
) -> bool:
	if not player_collision_invoker_enabled:
		return true
	var invoker_position := position
	if not is_inf(previous_position.x):
		var movement := position - previous_position
		if movement.length_squared() > 0.0001:
			var maximum_prediction_distance := \
				float(player_collision_invoker_radius_chunks) * \
				COLLISION_INVOKER_CHUNK_EXTENT
			var prediction_distance := minf(
				player_collision_prediction_distance,
				maximum_prediction_distance
			)
			invoker_position += movement.normalized() * prediction_distance
	if not force and _collision_invoker_chunk(invoker_position) == \
			_collision_invoker_chunk(_last_collision_viewer_position):
		return true
	_viewer_revision += 1
	if not bool(_reference_scene.call(
		"update_reference_collision_viewer",
		_player_collision_viewer_id,
		_viewer_revision,
		invoker_position,
		player_collision_invoker_radius_chunks
	)):
		return _fail("player collision viewer update failed: %s" % _terrain_world_error())
	_last_collision_viewer_position = invoker_position
	_accepted_collision_viewer_updates += 1
	return true


func is_player_collision_ready_at(position: Vector3) -> bool:
	if not player_collision_invoker_enabled:
		return true
	var terrain_world := get_terrain_world()
	if terrain_world == null or not terrain_world.has_method("query_chunk_state"):
		return false
	var state: RefCounted = terrain_world.call(
		"query_chunk_state", _collision_invoker_chunk(position), 0
	)
	return state != null and \
		bool(state.call("is_collision_required")) and \
		bool(state.call("is_collision_ready"))


func _collision_invoker_chunk(position: Vector3) -> Vector3i:
	if is_inf(position.x) or is_inf(position.y) or is_inf(position.z):
		return Vector3i(2147483647, 2147483647, 2147483647)
	return Vector3i(
		floori(position.x / COLLISION_INVOKER_CHUNK_EXTENT),
		floori(position.y / COLLISION_INVOKER_CHUNK_EXTENT),
		floori(position.z / COLLISION_INVOKER_CHUNK_EXTENT)
	)


func _update_focus_player_viewer(force: bool) -> bool:
	if not player_focus_viewer_enabled or player_focus_viewer_distance <= 0.0:
		return true
	var camera := _player.get_node_or_null("FirstPersonCamera") as Camera3D
	if camera == null:
		return true
	var focus_position := camera.global_position + (-camera.global_transform.basis.z * player_focus_viewer_distance)
	if not force and not _should_update_focus_player_viewer(focus_position):
		return true
	_viewer_revision += 1
	if not bool(_reference_scene.call(
		"update_reference_viewer", _player_focus_viewer_id, _viewer_revision, focus_position, _viewer_radius_chunks, _viewer_maximum_lod
	)):
		return _fail("focus player viewer update failed: %s" % _terrain_world_error())
	_last_focus_viewer_position = focus_position
	_accepted_focus_viewer_updates += 1
	return true


func _should_update_focus_player_viewer(position: Vector3) -> bool:
	if is_inf(_last_focus_viewer_position.x):
		return true
	return position.distance_to(_last_focus_viewer_position) >= player_viewer_update_distance


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


func _terrain_world_state() -> String:
	var terrain_world := get_terrain_world()
	if terrain_world != null and terrain_world.has_method("get_world_state_name"):
		return str(terrain_world.call("get_world_state_name"))
	return "terrain world unavailable"


func _terrain_world_error() -> String:
	var terrain_world := get_terrain_world()
	if terrain_world != null and terrain_world.has_method("get_world_error"):
		return str(terrain_world.call("get_world_error"))
	if terrain_world != null and terrain_world.has_method("get_last_error"):
		return str(terrain_world.call("get_last_error"))
	return "terrain world unavailable"

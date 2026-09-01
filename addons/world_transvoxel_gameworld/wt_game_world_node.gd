extends Node3D

const ADDON_ID := "world_transvoxel_gameworld"
const API_VERSION := 1
const COLLISION_INVOKER_CHUNK_EXTENT := 16.0
const DEFAULT_PLAYER_COLLISION_RADIUS := 0.45
const DEFAULT_PLAYER_COLLISION_HALF_HEIGHT := 0.9
const DEFAULT_PLAYER_SUPPORT_MARGIN := 0.2
const FOREGROUND_PRIORITY_PLAYER_SUPPORT := 0
const FOREGROUND_PRIORITY_INTERACTION_FOCUS := 1
const FOREGROUND_PRIORITY_SUPPORT_SOURCE_ID := 1
const FOREGROUND_PRIORITY_FOCUS_SOURCE_ID := 2
const RuntimeScene := preload("res://addons/world_transvoxel_terrain/runtime/wt_terrain_runtime_scene.tscn")
const EditOperation := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd")
const EditBatch := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd")
const InteractionCollisionDemand := preload("res://addons/world_transvoxel_gameworld/wt_interaction_collision_demand.gd")

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
@export var player_interaction_collision_invoker_enabled: bool = false
@export var player_foreground_priority_enabled: bool = false
@export_range(16, 1000, 1) var player_foreground_priority_update_interval_ms: int = 100
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
@export_range(0, 8, 1) var runtime_procedural_generation_worker_count: int = 0
@export_range(0, 8, 1) var runtime_meshing_worker_count: int = 0
@export_range(0, 128, 1) var runtime_render_apply_budget: int = 0
@export_range(0, 128, 1) var runtime_collision_apply_budget: int = 0
@export_range(0, 33333, 1) var runtime_collision_apply_deadline_us: int = 0
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
@export var runtime_gpu_meshing_shadow_enabled: bool = false
@export var runtime_gpu_meshing_publication_candidate_enabled: bool = false
@export_range(1, 64, 1) var runtime_gpu_meshing_shadow_capacity: int = 3
@export var runtime_gpu_resident_render_candidate_enabled: bool = false
@export_range(1, 16, 1) var runtime_gpu_resident_request_capacity: int = 16
@export_range(1, 4096, 1) var runtime_gpu_resident_chunk_capacity: int = 64

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
var _player_predictive_collision_viewer_id := 67
var _player_interaction_collision_viewer_id := 68
var _last_player_viewer_position := Vector3(INF, INF, INF)
var _last_predictive_viewer_position := Vector3(INF, INF, INF)
var _last_focus_viewer_position := Vector3(INF, INF, INF)
var _last_collision_viewer_position := Vector3(INF, INF, INF)
var _last_predictive_collision_viewer_position := Vector3(INF, INF, INF)
var _last_interaction_collision_viewer_positions: Array[Vector3] = []
var _last_collision_observation_position := Vector3(INF, INF, INF)
var _pending_collision_motion := Vector3.ZERO
var _pending_collision_motion_valid := false
var _accepted_player_viewer_updates := 0
var _accepted_predictive_viewer_updates := 0
var _accepted_focus_viewer_updates := 0
var _accepted_collision_viewer_updates := 0
var _accepted_predictive_collision_viewer_updates := 0
var _accepted_interaction_collision_viewer_updates := 0
var _foreground_support_revision := 0
var _foreground_focus_revision := 0
var _last_foreground_support_keys: Array = []
var _last_foreground_focus_keys: Array = []
var _foreground_priority_next_update_usec := 0
var _accepted_foreground_support_updates := 0
var _accepted_foreground_focus_updates := 0
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
var _cpu_causal_trace: RefCounted
var _last_player_collision_readiness := {
	"ready": true,
	"enabled": false,
	"probe_chunks": [],
	"not_ready_chunks": [],
}


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


func set_cpu_causal_trace(trace: RefCounted) -> void:
	_cpu_causal_trace = trace


func set_player_foreground_priority_enabled(enabled: bool) -> bool:
	if player_foreground_priority_enabled == enabled:
		return true
	if not enabled and player_foreground_priority_enabled and \
			_reference_scene != null:
		if not _release_player_foreground_priority_leases():
			return false
	player_foreground_priority_enabled = enabled
	_foreground_priority_next_update_usec = 0
	if enabled and _reference_scene != null and _player != null:
		return _update_player_foreground_priority_leases(true)
	return true


func refresh_player_foreground_priority(force: bool = true) -> bool:
	return _update_player_foreground_priority_leases(force)


func setup_standard_world() -> Node:
	if _reference_scene != null:
		return _reference_scene
	_reference_scene = RuntimeScene.instantiate()
	_reference_scene.name = "WtGameWorldTerrain"
	add_child(_reference_scene)
	if not bool(_reference_scene.call("ensure_runtime_defaults")):
		_fail("production terrain runtime defaults are unavailable")
		return null
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
	if setup_standard_world() == null:
		return false
	if not bool(_reference_scene.call("start_runtime_world")):
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


func stop_world() -> bool:
	if _reference_scene == null:
		return true
	if player_foreground_priority_enabled:
		if not _release_player_foreground_priority_leases():
			return false
	if not bool(_reference_scene.call("stop_runtime_world")):
		return _fail("backend stop failed: %s" % _terrain_world_error())
	if not await _wait_for_world_state("stopped"):
		return _fail("terrain world did not reach stopped state: state=%s error=%s timeout_frames=%d" % [
			_terrain_world_state(),
			_terrain_world_error(),
			startup_world_state_timeout_frames,
		])
	return true


func update_player_viewer(force: bool = false) -> bool:
	if not player_driven_viewer_enabled or _reference_scene == null or _player == null:
		return false
	var position: Vector3 = _player.global_position
	var previous_position := _last_player_viewer_position
	var visual_update_required := force or _should_update_player_viewer(position)
	if not visual_update_required:
		if not _update_player_collision_invoker(position, force):
			return false
		if not _update_player_interaction_collision_invoker(force):
			return false
		return _update_player_foreground_priority_leases(force)
	if not force and player_viewer_coalesce_while_streaming:
		var coalesce_reason := _player_viewer_streaming_debt_reason()
		if not coalesce_reason.is_empty():
			_coalesced_player_viewer_updates += 1
			_last_player_viewer_coalesce_reason = coalesce_reason
			if not _update_player_collision_invoker(position, force):
				return false
			return _update_player_interaction_collision_invoker(force)
	# When both roles move, enqueue the visual viewer first. The native worker
	# consumes one viewer event before a foreground edit, so collision-first order
	# can commit an edit against collision-only demand before visual demand arrives.
	_viewer_revision += 1
	if not bool(_reference_scene.call(
		"update_runtime_viewer", _player_viewer_id, _viewer_revision, position, _viewer_radius_chunks, _viewer_maximum_lod
	)):
		return _fail("player viewer update failed: %s" % _terrain_world_error())
	_last_player_viewer_position = position
	_accepted_player_viewer_updates += 1
	_trace_event(&"viewer_submitted", {
		"role": "visual_player",
		"viewer_id": _player_viewer_id,
		"revision": _viewer_revision,
		"position": _vector3_summary(position),
		"force": force,
	})
	if not _update_player_collision_invoker(position, force):
		return false
	if not _update_player_interaction_collision_invoker(force):
		return false
	if not _update_predictive_player_viewer(position, previous_position, force):
		return false
	if not _update_focus_player_viewer(force):
		return false
	if not _update_player_foreground_priority_leases(force):
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
	_trace_event(&"edit_submission_requested", {
		"submission_index": _edit_submission_count,
		"mode": str(mode_name),
		"center": _vector3_summary(center),
		"radius": radius,
		"material_id": material_id,
		"before_world_revision": before_revision,
	}, true)
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
	_trace_event(&"edit_submission_result", _last_edit_summary, true)
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
	var timeout_frames := startup_world_state_timeout_frames * 2 \
		if runtime_gpu_resident_render_candidate_enabled \
		else startup_world_state_timeout_frames
	for _frame in range(timeout_frames):
		var summary: Dictionary = terrain_world.call("get_cold_idle_summary")
		if runtime_gpu_resident_render_candidate_enabled:
			summary.merge(Dictionary(terrain_world.call("get_runtime_metrics")), true)
			summary.merge(_gpu_resident_settle_summary(terrain_world), true)
		_last_cold_idle_summary = summary
		var render_minimum_ready := int(summary.get(
			"render_resources", -1
		)) >= render_count
		if bool(summary.get("gpu_resident_settle_enabled", false)):
			var active_gpu_chunks := int(summary.get(
				"gpu_resident_active_chunks", 0
			))
			var active_gpu_entries := int(summary.get(
				"gpu_resident_active_entries", 0
			))
			var tracked_gpu_chunks := int(summary.get(
				"gpu_resident_tracked_chunks", 0
			))
			render_minimum_ready = bool(summary.get(
				"gpu_resident_running", false
			)) and active_gpu_chunks > 0 \
				and tracked_gpu_chunks == active_gpu_chunks \
				and active_gpu_entries >= active_gpu_chunks \
				and int(summary.get("gpu_resident_resident_entries", 0)) \
					>= active_gpu_entries \
				and int(summary.get("gpu_resident_rejected_chunks", 0)) == 0 \
				and int(summary.get("gpu_resident_failed_cells", 0)) == 0 \
				and int(summary.get("gpu_resident_native_rejections", 0)) == 0 \
				and int(summary.get("gpu_resident_effect_queued", 0)) == 0 \
				and int(summary.get("gpu_resident_effect_in_flight", 0)) == 0 \
				and int(summary.get("gpu_resident_native_queued", 0)) == 0 \
				and int(summary.get("gpu_resident_native_in_flight", 0)) == 0 \
				and int(summary.get("scheduler_queued_jobs", 0)) == 0 \
				and int(summary.get("scheduler_queued_completions", 0)) == 0 \
				and int(summary.get("storage_queued_requests", 0)) == 0 \
				and int(summary.get("storage_queued_completions", 0)) == 0 \
				and int(summary.get("storage_active_requests", 0)) == 0 \
				and int(summary.get("storage_in_flight_requests", 0)) == 0 \
				and int(summary.get("pending_chunk_replacements", 0)) == 0 \
				and int(summary.get("staged_render_resources", 0)) == 0 \
				and int(summary.get("non_retiring_visual_ready_chunk_records", 0)) \
					>= int(summary.get("non_retiring_chunk_records", 1))
		if bool(summary.get("world_running", false)) and \
				int(summary.get("queued_render", 0)) == 0 and \
				int(summary.get("queued_collision", 0)) == 0 and \
				render_minimum_ready and \
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
		if runtime_gpu_resident_render_candidate_enabled:
			summary.merge(_gpu_resident_settle_summary(terrain_world), true)
		_last_cold_idle_summary = summary
		if _is_streaming_settled(summary, render_count, collision_count, active_record_limit):
			await get_tree().process_frame
			metrics = terrain_world.call("get_runtime_metrics")
			summary = _streaming_settled_summary(metrics)
			if runtime_gpu_resident_render_candidate_enabled:
				summary.merge(_gpu_resident_settle_summary(terrain_world), true)
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
	# Compatibility alias for older integration diagnostics.
	return _reference_scene


func get_runtime_scene() -> Node:
	return _reference_scene


func get_terrain_world() -> Node:
	if _reference_scene == null or not _reference_scene.has_method("get_terrain_world"):
		return null
	return _reference_scene.call("get_terrain_world")


func get_last_error() -> String:
	return _last_error


func get_last_edit_summary() -> Dictionary:
	return _last_edit_summary


func get_causal_trace_context() -> Dictionary:
	return {
		"viewer_revision": _viewer_revision,
		"player_viewer_updates": _accepted_player_viewer_updates,
		"predictive_viewer_updates": _accepted_predictive_viewer_updates,
		"focus_viewer_updates": _accepted_focus_viewer_updates,
		"collision_viewer_updates": _accepted_collision_viewer_updates,
		"predictive_collision_viewer_updates":
			_accepted_predictive_collision_viewer_updates,
		"interaction_collision_viewer_updates":
			_accepted_interaction_collision_viewer_updates,
		"coalesced_player_viewer_updates": _coalesced_player_viewer_updates,
		"last_player_viewer_position": _vector3_summary(_last_player_viewer_position),
		"last_collision_viewer_position": _vector3_summary(_last_collision_viewer_position),
		"last_predictive_collision_viewer_position": _vector3_summary(
			_last_predictive_collision_viewer_position
		),
		"interaction_collision_viewer_count": _last_interaction_collision_viewer_positions.size(),
		"edit_submission_count": _edit_submission_count,
		"edit_accept_count": _edit_accept_count,
		"edit_commit_count": _edit_commit_count,
		"edit_failure_count": _edit_failure_count,
		"last_edit_committed_revision": _last_edit_committed_revision,
		"gpu_meshing_shadow_enabled": runtime_gpu_meshing_shadow_enabled,
		"gpu_meshing_publication_candidate_enabled":
			runtime_gpu_meshing_publication_candidate_enabled,
		"gpu_meshing_shadow_capacity": runtime_gpu_meshing_shadow_capacity,
		"gpu_resident_render_candidate_enabled":
			runtime_gpu_resident_render_candidate_enabled,
		"gpu_resident_request_capacity": runtime_gpu_resident_request_capacity,
		"gpu_resident_chunk_capacity": runtime_gpu_resident_chunk_capacity,
	}


func get_last_settle_summary() -> Dictionary:
	return _last_cold_idle_summary.duplicate(true)


func get_game_world_summary() -> Dictionary:
	var terrain_world := get_terrain_world()
	var metrics: Dictionary = {}
	var gpu_resident_status: Dictionary = {}
	var gpu_resident_effect_status: Dictionary = {}
	var gpu_resident_native_metrics: Dictionary = {}
	if terrain_world != null:
		metrics = terrain_world.call("get_runtime_metrics")
		if terrain_world.has_method("get_gpu_resident_render_status"):
			gpu_resident_status = terrain_world.call("get_gpu_resident_render_status")
			gpu_resident_effect_status = Dictionary(gpu_resident_status.get(
				"effect_status", {}
			))
			gpu_resident_native_metrics = Dictionary(gpu_resident_status.get(
				"native_metrics", {}
			))
	return {
		"addon_id": ADDON_ID,
		"api_version": API_VERSION,
		"profile_id": str(_profile_id),
		"standard_world_node": true,
		"terrain_scene": "production_runtime",
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
		"player_predictive_collision_viewer_updates":
			_accepted_predictive_collision_viewer_updates,
		"player_interaction_collision_invoker_enabled":
			player_interaction_collision_invoker_enabled,
		"player_interaction_collision_invoker_radius_chunks":
			InteractionCollisionDemand.RADIUS_CHUNKS,
		"player_interaction_collision_viewer_updates":
			_accepted_interaction_collision_viewer_updates,
		"interaction_collision_viewer_count": _last_interaction_collision_viewer_positions.size(),
		"player_foreground_priority_enabled": player_foreground_priority_enabled,
		"player_foreground_priority_update_interval_ms": player_foreground_priority_update_interval_ms,
		"player_foreground_support_updates": _accepted_foreground_support_updates,
		"player_foreground_focus_updates": _accepted_foreground_focus_updates,
		"player_foreground_support_keys": _last_foreground_support_keys.duplicate(),
		"player_foreground_focus_keys": _last_foreground_focus_keys.duplicate(),
		"viewer_positions": _viewer_positions.size(),
		"viewer_radius_chunks": _viewer_radius_chunks,
		"viewer_maximum_lod": _viewer_maximum_lod,
		"runtime_viewer_capacity": runtime_viewer_capacity,
		"runtime_demand_capacity_per_viewer": runtime_demand_capacity_per_viewer,
		"runtime_lod_refinement_radius_chunks": runtime_lod_refinement_radius_chunks,
		"runtime_procedural_generation_worker_count": runtime_procedural_generation_worker_count,
		"runtime_meshing_worker_count": runtime_meshing_worker_count,
		"runtime_render_apply_budget": runtime_render_apply_budget,
		"runtime_collision_apply_budget": runtime_collision_apply_budget,
		"runtime_collision_apply_deadline_us": runtime_collision_apply_deadline_us,
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
		"gpu_resident_render_candidate_enabled":
			runtime_gpu_resident_render_candidate_enabled,
		"gpu_resident_render_running": bool(gpu_resident_status.get("running", false)),
		"gpu_resident_active_chunks": int(gpu_resident_status.get("active_chunks", 0)),
		"gpu_resident_tracked_chunks": int(gpu_resident_status.get("tracked_chunks", 0)),
		"gpu_resident_incomplete_chunks": int(gpu_resident_status.get(
			"incomplete_chunks", 0
		)),
		"gpu_resident_retiring_chunks": int(gpu_resident_status.get(
			"retiring_chunks", 0
		)),
		"gpu_resident_inactive_chunk_examples": Array(gpu_resident_status.get(
			"inactive_chunk_examples", []
		)),
		"gpu_resident_retiring_chunk_examples": Array(gpu_resident_status.get(
			"retiring_chunk_examples", []
		)),
		"gpu_resident_rejected_chunks": int(gpu_resident_status.get("rejected_chunks", 0)),
		"gpu_resident_rejection_reasons": Dictionary(gpu_resident_status.get(
			"rejection_reasons", {}
		)).duplicate(true),
		"gpu_resident_rejection_examples": Array(gpu_resident_status.get(
			"rejection_examples", []
		)).duplicate(true),
		"gpu_resident_stale_incomplete_groups_superseded": int(
			gpu_resident_status.get("stale_incomplete_groups_superseded", 0)
		),
		"gpu_resident_activation_cohort_retry_attempts": int(
			gpu_resident_status.get("activation_cohort_retry_attempts", 0)
		),
		"gpu_resident_pending_activation_retry_groups": int(
			gpu_resident_status.get("pending_activation_retry_groups", 0)
		),
		"gpu_resident_last_activation_cohort_wait": Dictionary(
			gpu_resident_status.get("last_activation_cohort_wait", {})
		).duplicate(true),
		"gpu_resident_stale_activation_cohorts": int(
			gpu_resident_status.get("stale_activation_cohorts_retained", 0)
		),
		"gpu_resident_stale_activation_examples": Array(
			gpu_resident_status.get("stale_activation_examples", [])
		).duplicate(true),
		"gpu_resident_coverage_retained_reconciliation_deferrals": int(
			gpu_resident_status.get(
				"coverage_retained_reconciliation_deferrals", 0
			)
		),
		"gpu_resident_retirement_confirmation_deferrals": int(
			gpu_resident_status.get("retirement_confirmation_deferrals", 0)
		),
		"gpu_resident_retirement_candidate_cancellations": int(
			gpu_resident_status.get("retirement_candidate_cancellations", 0)
		),
		"gpu_resident_active_entries": int(gpu_resident_effect_status.get(
			"active_entry_count", 0
		)),
		"gpu_resident_effect_queued": int(gpu_resident_effect_status.get(
			"queued_request_count", 0
		)),
		"gpu_resident_effect_in_flight": int(gpu_resident_effect_status.get(
			"inflight_extraction_count", 0
		)),
		"gpu_resident_native_queued": int(gpu_resident_native_metrics.get(
			"queued_requests", 0
		)),
		"gpu_resident_native_in_flight": int(gpu_resident_native_metrics.get(
			"in_flight_requests", 0
		)),
		"gpu_resident_native_captured_requests": int(
			gpu_resident_native_metrics.get("captured_requests", 0)
		),
		"gpu_resident_native_capacity_rejections": int(
			gpu_resident_native_metrics.get("capacity_rejections", 0)
		),
		"gpu_resident_native_capture_reservation_attempts": int(
			gpu_resident_native_metrics.get("capture_reservation_attempts", 0)
		),
		"gpu_resident_native_capture_reservation_rejections": int(
			gpu_resident_native_metrics.get("capture_reservation_rejections", 0)
		),
		"gpu_resident_native_reserved_captures": int(
			gpu_resident_native_metrics.get("reserved_captures", 0)
		),
		"gpu_resident_native_reserved_capture_failures": int(
			gpu_resident_native_metrics.get("reserved_capture_failures", 0)
		),
		"gpu_resident_active_empty_entries": int(gpu_resident_effect_status.get(
			"active_empty_entry_count", 0
		)),
		"gpu_resident_active_partial_entries": int(gpu_resident_effect_status.get(
			"active_partial_entry_count", 0
		)),
		"gpu_resident_active_empty_entry_examples": Array(
			gpu_resident_effect_status.get("active_empty_entry_examples", [])
		).duplicate(true),
		"gpu_resident_active_partial_entry_examples": Array(
			gpu_resident_effect_status.get("active_partial_entry_examples", [])
		).duplicate(true),
		"gpu_resident_active_terrain_lod_counts": Dictionary(
			gpu_resident_effect_status.get("active_terrain_lod_counts", {})
		).duplicate(true),
		"gpu_resident_active_static_water_lod_counts": Dictionary(
			gpu_resident_effect_status.get("active_static_water_lod_counts", {})
		).duplicate(true),
		"runtime_collision_activation_distance": runtime_collision_activation_distance,
		"runtime_collision_deactivation_distance": runtime_collision_deactivation_distance,
		"expected_resource_count": _expected_resource_count,
		"active_chunk_records": int(metrics.get("active_chunk_records", 0)),
		"visual_ready_chunk_records": int(metrics.get("visual_ready_chunk_records", 0)),
		"fully_ready_chunk_records": int(metrics.get("fully_ready_chunk_records", 0)),
		"non_retiring_chunk_records": int(metrics.get("non_retiring_chunk_records", 0)),
		"non_retiring_visual_ready_chunk_records": int(metrics.get("non_retiring_visual_ready_chunk_records", 0)),
		"non_retiring_fully_ready_chunk_records": int(metrics.get("non_retiring_fully_ready_chunk_records", 0)),
		"non_retiring_visual_not_ready_chunk_records": int(metrics.get("non_retiring_visual_not_ready_chunk_records", 0)),
		"first_visual_not_ready_key": Vector4i(
			int(metrics.get("first_visual_not_ready_key_x", 0)),
			int(metrics.get("first_visual_not_ready_key_y", 0)),
			int(metrics.get("first_visual_not_ready_key_z", 0)),
			int(metrics.get("first_visual_not_ready_key_lod", 0))
		),
		"first_visual_not_ready_generation": int(metrics.get("first_visual_not_ready_generation", 0)),
		"first_visual_not_ready_visual_generation": int(metrics.get("first_visual_not_ready_visual_generation", 0)),
		"first_visual_not_ready_render_generation": int(metrics.get("first_visual_not_ready_render_generation", 0)),
		"first_visual_not_ready_staged_render_generation": int(metrics.get("first_visual_not_ready_staged_render_generation", 0)),
		"first_visual_not_ready_staged": bool(metrics.get("first_visual_not_ready_staged", false)),
		"first_visual_not_ready_external_activation_required": bool(metrics.get("first_visual_not_ready_external_activation_required", false)),
		"collision_required_chunk_records": int(metrics.get("collision_required_chunk_records", 0)),
		"collision_ready_chunk_records": int(metrics.get("collision_ready_chunk_records", 0)),
		"collision_required_not_ready_chunk_records": int(metrics.get("collision_required_not_ready_chunk_records", 0)),
		"first_collision_not_ready_key": Vector4i(
			int(metrics.get("first_collision_not_ready_key_x", 0)),
			int(metrics.get("first_collision_not_ready_key_y", 0)),
			int(metrics.get("first_collision_not_ready_key_z", 0)),
			int(metrics.get("first_collision_not_ready_key_lod", 0))
		),
		"first_collision_not_ready_generation": int(metrics.get("first_collision_not_ready_generation", 0)),
		"first_collision_not_ready_visual_required": bool(metrics.get("first_collision_not_ready_visual_required", false)),
		"first_collision_not_ready_visual_ready": bool(metrics.get("first_collision_not_ready_visual_ready", false)),
		"first_collision_not_ready_staged": bool(metrics.get("first_collision_not_ready_staged", false)),
		"pending_retirement_records": int(metrics.get("pending_retirement_records", 0)),
		"pending_retirement_records_missing": int(metrics.get("pending_retirement_records_missing", 0)),
		"render_resources": int(metrics.get("render_resources", 0)),
		"collision_resources": int(metrics.get("collision_resources", 0)),
		"queued_render": int(metrics.get("queued_render", 0)),
		"queued_collision": int(metrics.get("queued_collision", 0)),
		"deferred_collision": int(metrics.get("deferred_collision", 0)),
		"total_collision_backlog": int(metrics.get("total_collision_backlog", 0)),
		"application_submitted_render": int(metrics.get("application_submitted_render", 0)),
		"application_applied_render": int(metrics.get("application_applied_render", 0)),
		"application_stale_render": int(metrics.get("application_stale_render", 0)),
		"application_submitted_collision": int(metrics.get("application_submitted_collision", 0)),
		"application_applied_collision": int(metrics.get("application_applied_collision", 0)),
		"application_stale_collision": int(metrics.get("application_stale_collision", 0)),
		"application_unrequired_collision": int(metrics.get("application_unrequired_collision", 0)),
		"application_sink_failures": int(metrics.get("application_sink_failures", 0)),
		"application_queue_rejections": int(metrics.get("application_queue_rejections", 0)),
		"collision_apply_deadline_ns": int(metrics.get("collision_apply_deadline_ns", 0)),
		"collision_apply_time_ns_last": int(metrics.get("collision_apply_time_ns_last", 0)),
		"collision_apply_time_ns_maximum": int(metrics.get("collision_apply_time_ns_maximum", 0)),
		"collision_apply_deadline_exhaustions": int(metrics.get("collision_apply_deadline_exhaustions", 0)),
		"collision_apply_frame_time_ns_last": int(metrics.get("collision_apply_frame_time_ns_last", 0)),
		"collision_apply_frame_time_ns_total": int(metrics.get("collision_apply_frame_time_ns_total", 0)),
		"collision_apply_frame_time_ns_maximum": int(metrics.get("collision_apply_frame_time_ns_maximum", 0)),
		"collision_apply_frame_items_last": int(metrics.get("collision_apply_frame_items_last", 0)),
		"collision_apply_frame_items_maximum": int(metrics.get("collision_apply_frame_items_maximum", 0)),
		"collision_apply_frame_deadline_overruns": int(metrics.get("collision_apply_frame_deadline_overruns", 0)),
		"pending_chunk_retirements": int(metrics.get("pending_chunk_retirements", 0)),
		"pending_chunk_replacements": int(metrics.get("pending_chunk_replacements", 0)),
		"blocked_pending_chunk_replacements": int(metrics.get("blocked_pending_chunk_replacements", 0)),
		"first_blocked_replacement_key": Vector4i(
			int(metrics.get("first_blocked_replacement_key_x", 0)),
			int(metrics.get("first_blocked_replacement_key_y", 0)),
			int(metrics.get("first_blocked_replacement_key_z", 0)),
			int(metrics.get("first_blocked_replacement_key_lod", 0))
		),
		"first_blocked_replacement_missing": bool(metrics.get("first_blocked_replacement_missing", false)),
		"first_blocked_replacement_visual_required": bool(metrics.get("first_blocked_replacement_visual_required", false)),
		"first_blocked_replacement_visual_ready": bool(metrics.get("first_blocked_replacement_visual_ready", false)),
		"first_blocked_replacement_collision_required": bool(metrics.get("first_blocked_replacement_collision_required", false)),
		"first_blocked_replacement_collision_ready": bool(metrics.get("first_blocked_replacement_collision_ready", false)),
		"first_blocked_replacement_staged": bool(metrics.get("first_blocked_replacement_staged", false)),
		"first_blocked_replacement_render_record_present": bool(metrics.get("first_blocked_replacement_render_record_present", false)),
		"first_blocked_replacement_render_staged": bool(metrics.get("first_blocked_replacement_render_staged", false)),
		"first_blocked_replacement_generation": int(metrics.get("first_blocked_replacement_generation", 0)),
		"first_blocked_replacement_render_generation": int(metrics.get("first_blocked_replacement_render_generation", 0)),
		"first_blocked_replacement_staged_render_generation": int(metrics.get("first_blocked_replacement_staged_render_generation", 0)),
		"render_fading_resources": int(metrics.get("render_fading_resources", 0)),
		"staged_render_resources": int(metrics.get("staged_render_resources", 0)),
		"scheduler_sampling_records": int(metrics.get("scheduler_sampling_records", 0)),
		"scheduler_meshing_records": int(metrics.get("scheduler_meshing_records", 0)),
		"scheduler_ready_records": int(metrics.get("scheduler_ready_records", 0)),
		"scheduler_failed_records": int(metrics.get("scheduler_failed_records", 0)),
		"scheduler_queued_jobs": int(metrics.get("scheduler_queued_jobs", 0)),
		"scheduler_queued_completions": int(metrics.get("scheduler_queued_completions", 0)),
		"storage_queued_requests": int(metrics.get("storage_queued_requests", 0)),
		"storage_queued_completions": int(metrics.get("storage_queued_completions", 0)),
		"storage_active_requests": int(metrics.get("storage_active_requests", 0)),
		"storage_accepted_requests": int(metrics.get("storage_accepted_requests", 0)),
		"storage_started_requests": int(metrics.get("storage_started_requests", 0)),
		"storage_completed_requests": int(metrics.get("storage_completed_requests", 0)),
		"storage_request_queue_rejections": int(metrics.get("storage_request_queue_rejections", 0)),
		"storage_duplicate_requests": int(metrics.get("storage_duplicate_requests", 0)),
		"storage_successful_pages": int(metrics.get("storage_successful_pages", 0)),
		"storage_load_time_ns_last": int(metrics.get("storage_load_time_ns_last", 0)),
		"storage_load_time_ns_total": int(metrics.get("storage_load_time_ns_total", 0)),
		"storage_load_time_ns_maximum": int(metrics.get("storage_load_time_ns_maximum", 0)),
		"storage_worker_count": int(metrics.get("storage_worker_count", 0)),
		"storage_in_flight_requests": int(metrics.get("storage_in_flight_requests", 0)),
		"storage_maximum_in_flight_requests": int(
			metrics.get("storage_maximum_in_flight_requests", 0)
		),
		"storage_in_flight_elapsed_ns": int(metrics.get("storage_in_flight_elapsed_ns", 0)),
		"storage_in_flight_key": Vector4i(
			int(metrics.get("storage_in_flight_key_x", 0)),
			int(metrics.get("storage_in_flight_key_y", 0)),
			int(metrics.get("storage_in_flight_key_z", 0)),
			int(metrics.get("storage_in_flight_key_lod", 0))
		),
		"storage_in_flight_generation": int(metrics.get("storage_in_flight_generation", 0)),
		"page_loading_records": int(metrics.get("page_loading_records", 0)),
		"page_sample_ready_records": int(metrics.get("page_sample_ready_records", 0)),
		"page_awaiting_mesh_records": int(metrics.get("page_awaiting_mesh_records", 0)),
		"page_mesh_ready_records": int(metrics.get("page_mesh_ready_records", 0)),
		"page_ready_records": int(metrics.get("page_ready_records", 0)),
		"page_unresolved_dependencies": int(metrics.get("page_unresolved_dependencies", 0)),
		"page_pending_dependency_requests": int(metrics.get("page_pending_dependency_requests", 0)),
		"page_pinned_pages": int(metrics.get("page_pinned_pages", 0)),
		"page_dependency_requests": int(metrics.get("page_dependency_requests", 0)),
		"page_dependency_reprioritizations": int(metrics.get("page_dependency_reprioritizations", 0)),
		"page_dependency_cache_hits": int(metrics.get("page_dependency_cache_hits", 0)),
		"page_dependency_cache_misses": int(metrics.get("page_dependency_cache_misses", 0)),
		"page_accepted_storage_completions": int(metrics.get("page_accepted_storage_completions", 0)),
		"page_stale_storage_completions": int(metrics.get("page_stale_storage_completions", 0)),
		"page_cache_encoded_entries": int(metrics.get("page_cache_encoded_entries", 0)),
		"page_cache_decoded_entries": int(metrics.get("page_cache_decoded_entries", 0)),
		"page_cache_encoded_hits": int(metrics.get("page_cache_encoded_hits", 0)),
		"page_cache_encoded_misses": int(metrics.get("page_cache_encoded_misses", 0)),
		"page_cache_encoded_insertions": int(metrics.get("page_cache_encoded_insertions", 0)),
		"page_cache_encoded_refreshes": int(metrics.get("page_cache_encoded_refreshes", 0)),
		"page_cache_encoded_evictions": int(metrics.get("page_cache_encoded_evictions", 0)),
		"page_cache_decoded_hits": int(metrics.get("page_cache_decoded_hits", 0)),
		"page_cache_decoded_misses": int(metrics.get("page_cache_decoded_misses", 0)),
		"page_cache_decoded_insertions": int(metrics.get("page_cache_decoded_insertions", 0)),
		"page_cache_decoded_evictions": int(metrics.get("page_cache_decoded_evictions", 0)),
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
		"deferred_collision": int(metrics.get("deferred_collision", 0)),
		"total_collision_backlog": int(metrics.get("total_collision_backlog", 0)),
		"pending_chunk_retirements": int(metrics.get("pending_chunk_retirements", 0)),
		"pending_chunk_replacements": int(metrics.get("pending_chunk_replacements", 0)),
		"blocked_pending_chunk_replacements": int(metrics.get("blocked_pending_chunk_replacements", 0)),
		"first_blocked_replacement_key": Vector4i(
			int(metrics.get("first_blocked_replacement_key_x", 0)),
			int(metrics.get("first_blocked_replacement_key_y", 0)),
			int(metrics.get("first_blocked_replacement_key_z", 0)),
			int(metrics.get("first_blocked_replacement_key_lod", 0))
		),
		"first_blocked_replacement_missing": bool(metrics.get("first_blocked_replacement_missing", false)),
		"first_blocked_replacement_visual_required": bool(metrics.get("first_blocked_replacement_visual_required", false)),
		"first_blocked_replacement_visual_ready": bool(metrics.get("first_blocked_replacement_visual_ready", false)),
		"first_blocked_replacement_collision_required": bool(metrics.get("first_blocked_replacement_collision_required", false)),
		"first_blocked_replacement_collision_ready": bool(metrics.get("first_blocked_replacement_collision_ready", false)),
		"first_blocked_replacement_staged": bool(metrics.get("first_blocked_replacement_staged", false)),
		"first_blocked_replacement_render_record_present": bool(metrics.get("first_blocked_replacement_render_record_present", false)),
		"first_blocked_replacement_render_staged": bool(metrics.get("first_blocked_replacement_render_staged", false)),
		"first_blocked_replacement_generation": int(metrics.get("first_blocked_replacement_generation", 0)),
		"first_blocked_replacement_render_generation": int(metrics.get("first_blocked_replacement_render_generation", 0)),
		"first_blocked_replacement_staged_render_generation": int(metrics.get("first_blocked_replacement_staged_render_generation", 0)),
		"render_fading_resources": int(metrics.get("render_fading_resources", 0)),
		"staged_render_resources": int(metrics.get("staged_render_resources", 0)),
		"active_chunk_records": int(metrics.get("active_chunk_records", 0)),
		"visual_ready_chunk_records": int(metrics.get("visual_ready_chunk_records", 0)),
		"fully_ready_chunk_records": int(metrics.get("fully_ready_chunk_records", 0)),
		"non_retiring_visual_not_ready_chunk_records": int(metrics.get("non_retiring_visual_not_ready_chunk_records", 0)),
		"first_visual_not_ready_key": Vector4i(
			int(metrics.get("first_visual_not_ready_key_x", 0)),
			int(metrics.get("first_visual_not_ready_key_y", 0)),
			int(metrics.get("first_visual_not_ready_key_z", 0)),
			int(metrics.get("first_visual_not_ready_key_lod", 0))
		),
		"first_visual_not_ready_generation": int(metrics.get("first_visual_not_ready_generation", 0)),
		"first_visual_not_ready_visual_generation": int(metrics.get("first_visual_not_ready_visual_generation", 0)),
		"first_visual_not_ready_render_generation": int(metrics.get("first_visual_not_ready_render_generation", 0)),
		"first_visual_not_ready_staged_render_generation": int(metrics.get("first_visual_not_ready_staged_render_generation", 0)),
		"first_visual_not_ready_staged": bool(metrics.get("first_visual_not_ready_staged", false)),
		"first_visual_not_ready_external_activation_required": bool(metrics.get("first_visual_not_ready_external_activation_required", false)),
		"collision_required_chunk_records": int(metrics.get("collision_required_chunk_records", 0)),
		"collision_ready_chunk_records": int(metrics.get("collision_ready_chunk_records", 0)),
		"collision_required_not_ready_chunk_records": int(metrics.get("collision_required_not_ready_chunk_records", 0)),
		"first_collision_not_ready_key": Vector4i(
			int(metrics.get("first_collision_not_ready_key_x", 0)),
			int(metrics.get("first_collision_not_ready_key_y", 0)),
			int(metrics.get("first_collision_not_ready_key_z", 0)),
			int(metrics.get("first_collision_not_ready_key_lod", 0))
		),
		"first_collision_not_ready_generation": int(metrics.get("first_collision_not_ready_generation", 0)),
		"first_collision_not_ready_visual_required": bool(metrics.get("first_collision_not_ready_visual_required", false)),
		"first_collision_not_ready_visual_ready": bool(metrics.get("first_collision_not_ready_visual_ready", false)),
		"first_collision_not_ready_staged": bool(metrics.get("first_collision_not_ready_staged", false)),
		"application_submitted_render": int(metrics.get("application_submitted_render", 0)),
		"application_applied_render": int(metrics.get("application_applied_render", 0)),
		"application_stale_render": int(metrics.get("application_stale_render", 0)),
		"application_last_stale_render_key": Vector4i(
			int(metrics.get("application_last_stale_render_key_x", 0)),
			int(metrics.get("application_last_stale_render_key_y", 0)),
			int(metrics.get("application_last_stale_render_key_z", 0)),
			int(metrics.get("application_last_stale_render_key_lod", 0))
		),
		"application_last_stale_render_generation": int(metrics.get("application_last_stale_render_generation", 0)),
		"application_last_stale_render_record_generation": int(metrics.get("application_last_stale_render_record_generation", 0)),
		"application_submitted_collision": int(metrics.get("application_submitted_collision", 0)),
		"application_applied_collision": int(metrics.get("application_applied_collision", 0)),
		"application_stale_collision": int(metrics.get("application_stale_collision", 0)),
		"application_unrequired_collision": int(metrics.get("application_unrequired_collision", 0)),
		"application_sink_failures": int(metrics.get("application_sink_failures", 0)),
		"application_queue_rejections": int(metrics.get("application_queue_rejections", 0)),
		"collision_apply_deadline_ns": int(metrics.get("collision_apply_deadline_ns", 0)),
		"collision_apply_time_ns_last": int(metrics.get("collision_apply_time_ns_last", 0)),
		"collision_apply_time_ns_maximum": int(metrics.get("collision_apply_time_ns_maximum", 0)),
		"collision_apply_deadline_exhaustions": int(metrics.get("collision_apply_deadline_exhaustions", 0)),
		"collision_apply_frame_time_ns_last": int(metrics.get("collision_apply_frame_time_ns_last", 0)),
		"collision_apply_frame_time_ns_total": int(metrics.get("collision_apply_frame_time_ns_total", 0)),
		"collision_apply_frame_time_ns_maximum": int(metrics.get("collision_apply_frame_time_ns_maximum", 0)),
		"collision_apply_frame_items_last": int(metrics.get("collision_apply_frame_items_last", 0)),
		"collision_apply_frame_items_maximum": int(metrics.get("collision_apply_frame_items_maximum", 0)),
		"collision_apply_frame_deadline_overruns": int(metrics.get("collision_apply_frame_deadline_overruns", 0)),
		"render_resources": int(metrics.get("render_resources", 0)),
		"collision_resources": int(metrics.get("collision_resources", 0)),
		"scheduler_sampling_records": int(metrics.get("scheduler_sampling_records", 0)),
		"scheduler_meshing_records": int(metrics.get("scheduler_meshing_records", 0)),
		"scheduler_ready_records": int(metrics.get("scheduler_ready_records", 0)),
		"scheduler_failed_records": int(metrics.get("scheduler_failed_records", 0)),
		"scheduler_queued_jobs": int(metrics.get("scheduler_queued_jobs", 0)),
		"scheduler_queued_completions": int(metrics.get("scheduler_queued_completions", 0)),
		"storage_queued_requests": int(metrics.get("storage_queued_requests", 0)),
		"storage_queued_completions": int(metrics.get("storage_queued_completions", 0)),
		"storage_active_requests": int(metrics.get("storage_active_requests", 0)),
		"storage_accepted_requests": int(metrics.get("storage_accepted_requests", 0)),
		"storage_started_requests": int(metrics.get("storage_started_requests", 0)),
		"storage_completed_requests": int(metrics.get("storage_completed_requests", 0)),
		"storage_request_queue_rejections": int(metrics.get("storage_request_queue_rejections", 0)),
		"storage_duplicate_requests": int(metrics.get("storage_duplicate_requests", 0)),
		"storage_successful_pages": int(metrics.get("storage_successful_pages", 0)),
		"storage_load_time_ns_last": int(metrics.get("storage_load_time_ns_last", 0)),
		"storage_load_time_ns_total": int(metrics.get("storage_load_time_ns_total", 0)),
		"storage_load_time_ns_maximum": int(metrics.get("storage_load_time_ns_maximum", 0)),
		"storage_in_flight_requests": int(metrics.get("storage_in_flight_requests", 0)),
		"storage_in_flight_elapsed_ns": int(metrics.get("storage_in_flight_elapsed_ns", 0)),
		"storage_in_flight_key": Vector4i(
			int(metrics.get("storage_in_flight_key_x", 0)),
			int(metrics.get("storage_in_flight_key_y", 0)),
			int(metrics.get("storage_in_flight_key_z", 0)),
			int(metrics.get("storage_in_flight_key_lod", 0))
		),
		"storage_in_flight_generation": int(metrics.get("storage_in_flight_generation", 0)),
		"page_loading_records": int(metrics.get("page_loading_records", 0)),
		"page_sample_ready_records": int(metrics.get("page_sample_ready_records", 0)),
		"page_awaiting_mesh_records": int(metrics.get("page_awaiting_mesh_records", 0)),
		"page_mesh_ready_records": int(metrics.get("page_mesh_ready_records", 0)),
		"page_ready_records": int(metrics.get("page_ready_records", 0)),
		"page_unresolved_dependencies": int(metrics.get("page_unresolved_dependencies", 0)),
		"page_pending_dependency_requests": int(metrics.get("page_pending_dependency_requests", 0)),
		"page_pinned_pages": int(metrics.get("page_pinned_pages", 0)),
		"page_dependency_requests": int(metrics.get("page_dependency_requests", 0)),
		"page_dependency_reprioritizations": int(metrics.get("page_dependency_reprioritizations", 0)),
		"page_dependency_cache_hits": int(metrics.get("page_dependency_cache_hits", 0)),
		"page_dependency_cache_misses": int(metrics.get("page_dependency_cache_misses", 0)),
		"page_accepted_storage_completions": int(metrics.get("page_accepted_storage_completions", 0)),
		"page_stale_storage_completions": int(metrics.get("page_stale_storage_completions", 0)),
		"page_cache_encoded_entries": int(metrics.get("page_cache_encoded_entries", 0)),
		"page_cache_decoded_entries": int(metrics.get("page_cache_decoded_entries", 0)),
		"page_cache_encoded_hits": int(metrics.get("page_cache_encoded_hits", 0)),
		"page_cache_encoded_misses": int(metrics.get("page_cache_encoded_misses", 0)),
		"page_cache_encoded_insertions": int(metrics.get("page_cache_encoded_insertions", 0)),
		"page_cache_encoded_refreshes": int(metrics.get("page_cache_encoded_refreshes", 0)),
		"page_cache_encoded_evictions": int(metrics.get("page_cache_encoded_evictions", 0)),
		"page_cache_decoded_hits": int(metrics.get("page_cache_decoded_hits", 0)),
		"page_cache_decoded_misses": int(metrics.get("page_cache_decoded_misses", 0)),
		"page_cache_decoded_insertions": int(metrics.get("page_cache_decoded_insertions", 0)),
		"page_cache_decoded_evictions": int(metrics.get("page_cache_decoded_evictions", 0)),
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


func _gpu_resident_settle_summary(terrain_world: Node) -> Dictionary:
	var status := Dictionary(terrain_world.call("get_gpu_resident_render_status"))
	var effect := Dictionary(status.get("effect_status", {}))
	var native := Dictionary(status.get("native_metrics", {}))
	return {
		"gpu_resident_settle_enabled": true,
		"gpu_resident_running": bool(status.get("running", false)),
		"gpu_resident_tracked_chunks": int(status.get("tracked_chunks", 0)),
		"gpu_resident_active_chunks": int(status.get("active_chunks", 0)),
		"gpu_resident_incomplete_chunks": int(status.get("incomplete_chunks", 0)),
		"gpu_resident_retiring_chunks": int(status.get("retiring_chunks", 0)),
		"gpu_resident_prepared_inactive_chunks": int(status.get(
			"prepared_inactive_chunks", 0
		)),
		"gpu_resident_activation_queued_chunks": int(status.get(
			"activation_queued_chunks", 0
		)),
		"gpu_resident_oldest_inactive_age_frames": int(status.get(
			"oldest_inactive_age_frames", 0
		)),
		"gpu_resident_inactive_chunk_examples": Array(status.get(
			"inactive_chunk_examples", []
		)),
		"gpu_resident_retiring_chunk_examples": Array(status.get(
			"retiring_chunk_examples", []
		)),
		"gpu_resident_rejected_chunks": int(status.get("rejected_chunks", 0)),
		"gpu_resident_rejection_reasons": Dictionary(status.get(
			"rejection_reasons", {}
		)).duplicate(true),
		"gpu_resident_rejection_examples": Array(status.get(
			"rejection_examples", []
		)).duplicate(true),
		"gpu_resident_stale_incomplete_groups_superseded": int(status.get(
			"stale_incomplete_groups_superseded", 0
		)),
		"gpu_resident_activation_cohort_retry_attempts": int(status.get(
			"activation_cohort_retry_attempts", 0
		)),
		"gpu_resident_pending_activation_retry_groups": int(status.get(
			"pending_activation_retry_groups", 0
		)),
		"gpu_resident_pending_activation_cohorts": int(status.get(
			"pending_activation_cohorts", 0
		)),
		"gpu_resident_activation_cohorts_queued": int(status.get(
			"activation_cohorts_queued", 0
		)),
		"gpu_resident_activation_cohorts_committed": int(status.get(
			"activation_cohorts_committed", 0
		)),
		"gpu_resident_stale_activation_cohorts": int(status.get(
			"stale_activation_cohorts_retained", 0
		)),
		"gpu_resident_stale_activation_examples": Array(status.get(
			"stale_activation_examples", []
		)).duplicate(true),
		"gpu_resident_last_activation_cohort_wait": Dictionary(status.get(
			"last_activation_cohort_wait", {}
		)).duplicate(true),
		"gpu_resident_effect_queued": int(effect.get("queued_request_count", 0)),
		"gpu_resident_effect_in_flight": int(effect.get(
			"inflight_extraction_count", 0
		)),
		"gpu_resident_effect_pending_lifecycle_commands": int(effect.get(
			"pending_lifecycle_command_count", 0
		)),
		"gpu_resident_effect_event_count": int(effect.get("event_count", 0)),
		"gpu_resident_effect_draw_frames": int(effect.get("draw_frames", 0)),
		"gpu_resident_unrouted_effect_events": int(status.get(
			"unrouted_effect_events", 0
		)),
		"gpu_resident_unrouted_effect_event_examples": Array(status.get(
			"unrouted_effect_event_examples", []
		)).duplicate(true),
		"gpu_resident_active_entries": int(effect.get("active_entry_count", 0)),
		"gpu_resident_resident_entries": int(effect.get("resident_entry_count", 0)),
		"gpu_resident_failed_cells": int(effect.get(
			"arena_failed_cell_count_total", 0
		)),
		"gpu_resident_native_queued": int(native.get("queued_requests", 0)),
		"gpu_resident_native_in_flight": int(native.get("in_flight_requests", 0)),
		"gpu_resident_native_rejections": int(native.get(
			"validation_rejections", 0
		)),
	}


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
	var gpu_resident := bool(summary.get("gpu_resident_settle_enabled", false))
	if not gpu_resident and int(summary.get("render_resources", 0)) < render_count:
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
	if gpu_resident:
		if not bool(summary.get("gpu_resident_running", false)):
			return false
		var tracked_gpu_chunks := int(summary.get("gpu_resident_tracked_chunks", 0))
		var active_gpu_chunks := int(summary.get("gpu_resident_active_chunks", 0))
		var active_gpu_entries := int(summary.get("gpu_resident_active_entries", 0))
		if active_gpu_chunks <= 0 or tracked_gpu_chunks != active_gpu_chunks:
			return false
		if active_gpu_entries < render_count or active_gpu_entries < active_gpu_chunks \
				or int(summary.get("gpu_resident_resident_entries", 0)) \
				< active_gpu_entries:
			return false
		for key in [
			"gpu_resident_rejected_chunks",
			"gpu_resident_effect_queued",
			"gpu_resident_effect_in_flight",
			"gpu_resident_failed_cells",
			"gpu_resident_native_queued",
			"gpu_resident_native_in_flight",
			"gpu_resident_native_rejections"
		]:
			if int(summary.get(key, 0)) != 0:
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
	terrain_world.runtime_procedural_generation_worker_count = \
		runtime_procedural_generation_worker_count
	terrain_world.runtime_meshing_worker_count = runtime_meshing_worker_count
	terrain_world.runtime_render_apply_budget = runtime_render_apply_budget
	terrain_world.runtime_collision_apply_budget = runtime_collision_apply_budget
	terrain_world.runtime_collision_apply_deadline_us = runtime_collision_apply_deadline_us
	terrain_world.runtime_render_transition_frames = runtime_render_transition_frames
	terrain_world.runtime_shader_fade_parameter_enabled = runtime_shader_fade_parameter_enabled
	terrain_world.runtime_global_coarse_lod_coverage = runtime_global_coarse_lod_coverage
	terrain_world.runtime_collision_activation_distance = runtime_collision_activation_distance
	terrain_world.runtime_collision_deactivation_distance = runtime_collision_deactivation_distance
	terrain_world.runtime_gpu_meshing_shadow_enabled = runtime_gpu_meshing_shadow_enabled
	terrain_world.runtime_gpu_meshing_publication_candidate_enabled = \
		runtime_gpu_meshing_publication_candidate_enabled
	terrain_world.runtime_gpu_meshing_shadow_capacity = runtime_gpu_meshing_shadow_capacity
	terrain_world.runtime_gpu_resident_render_candidate_enabled = \
		runtime_gpu_resident_render_candidate_enabled
	terrain_world.runtime_gpu_resident_request_capacity = \
		runtime_gpu_resident_request_capacity
	terrain_world.runtime_gpu_resident_chunk_capacity = \
		runtime_gpu_resident_chunk_capacity


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
	_trace_event(&"authority_commit_signal", {
		"world_revision": world_revision,
		"edit_commit_count": _edit_commit_count,
	}, true)
	_begin_edit_burst()


func _on_terrain_edit_failed(error: String) -> void:
	_edit_failure_count += 1
	_last_edit_failure_error = error
	_last_error = error
	_trace_event(&"authority_edit_failed", {
		"error": error,
		"edit_failure_count": _edit_failure_count,
	}, true)


func _submit_initial_viewers() -> bool:
	# Viewer 1 is reserved for the live player viewer. Startup viewers are
	# persistent world-coverage viewers and must not be overwritten when the
	# player moves.
	var viewer_id := 2 if player_driven_viewer_enabled else 1
	for position in _viewer_positions:
		if not bool(_reference_scene.call("update_runtime_viewer", viewer_id, viewer_id, position, _viewer_radius_chunks, _viewer_maximum_lod)):
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
		"update_runtime_viewer", _player_predictive_viewer_id, _viewer_revision, predicted_position, _viewer_radius_chunks, _viewer_maximum_lod
	)):
		return _fail("predictive player viewer update failed: %s" % _terrain_world_error())
	_last_predictive_viewer_position = predicted_position
	_accepted_predictive_viewer_updates += 1
	_trace_event(&"viewer_submitted", {
		"role": "visual_predictive",
		"viewer_id": _player_predictive_viewer_id,
		"revision": _viewer_revision,
		"position": _vector3_summary(predicted_position),
		"force": force,
	})
	return true


func _should_update_predictive_player_viewer(position: Vector3) -> bool:
	if is_inf(_last_predictive_viewer_position.x):
		return true
	return position.distance_to(_last_predictive_viewer_position) >= player_viewer_update_distance


func _update_player_collision_invoker(
	position: Vector3,
	force: bool
) -> bool:
	if not player_collision_invoker_enabled:
		return true
	var predictive_position := position
	var movement := Vector3.ZERO
	if _pending_collision_motion_valid:
		movement = _pending_collision_motion
		_pending_collision_motion = Vector3.ZERO
		_pending_collision_motion_valid = false
	elif not is_inf(_last_collision_observation_position.x):
		movement = position - _last_collision_observation_position
	_last_collision_observation_position = position
	if movement.length_squared() > 0.0001:
		predictive_position += movement.normalized() * \
			_player_collision_prediction_distance()
	return _submit_player_collision_invokers(position, predictive_position, force)


func _submit_player_collision_invokers(
	player_position: Vector3,
	predictive_position: Vector3,
	force: bool
) -> bool:
	var player_chunk := _collision_invoker_chunk(player_position)
	if force or player_chunk != _collision_invoker_chunk(
		_last_collision_viewer_position
	):
		if not _submit_collision_viewer(
			_player_collision_viewer_id, player_position, &"collision_player", force
		):
			return false
		_last_collision_viewer_position = player_position
		_accepted_collision_viewer_updates += 1
	var predictive_chunk := _collision_invoker_chunk(predictive_position)
	if force or predictive_chunk != _collision_invoker_chunk(
		_last_predictive_collision_viewer_position
	):
		if not _submit_collision_viewer(
			_player_predictive_collision_viewer_id,
			predictive_position,
			&"collision_predictive",
			force
		):
			return false
		_last_predictive_collision_viewer_position = predictive_position
		_accepted_predictive_collision_viewer_updates += 1
	return true


func _submit_collision_viewer(
	viewer_id: int,
	position: Vector3,
	role: StringName,
	force: bool,
	radius_chunks: int = -1
) -> bool:
	var effective_radius := player_collision_invoker_radius_chunks \
		if radius_chunks < 0 else radius_chunks
	_viewer_revision += 1
	if not bool(_reference_scene.call(
		"update_runtime_collision_viewer",
		viewer_id,
		_viewer_revision,
		position,
		effective_radius
	)):
		return _fail("player collision viewer update failed: %s" % _terrain_world_error())
	_trace_event(&"viewer_submitted", {
		"role": role,
		"viewer_id": viewer_id,
		"revision": _viewer_revision,
		"position": _vector3_summary(position),
		"radius_chunks": effective_radius,
		"force": force,
	})
	_begin_streaming_burst()
	return true


func _update_player_interaction_collision_invoker(force: bool) -> bool:
	if not player_interaction_collision_invoker_enabled or _player == null:
		return _remove_interaction_collision_viewers(0)
	var camera := _player.get_node_or_null("FirstPersonCamera") as Camera3D
	if camera == null:
		return _remove_interaction_collision_viewers(0)
	var interaction_distance := float(_player.get("interaction_distance"))
	if interaction_distance <= 0.0:
		return _remove_interaction_collision_viewers(0)
	var positions := InteractionCollisionDemand.centers(
		camera.global_position, -camera.global_transform.basis.z, interaction_distance
	)
	if positions.is_empty():
		return _fail("interaction collision ray must be finite and at most 96 world units")
	if not _remove_interaction_collision_viewers(positions.size()):
		return false
	for index in range(positions.size()):
		var position: Vector3 = positions[index]
		if not force and index < _last_interaction_collision_viewer_positions.size() and \
				_collision_invoker_chunk(position) == _collision_invoker_chunk(
					_last_interaction_collision_viewer_positions[index]
				):
			continue
		if not _submit_collision_viewer(
			_player_interaction_collision_viewer_id + index, position,
			&"collision_interaction", force, InteractionCollisionDemand.RADIUS_CHUNKS
		):
			return false
		if index == _last_interaction_collision_viewer_positions.size():
			_last_interaction_collision_viewer_positions.append(position)
		else:
			_last_interaction_collision_viewer_positions[index] = position
		_accepted_interaction_collision_viewer_updates += 1
	return true


func _remove_interaction_collision_viewers(keep: int) -> bool:
	while _last_interaction_collision_viewer_positions.size() > keep:
		var index := _last_interaction_collision_viewer_positions.size() - 1
		_viewer_revision += 1
		if not bool(_reference_scene.call(
			"remove_runtime_collision_viewer",
			_player_interaction_collision_viewer_id + index, _viewer_revision
		)):
			return _fail("interaction collision viewer removal failed")
		_last_interaction_collision_viewer_positions.remove_at(index)
	return true


func _player_collision_prediction_distance() -> float:
	var maximum_prediction_distance := \
		float(player_collision_invoker_radius_chunks) * \
			COLLISION_INVOKER_CHUNK_EXTENT
	return minf(
		player_collision_prediction_distance,
		maximum_prediction_distance
	)


func is_player_collision_ready_at(
	position: Vector3,
	allow_outside_vertical_volume: bool = false
) -> bool:
	return bool(get_player_collision_readiness_at(
		position,
		allow_outside_vertical_volume,
		DEFAULT_PLAYER_COLLISION_RADIUS,
		DEFAULT_PLAYER_COLLISION_HALF_HEIGHT,
		DEFAULT_PLAYER_SUPPORT_MARGIN
	).get("ready", false))


func get_player_collision_readiness_at(
	position: Vector3,
	allow_outside_vertical_volume: bool = false,
	body_radius: float = DEFAULT_PLAYER_COLLISION_RADIUS,
	body_half_height: float = DEFAULT_PLAYER_COLLISION_HALF_HEIGHT,
	support_margin: float = DEFAULT_PLAYER_SUPPORT_MARGIN
) -> Dictionary:
	if not player_collision_invoker_enabled:
		_last_player_collision_readiness = {
			"ready": true,
			"enabled": false,
			"position": _vector3_summary(position),
			"probe_chunks": [],
			"not_ready_chunks": [],
		}
		return _last_player_collision_readiness.duplicate(true)
	if _player != null:
		var player_position: Vector3 = _player.global_position
		_pending_collision_motion = position - player_position
		_pending_collision_motion_valid = true
		var predictive_position := player_position
		if _pending_collision_motion.length_squared() > 0.0001:
			predictive_position += _pending_collision_motion.normalized() * \
				_player_collision_prediction_distance()
		if not _submit_player_collision_invokers(
			player_position, predictive_position, false
		):
			_last_player_collision_readiness = {
				"ready": false,
				"enabled": true,
				"reason": "collision_viewer_update_failed",
				"position": _vector3_summary(position),
				"probe_chunks": [],
				"not_ready_chunks": [],
			}
			return _last_player_collision_readiness.duplicate(true)
	var terrain_world := get_terrain_world()
	if terrain_world == null or not terrain_world.has_method("query_chunk_state"):
		_last_player_collision_readiness = {
			"ready": false,
			"enabled": true,
			"reason": "terrain_world_unavailable",
			"position": _vector3_summary(position),
			"probe_chunks": [],
			"not_ready_chunks": [],
		}
		return _last_player_collision_readiness.duplicate(true)
	var probe_chunks := _player_collision_probe_chunks(
		position, body_radius, body_half_height, support_margin
	)
	var checked_chunks: Array = []
	var not_ready_chunks: Array = []
	for chunk_value in probe_chunks:
		var chunk: Vector3i = chunk_value
		if allow_outside_vertical_volume and _is_chunk_outside_vertical_volume(chunk):
			continue
		var coverage := _collision_coverage_for_lod0_chunk(terrain_world, chunk)
		var summary := {
			"coordinate": chunk,
			"present": coverage.get("present", false),
			"collision_required": coverage.get("collision_required", false),
			"collision_ready": coverage.get("collision_ready", false),
			"collision_generation": coverage.get("collision_generation", 0),
			"staged_collision_generation": coverage.get(
				"staged_collision_generation", 0
			),
			"physical_coverage_lod": coverage.get("physical_coverage_lod", -1),
			"coverage_source": coverage.get("source", "none"),
		}
		checked_chunks.append(summary)
		if not bool(coverage.get("ready", false)):
			not_ready_chunks.append(summary)
	_last_player_collision_readiness = {
		"ready": not_ready_chunks.is_empty(),
		"enabled": true,
		"reason": "ready" if not_ready_chunks.is_empty() else "support_collision_pending",
		"position": _vector3_summary(position),
		"probe_chunks": checked_chunks,
		"not_ready_chunks": not_ready_chunks,
	}
	return _last_player_collision_readiness.duplicate(true)


func get_last_player_collision_readiness() -> Dictionary:
	return _last_player_collision_readiness.duplicate(true)


func _collision_coverage_for_lod0_chunk(
	terrain_world: Object,
	chunk: Vector3i,
	maximum_lod: int = -1
) -> Dictionary:
	var state: RefCounted = terrain_world.call("query_chunk_state", chunk, 0)
	var present := state != null and bool(state.call("is_present"))
	var collision_required := state != null and bool(
		state.call("is_collision_required")
	)
	var collision_ready := state != null and bool(
		state.call("is_collision_ready")
	)
	var collision_generation := int(
		state.call("get_collision_generation") if state != null else 0
	)
	var staged_collision_generation := int(
		state.call("get_staged_collision_generation") if state != null else 0
	)
	var result := {
		"ready": false,
		"source": "none",
		"physical_coverage_lod": -1,
		"present": present,
		"collision_required": collision_required,
		"collision_ready": collision_ready,
		"collision_generation": collision_generation,
		"staged_collision_generation": staged_collision_generation,
	}
	if collision_generation > 0:
		result.ready = true
		result.source = "applied_lod0"
		result.physical_coverage_lod = 0
		return result
	var highest_lod := clampi(
		_viewer_maximum_lod if maximum_lod < 0 else maximum_lod,
		0,
		15
	)
	var preserved_ancestor_lods: Array = []
	for lod in range(1, highest_lod + 1):
		var scale := 1 << lod
		var ancestor := Vector3i(
			floori(float(chunk.x) / float(scale)),
			floori(float(chunk.y) / float(scale)),
			floori(float(chunk.z) / float(scale))
		)
		var ancestor_state: RefCounted = terrain_world.call(
			"query_chunk_state", ancestor, lod
		)
		if ancestor_state != null and int(
			ancestor_state.call("get_collision_generation")
		) > 0:
			preserved_ancestor_lods.append(lod)
	result.preserved_ancestor_lods = preserved_ancestor_lods
	# A completed empty payload is authoritative: no collision should exist here.
	if present and collision_required and collision_ready and \
			staged_collision_generation == 0:
		result.ready = true
		result.source = "resolved_empty_lod0"
	return result


func _collision_state_has_usable_applied_shape(state: RefCounted) -> bool:
	if state == null or not bool(state.call("is_collision_required")) or \
			not bool(state.call("is_collision_ready")):
		return false
	var applied_generation := int(state.call("get_collision_generation"))
	var staged_generation := int(state.call("get_staged_collision_generation"))
	# Generation zero is valid for an authoritative empty collision payload.
	# It is not usable while a non-empty/current replacement remains staged.
	return applied_generation > 0 or staged_generation == 0


func _player_collision_probe_chunks(
	position: Vector3,
	body_radius: float,
	body_half_height: float,
	support_margin: float
) -> Array:
	var radius := maxf(0.0, body_radius)
	var minimum := position + Vector3(
		-radius,
		-maxf(0.0, body_half_height) - maxf(0.0, support_margin),
		-radius
	)
	var maximum := position + Vector3(radius, 0.0, radius)
	var minimum_chunk := _collision_invoker_chunk(minimum)
	var maximum_chunk := _collision_invoker_chunk(maximum)
	var chunks: Array = []
	for chunk_y in range(minimum_chunk.y, maximum_chunk.y + 1):
		for chunk_z in range(minimum_chunk.z, maximum_chunk.z + 1):
			for chunk_x in range(minimum_chunk.x, maximum_chunk.x + 1):
				chunks.append(Vector3i(chunk_x, chunk_y, chunk_z))
	return chunks


func _is_chunk_outside_vertical_volume(chunk: Vector3i) -> bool:
	if _generation_profile == null:
		return false
	var origin_y := int(_generation_profile.get("world_chunk_origin_y"))
	var count_y := int(_generation_profile.get("world_chunk_count_y"))
	return count_y > 0 and (chunk.y < origin_y or chunk.y >= origin_y + count_y)


func _is_outside_vertical_volume(position: Vector3) -> bool:
	if _generation_profile == null:
		return false
	var chunk_count_y := int(_generation_profile.get("world_chunk_count_y"))
	if chunk_count_y <= 0:
		return false
	var minimum_y := float(
		int(_generation_profile.get("world_chunk_origin_y"))
	) * COLLISION_INVOKER_CHUNK_EXTENT
	var maximum_y := minimum_y + (
		float(chunk_count_y) * COLLISION_INVOKER_CHUNK_EXTENT
	)
	return position.y < minimum_y or position.y >= maximum_y


func _collision_invoker_chunk(position: Vector3) -> Vector3i:
	if is_inf(position.x) or is_inf(position.y) or is_inf(position.z):
		return Vector3i(2147483647, 2147483647, 2147483647)
	return Vector3i(
		floori(position.x / COLLISION_INVOKER_CHUNK_EXTENT),
		floori(position.y / COLLISION_INVOKER_CHUNK_EXTENT),
		floori(position.z / COLLISION_INVOKER_CHUNK_EXTENT)
	)


func _vector3_summary(value: Vector3) -> Dictionary:
	if is_inf(value.x) or is_inf(value.y) or is_inf(value.z):
		return {"available": false}
	return {"available": true, "x": value.x, "y": value.y, "z": value.z}


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
		"update_runtime_viewer", _player_focus_viewer_id, _viewer_revision, focus_position, _viewer_radius_chunks, _viewer_maximum_lod
	)):
		return _fail("focus player viewer update failed: %s" % _terrain_world_error())
	_last_focus_viewer_position = focus_position
	_accepted_focus_viewer_updates += 1
	_trace_event(&"viewer_submitted", {
		"role": "visual_focus",
		"viewer_id": _player_focus_viewer_id,
		"revision": _viewer_revision,
		"position": _vector3_summary(focus_position),
		"force": force,
	})
	return true


func _should_update_focus_player_viewer(position: Vector3) -> bool:
	if is_inf(_last_focus_viewer_position.x):
		return true
	return position.distance_to(_last_focus_viewer_position) >= player_viewer_update_distance


func _update_player_foreground_priority_leases(force: bool) -> bool:
	if not player_foreground_priority_enabled or _player == null or \
			_reference_scene == null:
		return true
	var now_usec := Time.get_ticks_usec()
	if not force and now_usec < _foreground_priority_next_update_usec:
		return true
	if not _player.has_method("get_foreground_priority_targets"):
		return _fail("player does not expose foreground priority targets")
	var targets: Dictionary = _player.call("get_foreground_priority_targets")
	var support_keys := _foreground_chunk_keys(
		Array(targets.get("support_points", []))
	)
	var focus_keys: Array = []
	if bool(targets.get("focus_valid", false)):
		var focus_points: Array = targets.get("focus_points", [])
		if focus_points.is_empty():
			focus_points = [targets.get("focus_point", _player.global_position)]
		focus_keys = _foreground_chunk_keys(focus_points)
	if force or support_keys != _last_foreground_support_keys:
		_foreground_support_revision += 1
		if not _submit_foreground_priority_lease(
			FOREGROUND_PRIORITY_SUPPORT_SOURCE_ID,
			_foreground_support_revision,
			FOREGROUND_PRIORITY_PLAYER_SUPPORT,
			support_keys,
			"player_support"
		):
			return false
		_last_foreground_support_keys = support_keys.duplicate()
		_accepted_foreground_support_updates += 1
	if force or focus_keys != _last_foreground_focus_keys:
		_foreground_focus_revision += 1
		if not _submit_foreground_priority_lease(
			FOREGROUND_PRIORITY_FOCUS_SOURCE_ID,
			_foreground_focus_revision,
			FOREGROUND_PRIORITY_INTERACTION_FOCUS,
			focus_keys,
			"interaction_focus"
		):
			return false
		_last_foreground_focus_keys = focus_keys.duplicate()
		_accepted_foreground_focus_updates += 1
	_foreground_priority_next_update_usec = now_usec + \
		player_foreground_priority_update_interval_ms * 1000
	return true


func _release_player_foreground_priority_leases() -> bool:
	if _reference_scene == null:
		return true
	_foreground_support_revision += 1
	if not _submit_foreground_priority_lease(
		FOREGROUND_PRIORITY_SUPPORT_SOURCE_ID,
		_foreground_support_revision,
		FOREGROUND_PRIORITY_PLAYER_SUPPORT,
		[],
		"player_support_release"
	):
		return false
	_foreground_focus_revision += 1
	if not _submit_foreground_priority_lease(
		FOREGROUND_PRIORITY_FOCUS_SOURCE_ID,
		_foreground_focus_revision,
		FOREGROUND_PRIORITY_INTERACTION_FOCUS,
		[],
		"interaction_focus_release"
	):
		return false
	_last_foreground_support_keys.clear()
	_last_foreground_focus_keys.clear()
	return true


func _submit_foreground_priority_lease(
	source_id: int,
	revision: int,
	priority_class: int,
	keys: Array,
	role: String
) -> bool:
	if not bool(_reference_scene.call(
		"update_runtime_foreground_priority_lease",
		source_id,
		revision,
		priority_class,
		keys
	)):
		return _fail("%s priority update failed: %s" % [
			role,
			_terrain_world_error(),
		])
	_trace_event(&"foreground_priority_submitted", {
		"role": role,
		"source_id": source_id,
		"revision": revision,
		"priority_class": priority_class,
		"keys": keys.duplicate(),
	})
	return true


func _foreground_chunk_keys(points: Array) -> Array:
	var keys: Array = []
	for value in points:
		if not value is Vector3:
			continue
		var point: Vector3 = value
		var key := Vector3i(
			floori(point.x / COLLISION_INVOKER_CHUNK_EXTENT),
			floori(point.y / COLLISION_INVOKER_CHUNK_EXTENT),
			floori(point.z / COLLISION_INVOKER_CHUNK_EXTENT)
		)
		if not keys.has(key):
			keys.append(key)
	return keys


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
		&"place_static_water":
			return EditOperation.Mode.PLACE_STATIC_WATER
		&"remove_static_water":
			return EditOperation.Mode.REMOVE_STATIC_WATER
		&"restore_to_base":
			return EditOperation.Mode.RESTORE_TO_BASE
		_:
			return EditOperation.Mode.CARVE


func _trace_event(
	kind: StringName,
	payload: Dictionary = {},
	include_pipeline: bool = false
) -> void:
	if _cpu_causal_trace != null and bool(
		_cpu_causal_trace.call("is_active")
	):
		_cpu_causal_trace.call(
			"record", kind, payload, include_pipeline
		)


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

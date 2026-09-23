@tool
extends Node
class_name WtTerrainGpuResidentRenderController

const GlobalRenderEffect := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render_effect.gd"
)
const REQUIRED_BACKEND_METHODS := [
	"begin_gpu_resident_render_publication",
	"end_gpu_resident_render_publication",
	"pop_gpu_resident_render_request",
	"validate_gpu_resident_render_request",
	"get_gpu_resident_render_chunk_readiness",
	"prepare_gpu_resident_render_chunk",
	"get_gpu_resident_render_activation_cohort",
	"activate_gpu_resident_render_cohort",
	"reject_gpu_resident_render_request",
	"set_gpu_resident_render_chunk_active",
	"reconcile_gpu_resident_render_chunks",
	"get_gpu_resident_render_metrics",
	"get_render_material_override",
	"get_water_material_override",
]
const PRODUCTION_TERRAIN_SHADER := (
	"res://addons/world_transvoxel_gameworld/material/wt_game_terrain_palette.gdshader"
)
const PRODUCTION_WATER_SHADER := (
	"res://addons/world_transvoxel_gameworld/material/wt_game_static_water.gdshader"
)
const PRODUCTION_DEFAULT_ROAD_GRADES := [
	Vector2(34.0, 39.0),
	Vector2(39.0, 40.0),
	Vector2(46.0, 39.0),
	Vector2(39.0, 34.0),
	Vector2(34.0, 33.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
]
const APPLICATION_WAIT_FRAME_LIMIT := 180
const APPLICATION_WAIT_RETRY_FRAMES := 3
const RENDER_SUBMISSION_CAPACITY := 16
# Feed half of the bounded extraction queue per frame. This removes the
# four-item serialization without concentrating all sixteen submissions in one
# frame.
const NATIVE_SUBMISSIONS_PER_FRAME := RENDER_SUBMISSION_CAPACITY / 2
# Initial attempts share the retry budget: many prepared members can refer to
# one regional wait, so preparation must not rebuild its cohort for each member.
const ACTIVATION_COHORT_RETRY_CAPACITY := 4
const ACTIVATION_COHORT_RETRY_BUDGET_USEC := 750
const GROUP_MAINTENANCE_INSPECTIONS_PER_FRAME := 8
const ACTIVATION_WAIT_INTERACTION_PROBE_FRAMES := 1
const ACTIVATION_WAIT_BACKGROUND_PROBE_FRAMES := 2
const EFFECT_EVENT_CAPACITY_PER_FRAME := 32
const EFFECT_EVENT_BUDGET_USEC := 2000
const COLLISION_ACTIVATION_RETRY_BURST := 3
const LIFECYCLE_HISTORY_CAPACITY := 4096
const MATERIAL_SYNC_INTERVAL_FRAMES := 30
const IDLE_RECONCILIATION_INTERVAL_FRAMES := 8
const RECONCILIATION_IDENTITIES_PER_FRAME := 32
const DORMANT_GROUP_CAPACITY := 64
const DORMANT_APPLICATION_RETRY_FRAMES := 8

var _backend_terrain: Node
var _world_environment: WorldEnvironment
var _directional_light: DirectionalLight3D
var _previous_compositor: Compositor
var _compositor: Compositor
var _effect
var _groups: Dictionary = {}
var _deferred_interaction_requests: Array[Dictionary] = []
var _render_request_routes: Dictionary = {}
var _entry_routes: Dictionary = {}
var _prepared_group_routes: Dictionary = {}
var _activation_cohorts: Dictionary = {}
var _activation_collision_retry_queue: Array[String] = []
var _activation_retry_queue: Array[String] = []
var _activation_retry_membership: Dictionary = {}
# Multiple prepared seeds often describe the same atomic regional wait. Gate
# native polling by the authority-reported blocker while every seed remains in
# its normal queue. Slow probes ensure a missed event cannot strand the cohort.
var _activation_wait_probe_frames: Dictionary = {}
var _activation_collision_retry_streak := 0
var _running := false
var _native_request_capacity := 16
var _resident_capacity := 64
var _next_publication_sequence := 1
var _next_activation_cohort_id := 1
var _last_error := ""
var _submitted_surfaces := 0
var _validated_surfaces := 0
var _activated_chunks := 0
var _retired_chunks := 0
var _rejected_chunks := 0
var _rejection_reasons: Dictionary = {}
var _rejection_examples: Array = []
var _superseded_chunks := 0
var _recovery_count := 0
var _application_wait_expirations := 0
var _coverage_retained_reconciliation_deferrals := 0
var _coverage_protected_reconciliation_chunks := 0
var _retirement_confirmation_deferrals := 0
var _retirement_candidate_cancellations := 0
var _has_retirement_candidates := false
var _stale_incomplete_groups_superseded := 0
var _activation_cohorts_queued := 0
var _activation_cohorts_committed := 0
var _same_callback_edit_precommits := 0
var _same_callback_edit_precommit_chunks := 0
var _same_callback_edit_precommit_rejections: Dictionary = {}
var _recent_incremental_activations: Array[Dictionary] = []
var _recent_incremental_first_draws: Array[Dictionary] = []
var _interaction_application_deferrals := 0
var _last_interaction_application_deferral := {}
var _interaction_native_requests_admitted := 0
var _cpu_only_regional_retirements := 0
var _recent_lifecycle_events: Array[Dictionary] = []
var _lifecycle_history_enabled := OS.get_cmdline_user_args().has("--gpu-lifecycle-history")
var _activation_cohort_retry_attempts := 0
var _activation_cohort_retry_coalesced := 0
var _activation_stale_seed_skips := 0
var _last_activation_cohort_wait: Dictionary = {}
var _last_activation_cohort_wait_frame := -1
var _last_activation_cohort_query: Dictionary = {}
var _stale_activation_cohorts_retained := 0
var _stale_activation_examples: Array = []
var _unrouted_effect_events := 0
var _unrouted_effect_event_examples: Array = []
var _effect_events_processed := 0
var _effect_event_budget_stops := 0
var _effect_event_max_processed_per_frame := 0
var _process_frame := 0
var _prepared_group_scan_cursor := 0
var _incomplete_group_scan_cursor := 0
var _production_material_signature := ""
var _production_water_signature := ""
var _production_texture_cache: Dictionary = {}
var _stage_timing_enabled := OS.get_cmdline_user_args().has("--gpu-stage-timing")
var _stage_timing_usec: Dictionary = {}
var _next_material_sync_frame := 0
var _next_reconciliation_frame := 0
var _reconciliation_scan_cursor := 0
var _dormant_group_lru: Array[String] = []
var _dormant_group_peak := 0
var _dormant_group_insertions := 0
var _dormant_group_reactivations := 0
var _dormant_group_evictions := 0


func _ready() -> void:
	set_process(false)


func start(
	backend_terrain: Node,
	world_environment: WorldEnvironment,
	native_request_capacity: int = 16,
	resident_capacity: int = 64
) -> bool:
	if _running:
		return true
	if backend_terrain == null or world_environment == null:
		_last_error = "native terrain backend and WorldEnvironment are required"
		return false
	for method_name in REQUIRED_BACKEND_METHODS:
		if not backend_terrain.has_method(method_name):
			_last_error = "native terrain backend lacks %s" % method_name
			return false
	_native_request_capacity = clampi(native_request_capacity, 1, 16)
	_resident_capacity = clampi(resident_capacity, 1, 4096)
	_effect = GlobalRenderEffect.new()
	if not _effect.configure_resident_capacity(_resident_capacity):
		_last_error = str(_effect.get_status().get(
			"last_error", "global render effect rejected resident capacity"
		))
		_effect = null
		return false
	_previous_compositor = world_environment.compositor
	_compositor = Compositor.new()
	var effects: Array[CompositorEffect] = []
	if _previous_compositor != null:
		for existing in _previous_compositor.compositor_effects:
			if existing != null:
				effects.append(existing)
	effects.append(_effect)
	_compositor.compositor_effects = effects
	world_environment.compositor = _compositor
	if not bool(backend_terrain.call(
		"begin_gpu_resident_render_publication", _native_request_capacity
	)):
		world_environment.compositor = _previous_compositor
		_effect.close()
		_effect = null
		_compositor = null
		_previous_compositor = null
		_last_error = "native terrain backend rejected resident publication"
		return false
	_backend_terrain = backend_terrain
	_world_environment = world_environment
	_directional_light = _resolve_directional_light()
	_groups.clear()
	_deferred_interaction_requests.clear()
	_render_request_routes.clear()
	_entry_routes.clear()
	_prepared_group_routes.clear()
	_activation_cohorts.clear()
	_activation_collision_retry_queue.clear()
	_activation_retry_queue.clear()
	_activation_retry_membership.clear()
	_activation_wait_probe_frames.clear()
	_last_activation_cohort_query.clear()
	_activation_collision_retry_streak = 0
	_unrouted_effect_events = 0
	_unrouted_effect_event_examples.clear()
	_effect_events_processed = 0
	_effect_event_budget_stops = 0
	_effect_event_max_processed_per_frame = 0
	_running = true
	_last_error = ""
	set_process(true)
	return true


func stop() -> void:
	set_process(false)
	if not _running and _effect == null:
		return
	_running = false
	_restore_cpu_and_release_native_requests()
	if _backend_terrain != null and is_instance_valid(_backend_terrain):
		_backend_terrain.call("end_gpu_resident_render_publication")
	if _world_environment != null and is_instance_valid(_world_environment) \
			and _world_environment.compositor == _compositor:
		_world_environment.compositor = _previous_compositor
	if _effect != null:
		_effect.close()
	_groups.clear()
	_deferred_interaction_requests.clear()
	_render_request_routes.clear()
	_entry_routes.clear()
	_prepared_group_routes.clear()
	_activation_cohorts.clear()
	_activation_collision_retry_queue.clear()
	_activation_retry_queue.clear()
	_activation_retry_membership.clear()
	_activation_wait_probe_frames.clear()
	_last_activation_cohort_query.clear()
	_activation_collision_retry_streak = 0
	_backend_terrain = null
	_world_environment = null
	_directional_light = null
	_previous_compositor = null
	_compositor = null
	_effect = null
	_production_texture_cache.clear()
	_production_material_signature = ""
	_production_water_signature = ""


func _exit_tree() -> void:
	stop()


func is_running() -> bool:
	return _running


func is_chunk_generation_active(position: Vector3i, lod: int, generation: int) -> bool:
	if not _running or generation <= 0:
		return false
	for group_value in _groups.values():
		var group := Dictionary(group_value)
		if not bool(group.get("active", false)) or bool(group.get("retiring", false)):
			continue
		var request := Dictionary(Dictionary(group.get("requests", {})).get("terrain", {}))
		var identity := Dictionary(request.get("identity", {}))
		if int(identity.get("generation", -1)) == generation \
				and int(identity.get("lod", -1)) == lod \
				and int(identity.get("page_x", 0)) == position.x \
				and int(identity.get("page_y", 0)) == position.y \
				and int(identity.get("page_z", 0)) == position.z:
			return true
	return false


func get_active_chunk_identity(position: Vector3i, lod: int) -> Dictionary:
	var selected := {}
	for group_value in _groups.values():
		var group := Dictionary(group_value)
		if not bool(group.get("active", false)):
			continue
		var request := Dictionary(Dictionary(group.get("requests", {})).get("terrain", {}))
		var identity := Dictionary(request.get("identity", {}))
		if int(identity.get("lod", -1)) != lod \
				or int(identity.get("page_x", 0)) != position.x \
				or int(identity.get("page_y", 0)) != position.y \
				or int(identity.get("page_z", 0)) != position.z:
			continue
		if selected.is_empty() or (not bool(group.get("retiring", false)) \
				and bool(selected.get("retiring", false))) \
				or int(identity.get("generation", 0)) > int(selected.get("generation", 0)):
			selected = identity.duplicate(true)
			selected["retiring"] = bool(group.get("retiring", false))
	return selected


func set_debug_lifecycle_history_enabled(enabled: bool) -> void:
	_lifecycle_history_enabled = enabled
	if _effect != null:
		_effect.set_critical_path_timeline_enabled(enabled)
	if not enabled:
		_recent_lifecycle_events.clear()
		_recent_incremental_activations.clear()
		_recent_incremental_first_draws.clear()


func set_debug_stage_timing_enabled(enabled: bool) -> void:
	_stage_timing_enabled = enabled or OS.get_cmdline_user_args().has("--gpu-stage-timing")
	if _effect != null:
		_effect.set_debug_stage_timing_enabled(_stage_timing_enabled)


func get_debug_processing_states() -> Array:
	var states: Array = []
	for group_key in _groups:
		var group: Dictionary = _groups[group_key]
		var request: Dictionary = Dictionary(group.get("requests", {})).get("terrain", {})
		if request.is_empty():
			continue
		var stage := "extracting"
		if bool(group.get("retiring", false)):
			stage = "retiring"
		elif bool(group.get("active", false)):
			stage = "visible"
		elif bool(group.get("activation_queued", false)):
			stage = "activation_queued"
		elif bool(group.get("native_prepared", false)):
			stage = "cohort_wait"
		elif _surface_set_complete(group, "prepared"):
			stage = "native_prepare_wait"
		states.append({
			"identity": Dictionary(request.get("identity", {})).duplicate(),
			"bounds_min": request.get("bounds_min", Vector3.ZERO),
			"bounds_max": request.get("bounds_max", Vector3.ZERO),
			"stage": stage,
			"age_frames": _process_frame - int(group.get("created_frame", _process_frame)),
			"activation_retry_queued": _activation_retry_membership.has(group_key),
			"native_active": bool(group.get("native_active", false)),
			"lane": "interaction" if bool(group.get("interaction_activation_priority",
				group.get("collision_activation_priority", false))) else "background",
		})
	return states


func get_status() -> Dictionary:
	var native_metrics := {}
	var effect_status := {}
	if _backend_terrain != null and is_instance_valid(_backend_terrain):
		native_metrics = Dictionary(_backend_terrain.call(
			"get_gpu_resident_render_metrics"
		))
	if _effect != null:
		effect_status = _effect.get_status()
	var active_groups := 0
	var incomplete_groups := 0
	var prepared_inactive_groups := 0
	var activation_queued_groups := 0
	var retiring_groups := 0
	var oldest_inactive_age_frames := 0
	for group_value in _groups.values():
		var group := Dictionary(group_value)
		if bool(group.get("retiring", false)):
			retiring_groups += 1
		if bool(group.get("active", false)):
			active_groups += 1
		elif not bool(group.get("retiring", false)):
			oldest_inactive_age_frames = maxi(
				oldest_inactive_age_frames,
				_process_frame - int(group.get("created_frame", _process_frame))
			)
			if bool(group.get("activation_queued", false)):
				activation_queued_groups += 1
			if _surface_set_complete(group, "prepared"):
				prepared_inactive_groups += 1
			else:
				incomplete_groups += 1
	return {
		"schema": "world_transvoxel.terrain.gpu_resident_render_controller.v1",
		"running": _running,
		"stage_timing_enabled": _stage_timing_enabled,
		"stage_timing_usec": _stage_timing_usec.duplicate(true),
		"native_request_capacity": _native_request_capacity,
		"render_submission_capacity": RENDER_SUBMISSION_CAPACITY,
		"native_submissions_per_frame": NATIVE_SUBMISSIONS_PER_FRAME,
		"resident_capacity": _resident_capacity,
		"tracked_group_capacity": _tracked_group_capacity(),
		"tracked_chunks": _groups.size(),
		"active_chunks": active_groups,
		"incomplete_chunks": incomplete_groups,
		"prepared_inactive_chunks": prepared_inactive_groups,
		"activation_queued_chunks": activation_queued_groups,
		"retiring_chunks": retiring_groups,
		"dormant_chunks": _dormant_group_lru.size(),
		"dormant_chunk_capacity": DORMANT_GROUP_CAPACITY,
		"dormant_chunk_peak": _dormant_group_peak,
		"dormant_chunk_insertions": _dormant_group_insertions,
		"dormant_chunk_reactivations": _dormant_group_reactivations,
		"dormant_chunk_evictions": _dormant_group_evictions,
		"oldest_inactive_age_frames": oldest_inactive_age_frames,
		"inactive_chunk_examples": _inactive_group_examples(8),
		"retiring_chunk_examples": _retiring_group_examples(8),
		"submitted_surfaces": _submitted_surfaces,
		"validated_surfaces": _validated_surfaces,
		"activated_chunks": _activated_chunks,
		"retired_chunks": _retired_chunks,
		"rejected_chunks": _rejected_chunks,
		"rejection_reasons": _rejection_reasons.duplicate(true),
		"rejection_examples": _rejection_examples.duplicate(true),
		"superseded_chunks": _superseded_chunks,
		"recovery_count": _recovery_count,
		"application_wait_expirations": _application_wait_expirations,
		"coverage_retained_reconciliation_deferrals": (
			_coverage_retained_reconciliation_deferrals
		),
		"coverage_protected_reconciliation_chunks": (
			_coverage_protected_reconciliation_chunks
		),
		"retirement_confirmation_deferrals": _retirement_confirmation_deferrals,
		"retirement_candidate_cancellations": _retirement_candidate_cancellations,
		"stale_incomplete_groups_superseded": (
			_stale_incomplete_groups_superseded
		),
		"activation_cohorts_queued": _activation_cohorts_queued,
		"activation_cohorts_committed": _activation_cohorts_committed,
		"same_callback_edit_precommits": _same_callback_edit_precommits,
		"same_callback_edit_precommit_chunks": _same_callback_edit_precommit_chunks,
		"same_callback_edit_precommit_rejections": (
			_same_callback_edit_precommit_rejections.duplicate(true)
		),
		"recent_incremental_activations": _recent_incremental_activations.duplicate(true),
		"recent_incremental_first_draws": _recent_incremental_first_draws.duplicate(true),
		"deferred_interaction_requests": _deferred_interaction_requests.size(),
		"interaction_application_deferrals": _interaction_application_deferrals,
		"interaction_native_requests_admitted": _interaction_native_requests_admitted,
		"last_interaction_application_deferral": (
			_last_interaction_application_deferral.duplicate(true)
		),
		"cpu_only_regional_retirements": _cpu_only_regional_retirements,
		"lifecycle_history_enabled": _lifecycle_history_enabled,
		"recent_lifecycle_events": _recent_lifecycle_events.duplicate(true),
		"activation_cohort_retry_attempts": _activation_cohort_retry_attempts,
		"activation_cohort_retry_coalesced": _activation_cohort_retry_coalesced,
		"activation_stale_seed_skips": _activation_stale_seed_skips,
		"pending_activation_retry_groups": _activation_retry_membership.size(),
		"pending_background_activation_retry_queue": _activation_retry_queue.size(),
		"pending_interaction_activation_retry_groups": (
			_activation_collision_retry_queue.size()
		),
		"pending_collision_activation_retry_groups": (
			_activation_collision_retry_queue.size()
		),
		"last_activation_cohort_wait": _last_activation_cohort_wait.duplicate(true),
		"last_activation_cohort_query": _last_activation_cohort_query.duplicate(true),
		"last_activation_wait_age_frames": _process_frame - _last_activation_cohort_wait_frame \
			if _last_activation_cohort_wait_frame >= 0 else -1,
		"stale_activation_cohorts_retained": _stale_activation_cohorts_retained,
		"stale_activation_examples": _stale_activation_examples.duplicate(true),
		"unrouted_effect_events": _unrouted_effect_events,
		"unrouted_effect_event_examples": (
			_unrouted_effect_event_examples.duplicate(true)
		),
		"effect_event_capacity_per_frame": EFFECT_EVENT_CAPACITY_PER_FRAME,
		"effect_event_budget_usec": EFFECT_EVENT_BUDGET_USEC,
		"effect_events_processed": _effect_events_processed,
		"effect_event_budget_stops": _effect_event_budget_stops,
		"effect_event_max_processed_per_frame": _effect_event_max_processed_per_frame,
		"pending_activation_cohorts": _activation_cohorts.size(),
		"last_error": _last_error,
		"native_metrics": native_metrics,
		"effect_status": effect_status,
		"default_backend_unchanged": true,
		"gpu_resident_render_publication": true,
		"production_chunk_replacement": true,
		"native_request_handoff_decoupled": true,
		"native_position_space": "world",
		"cpu_collision_authority": true,
		"gpu_page_lattice_input": bool(native_metrics.get(
			"gpu_page_lattice_input", false
		)),
		"atomic_surface_set_activation": true,
		"production_material_parity": bool(effect_status.get(
			"production_material_parity", false
		)),
		"production_terrain_material_payload_ready": bool(effect_status.get(
			"production_terrain_material_payload_ready", false
		)),
		"production_terrain_albedo_mapping_parity": bool(effect_status.get(
			"production_terrain_albedo_mapping_parity", false
		)),
		"production_terrain_roughness_mapping_parity": bool(effect_status.get(
			"production_terrain_roughness_mapping_parity", false
		)),
		"production_terrain_accepted_normal_response_parity": bool(effect_status.get(
			"production_terrain_accepted_normal_response_parity", false
		)),
		"production_terrain_bounded_pbr_response_parity": bool(effect_status.get(
			"production_terrain_bounded_pbr_response_parity", false
		)),
		"production_terrain_directional_ambient_lighting_parity": bool(
			effect_status.get(
				"production_terrain_directional_ambient_lighting_parity", false
			)
		),
		"production_terrain_normal_mapping_parity": bool(effect_status.get(
			"production_terrain_normal_mapping_parity", false
		)),
		"production_terrain_pbr_lighting_parity": bool(effect_status.get(
			"production_terrain_pbr_lighting_parity", false
		)),
		"production_terrain_material_parity": bool(effect_status.get(
			"production_terrain_material_parity", false
		)),
		"production_static_water_material_parity": bool(effect_status.get(
			"production_static_water_material_parity", false
		)),
		"production_static_water_material_payload_ready": bool(effect_status.get(
			"production_static_water_material_payload_ready", false
		)),
		"production_static_water_fresnel_tint_parity": bool(effect_status.get(
			"production_static_water_fresnel_tint_parity", false
		)),
		"production_static_water_refraction_parity": bool(effect_status.get(
			"production_static_water_refraction_parity", false
		)),
		"production_static_water_scene_copy_ready": bool(effect_status.get(
			"production_static_water_scene_copy_ready", false
		)),
		"production_material_source": str(effect_status.get(
			"production_material_source", ""
		)),
		"production_material_parameter_bytes": int(effect_status.get(
			"production_material_parameter_bytes", 0
		)),
		"production_material_texture_count": int(effect_status.get(
			"production_material_texture_count", 0
		)),
		"production_water_material_source": str(effect_status.get(
			"production_water_material_source", ""
		)),
		"production_water_parameter_bytes": int(effect_status.get(
			"production_water_parameter_bytes", 0
		)),
	}


func _process(_delta: float) -> void:
	if not _running or _backend_terrain == null or _effect == null:
		return
	_process_frame += 1
	if _stage_timing_enabled and _process_frame <= 12:
		print("WT_GPU_PROCESS_STAGE begin frame=%d usec=%d" % [
			_process_frame, Time.get_ticks_usec()
		])
	var phase_start := Time.get_ticks_usec() if _stage_timing_enabled else 0
	if _process_frame >= _next_material_sync_frame:
		_sync_production_materials()
		# Materials and RD texture handles may arrive after the first process
		# frame. Do not postpone their initial installation by half a second.
		var initializing := _production_material_signature.is_empty() or _production_water_signature.is_empty()
		_next_material_sync_frame = _process_frame + (1 if initializing else MATERIAL_SYNC_INTERVAL_FRAMES)
	if _stage_timing_enabled:
		phase_start = _record_stage_time("materials", phase_start)
	if not _running:
		return
	_drain_effect_events()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("effect_events", phase_start)
	if not _running:
		return
	var pending_groups := _pending_group_keys()
	_supersede_stale_incomplete_groups(pending_groups)
	if _stage_timing_enabled:
		phase_start = _record_stage_time("supersede", phase_start)
	if not _running:
		return
	_retry_prepared_groups(pending_groups)
	if _stage_timing_enabled:
		phase_start = _record_stage_time("prepared_retry", phase_start)
	if not _running:
		return
	_drain_activation_cohort_retries()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("activation_retry", phase_start)
	if not _running:
		return
	_submit_native_captures()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("submit", phase_start)
	if not _running:
		return
	if _process_frame >= _next_reconciliation_frame:
		_next_reconciliation_frame = _process_frame + _reconcile_active_chunks()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("reconcile", phase_start)
	if not _running:
		return
	var effect_status: Dictionary = _effect.get_status()
	if _stage_timing_enabled:
		_record_stage_time("status", phase_start)
	if bool(effect_status.get("initialization_attempted", false)) \
			and not bool(effect_status.get("initialized", false)) \
			and not str(effect_status.get("last_error", "")).is_empty():
		_fail_closed(str(effect_status.get("last_error", "GPU renderer failed")))
	if _stage_timing_enabled and _process_frame <= 12:
		print("WT_GPU_PROCESS_STAGE end frame=%d usec=%d" % [
			_process_frame, Time.get_ticks_usec()
		])


func _record_stage_time(stage: String, start_us: int) -> int:
	var now := Time.get_ticks_usec()
	var elapsed := now - start_us
	_accumulate_stage_time(stage, elapsed)
	if elapsed >= 20000:
		print("WT_GPU_PROCESS_SLOW_STAGE frame=%d stage=%s usec=%d" % [
			_process_frame, stage, elapsed
		])
	return now


func _accumulate_stage_time(stage: String, elapsed: int) -> void:
	var value := Dictionary(_stage_timing_usec.get(stage, {"calls": 0, "total": 0, "max": 0}))
	value["calls"] = int(value["calls"]) + 1
	value["total"] = int(value["total"]) + elapsed
	value["max"] = maxi(int(value["max"]), elapsed)
	_stage_timing_usec[stage] = value


func _sync_production_materials() -> void:
	_sync_production_terrain_material()
	_sync_production_water_material()


func _sync_production_terrain_material() -> void:
	if _effect == null or _backend_terrain == null:
		return
	var material_value = _backend_terrain.call("get_render_material_override")
	if not material_value is ShaderMaterial:
		return
	var material := material_value as ShaderMaterial
	if material.shader == null \
			or material.shader.resource_path != PRODUCTION_TERRAIN_SHADER:
		return
	var config := _production_material_config(material)
	var signature := str(config.get("signature", ""))
	if signature.is_empty() or signature == _production_material_signature:
		return
	if _effect.configure_production_terrain_material(config):
		_production_material_signature = signature


func _sync_production_water_material() -> void:
	if _effect == null or _backend_terrain == null:
		return
	var material_value = _backend_terrain.call("get_water_material_override")
	if not material_value is ShaderMaterial:
		return
	var material := material_value as ShaderMaterial
	if material.shader == null or material.shader.resource_path != PRODUCTION_WATER_SHADER:
		return
	var deep_color = material.get_shader_parameter("deep_color")
	var edge_color = material.get_shader_parameter("edge_color")
	if not deep_color is Color:
		deep_color = Color(0.015, 0.14, 0.20, 1.0)
	if not edge_color is Color:
		edge_color = Color(0.08, 0.38, 0.46, 1.0)
	var deep_linear: Color = deep_color.srgb_to_linear()
	var edge_linear: Color = edge_color.srgb_to_linear()
	var deep_tint = material.get_shader_parameter("deep_tint")
	var edge_tint = material.get_shader_parameter("edge_tint")
	var refraction_strength = material.get_shader_parameter("refraction_strength")
	var values := PackedFloat32Array()
	_append_vec4(values, Vector4(
		deep_linear.r, deep_linear.g, deep_linear.b, 1.0
	))
	_append_vec4(values, Vector4(
		edge_linear.r, edge_linear.g, edge_linear.b, 1.0
	))
	_append_vec4(values, Vector4(
		float(deep_tint) if deep_tint is float else 0.34,
		float(edge_tint) if edge_tint is float else 0.52,
		float(refraction_strength) if refraction_strength is float else 0.008,
		0.0
	))
	var parameter_bytes := values.to_byte_array()
	var signature := "%s:%s" % [
		str(material.get_instance_id()), parameter_bytes.hex_encode()
	]
	if signature == _production_water_signature:
		return
	if _effect.configure_production_static_water_material({
		"source": PRODUCTION_WATER_SHADER,
		"parameter_bytes": parameter_bytes,
		"resource": material,
	}):
		_production_water_signature = signature


func _production_material_config(material: ShaderMaterial) -> Dictionary:
	var texture_names := [
		"checker_texture",
		"terrain_albedo_array",
		"terrain_normal_array",
		"terrain_roughness_array",
		"clean_albedo_texture",
	]
	var resources: Array = []
	var texture_rids: Array[RID] = []
	for index in range(texture_names.size()):
		var texture = material.get_shader_parameter(texture_names[index])
		if texture == null and texture_names[index] == "clean_albedo_texture":
			texture = material.get_shader_parameter("checker_texture")
		if not texture is Texture:
			return {}
		var rd_texture := _production_texture_rid(texture, index in [0, 1, 4])
		if not rd_texture.is_valid():
			return {}
		resources.append(texture)
		texture_rids.append(rd_texture)
	var values := PackedFloat32Array()
	_append_vec4(values, Vector4(
		1.0 if bool(material.get_shader_parameter(
			"procedural_ore_worldspace_blend_enabled"
		)) else 0.0,
		1.0 if bool(material.get_shader_parameter(
			"procedural_rolling_exterior_surface_enabled"
		)) else 0.0,
		1.0 if bool(material.get_shader_parameter(
			"procedural_road_worldspace_blend_enabled"
		)) else 0.0,
		1.0 if bool(material.get_shader_parameter(
			"procedural_four_biome_world_enabled"
		)) else 0.0
	))
	_append_vec4(values, Vector4(
		float(material.get_shader_parameter("procedural_seed_phase")),
		float(material.get_shader_parameter("procedural_ore_blend_width")),
		float(material.get_shader_parameter("procedural_road_half_width")),
		float(material.get_shader_parameter("procedural_road_shoulder_width"))
	))
	_append_vec4(values, Vector4(
		float(material.get_shader_parameter("procedural_surface_cover_full_depth")),
		float(material.get_shader_parameter("procedural_surface_cover_fade_depth")),
		float(material.get_shader_parameter("procedural_surface_cover_normal_start")),
		float(material.get_shader_parameter("procedural_surface_cover_normal_end"))
	))
	_append_vec4(values, Vector4(
		float(material.get_shader_parameter(
			"procedural_surface_biome_height_blend_width"
		)),
		float(material.get_shader_parameter(
			"procedural_surface_biome_noise_blend_width"
		)),
		0.0,
		0.0
	))
	var world_size: Vector2 = material.get_shader_parameter(
		"procedural_world_size_xz"
	)
	_append_vec4(values, Vector4(world_size.x, world_size.y, 0.0, 0.0))
	for index in range(18):
		var grade_value = material.get_shader_parameter(
			"procedural_road_grade_%d" % index
		)
		var grade: Vector2 = grade_value \
			if grade_value is Vector2 else PRODUCTION_DEFAULT_ROAD_GRADES[index]
		_append_vec4(values, Vector4(grade.x, grade.y, 0.0, 0.0))
	var lighting := _production_scene_lighting()
	var ambient_color: Color = lighting.get("ambient_color", Color.BLACK)
	var directional_color: Color = lighting.get("directional_color", Color.BLACK)
	var directional_direction: Vector3 = lighting.get(
		"directional_direction", Vector3.UP
	)
	_append_vec4(values, Vector4(
		ambient_color.r,
		ambient_color.g,
		ambient_color.b,
		float(lighting.get("ambient_energy", 0.0))
	))
	_append_vec4(values, Vector4(
		directional_color.r,
		directional_color.g,
		directional_color.b,
		float(lighting.get("directional_energy", 0.0))
	))
	_append_vec4(values, Vector4(
		directional_direction.x,
		directional_direction.y,
		directional_direction.z,
		1.0 if bool(lighting.get("supported", false)) else 0.0
	))
	var parameter_bytes := values.to_byte_array()
	var signature_parts := [str(material.get_instance_id()), parameter_bytes.hex_encode()]
	for texture in resources:
		signature_parts.append(str(texture.get_instance_id()))
	return {
		"source": PRODUCTION_TERRAIN_SHADER,
		"parameter_bytes": parameter_bytes,
		"texture_rids": texture_rids,
		"resources": resources,
		"scene_lighting_supported": bool(lighting.get("supported", false)),
		"signature": ":".join(signature_parts),
	}


func _production_texture_rid(texture: Texture, srgb: bool) -> RID:
	var key := "%d:%d" % [texture.get_instance_id(), int(srgb)]
	var source_rid := texture.get_rid()
	var cached: Dictionary = _production_texture_cache.get(key, {})
	if cached.get("source_rid", RID()) == source_rid and not cached.is_empty():
		return cached["rd_rid"]
	var rd_rid := RenderingServer.texture_get_rd_texture(source_rid, srgb)
	if rd_rid.is_valid():
		var invalidate := _invalidate_production_texture.bind(texture.get_instance_id())
		if not texture.changed.is_connected(invalidate):
			texture.changed.connect(invalidate)
		_production_texture_cache[key] = {"source_rid": source_rid, "rd_rid": rd_rid}
	return rd_rid


func _invalidate_production_texture(instance_id: int) -> void:
	_production_texture_cache.erase("%d:0" % instance_id)
	_production_texture_cache.erase("%d:1" % instance_id)
	_production_material_signature = ""


func _production_scene_lighting() -> Dictionary:
	var result := {
		"ambient_color": Color.BLACK,
		"ambient_energy": 0.0,
		"directional_color": Color.BLACK,
		"directional_energy": 0.0,
		"directional_direction": Vector3.UP,
		"supported": false,
	}
	if _world_environment == null or not is_instance_valid(_world_environment):
		return result
	var environment := _world_environment.environment
	if environment == null \
			or environment.ambient_light_source != Environment.AMBIENT_SOURCE_COLOR \
			or environment.fog_enabled:
		return result
	var ambient_linear := environment.ambient_light_color.srgb_to_linear()
	result["ambient_color"] = ambient_linear
	result["ambient_energy"] = environment.ambient_light_energy
	var active_directional_lights: Array[DirectionalLight3D] = []
	for candidate in get_tree().root.find_children(
		"*", "DirectionalLight3D", true, false
	):
		var light := candidate as DirectionalLight3D
		if light == null or light.get_viewport() != get_viewport() \
				or not light.is_visible_in_tree() or light.light_energy <= 0.0:
			continue
		if light.light_negative or light.shadow_enabled:
			return result
		active_directional_lights.append(light)
	if active_directional_lights.size() > 1:
		return result
	for light_type in ["OmniLight3D", "SpotLight3D"]:
		for candidate in get_tree().root.find_children("*", light_type, true, false):
			var local_light := candidate as Light3D
			if local_light != null and local_light.get_viewport() == get_viewport() \
					and local_light.is_visible_in_tree() \
					and local_light.light_energy > 0.0:
				return result
	result["supported"] = true
	if active_directional_lights.is_empty():
		return result
	_directional_light = active_directional_lights[0]
	var directional_linear := _directional_light.light_color.srgb_to_linear()
	result["directional_color"] = directional_linear
	result["directional_energy"] = _directional_light.light_energy
	result["directional_direction"] = \
		_directional_light.global_transform.basis.z.normalized()
	return result


func _resolve_directional_light() -> DirectionalLight3D:
	if get_tree() == null:
		return null
	var selected: DirectionalLight3D
	for candidate in get_tree().root.find_children(
		"*", "DirectionalLight3D", true, false
	):
		var light := candidate as DirectionalLight3D
		if light == null or light.get_viewport() != get_viewport() \
				or not light.is_visible_in_tree() or light.light_negative:
			continue
		if selected == null or light.light_energy > selected.light_energy:
			selected = light
	return selected


static func _append_vec4(values: PackedFloat32Array, value: Vector4) -> void:
	values.append(value.x)
	values.append(value.y)
	values.append(value.z)
	values.append(value.w)


func _submit_native_captures() -> void:
	var submitted_this_frame := 0
	var deferred_attempts_remaining := _deferred_interaction_requests.size()
	# Before any coverage exists, feed one immutable surface at a time. Initial
	# pipeline creation, arena allocation and field upload otherwise concentrate
	# up to eight captures in the first render callback and can prevent physics
	# from advancing for seconds. Normal bounded throughput resumes immediately
	# after the first active chunk proves the render path is warm.
	var submission_limit := 1 if _activated_chunks < 8 else 2
	while _render_request_routes.size() < RENDER_SUBMISSION_CAPACITY \
			and submitted_this_frame < submission_limit:
		var retry_deferred := deferred_attempts_remaining > 0
		var request := _deferred_interaction_requests.pop_front() \
				if retry_deferred else Dictionary(_backend_terrain.call(
					"pop_gpu_resident_render_request", true
				))
		if retry_deferred:
			deferred_attempts_remaining -= 1
		var request_status := str(request.get("status", ""))
		if not retry_deferred and request_status in ["EMPTY", "DISABLED"]:
			request = Dictionary(_backend_terrain.call(
				"pop_gpu_resident_render_request", false
			))
			request_status = str(request.get("status", ""))
		if request_status in ["EMPTY", "DISABLED"]:
			return
		var request_error := _validate_native_request(request)
		if not request_error.is_empty():
			_reject_native_request(request, request_error)
			continue
		var identity: Dictionary = request.get("identity", {})
		# A committed edit is already bounded by its immutable dirty cohort and has
		# a two-frame publication contract. Let that lane fill the extraction queue;
		# cold/background streaming remains capped so relocation cannot halt frames.
		if bool(identity.get("incremental_edit", false)):
			submission_limit = NATIVE_SUBMISSIONS_PER_FRAME
		var interaction_request := bool(identity.get("incremental_edit", false)) \
				or bool(identity.get("interaction_priority", false)) \
				or bool(identity.get("local_publication_priority", false))
		if interaction_request:
			_interaction_native_requests_admitted += 1
		# Same-callback edit precommit requires current application identity before
		# dispatch. A focus refresh can extract concurrently with CPU application
		# and is generation-validated at preparation/publication; gating it here
		# serializes cold approach behind CPU work.
		if bool(identity.get("incremental_edit", false)):
			var readiness := Dictionary(_backend_terrain.call(
				"get_gpu_resident_render_chunk_readiness", identity
			))
			var readiness_status := str(readiness.get("status", ""))
			if readiness_status == "WAITING_APPLICATION":
				_deferred_interaction_requests.append(request)
				_interaction_application_deferrals += 1
				_last_interaction_application_deferral = {
					"identity": identity.duplicate(true),
					"readiness": readiness.duplicate(true),
					"process_frame": _process_frame,
				}
				continue
			if readiness_status != "READY" \
					or not bool(readiness.get("ready", false)):
				_reject_native_request(request, str(readiness.get(
					"error", "interactive GPU request became stale before admission"
				)))
				continue
		if _try_admit_active_transition_remask(request):
			submitted_this_frame += 1
			continue
		var group_key := _group_key(identity)
		if _groups.has(group_key) and bool(Dictionary(_groups[group_key]).get(
			"retiring", false
		)):
			var retiring_group := Dictionary(_groups[group_key])
			if bool(retiring_group.get("dormant_retirement", false)):
				# Demand can return before the render thread acknowledges the
				# deactivation already in flight. Retain the new native token and
				# bind it to the cached buffers as soon as that callback arrives.
				var pending_requests: Dictionary = retiring_group.get(
					"pending_dormant_requests", {}
				)
				var pending_surface := str(identity.get("surface", ""))
				if pending_requests.has(pending_surface):
					_reject_native_request(
						Dictionary(pending_requests[pending_surface]),
						"newer dormant return request superseded it"
					)
				pending_requests[pending_surface] = request.duplicate(true)
				retiring_group["pending_dormant_requests"] = pending_requests
				_groups[group_key] = retiring_group
				_record_lifecycle_event("DORMANT_RETURN_HELD", group_key, {
					"surface": pending_surface,
					"request_id": int(request.get("request_id", 0)),
				})
				submitted_this_frame += 1
				continue
			_reject_native_request(request, "resident chunk group is retiring")
			continue
		if not _groups.has(group_key) \
				and _groups.size() >= _tracked_group_capacity():
			_reject_native_request(request, "resident chunk capacity reached")
			continue
		var surface := str(identity.get("surface", ""))
		var group: Dictionary = _groups.get(group_key, _new_group(identity))
		if Dictionary(group.get("requests", {})).has(surface):
			if bool(group.get("dormant", false)):
				# Dormant residency deliberately keeps the validated GPU buffers and
				# publication sequence. Runtime demand reactivation republishes the
				# same immutable generation with a fresh native request token. Rebind
				# that token to the retained entry instead of dispatching extraction a
				# second time or rejecting it as a duplicate.
				var dormant_requests: Dictionary = group.get("requests", {})
				dormant_requests[surface] = {
					"request_id": int(request.get("request_id", 0)),
					"identity": identity.duplicate(true),
					"bounds_min": request.get("bounds_min", Vector3.ZERO),
					"bounds_max": request.get("bounds_max", Vector3.ZERO),
				}
				var dormant_native_validated: Dictionary = group.get(
					"native_validated", {}
				)
				dormant_native_validated.erase(surface)
				group["requests"] = dormant_requests
				group["native_validated"] = dormant_native_validated
				group["validated"] = false
				group["native_prepared"] = false
				group["interaction_activation_priority"] = (
					bool(identity.get("incremental_edit", false))
					or bool(identity.get("interaction_priority", false))
					or bool(identity.get("local_publication_priority", false))
				)
				group["collision_activation_priority"] = bool(
					group["interaction_activation_priority"]
				)
				group["next_validation_frame"] = _process_frame
				_groups[group_key] = group
				_record_lifecycle_event("DORMANT_REBOUND", group_key, {
					"surface": surface,
					"request_id": int(request.get("request_id", 0)),
				})
				submitted_this_frame += 1
				continue
			_reject_native_request(request, "duplicate resident chunk surface")
			continue
		var sequence := _next_publication_sequence
		_next_publication_sequence += 1
		var render_request_id := int(_effect.submit_native_packed_input(
			Array(request.get("gpu_input_buffers", [])),
			int(request.get("cell_count", 0)),
			identity,
			sequence,
			false,
			request.get("bounds_min", Vector3.ZERO),
			request.get("bounds_max", Vector3.ZERO),
			bool(request.get("proven_empty", false))
		))
		if render_request_id <= 0:
			_reject_native_request(request, str(_effect.get_status().get(
				"last_error", "global renderer rejected resident surface"
			)))
			continue
		var requests: Dictionary = group.get("requests", {})
		var sequences: Dictionary = group.get("sequences", {})
		requests[surface] = {
			"request_id": int(request.get("request_id", 0)),
			"identity": identity.duplicate(true),
			"bounds_min": request.get("bounds_min", Vector3.ZERO),
			"bounds_max": request.get("bounds_max", Vector3.ZERO),
		}
		sequences[surface] = sequence
		group["requests"] = requests
		group["sequences"] = sequences
		_groups[group_key] = group
		_record_lifecycle_event("CAPTURE_SUBMITTED", group_key, {
			"surface": surface,
			"render_request_id": render_request_id,
		})
		var route := {"group_key": group_key, "surface": surface}
		_render_request_routes[render_request_id] = route
		_entry_routes[_entry_token(identity, sequence)] = route
		_submitted_surfaces += 1
		submitted_this_frame += 1


func _try_admit_active_transition_remask(request: Dictionary) -> bool:
	var identity := Dictionary(request.get("identity", {}))
	var desired_mask := int(identity.get("transition_mask", 0))
	var surface := str(identity.get("surface", ""))
	var source_group_key := ""
	for candidate_key_value in _groups.keys():
		var candidate_key := str(candidate_key_value)
		var candidate := Dictionary(_groups[candidate_key])
		if not bool(candidate.get("active", false)) \
				or bool(candidate.get("retiring", false)) \
				or bool(candidate.get("remask_pending", false)):
			continue
		var existing_request := Dictionary(Dictionary(candidate.get(
			"requests", {}
		)).get(surface, {}))
		var existing := Dictionary(existing_request.get("identity", {}))
		if existing.is_empty():
			continue
		var geometry_matches := true
		for field in [
			"page_x", "page_y", "page_z", "lod", "generation",
			"source_revision", "world_revision",
		]:
			if existing.get(field) != identity.get(field):
				geometry_matches = false
				break
		if not geometry_matches \
				or int(existing.get("transition_mask", 0)) == desired_mask:
			continue
		if (desired_mask & ~int(existing.get("cached_transition_mask", 0))) != 0:
			continue
		source_group_key = candidate_key
		break
	if source_group_key.is_empty():
		return false
	var validation := Dictionary(_backend_terrain.call(
		"validate_gpu_resident_render_request",
		int(request.get("request_id", 0)),
		identity
	))
	var validation_status := str(validation.get("status", ""))
	if validation_status == "WAITING_APPLICATION":
		_deferred_interaction_requests.append(request)
		_interaction_application_deferrals += 1
		return true
	if validation_status != "READY" \
			or not bool(validation.get("request_accepted", false)):
		_reject_native_request(request, str(validation.get(
			"error", "resident transition remask request became stale"
		)))
		return true
	var group := Dictionary(_groups[source_group_key])
	var pending := Dictionary(group.get("pending_remask_requests", {}))
	pending[surface] = request.duplicate(true)
	group["pending_remask_requests"] = pending
	_groups[source_group_key] = group
	for required_surface in _required_surfaces(group):
		if not pending.has(required_surface):
			return true
	var remask_entries: Array = []
	var requests := Dictionary(group.get("requests", {}))
	var sequences := Dictionary(group.get("sequences", {}))
	for required_surface in _required_surfaces(group):
		var desired_request := Dictionary(pending[required_surface])
		var desired_identity := Dictionary(desired_request.get("identity", {}))
		if int(desired_identity.get("transition_mask", -1)) != desired_mask:
			_reject_group(source_group_key, "resident remask surfaces disagree on transition mask")
			return true
		remask_entries.append({
			"identity": desired_identity.duplicate(true),
			"publication_sequence": int(sequences.get(required_surface, 0)),
		})
	group["remask_pending"] = true
	group["remask_transition_mask"] = desired_mask
	group["remasked"] = {}
	_groups[source_group_key] = group
	if not _effect.remask_active_entries(remask_entries, source_group_key):
		group["remask_pending"] = false
		group.erase("pending_remask_requests")
		_groups[source_group_key] = group
		_last_error = str(_effect.get_status().get(
			"last_error", "resident transition remask submission failed"
		))
	return true


func _tracked_group_capacity() -> int:
	# Resident capacity bounds active chunks. The effect arena separately reserves
	# candidate slots for the next generation, so the controller must admit both
	# halves of that double buffer or an atomic replacement cohort can deadlock.
	return _resident_capacity * 2


func _try_precommit_same_layout_edit(group_key: String) -> bool:
	if not _groups.has(group_key):
		return false
	var group: Dictionary = _groups[group_key]
	if bool(group.get("retiring", false)) \
			or bool(group.get("active", false)) \
			or bool(group.get("activation_queued", false)):
		return false
	var requests: Dictionary = group.get("requests", {})
	for surface in _required_surfaces(group):
		if not requests.has(surface):
			return false
	var terrain_request: Dictionary = requests.get("terrain", {})
	var terrain_identity: Dictionary = terrain_request.get("identity", {})
	if not bool(terrain_identity.get("incremental_edit", false)):
		return false
	var preflight := Dictionary(_backend_terrain.call(
		"get_gpu_resident_render_activation_cohort", terrain_identity
	))
	var expected_members := int(preflight.get("replacement_count", 0))
	if not bool(preflight.get("cohort_built", false)) \
			or not bool(preflight.get("authoritative_coverage_complete", false)) \
			or not bool(preflight.get("same_layout_edit", false)) \
			or expected_members <= 0 \
			or int(preflight.get("retirement_count", 0)) != 0:
		var rejection_reason := str(preflight.get(
			"same_layout_edit_rejection_reason", "preflight_contract"
		))
		if rejection_reason == "none" or rejection_reason.is_empty():
			rejection_reason = "preflight_contract"
		_same_callback_edit_precommit_rejections[rejection_reason] = int(
			_same_callback_edit_precommit_rejections.get(rejection_reason, 0)
		) + 1
		_record_lifecycle_event("EDIT_PRECOMMIT_REJECTED", group_key, {
			"reason": rejection_reason,
			"status": str(preflight.get("status", "")),
			"cohort_built": bool(preflight.get("cohort_built", false)),
			"same_layout_edit": bool(preflight.get("same_layout_edit", false)),
			"rejection_key": Dictionary(preflight.get(
				"same_layout_edit_rejection_key", {}
			)).duplicate(true),
			"replacement_count": expected_members,
			"retirement_count": int(preflight.get("retirement_count", 0)),
		})
		return false
	var cohort_group_keys: Array[String] = []
	var source_revision := int(terrain_identity.get("source_revision", 0))
	var world_revision := int(terrain_identity.get("world_revision", 0))
	for candidate_key_value in _groups.keys():
		var candidate_key := str(candidate_key_value)
		var candidate := Dictionary(_groups[candidate_key])
		if bool(candidate.get("retiring", false)) \
				or bool(candidate.get("active", false)) \
				or bool(candidate.get("activation_queued", false)):
			continue
		var candidate_requests := Dictionary(candidate.get("requests", {}))
		var candidate_identity := Dictionary(Dictionary(candidate_requests.get(
			"terrain", {}
		)).get("identity", {}))
		if not bool(candidate_identity.get("incremental_edit", false)) \
				or int(candidate_identity.get("source_revision", 0)) != source_revision \
				or int(candidate_identity.get("world_revision", 0)) != world_revision:
			continue
		for surface in _required_surfaces(candidate):
			if not candidate_requests.has(surface):
				return false
		cohort_group_keys.append(candidate_key)
	if cohort_group_keys.size() != expected_members \
			or not cohort_group_keys.has(group_key):
		return false
	cohort_group_keys.sort()
	var inventories: Array = []
	for candidate_key in cohort_group_keys:
		var candidate := Dictionary(_groups[candidate_key])
		var inventory := _group_identities(candidate)
		var preparation := Dictionary(_backend_terrain.call(
			"prepare_gpu_resident_render_chunk", inventory
		))
		if str(preparation.get("status", "")) != "PREPARED" \
				or not bool(preparation.get("prepared", false)):
			return false
		inventories.append(inventory)
	var cohort := Dictionary(_backend_terrain.call(
		"get_gpu_resident_render_activation_cohort", terrain_identity
	))
	var chunks: Array = cohort.get("chunks", [])
	if str(cohort.get("status", "")) != "READY" \
			or not bool(cohort.get("ready", false)) \
			or not bool(cohort.get("same_layout_edit", false)) \
			or chunks.size() != expected_members \
			or int(cohort.get("activation_required_count", 0)) != expected_members \
			or not Array(cohort.get("retirements", [])).is_empty():
		return false
	var expected_chunk_routes := {}
	for candidate_key in cohort_group_keys:
		var candidate := Dictionary(_groups[candidate_key])
		var candidate_identity := Dictionary(Dictionary(Dictionary(candidate.get(
			"requests", {}
		)).get("terrain", {})).get("identity", {}))
		expected_chunk_routes[_activation_chunk_key(candidate_identity)] = candidate_key
	for chunk_value in chunks:
		if not expected_chunk_routes.has(_activation_chunk_key(Dictionary(chunk_value))):
			return false
	var validated_by_group := {}
	var activation_entries: Array[Dictionary] = []
	var newly_validated_surfaces := 0
	for candidate_key in cohort_group_keys:
		var candidate := Dictionary(_groups[candidate_key])
		var candidate_requests := Dictionary(candidate.get("requests", {}))
		var candidate_sequences := Dictionary(candidate.get("sequences", {}))
		var native_validated := Dictionary(candidate.get(
			"native_validated", {}
		)).duplicate()
		for surface in _required_surfaces(candidate):
			var request: Dictionary = candidate_requests.get(surface, {})
			if not bool(native_validated.get(surface, false)):
				var validation := Dictionary(_backend_terrain.call(
					"validate_gpu_resident_render_request",
					int(request.get("request_id", 0)),
					Dictionary(request.get("identity", {}))
				))
				if str(validation.get("status", "")) != "READY" \
						or not bool(validation.get("ready", false)) \
						or not bool(validation.get("request_accepted", false)):
					return false
				native_validated[surface] = true
				newly_validated_surfaces += 1
			activation_entries.append({
				"identity": Dictionary(request.get("identity", {})),
				"publication_sequence": int(candidate_sequences.get(surface, 0)),
			})
		validated_by_group[candidate_key] = native_validated
	var cohort_id := _next_activation_cohort_id
	_next_activation_cohort_id += 1
	for candidate_key in cohort_group_keys:
		var candidate := Dictionary(_groups[candidate_key])
		var candidate_requests := Dictionary(candidate.get("requests", {}))
		var candidate_identity := Dictionary(Dictionary(candidate_requests.get(
			"terrain", {}
		)).get("identity", {}))
		candidate["native_validated"] = Dictionary(validated_by_group[candidate_key])
		candidate["validated"] = true
		candidate["native_prepared"] = true
		candidate["native_active"] = false
		candidate["activation_queued"] = true
		candidate["activation_cohort_id"] = cohort_id
		candidate["collision_activation_priority"] = true
		_groups[candidate_key] = candidate
		_prepared_group_routes[_activation_chunk_key(candidate_identity)] = candidate_key
		_activation_retry_membership.erase(candidate_key)
		_record_lifecycle_event("NATIVE_PREPARED", candidate_key, {
			"collision_priority": true,
			"same_callback_precommit": true,
			"cohort_members": expected_members,
		})
	_activation_cohorts[cohort_id] = {
		"group_keys": cohort_group_keys.duplicate(),
		"inventories": inventories.duplicate(true),
		"activation_entries": activation_entries.duplicate(true),
		"retirement_group_keys": [],
		"retirement_entries": [],
		"selected_chunks": chunks.duplicate(true),
		"native_committed": false,
		"regional": expected_members > 1,
		"authoritative_seed": terrain_identity.duplicate(true),
	}
	_record_lifecycle_event("COHORT_SELECTED", group_key, {
		"cohort_id": cohort_id,
		"regional": expected_members > 1,
		"member_count": expected_members,
		"same_callback_precommit": true,
	})
	_activation_cohorts_queued += 1
	_validated_surfaces += newly_validated_surfaces
	_same_callback_edit_precommits += 1
	_same_callback_edit_precommit_chunks += expected_members
	if not _effect.stage_activation_entries(activation_entries):
		_reject_activation_cohort(
			group_key, "global renderer rejected staged same-layout edit"
		)
		return false
	_record_lifecycle_event("ACTIVATION_REQUESTED", group_key, {
		"cohort_id": cohort_id,
		"same_callback_precommit": true,
	})
	return true


func _drain_effect_events() -> void:
	var deadline := _effect_event_clock_usec() + EFFECT_EVENT_BUDGET_USEC
	var processed := 0
	while processed < EFFECT_EVENT_CAPACITY_PER_FRAME:
		if processed > 0 and _effect_event_clock_usec() >= deadline:
			_effect_event_budget_stops += 1
			break
		var event: Dictionary = _effect.pop_event()
		if event.is_empty():
			break
		processed += 1
		_effect_events_processed += 1
		var route := _route_for_event(event)
		if route.is_empty():
			_unrouted_effect_events += 1
			if _unrouted_effect_event_examples.size() < 8:
				_unrouted_effect_event_examples.append(event.duplicate(true))
			continue
		var group_key := str(route.get("group_key", ""))
		if not _groups.has(group_key):
			continue
		match str(event.get("status", "")):
			"PREPARED":
				_record_surface_details(
					group_key, str(route.get("surface", "")), event
				)
				_mark_surface(group_key, "prepared", str(route.get("surface", "")))
				_record_lifecycle_event("SURFACE_PREPARED", group_key, {
					"surface": str(route.get("surface", "")),
					"gpu_dispatch_ticks_usec": int(event.get("gpu_dispatch_ticks_usec", 0)),
					"gpu_readback_ticks_usec": int(event.get("gpu_readback_ticks_usec", 0)),
					"effect_ticks_usec": int(event.get("ticks_usec", 0)),
					"regenerated_cells": int(event.get("entry_cell_count", 0)),
					"output_triangles": int(event.get("entry_index_count", 0)) / 3,
				})
				if not bool(Dictionary(_groups.get(group_key, {})).get(
					"retiring", false
				)):
					_try_validate_group(group_key)
			"ACTIVE":
				var active_group := Dictionary(_groups.get(group_key, {}))
				var active_request := Dictionary(Dictionary(active_group.get(
					"requests", {}
				)).get(str(route.get("surface", "")), {}))
				var active_identity := Dictionary(active_request.get("identity", {}))
				if bool(active_identity.get("incremental_edit", false)):
					_recent_incremental_activations.append({
						"identity": active_identity.duplicate(true),
						"surface": str(route.get("surface", "")),
						"empty": bool(event.get("entry_empty", false)),
						"effect_ticks_usec": int(event.get("ticks_usec", 0)),
						"observed_ticks_usec": Time.get_ticks_usec(),
						"frame": _process_frame,
					})
					while _recent_incremental_activations.size() > 32:
						_recent_incremental_activations.pop_front()
				_mark_surface(group_key, "activated", str(route.get("surface", "")))
				if not bool(Dictionary(_groups.get(group_key, {})).get(
					"retiring", false
				)):
					_try_finish_activation_cohort(group_key)
			"ACTIVATION_STAGED":
				_mark_surface(
					group_key, "activation_staged", str(route.get("surface", ""))
				)
				if not bool(Dictionary(_groups.get(group_key, {})).get(
					"retiring", false
				)):
					_try_commit_activation_cohort(group_key)
			"REMASKED":
				_mark_surface(group_key, "remasked", str(route.get("surface", "")))
				var remask_group := Dictionary(_groups.get(group_key, {}))
				if _surface_set_complete(remask_group, "remasked"):
					_finish_transition_remask(group_key)
			"FIRST_DRAW":
				var first_draw_group := Dictionary(_groups.get(group_key, {}))
				var first_draw_request := Dictionary(Dictionary(first_draw_group.get(
					"requests", {}
				)).get(str(route.get("surface", "")), {}))
				var first_draw_identity := Dictionary(first_draw_request.get(
					"identity", {}
				))
				if bool(first_draw_identity.get("incremental_edit", false)):
					_recent_incremental_first_draws.append({
						"identity": first_draw_identity.duplicate(true),
						"surface": str(route.get("surface", "")),
						"effect_ticks_usec": int(event.get("ticks_usec", 0)),
						"observed_ticks_usec": Time.get_ticks_usec(),
						"frame": _process_frame,
					})
					while _recent_incremental_first_draws.size() > 32:
						_recent_incremental_first_draws.pop_front()
				_record_lifecycle_event("FIRST_DRAW", group_key, {
					"surface": str(route.get("surface", "")),
					"effect_ticks_usec": int(event.get("ticks_usec", 0)),
					"index_count": int(event.get("entry_index_count", 0)),
				})
			"REJECTED":
				var rejection_error := str(event.get(
					"error", "GPU entry rejected"
				))
				if bool(Dictionary(_groups.get(group_key, {})).get(
					"dormant_retirement", false
				)):
					var failed_deactivation := Dictionary(_groups[group_key])
					failed_deactivation["retiring"] = false
					failed_deactivation["dormant_retirement"] = false
					_groups[group_key] = failed_deactivation
					_begin_group_retirement(
						group_key, "dormant_deactivation_failed", true
					)
					continue
				if bool(Dictionary(_groups.get(group_key, {})).get(
					"activation_queued", false
				)):
					var rejected_group := Dictionary(_groups[group_key])
					var rejected_cohort_id := int(rejected_group.get(
						"activation_cohort_id", 0
					))
					if rejected_cohort_id > 0 and _activation_cohorts.has(
						rejected_cohort_id
					) and bool(Dictionary(_activation_cohorts[
						rejected_cohort_id
					]).get("native_committed", false)):
						_fail_closed(
							"committed GPU activation failed: %s" % rejection_error
						)
						return
					_reject_activation_cohort(group_key, rejection_error)
					continue
				if _is_stale_render_event(rejection_error):
					_supersede_group(group_key)
				else:
					_reject_group(group_key, rejection_error)
			"RETIRED", "SUPERSEDED":
				_mark_surface(group_key, "retired", str(route.get("surface", "")))
				_try_finish_retirement(group_key)
			"DEACTIVATED":
				_mark_surface(group_key, "deactivated", str(route.get("surface", "")))
				_try_finish_retirement(group_key)
	_effect_event_max_processed_per_frame = maxi(
		_effect_event_max_processed_per_frame, processed
	)
	if processed >= EFFECT_EVENT_CAPACITY_PER_FRAME:
		_effect_event_budget_stops += 1


func _effect_event_clock_usec() -> int:
	return Time.get_ticks_usec()


func _try_validate_group(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	if bool(group.get("retiring", false)) \
			or bool(group.get("validated", false)) \
			or not _surface_set_complete(
		group, "prepared"
	):
		return
	if _process_frame < int(group.get("next_validation_frame", 0)):
		return
	var requests: Dictionary = group.get("requests", {})
	for surface in _required_surfaces(group):
		if bool(Dictionary(group.get("native_validated", {})).get(surface, false)):
			continue
		var request: Dictionary = requests.get(surface, {})
		var validation := Dictionary(_backend_terrain.call(
			"validate_gpu_resident_render_request",
			int(request.get("request_id", 0)),
			Dictionary(request.get("identity", {}))
		))
		var validation_status := str(validation.get("status", ""))
		if validation_status.begins_with("STALE"):
			var stale_validated: Dictionary = group.get("native_validated", {})
			stale_validated[surface] = true
			group["native_validated"] = stale_validated
			_groups[group_key] = group
			if _park_dormant_group(group_key):
				return
			_supersede_group(group_key)
			return
		if bool(validation.get("request_accepted", false)):
			var native_validated: Dictionary = group.get("native_validated", {})
			native_validated[surface] = true
			group["native_validated"] = native_validated
			_groups[group_key] = group
			_validated_surfaces += 1
		if validation_status not in ["READY", "WAITING_APPLICATION"]:
			_reject_group(group_key, str(validation.get(
				"error", "native resident admission rejected the chunk"
			)))
			return
	if not _surface_set_complete(group, "native_validated"):
		return
	var terrain_request: Dictionary = requests.get("terrain", {})
	var readiness := Dictionary(_backend_terrain.call(
		"get_gpu_resident_render_chunk_readiness",
		Dictionary(terrain_request.get("identity", {}))
	))
	var readiness_status := str(readiness.get("status", ""))
	if bool(group.get("dormant", false)) \
			and not bool(group.get("dormant_saw_application_absent", false)):
		if readiness_status == "WAITING_APPLICATION":
			group["dormant_saw_application_absent"] = true
		elif readiness_status == "READY" and bool(readiness.get(
			"external_activation_required", false
		)):
			group["dormant_saw_application_absent"] = true
		elif readiness_status == "READY":
			group["next_validation_frame"] = (
				_process_frame + DORMANT_APPLICATION_RETRY_FRAMES
			)
			_groups[group_key] = group
			return
	if readiness_status == "WAITING_APPLICATION":
		var wait_started := int(group.get(
			"application_wait_started_frame", -1
		))
		if wait_started < 0:
			wait_started = _process_frame
		group["application_wait_started_frame"] = wait_started
		group["next_validation_frame"] = _process_frame + (
			DORMANT_APPLICATION_RETRY_FRAMES
			if bool(group.get("dormant", false))
			else APPLICATION_WAIT_RETRY_FRAMES
		)
		_groups[group_key] = group
		if not bool(group.get("dormant", false)) \
				and _process_frame - wait_started >= APPLICATION_WAIT_FRAME_LIMIT:
			_application_wait_expirations += 1
			_reject_group(
				group_key,
				"GPU resident CPU-application wait expired",
				readiness
			)
		return
	if str(readiness.get("status", "")) != "READY" \
			or not bool(readiness.get("ready", false)):
		if str(readiness.get("status", "")).begins_with("STALE"):
			if _park_dormant_group(group_key):
				return
			_supersede_group(group_key)
			return
		_reject_group(group_key, str(readiness.get(
			"error", "native resident chunk readiness rejected the chunk"
		)))
		return
	group["validated"] = true
	var preparation := Dictionary(_backend_terrain.call(
		"prepare_gpu_resident_render_chunk", _group_identities(group)
	))
	var preparation_status := str(preparation.get("status", ""))
	if preparation_status.begins_with("STALE"):
		_groups[group_key] = group
		if _park_dormant_group(group_key):
			return
		_supersede_group(group_key)
		return
	if preparation_status != "PREPARED" \
			or not bool(preparation.get("prepared", false)):
		_groups[group_key] = group
		_reject_group(group_key, str(preparation.get(
			"error", "native resident preparation rejected the chunk"
		)))
		return
	group["native_prepared"] = true
	var prepared_identity := Dictionary(terrain_request.get("identity", {}))
	group["interaction_activation_priority"] = (
		bool(readiness.get("collision_required", false))
		or bool(prepared_identity.get("incremental_edit", false))
		or bool(prepared_identity.get("interaction_priority", false))
		or bool(prepared_identity.get("local_publication_priority", false))
	)
	# Retain the old field while smoke fixtures and persisted diagnostic captures
	# transition to the lane's correct interaction-wide meaning.
	group["collision_activation_priority"] = bool(
		group["interaction_activation_priority"]
	)
	_groups[group_key] = group
	_record_lifecycle_event("NATIVE_PREPARED", group_key, {
			"interaction_priority": bool(group.get("interaction_activation_priority", false)),
	})
	_prepared_group_routes[_activation_chunk_key(Dictionary(
		terrain_request.get("identity", {})
	))] = group_key
	_queue_activation_cohort_retry(group_key)


func _pending_group_keys() -> Array:
	var interaction_keys: Array = []
	var background_keys: Array = []
	for key in _groups:
		var group: Dictionary = _groups[key]
		if bool(group.get("active", false)) or bool(group.get("retiring", false)):
			continue
		var requests: Dictionary = group.get("requests", {})
		var request: Dictionary = requests.get("terrain", {})
		if request.is_empty() and not requests.is_empty():
			request = Dictionary(requests.values()[0])
		var identity: Dictionary = request.get("identity", {})
		if bool(identity.get("incremental_edit", false)) \
				or bool(identity.get("interaction_priority", false)) \
				or bool(identity.get("local_publication_priority", false)):
			interaction_keys.append(key)
		else:
			background_keys.append(key)
	interaction_keys.append_array(background_keys)
	return interaction_keys


func _retry_prepared_groups(group_keys: Array = _pending_group_keys()) -> void:
	if group_keys.is_empty():
		_prepared_group_scan_cursor = 0
		return
	_prepared_group_scan_cursor %= group_keys.size()
	var queued_cohort_retries := 0
	var inspection_count := mini(
		group_keys.size(), GROUP_MAINTENANCE_INSPECTIONS_PER_FRAME
	)
	for offset in range(inspection_count):
		var group_key_value = group_keys[
			(_prepared_group_scan_cursor + offset) % group_keys.size()
		]
		var group_key := str(group_key_value)
		if not _groups.has(group_key):
			continue
		var group: Dictionary = _groups[group_key]
		if bool(group.get("retiring", false)):
			continue
		if not bool(group.get("validated", false)):
			_try_validate_group(group_key)
		if not _groups.has(group_key):
			continue
		group = Dictionary(_groups[group_key])
		if queued_cohort_retries >= ACTIVATION_COHORT_RETRY_CAPACITY \
				or bool(group.get("retiring", false)) \
				or bool(group.get("active", false)) \
				or bool(group.get("activation_queued", false)) \
				or not bool(group.get("native_prepared", false)) \
				or _activation_retry_membership.has(group_key):
			continue
		_queue_activation_cohort_retry(group_key)
		queued_cohort_retries += 1
	_prepared_group_scan_cursor = (
		_prepared_group_scan_cursor + inspection_count
	) % group_keys.size()


func _supersede_stale_incomplete_groups(group_keys: Array = _pending_group_keys()) -> void:
	if group_keys.is_empty():
		_incomplete_group_scan_cursor = 0
		return
	_incomplete_group_scan_cursor %= group_keys.size()
	var inspection_count := mini(
		group_keys.size(), GROUP_MAINTENANCE_INSPECTIONS_PER_FRAME
	)
	for offset in range(inspection_count):
		var group_key_value = group_keys[
			(_incomplete_group_scan_cursor + offset) % group_keys.size()
		]
		var group_key := str(group_key_value)
		if not _groups.has(group_key):
			continue
		var group: Dictionary = _groups[group_key]
		if bool(group.get("active", false)) \
				or bool(group.get("retiring", false)) \
				or _surface_set_complete(group, "prepared") \
				or _process_frame < int(group.get(
					"next_incomplete_probe_frame", 0
				)):
			continue
		var requests: Dictionary = group.get("requests", {})
		if requests.is_empty():
			continue
		var request: Dictionary = requests.get("terrain", {})
		if request.is_empty():
			request = Dictionary(requests.values()[0])
		var readiness := Dictionary(_backend_terrain.call(
			"get_gpu_resident_render_chunk_readiness",
			Dictionary(request.get("identity", {}))
		))
		var readiness_status := str(readiness.get("status", ""))
		group["last_incomplete_status"] = readiness_status
		group["next_incomplete_probe_frame"] = (
			_process_frame + APPLICATION_WAIT_RETRY_FRAMES
		)
		_groups[group_key] = group
		if readiness_status.begins_with("STALE"):
			_stale_incomplete_groups_superseded += 1
			_supersede_group(group_key)
	_incomplete_group_scan_cursor = (
		_incomplete_group_scan_cursor + inspection_count
	) % group_keys.size()


func _try_queue_activation_cohort(group_key: String) -> bool:
	if not _groups.has(group_key):
		return false
	var group: Dictionary = _groups[group_key]
	if bool(group.get("retiring", false)) \
			or bool(group.get("activation_queued", false)) \
			or not bool(group.get("native_prepared", false)):
		return false
	var wait_signature := str(group.get("activation_wait_signature", ""))
	if not wait_signature.is_empty():
		var shared_probe_frame := int(_activation_wait_probe_frames.get(
			wait_signature, 0
		))
		if _process_frame < shared_probe_frame:
			_activation_cohort_retry_coalesced += 1
			group["next_activation_retry_frame"] = shared_probe_frame
			_groups[group_key] = group
			_queue_activation_cohort_retry(group_key)
			return false
	var terrain_identity := Dictionary(Dictionary(group.get(
		"requests", {}
	)).get("terrain", {})).get("identity", {})
	# Priority chooses which interaction candidate starts a retry round. A blocked
	# maximum-priority shell member must not jump ahead of every lower-priority
	# member again on each frame, or one repeatedly incomplete boundary can starve
	# the exact player chunk forever.
	group["activation_cohort_query_count"] = int(group.get(
		"activation_cohort_query_count", 0
	)) + 1
	_groups[group_key] = group
	var phase_start := Time.get_ticks_usec() if _stage_timing_enabled else 0
	var cohort: Dictionary
	var measure_native_timing := _stage_timing_enabled \
			and _activation_cohort_retry_attempts % 30 == 1
	if measure_native_timing:
		cohort = _backend_terrain.call("get_gpu_resident_render_activation_cohort", terrain_identity, true)
	else:
		cohort = _backend_terrain.call("get_gpu_resident_render_activation_cohort", terrain_identity)
	group = Dictionary(_groups.get(group_key, group))
	group["last_activation_cohort_status"] = str(cohort.get("status", ""))
	group["last_activation_cohort_error"] = str(cohort.get("error", ""))
	group["last_activation_interaction_region_isolated"] = bool(cohort.get(
		"interaction_region_isolated", false
	))
	group["last_activation_cohort_built"] = bool(cohort.get("cohort_built", false))
	group["last_activation_cohort_candidate_count"] = int(cohort.get(
		"cohort_candidate_count", 0
	))
	_groups[group_key] = group
	_record_activation_cohort_query(cohort)
	if _stage_timing_enabled:
		phase_start = _record_stage_time("activation_native_query", phase_start)
		if measure_native_timing:
			var native_timing: Dictionary = cohort.get("query_timing_usec", {})
			for stage in native_timing:
				_accumulate_stage_time("native_query_" + str(stage), int(native_timing[stage]))
	var cohort_status := str(cohort.get("status", ""))
	# Native STALE_APPLICATION rejects the seed before any region selection.
	# Retire it without spending the expensive-query budget on obsolete work.
	if cohort_status == "STALE_APPLICATION":
		_activation_stale_seed_skips += 1
		_record_activation_cohort_wait(cohort)
		if _park_dormant_group(group_key):
			return false
		_supersede_group(group_key)
		return false
	_queue_selected_activation_cohort(group_key, terrain_identity, cohort, phase_start)
	return true


func _queue_selected_activation_cohort(
	group_key: String, terrain_identity: Dictionary, cohort: Dictionary, phase_start: int
) -> void:
	_set_activation_frontend_blocker(group_key, "")
	var cohort_status := str(cohort.get("status", ""))
	if cohort_status == "WAITING_COHORT":
		var wait_signature := _activation_cohort_wait_signature(cohort)
		_record_lifecycle_event("COHORT_WAIT", group_key, {
			"status": cohort_status,
			"signature": wait_signature,
		})
		_record_activation_cohort_wait(cohort)
		if _groups.has(group_key):
			var waiting_group := Dictionary(_groups[group_key])
			var interaction_wait := bool(waiting_group.get(
				"interaction_activation_priority",
				waiting_group.get("collision_activation_priority", false)
			))
			var probe_delay := ACTIVATION_WAIT_INTERACTION_PROBE_FRAMES \
				if interaction_wait else ACTIVATION_WAIT_BACKGROUND_PROBE_FRAMES
			var next_probe_frame := _process_frame + probe_delay
			waiting_group["next_activation_retry_frame"] = next_probe_frame
			if not wait_signature.is_empty():
				waiting_group["activation_wait_signature"] = wait_signature
			_groups[group_key] = waiting_group
			if not wait_signature.is_empty():
				_activation_wait_probe_frames[wait_signature] = maxi(
					int(_activation_wait_probe_frames.get(wait_signature, 0)),
					next_probe_frame
				)
		_queue_activation_cohort_retry(group_key)
		return
	if cohort_status.begins_with("STALE"):
		_record_activation_cohort_wait(cohort)
		if _park_dormant_group(group_key):
			return
		_supersede_group(group_key)
		return
	if cohort_status != "READY" or not bool(cohort.get("ready", false)):
		_reject_group(group_key, str(cohort.get(
			"error", "native activation cohort rejected prepared GPU geometry"
		)))
		return
	if bool(cohort.get("regional", false)):
		# Keep one authority transaction in flight. Every candidate is staged and
		# protected on the render thread before this transaction mutates native
		# coverage, so old draws remain submitted until the final GPU commit.
		if _has_native_committed_activation_in_flight():
			_set_activation_frontend_blocker(
				group_key, "native_committed_transaction_in_flight"
			)
			_queue_activation_cohort_retry(group_key)
			return
	var group_keys: Array[String] = []
	var cohort_member_group_keys: Array[String] = []
	var activation_entries: Array[Dictionary] = []
	var retirement_group_keys: Array[String] = []
	var dormant_retirement_group_keys: Array[String] = []
	var retirement_entries: Array[Dictionary] = []
	var inventories: Array = []
	for member_value in Array(cohort.get("chunks", [])):
		var member := Dictionary(member_value)
		var member_group_key := str(_prepared_group_routes.get(
			_activation_chunk_key(member), ""
		))
		if member_group_key.is_empty() or not _groups.has(member_group_key):
			_set_activation_frontend_blocker(group_key, "prepared_member_route_missing")
			_queue_activation_cohort_retry(group_key)
			return
		var member_group := Dictionary(_groups[member_group_key])
		cohort_member_group_keys.append(member_group_key)
		var activation_required := bool(member.get("activation_required", true))
		if bool(member_group.get("retiring", false)):
			_set_activation_frontend_blocker(group_key, "prepared_member_retiring")
			_queue_activation_cohort_retry(group_key)
			return
		if activation_required:
			# A retained GPU entry may remain visible while a newly admitted native
			# application record requires activation confirmation. Recommitting its
			# existing slot is idempotent and restores the authority handshake.
			if bool(member_group.get("activation_queued", false)) \
					or not bool(member_group.get("native_prepared", false)):
				_set_activation_frontend_blocker(
					group_key, "activation_member_not_stable"
				)
				_queue_activation_cohort_retry(group_key)
				return
			group_keys.append(member_group_key)
		elif not bool(member_group.get("active", false)) \
				or not bool(member_group.get("native_active", false)):
			_set_activation_frontend_blocker(
				group_key, "retained_member_not_active"
			)
			_queue_activation_cohort_retry(group_key)
			return
		var requests: Dictionary = member_group.get("requests", {})
		var sequences: Dictionary = member_group.get("sequences", {})
		var member_identities := _group_identities(member_group)
		var routed_terrain_identity := Dictionary(requests.get(
			"terrain", {}
		)).get("identity", {})
		if _activation_chunk_key(routed_terrain_identity) != \
				_activation_chunk_key(member):
			_fail_closed("GPU activation cohort route changed chunk identity")
			return
		inventories.append(member_identities)
		if activation_required:
			for surface in _required_surfaces(member_group):
				var request := Dictionary(requests.get(surface, {}))
				activation_entries.append({
					"identity": Dictionary(request.get("identity", {})),
					"publication_sequence": int(sequences.get(surface, 0)),
				})
	if _stage_timing_enabled:
		phase_start = _record_stage_time("activation_member_routes", phase_start)
	var retirements := Array(cohort.get("retirements", []))
	var active_routes := _active_group_routes_by_chunk() if not retirements.is_empty() else {}
	var replacement_locations := {}
	for activation_entry in activation_entries:
		replacement_locations[_chunk_location_key(Dictionary(
			Dictionary(activation_entry).get("identity", {})
		))] = true
	for retirement_value in retirements:
		var retirement := Dictionary(retirement_value)
		var retirement_key := _chunk_location_key(retirement)
		var retirement_group_key := str(active_routes.get(retirement_key, ""))
		if retirement_group_key.is_empty():
			if active_routes.has(retirement_key):
				_fail_closed("authoritative GPU retirement has ambiguous active generations")
				return
			_cpu_only_regional_retirements += 1
			continue
		var retirement_group := Dictionary(_groups[retirement_group_key])
		if bool(retirement_group.get("retiring", false)) \
				or bool(retirement_group.get("activation_queued", false)):
			_fail_closed("authoritative GPU retirement is not stable")
			return
		if retirement_group_keys.has(retirement_group_key):
			_fail_closed("authoritative GPU retirement repeats a chunk")
			return
		retirement_group_keys.append(retirement_group_key)
		var retain_dormant := not replacement_locations.has(retirement_key)
		if retain_dormant:
			dormant_retirement_group_keys.append(retirement_group_key)
		var retirement_requests := Dictionary(retirement_group.get("requests", {}))
		var retirement_sequences := Dictionary(retirement_group.get("sequences", {}))
		for surface in _required_surfaces(retirement_group):
			var retirement_request := Dictionary(retirement_requests.get(surface, {}))
			retirement_entries.append({
				"identity": Dictionary(retirement_request.get("identity", {})),
				"publication_sequence": int(retirement_sequences.get(surface, 0)),
				"deactivate": retain_dormant,
			})
	if _stage_timing_enabled:
		_record_stage_time("activation_retirement_routes", phase_start)
	if inventories.is_empty():
		_set_activation_frontend_blocker(group_key, "empty_inventory")
		_queue_activation_cohort_retry(group_key)
		return
	if group_keys.is_empty():
		var retained_activation := Dictionary(_backend_terrain.call(
			"activate_gpu_resident_render_cohort", inventories, terrain_identity
		))
		if str(retained_activation.get("status", "")) != "ACTIVE" \
				or not bool(retained_activation.get("active", false)):
			_fail_closed(str(retained_activation.get(
				"error", "retained GPU activation cohort commit failed"
			)))
			return
		if not retirement_entries.is_empty():
			_mark_groups_retiring(
				retirement_group_keys, dormant_retirement_group_keys
			)
			if not _effect.replace_entries([], retirement_entries):
				_fail_closed("global renderer rejected committed retirement-only cohort")
				return
		for member_group_key in cohort_member_group_keys:
			_activation_retry_membership.erase(member_group_key)
		_activation_cohorts_committed += 1
		return
	var cohort_id := _next_activation_cohort_id
	_next_activation_cohort_id += 1
	_activation_cohorts[cohort_id] = {
		"group_keys": group_keys.duplicate(),
		"inventories": inventories.duplicate(true),
		"activation_entries": activation_entries.duplicate(true),
		"retirement_group_keys": retirement_group_keys.duplicate(),
		"dormant_retirement_group_keys": dormant_retirement_group_keys.duplicate(),
		"retirement_entries": retirement_entries.duplicate(true),
		"selected_chunks": Array(cohort.get("chunks", [])).duplicate(true),
		"native_committed": false,
		"regional": bool(cohort.get("regional", false)),
		"authoritative_seed": terrain_identity.duplicate(true),
	}
	for member_group_key in cohort_member_group_keys:
		_activation_retry_membership.erase(member_group_key)
	for member_group_key in group_keys:
		var member_group := Dictionary(_groups[member_group_key])
		member_group["activation_queued"] = true
		member_group["activation_cohort_id"] = cohort_id
		_groups[member_group_key] = member_group
		_record_lifecycle_event("COHORT_SELECTED", member_group_key, {
			"cohort_id": cohort_id,
			"regional": bool(cohort.get("regional", false)),
			"member_count": group_keys.size(),
		})
	_activation_cohorts_queued += 1
	# A one-member isolated cold publication has no regional retirement to make
	# atomic. Its PREPARED event already proves that the immutable GPU entry
	# exists, so committing native authority now and queuing the render activation
	# removes an otherwise redundant staging callback and acknowledgement round.
	# The render command still revalidates the protected identity before drawing.
	if group_keys.size() == 1 and retirement_entries.is_empty() \
			and not bool(cohort.get("regional", false)):
		var direct_activation := Dictionary(_backend_terrain.call(
			"activate_gpu_resident_render_cohort", inventories, terrain_identity
		))
		if str(direct_activation.get("status", "")) != "ACTIVE" \
				or not bool(direct_activation.get("active", false)):
			var direct_status := str(direct_activation.get("status", ""))
			if direct_status.begins_with("STALE") \
					or direct_status == "WAITING_COHORT":
				_activation_cohorts.erase(cohort_id)
				var direct_group := Dictionary(_groups[group_keys[0]])
				direct_group["activation_queued"] = false
				direct_group["activation_cohort_id"] = 0
				_groups[group_keys[0]] = direct_group
				_queue_activation_cohort_retry(str(group_keys[0]))
				return
			_fail_closed(str(direct_activation.get(
				"error", "native isolated activation commit failed"
			)))
			return
		var direct_group := Dictionary(_groups[group_keys[0]])
		direct_group["native_active"] = true
		_groups[group_keys[0]] = direct_group
		var direct_cohort := Dictionary(_activation_cohorts[cohort_id])
		direct_cohort["native_committed"] = true
		_activation_cohorts[cohort_id] = direct_cohort
		_record_lifecycle_event("NATIVE_COMMITTED", str(group_keys[0]), {
			"cohort_id": cohort_id,
			"isolated_direct": true,
		})
		if not _effect.activate_entries(activation_entries):
			_fail_closed("global renderer rejected committed isolated activation")
			return
		_record_lifecycle_event("ACTIVATION_REQUESTED", str(group_keys[0]), {
			"cohort_id": cohort_id,
			"isolated_direct": true,
		})
		return
	# The staging callback validates the complete immutable candidate set on the
	# render thread without changing visibility. Native authority is committed
	# only after every cohort surface reports staged.
	if not _effect.stage_activation_entries(activation_entries):
		_reject_activation_cohort(
			group_key, "global renderer rejected staged activation cohort"
		)


func _has_native_committed_activation_in_flight() -> bool:
	for cohort_value in _activation_cohorts.values():
		if bool(Dictionary(cohort_value).get("native_committed", false)):
			return true
	return false


func _prepared_inventory_pool(members: Array) -> Array:
	var inventories: Array = []
	# Supply only the authority-selected cohort. Native commit still recomputes
	# and validates membership; never admit an in-flight render activation.
	for member_value in members:
		var route_key := _activation_chunk_key(Dictionary(member_value))
		var group_key := str(_prepared_group_routes.get(route_key, ""))
		if group_key.is_empty() or not _groups.has(group_key):
			return []
		var group := Dictionary(_groups[group_key])
		if bool(group.get("retiring", false)) \
				or bool(group.get("activation_queued", false)) \
				or (not bool(group.get("native_prepared", false)) \
				and not bool(group.get("native_active", false))):
			return []
		var requests := Dictionary(group.get("requests", {}))
		if not _surface_set_complete(group, "prepared") \
				or requests.size() != _required_surfaces(group).size():
			return []
		var terrain_identity := Dictionary(Dictionary(requests.get("terrain", {})).get("identity", {}))
		if _activation_chunk_key(terrain_identity) != route_key:
			return []
		inventories.append(_group_identities(group))
	return inventories


func _active_group_routes_by_chunk() -> Dictionary:
	# Native retirement keys identify locations, not generations. Resolve each
	# to its unique active GPU identity once for the whole replacement batch.
	var routes := {}
	for group_key_value in _groups.keys():
		var group_key := str(group_key_value)
		var group := Dictionary(_groups[group_key])
		if not bool(group.get("active", false)) \
				or bool(group.get("retiring", false)):
			continue
		var terrain_request := Dictionary(Dictionary(group.get(
			"requests", {}
		)).get("terrain", {}))
		var location_key := _chunk_location_key(Dictionary(terrain_request.get(
			"identity", {}
		)))
		routes[location_key] = "" if routes.has(location_key) else group_key
	return routes


func _mark_groups_retiring(
	group_keys: Array[String], dormant_group_keys: Array[String] = []
) -> void:
	for group_key in group_keys:
		if not _groups.has(group_key):
			continue
		var group := Dictionary(_groups[group_key])
		# The native regional cohort commit already removed this route from the
		# authoritative render sink. The asynchronous RenderingDevice callback only
		# confirms buffer visibility and must not retire a later demand incarnation.
		group["native_active"] = false
		group["retiring"] = true
		group["dormant_retirement"] = dormant_group_keys.has(group_key)
		group["retired"] = {}
		group["deactivated"] = {}
		group["retirement_candidate_frame"] = -1
		_groups[group_key] = group
		_record_lifecycle_event("ATOMIC_RETIRE", group_key)


func _activation_cohort_wait_signature(wait: Dictionary) -> String:
	var member := Dictionary(wait.get("waiting_member", {}))
	if not member.is_empty():
		return "member:%s:%s:%d" % [
			_activation_chunk_key(member),
			str(wait.get("error", "")),
			int(wait.get("boundary_mask_wait_count", 0)),
		]
	var replacements: Array = wait.get("selected_replacements", [])
	var keys: Array[String] = []
	for replacement_value in replacements:
		keys.append(_activation_chunk_key(Dictionary(replacement_value)))
	keys.sort()
	if not keys.is_empty():
		return "region:%d:%s:%s" % [
			hash(keys),
			str(wait.get("error", "")),
			str(wait.get("authoritative_coverage_complete", false)),
		]
	# No stable authority identity means this wait cannot safely share a gate.
	return ""


func _record_activation_cohort_wait(wait: Dictionary) -> void:
	# Cohort replies contain large selected-member arrays. Copy only the bounded
	# blocker summary needed by runtime diagnostics; deep-copying the full reply
	# on every retry made instrumentation itself a multi-millisecond frame cost.
	_last_activation_cohort_wait = {}
	for key in [
		"status", "error", "regional", "open_viewer_plan_publications",
		"pending_replacement_count", "ready_staged_replacement_count",
		"pending_retirement_count", "pending_visual_retirement_count",
		"replacement_count", "retirement_count", "boundary_mask_wait_count",
		"cohort_candidate_count", "cohort_overlap_members",
		"cohort_same_lod_face_members", "cohort_coarse_face_members",
		"cohort_fine_face_members", "cohort_blocker_reason",
		"cohort_blocker_key", "priority_requested_member_count",
		"transition_remesh_member_count",
		"mask_conflict_reason", "mask_conflict_face", "mask_conflict_key",
		"mask_conflict_neighbor",
		"same_layout_edit", "same_layout_edit_rejection_reason",
		"authoritative_coverage_complete", "cohort_built",
		"geometric_coverage_complete", "interaction_region_isolated",
		"coverage_remesh_repair_count", "coverage_remesh_repair_key",
		"non_authoritative_replacement_count",
		"non_authoritative_retirement_count",
		"waiting_member_record_present", "waiting_member_visual_required",
		"waiting_member_external_activation_required",
		"waiting_member_external_prepared", "waiting_member_visual_ready",
		"waiting_member_collision_current", "waiting_member_generation_matches",
		"waiting_member_sink_can_set", "waiting_member_sink_matches",
	]:
		if wait.has(key):
			_last_activation_cohort_wait[key] = wait[key]
	_last_activation_cohort_wait["query_timing_usec"] = Dictionary(
		wait.get("query_timing_usec", {})
	).duplicate()
	_last_activation_cohort_wait["cohort_selected_sample"] = Array(
		wait.get("cohort_selected_sample", [])
	).slice(0, 8).duplicate(true)
	_last_activation_cohort_wait["cohort_retirement_sample"] = Array(
		wait.get("cohort_retirement_sample", [])
	).slice(0, 8).duplicate(true)
	_last_activation_cohort_wait["selected_replacement_sample"] = Array(
		wait.get("selected_replacements", [])
	).slice(0, 8).duplicate(true)
	_last_activation_cohort_wait["selected_retirement_sample"] = Array(
		wait.get("selected_retirements", [])
	).slice(0, 8).duplicate(true)
	_last_activation_cohort_wait_frame = _process_frame


	var member := Dictionary(wait.get("waiting_member", {}))
	if member.is_empty():
		return
	_last_activation_cohort_wait["waiting_member"] = member.duplicate(true)
	var route_key := _activation_chunk_key(member)
	var group_key := str(_prepared_group_routes.get(route_key, ""))
	if group_key.is_empty():
		group_key = _try_remask_waiting_member(member)
	_last_activation_cohort_wait["waiting_member_route_key"] = route_key
	_last_activation_cohort_wait["waiting_member_group_key"] = group_key
	_last_activation_cohort_wait["waiting_member_group_present"] = (
		not group_key.is_empty() and _groups.has(group_key)
	)
	if group_key.is_empty() or not _groups.has(group_key):
		return
	var group := Dictionary(_groups[group_key])
	_last_activation_cohort_wait["waiting_member_group"] = {
		"active": bool(group.get("active", false)),
		"retiring": bool(group.get("retiring", false)),
		"validated": bool(group.get("validated", false)),
		"native_prepared": bool(group.get("native_prepared", false)),
		"native_active": bool(group.get("native_active", false)),
		"activation_queued": bool(group.get("activation_queued", false)),
		"activation_retry_queued": _activation_retry_membership.has(group_key),
		"prepared_surfaces": Dictionary(group.get("prepared", {})).keys(),
		"native_validated_surfaces": Dictionary(
			group.get("native_validated", {})
		).keys(),
		"identities": _group_identities(group),
	}
	if bool(wait.get("waiting_member_external_activation_required", false)) \
			and bool(group.get("active", false)) \
			and bool(group.get("native_prepared", false)) \
			and not bool(group.get("activation_queued", false)):
		var desired_mask := int(member.get("transition_mask", 0))
		var identities := _group_identities(group)
		var current_mask := int(Dictionary(identities.front()).get(
			"transition_mask", 0
		)) if not identities.is_empty() else -1
		if desired_mask != current_mask:
			if bool(group.get("remask_pending", false)):
				return
			var remask_entries: Array = []
			var requests := Dictionary(group.get("requests", {}))
			for surface_value in requests.keys():
				var request := Dictionary(requests[surface_value])
				var identity := Dictionary(request.get("identity", {})).duplicate(true)
				identity["transition_mask"] = desired_mask
				remask_entries.append({
					"identity": identity,
					"publication_sequence": int(request.get("publication_sequence", 0)),
				})
			group["remask_pending"] = true
			group["remask_transition_mask"] = desired_mask
			group["remasked"] = {}
			_groups[group_key] = group
			if not _effect.remask_active_entries(remask_entries, group_key):
				group["remask_pending"] = false
				_groups[group_key] = group
				_queue_activation_cohort_retry(group_key)
			return
		# Geometry and visibility already match. Only the freshly admitted native
		# application record needs to regain authority.
		var preparation := Dictionary(_backend_terrain.call(
			"prepare_gpu_resident_render_chunk", identities
		))
		if str(preparation.get("status", "")) != "PREPARED" \
				or not bool(preparation.get("prepared", false)):
			_queue_activation_cohort_retry(group_key)
			return
		group["native_prepared"] = true
		_groups[group_key] = group
		var rebound := Dictionary(_backend_terrain.call(
			"set_gpu_resident_render_chunk_active",
			_group_identities(group),
			true
		))
		if str(rebound.get("status", "")) == "ACTIVE" \
				and bool(rebound.get("active", false)):
			group["native_active"] = true
			_groups[group_key] = group
		else:
			_queue_activation_cohort_retry(group_key)


func _record_activation_cohort_query(query: Dictionary) -> void:
	# Keep self-reporting bounded: regional replies can contain hundreds of
	# members, and diagnostics must not become terrain frame work.
	_last_activation_cohort_query = {}
	for key in [
		"status", "error", "ready", "regional", "cohort_built",
		"authoritative_coverage_complete", "same_layout_edit",
		"same_layout_edit_rejection_reason", "replacement_count",
		"retirement_count", "activation_required_count",
		"retained_active_count", "seed_independently_publishable",
		"seed_atomic_visual_edit_member",
		"seed_visual_publication_cohort_size",
		"visible_atomic_revision_members",
	]:
		if query.has(key):
			_last_activation_cohort_query[key] = query[key]
	_last_activation_cohort_query["chunk_sample"] = Array(
		query.get("chunks", [])
	).slice(0, 8, 1, true)
	_last_activation_cohort_query["retirement_sample"] = Array(
		query.get("retirements", [])
	).slice(0, 8, 1, true)


func _try_remask_waiting_member(member: Dictionary) -> String:
	var desired_mask := int(member.get("transition_mask", 0))
	for candidate_key_value in _groups.keys():
		var candidate_key := str(candidate_key_value)
		var group := Dictionary(_groups[candidate_key])
		var dormant_candidate := bool(group.get("dormant", false)) \
				and not bool(group.get("active", false)) \
				and not bool(group.get("native_active", false))
		var active_candidate := not bool(group.get("dormant", false)) \
				and bool(group.get("active", false)) \
				and bool(group.get("native_active", false))
		if (not dormant_candidate and not active_candidate) \
				or bool(group.get("retiring", false)) \
				or bool(group.get("activation_queued", false)) \
				or bool(group.get("remask_pending", false)) \
				or not _surface_set_complete(group, "prepared"):
			continue
		var requests := Dictionary(group.get("requests", {}))
		var terrain_request := Dictionary(requests.get("terrain", {}))
		var terrain_identity := Dictionary(terrain_request.get("identity", {}))
		var geometry_matches := true
		for field in ["page_x", "page_y", "page_z", "lod", "generation"]:
			if terrain_identity.get(field) != member.get(field):
				geometry_matches = false
				break
		if not geometry_matches \
				or int(terrain_identity.get("transition_mask", 0)) == desired_mask:
			continue
		var remask_entries: Array = []
		var sequences := Dictionary(group.get("sequences", {}))
		for surface in _required_surfaces(group):
			var request := Dictionary(requests.get(surface, {}))
			var identity := Dictionary(request.get("identity", {})).duplicate(true)
			if (desired_mask & ~int(identity.get(
					"cached_transition_mask", 0
			))) != 0:
				geometry_matches = false
				break
			identity["transition_mask"] = desired_mask
			remask_entries.append({
				"identity": identity,
				"publication_sequence": int(sequences.get(surface, 0)),
			})
		if not geometry_matches:
			continue
		var desired_terrain_identity := terrain_identity.duplicate(true)
		desired_terrain_identity["transition_mask"] = desired_mask
		var readiness := Dictionary(_backend_terrain.call(
			"get_gpu_resident_render_chunk_readiness", desired_terrain_identity
		))
		if str(readiness.get("status", "")) != "READY" \
				or not bool(readiness.get("ready", false)) \
				or not bool(readiness.get("external_activation_required", false)):
			continue
		group["remask_pending"] = true
		group["remask_transition_mask"] = desired_mask
		group["remask_reactivate_dormant"] = dormant_candidate
		group["remasked"] = {}
		_groups[candidate_key] = group
		if not _effect.remask_active_entries(remask_entries, candidate_key):
			group["remask_pending"] = false
			group.erase("remask_transition_mask")
			group.erase("remask_reactivate_dormant")
			_groups[candidate_key] = group
			continue
		_record_lifecycle_event(
			"DORMANT_REMASK_SUBMITTED" if dormant_candidate else "ACTIVE_REMASK_SUBMITTED",
			candidate_key,
			{
			"previous_transition_mask": int(terrain_identity.get(
				"transition_mask", 0
			)),
			"transition_mask": desired_mask,
			}
		)
		return candidate_key
	return ""


func _finish_transition_remask(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group := Dictionary(_groups[group_key])
	var desired_mask := int(group.get("remask_transition_mask", -1))
	if desired_mask < 0:
		return
	var requests := Dictionary(group.get("requests", {}))
	var sequences := Dictionary(group.get("sequences", {}))
	var reactivate_dormant := bool(group.get("remask_reactivate_dormant", false))
	var updated_requests := {}
	var terrain_identity := {}
	var previous_terrain_identity := {}
	for surface_value in requests.keys():
		var surface := str(surface_value)
		var request := Dictionary(requests[surface])
		var previous_identity := Dictionary(request.get("identity", {}))
		var sequence := int(sequences.get(surface, 0))
		_entry_routes.erase(_entry_token(previous_identity, sequence))
		var identity := previous_identity.duplicate(true)
		identity["transition_mask"] = desired_mask
		request["identity"] = identity
		updated_requests[surface] = request
		if surface == "terrain":
			previous_terrain_identity = previous_identity
			terrain_identity = identity
	group["requests"] = updated_requests
	group["native_prepared"] = false
	group["native_active"] = false
	group["remask_pending"] = false
	group.erase("remask_transition_mask")
	group.erase("remask_reactivate_dormant")
	group.erase("pending_remask_requests")
	group["remasked"] = {}
	if terrain_identity.is_empty():
		_fail_closed("resident transition remask lost its terrain identity")
		return
	var new_group_key := _group_key(terrain_identity)
	_groups.erase(group_key)
	_groups[new_group_key] = group
	if _dormant_group_lru.has(group_key):
		var dormant_index := _dormant_group_lru.find(group_key)
		_dormant_group_lru[dormant_index] = new_group_key
	for surface_value in updated_requests.keys():
		var request := Dictionary(updated_requests[surface_value])
		_entry_routes[_entry_token(
			Dictionary(request.get("identity", {})),
			int(sequences.get(str(surface_value), 0))
		)] = {"group_key": new_group_key, "surface": str(surface_value)}
	_prepared_group_routes.erase(_activation_chunk_key(previous_terrain_identity))
	_prepared_group_routes[_activation_chunk_key(terrain_identity)] = new_group_key
	_activation_retry_membership.erase(group_key)
	var identities := _group_identities(group)
	var preparation := Dictionary(_backend_terrain.call(
		"prepare_gpu_resident_render_chunk", identities
	))
	if str(preparation.get("status", "")) != "PREPARED" \
			or not bool(preparation.get("prepared", false)):
		_queue_activation_cohort_retry(new_group_key)
		return
	group["native_prepared"] = true
	_groups[new_group_key] = group
	if reactivate_dormant:
		_record_lifecycle_event("DORMANT_REMASK_PREPARED", new_group_key)
		_queue_activation_cohort_retry(new_group_key)
		return
	var rebound := Dictionary(_backend_terrain.call(
		"set_gpu_resident_render_chunk_active", identities, true
	))
	if str(rebound.get("status", "")) == "ACTIVE" \
			and bool(rebound.get("active", false)):
		group["native_active"] = true
		_groups[new_group_key] = group
	else:
		_queue_activation_cohort_retry(new_group_key)


func _queue_activation_cohort_retry(group_key: String) -> void:
	if group_key.is_empty() or _activation_retry_membership.has(group_key):
		return
	_activation_retry_membership[group_key] = true
	var group: Dictionary = _groups.get(group_key, {})
	if bool(group.get("interaction_activation_priority",
			group.get("collision_activation_priority", false))):
		_insert_interaction_activation_retry(group_key)
	else:
		_activation_retry_queue.append(group_key)


func _insert_interaction_activation_retry(group_key: String) -> void:
	var priority := _activation_group_scheduler_priority(group_key)
	var query_count := _activation_group_query_count(group_key)
	var index := _activation_collision_retry_queue.size()
	for candidate_index in range(_activation_collision_retry_queue.size()):
		var candidate_key := str(_activation_collision_retry_queue[candidate_index])
		var candidate_query_count := _activation_group_query_count(candidate_key)
		if query_count < candidate_query_count \
				or (query_count == candidate_query_count \
				and priority > _activation_group_scheduler_priority(candidate_key)):
			index = candidate_index
			break
	_activation_collision_retry_queue.insert(index, group_key)


func _activation_group_scheduler_priority(group_key: String) -> int:
	var group := Dictionary(_groups.get(group_key, {}))
	var terrain_request := Dictionary(Dictionary(group.get(
		"requests", {}
	)).get("terrain", {}))
	var identity := Dictionary(terrain_request.get("identity", {}))
	return int(identity.get("scheduler_priority", 0))


func _activation_group_query_count(group_key: String) -> int:
	return int(Dictionary(_groups.get(group_key, {})).get(
		"activation_cohort_query_count", 0
	))


func _set_activation_frontend_blocker(group_key: String, blocker: String) -> void:
	if not _groups.has(group_key):
		return
	var group := Dictionary(_groups[group_key])
	group["last_activation_frontend_blocker"] = blocker
	_groups[group_key] = group


func inspect_chunk_activation(coordinate: Vector3i, lod: int) -> Dictionary:
	for group_key_value in _groups:
		var group_key := str(group_key_value)
		var group := Dictionary(_groups[group_key])
		var terrain_request := Dictionary(Dictionary(group.get(
			"requests", {}
		)).get("terrain", {}))
		var identity := Dictionary(terrain_request.get("identity", {}))
		if int(identity.get("page_x", 0)) != coordinate.x \
				or int(identity.get("page_y", 0)) != coordinate.y \
				or int(identity.get("page_z", 0)) != coordinate.z \
				or int(identity.get("lod", 0)) != lod:
			continue
		var cohort_id := int(group.get("activation_cohort_id", 0))
		var cohort := Dictionary(_activation_cohorts.get(cohort_id, {}))
		var effect_status: Dictionary = _effect.get_status() if _effect != null else {}
		return {
			"found": true,
			"group_key": group_key,
			"generation": int(identity.get("generation", 0)),
			"scheduler_priority": int(identity.get("scheduler_priority", 0)),
			"activation_cohort_query_count": int(group.get(
				"activation_cohort_query_count", 0
			)),
			"identity_interaction_priority": bool(identity.get("interaction_priority", false)),
			"interaction_activation_priority": bool(group.get(
				"interaction_activation_priority", false
			)),
			"native_prepared": bool(group.get("native_prepared", false)),
			"native_active": bool(group.get("native_active", false)),
			"activation_queued": bool(group.get("activation_queued", false)),
			"activation_cohort_id": cohort_id,
			"activation_staged_surfaces": Dictionary(
				group.get("activation_staged", {})
			).keys(),
			"activated_surfaces": Dictionary(group.get("activated", {})).keys(),
			"cohort_present": not cohort.is_empty(),
			"cohort_member_count": Array(cohort.get("group_keys", [])).size(),
			"cohort_native_committed": bool(cohort.get("native_committed", false)),
			"effect_pending_lifecycle_commands": int(effect_status.get(
				"pending_lifecycle_command_count", 0
			)),
			"effect_pending_interaction_lifecycle_commands": int(effect_status.get(
				"pending_interaction_lifecycle_command_count", 0
			)),
			"effect_pending_events": int(effect_status.get("event_count", 0)),
			"effect_pending_priority_events": int(effect_status.get(
				"priority_event_count", 0
			)),
			"activation_retry_queued": bool(group.get("activation_retry_queued", false)),
			"retry_membership": _activation_retry_membership.has(group_key),
			"next_activation_retry_frame": int(group.get("next_activation_retry_frame", 0)),
			"interaction_queue_index": _activation_collision_retry_queue.find(group_key),
			"background_queue_index": _activation_retry_queue.find(group_key),
			"last_incomplete_status": str(group.get("last_incomplete_status", "")),
			"last_activation_cohort_status": str(group.get(
				"last_activation_cohort_status", ""
			)),
			"last_activation_cohort_error": str(group.get(
				"last_activation_cohort_error", ""
			)),
			"last_activation_interaction_region_isolated": bool(group.get(
				"last_activation_interaction_region_isolated", false
			)),
			"last_activation_cohort_built": bool(group.get(
				"last_activation_cohort_built", false
			)),
			"last_activation_cohort_candidate_count": int(group.get(
				"last_activation_cohort_candidate_count", 0
			)),
			"last_activation_frontend_blocker": str(group.get(
				"last_activation_frontend_blocker", ""
			)),
		}
	return {"found": false}


func _drain_activation_cohort_retries() -> void:
	for signature_value in _activation_wait_probe_frames.keys():
		var signature := str(signature_value)
		if int(_activation_wait_probe_frames[signature]) < _process_frame:
			_activation_wait_probe_frames.erase(signature)
	var deadline := _activation_retry_clock_usec() + ACTIVATION_COHORT_RETRY_BUDGET_USEC
	var attempts := 0
	var inspected := 0
	var pending_count := (
		_activation_collision_retry_queue.size() + _activation_retry_queue.size()
	)
	var inspection_limit := mini(pending_count, RENDER_SUBMISSION_CAPACITY)
	# Collision-bearing groups get a bounded first lane. Each retry returns to
	# that lane's tail, and one normal retry follows every collision burst so
	# gameplay locality cannot starve the rest of the visual frontier.
	while attempts < ACTIVATION_COHORT_RETRY_CAPACITY and inspected < inspection_limit \
			and (not _activation_collision_retry_queue.is_empty() \
				or not _activation_retry_queue.is_empty()):
		# One expensive query may exceed the budget; do not start another.
		# Cheap independent cohorts can advance without a frame per seed.
		if inspected > 0 and _activation_retry_clock_usec() >= deadline:
			break
		var use_collision_lane := not _activation_collision_retry_queue.is_empty() \
			and (_activation_retry_queue.is_empty() \
				or _activation_collision_retry_streak < COLLISION_ACTIVATION_RETRY_BURST)
		var group_key := _activation_collision_retry_queue.pop_front() \
			if use_collision_lane else _activation_retry_queue.pop_front()
		if use_collision_lane:
			_activation_collision_retry_streak += 1
		else:
			_activation_collision_retry_streak = 0
		inspected += 1
		if not _activation_retry_membership.has(group_key):
			continue
		if not _groups.has(group_key):
			_activation_retry_membership.erase(group_key)
			continue
		var group := Dictionary(_groups[group_key])
		if _process_frame < int(group.get("next_activation_retry_frame", 0)):
			if use_collision_lane:
				_insert_interaction_activation_retry(group_key)
			else:
				_activation_retry_queue.append(group_key)
			continue
		_activation_retry_membership.erase(group_key)
		if bool(group.get("retiring", false)) \
				or bool(group.get("activation_queued", false)) \
				or not bool(group.get("native_prepared", false)):
			continue
		_activation_cohort_retry_attempts += 1
		if _try_queue_activation_cohort(group_key):
			attempts += 1


func _activation_retry_clock_usec() -> int:
	return Time.get_ticks_usec()


func _try_commit_activation_cohort(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group := Dictionary(_groups[group_key])
	var cohort_id := int(group.get("activation_cohort_id", 0))
	if cohort_id <= 0 or not _activation_cohorts.has(cohort_id):
		return
	var cohort := Dictionary(_activation_cohorts[cohort_id])
	if bool(cohort.get("native_committed", false)):
		return
	var group_keys: Array = cohort.get("group_keys", [])
	for member_group_key_value in group_keys:
		var member_group_key := str(member_group_key_value)
		if not _groups.has(member_group_key):
			_fail_closed("GPU activation cohort lost a prepared chunk")
			return
		if not _surface_set_complete(
				Dictionary(_groups[member_group_key]), "activation_staged"
			):
			return
	var inventories: Array = cohort.get("inventories", [])
	var authoritative_seed := Dictionary(cohort.get("authoritative_seed", {}))
	# Commit the exact transaction selected by the query. Dropping the seed for a
	# one-member cohort changes native selection back to the global frontier and
	# can turn a READY interaction cohort into an endless WAITING_COHORT loop.
	var activation := Dictionary(_backend_terrain.call(
		"activate_gpu_resident_render_cohort", inventories, authoritative_seed
	))
	var activation_status := str(activation.get("status", ""))
	if activation_status != "ACTIVE" or not bool(activation.get("active", false)):
		if activation_status.begins_with("STALE") \
				or activation_status == "WAITING_COHORT":
			_release_staged_activation_cohort(cohort)
			if activation_status == "WAITING_COHORT":
				_record_activation_cohort_wait(activation)
			else:
				_stale_activation_cohorts_retained += 1
			if activation_status.begins_with("STALE") \
					and _stale_activation_examples.size() < 8:
				_stale_activation_examples.append({
					"status": activation_status,
					"error": str(activation.get("error", "")),
					"activation": activation.duplicate(true),
					"selected_chunks": Array(cohort.get(
						"selected_chunks", []
					)).duplicate(true),
					"inventories": inventories.duplicate(true),
				})
			# Prepared entries remain invisible. Keep them resident and retry
			# against the newly authoritative regional cohort.
			_activation_cohorts.erase(cohort_id)
			for member_group_key_value in group_keys:
				var member_group_key := str(member_group_key_value)
				if not _groups.has(member_group_key):
					continue
				var member_group := Dictionary(_groups[member_group_key])
				member_group["activation_queued"] = false
				member_group["activation_cohort_id"] = 0
				member_group["activation_staged"] = {}
				_groups[member_group_key] = member_group
				_queue_activation_cohort_retry(member_group_key)
			return
		_fail_closed(str(activation.get(
			"error", "native activation cohort commit failed"
		)))
		return
	for member_group_key_value in group_keys:
		var member_group_key := str(member_group_key_value)
		var member_group := Dictionary(_groups[member_group_key])
		member_group["native_active"] = true
		_groups[member_group_key] = member_group
		_record_lifecycle_event("NATIVE_COMMITTED", member_group_key, {
			"cohort_id": cohort_id,
		})
	cohort["native_committed"] = true
	_activation_cohorts[cohort_id] = cohort
	var retirement_group_keys: Array = cohort.get("retirement_group_keys", [])
	var dormant_retirement_group_keys: Array = cohort.get(
		"dormant_retirement_group_keys", []
	)
	_mark_groups_retiring(retirement_group_keys, dormant_retirement_group_keys)
	var activation_entries: Array = cohort.get("activation_entries", [])
	var retirement_entries: Array = cohort.get("retirement_entries", [])
	var render_swap_queued: bool = _effect.replace_entries(
		activation_entries, retirement_entries
	) if not retirement_entries.is_empty() else _effect.activate_entries(
		activation_entries
	)
	if not render_swap_queued:
		_fail_closed("global renderer rejected committed activation cohort")
		return
	for member_group_key_value in group_keys:
		_record_lifecycle_event("ACTIVATION_REQUESTED", str(member_group_key_value), {
			"cohort_id": cohort_id,
		})


func _try_finish_activation_cohort(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group := Dictionary(_groups[group_key])
	var cohort_id := int(group.get("activation_cohort_id", 0))
	if cohort_id <= 0 or not _activation_cohorts.has(cohort_id):
		return
	var cohort := Dictionary(_activation_cohorts[cohort_id])
	if not bool(cohort.get("native_committed", false)):
		_fail_closed("GPU entries activated before native cohort commit")
		return
	var group_keys: Array = cohort.get("group_keys", [])
	for member_group_key_value in group_keys:
		var member_group_key := str(member_group_key_value)
		if not _groups.has(member_group_key):
			_fail_closed("GPU activation cohort lost a committed chunk")
			return
		if not _surface_set_complete(
				Dictionary(_groups[member_group_key]), "activated"
		):
			return
	var retire_after_activation: Array[String] = []
	for member_group_key_value in group_keys:
		var member_group_key := str(member_group_key_value)
		var member_group := Dictionary(_groups[member_group_key])
		var was_dormant := bool(member_group.get("dormant", false))
		member_group["active"] = true
		member_group["dormant"] = false
		member_group["dormant_saw_application_absent"] = false
		member_group["activation_queued"] = false
		member_group["activation_cohort_id"] = 0
		_groups[member_group_key] = member_group
		if was_dormant:
			_dormant_group_lru.erase(member_group_key)
			_dormant_group_reactivations += 1
		if bool(member_group.get("retire_after_activation", false)):
			retire_after_activation.append(member_group_key)
		_record_lifecycle_event("ACTIVE", member_group_key)
		_activated_chunks += 1
	_mark_replaced_active_groups_retiring(group_keys)
	_activation_cohorts.erase(cohort_id)
	_activation_cohorts_committed += 1
	for member_group_key in retire_after_activation:
		_begin_group_retirement(member_group_key, "superseded_after_activation")


func _mark_replaced_active_groups_retiring(activated_group_keys: Array) -> void:
	var activated_locations := {}
	for group_key_value in activated_group_keys:
		var group_key := str(group_key_value)
		var group := Dictionary(_groups.get(group_key, {}))
		var identity := Dictionary(Dictionary(group.get("requests", {})).get(
			"terrain", {}
		)).get("identity", {})
		if not identity.is_empty():
			activated_locations[_chunk_location_key(identity)] = true
	for candidate_key_value in _groups.keys():
		var candidate_key := str(candidate_key_value)
		if activated_group_keys.has(candidate_key):
			continue
		var candidate := Dictionary(_groups[candidate_key])
		if not bool(candidate.get("active", false)) \
				or bool(candidate.get("retiring", false)):
			continue
		var identity := Dictionary(Dictionary(candidate.get("requests", {})).get(
			"terrain", {}
		)).get("identity", {})
		if identity.is_empty() \
				or not activated_locations.has(_chunk_location_key(identity)):
			continue
		# The GPU cohort commit has already disabled this predecessor. Keep its
		# resources routed until the asynchronous SUPERSEDED callbacks reclaim all
		# surfaces, but stop reporting it as visible immediately.
		candidate["retiring"] = true
		candidate["dormant_retirement"] = false
		candidate["retired"] = {}
		candidate["deactivated"] = {}
		_groups[candidate_key] = candidate
		_record_lifecycle_event("REPLACED", candidate_key)


func _reconcile_active_chunks() -> int:
	var terrain_identities: Array = []
	var group_by_identity: Dictionary = {}
	var active_groups: Array = []
	for group_key in _groups:
		var group: Dictionary = _groups[group_key]
		if not bool(group.get("active", false)):
			continue
		active_groups.append(group_key)
	if active_groups.is_empty():
		_reconciliation_scan_cursor = 0
		return IDLE_RECONCILIATION_INTERVAL_FRAMES
	_reconciliation_scan_cursor %= active_groups.size()
	var inspection_count := mini(
		active_groups.size(), RECONCILIATION_IDENTITIES_PER_FRAME
	)
	for offset in range(inspection_count):
		var group_key = active_groups[
			(_reconciliation_scan_cursor + offset) % active_groups.size()
		]
		var group: Dictionary = _groups[group_key]
		var terrain_identity: Dictionary = Dictionary(
			Dictionary(group.get("requests", {})).get("terrain", {})
		).get("identity", {})
		terrain_identities.append(terrain_identity)
		group_by_identity[_group_key(terrain_identity)] = group_key
	_reconciliation_scan_cursor = (
		_reconciliation_scan_cursor + inspection_count
	) % active_groups.size()
	var reconciliation := Dictionary(_backend_terrain.call(
		"reconcile_gpu_resident_render_chunks", terrain_identities
	))
	if str(reconciliation.get("status", "")) != "PASS":
		_fail_closed("native resident reconciliation failed")
		return IDLE_RECONCILIATION_INTERVAL_FRAMES
	var protected_count := int(reconciliation.get("coverage_protected_count", 0))
	_coverage_protected_reconciliation_chunks += protected_count
	if bool(reconciliation.get("coverage_staging_blocked", false)) \
			and protected_count > 0:
		_coverage_retained_reconciliation_deferrals += 1
	var retire_group_keys := {}
	for identity_value in Array(reconciliation.get("retire", [])):
		var identity := Dictionary(identity_value)
		var group_key := str(group_by_identity.get(_group_key(identity), ""))
		if not group_key.is_empty():
			retire_group_keys[group_key] = true
	var retirement_confirmation_pending := false
	for group_key_value in group_by_identity.values():
		var group_key := str(group_key_value)
		if not _groups.has(group_key):
			continue
		var group: Dictionary = _groups[group_key]
		var candidate_frame := int(group.get("retirement_candidate_frame", -1))
		if not retire_group_keys.has(group_key):
			if candidate_frame >= 0:
				group["retirement_candidate_frame"] = -1
				_groups[group_key] = group
				_retirement_candidate_cancellations += 1
			continue
		if candidate_frame >= 0 and candidate_frame < _process_frame:
			_begin_group_retirement(
				group_key, "native_reconciliation", false, true
			)
			continue
		group["retirement_candidate_frame"] = _process_frame
		_groups[group_key] = group
		retirement_confirmation_pending = true
		_retirement_confirmation_deferrals += 1
	_has_retirement_candidates = _has_retirement_candidates or retirement_confirmation_pending
	return 1 if retirement_confirmation_pending \
			or active_groups.size() > inspection_count \
			else IDLE_RECONCILIATION_INTERVAL_FRAMES


func _clear_retirement_candidates() -> void:
	if not _has_retirement_candidates:
		return
	_has_retirement_candidates = false
	for group_key_value in _groups.keys():
		var group_key := str(group_key_value)
		var group: Dictionary = _groups[group_key]
		if int(group.get("retirement_candidate_frame", -1)) < 0:
			continue
		group["retirement_candidate_frame"] = -1
		_groups[group_key] = group
		_retirement_candidate_cancellations += 1


func debug_ray_coverage(
	origin: Vector3, direction: Vector3, maximum_distance: float
) -> Array:
	var hits: Array = []
	var unit_direction := direction.normalized()
	if not origin.is_finite() or not unit_direction.is_finite() \
			or unit_direction.is_zero_approx() or maximum_distance <= 0.0:
		return hits
	for group_key_value in _groups.keys():
		var group_key := str(group_key_value)
		var group := Dictionary(_groups[group_key])
		var terrain_request := Dictionary(
			Dictionary(group.get("requests", {})).get("terrain", {})
		)
		if terrain_request.is_empty():
			continue
		var distance := _ray_aabb_distance(
			origin,
			unit_direction,
			terrain_request.get("bounds_min", Vector3.ZERO),
			terrain_request.get("bounds_max", Vector3.ZERO),
			maximum_distance
		)
		if distance < 0.0:
			continue
		var details := Dictionary(
			Dictionary(group.get("surface_details", {})).get("terrain", {})
		)
		hits.append({
			"distance": distance,
			"identity": Dictionary(terrain_request.get("identity", {})).duplicate(true),
			"bounds_min": terrain_request.get("bounds_min", Vector3.ZERO),
			"bounds_max": terrain_request.get("bounds_max", Vector3.ZERO),
			"active": bool(group.get("active", false)),
			"retiring": bool(group.get("retiring", false)),
			"empty": bool(details.get("empty", false)),
			"vertex_count": int(details.get("vertex_count", 0)),
			"index_count": int(details.get("index_count", 0)),
			"failure_cell_count": int(details.get("failure_cell_count", 0)),
		})
	hits.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return float(left.get("distance", INF)) < float(right.get("distance", INF))
	)
	return hits.slice(0, mini(16, hits.size()))


func request_debug_ray_geometry(rays: Array) -> int:
	if _effect == null or not _effect.has_method("request_debug_ray_geometry"):
		return 0
	return int(_effect.request_debug_ray_geometry(rays))


func pop_debug_ray_geometry(request_id: int) -> Dictionary:
	if _effect == null or not _effect.has_method("pop_debug_ray_geometry"):
		return {}
	return Dictionary(_effect.pop_debug_ray_geometry(request_id))


func _record_surface_details(
	group_key: String, surface: String, event: Dictionary
) -> void:
	if not _groups.has(group_key):
		return
	var group := Dictionary(_groups[group_key])
	var details := Dictionary(group.get("surface_details", {}))
	details[surface] = {
		"empty": bool(event.get("entry_empty", false)),
		"vertex_count": int(event.get("entry_vertex_count", 0)),
		"index_count": int(event.get("entry_index_count", 0)),
		"failure_cell_count": int(event.get("entry_failure_cell_count", 0)),
	}
	group["surface_details"] = details
	_groups[group_key] = group


static func _ray_aabb_distance(
	origin: Vector3,
	direction: Vector3,
	minimum: Vector3,
	maximum: Vector3,
	maximum_distance: float
) -> float:
	var near_distance := 0.0
	var far_distance := maximum_distance
	for axis in range(3):
		var axis_origin := origin[axis]
		var axis_direction := direction[axis]
		if absf(axis_direction) <= 0.000001:
			if axis_origin < minimum[axis] or axis_origin > maximum[axis]:
				return -1.0
			continue
		var first := (minimum[axis] - axis_origin) / axis_direction
		var second := (maximum[axis] - axis_origin) / axis_direction
		if first > second:
			var swap := first
			first = second
			second = swap
		near_distance = maxf(near_distance, first)
		far_distance = minf(far_distance, second)
		if near_distance > far_distance:
			return -1.0
	return near_distance if far_distance >= 0.0 else -1.0


func _reject_group(group_key: String, error: String, readiness: Dictionary = {}) -> void:
	if not _groups.has(group_key):
		return
	_last_error = error
	_rejected_chunks += 1
	var group: Dictionary = _groups[group_key]
	_rejection_reasons[error] = int(_rejection_reasons.get(error, 0)) + 1
	if _rejection_examples.size() < 16:
		var requests: Dictionary = group.get("requests", {})
		var request: Dictionary = requests.get("terrain", {})
		if request.is_empty() and not requests.is_empty():
			request = Dictionary(requests.values()[0])
		_rejection_examples.append({
			"error": error,
			"application_readiness": readiness.duplicate(true),
			"identity": Dictionary(request.get("identity", {})).duplicate(true),
			"prepared_surfaces": Dictionary(group.get("prepared", {})).duplicate(true),
			"validated_surfaces": Dictionary(group.get("native_validated", {})).duplicate(true),
			"activated_surfaces": Dictionary(group.get("activated", {})).duplicate(true),
		})
	if not bool(group.get("validated", false)):
		var native_validated: Dictionary = group.get("native_validated", {})
		for surface in Dictionary(group.get("requests", {})):
			if bool(native_validated.get(surface, false)):
				continue
			var request_value = Dictionary(group.get("requests", {}))[surface]
			var request := Dictionary(request_value)
			_reject_native_request(request, error)
	_begin_group_retirement(group_key, "rejected", true)


static func _is_stale_render_event(error: String) -> bool:
	return error.contains("became stale")


func _supersede_group(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	if bool(Dictionary(_groups[group_key]).get("activation_queued", false)):
		_supersede_activation_cohort(group_key)
		return
	_superseded_chunks += 1
	var group: Dictionary = _groups[group_key]
	var native_validated: Dictionary = group.get("native_validated", {})
	for surface in Dictionary(group.get("requests", {})):
		if bool(native_validated.get(surface, false)):
			continue
		var request := Dictionary(Dictionary(group.get("requests", {}))[surface])
		_backend_terrain.call(
			"validate_gpu_resident_render_request",
			int(request.get("request_id", 0)),
			Dictionary(request.get("identity", {}))
		)
	_begin_group_retirement(group_key, "superseded", true)


func _reject_activation_cohort(group_key: String, error: String) -> void:
	var group := Dictionary(_groups.get(group_key, {}))
	var cohort_id := int(group.get("activation_cohort_id", 0))
	var cohort := Dictionary(_activation_cohorts.get(cohort_id, {}))
	_release_staged_activation_cohort(cohort)
	_activation_cohorts.erase(cohort_id)
	for member_group_key_value in Array(cohort.get("group_keys", [group_key])):
		var member_group_key := str(member_group_key_value)
		if not _groups.has(member_group_key):
			continue
		var member_group := Dictionary(_groups[member_group_key])
		member_group["activation_queued"] = false
		member_group["activation_cohort_id"] = 0
		_groups[member_group_key] = member_group
		_reject_group(member_group_key, error)


func _supersede_activation_cohort(group_key: String) -> void:
	var group := Dictionary(_groups.get(group_key, {}))
	var cohort_id := int(group.get("activation_cohort_id", 0))
	var cohort := Dictionary(_activation_cohorts.get(cohort_id, {}))
	if bool(cohort.get("native_committed", false)):
		# Native indirect draws changed atomically already. Keep every cohort
		# member alive until the rendering-device activation callbacks finish,
		# then retire the superseded set as a normal complete cohort.
		for member_group_key_value in Array(cohort.get("group_keys", [group_key])):
			var member_group_key := str(member_group_key_value)
			if not _groups.has(member_group_key):
				continue
			var member_group := Dictionary(_groups[member_group_key])
			member_group["retire_after_activation"] = true
			_groups[member_group_key] = member_group
		return
	_release_staged_activation_cohort(cohort)
	_activation_cohorts.erase(cohort_id)
	for member_group_key_value in Array(cohort.get("group_keys", [group_key])):
		var member_group_key := str(member_group_key_value)
		if not _groups.has(member_group_key):
			continue
		var member_group := Dictionary(_groups[member_group_key])
		member_group["activation_queued"] = false
		member_group["activation_cohort_id"] = 0
		_groups[member_group_key] = member_group
		_supersede_group(member_group_key)


func _release_staged_activation_cohort(cohort: Dictionary) -> void:
	if _effect != null and _effect.has_method("cancel_staged_activation_entries"):
		_effect.cancel_staged_activation_entries(
			Array(cohort.get("activation_entries", []))
		)


func _begin_group_retirement(
	group_key: String,
	reason: String = "unspecified",
	force_release: bool = false,
	prefer_dormant: bool = false
) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	var cohort_id := int(group.get("activation_cohort_id", 0))
	var cohort := Dictionary(_activation_cohorts.get(cohort_id, {}))
	if bool(cohort.get("native_committed", false)):
		# Native visibility changed for the whole cohort. No member may leave
		# the route table until all rendering-device callbacks complete.
		for member_group_key_value in Array(cohort.get("group_keys", [group_key])):
			var member_group_key := str(member_group_key_value)
			if not _groups.has(member_group_key):
				continue
			var member_group := Dictionary(_groups[member_group_key])
			member_group["retire_after_activation"] = true
			_groups[member_group_key] = member_group
		return
	if bool(group.get("retiring", false)):
		return
	var dormant_retirement := not force_release and (
		prefer_dormant or _can_retain_dormant_group(group)
	)
	group["retiring"] = true
	group["dormant_retirement"] = dormant_retirement
	group["retired"] = {}
	group["deactivated"] = {}
	_groups[group_key] = group
	_record_lifecycle_event(
		"DEACTIVATE" if dormant_retirement else "RETIRE",
		group_key,
		{"reason": reason}
	)
	var requests: Dictionary = group.get("requests", {})
	var sequences: Dictionary = group.get("sequences", {})
	for surface in requests:
		var identity: Dictionary = Dictionary(requests[surface]).get("identity", {})
		if dormant_retirement:
			_effect.deactivate_entry(identity, int(sequences.get(surface, 0)))
		else:
			_effect.retire_entry(identity, int(sequences.get(surface, 0)))
	if requests.is_empty():
		_try_finish_retirement(group_key)


func _try_finish_retirement(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	var dormant_retirement := bool(group.get("dormant_retirement", false))
	var completion_field := "deactivated" if dormant_retirement else "retired"
	if not _surface_set_complete(group, completion_field, false):
		return
	if bool(group.get("native_active", false)):
		_backend_terrain.call(
			"set_gpu_resident_render_chunk_active", _group_identities(group), false
		)
		group["native_active"] = false
		_retired_chunks += 1
	if dormant_retirement:
		group["active"] = false
		group["dormant"] = true
		group["dormant_saw_application_absent"] = false
		group["retiring"] = false
		group["dormant_retirement"] = false
		group["validated"] = false
		group["native_prepared"] = false
		group["activation_queued"] = false
		group["activation_cohort_id"] = 0
		group["activation_staged"] = {}
		group["activated"] = {}
		group["application_wait_started_frame"] = -1
		group["next_validation_frame"] = _process_frame
		group["retirement_candidate_frame"] = -1
		var pending_dormant_requests: Dictionary = group.get(
			"pending_dormant_requests", {}
		)
		if not pending_dormant_requests.is_empty():
			var rebound_requests: Dictionary = group.get("requests", {})
			var rebound_native_validated: Dictionary = group.get(
				"native_validated", {}
			)
			for surface_value in pending_dormant_requests:
				var surface := str(surface_value)
				var rebound_request := Dictionary(
					pending_dormant_requests[surface_value]
				)
				rebound_requests[surface] = {
					"request_id": int(rebound_request.get("request_id", 0)),
					"identity": Dictionary(rebound_request.get(
						"identity", {}
					)).duplicate(true),
					"bounds_min": rebound_request.get("bounds_min", Vector3.ZERO),
					"bounds_max": rebound_request.get("bounds_max", Vector3.ZERO),
				}
				rebound_native_validated.erase(surface)
				_record_lifecycle_event("DORMANT_REBOUND", group_key, {
					"surface": surface,
					"request_id": int(rebound_request.get("request_id", 0)),
				})
			group["requests"] = rebound_requests
			group["native_validated"] = rebound_native_validated
			group["pending_dormant_requests"] = {}
		_groups[group_key] = group
		_retain_dormant_group(group_key)
		return
	_cleanup_group(group_key)


func _can_retain_dormant_group(group: Dictionary) -> bool:
	if not bool(group.get("active", false)) \
			or not bool(group.get("native_active", false)):
		return false
	var terrain_request := Dictionary(Dictionary(group.get(
		"requests", {}
	)).get("terrain", {}))
	if terrain_request.is_empty():
		return false
	var readiness := Dictionary(_backend_terrain.call(
		"get_gpu_resident_render_chunk_readiness",
		Dictionary(terrain_request.get("identity", {}))
	))
	return str(readiness.get("status", "")) == "WAITING_APPLICATION"


func _park_dormant_group(group_key: String) -> bool:
	if not _groups.has(group_key):
		return false
	var group := Dictionary(_groups[group_key])
	if not bool(group.get("dormant", false)) \
			or bool(group.get("active", false)) \
			or bool(group.get("native_active", false)):
		return false
	_activation_retry_membership.erase(group_key)
	var terrain_request := Dictionary(Dictionary(group.get(
		"requests", {}
	)).get("terrain", {}))
	if not terrain_request.is_empty():
		var activation_key := _activation_chunk_key(Dictionary(
			terrain_request.get("identity", {})
		))
		if str(_prepared_group_routes.get(activation_key, "")) == group_key:
			_prepared_group_routes.erase(activation_key)
	group["validated"] = false
	group["native_prepared"] = false
	group["activation_queued"] = false
	group["activation_cohort_id"] = 0
	group["application_wait_started_frame"] = -1
	group["next_validation_frame"] = (
		_process_frame + DORMANT_APPLICATION_RETRY_FRAMES
	)
	_groups[group_key] = group
	_retain_dormant_group(group_key)
	_record_lifecycle_event("DORMANT_PARKED", group_key)
	return true


func _retain_dormant_group(group_key: String) -> void:
	var newly_dormant := not _dormant_group_lru.has(group_key)
	_dormant_group_lru.erase(group_key)
	_dormant_group_lru.append(group_key)
	if newly_dormant:
		_dormant_group_insertions += 1
	_dormant_group_peak = maxi(_dormant_group_peak, _dormant_group_lru.size())
	while _dormant_group_lru.size() > DORMANT_GROUP_CAPACITY:
		var evicted_group_key := _select_dormant_eviction_group()
		_dormant_group_lru.erase(evicted_group_key)
		if not _groups.has(evicted_group_key):
			continue
		_dormant_group_evictions += 1
		_begin_group_retirement(evicted_group_key, "dormant_capacity", true)


func _select_dormant_eviction_group() -> String:
	var selected := ""
	var selected_priority := 4
	var selected_lod := -1
	for group_key_value in _dormant_group_lru:
		var group_key := str(group_key_value)
		if not _groups.has(group_key):
			return group_key
		var group := Dictionary(_groups[group_key])
		var terrain_request := Dictionary(Dictionary(group.get(
			"requests", {}
		)).get("terrain", {}))
		var identity := Dictionary(terrain_request.get("identity", {}))
		var lod := int(identity.get("lod", 0))
		var interaction := bool(identity.get("interaction_priority", false)) \
			or bool(identity.get("local_publication_priority", false))
		# Preserve exact interaction LOD0 residency ahead of predictive support and
		# coarse background entries. Oldest wins only within the same class.
		var priority := 2 if interaction and lod == 0 else (
			1 if interaction or lod == 0 else 0
		)
		if selected.is_empty() or priority < selected_priority \
				or priority == selected_priority and lod > selected_lod:
			selected = group_key
			selected_priority = priority
			selected_lod = lod
	return selected


func _record_lifecycle_event(
	action: String, group_key: String, details: Dictionary = {}
) -> void:
	if not _lifecycle_history_enabled or not _groups.has(group_key):
		return
	var group := Dictionary(_groups[group_key])
	var terrain_request := Dictionary(Dictionary(group.get(
		"requests", {}
	)).get("terrain", {}))
	var event := {
		"frame": _process_frame,
		"ticks_usec": Time.get_ticks_usec(),
		"action": action,
		"identity": Dictionary(terrain_request.get("identity", {})).duplicate(true),
		"active": bool(group.get("active", false)),
		"native_active": bool(group.get("native_active", false)),
		"activation_queued": bool(group.get("activation_queued", false)),
	}
	event.merge(details, true)
	_recent_lifecycle_events.append(event)
	if _recent_lifecycle_events.size() > LIFECYCLE_HISTORY_CAPACITY:
		_recent_lifecycle_events.pop_front()


func _restore_cpu_and_release_native_requests() -> void:
	if _backend_terrain == null or not is_instance_valid(_backend_terrain):
		return
	for request in _deferred_interaction_requests:
		_reject_native_request(request, "resident renderer stopped")
	for group_value in _groups.values():
		var group := Dictionary(group_value)
		if bool(group.get("native_active", false)):
			_backend_terrain.call(
				"set_gpu_resident_render_chunk_active", _group_identities(group), false
			)
		elif not bool(group.get("validated", false)):
			var native_validated: Dictionary = group.get("native_validated", {})
			for surface in Dictionary(group.get("requests", {})):
				if bool(native_validated.get(surface, false)):
					continue
				var request_value = Dictionary(group.get("requests", {}))[surface]
				_reject_native_request(Dictionary(request_value), "resident renderer stopped")


func _fail_closed(error: String) -> void:
	_last_error = error
	_recovery_count += 1
	push_error("WT_GPU_RESIDENT_FAIL_CLOSED: %s" % error)
	stop()


func _reject_native_request(request: Dictionary, error: String) -> void:
	if request.is_empty() or _backend_terrain == null:
		return
	_last_error = error
	_backend_terrain.call(
		"reject_gpu_resident_render_request",
		int(request.get("request_id", 0)),
		Dictionary(request.get("identity", {})),
		error
	)


func _cleanup_group(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var pending_group := Dictionary(_groups[group_key])
	var pending_cohort_id := int(pending_group.get("activation_cohort_id", 0))
	var pending_cohort := Dictionary(_activation_cohorts.get(pending_cohort_id, {}))
	if bool(pending_cohort.get("native_committed", false)):
		# A late retirement callback can race the already-committed activation.
		# Preserve the route, then issue a fresh retirement after activation.
		pending_group["retire_after_activation"] = true
		pending_group["retiring"] = false
		pending_group["retired"] = {}
		_groups[group_key] = pending_group
		return
	_activation_retry_membership.erase(group_key)
	_dormant_group_lru.erase(group_key)
	var group: Dictionary = _groups[group_key]
	var terrain_request := Dictionary(Dictionary(group.get(
		"requests", {}
	)).get("terrain", {}))
	if not terrain_request.is_empty():
		var terrain_identity := Dictionary(terrain_request.get("identity", {}))
		var activation_key := _activation_chunk_key(terrain_identity)
		if str(_prepared_group_routes.get(activation_key, "")) == group_key:
			_prepared_group_routes.erase(activation_key)
	for request_value in Dictionary(group.get("requests", {})).values():
		var request := Dictionary(request_value)
		var identity: Dictionary = request.get("identity", {})
		var surface := str(identity.get("surface", ""))
		var sequence := int(Dictionary(group.get("sequences", {})).get(surface, 0))
		_entry_routes.erase(_entry_token(identity, sequence))
	var render_request_ids := _render_request_routes.keys()
	for render_request_id in render_request_ids:
		if str(Dictionary(_render_request_routes[render_request_id]).get(
			"group_key", ""
		)) == group_key:
			_render_request_routes.erase(render_request_id)
	_groups.erase(group_key)


func _route_for_event(event: Dictionary) -> Dictionary:
	var controller_group_key := str(event.get("controller_group_key", ""))
	if not controller_group_key.is_empty():
		return {
			"group_key": controller_group_key,
			"surface": str(Dictionary(event.get("identity", {})).get("surface", "")),
		}
	var request_id := int(event.get("request_id", 0))
	if request_id > 0 and _render_request_routes.has(request_id):
		var route: Dictionary = _render_request_routes[request_id]
		_render_request_routes.erase(request_id)
		return route
	return Dictionary(_entry_routes.get(_entry_token(
		Dictionary(event.get("identity", {})),
		int(event.get("publication_sequence", 0))
	), {}))


func _mark_surface(group_key: String, field: String, surface: String) -> void:
	var group: Dictionary = _groups[group_key]
	var values: Dictionary = group.get(field, {})
	values[surface] = true
	group[field] = values
	_groups[group_key] = group


func _surface_set_complete(
	group: Dictionary, field: String, require_expected: bool = true
) -> bool:
	var values: Dictionary = group.get(field, {})
	var surfaces: Array = _required_surfaces(group) if require_expected \
		else Dictionary(group.get("requests", {})).keys()
	for surface in surfaces:
		if not bool(values.get(surface, false)):
			return false
	return true


func _group_identities(group: Dictionary) -> Array:
	var identities: Array = []
	var requests: Dictionary = group.get("requests", {})
	for surface in _required_surfaces(group):
		identities.append(Dictionary(requests.get(surface, {})).get("identity", {}))
	return identities


func _inactive_group_examples(limit: int) -> Array:
	var examples: Array = []
	for group_key_value in _groups.keys():
		if examples.size() >= limit:
			break
		var group_key := str(group_key_value)
		var group := Dictionary(_groups[group_key])
		if bool(group.get("active", false)) or bool(group.get("retiring", false)):
			continue
		var requests: Dictionary = group.get("requests", {})
		var identities := {}
		for surface_value in requests.keys():
			var surface := str(surface_value)
			identities[surface] = Dictionary(requests[surface]).get("identity", {})
		examples.append({
			"group_key": group_key,
			"age_frames": _process_frame - int(group.get("created_frame", _process_frame)),
			"water_expected": bool(group.get("water_expected", false)),
			"request_surfaces": requests.keys(),
			"prepared_surfaces": Dictionary(group.get("prepared", {})).keys(),
			"native_validated_surfaces": Dictionary(
				group.get("native_validated", {})
			).keys(),
			"validated": bool(group.get("validated", false)),
			"native_prepared": bool(group.get("native_prepared", false)),
			"native_active": bool(group.get("native_active", false)),
			"activation_queued": bool(group.get("activation_queued", false)),
			"activation_cohort_id": int(group.get("activation_cohort_id", 0)),
			"activation_retry_queued": _activation_retry_membership.has(group_key),
			"next_activation_retry_frame": int(group.get("next_activation_retry_frame", 0)),
			"activation_staged_surfaces": Dictionary(
				group.get("activation_staged", {})
			).keys(),
			"activated_surfaces": Dictionary(group.get("activated", {})).keys(),
			"last_incomplete_status": str(group.get(
				"last_incomplete_status", ""
			)),
			"identities": identities,
		})
	return examples


func _retiring_group_examples(limit: int) -> Array:
	var examples: Array = []
	for group_key_value in _groups.keys():
		if examples.size() >= limit:
			break
		var group_key := str(group_key_value)
		var group := Dictionary(_groups[group_key])
		if not bool(group.get("retiring", false)):
			continue
		var requests: Dictionary = group.get("requests", {})
		var identities := {}
		var request_ids := {}
		for surface_value in requests.keys():
			var surface := str(surface_value)
			var request := Dictionary(requests[surface])
			identities[surface] = Dictionary(request.get("identity", {}))
			request_ids[surface] = int(request.get("request_id", 0))
		examples.append({
			"group_key": group_key,
			"age_frames": _process_frame - int(group.get("created_frame", _process_frame)),
			"active": bool(group.get("active", false)),
			"native_active": bool(group.get("native_active", false)),
			"validated": bool(group.get("validated", false)),
			"request_ids": request_ids,
			"request_surfaces": requests.keys(),
			"native_validated_surfaces": Dictionary(
				group.get("native_validated", {})
			).keys(),
			"retired_surfaces": Dictionary(group.get("retired", {})).keys(),
			"identities": identities,
		})
	return examples


func _new_group(identity: Dictionary) -> Dictionary:
	return {
		"water_expected": bool(identity.get("static_water_surface_expected", false)),
		"requests": {},
		"sequences": {},
		"prepared": {},
		"activation_staged": {},
		"activated": {},
		"retired": {},
		"deactivated": {},
		"native_validated": {},
		"surface_details": {},
		"validated": false,
		"native_prepared": false,
		"native_active": false,
		"active": false,
		"activation_queued": false,
		"activation_cohort_id": 0,
		"retiring": false,
		"dormant": false,
		"dormant_saw_application_absent": false,
		"dormant_retirement": false,
		"pending_dormant_requests": {},
		"retirement_candidate_frame": -1,
		"application_wait_started_frame": -1,
		"next_validation_frame": 0,
		"created_frame": _process_frame,
		"next_incomplete_probe_frame": 0,
		"last_incomplete_status": "",
	}


static func _required_surfaces(group: Dictionary) -> Array[String]:
	return ["terrain", "static_water"] if bool(group.get(
		"water_expected", false
	)) else ["terrain"]


static func _validate_native_request(request: Dictionary) -> String:
	if str(request.get("schema", "")) \
			!= "world_transvoxel.gpu_resident_render_request.v7" \
			or str(request.get("status", "")) != "PASS":
		return "native GPU resident request contract failed"
	if str(request.get("position_space", "")) != "world":
		return "native GPU resident request is not in world position space"
	if str(request.get("input_stage", "")) != "pre_mesh_field" \
			or bool(request.get("cpu_topology_input_dependency", true)) \
			or bool(request.get("cpu_field_sampling", true)) \
			or not bool(request.get("gpu_density_field_generation", false)) \
			or not bool(request.get("gpu_material_field_generation", false)) \
			or not bool(request.get("gpu_page_lattice_input", false)) \
			or not bool(request.get("gpu_transvoxel_extraction", false)):
		return "native GPU resident request is not a GPU page-field input"
	var cpu_visual_mesh_omitted := bool(request.get(
		"cpu_visual_mesh_omitted", false
	))
	if not bool(request.get("gpu_resident_render_publication", false)) \
			or bool(request.get("cpu_render_visible_until_activation", false)) \
				== cpu_visual_mesh_omitted \
			or not bool(request.get("cpu_collision_publication_unchanged", false)) \
			or not bool(request.get("native_input_packing", false)) \
			or bool(request.get("cell_batch_exported", true)) \
			or bool(request.get("fallback_used", true)):
		return "native GPU resident request changed publication authority"
	var input_buffers := Array(request.get("gpu_input_buffers", []))
	var proven_empty := bool(request.get("proven_empty", false))
	if (not proven_empty and input_buffers.size() != 13) \
			or (proven_empty and not input_buffers.is_empty() \
				and input_buffers.size() != 13) \
			or int(request.get("cell_count", 0)) <= 0 \
			or int(request.get("page_count", 0)) <= 0:
		return "native GPU resident input inventory is invalid"
	var actual_bytes := 0
	for buffer_value in input_buffers:
		if not buffer_value is PackedByteArray \
				or PackedByteArray(buffer_value).is_empty():
			return "native GPU resident input buffer is invalid"
		actual_bytes += PackedByteArray(buffer_value).size()
	if actual_bytes != int(request.get("packed_byte_count", -1)):
		return "native GPU resident packed byte count is invalid"
	var identity := Dictionary(request.get("identity", {}))
	if str(identity.get("input_stage", "")) != "pre_mesh_field":
		return "native GPU resident identity lost its input stage"
	var bounds_min_value = request.get("bounds_min", null)
	var bounds_max_value = request.get("bounds_max", null)
	if not bounds_min_value is Vector3 or not bounds_max_value is Vector3:
		return "native GPU resident bounds are missing"
	var bounds_min: Vector3 = bounds_min_value
	var bounds_max: Vector3 = bounds_max_value
	if not bounds_min.is_finite() or not bounds_max.is_finite() \
			or bounds_min.x > bounds_max.x or bounds_min.y > bounds_max.y \
			or bounds_min.z > bounds_max.z:
		return "native GPU resident bounds are invalid"
	return ""


static func _group_key(identity: Dictionary) -> String:
	return "%d:%d:%d:%d:g%d:s%d:w%d:t%d" % [
		int(identity.get("page_x", 0)),
		int(identity.get("page_y", 0)),
		int(identity.get("page_z", 0)),
		int(identity.get("lod", 0)),
		int(identity.get("generation", 0)),
		int(identity.get("source_revision", 0)),
		int(identity.get("world_revision", 0)),
		int(identity.get("transition_mask", 0)),
	]


static func _chunk_location_key(identity: Dictionary) -> String:
	return "%d:%d:%d:%d" % [
		int(identity.get("page_x", 0)), int(identity.get("page_y", 0)),
		int(identity.get("page_z", 0)), int(identity.get("lod", 0)),
	]


static func _activation_chunk_key(identity: Dictionary) -> String:
	return "%d:%d:%d:%d:g%d:t%d" % [
		int(identity.get("page_x", 0)),
		int(identity.get("page_y", 0)),
		int(identity.get("page_z", 0)),
		int(identity.get("lod", 0)),
		int(identity.get("generation", 0)),
		int(identity.get("transition_mask", 0)),
	]


static func _entry_token(identity: Dictionary, sequence: int) -> String:
	return "%s:%s@%d" % [
		str(identity.get("surface", "")), _group_key(identity), sequence
	]

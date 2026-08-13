extends RefCounted

const SCHEMA := "world_transvoxel.cpu_causal_trace.v2"
const DEFAULT_CAPACITY := 8192
const NATIVE_EVENT_CAPACITY := 131072
const NATIVE_READ_BATCH := 4096
const NATIVE_MAX_BATCHES_PER_DRAIN := 32
const NORMAL_PIPELINE_CADENCE := 10
const DETAIL_PIPELINE_CADENCE := 3
const HITCH_THRESHOLD_US := 33300

const PIPELINE_METRICS := [
	"viewer_updates", "collision_viewer_updates", "coalesced_viewer_events",
	"planned_demands", "sample_jobs", "mesh_jobs", "storage_completions",
	"mesh_completions", "transition_mesh_completions", "edit_commits",
	"edit_rejections", "edit_replacements", "published_events",
	"rejected_events", "scheduler_requested_records",
	"scheduler_sampling_records", "scheduler_meshing_records",
	"scheduler_ready_records", "scheduler_failed_records",
	"scheduler_queued_jobs", "scheduler_queued_completions",
	"storage_queued_requests", "storage_queued_completions",
	"storage_active_requests", "storage_started_requests",
	"storage_completed_requests", "storage_successful_pages",
	"storage_load_time_ns_last", "storage_load_time_ns_total",
	"storage_in_flight_requests", "storage_in_flight_elapsed_ns",
	"storage_in_flight_key_x", "storage_in_flight_key_y",
	"storage_in_flight_key_z", "storage_in_flight_key_lod",
	"storage_in_flight_generation", "page_dependency_requests",
	"page_dependency_cache_hits", "page_dependency_cache_misses",
	"page_accepted_storage_completions", "page_stale_storage_completions",
	"page_loading_records", "page_sample_ready_records",
	"page_awaiting_mesh_records", "page_mesh_ready_records",
	"page_ready_records", "page_unresolved_dependencies",
	"page_pending_dependency_requests", "application_submitted_render",
	"application_submitted_collision", "application_applied_render",
	"application_applied_collision", "application_stale_render",
	"application_stale_collision", "application_unrequired_collision",
	"application_sink_failures", "application_queue_rejections",
	"collision_apply_time_ns_last", "collision_apply_frame_time_ns_last",
	"active_chunk_records", "visual_ready_chunk_records",
	"collision_required_chunk_records", "collision_ready_chunk_records",
	"collision_required_not_ready_chunk_records", "fully_ready_chunk_records",
	"non_retiring_chunk_records", "non_retiring_visual_ready_chunk_records",
	"non_retiring_fully_ready_chunk_records", "pending_retirement_records",
	"pending_chunk_retirements", "pending_chunk_replacements",
	"blocked_pending_chunk_replacements", "pending_render_retirements",
	"queued_render", "queued_collision", "deferred_collision",
	"total_collision_backlog", "render_resources", "staged_render_resources",
	"collision_resources", "staged_collision_resources",
]

var _host: Node
var _game_world: Node
var _terrain_world: Node
var _player: CharacterBody3D
var _output_path := ""
var _mode := ""
var _capacity := DEFAULT_CAPACITY
var _slots: Array = []
var _write_index := 0
var _event_count := 0
var _next_sequence := 0
var _dropped_events := 0
var _started_us := 0
var _last_frame_tick_us := 0
var _frame := 0
var _phase := "unassigned"
var _cause_id := ""
var _detail_sampling := false
var _force_pipeline_snapshot := false
var _last_movement_accepted = null
var _movement_note := {}
var _target_chunk := Vector3i.ZERO
var _target_lod := 0
var _target_enabled := false
var _capture_time_us_total := 0
var _capture_time_us_maximum := 0
var _pipeline_capture_time_us_total := 0
var _pipeline_capture_time_us_maximum := 0
var _pipeline_snapshot_count := 0
var _finalized := false
var _start_error := ""
var _native_session_started := false
var _native_read_failed := false
var _native_read_error := ""
var _native_slots: Array = []
var _native_write_index := 0
var _native_event_count := 0
var _native_local_dropped_events := 0
var _native_next_sequence := 0
var _native_source_gap_events := 0
var _native_status := {}
var _native_capture_time_us_total := 0
var _native_capture_time_us_maximum := 0
var _native_snapshot_count := 0


func start(
	host: Node,
	game_world: Node,
	terrain_world: Node,
	player: CharacterBody3D,
	output_path: String,
	mode: String,
	capacity: int = DEFAULT_CAPACITY
) -> bool:
	if host == null or game_world == null or terrain_world == null or player == null:
		_start_error = "required_node_missing"
		return false
	if output_path.is_empty():
		_start_error = "output_path_empty"
		return false
	if capacity < 256 or capacity > 65536:
		_start_error = "invalid_downstream_capacity"
		return false
	for method in [
		"begin_cpu_causal_trace",
		"get_cpu_causal_trace_events",
		"end_cpu_causal_trace",
	]:
		if not terrain_world.has_method(method):
			_start_error = "native_api_missing:%s" % method
			return false
	if not bool(terrain_world.call("begin_cpu_causal_trace")):
		_start_error = "native_trace_start_rejected"
		return false
	_host = host
	_game_world = game_world
	_terrain_world = terrain_world
	_player = player
	_output_path = output_path
	_mode = mode
	_capacity = capacity
	_slots.resize(_capacity)
	_native_slots.resize(NATIVE_EVENT_CAPACITY)
	_native_session_started = true
	_started_us = Time.get_ticks_usec()
	_last_frame_tick_us = _started_us
	if not _drain_native_trace():
		terrain_world.call("end_cpu_causal_trace")
		_native_session_started = false
		_start_error = _native_read_error
		return false
	record(&"trace_started", {"mode": _mode, "capacity": _capacity}, true)
	return true


func is_active() -> bool:
	return _started_us > 0 and not _finalized


func get_start_error() -> String:
	return _start_error


func begin_phase(label: String, cause_id: String = "", detail_sampling: bool = false) -> void:
	if not is_active():
		return
	_phase = label
	_cause_id = cause_id
	_detail_sampling = detail_sampling
	_force_pipeline_snapshot = true
	record(&"phase_started", {
		"label": label,
		"cause_id": cause_id,
		"detail_sampling": detail_sampling,
	}, true)


func set_target_chunk(chunk: Vector3i, lod: int, generation_before: int) -> void:
	_target_chunk = chunk
	_target_lod = lod
	_target_enabled = true
	record(&"target_chunk_bound", {
		"chunk": _vector3i_summary(chunk),
		"lod": lod,
		"generation_before": generation_before,
	}, true)


func clear_target_chunk() -> void:
	_target_enabled = false


func note_movement(
	accepted: bool,
	requested_velocity: Vector3,
	position_before: Vector3,
	position_after: Vector3
) -> void:
	if not is_active():
		return
	var changed: bool = (
		_last_movement_accepted == null or accepted != _last_movement_accepted
	)
	_movement_note = {
		"accepted": accepted,
		"requested_velocity": _vector3_summary(requested_velocity),
		"requested_speed": requested_velocity.length(),
		"position_before": _vector3_summary(position_before),
		"position_after": _vector3_summary(position_after),
		"distance": position_before.distance_to(position_after),
	}
	_last_movement_accepted = accepted
	if changed:
		_force_pipeline_snapshot = true


func capture_physics_frame(elapsed_us: int = -1) -> void:
	if not is_active():
		return
	var capture_started := Time.get_ticks_usec()
	var now_us := capture_started
	if elapsed_us < 0:
		elapsed_us = maxi(0, now_us - _last_frame_tick_us)
	_last_frame_tick_us = now_us
	_frame += 1
	var cadence := DETAIL_PIPELINE_CADENCE if _detail_sampling else NORMAL_PIPELINE_CADENCE
	var include_pipeline := (
		_force_pipeline_snapshot or
		elapsed_us >= HITCH_THRESHOLD_US or
		_frame % cadence == 0
	)
	var event := _base_event(&"physics_frame")
	event["frame_us"] = elapsed_us
	event["player_position"] = _vector3_summary(_player.global_position)
	if not _movement_note.is_empty():
		event["movement"] = _movement_note.duplicate(true)
	if include_pipeline:
		event["pipeline"] = _pipeline_snapshot()
	_force_pipeline_snapshot = false
	var capture_us := maxi(0, Time.get_ticks_usec() - capture_started)
	event["observer_us"] = capture_us
	_capture_time_us_total += capture_us
	_capture_time_us_maximum = maxi(_capture_time_us_maximum, capture_us)
	_append(event)


func record(kind: StringName, payload: Dictionary = {}, include_pipeline: bool = false) -> void:
	if not is_active() and kind != &"trace_started":
		return
	var capture_started := Time.get_ticks_usec()
	var event := _base_event(kind)
	if not payload.is_empty():
		event["payload"] = payload.duplicate(true)
	if include_pipeline:
		event["pipeline"] = _pipeline_snapshot()
	var capture_us := maxi(0, Time.get_ticks_usec() - capture_started)
	event["observer_us"] = capture_us
	_capture_time_us_total += capture_us
	_capture_time_us_maximum = maxi(_capture_time_us_maximum, capture_us)
	_append(event)


func write_snapshot(output_path: String, reason: String) -> Dictionary:
	if _started_us <= 0:
		return {"ok": false, "error": "trace_not_started"}
	if not _drain_native_trace():
		return {"ok": false, "error": _native_read_error}
	return _write(output_path, reason, false)


func finalize(reason: String = "scenario_complete") -> Dictionary:
	if _started_us <= 0:
		return {"ok": false, "error": "trace_not_started"}
	if _finalized:
		return {"ok": false, "error": "trace_already_finalized"}
	record(&"trace_final", {"reason": reason}, true)
	_terrain_world.call("end_cpu_causal_trace")
	if not _drain_native_trace():
		_finalized = true
		_native_session_started = false
		return {"ok": false, "error": _native_read_error}
	_native_session_started = false
	_finalized = true
	return _write(_output_path, reason, true)


func _pipeline_snapshot() -> Dictionary:
	var started := Time.get_ticks_usec()
	_drain_native_trace()
	var metrics: Dictionary = _terrain_world.call("get_runtime_metrics")
	var selected := {}
	for key in PIPELINE_METRICS:
		selected[key] = metrics.get(key, 0)
	var snapshot := {
		"world_revision": int(_terrain_world.call("get_backend_world_revision")),
		"metrics": selected,
		"native_trace": _native_status_summary(),
	}
	if _game_world.has_method("get_causal_trace_context"):
		snapshot["viewer"] = _game_world.call("get_causal_trace_context")
	if _target_enabled:
		snapshot["target"] = _target_snapshot()
	var elapsed_us := maxi(0, Time.get_ticks_usec() - started)
	snapshot["capture_us"] = elapsed_us
	_pipeline_capture_time_us_total += elapsed_us
	_pipeline_capture_time_us_maximum = maxi(
		_pipeline_capture_time_us_maximum, elapsed_us
	)
	_pipeline_snapshot_count += 1
	return snapshot


func _target_snapshot() -> Dictionary:
	var result := {
		"chunk": _vector3i_summary(_target_chunk),
		"lod": _target_lod,
		"present": false,
	}
	var state: RefCounted = _terrain_world.call(
		"query_chunk_state", _target_chunk, _target_lod
	)
	if state == null:
		return result
	result["present"] = true
	for method in [
		"get_generation", "is_visual_required", "is_visual_ready",
		"is_collision_required", "is_collision_ready", "get_render_generation",
		"get_staged_render_generation", "get_collision_generation",
	]:
		if state.has_method(method):
			result[method] = state.call(method)
	return result


func _base_event(kind: StringName) -> Dictionary:
	return {
		"sequence": _next_sequence,
		"elapsed_us": maxi(0, Time.get_ticks_usec() - _started_us),
		"frame": _frame,
		"kind": str(kind),
		"phase": _phase,
		"cause_id": _cause_id,
	}


func _append(event: Dictionary) -> void:
	event["sequence"] = _next_sequence
	_next_sequence += 1
	if _event_count == _capacity:
		_dropped_events += 1
	else:
		_event_count += 1
	_slots[_write_index] = event
	_write_index = (_write_index + 1) % _capacity


func _ordered_events() -> Array:
	var output := []
	output.resize(_event_count)
	var start := (_write_index - _event_count + _capacity) % _capacity
	for index in range(_event_count):
		output[index] = _slots[(start + index) % _capacity]
	return output


func _drain_native_trace() -> bool:
	if not _native_session_started or _native_read_failed:
		return not _native_read_failed
	var capture_started := Time.get_ticks_usec()
	for _batch in range(NATIVE_MAX_BATCHES_PER_DRAIN):
		var snapshot_value = _terrain_world.call(
			"get_cpu_causal_trace_events",
			_native_next_sequence,
			NATIVE_READ_BATCH
		)
		if not snapshot_value is Dictionary:
			return _fail_native_read("native_snapshot_not_dictionary", capture_started)
		var snapshot: Dictionary = snapshot_value
		if not bool(snapshot.get("valid", false)):
			return _fail_native_read("native_snapshot_invalid", capture_started)
		_native_status = snapshot.duplicate(false)
		_native_status.erase("events")
		var first_retained := int(snapshot.get(
			"first_retained_sequence", _native_next_sequence
		))
		if _native_next_sequence < first_retained:
			_native_source_gap_events += first_retained - _native_next_sequence
			_native_next_sequence = first_retained
		var events_value = snapshot.get("events", [])
		if not events_value is Array:
			return _fail_native_read("native_events_not_array", capture_started)
		var events: Array = events_value
		if events.is_empty():
			break
		for event_value in events:
			if not event_value is Dictionary:
				return _fail_native_read("native_event_not_dictionary", capture_started)
			var event: Dictionary = event_value
			var sequence := int(event.get("sequence", -1))
			if sequence < _native_next_sequence:
				continue
			if sequence > _native_next_sequence:
				_native_source_gap_events += sequence - _native_next_sequence
			_native_next_sequence = sequence + 1
			_append_native(event.duplicate(true))
		if _native_next_sequence >= int(snapshot.get(
			"next_sequence", _native_next_sequence
		)):
			break
	var capture_us := maxi(0, Time.get_ticks_usec() - capture_started)
	_native_capture_time_us_total += capture_us
	_native_capture_time_us_maximum = maxi(
		_native_capture_time_us_maximum, capture_us
	)
	_native_snapshot_count += 1
	return true


func _fail_native_read(error: String, capture_started: int) -> bool:
	_native_read_failed = true
	_native_read_error = error
	var capture_us := maxi(0, Time.get_ticks_usec() - capture_started)
	_native_capture_time_us_total += capture_us
	_native_capture_time_us_maximum = maxi(
		_native_capture_time_us_maximum, capture_us
	)
	_native_snapshot_count += 1
	return false


func _append_native(event: Dictionary) -> void:
	if _native_event_count == NATIVE_EVENT_CAPACITY:
		_native_local_dropped_events += 1
	else:
		_native_event_count += 1
	_native_slots[_native_write_index] = event
	_native_write_index = (_native_write_index + 1) % NATIVE_EVENT_CAPACITY


func _ordered_native_events() -> Array:
	var output := []
	output.resize(_native_event_count)
	var start := (
		_native_write_index - _native_event_count + NATIVE_EVENT_CAPACITY
	) % NATIVE_EVENT_CAPACITY
	for index in range(_native_event_count):
		output[index] = _native_slots[(start + index) % NATIVE_EVENT_CAPACITY]
	return output


func _native_status_summary() -> Dictionary:
	return {
		"read_failed": _native_read_failed,
		"read_error": _native_read_error,
		"source_enabled": bool(_native_status.get("enabled", false)),
		"source_capacity": int(_native_status.get("capacity", 0)),
		"source_retained_event_count": int(_native_status.get(
			"retained_event_count", 0
		)),
		"source_overwrite_count": int(_native_status.get(
			"dropped_event_count", 0
		)),
		"source_first_retained_sequence": int(_native_status.get(
			"first_retained_sequence", 0
		)),
		"source_next_sequence": int(_native_status.get(
			"next_sequence", _native_next_sequence
		)),
		"consumer_next_sequence": _native_next_sequence,
		"consumer_gap_event_count": _native_source_gap_events,
		"local_retained_event_count": _native_event_count,
		"local_dropped_event_count": _native_local_dropped_events,
	}


func _native_envelope() -> Dictionary:
	var summary := _native_status_summary()
	summary["schema"] = "world_transvoxel.native_cpu_causal_trace.v1"
	summary["local_event_capacity"] = NATIVE_EVENT_CAPACITY
	summary["complete"] = (
		not _native_read_failed and
		_native_source_gap_events == 0 and
		_native_local_dropped_events == 0
	)
	summary["capture_time_us_total"] = _native_capture_time_us_total
	summary["capture_time_us_maximum"] = _native_capture_time_us_maximum
	summary["snapshot_count"] = _native_snapshot_count
	summary["events"] = _ordered_native_events()
	return summary


func _write(output_path: String, reason: String, final: bool) -> Dictionary:
	if output_path.is_empty():
		return {"ok": false, "error": "output_path_empty"}
	var absolute_path := output_path
	if output_path.begins_with("res://") or output_path.begins_with("user://"):
		absolute_path = ProjectSettings.globalize_path(output_path)
	var make_error := DirAccess.make_dir_recursive_absolute(
		absolute_path.get_base_dir()
	)
	if make_error != OK:
		return {"ok": false, "error": "output_directory_failed", "code": make_error}
	var envelope := {
		"schema": SCHEMA,
		"mode": _mode,
		"reason": reason,
		"final": final,
		"started_ticks_us": _started_us,
		"duration_us": maxi(0, Time.get_ticks_usec() - _started_us),
		"frame_count": _frame,
		"event_capacity": _capacity,
		"event_count": _event_count,
		"dropped_event_count": _dropped_events,
		"first_retained_sequence": _next_sequence - _event_count,
		"next_sequence": _next_sequence,
		"observer": _observer_summary(),
		"native": _native_envelope(),
		"events": _ordered_events(),
	}
	var serialization_started := Time.get_ticks_usec()
	JSON.stringify(envelope)
	var serialization_probe_us := maxi(
		0, Time.get_ticks_usec() - serialization_started
	)
	envelope["observer"]["serialization_probe_us"] = serialization_probe_us
	var encoded := JSON.stringify(envelope)
	var write_started := Time.get_ticks_usec()
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		return {
			"ok": false,
			"error": "output_open_failed",
			"code": FileAccess.get_open_error(),
		}
	file.store_string(encoded + "\n")
	file.close()
	var write_us := maxi(0, Time.get_ticks_usec() - write_started)
	return {
		"ok": true,
		"path": absolute_path,
		"reason": reason,
		"final": final,
		"event_count": _event_count,
		"dropped_event_count": _dropped_events,
		"native_complete": bool(envelope["native"].get("complete", false)),
		"native_event_count": _native_event_count,
		"payload_bytes": encoded.to_utf8_buffer().size() + 1,
		"serialization_probe_us": serialization_probe_us,
		"write_us": write_us,
		"observer": _observer_summary(),
	}


func _observer_summary() -> Dictionary:
	return {
		"capture_time_us_total": _capture_time_us_total,
		"capture_time_us_maximum": _capture_time_us_maximum,
		"capture_time_us_mean": (
			float(_capture_time_us_total) / float(maxi(1, _next_sequence))
		),
		"pipeline_snapshot_count": _pipeline_snapshot_count,
		"pipeline_capture_time_us_total": _pipeline_capture_time_us_total,
		"pipeline_capture_time_us_maximum": _pipeline_capture_time_us_maximum,
	}


func _vector3_summary(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}


func _vector3i_summary(value: Vector3i) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}

@tool
extends RefCounted
class_name WtTerrainRuntimeState

const IMPLEMENTATION := "tqp52_generation_aware_readiness_v1"
const DEFAULT_MAXIMUM_ASYNC_REQUESTS := 64
const DEFAULT_VIEWER_CAPACITY := 8

var _api_generation: int = 0
var _world_running: bool = false
var _maximum_async_requests: int = DEFAULT_MAXIMUM_ASYNC_REQUESTS
var _viewer_capacity: int = DEFAULT_VIEWER_CAPACITY
var _pending_requests: Dictionary = {}
var _viewer_revisions: Dictionary = {}
var _collision_viewer_revisions: Dictionary = {}
var _edit_pending: bool = false
var _last_transition: String = "created"


func configure(runtime_profile: Resource) -> String:
	_maximum_async_requests = DEFAULT_MAXIMUM_ASYNC_REQUESTS
	_viewer_capacity = DEFAULT_VIEWER_CAPACITY
	if runtime_profile == null:
		return ""
	if not runtime_profile.has_method("get_validation_error"):
		return "runtime_profile must expose validation"
	var validation_error := str(runtime_profile.call("get_validation_error"))
	if not validation_error.is_empty():
		return validation_error
	_maximum_async_requests = int(runtime_profile.get("maximum_async_requests"))
	_viewer_capacity = int(runtime_profile.get("viewer_capacity"))
	return ""


func transition(running: bool, reason: String) -> Array[Dictionary]:
	var cancelled: Array[Dictionary] = []
	for request_id in _pending_requests:
		var record := Dictionary(_pending_requests[request_id]).duplicate(true)
		record["request_id"] = int(request_id)
		record["reason"] = reason
		cancelled.append(record)
	_api_generation += 1
	_world_running = running
	_pending_requests.clear()
	_viewer_revisions.clear()
	_collision_viewer_revisions.clear()
	_edit_pending = false
	_last_transition = reason
	return cancelled


func get_api_generation() -> int:
	return _api_generation


func can_submit_request() -> String:
	if not _world_running:
		return "world is not running"
	if _pending_requests.size() >= _maximum_async_requests:
		return "async request capacity reached"
	return ""


func register_request(request_id: int, kind: StringName, world_revision: int) -> bool:
	if request_id <= 0 or _pending_requests.has(request_id):
		return false
	_pending_requests[request_id] = {
		"kind": str(kind),
		"api_generation": _api_generation,
		"world_revision": world_revision,
	}
	return true


func finish_request(request_id: int, expected_kind: StringName) -> Dictionary:
	if not _pending_requests.has(request_id):
		return {"accepted": false, "reason": "untracked_or_cancelled_request"}
	var record := Dictionary(_pending_requests[request_id]).duplicate(true)
	_pending_requests.erase(request_id)
	record["request_id"] = request_id
	if int(record.get("api_generation", -1)) != _api_generation:
		record["accepted"] = false
		record["reason"] = "stale_api_generation"
		return record
	if str(record.get("kind", "")) != str(expected_kind):
		record["accepted"] = false
		record["reason"] = "request_kind_mismatch"
		return record
	record["accepted"] = true
	record["reason"] = "ok"
	return record


func validate_viewer_update(viewer_id: int, revision: int, collision_only: bool) -> String:
	if not _world_running:
		return "world is not running"
	if viewer_id <= 0 or revision <= 0:
		return "viewer_id and revision must be positive"
	var revisions := _collision_viewer_revisions if collision_only else _viewer_revisions
	if not revisions.has(viewer_id) and revisions.size() >= _viewer_capacity:
		return "viewer capacity reached"
	if revisions.has(viewer_id) and revision <= int(revisions[viewer_id]):
		return "viewer revision must be monotonic"
	return ""


func record_viewer_update(viewer_id: int, revision: int, collision_only: bool) -> void:
	var revisions := _collision_viewer_revisions if collision_only else _viewer_revisions
	revisions[viewer_id] = revision


func validate_viewer_removal(viewer_id: int, revision: int, collision_only: bool) -> String:
	var revisions := _collision_viewer_revisions if collision_only else _viewer_revisions
	if not revisions.has(viewer_id):
		return "viewer is not registered"
	if revision <= int(revisions[viewer_id]):
		return "viewer removal revision must be monotonic"
	return ""


func record_viewer_removal(viewer_id: int, collision_only: bool) -> void:
	var revisions := _collision_viewer_revisions if collision_only else _viewer_revisions
	revisions.erase(viewer_id)


func mark_edit_submitted() -> void:
	_edit_pending = true


func mark_edit_finished() -> void:
	_edit_pending = false


func readiness_snapshot(world) -> Dictionary:
	var metrics: Dictionary = world.get_runtime_metrics()
	var backend_state: String = str(world.get_backend_world_state_name())
	var base_state := "ready" if _world_running else ("failed" if backend_state == "failed" else "unavailable")
	var render_state := base_state
	var collision_state := base_state
	var edit_state := base_state
	var query_state := base_state
	if _world_running:
		render_state = _render_state(metrics)
		collision_state = _collision_state(metrics)
		edit_state = "pending" if _edit_pending or bool(metrics.get("pending_edit_operation", false)) else "ready"
		query_state = "backpressured" if _pending_requests.size() >= _maximum_async_requests else "ready"
	return {
		"api_generation": _api_generation,
		"world_revision": world.get_backend_world_revision(),
		"source_revision": world.get_backend_world_source_revision(),
		"world_state": backend_state,
		"render": {"state": render_state, "requested_viewers": _viewer_revisions.size()},
		"collision": {"state": collision_state, "requested_viewers": _collision_viewer_revisions.size(), "required_chunks": int(metrics.get("collision_required_chunk_records", 0)), "not_ready_chunks": int(metrics.get("collision_required_not_ready_chunk_records", 0))},
		"edit": {"state": edit_state, "pending": _edit_pending},
		"query": {"state": query_state, "pending": _pending_requests.size(), "capacity": _maximum_async_requests},
		"back_pressure": {"viewer_count": _viewer_revisions.size() + _collision_viewer_revisions.size(), "viewer_capacity_per_kind": _viewer_capacity, "async_request_count": _pending_requests.size(), "async_request_capacity": _maximum_async_requests, "scheduler_queue_rejections": int(metrics.get("scheduler_queue_rejections", 0)), "application_queue_rejections": int(metrics.get("application_queue_rejections", 0)), "storage_queue_rejections": int(metrics.get("storage_request_queue_rejections", 0))},
		"last_transition": _last_transition,
		"implementation": IMPLEMENTATION,
	}


func chunk_readiness(world, chunk_coordinate: Vector3i, lod: int) -> Dictionary:
	var state: RefCounted = world.query_chunk_state(chunk_coordinate, lod)
	if state == null:
		return {"present": false, "state": "unavailable", "error": world.get_last_error(), "api_generation": _api_generation}
	return {
		"present": bool(state.call("is_present")),
		"chunk_coordinate": chunk_coordinate,
		"lod": lod,
		"generation": int(state.call("get_generation")),
		"render_generation": int(state.call("get_render_generation")),
		"staged_render_generation": int(state.call("get_staged_render_generation")),
		"collision_generation": int(state.call("get_collision_generation")),
		"staged_collision_generation": int(state.call("get_staged_collision_generation")),
		"render_state": "ready" if bool(state.call("is_visual_ready")) else ("pending" if bool(state.call("is_present")) else "not_requested"),
		"collision_state": "ready" if bool(state.call("is_collision_ready")) else ("pending" if bool(state.call("is_collision_required")) else "not_requested"),
		"fully_ready": bool(state.call("is_fully_ready")),
		"api_generation": _api_generation,
		"implementation": IMPLEMENTATION,
	}


func _render_state(metrics: Dictionary) -> String:
	if _viewer_revisions.is_empty():
		return "not_requested"
	if int(metrics.get("scheduler_failed_records", 0)) > 0 or int(metrics.get("page_mesh_failures", 0)) > 0:
		return "failed"
	if int(metrics.get("queued_render", 0)) > 0 or int(metrics.get("scheduler_queued_jobs", 0)) > 0 or int(metrics.get("pending_chunk_replacements", 0)) > 0:
		return "pending"
	if int(metrics.get("non_retiring_visual_ready_chunk_records", 0)) < int(metrics.get("non_retiring_chunk_records", 0)):
		return "pending"
	return "ready"


func _collision_state(metrics: Dictionary) -> String:
	if _collision_viewer_revisions.is_empty() and int(metrics.get("collision_required_chunk_records", 0)) == 0:
		return "not_requested"
	if int(metrics.get("application_sink_failures", 0)) > 0:
		return "failed"
	if int(metrics.get("queued_collision", 0)) > 0 or int(metrics.get("collision_required_not_ready_chunk_records", 0)) > 0:
		return "pending"
	return "ready"

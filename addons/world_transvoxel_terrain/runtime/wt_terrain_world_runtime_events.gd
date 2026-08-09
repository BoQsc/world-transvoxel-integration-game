extends RefCounted


static func track_request(world, runtime_state, kind: StringName, submit: Callable) -> int:
	var capacity_error: String = str(runtime_state.can_submit_request())
	if not capacity_error.is_empty():
		world._last_error = capacity_error
		return 0
	var request_id := int(submit.call())
	if request_id > 0 and not runtime_state.register_request(
		request_id, kind, world.get_backend_world_revision()
	):
		world._last_error = "failed to register terrain request"
		return 0
	emit_readiness(world, runtime_state)
	return request_id


static func finish_request(
	world,
	runtime_state,
	request_id: int,
	kind: StringName,
	error: String
) -> bool:
	var record: Dictionary = runtime_state.finish_request(request_id, kind)
	if not bool(record.get("accepted", false)):
		return false
	var generation := int(record.get("api_generation", 0))
	if error.is_empty():
		world.terrain_request_completed.emit(
			request_id, str(kind), generation, world.get_backend_world_revision()
		)
	else:
		world.terrain_request_failed.emit(request_id, str(kind), generation, error)
	emit_readiness(world, runtime_state)
	return true


static func transition_runtime(
	world,
	runtime_state,
	running: bool,
	reason: String
) -> void:
	var cancelled: Array = runtime_state.transition(running, reason)
	for record in cancelled:
		world.terrain_request_cancelled.emit(
			int(record.get("request_id", 0)),
			str(record.get("kind", "unknown")),
			int(record.get("api_generation", 0)),
			reason
		)
	world.runtime_generation_changed.emit(
		runtime_state.get_api_generation(), running, reason
	)
	emit_readiness(world, runtime_state)


static func emit_readiness(world, runtime_state) -> void:
	world.readiness_changed.emit(runtime_state.readiness_snapshot(world))


static func forward_ready(world, runtime_state, request_id: int, kind: StringName, arguments: Array) -> void:
	if not finish_request(world, runtime_state, request_id, kind, ""):
		return
	match kind:
		&"world_snapshot":
			world.world_snapshot_ready.emit(request_id, arguments[0], arguments[1], arguments[2], arguments[3])
		&"sample":
			world.authoritative_sample_ready.emit(request_id, arguments[0])
		&"samples":
			world.authoritative_samples_ready.emit(request_id, arguments[0])


static func forward_failed(world, runtime_state, request_id: int, kind: StringName, error: String) -> void:
	if not finish_request(world, runtime_state, request_id, kind, error):
		return
	match kind:
		&"world_snapshot": world.world_snapshot_failed.emit(request_id, error)
		&"sample": world.authoritative_sample_failed.emit(request_id, error)
		&"samples": world.authoritative_samples_failed.emit(request_id, error)


static func forward_edit(world, runtime_state, committed: bool, value) -> void:
	runtime_state.mark_edit_finished()
	if committed:
		world.edit_committed.emit(int(value))
	else:
		world.edit_failed.emit(str(value))
	emit_readiness(world, runtime_state)

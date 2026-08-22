extends RefCounted

var _host: Node3D
var _player: CharacterBody3D
var _game_world: Node
var _terrain_world: Node
var _trace: RefCounted


func run(
	host: Node3D,
	player: CharacterBody3D,
	game_world: Node,
	trace: RefCounted,
	profile: StringName
) -> Dictionary:
	_host = host
	_player = player
	_game_world = game_world
	_trace = trace
	if _host == null or _player == null or _game_world == null or _trace == null:
		return {"ok": false, "error": "required_runtime_missing"}
	_terrain_world = _game_world.call("get_terrain_world")
	if _terrain_world == null:
		return {"ok": false, "error": "terrain_world_missing"}
	_player.call("set_human_input_enabled", false)
	var route := {
		"profile": str(profile),
		"legs": [],
		"edits": [],
	}
	route["legs"].append(await _flight_leg(
		"flight_ascend", Vector3.UP * 16.0, 90
	))
	route["legs"].append(await _flight_leg(
		"flight_relocation_carve",
		Vector3(1.0, 0.0, 1.0).normalized() * 32.0,
		480
	))
	var carve_surface := await _wait_for_surface()
	if is_inf(carve_surface.x):
		route["error"] = "carve_surface_unavailable"
		return {"ok": false, "route": route}
	var carve_result := await _submit_and_wait(
		&"carve", carve_surface - Vector3(0.0, 0.7, 0.0)
	)
	route["edits"].append(carve_result)
	if not bool(carve_result.get("committed", false)):
		route["error"] = "carve_not_committed"
		return {"ok": false, "route": route}
	route["legs"].append(await _flight_leg(
		"flight_relocation_construct",
		Vector3(-1.0, 0.0, 1.0).normalized() * 32.0,
		480
	))
	var construct_surface := await _wait_for_surface()
	if is_inf(construct_surface.x):
		route["error"] = "construct_surface_unavailable"
		return {"ok": false, "route": route}
	var construct_result := await _submit_and_wait(
		&"construct", construct_surface + Vector3(0.0, 0.7, 0.0)
	)
	route["edits"].append(construct_result)
	if not bool(construct_result.get("committed", false)):
		route["error"] = "construct_not_committed"
		return {"ok": false, "route": route}
	for _frame in range(120):
		await _capture_wait_frame()
	return {"ok": true, "route": route}


func _flight_leg(
	label: String,
	requested_velocity: Vector3,
	frame_count: int
) -> Dictionary:
	_trace.call("begin_phase", label, "waterfall:%s" % label, false)
	_player.call("set_fly_mode_enabled", true)
	var start_position := _player.global_position
	var accepted_frames := 0
	var blocked_frames := 0
	for _frame in range(frame_count):
		var accepted := bool(_player.call(
			"diagnostic_flight_step",
			requested_velocity,
			_host.get_physics_process_delta_time()
		))
		if accepted:
			accepted_frames += 1
		else:
			blocked_frames += 1
		await _host.get_tree().physics_frame
	return {
		"label": label,
		"requested_speed": requested_velocity.length(),
		"frame_count": frame_count,
		"accepted_frames": accepted_frames,
		"blocked_frames": blocked_frames,
		"distance": start_position.distance_to(_player.global_position),
		"start": _vector3_summary(start_position),
		"end": _vector3_summary(_player.global_position),
	}


func _wait_for_surface() -> Vector3:
	_trace.call(
		"begin_phase", "relocation_surface_wait", "waterfall:surface", true
	)
	for _frame in range(900):
		var center := Vector3(_player.global_position.x, 0.0, _player.global_position.z)
		var target := _find_collision_surface_near([
			center,
			center + Vector3(8.0, 0.0, 0.0),
			center + Vector3(0.0, 0.0, 8.0),
			center + Vector3(-8.0, 0.0, 0.0),
		])
		if not is_inf(target.x):
			_player.global_position = target + Vector3(0.0, 2.0, 0.0)
			_player.velocity = Vector3.ZERO
			_player.call("set_fly_mode_enabled", false)
			_game_world.call("update_player_viewer", true)
			return target
		await _capture_wait_frame()
	return Vector3(INF, INF, INF)


func _find_collision_surface_near(points: Array) -> Vector3:
	for point in points:
		var probe: Vector3 = point
		var query := PhysicsRayQueryParameters3D.create(
			probe + Vector3(0.0, 180.0, 0.0),
			probe + Vector3(0.0, -240.0, 0.0)
		)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		if _player is CollisionObject3D:
			query.exclude = [(_player as CollisionObject3D).get_rid()]
		var hit := _host.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			return hit["position"]
	return Vector3(INF, INF, INF)


func _submit_and_wait(mode: StringName, center: Vector3) -> Dictionary:
	_trace.call(
		"begin_phase", "relocated_%s" % str(mode),
		"waterfall:edit:%s" % str(mode), true
	)
	var before_revision := int(_terrain_world.call("get_backend_world_revision"))
	var accepted := bool(_player.call("submit_edit_input", mode, center, true))
	var committed := false
	for _frame in range(300):
		if int(_terrain_world.call("get_backend_world_revision")) > before_revision:
			committed = true
			break
		await _capture_wait_frame()
	var ready := false
	var ready_frame := -1
	var target_chunk := Vector3i(
		floori(center.x / 16.0), floori(center.y / 16.0),
		floori(center.z / 16.0)
	)
	for frame in range(1200):
		var state: RefCounted = _terrain_world.call(
			"query_chunk_state", target_chunk, 0
		)
		var metrics: Dictionary = _terrain_world.call("get_runtime_metrics")
		ready = state != null and \
				bool(state.call("is_visual_ready")) and \
				bool(state.call("is_collision_ready")) and \
				int(metrics.get("pending_chunk_replacements", 0)) == 0 and \
				int(metrics.get("pending_chunk_retirements", 0)) == 0 and \
				int(metrics.get("pending_render_retirements", 0)) == 0
		if ready:
			ready_frame = frame
			break
		await _capture_wait_frame()
	_trace.call("record", &"autonomous_edit_wait_finished", {
		"mode": str(mode),
		"accepted": accepted,
		"committed": committed,
		"ready": ready,
		"ready_frame": ready_frame,
		"center": _vector3_summary(center),
	}, true)
	return {
		"mode": str(mode),
		"center": _vector3_summary(center),
		"accepted": accepted,
		"committed": committed,
		"ready": ready,
		"ready_frame": ready_frame,
	}


func _capture_wait_frame() -> void:
	await _host.get_tree().physics_frame
	if _trace == null or not bool(_trace.call("is_active")):
		return
	_trace.call(
		"note_movement", true, Vector3.ZERO,
		_player.global_position, _player.global_position, "wait"
	)
	_trace.call("capture_physics_frame")


func _vector3_summary(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}

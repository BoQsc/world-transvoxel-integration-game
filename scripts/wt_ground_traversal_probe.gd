extends RefCounted

const SCHEMA := "world_transvoxel.ground_traversal_probe.v1"
const ROAD_START_XZ := Vector2(360.0, 360.0)
const ROAD_END_XZ := Vector2(820.0, 420.0)
const TEST_DISTANCE := 192.0
const WALK_SPEED := 8.0
const NOMINAL_PHYSICS_FPS := 60.0
const STATIC_FRAMES := 180
const MAX_RELOCATION_WAIT_FRAMES := 1800
const MAX_PRETRAVERSAL_SETTLE_FRAMES := 900
const REQUIRED_SETTLED_FRAMES := 30
const MAX_EXTRA_MOVEMENT_FRAMES := 900
const MAX_ACCEPTABLE_BLOCKED_FRAMES := 2
const MAX_MISSING_FLOOR_FRAMES := 2
const PLAYER_FOOT_OFFSET := 0.9
const FLOOR_PENETRATION_TOLERANCE := 0.20
const FLOOR_LOSS_DROP_TOLERANCE := 0.35

var _host: Node3D
var _player: CharacterBody3D
var _game_world: Node
var _terrain_world: Node
var _output_path := ""
var _profile := ""
var _frames: Array = []
var _static_frame_us: Array[float] = []
var _moving_frame_us: Array[float] = []
var _defects: Array = []
var _block_events: Array = []
var _blocked_frames := 0
var _longest_blocked_run := 0
var _current_blocked_run := 0
var _missing_floor_run := 0
var _longest_missing_floor_run := 0
var _last_confirmed_floor_y := -INF
var _maximum_floor_penetration := 0.0
var _started_us := 0
var _defect_diagnosis := {}
var _pretraversal_settle_frames := 0
var _pretraversal_settled := false


func run(
	host: Node3D,
	player: CharacterBody3D,
	game_world: Node,
	profile: StringName,
	output_path: String
) -> Dictionary:
	_host = host
	_player = player
	_game_world = game_world
	_profile = str(profile)
	_output_path = output_path
	_started_us = Time.get_ticks_usec()
	if _host == null or _player == null or _game_world == null:
		return await _finish(false, "required_runtime_missing", Vector3.ZERO)
	_terrain_world = _game_world.call("get_terrain_world")
	if _terrain_world == null:
		return await _finish(false, "terrain_world_missing", Vector3.ZERO)
	_player.call("set_human_input_enabled", false)
	print("WT_GROUND_TRAVERSAL_PHASE phase=relocation")
	var start_surface := await _relocate_to_road_start()
	if is_inf(start_surface.x):
		return await _finish(false, "road_start_collision_unavailable", Vector3.ZERO)
	var direction_2d := (ROAD_END_XZ - ROAD_START_XZ).normalized()
	var requested_velocity := Vector3(
		direction_2d.x * WALK_SPEED, 0.0, direction_2d.y * WALK_SPEED
	)
	print("WT_GROUND_TRAVERSAL_PHASE phase=settling")
	_pretraversal_settled = await _settle_pretraversal_streaming()
	if not _pretraversal_settled:
		return await _finish(false, "pretraversal_streaming_not_settled", start_surface)
	print("WT_GROUND_TRAVERSAL_PHASE phase=static")
	for frame in range(STATIC_FRAMES):
		await _step(Vector3.ZERO, "static", frame, _static_frame_us)
		if not _defects.is_empty():
			await _diagnose_defect_recovery()
			return await _finish(false, "static_ground_defect", start_surface)
	print("WT_GROUND_TRAVERSAL_PHASE phase=moving")
	var nominal_moving_frames := ceili(
		TEST_DISTANCE / WALK_SPEED * NOMINAL_PHYSICS_FPS
	)
	var movement_origin := _player.global_position
	var progress := 0.0
	for frame in range(nominal_moving_frames + MAX_EXTRA_MOVEMENT_FRAMES):
		await _step(requested_velocity, "moving", frame, _moving_frame_us)
		if not _defects.is_empty():
			await _diagnose_defect_recovery()
			return await _finish(false, "ground_traversal_defect", start_surface)
		var displacement := Vector2(
			_player.global_position.x - movement_origin.x,
			_player.global_position.z - movement_origin.z
		)
		progress = displacement.dot(direction_2d)
		if progress >= TEST_DISTANCE:
			break
	if progress < TEST_DISTANCE:
		return await _finish(false, "traversal_distance_incomplete", start_surface)
	if _blocked_frames > MAX_ACCEPTABLE_BLOCKED_FRAMES:
		return await _finish(false, "collision_guard_intervened", start_surface)
	return await _finish(true, "completed", start_surface)


func _settle_pretraversal_streaming() -> bool:
	var settled_run := 0
	for frame in range(MAX_PRETRAVERSAL_SETTLE_FRAMES):
		await _host.get_tree().physics_frame
		_pretraversal_settle_frames = frame + 1
		var runtime := _runtime_digest()
		if _runtime_is_settled(runtime):
			settled_run += 1
			if settled_run >= REQUIRED_SETTLED_FRAMES:
				return true
		else:
			settled_run = 0
	return false


func _runtime_is_settled(runtime: Dictionary) -> bool:
	return int(runtime.get("scheduler_queued_jobs", 0)) == 0 and \
		int(runtime.get("queued_render", 0)) == 0 and \
		int(runtime.get("queued_collision", 0)) == 0 and \
		int(runtime.get("deferred_collision", 0)) == 0 and \
		int(runtime.get("total_collision_backlog", 0)) == 0 and \
		int(runtime.get("pending_chunk_replacements", 0)) == 0 and \
		int(runtime.get("pending_chunk_retirements", 0)) == 0


func _relocate_to_road_start() -> Vector3:
	_player.call("set_fly_mode_enabled", false)
	_player.global_position = Vector3(ROAD_START_XZ.x, 74.0, ROAD_START_XZ.y)
	_player.velocity = Vector3.ZERO
	_game_world.call("update_player_viewer", true)
	for _frame in range(MAX_RELOCATION_WAIT_FRAMES):
		var floor := _floor_probe(_player.global_position)
		if bool(floor.get("hit", false)):
			var surface: Vector3 = floor["position"]
			_player.global_position = surface + Vector3.UP * (
				PLAYER_FOOT_OFFSET + 0.08
			)
			_player.velocity = Vector3.ZERO
			_game_world.call("update_player_viewer", true)
			for _settle in range(30):
				_player.call(
					"diagnostic_walk_step", Vector3.ZERO,
					maxf(_host.get_physics_process_delta_time(), 1.0 / 120.0)
				)
				await _host.get_tree().physics_frame
			var road_direction := Vector3(
				ROAD_END_XZ.x - ROAD_START_XZ.x,
				0.0,
				ROAD_END_XZ.y - ROAD_START_XZ.y
			).normalized()
			_player.call(
				"set_view_target",
				_player.global_position + road_direction * 14.0 + Vector3.DOWN * 3.0
			)
			return surface
		await _host.get_tree().physics_frame
		if _frame % 30 == 0:
			_game_world.call("update_player_viewer", true)
	return Vector3(INF, INF, INF)


func _step(
	requested_velocity: Vector3,
	phase: String,
	phase_frame: int,
	frame_times: Array[float]
) -> void:
	var tick_before := Time.get_ticks_usec()
	var position_before := _player.global_position
	var accepted := bool(_player.call(
		"diagnostic_walk_step",
		requested_velocity,
		maxf(_host.get_physics_process_delta_time(), 1.0 / 120.0)
	))
	await _host.get_tree().physics_frame
	var frame_us := float(Time.get_ticks_usec() - tick_before)
	frame_times.append(frame_us)
	var position_after := _player.global_position
	var floor := _floor_probe(position_after)
	var floor_hit := bool(floor.get("hit", false))
	var floor_y := float(floor.get("position", Vector3.ZERO).y) if floor_hit else -INF
	var foot_y := position_after.y - PLAYER_FOOT_OFFSET
	var clearance := foot_y - floor_y if floor_hit else INF
	var completed_block_run := _current_blocked_run if accepted else 0
	if accepted:
		_current_blocked_run = 0
	else:
		_blocked_frames += 1
		_current_blocked_run += 1
		_longest_blocked_run = maxi(
			_longest_blocked_run, _current_blocked_run
		)
	if floor_hit:
		_missing_floor_run = 0
		_last_confirmed_floor_y = floor_y
		if clearance < -FLOOR_PENETRATION_TOLERANCE:
			_maximum_floor_penetration = maxf(
				_maximum_floor_penetration, -clearance
			)
			_record_defect(
				"player_below_collision_surface", phase, phase_frame,
				position_after, floor_y, clearance
			)
	else:
		_missing_floor_run += 1
		_longest_missing_floor_run = maxi(
			_longest_missing_floor_run, _missing_floor_run
		)
		if _missing_floor_run > MAX_MISSING_FLOOR_FRAMES:
			_record_defect(
				"collision_floor_missing", phase, phase_frame,
				position_after, -INF, INF
			)
	if not is_inf(_last_confirmed_floor_y) and \
			foot_y < _last_confirmed_floor_y - FLOOR_LOSS_DROP_TOLERANCE and \
			not floor_hit:
		_record_defect(
			"player_dropped_below_last_floor", phase, phase_frame,
			position_after, _last_confirmed_floor_y, foot_y - _last_confirmed_floor_y
		)
	var collision_status: Dictionary = _player.call(
		"get_streaming_collision_status"
	)
	if not accepted and _current_blocked_run == 1:
		_block_events.append({
			"start_phase_frame": phase_frame,
			"position": _vector3_summary(position_after),
			"runtime": _runtime_digest(),
			"collision": _collision_digest(),
			"active_coverage": _active_coverage(position_after),
			"scene_collision_nodes": _scene_collision_nodes(position_after),
		})
	elif accepted and completed_block_run > 0 and not _block_events.is_empty():
		var event: Dictionary = _block_events[-1]
		event["blocked_frames"] = completed_block_run
		event["recovery_phase_frame"] = phase_frame
		event["recovery_runtime"] = _runtime_digest()
	var frame_record := {
		"phase": phase,
		"phase_frame": phase_frame,
		"elapsed_us": Time.get_ticks_usec() - _started_us,
		"frame_us": frame_us,
		"accepted": accepted,
		"position_before": _vector3_summary(position_before),
		"position_after": _vector3_summary(position_after),
		"distance": position_before.distance_to(position_after),
		"is_on_floor": _player.is_on_floor(),
		"floor_hit": floor_hit,
		"floor_y": floor_y if floor_hit else null,
		"foot_clearance": clearance if floor_hit else null,
		"collision_waiting": bool(collision_status.get("waiting", false)),
		"collision_wait_seconds": float(collision_status.get("wait_seconds", 0.0)),
	}
	if phase_frame % 15 == 0 or not accepted or not floor_hit or \
			clearance < -FLOOR_PENETRATION_TOLERANCE:
		frame_record["runtime"] = _runtime_digest()
	_frames.append(frame_record)


func _floor_probe(position: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(position.x, 127.5, position.z),
		Vector3(position.x, -127.5, position.z)
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	if _player is CollisionObject3D:
		query.exclude = [(_player as CollisionObject3D).get_rid()]
	var hit := _host.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {"hit": false}
	return {
		"hit": true,
		"position": hit["position"],
		"normal": hit["normal"],
		"collider_id": int(hit.get("collider_id", 0)),
		"collider_name": str(hit.get("collider", "")),
	}


func _record_defect(
	kind: String,
	phase: String,
	phase_frame: int,
	position: Vector3,
	floor_y: float,
	clearance: float
) -> void:
	if not _defects.is_empty():
		return
	_defects.append({
		"kind": kind,
		"phase": phase,
		"phase_frame": phase_frame,
		"elapsed_us": Time.get_ticks_usec() - _started_us,
		"position": _vector3_summary(position),
		"floor_y": floor_y if not is_inf(floor_y) else null,
		"clearance": clearance if not is_inf(clearance) else null,
		"runtime": _runtime_digest(),
		"collision": _collision_digest(),
		"offset_floor_rays": _offset_floor_rays(position),
		"active_coverage": _active_coverage(position),
		"scene_collision_nodes": _scene_collision_nodes(position),
	})


func _diagnose_defect_recovery() -> void:
	if _defects.is_empty():
		return
	var defect_position := _player.global_position
	_player.call("set_fly_mode_enabled", true)
	_player.velocity = Vector3.ZERO
	var recovery_frame := -1
	var stable_floor_frames := 0
	var timeline: Array = []
	for frame in range(180):
		_player.call("diagnostic_flight_step", Vector3.ZERO, 1.0 / 60.0)
		await _host.get_tree().physics_frame
		var floor := _floor_probe(defect_position)
		if bool(floor.get("hit", false)):
			stable_floor_frames += 1
			if recovery_frame < 0:
				recovery_frame = frame
		else:
			stable_floor_frames = 0
		if frame < 12 or frame % 15 == 0 or stable_floor_frames == 1:
			timeline.append({
				"frame": frame,
				"floor_hit": bool(floor.get("hit", false)),
				"floor_y": float(floor.get("position", Vector3.ZERO).y) \
					if bool(floor.get("hit", false)) else null,
				"runtime": _runtime_digest(),
			})
		if stable_floor_frames >= 10:
			break
	_defect_diagnosis = {
		"position": _vector3_summary(defect_position),
		"recovery_frame": recovery_frame,
		"recovery_seconds": float(recovery_frame) / NOMINAL_PHYSICS_FPS \
			if recovery_frame >= 0 else null,
		"stable_floor_frames": stable_floor_frames,
		"offset_floor_rays_after_wait": _offset_floor_rays(defect_position),
		"active_coverage_after_wait": _active_coverage(defect_position),
		"scene_collision_nodes_after_wait": _scene_collision_nodes(defect_position),
		"timeline": timeline,
	}


func _runtime_digest() -> Dictionary:
	var metrics: Dictionary = _terrain_world.call("get_runtime_metrics")
	return {
		"scheduler_queued_jobs": int(metrics.get("scheduler_queued_jobs", 0)),
		"queued_render": int(metrics.get("queued_render", 0)),
		"queued_collision": int(metrics.get("queued_collision", 0)),
		"deferred_collision": int(metrics.get("deferred_collision", 0)),
		"total_collision_backlog": int(metrics.get("total_collision_backlog", 0)),
		"pending_chunk_replacements": int(metrics.get("pending_chunk_replacements", 0)),
		"pending_chunk_retirements": int(metrics.get("pending_chunk_retirements", 0)),
		"collision_required_not_ready_chunk_records": int(
			metrics.get("collision_required_not_ready_chunk_records", 0)
		),
		"render_resources": int(metrics.get("render_resources", 0)),
		"collision_resources": int(metrics.get("collision_resources", 0)),
	}


func _collision_digest() -> Dictionary:
	var status: Dictionary = _player.call("get_streaming_collision_status")
	var readiness: Dictionary = status.get("readiness", {})
	var chunks: Array = []
	for value in Array(readiness.get("not_ready_chunks", [])):
		var chunk: Dictionary = value
		chunks.append({
			"coordinate": _vector3i_summary(chunk.get("coordinate", Vector3i.ZERO)),
			"present": bool(chunk.get("present", false)),
			"collision_required": bool(chunk.get("collision_required", false)),
			"collision_ready": bool(chunk.get("collision_ready", false)),
		})
	return {
		"waiting": bool(status.get("waiting", false)),
		"wait_seconds": float(status.get("wait_seconds", 0.0)),
		"reason": str(readiness.get("reason", "unknown")),
		"not_ready_chunks": chunks,
	}


func _offset_floor_rays(position: Vector3) -> Array:
	var offsets := [
		Vector2.ZERO,
		Vector2(-0.15, 0.0), Vector2(0.15, 0.0),
		Vector2(0.0, -0.15), Vector2(0.0, 0.15),
		Vector2(-0.45, 0.0), Vector2(0.45, 0.0),
		Vector2(0.0, -0.45), Vector2(0.0, 0.45),
	]
	var results: Array = []
	for offset in offsets:
		var probe_position := position + Vector3(offset.x, 0.0, offset.y)
		var floor := _floor_probe(probe_position)
		results.append({
			"offset": {"x": offset.x, "z": offset.y},
			"hit": bool(floor.get("hit", false)),
			"floor_y": float(floor.get("position", Vector3.ZERO).y) \
				if bool(floor.get("hit", false)) else null,
			"collider": str(floor.get("collider_name", "")),
		})
	return results


func _active_coverage(position: Vector3) -> Array:
	var records: Array = []
	for value in _terrain_world.call("query_active_chunk_states"):
		var state := value as RefCounted
		if state == null or not bool(state.call("is_present")):
			continue
		var coordinate: Vector3i = state.call("get_chunk_coordinate")
		var lod := int(state.call("get_lod"))
		var extent := 16.0 * float(1 << lod)
		var minimum := Vector3(
			float(coordinate.x), float(coordinate.y), float(coordinate.z)
		) * extent
		var maximum := minimum + Vector3.ONE * extent
		if position.x < minimum.x - 0.5 or position.x > maximum.x + 0.5 or \
				position.z < minimum.z - 0.5 or position.z > maximum.z + 0.5 or \
				position.y < minimum.y - 16.0 or position.y > maximum.y + 16.0:
			continue
		records.append({
			"coordinate": _vector3i_summary(coordinate),
			"lod": lod,
			"generation": int(state.call("get_generation")),
			"visual_required": bool(state.call("is_visual_required")),
			"visual_ready": bool(state.call("is_visual_ready")),
			"render_generation": int(state.call("get_render_generation")),
			"staged_render_generation": int(
				state.call("get_staged_render_generation")
			),
			"collision_required": bool(state.call("is_collision_required")),
			"collision_ready": bool(state.call("is_collision_ready")),
			"collision_generation": int(state.call("get_collision_generation")),
			"staged_collision_generation": int(
				state.call("get_staged_collision_generation")
			),
		})
	return records


func _scene_collision_nodes(position: Vector3) -> Array:
	var backend: Node = _terrain_world.call("get_backend_terrain")
	if backend == null:
		return []
	var records: Array = []
	for child in backend.get_children():
		if not child is StaticBody3D:
			continue
		var node_name := str(child.name)
		if not node_name.begins_with("WT_Collision_"):
			continue
		var key := _parse_scene_chunk_key(node_name)
		if key.is_empty():
			continue
		var lod := int(key["lod"])
		var extent := 16.0 * float(1 << lod)
		var minimum := Vector3(
			float(key["x"]), float(key["y"]), float(key["z"])
		) * extent
		var maximum := minimum + Vector3.ONE * extent
		if position.x < minimum.x - 0.5 or position.x > maximum.x + 0.5 or \
				position.z < minimum.z - 0.5 or position.z > maximum.z + 0.5 or \
				position.y < minimum.y - 16.0 or position.y > maximum.y + 16.0:
			continue
		var collision_shape := child.get_node_or_null("Shape") as CollisionShape3D
		var face_count := -1
		if collision_shape != null and \
				collision_shape.shape is ConcavePolygonShape3D:
			face_count = (collision_shape.shape as ConcavePolygonShape3D).get_faces().size()
		records.append({
			"name": node_name,
			"lod": lod,
			"inside_tree": child.is_inside_tree(),
			"shape_present": collision_shape != null and collision_shape.shape != null,
			"face_count": face_count,
		})
	return records


func _parse_scene_chunk_key(node_name: String) -> Dictionary:
	var parts := node_name.trim_prefix("WT_Collision_").split("_")
	if parts.size() != 4 or not parts[3].begins_with("L"):
		return {}
	return {
		"x": int(parts[0]),
		"y": int(parts[1]),
		"z": int(parts[2]),
		"lod": int(parts[3].trim_prefix("L")),
	}


func _finish(ok: bool, reason: String, start_surface: Vector3) -> Dictionary:
	var result := {
		"schema": SCHEMA,
		"status": "PASS" if ok else "FAIL",
		"reason": reason,
		"profile": _profile,
		"walk_speed": WALK_SPEED,
		"requested_distance": TEST_DISTANCE,
		"completed_route_distance": _completed_route_distance(),
		"pretraversal_settled": _pretraversal_settled,
		"pretraversal_settle_frames": _pretraversal_settle_frames,
		"maximum_acceptable_blocked_frames": MAX_ACCEPTABLE_BLOCKED_FRAMES,
		"road_start": {"x": ROAD_START_XZ.x, "z": ROAD_START_XZ.y},
		"road_direction_target": {"x": ROAD_END_XZ.x, "z": ROAD_END_XZ.y},
		"start_surface": _vector3_summary(start_surface),
		"final_position": _vector3_summary(
			_player.global_position if _player != null else Vector3.ZERO
		),
		"elapsed_seconds": float(Time.get_ticks_usec() - _started_us) / 1000000.0,
		"frame_count": _frames.size(),
		"blocked_frames": _blocked_frames,
		"longest_blocked_run": _longest_blocked_run,
		"longest_missing_floor_run": _longest_missing_floor_run,
		"maximum_floor_penetration": _maximum_floor_penetration,
		"block_events": _block_events.duplicate(true),
		"static_frame_time_us": _distribution(_static_frame_us),
		"moving_frame_time_us": _distribution(_moving_frame_us),
		"defects": _defects.duplicate(true),
		"defect_diagnosis": _defect_diagnosis.duplicate(true),
		"final_runtime": _runtime_digest() if _terrain_world != null else {},
		"frames": _frames,
	}
	_write_result(result)
	if not ok:
		await _write_failure_screenshot()
	print("WT_GROUND_TRAVERSAL_RESULT ", JSON.stringify({
		"status": result["status"],
		"reason": reason,
		"blocked_frames": _blocked_frames,
		"longest_blocked_run": _longest_blocked_run,
		"longest_missing_floor_run": _longest_missing_floor_run,
		"maximum_floor_penetration": _maximum_floor_penetration,
		"output": _output_path,
	}))
	return result


func _completed_route_distance() -> float:
	if _player == null:
		return 0.0
	var direction := (ROAD_END_XZ - ROAD_START_XZ).normalized()
	return maxf(0.0, Vector2(
		_player.global_position.x - ROAD_START_XZ.x,
		_player.global_position.z - ROAD_START_XZ.y
	).dot(direction))


func _distribution(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {"count": 0}
	var ordered := values.duplicate()
	ordered.sort()
	var total := 0.0
	for value in ordered:
		total += value
	return {
		"count": ordered.size(),
		"mean": total / float(ordered.size()),
		"p50": _percentile(ordered, 0.50),
		"p95": _percentile(ordered, 0.95),
		"p99": _percentile(ordered, 0.99),
		"maximum": ordered[-1],
	}


func _percentile(ordered: Array, fraction: float) -> float:
	var index := clampi(
		ceili(fraction * float(ordered.size())) - 1,
		0,
		ordered.size() - 1
	)
	return float(ordered[index])


func _write_result(result: Dictionary) -> void:
	var absolute := _absolute_path(_output_path)
	if absolute.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		push_error("WT_GROUND_TRAVERSAL_WRITE_FAIL path=%s" % absolute)
		return
	file.store_string(JSON.stringify(result, "  ") + "\n")
	file.close()


func _write_failure_screenshot() -> void:
	if DisplayServer.get_name() == "headless":
		return
	await _host.get_tree().process_frame
	var image := _host.get_viewport().get_texture().get_image()
	if image == null:
		return
	var absolute := _absolute_path(_output_path)
	var screenshot_path := absolute.trim_suffix(".json") + "_failure.png"
	image.save_png(screenshot_path)


func _absolute_path(path: String) -> String:
	if path.is_empty():
		return ""
	return ProjectSettings.globalize_path(path) if path.begins_with("res://") else path


func _vector3_summary(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}


func _vector3i_summary(value: Vector3i) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}

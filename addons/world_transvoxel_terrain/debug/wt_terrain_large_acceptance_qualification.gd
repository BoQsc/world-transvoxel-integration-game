@tool
extends "res://addons/world_transvoxel_terrain/debug/wt_terrain_large_acceptance_runtime.gd"

const EditOperation := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd")
const EditBatch := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd")
const LodAudit := preload("res://addons/world_transvoxel_terrain/debug/wt_terrain_lod_audit.gd")


func get_terrain_world() -> Node:
	return terrain_world


func set_automatic_viewer_tracking(enabled: bool) -> void:
	_runtime_follow_camera = enabled
	track_toggle.button_pressed = enabled


func get_acceptance_profile() -> Dictionary:
	return {
		"schema": "world_transvoxel_terrain.tqp57_large_acceptance_profile.v1",
		"volume_cells": [WORLD_CELLS.x, WORLD_CELLS.y, WORLD_CELLS.z],
		"volume_chunks": [WORLD_CHUNKS.x, WORLD_CHUNKS.y, WORLD_CHUNKS.z],
		"vertical_chunk_origin": VERTICAL_ORIGIN_CHUNKS,
		"source_revision": SOURCE_REVISION,
		"preset": "rolling_hills_cave",
		"viewer_radius_chunks": 2,
		"collision_radius_chunks": 1,
		"maximum_lod": 2,
		"active_chunk_capacity": 2048,
		"authority": "world-transvoxel",
		"fallback": false,
	}


func get_validation_snapshot() -> Dictionary:
	_refresh_metrics()
	return {
		"status": _readiness_status(),
		"profile": get_acceptance_profile(),
		"world_state": terrain_world.call("get_world_state_name") if terrain_world != null else "missing",
		"world_revision": terrain_world.call("get_world_revision") if terrain_world != null else 0,
		"catalog_page_count": terrain_world.call("get_world_page_count") if _world_started else 0,
		"viewer_position": Support.vector_summary(_viewer_position),
		"metrics": _last_metrics.duplicate(true),
		"lod_audit": _last_audit.duplicate(true),
	}


func collect_lod_audit(
	topology_center: Vector3 = Vector3.ZERO,
	topology_radius: float = 0.0,
	topology_at_lod_seam: bool = false
) -> Dictionary:
	_last_audit = LodAudit.collect(terrain_world, topology_center, topology_radius, topology_at_lod_seam)
	return _last_audit.duplicate(true)


func wait_until_ready(maximum_frames: int = 1800) -> Dictionary:
	var blocked_stall_frames := 0
	var blocked_signature := ""
	for frame in range(maximum_frames):
		_refresh_metrics()
		if _readiness_status() == "READY":
			return {"status": "PASS", "frames": frame, "snapshot": get_validation_snapshot()}
		var active := int(_last_metrics.get("non_retiring_chunk_records", 0))
		var ready := int(_last_metrics.get("non_retiring_fully_ready_chunk_records", 0))
		if active > 0 and ready < active and _work_queues_are_empty():
			var signature := "%d:%d:%d:%d" % [active, ready, int(_last_metrics.get("pending_chunk_replacements", 0)), int(_last_metrics.get("pending_chunk_retirements", 0))]
			if signature == blocked_signature: blocked_stall_frames += 1
			else:
				blocked_signature = signature
				blocked_stall_frames = 1
			if blocked_stall_frames == 1:
				print("TQP57_LARGE_NO_ACTIVE_WORK states=%s" % JSON.stringify(get_unready_chunk_states()))
			if blocked_stall_frames >= 60:
				return {"status": "FAIL", "error": "backend stopped progressing with required chunks not ready", "frames": frame, "stall_signature": signature, "unready_states": get_unready_chunk_states(), "snapshot": get_validation_snapshot()}
		else:
			blocked_stall_frames = 0
			blocked_signature = ""
		if status_label.text.begins_with("FAIL"): break
		if frame > 0 and frame % 120 == 0:
			print("TQP57_LARGE_WAIT frame=%d active=%d ready=%d jobs=%d storage=%d render=%d collision=%d replacements=%d retirements=%d" % [frame, active, ready, int(_last_metrics.get("scheduler_queued_jobs", 0)), int(_last_metrics.get("storage_queued_requests", 0)), int(_last_metrics.get("queued_render", 0)), int(_last_metrics.get("total_collision_backlog", 0)), int(_last_metrics.get("pending_chunk_replacements", 0)), int(_last_metrics.get("pending_chunk_retirements", 0))])
		await get_tree().process_frame
	return {"status": "FAIL", "frames": maximum_frames, "snapshot": get_validation_snapshot()}


func get_unready_chunk_states(limit: int = 16) -> Array[Dictionary]:
	var summaries: Array[Dictionary] = []
	for value in terrain_world.call("query_active_chunk_states"):
		var state := value as RefCounted
		if state == null or not bool(state.call("is_present")): continue
		var generation := int(state.call("get_generation"))
		var visual_required := bool(state.call("is_visual_required"))
		var visual_ready := bool(state.call("is_visual_ready"))
		var collision_required := bool(state.call("is_collision_required"))
		var collision_ready := bool(state.call("is_collision_ready"))
		var render_generation := int(state.call("get_render_generation"))
		var collision_generation := int(state.call("get_collision_generation"))
		var visual_valid := not visual_required or (visual_ready and render_generation in [0, generation] and int(state.call("get_staged_render_generation")) == 0)
		var collision_valid := not collision_required or (collision_ready and collision_generation in [0, generation] and int(state.call("get_staged_collision_generation")) == 0)
		if visual_valid and collision_valid: continue
		summaries.append({
			"coordinate": state.call("get_chunk_coordinate"), "lod": state.call("get_lod"),
			"generation": generation, "visual_required": visual_required,
			"visual_ready": visual_ready, "render_generation": render_generation,
			"staged_render_generation": state.call("get_staged_render_generation"),
			"collision_required": collision_required, "collision_ready": collision_ready,
			"collision_generation": collision_generation,
			"staged_collision_generation": state.call("get_staged_collision_generation"),
		})
		if summaries.size() >= limit: break
	return summaries


func publish_view(position: Vector3, force: bool = true) -> bool:
	return _request_viewer(_clamp_viewer_position(position), force)


func move_viewer_and_wait(position: Vector3, maximum_frames: int = 1800) -> Dictionary:
	var before := terrain_world.call("get_runtime_metrics") as Dictionary
	var target := _clamp_viewer_position(position)
	if not _request_viewer(target, true):
		return {"status": "FAIL", "error": terrain_world.call("get_last_error")}
	if not Engine.is_editor_hint(): _focus_camera(target)
	for _frame in range(maximum_frames):
		var metrics := terrain_world.call("get_runtime_metrics") as Dictionary
		if int(metrics.get("viewer_updates", 0)) > int(before.get("viewer_updates", 0)) and int(metrics.get("collision_viewer_updates", 0)) > int(before.get("collision_viewer_updates", 0)): break
		await get_tree().process_frame
	return await wait_until_ready(maximum_frames)


func submit_edit_and_wait(kind: StringName, center: Vector3, maximum_frames: int = 1800) -> Dictionary:
	if not _world_started: return {"status": "FAIL", "error": "world is not running"}
	var operation = EditOperation.new()
	operation.mode = EditOperation.Mode.CONSTRUCT if kind == &"construct" else EditOperation.Mode.CARVE
	operation.brush_shape = EditOperation.BrushShape.SPHERE
	operation.center = center
	operation.radius = 5.0
	operation.smooth_radius = 1.0
	operation.material_id = 4
	operation.density_value = 1.0
	operation.command_id = int(terrain_world.call("get_world_revision")) + 1
	var batch = EditBatch.new()
	batch.batch_id = operation.command_id
	batch.add_operation(operation)
	var expected_revision := int(terrain_world.call("get_world_revision")) + 1
	var started := Time.get_ticks_usec()
	if not bool(terrain_world.call("submit_edit_batch", batch, 5700)):
		return {"status": "FAIL", "error": terrain_world.call("get_last_error")}
	for _frame in range(maximum_frames):
		if int(terrain_world.call("get_world_revision")) >= expected_revision:
			var settled := await wait_until_ready(maximum_frames)
			return {"status": settled.get("status", "FAIL"), "kind": str(kind), "center": Support.vector_summary(center), "world_revision": terrain_world.call("get_world_revision"), "latency_usec": Time.get_ticks_usec() - started, "settlement": settled}
		await get_tree().process_frame
	return {"status": "FAIL", "error": "edit commit timed out"}


func focus_world_overview() -> void:
	_runtime_follow_camera = false
	track_toggle.button_pressed = false
	var target := Vector3(WORLD_CELLS.x * 0.5, 0.0, WORLD_CELLS.z * 0.5)
	camera.position = target + Vector3(0.0, 2200.0, 900.0)
	camera.look_at(target, Vector3.UP)


func shutdown_for_validation() -> Dictionary:
	return await _stop_preview(true)


func restart_preserving_storage(maximum_frames: int = 1800) -> Dictionary:
	var target := _viewer_position
	var stopped := await _stop_preview(false)
	if str(stopped.get("status", "")) != "PASS": return stopped
	_starting = true
	status_label.text = "RESTARTING"
	if not bool(terrain_world.call("start_world")):
		_fail_preview("preserving restart rejected: %s" % terrain_world.call("get_last_error"))
		return {"status": "FAIL", "error": terrain_world.call("get_last_error")}
	for _frame in range(maximum_frames):
		if str(terrain_world.call("get_world_state_name")) == "running":
			_world_started = true; break
		await get_tree().process_frame
	if not _world_started or not _request_viewer(target, true):
		_fail_preview("preserving restart did not restore the viewer")
		return {"status": "FAIL", "error": "restart viewer restoration failed"}
	var settlement := await wait_until_ready(maximum_frames)
	_starting = false
	material_applicator.call("apply_materials_now")
	return settlement

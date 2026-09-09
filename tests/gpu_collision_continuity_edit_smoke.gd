extends "res://tests/gpu_resident_multichunk_relocation_smoke.gd"

const EditOperation := preload(
	"res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd"
)
const EditBatch := preload(
	"res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd"
)

const SUPPORT_XZ := Vector2(2.0, 2.0)
const EDIT_XZ := Vector2(5.0, 5.0)
const SECOND_EDIT_XZ := Vector2(9.0, 5.0)


func _run() -> void:
	_setup_viewport()
	_world = TerrainWorld.new()
	_world.terrain_profile = _terrain_profile()
	_world.runtime_profile = _runtime_profile()
	_world.generation_profile = _generation_profile()
	_world.storage_profile = _storage_profile()
	_world.runtime_gpu_resident_render_candidate_enabled = true
	_world.runtime_gpu_meshing_shadow_capacity = 3
	_world.runtime_gpu_resident_chunk_capacity = 12
	root.add_child(_world)
	if not _world.start_backend_world() or not await _wait_for_state("running"):
		_fail("collision continuity world did not start")
		return
	if not _world.update_viewer(1, 1, Vector3(8, 8, 8), 1, 0) \
			or not _world.update_collision_viewer(2, 1, Vector3(8, 8, 8), 0) \
			or not await _wait_for_resident_state(2, 0):
		_fail("collision continuity fixture did not settle")
		return
	for _frame in range(3):
		await physics_frame
	var support := _vertical_hit(SUPPORT_XZ)
	var edit_hit := _vertical_hit(EDIT_XZ)
	if support.is_empty() or edit_hit.is_empty():
		_fail("fixture did not expose two standing surfaces")
		return
	if not _world.begin_cpu_causal_trace():
		_fail("collision continuity causal trace did not start")
		return
	var trace_started_ticks_usec := Time.get_ticks_usec()
	var operation := EditOperation.new()
	operation.mode = EditOperation.Mode.CARVE
	operation.brush_shape = EditOperation.BrushShape.SPHERE
	operation.center = Vector3(EDIT_XZ.x, float(edit_hit.position.y) - 0.5, EDIT_XZ.y)
	operation.radius = 1.5
	operation.density_value = 1.0
	var batch := EditBatch.new()
	batch.add_operation(operation)
	var submitted_ticks_usec := Time.get_ticks_usec()
	if not _world.submit_edit_batch(batch, 6751):
		_fail("collision continuity carve was rejected")
		return
	var committed := false
	var replacement_ready := false
	for frame in range(600):
		await physics_frame
		if _vertical_hit(SUPPORT_XZ).is_empty():
			_fail("unmodified player support disappeared at frame %d" % frame)
			return
		if int(_world.get_runtime_metrics().get("collision_resources", 0)) < 1:
			_fail("collision resource set became empty at frame %d" % frame)
			return
		committed = committed or _world.get_world_revision() == 1
		var state: RefCounted = _world.query_chunk_state(Vector3i(0, 0, 0), 0)
		if state != null and bool(state.call("is_collision_ready")) \
				and int(state.call("get_collision_generation")) \
				== int(state.call("get_generation")) \
				and int(state.call("get_staged_collision_generation")) == 0:
			replacement_ready = committed
		if committed and replacement_ready:
			break
	if not committed or not replacement_ready:
		_fail("edited collision generation did not become authoritative")
		return
	# The runtime record becomes query-visible inside the sink call. Poll the
	# still-open trace until the frontend has recorded completion of that call.
	var trace: Dictionary = {}
	for _trace_frame in range(10):
		trace = _world.get_cpu_causal_trace_events(0, 65536)
		var sink_recorded := false
		for event_variant in trace.get("events", []):
			var event: Dictionary = event_variant
			if str(event.get("kind", "")) == "collision_sink_applied" \
					and int(event.get("cause_id", 0)) == 1:
				sink_recorded = true
				break
		if sink_recorded:
			break
		await process_frame
	var edited_after := _vertical_hit(EDIT_XZ)
	var opened := edited_after.is_empty() or \
		float(edited_after.position.y) <= float(edit_hit.position.y) - 0.25
	for settle_frame in range(30):
		if opened:
			break
		await physics_frame
		if _vertical_hit(SUPPORT_XZ).is_empty():
			_fail("unmodified player support disappeared while collision settled at frame %d" % settle_frame)
			return
		edited_after = _vertical_hit(EDIT_XZ)
		opened = edited_after.is_empty() or \
			float(edited_after.position.y) <= float(edit_hit.position.y) - 0.25
	if not opened:
		_fail("mined collision surface did not open: before=%.3f after=%.3f" % [
			float(edit_hit.position.y), float(edited_after.position.y),
		])
		return
	var second_hit := _vertical_hit(SECOND_EDIT_XZ)
	if second_hit.is_empty():
		_fail("second edit surface was unavailable")
		return
	var second_operation := EditOperation.new()
	second_operation.mode = EditOperation.Mode.CARVE
	second_operation.brush_shape = EditOperation.BrushShape.SPHERE
	second_operation.center = Vector3(
		SECOND_EDIT_XZ.x, float(second_hit.position.y) - 0.5,
		SECOND_EDIT_XZ.y
	)
	second_operation.radius = 1.5
	second_operation.density_value = 1.0
	var second_batch := EditBatch.new()
	second_batch.add_operation(second_operation)
	if not _world.submit_edit_batch(second_batch, 6752):
		_fail("second collision continuity carve was rejected")
		return
	var second_replacement_ready := false
	for frame in range(600):
		await physics_frame
		if _vertical_hit(SUPPORT_XZ).is_empty():
			_fail("support disappeared during revision two at frame %d" % frame)
			return
		if int(_world.get_runtime_metrics().get("collision_resources", 0)) < 1:
			_fail("collision resources emptied during revision two at frame %d" % frame)
			return
		var second_state: RefCounted = _world.query_chunk_state(
			Vector3i(0, 0, 0), 0
		)
		if _world.get_world_revision() == 2 and second_state != null \
				and bool(second_state.call("is_collision_ready")) \
				and int(second_state.call("get_world_revision")) == 2 \
				and int(second_state.call("get_collision_generation")) \
				== int(second_state.call("get_generation")) \
				and int(second_state.call("get_staged_collision_generation")) == 0:
			second_replacement_ready = true
			break
	if not second_replacement_ready:
		_fail("second edited collision generation did not become authoritative")
		return
	var second_edited_after := _vertical_hit(SECOND_EDIT_XZ)
	var second_opened := second_edited_after.is_empty() or \
			float(second_edited_after.position.y) \
			<= float(second_hit.position.y) - 0.25
	if not second_opened:
		_fail("second mined collision surface did not open")
		return
	_world.end_cpu_causal_trace()
	var dirty_block_mask := 0
	var collision_sink_us := -1
	var collision_prepared_us := -1
	var mesh_started_us := -1
	var mesh_finished_us := -1
	var collision_events: Array[String] = []
	for event_variant in trace.get("events", []):
		var event: Dictionary = event_variant
		if str(event.get("kind", "")) in [
			"collision_payload_prepared", "collision_sink_applied"
		]:
			collision_events.append("%s:cause=%d:key=%d,%d,%d,L%d:status=%d" % [
				str(event.get("kind", "")), int(event.get("cause_id", 0)),
				int(event.get("chunk_x", -1)), int(event.get("chunk_y", -1)),
				int(event.get("chunk_z", -1)), int(event.get("chunk_lod", -1)),
				int(event.get("status", 0)),
			])
		if int(event.get("cause_id", 0)) != 1 \
				or int(event.get("chunk_lod", -1)) != 0 \
				or int(event.get("chunk_x", -1)) != 0 \
				or int(event.get("chunk_y", -1)) != 0 \
				or int(event.get("chunk_z", -1)) != 0:
			continue
		if str(event.get("kind", "")) == "collision_payload_prepared":
			dirty_block_mask = int(event.get("status", 0))
			collision_prepared_us = trace_started_ticks_usec \
				+ int(event.get("elapsed_ns", 0)) / 1000 - submitted_ticks_usec
		elif str(event.get("kind", "")) == "collision_sink_applied":
			collision_sink_us = trace_started_ticks_usec \
				+ int(event.get("elapsed_ns", 0)) / 1000 - submitted_ticks_usec
		elif str(event.get("kind", "")) == "mesh_started":
			mesh_started_us = trace_started_ticks_usec \
				+ int(event.get("elapsed_ns", 0)) / 1000 - submitted_ticks_usec
		elif str(event.get("kind", "")) == "mesh_finished":
			mesh_finished_us = trace_started_ticks_usec \
				+ int(event.get("elapsed_ns", 0)) / 1000 - submitted_ticks_usec
	if dirty_block_mask <= 0 or dirty_block_mask >= 255:
		_fail("edit did not exercise a partial collision patch: mask=%d events=%s" % [
			dirty_block_mask, str(collision_events),
		])
		return
	if collision_sink_us < 0:
		_fail("collision sink application was absent from causal trace: %s" % [
			str(collision_events),
		])
		return
	print(("GPU_COLLISION_CONTINUITY_EDIT_SMOKE_PASS support_frames=1200 " \
		+ "revisions=2 " \
		+ "support_y=%.3f edit_y=%.3f collision_resources=%d " \
		+ "dirty_block_mask=%d mesh_started_us=%d mesh_finished_us=%d " \
		+ "collision_prepared_us=%d collision_sink_us=%d") % [
		float(support.position.y), float(edit_hit.position.y),
		int(_world.get_runtime_metrics().get("collision_resources", 0)),
		dirty_block_mask, mesh_started_us, mesh_finished_us,
		collision_prepared_us, collision_sink_us,
	])
	_world.stop_backend_world()
	await _wait_for_state("stopped")
	quit(0)


func _vertical_hit(xz: Vector2) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(xz.x, 48.0, xz.y), Vector3(xz.x, -32.0, xz.y)
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return _world.get_world_3d().direct_space_state.intersect_ray(query)


func _fail(message: String) -> void:
	push_error("GPU_COLLISION_CONTINUITY_EDIT_SMOKE_FAIL: " + message)
	quit(1)

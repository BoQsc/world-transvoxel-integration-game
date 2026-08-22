extends SceneTree

const MARKER := "WT_TERRAIN_WATERFALL_HUD_PASS"
const TerrainWaterfallHud := preload("res://scripts/wt_terrain_waterfall_hud.gd")


class FakeTrace extends RefCounted:
	func is_active() -> bool:
		return true

	func get_live_waterfall_snapshot(
		_maximum_native_events: int,
		_maximum_downstream_events: int
	) -> Dictionary:
		return {
			"active": true,
			"elapsed_us": 2500000,
			"last_frame_us": 18000,
			"last_live_capture_us": 120,
			"phase": "human_edit",
			"movement": {"mode": "fly", "accepted": true},
			"pipeline": {
				"metrics": {
					"viewer_updates": 12,
					"scheduler_queued_jobs": 3,
					"mesh_worker_count": 2,
					"mesh_worker_active_jobs": 2,
					"mesh_worker_queued_jobs": 2,
					"mesh_worker_completed_jobs": 7,
					"mesh_worker_queue_wait_ns_last": 2500000,
					"mesh_worker_queue_wait_ns_maximum": 5000000,
					"storage_active_requests": 1,
					"page_awaiting_mesh_records": 2,
					"queued_render": 1,
					"pending_chunk_replacements": 4,
					"blocked_pending_chunk_replacements": 4,
				},
				"target": {
					"chunk": {"x": 4, "y": 2, "z": 8},
					"lod": 0,
					"present": true,
					"is_visual_ready": false,
					"is_collision_ready": false,
				},
			},
			"recent_native_events": [{
				"elapsed_ns": 2400000000,
				"thread_role": "runtime",
				"kind": "mesh_started",
				"has_chunk": true,
				"chunk_x": 4,
				"chunk_y": 2,
				"chunk_z": 8,
				"chunk_lod": 0,
			}],
		}


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var hud := TerrainWaterfallHud.new()
	root.add_child(hud)
	hud.call("attach_trace", FakeTrace.new(), "res://trace.json")
	await process_frame
	if not hud.visible or not hud.is_processing():
		_fail("HUD did not activate with the trace")
		return
	if hud.tooltip_text != "res://trace.json":
		_fail("HUD did not retain the trace destination")
		return
	var text := _collect_label_text(hud)
	for expected in [
		"TERRAIN PIPELINE WATERFALL", "workers 2", "mesh_started", "waiting on storage",
	]:
		if not text.contains(expected):
			_fail("HUD is missing expected live data: %s" % expected)
			return
	hud.call("detach_trace")
	if hud.visible or hud.is_processing():
		_fail("HUD did not become inert when disabled")
		return
	print("%s optional=1 live_snapshot=1 disabled_inert=1" % MARKER)
	quit(0)


func _collect_label_text(node: Node) -> String:
	var output := PackedStringArray()
	if node is Label:
		output.append((node as Label).text)
	for child in node.get_children():
		output.append(_collect_label_text(child))
	return "\n".join(output)


func _fail(message: String) -> void:
	push_error("WT_TERRAIN_WATERFALL_HUD_FAIL: " + message)
	quit(1)

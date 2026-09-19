extends PanelContainer

const REFRESH_INTERVAL_SECONDS := 0.25
const MAX_RECENT_EVENTS := 8

var _trace: RefCounted
var _output_path := ""
var _refresh_elapsed := 0.0
var _title_label: Label
var _frame_label: Label
var _queues_label: Label
var _target_label: Label
var _blocker_label: Label
var _events_label: Label


func _ready() -> void:
	_build_ui()
	visible = false
	set_process(false)


func attach_trace(trace: RefCounted, output_path: String) -> void:
	_trace = trace
	_output_path = output_path
	_refresh_elapsed = REFRESH_INTERVAL_SECONDS
	visible = true
	set_process(true)
	refresh_now()


func detach_trace() -> void:
	_trace = null
	_output_path = ""
	visible = false
	set_process(false)


func refresh_now() -> void:
	if _trace == null or not bool(_trace.call("is_active")):
		detach_trace()
		return
	var snapshot_value = _trace.call(
		"get_live_waterfall_snapshot", MAX_RECENT_EVENTS, 4
	)
	if not snapshot_value is Dictionary:
		return
	_apply_snapshot(snapshot_value)


func _process(delta: float) -> void:
	_refresh_elapsed += delta
	if _refresh_elapsed < REFRESH_INTERVAL_SECONDS:
		return
	_refresh_elapsed = 0.0
	refresh_now()


func _build_ui() -> void:
	name = "TerrainWaterfallHud"
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -470.0
	offset_top = 76.0
	offset_right = -12.0
	offset_bottom = 478.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.018, 0.035, 0.035, 0.94)
	panel.border_color = Color(0.20, 0.68, 0.64, 0.85)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(6)
	panel.content_margin_left = 12.0
	panel.content_margin_top = 10.0
	panel.content_margin_right = 12.0
	panel.content_margin_bottom = 10.0
	add_theme_stylebox_override("panel", panel)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 5)
	add_child(rows)
	_title_label = _make_label(16, Color(0.55, 1.0, 0.88))
	_frame_label = _make_label(13, Color(0.92, 0.96, 0.94))
	_queues_label = _make_label(12, Color(0.76, 0.84, 0.81))
	_target_label = _make_label(12, Color(0.76, 0.84, 0.81))
	_blocker_label = _make_label(13, Color(1.0, 0.85, 0.42))
	_events_label = _make_label(11, Color(0.69, 0.78, 0.75))
	for label in [
		_title_label, _frame_label, _queues_label, _target_label,
		_blocker_label, _events_label,
	]:
		rows.add_child(label)


func _make_label(font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.9))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _apply_snapshot(snapshot: Dictionary) -> void:
	var elapsed_ms := float(snapshot.get("elapsed_us", 0)) / 1000.0
	var frame_ms := float(snapshot.get("last_frame_us", 0)) / 1000.0
	var observer_ms := float(snapshot.get("last_live_capture_us", 0)) / 1000.0
	var movement: Dictionary = snapshot.get("movement", {})
	var movement_mode := str(movement.get("mode", "idle"))
	var accepted_text := "ready"
	if movement.has("accepted") and not bool(movement.get("accepted", true)):
		accepted_text = "blocked"
	_title_label.text = "TERRAIN PIPELINE WATERFALL   %.1fs" % (elapsed_ms / 1000.0)
	_frame_label.text = "frame %6.2f ms | observer %5.2f ms | %s %s | phase %s" % [
		frame_ms, observer_ms, movement_mode, accepted_text,
		str(snapshot.get("phase", "unassigned")),
	]

	var pipeline: Dictionary = snapshot.get("pipeline", {})
	var metrics: Dictionary = pipeline.get("metrics", {})
	_queues_label.text = (
		"VIEW  updates %d  jobs %d  completions %d  plans %d open / %d latest\n" +
		"MESH  workers %d  active %d  waiting %d  done %d  wait %.2f / %.2f ms\n" +
		"STORE queued %d  active %d  done %d  last %.2f ms\n" +
		"PAGES load %d  sample %d  mesh %d  ready %d\n" +
		"APPLY render %d  collision %d  deferred %d  backlog %d\n" +
		"PRIOR support %d  focus %d  matched %d  missing %d  changes %d\n" +
		"LOCAL plans %d  added %d  reject %d  worst %.3f ms\n" +
		"WARM  request %d  admit %d  join %d  hit %d  done %d  reject %d\n" +
		"VIS   replace %d  blocked %d  ready %d  retire %d  render-retire %d\n" +
		"FIRST %s"
	) % [
		int(metrics.get("viewer_updates", 0)),
		int(metrics.get("scheduler_queued_jobs", 0)),
		int(metrics.get("scheduler_queued_completions", 0)),
		int(metrics.get("open_viewer_plan_publications", 0)),
		int(metrics.get("latest_completed_viewer_plan_revision", 0)),
		int(metrics.get("mesh_worker_count", 0)),
		int(metrics.get("mesh_worker_active_jobs", 0)),
		int(metrics.get("mesh_worker_queued_jobs", 0)),
		int(metrics.get("mesh_worker_completed_jobs", 0)),
		float(metrics.get("mesh_worker_queue_wait_ns_last", 0)) / 1000000.0,
		float(metrics.get("mesh_worker_queue_wait_ns_maximum", 0)) / 1000000.0,
		int(metrics.get("storage_queued_requests", 0)),
		int(metrics.get("storage_active_requests", 0)),
		int(metrics.get("storage_completed_requests", 0)),
		float(metrics.get("storage_load_time_ns_last", 0)) / 1000000.0,
		int(metrics.get("page_loading_records", 0)),
		int(metrics.get("page_sample_ready_records", 0)),
		int(metrics.get("page_awaiting_mesh_records", 0)),
		int(metrics.get("page_ready_records", 0)),
		int(metrics.get("queued_render", 0)),
		int(metrics.get("queued_collision", 0)),
		int(metrics.get("deferred_collision", 0)),
		int(metrics.get("total_collision_backlog", 0)),
		int(metrics.get("foreground_priority_support_keys", 0)),
		int(metrics.get("foreground_priority_focus_keys", 0)),
		int(metrics.get("foreground_priority_matched_keys", 0)),
		int(metrics.get("foreground_priority_missing_keys", 0)),
		int(metrics.get("foreground_priority_changed_priorities", 0)),
		int(metrics.get("interaction_local_plan_refreshes", 0)),
		int(metrics.get("interaction_local_plan_added_chunks", 0)),
		int(metrics.get("interaction_local_plan_rejections", 0)),
		float(metrics.get("interaction_local_plan_ns_maximum", 0)) / 1000000.0,
		int(metrics.get("interaction_warm_requests", 0)),
		int(metrics.get("interaction_warm_admissions", 0)),
		int(metrics.get("interaction_warm_coalesced", 0)),
		int(metrics.get("interaction_warm_cache_hits", 0)),
		int(metrics.get("interaction_warm_completions", 0)),
		int(metrics.get("interaction_warm_rejections", 0)),
		int(metrics.get("pending_chunk_replacements", 0)),
		int(metrics.get("blocked_pending_chunk_replacements", 0)),
		int(metrics.get("ready_staged_chunk_replacements", 0)),
		int(metrics.get("pending_chunk_retirements", 0)),
		int(metrics.get("pending_render_retirements", 0)),
		_first_blocker_text(metrics),
	]

	var target: Dictionary = pipeline.get("target", {})
	if target.is_empty():
		_target_label.text = "EDIT  no target bound"
	else:
		var chunk: Dictionary = target.get("chunk", {})
		_target_label.text = "EDIT  chunk %d,%d,%d L%d | present %s | visual %s | collision %s" % [
			int(chunk.get("x", 0)), int(chunk.get("y", 0)), int(chunk.get("z", 0)),
			int(target.get("lod", 0)), _yes_no(bool(target.get("present", false))),
			_yes_no(bool(target.get("is_visual_ready", false))),
			_yes_no(bool(target.get("is_collision_ready", false))),
		]

	var blocker := _classify_blocker(frame_ms, movement, metrics, target)
	_blocker_label.text = "BLOCKER  " + blocker
	_blocker_label.add_theme_color_override(
		"font_color",
		Color(0.54, 1.0, 0.72) if blocker == "none observed" else Color(1.0, 0.72, 0.32)
	)
	_events_label.text = _format_events(snapshot.get("recent_native_events", []))
	tooltip_text = _output_path


func _classify_blocker(
	frame_ms: float,
	movement: Dictionary,
	metrics: Dictionary,
	target: Dictionary
) -> String:
	if movement.has("accepted") and not bool(movement.get("accepted", true)):
		if int(metrics.get("collision_required_not_ready_chunk_records", 0)) > 0:
			return "movement collision-readiness gate"
		return "movement rejected; no sampled collision cause"
	if not target.is_empty() and bool(target.get("present", false)):
		if not bool(target.get("is_visual_ready", false)):
			if int(metrics.get("storage_active_requests", 0)) > 0 or \
					int(metrics.get("storage_queued_requests", 0)) > 0:
				return "edit target waiting on storage/generation"
			if int(metrics.get("mesh_worker_queued_jobs", 0)) > 0:
				return "edit target waiting in mesh worker queue"
			if int(metrics.get("scheduler_queued_jobs", 0)) > 0:
				return "edit target waiting on sample/mesh scheduler"
			if int(metrics.get("queued_render", 0)) > 0:
				return "edit target waiting on render application"
			return "edit target not visually ready"
		if not bool(target.get("is_collision_ready", false)):
			return "edit target waiting on collision application"
	if int(metrics.get("blocked_pending_chunk_replacements", 0)) > 0:
		return "visibility staging waits on replacement set"
	if frame_ms >= 33.3:
		return "frame hitch; inspect retained event window"
	return "none observed"


func _first_blocker_text(metrics: Dictionary) -> String:
	if int(metrics.get("blocked_pending_chunk_replacements", 0)) <= 0:
		return "none"
	var reason := "collision"
	if bool(metrics.get("first_blocked_replacement_missing", false)):
		reason = "record missing"
	elif bool(metrics.get("first_blocked_replacement_visual_required", false)) and \
			not bool(metrics.get("first_blocked_replacement_visual_ready", false)):
		reason = "visual"
	elif not bool(metrics.get("first_blocked_replacement_collision_required", false)):
		reason = "application"
	return "%d,%d,%d L%d gen %d waiting %s" % [
		int(metrics.get("first_blocked_replacement_key_x", 0)),
		int(metrics.get("first_blocked_replacement_key_y", 0)),
		int(metrics.get("first_blocked_replacement_key_z", 0)),
		int(metrics.get("first_blocked_replacement_key_lod", 0)),
		int(metrics.get("first_blocked_replacement_generation", 0)),
		reason,
	]


func _format_events(events_value) -> String:
	if not events_value is Array or events_value.is_empty():
		return "RECENT  waiting for native events"
	var lines := PackedStringArray(["RECENT  ms       thread     stage                 chunk"])
	for event_value in events_value:
		if not event_value is Dictionary:
			continue
		var event: Dictionary = event_value
		var chunk_text := "-"
		if bool(event.get("has_chunk", false)):
			chunk_text = "%d,%d,%d L%d" % [
				int(event.get("chunk_x", 0)), int(event.get("chunk_y", 0)),
				int(event.get("chunk_z", 0)), int(event.get("chunk_lod", 0)),
			]
		lines.append("        %8.1f %-10s %-21s %s" % [
			float(event.get("elapsed_ns", 0)) / 1000000.0,
			str(event.get("thread_role", "")),
			_short_kind(str(event.get("kind", ""))),
			chunk_text,
		])
	return "\n".join(lines)


func _short_kind(kind: String) -> String:
	if kind == "foreground_priority_lease_applied":
		return "priority_lease"
	if kind == "foreground_priority_changed":
		return "priority_changed"
	return kind.replace("completion_consumed", "consumed").replace(
		"visibility_", "vis_"
	).replace("frontend_publication_", "frontend_")


func _yes_no(value: bool) -> String:
	return "yes" if value else "no"

extends Node3D

const Pipeline := preload("res://scripts/wt_playtest_pipeline_snapshot.gd")
const CHUNK_EXTENT := 16.0
const VISUAL_REFRESH_SECONDS := 0.2
const CHUNK_VISUAL_RADIUS := 160.0
const COLLISION_VISUAL_RADIUS := 96.0
const MAX_VISUALIZED_RECORDS := 768
const BOX_EDGES := [
	[0, 1], [1, 2], [2, 3], [3, 0],
	[4, 5], [5, 6], [6, 7], [7, 4],
	[0, 4], [1, 5], [2, 6], [3, 7],
]

var _game_world: Node
var _terrain_world: Node
var _player: CharacterBody3D
var _crosshair: Control
var _menu: Control
var _collision_toggle: CheckButton
var _chunk_toggle: CheckButton
var _pipeline_toggle: CheckButton
var _performance_toggle: CheckButton
var _performance_label: Label
var _collision_wait_label: Label
var _legend_label: Label
var _collision_lines: MeshInstance3D
var _chunk_lines: MeshInstance3D
var _pipeline_lines: MeshInstance3D
var _collision_wireframes: Dictionary = {}
var _gpu_states: Array = []
var _history: Array = []
var _draw_intervals: Array[float] = []
var _last_draw_us := 0
var _saved_label: Label
var _refresh_elapsed := 0.0
var _last_snapshot := {}


func build_ui(canvas: CanvasLayer, crosshair: Control = null) -> void:
	_crosshair = crosshair
	_build_escape_menu(canvas)
	_build_diagnostic_labels(canvas)
	_collision_lines = _make_line_instance("CollisionResidencyLines")
	_chunk_lines = _make_line_instance("ChunkBoundaryLines")
	_pipeline_lines = _make_line_instance("GpuPublicationLines")
	add_child(_collision_lines)
	add_child(_chunk_lines)
	add_child(_pipeline_lines)
	_collision_lines.visible = false
	_chunk_lines.visible = false
	_pipeline_lines.visible = false


func attach_runtime(game_world: Node, player: CharacterBody3D) -> void:
	_game_world = game_world
	_player = player
	_terrain_world = _game_world.call("get_terrain_world") \
		if _game_world != null and _game_world.has_method("get_terrain_world") \
		else null


func toggle_menu() -> void:
	set_menu_open(_menu == null or not _menu.visible)


func set_menu_open(open: bool) -> void:
	if _menu == null:
		return
	_menu.visible = open
	if _performance_label != null:
		_performance_label.visible = not open and _performance_toggle.button_pressed
	if _legend_label != null:
		_update_legend()
	if _crosshair != null:
		_crosshair.visible = not open
	if _player != null and _player.has_method("set_human_input_enabled"):
		_player.call("set_human_input_enabled", not open)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE \
			if open else Input.MOUSE_MODE_CAPTURED


func is_menu_open() -> bool:
	return _menu != null and _menu.visible


func get_diagnostic_snapshot() -> Dictionary:
	var snapshot := _last_snapshot.duplicate(true)
	snapshot["gpu_processing"] = _gpu_states.duplicate(true)
	snapshot["recent_samples"] = _history.duplicate(true)
	snapshot["enabled"] = _any_debug_enabled()
	snapshot["options"] = {
		"collision": _collision_toggle.button_pressed,
		"lod": _chunk_toggle.button_pressed,
		"gpu_pipeline": _pipeline_toggle.button_pressed,
		"hud": _performance_toggle.button_pressed,
	}
	return Pipeline.json_value(snapshot)


func _any_debug_enabled() -> bool:
	return (_collision_toggle != null and _collision_toggle.button_pressed) or \
		(_chunk_toggle != null and _chunk_toggle.button_pressed) or \
		(_pipeline_toggle != null and _pipeline_toggle.button_pressed) or \
		(_performance_toggle != null and _performance_toggle.button_pressed)


func _process(delta: float) -> void:
	_update_collision_wait_feedback()
	_refresh_elapsed += delta
	if _refresh_elapsed < VISUAL_REFRESH_SECONDS:
		return
	_refresh_elapsed = 0.0
	if _performance_toggle != null and _performance_toggle.button_pressed:
		_refresh_performance_hud()
	if (_collision_toggle != null and _collision_toggle.button_pressed) or \
			(_chunk_toggle != null and _chunk_toggle.button_pressed) or \
			(_pipeline_toggle != null and _pipeline_toggle.button_pressed):
		_refresh_world_visuals()


func _build_escape_menu(canvas: CanvasLayer) -> void:
	_menu = ColorRect.new()
	_menu.name = "EscapeDiagnosticsMenu"
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu.color = Color(0.015, 0.02, 0.02, 0.74)
	_menu.mouse_filter = Control.MOUSE_FILTER_STOP
	_menu.visible = false
	canvas.add_child(_menu)
	var panel := PanelContainer.new()
	panel.name = "DiagnosticsPanel"
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -190.0
	panel.offset_top = -240.0
	panel.offset_right = 190.0
	panel.offset_bottom = 240.0
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.035, 0.055, 0.055, 0.98)
	panel_style.border_color = Color(0.20, 0.52, 0.48, 1.0)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", panel_style)
	_menu.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	margin.add_child(content)
	var title := Label.new()
	title.text = "Playtest Diagnostics"
	title.add_theme_font_size_override("font_size", 22)
	content.add_child(title)
	content.add_child(HSeparator.new())
	_collision_toggle = CheckButton.new()
	_collision_toggle.name = "CollisionVisualizationToggle"
	_collision_toggle.text = "Collision visualization"
	_collision_toggle.toggled.connect(_set_collision_visualization)
	content.add_child(_collision_toggle)
	_chunk_toggle = CheckButton.new()
	_chunk_toggle.name = "ChunkBordersToggle"
	_chunk_toggle.text = "Chunk borders"
	_chunk_toggle.toggled.connect(_set_chunk_visualization)
	content.add_child(_chunk_toggle)
	_pipeline_toggle = CheckButton.new()
	_pipeline_toggle.name = "GpuPublicationToggle"
	_pipeline_toggle.text = "GPU publication stages"
	_pipeline_toggle.toggled.connect(_set_pipeline_visualization)
	content.add_child(_pipeline_toggle)
	_performance_toggle = CheckButton.new()
	_performance_toggle.name = "PerformanceHudToggle"
	_performance_toggle.text = "Performance + pipeline HUD"
	_performance_toggle.toggled.connect(_set_performance_hud)
	content.add_child(_performance_toggle)
	var save := Button.new()
	save.name = "SavePipelineSnapshot"
	save.text = "Save diagnostic snapshot"
	save.custom_minimum_size.y = 38.0
	save.pressed.connect(_save_snapshot)
	content.add_child(save)
	_saved_label = Label.new()
	_saved_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_saved_label.custom_minimum_size.x = 340.0
	_saved_label.add_theme_font_size_override("font_size", 12)
	content.add_child(_saved_label)
	content.add_spacer(false)
	var resume := Button.new()
	resume.name = "ResumeButton"
	resume.text = "Resume"
	resume.custom_minimum_size.y = 38.0
	resume.pressed.connect(set_menu_open.bind(false))
	content.add_child(resume)
	var quit := Button.new()
	quit.name = "ExitButton"
	quit.text = "Exit playtest"
	quit.custom_minimum_size.y = 38.0
	quit.pressed.connect(_quit_playtest)
	content.add_child(quit)


func _build_diagnostic_labels(canvas: CanvasLayer) -> void:
	_performance_label = Label.new()
	_performance_label.name = "PerformanceDiagnosticLabel"
	_performance_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_performance_label.offset_left = 12.0
	_performance_label.offset_top = 72.0
	_performance_label.offset_right = 550.0
	_performance_label.offset_bottom = 420.0
	_performance_label.add_theme_font_size_override("font_size", 14)
	_performance_label.add_theme_color_override("font_color", Color(0.86, 0.96, 0.92))
	_performance_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_performance_label.add_theme_constant_override("shadow_offset_x", 2)
	_performance_label.add_theme_constant_override("shadow_offset_y", 2)
	_performance_label.visible = false
	canvas.add_child(_performance_label)
	_collision_wait_label = Label.new()
	_collision_wait_label.name = "CollisionWaitLabel"
	_collision_wait_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_collision_wait_label.offset_left = -340.0
	_collision_wait_label.offset_top = -86.0
	_collision_wait_label.offset_right = 340.0
	_collision_wait_label.offset_bottom = -50.0
	_collision_wait_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_collision_wait_label.add_theme_font_size_override("font_size", 18)
	_collision_wait_label.add_theme_color_override("font_color", Color(1.0, 0.72, 0.20))
	_collision_wait_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_collision_wait_label.add_theme_constant_override("shadow_offset_x", 2)
	_collision_wait_label.add_theme_constant_override("shadow_offset_y", 2)
	_collision_wait_label.visible = false
	canvas.add_child(_collision_wait_label)
	_legend_label = Label.new()
	_legend_label.name = "WorldDiagnosticLegend"
	_legend_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_legend_label.offset_left = -700.0
	_legend_label.offset_top = -120.0
	_legend_label.offset_right = -12.0
	_legend_label.offset_bottom = -34.0
	_legend_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_legend_label.add_theme_font_size_override("font_size", 13)
	_legend_label.add_theme_color_override("font_color", Color(0.88, 0.92, 0.90))
	_legend_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_legend_label.visible = false
	canvas.add_child(_legend_label)


func _set_collision_visualization(enabled: bool) -> void:
	if _collision_lines != null:
		_collision_lines.visible = enabled
	if not enabled:
		_clear_collision_wireframes()
	_refresh_elapsed = VISUAL_REFRESH_SECONDS
	_update_legend()


func _set_chunk_visualization(enabled: bool) -> void:
	if _chunk_lines != null:
		_chunk_lines.visible = enabled
		if not enabled:
			_chunk_lines.mesh = null
			_last_snapshot["visualized_chunk_records"] = 0
	_refresh_elapsed = VISUAL_REFRESH_SECONDS
	_update_legend()


func _set_performance_hud(enabled: bool) -> void:
	if _performance_label != null:
		_performance_label.visible = enabled and not is_menu_open()
	if _terrain_world != null and _terrain_world.has_method("set_debug_gpu_stage_timing_enabled"):
		_terrain_world.call("set_debug_gpu_stage_timing_enabled", enabled)
	if enabled and not RenderingServer.frame_post_draw.is_connected(_record_draw_interval):
		RenderingServer.frame_post_draw.connect(_record_draw_interval)
	elif not enabled and RenderingServer.frame_post_draw.is_connected(_record_draw_interval):
		RenderingServer.frame_post_draw.disconnect(_record_draw_interval)
		_draw_intervals.clear()
		_last_draw_us = 0
	if enabled:
		_refresh_performance_hud()


func _set_pipeline_visualization(enabled: bool) -> void:
	_pipeline_lines.visible = enabled
	if not enabled:
		_pipeline_lines.mesh = null
		_last_snapshot["visualized_gpu_records"] = 0
	_refresh_elapsed = VISUAL_REFRESH_SECONDS
	_update_legend()


func _record_draw_interval() -> void:
	var now := Time.get_ticks_usec()
	if _last_draw_us != 0:
		_draw_intervals.append(float(now - _last_draw_us) / 1000.0)
		if _draw_intervals.size() > 128:
			_draw_intervals.pop_front()
	_last_draw_us = now


func _update_legend() -> void:
	if _legend_label == null:
		return
	var collision_visible := _collision_toggle != null and \
		_collision_toggle.button_pressed
	var chunks_visible := _chunk_toggle != null and _chunk_toggle.button_pressed
	var lines: Array[String] = []
	if collision_visible:
		lines.append("Collision: green live | cyan previous | purple staged | orange pending | gray no body")
	if chunks_visible:
		lines.append("LOD: cyan L0 | yellow L1 | orange L2 | magenta L3")
	if _pipeline_toggle != null and _pipeline_toggle.button_pressed:
		lines.append("GPU: blue extraction | yellow prepare | orange cohort wait")
		lines.append("purple activation queued | green active (includes empty) | red retiring")
	_legend_label.visible = not lines.is_empty() and not is_menu_open()
	_legend_label.text = "\n".join(lines)


func _update_collision_wait_feedback() -> void:
	if _collision_wait_label == null or _player == null or \
			not _player.has_method("get_streaming_collision_status"):
		return
	var status: Dictionary = _player.call("get_streaming_collision_status")
	var collision_pending := bool(status.get("collision_pending", false))
	_collision_wait_label.visible = collision_pending and not is_menu_open()
	if not collision_pending:
		return
	var readiness: Dictionary = status.get("readiness", {})
	var movement_note := "MOVEMENT AVAILABLE" if bool(
		status.get("movement_permitted", false)
	) else "MOVEMENT CONSTRAINED"
	_collision_wait_label.text = "TERRAIN COLLISION UPDATING  %.2f s  |  %d chunks  |  %s" % [
		float(status.get("wait_seconds", 0.0)),
		Array(readiness.get("not_ready_chunks", [])).size(),
		movement_note,
	]


func _refresh_performance_hud() -> void:
	if _performance_label == null:
		return
	var metrics := {}
	if _terrain_world != null and _terrain_world.has_method("get_runtime_metrics"):
		metrics = _terrain_world.call("get_runtime_metrics")
	var collision_status := {}
	if _player != null and _player.has_method("get_streaming_collision_status"):
		collision_status = _player.call("get_streaming_collision_status")
	var fps := float(Performance.get_monitor(Performance.TIME_FPS))
	var process_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
	var physics_ms := float(
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	) * 1000.0
	var draw_calls := int(Performance.get_monitor(
		Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
	))
	var primitives := int(Performance.get_monitor(
		Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME
	))
	_last_snapshot.merge({
		"ticks_us": Time.get_ticks_usec(),
		"fps": fps,
		"process_ms": process_ms,
		"physics_ms": physics_ms,
		"draw_calls": draw_calls,
		"primitives": primitives,
		"frame_cap": Engine.max_fps,
		"metrics": metrics.duplicate(true),
		"collision_status": collision_status.duplicate(true),
	}, true)
	_performance_label.text = (
		"DIAGNOSTICS ACTIVE (5 Hz)\nFPS %.1f / cap %d\nMain %.2f ms  Physics %.2f ms\n" +
		"Godot draws %d  Primitives %d (excludes custom GPU draws)\n" +
		"Jobs %d  Render %d  Collision %d\n" +
		"Replacements %d  Retirements %d  Collision backlog %d"
	) % [
		fps,
		Engine.max_fps,
		process_ms,
		physics_ms,
		draw_calls,
		primitives,
		int(metrics.get("scheduler_queued_jobs", 0)),
		int(metrics.get("queued_render", 0)),
		int(metrics.get("queued_collision", 0)),
		int(metrics.get("pending_chunk_replacements", 0)),
		int(metrics.get("pending_chunk_retirements", 0)),
		int(metrics.get("total_collision_backlog", 0)),
	]
	var intervals := _draw_intervals.duplicate()
	intervals.sort()
	var p95: float = intervals[mini(intervals.size() - 1, ceili(intervals.size() * 0.95) - 1)] \
		if not intervals.is_empty() else 0.0
	_last_snapshot["post_draw_p95_ms"] = p95
	_performance_label.text += "\nPost-draw p95 %.2f ms (%d frames)" % [p95, intervals.size()]
	if _terrain_world != null and _terrain_world.has_method("get_gpu_resident_render_status"):
		var gpu: Dictionary = _terrain_world.call("get_gpu_resident_render_status")
		if bool(gpu.get("running", false)):
			_gpu_states = _terrain_world.call("get_debug_gpu_processing_states")
			var counts := Pipeline.stage_counts(_gpu_states)
			var wait: Dictionary = gpu.get("last_activation_cohort_wait", {})
			var native: Dictionary = gpu.get("native_metrics", {})
			var effect: Dictionary = gpu.get("effect_status", {})
			var arena: Dictionary = effect.get("arena_status", {})
			_last_snapshot["gpu"] = {
				"stages": counts, "waiting": wait,
				"wait_age_frames": gpu.get("last_activation_wait_age_frames", -1),
				"pending_activation_retries": gpu.get("pending_activation_retry_groups", 0),
				"stale_seed_skips": gpu.get("activation_stale_seed_skips", 0),
				"native_queued": native.get("queued_requests", 0),
				"native_in_flight": native.get("in_flight_requests", 0),
				"stage_timing_usec": gpu.get("stage_timing_usec", {}),
				"arena": arena.duplicate(true),
			}
			_performance_label.text += (
				"\nGPU extracting %d  Prepare wait %d\nCohort wait %d  Activating %d\n" +
				"Active (incl. empty) %d  Retiring %d  Native queue %d\n" +
				"Activation retries %d  Stale seeds removed %d\n" +
				"Meshlets incremental %d / dispatch %d  Copy fallback %d\n" +
				"Last regenerated %d cells  Upload %d B  Device copy %d B\n" +
				"Arena pages %d  Active slots %d  Extraction failures %d\n" +
				"Last wait (%d frames ago): %s\nArena: %s"
			) % [counts.get("extracting", 0), counts.get("native_prepare_wait", 0),
				counts.get("cohort_wait", 0), counts.get("activation_queued", 0),
				counts.get("visible", 0), counts.get("retiring", 0), native.get("queued_requests", 0),
				gpu.get("pending_activation_retry_groups", 0), gpu.get("activation_stale_seed_skips", 0),
				arena.get("incremental_dispatch_count", 0), arena.get("dispatch_count", 0),
				arena.get("incremental_copy_fallback_count", 0),
				arena.get("last_regenerated_cell_count", 0),
				arena.get("last_dispatch_uploaded_bytes", 0),
				arena.get("last_incremental_meshlet_copy_bytes", 0),
				arena.get("page_count", 0), arena.get("active_slots", 0),
				arena.get("failed_extractions", 0),
				gpu.get("last_activation_wait_age_frames", -1), wait.get("status", "none"),
				arena.get("last_error", "ok") if not str(arena.get("last_error", "")).is_empty() else "ok"]
	var history_sample := {
		"ticks_us": _last_snapshot.ticks_us, "post_draw_p95_ms": p95,
		"queued_jobs": metrics.get("scheduler_queued_jobs", 0),
		"queued_collision": metrics.get("queued_collision", 0),
		"pending_replacements": metrics.get("pending_chunk_replacements", 0),
		"collision_waiting": collision_status.get("waiting", false),
		"gpu": Dictionary(_last_snapshot.get("gpu", {})).get("stages", {}),
	}
	_history.append(history_sample)
	if _history.size() > 64:
		_history.pop_front()


func _refresh_world_visuals() -> void:
	if _terrain_world == null or _player == null or \
			not _terrain_world.has_method("query_active_chunk_states"):
		return
	var states: Array = _terrain_world.call("query_active_chunk_states")
	var chunk_mesh := ImmediateMesh.new()
	var collision_mesh := ImmediateMesh.new()
	var chunk_count := 0
	var collision_count := 0
	var collision_counts := {}
	if _chunk_toggle != null and _chunk_toggle.button_pressed:
		chunk_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _line_material())
	if _collision_toggle != null and _collision_toggle.button_pressed:
		collision_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _line_material())
	for value in states:
		if chunk_count + collision_count >= MAX_VISUALIZED_RECORDS:
			break
		var state := value as RefCounted
		if state == null or not bool(state.call("is_present")):
			continue
		var coordinate: Vector3i = state.call("get_chunk_coordinate")
		var lod := int(state.call("get_lod"))
		var size := CHUNK_EXTENT * pow(2.0, float(lod))
		var minimum := Vector3(
			float(coordinate.x), float(coordinate.y), float(coordinate.z)
		) * size
		var maximum := minimum + Vector3.ONE * size
		if _chunk_toggle != null and _chunk_toggle.button_pressed and \
				bool(state.call("is_visual_required")) and \
				_bounds_near_player(minimum, maximum, CHUNK_VISUAL_RADIUS):
			_add_box_lines(chunk_mesh, minimum, maximum, _lod_color(lod))
			chunk_count += 1
		if _collision_toggle != null and _collision_toggle.button_pressed and \
				bool(state.call("is_collision_required")) and \
				_bounds_near_player(minimum, maximum, COLLISION_VISUAL_RADIUS):
			var stage := Pipeline.collision_stage(state)
			collision_counts[stage] = int(collision_counts.get(stage, 0)) + 1
			_add_box_lines(collision_mesh, minimum + Vector3.ONE * 0.08,
				maximum - Vector3.ONE * 0.08, Pipeline.collision_color(stage))
			collision_count += 1
	if _chunk_toggle != null and _chunk_toggle.button_pressed:
		if chunk_count > 0:
			chunk_mesh.surface_end()
		_chunk_lines.mesh = chunk_mesh if chunk_count > 0 else null
	if _collision_toggle != null and _collision_toggle.button_pressed:
		if collision_count > 0:
			collision_mesh.surface_end()
		_collision_lines.mesh = collision_mesh if collision_count > 0 else null
		_refresh_collision_wireframes()
	if _pipeline_toggle != null and _pipeline_toggle.button_pressed:
		_refresh_pipeline_visuals()
	_last_snapshot["visualized_chunk_records"] = chunk_count
	_last_snapshot["visualized_collision_records"] = collision_count
	_last_snapshot["collision_stages"] = collision_counts


func _bounds_near_player(minimum: Vector3, maximum: Vector3, radius: float) -> bool:
	var point := _player.global_position
	var closest := Vector3(
		clampf(point.x, minimum.x, maximum.x),
		clampf(point.y, minimum.y, maximum.y),
		clampf(point.z, minimum.z, maximum.z)
	)
	return point.distance_squared_to(closest) <= radius * radius


func set_debug_options(collision: bool, chunks: bool, pipeline: bool, hud: bool) -> void:
	_collision_toggle.set_pressed_no_signal(collision)
	_chunk_toggle.set_pressed_no_signal(chunks)
	_pipeline_toggle.set_pressed_no_signal(pipeline)
	_performance_toggle.set_pressed_no_signal(hud)
	_set_collision_visualization(collision)
	_set_chunk_visualization(chunks)
	_set_pipeline_visualization(pipeline)
	_set_performance_hud(hud)


func _refresh_pipeline_visuals() -> void:
	if not _terrain_world.has_method("get_debug_gpu_processing_states"):
		return
	_gpu_states = _terrain_world.call("get_debug_gpu_processing_states")
	var mesh := ImmediateMesh.new()
	var count := 0
	for state in _gpu_states:
		var minimum: Vector3 = state.get("bounds_min", Vector3.ZERO)
		var maximum: Vector3 = state.get("bounds_max", Vector3.ZERO)
		if maximum == minimum or not _bounds_near_player(minimum, maximum, CHUNK_VISUAL_RADIUS):
			continue
		if count >= MAX_VISUALIZED_RECORDS:
			break
		if count == 0:
			mesh.surface_begin(Mesh.PRIMITIVE_LINES, _line_material())
		_add_box_lines(mesh, minimum + Vector3.ONE * 0.04,
			maximum - Vector3.ONE * 0.04, Pipeline.STAGE_COLORS.get(state.stage, Color.WHITE))
		count += 1
	if count > 0:
		mesh.surface_end()
	_pipeline_lines.mesh = mesh if count > 0 else null
	_last_snapshot["visualized_gpu_records"] = count


func _refresh_collision_wireframes() -> void:
	if not _terrain_world.has_method("get_backend_terrain"):
		return
	var backend: Node = _terrain_world.call("get_backend_terrain")
	if backend == null:
		return
	var seen := {}
	var bodies: Array = []
	for child in backend.get_children():
		if child is StaticBody3D and str(child.name).begins_with("WT_Collision_"):
			if child.global_position.distance_squared_to(_player.global_position) \
					<= COLLISION_VISUAL_RADIUS * COLLISION_VISUAL_RADIUS:
				bodies.append(child)
	bodies.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return a.global_position.distance_squared_to(_player.global_position) \
			< b.global_position.distance_squared_to(_player.global_position))
	for body in bodies.slice(0, mini(96, bodies.size())):
		var shape_node := body.get_node_or_null("Shape") as CollisionShape3D
		if shape_node == null or shape_node.disabled or shape_node.shape == null:
			continue
		var key: int = body.get_instance_id()
		seen[key] = true
		var entry: Dictionary = _collision_wireframes.get(key, {})
		if entry.is_empty():
			var instance := _make_line_instance("LiveCollisionWire")
			var material := _line_material()
			material.vertex_color_use_as_albedo = false
			material.albedo_color = Color(0.2, 1.0, 0.4, 0.65)
			instance.material_override = material
			add_child(instance)
			entry = {"instance": instance, "shape_id": 0}
		if int(entry.shape_id) != shape_node.shape.get_instance_id():
			entry.instance.mesh = shape_node.shape.get_debug_mesh()
			entry.shape_id = shape_node.shape.get_instance_id()
		entry.instance.global_transform = shape_node.global_transform
		_collision_wireframes[key] = entry
	for key in _collision_wireframes.keys():
		if not seen.has(key):
			_collision_wireframes[key].instance.queue_free()
			_collision_wireframes.erase(key)
	_last_snapshot["live_collision_wireframes"] = seen.size()


func _clear_collision_wireframes() -> void:
	for entry in _collision_wireframes.values():
		entry.instance.queue_free()
	_collision_wireframes.clear()
	_last_snapshot["live_collision_wireframes"] = 0
	_last_snapshot["visualized_collision_records"] = 0
	_last_snapshot["collision_stages"] = {}
	if _collision_lines != null:
		_collision_lines.mesh = null


func _save_snapshot() -> void:
	_refresh_performance_hud()
	_refresh_world_visuals()
	var directory := ProjectSettings.globalize_path("res://.godot/world_transvoxel_captures/pipeline_debug")
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		_saved_label.text = "Snapshot directory could not be created."
		return
	var stem := "%s_%d" % [Time.get_datetime_string_from_system().replace(":", "-"), Time.get_ticks_msec()]
	var path := directory.path_join(stem + ".json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_saved_label.text = "Snapshot could not be written."
		return
	file.store_string(JSON.stringify(get_diagnostic_snapshot(), "\t"))
	file.close()
	_saved_label.text = "Saved " + stem + ".json"
	print("WT_PIPELINE_SNAPSHOT ", path)


func capture_debug_views(output_path: String) -> Dictionary:
	var directory := ProjectSettings.globalize_path(output_path).get_base_dir()
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return {"ok": false, "error": "capture_directory_failed"}
	var captures: Array = []
	for mode in ["collision", "lod", "pipeline", "menu", "off"]:
		set_menu_open(false)
		_player.call("set_human_input_enabled", false)
		set_debug_options(mode == "collision", mode == "lod", mode == "pipeline", mode != "off")
		if mode == "menu":
			set_menu_open(true)
		for _frame in range(18):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var stem := directory.path_join("debug_" + mode)
		var error := get_viewport().get_texture().get_image().save_png(stem + ".png")
		var snapshot := get_diagnostic_snapshot()
		var file := FileAccess.open(stem + ".json", FileAccess.WRITE)
		if file == null or error != OK:
			return {"ok": false, "error": "capture_write_failed", "mode": mode}
		file.store_string(JSON.stringify(snapshot, "\t"))
		file.close()
		captures.append({"mode": mode, "image": stem + ".png", "snapshot": stem + ".json"})
		if mode == "collision" and int(snapshot.get("live_collision_wireframes", 0)) == 0:
			return {"ok": false, "error": "no_physical_collision_wireframes", "captures": captures}
		if mode == "lod" and int(snapshot.get("visualized_chunk_records", 0)) == 0:
			return {"ok": false, "error": "no_lod_records", "captures": captures}
		if mode == "pipeline" and snapshot.get("gpu_processing", []).is_empty():
			return {"ok": false, "error": "no_gpu_processing_records", "captures": captures}
	return {"ok": true, "diagnostic_only": true, "captures": captures}


func _exit_tree() -> void:
	if RenderingServer.frame_post_draw.is_connected(_record_draw_interval):
		RenderingServer.frame_post_draw.disconnect(_record_draw_interval)
	if _terrain_world != null and is_instance_valid(_terrain_world) \
			and _terrain_world.has_method("set_debug_gpu_stage_timing_enabled"):
		_terrain_world.call("set_debug_gpu_stage_timing_enabled", false)


func _lod_color(lod: int) -> Color:
	match lod:
		0:
			return Color(0.18, 0.92, 1.0, 0.90)
		1:
			return Color(1.0, 0.90, 0.18, 0.90)
		2:
			return Color(1.0, 0.48, 0.12, 0.90)
		_:
			return Color(0.95, 0.28, 0.92, 0.90)


func _make_line_instance(node_name: String) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _line_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	return material


func _add_box_lines(
	mesh: ImmediateMesh,
	minimum: Vector3,
	maximum: Vector3,
	color: Color
) -> void:
	var corners := [
		Vector3(minimum.x, minimum.y, minimum.z),
		Vector3(maximum.x, minimum.y, minimum.z),
		Vector3(maximum.x, maximum.y, minimum.z),
		Vector3(minimum.x, maximum.y, minimum.z),
		Vector3(minimum.x, minimum.y, maximum.z),
		Vector3(maximum.x, minimum.y, maximum.z),
		Vector3(maximum.x, maximum.y, maximum.z),
		Vector3(minimum.x, maximum.y, maximum.z),
	]
	mesh.surface_set_color(color)
	for edge in BOX_EDGES:
		mesh.surface_add_vertex(corners[edge[0]])
		mesh.surface_add_vertex(corners[edge[1]])


func _quit_playtest() -> void:
	get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
	get_tree().quit(0)

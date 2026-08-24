extends Node3D

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
var _performance_toggle: CheckButton
var _performance_label: Label
var _collision_wait_label: Label
var _legend_label: Label
var _collision_lines: MeshInstance3D
var _chunk_lines: MeshInstance3D
var _refresh_elapsed := 0.0
var _last_snapshot := {}


func build_ui(canvas: CanvasLayer, crosshair: Control = null) -> void:
	_crosshair = crosshair
	_build_escape_menu(canvas)
	_build_diagnostic_labels(canvas)
	_collision_lines = _make_line_instance("CollisionResidencyLines")
	_chunk_lines = _make_line_instance("ChunkBoundaryLines")
	add_child(_collision_lines)
	add_child(_chunk_lines)
	_collision_lines.visible = false
	_chunk_lines.visible = false


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
	return _last_snapshot.duplicate(true)


func _process(delta: float) -> void:
	_update_collision_wait_feedback()
	_refresh_elapsed += delta
	if _refresh_elapsed < VISUAL_REFRESH_SECONDS:
		return
	_refresh_elapsed = 0.0
	if _performance_toggle != null and _performance_toggle.button_pressed:
		_refresh_performance_hud()
	if (_collision_toggle != null and _collision_toggle.button_pressed) or \
			(_chunk_toggle != null and _chunk_toggle.button_pressed):
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
	panel.offset_top = -170.0
	panel.offset_right = 190.0
	panel.offset_bottom = 170.0
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.035, 0.055, 0.055, 0.98)
	panel_style.border_color = Color(0.20, 0.52, 0.48, 1.0)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", panel_style)
	_menu.add_child(panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	content.add_theme_constant_override("margin_left", 20)
	content.add_theme_constant_override("margin_top", 18)
	content.add_theme_constant_override("margin_right", 20)
	content.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(content)
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
	_performance_toggle = CheckButton.new()
	_performance_toggle.name = "PerformanceHudToggle"
	_performance_toggle.text = "Performance HUD"
	_performance_toggle.toggled.connect(_set_performance_hud)
	content.add_child(_performance_toggle)
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
	_performance_label.offset_right = 470.0
	_performance_label.offset_bottom = 260.0
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
	_legend_label.offset_left = -560.0
	_legend_label.offset_top = -58.0
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
	get_tree().debug_collisions_hint = enabled
	_refresh_elapsed = VISUAL_REFRESH_SECONDS
	_update_legend()


func _set_chunk_visualization(enabled: bool) -> void:
	if _chunk_lines != null:
		_chunk_lines.visible = enabled
	_refresh_elapsed = VISUAL_REFRESH_SECONDS
	_update_legend()


func _set_performance_hud(enabled: bool) -> void:
	if _performance_label != null:
		_performance_label.visible = enabled
	if enabled:
		_refresh_performance_hud()


func _update_legend() -> void:
	if _legend_label == null:
		return
	var collision_visible := _collision_toggle != null and \
		_collision_toggle.button_pressed
	var chunks_visible := _chunk_toggle != null and _chunk_toggle.button_pressed
	_legend_label.visible = collision_visible or chunks_visible
	if collision_visible and chunks_visible:
		_legend_label.text = "Collision: green ready, orange pending | Chunks: cyan L0, yellow L1, orange L2, magenta L3"
	elif collision_visible:
		_legend_label.text = "Collision residency: green ready, orange pending"
	else:
		_legend_label.text = "Chunk LOD: cyan L0, yellow L1, orange L2, magenta L3"


func _update_collision_wait_feedback() -> void:
	if _collision_wait_label == null or _player == null or \
			not _player.has_method("get_streaming_collision_status"):
		return
	var status: Dictionary = _player.call("get_streaming_collision_status")
	var waiting := bool(status.get("waiting", false))
	_collision_wait_label.visible = waiting and not is_menu_open()
	if not waiting:
		return
	var readiness: Dictionary = status.get("readiness", {})
	_collision_wait_label.text = "TERRAIN COLLISION PENDING  %.2f s  |  %d support chunks" % [
		float(status.get("wait_seconds", 0.0)),
		Array(readiness.get("not_ready_chunks", [])).size(),
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
	_last_snapshot = {
		"fps": fps,
		"process_ms": process_ms,
		"physics_ms": physics_ms,
		"draw_calls": draw_calls,
		"primitives": primitives,
		"frame_cap": Engine.max_fps,
		"metrics": metrics.duplicate(true),
		"collision_status": collision_status.duplicate(true),
	}
	_performance_label.text = (
		"FPS %.1f / cap %d\nMain %.2f ms  Physics %.2f ms\n" +
		"Draws %d  Primitives %d\n" +
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


func _refresh_world_visuals() -> void:
	if _terrain_world == null or _player == null or \
			not _terrain_world.has_method("query_active_chunk_states"):
		return
	var states: Array = _terrain_world.call("query_active_chunk_states")
	var chunk_mesh := ImmediateMesh.new()
	var collision_mesh := ImmediateMesh.new()
	var chunk_count := 0
	var collision_count := 0
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
			var color := Color(0.20, 1.0, 0.38, 0.92) \
				if bool(state.call("is_collision_ready")) \
				else Color(1.0, 0.48, 0.12, 1.0)
			_add_box_lines(collision_mesh, minimum, maximum, color)
			collision_count += 1
	if _chunk_toggle != null and _chunk_toggle.button_pressed:
		chunk_mesh.surface_end()
		_chunk_lines.mesh = chunk_mesh if chunk_count > 0 else null
	if _collision_toggle != null and _collision_toggle.button_pressed:
		collision_mesh.surface_end()
		_collision_lines.mesh = collision_mesh if collision_count > 0 else null
	_last_snapshot["visualized_chunk_records"] = chunk_count
	_last_snapshot["visualized_collision_records"] = collision_count


func _bounds_near_player(minimum: Vector3, maximum: Vector3, radius: float) -> bool:
	var point := _player.global_position
	var closest := Vector3(
		clampf(point.x, minimum.x, maximum.x),
		clampf(point.y, minimum.y, maximum.y),
		clampf(point.z, minimum.z, maximum.z)
	)
	return point.distance_squared_to(closest) <= radius * radius


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

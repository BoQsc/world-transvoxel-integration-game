@tool
extends "res://addons/world_transvoxel_terrain/debug/wt_terrain_large_acceptance_qualification.gd"


func _refresh_metrics() -> void:
	super._refresh_metrics()
	if not _world_started: return
	status_label.text = _readiness_status()
	profile_label.text = "2,048 x 256 x 2,048 cells\n128 x 16 x 128 chunks\n%s catalog pages" % Support.format_integer(int(terrain_world.call("get_world_page_count")))
	viewer_label.text = "Viewer  %.1f, %.1f, %.1f\nRevision  %d" % [_viewer_position.x, _viewer_position.y, _viewer_position.z, _viewer_revision]
	residency_label.text = "Resident  %d active / %d ready\nRender  %d    Collision  %d" % [int(_last_metrics.get("non_retiring_chunk_records", 0)), int(_last_metrics.get("non_retiring_fully_ready_chunk_records", 0)), int(_last_metrics.get("render_resources", 0)), int(_last_metrics.get("collision_resources", 0))]
	var counts := _last_audit.get("lod_counts", {}) as Dictionary
	lod_label.text = "LOD0  %d    LOD1  %d    LOD2  %d\nOverlap  %d    Generation errors  %d" % [int(counts.get("0", 0)), int(counts.get("1", 0)), int(counts.get("2", 0)), int(_last_audit.get("coverage_overlap_count", 0)), (_last_audit.get("visual_generation_mismatches", []) as Array).size() + (_last_audit.get("collision_generation_mismatches", []) as Array).size()]
	pipeline_label.text = "Queues  %d jobs / %d storage\nRender  %d    Collision  %d" % [int(_last_metrics.get("scheduler_queued_jobs", 0)), int(_last_metrics.get("storage_queued_requests", 0)), int(_last_metrics.get("queued_render", 0)), int(_last_metrics.get("total_collision_backlog", 0))]


func _collect_live_lod_counts() -> Dictionary:
	var counts := {}
	var visual_errors := 0
	var collision_errors := 0
	for value in terrain_world.call("query_active_chunk_states"):
		var state := value as RefCounted
		if state == null or not bool(state.call("is_present")): continue
		var lod := str(int(state.call("get_lod")))
		counts[lod] = int(counts.get(lod, 0)) + 1
		var generation := int(state.call("get_generation"))
		if bool(state.call("is_visual_required")) and (not bool(state.call("is_visual_ready")) or int(state.call("get_render_generation")) not in [0, generation]): visual_errors += 1
		if bool(state.call("is_collision_required")) and (not bool(state.call("is_collision_ready")) or int(state.call("get_collision_generation")) not in [0, generation]): collision_errors += 1
	return {
		"status": "PASS" if visual_errors == 0 and collision_errors == 0 else "STREAMING",
		"lod_counts": counts, "coverage_overlap_count": 0,
		"visual_generation_mismatches": range(visual_errors),
		"collision_generation_mismatches": range(collision_errors),
		"implementation": "production_addon_live_lod_counts_v1",
	}


func _refresh_resident_bounds(force: bool = false) -> void:
	var backend: Node = terrain_world.call("get_backend_terrain") if terrain_world != null else null
	if backend == null: return
	var nodes: Array[MeshInstance3D] = []
	var names: Array[String] = []
	_collect_render_nodes(backend, nodes, names)
	names.sort()
	var signature := "\n".join(names).sha256_text()
	if not force and signature == _last_render_signature: return
	_last_render_signature = signature
	if nodes.is_empty():
		resident_bounds.mesh = null; return
	var immediate := ImmediateMesh.new()
	immediate.surface_begin(Mesh.PRIMITIVE_LINES)
	for node in nodes:
		var size := 16.0 * pow(2.0, float(Support.lod_from_render_name(str(node.name))))
		Support.add_box_lines(immediate, node.global_position, node.global_position + Vector3.ONE * size)
	immediate.surface_end()
	resident_bounds.mesh = immediate


func _collect_render_nodes(node: Node, nodes: Array[MeshInstance3D], names: Array[String]) -> void:
	if node is MeshInstance3D and str(node.name).begins_with("WT_Render_"):
		nodes.append(node); names.append(str(node.name))
	for child in node.get_children():
		if child is Node: _collect_render_nodes(child, nodes, names)


func _build_world_bounds() -> void:
	var minimum := Vector3(0.0, VERTICAL_ORIGIN_CHUNKS * 16.0, 0.0)
	var maximum := minimum + Vector3(WORLD_CELLS)
	var immediate := ImmediateMesh.new()
	immediate.surface_begin(Mesh.PRIMITIVE_LINES)
	Support.add_box_lines(immediate, minimum, maximum)
	for target in TELEPORTS:
		immediate.surface_add_vertex(Vector3(target.x, minimum.y, target.z))
		immediate.surface_add_vertex(Vector3(target.x, minimum.y + WORLD_CELLS.y, target.z))
	immediate.surface_end()
	world_bounds.mesh = immediate
	world_bounds.visible = show_world_bounds
	resident_bounds.visible = show_resident_bounds


func _configure_interface() -> void:
	bounds_toggle.button_pressed = show_world_bounds
	resident_toggle.button_pressed = show_resident_bounds
	track_toggle.button_pressed = true
	%NearButton.pressed.connect(_teleport_to.bind(TELEPORTS[0]))
	%CenterButton.pressed.connect(_teleport_to.bind(TELEPORTS[1]))
	%EditSiteButton.pressed.connect(_teleport_to.bind(TELEPORTS[2]))
	%FarZButton.pressed.connect(_teleport_to.bind(TELEPORTS[3]))
	%FarXButton.pressed.connect(_teleport_to.bind(TELEPORTS[4]))
	%OverviewButton.pressed.connect(focus_world_overview)
	%CarveButton.pressed.connect(func() -> void: submit_edit_and_wait(&"carve", EDIT_CENTER))
	%ConstructButton.pressed.connect(func() -> void: submit_edit_and_wait(&"construct", CONSTRUCTION_CENTER))
	%RestartButton.pressed.connect(_restart_preview)
	bounds_toggle.toggled.connect(func(value: bool) -> void: world_bounds.visible = value)
	resident_toggle.toggled.connect(func(value: bool) -> void: resident_bounds.visible = value)
	track_toggle.toggled.connect(func(value: bool) -> void: _runtime_follow_camera = value)


func _teleport_to(position: Vector3) -> void:
	move_viewer_and_wait(position)


func _apply_editor_teleport() -> void:
	move_viewer_and_wait(TELEPORTS[clampi(editor_teleport_preset, 0, TELEPORTS.size() - 1)])


func _apply_preview_enabled() -> void:
	if editor_preview_enabled: await _start_preview()
	else: await _stop_preview(true)


func _restart_preview() -> void:
	await _stop_preview(true)
	if editor_preview_enabled: await _start_preview()


func _update_runtime_camera(delta: float) -> void:
	var direction := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): direction -= camera.global_basis.z
	if Input.is_key_pressed(KEY_S): direction += camera.global_basis.z
	if Input.is_key_pressed(KEY_A): direction -= camera.global_basis.x
	if Input.is_key_pressed(KEY_D): direction += camera.global_basis.x
	if Input.is_key_pressed(KEY_Q): direction -= Vector3.UP
	if Input.is_key_pressed(KEY_E): direction += Vector3.UP
	if direction.length_squared() > 0.0:
		var speed := 180.0 if Input.is_key_pressed(KEY_SHIFT) else 54.0
		camera.global_position += direction.normalized() * speed * delta
	if _runtime_follow_camera:
		var tracked := _clamp_viewer_position(camera.global_position)
		if tracked.distance_to(_viewer_position) >= 8.0: _request_viewer(tracked, false)


func _clear_resident_bounds() -> void:
	_last_render_signature = ""
	if is_instance_valid(resident_bounds): resident_bounds.mesh = null

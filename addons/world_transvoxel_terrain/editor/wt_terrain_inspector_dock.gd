@tool
extends VBoxContainer
class_name WtTerrainInspectorDock

const RuntimeProfile := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_runtime_profile.gd")
const AuthoringDocument := preload("res://addons/world_transvoxel_terrain/editor/wt_terrain_authoring_document.gd")
const ReproExporter := preload("res://addons/world_transvoxel_terrain/editor/wt_terrain_repro_exporter.gd")
const BrushPreview := preload("res://addons/world_transvoxel_terrain/editor/wt_terrain_brush_preview.gd")

var _editor_interface
var _undo_redo
var _world: Node
var _document = AuthoringDocument.new()
var _status := Label.new()
var _diagnostics := RichTextLabel.new()
var _profile_selector := OptionButton.new()
var _mode := OptionButton.new()
var _shape := OptionButton.new()
var _radius := SpinBox.new()
var _smooth_radius := SpinBox.new()
var _material_id := SpinBox.new()
var _center: Array[SpinBox] = []
var _preview_toggle := CheckBox.new()
var _import_dialog := FileDialog.new()


func setup(editor_interface, undo_redo) -> void:
	_editor_interface = editor_interface
	_undo_redo = undo_redo


func _ready() -> void:
	name = "Terrain"
	custom_minimum_size = Vector2(320, 420)
	_build_toolbar()
	add_child(_status)
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(tabs)
	tabs.add_child(_build_runtime_tab())
	tabs.add_child(_build_authoring_tab())
	tabs.add_child(_build_diagnostics_tab())
	_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_import_dialog.access = FileDialog.ACCESS_RESOURCES
	_import_dialog.filters = PackedStringArray(["*.json ; Terrain Authoring JSON"])
	_import_dialog.file_selected.connect(_on_import_selected)
	add_child(_import_dialog)
	if _editor_interface != null:
		_editor_interface.get_selection().selection_changed.connect(_on_selection_changed)
	_on_selection_changed()


func shutdown() -> void:
	BrushPreview.clear(_world)
	if _editor_interface != null:
		var selection = _editor_interface.get_selection()
		if selection.selection_changed.is_connected(_on_selection_changed):
			selection.selection_changed.disconnect(_on_selection_changed)


func _build_toolbar() -> void:
	var bar := HBoxContainer.new()
	bar.add_child(_icon_button("Reload", "Refresh terrain diagnostics", _refresh))
	bar.add_child(_icon_button("Play", "Start selected terrain world", _start_world))
	bar.add_child(_icon_button("Stop", "Stop selected terrain world", _stop_world))
	bar.add_child(_icon_button("Save", "Export one-action terrain repro", _export_repro))
	bar.add_child(_icon_button("Load", "Import authoring draft", _open_import))
	add_child(bar)


func _build_runtime_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.name = "Runtime"
	for label in ["Low Power", "Balanced", "Quality", "Reference"]:
		_profile_selector.add_item(label)
	_profile_selector.select(RuntimeProfile.Preset.REFERENCE)
	tab.add_child(_labeled("Profile", _profile_selector))
	var apply := Button.new()
	apply.text = "Apply Profile"
	apply.pressed.connect(_apply_profile)
	tab.add_child(apply)
	return tab


func _build_authoring_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.name = "Author"
	for label in ["Carve", "Construct", "Fill", "Paint", "Restore", "Place Volume"]:
		_mode.add_item(label)
	for label in ["Sphere", "Box"]:
		_shape.add_item(label)
	tab.add_child(_labeled("Operation", _mode))
	tab.add_child(_labeled("Shape", _shape))
	_radius = _number(0.01, 1024.0, 0.1, 2.0)
	_smooth_radius = _number(0.0, 64.0, 0.05, 0.0)
	_material_id = _number(1.0, 65535.0, 1.0, 2.0)
	tab.add_child(_labeled("Radius", _radius))
	tab.add_child(_labeled("Smooth", _smooth_radius))
	tab.add_child(_labeled("Material", _material_id))
	var center_row := HBoxContainer.new()
	for axis in ["X", "Y", "Z"]:
		var field := _number(-1000000.0, 1000000.0, 0.25, 0.0)
		field.tooltip_text = axis
		_center.append(field)
		center_row.add_child(field)
	tab.add_child(_labeled("Center", center_row))
	_preview_toggle.text = "Preview"
	_preview_toggle.button_pressed = true
	_preview_toggle.toggled.connect(_update_preview)
	tab.add_child(_preview_toggle)
	var actions := HBoxContainer.new()
	actions.add_child(_icon_button("Undo", "Undo authoring draft change", _undo_draft))
	actions.add_child(_icon_button("Redo", "Redo authoring draft change", _redo_draft))
	actions.add_child(_command_button("Update Preview", _commit_preview))
	actions.add_child(_command_button("Commit Edit", _commit_edit))
	tab.add_child(actions)
	return tab


func _build_diagnostics_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.name = "Inspect"
	_diagnostics.bbcode_enabled = true
	_diagnostics.fit_content = false
	_diagnostics.scroll_active = true
	_diagnostics.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(_diagnostics)
	return tab


func _on_selection_changed() -> void:
	BrushPreview.clear(_world)
	_world = null
	if _editor_interface != null:
		var selected: Array[Node] = _editor_interface.get_selection().get_selected_nodes()
		if not selected.is_empty() and selected[0].has_method("get_readiness_snapshot"):
			_world = selected[0]
	_refresh()


func _start_world() -> void:
	if _world != null and not _world.is_world_running():
		_status.text = "Running" if _world.start_world() else _world.get_last_error()
	_refresh()


func _stop_world() -> void:
	if _world != null and _world.is_world_running():
		_status.text = "Stopped" if _world.stop_world() else _world.get_last_error()
	_refresh()


func _apply_profile() -> void:
	if _world == null:
		return
	if _world.is_world_running():
		_status.text = "Stop terrain before changing profile"
		return
	var profile = RuntimeProfile.create_builtin(_profile_selector.selected)
	_undo_redo.create_action("Set Terrain Runtime Profile")
	_undo_redo.add_do_property(_world, "runtime_profile", profile)
	_undo_redo.add_undo_property(_world, "runtime_profile", _world.runtime_profile)
	_undo_redo.commit_action()
	_refresh()


func _commit_preview() -> void:
	_commit_document_change()
	_update_preview(true)


func _commit_edit() -> void:
	_commit_document_change()
	if _world == null or not _world.is_world_running():
		_status.text = "Running terrain required"
		return
	var accepted: bool = bool(_world.submit_edit_batch(_document.create_batch(), 5300))
	_status.text = "Edit accepted" if accepted else _world.get_last_error()
	_refresh()


func _commit_document_change() -> void:
	var before: Dictionary = _document.to_dictionary()
	var after := before.duplicate(true)
	after["mode"] = _mode.selected
	after["brush_shape"] = _shape.selected
	after["radius"] = _radius.value
	after["smooth_radius"] = _smooth_radius.value
	after["material_id"] = int(_material_id.value)
	after["center"] = [_center[0].value, _center[1].value, _center[2].value]
	after["preview_enabled"] = _preview_toggle.button_pressed
	after["draft_revision"] = int(before.get("draft_revision", 0)) + 1
	_undo_redo.create_action("Change Terrain Authoring Draft")
	_undo_redo.add_do_method(_document, "apply_dictionary", after)
	_undo_redo.add_undo_method(_document, "apply_dictionary", before)
	_undo_redo.commit_action()


func _undo_draft() -> void:
	_undo_redo.undo()
	_sync_controls()


func _redo_draft() -> void:
	_undo_redo.redo()
	_sync_controls()


func _update_preview(_enabled: bool) -> void:
	if _preview_toggle.button_pressed:
		BrushPreview.update(_world, _document)
	else:
		BrushPreview.clear(_world)


func _export_repro() -> void:
	var result := ReproExporter.export_repro(_world, _document)
	_status.text = str(result.get("path", result.get("error", "Repro export failed")))


func _open_import() -> void:
	_import_dialog.popup_centered_ratio(0.7)


func _on_import_selected(path: String) -> void:
	_status.text = "Draft imported" if _document.import_json(path) else "Import rejected"
	_sync_controls()


func _refresh() -> void:
	if _world == null:
		_status.text = "Select WtTerrainWorld"
		_diagnostics.text = ""
		return
	var readiness: Dictionary = _world.get_readiness_snapshot()
	_status.text = "%s | generation %d" % [_world.get_world_state_name(), _world.get_api_generation()]
	_diagnostics.text = "[b]Readiness[/b]\n%s\n\n[b]Metrics[/b]\n%s" % [
		JSON.stringify(readiness, "  "), JSON.stringify(_world.get_runtime_metrics(), "  ")
	]


func _sync_controls() -> void:
	var values: Dictionary = _document.to_dictionary()
	_mode.select(int(values.get("mode", 0)))
	_shape.select(int(values.get("brush_shape", 0)))
	_radius.value = float(values.get("radius", 2.0))
	_smooth_radius.value = float(values.get("smooth_radius", 0.0))
	_material_id.value = float(values.get("material_id", 2))
	var point: Array = values.get("center", [0.0, 0.0, 0.0])
	for index in range(3):
		_center[index].value = float(point[index])
	_preview_toggle.button_pressed = bool(values.get("preview_enabled", true))
	_update_preview(_preview_toggle.button_pressed)


func _icon_button(icon_name: String, tooltip: String, callback: Callable) -> Button:
	var button := Button.new()
	button.icon = get_theme_icon(icon_name, "EditorIcons")
	button.tooltip_text = tooltip
	button.pressed.connect(callback)
	return button


func _command_button(label: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.pressed.connect(callback)
	return button


func _labeled(label: String, control: Control) -> Control:
	var row := HBoxContainer.new()
	var text := Label.new()
	text.text = label
	text.custom_minimum_size.x = 76
	row.add_child(text)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


func _number(minimum: float, maximum: float, step: float, value: float) -> SpinBox:
	var field := SpinBox.new()
	field.min_value = minimum
	field.max_value = maximum
	field.step = step
	field.value = value
	return field

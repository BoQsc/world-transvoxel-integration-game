@tool
extends EditorPlugin

const DependencyStatus := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_dependency_status.gd")
const InspectorDock := preload("res://addons/world_transvoxel_terrain/editor/wt_terrain_inspector_dock.gd")
const ADDON_NAME := "World Transvoxel Terrain"

var _dock: Control


func _enter_tree() -> void:
	var status := DependencyStatus.new().get_status()
	if not bool(status.get("installed", false)):
		print("%s: %s" % [ADDON_NAME, status.get("message", "")])
	if OS.get_cmdline_args().has("--import") or DisplayServer.get_name() == "headless":
		return
	_dock = InspectorDock.new()
	_dock.setup(get_editor_interface(), get_undo_redo())
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
	if _dock != null:
		_dock.shutdown()
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null

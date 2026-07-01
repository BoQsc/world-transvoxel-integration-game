@tool
extends EditorPlugin

const DependencyStatus := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_dependency_status.gd")
const ADDON_NAME := "World Transvoxel Terrain"


func _enter_tree() -> void:
	var status := DependencyStatus.new().get_status()
	if not bool(status.get("installed", false)):
		print("%s: %s" % [ADDON_NAME, status.get("message", "")])


func _exit_tree() -> void:
	pass

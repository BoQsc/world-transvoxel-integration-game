@tool
extends RefCounted
class_name WtTerrainDependencyStatus

const WORLD_TRANSVOXEL_PLUGIN_CFG := "res://addons/world_transvoxel/plugin.cfg"


func get_status() -> Dictionary:
	var installed := FileAccess.file_exists(WORLD_TRANSVOXEL_PLUGIN_CFG)
	var version := ""
	var name := ""
	var load_error := OK

	if installed:
		var config := ConfigFile.new()
		load_error = config.load(WORLD_TRANSVOXEL_PLUGIN_CFG)
		if load_error == OK:
			name = str(config.get_value("plugin", "name", ""))
			version = str(config.get_value("plugin", "version", ""))

	return {
		"dependency": "world-transvoxel",
		"installed": installed,
		"plugin_cfg": WORLD_TRANSVOXEL_PLUGIN_CFG,
		"name": name,
		"version": version,
		"load_error": load_error,
		"message": _message(installed, load_error, version),
	}


func _message(installed: bool, load_error: int, version: String) -> String:
	if not installed:
		return "world-transvoxel addon is not installed in this project"
	if load_error != OK:
		return "world-transvoxel plugin.cfg exists but could not be parsed"
	if version.is_empty():
		return "world-transvoxel addon is installed with unknown version"
	return "world-transvoxel addon is installed: %s" % version

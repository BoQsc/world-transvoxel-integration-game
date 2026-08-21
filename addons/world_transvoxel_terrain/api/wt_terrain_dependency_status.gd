@tool
extends RefCounted
class_name WtTerrainDependencyStatus

const WORLD_TRANSVOXEL_EXTENSION_DESCRIPTOR := \
	"res://addons/world_transvoxel/world_transvoxel.gdextension"
const WORLD_TRANSVOXEL_TERRAIN_CLASS := &"WorldTransvoxelTerrain"


func get_status() -> Dictionary:
	var descriptor_exists := FileAccess.file_exists(WORLD_TRANSVOXEL_EXTENSION_DESCRIPTOR)
	var class_exists := ClassDB.class_exists(WORLD_TRANSVOXEL_TERRAIN_CLASS)
	var installed := descriptor_exists and class_exists
	var version := ""
	if class_exists:
		var terrain = ClassDB.instantiate(WORLD_TRANSVOXEL_TERRAIN_CLASS)
		if terrain != null:
			if terrain.has_method("get_addon_version"):
				version = str(terrain.call("get_addon_version"))
			terrain.free()

	return {
		"dependency": "world-transvoxel",
		"installed": installed,
		"extension_descriptor": WORLD_TRANSVOXEL_EXTENSION_DESCRIPTOR,
		"descriptor_exists": descriptor_exists,
		"terrain_class": WORLD_TRANSVOXEL_TERRAIN_CLASS,
		"terrain_class_exists": class_exists,
		"name": "World Transvoxel",
		"version": version,
		"message": _message(descriptor_exists, class_exists, version),
	}


func _message(descriptor_exists: bool, class_exists: bool, version: String) -> String:
	if not descriptor_exists:
		return "world-transvoxel runtime artifact is not installed in this project"
	if not class_exists:
		return "world-transvoxel descriptor exists but its terrain class is unavailable"
	if version.is_empty():
		return "world-transvoxel runtime is installed with unknown version"
	return "world-transvoxel runtime is installed: %s" % version

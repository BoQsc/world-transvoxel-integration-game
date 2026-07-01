@tool
extends RefCounted
class_name WtWorldTransvoxelBridge

const DependencyStatus := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_dependency_status.gd")

const TERRAIN_CLASS := "WorldTransvoxelTerrain"
const CONFIG_CLASS := "WorldTransvoxelConfig"
const REQUIRED_TERRAIN_METHODS := [
	"get_addon_version",
	"get_milestone",
	"is_mit_backend_available",
	"get_backend_id",
	"get_backend_license",
	"get_backend_upstream_revision",
	"get_world_state_name",
	"get_runtime_metrics",
]
const REQUIRED_CONFIG_METHODS := [
	"get_schema_version",
	"is_valid",
	"get_validation_error",
]


func get_bridge_status() -> Dictionary:
	var dependency := DependencyStatus.new().get_status()
	var terrain_exists := ClassDB.class_exists(TERRAIN_CLASS)
	var config_exists := ClassDB.class_exists(CONFIG_CLASS)
	return {
		"dependency": dependency,
		"terrain_class": TERRAIN_CLASS,
		"config_class": CONFIG_CLASS,
		"terrain_class_exists": terrain_exists,
		"config_class_exists": config_exists,
		"bridge_ready": bool(dependency.get("installed", false)) and terrain_exists and config_exists,
	}


func instantiate_backend_terrain():
	if not ClassDB.class_exists(TERRAIN_CLASS):
		return null
	return ClassDB.instantiate(TERRAIN_CLASS)


func instantiate_backend_config():
	if not ClassDB.class_exists(CONFIG_CLASS):
		return null
	return ClassDB.instantiate(CONFIG_CLASS)


func get_backend_identity() -> Dictionary:
	var status := get_bridge_status()
	var identity := {
		"bridge_ready": bool(status.get("bridge_ready", false)),
		"addon_version": "",
		"milestone": "",
		"mit_backend_available": false,
		"backend_id": "",
		"backend_license": "",
		"backend_upstream_revision": "",
		"world_state_name": "",
		"config_schema_version": 0,
		"config_valid": false,
		"missing_methods": [],
	}
	if not bool(identity.get("bridge_ready", false)):
		return identity

	var terrain = instantiate_backend_terrain()
	if terrain == null:
		identity["bridge_ready"] = false
		identity["missing_methods"] = ["WorldTransvoxelTerrain instantiate"]
		return identity

	var missing := []
	for method_name in REQUIRED_TERRAIN_METHODS:
		if not terrain.has_method(method_name):
			missing.append("%s.%s" % [TERRAIN_CLASS, method_name])

	if missing.is_empty():
		identity["addon_version"] = str(terrain.call("get_addon_version"))
		identity["milestone"] = str(terrain.call("get_milestone"))
		identity["mit_backend_available"] = bool(terrain.call("is_mit_backend_available"))
		identity["backend_id"] = str(terrain.call("get_backend_id"))
		identity["backend_license"] = str(terrain.call("get_backend_license"))
		identity["backend_upstream_revision"] = str(terrain.call("get_backend_upstream_revision"))
		identity["world_state_name"] = str(terrain.call("get_world_state_name"))

	if terrain is Node:
		terrain.free()

	var config = instantiate_backend_config()
	if config == null:
		missing.append("WorldTransvoxelConfig instantiate")
	else:
		for method_name in REQUIRED_CONFIG_METHODS:
			if not config.has_method(method_name):
				missing.append("%s.%s" % [CONFIG_CLASS, method_name])
		if config.has_method("get_schema_version"):
			identity["config_schema_version"] = int(config.call("get_schema_version"))
		if config.has_method("is_valid"):
			identity["config_valid"] = bool(config.call("is_valid"))

	identity["missing_methods"] = missing
	if not missing.is_empty():
		identity["bridge_ready"] = false
	return identity

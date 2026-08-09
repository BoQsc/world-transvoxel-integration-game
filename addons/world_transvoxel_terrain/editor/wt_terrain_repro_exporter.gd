@tool
extends RefCounted
class_name WtTerrainReproExporter

const IMPLEMENTATION := "tqp53_one_action_repro_export_v1"


static func export_repro(world: Node, document: Resource, output_path: String = "") -> Dictionary:
	if world == null or not world.has_method("get_terrain_api_contract_summary"):
		return {"exported": false, "error": "WtTerrainWorld selection is required"}
	var path := output_path
	if path.is_empty():
		var stamp := Time.get_datetime_string_from_system().replace(":", "-")
		path = "user://world_transvoxel_terrain/repros/terrain_repro_%s.json" % stamp
	if not path.begins_with("user://") and not path.begins_with("res://"):
		return {"exported": false, "error": "repro path must use user:// or res://"}
	var absolute := ProjectSettings.globalize_path(path)
	var directory := absolute.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(directory) != OK and not DirAccess.dir_exists_absolute(directory):
		return {"exported": false, "error": "cannot create repro directory"}
	var payload := {
		"schema": "world_transvoxel_terrain.repro.v1",
		"api_contract": world.call("get_terrain_api_contract_summary"),
		"readiness": world.call("get_readiness_snapshot"),
		"debug_snapshot": world.call("get_debug_snapshot"),
		"authoring_document": document.call("to_dictionary") if document != null and document.has_method("to_dictionary") else {},
		"last_error": str(world.call("get_last_error")),
		"implementation": IMPLEMENTATION,
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"exported": false, "error": "cannot open repro output"}
	file.store_string(JSON.stringify(_json_safe(payload), "\t") + "\n")
	return {"exported": true, "path": path, "schema": payload["schema"], "implementation": IMPLEMENTATION}


static func _json_safe(value):
	match typeof(value):
		TYPE_DICTIONARY:
			var result := {}
			for key in value:
				result[str(key)] = _json_safe(value[key])
			return result
		TYPE_ARRAY:
			var result := []
			for item in value:
				result.append(_json_safe(item))
			return result
		TYPE_VECTOR2:
			return [value.x, value.y]
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return [value.x, value.y, value.z]
		TYPE_VECTOR4, TYPE_VECTOR4I:
			return [value.x, value.y, value.z, value.w]
		TYPE_COLOR:
			return [value.r, value.g, value.b, value.a]
		TYPE_STRING_NAME:
			return str(value)
		TYPE_OBJECT:
			return str(value)
		_:
			return value

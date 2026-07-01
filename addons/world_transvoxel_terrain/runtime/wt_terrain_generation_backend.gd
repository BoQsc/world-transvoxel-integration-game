@tool
extends RefCounted


static func start_backend_world(
	backend_terrain: Node,
	generation_profile: Resource,
	manifest_path: String,
	object_root: String
) -> Dictionary:
	if _uses_procedural_generation(generation_profile):
		if not backend_terrain.has_method("start_procedural_world"):
			return {
				"started": false,
				"error": "backend terrain cannot start procedural worlds",
			}
		return {
			"started": bool(backend_terrain.call(
				"start_procedural_world",
				int(generation_profile.get("world_chunk_count_x")),
				int(generation_profile.get("world_chunk_count_z")),
				int(generation_profile.get("seed")),
				int(generation_profile.get("source_revision")),
				object_root
			)),
			"error": "",
		}
	return {
		"started": bool(backend_terrain.call("start_world", manifest_path, object_root)),
		"error": "",
	}


static func _uses_procedural_generation(generation_profile: Resource) -> bool:
	if generation_profile == null:
		return false
	if not _resource_has_property(generation_profile, "source_mode"):
		return false
	if generation_profile.has_method("get_contract_summary"):
		var summary := Dictionary(generation_profile.call("get_contract_summary"))
		return str(summary.get("source_mode", "")) == "DETERMINISTIC_REFERENCE"
	return int(generation_profile.get("source_mode")) == 1


static func _resource_has_property(resource: Resource, property_name: String) -> bool:
	for property in resource.get_property_list():
		if str(property.get("name", "")) == property_name:
			return true
	return false

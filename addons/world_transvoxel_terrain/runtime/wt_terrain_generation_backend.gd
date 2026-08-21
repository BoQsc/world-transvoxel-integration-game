@tool
extends RefCounted


static func start_backend_world(
	backend_terrain: Node,
	generation_profile: Resource,
	manifest_path: String,
	object_root: String
) -> Dictionary:
	if backend_terrain == null:
		return {
			"started": false,
			"error": "backend terrain is required",
		}
	if generation_profile == null:
		if not backend_terrain.has_method("start_world"):
			return {
				"started": false,
				"error": "backend terrain cannot start persisted worlds",
			}
		return {
			"started": bool(backend_terrain.call("start_world", manifest_path, object_root)),
			"error": "",
		}
	var source_mode := _source_mode_name(generation_profile)
	var chunk_count_x := int(generation_profile.get("world_chunk_count_x"))
	var chunk_count_y := int(generation_profile.get("world_chunk_count_y"))
	var chunk_origin_y := int(generation_profile.get("world_chunk_origin_y"))
	var chunk_count_z := int(generation_profile.get("world_chunk_count_z"))
	var bottom_boundary_policy := _profile_int(
		generation_profile, "bottom_boundary_policy", 0
	)
	var bottom_boundary_thickness_cells := _profile_int(
		generation_profile, "bottom_boundary_thickness_cells", 0
	)
	var boundary_error := _bottom_boundary_configuration_error(
		source_mode,
		chunk_count_y,
		bottom_boundary_policy,
		bottom_boundary_thickness_cells
	)
	if not boundary_error.is_empty():
		return {
			"started": false,
			"error": boundary_error,
		}
	if source_mode == "FLAT":
		if backend_terrain.has_method("start_flat_world_with_vertical_origin"):
			return {
				"started": bool(backend_terrain.call(
					"start_flat_world_with_vertical_origin",
					chunk_count_x,
					chunk_count_y,
					chunk_origin_y,
					chunk_count_z,
					int(generation_profile.get("source_revision")),
					object_root
				)),
				"error": "",
			}
		if not backend_terrain.has_method("start_flat_world"):
			return {
				"started": false,
				"error": "backend terrain cannot start flat worlds",
			}
		return {
			"started": bool(backend_terrain.call(
				"start_flat_world",
				chunk_count_x,
				chunk_count_z,
				int(generation_profile.get("source_revision")),
				object_root
			)),
			"error": "",
		}
	if source_mode == "DETERMINISTIC_REFERENCE":
		var procedural_preset_id := _procedural_preset_id(generation_profile)
		if backend_terrain.has_method(
			"start_procedural_world_preset_with_vertical_origin_and_bottom_boundary"
		):
			return {
				"started": bool(backend_terrain.call(
					"start_procedural_world_preset_with_vertical_origin_and_bottom_boundary",
					chunk_count_x,
					chunk_count_y,
					chunk_origin_y,
					chunk_count_z,
					int(generation_profile.get("seed")),
					int(generation_profile.get("source_revision")),
					procedural_preset_id,
					bottom_boundary_policy,
					bottom_boundary_thickness_cells,
					object_root
				)),
				"error": "",
			}
		if bottom_boundary_policy != 0:
			return {
				"started": false,
				"error": "backend terrain lacks authoritative bottom-boundary support",
			}
		if backend_terrain.has_method("start_procedural_world_preset_with_vertical_origin"):
			return {
				"started": bool(backend_terrain.call(
					"start_procedural_world_preset_with_vertical_origin",
					chunk_count_x,
					chunk_count_y,
					chunk_origin_y,
					chunk_count_z,
					int(generation_profile.get("seed")),
					int(generation_profile.get("source_revision")),
					procedural_preset_id,
					object_root
				)),
				"error": "",
			}
		if procedural_preset_id != "mountain_reference":
			return {
				"started": false,
				"error": "backend terrain cannot start procedural preset: %s" % procedural_preset_id,
			}
		if backend_terrain.has_method("start_procedural_world_with_vertical_origin"):
			return {
				"started": bool(backend_terrain.call(
					"start_procedural_world_with_vertical_origin",
					chunk_count_x,
					chunk_count_y,
					chunk_origin_y,
					chunk_count_z,
					int(generation_profile.get("seed")),
					int(generation_profile.get("source_revision")),
					object_root
				)),
				"error": "",
			}
		if not backend_terrain.has_method("start_procedural_world"):
			return {
				"started": false,
				"error": "backend terrain cannot start procedural worlds",
			}
		return {
			"started": bool(backend_terrain.call(
				"start_procedural_world",
				chunk_count_x,
				chunk_count_z,
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


static func _source_mode_name(generation_profile: Resource) -> String:
	if generation_profile == null:
		return ""
	if not _resource_has_property(generation_profile, "source_mode"):
		return ""
	if generation_profile.has_method("get_contract_summary"):
		var summary := Dictionary(generation_profile.call("get_contract_summary"))
		return str(summary.get("source_mode", ""))
	var source_mode := int(generation_profile.get("source_mode"))
	if source_mode == 0:
		return "FLAT"
	if source_mode == 1:
		return "DETERMINISTIC_REFERENCE"
	if source_mode == 2:
		return "BAKED_WORLD"
	return ""


static func _procedural_preset_id(generation_profile: Resource) -> String:
	if generation_profile == null or not _resource_has_property(generation_profile, "procedural_preset_id"):
		return "mountain_reference"
	var preset_id := str(generation_profile.get("procedural_preset_id"))
	return preset_id if not preset_id.is_empty() else "mountain_reference"


static func _bottom_boundary_configuration_error(
	source_mode: String,
	chunk_count_y: int,
	policy: int,
	thickness_cells: int
) -> String:
	if policy < 0 or policy > 2:
		return "bottom boundary policy is invalid"
	if policy == 0:
		return "" if thickness_cells == 0 else "open bottom boundary must have zero thickness"
	if source_mode != "DETERMINISTIC_REFERENCE":
		return "bottom boundary policy requires deterministic native generation"
	if thickness_cells <= 0 or thickness_cells > chunk_count_y * 16:
		return "bottom boundary thickness is outside the vertical world volume"
	return ""


static func _profile_int(resource: Resource, property_name: String, fallback: int) -> int:
	if resource == null or not _resource_has_property(resource, property_name):
		return fallback
	return int(resource.get(property_name))


static func _resource_has_property(resource: Resource, property_name: String) -> bool:
	for property in resource.get_property_list():
		if str(property.get("name", "")) == property_name:
			return true
	return false

extends RefCounted


static func apply(transaction: Object, shape: StringName, operation: Resource) -> Dictionary:
	var material_id := int(operation.get("material_id"))
	var mode_name: StringName = operation.call("get_mode_name")
	var static_water := mode_name == &"place_static_water" or \
		mode_name == &"remove_static_water"
	var remove_static_water := mode_name == &"remove_static_water"
	var accepted := false
	if shape == &"sphere":
		if static_water:
			accepted = bool(transaction.call(
				"remove_static_water_sphere" if remove_static_water else \
					"place_static_water_sphere", operation.get("center"),
				float(operation.get("radius"))
			))
		else:
			accepted = bool(transaction.call(
				"place_material_volume_sphere", operation.get("center"),
				float(operation.get("radius")), material_id
			))
	else:
		var bounds: AABB = operation.call("estimate_affected_aabb")
		if static_water:
			accepted = bool(transaction.call(
				"remove_static_water_box" if remove_static_water else \
					"place_static_water_box", bounds.position,
				bounds.position + bounds.size
			))
		else:
			accepted = bool(transaction.call(
				"place_material_volume_box", bounds.position,
				bounds.position + bounds.size, material_id
			))
	return {
		"accepted": accepted,
		"error": "" if accepted else str(transaction.call("get_error")),
	}

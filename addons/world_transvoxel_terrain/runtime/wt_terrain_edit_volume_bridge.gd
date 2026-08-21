extends RefCounted


static func apply(transaction: Object, shape: StringName, operation: Resource) -> Dictionary:
	var material_id := int(operation.get("material_id"))
	var static_water: bool = operation.call("get_mode_name") == &"place_static_water"
	var accepted := false
	if shape == &"sphere":
		if static_water:
			accepted = bool(transaction.call(
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
				"place_static_water_box", bounds.position, bounds.position + bounds.size
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

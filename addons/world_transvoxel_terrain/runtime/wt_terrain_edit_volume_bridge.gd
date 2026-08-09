extends RefCounted


static func apply(transaction: Object, shape: StringName, operation: Resource) -> Dictionary:
	var material_id := int(operation.get("material_id"))
	var accepted := false
	if shape == &"sphere":
		accepted = bool(transaction.call(
			"place_material_volume_sphere", operation.get("center"),
			float(operation.get("radius")), material_id
		))
	else:
		var bounds: AABB = operation.call("estimate_affected_aabb")
		accepted = bool(transaction.call(
			"place_material_volume_box", bounds.position, bounds.position + bounds.size, material_id
		))
	return {
		"accepted": accepted,
		"error": "" if accepted else str(transaction.call("get_last_error")),
	}

extends RefCounted


static func apply_sphere(
	transaction: Object,
	operation: Resource,
	method_name: String,
	strength: float
) -> Dictionary:
	var smooth_radius := float(operation.get("smooth_radius"))
	var accepted := false
	if smooth_radius > 0.0:
		accepted = bool(transaction.call(
			method_name.replace("_sdf_sphere", "_smooth_sdf_sphere"),
			operation.get("center"), float(operation.get("radius")), strength, smooth_radius
		))
	else:
		accepted = bool(transaction.call(
			method_name, operation.get("center"), float(operation.get("radius")), strength
		))
	return _result(transaction, accepted)


static func apply_material_sphere(
	transaction: Object,
	operation: Resource,
	strength: float
) -> Dictionary:
	var smooth_radius := float(operation.get("smooth_radius"))
	var method_name := "construct_material_smooth_sdf_sphere" if smooth_radius > 0.0 else "construct_material_sdf_sphere"
	var arguments := [operation.get("center"), float(operation.get("radius")), strength, int(operation.get("material_id"))]
	if smooth_radius > 0.0:
		arguments.append(smooth_radius)
	return _result(transaction, bool(transaction.callv(method_name, arguments)))


static func _result(transaction: Object, accepted: bool) -> Dictionary:
	return {
		"accepted": accepted,
		"error": "" if accepted else str(transaction.call("get_last_error")),
	}

@tool
extends RefCounted
class_name WtTerrainEditBridge

const BACKEND_EDIT_METHODS := [
	"set_density_sphere",
	"set_density_box",
	"paint_material_sphere",
	"paint_material_box",
]

var _last_error: String = "ok"
var _last_submission_summary: Dictionary = {}


func get_last_error() -> String:
	return _last_error


func get_last_submission_summary() -> Dictionary:
	return _last_submission_summary


func begin_batch_transaction(
	backend_terrain: Object,
	batch: Resource,
	author_id: int = 0
) -> Object:
	_reset_summary()
	if not _validate_backend_terrain(backend_terrain):
		return null
	if not _validate_batch(batch):
		return null
	var transaction: Object = backend_terrain.call("begin_edit_transaction", author_id)
	if transaction == null:
		_last_error = _backend_error(backend_terrain)
		return null
	if not apply_batch_to_transaction(transaction, batch):
		return null
	return transaction


func commit_batch(
	backend_terrain: Object,
	batch: Resource,
	author_id: int = 0
) -> bool:
	var transaction := begin_batch_transaction(backend_terrain, batch, author_id)
	if transaction == null:
		return false
	if not backend_terrain.call("commit_edit_transaction", transaction):
		_last_error = _backend_error(backend_terrain)
		return false
	_last_submission_summary["submitted"] = true
	_last_error = "ok"
	return true


func apply_batch_to_transaction(transaction: Object, batch: Resource) -> bool:
	if transaction == null:
		_last_error = "backend edit transaction is required"
		return false
	if not _validate_batch(batch):
		return false
	var backend_command_count := 0
	for operation in batch.operations:
		var applied := _apply_operation(transaction, operation)
		if applied <= 0:
			return false
		backend_command_count += applied
	_last_submission_summary = {
		"submitted": false,
		"operation_count": batch.get_operation_count(),
		"backend_command_count": backend_command_count,
		"transaction_command_count": int(transaction.call("get_command_count")),
		"implementation": "bridge_edit_submission",
	}
	_last_error = "ok"
	return true


func _apply_operation(transaction: Object, operation: Resource) -> int:
	var mode := StringName(operation.call("get_mode_name"))
	var shape := StringName(operation.call("get_brush_shape_name"))
	if shape != &"sphere" and shape != &"box":
		_last_error = "world-transvoxel backend currently supports sphere and box edits only"
		return 0
	match mode:
		&"carve":
			return _apply_density(transaction, shape, operation, "set", _positive_density(operation))
		&"construct", &"fill":
			var density_count := _apply_density(
				transaction, shape, operation, "set", -_positive_density(operation)
			)
			if density_count <= 0:
				return 0
			var paint_count := _apply_paint(transaction, shape, operation)
			return density_count + paint_count if paint_count > 0 else 0
		&"paint":
			return _apply_paint(transaction, shape, operation)
		&"restore_to_base":
			var restore_count := _apply_density(
				transaction, shape, operation, "set", float(operation.get("density_value"))
			)
			if restore_count <= 0:
				return 0
			if int(operation.get("material_id")) > 0:
				var restore_paint_count := _apply_paint(transaction, shape, operation)
				return restore_count + restore_paint_count if restore_paint_count > 0 else 0
			return restore_count
		_:
			_last_error = "unsupported terrain edit operation: %s" % str(mode)
			return 0


func _apply_density(
	transaction: Object,
	shape: StringName,
	operation: Resource,
	method_prefix: String,
	value: float
) -> int:
	var ok := false
	if shape == &"sphere":
		ok = bool(transaction.call(
			"%s_density_sphere" % method_prefix,
			operation.get("center"),
			float(operation.get("radius")),
			value
		))
	else:
		var bounds: AABB = operation.call("estimate_affected_aabb")
		ok = bool(transaction.call(
			"%s_density_box" % method_prefix,
			bounds.position,
			bounds.position + bounds.size,
			value
		))
	if not ok:
		_last_error = _transaction_error(transaction)
		return 0
	return 1


func _apply_paint(transaction: Object, shape: StringName, operation: Resource) -> int:
	var material_id := int(operation.get("material_id"))
	var ok := false
	if shape == &"sphere":
		ok = bool(transaction.call(
			"paint_material_sphere",
			operation.get("center"),
			float(operation.get("radius")),
			material_id
		))
	else:
		var bounds: AABB = operation.call("estimate_affected_aabb")
		ok = bool(transaction.call(
			"paint_material_box",
			bounds.position,
			bounds.position + bounds.size,
			material_id
		))
	if not ok:
		_last_error = _transaction_error(transaction)
		return 0
	return 1


func _positive_density(operation: Resource) -> float:
	var value := absf(float(operation.get("density_value")))
	return value if value > 0.0 else 1.0


func _validate_backend_terrain(backend_terrain: Object) -> bool:
	if backend_terrain == null:
		_last_error = "backend terrain is required"
		return false
	for method_name in ["begin_edit_transaction", "commit_edit_transaction", "get_world_error"]:
		if not backend_terrain.has_method(method_name):
			_last_error = "backend terrain missing method: %s" % method_name
			return false
	return true


func _validate_batch(batch: Resource) -> bool:
	if batch == null:
		_last_error = "edit batch is required"
		return false
	if not batch.has_method("is_valid") or not batch.has_method("get_validation_error"):
		_last_error = "edit batch does not expose validation"
		return false
	if not batch.call("is_valid"):
		_last_error = str(batch.call("get_validation_error"))
		return false
	return true


func _backend_error(backend_terrain: Object) -> String:
	if backend_terrain != null and backend_terrain.has_method("get_world_error"):
		return str(backend_terrain.call("get_world_error"))
	return "backend terrain error is unavailable"


func _transaction_error(transaction: Object) -> String:
	if transaction != null and transaction.has_method("get_error"):
		return str(transaction.call("get_error"))
	return "backend transaction error is unavailable"


func _reset_summary() -> void:
	_last_error = "ok"
	_last_submission_summary = {
		"submitted": false,
		"operation_count": 0,
		"backend_command_count": 0,
		"transaction_command_count": 0,
		"implementation": "bridge_edit_submission",
	}

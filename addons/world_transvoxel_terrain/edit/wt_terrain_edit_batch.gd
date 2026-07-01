@tool
extends Resource
class_name WtTerrainEditBatch

@export var batch_id: int = 0
@export var operations: Array[Resource] = []


func add_operation(operation: Resource) -> bool:
	if operation == null:
		return false
	if not operation.has_method("is_valid"):
		return false
	operations.append(operation)
	return true


func clear() -> void:
	operations.clear()


func get_operation_count() -> int:
	return operations.size()


func is_valid() -> bool:
	return get_validation_error().is_empty()


func get_validation_error() -> String:
	if operations.is_empty():
		return "edit batch must contain at least one operation"
	for index in range(operations.size()):
		var operation := operations[index]
		if operation == null:
			return "edit batch operation %d is null" % index
		if not operation.has_method("get_validation_error"):
			return "edit batch operation %d does not expose validation" % index
		var error := str(operation.call("get_validation_error"))
		if not error.is_empty():
			return "edit batch operation %d is invalid: %s" % [index, error]
	return ""


func to_bridge_commands() -> Array[Dictionary]:
	var commands: Array[Dictionary] = []
	for operation in operations:
		if operation != null and operation.has_method("to_bridge_command"):
			commands.append(operation.call("to_bridge_command"))
	return commands

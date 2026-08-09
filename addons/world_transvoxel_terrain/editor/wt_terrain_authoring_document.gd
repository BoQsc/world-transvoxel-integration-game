@tool
extends Resource
class_name WtTerrainAuthoringDocument

const EditOperation := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd")
const EditBatch := preload("res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd")
const IMPLEMENTATION := "tqp53_authoring_document_v1"

@export var document_id: StringName = &"terrain_authoring_draft"
@export var mode: EditOperation.Mode = EditOperation.Mode.CARVE
@export var brush_shape: EditOperation.BrushShape = EditOperation.BrushShape.SPHERE
@export var center: Vector3 = Vector3.ZERO
@export_range(0.01, 1024.0, 0.01, "suffix:m") var radius: float = 2.0
@export_range(0.0, 64.0, 0.01, "suffix:m") var smooth_radius: float = 0.0
@export var box_extents: Vector3 = Vector3.ONE * 2.0
@export_range(1, 65535, 1) var material_id: int = 2
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0
@export var density_value: float = 1.0
@export var material_palette: Array[int] = [1, 2, 3, 4, 5, 7, 8, 10]
@export var preview_enabled: bool = true
@export var draft_revision: int = 1


func create_operation() -> Resource:
	var operation = EditOperation.new()
	operation.mode = mode
	operation.brush_shape = brush_shape
	operation.center = center
	operation.radius = radius
	operation.smooth_radius = smooth_radius
	operation.box_extents = box_extents
	operation.material_id = material_id
	operation.strength = strength
	operation.density_value = density_value
	return operation


func create_batch(batch_id: int = 0) -> Resource:
	var batch = EditBatch.new()
	batch.batch_id = batch_id if batch_id > 0 else draft_revision
	batch.add_operation(create_operation())
	return batch


func get_validation_error() -> String:
	if document_id.is_empty():
		return "authoring document_id is required"
	if not material_palette.has(material_id):
		return "material_id must be present in material_palette"
	return str(create_operation().call("get_validation_error"))


func is_valid() -> bool:
	return get_validation_error().is_empty()


func apply_dictionary(values: Dictionary) -> bool:
	var allowed := [
		"document_id", "mode", "brush_shape", "center", "radius", "smooth_radius",
		"box_extents", "material_id", "strength", "density_value", "material_palette",
		"preview_enabled", "draft_revision",
	]
	for key in values:
		if str(key) in allowed:
			set(str(key), _decode_value(str(key), values[key]))
	emit_changed()
	return is_valid()


func to_dictionary() -> Dictionary:
	return {
		"document_id": str(document_id),
		"mode": mode,
		"mode_name": str(create_operation().call("get_mode_name")),
		"brush_shape": brush_shape,
		"brush_shape_name": str(create_operation().call("get_brush_shape_name")),
		"center": [center.x, center.y, center.z],
		"radius": radius,
		"smooth_radius": smooth_radius,
		"box_extents": [box_extents.x, box_extents.y, box_extents.z],
		"material_id": material_id,
		"strength": strength,
		"density_value": density_value,
		"material_palette": material_palette.duplicate(),
		"preview_enabled": preview_enabled,
		"draft_revision": draft_revision,
		"valid": is_valid(),
		"validation_error": get_validation_error(),
		"implementation": IMPLEMENTATION,
	}


func import_json(path: String) -> bool:
	if not path.begins_with("res://") and not path.begins_with("user://"):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return false
	return apply_dictionary(Dictionary(parsed))


func _decode_value(key: String, value):
	if key == "center" or key == "box_extents":
		if value is Array and value.size() == 3:
			return Vector3(float(value[0]), float(value[1]), float(value[2]))
	if key == "material_palette":
		var result: Array[int] = []
		if value is Array:
			for item in value:
				result.append(int(item))
		return result
	return value

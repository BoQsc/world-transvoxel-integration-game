@tool
extends Resource
class_name WtTerrainEditOperation

enum Mode { CARVE, CONSTRUCT, FILL, PAINT, RESTORE_TO_BASE, PLACE_VOLUME }
enum BrushShape { SPHERE, BOX, CAPSULE, PLANE }

@export var mode: Mode = Mode.CARVE
@export var brush_shape: BrushShape = BrushShape.SPHERE
@export var center: Vector3 = Vector3.ZERO
@export_range(0.01, 1024.0, 0.01, "suffix:m") var radius: float = 1.0
@export_range(0.0, 64.0, 0.01, "suffix:m") var smooth_radius: float = 0.0
@export var box_extents: Vector3 = Vector3.ONE
@export_range(0, 65535, 1) var material_id: int = 1
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0
@export var density_value: float = 1.0
@export var author_id: int = 0
@export var command_id: int = 0


func get_mode_name() -> StringName:
	match mode:
		Mode.CARVE:
			return &"carve"
		Mode.CONSTRUCT:
			return &"construct"
		Mode.FILL:
			return &"fill"
		Mode.PAINT:
			return &"paint"
		Mode.RESTORE_TO_BASE:
			return &"restore_to_base"
		Mode.PLACE_VOLUME:
			return &"place_volume"
		_:
			return &"unknown"


func get_brush_shape_name() -> StringName:
	match brush_shape:
		BrushShape.SPHERE:
			return &"sphere"
		BrushShape.BOX:
			return &"box"
		BrushShape.CAPSULE:
			return &"capsule"
		BrushShape.PLANE:
			return &"plane"
		_:
			return &"unknown"


func requires_material() -> bool:
	return mode == Mode.CONSTRUCT or mode == Mode.FILL or mode == Mode.PAINT or mode == Mode.PLACE_VOLUME


func is_restore_to_base() -> bool:
	return mode == Mode.RESTORE_TO_BASE


func is_valid() -> bool:
	return get_validation_error().is_empty()


func get_validation_error() -> String:
	if get_mode_name() == &"unknown":
		return "edit operation mode is invalid"
	if get_brush_shape_name() == &"unknown":
		return "edit operation brush shape is invalid"
	if radius <= 0.0:
		return "edit operation radius must be positive"
	if is_nan(smooth_radius) or is_inf(smooth_radius) or smooth_radius < 0.0:
		return "edit operation smooth_radius must be finite and nonnegative"
	if smooth_radius > 0.0:
		if brush_shape != BrushShape.SPHERE:
			return "smooth SDF operations currently require a sphere brush"
		if mode != Mode.CARVE and mode != Mode.CONSTRUCT and mode != Mode.FILL:
			return "smooth_radius is supported only for carve, construct, and fill"
	if strength <= 0.0 or strength > 1.0:
		return "edit operation strength must be in the range (0, 1]"
	if is_nan(density_value) or is_inf(density_value):
		return "edit operation density_value must be finite"
	if mode != Mode.RESTORE_TO_BASE and density_value == 0.0:
		return "non-restore edit operation density_value must not be zero"
	if requires_material() and material_id <= 0:
		return "construct, fill, paint, and volume placement operations require a positive material_id"
	if brush_shape == BrushShape.BOX or brush_shape == BrushShape.CAPSULE:
		if box_extents.x <= 0.0 or box_extents.y <= 0.0 or box_extents.z <= 0.0:
			return "box and capsule operations require positive box_extents"
	if brush_shape == BrushShape.PLANE:
		if box_extents.x <= 0.0 or box_extents.z <= 0.0:
			return "plane operations require positive horizontal box_extents"
	return ""


func estimate_affected_aabb() -> AABB:
	var half_size := Vector3.ONE * radius
	if smooth_radius > 0.0:
		half_size += Vector3.ONE * smooth_radius
	match brush_shape:
		BrushShape.BOX:
			half_size = box_extents.abs()
		BrushShape.CAPSULE:
			half_size = Vector3(radius, absf(box_extents.y) + radius, radius)
		BrushShape.PLANE:
			half_size = Vector3(absf(box_extents.x), radius, absf(box_extents.z))
	return AABB(center - half_size, half_size * 2.0)


func to_bridge_command() -> Dictionary:
	var affected := estimate_affected_aabb()
	return {
		"schema_version": 1,
		"operation": str(get_mode_name()),
		"brush_shape": str(get_brush_shape_name()),
		"center": center,
		"radius": radius,
		"smooth_radius": smooth_radius,
		"box_extents": box_extents,
		"material_id": material_id,
		"strength": strength,
		"density_value": density_value,
		"author_id": author_id,
		"command_id": command_id,
		"affected_aabb": affected,
		"implementation": "resource_semantics_only",
	}

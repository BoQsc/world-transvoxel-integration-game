@tool
extends Resource
class_name WtTerrainMaterialProfile

const TEXTURE_FORMAT := "RGBA8"
const TEXTURE_BYTES_PER_PIXEL := 4
const MAX_STANDARD_TEXTURE_BYTES := 4 * 1024
const IMPLEMENTATION := "terrain_material_profile_contract_v1"

@export var profile_id: StringName = &"debug_checker_palette"
@export_range(2, 64, 1) var texture_resolution: int = 16
@export var shader_mode: StringName = &"uv2_material_id_checker"
@export var material_ids: Array[int] = [1, 2, 3, 4, 7]
@export var triplanar_projection: bool = true
@export var debug_view_enabled: bool = true


func get_contract_summary() -> Dictionary:
	var ids := _material_ids()
	return {
		"profile_id": str(profile_id),
		"texture_resolution": texture_resolution,
		"texture_format": TEXTURE_FORMAT,
		"texture_bytes": texture_resolution * texture_resolution * TEXTURE_BYTES_PER_PIXEL,
		"shader_mode": str(shader_mode),
		"material_count": material_ids.size(),
		"material_ids": ids,
		"material_ids_csv": _material_ids_csv(ids),
		"triplanar_projection": triplanar_projection,
		"debug_view_enabled": debug_view_enabled,
		"deterministic_palette": true,
		"small_texture_budget_bytes": MAX_STANDARD_TEXTURE_BYTES,
		"implementation": IMPLEMENTATION,
	}


func _material_ids() -> Array[int]:
	var ids: Array[int] = []
	for id in material_ids:
		ids.append(int(id))
	return ids


func _material_ids_csv(ids: Array[int]) -> String:
	var strings := PackedStringArray()
	for id in ids:
		strings.append(str(id))
	return ",".join(strings)

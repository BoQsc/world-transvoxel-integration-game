@tool
extends Resource
class_name WtTerrainMaterialProfile

const TEXTURE_FORMAT := "RGBA8"
const TEXTURE_BYTES_PER_PIXEL := 4
const MAX_STANDARD_TEXTURE_BYTES := 4 * 1024
const IMPLEMENTATION := "terrain_material_profile_contract_v1"
const PRODUCTION_IMPLEMENTATION := "terrain_production_material_texture_array_primary_material_pipeline_v2"
const DEFAULT_STANDARD_TEXTURE_RESOLUTION := 512

@export var profile_id: StringName = &"debug_checker_palette"
@export_range(2, 64, 1) var texture_resolution: int = 16
@export var shader_mode: StringName = &"uv2_material_id_checker"
@export var material_ids: Array[int] = [1, 2, 3, 4, 5, 7, 8]
@export var triplanar_projection: bool = true
@export var debug_view_enabled: bool = true
@export_range(16, 1024, 1) var standard_texture_resolution: int = DEFAULT_STANDARD_TEXTURE_RESOLUTION
@export var production_texture_slots: Array[StringName] = [&"albedo", &"normal", &"roughness_orm"]
@export var sample_material_names: Array[StringName] = [
	&"deep_stone",
	&"grass",
	&"gravel",
	&"sand",
	&"snow",
	&"mid_rock",
	&"ore_patch",
]
@export var mapping_policy: StringName = &"world_space_triplanar_ready"
@export var blending_policy: StringName = &"material_id_primary_slope_ready"
@export var texture_import_policy: StringName = &"mipmapped_vram_compressed_normal_aware"


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
		"production_texture_pipeline": true,
		"production_implementation": PRODUCTION_IMPLEMENTATION,
		"production_texture_slots": _string_names(production_texture_slots),
		"production_texture_slot_count": production_texture_slots.size(),
		"sample_material_names": _string_names(sample_material_names),
		"sample_material_count": sample_material_names.size(),
		"standard_texture_resolution": standard_texture_resolution,
		"production_texture_budget_bytes": _production_texture_budget_bytes(),
		"mapping_policy": str(mapping_policy),
		"blending_policy": str(blending_policy),
		"texture_import_policy": str(texture_import_policy),
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


func _string_names(values: Array[StringName]) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(str(value))
	return result


func _production_texture_budget_bytes() -> int:
	return standard_texture_resolution * standard_texture_resolution * TEXTURE_BYTES_PER_PIXEL * \
			production_texture_slots.size() * sample_material_names.size()

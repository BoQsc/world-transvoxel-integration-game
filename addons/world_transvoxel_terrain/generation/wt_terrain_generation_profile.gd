@tool
extends Resource
class_name WtTerrainGenerationProfile

enum SourceMode {
	FLAT,
	DETERMINISTIC_REFERENCE,
	BAKED_WORLD,
}

const UNDERGROUND_MODEL := "density_volume_vertical_strata_v1"
const UNDERGROUND_STRATA_MATERIAL_IDS: Array[int] = [1, 7, 4]
const UNDERGROUND_DEPTH_BANDS := "deep>=8:1,mid>=3:7,shallow>=1:4"

@export var source_mode: SourceMode = SourceMode.DETERMINISTIC_REFERENCE
@export var seed: int = 1
@export var default_solid_material: int = 1
@export var supports_underground_volume: bool = true
@export var profile_id: StringName = &"deterministic_reference"
@export_range(1, 4096, 1) var world_chunk_count_x: int = 128
@export_range(1, 4096, 1) var world_chunk_count_z: int = 128
@export var source_revision: int = 190001


func get_contract_summary() -> Dictionary:
	return {
		"profile_id": str(profile_id),
		"source_mode": SourceMode.keys()[source_mode],
		"seed": seed,
		"default_solid_material": default_solid_material,
		"supports_underground_volume": supports_underground_volume,
		"underground_model": UNDERGROUND_MODEL,
		"underground_strata_material_ids": UNDERGROUND_STRATA_MATERIAL_IDS,
		"underground_depth_bands": UNDERGROUND_DEPTH_BANDS,
		"flat_world_underground_contract": "same density/material volume semantics as procedural profiles",
		"world_chunk_count_x": world_chunk_count_x,
		"world_chunk_count_z": world_chunk_count_z,
		"source_revision": source_revision,
	}

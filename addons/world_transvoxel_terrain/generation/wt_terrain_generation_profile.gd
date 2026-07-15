@tool
extends Resource
class_name WtTerrainGenerationProfile

enum SourceMode {
	FLAT,
	DETERMINISTIC_REFERENCE,
	BAKED_WORLD,
}

const UNDERGROUND_MODEL := "density_volume_vertical_strata_v1"
const MATERIAL_STRATA_MODEL := "standard_density_depth_material_strata_v1"
const MATERIAL_PALETTE_VERSION := "world_transvoxel_material_palette_v1"
const SURFACE_BIOME_MODEL := "deterministic_macro_surface_biomes_v1"
const UNDERGROUND_PATCH_MODEL := "deterministic_deep_ore_patches_v1"
const STANDARD_MATERIAL_IDS: Array[int] = [1, 2, 3, 4, 5, 7, 8]
const SURFACE_MATERIAL_IDS: Array[int] = [2, 3, 4, 5]
const UNDERGROUND_STRATA_MATERIAL_IDS: Array[int] = [1, 8]
const UNDERGROUND_DEPTH_BANDS := "surface_cover<8:2|3|4|5,deep>=8:1,ore>=12:8"
const STANDARD_MATERIAL_MEANINGS := {
	1: "deep_stone",
	2: "grass_surface_biome",
	3: "gravel_surface_biome",
	4: "shallow_surface_sand_or_player_fill",
	5: "snow_surface_biome",
	7: "reserved_mid_depth_rock",
	8: "deep_ore_patch",
}

@export var source_mode: SourceMode = SourceMode.DETERMINISTIC_REFERENCE
@export var seed: int = 1
@export var default_solid_material: int = 1
@export var supports_underground_volume: bool = true
@export var profile_id: StringName = &"deterministic_reference"
@export_range(1, 4096, 1) var world_chunk_count_x: int = 128
@export_range(1, 4096, 1) var world_chunk_count_y: int = 8
@export_range(-4096, 4096, 1) var world_chunk_origin_y: int = 0
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
		"material_strata_model": MATERIAL_STRATA_MODEL,
		"material_palette_version": MATERIAL_PALETTE_VERSION,
		"surface_biome_model": SURFACE_BIOME_MODEL,
		"underground_patch_model": UNDERGROUND_PATCH_MODEL,
		"standard_material_ids": STANDARD_MATERIAL_IDS,
		"surface_material_ids": SURFACE_MATERIAL_IDS,
		"underground_strata_material_ids": UNDERGROUND_STRATA_MATERIAL_IDS,
		"underground_depth_bands": UNDERGROUND_DEPTH_BANDS,
		"standard_material_meanings": STANDARD_MATERIAL_MEANINGS,
		"flat_world_underground_contract": "same density/material volume semantics as procedural profiles",
		"world_chunk_count_x": world_chunk_count_x,
		"world_chunk_count_y": world_chunk_count_y,
		"world_chunk_origin_y": world_chunk_origin_y,
		"vertical_origin_cell": world_chunk_origin_y * 16,
		"vertical_cells": world_chunk_count_y * 16,
		"world_chunk_count_z": world_chunk_count_z,
		"source_revision": source_revision,
	}

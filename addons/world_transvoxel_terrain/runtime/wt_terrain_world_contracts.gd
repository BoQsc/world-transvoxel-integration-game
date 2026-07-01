extends RefCounted
class_name WtTerrainWorldContracts

static func profile_summaries(world) -> Dictionary:
	return {
		"terrain": resource_summary(world.terrain_profile),
		"generation": resource_summary(world.generation_profile),
		"storage": resource_summary(world.storage_profile),
		"recovery": resource_summary(world.recovery_policy),
		"material": resource_summary(world.material_profile),
	}

static func hot_path_boundary_summary(world) -> Dictionary:
	return {
		"implementation": "terrain_addon_native_hot_path_boundary_v1",
		"terrain_1_0_gate": "G48",
		"normal_runtime_hot_paths": {
			"generation": _hot_path(
				"profile_descriptor_and_lifecycle_request_only",
				"WtTerrainGenerationBackend.start_backend_world"
			),
			"meshing": _hot_path(
				"no_mesh_building_loop",
				"world-transvoxel render/collision chunk resources"
			),
			"streaming": _hot_path("viewer_request_only", "WtTerrainWorld.update_viewer/remove_viewer"),
			"edit_application": _hot_path("edit_command_bridge_only", "WtTerrainEditBridge.commit_batch"),
			"storage": _hot_path(
				"snapshot_request_and_profile_descriptor_only",
				"request_world_compaction/request_world_migration"
			),
		},
		"bounded_gdscript_helpers": {
			"material_application": "addon-owned debug/material helper, not generation or meshing",
			"mesh_stats": "addon-owned validation/debug helper, not gameplay hot path",
			"runtime_metrics": "counter read and summary only",
			"edit_batch_validation": "bounded command-list validation only",
		},
		"forbidden_gdscript_runtime_roles": [
			"density_volume_cell_loop",
			"terrain_mesh_build_loop",
			"chunk_source_file_streaming_loop",
			"page_generation_loop",
			"normal_runtime_pixel_or_image_terrain_loop",
		],
		"world": world_summary(world),
		"runtime_metrics": world.get_runtime_metrics(),
	}

static func terrain_api_contract_summary(world) -> Dictionary:
	return {
		"api_name": "WtTerrainWorld",
		"api_version": 1,
		"implementation": "terrain_addon_api_contract_v1",
		"stable_groups": {
			"profiles": [
				"terrain_profile",
				"generation_profile",
				"storage_profile",
				"recovery_policy",
				"material_profile",
				"get_profile_summaries",
			],
			"lifecycle": [
				"start_world",
				"stop_world",
				"is_world_running",
				"get_world_state_name",
				"get_world_revision",
				"get_world_source_revision",
				"get_world_page_count",
			],
			"streaming": ["update_viewer", "remove_viewer", "query_chunk_state"],
			"editing": [
				"submit_edit_batch",
				"get_last_edit_submission_summary",
				"request_authoritative_sample",
				"request_authoritative_samples",
			],
			"storage": [
				"request_world_compaction",
				"request_world_migration",
				"world_snapshot_ready",
				"world_snapshot_failed",
			],
			"telemetry": ["get_runtime_metrics", "is_cold_idle", "get_cold_idle_summary"],
			"debug": [
				"get_debug_snapshot",
				"get_hot_path_boundary_summary",
				"get_terrain_api_contract_summary",
			],
		},
		"profile_summaries": profile_summaries(world),
		"hot_path_boundary": hot_path_boundary_summary(world),
		"world": world_summary(world),
	}

static func contract_summary(world) -> Dictionary:
	return {
		"terrain_world": "WtTerrainWorld",
		"has_terrain_profile": world.terrain_profile != null,
		"has_generation_profile": world.generation_profile != null,
		"has_storage_profile": world.storage_profile != null,
		"has_recovery_policy": world.recovery_policy != null,
		"has_material_profile": world.material_profile != null,
		"dependency": world.get_dependency_status(),
		"bridge": world.get_bridge_status(),
		"backend_world_state": world.get_backend_world_state_name(),
		"cold_idle": world.is_cold_idle(),
		"terrain_api": terrain_api_contract_summary(world),
		"hot_path_boundary": hot_path_boundary_summary(world),
		"implementation": "a4_phase4_reference_profile_runtime_cold_idle",
		"phase_history": ["a4_phase1_resource_semantics_only", "terrain_world_lifecycle"],
	}

static func a4_phase1_summary(world) -> Dictionary:
	return {
		"terrain_profile": resource_summary(world.terrain_profile),
		"generation_profile": resource_summary(world.generation_profile),
		"storage_profile": resource_summary(world.storage_profile),
		"recovery_policy": resource_summary(world.recovery_policy),
		"material_profile": resource_summary(world.material_profile),
		"backend_identity": world.get_backend_identity(),
		"implementation": "resource_semantics_only",
	}

static func a4_phase3_summary(world) -> Dictionary:
	return {
		"terrain_profile": resource_summary(world.terrain_profile),
		"storage_profile": resource_summary(world.storage_profile),
		"backend_identity": world.get_backend_identity(),
		"backend_world_state": world.get_backend_world_state_name(),
		"backend_world_revision": world.get_backend_world_revision(),
		"last_error": world._last_error,
		"last_edit_submission": world._last_edit_submission_summary,
		"implementation": "terrain_world_lifecycle",
	}

static func a4_phase4_summary(world) -> Dictionary:
	return {
		"terrain_profile": resource_summary(world.terrain_profile),
		"storage_profile": resource_summary(world.storage_profile),
		"backend_world_state": world.get_backend_world_state_name(),
		"backend_world_revision": world.get_backend_world_revision(),
		"runtime_metrics": world.get_runtime_metrics(),
		"cold_idle": world.get_cold_idle_summary(),
		"implementation": "reference_profile_runtime_cold_idle",
	}

static func resource_summary(resource: Resource) -> Dictionary:
	if resource == null:
		return {"assigned": false}
	if resource.has_method("get_contract_summary"):
		var summary := Dictionary(resource.call("get_contract_summary"))
		summary["assigned"] = true
		return summary
	return {"assigned": true, "class": resource.get_class()}

static func world_summary(world) -> Dictionary:
	return {
		"state": world.get_world_state_name(),
		"running": world.is_world_running(),
		"revision": world.get_world_revision(),
		"source_revision": world.get_world_source_revision(),
		"page_count": world.get_world_page_count(),
	}

static func _hot_path(gdscript_role: String, entrypoint: String) -> Dictionary:
	return {
		"owner": "world_transvoxel_native_backend",
		"gdscript_role": gdscript_role,
		"entrypoint": entrypoint,
	}

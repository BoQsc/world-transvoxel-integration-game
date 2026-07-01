@tool
extends Resource
class_name WtTerrainStorageProfile

@export var profile_id: StringName = &"default_local"
@export var world_manifest_path: String = "user://worlds/default/world.wtworld"
@export var object_root_path: String = "user://worlds/default"
@export var edit_journal_path: String = "user://worlds/default/world.wtedit"
@export var snapshot_directory: String = "user://worlds/default/snapshots"
@export var persist_edits: bool = true
@export var allow_res_paths_for_test_fixtures: bool = false
@export_range(1, 255, 1) var journal_format_version: int = 1


func is_valid() -> bool:
	return get_validation_error().is_empty()


func get_validation_error() -> String:
	if str(profile_id).is_empty():
		return "storage profile_id must not be empty"
	if world_manifest_path.is_empty():
		return "world_manifest_path must not be empty"
	if object_root_path.is_empty():
		return "object_root_path must not be empty"
	if edit_journal_path.is_empty():
		return "edit_journal_path must not be empty"
	if snapshot_directory.is_empty():
		return "snapshot_directory must not be empty"
	if _is_read_only_resource_path(world_manifest_path):
		return "world_manifest_path must not use res://"
	if _is_read_only_resource_path(object_root_path):
		return "object_root_path must not use res://"
	if _is_read_only_resource_path(edit_journal_path):
		return "edit_journal_path must not use res://"
	if _is_read_only_resource_path(snapshot_directory):
		return "snapshot_directory must not use res://"
	if journal_format_version != 1:
		return "only journal format version 1 is currently defined"
	return ""


func get_contract_summary() -> Dictionary:
	return {
		"profile_id": str(profile_id),
		"world_manifest_path": world_manifest_path,
		"object_root_path": object_root_path,
		"edit_journal_path": edit_journal_path,
		"snapshot_directory": snapshot_directory,
		"persist_edits": persist_edits,
		"allow_res_paths_for_test_fixtures": allow_res_paths_for_test_fixtures,
		"journal_format_version": journal_format_version,
		"valid": is_valid(),
		"implementation": "resource_semantics_only",
	}


func _is_read_only_resource_path(path: String) -> bool:
	if allow_res_paths_for_test_fixtures:
		return false
	return path.begins_with("res://")

@tool
extends Resource
class_name WtTerrainRecoveryPolicy

const PRE_EDIT_SNAPSHOT := &"pre_edit_snapshot"
const BASE_TERRAIN := &"base_terrain"

@export var enabled_targets: Array[StringName] = [PRE_EDIT_SNAPSHOT, BASE_TERRAIN]
@export var automatic_timed_regeneration_enabled: bool = false
@export var smoothing_enabled: bool = false
@export var structural_collapse_enabled: bool = false
@export var fluid_equilibrium_enabled: bool = false


func allows_pre_edit_snapshot() -> bool:
	return enabled_targets.has(PRE_EDIT_SNAPSHOT)


func allows_restore_to_base() -> bool:
	return enabled_targets.has(BASE_TERRAIN)


func is_cold_idle_default() -> bool:
	return (
		not automatic_timed_regeneration_enabled
		and not smoothing_enabled
		and not structural_collapse_enabled
		and not fluid_equilibrium_enabled
	)


func is_valid() -> bool:
	return get_validation_error().is_empty()


func get_validation_error() -> String:
	for target in enabled_targets:
		if target != PRE_EDIT_SNAPSHOT and target != BASE_TERRAIN:
			return "unknown recovery target: %s" % str(target)
	if enabled_targets.is_empty():
		return "at least one recovery target must be enabled"
	return ""


func get_contract_summary() -> Dictionary:
	return {
		"enabled_targets": enabled_targets,
		"allows_pre_edit_snapshot": allows_pre_edit_snapshot(),
		"allows_restore_to_base": allows_restore_to_base(),
		"automatic_timed_regeneration_enabled": automatic_timed_regeneration_enabled,
		"smoothing_enabled": smoothing_enabled,
		"structural_collapse_enabled": structural_collapse_enabled,
		"fluid_equilibrium_enabled": fluid_equilibrium_enabled,
		"cold_idle_default": is_cold_idle_default(),
		"valid": is_valid(),
		"implementation": "manual_recovery_resource_semantics_only",
	}

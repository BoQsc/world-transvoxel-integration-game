@tool
extends RefCounted
class_name WtTerrainDebugSnapshot

const IMPLEMENTATION := "debug_snapshot_contract"


static func capture(terrain_world: Node) -> Dictionary:
	var metrics := _call_dictionary(terrain_world, "get_runtime_metrics")
	var cold_idle := _call_dictionary(terrain_world, "get_cold_idle_summary")
	return {
		"world": _world_summary(terrain_world),
		"terrain_profile": _resource_summary(_get_property(terrain_world, "terrain_profile")),
		"generation_profile": _resource_summary(_get_property(terrain_world, "generation_profile")),
		"storage_profile": _resource_summary(_get_property(terrain_world, "storage_profile")),
		"recovery_policy": _resource_summary(_get_property(terrain_world, "recovery_policy")),
		"budget": _budget_summary(metrics, cold_idle),
		"collision": _collision_summary(metrics),
		"streaming": _streaming_summary(metrics),
		"edit": _edit_summary(terrain_world, metrics),
		"material": _material_summary(terrain_world),
		"implementation": IMPLEMENTATION,
	}


static func _world_summary(terrain_world: Node) -> Dictionary:
	return {
		"assigned": terrain_world != null,
		"backend_state": _call_string(terrain_world, "get_backend_world_state_name", "stopped"),
		"backend_revision": _call_int(terrain_world, "get_backend_world_revision", 0),
		"backend_running": _call_bool(terrain_world, "is_backend_world_running", false),
		"last_error": _call_string(terrain_world, "get_last_error", "ok"),
	}


static func _budget_summary(metrics: Dictionary, cold_idle: Dictionary) -> Dictionary:
	return {
		"world_running": bool(metrics.get("world_running", false)),
		"cold_idle": bool(cold_idle.get("cold_idle", false)),
		"queued_render": int(metrics.get("queued_render", 0)),
		"queued_collision": int(metrics.get("queued_collision", 0)),
		"pending_chunk_retirements": int(metrics.get("pending_chunk_retirements", 0)),
		"render_resources": int(metrics.get("render_resources", 0)),
		"collision_resources": int(metrics.get("collision_resources", 0)),
	}


static func _collision_summary(metrics: Dictionary) -> Dictionary:
	return {
		"queued_collision": int(metrics.get("queued_collision", 0)),
		"collision_resources": int(metrics.get("collision_resources", 0)),
		"fully_ready_chunk_records": int(metrics.get("fully_ready_chunk_records", 0)),
		"active_chunk_records": int(metrics.get("active_chunk_records", 0)),
	}


static func _streaming_summary(metrics: Dictionary) -> Dictionary:
	return {
		"viewer_updates": int(metrics.get("viewer_updates", 0)),
		"viewer_removals": int(metrics.get("viewer_removals", 0)),
		"planned_demands": int(metrics.get("planned_demands", 0)),
		"active_chunk_records": int(metrics.get("active_chunk_records", 0)),
		"visual_ready_chunk_records": int(metrics.get("visual_ready_chunk_records", 0)),
		"fully_ready_chunk_records": int(metrics.get("fully_ready_chunk_records", 0)),
	}


static func _edit_summary(terrain_world: Node, metrics: Dictionary) -> Dictionary:
	return {
		"last_submission": _call_dictionary(terrain_world, "get_last_edit_submission_summary"),
		"edit_commits": int(metrics.get("edit_commits", 0)),
		"edit_rejections": int(metrics.get("edit_rejections", 0)),
		"edit_replacements": int(metrics.get("edit_replacements", 0)),
	}


static func _material_summary(terrain_world: Node) -> Dictionary:
	var profile := _get_property(terrain_world, "material_profile")
	if profile is Object and profile.has_method("get_contract_summary"):
		var summary := Dictionary(profile.call("get_contract_summary"))
		summary["configured"] = true
		summary["status"] = "material_profile_configured"
		return summary
	return {"configured": false, "status": "material_profile_not_assigned"}


static func _resource_summary(resource: Variant) -> Dictionary:
	if resource == null:
		return {"assigned": false}
	if resource is Object and resource.has_method("get_contract_summary"):
		var summary := Dictionary(resource.call("get_contract_summary"))
		summary["assigned"] = true
		return summary
	return {
		"assigned": true,
		"class": resource.get_class() if resource is Object else typeof(resource),
	}


static func _get_property(object: Object, property_name: String) -> Variant:
	if object == null:
		return null
	return object.get(property_name)


static func _call_dictionary(object: Object, method_name: String) -> Dictionary:
	if object == null or not object.has_method(method_name):
		return {}
	return Dictionary(object.call(method_name))


static func _call_string(object: Object, method_name: String, fallback: String) -> String:
	if object == null or not object.has_method(method_name):
		return fallback
	return str(object.call(method_name))


static func _call_int(object: Object, method_name: String, fallback: int) -> int:
	if object == null or not object.has_method(method_name):
		return fallback
	return int(object.call(method_name))


static func _call_bool(object: Object, method_name: String, fallback: bool) -> bool:
	if object == null or not object.has_method(method_name):
		return fallback
	return bool(object.call(method_name))

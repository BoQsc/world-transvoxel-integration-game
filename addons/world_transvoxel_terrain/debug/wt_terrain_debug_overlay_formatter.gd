@tool
extends RefCounted
class_name WtTerrainDebugOverlayFormatter

const IMPLEMENTATION := "debug_overlay_category_rendering"
const CATEGORY_ORDER := [
	"world",
	"terrain_profile",
	"generation_profile",
	"storage_profile",
	"recovery_policy",
	"budget",
	"collision",
	"streaming",
	"edit",
	"material",
]

const CATEGORY_KEYS := {
	"world": ["backend_state", "backend_running", "backend_revision", "last_error"],
	"terrain_profile": [
		"profile_id",
		"horizontal_cells",
		"vertical_cells",
		"plus_y_is_up",
		"finite_closed_boundary",
	],
	"generation_profile": [
		"profile_id",
		"source_mode",
		"seed",
		"supports_underground_volume",
	],
	"storage_profile": ["profile_id", "world_manifest_path", "object_root_path"],
	"recovery_policy": ["profile_id", "restore_mode", "cold_idle_after_recovery"],
	"budget": [
		"cold_idle",
		"queued_render",
		"queued_collision",
		"pending_chunk_retirements",
		"render_resources",
		"collision_resources",
	],
	"collision": [
		"queued_collision",
		"collision_resources",
		"active_chunk_records",
		"fully_ready_chunk_records",
	],
	"streaming": [
		"viewer_updates",
		"viewer_removals",
		"planned_demands",
		"active_chunk_records",
		"visual_ready_chunk_records",
		"fully_ready_chunk_records",
	],
	"edit": ["edit_commits", "edit_rejections", "edit_replacements"],
	"material": [
		"configured",
		"status",
		"profile_id",
		"texture_resolution",
		"shader_mode",
		"material_count",
	],
}


static func format_snapshot(snapshot: Dictionary) -> String:
	var lines := [
		"World Transvoxel Terrain Reference Scene",
		"profile=%sx%s" % [
			_value(snapshot, "terrain_profile", "horizontal_cells", 0),
			_value(snapshot, "terrain_profile", "vertical_cells", 0),
		],
	]
	for category in CATEGORY_ORDER:
		lines.append("[%s]" % category)
		var details := _format_category(snapshot, category)
		for detail in details:
			lines.append(detail)
	lines.append("overlay_implementation=%s" % IMPLEMENTATION)
	return "\n".join(lines)


static func get_rendered_categories(snapshot: Dictionary) -> Array[String]:
	var categories: Array[String] = []
	for category in CATEGORY_ORDER:
		if snapshot.has(category):
			categories.append(category)
	return categories


static func _format_category(snapshot: Dictionary, category: String) -> Array[String]:
	var output: Array[String] = []
	var data := Dictionary(snapshot.get(category, {}))
	for key in CATEGORY_KEYS.get(category, []):
		output.append("%s=%s" % [key, str(data.get(key, _fallback_value(category, key)))])
	return output


static func _value(
	snapshot: Dictionary,
	category: String,
	key: String,
	fallback: Variant
) -> Variant:
	var data := Dictionary(snapshot.get(category, {}))
	return data.get(key, fallback)


static func _fallback_value(_category: String, _key: String) -> Variant:
	return "n/a"

extends RefCounted

const STAGE_COLORS := {
	"extracting": Color(0.25, 0.65, 1.0),
	"native_prepare_wait": Color(1.0, 0.85, 0.15),
	"cohort_wait": Color(1.0, 0.40, 0.12),
	"activation_queued": Color(0.85, 0.35, 1.0),
	"visible": Color(0.2, 1.0, 0.45),
	"retiring": Color(1.0, 0.2, 0.25),
}


static func collision_stage(state: RefCounted) -> String:
	var generation := int(state.call("get_generation"))
	var active := int(state.call("get_collision_generation"))
	var staged := int(state.call("get_staged_collision_generation"))
	if active > 0:
		return "live" if active == generation and staged == 0 else "live_previous"
	if staged > 0:
		return "staged"
	return "ready_no_body" if bool(state.call("is_collision_ready")) else "pending"


static func collision_color(stage: String) -> Color:
	match stage:
		"live": return Color(0.2, 1.0, 0.4)
		"live_previous": return Color(0.3, 0.8, 1.0)
		"staged": return Color(0.85, 0.35, 1.0)
		"ready_no_body": return Color(0.55, 0.65, 0.65)
		_: return Color(1.0, 0.48, 0.12)


static func stage_counts(states: Array) -> Dictionary:
	var counts := {}
	for state in states:
		var stage := str(state.get("stage", "unknown"))
		counts[stage] = int(counts.get(stage, 0)) + 1
	return counts


static func json_value(value: Variant) -> Variant:
	if value is Vector3 or value is Vector3i:
		return {"x": value.x, "y": value.y, "z": value.z}
	if value is Dictionary:
		var result := {}
		for key in value:
			result[key] = json_value(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item in value:
			result.append(json_value(item))
		return result
	return value

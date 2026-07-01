@tool
extends RefCounted
class_name WtTerrainRuntimeAudit

const METRICS_IMPLEMENTATION := "terrain_world_runtime_metrics"
const COLD_IDLE_IMPLEMENTATION := "terrain_world_cold_idle"


static func get_runtime_metrics(backend_terrain: Node) -> Dictionary:
	if backend_terrain == null or not backend_terrain.has_method("get_runtime_metrics"):
		return {
			"world_running": false,
			"implementation": METRICS_IMPLEMENTATION,
		}
	var metrics := Dictionary(backend_terrain.call("get_runtime_metrics"))
	metrics["implementation"] = METRICS_IMPLEMENTATION
	return metrics


static func is_cold_idle(metrics: Dictionary) -> bool:
	if not bool(metrics.get("world_running", false)):
		return false
	return (
		int(metrics.get("queued_render", 0)) == 0
		and int(metrics.get("queued_collision", 0)) == 0
		and int(metrics.get("pending_chunk_retirements", 0)) == 0
		and int(metrics.get("active_chunk_records", 0)) ==
			int(metrics.get("fully_ready_chunk_records", 0))
	)


static func get_cold_idle_summary(metrics: Dictionary) -> Dictionary:
	return {
		"cold_idle": is_cold_idle(metrics),
		"world_running": bool(metrics.get("world_running", false)),
		"queued_render": int(metrics.get("queued_render", 0)),
		"queued_collision": int(metrics.get("queued_collision", 0)),
		"pending_chunk_retirements": int(metrics.get("pending_chunk_retirements", 0)),
		"active_chunk_records": int(metrics.get("active_chunk_records", 0)),
		"fully_ready_chunk_records": int(metrics.get("fully_ready_chunk_records", 0)),
		"render_resources": int(metrics.get("render_resources", 0)),
		"collision_resources": int(metrics.get("collision_resources", 0)),
		"implementation": COLD_IDLE_IMPLEMENTATION,
	}

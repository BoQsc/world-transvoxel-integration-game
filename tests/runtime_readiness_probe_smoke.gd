extends SceneTree

const Probe := preload("res://scripts/wt_runtime_readiness_probe.gd")
const Trace := preload("res://scripts/wt_cpu_causal_trace.gd")

class RejectedWorld:
	extends Node
	var queries := 0
	func get_game_world_summary() -> Dictionary:
		queries += 1
		return {"gpu_resident_rejected_chunks": 1}

class VisualGate:
	extends "res://scripts/main.gd"
	var failure_message := ""
	func _fail(message: String) -> void:
		failure_message = message


func _initialize() -> void:
	var gate := VisualGate.new()
	var rejected := RejectedWorld.new()
	gate.game_world = rejected
	var ready: bool = await gate._wait_for_streaming_fly_visual_ready("regression", 1800)
	if ready or rejected.queries != 1 or not gate.failure_message.contains("publication rejection"):
		push_error("READINESS_PROBE_FAIL: permanent rejection did not fail immediately")
		gate.free()
		rejected.free()
		quit(1)
		return
	gate.free()
	rejected.free()
	var ray := Probe.ray_chunks(Vector3(560.0, 75.6, 560.0), Vector3(562.6, -20.3, 560.0))
	if not bool(ray.complete) or not ray.chunks.has(Vector3i(35, 2, 35)) \
			or not ray.chunks.has(Vector3i(35, 2, 34)):
		push_error("READINESS_PROBE_FAIL: ray face coverage")
		quit(1)
		return
	var terrain: Node = ClassDB.instantiate(&"WorldTransvoxelTerrain")
	var absent := Probe.chunk_snapshot(terrain, Vector3i(999, 999, 999), 0)
	var trace := Trace.new()
	trace._terrain_world = terrain
	var trace_absent := trace._target_snapshot()
	for lod in [-1, 0, 21]:
		var inspection: Dictionary = terrain.call("inspect_gpu_resident_publication", Vector3i.ZERO, lod)
		if bool(inspection.get("built", true)) or not bool(inspection.get("read_only", false)):
			push_error("READINESS_PROBE_FAIL: disabled or invalid publication inspection")
			terrain.free()
			quit(1)
			return
	terrain.free()
	if bool(absent.is_present) or bool(trace_absent.present):
		push_error("READINESS_PROBE_FAIL: non-null absent snapshot reported as present")
		quit(1)
		return
	var serialized: Dictionary = Probe._json_value({
		"ray": [Vector3i(-1, 2, 3), Vector3(1.5, -2.25, 3.0)], "hit": null,
	})
	if serialized.ray[0].x != -1 or serialized.ray[1].y != -2.25 \
			or serialized.hit != null:
		push_error("READINESS_PROBE_FAIL: coordinate serialization")
		quit(1)
		return
	var negative := Probe.ray_chunks(Vector3(-1, -1, -1), Vector3(-17, -1, -1))
	if not negative.chunks.has(Vector3i(-1, -1, -1)) \
			or not negative.chunks.has(Vector3i(-2, -1, -1)):
		push_error("READINESS_PROBE_FAIL: negative coordinates")
		quit(1)
		return
	if bool(Probe.ray_chunks(Vector3.ZERO, Vector3.ONE * 10000).complete):
		push_error("READINESS_PROBE_FAIL: capacity")
		quit(1)
		return
	var probe := Probe.new()
	if probe.publication_inspection_enabled:
		push_error("READINESS_PROBE_FAIL: publication inspection must be opt-in")
		quit(1)
		return
	probe.samples.resize(Probe.CAPACITY)
	probe.capture("bounded", 0, null, null, null)
	if probe.dropped_samples != 1:
		push_error("READINESS_PROBE_FAIL: snapshot bound")
		quit(1)
		return
	print("READINESS_PROBE_PASS ray_face=1 negative_coordinates=1 bounded=1 absent_state=1 serialization=1")
	quit(0)

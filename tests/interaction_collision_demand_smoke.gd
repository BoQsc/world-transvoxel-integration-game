extends SceneTree

const Demand := preload("res://addons/world_transvoxel_gameworld/wt_interaction_collision_demand.gd")
const GameWorld := preload("res://addons/world_transvoxel_gameworld/wt_game_world_node.gd")
const Player := preload("res://scripts/wt_production_player.gd")

class MockScene:
	extends Node
	var live := {}
	var updates := 0
	func update_runtime_collision_viewer(id: int, _revision: int, position: Vector3, radius: int) -> bool:
		live[id] = {"position": position, "radius": radius}
		updates += 1
		return true
	func remove_runtime_collision_viewer(id: int, _revision: int) -> bool:
		return live.erase(id)

func _initialize() -> void:
	call_deferred("_run")

func _chunk(position: Vector3) -> Vector3i:
	return Vector3i((position / Demand.CHUNK_SIZE).floor())

func _run() -> void:
	var checks := 0
	for origin in [Vector3(0.01, 15.99, -0.01), Vector3(560, 75.6, 560), Vector3(-31.99, -16, -48)]:
		for direction in [Vector3.DOWN, Vector3.RIGHT, Vector3(1, 1, 1).normalized(), Vector3(-1, -2, 3).normalized()]:
			var positions := Demand.centers(origin, direction, 96.0)
			if positions.size() != Demand.MAXIMUM_VIEWERS:
				return _fail("96-unit ray was not bounded to two local viewers")
			for index in range(385):
				var key := _chunk(origin + direction * (float(index) * 0.25))
				var covered := false
				for center in positions:
					var offset := key - _chunk(center)
					covered = covered or offset.length_squared() <= Demand.RADIUS_CHUNKS * Demand.RADIUS_CHUNKS
				if not covered:
					return _fail("interaction ray has a collision-demand hole")
				checks += 1
	if not Demand.centers(Vector3.ZERO, Vector3.DOWN, 97.0).is_empty():
		return _fail("oversized ray silently truncated")
	var world := GameWorld.new()
	var scene := MockScene.new()
	var player := Player.new()
	var camera := Camera3D.new()
	camera.name = "FirstPersonCamera"
	player.add_child(camera)
	root.add_child(world)
	root.add_child(scene)
	root.add_child(player)
	var priority_points: Array = player.call(
		"_interaction_priority_points", Vector3(560, 75.6, 560), Vector3.DOWN, 96.0
	)
	var priority_keys: Array = world.call("_foreground_chunk_keys", priority_points)
	if priority_points.size() != 13 or priority_keys.size() != 7 \
			or priority_keys.front() != Vector3i(35, 4, 35) \
			or priority_keys.back() != Vector3i(35, -2, 35):
		return _fail("cursor priority did not cover the bounded interaction ray")
	world.set("_reference_scene", scene)
	world.set("_player", player)
	if world.player_interaction_collision_invoker_enabled or \
			not world.call("_update_player_interaction_collision_invoker", false) or scene.updates != 0:
		return _fail("optional ray demand changed default collision behavior")
	world.player_interaction_collision_invoker_enabled = true
	if not world.call("_update_player_interaction_collision_invoker", false) or scene.live.size() != 2:
		return _fail("ray viewers were not submitted")
	var updates := scene.updates
	if not world.call("_update_player_interaction_collision_invoker", false) or scene.updates != updates:
		return _fail("stationary ray resubmitted unchanged demand")
	player.interaction_distance = 16.0
	if not world.call("_update_player_interaction_collision_invoker", false) or scene.live.size() != 1:
		return _fail("shortening the ray retained distant collision demand")
	world.player_interaction_collision_invoker_enabled = false
	if not world.call("_update_player_interaction_collision_invoker", false) or not scene.live.is_empty():
		return _fail("disabled interaction demand was not retired")
	player.game_world = world
	world.runtime_gpu_resident_render_candidate_enabled = true
	var target: Dictionary = player.call("_render_mesh_interaction_target", Vector3.ZERO, Vector3.DOWN, 96.0)
	if target.get("reason") != "raycast_miss_gpu_collision_pending" or target.get("fallback_triangles_scanned", -1) != 0:
		return _fail("GPU interaction consumed CPU visual triangle fallback")
	player.queue_free()
	world.queue_free()
	scene.queue_free()
	await process_frame
	print("INTERACTION_COLLISION_DEMAND_PASS samples=%d bounded=2 coalesced=1 retired=1 priority_ray=7 gpu_cpu_visual_scan=0" % checks)
	quit(0)

func _fail(message: String) -> void:
	push_error("INTERACTION_COLLISION_DEMAND_FAIL: " + message)
	quit(1)

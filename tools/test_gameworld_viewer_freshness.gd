extends SceneTree

const GameWorldNode := preload(
	"res://addons/world_transvoxel_gameworld/wt_game_world_node.gd"
)
const GenerationProfile := preload(
	"res://addons/world_transvoxel_terrain/generation/wt_terrain_generation_profile.gd"
)


class FakeTerrainWorld:
	extends Node

	var metrics := {
		"scheduler_queued_jobs": 8,
		"non_retiring_chunk_records": 8,
		"non_retiring_visual_ready_chunk_records": 0,
	}

	func get_runtime_metrics() -> Dictionary:
		return metrics.duplicate(true)


class FakeRuntimeScene:
	extends Node

	var terrain_world: Node
	var viewer_updates: Array[Dictionary] = []
	var collision_viewer_updates: Array[Dictionary] = []
	var update_order: Array[String] = []

	func _init(value: Node) -> void:
		terrain_world = value

	func get_terrain_world() -> Node:
		return terrain_world

	func update_runtime_viewer(
		viewer_id: int,
		revision: int,
		position: Vector3,
		radius_chunks: int,
		maximum_lod: int
	) -> bool:
		update_order.append("visual")
		viewer_updates.append({
			"viewer_id": viewer_id,
			"revision": revision,
			"position": position,
			"radius_chunks": radius_chunks,
			"maximum_lod": maximum_lod,
		})
		return true

	func update_runtime_collision_viewer(
		viewer_id: int,
		revision: int,
		position: Vector3,
		radius_chunks: int
	) -> bool:
		update_order.append("collision")
		collision_viewer_updates.append({
			"viewer_id": viewer_id,
			"revision": revision,
			"position": position,
			"radius_chunks": radius_chunks,
		})
		return true

	func get_last_error() -> String:
		return "ok"


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var game_world := GameWorldNode.new()
	var generation_profile = GenerationProfile.new()
	generation_profile.world_chunk_count_x = 128
	generation_profile.world_chunk_count_y = 16
	generation_profile.world_chunk_origin_y = -8
	generation_profile.world_chunk_count_z = 128
	game_world.configure_game_world(
		&"viewer_freshness_test",
		generation_profile,
		null,
		[],
		2,
		0,
		Vector3.ZERO,
		3,
		null
	)
	root.add_child(game_world)
	game_world.player_viewer_update_distance = 8.0
	game_world.player_collision_invoker_enabled = true
	game_world.player_collision_prediction_distance = 24.0
	var terrain_world := FakeTerrainWorld.new()
	var runtime_scene := FakeRuntimeScene.new(terrain_world)
	runtime_scene.add_child(terrain_world)
	game_world.add_child(runtime_scene)
	game_world.set("_reference_scene", runtime_scene)
	var player := Node3D.new()
	game_world.attach_player(player, Vector3.ZERO)

	if not game_world.update_player_viewer(true):
		_fail("initial forced player viewer update failed")
		return
	if runtime_scene.update_order != ["visual", "collision"]:
		_fail("initial paired viewer order was not visual-first: %s" % str(runtime_scene.update_order))
		return
	player.global_position = Vector3(1.0, 0.0, 0.0)
	if not game_world.update_player_viewer(false):
		_fail("collision-only player viewer update was rejected")
		return
	if runtime_scene.viewer_updates.size() != 1 or \
			runtime_scene.collision_viewer_updates.size() != 2:
		_fail("collision invoker was coupled to visual viewer cadence")
		return
	var predicted_forward: Dictionary = runtime_scene.collision_viewer_updates.back()
	if not is_equal_approx(
		float(predicted_forward.get("position", Vector3.ZERO).x),
		25.0
	):
		_fail("collision invoker did not use the latest forward observation")
		return
	if not game_world.update_player_viewer(false):
		_fail("stopped collision invoker update was rejected")
		return
	var recentered: Dictionary = runtime_scene.collision_viewer_updates.back()
	if not is_equal_approx(
		float(recentered.get("position", Vector3.ZERO).x),
		1.0
	):
		_fail("stopped collision invoker retained stale forward prediction")
		return
	var collision_updates_before_blocked_intent := \
		runtime_scene.collision_viewer_updates.size()
	if game_world.is_player_collision_ready_at(Vector3(3.0, 0.0, 0.0)):
		_fail("fake terrain unexpectedly reported collision readiness")
		return
	if not game_world.update_player_viewer(false):
		_fail("blocked-intent collision invoker update was rejected")
		return
	if runtime_scene.collision_viewer_updates.size() != \
			collision_updates_before_blocked_intent + 1:
		_fail("blocked movement retracted or duplicated its predictive invoker")
		return
	var predicted_blocked_intent: Dictionary = \
		runtime_scene.collision_viewer_updates.back()
	if not is_equal_approx(
		float(predicted_blocked_intent.get("position", Vector3.ZERO).x),
		25.0
	):
		_fail("blocked movement did not retain requested forward prediction")
		return
	if game_world.is_player_collision_ready_at(player.global_position):
		_fail("fake terrain unexpectedly reported stopped collision readiness")
		return
	if not game_world.update_player_viewer(false):
		_fail("intentional-stop collision invoker update was rejected")
		return
	var intent_recentered: Dictionary = \
		runtime_scene.collision_viewer_updates.back()
	if not is_equal_approx(
		float(intent_recentered.get("position", Vector3.ZERO).x),
		1.0
	):
		_fail("intentional zero-motion input did not recenter collision")
		return
	player.global_position = Vector3.ZERO
	if not game_world.update_player_viewer(false):
		_fail("reversed collision invoker update was rejected")
		return
	var predicted_reverse: Dictionary = runtime_scene.collision_viewer_updates.back()
	if not is_equal_approx(
		float(predicted_reverse.get("position", Vector3.ZERO).x),
		-24.0
	):
		_fail("collision invoker did not reverse from the latest observation")
		return
	player.global_position = Vector3(32.0, 0.0, 0.0)
	if not game_world.update_player_viewer(false):
		_fail("moved player viewer update was rejected")
		return

	if runtime_scene.viewer_updates.size() != 2:
		_fail(
			"streaming debt suppressed the current player position: updates=%d" %
			runtime_scene.viewer_updates.size()
		)
		return
	if runtime_scene.update_order.slice(runtime_scene.update_order.size() - 2) != \
			["visual", "collision"]:
		_fail("moved paired viewer order was not visual-first: %s" % str(runtime_scene.update_order))
		return
	var latest: Dictionary = runtime_scene.viewer_updates.back()
	if latest.get("position", Vector3.ZERO) != player.global_position:
		_fail("latest player position was not submitted")
		return
	var accepted_updates := int(game_world.get("_accepted_player_viewer_updates"))
	if accepted_updates != 2:
		_fail("accepted player viewer count mismatch: %d" % accepted_updates)
		return
	if not game_world.is_player_collision_ready_at(Vector3(0.0, 128.0, 0.0), true):
		_fail("inspection flight was blocked above the finite vertical volume")
		return
	if game_world.is_player_collision_ready_at(Vector3(0.0, 128.0, 0.0), false):
		_fail("walking bypassed collision readiness above the finite vertical volume")
		return
	if game_world.is_player_collision_ready_at(Vector3.ZERO, true):
		_fail("inspection flight bypassed collision readiness inside the vertical volume")
		return
	print("WT_GAMEWORLD_VIEWER_FRESHNESS_PASS updates=2 collision_updates=%d debt=1" % \
		runtime_scene.collision_viewer_updates.size())
	game_world.free()
	quit(0)


func _fail(message: String) -> void:
	push_error("WT_GAMEWORLD_VIEWER_FRESHNESS_FAIL %s" % message)
	quit(1)

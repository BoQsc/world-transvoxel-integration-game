extends SceneTree

const GameWorldNode := preload(
	"res://addons/world_transvoxel_gameworld/wt_game_world_node.gd"
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


class FakeReferenceScene:
	extends Node

	var terrain_world: Node
	var viewer_updates: Array[Dictionary] = []
	var collision_viewer_updates: Array[Dictionary] = []
	var update_order: Array[String] = []

	func _init(value: Node) -> void:
		terrain_world = value

	func get_terrain_world() -> Node:
		return terrain_world

	func update_reference_viewer(
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

	func update_reference_collision_viewer(
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
	game_world.configure_game_world(
		&"viewer_freshness_test",
		null,
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
	var terrain_world := FakeTerrainWorld.new()
	var reference_scene := FakeReferenceScene.new(terrain_world)
	reference_scene.add_child(terrain_world)
	game_world.add_child(reference_scene)
	game_world.set("_reference_scene", reference_scene)
	var player := Node3D.new()
	game_world.attach_player(player, Vector3.ZERO)

	if not game_world.update_player_viewer(true):
		_fail("initial forced player viewer update failed")
		return
	if reference_scene.update_order != ["visual", "collision"]:
		_fail("initial paired viewer order was not visual-first: %s" % str(reference_scene.update_order))
		return
	player.global_position = Vector3(1.0, 0.0, 0.0)
	if not game_world.update_player_viewer(false):
		_fail("collision-only player viewer update was rejected")
		return
	if reference_scene.viewer_updates.size() != 1 or \
			reference_scene.collision_viewer_updates.size() != 2:
		_fail("collision invoker was coupled to visual viewer cadence")
		return
	player.global_position = Vector3(32.0, 0.0, 0.0)
	if not game_world.update_player_viewer(false):
		_fail("moved player viewer update was rejected")
		return

	if reference_scene.viewer_updates.size() != 2:
		_fail(
			"streaming debt suppressed the current player position: updates=%d" %
			reference_scene.viewer_updates.size()
		)
		return
	if reference_scene.update_order.slice(reference_scene.update_order.size() - 2) != \
			["visual", "collision"]:
		_fail("moved paired viewer order was not visual-first: %s" % str(reference_scene.update_order))
		return
	var latest: Dictionary = reference_scene.viewer_updates.back()
	if latest.get("position", Vector3.ZERO) != player.global_position:
		_fail("latest player position was not submitted")
		return
	var accepted_updates := int(game_world.get("_accepted_player_viewer_updates"))
	if accepted_updates != 2:
		_fail("accepted player viewer count mismatch: %d" % accepted_updates)
		return
	print("WT_GAMEWORLD_VIEWER_FRESHNESS_PASS updates=2 collision_updates=%d debt=1" % \
		reference_scene.collision_viewer_updates.size())
	game_world.free()
	quit(0)


func _fail(message: String) -> void:
	push_error("WT_GAMEWORLD_VIEWER_FRESHNESS_FAIL %s" % message)
	quit(1)

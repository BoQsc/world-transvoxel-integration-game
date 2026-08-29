extends SceneTree

const MARKER := "WT_PLAYER_COLLISION_FOOTPRINT_PASS"
const GameWorld := preload(
	"res://addons/world_transvoxel_gameworld/wt_game_world_node.gd"
)


class MockCollisionState:
	extends RefCounted

	var present := true
	var required := true
	var ready := true
	var applied_generation := 0
	var staged_generation := 0

	func is_present() -> bool:
		return present

	func is_collision_required() -> bool:
		return required

	func is_collision_ready() -> bool:
		return ready

	func get_collision_generation() -> int:
		return applied_generation

	func get_staged_collision_generation() -> int:
		return staged_generation


class MockTerrain:
	extends RefCounted

	var states := {}

	func set_state(coordinate: Vector3i, lod: int, state: MockCollisionState) -> void:
		states[Vector4i(coordinate.x, coordinate.y, coordinate.z, lod)] = state

	func query_chunk_state(coordinate: Vector3i, lod: int) -> RefCounted:
		return states.get(Vector4i(coordinate.x, coordinate.y, coordinate.z, lod))


class MockRuntimeScene:
	extends Node

	var collision_updates: Array[Dictionary] = []

	func update_runtime_collision_viewer(
		viewer_id: int,
		revision: int,
		position: Vector3,
		radius_chunks: int
	) -> bool:
		collision_updates.append({
			"viewer_id": viewer_id,
			"revision": revision,
			"position": position,
			"radius_chunks": radius_chunks,
		})
		return true


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var game_world := GameWorld.new()
	root.add_child(game_world)
	var interior: Array = game_world.call(
		"_player_collision_probe_chunks",
		Vector3(8.0, 8.0, 8.0),
		0.45,
		0.9,
		0.2
	)
	if interior != [Vector3i(0, 0, 0)]:
		_fail("interior footprint did not resolve to one chunk: %s" % str(interior))
		return
	var boundary: Array = game_world.call(
		"_player_collision_probe_chunks",
		Vector3(16.0, 16.9, 16.0),
		0.45,
		0.9,
		0.2
	)
	var expected := []
	for y in range(0, 2):
		for z in range(0, 2):
			for x in range(0, 2):
				expected.append(Vector3i(x, y, z))
	if boundary != expected:
		_fail("boundary footprint missed capsule/support chunks: %s" % str(boundary))
		return
	var state := MockCollisionState.new()
	state.staged_generation = 7
	if bool(game_world.call("_collision_state_has_usable_applied_shape", state)):
		_fail("staged-only collision was accepted as applied")
		return
	state.applied_generation = 6
	if not bool(game_world.call("_collision_state_has_usable_applied_shape", state)):
		_fail("preserved applied collision was rejected during replacement")
		return
	state.applied_generation = 0
	state.staged_generation = 0
	if not bool(game_world.call("_collision_state_has_usable_applied_shape", state)):
		_fail("authoritative empty collision state was rejected")
		return
	var terrain := MockTerrain.new()
	terrain.set_state(Vector3i(1, 0, 1), 0, state)
	state.staged_generation = 8
	var ancestor := MockCollisionState.new()
	ancestor.required = false
	ancestor.ready = false
	ancestor.applied_generation = 5
	terrain.set_state(Vector3i(0, 0, 0), 1, ancestor)
	var coverage: Dictionary = game_world.call(
		"_collision_coverage_for_lod0_chunk", terrain, Vector3i(1, 0, 1), 3
	)
	if bool(coverage.get("ready", false)) or \
			Array(coverage.get("preserved_ancestor_lods", [])) != [1]:
		_fail("parent collision incorrectly certified transition support: %s" % coverage)
		return
	var negative_child := MockCollisionState.new()
	negative_child.staged_generation = 9
	terrain.set_state(Vector3i(-1, 0, -1), 0, negative_child)
	var negative_parent := MockCollisionState.new()
	negative_parent.applied_generation = 6
	terrain.set_state(Vector3i(-1, 0, -1), 1, negative_parent)
	var negative_coverage: Dictionary = game_world.call(
		"_collision_coverage_for_lod0_chunk", terrain, Vector3i(-1, 0, -1), 3
	)
	if Array(negative_coverage.get("preserved_ancestor_lods", [])) != [1]:
		_fail("negative-coordinate parent coverage used truncation: %s" % negative_coverage)
		return
	var runtime_scene := MockRuntimeScene.new()
	root.add_child(runtime_scene)
	game_world.set("_reference_scene", runtime_scene)
	if not bool(game_world.call(
		"_submit_player_collision_invokers",
		Vector3(8.0, 8.0, 8.0),
		Vector3(40.0, 8.0, 8.0),
		false
	)) or runtime_scene.collision_updates.size() != 2:
		_fail("anchored and predictive collision viewers were not both submitted")
		return
	var anchored: Dictionary = runtime_scene.collision_updates[0]
	var predictive: Dictionary = runtime_scene.collision_updates[1]
	if int(anchored.get("viewer_id", 0)) == int(predictive.get("viewer_id", 0)) or \
			anchored.get("position") != Vector3(8.0, 8.0, 8.0) or \
			predictive.get("position") != Vector3(40.0, 8.0, 8.0):
		_fail("collision viewer roles were not spatially independent")
		return
	if not bool(game_world.call(
		"_submit_player_collision_invokers",
		Vector3(9.0, 8.0, 8.0),
		Vector3(41.0, 8.0, 8.0),
		false
	)) or runtime_scene.collision_updates.size() != 2:
		_fail("same-chunk collision viewer updates did not coalesce independently")
		return
	print("%s interior=1 boundary=%d transition_guard=pass dual_invokers=pass" % [
		MARKER,
		boundary.size(),
	])
	quit(0)


func _fail(message: String) -> void:
	push_error("WT_PLAYER_COLLISION_FOOTPRINT_FAIL: " + message)
	quit(1)

extends SceneTree

const MARKER := "WT_PLAYER_COLLISION_FOOTPRINT_PASS"
const GameWorld := preload(
	"res://addons/world_transvoxel_gameworld/wt_game_world_node.gd"
)
const ProductionPlayer := preload("res://scripts/wt_production_player.gd")


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


class MockPendingGameWorld:
	extends Node

	func get_player_collision_readiness_at(
		_position: Vector3,
		_allow_outside_vertical_volume: bool,
		_body_radius: float,
		_body_half_height: float,
		_support_margin: float
	) -> Dictionary:
		return {
			"ready": false,
			"movement_safe": false,
			"reason": "collision_pending_without_physical_coverage",
			"not_ready_chunks": [{"coordinate": Vector3i.ZERO}],
		}


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
			not bool(coverage.get("movement_safe", false)) or \
			Array(coverage.get("preserved_ancestor_lods", [])) != [1]:
		_fail("parent collision did not provide movement-safe transition coverage: %s" % coverage)
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
	var player := ProductionPlayer.new()
	var guarded: Vector3 = player.call(
		"_collision_pending_escape_velocity", Vector3(4.0, -12.0, -3.0)
	)
	if guarded != Vector3(4.0, 0.0, -3.0):
		_fail("pending collision guard prevented horizontal escape: %s" % guarded)
		return
	var upward: Vector3 = player.call(
		"_collision_pending_escape_velocity", Vector3(4.0, 7.0, -3.0)
	)
	if upward != Vector3(4.0, 7.0, -3.0):
		_fail("pending collision guard prevented upward escape: %s" % upward)
		return
	var pending_world := MockPendingGameWorld.new()
	root.add_child(pending_world)
	root.add_child(player)
	player.game_world = pending_world
	if not player.autonomous_move_with_streaming_collision(
			Vector3(4.0, -12.0, 0.0), 0.25
	) or player.global_position.x <= 0.0 or player.global_position.y < 0.0:
		_fail("pending collision state still caged the player: %s" % player.global_position)
		return
	var pending_status: Dictionary = player.get_streaming_collision_status()
	if bool(pending_status.get("waiting", true)) or \
			not bool(pending_status.get("collision_pending", false)) or \
			not bool(pending_status.get("movement_permitted", false)):
		_fail("pending collision self-report still describes blocked movement: %s" % pending_status)
		return
	var report_path := ProjectSettings.globalize_path(
		"res://.godot/world_transvoxel_captures/collision_failure/latest.json"
	)
	DirAccess.remove_absolute(report_path)
	player.set("_last_grounded_position", Vector3(4.0, 5.0, 6.0))
	player.set("_recent_edit_ticks_usec", Time.get_ticks_usec())
	player.set("_recent_edit_support_must_remain", true)
	player.set("_recent_edit_center", Vector3(12.0, 5.0, 6.0))
	player.set("_recent_edit_radius", 1.8)
	player.global_position = Vector3(4.0, 3.0, 6.0)
	player.call("_monitor_recent_edit_support")
	if player.global_position != Vector3(4.0, 5.1, 6.0) or \
			not FileAccess.file_exists(report_path):
		_fail("unexpected post-edit support loss was not recovered and reported")
		return
	var report: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(report_path)
	)
	if str(report.get("schema", "")) != \
			"world_transvoxel.collision_fall_incident.v1" or \
			not bool(report.get("recovered", false)):
		_fail("collision fall report was incomplete: %s" % report)
		return
	print("%s interior=1 boundary=%d transition_guard=pass dual_invokers=pass fall_recovery=pass" % [
		MARKER,
		boundary.size(),
	])
	quit(0)


func _fail(message: String) -> void:
	push_error("WT_PLAYER_COLLISION_FOOTPRINT_FAIL: " + message)
	quit(1)

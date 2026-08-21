extends SceneTree

const MARKER := "WT_PLAYER_WALKING_DIRECTION_PASS"
const ProductionPlayer := preload("res://scripts/wt_production_player.gd")


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var player := ProductionPlayer.new()
	var camera := Camera3D.new()
	camera.name = "FirstPersonCamera"
	player.add_child(camera)
	root.add_child(player)
	camera.rotation = Vector3(-0.35, 0.8, 0.0)
	if not player.has_method("_walking_world_direction"):
		_fail("walking has no camera-relative direction policy")
		return
	var actual: Vector3 = player.call(
		"_walking_world_direction", Vector3(0.0, 0.0, -1.0)
	)
	var expected := -camera.global_transform.basis.z
	expected.y = 0.0
	expected = expected.normalized()
	if actual.distance_to(expected) > 0.0001:
		_fail("walking direction does not follow camera heading")
		return
	if absf(actual.y) > 0.0001:
		_fail("walking direction contains vertical camera pitch")
		return
	print("%s camera_relative=1 horizontal=1" % MARKER)
	quit(0)


func _fail(message: String) -> void:
	push_error("WT_PLAYER_WALKING_DIRECTION_FAIL: " + message)
	quit(1)

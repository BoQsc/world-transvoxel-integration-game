extends SceneTree

const MARKER := "WT_PLAYER_STATIC_WATER_CONTROL_PASS"
const ProductionPlayer := preload("res://scripts/wt_production_player.gd")


class FakeGameWorld extends Node:
	var submitted_mode: StringName
	var submitted_material_id := -1

	func submit_sphere_edit(
		mode_name: StringName,
		_center: Vector3,
		_radius: float,
		material_id: int,
		_density_value: float
	) -> bool:
		submitted_mode = mode_name
		submitted_material_id = material_id
		return true

	func get_last_edit_summary() -> Dictionary:
		return {
			"accepted": true,
			"mode": str(submitted_mode),
			"material_id": submitted_material_id,
		}


func _initialize() -> void:
	var game_world := FakeGameWorld.new()
	var player := ProductionPlayer.new()
	root.add_child(game_world)
	root.add_child(player)
	player.game_world = game_world

	var key := InputEventKey.new()
	key.keycode = KEY_9
	if int(player.call("_material_slot_from_key", key)) != 8:
		_fail("key 9 did not map to the static-water slot")
		return
	if not player.set_selected_material_id(9):
		_fail("static-water material selection was rejected")
		return
	var selected := player.get_selected_material_summary()
	if int(selected.get("slot", 0)) != 9 or \
			str(selected.get("material_name", "")) != "static_water" or \
			str(selected.get("place_mode", "")) != "place_static_water" or \
			str(selected.get("remove_mode", "")) != "remove_static_water":
		_fail("static-water selection summary is incorrect: %s" % str(selected))
		return
	if not player.submit_edit_input(
		&"place_static_water", Vector3(4.0, 8.0, 12.0), true
	):
		_fail("player static-water submission was rejected")
		return
	if game_world.submitted_mode != &"place_static_water" or \
			game_world.submitted_material_id != 9:
		_fail("player emitted the wrong water command")
		return
	if not player.submit_edit_input(
		&"remove_static_water", Vector3(4.0, 8.0, 12.0), true
	):
		_fail("player static-water removal submission was rejected")
		return
	if game_world.submitted_mode != &"remove_static_water" or \
			game_world.submitted_material_id != 9:
		_fail("player emitted terrain carve instead of water removal")
		return
	print("%s slot=9 place=place_static_water remove=remove_static_water material=9" % MARKER)
	quit(0)


func _fail(message: String) -> void:
	push_error("WT_PLAYER_STATIC_WATER_CONTROL_FAIL: " + message)
	quit(1)

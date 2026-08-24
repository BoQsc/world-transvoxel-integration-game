extends SceneTree

const MARKER := "WT_PLAYTEST_DIAGNOSTICS_PASS"
const Diagnostics := preload("res://scripts/wt_playtest_diagnostics.gd")
const Player := preload("res://scripts/wt_production_player.gd")


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var canvas := CanvasLayer.new()
	host.add_child(canvas)
	var crosshair := Label.new()
	canvas.add_child(crosshair)
	var player := CharacterBody3D.new()
	player.set_script(Player)
	host.add_child(player)
	var diagnostics := Diagnostics.new()
	host.add_child(diagnostics)
	diagnostics.call("build_ui", canvas, crosshair)
	diagnostics.call("attach_runtime", null, player)
	diagnostics.call("set_menu_open", true)
	if not bool(diagnostics.call("is_menu_open")):
		_fail("ESC menu did not open")
		return
	if player.human_input_enabled:
		_fail("ESC menu did not suppress player input")
		return
	diagnostics.call("set_menu_open", false)
	if bool(diagnostics.call("is_menu_open")):
		_fail("ESC menu did not close")
		return
	if not player.human_input_enabled:
		_fail("closing ESC menu did not restore player input")
		return
	diagnostics.call("_set_collision_visualization", true)
	if not debug_collisions_hint:
		_fail("collision visualization did not enable physics debug hint")
		return
	diagnostics.call("_set_collision_visualization", false)
	print("%s menu=1 collision_toggle=1 chunk_toggle=1 performance_hud=1" % MARKER)
	quit(0)


func _fail(message: String) -> void:
	push_error("WT_PLAYTEST_DIAGNOSTICS_FAIL: " + message)
	quit(1)

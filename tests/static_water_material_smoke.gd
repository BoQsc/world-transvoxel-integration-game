extends SceneTree

const MARKER := "WT_STATIC_WATER_MATERIAL_PASS"
const WATER_SHADER := preload(
	"res://addons/world_transvoxel_gameworld/material/wt_game_static_water.gdshader"
)


func _initialize() -> void:
	var shader_code := WATER_SHADER.code
	if "cull_back" not in shader_code:
		_fail("exterior water rendering must cull rear volume boundaries")
		return
	if "cull_disabled" in shader_code:
		_fail("double-sided water exposes lower and rear boundary highlights")
		return
	if "depth_prepass_alpha" not in shader_code:
		_fail("transparent water must retain its alpha depth prepass")
		return
	print("%s exterior_boundary=front rear_boundary=culled" % MARKER)
	quit(0)


func _fail(message: String) -> void:
	push_error("WT_STATIC_WATER_MATERIAL_FAIL: " + message)
	quit(1)

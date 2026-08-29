extends SceneTree

const MARKER := "WT_STATIC_WATER_MATERIAL_PASS"
const WATER_SHADER := preload(
	"res://addons/world_transvoxel_gameworld/material/wt_game_static_water.gdshader"
)
const GPU_WATER_SHADER_PATH := (
	"res://addons/world_transvoxel_terrain/gpu/"
	+ "wt_terrain_gpu_global_render_water.glsl"
)


func _initialize() -> void:
	var shader_code := WATER_SHADER.code
	if "cull_disabled" not in shader_code:
		_fail("volumetric water must expose an interior exit boundary")
		return
	if "cull_back" in shader_code:
		_fail("back-face culling makes the water volume disappear from inside")
		return
	if "depth_draw_always" not in shader_code:
		_fail("water shell must depth-resolve in the transparent pass")
		return
	if "depth_prepass_alpha" in shader_code:
		_fail("water prepass must not hide opaque terrain from the screen sample")
		return
	if "hint_screen_texture" not in shader_code or "ALPHA = 1.0" not in shader_code:
		_fail("water must compose one opaque-scene sample without shell accumulation")
		return
	if "FRONT_FACING" not in shader_code:
		_fail("water must distinguish exterior and interior boundary shading")
		return
	var gpu_shader_code := FileAccess.get_file_as_string(GPU_WATER_SHADER_PATH)
	if gpu_shader_code.is_empty():
		_fail("generated GPU water shader is unavailable")
		return
	if "signed_facing < 0.0" not in gpu_shader_code:
		_fail("GPU water must classify the logical boundary from authority normals")
		return
	if "gl_FrontFacing" in gpu_shader_code:
		_fail("raw GPU table winding is not a logical water-boundary authority")
		return
	print("%s exterior=front interior=exit composition=single_shell" % MARKER)
	quit(0)


func _fail(message: String) -> void:
	push_error("WT_STATIC_WATER_MATERIAL_FAIL: " + message)
	quit(1)

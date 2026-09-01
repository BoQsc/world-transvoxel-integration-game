extends SceneTree

const Effect := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render_effect.gd"
)


func _initialize() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xC0111510
	var checks := 0
	for transform_index in range(8):
		var camera := Transform3D(
			Basis.from_euler(Vector3(
				rng.randf_range(-1.0, 1.0),
				rng.randf_range(-PI, PI),
				rng.randf_range(-0.5, 0.5)
			)),
			Vector3(
				rng.randf_range(-32.0, 32.0),
				rng.randf_range(-32.0, 32.0),
				rng.randf_range(-32.0, 32.0)
			)
		)
		var context := {
			"world_to_view": camera.affine_inverse(),
			"projection": Projection.IDENTITY,
		}
		for _group_index in range(512):
			var group_min := Vector3(INF, INF, INF)
			var group_max := Vector3(-INF, -INF, -INF)
			var any_visible := false
			for _member_index in range(rng.randi_range(1, 12)):
				var minimum := Vector3(
					rng.randf_range(-64.0, 64.0),
					rng.randf_range(-64.0, 64.0),
					rng.randf_range(-64.0, 64.0)
				)
				var maximum := minimum + Vector3(
					rng.randf_range(0.01, 24.0),
					rng.randf_range(0.01, 24.0),
					rng.randf_range(0.01, 24.0)
				)
				var entry := {"bounds_min": minimum, "bounds_max": maximum}
				any_visible = any_visible or Effect._entry_visible_for_context(entry, context)
				group_min = group_min.min(minimum)
				group_max = group_max.max(maximum)
				checks += 1
			var group := {"bounds_min": group_min, "bounds_max": group_max}
			if any_visible and not Effect._entry_visible_for_context(group, context):
				push_error("GPU_DRAW_BIN_CONSERVATIVE_FAIL visible member was culled")
				quit(1)
				return
	print("GPU_DRAW_BIN_CONSERVATIVE_PASS checks=%d contexts=8" % checks)
	quit(0)

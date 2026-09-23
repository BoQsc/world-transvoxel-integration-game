extends SceneTree

const BaseCoverage := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_base_coverage.gd"
)
const GlobalEffect := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render_effect.gd"
)
const Controller := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_resident_render_controller.gd"
)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if GlobalEffect == null or Controller == null:
		_fail("GPU render scripts did not parse")
		return
	var base = BaseCoverage.new()
	var leaves := {}
	for x in range(2):
		for y in range(-2, 0):
			for z in range(2):
				leaves["%d:%d:%d:2" % [x, y, z]] = "%d:%d:%d" % [x, y, z]
	var selected: Array[String] = []
	if not base._cover(0, -1, 0, 3, leaves, selected) or selected.size() != 8:
		_fail("complete LOD2 children did not cover their coarse root")
		return
	leaves.erase("1:-1:1:2")
	selected.clear()
	if base._cover(0, -1, 0, 3, leaves, selected) or not selected.is_empty():
		_fail("incomplete child set retired coarse coverage")
		return
	base._root_inventory = {"0:-1:0": true, "1:-1:0": true}
	var entries := {"edge": {"identity": {
		"page_x": 1, "page_y": -1, "page_z": 0, "lod": 2,
		"transition_mask": 0,
	}}}
	if base._balanced_against_retained_base(
		Vector3i(0, -1, 0), ["edge"], {"0:-1:0": ["edge"]}, entries
	):
		_fail("unstitched LOD2 edge replaced its coarse neighbor")
		return
	entries["edge"]["identity"]["transition_mask"] = 2
	if not base._balanced_against_retained_base(
		Vector3i(0, -1, 0), ["edge"], {"0:-1:0": ["edge"]}, entries
	):
		_fail("stitched LOD2 edge was rejected")
		return
	print("WT_GPU_BASE_COVERAGE_CUT_PASS")
	quit(0)


func _fail(message: String) -> void:
	push_error("WT_GPU_BASE_COVERAGE_CUT_FAIL: " + message)
	quit(1)

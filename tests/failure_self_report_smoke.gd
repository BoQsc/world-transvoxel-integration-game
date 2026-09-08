extends SceneTree

const Main := preload("res://scripts/main.gd")
const MARKER := "WT_FAILURE_SELF_REPORT_SMOKE_PASS"


func _initialize() -> void:
	var main := Main.new()
	main.call("_build_loading_overlay")
	var label: Label = main.get("loading_label")
	if label == null \
			or label.autowrap_mode != TextServer.AUTOWRAP_WORD_SMART \
			or label.offset_left < 90.0 \
			or label.offset_right > -90.0:
		push_error("WT_FAILURE_SELF_REPORT_SMOKE_FAIL: failure label is not bounded and wrapped")
		quit(1)
		return
	var report_path := str(main.call(
		"_write_failure_self_report", "synthetic startup failure"
	))
	var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(report_path))
	if not payload is Dictionary \
			or str(Dictionary(payload).get("schema", "")) \
				!= "world_transvoxel.terrain_failure.v1" \
			or str(Dictionary(payload).get("message", "")) \
				!= "synthetic startup failure":
		push_error("WT_FAILURE_SELF_REPORT_SMOKE_FAIL: structured report is incomplete")
		quit(1)
		return
	DirAccess.remove_absolute(report_path)
	main.free()
	print(MARKER)
	quit(0)

@tool
extends Node


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		return
	call_deferred("_reimport_requested_files")


func _reimport_requested_files() -> void:
	var files := PackedStringArray(OS.get_cmdline_user_args())
	if files.is_empty():
		push_error("No resource paths were provided for terrain texture reimport.")
		get_tree().quit(2)
		return
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem == null:
		push_error("Godot editor filesystem is unavailable.")
		get_tree().quit(3)
		return
	filesystem.reimport_files(files)
	print("WT_GODOT_EXPLICIT_REIMPORT_PASS resources=%d" % files.size())
	get_tree().quit()

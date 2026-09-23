extends SceneTree

const MaterialApplicator := preload("res://addons/world_transvoxel_gameworld/material/wt_game_terrain_material_applicator.gd")
const OUTPUT_DIRECTORY := "res://addons/world_transvoxel_gameworld/material/baked"
const RESOLUTION := 512


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))
	var applicator := MaterialApplicator.new()
	for slot: StringName in [&"albedo", &"normal", &"roughness_orm"]:
		var started := Time.get_ticks_msec()
		var images: Array[Image] = applicator.production_images_for_bake(RESOLUTION, slot)
		if images.size() != 8:
			push_error("terrain material bake returned %d layers for %s" % [images.size(), slot])
			quit(1)
			return
		for tile in range(images.size()):
			var image := images[tile]
			var path := "%s/terrain_%s_%d_%d.png" % [
				OUTPUT_DIRECTORY, slot, RESOLUTION, tile
			]
			var result := image.save_png(ProjectSettings.globalize_path(path))
			if result != OK:
				push_error("terrain material bake failed: %s (%d)" % [path, result])
				quit(1)
				return
			var round_trip := Image.new()
			if round_trip.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK or \
					round_trip.get_format() != Image.FORMAT_RGBA8 or \
					round_trip.get_data() != image.get_data().slice(0, RESOLUTION * RESOLUTION * 4):
				push_error("terrain material bake did not round-trip: %s" % path)
				quit(1)
				return
		print("WT_GAME_TERRAIN_MATERIAL_BAKE slot=%s layers=%d elapsed_ms=%d" % [
			slot, images.size(), Time.get_ticks_msec() - started
		])
	applicator.free()
	quit()

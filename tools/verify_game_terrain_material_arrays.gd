extends SceneTree

const MaterialApplicator := preload("res://addons/world_transvoxel_gameworld/material/wt_game_terrain_material_applicator.gd")


func _initialize() -> void:
	var applicator := MaterialApplicator.new()
	for slot: StringName in [&"albedo", &"normal", &"roughness_orm"]:
		var started := Time.get_ticks_msec()
		var baked: Array[Image] = applicator._baked_production_images(512, slot)
		var loaded_ms := Time.get_ticks_msec() - started
		if baked.size() != 8:
			push_error("baked terrain material images missing for %s: %d" % [slot, baked.size()])
			quit(1)
			return
		var generated: Array[Image] = applicator.production_images_for_bake(512, slot)
		for tile in range(8):
			if baked[tile].get_data() != generated[tile].get_data():
				push_error("baked terrain material differs from source: %s tile %d" % [slot, tile])
				quit(1)
				return
		print("WT_GAME_TERRAIN_MATERIAL_VERIFY slot=%s layers=8 baked_load_ms=%d parity=exact" % [
			slot, loaded_ms
		])
	applicator.free()
	quit()

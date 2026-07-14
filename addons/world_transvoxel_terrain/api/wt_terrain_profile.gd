@tool
extends Resource
class_name WtTerrainProfile

@export_range(1, 16384, 1) var horizontal_cells: int = 2048
@export_range(1, 4096, 1) var vertical_cells: int = 128
@export_range(-65536, 65536, 1) var vertical_origin_cell: int = 0
@export var finite_closed_boundary: bool = true
@export var plus_y_is_up: bool = true
@export var profile_id: StringName = &"reference_2048x64"


func get_contract_summary() -> Dictionary:
	return {
		"profile_id": str(profile_id),
		"horizontal_cells": horizontal_cells,
		"vertical_cells": vertical_cells,
		"vertical_origin_cell": vertical_origin_cell,
		"finite_closed_boundary": finite_closed_boundary,
		"plus_y_is_up": plus_y_is_up,
	}

extends SceneTree

const Controller := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_resident_render_controller.gd"
)

class Backend:
	extends Node

	func get_gpu_resident_render_chunk_readiness(_identity: Dictionary) -> Dictionary:
		return {
			"status": "READY", "ready": true,
			"external_activation_required": true,
		}


class Effect:
	extends RefCounted
	var remasks: Array = []

	func remask_active_entries(entries: Array, group_key: String) -> bool:
		remasks.append({"entries": entries.duplicate(true), "group_key": group_key})
		return true


func _initialize() -> void:
	var controller := Controller.new()
	var backend := Backend.new()
	var effect := Effect.new()
	controller._backend_terrain = backend
	controller._effect = effect
	var identity := {
		"page_x": 9, "page_y": 0, "page_z": 8, "lod": 1,
		"generation": 561, "transition_mask": 0,
		"cached_transition_mask": 32, "surface": "terrain",
	}
	var group_key := controller._group_key(identity)
	controller._groups[group_key] = {
		"active": true, "native_active": true, "native_prepared": true,
		"validated": true, "prepared": {"terrain": true},
		"requests": {"terrain": {"identity": identity, "publication_sequence": 17}},
		"sequences": {"terrain": 17},
	}
	controller._prepared_group_routes[controller._activation_chunk_key(identity)] = group_key
	var member := identity.duplicate(true)
	member["transition_mask"] = 32
	controller._record_activation_cohort_wait({
		"waiting_member": member,
		"waiting_member_external_activation_required": true,
	})
	var recovered := Dictionary(controller._groups.get(group_key, {}))
	var passed := effect.remasks.size() == 1 \
		and bool(recovered.get("remask_pending", false)) \
		and int(recovered.get("remask_transition_mask", -1)) == 32 \
		and not bool(recovered.get("remask_reactivate_dormant", true)) \
		and str(controller._last_activation_cohort_wait.get(
			"waiting_member_group_key", ""
		)) == group_key
	controller.free()
	backend.free()
	if not passed:
		push_error("GPU_ACTIVE_REMASK_RECOVERY_SMOKE_FAIL")
		quit(1)
		return
	print("GPU_ACTIVE_REMASK_RECOVERY_SMOKE_PASS exact_route_missing=1 active_geometry_reused=1")
	quit(0)

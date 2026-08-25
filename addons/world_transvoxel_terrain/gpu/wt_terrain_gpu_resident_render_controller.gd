@tool
extends Node
class_name WtTerrainGpuResidentRenderController

const GlobalRenderEffect := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render_effect.gd"
)
const REQUIRED_BACKEND_METHODS := [
	"begin_gpu_resident_render_publication",
	"end_gpu_resident_render_publication",
	"pop_gpu_resident_render_request",
	"validate_gpu_resident_render_request",
	"get_gpu_resident_render_chunk_readiness",
	"reject_gpu_resident_render_request",
	"set_gpu_resident_render_chunk_active",
	"reconcile_gpu_resident_render_chunks",
	"get_gpu_resident_render_metrics",
]
const APPLICATION_WAIT_FRAME_LIMIT := 180
const APPLICATION_WAIT_RETRY_FRAMES := 3
const RENDER_SUBMISSION_CAPACITY := 3

var _backend_terrain: Node
var _world_environment: WorldEnvironment
var _previous_compositor: Compositor
var _compositor: Compositor
var _effect
var _groups: Dictionary = {}
var _render_request_routes: Dictionary = {}
var _entry_routes: Dictionary = {}
var _running := false
var _native_request_capacity := 16
var _resident_capacity := 64
var _next_publication_sequence := 1
var _last_error := ""
var _submitted_surfaces := 0
var _validated_surfaces := 0
var _activated_chunks := 0
var _retired_chunks := 0
var _rejected_chunks := 0
var _recovery_count := 0
var _application_wait_expirations := 0
var _process_frame := 0


func _ready() -> void:
	set_process(false)


func start(
	backend_terrain: Node,
	world_environment: WorldEnvironment,
	native_request_capacity: int = 16,
	resident_capacity: int = 64
) -> bool:
	if _running:
		return true
	if backend_terrain == null or world_environment == null:
		_last_error = "native terrain backend and WorldEnvironment are required"
		return false
	for method_name in REQUIRED_BACKEND_METHODS:
		if not backend_terrain.has_method(method_name):
			_last_error = "native terrain backend lacks %s" % method_name
			return false
	_native_request_capacity = clampi(native_request_capacity, 1, 16)
	_resident_capacity = clampi(resident_capacity, 1, 256)
	_effect = GlobalRenderEffect.new()
	if not _effect.configure_resident_capacity(_resident_capacity):
		_last_error = str(_effect.get_status().get(
			"last_error", "global render effect rejected resident capacity"
		))
		_effect = null
		return false
	_previous_compositor = world_environment.compositor
	_compositor = Compositor.new()
	var effects: Array[CompositorEffect] = []
	if _previous_compositor != null:
		for existing in _previous_compositor.compositor_effects:
			if existing != null:
				effects.append(existing)
	effects.append(_effect)
	_compositor.compositor_effects = effects
	world_environment.compositor = _compositor
	if not bool(backend_terrain.call(
		"begin_gpu_resident_render_publication", _native_request_capacity
	)):
		world_environment.compositor = _previous_compositor
		_effect.close()
		_effect = null
		_compositor = null
		_previous_compositor = null
		_last_error = "native terrain backend rejected resident publication"
		return false
	_backend_terrain = backend_terrain
	_world_environment = world_environment
	_groups.clear()
	_render_request_routes.clear()
	_entry_routes.clear()
	_running = true
	_last_error = ""
	set_process(true)
	return true


func stop() -> void:
	set_process(false)
	if not _running and _effect == null:
		return
	_running = false
	_restore_cpu_and_release_native_requests()
	if _backend_terrain != null and is_instance_valid(_backend_terrain):
		_backend_terrain.call("end_gpu_resident_render_publication")
	if _world_environment != null and is_instance_valid(_world_environment) \
			and _world_environment.compositor == _compositor:
		_world_environment.compositor = _previous_compositor
	if _effect != null:
		_effect.close()
	_groups.clear()
	_render_request_routes.clear()
	_entry_routes.clear()
	_backend_terrain = null
	_world_environment = null
	_previous_compositor = null
	_compositor = null
	_effect = null


func is_running() -> bool:
	return _running


func get_status() -> Dictionary:
	var native_metrics := {}
	var effect_status := {}
	if _backend_terrain != null and is_instance_valid(_backend_terrain):
		native_metrics = Dictionary(_backend_terrain.call(
			"get_gpu_resident_render_metrics"
		))
	if _effect != null:
		effect_status = _effect.get_status()
	var active_groups := 0
	for group_value in _groups.values():
		if bool(Dictionary(group_value).get("active", false)):
			active_groups += 1
	return {
		"schema": "world_transvoxel.terrain.gpu_resident_render_controller.v1",
		"running": _running,
		"native_request_capacity": _native_request_capacity,
		"render_submission_capacity": RENDER_SUBMISSION_CAPACITY,
		"resident_capacity": _resident_capacity,
		"tracked_chunks": _groups.size(),
		"active_chunks": active_groups,
		"submitted_surfaces": _submitted_surfaces,
		"validated_surfaces": _validated_surfaces,
		"activated_chunks": _activated_chunks,
		"retired_chunks": _retired_chunks,
		"rejected_chunks": _rejected_chunks,
		"recovery_count": _recovery_count,
		"application_wait_expirations": _application_wait_expirations,
		"last_error": _last_error,
		"native_metrics": native_metrics,
		"effect_status": effect_status,
		"default_backend_unchanged": true,
		"gpu_resident_render_publication": true,
		"production_chunk_replacement": true,
		"native_request_handoff_decoupled": true,
		"cpu_collision_authority": true,
		"atomic_surface_set_activation": true,
		"production_material_parity": false,
	}


func _process(_delta: float) -> void:
	if not _running or _backend_terrain == null or _effect == null:
		return
	_process_frame += 1
	_drain_effect_events()
	_retry_prepared_groups()
	_reconcile_active_chunks()
	_submit_native_captures()
	var effect_status: Dictionary = _effect.get_status()
	if bool(effect_status.get("initialization_attempted", false)) \
			and not bool(effect_status.get("initialized", false)) \
			and not str(effect_status.get("last_error", "")).is_empty():
		_fail_closed(str(effect_status.get("last_error", "GPU renderer failed")))


func _submit_native_captures() -> void:
	while _render_request_routes.size() < RENDER_SUBMISSION_CAPACITY:
		var request := Dictionary(_backend_terrain.call(
			"pop_gpu_resident_render_request"
		))
		var request_status := str(request.get("status", ""))
		if request_status in ["EMPTY", "DISABLED"]:
			return
		var request_error := _validate_native_request(request)
		if not request_error.is_empty():
			_reject_native_request(request, request_error)
			continue
		var identity: Dictionary = request.get("identity", {})
		var group_key := _group_key(identity)
		if not _groups.has(group_key) and _groups.size() >= _resident_capacity:
			_reject_native_request(request, "resident chunk capacity reached")
			continue
		var surface := str(identity.get("surface", ""))
		var group: Dictionary = _groups.get(group_key, _new_group(identity))
		if Dictionary(group.get("requests", {})).has(surface):
			_reject_native_request(request, "duplicate resident chunk surface")
			continue
		var batch: Dictionary = request.get("cell_batch", {})
		var sequence := _next_publication_sequence
		_next_publication_sequence += 1
		var render_request_id := int(_effect.submit_explicit_samples(
			batch.get("densities", PackedFloat32Array()),
			batch.get("gradients", PackedVector3Array()),
			batch.get("materials", PackedInt32Array()),
			batch.get("material_authored", PackedByteArray()),
			batch.get("cells", []),
			identity,
			sequence,
			false
		))
		if render_request_id <= 0:
			_reject_native_request(request, str(_effect.get_status().get(
				"last_error", "global renderer rejected resident surface"
			)))
			continue
		var requests: Dictionary = group.get("requests", {})
		var sequences: Dictionary = group.get("sequences", {})
		requests[surface] = request
		sequences[surface] = sequence
		group["requests"] = requests
		group["sequences"] = sequences
		_groups[group_key] = group
		var route := {"group_key": group_key, "surface": surface}
		_render_request_routes[render_request_id] = route
		_entry_routes[_entry_token(identity, sequence)] = route
		_submitted_surfaces += 1


func _drain_effect_events() -> void:
	while true:
		var event: Dictionary = _effect.pop_event()
		if event.is_empty():
			return
		var route := _route_for_event(event)
		if route.is_empty():
			continue
		var group_key := str(route.get("group_key", ""))
		if not _groups.has(group_key):
			continue
		match str(event.get("status", "")):
			"PREPARED":
				_mark_surface(group_key, "prepared", str(route.get("surface", "")))
				_try_validate_group(group_key)
			"ACTIVE":
				_mark_surface(group_key, "activated", str(route.get("surface", "")))
				_try_activate_chunk(group_key)
			"REJECTED":
				_reject_group(group_key, str(event.get("error", "GPU entry rejected")))
			"RETIRED", "SUPERSEDED":
				_mark_surface(group_key, "retired", str(route.get("surface", "")))
				_try_finish_retirement(group_key)


func _try_validate_group(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	if bool(group.get("validated", false)) or not _surface_set_complete(
		group, "prepared"
	):
		return
	if _process_frame < int(group.get("next_validation_frame", 0)):
		return
	var requests: Dictionary = group.get("requests", {})
	for surface in _required_surfaces(group):
		if bool(Dictionary(group.get("native_validated", {})).get(surface, false)):
			continue
		var request: Dictionary = requests.get(surface, {})
		var validation := Dictionary(_backend_terrain.call(
			"validate_gpu_resident_render_request",
			int(request.get("request_id", 0)),
			Dictionary(request.get("identity", {}))
		))
		var validation_status := str(validation.get("status", ""))
		if bool(validation.get("request_accepted", false)):
			var native_validated: Dictionary = group.get("native_validated", {})
			native_validated[surface] = true
			group["native_validated"] = native_validated
			_groups[group_key] = group
			_validated_surfaces += 1
		if validation_status not in ["READY", "WAITING_APPLICATION"]:
			_reject_group(group_key, str(validation.get(
				"error", "native resident admission rejected the chunk"
			)))
			return
	if not _surface_set_complete(group, "native_validated"):
		return
	var terrain_request: Dictionary = requests.get("terrain", {})
	var readiness := Dictionary(_backend_terrain.call(
		"get_gpu_resident_render_chunk_readiness",
		Dictionary(terrain_request.get("identity", {}))
	))
	if str(readiness.get("status", "")) == "WAITING_APPLICATION":
		var wait_started := int(group.get(
			"application_wait_started_frame", -1
		))
		if wait_started < 0:
			wait_started = _process_frame
		group["application_wait_started_frame"] = wait_started
		group["next_validation_frame"] = (
			_process_frame + APPLICATION_WAIT_RETRY_FRAMES
		)
		_groups[group_key] = group
		if _process_frame - wait_started >= APPLICATION_WAIT_FRAME_LIMIT:
			_application_wait_expirations += 1
			_reject_group(
				group_key,
				"GPU resident CPU-application wait expired"
			)
		return
	if str(readiness.get("status", "")) != "READY" \
			or not bool(readiness.get("ready", false)):
		_reject_group(group_key, str(readiness.get(
			"error", "native resident chunk readiness rejected the chunk"
		)))
		return
	group["validated"] = true
	_groups[group_key] = group
	var sequences: Dictionary = group.get("sequences", {})
	var activation_entries: Array[Dictionary] = []
	for surface in _required_surfaces(group):
		var request: Dictionary = requests.get(surface, {})
		activation_entries.append({
			"identity": Dictionary(request.get("identity", {})),
			"publication_sequence": int(sequences.get(surface, 0)),
		})
	if not _effect.activate_entries(activation_entries):
		_reject_group(group_key, "global renderer rejected chunk activation set")


func _retry_prepared_groups() -> void:
	var group_keys := _groups.keys()
	for group_key_value in group_keys:
		var group_key := str(group_key_value)
		if not _groups.has(group_key):
			continue
		var group: Dictionary = _groups[group_key]
		if not bool(group.get("validated", false)) \
				and not bool(group.get("retiring", false)):
			_try_validate_group(group_key)


func _try_activate_chunk(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	if bool(group.get("active", false)) or not _surface_set_complete(
		group, "activated"
	):
		return
	var activation := Dictionary(_backend_terrain.call(
		"set_gpu_resident_render_chunk_active", _group_identities(group), true
	))
	if str(activation.get("status", "")) != "ACTIVE" \
			or not bool(activation.get("active", false)):
		_reject_group(group_key, str(activation.get(
			"error", "native chunk activation became stale"
		)))
		return
	group["active"] = true
	_groups[group_key] = group
	_activated_chunks += 1


func _reconcile_active_chunks() -> void:
	var terrain_identities: Array = []
	var group_by_identity: Dictionary = {}
	for group_key in _groups:
		var group: Dictionary = _groups[group_key]
		if not bool(group.get("active", false)):
			continue
		var terrain_identity: Dictionary = Dictionary(
			Dictionary(group.get("requests", {})).get("terrain", {})
		).get("identity", {})
		terrain_identities.append(terrain_identity)
		group_by_identity[_group_key(terrain_identity)] = group_key
	if terrain_identities.is_empty():
		return
	var reconciliation := Dictionary(_backend_terrain.call(
		"reconcile_gpu_resident_render_chunks", terrain_identities
	))
	if str(reconciliation.get("status", "")) != "PASS":
		_fail_closed("native resident reconciliation failed")
		return
	for identity_value in Array(reconciliation.get("retire", [])):
		var identity := Dictionary(identity_value)
		var group_key := str(group_by_identity.get(_group_key(identity), ""))
		if not group_key.is_empty():
			_begin_group_retirement(group_key)


func _reject_group(group_key: String, error: String) -> void:
	if not _groups.has(group_key):
		return
	_last_error = error
	_rejected_chunks += 1
	var group: Dictionary = _groups[group_key]
	if not bool(group.get("validated", false)):
		var native_validated: Dictionary = group.get("native_validated", {})
		for surface in Dictionary(group.get("requests", {})):
			if bool(native_validated.get(surface, false)):
				continue
			var request_value = Dictionary(group.get("requests", {}))[surface]
			var request := Dictionary(request_value)
			_reject_native_request(request, error)
	_begin_group_retirement(group_key)


func _begin_group_retirement(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	if bool(group.get("retiring", false)):
		return
	group["retiring"] = true
	_groups[group_key] = group
	var requests: Dictionary = group.get("requests", {})
	var sequences: Dictionary = group.get("sequences", {})
	for surface in requests:
		var identity: Dictionary = Dictionary(requests[surface]).get("identity", {})
		_effect.retire_entry(identity, int(sequences.get(surface, 0)))
	if requests.is_empty():
		_try_finish_retirement(group_key)


func _try_finish_retirement(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	if not _surface_set_complete(group, "retired", false):
		return
	if bool(group.get("active", false)):
		_backend_terrain.call(
			"set_gpu_resident_render_chunk_active", _group_identities(group), false
		)
		_retired_chunks += 1
	_cleanup_group(group_key)


func _restore_cpu_and_release_native_requests() -> void:
	if _backend_terrain == null or not is_instance_valid(_backend_terrain):
		return
	for group_value in _groups.values():
		var group := Dictionary(group_value)
		if bool(group.get("active", false)):
			_backend_terrain.call(
				"set_gpu_resident_render_chunk_active", _group_identities(group), false
			)
		elif not bool(group.get("validated", false)):
			var native_validated: Dictionary = group.get("native_validated", {})
			for surface in Dictionary(group.get("requests", {})):
				if bool(native_validated.get(surface, false)):
					continue
				var request_value = Dictionary(group.get("requests", {}))[surface]
				_reject_native_request(Dictionary(request_value), "resident renderer stopped")


func _fail_closed(error: String) -> void:
	_last_error = error
	_recovery_count += 1
	stop()


func _reject_native_request(request: Dictionary, error: String) -> void:
	if request.is_empty() or _backend_terrain == null:
		return
	_backend_terrain.call(
		"reject_gpu_resident_render_request",
		int(request.get("request_id", 0)),
		Dictionary(request.get("identity", {})),
		error
	)


func _cleanup_group(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	for request_value in Dictionary(group.get("requests", {})).values():
		var request := Dictionary(request_value)
		var identity: Dictionary = request.get("identity", {})
		var surface := str(identity.get("surface", ""))
		var sequence := int(Dictionary(group.get("sequences", {})).get(surface, 0))
		_entry_routes.erase(_entry_token(identity, sequence))
	var render_request_ids := _render_request_routes.keys()
	for render_request_id in render_request_ids:
		if str(Dictionary(_render_request_routes[render_request_id]).get(
			"group_key", ""
		)) == group_key:
			_render_request_routes.erase(render_request_id)
	_groups.erase(group_key)


func _route_for_event(event: Dictionary) -> Dictionary:
	var request_id := int(event.get("request_id", 0))
	if request_id > 0 and _render_request_routes.has(request_id):
		var route: Dictionary = _render_request_routes[request_id]
		_render_request_routes.erase(request_id)
		return route
	return Dictionary(_entry_routes.get(_entry_token(
		Dictionary(event.get("identity", {})),
		int(event.get("publication_sequence", 0))
	), {}))


func _mark_surface(group_key: String, field: String, surface: String) -> void:
	var group: Dictionary = _groups[group_key]
	var values: Dictionary = group.get(field, {})
	values[surface] = true
	group[field] = values
	_groups[group_key] = group


func _surface_set_complete(
	group: Dictionary, field: String, require_expected: bool = true
) -> bool:
	var values: Dictionary = group.get(field, {})
	var surfaces: Array = _required_surfaces(group) if require_expected \
		else Dictionary(group.get("requests", {})).keys()
	for surface in surfaces:
		if not bool(values.get(surface, false)):
			return false
	return true


func _group_identities(group: Dictionary) -> Array:
	var identities: Array = []
	var requests: Dictionary = group.get("requests", {})
	for surface in _required_surfaces(group):
		identities.append(Dictionary(requests.get(surface, {})).get("identity", {}))
	return identities


static func _new_group(identity: Dictionary) -> Dictionary:
	return {
		"water_expected": bool(identity.get("static_water_surface_expected", false)),
		"requests": {},
		"sequences": {},
		"prepared": {},
		"activated": {},
		"retired": {},
		"native_validated": {},
		"validated": false,
		"active": false,
		"retiring": false,
		"application_wait_started_frame": -1,
		"next_validation_frame": 0,
	}


static func _required_surfaces(group: Dictionary) -> Array[String]:
	return ["terrain", "static_water"] if bool(group.get(
		"water_expected", false
	)) else ["terrain"]


static func _validate_native_request(request: Dictionary) -> String:
	if str(request.get("schema", "")) \
			!= "world_transvoxel.gpu_resident_render_request.v1" \
			or str(request.get("status", "")) != "PASS":
		return "native GPU resident request contract failed"
	if not bool(request.get("gpu_resident_render_publication", false)) \
			or not bool(request.get("cpu_render_visible_until_activation", false)) \
			or not bool(request.get("cpu_collision_publication_unchanged", false)):
		return "native GPU resident request changed publication authority"
	var batch: Dictionary = request.get("cell_batch", {})
	if str(batch.get("status", "")) != "PASS" \
			or bool(batch.get("fallback_used", true)):
		return "native GPU resident cell batch is invalid"
	return ""


static func _group_key(identity: Dictionary) -> String:
	return "%d:%d:%d:%d:g%d:s%d:w%d:t%d" % [
		int(identity.get("page_x", 0)),
		int(identity.get("page_y", 0)),
		int(identity.get("page_z", 0)),
		int(identity.get("lod", 0)),
		int(identity.get("generation", 0)),
		int(identity.get("source_revision", 0)),
		int(identity.get("world_revision", 0)),
		int(identity.get("transition_mask", 0)),
	]


static func _entry_token(identity: Dictionary, sequence: int) -> String:
	return "%s:%s@%d" % [
		str(identity.get("surface", "")), _group_key(identity), sequence
	]

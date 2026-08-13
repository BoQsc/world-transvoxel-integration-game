extends RefCounted

const SCHEMA := "world_transvoxel.cpu_b3a_lod_opening_capture.v1"
const REQUIRED_PROFILE := &"g23_four_biomes_lakes_mountains_roads_2k_256_on_demand"
const ROUTE_REPETITIONS := 2
const SAMPLE_CADENCE_FRAMES := 4
const TRACE_DRAIN_CADENCE_FRAMES := 12
const INITIAL_SETTLE_FRAMES := 180
const POST_EVENT_FRAMES := 240
const POST_EVENT_CHECKPOINTS := [0, 1, 3, 8, 16, 32, 60, 120, 240]
const CHUNK_CELLS := 16
const MAXIMUM_LOD := 3
const ROAD_EVIDENCE_EXCLUSION_CELLS := 32.0
const EXPANSIVE_ROAD_SEGMENTS := [
	Vector4(360.0, 360.0, 820.0, 420.0),
	Vector4(820.0, 420.0, 1020.0, 360.0),
	Vector4(1020.0, 360.0, 1640.0, 380.0),
	Vector4(1640.0, 380.0, 1700.0, 900.0),
	Vector4(1700.0, 900.0, 1600.0, 1600.0),
	Vector4(1600.0, 1600.0, 1020.0, 1700.0),
	Vector4(1020.0, 1700.0, 400.0, 1600.0),
	Vector4(400.0, 1600.0, 300.0, 1100.0),
	Vector4(300.0, 1100.0, 400.0, 850.0),
	Vector4(400.0, 850.0, 360.0, 360.0),
	Vector4(400.0, 850.0, 760.0, 1040.0),
	Vector4(760.0, 1040.0, 1024.0, 1024.0),
	Vector4(1024.0, 1024.0, 1280.0, 1000.0),
	Vector4(1280.0, 1000.0, 1700.0, 900.0),
	Vector4(1024.0, 1024.0, 1020.0, 1700.0),
	Vector4(1024.0, 1024.0, 1020.0, 360.0),
	Vector4(760.0, 1040.0, 1020.0, 1700.0),
	Vector4(1280.0, 1000.0, 1600.0, 1600.0),
]

var _host: Node
var _game_world: Node
var _terrain_world: Node
var _backend: Node
var _player: CharacterBody3D
var _camera: Camera3D
var _trace: RefCounted
var _capture_path := ""
var _started_us := 0
var _observer_us_total := 0
var _observer_us_maximum := 0
var _observer_sample_count := 0
var _authoritative_sample_batches := {}
var _authoritative_sample_failures := {}


func run(
	host: Node,
	game_world: Node,
	player: CharacterBody3D,
	selected_profile: StringName,
	capture_path: String,
	trace: RefCounted
) -> Dictionary:
	_host = host
	_game_world = game_world
	_player = player
	_trace = trace
	_capture_path = capture_path
	_started_us = Time.get_ticks_usec()
	var error := _validate_contract(selected_profile)
	if not error.is_empty():
		return _structural_failure(error)

	_trace.call("begin_phase", "cpu_b3a_road_free_route", "cpu_b3a:route:1", true)
	_trace.call("record", &"cpu_b3a_contract", {
		"profile": str(selected_profile),
		"viewer_route_clear_of_roads": true,
		"every_evidence_ray_road_filtered": true,
		"screenshots_are_supporting_only": true,
		"performance_baseline": false,
		"direct_opening_requires": "background_color_and_front_facing_render_miss_and_collision_or_authoritative_density_crossing",
	}, true)
	if _player.has_method("set_human_input_enabled"):
		_player.call("set_human_input_enabled", false)
	if _player.has_method("set_fly_mode_enabled"):
		_player.call("set_fly_mode_enabled", false)
	_player.velocity = Vector3.ZERO
	_camera.fov = 72.0
	_camera.far = 5000.0

	var route := _road_free_route()
	_apply_pose(route[0], true)
	for _frame in range(INITIAL_SETTLE_FRAMES):
		await _host.get_tree().process_frame
	var baseline_capture := _save_image(_viewport_image(), "baseline")
	var samples := []
	var color_candidates := []
	var confirmed := {}
	var route_frame := 0
	for repetition in range(ROUTE_REPETITIONS):
		for segment_index in range(1, route.size()):
			var previous: Dictionary = route[segment_index - 1]
			var current: Dictionary = route[segment_index]
			var frames := int(current.get("frames", 60))
			for frame in range(1, frames + 1):
				route_frame += 1
				var t := float(frame) / float(maxi(frames, 1))
				var previous_position: Vector3 = previous.get("position", _player.global_position)
				var current_position: Vector3 = current.get("position", _player.global_position)
				var previous_target: Vector3 = previous.get("target", Vector3.ZERO)
				var current_target: Vector3 = current.get("target", Vector3.ZERO)
				_apply_pose({
					"position": previous_position.lerp(current_position, t),
					"target": previous_target.lerp(current_target, t),
				}, false)
				await _host.get_tree().process_frame
				if route_frame % TRACE_DRAIN_CADENCE_FRAMES == 0:
					_trace.call("record", &"cpu_b3a_route_checkpoint", {
						"route_frame": route_frame,
						"repetition": repetition,
						"segment": segment_index,
					}, true)
				if route_frame % SAMPLE_CADENCE_FRAMES != 0:
					continue
				var observed := _observe_frame(
					"r%02d_s%02d_f%03d" % [repetition, segment_index, frame],
					route_frame
				)
				samples.append(_observation_digest(observed))
				if not bool(observed.get("color_candidate", false)):
					continue
				var evidence := await _confirm_observation(observed)
				if color_candidates.is_empty():
					evidence["capture_path"] = _save_image(
						observed.get("image", null), "first_color_candidate"
					)
				color_candidates.append(_observation_digest(evidence, true))
				if bool(evidence.get("direct_opening_confirmed", false)):
					confirmed = evidence
					break
			if not confirmed.is_empty():
				break
		if not confirmed.is_empty():
			break

	var post_event := []
	var classification := "NOT_REPRODUCED_IN_BOUNDED_ROAD_FILTERED_ROUTE"
	if not confirmed.is_empty():
		classification = _preliminary_classification(confirmed)
		var selected_chunk: Dictionary = confirmed.get("selected_trace_chunk", {})
		if not selected_chunk.is_empty():
			_trace.call(
				"set_target_chunk",
				_vector3i_from_summary(selected_chunk.get("coordinate", {})),
				int(selected_chunk.get("lod", 0)),
				int(selected_chunk.get("generation", 0))
			)
		_trace.call("begin_phase", "cpu_b3a_opening_settle", "cpu_b3a:opening:1", true)
		_trace.call("record", &"cpu_b3a_opening_confirmed", {
			"classification": classification,
			"route_frame": int(confirmed.get("route_frame", -1)),
			"selected_trace_chunk": selected_chunk,
		}, true)
		post_event = await _capture_post_event_window(confirmed)

	var final_capture := _save_image(_viewport_image(), "final")
	var trace_reason := (
		"cpu_b3a_opening_captured" if not confirmed.is_empty()
		else "cpu_b3a_not_reproduced"
	)
	var trace_result: Dictionary = _trace.call("finalize", trace_reason)
	var report := {
		"schema": SCHEMA,
		"ok": bool(trace_result.get("ok", false)) and bool(trace_result.get("native_complete", false)),
		"status": "CAUSAL_EVENT_CAPTURED" if not confirmed.is_empty() else "BOUNDED_ROUTE_COMPLETE_NO_EVENT",
		"classification": classification,
		"profile": str(selected_profile),
		"implementation_changed": false,
		"capture_contract": {
			"route": "g23_road_filtered_snow_grass_pocket_v1",
			"route_repetitions": ROUTE_REPETITIONS,
			"sample_cadence_frames": SAMPLE_CADENCE_FRAMES,
			"post_event_frames": POST_EVENT_FRAMES,
			"direct_opening_requires": [
				"sky-like or near-black pixel inside downward terrain-only screen region",
				"no front-facing render triangle on the full same camera ray",
				"physics collision hit or authoritative air-to-solid density crossing on that ray",
			],
			"screenshots_are_authority": false,
			"aggregate_queue_counts_are_authority": false,
			"native_chunk_lifecycle_required": true,
			"performance_baseline": false,
		},
		"route_exclusion": _route_exclusion_contract(),
		"baseline_capture_path": baseline_capture,
		"final_capture_path": final_capture,
		"route_frame_count": route_frame,
		"sample_count": samples.size(),
		"color_candidate_count": color_candidates.size(),
		"excluded_authored_road_ray_count": _candidate_ray_count(
			color_candidates, "excluded_authored_road_rays"
		),
		"rendered_road_clear_ray_count": _candidate_ray_count(
			color_candidates, "rendered_road_clear_rays"
		),
		"direct_opening_count": 0 if confirmed.is_empty() else 1,
		"samples": samples,
		"color_candidates": color_candidates,
		"confirmed_observation": _observation_digest(confirmed, true),
		"post_event": post_event,
		"final_runtime": _runtime_digest(),
		"trace": trace_result,
		"observer": {
			"sample_count": _observer_sample_count,
			"capture_us_total": _observer_us_total,
			"capture_us_maximum": _observer_us_maximum,
			"capture_us_mean": float(_observer_us_total) / float(maxi(1, _observer_sample_count)),
		},
		"duration_us": Time.get_ticks_usec() - _started_us,
		"claim_boundary": (
			"No road-clear temporary LOD opening was reproduced by this bounded road-filtered route; this does not prove absence."
			if confirmed.is_empty() else
			"The opening is established by correlated screen, physics, render-mesh, chunk-generation, and native lifecycle evidence; the screenshot is supporting evidence only."
		),
		"performance_claim_boundary": "Synchronous image readback, exact mesh-ray traversal, authoritative sampling, and trace drainage make this correctness capture unsuitable for frame-time or throughput claims.",
	}
	var report_path := _report_path()
	report["report_path"] = report_path
	if not _write_json(report_path, report):
		report["ok"] = false
		report["write_error"] = "report_write_failed"
	return report


func _validate_contract(selected_profile: StringName) -> String:
	if _host == null or _game_world == null or _player == null:
		return "host_game_world_or_player_unavailable"
	if selected_profile != REQUIRED_PROFILE:
		return "cpu_b3a_requires_g23"
	if _capture_path.is_empty():
		return "capture_path_empty"
	_terrain_world = _game_world.call("get_terrain_world")
	if _terrain_world == null:
		return "terrain_world_unavailable"
	if not _terrain_world.has_method("query_chunk_state"):
		return "chunk_state_query_unavailable"
	if _terrain_world.has_method("get_backend_terrain"):
		_backend = _terrain_world.call("get_backend_terrain")
	if _backend == null:
		return "backend_terrain_unavailable"
	_camera = _player.get_node_or_null("FirstPersonCamera") as Camera3D
	if _camera == null:
		return "first_person_camera_unavailable"
	if _trace == null or not bool(_trace.call("is_active")):
		return "complete_cpu_causal_trace_required"
	return ""


func _road_free_route() -> Array:
	return [
		{"position": Vector3(1160.0, 146.0, 1260.0), "target": Vector3(1240.0, 34.0, 1380.0)},
		{"position": Vector3(1300.0, 142.0, 1320.0), "target": Vector3(1260.0, 34.0, 1430.0), "frames": 60},
		{"position": Vector3(1180.0, 148.0, 1480.0), "target": Vector3(1280.0, 38.0, 1440.0), "frames": 72},
		{"position": Vector3(1320.0, 146.0, 1500.0), "target": Vector3(1240.0, 34.0, 1420.0), "frames": 60},
		{"position": Vector3(1160.0, 146.0, 1260.0), "target": Vector3(1240.0, 34.0, 1380.0), "frames": 72},
	]


func _route_exclusion_contract() -> Dictionary:
	return {
		"road_field": "wt_expansive_road_segments",
		"road_segment_source": "addons/world_transvoxel/src/storage/wt_procedural_road_field.cpp",
		"minimum_viewer_route_road_centerline_clearance_cells": 132.94117647058812,
		"road_surface_and_shoulder_limit_cells": 16.0,
		"minimum_clearance_multiple": 8.308823529411757,
		"evidence_ray_exclusion_cells": ROAD_EVIDENCE_EXCLUSION_CELLS,
		"every_candidate_ray_filtered": true,
		"lake_centers_excluded": [
			{"x": 650.0, "z": 700.0},
			{"x": 1400.0, "z": 700.0},
			{"x": 650.0, "z": 1370.0},
		],
		"cave_fixture_bounds_excluded": true,
		"roads_may_exist_elsewhere_in_profile": true,
	}


func _apply_pose(step: Dictionary, force_viewer: bool) -> void:
	var position: Vector3 = step.get("position", _player.global_position)
	var target: Vector3 = step.get("target", position + Vector3.FORWARD)
	_player.global_position = position
	_player.velocity = Vector3.ZERO
	_camera.look_at_from_position(position, target, Vector3.UP)
	_camera.current = true
	_camera.make_current()
	if _game_world.has_method("update_player_viewer"):
		_game_world.call("update_player_viewer", force_viewer)


func _observe_frame(label: String, route_frame: int) -> Dictionary:
	var started := Time.get_ticks_usec()
	var image := _viewport_image()
	var screen := _terrain_screen_background_summary(image)
	var elapsed := Time.get_ticks_usec() - started
	_observer_us_total += elapsed
	_observer_us_maximum = maxi(_observer_us_maximum, elapsed)
	_observer_sample_count += 1
	return {
		"label": label,
		"route_frame": route_frame,
		"capture_elapsed_us": Time.get_ticks_usec() - _started_us,
		"player_position": _vector3_summary(_player.global_position),
		"camera_position": _vector3_summary(_camera.global_position),
		"screen": screen,
		"color_candidate": int(screen.get("background_sample_count", 0)) > 0,
		"runtime": _runtime_digest(),
		"observer_us": elapsed,
		"image": image,
	}


func _confirm_observation(observation: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	var evidence := observation.duplicate(true)
	evidence.erase("image")
	var pixels: Array = evidence.get("screen", {}).get("examples", [])
	var rays := _screen_pixel_rays(pixels)
	var render_hits: Array = _host.call("_human_artifact_render_ray_hits", _backend, rays)
	var render_by_index := {}
	for render in render_hits:
		if render is Dictionary:
			render_by_index[int(render.get("index", -1))] = render
	var authoritative_proofs := await _authoritative_ray_proofs(rays, render_by_index)
	var direct_rays := []
	var material_false_positive_rays := []
	var excluded_authored_road_rays := []
	var rendered_road_clear_rays := []
	var unconfirmed_rays := []
	for ray in rays:
		var ray_index := int(ray.get("index", -1))
		var render: Dictionary = render_by_index.get(ray_index, {})
		var merged: Dictionary = ray.duplicate(true)
		merged["render"] = render
		merged["authoritative_ray"] = authoritative_proofs.get(ray_index, {})
		var road_distance := _evidence_ray_road_distance(merged)
		merged["authored_road_distance_cells"] = road_distance
		merged["authored_road_excluded"] = road_distance <= ROAD_EVIDENCE_EXCLUSION_CELLS
		if bool(merged["authored_road_excluded"]):
			excluded_authored_road_rays.append(merged)
		elif bool(render.get("render_front_like_hit", false)):
			material_false_positive_rays.append(merged)
			rendered_road_clear_rays.append(merged)
		elif bool(ray.get("physics_hit", false)) or \
				bool(merged["authoritative_ray"].get("air_to_solid_crossing", false)):
			direct_rays.append(merged)
		else:
			unconfirmed_rays.append(merged)
	evidence["screen_pixel_rays"] = rays
	evidence["render_ray_hits"] = render_hits
	evidence["direct_opening_rays"] = direct_rays
	evidence["material_false_positive_rays"] = material_false_positive_rays
	evidence["excluded_authored_road_rays"] = excluded_authored_road_rays
	evidence["rendered_road_clear_rays"] = rendered_road_clear_rays
	evidence["unconfirmed_rays"] = unconfirmed_rays
	evidence["direct_opening_confirmed"] = not direct_rays.is_empty()
	var hit_positions := []
	for direct in direct_rays:
		if bool(direct.get("physics_hit", false)):
			hit_positions.append(_vector3_from_summary(direct.get("hit_position", {})))
		else:
			hit_positions.append(_vector3_from_summary(
				direct.get("authoritative_ray", {}).get("surface_point", {})
			))
	evidence["chunk_neighborhood"] = _chunk_neighborhood(hit_positions)
	evidence["selected_trace_chunk"] = _select_trace_chunk(evidence["chunk_neighborhood"])
	var elapsed := Time.get_ticks_usec() - started
	evidence["confirmation_observer_us"] = elapsed
	_observer_us_total += elapsed
	_observer_us_maximum = maxi(_observer_us_maximum, elapsed)
	return evidence


func _capture_post_event_window(observation: Dictionary) -> Array:
	var pixels: Array = observation.get("screen", {}).get("examples", [])
	var authoritative_indices := {}
	for ray in observation.get("direct_opening_rays", []):
		if bool(ray.get("authoritative_ray", {}).get("air_to_solid_crossing", false)):
			authoritative_indices[int(ray.get("index", -1))] = true
	var output := []
	for frame in range(POST_EVENT_FRAMES + 1):
		if frame > 0:
			await _host.get_tree().process_frame
		if frame not in POST_EVENT_CHECKPOINTS:
			continue
		var image := _viewport_image()
		var fixed := _fixed_pixel_evidence(pixels, image, authoritative_indices)
		fixed["frame"] = frame
		fixed["capture_elapsed_us"] = Time.get_ticks_usec() - _started_us
		fixed["runtime"] = _runtime_digest()
		if frame in [0, 8, 32, 120, 240]:
			fixed["capture_path"] = _save_image(image, "settle_%03d" % frame)
		output.append(fixed)
	return output


func _fixed_pixel_evidence(
	pixels: Array,
	image: Image,
	authoritative_indices: Dictionary
) -> Dictionary:
	var current_pixels := []
	for pixel in pixels:
		var x := clampi(int(pixel.get("x", 0)), 0, maxi(0, image.get_width() - 1))
		var y := clampi(int(pixel.get("y", 0)), 0, maxi(0, image.get_height() - 1))
		var color := image.get_pixel(x, y)
		current_pixels.append({
			"x": x, "y": y, "r": color.r, "g": color.g, "b": color.b,
			"background_like": _is_background_like(color),
		})
	var rays := _screen_pixel_rays(current_pixels)
	var render_hits: Array = _host.call("_human_artifact_render_ray_hits", _backend, rays)
	var render_by_index := {}
	for render in render_hits:
		if render is Dictionary:
			render_by_index[int(render.get("index", -1))] = render
	var direct_count := 0
	var hit_positions := []
	for ray in rays:
		var pixel: Dictionary = ray.get("pixel", {})
		var render: Dictionary = render_by_index.get(int(ray.get("index", -1)), {})
		if bool(pixel.get("background_like", false)) and \
				not bool(render.get("render_front_like_hit", false)) and \
				(bool(ray.get("physics_hit", false)) or authoritative_indices.has(int(ray.get("index", -1)))):
			direct_count += 1
			hit_positions.append(_vector3_from_summary(ray.get("hit_position", {})))
	return {
		"pixels": current_pixels,
		"screen_pixel_rays": rays,
		"render_ray_hits": render_hits,
		"direct_opening_ray_count": direct_count,
		"direct_opening_persists": direct_count > 0,
		"chunk_neighborhood": _chunk_neighborhood(hit_positions),
	}


func _terrain_screen_background_summary(image: Image) -> Dictionary:
	if image == null or image.get_width() <= 0 or image.get_height() <= 0:
		return {"available": false, "background_sample_count": 0, "examples": []}
	var width := image.get_width()
	var height := image.get_height()
	var left := int(width * 0.18)
	var right := int(width * 0.82)
	var top := int(height * 0.12)
	var sky_top := int(height * 0.56)
	var bottom := int(height * 0.92)
	var stride := 4
	var count := 0
	var sky_count := 0
	var dark_count := 0
	var examples := []
	for y in range(top, bottom, stride):
		for x in range(left, right, stride):
			var color := image.get_pixel(x, y)
			if not _is_background_like(color):
				continue
			if _is_sky_like(color) and y < sky_top:
				continue
			count += 1
			if _is_sky_like(color):
				sky_count += 1
			else:
				dark_count += 1
			if examples.size() < 12:
				examples.append({
					"x": x, "y": y, "r": color.r, "g": color.g, "b": color.b,
					"background_like": true,
					"background_kind": "sky" if _is_sky_like(color) else "near_black",
				})
	return {
		"available": true,
		"width": width,
		"height": height,
		"stride": stride,
		"region": {
			"left": left, "right": right, "top": top, "bottom": bottom,
			"sky_candidate_top": sky_top,
		},
		"background_sample_count": count,
		"sky_sample_count": sky_count,
		"near_black_sample_count": dark_count,
		"examples": examples,
	}


func _is_sky_like(color: Color) -> bool:
	return color.b >= 0.65 and color.g >= 0.45 and color.r <= 0.72 and \
		color.b >= color.r + 0.10 and color.b >= color.g + 0.02


func _is_background_like(color: Color) -> bool:
	return _is_sky_like(color) or maxf(color.r, maxf(color.g, color.b)) <= 0.12


func _screen_pixel_rays(pixels: Array) -> Array:
	if _host.get_world_3d() == null:
		return []
	var reports := []
	var direct_space_state: PhysicsDirectSpaceState3D = _host.get_world_3d().direct_space_state
	for index in range(pixels.size()):
		var pixel: Dictionary = pixels[index]
		var screen_point := Vector2(float(pixel.get("x", 0.0)), float(pixel.get("y", 0.0)))
		var origin := _camera.project_ray_origin(screen_point)
		var direction := _camera.project_ray_normal(screen_point).normalized()
		var max_distance := 1024.0
		var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * max_distance)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		if _player is CollisionObject3D:
			query.exclude = [(_player as CollisionObject3D).get_rid()]
		var hit: Dictionary = direct_space_state.intersect_ray(query)
		var report := {
			"index": index,
			"pixel": pixel,
			"origin": _vector3_summary(origin),
			"direction": _vector3_summary(direction),
			"max_distance": max_distance,
			"render_max_distance": max_distance,
			"physics_hit": not hit.is_empty(),
		}
		if not hit.is_empty():
			var position: Vector3 = hit.get("position", origin)
			report["hit_position"] = _vector3_summary(position)
			report["hit_distance"] = origin.distance_to(position)
			report["hit_normal"] = _vector3_summary(hit.get("normal", Vector3.ZERO))
			var collider = hit.get("collider", null)
			report["hit_collider"] = str(collider.name) if collider is Node else str(collider)
		reports.append(report)
	return reports


func _authoritative_ray_proofs(rays: Array, render_by_index: Dictionary) -> Dictionary:
	var ray_point_keys := {}
	var points := []
	var point_seen := {}
	for ray in rays:
		var ray_index := int(ray.get("index", -1))
		var render: Dictionary = render_by_index.get(ray_index, {})
		if bool(render.get("render_front_like_hit", false)):
			continue
		var origin := _vector3_from_summary(ray.get("origin", {}))
		var direction := _vector3_from_summary(ray.get("direction", {})).normalized()
		var keys := []
		for distance in range(4, 769, 4):
			var point := Vector3i(
				roundi(origin.x + direction.x * distance),
				roundi(origin.y + direction.y * distance),
				roundi(origin.z + direction.z * distance)
			)
			if point.x < 0 or point.x > 2048 or point.z < 0 or point.z > 2048 or \
					point.y < -128 or point.y > 128:
				continue
			var key := _grid_point_key(point)
			if keys.is_empty() or keys.back() != key:
				keys.append(key)
			if not point_seen.has(key):
				point_seen[key] = true
				points.append(point)
		ray_point_keys[ray_index] = keys
	if points.is_empty():
		return {}
	_ensure_authoritative_sample_connections()
	var request_id := int(_terrain_world.call("request_authoritative_samples", points, 0))
	if request_id <= 0:
		return {}
	var samples := []
	for _frame in range(240):
		if _authoritative_sample_failures.has(request_id):
			_authoritative_sample_failures.erase(request_id)
			return {}
		if _authoritative_sample_batches.has(request_id):
			samples = _authoritative_sample_batches[request_id]
			_authoritative_sample_batches.erase(request_id)
			break
		await _host.get_tree().process_frame
	var by_key := {}
	for sample in samples:
		if sample == null:
			continue
		var point: Vector3i = sample.call("get_grid_point")
		by_key[_grid_point_key(point)] = {
			"point": _vector3i_summary(point),
			"density": float(sample.call("get_density")),
			"material": int(sample.call("get_material")),
			"world_revision": int(sample.call("get_world_revision")),
		}
	var output := {}
	for ray_index in ray_point_keys:
		var observed := []
		var crossing := false
		var surface_point := {}
		var previous_density := INF
		for key in ray_point_keys[ray_index]:
			if not by_key.has(key):
				continue
			var sample: Dictionary = by_key[key]
			var density := float(sample.get("density", INF))
			observed.append(sample)
			if previous_density > 0.0 and density <= 0.0:
				crossing = true
				surface_point = sample.get("point", {})
				break
			previous_density = density
		output[ray_index] = {
			"air_to_solid_crossing": crossing,
			"surface_point": surface_point,
			"sample_count": observed.size(),
			"samples": observed,
		}
	return output


func _ensure_authoritative_sample_connections() -> void:
	var ready_callable := Callable(self, "_on_authoritative_samples_ready")
	if not _terrain_world.is_connected("authoritative_samples_ready", ready_callable):
		_terrain_world.connect("authoritative_samples_ready", ready_callable)
	var failed_callable := Callable(self, "_on_authoritative_samples_failed")
	if not _terrain_world.is_connected("authoritative_samples_failed", failed_callable):
		_terrain_world.connect("authoritative_samples_failed", failed_callable)


func _on_authoritative_samples_ready(request_id: int, samples: Array) -> void:
	_authoritative_sample_batches[request_id] = samples


func _on_authoritative_samples_failed(request_id: int, error: String) -> void:
	_authoritative_sample_failures[request_id] = error


func _grid_point_key(point: Vector3i) -> String:
	return "%d,%d,%d" % [point.x, point.y, point.z]


func _evidence_ray_road_distance(ray: Dictionary) -> float:
	var position := Vector3(INF, INF, INF)
	var render: Dictionary = ray.get("render", {})
	if bool(render.get("render_front_like_hit", false)):
		position = _vector3_from_summary(render.get("render_front_like_position", {}))
	elif bool(ray.get("physics_hit", false)):
		position = _vector3_from_summary(ray.get("hit_position", {}))
	elif bool(ray.get("authoritative_ray", {}).get("air_to_solid_crossing", false)):
		position = _vector3_from_summary(ray.get("authoritative_ray", {}).get("surface_point", {}))
	if is_inf(position.x):
		return INF
	var minimum := INF
	var point := Vector2(position.x, position.z)
	for segment_value in EXPANSIVE_ROAD_SEGMENTS:
		var segment: Vector4 = segment_value
		var a := Vector2(segment.x, segment.y)
		var b := Vector2(segment.z, segment.w)
		var ab := b - a
		var t := clampf((point - a).dot(ab) / maxf(ab.length_squared(), 1.0), 0.0, 1.0)
		minimum = minf(minimum, point.distance_to(a + ab * t))
	return minimum


func _candidate_ray_count(candidates: Array, key: String) -> int:
	var count := 0
	for candidate in candidates:
		if candidate is Dictionary:
			count += Array(candidate.get(key, [])).size()
	return count


func _chunk_neighborhood(hit_positions: Array) -> Array:
	var output := []
	var seen := {}
	for position_value in hit_positions:
		var position: Vector3 = position_value
		for lod in range(MAXIMUM_LOD + 1):
			var extent := float(CHUNK_CELLS * int(1 << lod))
			var center := Vector3i(
				floori(position.x / extent),
				floori(position.y / extent),
				floori(position.z / extent)
			)
			for dz in range(-1, 2):
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var coordinate := center + Vector3i(dx, dy, dz)
						var key := "%d:%d,%d,%d" % [lod, coordinate.x, coordinate.y, coordinate.z]
						if seen.has(key):
							continue
						seen[key] = true
						var summary := _chunk_state_summary(coordinate, lod)
						summary["contains_target_position"] = coordinate == center
						output.append(summary)
	return output


func _chunk_state_summary(coordinate: Vector3i, lod: int) -> Dictionary:
	var state: RefCounted = _terrain_world.call("query_chunk_state", coordinate, lod)
	var summary := {
		"coordinate": _vector3i_summary(coordinate), "lod": lod, "present": false,
		"generation": 0, "visual_required": false, "visual_ready": false,
		"render_generation": 0, "staged_render_generation": 0,
		"collision_required": false, "collision_ready": false,
		"collision_generation": 0, "staged_collision_generation": 0,
	}
	if state == null:
		return summary
	summary["present"] = bool(state.call("is_present"))
	var methods := {
		"get_generation": "generation",
		"is_visual_required": "visual_required",
		"is_visual_ready": "visual_ready",
		"get_render_generation": "render_generation",
		"get_staged_render_generation": "staged_render_generation",
		"is_collision_required": "collision_required",
		"is_collision_ready": "collision_ready",
		"get_collision_generation": "collision_generation",
		"get_staged_collision_generation": "staged_collision_generation",
	}
	for method in methods:
		if state.has_method(method):
			summary[methods[method]] = state.call(method)
	return summary


func _select_trace_chunk(neighborhood: Array) -> Dictionary:
	for state in neighborhood:
		if bool(state.get("contains_target_position", false)) and \
				bool(state.get("present", false)) and \
				bool(state.get("visual_required", false)):
			return state
	for state in neighborhood:
		if bool(state.get("contains_target_position", false)) and bool(state.get("present", false)):
			return state
	return {}


func _preliminary_classification(observation: Dictionary) -> String:
	var runtime: Dictionary = observation.get("runtime", {})
	if int(runtime.get("pending_retirement_records_missing", 0)) > 0:
		return "RETIREMENT_COVERAGE_LOSS_CANDIDATE"
	for state in observation.get("chunk_neighborhood", []):
		if not bool(state.get("contains_target_position", false)):
			continue
		if bool(state.get("visual_required", false)) and not bool(state.get("visual_ready", false)):
			return "RESIDENCY_OR_REPLACEMENT_READINESS_CANDIDATE"
		if bool(state.get("visual_ready", false)) and \
				int(state.get("render_generation", 0)) != int(state.get("generation", 0)):
			return "PUBLICATION_ORDERING_CANDIDATE"
	return "VISIBILITY_COVERAGE_CANDIDATE"


func _runtime_digest() -> Dictionary:
	var summary: Dictionary = _game_world.call("get_game_world_summary")
	var output := {}
	for key in [
		"active_chunk_records", "visual_ready_chunk_records",
		"non_retiring_chunk_records", "non_retiring_visual_ready_chunk_records",
		"pending_retirement_records", "pending_retirement_records_missing",
		"pending_chunk_retirements", "pending_chunk_replacements",
		"blocked_pending_chunk_replacements", "render_resources",
		"staged_render_resources", "render_fading_resources", "queued_render",
		"collision_resources", "queued_collision", "total_collision_backlog",
		"scheduler_queued_jobs", "scheduler_queued_completions",
		"application_sink_failures", "application_queue_rejections",
		"player_viewer_updates", "player_collision_viewer_updates",
	]:
		output[key] = int(summary.get(key, 0))
	return output


func _observation_digest(observation: Dictionary, include_evidence: bool = false) -> Dictionary:
	if observation.is_empty():
		return {}
	var output := {
		"label": str(observation.get("label", "")),
		"route_frame": int(observation.get("route_frame", -1)),
		"capture_elapsed_us": int(observation.get("capture_elapsed_us", -1)),
		"player_position": observation.get("player_position", {}),
		"camera_position": observation.get("camera_position", {}),
		"screen": observation.get("screen", {}),
		"color_candidate": bool(observation.get("color_candidate", false)),
		"runtime": observation.get("runtime", {}),
		"observer_us": int(observation.get("observer_us", 0)),
	}
	if include_evidence:
		for key in [
			"direct_opening_confirmed", "screen_pixel_rays", "render_ray_hits",
			"direct_opening_rays", "material_false_positive_rays",
			"excluded_authored_road_rays", "rendered_road_clear_rays", "unconfirmed_rays",
			"chunk_neighborhood", "selected_trace_chunk", "confirmation_observer_us",
			"capture_path",
		]:
			if observation.has(key):
				output[key] = observation[key]
	return output


func _viewport_image() -> Image:
	if DisplayServer.get_name() == "headless":
		return null
	var texture := _host.get_viewport().get_texture()
	return texture.get_image() if texture != null else null


func _save_image(image: Image, label: String) -> String:
	if image == null:
		return ""
	var path := _variant_path(label)
	return path if image.save_png(path) == OK else ""


func _variant_path(label: String) -> String:
	var dot := _capture_path.rfind(".")
	if dot > 0:
		return _capture_path.substr(0, dot) + "_cpu_b3a_" + label + ".png"
	return _capture_path + "_cpu_b3a_" + label + ".png"


func _report_path() -> String:
	var dot := _capture_path.rfind(".")
	if dot > 0:
		return _capture_path.substr(0, dot) + "_cpu_b3a.json"
	return _capture_path + "_cpu_b3a.json"


func _write_json(path: String, value: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(value, "\t") + "\n")
	file.close()
	return true


func _structural_failure(error: String) -> Dictionary:
	return {
		"schema": SCHEMA,
		"ok": false,
		"status": "STRUCTURAL_FAILURE",
		"error": error,
		"implementation_changed": false,
	}


func _vector3_summary(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}


func _vector3i_summary(value: Vector3i) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}


func _vector3_from_summary(value) -> Vector3:
	if value is Vector3:
		return value
	if value is Dictionary:
		return Vector3(
			float(value.get("x", 0.0)),
			float(value.get("y", 0.0)),
			float(value.get("z", 0.0))
		)
	return Vector3.ZERO


func _vector3i_from_summary(value) -> Vector3i:
	if value is Vector3i:
		return value
	if value is Dictionary:
		return Vector3i(
			int(value.get("x", 0)),
			int(value.get("y", 0)),
			int(value.get("z", 0))
		)
	return Vector3i.ZERO

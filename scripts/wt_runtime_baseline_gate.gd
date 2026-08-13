extends RefCounted

const FOUR_BIOME_WORLD_PROFILE := &"g23_four_biomes_lakes_mountains_roads_2k_256_on_demand"
const CHUNK_SIZE := 16.0
const WARMUP_FRAMES := 60
const NORMAL_FLIGHT_FRAMES := 180
const FAST_FLIGHT_FRAMES := 180
const FAST_AXIS_FLIGHT_FRAMES := 120
const STOP_FRAMES := 45
const AXIS_STOP_FRAMES := 30
const FINAL_STOP_FRAMES := 90
const PHYSICS_TARGET_WAIT_FRAMES := 180
const EDIT_COMMIT_WAIT_FRAMES := 300
const EDIT_READY_WAIT_FRAMES := 900
const FIXED_POST_FLIGHT_EDIT_POSITION := Vector3(560.0, 74.0, 560.0)
const MINIMUM_ROUTE_NET_DISPLACEMENT := 340.0
const MAXIMUM_BLOCKED_MOVEMENT_FRAMES := 20
const MAXIMUM_CONSECUTIVE_BLOCKED_MOVEMENT_FRAMES := 10
const MAXIMUM_FRAME_P95_MS := 20.0
const MAXIMUM_FRAME_P99_MS := 33.3
const MAXIMUM_PHYSICS_TARGET_WAIT_FRAMES := 30
const MAXIMUM_AUTHORITY_COMMIT_FRAMES := 15
const MAXIMUM_VISUAL_READY_FRAMES_AFTER_COMMIT := 15
const MAXIMUM_COLLISION_READY_FRAMES_AFTER_COMMIT := 15
const MAXIMUM_VISUAL_COLLISION_DIVERGENCE_FRAMES := 8

var _causal_trace: RefCounted


func run(
	host: Node,
	game_world: Node,
	player: CharacterBody3D,
	selected_profile: StringName,
	causal_trace_output_path: String = ""
) -> Dictionary:
	if host == null or game_world == null or player == null:
		return _structural_failure("host_game_world_or_player_unavailable")
	if selected_profile != FOUR_BIOME_WORLD_PROFILE:
		return _structural_failure("runtime_baseline_requires_g23")
	var terrain_world: Node = game_world.call("get_terrain_world")
	if terrain_world == null:
		return _structural_failure("terrain_world_unavailable")
	if not causal_trace_output_path.is_empty():
		var TraceScript := load("res://scripts/wt_cpu_causal_trace.gd")
		_causal_trace = TraceScript.new()
		if not bool(_causal_trace.call(
			"start", host, game_world, terrain_world, player,
			causal_trace_output_path, "deterministic_cpu_b2"
		)):
			return _structural_failure(
				"causal_trace_start_failed:%s" % str(
					_causal_trace.call("get_start_error")
				)
			)
		if game_world.has_method("set_cpu_causal_trace"):
			game_world.call("set_cpu_causal_trace", _causal_trace)

	if player.has_method("set_human_input_enabled"):
		player.call("set_human_input_enabled", false)
	if player.has_method("set_fly_mode_enabled"):
		player.call("set_fly_mode_enabled", true)
	player.velocity = Vector3.ZERO

	var clock := {
		"last_tick_us": Time.get_ticks_usec(),
		"all_frame_us": [],
	}
	var backlog := _empty_backlog_summary()
	var phases := []
	var diagonal_direction := Vector3(1.0, -0.02, 1.0).normalized()
	var x_direction := Vector3.RIGHT
	var z_direction := Vector3.BACK
	var normal_speed := float(player.get("fly_speed"))
	var fast_speed := normal_speed * float(player.get("fly_fast_multiplier"))
	var start_position := player.global_position
	var runtime_metrics_start: Dictionary = terrain_world.call("get_runtime_metrics")

	phases.append(await _run_stop_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"warmup", WARMUP_FRAMES
	))
	phases.append(await _run_movement_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"normal_outbound", diagonal_direction * normal_speed, NORMAL_FLIGHT_FRAMES
	))
	phases.append(await _run_stop_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"normal_stop", STOP_FRAMES
	))
	phases.append(await _run_movement_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"normal_return", -diagonal_direction * normal_speed, NORMAL_FLIGHT_FRAMES
	))
	phases.append(await _run_stop_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"return_stop", STOP_FRAMES
	))
	phases.append(await _run_movement_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"fast_x_outbound", x_direction * fast_speed, FAST_AXIS_FLIGHT_FRAMES
	))
	phases.append(await _run_stop_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"fast_x_outbound_stop", AXIS_STOP_FRAMES
	))
	phases.append(await _run_movement_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"fast_x_return", -x_direction * fast_speed, FAST_AXIS_FLIGHT_FRAMES
	))
	phases.append(await _run_stop_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"fast_x_return_stop", AXIS_STOP_FRAMES
	))
	phases.append(await _run_movement_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"fast_z_outbound", z_direction * fast_speed, FAST_AXIS_FLIGHT_FRAMES
	))
	phases.append(await _run_stop_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"fast_z_outbound_stop", AXIS_STOP_FRAMES
	))
	phases.append(await _run_movement_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"fast_z_return", -z_direction * fast_speed, FAST_AXIS_FLIGHT_FRAMES
	))
	phases.append(await _run_stop_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"fast_z_return_stop", AXIS_STOP_FRAMES
	))
	phases.append(await _run_movement_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"fast_diagonal_outbound",
		diagonal_direction * fast_speed,
		FAST_FLIGHT_FRAMES
	))
	phases.append(await _run_stop_phase(
		host, game_world, terrain_world, player, clock, backlog,
		"pre_edit_stop", FINAL_STOP_FRAMES
	))

	var movement_end_position := player.global_position
	_trace_record(&"relocation_requested", {
		"from": _vector3_summary(movement_end_position),
		"to": _vector3_summary(FIXED_POST_FLIGHT_EDIT_POSITION),
	}, true)
	player.global_position = FIXED_POST_FLIGHT_EDIT_POSITION
	player.velocity = Vector3.ZERO
	if game_world.has_method("update_player_viewer"):
		var relocation_viewer_accepted := bool(
			game_world.call("update_player_viewer", true)
		)
		_trace_record(&"relocation_viewer_submitted", {
			"accepted": relocation_viewer_accepted,
			"position": _vector3_summary(player.global_position),
		}, true)
	var edit_summary := await _run_single_edit_measurement(
		host, game_world, terrain_world, player, clock, backlog
	)
	var runtime_metrics_end: Dictionary = terrain_world.call("get_runtime_metrics")
	var movement_summary := _summarize_movement(phases)
	var all_frame_us: Array = clock["all_frame_us"]
	var frame_time_summary := _frame_time_summary(all_frame_us)
	var route_net_displacement := start_position.distance_to(movement_end_position)
	var collision_apply_deadline_ns := int(
		runtime_metrics_end.get("collision_apply_deadline_ns", 0)
	)
	var maximum_single_collision_apply_ns := int(
		runtime_metrics_end.get("collision_apply_time_ns_maximum", 0)
	)
	var maximum_frame_collision_apply_ns := int(
		runtime_metrics_end.get("collision_apply_frame_time_ns_maximum", 0)
	)
	var collision_apply_soft_bound_ns := (
		collision_apply_deadline_ns +
		maximum_single_collision_apply_ns +
		250000
	)
	var collision_apply_frame_budget_ok := (
		collision_apply_deadline_ns == 0 or
		maximum_frame_collision_apply_ns <= collision_apply_soft_bound_ns
	)
	var measurement_complete := bool(edit_summary.get("measurement_complete", false))
	var acceptance_failures: Array[String] = []
	if not collision_apply_frame_budget_ok:
		acceptance_failures.append("collision_apply_frame_budget")
	if int(movement_summary.get("rejected_zero_motion_frames", -1)) != 0:
		acceptance_failures.append("movement_rejected_zero_motion")
	if float(movement_summary.get("stop_drift_distance", INF)) > 0.01:
		acceptance_failures.append("stop_drift")
	if route_net_displacement < MINIMUM_ROUTE_NET_DISPLACEMENT:
		acceptance_failures.append("route_net_displacement")
	if int(movement_summary.get("blocked_frames", 0)) > MAXIMUM_BLOCKED_MOVEMENT_FRAMES:
		acceptance_failures.append("blocked_movement_frames")
	if int(movement_summary.get(
		"maximum_consecutive_blocked_frames", 0
	)) > MAXIMUM_CONSECUTIVE_BLOCKED_MOVEMENT_FRAMES:
		acceptance_failures.append("consecutive_blocked_movement_frames")
	if float(frame_time_summary.get("p95", INF)) > MAXIMUM_FRAME_P95_MS:
		acceptance_failures.append("frame_p95")
	if float(frame_time_summary.get("p99", INF)) > MAXIMUM_FRAME_P99_MS:
		acceptance_failures.append("frame_p99")
	if not bool(edit_summary.get("physics_target_found", false)):
		acceptance_failures.append("physics_target_missing")
	if int(edit_summary.get(
		"physics_target_wait_frames", PHYSICS_TARGET_WAIT_FRAMES + 1
	)) > MAXIMUM_PHYSICS_TARGET_WAIT_FRAMES:
		acceptance_failures.append("physics_target_wait")
	var authority_commit_frames := int(edit_summary.get("authority_commit_frames", -1))
	if authority_commit_frames < 0 or authority_commit_frames > MAXIMUM_AUTHORITY_COMMIT_FRAMES:
		acceptance_failures.append("authority_commit_wait")
	var visual_ready_frames := int(
		edit_summary.get("visual_ready_frames_after_commit", -1)
	)
	if visual_ready_frames < 0 or visual_ready_frames > MAXIMUM_VISUAL_READY_FRAMES_AFTER_COMMIT:
		acceptance_failures.append("visual_ready_wait")
	var collision_ready_frames := int(
		edit_summary.get("collision_ready_frames_after_commit", -1)
	)
	if bool(edit_summary.get("collision_required", false)) and (
		collision_ready_frames < 0 or
		collision_ready_frames > MAXIMUM_COLLISION_READY_FRAMES_AFTER_COMMIT
	):
		acceptance_failures.append("collision_ready_wait")
	var divergence_frames := int(
		edit_summary.get("visual_collision_divergence_frames", -1)
	)
	if divergence_frames < 0 or (
		divergence_frames > MAXIMUM_VISUAL_COLLISION_DIVERGENCE_FRAMES
	):
		acceptance_failures.append("visual_collision_divergence")
	var causal_trace_summary := {"enabled": false}
	if _causal_trace != null:
		causal_trace_summary = _causal_trace.call("finalize", "scenario_complete")
		if not bool(causal_trace_summary.get("ok", false)):
			acceptance_failures.append("causal_trace_finalize")
		elif not bool(causal_trace_summary.get("native_complete", false)):
			acceptance_failures.append("causal_trace_native_incomplete")
	var acceptance_ok := measurement_complete and acceptance_failures.is_empty()

	return {
		"enabled": true,
		"ok": acceptance_ok,
		"measurement_complete": measurement_complete,
		"implementation": "g23_p0_runtime_baseline_v3",
		"profile": str(selected_profile),
		"start_position": _vector3_summary(start_position),
		"movement_end_position": _vector3_summary(movement_end_position),
		"end_position": _vector3_summary(player.global_position),
		"route_net_displacement": route_net_displacement,
		"fixed_post_flight_edit_position": _vector3_summary(
			FIXED_POST_FLIGHT_EDIT_POSITION
		),
		"normal_speed": normal_speed,
		"fast_speed": fast_speed,
		"collision_invoker_radius_chunks": int(
			game_world.get("player_collision_invoker_radius_chunks")
		),
		"collision_prediction_distance": float(
			game_world.get("player_collision_prediction_distance")
		),
		"movement": movement_summary,
		"phases": phases,
		"edit": edit_summary,
		"frame_time_ms": frame_time_summary,
		"backlog": backlog,
		"causal_trace": causal_trace_summary,
		"acceptance": {
			"ok": acceptance_ok,
			"failures": acceptance_failures,
			"minimum_route_net_displacement": MINIMUM_ROUTE_NET_DISPLACEMENT,
			"maximum_blocked_movement_frames": MAXIMUM_BLOCKED_MOVEMENT_FRAMES,
			"maximum_consecutive_blocked_movement_frames":
				MAXIMUM_CONSECUTIVE_BLOCKED_MOVEMENT_FRAMES,
			"maximum_frame_p95_ms": MAXIMUM_FRAME_P95_MS,
			"maximum_frame_p99_ms": MAXIMUM_FRAME_P99_MS,
			"maximum_physics_target_wait_frames": MAXIMUM_PHYSICS_TARGET_WAIT_FRAMES,
			"maximum_authority_commit_frames": MAXIMUM_AUTHORITY_COMMIT_FRAMES,
			"maximum_visual_ready_frames_after_commit":
				MAXIMUM_VISUAL_READY_FRAMES_AFTER_COMMIT,
			"maximum_collision_ready_frames_after_commit":
				MAXIMUM_COLLISION_READY_FRAMES_AFTER_COMMIT,
			"maximum_visual_collision_divergence_frames":
				MAXIMUM_VISUAL_COLLISION_DIVERGENCE_FRAMES,
		},
		"collision_apply_frame_budget": {
			"ok": collision_apply_frame_budget_ok,
			"deadline_ns": collision_apply_deadline_ns,
			"maximum_single_apply_ns": maximum_single_collision_apply_ns,
			"maximum_frame_apply_ns": maximum_frame_collision_apply_ns,
			"soft_bound_ns": collision_apply_soft_bound_ns,
			"bound_model": "deadline_plus_one_indivisible_shape_plus_0_25ms",
		},
		"runtime_metric_delta": {
			"viewer_updates": _metric_delta(runtime_metrics_start, runtime_metrics_end, "viewer_updates"),
			"collision_viewer_updates": _metric_delta(
				runtime_metrics_start, runtime_metrics_end, "collision_viewer_updates"
			),
			"collision_apply_time_ns_total": _metric_delta(
				runtime_metrics_start, runtime_metrics_end, "collision_apply_time_ns_total"
			),
			"collision_apply_time_ns_maximum_end": int(
				runtime_metrics_end.get("collision_apply_time_ns_maximum", 0)
			),
			"collision_apply_frame_time_ns_total": _metric_delta(
				runtime_metrics_start,
				runtime_metrics_end,
				"collision_apply_frame_time_ns_total"
			),
			"collision_apply_frame_time_ns_maximum_end": int(
				runtime_metrics_end.get("collision_apply_frame_time_ns_maximum", 0)
			),
			"collision_apply_frame_items_maximum_end": int(
				runtime_metrics_end.get("collision_apply_frame_items_maximum", 0)
			),
			"collision_apply_frame_deadline_overruns": _metric_delta(
				runtime_metrics_start,
				runtime_metrics_end,
				"collision_apply_frame_deadline_overruns"
			),
			"sample_job_time_ns_maximum_end": int(
				runtime_metrics_end.get("sample_job_time_ns_maximum", 0)
			),
			"mesh_job_time_ns_maximum_end": int(
				runtime_metrics_end.get("mesh_job_time_ns_maximum", 0)
			),
		},
	}


func _run_movement_phase(
	host: Node,
	game_world: Node,
	terrain_world: Node,
	player: CharacterBody3D,
	clock: Dictionary,
	backlog: Dictionary,
	label: String,
	motion_velocity: Vector3,
	frame_count: int
) -> Dictionary:
	_trace_begin_phase(label, "movement:%s" % label, false)
	var start_position := player.global_position
	var accepted_frames := 0
	var blocked_frames := 0
	var current_blocked_run := 0
	var maximum_blocked_run := 0
	var frame_us := []
	for frame in range(frame_count):
		var position_before := player.global_position
		var accepted := bool(player.call(
			"autonomous_move_with_streaming_collision",
			motion_velocity,
			host.get_physics_process_delta_time()
		))
		_trace_note_movement(
			accepted, motion_velocity, position_before, player.global_position
		)
		if accepted:
			accepted_frames += 1
			current_blocked_run = 0
		else:
			blocked_frames += 1
			current_blocked_run += 1
			maximum_blocked_run = maxi(maximum_blocked_run, current_blocked_run)
		if game_world.has_method("update_player_viewer"):
			game_world.call("update_player_viewer", false)
		if frame % 15 == 0:
			_collect_backlog(game_world, terrain_world, backlog)
		frame_us.append(await _next_physics_frame(host, clock))
	return {
		"label": label,
		"kind": "movement",
		"frames": frame_count,
		"accepted_frames": accepted_frames,
		"blocked_frames": blocked_frames,
		"blocked_ratio": float(blocked_frames) / float(maxi(1, frame_count)),
		"maximum_consecutive_blocked_frames": maximum_blocked_run,
		"requested_speed": motion_velocity.length(),
		"travel_distance": start_position.distance_to(player.global_position),
		"start_position": _vector3_summary(start_position),
		"end_position": _vector3_summary(player.global_position),
		"frame_time_ms": _frame_time_summary(frame_us),
	}


func _run_stop_phase(
	host: Node,
	game_world: Node,
	terrain_world: Node,
	player: CharacterBody3D,
	clock: Dictionary,
	backlog: Dictionary,
	label: String,
	frame_count: int
) -> Dictionary:
	_trace_begin_phase(label, "stop:%s" % label, false)
	var start_position := player.global_position
	var rejected_zero_motion_frames := 0
	var frame_us := []
	for frame in range(frame_count):
		var position_before := player.global_position
		var accepted := bool(player.call(
			"autonomous_move_with_streaming_collision",
			Vector3.ZERO,
			host.get_physics_process_delta_time()
		))
		_trace_note_movement(
			accepted, Vector3.ZERO, position_before, player.global_position
		)
		if not accepted:
			rejected_zero_motion_frames += 1
		if game_world.has_method("update_player_viewer"):
			game_world.call("update_player_viewer", false)
		if frame % 15 == 0:
			_collect_backlog(game_world, terrain_world, backlog)
		frame_us.append(await _next_physics_frame(host, clock))
	return {
		"label": label,
		"kind": "stop",
		"frames": frame_count,
		"rejected_zero_motion_frames": rejected_zero_motion_frames,
		"drift_distance": start_position.distance_to(player.global_position),
		"frame_time_ms": _frame_time_summary(frame_us),
	}


func _run_single_edit_measurement(
	host: Node,
	game_world: Node,
	terrain_world: Node,
	player: CharacterBody3D,
	clock: Dictionary,
	backlog: Dictionary
) -> Dictionary:
	var camera := player.get_node_or_null("FirstPersonCamera") as Camera3D
	if camera == null:
		return {"measurement_complete": false, "error": "camera_unavailable"}
	var target_guess := Vector3(
		player.global_position.x + 2.0,
		player.global_position.y - 72.0,
		player.global_position.z
	)
	if not bool(player.call("autonomous_look_at", target_guess)):
		return {"measurement_complete": false, "error": "camera_look_at_failed"}

	_trace_begin_phase("edit_target_wait", "edit:target_acquisition", true)
	var physics_target_wait_frames := 0
	var physics_hit := {}
	var target_wait_frame_us := []
	for frame in range(PHYSICS_TARGET_WAIT_FRAMES + 1):
		physics_hit = _physics_interaction_target(host, player, camera)
		if not physics_hit.is_empty():
			physics_target_wait_frames = frame
			break
		if frame == PHYSICS_TARGET_WAIT_FRAMES:
			physics_target_wait_frames = frame
			break
		if game_world.has_method("update_player_viewer"):
			game_world.call("update_player_viewer", false)
		if frame % 15 == 0:
			_collect_backlog(game_world, terrain_world, backlog)
		target_wait_frame_us.append(await _next_physics_frame(host, clock))

	var expected_edit_position: Vector3 = physics_hit.get("position", target_guess)
	_trace_record(&"edit_target_acquired", {
		"found": not physics_hit.is_empty(),
		"wait_frames": physics_target_wait_frames,
		"position": _vector3_summary(expected_edit_position),
	}, true)
	var expected_chunk := _chunk_coordinate(expected_edit_position)
	var state_before: RefCounted = terrain_world.call("query_chunk_state", expected_chunk, 0)
	var generation_before := _chunk_generation(state_before)
	if _causal_trace != null:
		_causal_trace.call(
			"set_target_chunk", expected_chunk, 0, generation_before
		)
	var revision_before := int(terrain_world.call("get_backend_world_revision"))
	_trace_begin_phase("edit_submit", "edit:submission:1", true)
	var interaction_start_us := Time.get_ticks_usec()
	var interaction_accepted := bool(player.call("autonomous_submit_interaction", &"carve"))
	var interaction_call_us := Time.get_ticks_usec() - interaction_start_us
	var interaction: Dictionary = player.call("get_last_interaction_summary")
	_trace_record(&"edit_submitted", {
		"accepted": interaction_accepted,
		"call_us": interaction_call_us,
		"revision_before": revision_before,
		"interaction": interaction,
	}, true)
	var edit_position: Vector3 = interaction.get("position", expected_edit_position)
	var edited_chunk := _chunk_coordinate(edit_position)
	if edited_chunk != expected_chunk:
		expected_chunk = edited_chunk
		state_before = terrain_world.call("query_chunk_state", expected_chunk, 0)
		generation_before = _chunk_generation(state_before)
		if _causal_trace != null:
			_causal_trace.call(
				"set_target_chunk", expected_chunk, 0, generation_before
			)

	var commit_frame := -1
	var commit_frame_us := []
	_trace_begin_phase("authority_commit_wait", "edit:submission:1", true)
	if interaction_accepted:
		for frame in range(EDIT_COMMIT_WAIT_FRAMES + 1):
			if int(terrain_world.call("get_backend_world_revision")) > revision_before:
				commit_frame = frame
				_trace_record(&"authority_commit_observed", {
					"wait_frames": frame,
					"world_revision": int(
						terrain_world.call("get_backend_world_revision")
					),
				}, true)
				break
			if frame == EDIT_COMMIT_WAIT_FRAMES:
				break
			if frame % 15 == 0:
				_collect_backlog(game_world, terrain_world, backlog)
			commit_frame_us.append(await _next_physics_frame(host, clock))

	var generation_ready_frame := -1
	var visual_ready_frame := -1
	var collision_ready_frame := -1
	var logical_visual_ready_frame := -1
	var logical_collision_ready_frame := -1
	var collision_required := false
	var resource_generation_api := false
	var ready_frame_us := []
	var final_generation := generation_before
	var final_render_generation := 0
	var final_staged_render_generation := 0
	var final_collision_generation := 0
	var generation_change_recorded := false
	var visual_ready_recorded := false
	var collision_ready_recorded := false
	_trace_begin_phase("exact_publication_wait", "edit:submission:1", true)
	if commit_frame >= 0:
		for frame in range(EDIT_READY_WAIT_FRAMES + 1):
			var state: RefCounted = terrain_world.call("query_chunk_state", expected_chunk, 0)
			if state != null:
				var observed_generation := _chunk_generation(state)
				if observed_generation != final_generation and \
						observed_generation > generation_before:
					final_generation = observed_generation
					visual_ready_frame = -1
					collision_ready_frame = -1
				var generation_changed := final_generation > generation_before
				if generation_changed and generation_ready_frame < 0:
					generation_ready_frame = frame
				if generation_changed and not generation_change_recorded:
					generation_change_recorded = true
					_trace_record(&"target_generation_changed", {
						"frame_after_commit": frame,
						"generation": final_generation,
					}, true)
				if state.has_method("is_collision_required"):
					collision_required = bool(state.call("is_collision_required"))
				if generation_changed and logical_visual_ready_frame < 0 and \
						state.has_method("is_visual_ready") and bool(state.call("is_visual_ready")):
					logical_visual_ready_frame = frame
				if generation_changed and logical_collision_ready_frame < 0 and \
						state.has_method("is_collision_ready") and bool(state.call("is_collision_ready")):
					logical_collision_ready_frame = frame
				resource_generation_api = \
					state.has_method("get_render_generation") and \
					state.has_method("get_collision_generation")
				if resource_generation_api:
					final_render_generation = int(state.call("get_render_generation"))
					if state.has_method("get_staged_render_generation"):
						final_staged_render_generation = int(
							state.call("get_staged_render_generation")
						)
					final_collision_generation = int(
						state.call("get_collision_generation")
					)
					if generation_changed and visual_ready_frame < 0 and \
							final_render_generation == final_generation:
						visual_ready_frame = frame
						if not visual_ready_recorded:
							visual_ready_recorded = true
							_trace_record(&"exact_render_published", {
								"frame_after_commit": frame,
								"generation": final_generation,
							}, true)
					if generation_changed and collision_ready_frame < 0 and \
							final_collision_generation == final_generation:
						collision_ready_frame = frame
						if not collision_ready_recorded:
							collision_ready_recorded = true
							_trace_record(&"exact_collision_published", {
								"frame_after_commit": frame,
								"generation": final_generation,
							}, true)
				else:
					visual_ready_frame = logical_visual_ready_frame
					collision_ready_frame = logical_collision_ready_frame
			if visual_ready_frame >= 0 and (collision_ready_frame >= 0 or not collision_required):
				break
			if frame == EDIT_READY_WAIT_FRAMES:
				break
			if frame % 15 == 0:
				_collect_backlog(game_world, terrain_world, backlog)
			ready_frame_us.append(await _next_physics_frame(host, clock))

	var divergence_frames := -1
	if visual_ready_frame >= 0 and collision_ready_frame >= 0:
		divergence_frames = absi(visual_ready_frame - collision_ready_frame)
	var physics_target_wait_ms := _frames_elapsed_ms(
		target_wait_frame_us,
		physics_target_wait_frames
	)
	var authority_commit_ms := _frames_elapsed_ms(commit_frame_us, commit_frame)
	var visual_ready_ms := _frames_elapsed_ms(ready_frame_us, visual_ready_frame)
	var collision_ready_ms := _frames_elapsed_ms(ready_frame_us, collision_ready_frame)
	var ready_observation_window_ms := _frames_elapsed_ms(
		ready_frame_us,
		ready_frame_us.size()
	)
	var relocation_to_visual_ready_ms := -1.0
	if visual_ready_ms >= 0.0:
		relocation_to_visual_ready_ms = (
			physics_target_wait_ms + authority_commit_ms + visual_ready_ms
		)
	var relocation_to_collision_ready_ms := -1.0
	if collision_ready_ms >= 0.0:
		relocation_to_collision_ready_ms = (
			physics_target_wait_ms + authority_commit_ms + collision_ready_ms
		)
	var relocation_to_visual_ready_lower_bound_ms := (
		physics_target_wait_ms + authority_commit_ms +
		(visual_ready_ms if visual_ready_ms >= 0.0 else ready_observation_window_ms)
	)
	var relocation_to_collision_ready_lower_bound_ms := (
		physics_target_wait_ms + authority_commit_ms +
		(collision_ready_ms if collision_ready_ms >= 0.0 else ready_observation_window_ms)
	)
	return {
		"measurement_complete": interaction_accepted and commit_frame >= 0,
		"physics_target_found": not physics_hit.is_empty(),
		"physics_target_wait_frames": physics_target_wait_frames,
		"physics_target_wait_ms": physics_target_wait_ms,
		"physics_target_wait_frame_time_ms": _frame_time_summary(target_wait_frame_us),
		"interaction_accepted": interaction_accepted,
		"interaction_call_ms": float(interaction_call_us) / 1000.0,
		"interaction_target_source": str(interaction.get("target_source", "none")),
		"interaction_ray_hit": bool(interaction.get("ray_hit", false)),
		"interaction_render_mesh_hit": bool(interaction.get("render_mesh_hit", false)),
		"interaction_reason": str(interaction.get("reason", "unknown")),
		"edit_position": _vector3_summary(edit_position),
		"target_chunk": _vector3i_summary(expected_chunk),
		"generation_before": generation_before,
		"generation_after": final_generation,
		"render_generation_after": final_render_generation,
		"staged_render_generation_after": final_staged_render_generation,
		"collision_generation_after": final_collision_generation,
		"resource_generation_api": resource_generation_api,
		"authority_commit_frames": commit_frame,
		"authority_commit_ms": authority_commit_ms,
		"generation_changed_frames_after_commit": generation_ready_frame,
		"visual_ready_frames_after_commit": visual_ready_frame,
		"visual_ready_ms_after_commit": visual_ready_ms,
		"collision_required": collision_required,
		"collision_ready_frames_after_commit": collision_ready_frame,
		"collision_ready_ms_after_commit": collision_ready_ms,
		"ready_observation_window_frames": ready_frame_us.size(),
		"ready_observation_window_ms": ready_observation_window_ms,
		"visual_ready_censored": visual_ready_frame < 0,
		"collision_ready_censored": collision_ready_frame < 0,
		"relocation_to_visual_ready_ms": relocation_to_visual_ready_ms,
		"relocation_to_collision_ready_ms": relocation_to_collision_ready_ms,
		"relocation_to_visual_ready_lower_bound_ms":
			relocation_to_visual_ready_lower_bound_ms,
		"relocation_to_collision_ready_lower_bound_ms":
			relocation_to_collision_ready_lower_bound_ms,
		"logical_visual_ready_frames_after_commit": logical_visual_ready_frame,
		"logical_collision_ready_frames_after_commit":
			logical_collision_ready_frame,
		"visual_collision_divergence_frames": divergence_frames,
		"commit_frame_time_ms": _frame_time_summary(commit_frame_us),
		"ready_frame_time_ms": _frame_time_summary(ready_frame_us),
	}


func _physics_interaction_target(
	host: Node,
	player: CharacterBody3D,
	camera: Camera3D
) -> Dictionary:
	var origin := camera.global_position
	var direction := -camera.global_transform.basis.z
	var distance := float(player.get("interaction_distance"))
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * distance)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = [player.get_rid()]
	return host.get_world_3d().direct_space_state.intersect_ray(query)


func _next_physics_frame(host: Node, clock: Dictionary) -> int:
	await host.get_tree().physics_frame
	var now_us := Time.get_ticks_usec()
	var elapsed_us := maxi(0, now_us - int(clock["last_tick_us"]))
	clock["last_tick_us"] = now_us
	var all_frame_us: Array = clock["all_frame_us"]
	all_frame_us.append(elapsed_us)
	if _causal_trace != null:
		_causal_trace.call("capture_physics_frame", elapsed_us)
	return elapsed_us


func _trace_begin_phase(label: String, cause_id: String, detail: bool) -> void:
	if _causal_trace != null:
		_causal_trace.call("begin_phase", label, cause_id, detail)


func _trace_record(
	kind: StringName,
	payload: Dictionary = {},
	include_pipeline: bool = false
) -> void:
	if _causal_trace != null:
		_causal_trace.call("record", kind, payload, include_pipeline)


func _trace_note_movement(
	accepted: bool,
	requested_velocity: Vector3,
	position_before: Vector3,
	position_after: Vector3
) -> void:
	if _causal_trace != null:
		_causal_trace.call(
			"note_movement", accepted, requested_velocity,
			position_before, position_after
		)


func _collect_backlog(
	game_world: Node,
	terrain_world: Node,
	backlog: Dictionary
) -> void:
	var summary: Dictionary = game_world.call("get_game_world_summary")
	var metrics: Dictionary = terrain_world.call("get_runtime_metrics")
	backlog["samples"] = int(backlog["samples"]) + 1
	for key in [
		"scheduler_queued_jobs",
		"scheduler_queued_completions",
		"pending_chunk_replacements",
		"pending_chunk_retirements",
		"queued_render",
		"queued_collision",
		"staged_render_resources",
	]:
		var maximum_key: String = "maximum_" + str(key)
		backlog[maximum_key] = maxi(
			int(backlog.get(maximum_key, 0)),
			int(summary.get(key, 0))
		)
	backlog["maximum_collision_apply_time_ns_last"] = maxi(
		int(backlog["maximum_collision_apply_time_ns_last"]),
		int(metrics.get("collision_apply_time_ns_last", 0))
	)
	backlog["maximum_collision_apply_time_ns_observed"] = maxi(
		int(backlog["maximum_collision_apply_time_ns_observed"]),
		int(metrics.get("collision_apply_time_ns_maximum", 0))
	)
	backlog["maximum_collision_apply_frame_time_ns_observed"] = maxi(
		int(backlog["maximum_collision_apply_frame_time_ns_observed"]),
		int(metrics.get("collision_apply_frame_time_ns_maximum", 0))
	)
	backlog["maximum_collision_apply_frame_items_observed"] = maxi(
		int(backlog["maximum_collision_apply_frame_items_observed"]),
		int(metrics.get("collision_apply_frame_items_maximum", 0))
	)
	backlog["maximum_sample_job_time_ns_observed"] = maxi(
		int(backlog["maximum_sample_job_time_ns_observed"]),
		int(metrics.get("sample_job_time_ns_maximum", 0))
	)
	backlog["maximum_mesh_job_time_ns_observed"] = maxi(
		int(backlog["maximum_mesh_job_time_ns_observed"]),
		int(metrics.get("mesh_job_time_ns_maximum", 0))
	)


func _empty_backlog_summary() -> Dictionary:
	return {
		"samples": 0,
		"maximum_scheduler_queued_jobs": 0,
		"maximum_scheduler_queued_completions": 0,
		"maximum_pending_chunk_replacements": 0,
		"maximum_pending_chunk_retirements": 0,
		"maximum_queued_render": 0,
		"maximum_queued_collision": 0,
		"maximum_staged_render_resources": 0,
		"maximum_collision_apply_time_ns_last": 0,
		"maximum_collision_apply_time_ns_observed": 0,
		"maximum_collision_apply_frame_time_ns_observed": 0,
		"maximum_collision_apply_frame_items_observed": 0,
		"maximum_sample_job_time_ns_observed": 0,
		"maximum_mesh_job_time_ns_observed": 0,
	}


func _summarize_movement(phases: Array) -> Dictionary:
	var movement_frames := 0
	var accepted_frames := 0
	var blocked_frames := 0
	var maximum_blocked_run := 0
	var stop_drift_distance := 0.0
	var rejected_zero_motion_frames := 0
	for phase_value in phases:
		var phase: Dictionary = phase_value
		if str(phase.get("kind", "")) == "movement":
			movement_frames += int(phase.get("frames", 0))
			accepted_frames += int(phase.get("accepted_frames", 0))
			blocked_frames += int(phase.get("blocked_frames", 0))
			maximum_blocked_run = maxi(
				maximum_blocked_run,
				int(phase.get("maximum_consecutive_blocked_frames", 0))
			)
		elif str(phase.get("kind", "")) == "stop":
			stop_drift_distance += float(phase.get("drift_distance", 0.0))
			rejected_zero_motion_frames += int(phase.get("rejected_zero_motion_frames", 0))
	return {
		"frames": movement_frames,
		"accepted_frames": accepted_frames,
		"blocked_frames": blocked_frames,
		"blocked_ratio": float(blocked_frames) / float(maxi(1, movement_frames)),
		"maximum_consecutive_blocked_frames": maximum_blocked_run,
		"stop_drift_distance": stop_drift_distance,
		"rejected_zero_motion_frames": rejected_zero_motion_frames,
	}


func _frame_time_summary(samples_us: Array) -> Dictionary:
	if samples_us.is_empty():
		return {
			"samples": 0,
			"p50": 0.0,
			"p95": 0.0,
			"p99": 0.0,
			"maximum": 0.0,
			"over_16_67_ms": 0,
			"over_33_3_ms": 0,
		}
	var sorted := samples_us.duplicate()
	sorted.sort()
	var over_16_67_ms := 0
	var over_33_3_ms := 0
	for value in samples_us:
		if int(value) > 16670:
			over_16_67_ms += 1
		if int(value) > 33300:
			over_33_3_ms += 1
	return {
		"samples": samples_us.size(),
		"p50": float(_percentile_us(sorted, 0.50)) / 1000.0,
		"p95": float(_percentile_us(sorted, 0.95)) / 1000.0,
		"p99": float(_percentile_us(sorted, 0.99)) / 1000.0,
		"maximum": float(sorted[sorted.size() - 1]) / 1000.0,
		"over_16_67_ms": over_16_67_ms,
		"over_33_3_ms": over_33_3_ms,
	}


func _percentile_us(sorted_samples: Array, percentile: float) -> int:
	var index := ceili(percentile * float(sorted_samples.size())) - 1
	return int(sorted_samples[clampi(index, 0, sorted_samples.size() - 1)])


func _frames_elapsed_ms(frame_us: Array, frame_count: int) -> float:
	if frame_count < 0:
		return -1.0
	var elapsed_us := 0
	for index in range(mini(frame_count, frame_us.size())):
		elapsed_us += int(frame_us[index])
	return float(elapsed_us) / 1000.0


func _chunk_generation(state: RefCounted) -> int:
	if state == null or not state.has_method("get_generation"):
		return 0
	return int(state.call("get_generation"))


func _chunk_coordinate(position: Vector3) -> Vector3i:
	return Vector3i(
		floori(position.x / CHUNK_SIZE),
		floori(position.y / CHUNK_SIZE),
		floori(position.z / CHUNK_SIZE)
	)


func _metric_delta(before: Dictionary, after: Dictionary, key: String) -> int:
	return int(after.get(key, 0)) - int(before.get(key, 0))


func _structural_failure(error: String) -> Dictionary:
	return {
		"enabled": true,
		"ok": false,
		"measurement_complete": false,
		"error": error,
		"implementation": "g23_p0_runtime_baseline_v3",
	}


func _vector3_summary(value: Vector3) -> Dictionary:
	return {
		"x": value.x,
		"y": value.y,
		"z": value.z,
	}


func _vector3i_summary(value: Vector3i) -> Dictionary:
	return {
		"x": value.x,
		"y": value.y,
		"z": value.z,
	}

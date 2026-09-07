extends SceneTree

const MARKER := "WT_PLAYTEST_DIAGNOSTICS_PASS"
const Diagnostics := preload("res://scripts/wt_playtest_diagnostics.gd")
const Player := preload("res://scripts/wt_production_player.gd")
const Pipeline := preload("res://scripts/wt_playtest_pipeline_snapshot.gd")

class ChunkState:
	extends RefCounted
	var generation := 2
	var active := 0
	var staged := 0
	var ready := false
	func get_generation() -> int: return generation
	func get_collision_generation() -> int: return active
	func get_staged_collision_generation() -> int: return staged
	func is_collision_ready() -> bool: return ready
	func is_present() -> bool: return true
	func get_chunk_coordinate() -> Vector3i: return Vector3i.ZERO
	func get_lod() -> int: return 0
	func is_visual_required() -> bool: return true
	func is_collision_required() -> bool: return true

class Terrain:
	extends Node3D
	var queries := 0
	var timing := false
	var state := ChunkState.new()
	func query_active_chunk_states() -> Array:
		queries += 1
		return [state]
	func get_runtime_metrics() -> Dictionary:
		queries += 1
		return {}
	func get_gpu_resident_render_status() -> Dictionary:
		queries += 1
		return {
			"running": true,
			"effect_status": {
				"arena_status": {
					"dispatch_count": 7,
					"incremental_dispatch_count": 5,
					"incremental_copy_fallback_count": 0,
					"last_regenerated_cell_count": 512,
					"last_dispatch_uploaded_bytes": 128,
					"last_incremental_meshlet_copy_bytes": 256,
				},
			},
		}
	func get_debug_gpu_processing_states() -> Array:
		queries += 1
		return [{"stage": "cohort_wait", "bounds_min": Vector3.ZERO, "bounds_max": Vector3.ONE * 16}]
	func get_backend_terrain() -> Node: return self
	func set_debug_gpu_stage_timing_enabled(value: bool) -> void: timing = value

class World:
	extends Node
	var terrain: Node
	func get_terrain_world() -> Node: return terrain


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var canvas := CanvasLayer.new()
	host.add_child(canvas)
	var crosshair := Label.new()
	canvas.add_child(crosshair)
	var player := CharacterBody3D.new()
	player.set_script(Player)
	host.add_child(player)
	var diagnostics := Diagnostics.new()
	host.add_child(diagnostics)
	diagnostics.call("build_ui", canvas, crosshair)
	diagnostics.call("attach_runtime", null, player)
	diagnostics.call("set_menu_open", true)
	if not bool(diagnostics.call("is_menu_open")):
		_fail("ESC menu did not open")
		return
	if player.human_input_enabled:
		_fail("ESC menu did not suppress player input")
		return
	diagnostics.call("set_menu_open", false)
	if bool(diagnostics.call("is_menu_open")):
		_fail("ESC menu did not close")
		return
	if not player.human_input_enabled:
		_fail("closing ESC menu did not restore player input")
		return
	diagnostics.call("_set_collision_visualization", true)
	if not diagnostics.get("_collision_lines").visible or debug_collisions_hint:
		_fail("collision visualization must use explicit live shapes, not duplicate engine hints")
		return
	diagnostics.call("_set_collision_visualization", false)
	var state := ChunkState.new()
	if Pipeline.collision_stage(state) != "pending":
		_fail("missing shape classified as live")
		return
	state.ready = true
	state.staged = 2
	if Pipeline.collision_stage(state) != "staged":
		_fail("logical collision readiness hid staged geometry")
		return
	state.active = 1
	if Pipeline.collision_stage(state) != "live_previous":
		_fail("old physical generation classified as current")
		return
	state.active = 2
	state.staged = 0
	if Pipeline.collision_stage(state) != "live":
		_fail("current physical generation missing")
		return
	state.active = 0
	if Pipeline.collision_stage(state) != "ready_no_body":
		_fail("ready empty state classified as physical collider")
		return
	var terrain := Terrain.new()
	host.add_child(terrain)
	var world := World.new()
	world.terrain = terrain
	host.add_child(world)
	diagnostics.attach_runtime(world, player)
	diagnostics._process(1.0)
	if terrain.queries != 0:
		_fail("disabled diagnostics queried terrain")
		return
	var body := StaticBody3D.new()
	body.name = "WT_Collision_0_0_0_L0"
	terrain.add_child(body)
	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "Shape"
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.FORWARD]))
	collision_shape.shape = shape
	body.add_child(collision_shape)
	diagnostics.set_debug_options(true, true, true, true)
	diagnostics._process(1.0)
	var snapshot: Dictionary = diagnostics.get_diagnostic_snapshot()
	if int(snapshot.get("visualized_gpu_records", 0)) != 1 \
			or int(snapshot.get("live_collision_wireframes", 0)) != 1 \
			or int(Dictionary(snapshot.get("gpu", {})).get(
				"arena", {}
			).get("incremental_dispatch_count", 0)) != 5 \
			or not terrain.timing or not snapshot.enabled:
		_fail("debug view lacks actual collision mesh or GPU stage")
		return
	if str(snapshot.gpu_processing[0].stage) != "cohort_wait":
		_fail("prepared GPU geometry classified as visible")
		return
	var entry: Dictionary = diagnostics._collision_wireframes[body.get_instance_id()]
	var replacement := ConcavePolygonShape3D.new()
	replacement.set_faces(PackedVector3Array([Vector3.UP, Vector3.RIGHT, Vector3.FORWARD]))
	collision_shape.shape = replacement
	diagnostics._process(1.0)
	if entry.instance != diagnostics._collision_wireframes[body.get_instance_id()].instance \
			or diagnostics._collision_wireframes[body.get_instance_id()].shape_id != replacement.get_instance_id():
		_fail("collision replacement did not reuse and update the debug instance")
		return
	collision_shape.disabled = true
	diagnostics._process(1.0)
	if not diagnostics._collision_wireframes.is_empty():
		_fail("disabled physical shape remained in the debug view")
		return
	diagnostics.set_debug_options(false, false, false, false)
	var queries_before := terrain.queries
	diagnostics._process(1.0)
	if terrain.queries != queries_before or terrain.timing \
			or not diagnostics._collision_wireframes.is_empty() \
			or RenderingServer.frame_post_draw.is_connected(diagnostics._record_draw_interval):
		_fail("disabled diagnostics retained queries, wireframes, or timing")
		return
	print("%s menu=1 collision_toggle=1 chunk_toggle=1 pipeline_stages=1 live_collision_mesh=1 staged_distinct=1 disabled_queries=0 performance_hud=1" % MARKER)
	quit(0)


func _fail(message: String) -> void:
	push_error("WT_PLAYTEST_DIAGNOSTICS_FAIL: " + message)
	quit(1)

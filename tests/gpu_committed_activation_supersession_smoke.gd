extends "res://tests/gpu_global_render_publication_smoke.gd"

const PASS_MARKER := "GPU_COMMITTED_ACTIVATION_SUPERSESSION_SMOKE_PASS"


func _run() -> void:
	if not ClassDB.class_exists("WorldTransvoxelCellProbe"):
		_fail("WorldTransvoxelCellProbe is unavailable")
		return
	var probe := ClassDB.instantiate("WorldTransvoxelCellProbe") as RefCounted
	var capture: Dictionary = probe.call(
		"capture_chunk_cells_with_callable",
		Callable(self, "_chunk_sample"),
		Vector3i.ZERO,
		1,
		1 << 5,
		1 << 5,
		0.0,
		0.25
	)
	if not bool(capture.get("ok", false)):
		_fail("native chunk cell capture failed")
		return
	var batch: Dictionary = capture.get("cell_batch", {})
	_setup_viewport()
	_effect = GlobalRenderEffect.new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [_effect]
	_world_environment.compositor = compositor

	var committed_identity := _identity(batch, 901, 41, 71)
	if _submit(batch, committed_identity, 1, false) <= 0:
		_fail("committed candidate submission failed")
		return
	if not await _wait_for_status(
		func(status: Dictionary) -> bool:
			return int(status.get("prepared_entries", 0)) >= 1,
		10.0
	):
		_fail("committed candidate did not prepare")
		return
	if not _effect.activate_pending_entries([{
		"identity": committed_identity,
		"publication_sequence": 1,
	}]):
		_fail("committed activation could not be queued")
		return

	# Advance the latest sequence before the render callback consumes the already
	# committed activation. The old token must remain valid for exactly that
	# transaction while this newer generation prepares behind it.
	var newer_identity := committed_identity.duplicate(true)
	newer_identity["generation"] = 902
	newer_identity["source_revision"] = 42
	newer_identity["world_revision"] = 72
	if _submit(batch, newer_identity, 2, false) <= 0:
		_fail("newer candidate submission failed")
		return
	if not await _wait_for_status(
		func(status: Dictionary) -> bool:
			return int(status.get("protected_stale_activations", 0)) >= 1 \
				and int(status.get("active_entry_count", 0)) == 1 \
				and int(status.get("protected_activation_entries", -1)) == 0,
		10.0
	):
		_fail("committed activation was not protected: %s" % _effect.get_status())
		return
	var committed_active := false
	var committed_rejected := false
	while true:
		var event: Dictionary = _effect.pop_event()
		if event.is_empty():
			break
		if Dictionary(event.get("identity", {})) != committed_identity:
			continue
		committed_active = committed_active or str(event.get("status", "")) == "ACTIVE"
		committed_rejected = committed_rejected or str(event.get("status", "")) == "REJECTED"
	if not committed_active or committed_rejected:
		_fail("committed activation event was lost or rejected")
		return
	print(PASS_MARKER)
	_effect.close()
	await RenderingServer.frame_post_draw
	quit(0)

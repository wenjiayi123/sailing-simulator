extends SceneTree

const REPORT_PATH := "res://reports/cargo_circuit_full_replay_smoke_v1.json"
const MAX_STEPS := 2000
const FAST_FORWARD_DELTA := 0.25


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var errors: Array[String] = []
	var results: Array[Dictionary] = []
	var scene_status := change_scene_to_file("res://main.tscn")
	if scene_status != OK:
		_finish(results, ["main scene load failed: %s" % error_string(scene_status)])
		return
	for _index in range(18):
		await process_frame
	await physics_frame
	await physics_frame
	var controller := current_scene.get_node_or_null("CargoCircuitReplayController")
	if controller == null:
		_finish(results, ["CargoCircuitReplayController missing"])
		return
	controller.set_physics_process(false)
	for replay in [
		{"name": "SAC-S1", "method": "start_replay"},
		{"name": "RES-SAC-D2", "method": "start_dynamic_replay"},
	]:
		var record := replay as Dictionary
		var name := String(record["name"])
		var started := bool(controller.call(String(record["method"])))
		if not started:
			errors.append("%s refused its frozen test trajectory" % name)
			continue
		controller.set_physics_process(false)
		var iterations := 0
		while bool(controller.call("is_replay_active")) and iterations < MAX_STEPS:
			controller.call("_physics_process", FAST_FORWARD_DELTA)
			iterations += 1
		var status := controller.call("get_replay_status") as Dictionary
		var last_result := status.get("last_result", {}) as Dictionary
		var passed := (
			not bool(status.get("active", true))
			and bool(last_result.get("success", false))
			and int(status.get("large_rock_replay_guard_blocks", -1)) == 0
			and int(status.get("sample_index", 0)) >= int(status.get("sample_count", 1)) - 2
		)
		results.append({
			"name": name,
			"passed": passed,
			"iterations": iterations,
			"format": status.get("format", ""),
			"sample_index": status.get("sample_index", 0),
			"sample_count": status.get("sample_count", 0),
			"large_rock_replay_guard_blocks": status.get("large_rock_replay_guard_blocks", -1),
			"last_result": last_result,
		})
		if not passed:
			errors.append("%s full replay did not finish collision-free" % name)
		controller.call("stop_replay", true)
		await physics_frame
	controller.set_physics_process(true)
	_finish(results, errors)


func _finish(results: Array[Dictionary], errors: Array[String]) -> void:
	var payload := {
		"format": "cargo_circuit_full_replay_smoke_v1",
		"passed": errors.is_empty(),
		"fast_forward_delta_seconds": FAST_FORWARD_DELTA,
		"results": results,
		"errors": errors,
		"boundary": "Full frozen-test visualization replay with runtime large-rock segment sweeps; not a new policy evaluation or sea trial.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "  ") + "\n")
		file.close()
	print(
		"CARGO_FULL_REPLAY:%s:%d/%d"
		% ["PASS" if errors.is_empty() else "FAIL", results.filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(), results.size()]
	)
	for error in errors:
		push_error(error)
	quit(0 if errors.is_empty() else 1)

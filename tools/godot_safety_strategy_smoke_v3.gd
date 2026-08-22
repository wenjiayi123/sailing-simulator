extends SceneTree

const REPORT_PATH := "res://reports/godot_safety_strategy_smoke_v3.json"
const EXPECTED := [
	"ppo", "sac", "td3", "dqn", "a2c", "ddpg", "trpo", "los_pid", "lqr", "mpc"
]

var _checks: Dictionary = {}
var _errors: Array[String] = []


func _record(name: String, passed: bool, detail: Variant) -> void:
	_checks[name] = {"passed": passed, "detail": detail}
	if not passed:
		_errors.append("%s: %s" % [name, str(detail)])


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var status := change_scene_to_file("res://main.tscn")
	_record("main_scene_load", status == OK, status)
	for _index in range(18):
		await process_frame
	var main := current_scene
	if main == null:
		_record("main_scene_ready", false, "current_scene is null")
		_finish()
		return
	var panel := main.get_node_or_null("ShipRLControlPanel")
	_record("rl_panel_present", panel != null, "ShipRLControlPanel")
	if panel == null:
		_finish()
		return
	panel.call("show_training_center")
	await process_frame
	var strategies := panel.get("_strategy_option") as OptionButton
	var algorithms := panel.get("_algorithm_option") as OptionButton
	_record("strategy_dropdown_present", strategies != null, "OptionButton")
	if strategies == null or algorithms == null:
		_finish()
		return
	_record("additive_inventory_count", strategies.item_count == 21, strategies.item_count)
	var base_inventory: Array[String] = []
	var safety_inventory: Array[String] = []
	var base_paths_ready := true
	var safety_paths_ready := true
	for index in range(20):
		var metadata = strategies.get_item_metadata(index)
		if not metadata is Dictionary:
			continue
		var record := metadata as Dictionary
		var algorithm := String(record.get("algorithm", ""))
		var checkpoint := String(record.get("checkpoint", ""))
		var trajectory := String(record.get("trajectory", ""))
		if index < 10:
			base_inventory.append(algorithm)
			base_paths_ready = base_paths_ready and FileAccess.file_exists(checkpoint) and FileAccess.file_exists(trajectory)
		else:
			safety_inventory.append(algorithm)
			safety_paths_ready = safety_paths_ready and FileAccess.file_exists(checkpoint) and FileAccess.file_exists(trajectory)
	_record("base_inventory_preserved", base_inventory == EXPECTED, base_inventory)
	_record("safety_inventory_additive", safety_inventory == EXPECTED, safety_inventory)
	_record("base_artifacts_selectable", base_paths_ready, "10 checkpoint + test trajectories")
	_record("safety_artifacts_selectable", safety_paths_ready, "10 preserved checkpoints + V3 trajectories")
	var replay := main.get_node_or_null("ShipPolicyReplayController")
	_record("replay_controller_present", replay != null, "ShipPolicyReplayController")
	if replay != null and safety_paths_ready:
		var safety_trajectory := String((strategies.get_item_metadata(10) as Dictionary).get("trajectory", ""))
		var loaded := bool(replay.call("load_trajectory", safety_trajectory))
		_record("safety_trajectory_loads_as_recorded_evidence", loaded and bool(replay.call("_is_recorded_rollout")), safety_trajectory)
		_record("recorded_incident_marker_present", replay.get("_incident_marker") != null, "RecordedTestIncidentMarker")
	strategies.select(10)
	strategies.item_selected.emit(10)
	await process_frame
	var safety_metadata := strategies.get_item_metadata(10) as Dictionary
	_record(
		"safety_selection_maps_to_base_algorithm",
		algorithms.get_item_text(algorithms.selected) == "ppo"
		and String(safety_metadata.get("safety_profile", "")) == "safety_v3",
		panel.get("_training_status_label").text,
	)
	strategies.select(0)
	strategies.item_selected.emit(0)
	await process_frame
	var base_metadata := strategies.get_item_metadata(0) as Dictionary
	_record(
		"base_selection_remains_available",
		String(base_metadata.get("algorithm", "")) == "ppo"
		and String(base_metadata.get("safety_profile", "")).is_empty(),
		panel.get("_training_status_label").text,
	)
	var personal := strategies.get_item_metadata(20) as Dictionary
	_record(
		"personal_latest_slot_preserved",
		not bool(personal.get("frozen", true)),
		strategies.get_item_text(20),
	)
	_finish()


func _finish() -> void:
	var payload := {
		"schema_version": "godot_safety_strategy_smoke_v3",
		"generated_at": Time.get_datetime_string_from_system(true),
		"checks": _checks,
		"passed_checks": _checks.size() - _errors.size(),
		"total_checks": _checks.size(),
		"passed": _errors.is_empty(),
		"errors": _errors,
		"boundary": "Godot dropdown inventory and frozen trajectory linkage; not live vessel authority.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "  ") + "\n")
		file.close()
	print("Godot Safety V3 strategy smoke: %s (%d/%d)" % [
		"PASS" if _errors.is_empty() else "FAIL",
		payload["passed_checks"],
		payload["total_checks"],
	])
	quit(0 if _errors.is_empty() else 1)

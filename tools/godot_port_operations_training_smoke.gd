extends SceneTree

const REPORT_PATH := "res://reports/godot_port_operations_training_smoke_v1.json"
const FROZEN_POLICY_PATHS := [
	"res://reports/artifacts/cargo_circuit_rl_v1/cargo_sac_policy.zip",
	"res://reports/artifacts/cargo_circuit_rl_v1/cargo_sac_test_episodes.csv",
	"res://reports/artifacts/cargo_circuit_dynamic_rl_v2/cargo_dynamic_sac_policy.zip",
	"res://reports/artifacts/cargo_circuit_dynamic_rl_v2/cargo_sac_test_episodes.csv",
]

var _checks: Dictionary = {}
var _errors: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _record(name: String, passed: bool, detail: Variant) -> void:
	_checks[name] = {"passed": passed, "detail": detail}
	if not passed:
		_errors.append("%s: %s" % [name, str(detail)])


func _policy_hashes() -> Dictionary:
	var hashes := {}
	for path in FROZEN_POLICY_PATHS:
		hashes[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "MISSING"
	return hashes


func _complete(controller: Node, procedure_key: String, evidence: Dictionary) -> Dictionary:
	controller.call("start_procedure", procedure_key)
	var snapshot := controller.call("get_operation_snapshot") as Dictionary
	while bool(snapshot.get("running", false)):
		var receipt := controller.call("submit_current_step", evidence) as Dictionary
		if String(receipt.get("status", "")) == "REJECTED":
			break
		snapshot = controller.call("get_operation_snapshot") as Dictionary
	return controller.call("get_operation_snapshot") as Dictionary


func _find_button(root: Control, text: String) -> Button:
	for node in root.find_children("*", "Button", true, false):
		var button := node as Button
		if button != null and button.text == text:
			return button
	return null


func _run() -> void:
	var before_hashes := _policy_hashes()
	var scene_status := change_scene_to_file("res://main.tscn")
	_record("main_scene_load_request", scene_status == OK, scene_status)
	for _index in range(24):
		await process_frame
	var main := current_scene
	if main == null:
		_record("main_scene_ready", false, "current_scene is null")
		_finish(before_hashes)
		return
	var controller := main.get_node_or_null("ShipPortOperationsTrainingController")
	var panel := main.get_node_or_null("ShipPortOperationsPanel")
	_record("port_operations_components_present", controller != null and panel != null, {"controller": controller != null, "panel": panel != null})
	if controller == null or panel == null:
		_finish(before_hashes)
		return
	var catalog := controller.call("list_procedures") as Array
	_record("six_procedure_catalog", catalog.size() == 6, catalog)
	var idle := controller.call("get_operation_snapshot") as Dictionary
	_record(
		"procedural_no_dynamics_boundary",
		idle.get("production_authority") == false
		and idle.get("changes_motion_model") == false
		and idle.get("changes_policy") == false
		and idle.get("applies_physical_forces") == false,
		idle.get("boundary"),
	)
	var profile := controller.call("get_training_profile") as Dictionary
	_record(
		"synthetic_profile_not_field_verified",
		profile.get("berth_geometry_verified") == false
		and profile.get("pilotage_and_tug_rules_verified") == false
		and profile.get("official_depth_data") == false
		and profile.get("actuation_connected") == false,
		profile,
	)
	var unknown := controller.call("start_procedure", "unknown") as Dictionary
	_record("unknown_procedure_fails_closed", String(unknown.get("status", "")) == "REJECTED" and String(unknown.get("detail", {}).get("reason", "")) == "UNKNOWN_PROCEDURE", unknown)
	controller.call("start_procedure", "berthing")
	var missing_confirmation := controller.call("submit_current_step", {}) as Dictionary
	_record("explicit_confirmation_gate", String(missing_confirmation.get("status", "")) == "REJECTED" and String(missing_confirmation.get("detail", {}).get("reason", "")) == "EXPLICIT_CONFIRMATION_REQUIRED", missing_confirmation)
	var full_evidence := {
		"confirmed": true,
		"readback_confirmed": true,
		"training_geometry_acknowledged": true,
		"dry_run_confirmed": true,
		"submitted_from": "acceptance",
	}
	var berthing := _complete(controller, "berthing", full_evidence)
	_record("berthing_workflow_complete", bool(berthing.get("complete", false)) and (berthing.get("completed_steps", []) as Array).size() == 6, berthing)
	var unberthing := _complete(controller, "unberthing", full_evidence)
	_record("unberthing_workflow_complete", bool(unberthing.get("complete", false)) and (unberthing.get("completed_steps", []) as Array).size() == 6, unberthing)
	var tug := _complete(controller, "tug_operations", full_evidence)
	_record("tug_workflow_is_procedural", bool(tug.get("complete", false)) and tug.get("applies_physical_forces") == false, tug)
	var anchor := _complete(controller, "anchoring", full_evidence)
	_record("anchoring_workflow_complete", bool(anchor.get("complete", false)) and (anchor.get("completed_steps", []) as Array).size() == 6, anchor)
	var mooring := _complete(controller, "mooring", full_evidence)
	_record("mooring_workflow_is_procedural", bool(mooring.get("complete", false)) and mooring.get("applies_physical_forces") == false, mooring)
	controller.call("start_procedure", "thruster_dry_run")
	var no_dry_run := controller.call("submit_current_step", {"confirmed": true}) as Dictionary
	_record("thruster_actuation_fails_closed", String(no_dry_run.get("status", "")) == "REJECTED" and String(no_dry_run.get("detail", {}).get("reason", "")) == "THRUSTER_DRY_RUN_CONFIRMATION_REQUIRED", no_dry_run)
	var thruster := _complete(controller, "thruster_dry_run", full_evidence)
	_record("thruster_dry_run_complete_without_force", bool(thruster.get("complete", false)) and thruster.get("applies_physical_forces") == false, thruster)
	var receipt_ids: Array[String] = []
	for raw_receipt in thruster.get("receipts", []) as Array:
		var receipt := raw_receipt as Dictionary
		receipt_ids.append(String(receipt.get("receipt_id", "")))
	var unique_receipt_ids := {}
	for receipt_id in receipt_ids:
		unique_receipt_ids[receipt_id] = true
	_record("operation_receipts_unique", not receipt_ids.is_empty() and unique_receipt_ids.size() == receipt_ids.size(), {"count": receipt_ids.size(), "unique": unique_receipt_ids.size()})
	var panel_root := panel.get("_root") as Control
	panel_root.visible = false
	var key_event := InputEventKey.new()
	key_event.pressed = true
	key_event.physical_keycode = KEY_Y
	panel.call("_unhandled_input", key_event)
	await process_frame
	_record("hotkey_Y_opens_port_operations", panel_root.visible, panel_root.visible)
	var option := panel.get("_procedure_option") as OptionButton
	option.select(0)
	var start_button := _find_button(panel_root, "开始程序")
	var submit_button := _find_button(panel_root, "提交当前步骤")
	(start_button as Button).pressed.emit()
	(panel.get("_confirmed_check") as CheckBox).button_pressed = true
	(panel.get("_readback_check") as CheckBox).button_pressed = true
	(submit_button as Button).pressed.emit()
	var panel_snapshot := panel.call("get_acceptance_snapshot") as Dictionary
	_record(
		"panel_submits_real_controller_step",
		String(panel_snapshot.get("last_receipt", {}).get("status", "")) == "EXECUTED"
		and int((panel_snapshot.get("operation", {}) as Dictionary).get("step_index", 0)) == 1,
		panel_snapshot.get("last_receipt", {}),
	)
	_finish(before_hashes)


func _finish(before_hashes: Dictionary) -> void:
	var after_hashes := _policy_hashes()
	_record("frozen_policy_artifacts_unchanged", before_hashes == after_hashes and not before_hashes.values().has("MISSING"), {"before": before_hashes, "after": after_hashes})
	var payload := {
		"schema_version": "godot_port_operations_training_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": _errors.is_empty(),
		"passed_checks": _checks.values().filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"total_checks": _checks.size(),
		"checks": _checks,
		"errors": _errors,
		"boundary": "Procedural berthing, unberthing, tug, anchoring, mooring and thruster dry-run acceptance; no hydrodynamic or line-force model and no field authority.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("PORT_OPERATIONS_TRAINING_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_checks"], payload["total_checks"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

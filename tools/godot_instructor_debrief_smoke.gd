extends SceneTree

const REPORT_PATH := "res://reports/godot_instructor_debrief_smoke_v2.json"
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


func _all_faults_clear(faults: Dictionary) -> bool:
	for value in faults.values():
		if value is bool and bool(value):
			return false
		if value is float or value is int:
			if not is_zero_approx(float(value)):
				return false
	return true


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
	var controller := main.get_node_or_null("ShipInstructorExerciseController")
	var equipment := main.get_node_or_null("ShipNavigationEquipmentSuite")
	var instructor := main.get_node_or_null("ShipInstructorConsolePanel")
	var review := main.get_node_or_null("ShipSimulationReviewPanel")
	_record("instructor_components_present", controller != null and equipment != null and instructor != null and review != null, {
		"controller": controller != null,
		"equipment": equipment != null,
		"instructor": instructor != null,
		"review": review != null,
	})
	if controller == null or equipment == null or instructor == null or review == null:
		_finish(before_hashes)
		return
	var templates := controller.call("list_templates") as Array
	_record("exercise_template_catalog", templates.size() == 3, templates)
	var initial := controller.call("get_exercise_snapshot") as Dictionary
	_record(
		"exercise_assurance_boundary",
		initial.get("production_authority") == false
		and initial.get("changes_motion_model") == false
		and initial.get("changes_policy") == false,
		initial.get("boundary"),
	)
	var matrix := controller.call("get_fault_matrix") as Array
	_record("equipment_fault_matrix_complete", matrix.size() == 9, matrix)
	var rejected := controller.call("inject_equipment_fault", "unknown_fault", true, "acceptance") as Dictionary
	_record("unknown_fault_fails_closed", String(rejected.get("status", "")) == "REJECTED" and String(rejected.get("detail", {}).get("reason", "")) == "UNKNOWN_FAULT", rejected)
	var load_receipt := controller.call("load_exercise", "sensor_disagreement") as Dictionary
	_record("timeline_load_receipt", String(load_receipt.get("status", "")) == "ACCEPTED" and not String(load_receipt.get("receipt_id", "")).is_empty(), load_receipt)
	var start_receipt := controller.call("start_exercise") as Dictionary
	var after_start := controller.call("get_exercise_snapshot") as Dictionary
	_record("timeline_start_and_zero_marker", String(start_receipt.get("status", "")) == "ACCEPTED" and int(after_start.get("next_event_index", 0)) == 1, after_start)
	controller.call("execute_next_event")
	var gyro_faults := equipment.call("get_fault_state") as Dictionary
	_record("scheduled_gyro_fault_executes", is_equal_approx(float(gyro_faults.get("gyro_bias_deg", 0.0)), 7.5), gyro_faults)
	controller.call("execute_next_event")
	var gnss_faults := equipment.call("get_fault_state") as Dictionary
	var bridge_snapshot := equipment.call("get_bridge_snapshot") as Dictionary
	_record(
		"scheduled_gnss_fault_reaches_ecdis",
		bool(gnss_faults.get("gnss_frozen", false))
		and not bool(bridge_snapshot.get("ownship", {}).get("gnss_valid", true)),
		{"faults": gnss_faults, "ownship": bridge_snapshot.get("ownship", {})},
	)
	while int((controller.call("get_exercise_snapshot") as Dictionary).get("next_event_index", 0)) < int((controller.call("get_exercise_snapshot") as Dictionary).get("event_count", 0)):
		controller.call("execute_next_event")
	var complete := controller.call("get_exercise_snapshot") as Dictionary
	_record("timeline_completes_with_receipts", bool(complete.get("complete", false)) and (complete.get("receipts", []) as Array).size() >= 8, {
		"complete": complete.get("complete"),
		"receipt_count": (complete.get("receipts", []) as Array).size(),
	})
	_record("timeline_restores_affected_sensors", _all_faults_clear(equipment.call("get_fault_state") as Dictionary), equipment.call("get_fault_state"))
	var debrief := instructor.call("_build_report_payload") as Dictionary
	_record(
		"debrief_contains_timeline_faults_and_receipts",
		String(debrief.get("schemaVersion", "")) == "ship_instructor_debrief_v2"
		and (debrief.get("equipmentFaultMatrix", []) as Array).size() == 9
		and ((debrief.get("exerciseTimeline", {}) as Dictionary).get("receipts", []) as Array).size() >= 8,
		debrief.get("scenarioInjectionSummary", {}),
	)
	review.call("ingest_instructor_debrief", debrief)
	var review_snapshot := review.call("get_debrief_acceptance_snapshot") as Dictionary
	_record(
		"review_ingests_auditable_debrief",
		bool(review_snapshot.get("received", false))
		and int(review_snapshot.get("fault_matrix_count", 0)) == 9
		and int(review_snapshot.get("receipt_count", 0)) >= 8,
		review_snapshot,
	)
	controller.call("reset_exercise", true)
	_record("acceptance_cleanup_clears_faults", _all_faults_clear(equipment.call("get_fault_state") as Dictionary), equipment.call("get_fault_state"))
	_finish(before_hashes)


func _finish(before_hashes: Dictionary) -> void:
	var after_hashes := _policy_hashes()
	_record("frozen_policy_artifacts_unchanged", before_hashes == after_hashes and not before_hashes.values().has("MISSING"), {"before": before_hashes, "after": after_hashes})
	var payload := {
		"schema_version": "godot_instructor_debrief_smoke_v2",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": _errors.is_empty(),
		"passed_checks": _checks.values().filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"total_checks": _checks.size(),
		"checks": _checks,
		"errors": _errors,
		"boundary": "Deterministic instructor timeline, display-equipment fault matrix, receipts and debrief acceptance; not an approved full-mission instructor operating station or sea-trial result.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("INSTRUCTOR_DEBRIEF_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_checks"], payload["total_checks"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

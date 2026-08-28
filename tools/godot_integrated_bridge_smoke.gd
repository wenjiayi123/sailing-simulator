extends SceneTree

const REPORT_PATH := "res://reports/godot_integrated_bridge_smoke_v1.json"
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


func _run() -> void:
	var before_hashes := _policy_hashes()
	var status := change_scene_to_file("res://main.tscn")
	_record("main_scene_load_request", status == OK, status)
	for _index in range(20):
		await process_frame
	var main := current_scene
	if main == null:
		_record("main_scene_ready", false, "current_scene is null")
		_finish(before_hashes)
		return
	var suite := main.get_node_or_null("ShipNavigationEquipmentSuite")
	var panel := main.get_node_or_null("ShipIntegratedBridgePanel")
	_record("equipment_suite_present", suite != null, "ShipNavigationEquipmentSuite")
	_record("integrated_bridge_panel_present", panel != null, "ShipIntegratedBridgePanel")
	if suite == null or panel == null:
		_finish(before_hashes)
		return
	var snapshot := suite.call("force_refresh") as Dictionary
	var radar := snapshot.get("radar", {}) as Dictionary
	var ecdis := snapshot.get("ecdis", {}) as Dictionary
	var conning := snapshot.get("conning", {}) as Dictionary
	_record(
		"snapshot_contract",
		String(snapshot.get("format", "")) == "ship_integrated_bridge_snapshot_v1"
		and snapshot.get("production_authority") == false
		and snapshot.get("official_navigation_product") == false,
		{"format": snapshot.get("format"), "boundary": snapshot.get("boundary")},
	)
	_record(
		"radar_models_limits_and_errors",
		bool(radar.get("power", false))
		and (radar.get("limitations_modeled", []) as Array).size() >= 6
		and radar.get("type_approved") == false,
		{"limitations": radar.get("limitations_modeled"), "contacts": radar.get("detected_contact_count")},
	)
	_record(
		"ecdis_is_functional_but_fail_closed",
		ecdis.has("route_check_passed")
		and ecdis.has("alarms")
		and ecdis.get("official_chart") == false
		and ecdis.get("update_service_connected") == false,
		{"route_check": ecdis.get("route_check_passed"), "alarms": (ecdis.get("alarms", []) as Array).size()},
	)
	_record(
		"conning_uses_runtime_telemetry",
		conning.has("heading_degrees")
		and conning.has("course_degrees")
		and conning.has("sensor_validity"),
		conning,
	)
	var cpa := suite.call("compute_cpa_tcpa", Vector2(1000.0, 0.0), Vector2(-10.0, 0.0)) as Dictionary
	_record(
		"arpa_cpa_tcpa_known_case",
		absf(float(cpa.get("tcpa_seconds", 0.0)) - 100.0) < 0.001
		and float(cpa.get("dcpa_meters", 999.0)) < 0.001
		and String(cpa.get("risk", "")) == "DANGER",
		cpa,
	)
	var acquire := suite.call("acquire_nearest_contact") as Dictionary
	var acquired_snapshot := suite.call("get_bridge_snapshot") as Dictionary
	_record(
		"arpa_target_acquisition",
		bool(acquire.get("accepted", false))
		and int(acquired_snapshot.get("radar", {}).get("acquired_track_count", 0)) >= 1,
		acquire,
	)
	var original_range := float(radar.get("range_nm", 0.0))
	suite.call("step_radar_range", 1)
	var changed_range := float((suite.call("get_bridge_snapshot") as Dictionary).get("radar", {}).get("range_nm", 0.0))
	_record("radar_range_control_changes_backend", changed_range > original_range, {"before": original_range, "after": changed_range})
	suite.call("set_equipment_fault", "radar_power_loss", true)
	var failed_radar := (suite.call("get_bridge_snapshot") as Dictionary).get("radar", {}) as Dictionary
	_record("radar_power_fault_fails_closed", failed_radar.get("power") == false and int(failed_radar.get("detected_contact_count", -1)) == 0, failed_radar.get("boundary"))
	suite.call("clear_equipment_faults")
	var restored_radar := (suite.call("get_bridge_snapshot") as Dictionary).get("radar", {}) as Dictionary
	_record("fault_clear_restores_sensor", restored_radar.get("power") == true, restored_radar.get("power"))
	var panel_root := panel.get("_root") as Control
	panel_root.visible = false
	var event := InputEventKey.new()
	event.pressed = true
	event.physical_keycode = KEY_B
	panel.call("_unhandled_input", event)
	await process_frame
	_record("hotkey_B_opens_integrated_bridge", panel_root.visible, panel_root.visible)
	var acceptance := panel.call("get_acceptance_snapshot") as Dictionary
	_record("panel_receives_equipment_snapshot", acceptance.has("radar") and acceptance.has("ecdis") and acceptance.has("conning"), acceptance.get("format"))
	_finish(before_hashes)


func _finish(before_hashes: Dictionary) -> void:
	var after_hashes := _policy_hashes()
	_record("frozen_policy_artifacts_unchanged", before_hashes == after_hashes and not before_hashes.values().has("MISSING"), {"before": before_hashes, "after": after_hashes})
	var payload := {
		"schema_version": "godot_integrated_bridge_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": _errors.is_empty(),
		"passed_checks": _checks.values().filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"total_checks": _checks.size(),
		"checks": _checks,
		"errors": _errors,
		"boundary": "Runtime radar/ARPA/ECDIS/conning software acceptance; not IMO/DNV type approval, official chart carriage compliance or live-vessel authority.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("INTEGRATED_BRIDGE_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_checks"], payload["total_checks"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

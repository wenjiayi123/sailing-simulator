extends SceneTree

const REPORT_PATH := "res://reports/godot_multisensor_fusion_smoke_v1.json"
const FROZEN_POLICY_PATHS := [
	"res://data/rl/default_port_dataset.json",
	"res://data/rl/long_beach_ais_port_ops_benchmark_v2.json",
	"res://data/rl/long_beach_ais_port_ops_experiment_v2.json",
	"res://data/rl/long_beach_public_weather_benchmark_v1.json",
	"res://data/rl/long_beach_public_weather_experiment_v1.json",
	"res://data/rl/port_ops_safety_supervisor_v3.json",
	"res://reports/artifacts/cargo_circuit_rl_v1/cargo_sac_policy.zip",
	"res://reports/artifacts/cargo_circuit_dynamic_rl_v2/cargo_dynamic_sac_policy.zip",
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


func _advance(suite: Node, seconds: float = 1.0) -> Dictionary:
	return suite.call("advance_simulation_time_for_test", seconds) as Dictionary


func _run() -> void:
	var before_hashes := _policy_hashes()
	var status := change_scene_to_file("res://main.tscn")
	_record("main_scene_load_request", status == OK, status)
	for _index in range(24):
		await process_frame
	var main := current_scene
	if main == null:
		_record("main_scene_ready", false, "current_scene is null")
		_finish(before_hashes)
		return
	var suite := main.get_node_or_null("ShipMultisensorFusionSuite")
	var panel := main.get_node_or_null("ShipMultisensorFusionPanel")
	_record("fusion_suite_present", suite != null, "ShipMultisensorFusionSuite")
	_record("fusion_panel_present", panel != null, "ShipMultisensorFusionPanel")
	if suite == null or panel == null:
		_finish(before_hashes)
		return

	suite.call("clear_sensor_faults")
	var baseline := _advance(suite, 1.0)
	var channels := baseline.get("channels", {}) as Dictionary
	var packets := suite.call("get_latest_sensor_packets") as Dictionary
	var six_channels_present := true
	var packet_contract_passed := true
	for sensor_id in ["RADAR", "AIS", "EO", "IR", "GNSS", "INS"]:
		six_channels_present = six_channels_present and channels.has(sensor_id) and packets.has(sensor_id)
		var packet := packets.get(sensor_id, {}) as Dictionary
		packet_contract_passed = packet_contract_passed \
			and String(packet.get("schema_version", "")) == "ship_sensor_packet_v1" \
			and packet.has("measurement_time_seconds") \
			and packet.has("receive_time_seconds") \
			and packet.has("source_identity") \
			and packet.has("quality") \
			and packet.has("integrity") \
			and packet.get("hardware_verified") == false \
			and packet.get("production_authority") == false
	_record("six_sensor_channels_present", six_channels_present, channels.keys())
	_record("packet_time_provenance_quality_contract", packet_contract_passed, "six channel packets")
	var ownship := baseline.get("ownship_fusion", {}) as Dictionary
	_record(
		"baseline_gnss_ins_fusion",
		bool(ownship.get("navigation_valid", false))
		and String(ownship.get("mode", "")) == "GNSS_INS_FUSED"
		and (ownship.get("sources", []) as Array).has("GNSS")
		and (ownship.get("sources", []) as Array).has("INS"),
		ownship,
	)
	var gateway := baseline.get("rl_observation_gateway", {}) as Dictionary
	_record(
		"rl_gateway_preserves_existing_policy",
		gateway.has("available")
		and gateway.get("wired_to_existing_policy") == false
		and gateway.get("requires_versioned_observation_adapter_and_retraining") == true,
		gateway,
	)
	_record(
		"claims_fail_closed",
		baseline.get("real_sensor_data_verified") == false
		and baseline.get("physical_sensor_calibration_verified") == false
		and baseline.get("production_authority") == false,
		baseline.get("boundary"),
	)

	suite.call("clear_sensor_faults")
	suite.call("set_sensor_fault", "radar_dropout", true)
	var radar_failed := _advance(suite)
	var radar_health := (radar_failed.get("channels", {}) as Dictionary).get("RADAR", {}) as Dictionary
	var radar_packet := (suite.call("get_latest_sensor_packets") as Dictionary).get("RADAR", {}) as Dictionary
	_record(
		"radar_dropout_fails_closed",
		String(radar_health.get("status", "")) == "OFFLINE"
		and radar_packet.get("valid") == false
		and (radar_packet.get("observations", []) as Array).is_empty(),
		{"health": radar_health, "faults": radar_packet.get("faults_applied")},
	)

	suite.call("clear_sensor_faults")
	suite.call("set_sensor_fault", "eo_occlusion_ratio", 1.0)
	_advance(suite)
	var eo_packet := (suite.call("get_latest_sensor_packets") as Dictionary).get("EO", {}) as Dictionary
	_record(
		"eo_full_occlusion_removes_detections",
		(eo_packet.get("observations", []) as Array).is_empty()
		and float((eo_packet.get("faults_applied", {}) as Dictionary).get("occlusion_ratio", 0.0)) == 1.0,
		eo_packet.get("faults_applied"),
	)

	suite.call("clear_sensor_faults")
	suite.call("set_sensor_fault", "ir_false_alarm_count", 3)
	_advance(suite)
	var ir_packet := (suite.call("get_latest_sensor_packets") as Dictionary).get("IR", {}) as Dictionary
	var simulated_false_alarms := (ir_packet.get("observations", []) as Array).filter(
		func(item: Dictionary) -> bool: return bool(item.get("false_alarm_simulated", false))
	).size()
	_record("ir_false_alarms_are_explicit", simulated_false_alarms == 3, simulated_false_alarms)

	suite.call("clear_sensor_faults")
	suite.call("set_sensor_fault", "ais_latency_ms", 2500.0)
	var ais_delayed := _advance(suite, 3.3)
	var ais_health := (ais_delayed.get("channels", {}) as Dictionary).get("AIS", {}) as Dictionary
	var ais_packet := (suite.call("get_latest_sensor_packets") as Dictionary).get("AIS", {}) as Dictionary
	_record(
		"ais_latency_becomes_stale",
		float(ais_packet.get("latency_ms", 0.0)) >= 2500.0
		and String(ais_health.get("status", "")) == "STALE",
		{"health": ais_health, "latency_ms": ais_packet.get("latency_ms")},
	)

	suite.call("clear_sensor_faults")
	suite.call("set_sensor_fault", "gnss_spoof_offset_m", Vector2(220.0, -140.0))
	var spoofed := _advance(suite)
	var spoofed_ownship := spoofed.get("ownship_fusion", {}) as Dictionary
	var gnss_packet := (suite.call("get_latest_sensor_packets") as Dictionary).get("GNSS", {}) as Dictionary
	_record(
		"gnss_spoof_detected_and_degraded",
		String(gnss_packet.get("integrity", "")) == "SPOOF_SUSPECTED"
		and String(spoofed_ownship.get("mode", "")) == "DEAD_RECKONING_DEGRADED"
		and (spoofed_ownship.get("integrity_alerts", []) as Array).has("GNSS_SPOOF_SUSPECTED"),
		{"mode": spoofed_ownship.get("mode"), "alerts": spoofed_ownship.get("integrity_alerts")},
	)

	suite.call("clear_sensor_faults")
	suite.call("set_sensor_fault", "gnss_dropout", true)
	suite.call("set_sensor_fault", "ins_dropout", true)
	var navigation_failed := _advance(suite)
	_record(
		"gnss_ins_dual_failure_blocks_decision",
		String(navigation_failed.get("fusion_mode", "")) == "FAIL_CLOSED"
		and navigation_failed.get("decision_input_valid") == false
		and (navigation_failed.get("ownship_fusion", {}) as Dictionary).get("navigation_valid") == false,
		navigation_failed.get("ownship_fusion"),
	)

	var external_receipt := suite.call("ingest_external_packet", {"sensor_id": "RADAR"}) as Dictionary
	_record(
		"external_ingest_disabled_without_site_evidence",
		String(external_receipt.get("status", "")) == "REJECTED"
		and String((external_receipt.get("detail", {}) as Dictionary).get("reason", "")) == "EXTERNAL_INGEST_DISABLED",
		external_receipt,
	)
	var unknown_receipt := suite.call("set_sensor_fault", "unknown_fault", true) as Dictionary
	_record("unknown_fault_rejected", String(unknown_receipt.get("status", "")) == "REJECTED", unknown_receipt)

	suite.call("clear_sensor_faults")
	var restored := _advance(suite)
	_record(
		"fault_clear_restores_navigation",
		String((restored.get("ownship_fusion", {}) as Dictionary).get("mode", "")) == "GNSS_INS_FUSED"
		and bool(restored.get("decision_input_valid", false)),
		restored.get("ownship_fusion"),
	)
	var panel_root := panel.get("_root") as Control
	panel_root.visible = false
	var event := InputEventKey.new()
	event.pressed = true
	event.physical_keycode = KEY_K
	panel.call("_unhandled_input", event)
	await process_frame
	_record("hotkey_K_opens_sensor_panel", panel_root.visible, panel_root.visible)
	var acceptance := panel.call("get_acceptance_snapshot") as Dictionary
	_record(
		"panel_receives_fusion_snapshot",
		String(acceptance.get("schema_version", "")) == "ship_multisensor_fusion_snapshot_v1"
		and (acceptance.get("channels", {}) as Dictionary).size() == 6,
		acceptance.get("schema_version"),
	)
	_record("audit_receipts_present", (suite.call("get_receipts") as Array).size() > 20, (suite.call("get_receipts") as Array).size())
	_finish(before_hashes)


func _finish(before_hashes: Dictionary) -> void:
	var after_hashes := _policy_hashes()
	_record(
		"frozen_policy_and_model_artifacts_unchanged",
		before_hashes == after_hashes and not before_hashes.values().has("MISSING"),
		{"before": before_hashes, "after": after_hashes},
	)
	var payload := {
		"schema_version": "godot_multisensor_fusion_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": _errors.is_empty(),
		"passed_checks": _checks.values().filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"total_checks": _checks.size(),
		"checks": _checks,
		"errors": _errors,
		"training_performed": false,
		"motion_model_changed": false,
		"existing_policy_changed": false,
		"boundary": "Software sensor simulation and fusion acceptance only; no physical sensor, field calibration, live-data or production-vessel claim.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("MULTISENSOR_FUSION_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_checks"], payload["total_checks"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

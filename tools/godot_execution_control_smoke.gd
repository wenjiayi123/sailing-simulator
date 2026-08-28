extends SceneTree

const REPORT_PATH := "res://reports/godot_execution_control_smoke_v1.json"
const FROZEN_PATHS := [
	"res://player.gd",
	"res://scripts/physics/catamaran_three_dof_dynamics.gd",
	"res://data/verification/catamaran_usv_dynamics_reference_v2.json",
	"res://data/rl/long_beach_ais_port_ops_benchmark_v2.json",
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


func _hashes() -> Dictionary:
	var result := {}
	for path in FROZEN_PATHS:
		result[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "MISSING"
	return result


func _run() -> void:
	var hashes_before := _hashes()
	var status := change_scene_to_file("res://main.tscn")
	_record("main_scene_load_request", status == OK, status)
	for _index in range(24):
		await process_frame
	var main := current_scene
	if main == null:
		_record("main_scene_ready", false, "current_scene is null")
		_finish(hashes_before)
		return
	var suite := main.get_node_or_null("ShipExecutionControlSuite")
	var panel := main.get_node_or_null("ShipExecutionControlPanel")
	var player := main.get_node_or_null("Player")
	_record("execution_suite_present", suite != null, "ShipExecutionControlSuite")
	_record("execution_panel_present", panel != null, "ShipExecutionControlPanel")
	_record("controlled_vessel_present", player != null, "Player")
	if suite == null or panel == null or player == null:
		_finish(hashes_before)
		return

	var baseline := suite.call("get_execution_snapshot") as Dictionary
	_record(
		"default_is_disarmed_manual_monitoring",
		String(baseline.get("schema_version", "")) == "ship_execution_control_snapshot_v1"
		and baseline.get("armed") == false
		and String(baseline.get("authority", "")) == "MANUAL"
		and (player.call("get_ship_telemetry") as Dictionary).get("external_agent_control_enabled") == false,
		{"mode": baseline.get("mode"), "authority": baseline.get("authority")},
	)
	_record(
		"physical_and_production_claims_fail_closed",
		baseline.get("physical_actuator_feedback_verified") == false
		and baseline.get("physical_emergency_stop_verified") == false
		and baseline.get("production_authority") == false,
		baseline.get("boundary"),
	)
	var premature := suite.call("request_control", "RL") as Dictionary
	_record("control_requires_explicit_arming", String(premature.get("status", "")) == "REJECTED", premature)

	var arm := suite.call("arm_simulation_execution", "SMOKE_OPERATOR") as Dictionary
	_record("simulation_execution_arms_explicitly", String(arm.get("status", "")) == "ACCEPTED_SIMULATION_ONLY", arm)
	var remote := suite.call("request_control", "REMOTE_CONTROL_CENTER") as Dictionary
	_record(
		"remote_control_fails_closed_without_site_authority",
		String(remote.get("status", "")) == "REJECTED"
		and String((remote.get("detail", {}) as Dictionary).get("reason", "")) == "REMOTE_AUTHORITY_NOT_VERIFIED",
		remote,
	)
	var authority := suite.call("request_control", "RL") as Dictionary
	_record("rl_authority_is_opt_in", String(authority.get("status", "")) == "ACCEPTED", authority)
	var limited_receipt := suite.call("submit_rl_action", 1.0, -1.0, 0) as Dictionary
	var limited_snapshot := suite.call("get_execution_snapshot") as Dictionary
	var requested := limited_snapshot.get("requested_command", {}) as Dictionary
	var effective := limited_snapshot.get("effective_command", {}) as Dictionary
	_record(
		"range_and_slew_limits_apply_before_vessel",
		String(limited_receipt.get("status", "")) == "ACCEPTED_LIMITED"
		and float(requested.get("throttle", 0.0)) == 1.0
		and float(requested.get("rudder", 0.0)) == -1.0
		and float(effective.get("throttle", 1.0)) <= 0.04 + 0.0001
		and absf(float(effective.get("rudder", 1.0))) <= 0.06 + 0.0001,
		{"requested": requested, "effective": effective},
	)
	var telemetry := player.call("get_ship_telemetry") as Dictionary
	var feedback := limited_snapshot.get("actuator_feedback", {}) as Dictionary
	_record(
		"command_feedback_is_acknowledged",
		bool(feedback.get("command_acknowledged", false))
		and is_equal_approx(float(feedback.get("target_throttle", 99.0)), float(effective.get("throttle", 0.0)))
		and is_equal_approx(float(feedback.get("target_rudder", 99.0)), float(effective.get("rudder", 0.0))),
		feedback,
	)
	var replayed := suite.call("submit_rl_action", 0.2, 0.1, 0) as Dictionary
	_record(
		"replayed_command_is_rejected",
		String(replayed.get("status", "")) == "REJECTED"
		and String((replayed.get("detail", {}) as Dictionary).get("reason", "")) == "REPLAY_OR_REORDER",
		replayed,
	)

	var timed_out := suite.call("advance_control_for_test", 0.50) as Dictionary
	var timeout_output := timed_out.get("effective_command", {}) as Dictionary
	_record(
		"watchdog_neutralizes_stale_command",
		bool((timed_out.get("watchdog", {}) as Dictionary).get("timed_out", false))
		and String(timed_out.get("mode", "")) == "FAIL_SAFE_WATCHDOG_NEUTRAL"
		and is_zero_approx(float(timeout_output.get("throttle", 1.0)))
		and is_zero_approx(float(timeout_output.get("rudder", 1.0))),
		{"watchdog": timed_out.get("watchdog"), "output": timeout_output},
	)

	var recovered := suite.call("submit_rl_action", 0.36, 0.14, 1) as Dictionary
	_record("fresh_command_recovers_after_watchdog", String(recovered.get("status", "")) == "ACCEPTED", recovered)
	var manual := suite.call("manual_immediate_takeover", "SMOKE_HELM") as Dictionary
	var manual_snapshot := suite.call("get_execution_snapshot") as Dictionary
	telemetry = player.call("get_ship_telemetry") as Dictionary
	_record(
		"manual_takeover_is_immediate_and_high_priority",
		String(manual.get("status", "")) == "ACCEPTED_IMMEDIATE"
		and manual_snapshot.get("armed") == false
		and String(manual_snapshot.get("authority", "")) == "MANUAL"
		and telemetry.get("external_agent_control_enabled") == false,
		{"snapshot": manual_snapshot.get("manual_takeover"), "external": telemetry.get("external_agent_control_enabled")},
	)

	suite.call("arm_simulation_execution", "SMOKE_OPERATOR")
	telemetry = player.call("get_ship_telemetry") as Dictionary
	var heading := float(telemetry.get("heading_degrees", 0.0))
	var autopilot_receipt := suite.call("engage_autopilot", heading + 30.0, 3.0) as Dictionary
	var autopilot_snapshot := suite.call("advance_control_for_test", 0.10) as Dictionary
	var autopilot_requested := autopilot_snapshot.get("requested_command", {}) as Dictionary
	_record(
		"autopilot_closes_heading_and_speed_loop",
		String(autopilot_receipt.get("status", "")) == "ACCEPTED"
		and String(autopilot_snapshot.get("authority", "")) == "AUTOPILOT"
		and bool((autopilot_snapshot.get("autopilot", {}) as Dictionary).get("engaged", false))
		and float(autopilot_requested.get("throttle", 0.0)) > 0.0
		and float(autopilot_requested.get("rudder", 0.0)) > 0.0
		and absf(float((autopilot_snapshot.get("effective_command", {}) as Dictionary).get("rudder", 1.0))) <= 0.65,
		{"autopilot": autopilot_snapshot.get("autopilot"), "requested": autopilot_requested},
	)

	suite.call("set_execution_fault", "steering_actuator_jam", true)
	var jammed := suite.call("advance_control_for_test", 0.10) as Dictionary
	_record("actuator_jam_is_visible_and_degraded", String(jammed.get("mode", "")) == "DEGRADED_ACTUATOR_JAM" and bool((jammed.get("faults", {}) as Dictionary).get("steering_actuator_jam", false)), jammed.get("faults"))
	suite.call("clear_execution_faults")
	suite.call("set_execution_fault", "rudder_feedback_loss", true)
	var feedback_failed := suite.call("get_execution_snapshot") as Dictionary
	_record(
		"feedback_loss_fails_safe",
		String(feedback_failed.get("mode", "")) == "FAIL_SAFE_FEEDBACK_LOSS"
		and (feedback_failed.get("actuator_feedback", {}) as Dictionary).get("target_rudder") == null
		and is_zero_approx(float((feedback_failed.get("effective_command", {}) as Dictionary).get("rudder", 1.0))),
		feedback_failed.get("actuator_feedback"),
	)
	suite.call("clear_execution_faults")

	var estop := suite.call("trigger_emergency_stop", "SMOKE_ESTOP") as Dictionary
	var estop_snapshot := suite.call("get_execution_snapshot") as Dictionary
	telemetry = player.call("get_ship_telemetry") as Dictionary
	_record(
		"emergency_stop_latches_and_neutralizes",
		String(estop.get("status", "")) == "LATCHED"
		and bool((estop_snapshot.get("emergency_stop", {}) as Dictionary).get("latched", false))
		and is_zero_approx(float(telemetry.get("target_throttle", 1.0)))
		and is_zero_approx(float(telemetry.get("target_rudder", 1.0))),
		{"estop": estop_snapshot.get("emergency_stop"), "telemetry": {"throttle": telemetry.get("target_throttle"), "rudder": telemetry.get("target_rudder")}},
	)
	var arm_during_estop := suite.call("arm_simulation_execution", "SMOKE_OPERATOR") as Dictionary
	_record("estop_blocks_rearming", String(arm_during_estop.get("status", "")) == "REJECTED", arm_during_estop)
	var reset_without_confirmation := suite.call("release_emergency_stop", false) as Dictionary
	_record("estop_reset_requires_manual_confirmation", String(reset_without_confirmation.get("status", "")) == "REJECTED", reset_without_confirmation)
	var reset_confirmed := suite.call("release_emergency_stop", true) as Dictionary
	var reset_snapshot := suite.call("get_execution_snapshot") as Dictionary
	_record(
		"confirmed_estop_reset_returns_to_unarmed_manual",
		String(reset_confirmed.get("status", "")) == "ACCEPTED"
		and reset_snapshot.get("armed") == false
		and String(reset_snapshot.get("authority", "")) == "MANUAL"
		and (player.call("get_ship_telemetry") as Dictionary).get("external_agent_control_enabled") == false,
		reset_snapshot.get("mode"),
	)
	var unknown_fault := suite.call("set_execution_fault", "unknown_fault", true) as Dictionary
	_record("unknown_fault_is_rejected", String(unknown_fault.get("status", "")) == "REJECTED", unknown_fault)

	var panel_root := panel.get("_root") as Control
	panel_root.visible = false
	var event := InputEventKey.new()
	event.pressed = true
	event.physical_keycode = KEY_L
	panel.call("_unhandled_input", event)
	await process_frame
	_record("hotkey_L_opens_execution_panel", panel_root.visible, panel_root.visible)
	var acceptance := panel.call("get_acceptance_snapshot") as Dictionary
	_record("panel_receives_execution_snapshot", String(acceptance.get("schema_version", "")) == "ship_execution_control_snapshot_v1" and acceptance.has("actuator_feedback"), acceptance.get("schema_version"))
	_record("audit_receipts_are_retained", (suite.call("get_receipts") as Array).size() >= 18, (suite.call("get_receipts") as Array).size())
	_finish(hashes_before)


func _finish(hashes_before: Dictionary) -> void:
	var hashes_after := _hashes()
	_record(
		"motion_model_and_existing_policy_artifacts_unchanged",
		hashes_before == hashes_after and not hashes_before.values().has("MISSING"),
		{"before": hashes_before, "after": hashes_after},
	)
	var payload := {
		"schema_version": "godot_execution_control_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": _errors.is_empty(),
		"passed_checks": _checks.values().filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"total_checks": _checks.size(),
		"checks": _checks,
		"errors": _errors,
		"training_performed": false,
		"motion_model_changed": false,
		"existing_policy_changed": false,
		"boundary": "Software execution-control closure against the simulator vessel API; no physical actuator, independent hardware emergency stop, type approval or live-vessel authority.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("EXECUTION_CONTROL_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_checks"], payload["total_checks"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

extends SceneTree

const REPORT_PATH := "res://reports/godot_full_mission_bridge_smoke_v1.json"
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


func _find_button(root: Control, text: String) -> Button:
	for raw_node in root.find_children("*", "Button", true, false):
		var button := raw_node as Button
		if button != null and button.text == text:
			return button
	return null


func _run() -> void:
	var before_hashes := _policy_hashes()
	var scene_status := change_scene_to_file("res://main.tscn")
	_record("main_scene_load_request", scene_status == OK, scene_status)
	for _index in range(28):
		await process_frame
	var main := current_scene
	if main == null:
		_record("main_scene_ready", false, "current_scene is null")
		_finish(before_hashes)
		return
	var communication := main.get_node_or_null("ShipGmdssCommunicationsSuite")
	var bridge := main.get_node_or_null("ShipFullMissionBridgeSuite")
	var panel := main.get_node_or_null("ShipFullMissionBridgePanel")
	var player := main.get_node_or_null("Player")
	_record("full_mission_components_present", communication != null and bridge != null and panel != null and player != null, {
		"communication": communication != null,
		"bridge": bridge != null,
		"panel": panel != null,
		"player": player != null,
	})
	if communication == null or bridge == null or panel == null or player == null:
		_finish(before_hashes)
		return

	var initial := bridge.call("get_full_mission_snapshot") as Dictionary
	_record("full_mission_snapshot_schema", String(initial.get("schema_version", "")) == "ship_full_mission_bridge_snapshot_v1", initial.get("schema_version"))
	_record("software_bridge_components_complete", bool(initial.get("functional_software_bridge_complete", false)) and (initial.get("component_presence", {}) as Dictionary).values().all(func(value: Variant) -> bool: return bool(value)), initial.get("component_presence"))
	var initial_claims := initial.get("claims", {}) as Dictionary
	_record("external_claims_fail_closed", initial_claims.get("type_approved_bridge_equipment") == false and initial_claims.get("real_gmdss_transmission") == false and initial_claims.get("physical_360_bridge_verified") == false and initial_claims.get("certified_instructor_available") == false and initial_claims.get("approved_training_course") == false and initial.get("production_authority") == false, initial_claims)
	var preservation := initial.get("preservation_boundary", {}) as Dictionary
	_record("motion_policy_and_rl_contracts_preserved", preservation.get("base_ship_motion_model_replaced") == false and preservation.get("advanced_task_hydrodynamic_extension_enabled") == true and preservation.get("advanced_task_hydrodynamic_extension_scope") == "five_advanced_mission_scenarios_only" and preservation.get("observation_space_modified") == false and preservation.get("action_space_modified") == false and preservation.get("reward_function_modified") == false and preservation.get("existing_policy_modified") == false and preservation.get("training_performed") == false, preservation)

	var predeparture := bridge.call("run_predeparture_check") as Dictionary
	_record("predeparture_check_passes_without_arming", String(predeparture.get("status", "")) == "PASS" and bool(predeparture.get("detail", {}).get("control_remains_disarmed", false)), predeparture)
	var mission := bridge.call("prepare_training_mission", "full mission acceptance", "restricted_visibility_bridge") as Dictionary
	_record("mission_preparation_receipt", String(mission.get("status", "")) == "ACCEPTED_SIMULATION_ONLY" and mission.get("detail", {}).get("training_started") == false, mission)
	var prepared_snapshot := bridge.call("get_full_mission_snapshot") as Dictionary
	_record("mission_links_team_and_instructor", not String(prepared_snapshot.get("collaboration", {}).get("session_id", "")).is_empty() and String(prepared_snapshot.get("instructor_exercise", {}).get("template_key", "")) == "restricted_visibility_bridge", {"collaboration": prepared_snapshot.get("collaboration", {}).get("session_id"), "exercise": prepared_snapshot.get("instructor_exercise", {}).get("template_key")})

	var bad_distress := communication.call("prepare_distress_alert", "UNKNOWN", "oow-01") as Dictionary
	_record("unknown_distress_nature_rejected", String(bad_distress.get("status", "")) == "REJECTED" and String(bad_distress.get("detail", {}).get("reason", "")) == "UNKNOWN_DISTRESS_NATURE", bad_distress)
	var prepared := communication.call("prepare_distress_alert", "COLLISION", "oow-01") as Dictionary
	var distress_id := String(prepared.get("subject", ""))
	_record("distress_requires_guarded_prepare", String(prepared.get("status", "")) == "PREPARED_GUARDED" and not distress_id.is_empty(), prepared)
	var short_hold := communication.call("transmit_prepared_distress", distress_id, 2.9, "oow-01") as Dictionary
	_record("short_distress_hold_rejected", String(short_hold.get("status", "")) == "REJECTED" and String(short_hold.get("detail", {}).get("reason", "")) == "GUARD_HOLD_TOO_SHORT", short_hold)
	var wrong_operator := communication.call("transmit_prepared_distress", distress_id, 3.0, "other") as Dictionary
	_record("distress_operator_mismatch_rejected", String(wrong_operator.get("status", "")) == "REJECTED" and String(wrong_operator.get("detail", {}).get("reason", "")) == "OPERATOR_CONFIRMATION_MISMATCH", wrong_operator)
	var transmitted := communication.call("transmit_prepared_distress", distress_id, 3.0, "oow-01") as Dictionary
	_record("distress_training_transmission_receipt", String(transmitted.get("status", "")) == "TRANSMITTED_SIMULATION_ONLY" and transmitted.get("detail", {}).get("real_radio_transmission") == false and transmitted.get("detail", {}).get("coast_station_connected") == false, transmitted)
	var follow_up := communication.call("record_voice_follow_up", distress_id, "16", "MAYDAY training follow-up", "oow-01") as Dictionary
	_record("voice_follow_up_recorded", String(follow_up.get("status", "")) == "RECORDED_SIMULATION_ONLY" and follow_up.get("detail", {}).get("real_radio_transmission") == false, follow_up)
	var acknowledged := communication.call("acknowledge_call", distress_id, "TRAINING COAST STATION", "instructor-01") as Dictionary
	_record("distress_acknowledgement_recorded", String(acknowledged.get("status", "")) == "ACKNOWLEDGED_SIMULATION_ONLY", acknowledged)
	var cancelled := communication.call("cancel_distress_alert", distress_id, "EXERCISE COMPLETE", "oow-01") as Dictionary
	_record("distress_cancellation_recorded", String(cancelled.get("status", "")) == "CANCELLED_SIMULATION_ONLY", cancelled)
	var direct_distress := communication.call("send_dsc_call", "DISTRESS", "ALL", "COLLISION", "oow-01") as Dictionary
	_record("direct_distress_bypass_rejected", String(direct_distress.get("status", "")) == "REJECTED" and String(direct_distress.get("detail", {}).get("reason", "")) == "DISTRESS_REQUIRES_GUARDED_TWO_STEP_FLOW", direct_distress)
	for priority in ["URGENCY", "SAFETY", "ROUTINE"]:
		var call := communication.call("send_dsc_call", priority, "TRAINING COAST STATION", "%s EXERCISE" % priority, "oow-01") as Dictionary
		_record("%s_call_recorded" % priority.to_lower(), String(call.get("status", "")) == "TRANSMITTED_SIMULATION_ONLY" and call.get("detail", {}).get("real_radio_transmission") == false, call)
	communication.call("set_communication_fault", "vhf_power_loss", true)
	var fault_block := communication.call("send_dsc_call", "ROUTINE", "TRAINING COAST STATION", "FAULT TEST", "oow-01") as Dictionary
	_record("vhf_fault_fails_closed", String(fault_block.get("status", "")) == "REJECTED" and String(fault_block.get("detail", {}).get("reason", "")) == "DSC_PATH_UNAVAILABLE", fault_block)
	communication.call("clear_communication_faults")
	var comm_snapshot := communication.call("get_communication_snapshot") as Dictionary
	_record("gmdss_snapshot_boundary", comm_snapshot.get("real_radio_transmission_enabled") == false and comm_snapshot.get("coast_station_connected") == false and comm_snapshot.get("type_approved") == false and comm_snapshot.get("production_authority") == false, comm_snapshot.get("boundary"))
	_record("gmdss_receipt_chain_valid", bool((communication.call("verify_receipt_chain") as Dictionary).get("passed", false)), communication.call("verify_receipt_chain"))

	var invalid_sector := bridge.call("set_visual_sector", "UNKNOWN") as Dictionary
	_record("unknown_visual_sector_rejected", String(invalid_sector.get("status", "")) == "REJECTED", invalid_sector)
	var sweep := bridge.call("sweep_all_visual_sectors") as Dictionary
	var visual := (bridge.call("get_full_mission_snapshot") as Dictionary).get("visual", {}) as Dictionary
	_record("software_360_sector_sweep", String(sweep.get("status", "")) == "PASS" and int(sweep.get("detail", {}).get("sector_count", 0)) == 8 and int(sweep.get("detail", {}).get("declared_coverage_degrees", 0)) == 360 and int(visual.get("visited_sector_count", 0)) == 8, {"receipt": sweep, "visual": visual})
	_record("physical_360_claim_remains_blocked", visual.get("physical_projection_verified") == false and visual.get("multi_channel_synchronization_verified") == false, visual)
	_record("camera_sector_changes_visual_yaw", absf(fposmod(rad_to_deg(float(player.get("camera_yaw"))), 360.0) - 135.0) < 0.1, player.get("camera_yaw"))

	var no_authorizer := bridge.call("arm_and_engage_autopilot", 90.0, 3.0, "") as Dictionary
	_record("autopilot_requires_authorizer", String(no_authorizer.get("status", "")) == "REJECTED", no_authorizer)
	var autopilot := bridge.call("arm_and_engage_autopilot", 90.0, 3.0, "acceptance-instructor") as Dictionary
	_record("autopilot_and_propulsion_console_path", String(autopilot.get("status", "")) == "ACCEPTED_SIMULATION_ONLY" and autopilot.get("detail", {}).get("physical_actuator") == false, autopilot)
	var execution := (bridge.call("get_full_mission_snapshot") as Dictionary).get("execution_control", {}) as Dictionary
	_record("autopilot_authority_and_target_feedback", String(execution.get("authority", "")) == "AUTOPILOT" and bool(execution.get("autopilot", {}).get("engaged", false)) and float(execution.get("autopilot", {}).get("target_speed_mps", 0.0)) == 3.0, execution)
	var takeover := bridge.call("manual_immediate_takeover", "acceptance") as Dictionary
	execution = (bridge.call("get_full_mission_snapshot") as Dictionary).get("execution_control", {}) as Dictionary
	_record("manual_immediate_takeover_restores_authority", String(takeover.get("status", "")) == "ACCEPTED_IMMEDIATE" and String(execution.get("authority", "")) == "MANUAL" and not bool(execution.get("armed", true)), {"receipt": takeover, "execution": execution})
	_record("full_mission_receipt_chain_valid", bool((bridge.call("verify_receipt_chain") as Dictionary).get("passed", false)), bridge.call("verify_receipt_chain"))

	var panel_root := panel.get("_root") as Control
	panel_root.visible = false
	var key_event := InputEventKey.new()
	key_event.pressed = true
	key_event.physical_keycode = KEY_F12
	panel.call("_unhandled_input", key_event)
	await process_frame
	_record("hotkey_f12_opens_full_mission_panel", panel_root.visible, panel_root.visible)
	var prepare_button := _find_button(panel_root, "准备遇险报警")
	var confirm_button := _find_button(panel_root, "确认按压 3 秒")
	_record("panel_gmdss_controls_present", prepare_button != null and confirm_button != null and _find_button(panel_root, "执行 360° 八扇区扫描") != null, {"prepare": prepare_button != null, "confirm": confirm_button != null})
	if prepare_button != null and confirm_button != null:
		prepare_button.pressed.emit()
		confirm_button.pressed.emit()
	var panel_snapshot := panel.call("get_acceptance_snapshot") as Dictionary
	_record("panel_actions_reach_runtime_suite", String(panel_snapshot.get("last_receipt", {}).get("status", "")) == "TRANSMITTED_SIMULATION_ONLY" and (panel_snapshot.get("communications", {}).get("calls", []) as Array).size() >= 5, panel_snapshot.get("last_receipt"))
	_record("panel_acceptance_boundaries", panel_snapshot.get("training_performed") == false and panel_snapshot.get("base_ship_motion_model_replaced") == false and panel_snapshot.get("advanced_task_hydrodynamic_extension_enabled") == true and panel_snapshot.get("existing_policy_modified") == false and panel_snapshot.get("physical_full_mission_bridge_verified") == false and panel_snapshot.get("production_authority") == false, panel_snapshot)
	_finish(before_hashes)


func _finish(before_hashes: Dictionary) -> void:
	var after_hashes := _policy_hashes()
	_record("frozen_policy_artifacts_unchanged", before_hashes == after_hashes and not before_hashes.values().has("MISSING"), {"before": before_hashes, "after": after_hashes})
	var payload := {
		"schema_version": "godot_full_mission_bridge_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": _errors.is_empty(),
		"passed_count": _checks.values().filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"check_count": _checks.size(),
		"checks": _checks,
		"errors": _errors,
		"training_performed": false,
		"base_ship_motion_model_replaced": false,
		"advanced_task_hydrodynamic_extension_enabled": true,
		"observation_space_modified": false,
		"action_space_modified": false,
		"reward_function_modified": false,
		"existing_policy_modified": false,
		"real_radio_transmission": false,
		"physical_360_bridge_verified": false,
		"certified_instructor_available": false,
		"approved_training_course": false,
		"production_authority": false,
		"boundary": "Functional full-mission software bridge acceptance only; not physical bridge, type approval, GMDSS transmission, instructor certification or course approval.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("FULL_MISSION_BRIDGE_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_count"], payload["check_count"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

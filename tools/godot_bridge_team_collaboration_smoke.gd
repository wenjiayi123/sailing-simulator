extends SceneTree

const REPORT_PATH := "res://reports/godot_bridge_team_collaboration_smoke_v1.json"
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
	var controller := main.get_node_or_null("ShipBridgeTeamCollaborationController")
	var panel := main.get_node_or_null("ShipBridgeTeamPanel")
	_record("collaboration_components_present", controller != null and panel != null, {"controller": controller != null, "panel": panel != null})
	if controller == null or panel == null:
		_finish(before_hashes)
		return
	var session := controller.call("create_session", "acceptance bridge team") as Dictionary
	_record("session_creation_receipt", String(session.get("status", "")) == "ACCEPTED" and not String(session.get("subject", "")).is_empty(), session)
	var master := controller.call("join_station", "MASTER", "master-01", "Master") as Dictionary
	var oow := controller.call("join_station", "OOW", "oow-01", "OOW") as Dictionary
	var helm := controller.call("join_station", "HELM", "helm-01", "Helm") as Dictionary
	_record("required_brm_roles_join", [master, oow, helm].all(func(receipt: Dictionary) -> bool: return String(receipt.get("status", "")) == "ACCEPTED"), {"master": master, "oow": oow, "helm": helm})
	var master_id := String(master.get("subject", ""))
	var oow_id := String(oow.get("subject", ""))
	var helm_id := String(helm.get("subject", ""))
	var duplicate := controller.call("join_station", "MASTER", "master-02", "Duplicate") as Dictionary
	_record("duplicate_role_fails_closed", String(duplicate.get("status", "")) == "REJECTED" and String(duplicate.get("detail", {}).get("reason", "")) == "ROLE_ALREADY_OCCUPIED", duplicate)
	var unauthorized := controller.call("send_bridge_message", helm_id, "OOW", "COMMAND", "Port ten", true, "acceptance") as Dictionary
	_record("helm_command_authority_rejected", String(unauthorized.get("status", "")) == "REJECTED" and String(unauthorized.get("detail", {}).get("reason", "")) == "COMMAND_AUTHORITY_REQUIRED", unauthorized)
	var command := controller.call("send_bridge_message", master_id, "HELM", "COMMAND", "Starboard ten", true, "acceptance") as Dictionary
	var message_id := String(command.get("subject", ""))
	_record("master_command_open_loop_created", String(command.get("status", "")) == "EXECUTED" and not message_id.is_empty(), command)
	var wrong_role := controller.call("acknowledge_message", message_id, oow_id, "Starboard ten") as Dictionary
	_record("wrong_recipient_readback_rejected", String(wrong_role.get("status", "")) == "REJECTED" and String(wrong_role.get("detail", {}).get("reason", "")) == "WRONG_RECIPIENT_ROLE", wrong_role)
	var empty_readback := controller.call("acknowledge_message", message_id, helm_id, "") as Dictionary
	_record("empty_readback_rejected", String(empty_readback.get("status", "")) == "REJECTED" and String(empty_readback.get("detail", {}).get("reason", "")) == "READBACK_TEXT_REQUIRED", empty_readback)
	var closed_loop := controller.call("acknowledge_message", message_id, helm_id, "Starboard ten, helm") as Dictionary
	_record("command_closed_loop_receipt", String(closed_loop.get("status", "")) == "EXECUTED", closed_loop)
	var brief := controller.call("record_situation_brief", master_id, "Cross traffic", "Hold course and monitor CPA", "Stop engines and call master") as Dictionary
	_record("hazard_plan_contingency_brief", String(brief.get("status", "")) == "EXECUTED", brief)
	var challenge := controller.call("send_bridge_message", oow_id, "MASTER", "CHALLENGE", "CPA below agreed limit", true, "acceptance") as Dictionary
	var challenge_id := String(challenge.get("subject", ""))
	var challenge_ack := controller.call("acknowledge_message", challenge_id, master_id, "Challenge received; reassessing") as Dictionary
	_record("challenge_response_closed_loop", String(challenge.get("status", "")) == "EXECUTED" and String(challenge_ack.get("status", "")) == "EXECUTED", {"challenge": challenge, "ack": challenge_ack})
	var team_check := controller.call("run_brm_team_check") as Dictionary
	_record("brm_team_check_passes", bool(team_check.get("passed", false)) and (team_check.get("gaps", []) as Array).is_empty(), team_check)
	var snapshot := controller.call("get_collaboration_snapshot") as Dictionary
	var no_actuation := snapshot.get("messages", []) as Array
	_record(
		"communications_never_map_to_actuation",
		snapshot.get("remote_control_authority") == false
		and snapshot.get("messages_mapped_to_actuation") == false
		and no_actuation.all(func(message: Dictionary) -> bool: return message.get("mapped_to_actuation") == false),
		snapshot.get("boundary"),
	)
	var remote_rejected := controller.call("enable_udp_transport", 0, "0.0.0.0", false) as Dictionary
	_record("non_loopback_network_requires_authorization", String(remote_rejected.get("status", "")) == "REJECTED" and String(remote_rejected.get("detail", {}).get("reason", "")) == "NON_LOOPBACK_REQUIRES_EXPLICIT_AUTHORIZATION", remote_rejected)
	var udp_start := controller.call("enable_udp_transport", 0, "127.0.0.1", false) as Dictionary
	var udp_status := controller.call("get_udp_status") as Dictionary
	_record("loopback_udp_binds_runtime_port", String(udp_start.get("status", "")) == "EXECUTED" and bool(udp_status.get("listening", false)) and int(udp_status.get("port", 0)) > 0, udp_status)
	var probe := controller.call("send_udp_loopback_probe", master_id) as Dictionary
	for _index in range(20):
		await process_frame
	udp_status = controller.call("get_udp_status") as Dictionary
	_record("udp_loopback_packet_received", String(probe.get("status", "")) == "EXECUTED" and int(udp_status.get("received_packets", 0)) >= 1 and int(udp_status.get("rejected_packets", 0)) == 0, udp_status)
	controller.call("stop_udp_transport")
	_record("udp_transport_stops_cleanly", not bool((controller.call("get_udp_status") as Dictionary).get("listening", true)), controller.call("get_udp_status"))
	var panel_root := panel.get("_root") as Control
	panel_root.visible = false
	var key_event := InputEventKey.new()
	key_event.pressed = true
	key_event.physical_keycode = KEY_J
	panel.call("_unhandled_input", key_event)
	await process_frame
	_record("hotkey_J_opens_bridge_team_panel", panel_root.visible, panel_root.visible)
	(panel.get("_session_name") as LineEdit).text = "panel collaboration"
	_find_button(panel_root, "新建会话").pressed.emit()
	(panel.get("_operator_id") as LineEdit).text = "panel-master"
	(panel.get("_join_role") as OptionButton).select(0)
	_find_button(panel_root, "加入").pressed.emit()
	var panel_snapshot := panel.call("get_acceptance_snapshot") as Dictionary
	_record("panel_creates_session_and_joins_station", (panel_snapshot.get("collaboration", {}).get("stations", []) as Array).size() == 1 and String(panel_snapshot.get("last_receipt", {}).get("status", "")) == "ACCEPTED", panel_snapshot.get("last_receipt", {}))
	_finish(before_hashes)


func _finish(before_hashes: Dictionary) -> void:
	var after_hashes := _policy_hashes()
	_record("frozen_policy_artifacts_unchanged", before_hashes == after_hashes and not before_hashes.values().has("MISSING"), {"before": before_hashes, "after": after_hashes})
	var payload := {
		"schema_version": "godot_bridge_team_collaboration_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": _errors.is_empty(),
		"passed_checks": _checks.values().filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"total_checks": _checks.size(),
		"checks": _checks,
		"errors": _errors,
		"boundary": "Role-based bridge-team messaging, closed-loop readback, challenge-response, BRM check and loopback UDP acceptance; not operational VHF/GMDSS, encrypted field networking or remote vessel control.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("BRIDGE_TEAM_COLLABORATION_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_checks"], payload["total_checks"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

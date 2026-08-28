extends SceneTree

const REPORT_PATH := "res://reports/godot_bridge_cybersecurity_smoke_v1.json"
const EXPORT_PATH := "user://ship_bridge_cybersecurity_snapshot.json"
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
	var public_detail: Variant = _public_value(detail)
	_checks[name] = {"passed": passed, "detail": public_detail}
	if not passed:
		_errors.append("%s: %s" % [name, str(public_detail)])


func _public_value(value: Variant) -> Variant:
	if value is Dictionary:
		var clean := {}
		for key in value:
			clean[key] = _public_value(value[key])
		return clean
	if value is Array:
		var clean_array: Array = []
		for item in value:
			clean_array.append(_public_value(item))
		return clean_array
	if value is String or value is StringName:
		var project_root := ProjectSettings.globalize_path("res://").trim_suffix("/")
		var user_root := ProjectSettings.globalize_path("user://").trim_suffix("/")
		return String(value).replace(project_root + "/", "res://").replace(user_root + "/", "user://")
	return value


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
	for _index in range(30):
		await process_frame
	var main := current_scene
	if main == null:
		_record("main_scene_ready", false, "current_scene is null")
		_finish(before_hashes)
		return
	var suite := main.get_node_or_null("ShipBridgeCybersecuritySuite")
	var panel := main.get_node_or_null("ShipBridgeCybersecurityPanel")
	var overview := main.get_node_or_null("ShipSystemOverviewPanel")
	_record("cybersecurity_runtime_components_present", suite != null and panel != null and overview != null, {"suite": suite != null, "panel": panel != null, "overview": overview != null})
	if suite == null or panel == null or overview == null:
		_finish(before_hashes)
		return

	var initial := suite.call("get_security_snapshot") as Dictionary
	_record("snapshot_schema", String(initial.get("schema_version", "")) == "ship_bridge_cybersecurity_snapshot_v1", initial.get("schema_version"))
	_record("seven_security_zones_loaded", int(initial.get("zone_count", 0)) == 7, initial.get("zone_count"))
	_record("eight_allowed_flows_loaded", int(initial.get("allowed_flow_count", 0)) == 8, initial.get("allowed_flow_count"))
	_record("four_training_identities_loaded", int(initial.get("identity_count", 0)) == 4, initial.get("identity_count"))
	_record("default_deny_active", initial.get("default_deny") == true, initial.get("default_deny"))
	_record("least_privilege_active", initial.get("least_privilege") == true, initial.get("least_privilege"))
	_record("no_network_actuation_mapping", initial.get("network_messages_mapped_to_actuation") == false, initial.get("network_messages_mapped_to_actuation"))
	_record("initial_production_claims_fail_closed", initial.get("production_network_segmentation_verified") == false and initial.get("hardware_root_of_trust_verified") == false and initial.get("production_ids_connected") == false and initial.get("independent_penetration_test_completed") == false and initial.get("class_or_flag_cyber_approval") == false and initial.get("production_authority") == false, initial.get("boundary"))

	var missing := suite.call("authenticate", "", "", "") as Dictionary
	_record("missing_credentials_rejected", String(missing.get("status", "")) == "REJECTED" and String(missing.get("detail", {}).get("reason", "")) == "USERNAME_PASSWORD_AND_NONCE_REQUIRED", missing.get("detail"))
	var operator_login := suite.call("authenticate", "bridge_operator", "Bridge-Operator-Training-2026!", "operator-valid-1") as Dictionary
	var operator_token := String(operator_login.get("subject", ""))
	_record("operator_training_authentication", String(operator_login.get("status", "")) == "AUTHENTICATED_TRAINING_ONLY" and not operator_token.is_empty(), {"status": operator_login.get("status"), "token_redacted": not operator_token.is_empty()})
	var replay_login := suite.call("authenticate", "bridge_operator", "Bridge-Operator-Training-2026!", "operator-valid-1") as Dictionary
	_record("authentication_nonce_replay_rejected", String(replay_login.get("detail", {}).get("reason", "")) == "NONCE_REPLAY", replay_login.get("detail"))
	var operator_escalation := suite.call("authorize_action", operator_token, "verify_signed_update") as Dictionary
	_record("operator_privilege_escalation_rejected", String(operator_escalation.get("status", "")) == "REJECTED" and String(operator_escalation.get("detail", {}).get("reason", "")) == "PERMISSION_DENIED", operator_escalation.get("detail"))
	for index in range(3):
		suite.call("authenticate", "bridge_operator", "wrong-password", "operator-bad-%d" % index)
	var locked := suite.call("authenticate", "bridge_operator", "Bridge-Operator-Training-2026!", "operator-after-lock") as Dictionary
	_record("repeated_bad_credentials_lock_account", String(locked.get("detail", {}).get("reason", "")) == "ACCOUNT_LOCKED", locked.get("detail"))

	var allowed_flow := suite.call("request_network_flow", operator_token, "NAVIGATION_SENSOR", "BRIDGE_OPERATIONS", "NAV_TELEMETRY", "flow-allowed-1") as Dictionary
	_record("allowlisted_navigation_flow_accepted", String(allowed_flow.get("status", "")) == "ALLOWED_POLICY_SIMULATION_ONLY", allowed_flow.get("status"))
	_record("allowed_flow_never_forwards_packet", allowed_flow.get("detail", {}).get("packet_forwarded") == false and allowed_flow.get("detail", {}).get("mapped_to_actuation") == false, allowed_flow.get("detail"))
	var flow_replay := suite.call("request_network_flow", operator_token, "NAVIGATION_SENSOR", "BRIDGE_OPERATIONS", "NAV_TELEMETRY", "flow-allowed-1") as Dictionary
	_record("network_flow_nonce_replay_rejected", String(flow_replay.get("detail", {}).get("reason", "")) == "NONCE_REPLAY", flow_replay.get("detail"))
	var prohibited := suite.call("request_network_flow", operator_token, "EXTERNAL_EXCHANGE", "SAFETY_CONTROL", "DIRECT_CONTROL", "flow-prohibited-1") as Dictionary
	_record("external_direct_control_default_denied", String(prohibited.get("detail", {}).get("reason", "")) == "DEFAULT_DENY" and prohibited.get("detail", {}).get("mapped_to_actuation") == false, prohibited.get("detail"))
	var operator_update := suite.call("verify_signed_update", operator_token, false) as Dictionary
	_record("operator_signed_update_denied_by_rbac", String(operator_update.get("status", "")) == "REJECTED", operator_update.get("detail", {}).get("reason"))

	var admin_login := suite.call("authenticate", "security_admin", "Cyber-Admin-Training-2026!", "admin-valid-1") as Dictionary
	var admin_token := String(admin_login.get("subject", ""))
	_record("security_admin_training_authentication", String(admin_login.get("status", "")) == "AUTHENTICATED_TRAINING_ONLY" and not admin_token.is_empty(), {"status": admin_login.get("status"), "token_redacted": not admin_token.is_empty()})
	var boot := suite.call("verify_boot_integrity", admin_token) as Dictionary
	_record("software_boot_allowlist_passes", String(boot.get("status", "")) == "PASS_SOFTWARE_ALLOWLIST" and int(boot.get("detail", {}).get("file_count", 0)) == 7, boot.get("detail"))
	_record("boot_check_does_not_claim_hardware_trust", boot.get("detail", {}).get("hardware_root_of_trust_verified") == false and boot.get("detail", {}).get("measured_boot_verified") == false, boot.get("detail"))
	var valid_update := suite.call("verify_signed_update", admin_token, false) as Dictionary
	_record("rsa_signed_update_fixture_valid", String(valid_update.get("status", "")) == "SIGNATURE_VALID_QUARANTINED" and valid_update.get("detail", {}).get("signature", {}).get("signature_valid") == true, valid_update.get("detail", {}).get("signature"))
	_record("valid_update_remains_quarantined", valid_update.get("detail", {}).get("package_installed") == false and valid_update.get("detail", {}).get("production_signed_update_verified") == false, valid_update.get("detail"))
	var tampered_update := suite.call("verify_signed_update", admin_token, true) as Dictionary
	_record("tampered_update_signature_rejected", String(tampered_update.get("status", "")) == "REJECTED" and tampered_update.get("detail", {}).get("signature", {}).get("signature_valid") == false, tampered_update.get("detail", {}).get("signature"))

	var recovery := suite.call("create_recovery_snapshot", admin_token) as Dictionary
	var recovery_id := String(recovery.get("subject", ""))
	_record("in_memory_recovery_snapshot_created", String(recovery.get("status", "")) == "CREATED_IN_MEMORY_TRAINING_ONLY" and not recovery_id.is_empty(), {"status": recovery.get("status"), "snapshot_id": recovery_id})
	var unsafe_restore := suite.call("restore_recovery_snapshot", admin_token, recovery_id, false) as Dictionary
	_record("recovery_requires_manual_confirmation", String(unsafe_restore.get("detail", {}).get("reason", "")) == "MANUAL_CONFIRMATION_REQUIRED", unsafe_restore.get("detail"))
	var restore := suite.call("restore_recovery_snapshot", admin_token, recovery_id, true) as Dictionary
	_record("confirmed_training_recovery_succeeds", String(restore.get("status", "")) == "RESTORED_IN_MEMORY_TRAINING_ONLY", restore.get("status"))
	_record("recovery_does_not_claim_field_dr", restore.get("detail", {}).get("bare_metal_restore_verified") == false and restore.get("detail", {}).get("rto_rpo_field_tested") == false, restore.get("detail"))

	var campaign := suite.call("run_penetration_campaign", admin_token) as Dictionary
	var cases := campaign.get("detail", {}).get("cases", []) as Array
	_record("eight_case_penetration_campaign_passes", String(campaign.get("status", "")) == "PASS_FUNCTIONAL_SIMULATION" and cases.size() == 8 and int(campaign.get("detail", {}).get("passed_count", 0)) == 8, {"status": campaign.get("status"), "count": cases.size()})
	for raw_case in cases:
		var item := raw_case as Dictionary
		_record("penetration_%s_blocked" % String(item.get("case_id", "unknown")), item.get("detected") == true and item.get("blocked") == true and item.get("production_system_attacked") == false, item)
	_record("campaign_is_not_external_penetration_test", campaign.get("detail", {}).get("real_external_penetration_test_completed") == false and campaign.get("detail", {}).get("independent_tester_verified") == false, campaign.get("detail"))

	var alerts := suite.call("get_alerts") as Array
	var alert_rules: Array[String] = []
	for raw_alert in alerts:
		var rule := String((raw_alert as Dictionary).get("rule_id", ""))
		if rule not in alert_rules:
			alert_rules.append(rule)
	for rule_id in ["AUTHENTICATION_BRUTE_FORCE", "NONCE_REPLAY", "RBAC_DENIAL", "PROHIBITED_ZONE_FLOW", "INVALID_UPDATE_SIGNATURE", "BOOT_INTEGRITY_FAILURE", "AUDIT_CHAIN_TAMPER", "RECOVERY_WITHOUT_CONFIRMATION"]:
		_record("ids_rule_%s_observed" % String(rule_id).to_lower(), rule_id in alert_rules, alert_rules)
	var latest_alert_id := String((alerts[-1] as Dictionary).get("alert_id", ""))
	var acknowledge := suite.call("acknowledge_alert", admin_token, latest_alert_id) as Dictionary
	_record("alert_acknowledgement_recorded", String(acknowledge.get("status", "")) == "ACKNOWLEDGED", acknowledge.get("status"))
	var chain := suite.call("verify_audit_chain") as Dictionary
	_record("tamper_evident_audit_chain_valid", chain.get("passed") == true and int(chain.get("record_count", 0)) >= 20, {"passed": chain.get("passed"), "record_count": chain.get("record_count")})
	var tampered_log := suite.call("get_audit_log") as Array
	var changed := (tampered_log[0] as Dictionary).duplicate(true)
	changed["status"] = "FORGED"
	tampered_log[0] = changed
	var tamper_check := suite.call("verify_audit_chain", tampered_log) as Dictionary
	_record("audit_record_tampering_detected", tamper_check.get("passed") == false and not (tamper_check.get("errors", []) as Array).is_empty(), tamper_check.get("errors"))

	var panel_root := panel.get("_root") as Control
	panel_root.visible = false
	var key_event := InputEventKey.new()
	key_event.pressed = true
	key_event.physical_keycode = KEY_F11
	panel.call("_unhandled_input", key_event)
	await process_frame
	_record("hotkey_f11_opens_cybersecurity_panel", panel_root.visible, panel_root.visible)
	_record("panel_controls_present", _find_button(panel_root, "登录训练身份") != null and _find_button(panel_root, "允许导航遥测流") != null and _find_button(panel_root, "验证签名更新") != null and _find_button(panel_root, "运行八项渗透测试") != null and _find_button(panel_root, "确认恢复") != null, "five control groups")
	(panel.get("_username") as LineEdit).text = "security_admin"
	(panel.get("_password") as LineEdit).text = "Cyber-Admin-Training-2026!"
	(panel.get("_nonce") as LineEdit).text = "panel-admin-valid-1"
	var login_button := _find_button(panel_root, "登录训练身份")
	if login_button != null:
		login_button.pressed.emit()
	var panel_snapshot := panel.call("get_acceptance_snapshot") as Dictionary
	_record("panel_login_reaches_runtime_authentication", panel_snapshot.get("authenticated_training_session") == true and String(panel_snapshot.get("last_receipt", {}).get("status", "")) == "AUTHENTICATED_TRAINING_ONLY" and String(panel_snapshot.get("last_receipt", {}).get("subject", "")) == "REDACTED_SESSION_TOKEN", panel_snapshot.get("last_receipt"))
	var panel_flow := _find_button(panel_root, "阻断外部直控流")
	if panel_flow != null:
		panel_flow.pressed.emit()
	panel_snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	_record("panel_default_deny_action_reaches_suite", String(panel_snapshot.get("last_receipt", {}).get("detail", {}).get("reason", "")) == "DEFAULT_DENY", panel_snapshot.get("last_receipt"))
	var export_button := _find_button(panel_root, "导出安全证据")
	if export_button != null:
		export_button.pressed.emit()
	var export_exists := FileAccess.file_exists(EXPORT_PATH)
	var exported := _read_json(EXPORT_PATH)
	_record("panel_evidence_export_is_redacted", export_exists and exported.get("production_authority") == false and String(exported.get("last_receipt", {}).get("subject", "")) != String(panel.get("_session_token")), {"exists": export_exists, "production_authority": exported.get("production_authority")})
	if export_exists:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(EXPORT_PATH))
	var overview_root := overview.get("_root") as Control
	var overview_button := _find_button(overview_root, "船舶网络安全 / 分区 · 身份 · 签名更新 · IDS · 恢复")
	_record("system_overview_cybersecurity_entry_present", overview_button != null, overview_button != null)
	if overview_button != null:
		panel_root.visible = false
		overview_root.visible = true
		overview_button.pressed.emit()
	_record("overview_entry_opens_cybersecurity_panel", panel_root.visible and not overview_root.visible, {"panel": panel_root.visible, "overview": overview_root.visible})
	panel_snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	_record("panel_preserves_motion_policy_and_rl_contracts", panel_snapshot.get("training_performed") == false and panel_snapshot.get("ship_motion_model_modified") == false and panel_snapshot.get("observation_space_modified") == false and panel_snapshot.get("action_space_modified") == false and panel_snapshot.get("reward_function_modified") == false and panel_snapshot.get("existing_policy_modified") == false, panel_snapshot)
	_record("panel_production_claims_fail_closed", panel_snapshot.get("network_messages_mapped_to_actuation") == false and panel_snapshot.get("production_network_segmentation_verified") == false and panel_snapshot.get("hardware_secure_boot_verified") == false and panel_snapshot.get("production_ids_verified") == false and panel_snapshot.get("independent_penetration_test_completed") == false and panel_snapshot.get("class_or_flag_cyber_approval") == false and panel_snapshot.get("production_authority") == false, panel_snapshot)
	_finish(before_hashes)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(file.get_as_text()) if file != null else null
	return parsed as Dictionary if parsed is Dictionary else {}


func _finish(before_hashes: Dictionary) -> void:
	var after_hashes := _policy_hashes()
	_record("frozen_policy_artifacts_unchanged", before_hashes == after_hashes and not before_hashes.values().has("MISSING"), {"before": before_hashes, "after": after_hashes})
	var payload := {
		"schema_version": "godot_bridge_cybersecurity_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": _errors.is_empty(),
		"passed_count": _checks.values().filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"check_count": _checks.size(),
		"checks": _checks,
		"errors": _errors,
		"training_performed": false,
		"ship_motion_model_modified": false,
		"observation_space_modified": false,
		"action_space_modified": false,
		"reward_function_modified": false,
		"existing_policy_modified": false,
		"network_messages_mapped_to_actuation": false,
		"production_network_segmentation_verified": false,
		"hardware_secure_boot_verified": false,
		"production_ids_verified": false,
		"disaster_recovery_field_verified": false,
		"independent_penetration_test_completed": false,
		"class_or_flag_cyber_approval": false,
		"production_authority": false,
		"boundary": "Offline bridge cybersecurity control trainer only; no production network, hardware trust anchor, SOC, field disaster recovery, independent penetration test or class approval.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("BRIDGE_CYBERSECURITY_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_count"], payload["check_count"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

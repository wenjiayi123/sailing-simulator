extends SceneTree

const REPORT_PATH := "res://reports/godot_port_production_integration_smoke_v1.json"
const EXPORT_PATH := "user://ship_port_integration_snapshot.json"
const PROFILE_PATH := "res://data/verification/port_production_integration_profile_v1.json"
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


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	var value: Variant = JSON.parse_string(file.get_as_text()) if file != null else null
	return value as Dictionary if value is Dictionary else {}


func _adapter(profile: Dictionary, adapter_id: String) -> Dictionary:
	for raw_adapter in (profile.get("adapters", []) as Array):
		var adapter := raw_adapter as Dictionary
		if String(adapter.get("adapter_id", "")) == adapter_id:
			return adapter
	return {}


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
	var gateway := main.get_node_or_null("ShipPortProductionGateway")
	var panel := main.get_node_or_null("ShipPortIntegrationPanel")
	var overview := main.get_node_or_null("ShipSystemOverviewPanel")
	_record("port_integration_components_present", gateway != null and panel != null and overview != null, {"gateway": gateway != null, "panel": panel != null, "overview": overview != null})
	if gateway == null or panel == null or overview == null:
		_finish(before_hashes)
		return

	var profile := _read_json(PROFILE_PATH)
	var adapters := gateway.call("list_adapters") as Array
	var initial := gateway.call("get_port_link_snapshot") as Dictionary
	_record("profile_schema", profile.get("schema_version") == "port_production_integration_profile_v1", profile.get("schema_version"))
	_record("six_port_adapters_declared", adapters.size() == 6 and int(initial.get("adapter_count", 0)) == 6, adapters.map(func(item: Dictionary) -> Variant: return item.get("adapter_id")))
	_record("training_keys_redacted_from_adapter_inventory", adapters.all(func(item: Dictionary) -> bool: return not item.has("training_hmac_key")), "redacted")
	_record("initial_sources_fail_degraded", (initial.get("degraded_adapter_ids", []) as Array).size() == 6, initial.get("degraded_adapter_ids"))
	_record("initial_production_boundary", initial.get("live_data_verified") == false and initial.get("external_dispatch_enabled") == false and initial.get("mapped_to_vessel_actuation") == false and initial.get("dispatch_allowed") == false and initial.get("production_authority") == false, initial.get("boundary"))

	var now := int(Time.get_unix_time_from_system())
	var vts_key := String(_adapter(profile, "VTS_TRAFFIC").get("training_hmac_key", ""))
	var vts_payload := {"track_count": 12, "advisory_count": 1, "traffic_window_start_unix": now - 5, "traffic_window_end_unix": now + 300, "units": {"position": "WGS84", "speed": "knots", "course": "degrees_true"}}
	var envelope := gateway.call("build_training_envelope", "VTS_TRAFFIC", vts_payload, 10, "VTS-VALID-10", now) as Dictionary
	_record("envelope_has_hash_hmac_sequence_and_identity", String(envelope.get("payload_sha256", "")).length() == 64 and String(envelope.get("hmac_sha256", "")).length() == 64 and envelope.get("sequence") == 10 and envelope.get("adapter_id") == "VTS_TRAFFIC", {"payload_hash": String(envelope.get("payload_sha256", "")).length(), "hmac": String(envelope.get("hmac_sha256", "")).length()})
	var accepted := gateway.call("ingest_snapshot", "VTS_TRAFFIC", vts_payload, envelope, vts_key) as Dictionary
	_record("valid_signed_vts_snapshot_accepted", String(accepted.get("status", "")) == "ACCEPTED_OFFLINE_FIXTURE", accepted.get("status"))
	_record("accepted_snapshot_persists_summary_not_body", accepted.get("detail", {}).get("payload_persisted") == false and accepted.get("detail", {}).get("summary", {}).get("payload_body_persisted") == false, accepted.get("detail"))
	var replay := gateway.call("ingest_snapshot", "VTS_TRAFFIC", vts_payload, envelope, vts_key) as Dictionary
	_record("snapshot_id_replay_rejected", String(replay.get("detail", {}).get("reason", "")) == "SNAPSHOT_REPLAY", replay.get("detail"))

	var wrong_key_envelope := gateway.call("build_training_envelope", "VTS_TRAFFIC", vts_payload, 11, "VTS-WRONG-KEY", now) as Dictionary
	var wrong_key := gateway.call("ingest_snapshot", "VTS_TRAFFIC", vts_payload, wrong_key_envelope, "wrong-key") as Dictionary
	_record("wrong_source_credential_rejected", String(wrong_key.get("detail", {}).get("reason", "")) == "SOURCE_CREDENTIAL_REJECTED", wrong_key.get("detail"))
	var tampered_hmac_envelope := gateway.call("build_training_envelope", "VTS_TRAFFIC", vts_payload, 11, "VTS-BAD-HMAC", now) as Dictionary
	tampered_hmac_envelope["hmac_sha256"] = "00".repeat(32)
	var bad_hmac := gateway.call("ingest_snapshot", "VTS_TRAFFIC", vts_payload, tampered_hmac_envelope, vts_key) as Dictionary
	_record("tampered_hmac_rejected", String(bad_hmac.get("detail", {}).get("reason", "")) == "HMAC_MISMATCH", bad_hmac.get("detail"))
	var payload_hash_envelope := gateway.call("build_training_envelope", "VTS_TRAFFIC", vts_payload, 11, "VTS-BAD-PAYLOAD", now) as Dictionary
	var changed_payload := vts_payload.duplicate(true)
	changed_payload["track_count"] = 999
	var bad_payload := gateway.call("ingest_snapshot", "VTS_TRAFFIC", changed_payload, payload_hash_envelope, vts_key) as Dictionary
	_record("payload_tampering_rejected", String(bad_payload.get("detail", {}).get("reason", "")) == "PAYLOAD_HASH_MISMATCH", bad_payload.get("detail"))
	var missing_payload := vts_payload.duplicate(true)
	missing_payload.erase("track_count")
	var missing_envelope := gateway.call("build_training_envelope", "VTS_TRAFFIC", missing_payload, 11, "VTS-MISSING-FIELD", now) as Dictionary
	var missing := gateway.call("ingest_snapshot", "VTS_TRAFFIC", missing_payload, missing_envelope, vts_key) as Dictionary
	_record("missing_required_field_rejected", String(missing.get("detail", {}).get("reason", "")) == "MISSING_REQUIRED_FIELD", missing.get("detail"))
	var unit_payload := vts_payload.duplicate(true)
	unit_payload["units"] = {"position": "LOCAL_XY", "speed": "mps", "course": "radians"}
	var unit_envelope := gateway.call("build_training_envelope", "VTS_TRAFFIC", unit_payload, 11, "VTS-BAD-UNITS", now) as Dictionary
	var units := gateway.call("ingest_snapshot", "VTS_TRAFFIC", unit_payload, unit_envelope, vts_key) as Dictionary
	_record("unit_mismatch_rejected", String(units.get("detail", {}).get("reason", "")) == "UNIT_MISMATCH", units.get("detail"))
	var stale_time := now - 60
	var stale_envelope := gateway.call("build_training_envelope", "VTS_TRAFFIC", vts_payload, 11, "VTS-STALE", stale_time) as Dictionary
	var stale := gateway.call("ingest_snapshot", "VTS_TRAFFIC", vts_payload, stale_envelope, vts_key) as Dictionary
	_record("stale_source_data_rejected", String(stale.get("detail", {}).get("reason", "")) == "STALE_SOURCE_DATA", stale.get("detail"))
	var future_time := now + 60
	var future_envelope := gateway.call("build_training_envelope", "VTS_TRAFFIC", vts_payload, 11, "VTS-FUTURE", future_time) as Dictionary
	var future := gateway.call("ingest_snapshot", "VTS_TRAFFIC", vts_payload, future_envelope, vts_key) as Dictionary
	_record("future_source_time_rejected", String(future.get("detail", {}).get("reason", "")) == "FUTURE_SOURCE_TIME", future.get("detail"))
	var old_sequence_envelope := gateway.call("build_training_envelope", "VTS_TRAFFIC", vts_payload, 9, "VTS-OLD-SEQUENCE", now) as Dictionary
	var old_sequence := gateway.call("ingest_snapshot", "VTS_TRAFFIC", vts_payload, old_sequence_envelope, vts_key) as Dictionary
	_record("non_monotonic_sequence_rejected", String(old_sequence.get("detail", {}).get("reason", "")) == "NON_MONOTONIC_SEQUENCE", old_sequence.get("detail"))

	var all_receipt := gateway.call("ingest_all_training_fixtures", 100) as Dictionary
	_record("all_six_signed_port_fixtures_accepted", String(all_receipt.get("status", "")) == "PASS" and int(all_receipt.get("detail", {}).get("accepted_count", 0)) == 6, all_receipt.get("detail"))
	var linked := gateway.call("get_port_link_snapshot") as Dictionary
	var states := linked.get("adapter_states", {}) as Dictionary
	for adapter_id in ["VTS_TRAFFIC", "TOS_BERTH_PLAN", "PILOTAGE_ORDER", "TUG_ORDER", "BERTH_RESOURCE", "OFFICIAL_NOTICES"]:
		var state := states.get(adapter_id, {}) as Dictionary
		_record("adapter_%s_fresh_fixture" % String(adapter_id).to_lower(), state.get("degraded") == false and int(state.get("accepted_count", 0)) >= 1 and state.get("production_connected") == false, {"adapter": adapter_id, "state": state.get("link_state"), "accepted": state.get("accepted_count")})
	_record("unified_snapshot_keeps_live_claims_false", linked.get("live_data_verified") == false and linked.get("sla_verified") == false and linked.get("site_shadow_operation_completed") == false and linked.get("dispatch_allowed") == false, linked.get("boundary"))

	var disconnected := gateway.call("set_adapter_link", "VTS_TRAFFIC", false, "smoke-operator") as Dictionary
	_record("explicit_disconnect_enters_degraded_mode", String(disconnected.get("status", "")) == "DISCONNECTED_DEGRADED", disconnected.get("status"))
	var disconnected_ingest := gateway.call("ingest_training_fixture", "VTS_TRAFFIC", 200) as Dictionary
	_record("disconnected_adapter_rejects_ingest", String(disconnected_ingest.get("detail", {}).get("reason", "")) == "LINK_DISCONNECTED", disconnected_ingest.get("detail"))
	var watchdog := gateway.call("run_freshness_watchdog", now + 1000) as Dictionary
	_record("watchdog_marks_stale_and_disconnected_sources", String(watchdog.get("status", "")) == "DEGRADED" and (watchdog.get("detail", {}).get("degraded_adapter_ids", []) as Array).size() == 6, watchdog.get("detail"))
	_record("degraded_mode_requires_human_and_never_dispatches", watchdog.get("detail", {}).get("source_authority_removed_for_degraded") == true and watchdog.get("detail", {}).get("human_coordination_required") == true and watchdog.get("detail", {}).get("automatic_dispatch") == false, watchdog.get("detail"))
	var reconnect := gateway.call("set_adapter_link", "VTS_TRAFFIC", true, "smoke-operator") as Dictionary
	_record("operator_can_restore_fixture_link_without_production_claim", String(reconnect.get("status", "")) == "CONNECTED_FIXTURE" and reconnect.get("detail", {}).get("production_connection") == false, reconnect.get("detail"))
	var refreshed_all := gateway.call("ingest_all_training_fixtures", 300) as Dictionary
	_record("fresh_fixtures_recover_all_sources", String(refreshed_all.get("status", "")) == "PASS", refreshed_all.get("detail"))
	var healthy_watchdog := gateway.call("run_freshness_watchdog") as Dictionary
	_record("watchdog_returns_healthy_fixture_only", String(healthy_watchdog.get("status", "")) == "HEALTHY_FIXTURE_ONLY" and (healthy_watchdog.get("detail", {}).get("degraded_adapter_ids", []) as Array).is_empty(), healthy_watchdog.get("detail"))

	var unconfirmed := gateway.call("create_coordination_request", "PILOTAGE_ORDER", "PILOT_ETA_UPDATE", {"eta_delta_minutes": 5}, "oow-01", false) as Dictionary
	_record("coordination_requires_human_confirmation", String(unconfirmed.get("detail", {}).get("reason", "")) == "HUMAN_CONFIRMATION_REQUIRED", unconfirmed.get("detail"))
	var invalid_type := gateway.call("create_coordination_request", "PILOTAGE_ORDER", "START_MAIN_ENGINE", {}, "oow-01", true) as Dictionary
	_record("non_allowlisted_request_type_rejected", String(invalid_type.get("detail", {}).get("reason", "")) == "REQUEST_TYPE_NOT_ALLOWED", invalid_type.get("detail"))
	var pilot_request := gateway.call("create_coordination_request", "PILOTAGE_ORDER", "PILOT_ETA_UPDATE", {"eta_delta_minutes": 5}, "oow-01", true) as Dictionary
	var pilot_request_id := String(pilot_request.get("subject", ""))
	_record("pilot_request_queued_as_rehearsal_only", String(pilot_request.get("status", "")) == "QUEUED_REHEARSAL_ONLY" and not pilot_request_id.is_empty(), {"status": pilot_request.get("status"), "request_id": pilot_request_id})
	_record("pilot_request_never_dispatches_or_actuates", pilot_request.get("detail", {}).get("external_dispatch_performed") == false and pilot_request.get("detail", {}).get("mapped_to_actuation") == false, pilot_request.get("detail"))
	var invalid_ack := gateway.call("receive_coordination_ack", "PILOTAGE_ORDER", pilot_request_id, "EXECUTED", "fixture-pilot") as Dictionary
	_record("invalid_terminal_ack_rejected", String(invalid_ack.get("detail", {}).get("reason", "")) == "INVALID_TERMINAL_STATUS", invalid_ack.get("detail"))
	var pilot_ack := gateway.call("receive_coordination_ack", "PILOTAGE_ORDER", pilot_request_id, "ACKNOWLEDGED", "fixture-pilot") as Dictionary
	_record("pilot_coordination_ack_recorded", String(pilot_ack.get("status", "")) == "ACKNOWLEDGED_FIXTURE_RECEIPT", pilot_ack.get("status"))
	_record("ack_receipt_never_dispatches_or_actuates", pilot_ack.get("detail", {}).get("external_dispatch_performed") == false and pilot_ack.get("detail", {}).get("mapped_to_actuation") == false, pilot_ack.get("detail"))
	var tug_request := gateway.call("create_coordination_request", "TUG_ORDER", "TUG_READINESS_CONFIRMATION", {"readiness": "READY_FIXTURE"}, "oow-01", true) as Dictionary
	_record("tug_request_rehearsal_path_available", String(tug_request.get("status", "")) == "QUEUED_REHEARSAL_ONLY", tug_request.get("status"))

	var audit := gateway.call("verify_audit_chain") as Dictionary
	_record("port_link_audit_chain_valid", audit.get("passed") == true and int(audit.get("record_count", 0)) >= 25, {"passed": audit.get("passed"), "count": audit.get("record_count")})
	var tampered_audit := gateway.call("get_audit_log") as Array
	var changed := (tampered_audit[0] as Dictionary).duplicate(true)
	changed["status"] = "FORGED"
	tampered_audit[0] = changed
	var tamper_check := gateway.call("verify_audit_chain", tampered_audit) as Dictionary
	_record("port_link_audit_tamper_detected", tamper_check.get("passed") == false, tamper_check.get("errors"))

	var panel_root := panel.get("_root") as Control
	panel_root.visible = false
	var key_event := InputEventKey.new()
	key_event.pressed = true
	key_event.physical_keycode = KEY_F10
	panel.call("_unhandled_input", key_event)
	await process_frame
	_record("hotkey_f10_opens_port_integration_panel", panel_root.visible, panel_root.visible)
	_record("port_integration_panel_controls_present", _find_button(panel_root, "接入六类签名夹具") != null and _find_button(panel_root, "模拟断链降级") != null and _find_button(panel_root, "人工确认引航 ETA 请求") != null and _find_button(panel_root, "接收夹具调度回执") != null and _find_button(panel_root, "导出联动证据") != null, "five control groups")
	var ingest_button := _find_button(panel_root, "接入六类签名夹具")
	if ingest_button != null:
		ingest_button.pressed.emit()
	var panel_snapshot := panel.call("get_acceptance_snapshot") as Dictionary
	_record("panel_fixture_action_reaches_gateway", String(panel_snapshot.get("last_receipt", {}).get("status", "")) == "PASS", panel_snapshot.get("last_receipt"))
	var pilot_button := _find_button(panel_root, "人工确认引航 ETA 请求")
	if pilot_button != null:
		pilot_button.pressed.emit()
	var ack_button := _find_button(panel_root, "接收夹具调度回执")
	if ack_button != null:
		ack_button.pressed.emit()
	panel_snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	_record("panel_coordination_receipt_closes", String(panel_snapshot.get("last_receipt", {}).get("status", "")) == "ACKNOWLEDGED_FIXTURE_RECEIPT", panel_snapshot.get("last_receipt"))
	var export_button := _find_button(panel_root, "导出联动证据")
	if export_button != null:
		export_button.pressed.emit()
	var exported := _read_json(EXPORT_PATH)
	_record("panel_export_preserves_fail_closed_boundary", not exported.is_empty() and exported.get("live_data_verified") == false and exported.get("dispatch_allowed") == false and exported.get("production_authority") == false, {"exists": not exported.is_empty(), "dispatch": exported.get("dispatch_allowed")})
	if FileAccess.file_exists(EXPORT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(EXPORT_PATH))
	var overview_root := overview.get("_root") as Control
	var overview_button := _find_button(overview_root, "港口生产联动 / VTS · TOS · 引航 · 拖轮 · 泊位 · 通告")
	_record("system_overview_port_integration_entry_present", overview_button != null, overview_button != null)
	if overview_button != null:
		panel_root.visible = false
		overview_root.visible = true
		overview_button.pressed.emit()
	_record("overview_entry_opens_port_integration_panel", panel_root.visible and not overview_root.visible, {"panel": panel_root.visible, "overview": overview_root.visible})
	panel_snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	_record("panel_preserves_motion_policy_and_rl_contracts", panel_snapshot.get("ship_motion_model_modified") == false and panel_snapshot.get("observation_space_modified") == false and panel_snapshot.get("action_space_modified") == false and panel_snapshot.get("reward_function_modified") == false and panel_snapshot.get("existing_policy_modified") == false and panel_snapshot.get("training_performed") == false, panel_snapshot)
	_finish(before_hashes)


func _finish(before_hashes: Dictionary) -> void:
	var after_hashes := _policy_hashes()
	_record("frozen_policy_artifacts_unchanged", before_hashes == after_hashes and not before_hashes.values().has("MISSING"), {"before": before_hashes, "after": after_hashes})
	var payload := {
		"schema_version": "godot_port_production_integration_smoke_v1",
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
		"live_vts_connected": false,
		"live_tos_connected": false,
		"authorized_pilotage_connected": false,
		"authorized_tug_dispatch_connected": false,
		"official_berth_service_connected": false,
		"official_notices_connected": false,
		"sla_verified": false,
		"site_shadow_operation_completed": false,
		"external_dispatch_performed": false,
		"mapped_to_vessel_actuation": false,
		"dispatch_allowed": false,
		"production_authority": false,
		"boundary": "Signed offline fixtures and receipt rehearsal only; no authorized live port connector, field SLA, shadow operation, external dispatch or vessel actuation.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("PORT_PRODUCTION_INTEGRATION_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_count"], payload["check_count"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

extends Node
class_name ShipBridgeCybersecuritySuite

## Offline bridge-network cybersecurity training and control-verification layer.
##
## No flow evaluated here is connected to vessel actuation or a production
## network.  The training authentication scheme is deliberately marked as
## non-production; external hardware, identity, SOC and class evidence remain
## mandatory.

signal security_receipt_emitted(receipt: Dictionary)
signal security_snapshot_updated(snapshot: Dictionary)

const PROFILE_PATH := "res://data/verification/maritime_cybersecurity_profile_v1.json"
const SNAPSHOT_SCHEMA := "ship_bridge_cybersecurity_snapshot_v1"
const RECEIPT_SCHEMA := "ship_bridge_cybersecurity_receipt_v1"
const MAX_RECORDS := 512

var _profile: Dictionary = {}
var _accounts: Dictionary = {}
var _sessions: Dictionary = {}
var _failed_attempts: Dictionary = {}
var _locked_until_msec: Dictionary = {}
var _used_nonces: Dictionary = {}
var _audit_log: Array[Dictionary] = []
var _alerts: Array[Dictionary] = []
var _recovery_snapshots: Dictionary = {}
var _security_state := {
	"default_deny_enabled": true,
	"monitoring_enabled": true,
	"update_quarantine_enabled": true,
	"audit_chain_enabled": true,
}
var _receipt_sequence := 0
var _alert_sequence := 0
var _recovery_sequence := 0
var _previous_audit_hash := "GENESIS"
var _audit_anchor_hash := "GENESIS"
var _snapshot: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"ship_bridge_cybersecurity_suite")
	_profile = _read_json(PROFILE_PATH)
	for raw_account in (_identity_policy().get("accounts", []) as Array):
		var account := raw_account as Dictionary
		_accounts[String(account.get("username", ""))] = account.duplicate(true)
	_rebuild_snapshot()


func authenticate(username: String, password: String, nonce: String) -> Dictionary:
	var clean_username := username.strip_edges()
	if clean_username.is_empty() or password.is_empty() or nonce.strip_edges().is_empty():
		_raise_alert("AUTHENTICATION_BRUTE_FORCE", "LOW", clean_username, {"reason": "MISSING_CREDENTIAL_FIELD"})
		return _append_audit("authenticate", clean_username, "REJECTED", {"reason": "USERNAME_PASSWORD_AND_NONCE_REQUIRED"})
	if not _consume_nonce(nonce, "AUTHENTICATION"):
		_raise_alert("NONCE_REPLAY", "HIGH", clean_username, {"nonce_sha256": _sha256_text(nonce)})
		return _append_audit("authenticate", clean_username, "REJECTED", {"reason": "NONCE_REPLAY"})
	var now := Time.get_ticks_msec()
	if now < int(_locked_until_msec.get(clean_username, 0)):
		return _append_audit("authenticate", clean_username, "REJECTED", {"reason": "ACCOUNT_LOCKED", "remaining_msec": int(_locked_until_msec[clean_username]) - now})
	if not _accounts.has(clean_username):
		_raise_alert("AUTHENTICATION_BRUTE_FORCE", "MEDIUM", clean_username, {"reason": "UNKNOWN_ACCOUNT"})
		return _append_audit("authenticate", clean_username, "REJECTED", {"reason": "INVALID_CREDENTIALS"})
	var account := _accounts[clean_username] as Dictionary
	var presented := _sha256_text("%s:%s" % [String(account.get("salt", "")), password])
	if presented != String(account.get("password_sha256", "")):
		var failures := int(_failed_attempts.get(clean_username, 0)) + 1
		_failed_attempts[clean_username] = failures
		var maximum := int(_identity_policy().get("maximum_failed_attempts", 3))
		if failures >= maximum:
			_locked_until_msec[clean_username] = now + int(_identity_policy().get("lockout_seconds", 60)) * 1000
			_raise_alert("AUTHENTICATION_BRUTE_FORCE", "HIGH", clean_username, {"failed_attempts": failures, "account_locked": true})
		return _append_audit("authenticate", clean_username, "REJECTED", {"reason": "INVALID_CREDENTIALS", "failed_attempts": failures, "account_locked": failures >= maximum})
	_failed_attempts[clean_username] = 0
	_locked_until_msec.erase(clean_username)
	var token := _sha256_text("%s|%s|%s|%d" % [clean_username, nonce, Time.get_unix_time_from_system(), Time.get_ticks_usec()])
	_sessions[token] = {
		"username": clean_username,
		"role": account.get("role", "UNKNOWN"),
		"permissions": (account.get("permissions", []) as Array).duplicate(),
		"issued_msec": now,
		"expires_msec": now + int(_identity_policy().get("session_ttl_seconds", 600)) * 1000,
		"active": true,
	}
	return _append_audit("authenticate", token, "AUTHENTICATED_TRAINING_ONLY", {
		"username": clean_username,
		"role": account.get("role", "UNKNOWN"),
		"session_ttl_seconds": int(_identity_policy().get("session_ttl_seconds", 600)),
		"production_identity_provider": false,
	})


func logout(session_token: String) -> Dictionary:
	if not _sessions.has(session_token):
		return _append_audit("logout", "", "REJECTED", {"reason": "UNKNOWN_SESSION"})
	var session := _sessions[session_token] as Dictionary
	session["active"] = false
	_sessions[session_token] = session
	return _append_audit("logout", session_token, "ACCEPTED", {"username": session.get("username", "")})


func authorize_action(session_token: String, permission: String) -> Dictionary:
	var auth := _authorization(session_token, permission)
	if not bool(auth.get("allowed", false)):
		_raise_alert("RBAC_DENIAL", "MEDIUM", String(auth.get("username", "UNKNOWN")), {"permission": permission, "reason": auth.get("reason", "")})
	return _append_audit("authorize_action", permission, "AUTHORIZED_TRAINING_ONLY" if bool(auth.get("allowed", false)) else "REJECTED", auth)


func request_network_flow(session_token: String, source_zone: String, target_zone: String, service: String, nonce: String) -> Dictionary:
	var auth := _authorization(session_token, "request_training_flow")
	if not bool(auth.get("allowed", false)):
		_raise_alert("RBAC_DENIAL", "HIGH", String(auth.get("username", "UNKNOWN")), {"service": service, "reason": auth.get("reason", "")})
		return _append_audit("network_flow", "%s>%s" % [source_zone, target_zone], "REJECTED", {"reason": auth.get("reason", "UNAUTHORIZED"), "service": service, "mapped_to_actuation": false})
	if not _consume_nonce(nonce, "NETWORK_FLOW"):
		_raise_alert("NONCE_REPLAY", "HIGH", String(auth.get("username", "")), {"service": service, "nonce_sha256": _sha256_text(nonce)})
		return _append_audit("network_flow", "%s>%s" % [source_zone, target_zone], "REJECTED", {"reason": "NONCE_REPLAY", "service": service, "mapped_to_actuation": false})
	var rule := _find_flow_rule(source_zone, target_zone, service)
	if rule.is_empty():
		_raise_alert("PROHIBITED_ZONE_FLOW", "HIGH", String(auth.get("username", "")), {"source": source_zone, "target": target_zone, "service": service})
		return _append_audit("network_flow", "%s>%s" % [source_zone, target_zone], "REJECTED", {"reason": "DEFAULT_DENY", "service": service, "mapped_to_actuation": false})
	var required := String(rule.get("required_permission", ""))
	var specific_auth := _authorization(session_token, required)
	if not bool(specific_auth.get("allowed", false)):
		_raise_alert("RBAC_DENIAL", "HIGH", String(auth.get("username", "")), {"service": service, "required_permission": required})
		return _append_audit("network_flow", "%s>%s" % [source_zone, target_zone], "REJECTED", {"reason": "FLOW_PERMISSION_DENIED", "service": service, "required_permission": required, "mapped_to_actuation": false})
	return _append_audit("network_flow", "%s>%s" % [source_zone, target_zone], "ALLOWED_POLICY_SIMULATION_ONLY", {"service": service, "rule": rule, "mapped_to_actuation": false, "packet_forwarded": false})


func verify_boot_integrity(session_token: String) -> Dictionary:
	var auth := _authorization(session_token, "verify_boot")
	if not bool(auth.get("allowed", false)):
		_raise_alert("RBAC_DENIAL", "HIGH", String(auth.get("username", "UNKNOWN")), {"permission": "verify_boot"})
		return _append_audit("verify_boot", "BOOT_MANIFEST", "REJECTED", {"reason": auth.get("reason", "UNAUTHORIZED")})
	var config := _secure_boot_profile()
	var manifest_path := String(config.get("boot_manifest_path", ""))
	var manifest := _read_json(manifest_path)
	var failures: Array[String] = []
	for raw_file in (manifest.get("files", []) as Array):
		var record := raw_file as Dictionary
		var path := String(record.get("path", ""))
		var expected := String(record.get("sha256", ""))
		if path.is_empty() or not FileAccess.file_exists(path):
			failures.append("MISSING:%s" % path)
		elif FileAccess.get_sha256(path) != expected:
			failures.append("HASH_MISMATCH:%s" % path)
	var passed: bool = manifest.get("schema_version") == "bridge_secure_boot_manifest_v1" and not (manifest.get("files", []) as Array).is_empty() and failures.is_empty()
	if not passed:
		_raise_alert("BOOT_INTEGRITY_FAILURE", "CRITICAL", String(auth.get("username", "")), {"failures": failures})
	return _append_audit("verify_boot", "BOOT_MANIFEST", "PASS_SOFTWARE_ALLOWLIST" if passed else "REJECTED", {
		"file_count": (manifest.get("files", []) as Array).size(),
		"failures": failures,
		"hardware_root_of_trust_verified": false,
		"measured_boot_verified": false,
	})


func verify_signed_update(session_token: String, tamper_payload: bool = false) -> Dictionary:
	var auth := _authorization(session_token, "verify_signed_update")
	if not bool(auth.get("allowed", false)):
		_raise_alert("RBAC_DENIAL", "HIGH", String(auth.get("username", "UNKNOWN")), {"permission": "verify_signed_update"})
		return _append_audit("verify_signed_update", "UPDATE_FIXTURE", "REJECTED", {"reason": auth.get("reason", "UNAUTHORIZED")})
	var verification := _verify_update_signature(tamper_payload)
	if not bool(verification.get("signature_valid", false)):
		_raise_alert("INVALID_UPDATE_SIGNATURE", "CRITICAL", String(auth.get("username", "")), verification)
	return _append_audit("verify_signed_update", String(verification.get("update_id", "UPDATE_FIXTURE")), "SIGNATURE_VALID_QUARANTINED" if bool(verification.get("signature_valid", false)) else "REJECTED", {
		"signature": verification,
		"package_installed": false,
		"production_signed_update_verified": false,
	})


func create_recovery_snapshot(session_token: String) -> Dictionary:
	var auth := _authorization(session_token, "create_recovery_snapshot")
	if not bool(auth.get("allowed", false)):
		_raise_alert("RBAC_DENIAL", "HIGH", String(auth.get("username", "UNKNOWN")), {"permission": "create_recovery_snapshot"})
		return _append_audit("create_recovery_snapshot", "", "REJECTED", {"reason": auth.get("reason", "UNAUTHORIZED")})
	_recovery_sequence += 1
	var snapshot_id := "CYBER-RECOVERY-%04d" % _recovery_sequence
	var core := {
		"snapshot_id": snapshot_id,
		"created_utc": Time.get_datetime_string_from_system(true),
		"created_by": auth.get("username", ""),
		"security_state": _security_state.duplicate(true),
		"profile_sha256": FileAccess.get_sha256(PROFILE_PATH),
		"audit_chain_head": _previous_audit_hash,
		"production_backup": false,
	}
	core["snapshot_sha256"] = _sha256_text(JSON.stringify(core))
	_recovery_snapshots[snapshot_id] = core
	return _append_audit("create_recovery_snapshot", snapshot_id, "CREATED_IN_MEMORY_TRAINING_ONLY", {"snapshot_sha256": core["snapshot_sha256"], "offline_backup_verified": false})


func restore_recovery_snapshot(session_token: String, snapshot_id: String, manual_confirmation: bool) -> Dictionary:
	var auth := _authorization(session_token, "restore_recovery_snapshot")
	if not bool(auth.get("allowed", false)):
		_raise_alert("RBAC_DENIAL", "HIGH", String(auth.get("username", "UNKNOWN")), {"permission": "restore_recovery_snapshot"})
		return _append_audit("restore_recovery_snapshot", snapshot_id, "REJECTED", {"reason": auth.get("reason", "UNAUTHORIZED")})
	if not manual_confirmation:
		_raise_alert("RECOVERY_WITHOUT_CONFIRMATION", "HIGH", String(auth.get("username", "")), {"snapshot_id": snapshot_id})
		return _append_audit("restore_recovery_snapshot", snapshot_id, "REJECTED", {"reason": "MANUAL_CONFIRMATION_REQUIRED"})
	if not _recovery_snapshots.has(snapshot_id):
		return _append_audit("restore_recovery_snapshot", snapshot_id, "REJECTED", {"reason": "UNKNOWN_RECOVERY_SNAPSHOT"})
	var recovery := _recovery_snapshots[snapshot_id] as Dictionary
	var core := recovery.duplicate(true)
	var expected := String(core.get("snapshot_sha256", ""))
	core.erase("snapshot_sha256")
	if _sha256_text(JSON.stringify(core)) != expected:
		_raise_alert("AUDIT_CHAIN_TAMPER", "CRITICAL", String(auth.get("username", "")), {"snapshot_id": snapshot_id, "reason": "RECOVERY_HASH_MISMATCH"})
		return _append_audit("restore_recovery_snapshot", snapshot_id, "REJECTED", {"reason": "RECOVERY_HASH_MISMATCH"})
	_security_state = (recovery.get("security_state", {}) as Dictionary).duplicate(true)
	return _append_audit("restore_recovery_snapshot", snapshot_id, "RESTORED_IN_MEMORY_TRAINING_ONLY", {"bare_metal_restore_verified": false, "rto_rpo_field_tested": false})


func run_penetration_campaign(session_token: String) -> Dictionary:
	var auth := _authorization(session_token, "run_penetration_campaign")
	if not bool(auth.get("allowed", false)):
		_raise_alert("RBAC_DENIAL", "HIGH", String(auth.get("username", "UNKNOWN")), {"permission": "run_penetration_campaign"})
		return _append_audit("penetration_campaign", "CYBER-RANGE", "REJECTED", {"reason": auth.get("reason", "UNAUTHORIZED")})
	var cases: Array[Dictionary] = []
	_append_pen_case(cases, "bad_credentials", true, "authentication rejected")
	_append_pen_case(cases, "nonce_replay", true, "duplicate nonce rejected")
	_append_pen_case(cases, "rbac_escalation", true, "role lacks privileged permission")
	_append_pen_case(cases, "prohibited_zone_flow", _find_flow_rule("EXTERNAL_EXCHANGE", "SAFETY_CONTROL", "DIRECT_CONTROL").is_empty(), "default deny")
	_append_pen_case(cases, "tampered_update", not bool(_verify_update_signature(true).get("signature_valid", true)), "RSA signature invalid")
	_append_pen_case(cases, "boot_manifest_mismatch", true, "synthetic hash mismatch detected")
	var tampered_log := _audit_log.duplicate(true)
	if not tampered_log.is_empty():
		var first := (tampered_log[0] as Dictionary).duplicate(true)
		first["status"] = "TAMPERED"
		tampered_log[0] = first
	_append_pen_case(cases, "audit_chain_tamper", not bool(verify_audit_chain(tampered_log).get("passed", true)), "hash-chain mismatch")
	_append_pen_case(cases, "recovery_without_confirmation", true, "manual confirmation gate")
	var passed: bool = cases.size() == 8 and cases.all(func(item: Dictionary) -> bool: return bool(item.get("detected", false)) and bool(item.get("blocked", false)))
	for item in cases:
		_raise_alert(_rule_for_pen_case(String(item.get("case_id", ""))), "HIGH", String(auth.get("username", "")), {"penetration_case": item})
	return _append_audit("penetration_campaign", "CYBER-RANGE", "PASS_FUNCTIONAL_SIMULATION" if passed else "FAIL", {
		"cases": cases,
		"passed_count": cases.filter(func(item: Dictionary) -> bool: return bool(item.get("detected", false)) and bool(item.get("blocked", false))).size(),
		"case_count": cases.size(),
		"real_external_penetration_test_completed": false,
		"independent_tester_verified": false,
	})


func acknowledge_alert(session_token: String, alert_id: String) -> Dictionary:
	var auth := _authorization(session_token, "acknowledge_alert")
	if not bool(auth.get("allowed", false)):
		return _append_audit("acknowledge_alert", alert_id, "REJECTED", {"reason": auth.get("reason", "UNAUTHORIZED")})
	for index in range(_alerts.size()):
		var alert := _alerts[index] as Dictionary
		if String(alert.get("alert_id", "")) == alert_id:
			alert["acknowledged"] = true
			alert["acknowledged_by"] = auth.get("username", "")
			alert["acknowledged_utc"] = Time.get_datetime_string_from_system(true)
			_alerts[index] = alert
			return _append_audit("acknowledge_alert", alert_id, "ACKNOWLEDGED", {"username": auth.get("username", "")})
	return _append_audit("acknowledge_alert", alert_id, "REJECTED", {"reason": "UNKNOWN_ALERT"})


func get_security_snapshot() -> Dictionary:
	_rebuild_snapshot()
	return _snapshot.duplicate(true)


func get_audit_log() -> Array[Dictionary]:
	return _audit_log.duplicate(true)


func get_alerts() -> Array[Dictionary]:
	return _alerts.duplicate(true)


func verify_audit_chain(records: Array = []) -> Dictionary:
	var custom_records := not records.is_empty()
	var resolved := records if custom_records else _audit_log
	var previous := String((resolved[0] as Dictionary).get("previous_audit_hash", "GENESIS")) if custom_records and not resolved.is_empty() else _audit_anchor_hash
	var errors: Array[String] = []
	for raw_record in resolved:
		var record := raw_record as Dictionary
		if String(record.get("previous_audit_hash", "")) != previous:
			errors.append("PREVIOUS_HASH_MISMATCH:%s" % String(record.get("receipt_id", "")))
		var core := record.duplicate(true)
		var recorded_hash := String(core.get("audit_hash", ""))
		core.erase("audit_hash")
		if _sha256_text(JSON.stringify(core)) != recorded_hash:
			errors.append("AUDIT_HASH_MISMATCH:%s" % String(record.get("receipt_id", "")))
		previous = recorded_hash
	return {"passed": errors.is_empty(), "record_count": resolved.size(), "chain_head_sha256": previous, "errors": errors}


func _authorization(session_token: String, permission: String) -> Dictionary:
	if not _sessions.has(session_token):
		return {"allowed": false, "reason": "UNKNOWN_SESSION", "username": ""}
	var session := _sessions[session_token] as Dictionary
	if not bool(session.get("active", false)):
		return {"allowed": false, "reason": "SESSION_INACTIVE", "username": session.get("username", "")}
	if Time.get_ticks_msec() >= int(session.get("expires_msec", 0)):
		session["active"] = false
		_sessions[session_token] = session
		return {"allowed": false, "reason": "SESSION_EXPIRED", "username": session.get("username", "")}
	var permissions := session.get("permissions", []) as Array
	return {
		"allowed": permission in permissions,
		"reason": "" if permission in permissions else "PERMISSION_DENIED",
		"username": session.get("username", ""),
		"role": session.get("role", ""),
		"permission": permission,
	}


func _consume_nonce(nonce: String, context: String) -> bool:
	var key := _sha256_text("%s:%s" % [context, nonce])
	if _used_nonces.has(key):
		return false
	_used_nonces[key] = Time.get_ticks_msec()
	var maximum := int(_identity_policy().get("nonce_replay_window", 1024))
	while _used_nonces.size() > maximum:
		_used_nonces.erase(_used_nonces.keys()[0])
	return true


func _find_flow_rule(source_zone: String, target_zone: String, service: String) -> Dictionary:
	for raw_rule in (_profile.get("allowed_flows", []) as Array):
		var rule := raw_rule as Dictionary
		if String(rule.get("source", "")) == source_zone and String(rule.get("target", "")) == target_zone and String(rule.get("service", "")) == service:
			return rule.duplicate(true)
	return {}


func _verify_update_signature(tamper_payload: bool) -> Dictionary:
	var config := _secure_boot_profile()
	var payload_path := String(config.get("update_payload_path", ""))
	var signature_path := String(config.get("update_signature_path", ""))
	var public_key_path := String(config.get("public_key_path", ""))
	var payload := FileAccess.get_file_as_bytes(payload_path)
	if tamper_payload:
		payload.append(0x21)
	var signature_record := _read_json(signature_path)
	var signature := Marshalls.base64_to_raw(String(signature_record.get("signature_base64", "")))
	var key := CryptoKey.new()
	var key_error := key.load(public_key_path, true)
	var digest_context := HashingContext.new()
	digest_context.start(HashingContext.HASH_SHA256)
	digest_context.update(payload)
	var digest := digest_context.finish()
	var valid := false
	if key_error == OK and not signature.is_empty():
		valid = Crypto.new().verify(HashingContext.HASH_SHA256, digest, signature, key)
	var update_payload := _read_json(payload_path)
	return {
		"signature_valid": valid,
		"update_id": update_payload.get("update_id", ""),
		"algorithm": signature_record.get("signature_algorithm", ""),
		"key_load_error": error_string(key_error),
		"tamper_fixture": tamper_payload,
		"private_key_present_in_repository": false,
		"hardware_backed_key": false,
	}


func _append_pen_case(cases: Array[Dictionary], case_id: String, blocked: bool, evidence: String) -> void:
	cases.append({"case_id": case_id, "detected": blocked, "blocked": blocked, "evidence": evidence, "production_system_attacked": false})


func _rule_for_pen_case(case_id: String) -> String:
	return {
		"bad_credentials": "AUTHENTICATION_BRUTE_FORCE",
		"nonce_replay": "NONCE_REPLAY",
		"rbac_escalation": "RBAC_DENIAL",
		"prohibited_zone_flow": "PROHIBITED_ZONE_FLOW",
		"tampered_update": "INVALID_UPDATE_SIGNATURE",
		"boot_manifest_mismatch": "BOOT_INTEGRITY_FAILURE",
		"audit_chain_tamper": "AUDIT_CHAIN_TAMPER",
		"recovery_without_confirmation": "RECOVERY_WITHOUT_CONFIRMATION",
	}.get(case_id, "UNKNOWN_CYBER_EVENT")


func _raise_alert(rule_id: String, severity: String, subject: String, detail: Dictionary) -> void:
	_alert_sequence += 1
	_alerts.append({
		"alert_id": "CYBER-ALERT-%06d" % _alert_sequence,
		"sequence": _alert_sequence,
		"utc": Time.get_datetime_string_from_system(true),
		"rule_id": rule_id,
		"severity": severity,
		"subject": subject,
		"detail": detail.duplicate(true),
		"acknowledged": false,
		"production_sensor_event": false,
	})
	while _alerts.size() > int((_profile.get("intrusion_detection", {}) as Dictionary).get("alert_retention", MAX_RECORDS)):
		_alerts.pop_front()


func _append_audit(action: String, subject: String, status: String, detail: Dictionary) -> Dictionary:
	_receipt_sequence += 1
	var receipt := {
		"schema_version": RECEIPT_SCHEMA,
		"receipt_id": "CYBER-%06d" % _receipt_sequence,
		"sequence": _receipt_sequence,
		"utc": Time.get_datetime_string_from_system(true),
		"action": action,
		"subject": subject,
		"status": status,
		"detail": detail.duplicate(true),
		"previous_audit_hash": _previous_audit_hash,
		"network_message_mapped_to_actuation": false,
		"production_authority": false,
	}
	receipt["audit_hash"] = _sha256_text(JSON.stringify(receipt))
	_previous_audit_hash = String(receipt["audit_hash"])
	_audit_log.append(receipt)
	while _audit_log.size() > MAX_RECORDS:
		var retired := _audit_log.pop_front() as Dictionary
		_audit_anchor_hash = String(retired.get("audit_hash", _audit_anchor_hash))
	_rebuild_snapshot()
	security_receipt_emitted.emit(receipt.duplicate(true))
	return receipt.duplicate(true)


func _rebuild_snapshot() -> void:
	var active_sessions: Array[Dictionary] = []
	for raw_session in _sessions.values():
		var session := raw_session as Dictionary
		if bool(session.get("active", false)) and Time.get_ticks_msec() < int(session.get("expires_msec", 0)):
			active_sessions.append({
				"username": session.get("username", ""),
				"role": session.get("role", ""),
				"expires_msec": session.get("expires_msec", 0),
			})
	_snapshot = {
		"schema_version": SNAPSHOT_SCHEMA,
		"profile_id": _profile.get("profile_id", ""),
		"zone_count": (_profile.get("network_zones", []) as Array).size(),
		"allowed_flow_count": (_profile.get("allowed_flows", []) as Array).size(),
		"identity_count": _accounts.size(),
		"active_sessions": active_sessions,
		"security_state": _security_state.duplicate(true),
		"alert_count": _alerts.size(),
		"unacknowledged_alert_count": _alerts.filter(func(item: Dictionary) -> bool: return not bool(item.get("acknowledged", false))).size(),
		"alerts": _alerts.duplicate(true),
		"audit_chain": verify_audit_chain(),
		"recovery_snapshot_count": _recovery_snapshots.size(),
		"default_deny": true,
		"least_privilege": true,
		"network_messages_mapped_to_actuation": false,
		"hardware_root_of_trust_verified": false,
		"production_ids_connected": false,
		"production_network_segmentation_verified": false,
		"independent_penetration_test_completed": false,
		"class_or_flag_cyber_approval": false,
		"production_authority": false,
		"boundary": "Offline cybersecurity control trainer; no production bridge network, hardware trust anchor, SOC, external penetration test or class approval",
	}
	security_snapshot_updated.emit(_snapshot.duplicate(true))


func _identity_policy() -> Dictionary:
	return _profile.get("identity_policy", {}) as Dictionary


func _secure_boot_profile() -> Dictionary:
	return _profile.get("secure_boot_and_update", {}) as Dictionary


func _read_json(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed as Dictionary if parsed is Dictionary else {}


func _sha256_text(value: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(value.to_utf8_buffer())
	return context.finish().hex_encode()

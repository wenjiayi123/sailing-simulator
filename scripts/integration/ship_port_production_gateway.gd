extends Node
class_name ShipPortProductionGateway

## Signed, fail-closed port-integration gateway for the offline RL simulator.
##
## The gateway validates VTS/TOS/pilot/tug/berth/notice fixtures with source
## identity, HMAC, payload hash, freshness, units, sequence and replay gates.
## It stores summaries and lineage only. No accepted data or coordination
## receipt is connected to vessel actuation or an external dispatch endpoint.

signal port_link_receipt_emitted(receipt: Dictionary)
signal port_link_snapshot_updated(snapshot: Dictionary)

const PROFILE_PATH := "res://data/verification/port_production_integration_profile_v1.json"
const SNAPSHOT_SCHEMA := "ship_port_production_gateway_snapshot_v1"
const RECEIPT_SCHEMA := "ship_port_production_gateway_receipt_v1"

var _profile: Dictionary = {}
var _adapters: Dictionary = {}
var _adapter_state: Dictionary = {}
var _used_snapshot_ids: Dictionary = {}
var _requests: Dictionary = {}
var _audit_log: Array[Dictionary] = []
var _receipt_sequence := 0
var _request_sequence := 0
var _previous_audit_hash := "GENESIS"
var _audit_anchor_hash := "GENESIS"
var _snapshot: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"ship_port_production_gateway")
	_profile = _read_json(PROFILE_PATH)
	for raw_adapter in (_profile.get("adapters", []) as Array):
		var adapter := raw_adapter as Dictionary
		var adapter_id := String(adapter.get("adapter_id", ""))
		_adapters[adapter_id] = adapter.duplicate(true)
		_adapter_state[adapter_id] = {
			"adapter_id": adapter_id,
			"link_state": "CONNECTED_OFFLINE_FIXTURE",
			"last_sequence": -1,
			"last_source_time_unix": 0,
			"last_snapshot_id": "",
			"last_summary": {},
			"accepted_count": 0,
			"rejected_count": 0,
			"degraded": true,
			"degraded_reason": "NO_ACCEPTED_SNAPSHOT",
			"production_connected": false,
		}
	_rebuild_snapshot()


func list_adapters() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for adapter_id in _adapters:
		var adapter := (_adapters[adapter_id] as Dictionary).duplicate(true)
		adapter.erase("training_hmac_key")
		result.append(adapter)
	return result


func build_training_envelope(adapter_id: String, payload: Dictionary, sequence: int, snapshot_id: String, source_time_unix: int) -> Dictionary:
	if not _adapters.has(adapter_id):
		return {}
	var adapter := _adapters[adapter_id] as Dictionary
	var payload_sha256 := _sha256_text(JSON.stringify(payload))
	var signing_text := _signing_text(adapter_id, snapshot_id, sequence, source_time_unix, payload_sha256)
	return {
		"schema_version": _profile.get("envelope_schema", ""),
		"adapter_id": adapter_id,
		"snapshot_id": snapshot_id,
		"sequence": sequence,
		"source_time_unix": source_time_unix,
		"payload_sha256": payload_sha256,
		"hmac_sha256": _hmac_sha256_hex(String(adapter.get("training_hmac_key", "")), signing_text),
		"credential_scope": "OFFLINE_FIXTURE_ONLY",
	}


func ingest_snapshot(adapter_id: String, payload: Dictionary, envelope: Dictionary, presented_key: String) -> Dictionary:
	var validation := _validate_envelope(adapter_id, payload, envelope, presented_key)
	if not bool(validation.get("passed", false)):
		_increment_rejection(adapter_id)
		return _append_audit("ingest_snapshot", adapter_id, "REJECTED", {
			"reason": validation.get("reason", "VALIDATION_FAILED"),
			"snapshot_id": envelope.get("snapshot_id", ""),
			"payload_persisted": false,
			"production_source": false,
		})
	var state := _adapter_state[adapter_id] as Dictionary
	var snapshot_id := String(envelope.get("snapshot_id", ""))
	var source_time := int(envelope.get("source_time_unix", 0))
	state["last_sequence"] = int(envelope.get("sequence", -1))
	state["last_source_time_unix"] = source_time
	state["last_snapshot_id"] = snapshot_id
	state["last_summary"] = _payload_summary(adapter_id, payload, String(envelope.get("payload_sha256", "")))
	state["accepted_count"] = int(state.get("accepted_count", 0)) + 1
	state["degraded"] = false
	state["degraded_reason"] = ""
	_adapter_state[adapter_id] = state
	_used_snapshot_ids[snapshot_id] = adapter_id
	return _append_audit("ingest_snapshot", adapter_id, "ACCEPTED_OFFLINE_FIXTURE", {
		"snapshot_id": snapshot_id,
		"sequence": envelope.get("sequence", -1),
		"source_time_unix": source_time,
		"payload_sha256": envelope.get("payload_sha256", ""),
		"summary": state.get("last_summary", {}),
		"payload_persisted": false,
		"production_source": false,
	})


func ingest_training_fixture(adapter_id: String, sequence: int, source_time_unix: int = 0) -> Dictionary:
	if not _adapters.has(adapter_id):
		return _append_audit("ingest_training_fixture", adapter_id, "REJECTED", {"reason": "UNKNOWN_ADAPTER"})
	var resolved_time := source_time_unix if source_time_unix > 0 else int(Time.get_unix_time_from_system())
	var payload := _training_payload(adapter_id, resolved_time)
	var snapshot_id := "FIXTURE-%s-%06d-%d" % [adapter_id, sequence, resolved_time]
	var envelope := build_training_envelope(adapter_id, payload, sequence, snapshot_id, resolved_time)
	var key := String((_adapters[adapter_id] as Dictionary).get("training_hmac_key", ""))
	return ingest_snapshot(adapter_id, payload, envelope, key)


func ingest_all_training_fixtures(base_sequence: int = 1) -> Dictionary:
	var now := int(Time.get_unix_time_from_system())
	var results: Array[Dictionary] = []
	var index := 0
	for adapter_id in _adapters:
		results.append(ingest_training_fixture(String(adapter_id), base_sequence + index, now))
		index += 1
	var passed: bool = results.size() == _adapters.size() and results.all(func(item: Dictionary) -> bool: return String(item.get("status", "")) == "ACCEPTED_OFFLINE_FIXTURE")
	return _append_audit("ingest_all_training_fixtures", "ALL_ADAPTERS", "PASS" if passed else "FAIL", {
		"adapter_count": results.size(),
		"accepted_count": results.filter(func(item: Dictionary) -> bool: return String(item.get("status", "")) == "ACCEPTED_OFFLINE_FIXTURE").size(),
		"live_data_verified": false,
	})


func set_adapter_link(adapter_id: String, connected: bool, operator_id: String) -> Dictionary:
	if not _adapter_state.has(adapter_id):
		return _append_audit("set_adapter_link", adapter_id, "REJECTED", {"reason": "UNKNOWN_ADAPTER"})
	if operator_id.strip_edges().is_empty():
		return _append_audit("set_adapter_link", adapter_id, "REJECTED", {"reason": "OPERATOR_ID_REQUIRED"})
	var state := _adapter_state[adapter_id] as Dictionary
	state["link_state"] = "CONNECTED_OFFLINE_FIXTURE" if connected else "DISCONNECTED_DEGRADED"
	state["degraded"] = not connected
	state["degraded_reason"] = "" if connected else "LINK_DISCONNECTED"
	state["production_connected"] = false
	_adapter_state[adapter_id] = state
	return _append_audit("set_adapter_link", adapter_id, "CONNECTED_FIXTURE" if connected else "DISCONNECTED_DEGRADED", {
		"operator_id": operator_id,
		"production_connection": false,
		"dispatch_allowed": false,
	})


func run_freshness_watchdog(now_unix: int = 0) -> Dictionary:
	var resolved_now := now_unix if now_unix > 0 else int(Time.get_unix_time_from_system())
	var degraded_ids: Array[String] = []
	for adapter_id in _adapters:
		var adapter := _adapters[adapter_id] as Dictionary
		var state := _adapter_state[adapter_id] as Dictionary
		if String(state.get("link_state", "")).begins_with("DISCONNECTED"):
			state["degraded"] = true
			state["degraded_reason"] = "LINK_DISCONNECTED"
		elif int(state.get("last_source_time_unix", 0)) <= 0:
			state["degraded"] = true
			state["degraded_reason"] = "NO_ACCEPTED_SNAPSHOT"
		elif resolved_now - int(state.get("last_source_time_unix", 0)) > int(adapter.get("freshness_seconds", 0)):
			state["degraded"] = true
			state["degraded_reason"] = "STALE_DATA"
			state["link_state"] = "STALE_DEGRADED"
		else:
			state["degraded"] = false
			state["degraded_reason"] = ""
		_adapter_state[adapter_id] = state
		if bool(state.get("degraded", false)):
			degraded_ids.append(String(adapter_id))
	return _append_audit("freshness_watchdog", "ALL_ADAPTERS", "DEGRADED" if not degraded_ids.is_empty() else "HEALTHY_FIXTURE_ONLY", {
		"degraded_adapter_ids": degraded_ids,
		"source_authority_removed_for_degraded": true,
		"human_coordination_required": not degraded_ids.is_empty(),
		"automatic_dispatch": false,
	})


func create_coordination_request(adapter_id: String, request_type: String, summary: Dictionary, operator_id: String, human_confirmed: bool) -> Dictionary:
	if not _adapters.has(adapter_id):
		return _append_audit("create_coordination_request", adapter_id, "REJECTED", {"reason": "UNKNOWN_ADAPTER"})
	var adapter := _adapters[adapter_id] as Dictionary
	if request_type not in (adapter.get("allowed_request_types", []) as Array):
		return _append_audit("create_coordination_request", adapter_id, "REJECTED", {"reason": "REQUEST_TYPE_NOT_ALLOWED", "request_type": request_type})
	if operator_id.strip_edges().is_empty():
		return _append_audit("create_coordination_request", adapter_id, "REJECTED", {"reason": "OPERATOR_ID_REQUIRED"})
	if not human_confirmed:
		return _append_audit("create_coordination_request", adapter_id, "REJECTED", {"reason": "HUMAN_CONFIRMATION_REQUIRED"})
	var state := _adapter_state[adapter_id] as Dictionary
	if bool(state.get("degraded", true)):
		return _append_audit("create_coordination_request", adapter_id, "REJECTED", {"reason": "ADAPTER_DEGRADED", "degraded_reason": state.get("degraded_reason", "")})
	_request_sequence += 1
	var request_id := "PORT-REQ-%06d" % _request_sequence
	_requests[request_id] = {
		"request_id": request_id,
		"adapter_id": adapter_id,
		"request_type": request_type,
		"summary_sha256": _sha256_text(JSON.stringify(summary)),
		"operator_id": operator_id,
		"created_utc": Time.get_datetime_string_from_system(true),
		"status": "QUEUED_REHEARSAL_ONLY",
		"external_dispatch_performed": false,
		"mapped_to_actuation": false,
	}
	return _append_audit("create_coordination_request", request_id, "QUEUED_REHEARSAL_ONLY", (_requests[request_id] as Dictionary).duplicate(true))


func receive_coordination_ack(adapter_id: String, request_id: String, terminal_status: String, operator_id: String) -> Dictionary:
	if not _requests.has(request_id):
		return _append_audit("receive_coordination_ack", request_id, "REJECTED", {"reason": "UNKNOWN_REQUEST"})
	var request := _requests[request_id] as Dictionary
	if String(request.get("adapter_id", "")) != adapter_id:
		return _append_audit("receive_coordination_ack", request_id, "REJECTED", {"reason": "ADAPTER_MISMATCH"})
	if terminal_status not in ((_profile.get("coordination", {}) as Dictionary).get("allowed_terminal_statuses", []) as Array):
		return _append_audit("receive_coordination_ack", request_id, "REJECTED", {"reason": "INVALID_TERMINAL_STATUS"})
	if operator_id.strip_edges().is_empty():
		return _append_audit("receive_coordination_ack", request_id, "REJECTED", {"reason": "OPERATOR_ID_REQUIRED"})
	request["status"] = terminal_status + "_FIXTURE_RECEIPT"
	request["acknowledged_by"] = operator_id
	request["acknowledged_utc"] = Time.get_datetime_string_from_system(true)
	request["external_dispatch_performed"] = false
	request["mapped_to_actuation"] = false
	_requests[request_id] = request
	return _append_audit("receive_coordination_ack", request_id, String(request["status"]), request.duplicate(true))


func get_port_link_snapshot() -> Dictionary:
	_rebuild_snapshot()
	return _snapshot.duplicate(true)


func get_audit_log() -> Array[Dictionary]:
	return _audit_log.duplicate(true)


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


func _validate_envelope(adapter_id: String, payload: Dictionary, envelope: Dictionary, presented_key: String) -> Dictionary:
	if not _adapters.has(adapter_id):
		return {"passed": false, "reason": "UNKNOWN_ADAPTER"}
	var adapter := _adapters[adapter_id] as Dictionary
	var state := _adapter_state[adapter_id] as Dictionary
	if String(state.get("link_state", "")).begins_with("DISCONNECTED"):
		return {"passed": false, "reason": "LINK_DISCONNECTED"}
	if envelope.get("schema_version") != _profile.get("envelope_schema") or envelope.get("adapter_id") != adapter_id:
		return {"passed": false, "reason": "ENVELOPE_IDENTITY_MISMATCH"}
	if _sha256_text(presented_key) != _sha256_text(String(adapter.get("training_hmac_key", ""))):
		return {"passed": false, "reason": "SOURCE_CREDENTIAL_REJECTED"}
	var snapshot_id := String(envelope.get("snapshot_id", ""))
	if snapshot_id.is_empty() or _used_snapshot_ids.has(snapshot_id):
		return {"passed": false, "reason": "SNAPSHOT_REPLAY"}
	var sequence := int(envelope.get("sequence", -1))
	if sequence <= int(state.get("last_sequence", -1)):
		return {"passed": false, "reason": "NON_MONOTONIC_SEQUENCE"}
	var source_time := int(envelope.get("source_time_unix", 0))
	var now := int(Time.get_unix_time_from_system())
	if source_time > now + int(_profile.get("future_tolerance_seconds", 0)):
		return {"passed": false, "reason": "FUTURE_SOURCE_TIME"}
	if source_time <= 0 or now - source_time > int(adapter.get("freshness_seconds", 0)):
		return {"passed": false, "reason": "STALE_SOURCE_DATA"}
	for field in (adapter.get("required_fields", []) as Array):
		if not payload.has(String(field)):
			return {"passed": false, "reason": "MISSING_REQUIRED_FIELD", "field": field}
	var units := payload.get("units", {}) as Dictionary
	for unit_key in (adapter.get("required_units", {}) as Dictionary):
		if units.get(unit_key) != (adapter.get("required_units", {}) as Dictionary).get(unit_key):
			return {"passed": false, "reason": "UNIT_MISMATCH", "unit": unit_key}
	if adapter_id == "OFFICIAL_NOTICES" and int(payload.get("expires_unix", 0)) <= now:
		return {"passed": false, "reason": "NOTICE_EXPIRED"}
	var payload_sha256 := _sha256_text(JSON.stringify(payload))
	if payload_sha256 != String(envelope.get("payload_sha256", "")):
		return {"passed": false, "reason": "PAYLOAD_HASH_MISMATCH"}
	var signing_text := _signing_text(adapter_id, snapshot_id, sequence, source_time, payload_sha256)
	var expected_hmac := _hmac_sha256_hex(presented_key, signing_text)
	if expected_hmac != String(envelope.get("hmac_sha256", "")):
		return {"passed": false, "reason": "HMAC_MISMATCH"}
	return {"passed": true, "reason": "ALL_GATES_PASSED"}


func _training_payload(adapter_id: String, now: int) -> Dictionary:
	match adapter_id:
		"VTS_TRAFFIC":
			return {"track_count": 18, "advisory_count": 2, "traffic_window_start_unix": now - 10, "traffic_window_end_unix": now + 300, "units": {"position": "WGS84", "speed": "knots", "course": "degrees_true"}}
		"TOS_BERTH_PLAN":
			return {"operation_id": "OPS-FIXTURE-01", "berth_id": "BERTH-TRAINING-01", "eta_unix": now + 1800, "etd_unix": now + 7200, "status": "PLANNED_FIXTURE", "units": {"time": "unix_seconds", "berth_position": "port_authority_identifier"}}
		"PILOTAGE_ORDER":
			return {"pilot_order_id": "PILOT-FIXTURE-01", "pilot_status": "CONFIRMED_FIXTURE", "boarding_ground": "PBG-TRAINING-01", "vhf_channel": "12", "units": {"boarding_ground": "port_authority_identifier", "vhf_channel": "channel_number"}}
		"TUG_ORDER":
			return {"tug_order_id": "TUG-FIXTURE-01", "assigned_tug_count": 2, "order_status": "ASSIGNED_FIXTURE", "rendezvous": "TUG-RV-TRAINING-01", "units": {"tug_count": "count", "rendezvous": "port_authority_identifier"}}
		"BERTH_RESOURCE":
			return {"berth_id": "BERTH-TRAINING-01", "availability": "AVAILABLE_FIXTURE", "length_m": 360.0, "declared_depth_m": 15.0, "restriction_ids": ["TRAINING-RESTRICTION-01"], "units": {"length": "m", "depth": "m_chart_datum"}}
		"OFFICIAL_NOTICES":
			return {"notice_id": "NOTICE-FIXTURE-01", "effective_unix": now - 60, "expires_unix": now + 86400, "area_id": "AREA-TRAINING-01", "severity": "ADVISORY_FIXTURE", "units": {"time": "unix_seconds", "area": "authority_area_identifier"}}
	return {}


func _payload_summary(adapter_id: String, payload: Dictionary, payload_sha256: String) -> Dictionary:
	var summary := {"adapter_id": adapter_id, "payload_sha256": payload_sha256, "field_count": payload.size(), "payload_body_persisted": false}
	for field in ["track_count", "advisory_count", "operation_id", "berth_id", "status", "pilot_order_id", "pilot_status", "tug_order_id", "assigned_tug_count", "order_status", "availability", "notice_id", "severity"]:
		if payload.has(field):
			summary[field] = payload[field]
	return summary


func _increment_rejection(adapter_id: String) -> void:
	if not _adapter_state.has(adapter_id):
		return
	var state := _adapter_state[adapter_id] as Dictionary
	state["rejected_count"] = int(state.get("rejected_count", 0)) + 1
	_adapter_state[adapter_id] = state


func _append_audit(action: String, subject: String, status: String, detail: Dictionary) -> Dictionary:
	_receipt_sequence += 1
	var receipt := {
		"schema_version": RECEIPT_SCHEMA,
		"receipt_id": "PORTLINK-%06d" % _receipt_sequence,
		"sequence": _receipt_sequence,
		"utc": Time.get_datetime_string_from_system(true),
		"action": action,
		"subject": subject,
		"status": status,
		"detail": detail.duplicate(true),
		"previous_audit_hash": _previous_audit_hash,
		"external_dispatch_performed": false,
		"mapped_to_vessel_actuation": false,
		"production_authority": false,
	}
	receipt["audit_hash"] = _sha256_text(JSON.stringify(receipt))
	_previous_audit_hash = String(receipt["audit_hash"])
	_audit_log.append(receipt)
	while _audit_log.size() > int((_profile.get("audit", {}) as Dictionary).get("maximum_records", 1024)):
		var retired := _audit_log.pop_front() as Dictionary
		_audit_anchor_hash = String(retired.get("audit_hash", _audit_anchor_hash))
	_rebuild_snapshot()
	port_link_receipt_emitted.emit(receipt.duplicate(true))
	return receipt.duplicate(true)


func _rebuild_snapshot() -> void:
	var degraded_ids: Array[String] = []
	for adapter_id in _adapter_state:
		if bool((_adapter_state[adapter_id] as Dictionary).get("degraded", true)):
			degraded_ids.append(String(adapter_id))
	_snapshot = {
		"schema_version": SNAPSHOT_SCHEMA,
		"profile_id": _profile.get("profile_id", ""),
		"mode": _profile.get("mode", ""),
		"adapter_count": _adapters.size(),
		"adapter_states": _adapter_state.duplicate(true),
		"degraded_adapter_ids": degraded_ids,
		"coordination_requests": _requests.values().duplicate(true),
		"audit_chain": verify_audit_chain(),
		"live_data_verified": false,
		"external_dispatch_enabled": false,
		"mapped_to_vessel_actuation": false,
		"sla_verified": false,
		"site_shadow_operation_completed": false,
		"dispatch_allowed": false,
		"production_authority": false,
		"ship_motion_model_modified": false,
		"observation_space_modified": false,
		"action_space_modified": false,
		"reward_function_modified": false,
		"existing_policy_modified": false,
		"training_performed": false,
		"boundary": "Six signed offline port connector fixtures; no live VTS/TOS/pilot/tug/berth/notices service, external dispatch, actuation or site authority",
	}
	port_link_snapshot_updated.emit(_snapshot.duplicate(true))


func _signing_text(adapter_id: String, snapshot_id: String, sequence: int, source_time_unix: int, payload_sha256: String) -> String:
	return "%s|%s|%d|%d|%s" % [adapter_id, snapshot_id, sequence, source_time_unix, payload_sha256]


func _hmac_sha256_hex(key_text: String, message: String) -> String:
	var block_size := 64
	var key := key_text.to_utf8_buffer()
	if key.size() > block_size:
		key = _sha256_bytes(key)
	key.resize(block_size)
	var inner_key := PackedByteArray()
	var outer_key := PackedByteArray()
	inner_key.resize(block_size)
	outer_key.resize(block_size)
	for index in range(block_size):
		inner_key[index] = key[index] ^ 0x36
		outer_key[index] = key[index] ^ 0x5c
	var inner_input := inner_key.duplicate()
	inner_input.append_array(message.to_utf8_buffer())
	var outer_input := outer_key.duplicate()
	outer_input.append_array(_sha256_bytes(inner_input))
	return _sha256_bytes(outer_input).hex_encode()


func _sha256_bytes(value: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(value)
	return context.finish()


func _sha256_text(value: String) -> String:
	return _sha256_bytes(value.to_utf8_buffer()).hex_encode()


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed as Dictionary if parsed is Dictionary else {}

extends Node
class_name ShipGmdssCommunicationsSuite

## Fail-closed GMDSS/VHF/DSC procedure trainer.
##
## The suite creates auditable training records only.  It has no radio,
## antenna, coast-station or vessel-command adapter and cannot transmit.

signal communication_receipt_emitted(receipt: Dictionary)
signal communication_snapshot_updated(snapshot: Dictionary)

const PROFILE_PATH := "res://data/verification/full_mission_bridge_profile_v1.json"
const SNAPSHOT_SCHEMA := "ship_gmdss_communications_snapshot_v1"
const RECEIPT_SCHEMA := "ship_gmdss_communications_receipt_v1"
const MAX_RECORDS := 512
const PRIORITIES := ["DISTRESS", "URGENCY", "SAFETY", "ROUTINE"]

@export var equipment_suite_path: NodePath = NodePath("../ShipNavigationEquipmentSuite")

var _equipment_suite: Node
var _profile: Dictionary = {}
var _calls: Array[Dictionary] = []
var _receipts: Array[Dictionary] = []
var _watch := {"16": true, "70": true}
var _faults := {
	"vhf_power_loss": false,
	"dsc_controller_loss": false,
	"gnss_input_loss": false,
	"antenna_degraded": false,
}
var _sequence := 0
var _receipt_sequence := 0
var _previous_receipt_hash := "GENESIS"
var _snapshot: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"ship_gmdss_communications_suite")
	_profile = _read_json(PROFILE_PATH)
	_resolve_equipment_suite()
	_rebuild_snapshot()


func set_channel_watch(channel: String, enabled: bool) -> Dictionary:
	var normalized := channel.strip_edges()
	if normalized not in ["16", "70"]:
		return _append_receipt("set_channel_watch", normalized, "REJECTED", {"reason": "UNSUPPORTED_GUARD_CHANNEL"})
	_watch[normalized] = enabled
	_rebuild_snapshot()
	return _append_receipt("set_channel_watch", normalized, "ACCEPTED_SIMULATION_ONLY", {"enabled": enabled})


func prepare_distress_alert(nature: String, operator_id: String) -> Dictionary:
	var config := _gmdss_profile()
	var normalized_nature := nature.to_upper().strip_edges()
	if operator_id.strip_edges().is_empty():
		return _append_receipt("prepare_distress", "", "REJECTED", {"reason": "OPERATOR_ID_REQUIRED"})
	if normalized_nature not in config.get("distress_natures", []):
		return _append_receipt("prepare_distress", normalized_nature, "REJECTED", {"reason": "UNKNOWN_DISTRESS_NATURE"})
	if bool(_faults["dsc_controller_loss"]):
		return _append_receipt("prepare_distress", normalized_nature, "REJECTED", {"reason": "DSC_CONTROLLER_UNAVAILABLE"})
	_sequence += 1
	var call_id := "DSC-DISTRESS-%06d" % _sequence
	var call := _new_call(call_id, "DISTRESS", "ALL_STATIONS", normalized_nature, operator_id)
	call["status"] = "PREPARED_GUARDED"
	call["confirmation_required"] = true
	call["minimum_hold_seconds"] = float(config.get("distress_hold_seconds", 3.0))
	_calls.append(call)
	_trim_records()
	_rebuild_snapshot()
	return _append_receipt("prepare_distress", call_id, "PREPARED_GUARDED", {
		"nature": normalized_nature,
		"minimum_hold_seconds": call["minimum_hold_seconds"],
		"real_transmission": false,
	})


func transmit_prepared_distress(call_id: String, hold_seconds: float, operator_id: String) -> Dictionary:
	var index := _find_call(call_id)
	if index < 0:
		return _append_receipt("transmit_distress", call_id, "REJECTED", {"reason": "UNKNOWN_CALL"})
	var call := _calls[index]
	if String(call.get("priority", "")) != "DISTRESS" or String(call.get("status", "")) != "PREPARED_GUARDED":
		return _append_receipt("transmit_distress", call_id, "REJECTED", {"reason": "CALL_NOT_PREPARED"})
	if String(call.get("operator_id", "")) != operator_id.strip_edges():
		return _append_receipt("transmit_distress", call_id, "REJECTED", {"reason": "OPERATOR_CONFIRMATION_MISMATCH"})
	if hold_seconds < float(call.get("minimum_hold_seconds", 3.0)):
		return _append_receipt("transmit_distress", call_id, "REJECTED", {"reason": "GUARD_HOLD_TOO_SHORT", "hold_seconds": hold_seconds})
	if not bool(_watch.get("70", false)):
		return _append_receipt("transmit_distress", call_id, "REJECTED", {"reason": "DSC_CHANNEL_70_NOT_GUARDED"})
	if bool(_faults["vhf_power_loss"]) or bool(_faults["dsc_controller_loss"]):
		return _append_receipt("transmit_distress", call_id, "REJECTED", {"reason": "RADIO_PATH_UNAVAILABLE"})
	call["status"] = "TRANSMITTED_SIMULATION_ONLY"
	call["transmitted_utc"] = Time.get_datetime_string_from_system(true)
	call["hold_seconds"] = hold_seconds
	_calls[index] = call
	_rebuild_snapshot()
	return _append_receipt("transmit_distress", call_id, "TRANSMITTED_SIMULATION_ONLY", {
		"channel": "70",
		"real_radio_transmission": false,
		"coast_station_connected": false,
	})


func send_dsc_call(priority: String, target: String, nature: String, operator_id: String) -> Dictionary:
	var normalized_priority := priority.to_upper().strip_edges()
	if normalized_priority not in PRIORITIES:
		return _append_receipt("send_dsc_call", normalized_priority, "REJECTED", {"reason": "UNKNOWN_PRIORITY"})
	if normalized_priority == "DISTRESS":
		return _append_receipt("send_dsc_call", normalized_priority, "REJECTED", {"reason": "DISTRESS_REQUIRES_GUARDED_TWO_STEP_FLOW"})
	if target.strip_edges().is_empty() or nature.strip_edges().is_empty() or operator_id.strip_edges().is_empty():
		return _append_receipt("send_dsc_call", normalized_priority, "REJECTED", {"reason": "TARGET_NATURE_AND_OPERATOR_REQUIRED"})
	if not bool(_watch.get("70", false)) or bool(_faults["vhf_power_loss"]) or bool(_faults["dsc_controller_loss"]):
		return _append_receipt("send_dsc_call", normalized_priority, "REJECTED", {"reason": "DSC_PATH_UNAVAILABLE"})
	_sequence += 1
	var call_id := "DSC-%s-%06d" % [normalized_priority, _sequence]
	var call := _new_call(call_id, normalized_priority, target.strip_edges(), nature.strip_edges(), operator_id)
	call["status"] = "TRANSMITTED_SIMULATION_ONLY"
	call["transmitted_utc"] = Time.get_datetime_string_from_system(true)
	_calls.append(call)
	_trim_records()
	_rebuild_snapshot()
	return _append_receipt("send_dsc_call", call_id, "TRANSMITTED_SIMULATION_ONLY", {
		"priority": normalized_priority,
		"target": target.strip_edges(),
		"real_radio_transmission": false,
	})


func record_voice_follow_up(call_id: String, channel: String, message: String, operator_id: String) -> Dictionary:
	var index := _find_call(call_id)
	if index < 0:
		return _append_receipt("voice_follow_up", call_id, "REJECTED", {"reason": "UNKNOWN_CALL"})
	var allowed_channels := _gmdss_profile().get("voice_channels", []) as Array
	var normalized_channel := channel.pad_zeros(2)
	if normalized_channel not in allowed_channels:
		return _append_receipt("voice_follow_up", call_id, "REJECTED", {"reason": "UNSUPPORTED_VOICE_CHANNEL"})
	if message.strip_edges().is_empty() or operator_id.strip_edges().is_empty():
		return _append_receipt("voice_follow_up", call_id, "REJECTED", {"reason": "MESSAGE_AND_OPERATOR_REQUIRED"})
	if bool(_faults["vhf_power_loss"]):
		return _append_receipt("voice_follow_up", call_id, "REJECTED", {"reason": "VHF_POWER_LOSS"})
	var call := _calls[index]
	if not String(call.get("status", "")).begins_with("TRANSMITTED"):
		return _append_receipt("voice_follow_up", call_id, "REJECTED", {"reason": "CALL_NOT_TRANSMITTED"})
	var follow_ups := call.get("voice_follow_ups", []) as Array
	follow_ups.append({
		"channel": normalized_channel,
		"message": message.strip_edges(),
		"operator_id": operator_id.strip_edges(),
		"utc": Time.get_datetime_string_from_system(true),
		"real_radio_transmission": false,
	})
	call["voice_follow_ups"] = follow_ups
	_calls[index] = call
	_rebuild_snapshot()
	return _append_receipt("voice_follow_up", call_id, "RECORDED_SIMULATION_ONLY", {"channel": normalized_channel, "real_radio_transmission": false})


func acknowledge_call(call_id: String, station: String, operator_id: String) -> Dictionary:
	var index := _find_call(call_id)
	if index < 0:
		return _append_receipt("acknowledge_call", call_id, "REJECTED", {"reason": "UNKNOWN_CALL"})
	if station.strip_edges().is_empty() or operator_id.strip_edges().is_empty():
		return _append_receipt("acknowledge_call", call_id, "REJECTED", {"reason": "STATION_AND_OPERATOR_REQUIRED"})
	var call := _calls[index]
	call["acknowledged"] = true
	call["acknowledged_by"] = station.strip_edges()
	call["acknowledged_operator_id"] = operator_id.strip_edges()
	call["acknowledged_utc"] = Time.get_datetime_string_from_system(true)
	_calls[index] = call
	_rebuild_snapshot()
	return _append_receipt("acknowledge_call", call_id, "ACKNOWLEDGED_SIMULATION_ONLY", {"station": station.strip_edges()})


func cancel_distress_alert(call_id: String, reason: String, operator_id: String) -> Dictionary:
	var index := _find_call(call_id)
	if index < 0:
		return _append_receipt("cancel_distress", call_id, "REJECTED", {"reason": "UNKNOWN_CALL"})
	var call := _calls[index]
	if String(call.get("priority", "")) != "DISTRESS" or not String(call.get("status", "")).begins_with("TRANSMITTED"):
		return _append_receipt("cancel_distress", call_id, "REJECTED", {"reason": "DISTRESS_NOT_TRANSMITTED"})
	if reason.strip_edges().is_empty() or operator_id.strip_edges().is_empty():
		return _append_receipt("cancel_distress", call_id, "REJECTED", {"reason": "REASON_AND_OPERATOR_REQUIRED"})
	call["status"] = "CANCELLED_SIMULATION_ONLY"
	call["cancellation_reason"] = reason.strip_edges()
	call["cancelled_by"] = operator_id.strip_edges()
	call["cancelled_utc"] = Time.get_datetime_string_from_system(true)
	_calls[index] = call
	_rebuild_snapshot()
	return _append_receipt("cancel_distress", call_id, "CANCELLED_SIMULATION_ONLY", {"reason": reason.strip_edges(), "real_radio_transmission": false})


func set_communication_fault(fault_name: String, enabled: bool) -> Dictionary:
	if not _faults.has(fault_name):
		return _append_receipt("set_communication_fault", fault_name, "REJECTED", {"reason": "UNKNOWN_FAULT"})
	_faults[fault_name] = enabled
	_rebuild_snapshot()
	return _append_receipt("set_communication_fault", fault_name, "ACCEPTED_SIMULATION_ONLY", {"enabled": enabled})


func clear_communication_faults() -> Dictionary:
	for key in _faults:
		_faults[key] = false
	_rebuild_snapshot()
	return _append_receipt("clear_communication_faults", "ALL", "ACCEPTED_SIMULATION_ONLY", {})


func get_communication_snapshot() -> Dictionary:
	return _snapshot.duplicate(true)


func get_receipts() -> Array[Dictionary]:
	return _receipts.duplicate(true)


func verify_receipt_chain() -> Dictionary:
	var previous := "GENESIS"
	var errors: Array[String] = []
	for raw_receipt in _receipts:
		var receipt := raw_receipt as Dictionary
		if String(receipt.get("previous_receipt_hash", "")) != previous:
			errors.append("PREVIOUS_HASH_MISMATCH:%s" % String(receipt.get("receipt_id", "")))
		var core := receipt.duplicate(true)
		var recorded_hash := String(core.get("receipt_hash", ""))
		core.erase("receipt_hash")
		if _sha256_text(JSON.stringify(core)) != recorded_hash:
			errors.append("RECEIPT_HASH_MISMATCH:%s" % String(receipt.get("receipt_id", "")))
		previous = recorded_hash
	return {"passed": errors.is_empty(), "receipt_count": _receipts.size(), "last_receipt_hash": previous, "errors": errors}


func _new_call(call_id: String, priority: String, target: String, nature: String, operator_id: String) -> Dictionary:
	return {
		"call_id": call_id,
		"priority": priority,
		"target": target,
		"nature": nature,
		"operator_id": operator_id.strip_edges(),
		"training_identity": _gmdss_profile().get("training_identity", "TRAINING"),
		"position": _ownship_position(),
		"position_source_valid": not bool(_faults["gnss_input_loss"]),
		"created_utc": Time.get_datetime_string_from_system(true),
		"status": "DRAFT",
		"acknowledged": false,
		"voice_follow_ups": [],
		"real_radio_transmission": false,
		"coast_station_connected": false,
	}


func _ownship_position() -> Dictionary:
	_resolve_equipment_suite()
	if bool(_faults["gnss_input_loss"]) or _equipment_suite == null or not _equipment_suite.has_method("get_bridge_snapshot"):
		return {"available": false, "source": "SIMULATOR_GNSS_UNAVAILABLE"}
	var bridge := _equipment_suite.call("get_bridge_snapshot") as Dictionary
	var ownship := bridge.get("ownship", {}) as Dictionary
	var position := ownship.get("position", Vector3.ZERO) as Vector3
	return {
		"available": bool(ownship.get("available", false)),
		"x_meters": position.x,
		"z_meters": position.z,
		"source": "SIMULATOR_BRIDGE_POSITION",
		"official_navigation_position": false,
	}


func _rebuild_snapshot() -> void:
	var pending_distress := _calls.filter(func(call: Dictionary) -> bool: return String(call.get("priority", "")) == "DISTRESS" and String(call.get("status", "")) == "PREPARED_GUARDED")
	_snapshot = {
		"schema_version": SNAPSHOT_SCHEMA,
		"profile_id": _profile.get("profile_id", ""),
		"sea_area": _gmdss_profile().get("sea_area", "A1_SIMULATED"),
		"training_identity": _gmdss_profile().get("training_identity", "TRAINING"),
		"channel_watch": _watch.duplicate(true),
		"priorities": PRIORITIES.duplicate(),
		"calls": _calls.duplicate(true),
		"pending_distress_count": pending_distress.size(),
		"faults": _faults.duplicate(true),
		"receipt_chain": verify_receipt_chain(),
		"real_radio_transmission_enabled": false,
		"coast_station_connected": false,
		"type_approved": false,
		"production_authority": false,
		"boundary": "GMDSS/VHF/DSC procedure trainer only; no RF transmission, coast station, type approval or live-vessel authority",
	}
	communication_snapshot_updated.emit(get_communication_snapshot())


func _append_receipt(action: String, subject: String, status: String, detail: Dictionary) -> Dictionary:
	_receipt_sequence += 1
	var receipt := {
		"schema_version": RECEIPT_SCHEMA,
		"receipt_id": "GMDSS-%06d" % _receipt_sequence,
		"sequence": _receipt_sequence,
		"utc": Time.get_datetime_string_from_system(true),
		"action": action,
		"subject": subject,
		"status": status,
		"detail": detail.duplicate(true),
		"previous_receipt_hash": _previous_receipt_hash,
		"real_radio_transmission": false,
		"production_authority": false,
	}
	receipt["receipt_hash"] = _sha256_text(JSON.stringify(receipt))
	_previous_receipt_hash = String(receipt["receipt_hash"])
	_receipts.append(receipt)
	_trim_records()
	_rebuild_snapshot()
	communication_receipt_emitted.emit(receipt.duplicate(true))
	return receipt.duplicate(true)


func _find_call(call_id: String) -> int:
	for index in range(_calls.size()):
		if String(_calls[index].get("call_id", "")) == call_id:
			return index
	return -1


func _trim_records() -> void:
	while _calls.size() > MAX_RECORDS:
		_calls.pop_front()
	while _receipts.size() > MAX_RECORDS:
		_receipts.pop_front()


func _resolve_equipment_suite() -> void:
	if _equipment_suite == null or not is_instance_valid(_equipment_suite):
		_equipment_suite = get_node_or_null(equipment_suite_path)
		if _equipment_suite == null and get_tree() != null:
			_equipment_suite = get_tree().get_first_node_in_group(&"ship_navigation_equipment_suite")


func _gmdss_profile() -> Dictionary:
	return _profile.get("gmdss_training", {}) as Dictionary


func _read_json(path: String) -> Dictionary:
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

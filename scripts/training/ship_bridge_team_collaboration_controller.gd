extends Node
class_name ShipBridgeTeamCollaborationController

## Multi-station bridge-team collaboration and loopback UDP transport.
##
## Messages, role authority and readbacks are auditable. No message is mapped
## to helm, engine or policy actuation. UDP is loopback-only unless a caller
## explicitly authorizes a non-loopback research network.

signal collaboration_receipt_emitted(receipt: Dictionary)
signal collaboration_state_changed(snapshot: Dictionary)

const SCHEMA_VERSION := "ship_bridge_team_collaboration_v1"
const UDP_PROTOCOL := "ship_bridge_team_udp_v1"
const MAX_RECORDS := 1024
const ROLES := ["MASTER", "OOW", "HELM", "RADAR", "ECDIS", "ENGINE", "MOORING_FORE", "MOORING_AFT", "INSTRUCTOR"]
const MESSAGE_CATEGORIES := ["COMMAND", "REPORT", "CHALLENGE", "RESPONSE", "ALERT"]
const COMMAND_ROLES := ["MASTER", "OOW", "INSTRUCTOR"]

var _session_id := ""
var _session_name := ""
var _session_token := ""
var _stations: Dictionary = {}
var _messages: Array[Dictionary] = []
var _briefs: Array[Dictionary] = []
var _receipts: Array[Dictionary] = []
var _sequence := 0
var _receipt_sequence := 0

var _udp_server := UDPServer.new()
var _udp_peers: Array[PacketPeerUDP] = []
var _udp_listening := false
var _udp_bind_address := ""
var _udp_port := 0
var _udp_received_packets := 0
var _udp_rejected_packets := 0
var _udp_last_error := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"ship_bridge_team_collaboration_controller")
	set_process(true)


func _exit_tree() -> void:
	stop_udp_transport()


func _process(_delta: float) -> void:
	_poll_udp()


func create_session(session_name: String) -> Dictionary:
	var clean_name := session_name.strip_edges()
	if clean_name.is_empty():
		return _append_receipt("create_session", "", "REJECTED", {"reason": "SESSION_NAME_REQUIRED"})
	stop_udp_transport()
	_sequence = 0
	_stations.clear()
	_messages.clear()
	_briefs.clear()
	_session_name = clean_name
	_session_id = "BRIDGE-%s-%06d" % [Time.get_date_string_from_system().replace("-", ""), Time.get_ticks_msec() % 1000000]
	_session_token = _sha256_text("%s|%s|%s" % [_session_id, Time.get_unix_time_from_system(), clean_name])
	var receipt := _append_receipt("create_session", _session_id, "ACCEPTED", {"session_name": _session_name})
	_emit_state()
	return receipt


func join_station(role: String, operator_id: String, display_name: String = "") -> Dictionary:
	if _session_id.is_empty():
		return _append_receipt("join_station", role, "REJECTED", {"reason": "NO_ACTIVE_SESSION"})
	var normalized_role := role.to_upper()
	if normalized_role not in ROLES:
		return _append_receipt("join_station", normalized_role, "REJECTED", {"reason": "UNKNOWN_ROLE"})
	var clean_operator := operator_id.strip_edges()
	if clean_operator.is_empty():
		return _append_receipt("join_station", normalized_role, "REJECTED", {"reason": "OPERATOR_ID_REQUIRED"})
	for raw in _stations.values():
		var station := raw as Dictionary
		if String(station.get("role", "")) == normalized_role and bool(station.get("active", false)):
			return _append_receipt("join_station", normalized_role, "REJECTED", {"reason": "ROLE_ALREADY_OCCUPIED", "station_id": station.get("station_id", "")})
	var station_id := "%s-%02d" % [normalized_role, _stations.size() + 1]
	_stations[station_id] = {
		"station_id": station_id,
		"role": normalized_role,
		"operator_id": clean_operator,
		"display_name": display_name.strip_edges() if not display_name.strip_edges().is_empty() else clean_operator,
		"active": true,
		"joined_utc": Time.get_datetime_string_from_system(true),
		"last_heartbeat_ticks_msec": Time.get_ticks_msec(),
		"messages_sent": 0,
		"readbacks_completed": 0,
	}
	var receipt := _append_receipt("join_station", station_id, "ACCEPTED", {"role": normalized_role, "operator_id": clean_operator})
	_emit_state()
	return receipt


func heartbeat(station_id: String, source: String = "local") -> Dictionary:
	if not _stations.has(station_id):
		return _append_receipt("heartbeat", station_id, "REJECTED", {"reason": "UNKNOWN_STATION", "source": source})
	var station := _stations[station_id] as Dictionary
	station["last_heartbeat_ticks_msec"] = Time.get_ticks_msec()
	station["active"] = true
	_stations[station_id] = station
	return _append_receipt("heartbeat", station_id, "EXECUTED", {"source": source})


func send_bridge_message(
	sender_station_id: String,
	target_role: String,
	category: String,
	content: String,
	requires_readback: bool = true,
	source: String = "local"
) -> Dictionary:
	if not _stations.has(sender_station_id):
		return _append_receipt("send_message", sender_station_id, "REJECTED", {"reason": "UNKNOWN_SENDER"})
	var normalized_target := target_role.to_upper()
	if normalized_target != "ALL" and normalized_target not in ROLES:
		return _append_receipt("send_message", normalized_target, "REJECTED", {"reason": "UNKNOWN_TARGET_ROLE"})
	var normalized_category := category.to_upper()
	if normalized_category not in MESSAGE_CATEGORIES:
		return _append_receipt("send_message", normalized_category, "REJECTED", {"reason": "UNKNOWN_CATEGORY"})
	var clean_content := content.strip_edges()
	if clean_content.is_empty():
		return _append_receipt("send_message", normalized_category, "REJECTED", {"reason": "MESSAGE_CONTENT_REQUIRED"})
	var sender := _stations[sender_station_id] as Dictionary
	if normalized_category == "COMMAND" and String(sender.get("role", "")) not in COMMAND_ROLES:
		return _append_receipt("send_message", sender_station_id, "REJECTED", {"reason": "COMMAND_AUTHORITY_REQUIRED", "role": sender.get("role", "")})
	_sequence += 1
	var message_id := "MSG-%06d" % _sequence
	var message := {
		"message_id": message_id,
		"sequence": _sequence,
		"session_id": _session_id,
		"sent_utc": Time.get_datetime_string_from_system(true),
		"sender_station_id": sender_station_id,
		"sender_role": sender.get("role", ""),
		"target_role": normalized_target,
		"category": normalized_category,
		"content": clean_content,
		"requires_readback": requires_readback,
		"status": "OPEN" if requires_readback else "INFORMATION",
		"acknowledgements": [],
		"source": source,
		"mapped_to_actuation": false,
	}
	_messages.append(message)
	while _messages.size() > MAX_RECORDS:
		_messages.remove_at(0)
	sender["messages_sent"] = int(sender.get("messages_sent", 0)) + 1
	_stations[sender_station_id] = sender
	var receipt := _append_receipt("send_message", message_id, "EXECUTED", {"target_role": normalized_target, "category": normalized_category, "requires_readback": requires_readback})
	_emit_state()
	return receipt


func acknowledge_message(message_id: String, station_id: String, readback_text: String) -> Dictionary:
	if not _stations.has(station_id):
		return _append_receipt("acknowledge_message", message_id, "REJECTED", {"reason": "UNKNOWN_STATION"})
	var index := _find_message_index(message_id)
	if index < 0:
		return _append_receipt("acknowledge_message", message_id, "REJECTED", {"reason": "UNKNOWN_MESSAGE"})
	var message := _messages[index]
	var station := _stations[station_id] as Dictionary
	var target_role := String(message.get("target_role", ""))
	if target_role != "ALL" and String(station.get("role", "")) != target_role:
		return _append_receipt("acknowledge_message", message_id, "REJECTED", {"reason": "WRONG_RECIPIENT_ROLE", "expected": target_role, "actual": station.get("role", "")})
	var clean_readback := readback_text.strip_edges()
	if bool(message.get("requires_readback", false)) and clean_readback.is_empty():
		return _append_receipt("acknowledge_message", message_id, "REJECTED", {"reason": "READBACK_TEXT_REQUIRED"})
	var acknowledgements := message.get("acknowledgements", []) as Array
	for raw in acknowledgements:
		if String((raw as Dictionary).get("station_id", "")) == station_id:
			return _append_receipt("acknowledge_message", message_id, "REJECTED", {"reason": "DUPLICATE_ACKNOWLEDGEMENT"})
	acknowledgements.append({
		"station_id": station_id,
		"role": station.get("role", ""),
		"readback": clean_readback,
		"utc": Time.get_datetime_string_from_system(true),
	})
	message["acknowledgements"] = acknowledgements
	message["status"] = "CLOSED_LOOP"
	_messages[index] = message
	station["readbacks_completed"] = int(station.get("readbacks_completed", 0)) + 1
	_stations[station_id] = station
	var receipt := _append_receipt("acknowledge_message", message_id, "EXECUTED", {"station_id": station_id, "status": "CLOSED_LOOP"})
	_emit_state()
	return receipt


func record_situation_brief(station_id: String, hazard: String, plan: String, contingency: String) -> Dictionary:
	if not _stations.has(station_id):
		return _append_receipt("situation_brief", station_id, "REJECTED", {"reason": "UNKNOWN_STATION"})
	if hazard.strip_edges().is_empty() or plan.strip_edges().is_empty() or contingency.strip_edges().is_empty():
		return _append_receipt("situation_brief", station_id, "REJECTED", {"reason": "HAZARD_PLAN_CONTINGENCY_REQUIRED"})
	var station := _stations[station_id] as Dictionary
	var brief := {
		"brief_id": "BRIEF-%04d" % (_briefs.size() + 1),
		"station_id": station_id,
		"role": station.get("role", ""),
		"hazard": hazard.strip_edges(),
		"plan": plan.strip_edges(),
		"contingency": contingency.strip_edges(),
		"utc": Time.get_datetime_string_from_system(true),
	}
	_briefs.append(brief)
	var receipt := _append_receipt("situation_brief", String(brief.get("brief_id", "")), "EXECUTED", brief)
	_emit_state()
	return receipt


func run_brm_team_check() -> Dictionary:
	var roles_present: Array[String] = []
	for raw in _stations.values():
		var station := raw as Dictionary
		if bool(station.get("active", false)):
			roles_present.append(String(station.get("role", "")))
	var gaps: Array[String] = []
	for required in ["MASTER", "OOW", "HELM"]:
		if required not in roles_present:
			gaps.append("MISSING_ROLE_%s" % required)
	var open_messages := _open_loop_messages()
	if not open_messages.is_empty():
		gaps.append("OPEN_READBACK_%d" % open_messages.size())
	if _briefs.is_empty():
		gaps.append("SITUATION_BRIEF_MISSING")
	return {
		"passed": gaps.is_empty(),
		"roles_present": roles_present,
		"open_loop_messages": open_messages,
		"brief_count": _briefs.size(),
		"gaps": gaps,
		"production_authority": false,
	}


func enable_udp_transport(port: int = 0, bind_address: String = "127.0.0.1", authorize_non_loopback: bool = false) -> Dictionary:
	if _session_id.is_empty():
		return _append_receipt("udp_enable", "", "REJECTED", {"reason": "NO_ACTIVE_SESSION"})
	var is_loopback := bind_address in ["127.0.0.1", "::1", "localhost"]
	if not is_loopback and not authorize_non_loopback:
		return _append_receipt("udp_enable", bind_address, "REJECTED", {"reason": "NON_LOOPBACK_REQUIRES_EXPLICIT_AUTHORIZATION"})
	stop_udp_transport()
	var error := _udp_server.listen(clampi(port, 0, 65535), bind_address)
	if error != OK:
		_udp_last_error = error_string(error)
		return _append_receipt("udp_enable", bind_address, "REJECTED", {"reason": "UDP_LISTEN_FAILED", "error": _udp_last_error})
	_udp_listening = true
	_udp_bind_address = bind_address
	_udp_port = _udp_server.get_local_port()
	_udp_last_error = ""
	var receipt := _append_receipt("udp_enable", "%s:%d" % [_udp_bind_address, _udp_port], "EXECUTED", {"loopback_only": is_loopback, "encrypted": false, "authenticated_session_token": true})
	_emit_state()
	return receipt


func send_udp_loopback_probe(station_id: String) -> Dictionary:
	if not _udp_listening:
		return _append_receipt("udp_probe", station_id, "REJECTED", {"reason": "UDP_NOT_LISTENING"})
	if not _stations.has(station_id):
		return _append_receipt("udp_probe", station_id, "REJECTED", {"reason": "UNKNOWN_STATION"})
	var envelope := {
		"protocol": UDP_PROTOCOL,
		"session_id": _session_id,
		"session_token": _session_token,
		"kind": "heartbeat",
		"station_id": station_id,
		"nonce": "N-%d" % Time.get_ticks_usec(),
	}
	var peer := PacketPeerUDP.new()
	var destination_error := peer.set_dest_address("127.0.0.1", _udp_port)
	if destination_error != OK:
		return _append_receipt("udp_probe", station_id, "REJECTED", {"reason": "DESTINATION_FAILED", "error": error_string(destination_error)})
	var send_error := peer.put_packet(JSON.stringify(envelope).to_utf8_buffer())
	if send_error != OK:
		return _append_receipt("udp_probe", station_id, "REJECTED", {"reason": "SEND_FAILED", "error": error_string(send_error)})
	return _append_receipt("udp_probe", station_id, "EXECUTED", {"destination": "127.0.0.1:%d" % _udp_port})


func stop_udp_transport() -> Dictionary:
	if _udp_server != null and _udp_server.is_listening():
		_udp_server.stop()
	_udp_peers.clear()
	var was_listening := _udp_listening
	_udp_listening = false
	_udp_bind_address = ""
	_udp_port = 0
	if was_listening:
		var receipt := _append_receipt("udp_stop", "", "EXECUTED", {})
		_emit_state()
		return receipt
	return {"receipt_id": "", "status": "NOOP"}


func get_collaboration_snapshot() -> Dictionary:
	return {
		"format": SCHEMA_VERSION,
		"session_id": _session_id,
		"session_name": _session_name,
		"stations": _stations.values().duplicate(true),
		"messages": _messages.duplicate(true),
		"situation_briefs": _briefs.duplicate(true),
		"receipts": _receipts.duplicate(true),
		"brm_check": run_brm_team_check(),
		"udp": get_udp_status(),
		"production_authority": false,
		"remote_control_authority": false,
		"messages_mapped_to_actuation": false,
		"boundary": "Research bridge-team communications and loopback UDP transport; not GMDSS/VHF, secure operational networking, or remote vessel control.",
	}


func get_udp_status() -> Dictionary:
	return {
		"listening": _udp_listening,
		"bind_address": _udp_bind_address,
		"port": _udp_port,
		"protocol": UDP_PROTOCOL,
		"received_packets": _udp_received_packets,
		"rejected_packets": _udp_rejected_packets,
		"last_error": _udp_last_error,
		"encrypted": false,
		"production_authority": false,
	}


func _poll_udp() -> void:
	if not _udp_listening:
		return
	var poll_error := _udp_server.poll()
	if poll_error != OK:
		_udp_last_error = error_string(poll_error)
		return
	while _udp_server.is_connection_available():
		var peer := _udp_server.take_connection()
		if peer != null:
			_udp_peers.append(peer)
	for peer in _udp_peers:
		while peer.get_available_packet_count() > 0:
			_handle_udp_packet(peer.get_packet())


func _handle_udp_packet(packet: PackedByteArray) -> void:
	var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
	if not parsed is Dictionary:
		_udp_rejected_packets += 1
		_append_receipt("udp_receive", "", "REJECTED", {"reason": "INVALID_JSON"})
		return
	var envelope := parsed as Dictionary
	if String(envelope.get("protocol", "")) != UDP_PROTOCOL:
		_udp_rejected_packets += 1
		_append_receipt("udp_receive", "", "REJECTED", {"reason": "PROTOCOL_MISMATCH"})
		return
	if String(envelope.get("session_id", "")) != _session_id or String(envelope.get("session_token", "")) != _session_token:
		_udp_rejected_packets += 1
		_append_receipt("udp_receive", "", "REJECTED", {"reason": "SESSION_AUTHENTICATION_FAILED"})
		return
	_udp_received_packets += 1
	var kind := String(envelope.get("kind", ""))
	if kind == "heartbeat":
		heartbeat(String(envelope.get("station_id", "")), "udp_loopback")
		_append_receipt("udp_receive", String(envelope.get("nonce", "")), "EXECUTED", {"kind": kind})
	else:
		_udp_rejected_packets += 1
		_append_receipt("udp_receive", kind, "REJECTED", {"reason": "UNSUPPORTED_PACKET_KIND"})
	_emit_state()


func _find_message_index(message_id: String) -> int:
	for index in range(_messages.size()):
		if String(_messages[index].get("message_id", "")) == message_id:
			return index
	return -1


func _open_loop_messages() -> Array[Dictionary]:
	var open: Array[Dictionary] = []
	for raw in _messages:
		var message := raw as Dictionary
		if bool(message.get("requires_readback", false)) and String(message.get("status", "")) != "CLOSED_LOOP":
			open.append(message.duplicate(true))
	return open


func _append_receipt(action: String, subject: String, status: String, detail: Dictionary) -> Dictionary:
	_receipt_sequence += 1
	var receipt := {
		"receipt_id": "BRM-%06d" % _receipt_sequence,
		"sequence": _receipt_sequence,
		"utc": Time.get_datetime_string_from_system(true),
		"session_id": _session_id,
		"action": action,
		"subject": subject,
		"status": status,
		"detail": detail.duplicate(true),
	}
	_receipts.append(receipt)
	while _receipts.size() > MAX_RECORDS:
		_receipts.remove_at(0)
	collaboration_receipt_emitted.emit(receipt.duplicate(true))
	return receipt


func _emit_state() -> void:
	collaboration_state_changed.emit(get_collaboration_snapshot())


func _sha256_text(value: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(value.to_utf8_buffer())
	return context.finish().hex_encode()

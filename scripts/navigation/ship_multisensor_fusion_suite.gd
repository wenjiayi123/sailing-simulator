extends Node
class_name ShipMultisensorFusionSuite

## Multi-source perception and fusion facade for the research simulator.
##
## Every channel carries time, provenance, quality and hardware-verification
## metadata.  Scene truth is used only inside declared simulation adapters.
## External packets are fail-closed until a site enables and evidences the
## connector.  The node observes the vessel; it never changes dynamics,
## policies, or actuator commands.

signal fusion_snapshot_updated(snapshot: Dictionary)
signal sensor_receipt_emitted(receipt: Dictionary)

const PROFILE_PATH := "res://data/verification/multisensor_fusion_profile_v1.json"
const PACKET_SCHEMA := "ship_sensor_packet_v1"
const SNAPSHOT_SCHEMA := "ship_multisensor_fusion_snapshot_v1"
const SENSOR_ORDER := ["RADAR", "AIS", "EO", "IR", "GNSS", "INS"]
const MAX_RECEIPTS := 512

@export var equipment_suite_path: NodePath = NodePath("../ShipNavigationEquipmentSuite")

var _equipment_suite: Node
var _profile: Dictionary = {}
var _elapsed_seconds := 0.0
var _sample_timer := 0.0
var _sequence := 0
var _receipt_sequence := 0
var _pending_packets: Array[Dictionary] = []
var _latest_packets: Dictionary = {}
var _receipts: Array[Dictionary] = []
var _snapshot: Dictionary = {}
var _last_ins_position := Vector2.ZERO
var _last_truth_position := Vector2.ZERO
var _faults := {
	"radar_dropout": false,
	"radar_false_alarm_count": 0,
	"ais_dropout": false,
	"ais_latency_ms": 0.0,
	"ais_spoof_identity": false,
	"eo_dropout": false,
	"eo_occlusion_ratio": 0.0,
	"ir_dropout": false,
	"ir_false_alarm_count": 0,
	"gnss_dropout": false,
	"gnss_latency_ms": 0.0,
	"gnss_spoof_offset_m": Vector2.ZERO,
	"ins_dropout": false,
	"ins_heading_bias_deg": 0.0,
	"time_sync_loss": false,
}


func _ready() -> void:
	add_to_group(&"ship_multisensor_fusion_suite")
	_profile = _read_json(PROFILE_PATH)
	_equipment_suite = get_node_or_null(equipment_suite_path)
	_sample_timer = 0.0
	advance_simulation_time_for_test(0.0)
	set_process(true)


func _process(delta: float) -> void:
	_elapsed_seconds += maxf(delta, 0.0)
	_sample_timer -= maxf(delta, 0.0)
	if _sample_timer <= 0.0:
		_sample_timer = float(_profile.get("sample_interval_seconds", 0.25))
		_sample_all_channels()
	_release_due_packets()
	_rebuild_snapshot()


func advance_simulation_time_for_test(delta: float) -> Dictionary:
	## Deterministic helper used by headless acceptance; it does not alter the
	## vessel clock, physics, policy, or actuator state.
	_elapsed_seconds += maxf(delta, 0.0)
	_sample_all_channels()
	_release_due_packets()
	_rebuild_snapshot()
	return get_fusion_snapshot()


func force_refresh() -> Dictionary:
	_sample_all_channels()
	_release_due_packets()
	_rebuild_snapshot()
	return get_fusion_snapshot()


func get_fusion_snapshot() -> Dictionary:
	return _snapshot.duplicate(true)


func get_latest_sensor_packets() -> Dictionary:
	return _latest_packets.duplicate(true)


func get_fault_state() -> Dictionary:
	return _faults.duplicate(true)


func get_receipts() -> Array[Dictionary]:
	return _receipts.duplicate(true)


func set_sensor_fault(fault_name: String, value: Variant) -> Dictionary:
	if not _faults.has(fault_name):
		return _append_receipt("set_sensor_fault", fault_name, "REJECTED", {"reason": "UNKNOWN_FAULT"})
	_faults[fault_name] = value
	var receipt := _append_receipt("set_sensor_fault", fault_name, "ACCEPTED", {"value": value})
	_sample_all_channels()
	_release_due_packets()
	_rebuild_snapshot()
	return receipt


func clear_sensor_faults() -> Dictionary:
	_faults = {
		"radar_dropout": false,
		"radar_false_alarm_count": 0,
		"ais_dropout": false,
		"ais_latency_ms": 0.0,
		"ais_spoof_identity": false,
		"eo_dropout": false,
		"eo_occlusion_ratio": 0.0,
		"ir_dropout": false,
		"ir_false_alarm_count": 0,
		"gnss_dropout": false,
		"gnss_latency_ms": 0.0,
		"gnss_spoof_offset_m": Vector2.ZERO,
		"ins_dropout": false,
		"ins_heading_bias_deg": 0.0,
		"time_sync_loss": false,
	}
	_pending_packets.clear()
	var receipt := _append_receipt("clear_sensor_faults", "ALL", "ACCEPTED", {})
	advance_simulation_time_for_test(1.0)
	return receipt


func ingest_external_packet(packet: Dictionary) -> Dictionary:
	var external := _profile.get("external_ingest", {}) as Dictionary
	if not bool(external.get("enabled", false)):
		return _append_receipt("ingest_external_packet", String(packet.get("sensor_id", "UNKNOWN")), "REJECTED", {"reason": "EXTERNAL_INGEST_DISABLED"})
	for required in ["schema_version", "sensor_id", "measurement_time_seconds", "source_identity", "calibration_reference", "observations"]:
		if not packet.has(required):
			return _append_receipt("ingest_external_packet", String(packet.get("sensor_id", "UNKNOWN")), "REJECTED", {"reason": "MISSING_FIELD", "field": required})
	if String(packet.get("schema_version", "")) != PACKET_SCHEMA:
		return _append_receipt("ingest_external_packet", String(packet.get("sensor_id", "UNKNOWN")), "REJECTED", {"reason": "SCHEMA_MISMATCH"})
	var sensor_id := String(packet.get("sensor_id", ""))
	var accepted := packet.duplicate(true)
	accepted["receive_time_seconds"] = _elapsed_seconds
	accepted["hardware_verified"] = false
	accepted["field_verification_pending"] = true
	_latest_packets[sensor_id] = accepted
	_rebuild_snapshot()
	return _append_receipt("ingest_external_packet", sensor_id, "ACCEPTED_FOR_RESEARCH_REVIEW", {"hardware_verified": false})


func _sample_all_channels() -> void:
	if _equipment_suite == null or not is_instance_valid(_equipment_suite):
		_equipment_suite = get_node_or_null(equipment_suite_path)
	if _equipment_suite == null or not _equipment_suite.has_method("get_simulator_sensor_truth_frame"):
		return
	var truth := _equipment_suite.call("get_simulator_sensor_truth_frame") as Dictionary
	if not bool(truth.get("available", false)):
		return
	_queue_packet(_radar_packet(truth))
	_queue_packet(_ais_packet(truth))
	_queue_packet(_eo_packet(truth))
	_queue_packet(_ir_packet(truth))
	_queue_packet(_gnss_packet(truth))
	_queue_packet(_ins_packet(truth))


func _queue_packet(packet: Dictionary) -> void:
	_sequence += 1
	packet["sequence"] = _sequence
	var latency_ms := float(packet.get("latency_ms", 0.0))
	packet["receive_time_seconds"] = _elapsed_seconds + latency_ms / 1000.0
	_pending_packets.append(packet)


func _release_due_packets() -> void:
	var remaining: Array[Dictionary] = []
	for packet in _pending_packets:
		if float(packet.get("receive_time_seconds", INF)) <= _elapsed_seconds:
			var sensor_id := String(packet.get("sensor_id", "UNKNOWN"))
			_latest_packets[sensor_id] = packet
			_append_receipt("sensor_packet_received", sensor_id, "ACCEPTED", {
				"sequence": packet.get("sequence"),
				"latency_ms": packet.get("latency_ms"),
				"valid": packet.get("valid"),
				"integrity": packet.get("integrity"),
			})
		else:
			remaining.append(packet)
	_pending_packets = remaining


func _base_packet(sensor_id: String, valid: bool, quality: float, observations: Array) -> Dictionary:
	var channel := (_profile.get("sensor_channels", {}) as Dictionary).get(sensor_id, {}) as Dictionary
	var timestamp := _elapsed_seconds
	if bool(_faults["time_sync_loss"]):
		timestamp -= 2.5
	return {
		"schema_version": PACKET_SCHEMA,
		"sensor_id": sensor_id,
		"modality": sensor_id,
		"frame_id": "ship_local_x_east_z_north",
		"measurement_time_seconds": timestamp,
		"latency_ms": float(channel.get("nominal_latency_ms", 0.0)),
		"valid": valid,
		"quality": clampf(quality, 0.0, 1.0),
		"integrity": "VALID" if valid else "UNAVAILABLE",
		"observations": observations,
		"source_mode": channel.get("source_mode", "SIMULATOR_GENERATED"),
		"source_identity": "godot_research_sensor_adapter::" + sensor_id.to_lower(),
		"calibration_reference": "SIM_PROFILE_ONLY_NOT_FIELD_CALIBRATION",
		"hardware_verified": false,
		"live_data_verified": false,
		"production_authority": false,
	}


func _radar_packet(truth: Dictionary) -> Dictionary:
	var dropped := bool(_faults["radar_dropout"])
	var observations: Array = []
	if not dropped:
		var bridge := _equipment_suite.call("get_bridge_snapshot") as Dictionary
		for raw_contact in (bridge.get("radar", {}) as Dictionary).get("contacts", []) as Array:
			var contact := raw_contact as Dictionary
			observations.append({
				"observation_id": "RADAR::" + String(contact.get("id", observations.size())),
				"position_xz": contact.get("measured_position_xz", Vector2.ZERO),
				"velocity_xz_mps": contact.get("velocity_xz_mps", Vector2.ZERO),
				"range_meters": contact.get("range_meters"),
				"bearing_degrees": contact.get("bearing_degrees"),
				"confidence": clampf(float(contact.get("signal_strength", 0.5)), 0.05, 1.0),
				"identity": null,
			})
		for index in range(maxi(0, int(_faults["radar_false_alarm_count"]))):
			observations.append(_false_alarm("RADAR", index, 420.0 + index * 55.0))
	var packet := _base_packet("RADAR", not dropped, 0.0 if dropped else 0.82, observations)
	packet["faults_applied"] = {"dropout": dropped, "false_alarm_count": int(_faults["radar_false_alarm_count"])}
	return packet


func _ais_packet(truth: Dictionary) -> Dictionary:
	var dropped := bool(_faults["ais_dropout"])
	var observations: Array = []
	if not dropped:
		for raw_contact in truth.get("contacts", []) as Array:
			var contact := raw_contact as Dictionary
			if String(contact.get("kind", "")) not in ["VESSEL", "AIS_HISTORY"]:
				continue
			var identity := String(contact.get("label", contact.get("id", "UNKNOWN")))
			if bool(_faults["ais_spoof_identity"]) and observations.is_empty():
				identity = "SPOOFED_IDENTITY"
			observations.append({
				"observation_id": "AIS::" + String(contact.get("id", observations.size())),
				"position_xz": _xz(contact.get("position", Vector3.ZERO) as Vector3),
				"velocity_xz_mps": contact.get("velocity_xz_mps", Vector2.ZERO),
				"confidence": 0.88,
				"identity": identity,
				"identity_integrity": "SUSPECTED_SPOOF" if identity == "SPOOFED_IDENTITY" else "UNVERIFIED_REPLAY",
			})
	var packet := _base_packet("AIS", not dropped, 0.0 if dropped else 0.76, observations)
	packet["latency_ms"] = float(packet["latency_ms"]) + maxf(0.0, float(_faults["ais_latency_ms"]))
	packet["integrity"] = "SPOOF_SUSPECTED" if bool(_faults["ais_spoof_identity"]) else packet["integrity"]
	packet["faults_applied"] = {"dropout": dropped, "extra_latency_ms": float(_faults["ais_latency_ms"]), "identity_spoof": bool(_faults["ais_spoof_identity"])}
	return packet


func _eo_packet(truth: Dictionary) -> Dictionary:
	var dropped := bool(_faults["eo_dropout"])
	var occlusion := clampf(float(_faults["eo_occlusion_ratio"]), 0.0, 1.0)
	var observations: Array = []
	if not dropped:
		observations = _optical_observations(truth, "EO", 1800.0, 0.86, occlusion)
	var packet := _base_packet("EO", not dropped, 0.0 if dropped else 0.84 * (1.0 - occlusion * 0.7), observations)
	packet["faults_applied"] = {"dropout": dropped, "occlusion_ratio": occlusion}
	return packet


func _ir_packet(truth: Dictionary) -> Dictionary:
	var dropped := bool(_faults["ir_dropout"])
	var observations: Array = []
	if not dropped:
		observations = _optical_observations(truth, "IR", 2400.0, 0.78, 0.0)
		for index in range(maxi(0, int(_faults["ir_false_alarm_count"]))):
			observations.append(_false_alarm("IR", index, 300.0 + index * 70.0))
	var packet := _base_packet("IR", not dropped, 0.0 if dropped else 0.79, observations)
	packet["faults_applied"] = {"dropout": dropped, "false_alarm_count": int(_faults["ir_false_alarm_count"])}
	return packet


func _optical_observations(truth: Dictionary, modality: String, maximum_range: float, base_confidence: float, occlusion: float) -> Array:
	var observations: Array = []
	var own_position := _xz(((truth.get("ownship", {}) as Dictionary).get("position", Vector3.ZERO)) as Vector3)
	for raw_contact in truth.get("contacts", []) as Array:
		var contact := raw_contact as Dictionary
		var position := _xz(contact.get("position", Vector3.ZERO) as Vector3)
		var distance := own_position.distance_to(position)
		if distance > maximum_range:
			continue
		var phase := float(abs(hash(modality + String(contact.get("id", "")))) % 1000) / 1000.0
		if phase < occlusion:
			continue
		var confidence := base_confidence * (1.0 - 0.45 * distance / maximum_range)
		observations.append({
			"observation_id": modality + "::" + String(contact.get("id", observations.size())),
			"position_xz": position + Vector2(sin(phase * 6.28), cos(phase * 6.28)) * (2.0 if modality == "EO" else 3.5),
			"velocity_xz_mps": contact.get("velocity_xz_mps", Vector2.ZERO),
			"confidence": clampf(confidence, 0.05, 1.0),
			"classification": contact.get("kind", "UNKNOWN"),
			"identity": null,
		})
	return observations


func _gnss_packet(truth: Dictionary) -> Dictionary:
	var dropped := bool(_faults["gnss_dropout"])
	var observations: Array = []
	var offset := _faults["gnss_spoof_offset_m"] as Vector2
	if not dropped:
		var ownship := truth.get("ownship", {}) as Dictionary
		var true_position := _xz(ownship.get("position", Vector3.ZERO) as Vector3)
		var phase := float(_sequence % 100) * 0.31
		var noise := Vector2(sin(phase), cos(phase)) * 1.8
		observations.append({
			"observation_id": "GNSS::OWNSHIP",
			"position_xz": true_position + noise + offset,
			"position_uncertainty_meters": 2.5 if offset.length() < 0.01 else 250.0,
			"confidence": 0.97 if offset.length() < 0.01 else 0.18,
		})
	var packet := _base_packet("GNSS", not dropped, 0.0 if dropped else (0.2 if offset.length() > 0.01 else 0.96), observations)
	packet["latency_ms"] = float(packet["latency_ms"]) + maxf(0.0, float(_faults["gnss_latency_ms"]))
	packet["integrity"] = "SPOOF_SUSPECTED" if offset.length() > 0.01 else packet["integrity"]
	packet["faults_applied"] = {"dropout": dropped, "extra_latency_ms": float(_faults["gnss_latency_ms"]), "spoof_offset_m": offset}
	return packet


func _ins_packet(truth: Dictionary) -> Dictionary:
	var dropped := bool(_faults["ins_dropout"])
	var observations: Array = []
	if not dropped:
		var ownship := truth.get("ownship", {}) as Dictionary
		var true_position := _xz(ownship.get("position", Vector3.ZERO) as Vector3)
		if _last_ins_position == Vector2.ZERO:
			_last_ins_position = true_position
			_last_truth_position = true_position
		else:
			_last_ins_position += true_position - _last_truth_position
			_last_truth_position = true_position
		var drift := Vector2(0.012, -0.009) * _elapsed_seconds
		var heading_bias := float(_faults["ins_heading_bias_deg"])
		observations.append({
			"observation_id": "INS::OWNSHIP",
			"position_xz": _last_ins_position + drift,
			"heading_degrees": fposmod(float(ownship.get("heading_degrees", 0.0)) + heading_bias, 360.0),
			"course_degrees": ownship.get("course_degrees", 0.0),
			"speed_mps": ownship.get("speed_mps", 0.0),
			"velocity_xz_mps": ownship.get("velocity_xz_mps", Vector2.ZERO),
			"position_uncertainty_meters": 2.0 + drift.length(),
			"confidence": maxf(0.55, 0.96 - drift.length() * 0.01),
		})
	var packet := _base_packet("INS", not dropped, 0.0 if dropped else 0.94, observations)
	packet["integrity"] = "BIAS_SUSPECTED" if absf(float(_faults["ins_heading_bias_deg"])) > 0.01 else packet["integrity"]
	packet["faults_applied"] = {"dropout": dropped, "heading_bias_deg": float(_faults["ins_heading_bias_deg"])}
	return packet


func _false_alarm(modality: String, index: int, range_meters: float) -> Dictionary:
	var bearing := fposmod(37.0 * float(index + 1) + float(_sequence) * 11.0, 360.0)
	return {
		"observation_id": "%s::FALSE::%d::%d" % [modality, _sequence, index],
		"position_xz": _velocity_from_course(bearing, range_meters),
		"velocity_xz_mps": Vector2.ZERO,
		"confidence": 0.18,
		"classification": "UNCONFIRMED_ECHO",
		"identity": null,
		"false_alarm_simulated": true,
	}


func _rebuild_snapshot() -> void:
	var channels := _channel_health()
	var ownship := _fuse_ownship(channels)
	var tracks := _fuse_tracks(channels)
	var online_count := channels.values().filter(func(value: Dictionary) -> bool: return String(value.get("status", "")) == "ONLINE").size()
	var critical_ready := bool(ownship.get("navigation_valid", false))
	var fusion_mode := "NORMAL"
	if not critical_ready:
		fusion_mode = "FAIL_CLOSED"
	elif online_count < SENSOR_ORDER.size():
		fusion_mode = "DEGRADED"
	var decision_valid := critical_ready and (not tracks.is_empty() or online_count >= 4)
	_snapshot = {
		"schema_version": SNAPSHOT_SCHEMA,
		"generated_at_simulation_seconds": _elapsed_seconds,
		"channels": channels,
		"ownship_fusion": ownship,
		"fused_tracks": tracks,
		"confirmed_track_count": tracks.filter(func(item: Dictionary) -> bool: return bool(item.get("confirmed", false))).size(),
		"unconfirmed_track_count": tracks.filter(func(item: Dictionary) -> bool: return not bool(item.get("confirmed", false))).size(),
		"fusion_mode": fusion_mode,
		"decision_input_valid": decision_valid,
		"rl_observation_gateway": {
			"available": decision_valid,
			"wired_to_existing_policy": false,
			"requires_versioned_observation_adapter_and_retraining": true,
			"reason": "existing policies remain frozen during function build",
		},
		"faults": _faults.duplicate(true),
		"pending_packet_count": _pending_packets.size(),
		"receipt_count": _receipts.size(),
		"real_sensor_data_verified": false,
		"physical_sensor_calibration_verified": false,
		"production_authority": false,
		"boundary": _profile.get("claim_boundary", "research simulation only"),
	}
	fusion_snapshot_updated.emit(get_fusion_snapshot())


func _channel_health() -> Dictionary:
	var result := {}
	var timeout := float(_profile.get("channel_timeout_seconds", 1.5))
	for sensor_id in SENSOR_ORDER:
		var packet := _latest_packets.get(sensor_id, {}) as Dictionary
		var status := "OFFLINE"
		var age_seconds = null
		if not packet.is_empty():
			age_seconds = maxf(0.0, _elapsed_seconds - float(packet.get("measurement_time_seconds", _elapsed_seconds)))
			if float(age_seconds) > timeout:
				status = "STALE"
			elif not bool(packet.get("valid", false)):
				status = "OFFLINE"
			elif String(packet.get("integrity", "VALID")) != "VALID":
				status = "DEGRADED"
			else:
				status = "ONLINE"
		result[sensor_id] = {
			"status": status,
			"age_seconds": age_seconds,
			"quality": packet.get("quality", 0.0),
			"integrity": packet.get("integrity", "UNAVAILABLE"),
			"latency_ms": packet.get("latency_ms"),
			"sequence": packet.get("sequence"),
			"source_mode": packet.get("source_mode", "NO_DATA"),
			"hardware_verified": false,
		}
	return result


func _fuse_ownship(channels: Dictionary) -> Dictionary:
	var gnss := _latest_packets.get("GNSS", {}) as Dictionary
	var ins := _latest_packets.get("INS", {}) as Dictionary
	var gnss_valid := bool(gnss.get("valid", false)) and not (gnss.get("observations", []) as Array).is_empty()
	var ins_valid := bool(ins.get("valid", false)) and not (ins.get("observations", []) as Array).is_empty()
	var result := {
		"navigation_valid": false,
		"mode": "FAIL_CLOSED_NO_POSITION",
		"position_xz": null,
		"heading_degrees": null,
		"gnss_ins_disagreement_meters": null,
		"integrity_alerts": [],
		"sources": [],
	}
	if not gnss_valid and not ins_valid:
		return result
	var gnss_observation := (gnss.get("observations", []) as Array)[0] as Dictionary if gnss_valid else {}
	var ins_observation := (ins.get("observations", []) as Array)[0] as Dictionary if ins_valid else {}
	if gnss_valid and ins_valid:
		var gnss_position := gnss_observation.get("position_xz", Vector2.ZERO) as Vector2
		var ins_position := ins_observation.get("position_xz", Vector2.ZERO) as Vector2
		var disagreement := gnss_position.distance_to(ins_position)
		result["gnss_ins_disagreement_meters"] = disagreement
		result["sources"] = ["GNSS", "INS"]
		result["heading_degrees"] = ins_observation.get("heading_degrees")
		if disagreement > float(_profile.get("gnss_ins_disagreement_alarm_meters", 35.0)) or String(gnss.get("integrity", "")) == "SPOOF_SUSPECTED":
			result["navigation_valid"] = true
			result["mode"] = "DEAD_RECKONING_DEGRADED"
			result["position_xz"] = ins_position
			result["integrity_alerts"] = ["GNSS_INS_DISAGREEMENT", "GNSS_SPOOF_SUSPECTED"]
		else:
			result["navigation_valid"] = true
			result["mode"] = "GNSS_INS_FUSED"
			result["position_xz"] = gnss_position.lerp(ins_position, 0.28)
	elif ins_valid:
		result["navigation_valid"] = true
		result["mode"] = "DEAD_RECKONING_DEGRADED"
		result["position_xz"] = ins_observation.get("position_xz")
		result["heading_degrees"] = ins_observation.get("heading_degrees")
		result["sources"] = ["INS"]
		result["integrity_alerts"] = ["GNSS_UNAVAILABLE"]
	else:
		result["navigation_valid"] = true
		result["mode"] = "GNSS_POSITION_ONLY_DEGRADED"
		result["position_xz"] = gnss_observation.get("position_xz")
		result["sources"] = ["GNSS"]
		result["integrity_alerts"] = ["INS_UNAVAILABLE"]
	return result


func _fuse_tracks(channels: Dictionary) -> Array[Dictionary]:
	var tracks: Array[Dictionary] = []
	var gate := float(_profile.get("association_gate_meters", 85.0))
	for sensor_id in ["RADAR", "AIS", "EO", "IR"]:
		var health := channels.get(sensor_id, {}) as Dictionary
		if String(health.get("status", "OFFLINE")) in ["OFFLINE", "STALE"]:
			continue
		var packet := _latest_packets.get(sensor_id, {}) as Dictionary
		for raw_observation in packet.get("observations", []) as Array:
			var observation := raw_observation as Dictionary
			var position := observation.get("position_xz", Vector2.ZERO) as Vector2
			var selected_index := -1
			var nearest_distance := INF
			for index in range(tracks.size()):
				var distance := position.distance_to(tracks[index].get("position_xz", Vector2.ZERO) as Vector2)
				if distance < nearest_distance and distance <= gate:
					nearest_distance = distance
					selected_index = index
			if selected_index < 0:
				tracks.append({
					"track_id": "FUSED-%04d" % (tracks.size() + 1),
					"position_xz": position,
					"velocity_xz_mps": observation.get("velocity_xz_mps", Vector2.ZERO),
					"confidence": float(observation.get("confidence", 0.2)),
					"identity": observation.get("identity"),
					"sources": [sensor_id],
					"observation_ids": [observation.get("observation_id")],
					"false_alarm_suspected": bool(observation.get("false_alarm_simulated", false)),
				})
			else:
				var track := tracks[selected_index]
				var old_confidence := float(track.get("confidence", 0.2))
				var new_confidence := float(observation.get("confidence", 0.2))
				var ratio := new_confidence / maxf(old_confidence + new_confidence, 0.001)
				track["position_xz"] = (track.get("position_xz", position) as Vector2).lerp(position, ratio)
				track["velocity_xz_mps"] = (track.get("velocity_xz_mps", Vector2.ZERO) as Vector2).lerp(observation.get("velocity_xz_mps", Vector2.ZERO) as Vector2, ratio)
				track["confidence"] = clampf(old_confidence + new_confidence * 0.45, 0.0, 1.0)
				if observation.get("identity") != null:
					track["identity"] = observation.get("identity")
				var sources := track.get("sources", []) as Array
				if not sources.has(sensor_id):
					sources.append(sensor_id)
				track["sources"] = sources
				var observation_ids := track.get("observation_ids", []) as Array
				observation_ids.append(observation.get("observation_id"))
				track["observation_ids"] = observation_ids
				track["false_alarm_suspected"] = bool(track.get("false_alarm_suspected", false)) and bool(observation.get("false_alarm_simulated", false))
				tracks[selected_index] = track
	for index in range(tracks.size()):
		var track := tracks[index]
		var sources := track.get("sources", []) as Array
		track["confirmed"] = sources.size() >= 2 or sources.has("AIS")
		track["source_count"] = sources.size()
		track["hardware_verified"] = false
		track["production_authority"] = false
		tracks[index] = track
	return tracks


func _append_receipt(action: String, subject: String, status: String, detail: Dictionary) -> Dictionary:
	_receipt_sequence += 1
	var receipt := {
		"schema_version": "ship_sensor_receipt_v1",
		"sequence": _receipt_sequence,
		"simulation_time_seconds": _elapsed_seconds,
		"action": action,
		"subject": subject,
		"status": status,
		"detail": detail.duplicate(true),
		"production_authority": false,
	}
	_receipts.append(receipt)
	if _receipts.size() > MAX_RECEIPTS:
		_receipts.pop_front()
	sensor_receipt_emitted.emit(receipt.duplicate(true))
	return receipt


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


static func _velocity_from_course(course_degrees: float, magnitude: float) -> Vector2:
	var angle := deg_to_rad(course_degrees)
	return Vector2(sin(angle), cos(angle)) * magnitude


static func _xz(position: Vector3) -> Vector2:
	return Vector2(position.x, position.z)

extends Node
class_name ShipExecutionControlSuite

## Opt-in execution-control and authority-arbitration layer for the simulator.
##
## The layer uses the vessel's existing public command API. It does not change
## the vessel motion model or any policy. It starts disarmed so legacy research
## runs retain their current behavior until an operator explicitly arms this
## versioned control path.

signal execution_snapshot_updated(snapshot: Dictionary)
signal execution_receipt_emitted(receipt: Dictionary)

const PROFILE_PATH := "res://data/verification/execution_control_profile_v1.json"
const SNAPSHOT_SCHEMA := "ship_execution_control_snapshot_v1"
const RECEIPT_SCHEMA := "ship_execution_control_receipt_v1"
const COMMAND_SCHEMA := "ship_execution_command_v1"
const MAX_RECEIPTS := 512
const COMMAND_SOURCES := ["RL", "AUTOPILOT", "REMOTE_CONTROL_CENTER"]

@export var player_path: NodePath = NodePath("../Player")
@export var policy_replay_path: NodePath = NodePath("../ShipPolicyReplayController")
@export var cargo_replay_path: NodePath = NodePath("../CargoCircuitReplayController")

var _player: Node
var _profile: Dictionary = {}
var _elapsed_seconds := 0.0
var _receipt_sequence := 0
var _source_sequences := {}
var _commands := {}
var _receipts: Array[Dictionary] = []
var _snapshot: Dictionary = {}
var _armed := false
var _authority := "MANUAL"
var _mode := "MANUAL_DIRECT"
var _last_requested := Vector2.ZERO
var _last_output := Vector2.ZERO
var _last_output_time_seconds := 0.0
var _last_valid_command_time_seconds = null
var _watchdog_timed_out := false
var _emergency_stop_latched := false
var _manual_takeover_count := 0
var _autopilot := {
	"engaged": false,
	"target_heading_degrees": 0.0,
	"target_speed_mps": 0.0,
}
var _faults := {
	"command_link_loss": false,
	"rudder_feedback_loss": false,
	"throttle_feedback_loss": false,
	"steering_actuator_jam": false,
	"propulsion_actuator_jam": false,
}


func _ready() -> void:
	add_to_group(&"ship_execution_control_suite")
	_profile = _read_json(PROFILE_PATH)
	_player = get_node_or_null(player_path)
	_rebuild_snapshot()
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	_elapsed_seconds += maxf(delta, 0.0)
	_control_step(maxf(delta, 0.0))


func get_execution_snapshot() -> Dictionary:
	return _snapshot.duplicate(true)


func get_receipts() -> Array[Dictionary]:
	return _receipts.duplicate(true)


func get_fault_state() -> Dictionary:
	return _faults.duplicate(true)


func arm_simulation_execution(authorizer: String = "INSTRUCTOR") -> Dictionary:
	if _emergency_stop_latched:
		return _append_receipt("arm", authorizer, "REJECTED", {"reason": "EMERGENCY_STOP_LATCHED"})
	_armed = true
	_authority = "STANDBY"
	_mode = "ARMED_STANDBY"
	_watchdog_timed_out = false
	_rebuild_snapshot()
	return _append_receipt("arm", authorizer, "ACCEPTED_SIMULATION_ONLY", {"production_authority": false})


func disarm_to_manual(reason: String = "OPERATOR_DISARM") -> Dictionary:
	_stop_legacy_automation_for_takeover()
	_armed = false
	_authority = "MANUAL"
	_mode = "MANUAL_DIRECT"
	_commands.clear()
	_autopilot["engaged"] = false
	_last_requested = Vector2.ZERO
	_last_output = Vector2.ZERO
	_watchdog_timed_out = false
	_clear_player_agent_command()
	_rebuild_snapshot()
	return _append_receipt("disarm", "MANUAL", "ACCEPTED", {"reason": reason})


func request_control(source: String) -> Dictionary:
	var normalized := source.to_upper()
	if normalized == "MANUAL":
		return manual_immediate_takeover("CONTROL_REQUEST")
	if normalized not in COMMAND_SOURCES:
		return _append_receipt("request_control", normalized, "REJECTED", {"reason": "UNKNOWN_SOURCE"})
	if _emergency_stop_latched:
		return _append_receipt("request_control", normalized, "REJECTED", {"reason": "EMERGENCY_STOP_LATCHED"})
	if not _armed:
		return _append_receipt("request_control", normalized, "REJECTED", {"reason": "EXECUTION_NOT_ARMED"})
	if normalized == "REMOTE_CONTROL_CENTER":
		var remote := _profile.get("remote_control_center", {}) as Dictionary
		if not bool(remote.get("enabled", false)) or not bool(remote.get("authenticated", false)) or not bool(remote.get("site_authorized", false)):
			return _append_receipt("request_control", normalized, "REJECTED", {"reason": "REMOTE_AUTHORITY_NOT_VERIFIED"})
	_authority = normalized
	_mode = "WAITING_FOR_%s_COMMAND" % normalized
	_watchdog_timed_out = false
	_last_valid_command_time_seconds = null
	if normalized != "AUTOPILOT":
		_autopilot["engaged"] = false
	_rebuild_snapshot()
	return _append_receipt("request_control", normalized, "ACCEPTED", {"authority": normalized})


func submit_command(source: String, throttle: float, rudder: float, sequence: int = -1) -> Dictionary:
	var normalized := source.to_upper()
	if normalized not in COMMAND_SOURCES:
		return _append_receipt("submit_command", normalized, "REJECTED", {"reason": "UNKNOWN_SOURCE"})
	if not is_finite(throttle) or not is_finite(rudder):
		return _append_receipt("submit_command", normalized, "REJECTED", {"reason": "NON_FINITE_COMMAND"})
	if _emergency_stop_latched:
		return _append_receipt("submit_command", normalized, "REJECTED", {"reason": "EMERGENCY_STOP_LATCHED"})
	if not _armed or _authority != normalized:
		return _append_receipt("submit_command", normalized, "REJECTED", {"reason": "SOURCE_HAS_NO_AUTHORITY", "authority": _authority})
	if bool(_faults["command_link_loss"]):
		return _append_receipt("submit_command", normalized, "REJECTED", {"reason": "COMMAND_LINK_LOSS"})
	var previous_sequence := int(_source_sequences.get(normalized, -1))
	var accepted_sequence := sequence if sequence >= 0 else previous_sequence + 1
	if accepted_sequence <= previous_sequence:
		return _append_receipt("submit_command", normalized, "REJECTED", {"reason": "REPLAY_OR_REORDER", "last_sequence": previous_sequence})
	_source_sequences[normalized] = accepted_sequence
	_commands[normalized] = {
		"schema_version": COMMAND_SCHEMA,
		"source": normalized,
		"sequence": accepted_sequence,
		"submitted_at_seconds": _elapsed_seconds,
		"requested_throttle": throttle,
		"requested_rudder": rudder,
	}
	_last_valid_command_time_seconds = _elapsed_seconds
	_watchdog_timed_out = false
	_control_step(float(_profile.get("cycle_period_seconds", 0.05)))
	var limits := _profile.get("command_limits", {}) as Dictionary
	var limited := throttle > float(limits.get("maximum_ahead_throttle", 0.75)) \
		or throttle < -float(limits.get("maximum_astern_throttle", 0.35)) \
		or absf(rudder) > float(limits.get("maximum_rudder_normalized", 0.65))
	return _append_receipt("submit_command", normalized, "ACCEPTED_LIMITED" if limited else "ACCEPTED", {
		"sequence": accepted_sequence,
		"requested": {"throttle": throttle, "rudder": rudder},
		"effective": {"throttle": _last_output.x, "rudder": _last_output.y},
	})


func submit_rl_action(throttle: float, rudder: float, sequence: int = -1) -> Dictionary:
	return submit_command("RL", throttle, rudder, sequence)


func engage_autopilot(target_heading_degrees: float, target_speed_mps: float) -> Dictionary:
	if _emergency_stop_latched:
		return _append_receipt("engage_autopilot", "AUTOPILOT", "REJECTED", {"reason": "EMERGENCY_STOP_LATCHED"})
	if not _armed:
		return _append_receipt("engage_autopilot", "AUTOPILOT", "REJECTED", {"reason": "EXECUTION_NOT_ARMED"})
	_authority = "AUTOPILOT"
	_autopilot = {
		"engaged": true,
		"target_heading_degrees": fposmod(target_heading_degrees, 360.0),
		"target_speed_mps": maxf(target_speed_mps, 0.0),
	}
	_last_valid_command_time_seconds = _elapsed_seconds
	_watchdog_timed_out = false
	_control_step(float(_profile.get("cycle_period_seconds", 0.05)))
	return _append_receipt("engage_autopilot", "AUTOPILOT", "ACCEPTED", _autopilot)


func manual_immediate_takeover(reason: String = "HELM_INPUT") -> Dictionary:
	_stop_legacy_automation_for_takeover()
	_manual_takeover_count += 1
	_armed = false
	_authority = "MANUAL"
	_mode = "MANUAL_IMMEDIATE_TAKEOVER"
	_autopilot["engaged"] = false
	_commands.clear()
	_last_requested = Vector2.ZERO
	_last_output = Vector2.ZERO
	_watchdog_timed_out = false
	_clear_player_agent_command()
	_rebuild_snapshot()
	return _append_receipt("manual_takeover", "MANUAL", "ACCEPTED_IMMEDIATE", {"reason": reason, "takeover_count": _manual_takeover_count})


func trigger_emergency_stop(reason: String = "OPERATOR_ESTOP") -> Dictionary:
	_stop_legacy_automation_for_takeover()
	_emergency_stop_latched = true
	_armed = false
	_authority = "EMERGENCY_STOP"
	_mode = "EMERGENCY_STOP_LATCHED"
	_autopilot["engaged"] = false
	_commands.clear()
	_last_requested = Vector2.ZERO
	_last_output = Vector2.ZERO
	_apply_player_command(Vector2.ZERO)
	_rebuild_snapshot()
	return _append_receipt("emergency_stop", "EMERGENCY_STOP", "LATCHED", {"reason": reason, "physical_independence_verified": false})


func release_emergency_stop(manual_confirmation: bool) -> Dictionary:
	if not _emergency_stop_latched:
		return _append_receipt("release_emergency_stop", "EMERGENCY_STOP", "REJECTED", {"reason": "NOT_LATCHED"})
	if not manual_confirmation:
		return _append_receipt("release_emergency_stop", "EMERGENCY_STOP", "REJECTED", {"reason": "MANUAL_CONFIRMATION_REQUIRED"})
	_emergency_stop_latched = false
	_armed = false
	_authority = "MANUAL"
	_mode = "MANUAL_AFTER_ESTOP_RESET"
	_clear_player_agent_command()
	_rebuild_snapshot()
	return _append_receipt("release_emergency_stop", "MANUAL", "ACCEPTED", {"rearm_required": true})


func set_execution_fault(fault_name: String, value: bool) -> Dictionary:
	if not _faults.has(fault_name):
		return _append_receipt("set_fault", fault_name, "REJECTED", {"reason": "UNKNOWN_FAULT"})
	_faults[fault_name] = value
	_control_step(float(_profile.get("cycle_period_seconds", 0.05)))
	return _append_receipt("set_fault", fault_name, "ACCEPTED", {"value": value})


func clear_execution_faults() -> Dictionary:
	for key in _faults:
		_faults[key] = false
	_rebuild_snapshot()
	return _append_receipt("clear_faults", "ALL", "ACCEPTED", {})


func advance_control_for_test(delta: float) -> Dictionary:
	_elapsed_seconds += maxf(delta, 0.0)
	_control_step(maxf(delta, 0.0))
	return get_execution_snapshot()


func _control_step(delta: float) -> void:
	_resolve_player()
	if _emergency_stop_latched:
		_last_requested = Vector2.ZERO
		_last_output = Vector2.ZERO
		_mode = "EMERGENCY_STOP_LATCHED"
		_apply_player_command(Vector2.ZERO)
		_rebuild_snapshot()
		return
	if not _armed or _authority in ["MANUAL", "STANDBY"]:
		_rebuild_snapshot()
		return
	if bool(_faults["rudder_feedback_loss"]) or bool(_faults["throttle_feedback_loss"]):
		_last_requested = Vector2.ZERO
		_last_output = Vector2.ZERO
		_mode = "FAIL_SAFE_FEEDBACK_LOSS"
		_apply_player_command(Vector2.ZERO)
		_rebuild_snapshot()
		return
	if _authority == "AUTOPILOT" and bool(_autopilot.get("engaged", false)):
		_commands["AUTOPILOT"] = _autopilot_command()
		_last_valid_command_time_seconds = _elapsed_seconds
	var command := _commands.get(_authority, {}) as Dictionary
	var age := INF if _last_valid_command_time_seconds == null else maxf(0.0, _elapsed_seconds - float(_last_valid_command_time_seconds))
	if bool(_faults["command_link_loss"]) or command.is_empty() or age > float(_profile.get("watchdog_timeout_seconds", 0.35)):
		_watchdog_timed_out = true
		_last_requested = Vector2.ZERO
		_last_output = Vector2.ZERO
		_mode = "FAIL_SAFE_WATCHDOG_NEUTRAL"
		_apply_player_command(Vector2.ZERO)
		_rebuild_snapshot()
		return
	_watchdog_timed_out = false
	var requested := Vector2(float(command.get("requested_throttle", 0.0)), float(command.get("requested_rudder", 0.0)))
	_last_requested = requested
	var limited := _bounded_command(requested)
	var limits := _profile.get("command_limits", {}) as Dictionary
	var dt := maxf(delta, float(_profile.get("cycle_period_seconds", 0.05)))
	var effective := Vector2(
		move_toward(_last_output.x, limited.x, float(limits.get("maximum_throttle_slew_per_second", 0.8)) * dt),
		move_toward(_last_output.y, limited.y, float(limits.get("maximum_rudder_slew_per_second", 1.2)) * dt)
	)
	if bool(_faults["propulsion_actuator_jam"]):
		effective.x = _last_output.x
	if bool(_faults["steering_actuator_jam"]):
		effective.y = _last_output.y
	_last_output = effective
	_last_output_time_seconds = _elapsed_seconds
	_mode = "BOUNDED_%s_CONTROL" % _authority
	if bool(_faults["propulsion_actuator_jam"]) or bool(_faults["steering_actuator_jam"]):
		_mode = "DEGRADED_ACTUATOR_JAM"
	_apply_player_command(_last_output)
	_rebuild_snapshot()


func _autopilot_command() -> Dictionary:
	var telemetry := _player_telemetry()
	var current_heading := float(telemetry.get("heading_degrees", 0.0))
	var current_speed := absf(float(telemetry.get("speed", 0.0)))
	var heading_error := wrapf(float(_autopilot.get("target_heading_degrees", 0.0)) - current_heading, -180.0, 180.0)
	var autopilot_profile := _profile.get("autopilot", {}) as Dictionary
	var full_rudder := maxf(float(autopilot_profile.get("heading_error_full_rudder_degrees", 55.0)), 1.0)
	var rudder := clampf(heading_error / full_rudder, -1.0, 1.0)
	var target_speed := float(_autopilot.get("target_speed_mps", 0.0))
	var throttle := float(autopilot_profile.get("minimum_throttle", 0.16)) + (target_speed - current_speed) * float(autopilot_profile.get("speed_gain", 0.16))
	throttle = clampf(throttle, 0.0, float(autopilot_profile.get("maximum_throttle", 0.55)))
	var sequence := int(_source_sequences.get("AUTOPILOT", -1)) + 1
	_source_sequences["AUTOPILOT"] = sequence
	return {
		"schema_version": COMMAND_SCHEMA,
		"source": "AUTOPILOT",
		"sequence": sequence,
		"submitted_at_seconds": _elapsed_seconds,
		"requested_throttle": throttle,
		"requested_rudder": rudder,
		"heading_error_degrees": heading_error,
	}


func _bounded_command(requested: Vector2) -> Vector2:
	var limits := _profile.get("command_limits", {}) as Dictionary
	return Vector2(
		clampf(requested.x, -float(limits.get("maximum_astern_throttle", 0.35)), float(limits.get("maximum_ahead_throttle", 0.75))),
		clampf(requested.y, -float(limits.get("maximum_rudder_normalized", 0.65)), float(limits.get("maximum_rudder_normalized", 0.65)))
	)


func _apply_player_command(command: Vector2) -> void:
	if _player != null and _player.has_method("set_ship_agent_command"):
		_player.call("set_ship_agent_command", command.x, command.y)


func _clear_player_agent_command() -> void:
	if _player != null and _player.has_method("clear_ship_agent_command"):
		_player.call("clear_ship_agent_command")


func _stop_legacy_automation_for_takeover() -> void:
	var policy_replay := get_node_or_null(policy_replay_path)
	if policy_replay != null and policy_replay.has_method("stop_replay"):
		policy_replay.call("stop_replay")
	var cargo_replay := get_node_or_null(cargo_replay_path)
	if cargo_replay != null and cargo_replay.has_method("stop_replay"):
		cargo_replay.call("stop_replay", true)


func _rebuild_snapshot() -> void:
	var telemetry := _player_telemetry()
	var feedback_profile := _profile.get("feedback", {}) as Dictionary
	var receiver_throttle: Variant = telemetry.get("target_throttle")
	var receiver_rudder: Variant = telemetry.get("target_rudder")
	if bool(telemetry.get("external_agent_control_enabled", false)) and _player != null:
		receiver_throttle = _player.get("ship_external_throttle")
		receiver_rudder = _player.get("ship_external_rudder")
	var target_throttle = null if bool(_faults["throttle_feedback_loss"]) else receiver_throttle
	var actual_throttle = null if bool(_faults["throttle_feedback_loss"]) else telemetry.get("throttle")
	var target_rudder = null if bool(_faults["rudder_feedback_loss"]) else receiver_rudder
	var actual_rudder = null if bool(_faults["rudder_feedback_loss"]) else telemetry.get("rudder")
	var ack_tolerance := float(feedback_profile.get("command_ack_tolerance", 0.015))
	var command_ack := target_throttle != null and target_rudder != null \
		and absf(float(target_throttle) - _last_output.x) <= ack_tolerance \
		and absf(float(target_rudder) - _last_output.y) <= ack_tolerance
	var tracking_tolerance := float(feedback_profile.get("actuator_tracking_tolerance", 0.12))
	var tracking_ok := actual_throttle != null and actual_rudder != null \
		and absf(float(actual_throttle) - _last_output.x) <= tracking_tolerance \
		and absf(float(actual_rudder) - _last_output.y) <= tracking_tolerance
	var last_command_age = null if _last_valid_command_time_seconds == null else maxf(0.0, _elapsed_seconds - float(_last_valid_command_time_seconds))
	_snapshot = {
		"schema_version": SNAPSHOT_SCHEMA,
		"generated_at_simulation_seconds": _elapsed_seconds,
		"armed": _armed,
		"mode": _mode,
		"authority": _authority,
		"authority_priority": (_profile.get("authority_priority", []) as Array).duplicate(),
		"requested_command": {"throttle": _last_requested.x, "rudder": _last_requested.y},
		"effective_command": {"throttle": _last_output.x, "rudder": _last_output.y},
		"actuator_feedback": {
			"target_throttle": target_throttle,
			"actual_throttle": actual_throttle,
			"target_rudder": target_rudder,
			"actual_rudder": actual_rudder,
			"command_acknowledged": command_ack,
			"actual_tracking_within_tolerance": tracking_ok,
			"physical_feedback_verified": false,
		},
		"watchdog": {
			"timeout_seconds": float(_profile.get("watchdog_timeout_seconds", 0.35)),
			"last_command_age_seconds": last_command_age,
			"timed_out": _watchdog_timed_out,
		},
		"emergency_stop": {
			"latched": _emergency_stop_latched,
			"software_channel_verified": true,
			"independent_hardware_verified": false,
			"manual_confirmation_required_to_reset": true,
		},
		"manual_takeover": {
			"immediate_priority": true,
			"takeover_count": _manual_takeover_count,
			"player_external_control_active": bool(telemetry.get("external_agent_control_enabled", false)),
		},
		"autopilot": _autopilot.duplicate(true),
		"faults": _faults.duplicate(true),
		"rl_command_gateway": {
			"available_when_armed": true,
			"existing_policy_adapter_wired": false,
			"versioned_api": "submit_rl_action(throttle, rudder, sequence)",
		},
		"external_actuator_adapter": _profile.get("external_actuator_adapter", {}),
		"remote_control_center": _profile.get("remote_control_center", {}),
		"receipt_count": _receipts.size(),
		"physical_actuator_feedback_verified": false,
		"physical_emergency_stop_verified": false,
		"production_authority": false,
		"boundary": _profile.get("claim_boundary", "research simulation only"),
	}
	execution_snapshot_updated.emit(get_execution_snapshot())


func _player_telemetry() -> Dictionary:
	_resolve_player()
	if _player != null and _player.has_method("get_ship_telemetry"):
		return _player.call("get_ship_telemetry") as Dictionary
	return {}


func _resolve_player() -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_node_or_null(player_path)


func _append_receipt(action: String, subject: String, status: String, detail: Dictionary) -> Dictionary:
	_receipt_sequence += 1
	var receipt := {
		"schema_version": RECEIPT_SCHEMA,
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
	execution_receipt_emitted.emit(receipt.duplicate(true))
	_rebuild_snapshot()
	return receipt


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}

extends Node
class_name ShipFullMissionBridgeSuite

## Additive full-mission bridge orchestrator for RL navigation exercises.
##
## It aggregates existing equipment without changing vessel dynamics, policy,
## observation, action or reward contracts.  Camera-sector selection is visual
## only; every actuation remains inside ShipExecutionControlSuite.

signal full_mission_receipt_emitted(receipt: Dictionary)
signal full_mission_snapshot_updated(snapshot: Dictionary)

const PROFILE_PATH := "res://data/verification/full_mission_bridge_profile_v1.json"
const SNAPSHOT_SCHEMA := "ship_full_mission_bridge_snapshot_v1"
const RECEIPT_SCHEMA := "ship_full_mission_bridge_receipt_v1"
const MAX_RECEIPTS := 512
const VISUAL_SECTORS := [
	{"sector_id": "FORWARD", "label": "正前", "bearing_degrees": 180.0},
	{"sector_id": "STARBOARD_BOW", "label": "右前", "bearing_degrees": 225.0},
	{"sector_id": "STARBOARD_BEAM", "label": "正右", "bearing_degrees": 270.0},
	{"sector_id": "STARBOARD_QUARTER", "label": "右后", "bearing_degrees": 315.0},
	{"sector_id": "AFT", "label": "正后", "bearing_degrees": 0.0},
	{"sector_id": "PORT_QUARTER", "label": "左后", "bearing_degrees": 45.0},
	{"sector_id": "PORT_BEAM", "label": "正左", "bearing_degrees": 90.0},
	{"sector_id": "PORT_BOW", "label": "左前", "bearing_degrees": 135.0},
]

@export var player_path: NodePath = NodePath("../Player")
@export var equipment_suite_path: NodePath = NodePath("../ShipNavigationEquipmentSuite")
@export var communication_suite_path: NodePath = NodePath("../ShipGmdssCommunicationsSuite")
@export var execution_suite_path: NodePath = NodePath("../ShipExecutionControlSuite")
@export var collaboration_controller_path: NodePath = NodePath("../ShipBridgeTeamCollaborationController")
@export var instructor_controller_path: NodePath = NodePath("../ShipInstructorExerciseController")

var _player: Node
var _equipment_suite: Node
var _communication_suite: Node
var _execution_suite: Node
var _collaboration_controller: Node
var _instructor_controller: Node
var _profile: Dictionary = {}
var _current_visual_sector := "FORWARD"
var _visited_visual_sectors: Dictionary = {}
var _receipts: Array[Dictionary] = []
var _receipt_sequence := 0
var _previous_receipt_hash := "GENESIS"
var _snapshot: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"ship_full_mission_bridge_suite")
	_profile = _read_json(PROFILE_PATH)
	_resolve_components()
	_rebuild_snapshot()


func prepare_training_mission(session_name: String, exercise_key: String) -> Dictionary:
	_resolve_components()
	if session_name.strip_edges().is_empty():
		return _append_receipt("prepare_training_mission", exercise_key, "REJECTED", {"reason": "SESSION_NAME_REQUIRED"})
	if _collaboration_controller == null or not _collaboration_controller.has_method("create_session"):
		return _append_receipt("prepare_training_mission", exercise_key, "REJECTED", {"reason": "COLLABORATION_CONTROLLER_UNAVAILABLE"})
	if _instructor_controller == null or not _instructor_controller.has_method("load_exercise"):
		return _append_receipt("prepare_training_mission", exercise_key, "REJECTED", {"reason": "INSTRUCTOR_CONTROLLER_UNAVAILABLE"})
	var session_receipt := _collaboration_controller.call("create_session", session_name.strip_edges()) as Dictionary
	var exercise_receipt := _instructor_controller.call("load_exercise", exercise_key) as Dictionary
	var accepted := String(session_receipt.get("status", "")) == "ACCEPTED" and String(exercise_receipt.get("status", "")) == "ACCEPTED"
	_rebuild_snapshot()
	return _append_receipt("prepare_training_mission", exercise_key, "ACCEPTED_SIMULATION_ONLY" if accepted else "REJECTED", {
		"session_receipt": session_receipt,
		"exercise_receipt": exercise_receipt,
		"control_armed": false,
		"training_started": false,
	})


func run_predeparture_check() -> Dictionary:
	_resolve_components()
	var gaps: Array[String] = []
	var equipment := _component_snapshot(_equipment_suite, "get_bridge_snapshot")
	var communication := _component_snapshot(_communication_suite, "get_communication_snapshot")
	var execution := _component_snapshot(_execution_suite, "get_execution_snapshot")
	if equipment.is_empty():
		gaps.append("NAVIGATION_EQUIPMENT_UNAVAILABLE")
	else:
		var radar := equipment.get("radar", {}) as Dictionary
		var ecdis := equipment.get("ecdis", {}) as Dictionary
		if not bool(radar.get("power", false)):
			gaps.append("RADAR_NOT_AVAILABLE")
		if not ecdis.has("route_check_passed") or not ecdis.has("alarms"):
			gaps.append("ECDIS_ROUTE_MONITOR_UNAVAILABLE")
	if communication.is_empty():
		gaps.append("GMDSS_TRAINER_UNAVAILABLE")
	else:
		var watch := communication.get("channel_watch", {}) as Dictionary
		if not bool(watch.get("16", false)) or not bool(watch.get("70", false)):
			gaps.append("GMDSS_GUARD_CHANNEL_NOT_WATCHED")
		if bool((communication.get("faults", {}) as Dictionary).get("vhf_power_loss", false)):
			gaps.append("VHF_POWER_LOSS")
	if execution.is_empty():
		gaps.append("EXECUTION_CONTROL_UNAVAILABLE")
	elif bool((execution.get("emergency_stop", {}) as Dictionary).get("latched", false)):
		gaps.append("EMERGENCY_STOP_LATCHED")
	var passed := gaps.is_empty()
	return _append_receipt("predeparture_check", "FULL_MISSION_BRIDGE", "PASS" if passed else "REJECTED", {
		"gaps": gaps,
		"control_remains_disarmed": not bool(execution.get("armed", false)),
		"production_authority": false,
	})


func set_visual_sector(sector_id: String) -> Dictionary:
	_resolve_components()
	var sector := _find_sector(sector_id.to_upper())
	if sector.is_empty():
		return _append_receipt("set_visual_sector", sector_id, "REJECTED", {"reason": "UNKNOWN_VISUAL_SECTOR"})
	if _player == null or not is_instance_valid(_player):
		return _append_receipt("set_visual_sector", sector_id, "REJECTED", {"reason": "PLAYER_CAMERA_UNAVAILABLE"})
	var bearing := float(sector.get("bearing_degrees", 0.0))
	_player.set("camera_yaw", deg_to_rad(bearing))
	if _player.has_method("_apply_camera_orbit"):
		_player.call("_apply_camera_orbit", 0.0, true)
	_current_visual_sector = String(sector.get("sector_id", "FORWARD"))
	_visited_visual_sectors[_current_visual_sector] = true
	_rebuild_snapshot()
	return _append_receipt("set_visual_sector", _current_visual_sector, "ACCEPTED_VISUAL_ONLY", {
		"bearing_degrees": bearing,
		"camera_only": true,
		"ship_motion_model_modified": false,
	})


func sweep_all_visual_sectors() -> Dictionary:
	var sector_receipts: Array[Dictionary] = []
	for raw_sector in VISUAL_SECTORS:
		var sector := raw_sector as Dictionary
		sector_receipts.append(set_visual_sector(String(sector.get("sector_id", ""))))
	var all_passed := sector_receipts.all(func(receipt: Dictionary) -> bool: return String(receipt.get("status", "")) == "ACCEPTED_VISUAL_ONLY")
	_rebuild_snapshot()
	return _append_receipt("sweep_visual_sectors", "360_DEGREES", "PASS" if all_passed else "REJECTED", {
		"sector_count": sector_receipts.size(),
		"visited_sector_count": _visited_visual_sectors.size(),
		"declared_coverage_degrees": 360 if _visited_visual_sectors.size() == VISUAL_SECTORS.size() else _visited_visual_sectors.size() * 45,
		"physical_projection_verified": false,
	})


func arm_and_engage_autopilot(target_heading_degrees: float, target_speed_mps: float, authorizer: String) -> Dictionary:
	_resolve_components()
	if authorizer.strip_edges().is_empty():
		return _append_receipt("arm_and_engage_autopilot", "AUTOPILOT", "REJECTED", {"reason": "AUTHORIZER_REQUIRED"})
	if _execution_suite == null or not _execution_suite.has_method("arm_simulation_execution") or not _execution_suite.has_method("engage_autopilot"):
		return _append_receipt("arm_and_engage_autopilot", "AUTOPILOT", "REJECTED", {"reason": "EXECUTION_SUITE_UNAVAILABLE"})
	var arm := _execution_suite.call("arm_simulation_execution", authorizer.strip_edges()) as Dictionary
	var engage := _execution_suite.call("engage_autopilot", target_heading_degrees, target_speed_mps) as Dictionary
	var accepted := String(arm.get("status", "")).begins_with("ACCEPTED") and String(engage.get("status", "")).begins_with("ACCEPTED")
	_rebuild_snapshot()
	return _append_receipt("arm_and_engage_autopilot", "AUTOPILOT", "ACCEPTED_SIMULATION_ONLY" if accepted else "REJECTED", {
		"arm_receipt": arm,
		"engage_receipt": engage,
		"physical_actuator": false,
	})


func manual_immediate_takeover(reason: String = "FULL_MISSION_BRIDGE_OPERATOR") -> Dictionary:
	_resolve_components()
	if _execution_suite == null or not _execution_suite.has_method("manual_immediate_takeover"):
		return _append_receipt("manual_takeover", "MANUAL", "REJECTED", {"reason": "EXECUTION_SUITE_UNAVAILABLE"})
	var control_receipt := _execution_suite.call("manual_immediate_takeover", reason) as Dictionary
	var accepted := String(control_receipt.get("status", "")) == "ACCEPTED_IMMEDIATE"
	_rebuild_snapshot()
	return _append_receipt("manual_takeover", "MANUAL", "ACCEPTED_IMMEDIATE" if accepted else "REJECTED", {"control_receipt": control_receipt})


func get_full_mission_snapshot() -> Dictionary:
	_resolve_components()
	_rebuild_snapshot()
	return _snapshot.duplicate(true)


func get_visual_sectors() -> Array[Dictionary]:
	return VISUAL_SECTORS.duplicate(true)


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


func _rebuild_snapshot() -> void:
	var equipment := _component_snapshot(_equipment_suite, "get_bridge_snapshot")
	var communication := _component_snapshot(_communication_suite, "get_communication_snapshot")
	var execution := _component_snapshot(_execution_suite, "get_execution_snapshot")
	var collaboration := _component_snapshot(_collaboration_controller, "get_collaboration_snapshot")
	var instructor := _component_snapshot(_instructor_controller, "get_exercise_snapshot")
	var component_presence := {
		"navigation_equipment": not equipment.is_empty(),
		"gmdss_communications": not communication.is_empty(),
		"execution_control": not execution.is_empty(),
		"multi_station_collaboration": not collaboration.is_empty(),
		"instructor_exercise": not instructor.is_empty(),
	}
	var software_functional := component_presence.values().all(func(value: Variant) -> bool: return bool(value)) and VISUAL_SECTORS.size() == 8
	_snapshot = {
		"schema_version": SNAPSHOT_SCHEMA,
		"profile_id": _profile.get("profile_id", ""),
		"component_presence": component_presence,
		"navigation_equipment": equipment,
		"communications": communication,
		"execution_control": execution,
		"collaboration": collaboration,
		"instructor_exercise": instructor,
		"visual": {
			"mode": "SOFTWARE_ORBIT_SECTORS",
			"current_sector": _current_visual_sector,
			"sector_count": VISUAL_SECTORS.size(),
			"visited_sector_count": _visited_visual_sectors.size(),
			"declared_horizontal_coverage_degrees": 360,
			"physical_projection_verified": false,
			"multi_channel_synchronization_verified": false,
		},
		"functional_software_bridge_complete": software_functional,
		"receipt_chain": verify_receipt_chain(),
		"preservation_boundary": (_profile.get("preservation_boundary", {}) as Dictionary).duplicate(true),
		"claims": (_profile.get("claim_boundary", {}) as Dictionary).duplicate(true),
		"production_authority": false,
		"boundary": "Integrated software bridge for RL simulation and training; not a type-approved physical full-mission bridge or approved course",
	}
	full_mission_snapshot_updated.emit(_snapshot.duplicate(true))


func _component_snapshot(component: Node, method: String) -> Dictionary:
	if component != null and is_instance_valid(component) and component.has_method(method):
		return component.call(method) as Dictionary
	return {}


func _find_sector(sector_id: String) -> Dictionary:
	for raw_sector in VISUAL_SECTORS:
		var sector := raw_sector as Dictionary
		if String(sector.get("sector_id", "")) == sector_id:
			return sector
	return {}


func _append_receipt(action: String, subject: String, status: String, detail: Dictionary) -> Dictionary:
	_receipt_sequence += 1
	var receipt := {
		"schema_version": RECEIPT_SCHEMA,
		"receipt_id": "FMB-%06d" % _receipt_sequence,
		"sequence": _receipt_sequence,
		"utc": Time.get_datetime_string_from_system(true),
		"action": action,
		"subject": subject,
		"status": status,
		"detail": detail.duplicate(true),
		"previous_receipt_hash": _previous_receipt_hash,
		"ship_motion_model_modified": false,
		"existing_policy_modified": false,
		"production_authority": false,
	}
	receipt["receipt_hash"] = _sha256_text(JSON.stringify(receipt))
	_previous_receipt_hash = String(receipt["receipt_hash"])
	_receipts.append(receipt)
	while _receipts.size() > MAX_RECEIPTS:
		_receipts.pop_front()
	_rebuild_snapshot()
	full_mission_receipt_emitted.emit(receipt.duplicate(true))
	return receipt.duplicate(true)


func _resolve_components() -> void:
	_player = _resolve(_player, player_path, &"player")
	_equipment_suite = _resolve(_equipment_suite, equipment_suite_path, &"ship_navigation_equipment_suite")
	_communication_suite = _resolve(_communication_suite, communication_suite_path, &"ship_gmdss_communications_suite")
	_execution_suite = _resolve(_execution_suite, execution_suite_path, &"ship_execution_control_suite")
	_collaboration_controller = _resolve(_collaboration_controller, collaboration_controller_path, &"ship_bridge_team_collaboration_controller")
	_instructor_controller = _resolve(_instructor_controller, instructor_controller_path, &"ship_instructor_exercise_controller")


func _resolve(current: Node, path: NodePath, group_name: StringName) -> Node:
	if current != null and is_instance_valid(current):
		return current
	var resolved := get_node_or_null(path)
	if resolved == null and get_tree() != null:
		resolved = get_tree().get_first_node_in_group(group_name)
	return resolved


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

extends Node
class_name ShipAdvancedMissionRealismController

## Task-level realism, machinery-fault and debrief layer for the five advanced
## maritime missions. Hydrodynamic additions are bounded research proxies and
## remain fail-closed as uncalibrated until named-vessel trials are supplied.

signal realism_snapshot_updated(snapshot: Dictionary)
signal realism_receipt_emitted(receipt: Dictionary)

const SCHEMA_VERSION := "ship_advanced_mission_realism_runtime_v1"
const RECEIPT_VERSION := "ship_advanced_mission_realism_receipt_v1"
const GRAVITY_MPS2 := 9.80665
const REFRESH_INTERVAL_SECONDS := 0.20
const MAX_RECEIPTS := 512
const MAX_SAMPLES := 1800
const ZERO_FAULTS := {
	"port_propulsion_loss": 0.0,
	"starboard_propulsion_loss": 0.0,
	"steering_bias_deg": 0.0,
}

@export var scenario_controller_path: NodePath = NodePath("../ShipScenarioController")
@export var advanced_mission_controller_path: NodePath = NodePath("../ShipAdvancedMissionController")
@export var fleet_manager_path: NodePath = NodePath("../ShipFleetManager")
@export var weather_time_path: NodePath = NodePath("../ShipWeatherTimeController")
@export var equipment_suite_path: NodePath = NodePath("../ShipNavigationEquipmentSuite")
@export var communication_suite_path: NodePath = NodePath("../ShipGmdssCommunicationsSuite")
@export var instructor_controller_path: NodePath = NodePath("../ShipInstructorExerciseController")

var _scenario_controller: Node
var _advanced_mission_controller: Node
var _fleet_manager: Node
var _weather_time: Node
var _equipment_suite: Node
var _communication_suite: Node
var _instructor_controller: Node
var _scenario_key := ""
var _scenario: Dictionary = {}
var _profile: Dictionary = {}
var _active := false
var _elapsed_seconds := 0.0
var _refresh_left := 0.0
var _predeparture_passed := false
var _predeparture_operator := ""
var _environment_applied := false
var _machinery_faults: Dictionary = ZERO_FAULTS.duplicate(true)
var _operator_actions: Array[Dictionary] = []
var _samples: Array[Dictionary] = []
var _receipts: Array[Dictionary] = []
var _receipt_sequence := 0
var _minimum_ukc_m := INF
var _minimum_bank_clearance_m := INF
var _maximum_squat_m := 0.0
var _maximum_depth_froude := 0.0
var _latest_hydrodynamics: Dictionary = {}
var _snapshot: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"ship_advanced_mission_realism_controller")
	_resolve_components()
	if _scenario_controller != null and _scenario_controller.has_signal("scenario_changed"):
		_scenario_controller.connect("scenario_changed", _on_scenario_changed)
	call_deferred("_activate_current_scenario")
	set_process(true)


func _process(delta: float) -> void:
	if not _active or get_tree().paused:
		return
	_elapsed_seconds += maxf(delta, 0.0)
	_refresh_left -= maxf(delta, 0.0)
	if _refresh_left > 0.0:
		return
	_refresh_left = REFRESH_INTERVAL_SECONDS
	_sample_runtime_state()
	_rebuild_snapshot()


func get_realism_snapshot() -> Dictionary:
	if _active:
		_sample_runtime_state()
	_rebuild_snapshot()
	return _snapshot.duplicate(true)


func get_receipts() -> Array[Dictionary]:
	return _receipts.duplicate(true)


func run_predeparture_check(operator_id: String) -> Dictionary:
	if not _active:
		return _append_receipt("predeparture_check", "REJECTED", {"reason": "ADVANCED_REALISM_PROFILE_INACTIVE"})
	if operator_id.strip_edges().is_empty():
		return _append_receipt("predeparture_check", "REJECTED", {"reason": "OPERATOR_ID_REQUIRED"})
	var bridge := _bridge_domain_readiness()
	var hydro := _hydrodynamics_for_state(Vector3.ZERO, 0.0, 0.0, false)
	var gaps: Array[String] = []
	for domain in bridge.get("missing_domains", []) as Array:
		gaps.append(String(domain))
	if float(hydro.get("static_ukc_m", -INF)) < float(hydro.get("minimum_ukc_m", 0.0)):
		gaps.append("STATIC_UKC_BELOW_LIMIT")
	_predeparture_passed = gaps.is_empty()
	_predeparture_operator = operator_id.strip_edges() if _predeparture_passed else ""
	_rebuild_snapshot()
	return _append_receipt(
		"predeparture_check",
		"PASS" if _predeparture_passed else "REJECTED",
		{
			"operator_id": operator_id.strip_edges(),
			"gaps": gaps,
			"bridge_domains": bridge,
			"static_ukc_m": hydro.get("static_ukc_m"),
			"control_armed": false,
			"production_authority": false,
		},
	)


func record_operator_action(action_key: String, operator_id: String) -> Dictionary:
	if not _active:
		return _append_receipt("operator_action", "REJECTED", {"reason": "ADVANCED_REALISM_PROFILE_INACTIVE"})
	if action_key.strip_edges().is_empty() or operator_id.strip_edges().is_empty():
		return _append_receipt("operator_action", "REJECTED", {"reason": "ACTION_AND_OPERATOR_REQUIRED"})
	var record := {
		"action_key": action_key.strip_edges(),
		"operator_id": operator_id.strip_edges(),
		"elapsed_seconds": snapped(_elapsed_seconds, 0.01),
		"utc": Time.get_datetime_string_from_system(true),
	}
	_operator_actions.append(record)
	return _append_receipt("operator_action", "ACCEPTED_SIMULATION_ONLY", record)


func inject_machinery_fault(fault_key: String, value: float, operator_id: String) -> Dictionary:
	if not _active:
		return _append_receipt("machinery_fault", "REJECTED", {"reason": "ADVANCED_REALISM_PROFILE_INACTIVE"})
	if operator_id.strip_edges().is_empty():
		return _append_receipt("machinery_fault", "REJECTED", {"reason": "OPERATOR_ID_REQUIRED"})
	var allowed := _profile.get("allowed_machinery_faults", []) as Array
	if not allowed.has(fault_key):
		return _append_receipt("machinery_fault", "REJECTED", {"reason": "FAULT_NOT_ALLOWED_FOR_MISSION", "fault_key": fault_key})
	match fault_key:
		"port_propulsion_loss", "starboard_propulsion_loss":
			_machinery_faults[fault_key] = clampf(value, 0.0, 1.0)
		"steering_bias_deg":
			_machinery_faults[fault_key] = clampf(value, -18.0, 18.0)
		_:
			return _append_receipt("machinery_fault", "REJECTED", {"reason": "UNKNOWN_FAULT", "fault_key": fault_key})
	_rebuild_snapshot()
	return _append_receipt("machinery_fault", "EXECUTED_SIMULATION_ONLY", {
		"fault_key": fault_key,
		"value": _machinery_faults[fault_key],
		"operator_id": operator_id.strip_edges(),
		"persistent_until_restored": true,
	})


func restore_machinery_faults(operator_id: String) -> Dictionary:
	if operator_id.strip_edges().is_empty():
		return _append_receipt("machinery_restore", "REJECTED", {"reason": "OPERATOR_ID_REQUIRED"})
	_machinery_faults = ZERO_FAULTS.duplicate(true)
	_rebuild_snapshot()
	return _append_receipt("machinery_restore", "EXECUTED_SIMULATION_ONLY", {
		"operator_id": operator_id.strip_edges(),
		"faults": _machinery_faults.duplicate(true),
	})


func get_hydrodynamic_forcing(ship: Node3D) -> Dictionary:
	if not _active or ship == null or not is_instance_valid(ship):
		return _inactive_forcing()
	var telemetry := _telemetry(ship)
	var forcing := _hydrodynamics_for_state(
		ship.global_position,
		float(telemetry.get("heading_degrees", 0.0)),
		# Hydrodynamic drag/squat depend on water-relative surge, not ground
		# speed. Ground speed includes current and breaks the RL plant contract.
		float(telemetry.get("surge_mps", telemetry.get("speed", 0.0))),
		true,
	)
	if ship != _controlled_ship():
		forcing["port_thrust_factor"] = 1.0
		forcing["starboard_thrust_factor"] = 1.0
		forcing["steering_bias_deg"] = 0.0
	return forcing


func evaluate_hydrodynamic_state(position: Vector3, heading_degrees: float, speed_mps: float) -> Dictionary:
	return _hydrodynamics_for_state(position, heading_degrees, speed_mps, true)


func get_debrief_report() -> Dictionary:
	var mission_snapshot := _advanced_snapshot()
	var gate := mission_snapshot.get("gate", {}) as Dictionary
	var behavioral := mission_snapshot.get("behavioral_assessment", {}) as Dictionary
	var hydro := _latest_hydrodynamics
	var hydro_profile := _profile.get("hydrodynamics", {}) as Dictionary
	var minimum_required_ukc := float(hydro_profile.get("minimum_ukc_m", 0.0))
	var minimum_required_bank := float(hydro_profile.get("minimum_bank_clearance_m", 0.0))
	var collision_free := bool(gate.get("collision_free", true))
	var ukc_safe := _minimum_ukc_m == INF or _minimum_ukc_m >= minimum_required_ukc
	var bank_safe := _minimum_bank_clearance_m == INF or _minimum_bank_clearance_m >= minimum_required_bank
	var mission_passed := bool(behavioral.get("passed", gate.get("passed", false)))
	var unresolved_faults := _active_fault_keys()
	var safety_score := 0.0
	if collision_free:
		safety_score += 25.0
	if ukc_safe:
		safety_score += 15.0
	if bank_safe:
		safety_score += 10.0
	var mission_score := 30.0 if mission_passed else 0.0
	var procedure_score := 0.0
	if _predeparture_passed:
		procedure_score += 10.0
	if not _operator_actions.is_empty():
		procedure_score += 5.0
	if unresolved_faults.is_empty():
		procedure_score += 5.0
	var total_score := safety_score + mission_score + procedure_score
	var passed := total_score >= 70.0 and mission_passed and _predeparture_passed and ukc_safe and bank_safe and collision_free
	return {
		"schema_version": "ship_advanced_mission_debrief_v1",
		"scenario_key": _scenario_key,
		"elapsed_seconds": snapped(_elapsed_seconds, 0.01),
		"status": "PASS" if passed else "NOT_YET_PASS",
		"passed": passed,
		"score": snapped(total_score, 0.1),
		"score_breakdown": {"safety": safety_score, "mission": mission_score, "procedure": procedure_score},
		"mission_gate": gate.duplicate(true),
		"behavioral_assessment": behavioral.duplicate(true),
		"predeparture_passed": _predeparture_passed,
		"operator_actions": _operator_actions.duplicate(true),
		"sample_count": _samples.size(),
		"minimum_ukc_m": null if _minimum_ukc_m == INF else snapped(_minimum_ukc_m, 0.001),
		"minimum_bank_clearance_m": null if _minimum_bank_clearance_m == INF else snapped(_minimum_bank_clearance_m, 0.001),
		"maximum_squat_m": snapped(_maximum_squat_m, 0.001),
		"maximum_depth_froude": snapped(_maximum_depth_froude, 0.001),
		"latest_hydrodynamics": hydro.duplicate(true),
		"active_faults": unresolved_faults,
		"competency_criteria": (_profile.get("competency_criteria", []) as Array).duplicate(),
		"named_vessel_dynamics_calibrated": false,
		"physical_hil_verified": false,
		"stcw_approved": false,
		"dnv_certified": false,
		"production_authority": false,
	}


func finalize_mission_debrief(operator_id: String) -> Dictionary:
	if operator_id.strip_edges().is_empty():
		return _append_receipt("finalize_debrief", "REJECTED", {"reason": "OPERATOR_ID_REQUIRED"})
	var report := get_debrief_report()
	report["finalized_by"] = operator_id.strip_edges()
	report["finalized_at_utc"] = Time.get_datetime_string_from_system(true)
	report["receipts"] = _receipts.duplicate(true)
	var path := "user://advanced_mission_debrief_%s.json" % _scenario_key
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _append_receipt("finalize_debrief", "REJECTED", {"reason": "REPORT_WRITE_FAILED", "path": path})
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	return _append_receipt("finalize_debrief", "EXPORTED", {
		"path": ProjectSettings.globalize_path(path),
		"operator_id": operator_id.strip_edges(),
		"report_status": report.get("status"),
		"score": report.get("score"),
	})


func _on_scenario_changed(_status: Dictionary) -> void:
	_activate_current_scenario()


func _activate_current_scenario() -> void:
	_resolve_components()
	_elapsed_seconds = 0.0
	_refresh_left = 0.0
	_predeparture_passed = false
	_predeparture_operator = ""
	_environment_applied = false
	_machinery_faults = ZERO_FAULTS.duplicate(true)
	_operator_actions.clear()
	_samples.clear()
	_minimum_ukc_m = INF
	_minimum_bank_clearance_m = INF
	_maximum_squat_m = 0.0
	_maximum_depth_froude = 0.0
	_latest_hydrodynamics = {}
	_scenario = {}
	if _scenario_controller != null and _scenario_controller.has_method("get_current_scenario_config"):
		_scenario = _scenario_controller.call("get_current_scenario_config") as Dictionary
	var status: Dictionary = {}
	if _scenario_controller != null and _scenario_controller.has_method("get_scenario_status"):
		status = _scenario_controller.call("get_scenario_status") as Dictionary
	_scenario_key = String(status.get("key", "open_water"))
	_profile = (_scenario.get("realism", {}) as Dictionary).duplicate(true)
	_active = String(_profile.get("profile_version", "")) == "advanced_mission_realism_v1"
	if _active and _weather_time != null and _weather_time.has_method("apply_zero_fog_clear_baseline"):
		var environment := (_profile.get("environment", {}) as Dictionary).duplicate(true)
		_weather_time.call("apply_zero_fog_clear_baseline", environment)
		_environment_applied = true
	_sample_runtime_state()
	_rebuild_snapshot()
	_append_receipt("activate_realism_profile", "ACCEPTED_SIMULATION_ONLY" if _active else "INACTIVE", {
		"scenario_key": _scenario_key,
		"profile_version": _profile.get("profile_version", ""),
		"environment_applied": _environment_applied,
		"changes_existing_policy": false,
	})


func _sample_runtime_state() -> void:
	if not _active:
		return
	var ship := _controlled_ship()
	if ship == null:
		return
	_latest_hydrodynamics = get_hydrodynamic_forcing(ship)
	var ukc_variant: Variant = _latest_hydrodynamics.get("under_keel_clearance_m")
	if ukc_variant != null:
		_minimum_ukc_m = minf(_minimum_ukc_m, float(ukc_variant))
	var bank_variant: Variant = _latest_hydrodynamics.get("bank_clearance_m")
	if bank_variant != null:
		_minimum_bank_clearance_m = minf(_minimum_bank_clearance_m, float(bank_variant))
	_maximum_squat_m = maxf(_maximum_squat_m, float(_latest_hydrodynamics.get("squat_m", 0.0)))
	_maximum_depth_froude = maxf(_maximum_depth_froude, float(_latest_hydrodynamics.get("depth_froude", 0.0)))
	_samples.append({
		"elapsed_seconds": snapped(_elapsed_seconds, 0.01),
		"position": {"x": ship.global_position.x, "z": ship.global_position.z},
		"hydrodynamics": _latest_hydrodynamics.duplicate(true),
		"mission_gate": (_advanced_snapshot().get("gate", {}) as Dictionary).duplicate(true),
	})
	while _samples.size() > MAX_SAMPLES:
		_samples.pop_front()


func _hydrodynamics_for_state(position: Vector3, heading_degrees: float, speed_mps: float, include_bank: bool) -> Dictionary:
	if not _active:
		return _inactive_forcing()
	var hydro := _profile.get("hydrodynamics", {}) as Dictionary
	var vessel := _profile.get("vessel", {}) as Dictionary
	var weather := _weather_snapshot()
	var tide_m := float(weather.get("tide_meters", (_profile.get("environment", {}) as Dictionary).get("tide_meters", 0.0)))
	var chart_depth_m := maxf(float(hydro.get("water_depth_m", 0.0)), 0.1)
	var water_depth_m := maxf(chart_depth_m + tide_m, 0.1)
	var draft_m := maxf(float(vessel.get("draft_m", 0.0)), 0.0)
	var static_ukc_m := water_depth_m - draft_m
	var depth_froude := absf(speed_mps) / sqrt(GRAVITY_MPS2 * water_depth_m)
	var bounded_froude := minf(depth_froude, 0.85)
	var froude_squared := bounded_froude * bounded_froude
	var squat_m := 0.0
	if bool(hydro.get("shallow_water_enabled", false)) and draft_m > 0.0:
		squat_m = float(hydro.get("squat_coefficient", 0.0)) * draft_m * froude_squared / maxf(1.0 - froude_squared, 0.15)
		squat_m = clampf(squat_m, 0.0, draft_m * 0.65)
	var ukc_m := static_ukc_m - squat_m
	var shallow_drag := 0.0
	if bool(hydro.get("shallow_water_enabled", false)) and not is_zero_approx(speed_mps):
		var drag_gain := float(hydro.get("shallow_drag_n_per_mps2", 0.0))
		shallow_drag = -signf(speed_mps) * drag_gain * speed_mps * speed_mps * (1.0 + 4.0 * froude_squared)
		if ukc_m <= 0.0:
			shallow_drag += -signf(speed_mps) * 5000.0
	var bank_clearance: Variant = null
	var bank_proximity := 0.0
	var bank_world_force_x := 0.0
	var bank_yaw_moment := 0.0
	if include_bank and bool(hydro.get("bank_effect_enabled", false)):
		var center_x := float(hydro.get("channel_center_x_m", 0.0))
		var half_width := maxf(float(hydro.get("navigable_half_width_m", 0.0)), 0.1)
		var beam_m := maxf(float(vessel.get("beam_m", 0.0)), 0.0)
		bank_clearance = half_width - absf(position.x - center_x) - beam_m * 0.5
		var influence := maxf(float(hydro.get("bank_influence_distance_m", 0.0)), 0.1)
		bank_proximity = clampf((influence - maxf(float(bank_clearance), 0.0)) / influence, 0.0, 1.0)
		var side := 1.0 if position.x >= center_x else -1.0
		var speed_factor := clampf(absf(speed_mps) / 5.0, 0.0, 1.5)
		bank_world_force_x = side * float(hydro.get("bank_suction_force_n", 0.0)) * bank_proximity * speed_factor
		var heading_rad := deg_to_rad(heading_degrees)
		var bank_force_sway := bank_world_force_x * cos(heading_rad)
		bank_yaw_moment = -signf(bank_force_sway) * float(hydro.get("bank_yaw_moment_nm", 0.0)) * bank_proximity * speed_factor
	var heading := deg_to_rad(heading_degrees)
	var bank_force_body := Vector2(bank_world_force_x * sin(heading), bank_world_force_x * cos(heading))
	var total_body_force := Vector2(shallow_drag, 0.0) + bank_force_body
	return {
		"active": true,
		"model_id": "bounded_shallow_bank_proxy_v1",
		"model_evidence": "generic_research_proxy_not_named_vessel_calibrated",
		"hydrodynamic_force_body_n": total_body_force,
		"hydrodynamic_yaw_moment_nm": bank_yaw_moment,
		"port_thrust_factor": 1.0 - float(_machinery_faults.get("port_propulsion_loss", 0.0)),
		"starboard_thrust_factor": 1.0 - float(_machinery_faults.get("starboard_propulsion_loss", 0.0)),
		"steering_bias_deg": float(_machinery_faults.get("steering_bias_deg", 0.0)),
		"chart_depth_m": chart_depth_m,
		"tide_m": tide_m,
		"water_depth_m": water_depth_m,
		"draft_m": draft_m,
		"static_ukc_m": static_ukc_m,
		"squat_m": squat_m,
		"under_keel_clearance_m": ukc_m,
		"minimum_ukc_m": float(hydro.get("minimum_ukc_m", 0.0)),
		"depth_froude": depth_froude,
		"bank_clearance_m": bank_clearance,
		"minimum_bank_clearance_m": float(hydro.get("minimum_bank_clearance_m", 0.0)),
		"bank_proximity": bank_proximity,
		"bank_effect_enabled": bool(hydro.get("bank_effect_enabled", false)),
		"named_vessel_dynamics_calibrated": false,
		"production_authority": false,
	}


func _inactive_forcing() -> Dictionary:
	return {
		"active": false,
		"hydrodynamic_force_body_n": Vector2.ZERO,
		"hydrodynamic_yaw_moment_nm": 0.0,
		"port_thrust_factor": 1.0,
		"starboard_thrust_factor": 1.0,
		"steering_bias_deg": 0.0,
		"named_vessel_dynamics_calibrated": false,
		"production_authority": false,
	}


func _bridge_domain_readiness() -> Dictionary:
	_resolve_components()
	var required := _profile.get("required_bridge_domains", []) as Array
	var equipment := _component_snapshot(_equipment_suite, "get_bridge_snapshot")
	var communication := _component_snapshot(_communication_suite, "get_communication_snapshot")
	var radar := equipment.get("radar", {}) as Dictionary
	var ecdis := equipment.get("ecdis", {}) as Dictionary
	var conning := equipment.get("conning", {}) as Dictionary
	var channel_watch := communication.get("channel_watch", {}) as Dictionary
	var communication_faults := communication.get("faults", {}) as Dictionary
	var states := {
		"radar_arpa": not radar.is_empty() and bool(radar.get("power", false)),
		"ecdis": not ecdis.is_empty() and ecdis.has("route_check_passed") and ecdis.has("alarms"),
		"conning": not conning.is_empty() and conning.has("heading_degrees") and conning.has("speed_knots"),
		"gmdss": not communication.is_empty() \
			and bool(channel_watch.get("16", false)) \
			and bool(channel_watch.get("70", false)) \
			and not bool(communication_faults.get("vhf_power_loss", false)),
		"instructor": _instructor_controller != null and is_instance_valid(_instructor_controller),
		"recording_debrief": true,
	}
	var missing: Array[String] = []
	for raw_domain in required:
		var domain := String(raw_domain)
		if not bool(states.get(domain, false)):
			missing.append(domain)
	return {
		"passed": missing.is_empty(),
		"required_domains": required.duplicate(),
		"states": states,
		"missing_domains": missing,
	}


func _rebuild_snapshot() -> void:
	var bridge := _bridge_domain_readiness() if _active else {"passed": false, "missing_domains": ["ADVANCED_REALISM_PROFILE_INACTIVE"]}
	var debrief := get_debrief_report() if _active else {}
	_snapshot = {
		"schema_version": SCHEMA_VERSION,
		"scenario_key": _scenario_key,
		"active": _active,
		"profile": _profile.duplicate(true),
		"environment_applied": _environment_applied,
		"environment": _weather_snapshot(),
		"bridge_readiness": bridge,
		"predeparture_passed": _predeparture_passed,
		"predeparture_operator": _predeparture_operator,
		"hydrodynamics": _latest_hydrodynamics.duplicate(true),
		"machinery_faults": _machinery_faults.duplicate(true),
		"operator_action_count": _operator_actions.size(),
		"debrief": debrief,
		"existing_policy_modified": false,
		"named_vessel_dynamics_calibrated": false,
		"physical_hil_verified": false,
		"stcw_approved": false,
		"dnv_certified": false,
		"production_authority": false,
		"boundary": "Software mission-realism proxy; named-vessel calibration, physical bridge HIL, official charts, witnessed sea trials and certification remain external gates.",
	}
	realism_snapshot_updated.emit(_snapshot.duplicate(true))


func _advanced_snapshot() -> Dictionary:
	if _advanced_mission_controller == null or not is_instance_valid(_advanced_mission_controller):
		_resolve_components()
	if _advanced_mission_controller != null and _advanced_mission_controller.has_method("get_advanced_mission_snapshot"):
		return _advanced_mission_controller.call("get_advanced_mission_snapshot") as Dictionary
	return {}


func _weather_snapshot() -> Dictionary:
	if _weather_time == null or not is_instance_valid(_weather_time):
		_resolve_components()
	if _weather_time != null and _weather_time.has_method("get_weather_time_status"):
		return _weather_time.call("get_weather_time_status") as Dictionary
	return (_profile.get("environment", {}) as Dictionary).duplicate(true)


func _controlled_ship() -> Node3D:
	if _fleet_manager == null or not is_instance_valid(_fleet_manager):
		_resolve_components()
	if _fleet_manager != null and _fleet_manager.has_method("get_controlled_ship"):
		var candidate: Variant = _fleet_manager.call("get_controlled_ship")
		if candidate is Node3D and is_instance_valid(candidate):
			return candidate as Node3D
	return get_tree().get_first_node_in_group(&"player") as Node3D


func _telemetry(ship: Node3D) -> Dictionary:
	if ship != null and ship.has_method("get_ship_telemetry"):
		return ship.call("get_ship_telemetry") as Dictionary
	return {}


func _active_fault_keys() -> Array[String]:
	var result: Array[String] = []
	for key in _machinery_faults:
		if not is_zero_approx(float(_machinery_faults[key])):
			result.append(String(key))
	return result


func _component_snapshot(component: Node, method_name: String) -> Dictionary:
	if component != null and is_instance_valid(component) and component.has_method(method_name):
		return component.call(method_name) as Dictionary
	return {}


func _resolve_components() -> void:
	_scenario_controller = _resolve(_scenario_controller, scenario_controller_path, &"ship_scenario_system")
	_advanced_mission_controller = _resolve(_advanced_mission_controller, advanced_mission_controller_path, &"ship_advanced_mission_controller")
	_fleet_manager = _resolve(_fleet_manager, fleet_manager_path, &"ship_fleet_manager")
	_weather_time = _resolve(_weather_time, weather_time_path, &"ship_weather_time_system")
	_equipment_suite = _resolve(_equipment_suite, equipment_suite_path, &"ship_navigation_equipment_suite")
	_communication_suite = _resolve(_communication_suite, communication_suite_path, &"ship_gmdss_communications_suite")
	_instructor_controller = _resolve(_instructor_controller, instructor_controller_path, &"ship_instructor_exercise_controller")


func _resolve(current: Node, path: NodePath, group_name: StringName) -> Node:
	if current != null and is_instance_valid(current):
		return current
	var resolved := get_node_or_null(path)
	if resolved == null and get_tree() != null:
		resolved = get_tree().get_first_node_in_group(group_name)
	return resolved


func _append_receipt(action: String, status: String, detail: Dictionary) -> Dictionary:
	_receipt_sequence += 1
	var receipt := {
		"schema_version": RECEIPT_VERSION,
		"receipt_id": "AMX-%06d" % _receipt_sequence,
		"utc": Time.get_datetime_string_from_system(true),
		"scenario_key": _scenario_key,
		"elapsed_seconds": snapped(_elapsed_seconds, 0.01),
		"action": action,
		"status": status,
		"detail": detail.duplicate(true),
		"existing_policy_modified": false,
		"production_authority": false,
	}
	_receipts.append(receipt)
	while _receipts.size() > MAX_RECEIPTS:
		_receipts.pop_front()
	realism_receipt_emitted.emit(receipt.duplicate(true))
	return receipt.duplicate(true)

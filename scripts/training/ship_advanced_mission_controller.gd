extends Node
class_name ShipAdvancedMissionController

## Runtime task-map controller for berthing and COLREG encounter benchmarks.
##
## The controller creates deterministic target traffic and computes observable
## mission gates. It never commands the own ship and never changes an RL policy.

signal advanced_mission_changed(snapshot: Dictionary)
signal advanced_mission_receipt_emitted(receipt: Dictionary)

const SCHEMA_VERSION := "ship_advanced_mission_runtime_v1"
const KNOTS_PER_MPS := 1.943844
const REFRESH_INTERVAL_SECONDS := 0.20
const MAX_RECEIPTS := 256
const SHIP_Y := -140.73494

@export var scenario_controller_path: NodePath = NodePath("../ShipScenarioController")
@export var fleet_manager_path: NodePath = NodePath("../ShipFleetManager")
@export var route_system_path: NodePath = NodePath("../ShipRouteSystem")

var _scenario_controller: Node
var _fleet_manager: Node
var _route_system: Node
var _traffic_ships: Array[Node3D] = []
var _traffic_definitions: Array[Dictionary] = []
var _scenario_key := ""
var _scenario: Dictionary = {}
var _task_type := "route_following"
var _evaluation: Dictionary = {}
var _elapsed_seconds := 0.0
var _refresh_left := 0.0
var _minimum_separation_m := INF
var _initial_heading_degrees := 0.0
var _maximum_heading_change_degrees := 0.0
var _first_substantial_action_s := -1.0
var _first_substantial_action_distance_m := INF
var _first_substantial_action_tcpa_s := INF
var _first_substantial_action_side := "NONE"
var _lane_sample_count := 0
var _lane_compliant_sample_count := 0
var _closest_track_relation_distance_m := INF
var _closest_track_relation := "UNOBSERVED"
var _overtaking_ever_ahead := false
var _overtaking_agreement_confirmed := false
var _overtaking_agreement_authorizer := ""
var _receipts: Array[Dictionary] = []
var _receipt_sequence := 0
var _snapshot: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"ship_advanced_mission_controller")
	_resolve_components()
	if _scenario_controller != null and _scenario_controller.has_signal("scenario_changed"):
		_scenario_controller.connect("scenario_changed", _on_scenario_changed)
	call_deferred("_activate_current_scenario")
	set_process(true)


func _exit_tree() -> void:
	_clear_mission_traffic()


func _process(delta: float) -> void:
	if get_tree().paused:
		return
	_elapsed_seconds += maxf(delta, 0.0)
	_refresh_left -= maxf(delta, 0.0)
	if _refresh_left > 0.0:
		return
	_refresh_left = REFRESH_INTERVAL_SECONDS
	_rebuild_snapshot()


func get_advanced_mission_snapshot() -> Dictionary:
	_rebuild_snapshot()
	return _snapshot.duplicate(true)


func get_receipts() -> Array[Dictionary]:
	return _receipts.duplicate(true)


func reset_current_mission() -> Dictionary:
	_resolve_components()
	if _scenario_controller == null or not _scenario_controller.has_method("apply_scenario"):
		return _append_receipt("reset_mission", "REJECTED", {"reason": "SCENARIO_CONTROLLER_UNAVAILABLE"})
	var status := _scenario_controller.call("get_scenario_status") as Dictionary
	_scenario_controller.call("apply_scenario", int(status.get("index", 0)), true)
	return _append_receipt("reset_mission", "ACCEPTED_SIMULATION_ONLY", {"scenario_key": status.get("key", "")})


func confirm_overtaking_agreement(confirmed: bool, authorizer: String) -> Dictionary:
	if _task_type != "overtaking":
		return _append_receipt("confirm_overtaking_agreement", "REJECTED", {"reason": "NOT_OVERTAKING_SCENARIO"})
	if confirmed and authorizer.strip_edges().is_empty():
		return _append_receipt("confirm_overtaking_agreement", "REJECTED", {"reason": "AUTHORIZER_REQUIRED"})
	_overtaking_agreement_confirmed = confirmed
	_overtaking_agreement_authorizer = authorizer.strip_edges() if confirmed else ""
	_rebuild_snapshot()
	return _append_receipt("confirm_overtaking_agreement", "ACCEPTED_SIMULATION_ONLY", {
		"confirmed": _overtaking_agreement_confirmed,
		"authorizer": _overtaking_agreement_authorizer,
		"real_vhf_authority": false,
	})


func _on_scenario_changed(_status: Dictionary) -> void:
	_activate_current_scenario()


func _activate_current_scenario() -> void:
	_resolve_components()
	_clear_mission_traffic()
	_elapsed_seconds = 0.0
	_minimum_separation_m = INF
	_initial_heading_degrees = float(((_scenario_controller.call("get_current_scenario_config") as Dictionary).get("spawn", {}) as Dictionary).get("heading_degrees", 0.0)) \
		if _scenario_controller != null and _scenario_controller.has_method("get_current_scenario_config") else 0.0
	_maximum_heading_change_degrees = 0.0
	_first_substantial_action_s = -1.0
	_first_substantial_action_distance_m = INF
	_first_substantial_action_tcpa_s = INF
	_first_substantial_action_side = "NONE"
	_lane_sample_count = 0
	_lane_compliant_sample_count = 0
	_closest_track_relation_distance_m = INF
	_closest_track_relation = "UNOBSERVED"
	_overtaking_ever_ahead = false
	_overtaking_agreement_confirmed = false
	_overtaking_agreement_authorizer = ""
	_scenario = {}
	if _scenario_controller != null and _scenario_controller.has_method("get_current_scenario_config"):
		_scenario = _scenario_controller.call("get_current_scenario_config") as Dictionary
	var status: Dictionary = {}
	if _scenario_controller != null and _scenario_controller.has_method("get_scenario_status"):
		status = _scenario_controller.call("get_scenario_status") as Dictionary
	_scenario_key = String(status.get("key", "open_water"))
	_task_type = String(_scenario.get("task_type", "route_following"))
	_evaluation = (_scenario.get("evaluation", {}) as Dictionary).duplicate(true)
	_initial_heading_degrees = float((_scenario.get("spawn", {}) as Dictionary).get("heading_degrees", 0.0))
	# Fleet spawning duplicates the currently selected vessel. Preserve and
	# restore the own-ship pose after target creation so a clone's ready-time
	# initialization can never leak its spawn transform into the own ship.
	var controlled := _controlled_ship()
	var own_position := controlled.global_position if controlled != null else Vector3.ZERO
	var own_heading := float(_telemetry(controlled).get("heading_degrees", 0.0))
	for raw_definition in _scenario.get("traffic", []) as Array:
		if raw_definition is Dictionary:
			_spawn_traffic_ship(raw_definition as Dictionary)
	if controlled != null and not _traffic_ships.is_empty() and controlled.has_method("set_ship_navigation_spawn"):
		controlled.call("set_ship_navigation_spawn", own_position, own_heading)
	if controlled != null and _fleet_manager != null and _fleet_manager.has_method("select_ship"):
		_fleet_manager.call("select_ship", controlled)
	_rebuild_snapshot()
	_append_receipt("activate_scenario", "ACCEPTED_SIMULATION_ONLY", {
		"scenario_key": _scenario_key,
		"task_type": _task_type,
		"traffic_count": _traffic_ships.size(),
		"own_ship_commanded": false,
	})


func _spawn_traffic_ship(definition: Dictionary) -> void:
	if _fleet_manager == null or not _fleet_manager.has_method("spawn_ship_at"):
		return
	var spawn := definition.get("spawn", {}) as Dictionary
	var position := Vector3(
		float(spawn.get("x", 0.0)),
		SHIP_Y,
		float(spawn.get("z", 0.0))
	)
	var ship_variant: Variant = _fleet_manager.call("spawn_ship_at", position, {})
	if not (ship_variant is Node3D):
		return
	var ship := ship_variant as Node3D
	# A duplicated CharacterBody enters the physics server at its source pose
	# before its target transform is synchronized. Temporarily removing its
	# collision prevents the own ship from being carried by that one-frame spawn
	# displacement. Collision is restored after the target pose is committed.
	var collision_layer := 0
	var collision_mask := 0
	if ship is CollisionObject3D:
		var collision_ship := ship as CollisionObject3D
		collision_layer = collision_ship.collision_layer
		collision_mask = collision_ship.collision_mask
		collision_ship.collision_layer = 0
		collision_ship.collision_mask = 0
	ship.name = "MissionTraffic_%s" % String(definition.get("id", _traffic_ships.size() + 1))
	ship.add_to_group(&"ship_advanced_mission_traffic")
	if ship.has_method("set_ship_navigation_spawn"):
		ship.call("set_ship_navigation_spawn", position, float(spawn.get("heading_degrees", 0.0)))
	if ship.has_method("set_ship_agent_command"):
		ship.call(
			"set_ship_agent_command",
			float(definition.get("throttle", 0.25)),
			float(definition.get("rudder", 0.0))
		)
	_traffic_ships.append(ship)
	_traffic_definitions.append(definition.duplicate(true))
	if ship is CollisionObject3D:
		_arm_traffic_collision_after_physics(ship as CollisionObject3D, collision_layer, collision_mask)


func _arm_traffic_collision_after_physics(ship: CollisionObject3D, collision_layer: int, collision_mask: int) -> void:
	await get_tree().physics_frame
	if ship == null or not is_instance_valid(ship) or not _traffic_ships.has(ship):
		return
	ship.collision_layer = collision_layer
	ship.collision_mask = collision_mask


func _clear_mission_traffic() -> void:
	for ship in _traffic_ships:
		if ship != null and is_instance_valid(ship):
			if ship.has_method("clear_ship_agent_command"):
				ship.call("clear_ship_agent_command")
			ship.queue_free()
	_traffic_ships.clear()
	_traffic_definitions.clear()


func _rebuild_snapshot() -> void:
	var own := _controlled_ship()
	var own_telemetry := _telemetry(own)
	var traffic_metrics: Array[Dictionary] = []
	var nearest_distance := INF
	var nearest_tcpa := float(_evaluation.get("tcpa_horizon_seconds", 180.0))
	var nearest_dcpa := INF
	for index in range(_traffic_ships.size()):
		var traffic := _traffic_ships[index]
		if traffic == null or not is_instance_valid(traffic) or own == null:
			continue
		var definition := _traffic_definitions[index] if index < _traffic_definitions.size() else {}
		var traffic_telemetry := _telemetry(traffic)
		var relative := _relative_motion(own, own_telemetry, traffic, traffic_telemetry)
		var own_along_traffic_track := _own_along_traffic_track(own, traffic, traffic_telemetry)
		traffic_metrics.append({
			"id": String(definition.get("id", traffic.name)),
			"role": String(definition.get("role", "traffic")),
			"distance_m": relative["distance_m"],
			"tcpa_s": relative["tcpa_s"],
			"dcpa_m": relative["dcpa_m"],
			"speed_knots": absf(float(traffic_telemetry.get("speed", 0.0))) * KNOTS_PER_MPS,
			"external_agent_control_enabled": bool(traffic_telemetry.get("external_agent_control_enabled", false)),
			"collision_layer": traffic.collision_layer if traffic is CollisionObject3D else 0,
			"position": {"x": traffic.global_position.x, "z": traffic.global_position.z},
			"own_along_traffic_track_m": own_along_traffic_track,
		})
		if float(relative["distance_m"]) < nearest_distance:
			nearest_distance = float(relative["distance_m"])
			nearest_tcpa = float(relative["tcpa_s"])
			nearest_dcpa = float(relative["dcpa_m"])
		if _task_type == "crossing_give_way" and float(relative["distance_m"]) < _closest_track_relation_distance_m:
			_closest_track_relation_distance_m = float(relative["distance_m"])
			_closest_track_relation = "ASTERN" if own_along_traffic_track < 0.0 else "AHEAD"
		if _task_type == "overtaking" and own_along_traffic_track > 5.7:
			_overtaking_ever_ahead = true
	if nearest_distance < INF:
		_minimum_separation_m = minf(_minimum_separation_m, nearest_distance)
	var heading_change := _signed_heading_delta_degrees(float(own_telemetry.get("heading_degrees", _initial_heading_degrees)), _initial_heading_degrees)
	_maximum_heading_change_degrees = maxf(_maximum_heading_change_degrees, absf(heading_change))
	if _first_substantial_action_s < 0.0 and absf(heading_change) >= 10.0 and nearest_distance < INF:
		_first_substantial_action_s = _elapsed_seconds
		_first_substantial_action_distance_m = nearest_distance
		_first_substantial_action_tcpa_s = nearest_tcpa
		_first_substantial_action_side = "STARBOARD" if heading_change > 0.0 else "PORT"
	if _task_type == "head_on" and own != null:
		_lane_sample_count += 1
		if own.global_position.x <= 0.0:
			_lane_compliant_sample_count += 1
	var gate := _mission_gate(own, own_telemetry)
	var behavioral := _behavioral_assessment(gate)
	_snapshot = {
		"schema_version": SCHEMA_VERSION,
		"scenario_key": _scenario_key,
		"scenario_name": String(_scenario.get("name", _scenario_key)),
		"task_type": _task_type,
		"elapsed_seconds": snapped(_elapsed_seconds, 0.01),
		"colreg_rule_ids": (_scenario.get("colreg_rule_ids", []) as Array).duplicate(),
		"traffic_count": traffic_metrics.size(),
		"traffic": traffic_metrics,
		"nearest_distance_m": nearest_distance if nearest_distance < INF else null,
		"nearest_tcpa_s": nearest_tcpa if nearest_distance < INF else null,
		"nearest_dcpa_m": nearest_dcpa if nearest_dcpa < INF else null,
		"minimum_observed_separation_m": _minimum_separation_m if _minimum_separation_m < INF else null,
		"own_ship": {
			"position": {"x": own.global_position.x, "z": own.global_position.z} if own != null else {},
			"heading_degrees": own_telemetry.get("heading_degrees"),
			"speed_knots": absf(float(own_telemetry.get("speed", 0.0))) * KNOTS_PER_MPS,
			"sway_mps": float(own_telemetry.get("sway_mps", 0.0)),
			"collision_warning": String(own_telemetry.get("collision_warning", "CLEAR")),
		},
		"evaluation": _evaluation.duplicate(true),
		"gate": gate,
		"behavioral_assessment": behavioral,
		"own_ship_commanded_by_controller": false,
		"traffic_uses_deterministic_simulator_commands": true,
		"overtaking_agreement_confirmed": _overtaking_agreement_confirmed,
		"overtaking_agreement_authorizer": _overtaking_agreement_authorizer,
		"existing_policy_modified": false,
		"production_authority": false,
		"claim_boundary": String(_scenario.get("claim_boundary", "Simulation and training only.")),
	}
	advanced_mission_changed.emit(_snapshot.duplicate(true))


func _mission_gate(own: Node3D, telemetry: Dictionary) -> Dictionary:
	if own == null:
		return {"status": "BLOCKED", "passed": false, "reason": "OWN_SHIP_UNAVAILABLE"}
	var collision_free := float(telemetry.get("last_impact_speed", 0.0)) <= 0.0
	match _task_type:
		"berthing":
			var target := _evaluation.get("berth_target", {}) as Dictionary
			var distance := Vector2(
				own.global_position.x - float(target.get("x", 0.0)),
				own.global_position.z - float(target.get("z", 0.0))
			).length()
			var heading_error := _heading_error_degrees(
				float(telemetry.get("heading_degrees", 0.0)),
				float(target.get("heading_degrees", 0.0))
			)
			var speed_knots := absf(float(telemetry.get("speed", 0.0))) * KNOTS_PER_MPS
			var sway := absf(float(telemetry.get("sway_mps", 0.0)))
			var passed := (
				distance <= float(_evaluation.get("position_tolerance_m", 7.0))
				and heading_error <= float(_evaluation.get("heading_tolerance_degrees", 8.0))
				and speed_knots <= float(_evaluation.get("maximum_speed_knots", 0.8))
				and sway <= float(_evaluation.get("maximum_sway_mps", 0.25))
				and collision_free
			)
			return {
				"status": "PASS" if passed else "ACTIVE",
				"passed": passed,
				"berth_distance_m": distance,
				"heading_error_degrees": heading_error,
				"speed_knots": speed_knots,
				"sway_mps": sway,
				"collision_free": collision_free,
			}
		"unberthing":
			var origin := _evaluation.get("berth_origin", {}) as Dictionary
			var clear_distance := Vector2(
				own.global_position.x - float(origin.get("x", 0.0)),
				own.global_position.z - float(origin.get("z", 0.0))
			).length()
			var exit_speed := absf(float(telemetry.get("speed", 0.0))) * KNOTS_PER_MPS
			var passed := (
				clear_distance >= float(_evaluation.get("minimum_clear_distance_m", 110.0))
				and exit_speed <= float(_evaluation.get("maximum_exit_speed_knots", 5.0))
				and collision_free
			)
			return {
				"status": "PASS" if passed else "ACTIVE",
				"passed": passed,
				"clear_distance_m": clear_distance,
				"speed_knots": exit_speed,
				"collision_free": collision_free,
			}
		"head_on", "crossing_give_way", "overtaking":
			var required_distance := float(_evaluation.get("minimum_passing_distance_m", 20.0))
			var observed := _minimum_separation_m if _minimum_separation_m < INF else 9999.0
			var route_complete := _route_complete(own.global_position)
			var safety_satisfied := observed >= required_distance and collision_free
			var agreement_required := bool(_evaluation.get("overtaking_agreement_required", false))
			var agreement_satisfied := not agreement_required or _overtaking_agreement_confirmed
			var passed := route_complete and safety_satisfied and agreement_satisfied
			return {
				"status": "PASS" if passed else ("ACTIVE" if safety_satisfied and agreement_satisfied else "FAIL"),
				"passed": passed,
				"route_complete": route_complete,
				"minimum_passing_distance_m": observed,
				"required_passing_distance_m": required_distance,
				"collision_free": collision_free,
				"overtaking_agreement_required": agreement_required,
				"overtaking_agreement_confirmed": _overtaking_agreement_confirmed,
				"overtaking_agreement_authorizer": _overtaking_agreement_authorizer,
				"expected_passing": String(_evaluation.get("expected_passing", "")),
			}
		_:
			return {"status": "MONITOR", "passed": false, "reason": "NO_ADVANCED_GATE_FOR_BASE_SCENARIO"}


func _relative_motion(own: Node3D, own_telemetry: Dictionary, traffic: Node3D, traffic_telemetry: Dictionary) -> Dictionary:
	var relative_position := Vector2(
		traffic.global_position.x - own.global_position.x,
		traffic.global_position.z - own.global_position.z
	)
	var own_velocity := _velocity_from_telemetry(own_telemetry)
	var traffic_velocity := _velocity_from_telemetry(traffic_telemetry)
	var relative_velocity := traffic_velocity - own_velocity
	var horizon := float(_evaluation.get("tcpa_horizon_seconds", 180.0))
	var speed_squared := relative_velocity.length_squared()
	var raw_tcpa := -relative_position.dot(relative_velocity) / speed_squared if speed_squared > 0.000001 else horizon
	var tcpa := clampf(raw_tcpa, 0.0, horizon) if raw_tcpa > 0.0 else horizon
	var dcpa := (relative_position + relative_velocity * tcpa).length()
	return {"distance_m": relative_position.length(), "tcpa_s": tcpa, "dcpa_m": dcpa}


func _own_along_traffic_track(own: Node3D, traffic: Node3D, traffic_telemetry: Dictionary) -> float:
	var heading := deg_to_rad(float(traffic_telemetry.get("heading_degrees", 0.0)))
	var traffic_forward := Vector2(sin(heading), cos(heading))
	var relative_own := Vector2(own.global_position.x - traffic.global_position.x, own.global_position.z - traffic.global_position.z)
	return relative_own.dot(traffic_forward)


func _behavioral_assessment(gate: Dictionary) -> Dictionary:
	var lane_ratio := float(_lane_compliant_sample_count) / float(_lane_sample_count) if _lane_sample_count > 0 else 1.0
	var early_action := _first_substantial_action_s >= 0.0 \
		and _first_substantial_action_distance_m >= 60.0 \
		and _first_substantial_action_tcpa_s >= 20.0
	var passed := bool(gate.get("passed", false))
	var criteria := {}
	match _task_type:
		"head_on":
			criteria = {
				"early_substantial_action": early_action,
				"action_side_starboard": _first_substantial_action_side == "STARBOARD",
				"starboard_lane_ratio": lane_ratio,
				"starboard_lane_compliant": lane_ratio >= 0.90,
			}
			passed = passed and early_action and _first_substantial_action_side == "STARBOARD" and lane_ratio >= 0.90
		"crossing_give_way":
			criteria = {
				"early_substantial_action": early_action,
				"action_side_starboard": _first_substantial_action_side == "STARBOARD",
				"closest_track_relation": _closest_track_relation,
				"passed_astern": _closest_track_relation == "ASTERN",
			}
			passed = passed and early_action and _first_substantial_action_side == "STARBOARD" and _closest_track_relation == "ASTERN"
		"overtaking":
			criteria = {
				"agreement_confirmed": _overtaking_agreement_confirmed,
				"overtaking_vessel_passed_ahead": _overtaking_ever_ahead,
			}
			passed = passed and _overtaking_agreement_confirmed and _overtaking_ever_ahead
		_:
			criteria = {"task_gate_passed": bool(gate.get("passed", false))}
	return {
		"status": "PASS" if passed else "NOT_YET_PASS",
		"passed": passed,
		"initial_heading_degrees": _initial_heading_degrees,
		"maximum_heading_change_degrees": _maximum_heading_change_degrees,
		"first_substantial_action_s": null if _first_substantial_action_s < 0.0 else _first_substantial_action_s,
		"first_substantial_action_distance_m": null if _first_substantial_action_distance_m == INF else _first_substantial_action_distance_m,
		"first_substantial_action_tcpa_s": null if _first_substantial_action_tcpa_s == INF else _first_substantial_action_tcpa_s,
		"first_substantial_action_side": _first_substantial_action_side,
		"criteria": criteria,
		"test_only_waypoint_traversal_is_not_behavioral_evidence": true,
	}


func _velocity_from_telemetry(telemetry: Dictionary) -> Vector2:
	var heading := deg_to_rad(float(telemetry.get("heading_degrees", 0.0)))
	var speed := float(telemetry.get("speed", 0.0))
	return Vector2(sin(heading) * speed, cos(heading) * speed)


func _route_complete(position: Vector3) -> bool:
	if _route_system == null or not is_instance_valid(_route_system):
		_resolve_components()
	if _route_system != null and _route_system.has_method("get_route_telemetry"):
		var telemetry := _route_system.call("get_route_telemetry", position) as Dictionary
		return not bool(telemetry.get("active", true))
	return false


func _controlled_ship() -> Node3D:
	if _fleet_manager == null or not is_instance_valid(_fleet_manager):
		_resolve_components()
	if _fleet_manager != null and _fleet_manager.has_method("get_controlled_ship"):
		var ship_variant: Variant = _fleet_manager.call("get_controlled_ship")
		if ship_variant is Node3D and is_instance_valid(ship_variant):
			return ship_variant as Node3D
	return get_tree().get_first_node_in_group(&"player") as Node3D


func _telemetry(ship: Node3D) -> Dictionary:
	if ship != null and is_instance_valid(ship) and ship.has_method("get_ship_telemetry"):
		return ship.call("get_ship_telemetry") as Dictionary
	return {}


func _heading_error_degrees(actual: float, target: float) -> float:
	return absf(fposmod(actual - target + 180.0, 360.0) - 180.0)


func _signed_heading_delta_degrees(actual: float, initial: float) -> float:
	return fposmod(actual - initial + 180.0, 360.0) - 180.0


func _resolve_components() -> void:
	_scenario_controller = _resolve(_scenario_controller, scenario_controller_path, &"ship_scenario_system")
	_fleet_manager = _resolve(_fleet_manager, fleet_manager_path, &"ship_fleet_manager")
	_route_system = _resolve(_route_system, route_system_path, &"ship_route_system")


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
		"schema_version": "ship_advanced_mission_receipt_v1",
		"receipt_id": "AMR-%06d" % _receipt_sequence,
		"utc": Time.get_datetime_string_from_system(true),
		"action": action,
		"status": status,
		"detail": detail.duplicate(true),
		"existing_policy_modified": false,
		"production_authority": false,
	}
	_receipts.append(receipt)
	while _receipts.size() > MAX_RECEIPTS:
		_receipts.pop_front()
	advanced_mission_receipt_emitted.emit(receipt.duplicate(true))
	return receipt.duplicate(true)

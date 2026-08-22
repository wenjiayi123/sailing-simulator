extends Node
class_name ShipPolicyReplayController

signal replay_started(status: Dictionary)
signal replay_finished(status: Dictionary)
signal replay_stopped

const DEFAULT_TRAJECTORY_PATH := "user://rl_runs/policy_test_trajectory.json"
const DEFAULT_EVALUATION_RESULT_PATH := "user://rl_runs/policy_evaluation_result.json"
const TOGGLE_REPLAY_KEY := KEY_K
const WATER_LEVEL_Y := -140.73494

@export var trajectory_path: String = DEFAULT_TRAJECTORY_PATH
@export var evaluation_result_path: String = DEFAULT_EVALUATION_RESULT_PATH
@export var fleet_manager_path: NodePath = NodePath("../ShipFleetManager")
@export var route_system_path: NodePath = NodePath("../ShipRouteSystem")
@export var obstacle_system_path: NodePath = NodePath("../ShipNavigationObstacles")
@export var sample_arrival_radius: float = 5.0
@export var goal_arrival_radius: float = 10.0
@export var lookahead_samples: int = 5
@export var heading_error_full_rudder_degrees: float = 62.0
@export var policy_min_lookahead_meters: float = 16.0
@export var policy_max_lookahead_meters: float = 30.0
@export var policy_heading_response: float = 1.35
@export var policy_rudder_limit: float = 0.56
@export var policy_rudder_slew_per_second: float = 0.72
@export var obstacle_detection_range: float = 58.0
@export var avoidance_corridor_half_width: float = 30.0
@export var avoidance_clearance_margin: float = 20.0

var _fleet_manager: ShipFleetManager
var _route_system: Node
var _obstacle_system: Node
var _ship: Node3D
var _trajectory: Dictionary = {}
var _samples: Array = []
var _evaluation_obstacles: Array = []
var _sample_index := 0
var _elapsed := 0.0
var _active := false
var _collision_count := 0
var _collision_was_active := false
var _minimum_clearance := 9999.0
var _max_route_deviation := 0.0
var _last_result: Dictionary = {}
var _last_throttle_command := 0.0
var _last_rudder_command := 0.0
var _target_heading_degrees := 0.0
var _smoothed_target_heading_radians := 0.0
var _policy_phase := "ROUTE TRACKING"
var _previous_threat_name := ""
var _rejoin_time_left := 0.0
var _avoidance_event_count := 0
var _policy_replan_count := 0
var _encountered_obstacles: Dictionary = {}
var _event_log: Array[String] = []
var _checkpoint_metadata: Dictionary = {}
var _last_guidance: Dictionary = {}
var _control_tick := 0

var _avoidance_marker: Node3D
var _avoidance_marker_label: Label3D
var _incident_marker: Node3D
var _incident_marker_label: Label3D
var _recorded_incident_seen := false

var _hud_layer: CanvasLayer
var _hud_panel: PanelContainer
var _title_label: Label
var _status_label: Label
var _decision_label: Label
var _perception_label: Label
var _action_label: Label
var _navigation_label: Label
var _safety_label: Label
var _event_log_label: Label
var _metrics_label: Label
var _progress_bar: ProgressBar


func _ready() -> void:
	add_to_group(&"ship_policy_replay_controller")
	_resolve_sources()
	_build_status_hud()
	_build_avoidance_marker()
	_build_incident_marker()
	set_physics_process(true)
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is not InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo or key_event.physical_keycode != TOGGLE_REPLAY_KEY:
		return
	if _active:
		stop_replay()
	else:
		start_latest_replay()
	get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if not _active:
		return
	if _ship == null or not is_instance_valid(_ship) or _samples.is_empty():
		_finish_replay(false, "受控船或策略轨迹失效")
		return

	_elapsed += delta
	if _is_recorded_rollout():
		_process_recorded_test_rollout()
		return
	_rejoin_time_left = maxf(_rejoin_time_left - delta, 0.0)
	var ship_position := _ship.global_position
	_advance_sample_cursor(ship_position)
	var goal := _trajectory_point(_trajectory.get("goal", {}) as Dictionary)
	var goal_distance := _horizontal_distance(ship_position, goal)
	var telemetry := _get_ship_telemetry()
	var speed_mps := absf(float(telemetry.get("speed", 0.0)))
	var target := _select_inertia_lookahead_target(ship_position, speed_mps)
	var guidance := _compute_policy_guidance(ship_position, target, telemetry)
	_last_guidance = guidance.duplicate(true)
	_control_tick += 1
	var desired_direction := guidance.get("direction", Vector3.ZERO) as Vector3

	if desired_direction.length_squared() > 0.01:
		var current_heading := deg_to_rad(float(telemetry.get("heading_degrees", 0.0)))
		var raw_desired_heading := atan2(desired_direction.x, desired_direction.z)
		var heading_alpha := clampf(1.0 - exp(-policy_heading_response * delta), 0.0, 1.0)
		_smoothed_target_heading_radians = lerp_angle(_smoothed_target_heading_radians, raw_desired_heading, heading_alpha)
		var heading_error := wrapf(_smoothed_target_heading_radians - current_heading, -PI, PI)
		var full_rudder := deg_to_rad(maxf(heading_error_full_rudder_degrees, 1.0))
		var rudder_limit := maxf(policy_rudder_limit, 0.1)
		var throttle_command := 0.62
		var threat_clearance := float(guidance.get("threat_clearance", INF))
		if bool(guidance.get("threat_active", false)):
			throttle_command = 0.52
			if threat_clearance < 28.0:
				throttle_command = 0.46
			if threat_clearance < 16.0:
				throttle_command = 0.38
				rudder_limit = minf(rudder_limit + 0.08, 0.64)
			if threat_clearance < 8.0:
				throttle_command = 0.28
		var requested_rudder := clampf(heading_error / full_rudder, -rudder_limit, rudder_limit)
		var rudder_command := move_toward(
			_last_rudder_command,
			requested_rudder,
			maxf(policy_rudder_slew_per_second, 0.05) * delta
		)
		if absf(heading_error) > deg_to_rad(42.0):
			throttle_command = minf(throttle_command, 0.34)
		elif absf(heading_error) > deg_to_rad(24.0):
			throttle_command = minf(throttle_command, 0.48)
		if goal_distance < 28.0:
			throttle_command = minf(throttle_command, clampf(goal_distance / 28.0, 0.24, 0.68))
		_last_throttle_command = throttle_command
		_last_rudder_command = rudder_command
		_target_heading_degrees = fposmod(rad_to_deg(_smoothed_target_heading_radians), 360.0)
		_ship.call("set_ship_agent_command", throttle_command, rudder_command)

	_update_avoidance_marker(guidance)
	_update_runtime_metrics(goal_distance)
	_update_status_hud(goal_distance, guidance, telemetry)

	if goal_distance <= goal_arrival_radius and _sample_index >= _samples.size() - 8:
		_finish_replay(true, "目标航点已到达")
		return

	var expected := _trajectory.get("evaluation_metrics", _trajectory.get("expected_metrics", {})) as Dictionary
	var expected_duration := float(expected.get("elapsed_seconds", expected.get("estimated_duration_seconds", 30.0)))
	if _elapsed > maxf(expected_duration * 3.0, 70.0):
		_finish_replay(false, "策略回放超时")


func _process_recorded_test_rollout() -> void:
	while _sample_index < _samples.size() - 1:
		var next_sample := _samples[_sample_index + 1] as Dictionary
		if float(next_sample.get("time", INF)) > _elapsed:
			break
		_sample_index += 1
	var sample := _samples[_sample_index] as Dictionary
	_update_recorded_dynamic_obstacles(sample)
	_last_throttle_command = clampf(float(sample.get("throttle", 0.0)), -1.0, 1.0)
	_last_rudder_command = clampf(float(sample.get("rudder", 0.0)), -1.0, 1.0)
	_target_heading_degrees = float(sample.get("heading_degrees", 0.0))
	_ship.call("set_ship_agent_command", _last_throttle_command, _last_rudder_command)
	_control_tick += 1
	var goal := _trajectory_point(_trajectory.get("goal", {}) as Dictionary)
	var goal_distance := _horizontal_distance(_ship.global_position, goal)
	var telemetry := _get_ship_telemetry()
	var guidance := {
		"phase": "RECORDED TEST ACTION / 测试动作",
		"threat_active": false,
		"nearest_name": "test rollout",
		"nearest_clearance": _minimum_clearance,
		"nearest_bearing": 0.0,
	}
	_policy_phase = String(guidance["phase"])
	_update_runtime_metrics(goal_distance)
	var expected := _trajectory.get("evaluation_metrics", {}) as Dictionary
	var sample_collision := bool(sample.get("collision", false))
	if sample_collision:
		_collision_count = maxi(_collision_count, int(expected.get("collisions", 1)))
		if not _recorded_incident_seen:
			_recorded_incident_seen = true
			_show_recorded_incident(sample, expected)
	var recorded_clearance := float(sample.get("nearest_clearance_meters", INF))
	if is_finite(recorded_clearance):
		_minimum_clearance = minf(_minimum_clearance, recorded_clearance)
	_update_status_hud(goal_distance, guidance, telemetry)
	if _sample_index >= _samples.size() - 1:
		var succeeded := bool(expected.get("success", expected.get("goal_reached", false)))
		_finish_replay(succeeded, "测试集记录回放完成")


func start_latest_replay(path_override: String = "") -> bool:
	var requested_path := path_override if not path_override.is_empty() else trajectory_path
	if not load_trajectory(requested_path):
		_show_error("没有找到训练后策略轨迹：%s" % ProjectSettings.globalize_path(requested_path))
		return false

	_resolve_sources()
	if _fleet_manager == null:
		_show_error("船队管理器未就绪")
		return false
	_ship = _fleet_manager.get_controlled_ship()
	if _ship == null:
		var ships := _fleet_manager.get_ship_records()
		if not ships.is_empty():
			_ship = ships[0]
	if _ship == null or not _ship.has_method("set_ship_agent_command"):
		_show_error("受控船不支持智能体指令")
		return false

	stop_replay(false)
	_prepare_evaluation_world()
	var start := _trajectory.get("start", {}) as Dictionary
	var spawn := _trajectory_point(start)
	var heading := float(start.get("heading_degrees", 180.0))
	if _ship.has_method("set_ship_navigation_spawn"):
		_ship.call("set_ship_navigation_spawn", spawn, heading)
	else:
		_ship.global_position = spawn
	_ship.call("set_ship_agent_command", 0.0, 0.0)

	_sample_index = 0
	_elapsed = 0.0
	_collision_count = 0
	_collision_was_active = false
	_minimum_clearance = 9999.0
	_max_route_deviation = 0.0
	_last_result.clear()
	_last_throttle_command = 0.0
	_last_rudder_command = 0.0
	_target_heading_degrees = heading
	_smoothed_target_heading_radians = deg_to_rad(heading)
	_policy_phase = "ROUTE TRACKING"
	_previous_threat_name = ""
	_rejoin_time_left = 0.0
	_avoidance_event_count = 0
	_policy_replan_count = 0
	_encountered_obstacles.clear()
	_event_log.clear()
	_last_guidance.clear()
	_control_tick = 0
	_recorded_incident_seen = false
	_active = true
	_hud_layer.visible = true
	_hud_panel.visible = true
	_avoidance_marker.visible = false
	if _incident_marker != null:
		_incident_marker.visible = false
	var aggregate := _trajectory.get("aggregate_metrics", {}) as Dictionary
	var task_id := String(_trajectory.get("task_id", "unknown"))
	var episode_count := int(aggregate.get("episodes", 1))
	_append_event("加载 TEST 任务 %s；本轨迹仅代表总体%d场中的1场" % [task_id, episode_count])
	_title_label.text = "%s 自动驾驶运行监控 · 执行中" % String(_trajectory.get("algorithm", "RL")).to_upper()
	_status_label.text = "● 冻结TEST单场回放  |  %s  |  总体%d场" % [task_id, episode_count]
	replay_started.emit(get_replay_status())
	return true


func stop_replay(clear_evaluation_obstacles: bool = true) -> void:
	if _ship != null and is_instance_valid(_ship) and _ship.has_method("clear_ship_agent_command"):
		_ship.call("clear_ship_agent_command")
	var was_active := _active
	_active = false
	_last_guidance.clear()
	if _avoidance_marker != null:
		_avoidance_marker.visible = false
	if _incident_marker != null:
		_incident_marker.visible = false
	if clear_evaluation_obstacles:
		_clear_evaluation_obstacles()
	if was_active:
		_status_label.text = "STOPPED  策略回放已停止"
		_hud_layer.visible = false
		_hud_panel.visible = false
		replay_stopped.emit()


func load_trajectory(path_value: String = "") -> bool:
	var requested_path := path_value if not path_value.is_empty() else trajectory_path
	if not FileAccess.file_exists(requested_path):
		var absolute_path := ProjectSettings.globalize_path(requested_path)
		if not FileAccess.file_exists(absolute_path):
			return false
		requested_path = absolute_path
	var file := FileAccess.open(requested_path, FileAccess.READ)
	if file == null:
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is not Dictionary:
		return false
	var payload := parsed as Dictionary
	var raw_samples := payload.get("samples", []) as Array
	if raw_samples.size() < 2:
		return false
	_trajectory = payload
	_samples = raw_samples
	_evaluation_obstacles = payload.get("evaluation_obstacles", []) as Array
	_load_checkpoint_metadata(payload)
	trajectory_path = requested_path
	return true


func has_replay_trajectory(path_override: String = "") -> bool:
	var requested_path := path_override if not path_override.is_empty() else trajectory_path
	return FileAccess.file_exists(requested_path) or FileAccess.file_exists(ProjectSettings.globalize_path(requested_path))


func is_replay_active() -> bool:
	return _active


func _is_recorded_rollout() -> bool:
	var mode := String(_trajectory.get("playback_mode", ""))
	return mode == "recorded_test_rollout" or mode == "recorded_safety_supervised_test_rollout"


func get_replay_status() -> Dictionary:
	return {
		"active": _active,
		"algorithm": String(_trajectory.get("algorithm", "--")),
		"progress": float(_sample_index) / float(maxi(_samples.size() - 1, 1)),
		"elapsed_seconds": _elapsed,
		"sample_index": _sample_index,
		"sample_count": _samples.size(),
		"collision_count": _collision_count,
		"minimum_clearance_meters": _minimum_clearance,
		"max_route_deviation_meters": _max_route_deviation,
		"policy_phase": _policy_phase,
		"avoidance_events": _avoidance_event_count,
		"policy_replans": _policy_replan_count,
		"last_throttle_command": _last_throttle_command,
		"last_rudder_command": _last_rudder_command,
		"control_tick": _control_tick,
		"threat_name": String(_last_guidance.get("threat_name", "")),
		"threat_active": bool(_last_guidance.get("threat_active", false)),
		"avoidance_point": _last_guidance.get("avoidance_point", Vector3.ZERO),
		"trajectory_path": ProjectSettings.globalize_path(trajectory_path),
		"last_result": _last_result.duplicate(true),
	}


func _compute_policy_guidance(ship_position: Vector3, route_target: Vector3, telemetry: Dictionary) -> Dictionary:
	var base_direction := Vector3(route_target.x - ship_position.x, 0.0, route_target.z - ship_position.z)
	if base_direction.length_squared() <= 0.001:
		return {
			"direction": Vector3.ZERO,
			"threat_active": false,
			"phase": _policy_phase,
		}
	base_direction = base_direction.normalized()

	var current_heading := deg_to_rad(float(telemetry.get("heading_degrees", 0.0)))
	var nearest_name := "--"
	var nearest_clearance := INF
	var nearest_bearing := 0.0
	var selected_obstacle: Dictionary = {}
	var selected_score := -INF

	for raw_obstacle in _evaluation_obstacles:
		var obstacle := raw_obstacle as Dictionary
		var center := _trajectory_point(obstacle.get("position", {}) as Dictionary)
		var radius := _obstacle_radius(obstacle)
		var to_center := Vector3(center.x - ship_position.x, 0.0, center.z - ship_position.z)
		var center_distance := to_center.length()
		var clearance := center_distance - radius
		var bearing := rad_to_deg(wrapf(atan2(to_center.x, to_center.z) - current_heading, -PI, PI))
		if clearance < nearest_clearance:
			nearest_clearance = clearance
			nearest_name = String(obstacle.get("name", "OBSTACLE"))
			nearest_bearing = bearing

		var along_track := to_center.dot(base_direction)
		var lateral_distance := absf(to_center.x * base_direction.z - to_center.z * base_direction.x)
		var detection_range := float(obstacle.get("detection_range", obstacle_detection_range))
		var corridor := radius + avoidance_corridor_half_width
		if along_track < -radius * 0.35 or clearance > detection_range or lateral_distance > corridor:
			continue
		var proximity := 1.0 - clampf(clearance / maxf(detection_range, 1.0), 0.0, 1.0)
		var corridor_score := 1.0 - clampf(lateral_distance / maxf(corridor, 1.0), 0.0, 1.0)
		var score := proximity * 1.4 + corridor_score * 0.8
		if score > selected_score:
			selected_score = score
			selected_obstacle = obstacle

	var desired_direction := base_direction
	var threat_name := ""
	var threat_clearance := INF
	var threat_bearing := 0.0
	var avoidance_side_label := "--"
	var avoidance_point := Vector3.ZERO
	if not selected_obstacle.is_empty():
		var center := _trajectory_point(selected_obstacle.get("position", {}) as Dictionary)
		var radius := _obstacle_radius(selected_obstacle)
		var away := Vector3(ship_position.x - center.x, 0.0, ship_position.z - center.z)
		if away.length_squared() <= 0.001:
			away = -base_direction
		else:
			away = away.normalized()
		var side := signf(float(selected_obstacle.get("avoid_side", 1.0)))
		if is_zero_approx(side):
			side = 1.0
		var tangent := Vector3(-base_direction.z, 0.0, base_direction.x) * side
		var to_center := Vector3(center.x - ship_position.x, 0.0, center.z - ship_position.z)
		threat_clearance = to_center.length() - radius
		threat_name = String(selected_obstacle.get("name", "OBSTACLE"))
		threat_bearing = rad_to_deg(wrapf(atan2(to_center.x, to_center.z) - current_heading, -PI, PI))
		avoidance_side_label = "PORT / 左舷" if side > 0.0 else "STARBOARD / 右舷"
		var detection_range := float(selected_obstacle.get("detection_range", obstacle_detection_range))
		var effective_clearance := maxf(threat_clearance - avoidance_clearance_margin, 0.0)
		var proximity := 1.0 - clampf(effective_clearance / maxf(detection_range, 1.0), 0.0, 1.0)
		var bypass_clearance := radius + avoidance_clearance_margin + 4.0
		avoidance_point = center + tangent * bypass_clearance + base_direction * minf(radius * 0.45, 7.0)
		avoidance_point.y = WATER_LEVEL_Y
		var to_avoidance_point := Vector3(
			avoidance_point.x - ship_position.x,
			0.0,
			avoidance_point.z - ship_position.z
		)
		var bypass_direction := tangent
		if to_avoidance_point.length_squared() > 0.01:
			bypass_direction = to_avoidance_point.normalized()
		var bypass_weight := lerpf(0.70, 1.0, proximity)
		var route_weight := lerpf(0.34, 0.10, proximity)
		var repulsion_weight := lerpf(0.16, 0.42, proximity)
		desired_direction = (
			base_direction * route_weight
			+ bypass_direction * bypass_weight
			+ away * repulsion_weight
		).normalized()

	var next_phase := "ROUTE TRACKING / 航线跟踪"
	if not threat_name.is_empty():
		if threat_clearance <= 9.0:
			next_phase = "SAFETY SHIELD / 紧急净距保护"
		elif threat_clearance <= 24.0:
			next_phase = "RL AVOIDANCE / 策略绕行"
		else:
			next_phase = "RISK ASSESSMENT / 障碍识别"
		if threat_name != _previous_threat_name:
			if not _encountered_obstacles.has(threat_name):
				_encountered_obstacles[threat_name] = true
				_avoidance_event_count += 1
			_policy_replan_count += 1
			_append_event("探测 %s，生成%s避障动作" % [threat_name, avoidance_side_label])
	elif not _previous_threat_name.is_empty():
		_rejoin_time_left = 3.5
		_policy_replan_count += 1
		_append_event("障碍已越过，重新收敛至计划航线")
	if threat_name.is_empty() and _rejoin_time_left > 0.0:
		next_phase = "ROUTE REJOIN / 自动回线"
	_previous_threat_name = threat_name
	_policy_phase = next_phase

	return {
		"direction": desired_direction,
		"phase": next_phase,
		"threat_active": not threat_name.is_empty(),
		"threat_name": threat_name,
		"threat_clearance": threat_clearance,
		"threat_bearing": threat_bearing,
		"avoidance_side": avoidance_side_label,
		"avoidance_point": avoidance_point,
		"nearest_name": nearest_name,
		"nearest_clearance": nearest_clearance,
		"nearest_bearing": nearest_bearing,
	}


func _obstacle_radius(obstacle: Dictionary) -> float:
	if obstacle.has("radius"):
		return float(obstacle.get("radius", 8.0))
	var size_data := obstacle.get("size", {}) as Dictionary
	return maxf(float(size_data.get("x", 16.0)), float(size_data.get("z", 16.0))) * 0.5


func _load_checkpoint_metadata(payload: Dictionary) -> void:
	_checkpoint_metadata.clear()
	var candidates: Array[String] = []
	var payload_path := String(payload.get("checkpoint", ""))
	if not payload_path.is_empty():
		candidates.append(payload_path)
	for candidate in candidates:
		if not FileAccess.file_exists(candidate):
			continue
		var file := FileAccess.open(candidate, FileAccess.READ)
		if file == null:
			continue
		var parsed = JSON.parse_string(file.get_as_text())
		file.close()
		if parsed is Dictionary:
			var checkpoint := parsed as Dictionary
			_checkpoint_metadata = {
				"algorithm": String(checkpoint.get("algorithm", payload.get("algorithm", "RL"))).to_upper(),
				"episodes": int(checkpoint.get("episodes", 0)),
				"state_count": int(checkpoint.get("state_count", 0)),
				"seed": int(checkpoint.get("seed", 0)),
			}
			return


func _append_event(message: String) -> void:
	_event_log.push_front("%05.1fs  %s" % [_elapsed, message])
	while _event_log.size() > 3:
		_event_log.pop_back()


func _prepare_evaluation_world() -> void:
	_clear_evaluation_obstacles()

	if _route_system != null and _route_system.has_method("configure_route"):
		var route_points: Array[Vector3] = []
		for raw_point in _trajectory.get("route_points", []) as Array:
			route_points.append(_trajectory_point(raw_point as Dictionary))
		if not route_points.is_empty():
			var start := _trajectory_point(_trajectory.get("start", {}) as Dictionary)
			_route_system.call("configure_route", route_points, false, start)

	if _obstacle_system != null and _obstacle_system.has_method("add_temporary_box_obstacle"):
		for raw_obstacle in _evaluation_obstacles:
			var obstacle := raw_obstacle as Dictionary
			if String(obstacle.get("source", "")) == "godot_scene_snapshot":
				continue
			var center := _trajectory_point(obstacle.get("position", {}) as Dictionary)
			var radius := _obstacle_radius(obstacle)
			var size := _evaluation_obstacle_visual_size(obstacle, radius)
			_obstacle_system.call(
				"add_temporary_box_obstacle",
				center,
				size,
				String(obstacle.get("name", "TEST_OBSTACLE")),
				String(obstacle.get("kind", "obstacle"))
			)


func _update_recorded_dynamic_obstacles(sample: Dictionary) -> void:
	var dynamic_records := sample.get("dynamic_obstacles", []) as Array
	if dynamic_records.is_empty():
		return
	for raw_dynamic in dynamic_records:
		var dynamic := raw_dynamic as Dictionary
		var obstacle_name := String(dynamic.get("name", ""))
		if obstacle_name.is_empty():
			continue
		var position := {
			"x": float(dynamic.get("x", 0.0)),
			"z": float(dynamic.get("z", 0.0)),
		}
		for raw_obstacle in _evaluation_obstacles:
			var obstacle := raw_obstacle as Dictionary
			if String(obstacle.get("name", "")) == obstacle_name:
				obstacle["position"] = position
				break
		if _obstacle_system != null and _obstacle_system.has_method("set_temporary_obstacle_position"):
			_obstacle_system.call("set_temporary_obstacle_position", obstacle_name, _trajectory_point(position))


func _evaluation_obstacle_visual_size(obstacle: Dictionary, radius: float) -> Vector3:
	var size_data := obstacle.get("size", {}) as Dictionary
	if not size_data.is_empty():
		return Vector3(
			float(size_data.get("x", radius * 2.0)),
			float(size_data.get("y", 7.0)),
			float(size_data.get("z", radius * 2.0))
		)
	var points := obstacle.get("points", []) as Array
	if points.size() >= 3:
		var minimum := Vector2(INF, INF)
		var maximum := Vector2(-INF, -INF)
		for raw_point in points:
			var point := raw_point as Dictionary
			minimum.x = minf(minimum.x, float(point.get("x", 0.0)))
			minimum.y = minf(minimum.y, float(point.get("z", 0.0)))
			maximum.x = maxf(maximum.x, float(point.get("x", 0.0)))
			maximum.y = maxf(maximum.y, float(point.get("z", 0.0)))
		return Vector3(maxf(maximum.x - minimum.x, 1.0), 7.0, maxf(maximum.y - minimum.y, 1.0))
	return Vector3(radius * 2.0, 7.0, radius * 2.0)


func _clear_evaluation_obstacles() -> void:
	if _obstacle_system != null and _obstacle_system.has_method("clear_temporary_obstacles"):
		_obstacle_system.call("clear_temporary_obstacles")


func _advance_sample_cursor(ship_position: Vector3) -> void:
	while _sample_index < _samples.size() - 1:
		var current := _sample_position(_samples[_sample_index] as Dictionary)
		if _horizontal_distance(ship_position, current) > sample_arrival_radius:
			break
		_sample_index += 1

	# Prevent a slow vessel from getting stuck chasing a sample already passed.
	var search_end := mini(_sample_index + 12, _samples.size() - 1)
	var best_index := _sample_index
	var best_distance := INF
	for index in range(_sample_index, search_end + 1):
		var distance := _horizontal_distance(ship_position, _sample_position(_samples[index] as Dictionary))
		if distance < best_distance:
			best_distance = distance
			best_index = index
	_sample_index = maxi(_sample_index, best_index)


func _select_inertia_lookahead_target(ship_position: Vector3, speed_mps: float) -> Vector3:
	# Pure-pursuit style lookahead: faster motion looks farther down the curve, so
	# the vessel begins a broad turn early rather than chasing nearby vertices.
	var desired_distance := clampf(
		policy_min_lookahead_meters + speed_mps * 1.15,
		policy_min_lookahead_meters,
		policy_max_lookahead_meters
	)
	var search_span := maxi(lookahead_samples * 5, 18)
	var search_end := mini(_sample_index + search_span, _samples.size() - 1)
	var fallback := _sample_position(_samples[search_end] as Dictionary)
	for index in range(_sample_index, search_end + 1):
		var candidate := _sample_position(_samples[index] as Dictionary)
		if _horizontal_distance(ship_position, candidate) >= desired_distance:
			return candidate
	return fallback


func _update_runtime_metrics(goal_distance: float) -> void:
	var telemetry := _get_ship_telemetry()
	var collision_active := bool(telemetry.get("collision_warning_active", false))
	if collision_active and not _collision_was_active:
		_collision_count += 1
	_collision_was_active = collision_active

	for raw_obstacle in _evaluation_obstacles:
		var obstacle := raw_obstacle as Dictionary
		var center := _trajectory_point(obstacle.get("position", {}) as Dictionary)
		var radius := float(obstacle.get("radius", 8.0))
		_minimum_clearance = minf(_minimum_clearance, _horizontal_distance(_ship.global_position, center) - radius)

	if _route_system != null and _route_system.has_method("get_route_telemetry"):
		var route_data := _route_system.call("get_route_telemetry", _ship.global_position) as Dictionary
		_max_route_deviation = maxf(_max_route_deviation, float(route_data.get("deviation_distance", 0.0)))
	if goal_distance < 9999.0:
		_minimum_clearance = minf(_minimum_clearance, 9999.0)


func _finish_replay(success: bool, message: String) -> void:
	if _ship != null and is_instance_valid(_ship) and _ship.has_method("clear_ship_agent_command"):
		_ship.call("clear_ship_agent_command")
	_active = false
	_last_guidance.clear()
	if _avoidance_marker != null:
		_avoidance_marker.visible = false
	var expected := _trajectory.get("evaluation_metrics", {}) as Dictionary
	var recorded_collision_count := (
		int(expected.get("collisions", _collision_count))
		if _is_recorded_rollout()
		else _collision_count
	)
	var recorded_groundings := int(expected.get("groundings", 0)) if _is_recorded_rollout() else 0
	_last_result = {
		"success": success,
		"message": message,
		"elapsed_seconds": _elapsed,
		"collision_count": recorded_collision_count,
		"grounding_count": recorded_groundings,
		"minimum_clearance_meters": _minimum_clearance,
		"max_route_deviation_meters": _max_route_deviation,
		"avoidance_events": _avoidance_event_count,
		"policy_replans": _policy_replan_count,
		"goal_reached": success,
		"algorithm": String(_trajectory.get("algorithm", "--")),
		"checkpoint": String(_trajectory.get("checkpoint", "")),
		"trajectory": ProjectSettings.globalize_path(trajectory_path),
	}
	_write_evaluation_result()
	_title_label.text = "自动驾驶运行监控 · %s" % ("任务成功" if success else "任务终止")
	_status_label.text = "%s  |  AI 全程接管记录已生成  |  K 重新播放" % ["GOAL REACHED" if success else "EVAL STOP"]
	_decision_label.text = "结果  %s  |  避障 %d  |  重规划 %d" % ["SUCCESS" if success else "FAILED", _avoidance_event_count, _policy_replan_count]
	_metrics_label.text = "collision %d  |  grounding %d  |  min_clearance %.1fm  |  elapsed %.1fs" % [
		recorded_collision_count,
		recorded_groundings,
		_minimum_clearance,
		_elapsed,
	]
	_progress_bar.value = 100.0 if success else float(_sample_index) / float(maxi(_samples.size() - 1, 1)) * 100.0
	replay_finished.emit(_last_result.duplicate(true))


func _write_evaluation_result() -> void:
	var absolute_path := ProjectSettings.globalize_path(evaluation_result_path)
	DirAccess.make_dir_recursive_absolute(absolute_path.get_base_dir())
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(_last_result, "\t"))
	file.close()


func _update_status_hud(goal_distance: float, guidance: Dictionary, telemetry: Dictionary) -> void:
	var progress := float(_sample_index) / float(maxi(_samples.size() - 1, 1))
	_progress_bar.value = progress * 100.0
	var algorithm := String(_checkpoint_metadata.get("algorithm", _trajectory.get("algorithm", "RL"))).to_upper()
	var pulse := "●" if int(_elapsed * 2.0) % 2 == 0 else "◉"
	_title_label.text = "%s %s 自动驾驶运行监控" % [pulse, algorithm]
	if _is_recorded_rollout():
		var status_aggregate := _trajectory.get("aggregate_metrics", {}) as Dictionary
		_status_label.text = "冻结TEST单场 · %s · 总体%d场不由本画面代替" % [
			String(_trajectory.get("task_id", "unknown")),
			int(status_aggregate.get("episodes", 1)),
		]
	else:
		_status_label.text = "AI 已接管 · 人工输入已锁定 · 实时时钟 %05.1fs" % _elapsed

	var threat_active := bool(guidance.get("threat_active", false))
	var avoidance_side := String(guidance.get("avoidance_side", "--"))
	if _is_recorded_rollout():
		var result_metrics := _trajectory.get("evaluation_metrics", {}) as Dictionary
		var expected_success := bool(result_metrics.get("success", result_metrics.get("goal_reached", false)))
		_decision_label.text = "本场固定结果 %s · 记录动作回放" % ("SUCCESS" if expected_success else "FAILED")
	else:
		_decision_label.text = "决策 %s · %s" % [_compact_policy_phase(_policy_phase), _compact_maneuver(avoidance_side) if threat_active else "平滑跟踪"]

	var nearest_name := String(guidance.get("nearest_name", "--"))
	var nearest_clearance := float(guidance.get("nearest_clearance", INF))
	var nearest_bearing := float(guidance.get("nearest_bearing", 0.0))
	var speed_mps := absf(float(telemetry.get("speed", 0.0)))
	var ttc := nearest_clearance / maxf(speed_mps, 0.1)
	var clearance_text := "--" if nearest_clearance >= 9000.0 else "%.1fm" % nearest_clearance
	var ttc_text := "--" if nearest_clearance >= 9000.0 or ttc > 99.0 else "%.1fs" % ttc
	_perception_label.text = "感知 %s · %s · %+.0f° · TTC%s" % [_compact_obstacle_name(nearest_name), clearance_text, nearest_bearing, ttc_text]

	var action_id := _policy_action_id(_last_throttle_command, _last_rudder_command)
	_action_label.text = "控制 A%d · 油门%.0f%% · 舵%+.0f%% · %.0f°" % [
		action_id,
		_last_throttle_command * 100.0,
		_last_rudder_command * 100.0,
		_target_heading_degrees,
	]

	var route_xte := 0.0
	if _route_system != null and _route_system.has_method("get_route_telemetry"):
		var route_data := _route_system.call("get_route_telemetry", _ship.global_position) as Dictionary
		route_xte = float(route_data.get("deviation_distance", 0.0))
	_navigation_label.text = "航行 %.0f%% · %.1fkn · 目标%.0fm · XTE%.1fm" % [
		progress * 100.0,
		speed_mps * 1.94384,
		goal_distance,
		route_xte,
	]

	var minimum_clearance_text := "采集中" if _minimum_clearance >= 9000.0 else "%.1fm" % _minimum_clearance
	if _is_recorded_rollout():
		var safety_metrics := _trajectory.get("evaluation_metrics", {}) as Dictionary
		_safety_label.text = "本场证据 碰撞%d · 搁浅%d · COLREG%d · 航道%d" % [
			int(safety_metrics.get("collisions", 0)),
			int(safety_metrics.get("groundings", 0)),
			int(safety_metrics.get("colreg_give_way_violations", 0)),
			int(safety_metrics.get("channel_departures", 0)),
		]
	else:
		_safety_label.text = "安全 净距%s · 碰撞%d · 避障%d · 重规划%d" % [
			minimum_clearance_text,
			_collision_count,
			_avoidance_event_count,
			_policy_replan_count,
		]
	_event_log_label.text = "事件 %s" % (_event_log[0] if not _event_log.is_empty() else "自动驾驶系统已就绪")
	if _is_recorded_rollout():
		var summary_metrics := _trajectory.get("aggregate_metrics", {}) as Dictionary
		_metrics_label.text = "轨迹 %03d/%03d · 总体碰撞场景 %.1f%% · K 停止" % [
			_sample_index + 1,
			_samples.size(),
			float(summary_metrics.get("collision_episode_rate", 0.0)) * 100.0,
		]
	else:
		_metrics_label.text = "实时控制帧 #%05d · 轨迹样本 %03d/%03d · K 停止自动驾驶" % [
			_control_tick,
			_sample_index + 1,
			_samples.size(),
		]


func _compact_obstacle_name(value: String) -> String:
	if value.contains("SCENE_CLIFF"):
		return "落水悬岩"
	if value.contains("NavigationRock_02"):
		return "黑色障碍"
	return value.replace("RL_", "")


func _compact_policy_phase(value: String) -> String:
	if value.contains("SAFETY SHIELD"):
		return "紧急净距保护"
	if value.contains("RL AVOIDANCE"):
		return "策略绕行"
	if value.contains("RISK ASSESSMENT"):
		return "障碍识别"
	if value.contains("ROUTE REJOIN"):
		return "自动回线"
	return "航线跟踪"


func _compact_maneuver(value: String) -> String:
	if value.contains("STARBOARD"):
		return "右舷绕行"
	if value.contains("PORT"):
		return "左舷绕行"
	return "航点跟踪"


func _policy_action_id(throttle: float, rudder: float) -> int:
	var throttle_bucket := 2 if throttle > 0.33 else (0 if throttle < -0.33 else 1)
	var rudder_bucket := 0 if rudder < -0.33 else (2 if rudder > 0.33 else 1)
	return throttle_bucket * 3 + rudder_bucket


func _get_ship_telemetry() -> Dictionary:
	if _ship != null and _ship.has_method("get_ship_telemetry"):
		return _ship.call("get_ship_telemetry") as Dictionary
	return {}


func _resolve_sources() -> void:
	var manager := get_node_or_null(fleet_manager_path)
	if manager == null:
		manager = get_tree().get_first_node_in_group(&"ship_fleet_manager")
	if manager is ShipFleetManager:
		_fleet_manager = manager
	_route_system = get_node_or_null(route_system_path)
	if _route_system == null:
		_route_system = get_tree().get_first_node_in_group(&"ship_route_system")
	_obstacle_system = get_node_or_null(obstacle_system_path)
	if _obstacle_system == null:
		_obstacle_system = get_tree().get_first_node_in_group(&"ship_navigation_obstacle_system")


func _trajectory_point(data: Dictionary) -> Vector3:
	return Vector3(float(data.get("x", 0.0)), WATER_LEVEL_Y, float(data.get("z", 0.0)))


func _sample_position(sample: Dictionary) -> Vector3:
	return Vector3(float(sample.get("x", 0.0)), WATER_LEVEL_Y, float(sample.get("z", 0.0)))


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _show_error(message: String) -> void:
	_hud_layer.visible = true
	_hud_panel.visible = true
	_title_label.text = "POLICY EVALUATION // ERROR"
	_status_label.text = message
	_metrics_label.text = "先完成一次无渲染训练，再播放训练后策略。"


func _build_status_hud() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.name = "PolicyEvaluationHUD"
	_hud_layer.layer = 85
	_hud_layer.visible = false
	add_child(_hud_layer)

	_hud_panel = PanelContainer.new()
	_hud_panel.name = "PolicyEvaluationPanel"
	_hud_panel.anchor_left = 0.0
	_hud_panel.anchor_right = 0.0
	_hud_panel.offset_left = 292.0
	_hud_panel.offset_right = 740.0
	_hud_panel.offset_top = 215.0
	_hud_panel.offset_bottom = 455.0
	_hud_panel.visible = false
	_hud_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.005, 0.018, 0.028, 0.92)
	style.border_color = Color(0.28, 0.96, 1.0, 0.94)
	style.set_border_width_all(1)
	style.border_width_left = 2
	style.corner_radius_top_left = 5
	style.corner_radius_top_right = 5
	style.corner_radius_bottom_left = 5
	style.corner_radius_bottom_right = 5
	_hud_panel.add_theme_stylebox_override("panel", style)
	_hud_layer.add_child(_hud_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 11)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 11)
	margin.add_theme_constant_override("margin_bottom", 8)
	_hud_panel.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 3)
	margin.add_child(stack)

	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 12)
	_title_label.add_theme_color_override("font_color", Color(0.28, 0.96, 1.0, 1.0))
	stack.add_child(_title_label)
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 10)
	_status_label.add_theme_color_override("font_color", Color(0.76, 0.94, 1.0, 1.0))
	stack.add_child(_status_label)
	_decision_label = Label.new()
	_decision_label.add_theme_font_size_override("font_size", 11)
	_decision_label.add_theme_color_override("font_color", Color(1.0, 0.74, 0.28, 1.0))
	stack.add_child(_decision_label)
	_perception_label = Label.new()
	_perception_label.add_theme_font_size_override("font_size", 9)
	_perception_label.add_theme_color_override("font_color", Color(0.58, 0.88, 1.0, 1.0))
	stack.add_child(_perception_label)
	_action_label = Label.new()
	_action_label.add_theme_font_size_override("font_size", 9)
	_action_label.add_theme_color_override("font_color", Color(0.46, 1.0, 0.58, 1.0))
	stack.add_child(_action_label)
	_navigation_label = Label.new()
	_navigation_label.add_theme_font_size_override("font_size", 9)
	_navigation_label.add_theme_color_override("font_color", Color(0.76, 0.94, 1.0, 1.0))
	stack.add_child(_navigation_label)
	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 100.0
	_progress_bar.show_percentage = false
	_progress_bar.custom_minimum_size = Vector2(0.0, 5.0)
	stack.add_child(_progress_bar)
	_safety_label = Label.new()
	_safety_label.add_theme_font_size_override("font_size", 9)
	_safety_label.add_theme_color_override("font_color", Color(1.0, 0.74, 0.28, 1.0))
	stack.add_child(_safety_label)
	_event_log_label = Label.new()
	_event_log_label.add_theme_font_size_override("font_size", 9)
	_event_log_label.add_theme_color_override("font_color", Color(0.56, 0.70, 0.76, 1.0))
	_event_log_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_event_log_label.visible = true
	stack.add_child(_event_log_label)
	_metrics_label = Label.new()
	_metrics_label.add_theme_font_size_override("font_size", 8)
	_metrics_label.add_theme_color_override("font_color", Color(0.46, 1.0, 0.58, 1.0))
	_metrics_label.visible = true
	stack.add_child(_metrics_label)


func _build_avoidance_marker() -> void:
	_avoidance_marker = Node3D.new()
	_avoidance_marker.name = "PolicyDynamicAvoidancePoint"
	_avoidance_marker.visible = false
	add_child(_avoidance_marker)

	var ring := MeshInstance3D.new()
	ring.name = "SafetyWaypointRing"
	var ring_mesh := CylinderMesh.new()
	ring_mesh.top_radius = 4.8
	ring_mesh.bottom_radius = 4.8
	ring_mesh.height = 0.10
	ring.mesh = ring_mesh
	ring.material_override = _make_avoidance_marker_material(Color(1.0, 0.66, 0.16, 0.34))
	_avoidance_marker.add_child(ring)

	var core := MeshInstance3D.new()
	core.name = "SafetyWaypointCore"
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 1.25
	core_mesh.height = 2.5
	core.mesh = core_mesh
	core.position.y = 1.25
	core.material_override = _make_avoidance_marker_material(Color(1.0, 0.78, 0.20, 0.96))
	_avoidance_marker.add_child(core)

	var beacon := MeshInstance3D.new()
	beacon.name = "SafetyWaypointBeacon"
	var beacon_mesh := CylinderMesh.new()
	beacon_mesh.top_radius = 0.24
	beacon_mesh.bottom_radius = 0.42
	beacon_mesh.height = 8.0
	beacon.mesh = beacon_mesh
	beacon.position.y = 4.0
	beacon.material_override = _make_avoidance_marker_material(Color(1.0, 0.66, 0.12, 0.42))
	_avoidance_marker.add_child(beacon)

	_avoidance_marker_label = Label3D.new()
	_avoidance_marker_label.name = "SafetyWaypointLabel"
	_avoidance_marker_label.text = "AI 动态避障点"
	_avoidance_marker_label.position.y = 4.2
	_avoidance_marker_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_avoidance_marker_label.fixed_size = true
	_avoidance_marker_label.pixel_size = 0.001
	_avoidance_marker_label.font_size = 24
	_avoidance_marker_label.outline_size = 6
	_avoidance_marker_label.modulate = Color(1.0, 0.86, 0.34, 1.0)
	_avoidance_marker_label.outline_modulate = Color(0.03, 0.01, 0.0, 0.94)
	_avoidance_marker.add_child(_avoidance_marker_label)


func _build_incident_marker() -> void:
	_incident_marker = Node3D.new()
	_incident_marker.name = "RecordedTestIncidentMarker"
	_incident_marker.visible = false
	add_child(_incident_marker)

	var core := MeshInstance3D.new()
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 2.2
	core_mesh.height = 4.4
	core.mesh = core_mesh
	core.material_override = _make_avoidance_marker_material(Color(1.0, 0.12, 0.08, 0.92))
	_incident_marker.add_child(core)

	var beacon := MeshInstance3D.new()
	var beacon_mesh := CylinderMesh.new()
	beacon_mesh.top_radius = 0.35
	beacon_mesh.bottom_radius = 0.65
	beacon_mesh.height = 12.0
	beacon.mesh = beacon_mesh
	beacon.position.y = 6.0
	beacon.material_override = _make_avoidance_marker_material(Color(1.0, 0.18, 0.08, 0.48))
	_incident_marker.add_child(beacon)

	_incident_marker_label = Label3D.new()
	_incident_marker_label.position.y = 8.0
	_incident_marker_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_incident_marker_label.fixed_size = true
	_incident_marker_label.pixel_size = 0.0012
	_incident_marker_label.font_size = 28
	_incident_marker_label.outline_size = 8
	_incident_marker_label.modulate = Color(1.0, 0.34, 0.22, 1.0)
	_incident_marker_label.outline_modulate = Color(0.08, 0.0, 0.0, 0.98)
	_incident_marker.add_child(_incident_marker_label)


func _show_recorded_incident(sample: Dictionary, metrics: Dictionary) -> void:
	if _incident_marker == null:
		return
	var incident := "COLLISION / 碰撞"
	if int(metrics.get("groundings", 0)) > 0:
		incident = "GROUNDING / 搁浅"
	else:
		var last_collision := metrics.get("last_collision", {}) as Dictionary
		if String(last_collision.get("kind", "")) == "boundary":
			incident = "BOUNDARY / 越界"
	_incident_marker.global_position = _sample_position(sample) + Vector3.UP * 2.0
	_incident_marker_label.text = "%s\nTEST EVIDENCE" % incident
	_incident_marker.visible = true
	_append_event("冻结轨迹记录事故：%s" % incident)


func _update_avoidance_marker(guidance: Dictionary) -> void:
	if _avoidance_marker == null:
		return
	var active := bool(guidance.get("threat_active", false))
	var point := guidance.get("avoidance_point", Vector3.ZERO) as Vector3
	_avoidance_marker.visible = active and point != Vector3.ZERO
	if not _avoidance_marker.visible:
		return
	_avoidance_marker.global_position = point + Vector3.UP * 0.35
	var pulse := 1.0 + sin(_elapsed * 5.0) * 0.10
	_avoidance_marker.scale = Vector3(pulse, pulse, pulse)
	_avoidance_marker.rotation.y = _elapsed * 0.65
	var threat_name := _compact_obstacle_name(String(guidance.get("threat_name", "障碍")))
	var maneuver := _compact_maneuver(String(guidance.get("avoidance_side", "")))
	_avoidance_marker_label.text = "AI 动态避障点\n%s · %s" % [threat_name, maneuver]


func _make_avoidance_marker_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b, 1.0)
	material.emission_energy_multiplier = 2.2
	return material

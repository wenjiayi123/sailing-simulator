extends Node
## Direct SAC inference. Scene specialists own every action while active.
## Failed/mismatched artifacts cannot enter normal runtime through this loader.
const CATALOG_PATH := "res://data/rl/mission_rl_catalog_v1.json"
const CONTRACT := "mission_direct_sac_40d_v1"
var active := false
var status := "未选择场景强化学习策略"
var actor: Dictionary = {}
var scenario: Dictionary = {}
var key := ""
var ship: Node3D
var waypoint := 0
var route: Array = []
var arrival := 10.0
var frames := 0
var elapsed := 0.0
var first_action := false
var passed_ahead := false
var hold_seconds := 0.0
var last_action := Vector2.ZERO
var inference_count := 0
var last_observation: Array = []
var scenario_system: Node
var auto_switch := false

func _ready() -> void:
	add_to_group(&"mission_rl_controller")
	scenario_system = get_tree().get_first_node_in_group(&"ship_scenario_system")
	if scenario_system != null:
		scenario_system.connect("scenario_changed", _on_scenario_changed)

func _json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return value as Dictionary if value is Dictionary else {}

func current_strategy() -> Dictionary:
	if scenario_system == null:
		return {}
	var current_key := String((scenario_system.call("get_scenario_status") as Dictionary).get("key", ""))
	return (_json(CATALOG_PATH).get("scenarios", {}) as Dictionary).get(current_key, {}) as Dictionary

func start_current() -> bool:
	var entry := current_strategy()
	if not bool(entry.get("live_switch_admitted", false)):
		status = String(entry.get("status_zh", "本场景尚无通过完整验证的强化学习策略"))
		return false
	auto_switch = true
	return load_actor(String(entry.get("actor_path", "")))

func load_actor(path: String, validation_only: bool = false) -> bool:
	stop("检查策略合同")
	var value := _json(path)
	var validation_authorized := validation_only and OS.get_cmdline_user_args().has("--mission-rl-validation")
	if value.get("observation_contract") != CONTRACT or int(value.get("observation_size", 0)) != 40:
		status = "拒绝：强化学习观测合同不匹配"
		return false
	if not validation_authorized and not bool(value.get("live_switch_admitted", false)):
		status = "拒绝：尚未通过原生运行验收"
		return false
	if not validation_authorized:
		var admitted_entry := current_strategy()
		if admitted_entry.get("actor_path") != path or admitted_entry.get("actor_sha256") != FileAccess.get_sha256(path):
			status = "拒绝：策略文件与准入目录不一致"
			return false
	for source in (value.get("native_runtime_sources", {}) as Dictionary):
		if FileAccess.get_sha256("res://" + String(source)) != String(value["native_runtime_sources"][source]):
			status = "拒绝：原生执行合同已改变，需要重新验收"
			return false
	for source in (value.get("source_hashes", {}) as Dictionary):
		if FileAccess.get_sha256("res://" + String(source)) != String(value["source_hashes"][source]):
			var archived_source := "res://reports/artifacts/mission_rl_v1/training_sources/" + String(value["source_hashes"][source]) + ".py"
			if String(source) == "tools/train_mission_rl.py" and FileAccess.get_sha256(archived_source) == String(value["source_hashes"][source]):
				continue
			status = "拒绝：模型与训练来源指纹不一致"
			return false
	if scenario_system == null:
		return false
	key = String((scenario_system.call("get_scenario_status") as Dictionary).get("key", ""))
	if value.get("scenario") != key:
		status = "拒绝：策略不属于当前任务"
		return false
	scenario = scenario_system.call("get_current_scenario_config") as Dictionary
	var fleet := get_tree().get_first_node_in_group(&"ship_fleet_manager")
	ship = fleet.call("get_controlled_ship") as Node3D if fleet != null else null
	if ship == null:
		status = "拒绝：无可控船舶"
		return false
	if not validation_authorized:
		var spawn := _point(scenario.get("spawn", {}) as Dictionary)
		if Vector2(ship.global_position.x, ship.global_position.z).distance_to(spawn) > 2.0:
			status = "请先应用任务，复位至已验证的强化学习起点"
			return false
		var route_system := get_tree().get_first_node_in_group(&"ship_route_system")
		var current_route: Array = route_system.get("waypoint_positions") if route_system != null else []
		var expected_route := scenario.get("route", []) as Array
		if current_route.size() != expected_route.size():
			status = "航线已改变，请重新应用当前任务后启用强化学习"
			return false
		for index in range(current_route.size()):
			var point := current_route[index] as Vector3
			if Vector2(point.x, point.z).distance_to(_point(expected_route[index])) > 0.05:
				status = "航线与策略合同不一致"
				return false
	var profile := _json("res://data/ports/default_port_profile.json")
	for mission in profile.get("navigation_missions", []) as Array:
		if mission.get("scenario_key") == key:
			arrival = float(mission.get("arrival_radius", 10.0))
	for group in [&"ship_policy_replay_controller", &"cargo_circuit_replay_controller"]:
		var replay := get_tree().get_first_node_in_group(group)
		if replay != null and replay.has_method("stop_replay"):
			replay.call("stop_replay")
	actor = value
	route = scenario.get("route", []) as Array
	waypoint = 0
	frames = 0
	elapsed = 0.0
	first_action = false
	passed_ahead = false
	hold_seconds = 0.0
	inference_count = 0
	active = true
	ship.call("set_ship_agent_command", 0.0, 0.0)
	status = "场景强化学习接管：" + String(actor.get("strategy_id", "SAC"))
	return true

func stop(reason: String = "强化学习已停止") -> void:
	if active and ship != null and is_instance_valid(ship):
		ship.call("clear_ship_agent_command")
	active = false
	status = reason

func _on_scenario_changed(_value: Dictionary) -> void:
	var resume := auto_switch
	stop("任务已切换，正在核验匹配策略")
	if resume:
		call_deferred("start_current")

func _physics_process(delta: float) -> void:
	if not active:
		return
	if ship == null or not is_instance_valid(ship):
		stop("船舶不可用")
		return
	elapsed += delta
	var telemetry := ship.call("get_ship_telemetry") as Dictionary
	if float(telemetry.get("last_impact_speed", 0.0)) > 0.0:
		stop("任务失败：发生碰撞")
		return
	if frames == 0:
		last_observation = observation(telemetry)
		var command := infer(last_observation, actor)
		last_action = command
		ship.call("set_ship_agent_command", command.x, command.y)
		inference_count += 1
	frames += 1
	if frames >= int((actor.get("config", {}) as Dictionary).get("decision_frames", 30)):
		frames = 0
		_update_task(telemetry)
	if elapsed >= 600.0:
		stop("任务失败：强化学习运行超时")

func _point(value: Dictionary) -> Vector2:
	return Vector2(float(value.get("x", 0)), float(value.get("z", 0)))

func _body(vector: Vector2, heading: float) -> Vector2:
	return Vector2(vector.x * sin(heading) + vector.y * cos(heading), vector.x * cos(heading) - vector.y * sin(heading))

func _clearance(position: Vector2) -> float:
	var result := float(scenario.get("boundary_half_extent", 180)) - maxf(absf(position.x), absf(position.y)) - 3.2
	for box in scenario.get("boxes", []) as Array:
		var size_value := _point(box.get("size", {}) as Dictionary) * 0.5
		var offset := (position - _point(box.get("position", {}) as Dictionary)).abs() - size_value
		var distance := Vector2(maxf(offset.x, 0), maxf(offset.y, 0)).length() + minf(maxf(offset.x, offset.y), 0) - 3.2
		result = minf(result, distance)
	for rock in scenario.get("rocks", []) as Array:
		result = minf(result, position.distance_to(_point(rock)) - float(rock.get("radius", 6)) - 3.2)
	return result

func observation(t: Dictionary) -> Array:
	var position := Vector2(ship.global_position.x, ship.global_position.z)
	var heading := deg_to_rad(float(t.get("heading_degrees", 0)))
	var target := _point(route[waypoint]) - position
	var body := _body(target, heading)
	var bearing := wrapf(atan2(target.x, target.y) - heading, -PI, PI)
	var last := waypoint == route.size() - 1
	var evaluation := scenario.get("evaluation", {}) as Dictionary
	var berth := evaluation.get("berth_target", {}) as Dictionary
	var hd := wrapf(deg_to_rad(float(berth.get("heading_degrees", 0))) - heading, -PI, PI)
	var next_delta := _point(route[mini(waypoint + 1, route.size() - 1)]) - _point(route[waypoint])
	var next_bearing := wrapf(atan2(next_delta.x, next_delta.y) - heading, -PI, PI) if next_delta.length() > 0 else 0.0
	var weather := get_tree().get_first_node_in_group(&"ship_weather_time_system")
	var sea := weather.call("get_sea_state_status") as Dictionary if weather != null else {}
	var current_speed := float(sea.get("current_speed_knots", 0)) * 0.514444
	var current_heading := deg_to_rad(float(sea.get("current_direction_degrees", 0)))
	var current_world := Vector2(sin(current_heading), cos(current_heading)) * current_speed
	var current := _body(current_world, heading)
	var obs: Array = [target.length()/100, sin(bearing), cos(bearing), body.x/50, body.y/50,
		float(t.get("surge_mps", 0))/11, float(t.get("sway_mps", 0))/3, deg_to_rad(float(t.get("yaw_rate_deg_s", 0)))/0.5,
		float(t.get("port_throttle", 0)), float(t.get("starboard_throttle", 0)), float(t.get("steering_angle_deg", 0))/18,
		sin(next_bearing), cos(next_bearing), float(waypoint)/maxi(route.size()-1, 1), float(last), float(key == "auto_berthing"),
		sin(hd) if key == "auto_berthing" else 0.0, cos(hd) if key == "auto_berthing" else 0.0,
		current.x, current.y, _clearance(position)/30, position.x/float(scenario["boundary_half_extent"]), position.y/float(scenario["boundary_half_extent"]), sin(heading), cos(heading)]
	var own_velocity := Vector2(sin(heading), cos(heading))*float(t.get("surge_mps", 0)) + Vector2(cos(heading), -sin(heading))*float(t.get("sway_mps", 0)) + current_world
	var nearest: Array = []
	var nearest_distance := INF
	for target_ship in get_tree().get_nodes_in_group(&"ship_advanced_mission_traffic"):
		var other := target_ship.call("get_ship_telemetry") as Dictionary
		var th := deg_to_rad(float(other.get("heading_degrees", 0)))
		var rel := Vector2(target_ship.global_position.x, target_ship.global_position.z) - position
		var velocity := Vector2(sin(th), cos(th))*float(other.get("surge_mps", 0)) + Vector2(cos(th), -sin(th))*float(other.get("sway_mps", 0)) + current_world - own_velocity
		if rel.length() < nearest_distance:
			nearest_distance = rel.length()
			var raw_tcpa := -rel.dot(velocity)/maxf(velocity.length_squared(), 0.000000001)
			var tcpa := minf(raw_tcpa, 180) if raw_tcpa > 0 else 180.0
			var relative_body := _body(rel, heading)
			var velocity_body := _body(velocity, heading)
			nearest = [1.0, relative_body.x/200, relative_body.y/100, velocity_body.x/11, velocity_body.y/11, tcpa/180, (rel+velocity*tcpa).length()/100]
		if -rel.dot(Vector2(sin(th), cos(th))) > 5.7:
			passed_ahead = true
	obs.append_array(nearest if not nearest.is_empty() else [0,0,0,0,0,1,1])
	var advanced := get_tree().get_first_node_in_group(&"ship_advanced_mission_controller")
	var snapshot := advanced.call("get_advanced_mission_snapshot") as Dictionary if advanced != null else {}
	var behavior := snapshot.get("behavioral_assessment", {}) as Dictionary
	first_action = behavior.get("first_substantial_action_s") != null
	var agreement := bool(snapshot.get("overtaking_agreement_confirmed", false)) if key == "narrow_channel_overtaking" else true
	obs.append_array([float(first_action), float(agreement), float(passed_ahead), hold_seconds/3.0,
		float(key == "narrow_channel_head_on"), float(key == "crossing_starboard"), float(key == "narrow_channel_overtaking"), float(key == "auto_unberthing")])
	for index in range(obs.size()):
		obs[index] = clampf(float(obs[index]), -1, 1)
	return obs

func infer(obs: Array, model: Dictionary) -> Vector2:
	var values := obs.duplicate()
	var layers := model.get("terminal_layers", model.get("layers", [])) as Array if float(obs[14]) > 0.5 else model.get("layers", []) as Array
	for layer in layers:
		var next_values: Array = []
		var weights := layer.get("weight", []) as Array
		var bias := layer.get("bias", []) as Array
		for index in range(weights.size()):
			var value := float(bias[index])
			var row := weights[index] as Array
			for j in range(values.size()):
				value += float(row[j]) * float(values[j])
			next_values.append(tanh(value) if layer.get("activation") == "tanh" else maxf(value, 0))
		values = next_values
	var lower := model.get("action_low", [-0.6,-0.65]) as Array
	var upper := model.get("action_high", [0.65,0.65]) as Array
	return Vector2(float(lower[0])+(float(values[0])+1)*0.5*(float(upper[0])-float(lower[0])),
		float(lower[1])+(float(values[1])+1)*0.5*(float(upper[1])-float(lower[1])))

func _update_task(t: Dictionary) -> void:
	var position := Vector2(ship.global_position.x, ship.global_position.z)
	var distance := position.distance_to(_point(route[waypoint]))
	if waypoint < route.size()-1:
		if distance <= arrival:
			waypoint += 1
		return
	var advanced := get_tree().get_first_node_in_group(&"ship_advanced_mission_controller")
	var snapshot := advanced.call("get_advanced_mission_snapshot") as Dictionary if advanced != null else {}
	var passed := bool((snapshot.get("behavioral_assessment", {}) as Dictionary).get("passed", false))
	if key in ["open_water", "harbor"]:
		passed = distance <= arrival
	if key == "auto_berthing":
		hold_seconds = hold_seconds + 0.5 if passed else 0.0
		passed = passed and hold_seconds >= 3.0
	if passed and (distance <= arrival or key == "auto_berthing"):
		stop("强化学习任务完成")

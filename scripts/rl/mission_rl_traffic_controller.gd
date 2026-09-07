extends Node
## An optional second learned actor for a lane-holding overtaken vessel.
var traffic_actor: Dictionary = {}
var current_id := ""
var frames := 0
var inference_count := 0
var maximum_cross_track_m := 0.0
var traffic_collision := false
var last_command := Vector2.ZERO

func _ready() -> void:
	process_priority = 10
	add_to_group(&"mission_rl_traffic_controller")

func _physics_process(_delta: float) -> void:
	var controller := get_parent().get_node_or_null("MissionRLController")
	if controller == null or not bool(controller.get("active")):
		return
	var actor := controller.get("actor") as Dictionary
	var config := actor.get("config", {}) as Dictionary
	var path := String(config.get("traffic_policy_path", ""))
	if path.is_empty():
		return
	var identity := String(actor.get("strategy_id", ""))
	if identity != current_id or float(controller.get("elapsed")) < 0.02:
		if FileAccess.get_sha256("res://" + path) != String(config.get("traffic_policy_sha256", "")):
			controller.call("stop", "拒绝：目标船强化学习模型指纹不一致")
			return
		traffic_actor = JSON.parse_string(FileAccess.get_file_as_string("res://" + path)) as Dictionary
		current_id = identity
		inference_count = 0
		maximum_cross_track_m = 0.0
		traffic_collision = false
		frames = 0
	for target in get_tree().get_nodes_in_group(&"ship_advanced_mission_traffic"):
		var t := target.call("get_ship_telemetry") as Dictionary
		maximum_cross_track_m = maxf(maximum_cross_track_m, absf(target.global_position.x - 18.0))
		traffic_collision = traffic_collision or float(t.get("last_impact_speed", 0)) > 0.0
		if traffic_collision or maximum_cross_track_m >= 7.0:
			controller.call("stop", "任务失败：目标船偏离航道或发生碰撞")
			return
		if frames == 0:
			last_command = infer(observation(target, t), traffic_actor)
			target.call("set_ship_agent_command", last_command.x, last_command.y)
			inference_count += 1
	frames = (frames + 1) % 30

func infer(obs: Array, model: Dictionary) -> Vector2:
	var values := obs.duplicate()
	for layer in model.get("layers", []) as Array:
		var output: Array = []
		var weights := layer.get("weight", []) as Array
		var bias := layer.get("bias", []) as Array
		for i in range(weights.size()):
			var value := float(bias[i])
			var row := weights[i] as Array
			for j in range(values.size()):
				value += float(row[j]) * float(values[j])
			output.append(tanh(value) if layer.get("activation") == "tanh" else maxf(value,0))
		values = output
	var lo := model.get("action_low", [0,-0.4]) as Array
	var hi := model.get("action_high", [0.35,0.4]) as Array
	return Vector2(float(lo[0])+(float(values[0])+1)*0.5*(float(hi[0])-float(lo[0])),float(lo[1])+(float(values[1])+1)*0.5*(float(hi[1])-float(lo[1])))

func observation(target: Node3D, t: Dictionary) -> Array:
	var h := deg_to_rad(float(t.get("heading_degrees", 0)))
	var weather := get_tree().get_first_node_in_group(&"ship_weather_time_system")
	var sea := weather.call("get_sea_state_status") as Dictionary if weather != null else {}
	var cx := float(sea.get("current_speed_knots", 0)) * 0.514444 * sin(deg_to_rad(float(sea.get("current_direction_degrees", 0))))
	var result: Array = [(target.global_position.x-18.0)/30.0,sin(h),cos(h),float(t.get("surge_mps",0))/5.0,
		float(t.get("sway_mps",0))/2.0,deg_to_rad(float(t.get("yaw_rate_deg_s",0)))/0.5,
		float(t.get("port_throttle",0)),float(t.get("starboard_throttle",0)),float(t.get("steering_angle_deg",0))/18.0,cx]
	for i in range(result.size()):
		result[i] = clampf(float(result[i]),-1,1)
	return result

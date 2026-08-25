extends SceneTree

const REPORT_PATH := "res://reports/godot_ui_navigation_smoke_v1.json"
const EXPECTED_PORT_ALGORITHMS := [
	"ppo", "sac", "td3", "dqn", "a2c", "ddpg", "trpo", "los_pid", "lqr", "mpc"
]

var _errors: Array[String] = []
var _checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _record(name: String, passed: bool, detail: Variant) -> void:
	_checks[name] = {"passed": passed, "detail": detail}
	if not passed:
		_errors.append("%s: %s" % [name, str(detail)])


func _panel_root(panel: Node) -> Control:
	var root := panel.get("_root") as Control
	return root


func _send_key(panel: Node, keycode: Key) -> bool:
	var root := _panel_root(panel)
	if root == null:
		return false
	root.visible = false
	var event := InputEventKey.new()
	event.pressed = true
	event.physical_keycode = keycode
	panel.call("_unhandled_input", event)
	return root.visible


func _find_button(root: Node, title: String) -> Button:
	for node in root.find_children("*", "Button", true, false):
		var button := node as Button
		if button != null and button.text == title:
			return button
	return null


func _press_and_check(
	center_root: Control,
	title: String,
	targets: Array[Node]
) -> bool:
	var button := _find_button(center_root, title)
	if button == null:
		return false
	for target in targets:
		var root := _panel_root(target)
		if root != null:
			root.visible = false
	center_root.visible = true
	button.pressed.emit()
	await process_frame
	for target in targets:
		var root := _panel_root(target)
		if root == null or not root.visible:
			return false
	return true


func _run() -> void:
	var scene_status := change_scene_to_file("res://main.tscn")
	_record("main_scene_load_request", scene_status == OK, scene_status)
	for _index in range(16):
		await process_frame
	var main := current_scene
	if main == null:
		_record("main_scene_ready", false, "current_scene is null")
		_finish()
		return
	_record("main_scene_ready", true, main.name)
	var weather := main.get_node_or_null("ShipWeatherTimeController")
	var telemetry_hud := main.get_node_or_null("ShipTelemetryHUD")
	var world_environment := main.get_node_or_null("WorldEnvironment") as WorldEnvironment
	var weather_status: Dictionary = {}
	if weather != null and weather.has_method("get_weather_time_status"):
		weather_status = weather.call("get_weather_time_status") as Dictionary
	var fog_enabled := true
	if world_environment != null and world_environment.environment != null:
		fog_enabled = world_environment.environment.fog_enabled
	_record(
		"default_weather_is_clear",
		String(weather_status.get("key", "")) == "clear"
		and float(weather_status.get("visibility_km", 0.0)) >= 18.0
		and not fog_enabled,
		{
			"weather": weather_status.get("weather", ""),
			"visibility_km": weather_status.get("visibility_km", 0.0),
			"fog_enabled": fog_enabled,
		},
	)
	if weather != null and weather.has_method("get_water_surface_visual_status"):
		var calm_water_visual := weather.call("get_water_surface_visual_status") as Dictionary
		weather.call("apply_mode", 2)
		var rougher_water_visual := weather.call("get_water_surface_visual_status") as Dictionary
		weather.call("apply_mode", 0)
		_record(
			"water_visual_matches_sea_state",
			bool(calm_water_visual.get("connected", false))
			and float(calm_water_visual.get("vertex_wave_height", 1.0)) < 0.08
			and float(rougher_water_visual.get("vertex_wave_height", 0.0)) > float(calm_water_visual.get("vertex_wave_height", 1.0)),
			{
				"calm_visual_wave_height": calm_water_visual.get("vertex_wave_height", 0.0),
				"rougher_visual_wave_height": rougher_water_visual.get("vertex_wave_height", 0.0),
			},
		)
	if telemetry_hud != null:
		var radar_scope: Control = telemetry_hud.get("_radar_scope") as Control
		if radar_scope != null:
			var radar_boxes := radar_scope.get("box_obstacles") as Array
			var radar_terrain := radar_scope.get("terrain_obstacles") as Array
			var leaked_large_rock_boxes := radar_boxes.filter(
				func(item: Dictionary) -> bool:
					return String(item.get("source", "")) == "large_rock_manifest"
			)
			_record(
				"radar_large_rocks_use_terrain_symbols",
				radar_terrain.size() == 32 and leaked_large_rock_boxes.is_empty(),
				{"terrain_symbols": radar_terrain.size(), "rectangle_symbols": radar_boxes.size()},
			)

	var node_names := [
		"CargoCircuitRLPanel",
		"ShipRLControlPanel",
		"ShipRiskDecisionPanel",
		"ShipNavigationPlanningPanel",
		"ShipWeatherSeaPanel",
		"ShipSimulationReviewPanel",
		"ShipAISFleetPanel",
		"ShipInstructorConsolePanel",
		"ShipSystemOverviewPanel",
	]
	var panels: Dictionary = {}
	for node_name in node_names:
		var panel := main.get_node_or_null(NodePath(node_name))
		panels[node_name] = panel
		_record("panel_%s_present" % node_name, panel != null, node_name)
	if not _errors.is_empty():
		_finish()
		return

	var key_checks := {
		"total_control_H": [panels["CargoCircuitRLPanel"], KEY_H],
		"overview_M": [panels["ShipSystemOverviewPanel"], KEY_M],
		"rl_Z": [panels["ShipRLControlPanel"], KEY_Z],
		"fleet_X": [panels["ShipRLControlPanel"], KEY_X],
		"training_C": [panels["ShipRLControlPanel"], KEY_C],
		"navigation_N": [panels["ShipNavigationPlanningPanel"], KEY_N],
		"risk_V": [panels["ShipRiskDecisionPanel"], KEY_V],
		"weather_W": [panels["ShipWeatherSeaPanel"], KEY_W],
		"review_P": [panels["ShipSimulationReviewPanel"], KEY_P],
		"ais_I": [panels["ShipAISFleetPanel"], KEY_I],
		"assistant_O": [panels["ShipInstructorConsolePanel"], KEY_O],
	}
	for check_name in key_checks:
		var specification: Array = key_checks[check_name]
		_record(
			"hotkey_%s" % check_name,
			_send_key(specification[0], specification[1]),
			"panel root must become visible",
		)

	var cargo_controller := main.get_node_or_null("CargoCircuitReplayController")
	_record(
		"cargo_replay_controller_present",
		cargo_controller != null,
		"CargoCircuitReplayController",
	)
	if cargo_controller != null:
		var cargo_player := main.get_node_or_null("Player") as Node3D
		var cargo_start := cargo_player.global_position if cargo_player != null else Vector3.ZERO
		panels["CargoCircuitRLPanel"].call("_on_play_selected_strategy_pressed")
		for _index in range(4):
			await physics_frame
		var cargo_status := cargo_controller.call("get_replay_status") as Dictionary
		var cargo_displacement := (
			cargo_player.global_position.distance_to(cargo_start)
			if cargo_player != null
			else 0.0
		)
		_record(
			"h_hub_plays_frozen_policy",
			bool(cargo_status.get("active", false))
			and bool(cargo_status.get("trained_rl", false))
			and String(cargo_status.get("dataset_split", "")) == "test"
			and cargo_displacement > 0.001,
			{
				"algorithm": cargo_status.get("algorithm", ""),
				"dataset_split": cargo_status.get("dataset_split", ""),
				"trained_rl": cargo_status.get("trained_rl", false),
				"displacement_m": cargo_displacement,
			},
		)
		cargo_controller.call("stop_replay", true)
		await process_frame

	var rl_panel: Node = panels["ShipRLControlPanel"]
	rl_panel.call("show_training_center")
	await process_frame
	var algorithm_option := rl_panel.get("_algorithm_option") as OptionButton
	var inventory: Array[String] = []
	if algorithm_option != null:
		for index in range(algorithm_option.item_count):
			inventory.append(algorithm_option.get_item_text(index))
	_record(
		"frontend_backend_algorithm_inventory",
		inventory == EXPECTED_PORT_ALGORITHMS,
		inventory,
	)
	var training_buttons_connected := true
	var rl_root := _panel_root(rl_panel)
	for title in ["导出配置", "启动训练", "算法/环境设置", "运行测试集并渲染", "停止策略回放"]:
		var button := _find_button(rl_root, title)
		if button == null or button.pressed.get_connections().is_empty():
			training_buttons_connected = false
	_record(
		"training_buttons_have_handlers",
		training_buttons_connected,
		"export/train/settings/test replay/stop replay",
	)

	var center: Node = panels["ShipSystemOverviewPanel"]
	var center_root := _panel_root(center)
	var overview_buttons_connected := true
	for node in center_root.find_children("*", "Button", true, false):
		var button := node as Button
		if button != null and button.pressed.get_connections().is_empty():
			overview_buttons_connected = false
	_record(
		"system_overview_buttons_have_handlers",
		overview_buttons_connected,
		"all system-overview buttons",
	)
	_record(
		"button_training_center",
		await _press_and_check(
			center_root,
			"打开训练中心  ·  TRAINING CENTER",
			[panels["ShipRLControlPanel"]],
		),
		"system overview -> training center",
	)
	_record(
		"button_navigation_group",
		await _press_and_check(
			center_root,
			"航线规划 / 风险决策 / 海况",
			[
				panels["ShipNavigationPlanningPanel"],
				panels["ShipRiskDecisionPanel"],
				panels["ShipWeatherSeaPanel"],
			],
		),
		"system overview -> navigation/risk/weather",
	)
	_record(
		"button_ais",
		await _press_and_check(
			center_root,
			"AIS 船队态势",
			[panels["ShipAISFleetPanel"]],
		),
		"system overview -> AIS",
	)
	_record(
		"button_review",
		await _press_and_check(
			center_root,
			"打开训练结果复盘",
			[panels["ShipSimulationReviewPanel"]],
		),
		"system overview -> review",
	)
	_record(
		"button_xiaoyi_assistant",
		await _press_and_check(
			center_root,
			"小懿全系统助手",
			[panels["ShipInstructorConsolePanel"]],
		),
		"system overview -> Xiaoyi assistant",
	)
	var status_label := center.get("_status_label") as Label
	var advisor_button := _find_button(
		center_root,
		"训练顾问：查看算法选择依据",
	)
	advisor_button.pressed.emit()
	_record(
		"button_xiaoyi_advisor",
		status_label.text.begins_with("小懿建议"),
		status_label.text,
	)
	var boundary_button := _find_button(
		center_root,
		"运行环境与数据边界审查",
	)
	boundary_button.pressed.emit()
	_record(
		"button_data_boundary",
		status_label.text.begins_with("边界审查"),
		status_label.text,
	)
	var validator_button := _find_button(
		center_root,
		"校验 v2 港口数据契约",
	)
	validator_button.pressed.emit()
	await process_frame
	_record(
		"button_port_contract_validator",
		status_label.text.begins_with("契约校验通过")
		and status_label.text.contains("live-control=false"),
		status_label.text,
	)

	for node_name in node_names:
		var root := _panel_root(panels[node_name])
		if root != null:
			root.visible = false
	var player := main.get_node_or_null("Player")
	if player == null:
		_record("player_present", false, "Player")
	else:
		_record("player_present", true, player.name)
		var visual_summary := player.call("get_procedural_usv_component_summary") as Dictionary
		var components := visual_summary.get("components", []) as Array
		var legacy_sprite := player.get_node_or_null("LegacyAnimationStateDriver") as AnimatedSprite3D
		_record(
			"original_procedural_usv_visual",
			String(visual_summary.get("visual_type", "")) == "procedural_unmanned_surface_vessel"
			and components.has("双体浮筒")
			and components.has("旋转雷达")
			and components.has("双推进器")
			and legacy_sprite != null
			and not legacy_sprite.visible,
			visual_summary,
		)
		var start_position: Vector3 = player.global_position
		var start_heading := float(player.get("ship_heading_yaw"))
		player.call("set_ship_agent_command", 0.9, 0.35)
		for _index in range(180):
			await physics_frame
		var displacement := Vector2(
			player.global_position.x - start_position.x,
			player.global_position.z - start_position.z
		).length()
		var speed := absf(float(player.get("ship_forward_speed")))
		var heading_delta := absf(
			wrapf(float(player.get("ship_heading_yaw")) - start_heading, -PI, PI)
		)
		_record(
			"basic_navigation_forward_motion",
			displacement > 1.0 and speed > 0.1,
			{"displacement_m": displacement, "speed_mps": speed},
		)
		_record(
			"basic_navigation_rudder_response",
			heading_delta > 0.02,
			{"heading_change_radians": heading_delta},
		)
		player.call("clear_ship_agent_command")
		_record(
			"human_control_remains_available",
			bool(player.get("human_control_enabled")),
			"human_control_enabled",
		)
		player.call("reset_ship_motion_state")
		var human_start: Vector3 = player.global_position
		Input.action_press("ui_up", 1.0)
		Input.action_press("ui_right", 0.45)
		for _index in range(120):
			await physics_frame
		Input.action_release("ui_up")
		Input.action_release("ui_right")
		var human_displacement := Vector2(
			player.global_position.x - human_start.x,
			player.global_position.z - human_start.z
		).length()
		var human_telemetry := player.call("get_ship_telemetry") as Dictionary
		_record(
			"human_navigation_input_motion",
			human_displacement > 4.0 and absf(float(human_telemetry.get("speed", 0.0))) > 3.0,
			{
				"displacement_m": human_displacement,
				"speed_mps": human_telemetry.get("speed", 0.0),
			},
		)
		_record(
			"human_navigation_calm_water_three_dof_handling",
			String(human_telemetry.get("motion_mode", "")) == "three_dof_reference"
			and bool(human_telemetry.get("three_dof_active", false))
			and absf(float(human_telemetry.get("drift_angle_degrees", 180.0))) < 20.0,
			{
				"motion_mode": human_telemetry.get("motion_mode", ""),
				"drift_angle_degrees": human_telemetry.get("drift_angle_degrees", 0.0),
			},
		)
	_finish()


func _finish() -> void:
	var payload := {
		"schema_version": "godot_ui_navigation_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"checks": _checks,
		"passed_checks": _checks.values().filter(
			func(item: Dictionary) -> bool: return bool(item["passed"])
		).size(),
		"total_checks": _checks.size(),
		"errors": _errors,
		"passed": _errors.is_empty(),
		"boundary": "Headless UI linkage and low-speed main-scene navigation regression smoke; not a long-duration performance or sea-trial result.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print(
		"UI_NAVIGATION_SMOKE:%s:%d/%d"
		% [
			"PASS" if payload["passed"] else "FAIL",
			payload["passed_checks"],
			payload["total_checks"],
		]
	)
	if not _errors.is_empty():
		for error in _errors:
			push_error(error)
	quit(0 if _errors.is_empty() else 1)

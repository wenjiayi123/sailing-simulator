extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_O
const REPORT_PATH := "user://ship_instructor_report.json"
const REFRESH_INTERVAL := 0.35
const COLOR_BG := Color(0.010, 0.020, 0.030, 0.95)
const COLOR_PANEL := Color(0.030, 0.052, 0.064, 0.95)
const COLOR_ACCENT := Color(0.28, 0.96, 1.0, 0.96)
const COLOR_GREEN := Color(0.46, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.72, 0.26, 1.0)
const COLOR_RED := Color(1.0, 0.28, 0.22, 1.0)
const COLOR_TEXT := Color(0.80, 0.94, 1.0, 0.98)
const COLOR_MUTED := Color(0.56, 0.70, 0.76, 0.92)

@export var start_visible: bool = false
@export var fleet_manager_path: NodePath = NodePath("../ShipFleetManager")
@export var scenario_controller_path: NodePath = NodePath("../ShipScenarioController")
@export var weather_time_path: NodePath = NodePath("../ShipWeatherTimeController")
@export var obstacle_system_path: NodePath = NodePath("../ShipNavigationObstacles")
@export var route_system_path: NodePath = NodePath("../ShipRouteSystem")
@export var risk_panel_path: NodePath = NodePath("../ShipRiskDecisionPanel")
@export var navigation_panel_path: NodePath = NodePath("../ShipNavigationPlanningPanel")
@export var review_panel_path: NodePath = NodePath("../ShipSimulationReviewPanel")
@export var ais_panel_path: NodePath = NodePath("../ShipAISFleetPanel")
@export var exercise_controller_path: NodePath = NodePath("../ShipInstructorExerciseController")
@export var advanced_realism_path: NodePath = NodePath("../ShipAdvancedMissionRealismController")

var _root: Control
var _pause_button: Button
var _speed_buttons: Array[Button] = []
var _scenario_buttons: Dictionary = {}
var _weather_buttons: Dictionary = {}
var _action_buttons: Dictionary = {}
var _labels: Dictionary = {}
var _scenario_banner_label: Label
var _log_label: Label
var _fleet_manager: Node
var _scenario_controller: Node
var _weather_time: Node
var _obstacle_system: Node
var _route_system: Node
var _risk_panel: Node
var _navigation_panel: Node
var _review_panel: Node
var _ais_panel: Node
var _exercise_controller: Node
var _advanced_realism: Node
var _refresh_timer := 0.0
var _incident_log: Array[Dictionary] = []
var _event_log: Array[Dictionary] = []
var _temporary_obstacle_count := 0
var _last_report_path := ""


func _ready() -> void:
	layer = 64
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_interface()
	_resolve_sources()
	_refresh_status()
	set_process(true)
	set_process_unhandled_input(true)


func _process(delta: float) -> void:
	if not _root.visible:
		return
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_INTERVAL
		_refresh_status()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return
		if key_event.physical_keycode == TOGGLE_PANEL_KEY:
			_root.visible = not _root.visible
			if _root.visible:
				_refresh_timer = 0.0
				_refresh_status()
			get_viewport().set_input_as_handled()


func show_panel() -> void:
	_root.visible = true
	_refresh_timer = 0.0
	_refresh_status()


func _on_root_gui_input(event: InputEvent) -> void:
	if not _root.visible:
		return
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
			return
		var mouse_position := get_viewport().get_mouse_position()
		for action_key in _action_buttons.keys():
			var button := _action_buttons[action_key] as Button
			if button == null or not is_instance_valid(button) or not button.visible:
				continue
			if button.get_global_rect().has_point(mouse_position):
				_trigger_action_by_key(String(action_key))
				_root.accept_event()
				return


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipInstructorConsoleRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = start_visible
	_root.process_mode = Node.PROCESS_MODE_ALWAYS
	_root.gui_input.connect(_on_root_gui_input)
	add_child(_root)

	var panel := PanelContainer.new()
	panel.name = "ShipInstructorConsole"
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -384.0
	panel.offset_top = -318.0
	panel.offset_right = 384.0
	panel.offset_bottom = 318.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.process_mode = Node.PROCESS_MODE_ALWAYS
	panel.add_theme_stylebox_override("panel", _panel_style(COLOR_BG, COLOR_ACCENT))
	_root.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 8)
	margin.add_child(stack)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	stack.add_child(header)
	var portrait := TextureRect.new()
	portrait.texture = load("res://assets/generated/release/xiaoyi_maritime_officer.svg")
	portrait.custom_minimum_size = Vector2(42.0, 48.0)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	header.add_child(portrait)
	var title := _make_label("舷鸥全系统助手 / Instructor", 16, COLOR_ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var hide_button := _make_button("收起")
	hide_button.pressed.connect(func() -> void: _root.visible = false)
	header.add_child(hide_button)

	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", 8)
	stack.add_child(summary)
	_add_status_pill(summary, "sim_state", "RUN 1.0x")
	_add_status_pill(summary, "scenario", "SCENE --")
	_add_status_pill(summary, "weather", "WX --")
	_add_status_pill(summary, "ship", "SHIP --")

	_scenario_banner_label = _make_label("SCENARIO INJECTION READY  操作会明确记录为教员场景注入", 12, COLOR_GREEN)
	_scenario_banner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_scenario_banner_label.custom_minimum_size = Vector2(0.0, 34.0)
	_scenario_banner_label.add_theme_stylebox_override("normal", _panel_style(COLOR_PANEL, Color(0.46, 1.0, 0.58, 0.38), 6))
	stack.add_child(_scenario_banner_label)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	stack.add_child(grid)

	_add_section(grid, "播放控制", _build_playback_controls())
	_add_section(grid, "场景切换", _build_scenario_controls())
	_add_section(grid, "事故注入", _build_incident_controls())
	_add_section(grid, "临时障碍", _build_obstacle_controls())
	_add_section(grid, "天气切换", _build_weather_controls())
	_add_section(grid, "重置 / 报告", _build_reset_report_controls())
	_add_section(grid, "设备故障矩阵", _build_equipment_fault_controls())
	_add_section(grid, "任务机械故障", _build_mission_machinery_fault_controls())
	_add_section(grid, "演练时间线", _build_exercise_timeline_controls())

	_log_label = _make_label("--", 11, COLOR_MUTED)
	_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log_label.custom_minimum_size = Vector2(0.0, 68.0)
	_log_label.add_theme_stylebox_override("normal", _panel_style(COLOR_PANEL, Color(0.28, 0.96, 1.0, 0.22), 6))
	stack.add_child(_log_label)


func _build_playback_controls() -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	_pause_button = _make_button("暂停")
	_pause_button.pressed.connect(_on_pause_pressed)
	root.add_child(_pause_button)
	var speed_row := HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 6)
	root.add_child(speed_row)
	for speed in [0.5, 1.0, 2.0, 4.0]:
		var button := _make_button("%.1fx" % speed)
		button.custom_minimum_size = Vector2(64.0, 28.0)
		button.pressed.connect(_on_speed_pressed.bind(float(speed)))
		speed_row.add_child(button)
		_speed_buttons.append(button)
	return root


func _build_scenario_controls() -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	root.add_child(row)
	var open_button := _make_button("开放水域")
	open_button.pressed.connect(_on_scenario_pressed.bind(0))
	row.add_child(open_button)
	_scenario_buttons[0] = open_button
	_register_action_button("open_water", open_button)
	var harbor_button := _make_button("简易港口")
	harbor_button.pressed.connect(_on_scenario_pressed.bind(1))
	row.add_child(harbor_button)
	_scenario_buttons[1] = harbor_button
	_register_action_button("harbor", harbor_button)
	return root


func _build_incident_controls() -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	var row_a := HBoxContainer.new()
	row_a.add_theme_constant_override("separation", 6)
	root.add_child(row_a)
	var collision_button := _make_button("碰撞")
	collision_button.pressed.connect(_on_incident_pressed.bind("collision"))
	row_a.add_child(collision_button)
	var grounding_button := _make_button("搁浅")
	grounding_button.pressed.connect(_on_incident_pressed.bind("grounding"))
	row_a.add_child(grounding_button)
	var row_b := HBoxContainer.new()
	row_b.add_theme_constant_override("separation", 6)
	root.add_child(row_b)
	var engine_button := _make_button("动力故障")
	engine_button.pressed.connect(_on_incident_pressed.bind("engine_fault"))
	row_b.add_child(engine_button)
	_register_action_button("engine_fault", engine_button)
	var rudder_button := _make_button("舵机故障")
	rudder_button.pressed.connect(_on_incident_pressed.bind("rudder_fault"))
	row_b.add_child(rudder_button)
	_register_action_button("rudder_fault", rudder_button)
	return root


func _build_obstacle_controls() -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	root.add_child(row)
	var add_button := _make_button("船首障碍")
	add_button.pressed.connect(_on_add_obstacle_pressed)
	row.add_child(add_button)
	_register_action_button("bow_obstacle", add_button)
	var clear_button := _make_button("清除临障")
	clear_button.pressed.connect(_on_clear_obstacles_pressed)
	row.add_child(clear_button)
	return root


func _build_weather_controls() -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	var row_a := HBoxContainer.new()
	row_a.add_theme_constant_override("separation", 6)
	root.add_child(row_a)
	var clear_button := _make_button("晴天")
	clear_button.pressed.connect(_on_weather_pressed.bind(0))
	row_a.add_child(clear_button)
	_weather_buttons[0] = clear_button
	var mist_button := _make_button("薄雾")
	mist_button.pressed.connect(_on_weather_pressed.bind(1))
	row_a.add_child(mist_button)
	_weather_buttons[1] = mist_button
	var row_b := HBoxContainer.new()
	row_b.add_theme_constant_override("separation", 6)
	root.add_child(row_b)
	var dusk_button := _make_button("黄昏")
	dusk_button.pressed.connect(_on_weather_pressed.bind(2))
	row_b.add_child(dusk_button)
	_weather_buttons[2] = dusk_button
	var night_button := _make_button("夜航")
	night_button.pressed.connect(_on_weather_pressed.bind(3))
	row_b.add_child(night_button)
	_weather_buttons[3] = night_button
	return root


func _build_reset_report_controls() -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	var row_a := HBoxContainer.new()
	row_a.add_theme_constant_override("separation", 6)
	root.add_child(row_a)
	var reset_ship_button := _make_button("重置受控")
	reset_ship_button.pressed.connect(_on_reset_controlled_pressed)
	row_a.add_child(reset_ship_button)
	var reset_all_button := _make_button("重置船队")
	reset_all_button.pressed.connect(_on_reset_fleet_pressed)
	row_a.add_child(reset_all_button)
	var report_button := _make_button("生成报告")
	report_button.pressed.connect(_on_report_pressed)
	root.add_child(report_button)
	_register_action_button("report", report_button)
	return root


func _build_equipment_fault_controls() -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	var row_a := HBoxContainer.new()
	row_a.add_theme_constant_override("separation", 6)
	root.add_child(row_a)
	var radar_button := _make_button("雷达黑屏")
	radar_button.pressed.connect(_on_equipment_fault_pressed.bind("radar_power_loss", true))
	row_a.add_child(radar_button)
	var ais_button := _make_button("AIS 丢失")
	ais_button.pressed.connect(_on_equipment_fault_pressed.bind("ais_loss", true))
	row_a.add_child(ais_button)
	var row_b := HBoxContainer.new()
	row_b.add_theme_constant_override("separation", 6)
	root.add_child(row_b)
	var gyro_button := _make_button("罗经 +7.5°")
	gyro_button.pressed.connect(_on_equipment_fault_pressed.bind("gyro_bias_deg", 7.5))
	row_b.add_child(gyro_button)
	var restore_button := _make_button("恢复设备")
	restore_button.pressed.connect(_on_clear_equipment_faults_pressed)
	row_b.add_child(restore_button)
	return root


func _build_mission_machinery_fault_controls() -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	var row_a := HBoxContainer.new()
	row_a.add_theme_constant_override("separation", 6)
	root.add_child(row_a)
	var port_button := _make_button("左推进损失 50%")
	port_button.pressed.connect(_on_mission_machinery_fault_pressed.bind("port_propulsion_loss", 0.5))
	row_a.add_child(port_button)
	var starboard_button := _make_button("右推进损失 50%")
	starboard_button.pressed.connect(_on_mission_machinery_fault_pressed.bind("starboard_propulsion_loss", 0.5))
	row_a.add_child(starboard_button)
	var row_b := HBoxContainer.new()
	row_b.add_theme_constant_override("separation", 6)
	root.add_child(row_b)
	var steering_button := _make_button("操舵偏差 +8°")
	steering_button.pressed.connect(_on_mission_machinery_fault_pressed.bind("steering_bias_deg", 8.0))
	row_b.add_child(steering_button)
	var restore_button := _make_button("恢复机械")
	restore_button.pressed.connect(_on_restore_mission_machinery_faults_pressed)
	row_b.add_child(restore_button)
	return root


func _build_exercise_timeline_controls() -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	var template_row := HBoxContainer.new()
	template_row.add_theme_constant_override("separation", 6)
	root.add_child(template_row)
	var visibility_button := _make_button("受限能见度")
	visibility_button.pressed.connect(_on_load_exercise_pressed.bind("restricted_visibility_bridge"))
	template_row.add_child(visibility_button)
	var disagreement_button := _make_button("传感器矛盾")
	disagreement_button.pressed.connect(_on_load_exercise_pressed.bind("sensor_disagreement"))
	template_row.add_child(disagreement_button)
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 6)
	root.add_child(action_row)
	var start_button := _make_button("启动时间线")
	start_button.pressed.connect(_on_exercise_start_pressed)
	action_row.add_child(start_button)
	var next_button := _make_button("下一事件")
	next_button.pressed.connect(_on_exercise_next_pressed)
	action_row.add_child(next_button)
	var pause_button := _make_button("暂停时间线")
	pause_button.pressed.connect(_on_exercise_pause_pressed)
	action_row.add_child(pause_button)
	var reset_button := _make_button("复位时间线")
	reset_button.pressed.connect(_on_exercise_reset_pressed)
	action_row.add_child(reset_button)
	return root


func _add_section(parent: Control, title: String, content: Control) -> void:
	var section := PanelContainer.new()
	section.custom_minimum_size = Vector2(0.0, 100.0)
	section.add_theme_stylebox_override("panel", _panel_style(COLOR_PANEL, Color(0.28, 0.96, 1.0, 0.24), 6))
	parent.add_child(section)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	section.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 7)
	margin.add_child(stack)
	stack.add_child(_make_label(title, 12, COLOR_ACCENT))
	stack.add_child(content)


func _add_status_pill(parent: Control, key: String, text: String) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(150.0, 30.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.process_mode = Node.PROCESS_MODE_ALWAYS
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", COLOR_TEXT)
	button.add_theme_color_override("font_hover_color", COLOR_ACCENT)
	button.add_theme_color_override("font_pressed_color", COLOR_GREEN)
	button.add_theme_stylebox_override("normal", _panel_style(COLOR_PANEL, COLOR_ACCENT))
	button.add_theme_stylebox_override("hover", _panel_style(Color(0.038, 0.074, 0.088, 0.98), COLOR_GREEN))
	button.add_theme_stylebox_override("pressed", _panel_style(Color(0.020, 0.048, 0.056, 1.0), COLOR_AMBER))
	button.pressed.connect(_on_status_pill_pressed.bind(key))
	parent.add_child(button)
	_labels[key] = button


func _resolve_sources() -> void:
	_fleet_manager = get_node_or_null(fleet_manager_path)
	if _fleet_manager == null:
		_fleet_manager = get_tree().get_first_node_in_group(&"ship_fleet_manager")
	_scenario_controller = get_node_or_null(scenario_controller_path)
	if _scenario_controller == null:
		_scenario_controller = get_tree().get_first_node_in_group(&"ship_scenario_system")
	_weather_time = get_node_or_null(weather_time_path)
	if _weather_time == null:
		_weather_time = get_tree().get_first_node_in_group(&"ship_weather_time_system")
	_obstacle_system = get_node_or_null(obstacle_system_path)
	if _obstacle_system == null:
		_obstacle_system = get_tree().get_first_node_in_group(&"ship_navigation_obstacle_system")
	_route_system = get_node_or_null(route_system_path)
	if _route_system == null:
		_route_system = get_tree().get_first_node_in_group(&"ship_route_system")
	_risk_panel = get_node_or_null(risk_panel_path)
	if _risk_panel == null:
		_risk_panel = get_tree().get_first_node_in_group(&"ship_risk_decision_panel")
	_navigation_panel = get_node_or_null(navigation_panel_path)
	if _navigation_panel == null:
		_navigation_panel = get_tree().get_first_node_in_group(&"ship_navigation_planning_panel")
	_review_panel = get_node_or_null(review_panel_path)
	if _review_panel == null:
		_review_panel = get_tree().get_first_node_in_group(&"ship_simulation_review_panel")
	_ais_panel = get_node_or_null(ais_panel_path)
	if _ais_panel == null:
		_ais_panel = get_tree().get_first_node_in_group(&"ship_ais_fleet_panel")
	_exercise_controller = get_node_or_null(exercise_controller_path)
	if _exercise_controller == null:
		_exercise_controller = get_tree().get_first_node_in_group(&"ship_instructor_exercise_controller")
	_advanced_realism = get_node_or_null(advanced_realism_path)
	if _advanced_realism == null:
		_advanced_realism = get_tree().get_first_node_in_group(&"ship_advanced_mission_realism_controller")


func _refresh_status() -> void:
	_resolve_sources()
	var paused := get_tree().paused
	var speed := Engine.time_scale
	_update_label("sim_state", ("%s %.1fx" % ["PAUSE" if paused else "RUN", speed]), COLOR_AMBER if paused else COLOR_GREEN)
	if _pause_button != null:
		_pause_button.text = "继续" if paused else "暂停"
	for button in _speed_buttons:
		var value_text := button.text.replace("x", "")
		var is_active := value_text.is_valid_float() and is_equal_approx(float(value_text), speed)
		button.modulate = Color(1.0, 1.0, 1.0, 1.0) if is_active else Color(0.78, 0.88, 0.92, 1.0)
	_update_label("scenario", "SCENE " + _scenario_name())
	_update_label("weather", "WX " + _weather_name())
	_update_label("ship", "SHIP " + _controlled_ship_name())
	_sync_button_states()
	_update_log()


func _on_pause_pressed() -> void:
	get_tree().paused = not get_tree().paused
	_log("仿真暂停" if get_tree().paused else "仿真继续")
	_refresh_status()


func _on_speed_pressed(speed: float) -> void:
	Engine.time_scale = clampf(speed, 0.1, 8.0)
	_log("倍速 %.1fx" % Engine.time_scale)
	_refresh_status()


func _on_status_pill_pressed(key: String) -> void:
	match key:
		"sim_state":
			_on_pause_pressed()
			_announce_scenario_action("RUN TOGGLE  播放状态已切换", COLOR_GREEN)
		"scenario":
			var current := int(_scenario_status().get("index", 0))
			_on_scenario_pressed(current + 1)
		"weather":
			var current_weather := int(_weather_status().get("index", 0))
			_on_weather_pressed(current_weather + 1)
		"ship":
			_on_ship_status_pressed()


func _on_ship_status_pressed() -> void:
	_resolve_sources()
	if _fleet_manager != null and _fleet_manager.has_method("cycle_controlled_ship"):
		_fleet_manager.call("cycle_controlled_ship", 1)
		_log("切换受控船：%s" % _controlled_ship_name())
	else:
		_log("打开船队态势")
	_open_panel(_ais_panel, "船队态势面板")
	_announce_scenario_action("SHIP READY  船队态势已打开", COLOR_GREEN)
	_refresh_status()


func _register_action_button(action_key: String, button: Button) -> void:
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.focus_mode = Control.FOCUS_NONE
	_action_buttons[action_key] = button


func _trigger_action_by_key(action_key: String) -> void:
	match action_key:
		"open_water":
			_on_scenario_pressed(0)
		"harbor":
			_on_scenario_pressed(1)
		"engine_fault":
			_on_incident_pressed("engine_fault")
		"rudder_fault":
			_on_incident_pressed("rudder_fault")
		"bow_obstacle":
			_on_add_obstacle_pressed()
		"report":
			_on_report_pressed()


func _on_scenario_pressed(index: int) -> void:
	if _scenario_controller == null or not _scenario_controller.has_method("apply_scenario"):
		_log("场景系统未就绪")
		_announce_scenario_action("SCENE ERROR  场景系统未就绪", COLOR_RED)
		return
	_scenario_controller.call("apply_scenario", index, true)
	var scenario := _scenario_name()
	_log("切换场景：%s；航线、障碍、船舶出生点已更新" % scenario)
	_announce_scenario_action("SCENE READY  %s：训练环境已切换" % scenario, COLOR_GREEN)
	_open_panel(_navigation_panel, "航行任务面板")
	_refresh_status()


func _on_weather_pressed(index: int) -> void:
	if _weather_time == null or not _weather_time.has_method("apply_mode"):
		_log("天气系统未就绪")
		_announce_scenario_action("WX ERROR  天气系统未就绪", COLOR_RED)
		return
	_weather_time.call("apply_mode", index)
	var weather := _weather_name()
	_log("切换天气：%s" % weather)
	_announce_scenario_action("WX READY  %s 海况已写入训练环境" % weather, COLOR_GREEN)
	_refresh_status()


func _on_incident_pressed(incident_key: String) -> void:
	var ship := _get_controlled_ship()
	if ship == null or not ship.has_method("inject_ship_incident"):
		_log("受控船未就绪")
		_announce_scenario_action("INCIDENT ERROR  受控船未就绪", COLOR_RED)
		return
	ship.call("inject_ship_incident", incident_key, 1.0)
	_incident_log.append({
		"time": Time.get_unix_time_from_system(),
		"clock": Time.get_time_string_from_system(),
		"ship": ship.name,
		"type": incident_key,
		"label": _incident_label(incident_key),
		"scenario": _scenario_name(),
		"weather": _weather_name()
	})
	_log("注入事故：%s / %s；事件已进入复盘日志" % [_incident_label(incident_key), ship.name])
	_announce_scenario_action("INCIDENT LOGGED  %s 已注入，风险面板可复盘" % _incident_label(incident_key), COLOR_AMBER)
	_open_panel(_risk_panel, "风险态势面板")
	_refresh_status()


func _on_add_obstacle_pressed() -> void:
	var ship := _get_controlled_ship()
	if ship == null:
		_log("受控船未就绪")
		_announce_scenario_action("OBSTACLE ERROR  受控船未就绪", COLOR_RED)
		return
	if _obstacle_system == null or not _obstacle_system.has_method("add_temporary_box_obstacle"):
		_log("障碍系统未就绪")
		_announce_scenario_action("OBSTACLE ERROR  障碍系统未就绪", COLOR_RED)
		return
	var position := _temporary_obstacle_position(ship)
	var obstacle: Dictionary = _obstacle_system.call(
		"add_temporary_box_obstacle",
		position,
		Vector3(13.0, 6.0, 13.0),
		"InstructorObstacle_%02d" % (_temporary_obstacle_count + 1)
	)
	_temporary_obstacle_count += 1
	_log("添加船首临时障碍：%s  x=%.1f z=%.1f" % [String(obstacle.get("name", "Obstacle")), position.x, position.z])
	_announce_scenario_action("OBSTACLE ACTIVE  教员临时障碍已注入，CPA/建议航速会刷新", COLOR_AMBER)
	_open_panel(_risk_panel, "风险态势面板")
	_refresh_status()


func _on_clear_obstacles_pressed() -> void:
	if _obstacle_system == null or not _obstacle_system.has_method("clear_temporary_obstacles"):
		_log("障碍系统未就绪")
		_announce_scenario_action("OBSTACLE ERROR  障碍系统未就绪", COLOR_RED)
		return
	var removed := int(_obstacle_system.call("clear_temporary_obstacles"))
	_temporary_obstacle_count = maxi(_temporary_obstacle_count - removed, 0)
	_log("清除临时障碍：%d" % removed)
	_announce_scenario_action("OBSTACLE CLEAR  已移除 %d 个教员注入障碍" % removed, COLOR_GREEN)
	_refresh_status()


func _on_reset_controlled_pressed() -> void:
	var ship := _get_controlled_ship()
	if ship != null and ship.has_method("clear_ship_agent_command"):
		ship.call("clear_ship_agent_command")
	if _scenario_controller != null and _scenario_controller.has_method("get_scenario_status") and _scenario_controller.has_method("apply_scenario"):
		var status := _scenario_controller.call("get_scenario_status") as Dictionary
		_scenario_controller.call("apply_scenario", int(status.get("index", 0)), true)
	elif ship != null and ship.has_method("reset_ship_motion_state"):
		ship.call("reset_ship_motion_state")
	_log("重置受控船")
	_refresh_status()


func _on_reset_fleet_pressed() -> void:
	if _fleet_manager == null or not _fleet_manager.has_method("get_ship_records"):
		_log("船队系统未就绪")
		return
	for ship in _fleet_manager.call("get_ship_records"):
		if ship is Node3D and is_instance_valid(ship):
			if ship.has_method("clear_ship_agent_command"):
				ship.call("clear_ship_agent_command")
			if ship.has_method("reset_ship_motion_state"):
				ship.call("reset_ship_motion_state")
	_log("重置船队运动状态")
	_refresh_status()


func _on_equipment_fault_pressed(fault_key: String, value: Variant) -> void:
	_resolve_sources()
	if _exercise_controller == null or not _exercise_controller.has_method("inject_equipment_fault"):
		_log("设备故障控制器未就绪")
		_announce_scenario_action("EQUIPMENT ERROR  设备故障控制器未就绪", COLOR_RED)
		return
	var receipt := _exercise_controller.call("inject_equipment_fault", fault_key, value, "instructor_panel") as Dictionary
	_log_receipt(receipt, "设备故障注入")


func _on_clear_equipment_faults_pressed() -> void:
	_resolve_sources()
	if _exercise_controller == null or not _exercise_controller.has_method("clear_equipment_faults"):
		_log("设备故障控制器未就绪")
		return
	var receipt := _exercise_controller.call("clear_equipment_faults", "instructor_panel") as Dictionary
	_log_receipt(receipt, "设备故障恢复")


func _on_mission_machinery_fault_pressed(fault_key: String, value: float) -> void:
	_resolve_sources()
	if _advanced_realism == null or not _advanced_realism.has_method("inject_machinery_fault"):
		_log("任务机械故障控制器未就绪")
		_announce_scenario_action("MACHINERY ERROR  高级任务现实性控制器未就绪", COLOR_RED)
		return
	var receipt := _advanced_realism.call("inject_machinery_fault", fault_key, value, "instructor_panel") as Dictionary
	_log_receipt(receipt, "任务机械故障注入")


func _on_restore_mission_machinery_faults_pressed() -> void:
	_resolve_sources()
	if _advanced_realism == null or not _advanced_realism.has_method("restore_machinery_faults"):
		_log("任务机械故障控制器未就绪")
		return
	var receipt := _advanced_realism.call("restore_machinery_faults", "instructor_panel") as Dictionary
	_log_receipt(receipt, "任务机械故障恢复")


func _on_load_exercise_pressed(template_key: String) -> void:
	_resolve_sources()
	if _exercise_controller == null or not _exercise_controller.has_method("load_exercise"):
		_log("演练时间线控制器未就绪")
		return
	var receipt := _exercise_controller.call("load_exercise", template_key) as Dictionary
	_log_receipt(receipt, "载入演练时间线")


func _on_exercise_start_pressed() -> void:
	_call_exercise_action("start_exercise", "启动演练时间线")


func _on_exercise_next_pressed() -> void:
	_call_exercise_action("execute_next_event", "执行下一时间线事件")


func _on_exercise_pause_pressed() -> void:
	_call_exercise_action("pause_exercise", "暂停演练时间线")


func _on_exercise_reset_pressed() -> void:
	_resolve_sources()
	if _exercise_controller == null or not _exercise_controller.has_method("reset_exercise"):
		_log("演练时间线控制器未就绪")
		return
	var receipt := _exercise_controller.call("reset_exercise", true) as Dictionary
	_log_receipt(receipt, "复位演练时间线")


func _call_exercise_action(method_name: String, label: String) -> void:
	_resolve_sources()
	if _exercise_controller == null or not _exercise_controller.has_method(method_name):
		_log("演练时间线控制器未就绪")
		return
	var receipt := _exercise_controller.call(method_name) as Dictionary
	_log_receipt(receipt, label)


func _log_receipt(receipt: Dictionary, label: String) -> void:
	var accepted := String(receipt.get("status", "REJECTED")) != "REJECTED"
	_log("%s：%s / %s" % [label, receipt.get("status", "REJECTED"), receipt.get("receipt_id", "NO-RECEIPT")])
	_announce_scenario_action(
		"RECEIPT %s  %s" % [receipt.get("receipt_id", "--"), label],
		COLOR_GREEN if accepted else COLOR_RED,
	)
	_refresh_status()


func _on_report_pressed() -> void:
	var payload := _build_report_payload()
	payload["reportPath"] = ProjectSettings.globalize_path(REPORT_PATH)
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file == null:
		_log("报告写入失败")
		_announce_scenario_action("REPORT ERROR  报告写入失败", COLOR_RED)
		return
	file.store_string(JSON.stringify(_json_safe(payload), "\t"))
	file.close()
	_last_report_path = ProjectSettings.globalize_path(REPORT_PATH)
	_log("报告已生成：%s；场景、天气、船队、航线、障碍和操作日志已记录" % _last_report_path)
	_announce_scenario_action("REPORT READY  教员场景注入记录已生成", COLOR_GREEN)
	_open_panel(_review_panel, "复盘报告面板")
	if _review_panel != null and _review_panel.has_method("ingest_instructor_debrief"):
		_review_panel.call("ingest_instructor_debrief", payload)
	if _review_panel != null and _review_panel.has_method("mark_instructor_report_generated"):
		_review_panel.call("mark_instructor_report_generated", _last_report_path)
	_refresh_status()


func _build_report_payload() -> Dictionary:
	var exercise := {}
	if _exercise_controller != null and _exercise_controller.has_method("get_exercise_snapshot"):
		exercise = _exercise_controller.call("get_exercise_snapshot") as Dictionary
	var mission_realism := {}
	if _advanced_realism != null and _advanced_realism.has_method("get_realism_snapshot"):
		mission_realism = _advanced_realism.call("get_realism_snapshot") as Dictionary
	return {
		"schemaVersion": "ship_instructor_debrief_v2",
		"generatedAt": Time.get_datetime_string_from_system(false, true),
		"simulation": {
			"paused": get_tree().paused,
			"timeScale": Engine.time_scale
		},
		"scenario": _scenario_status(),
		"weather": _weather_status(),
		"fleet": _fleet_snapshot(),
		"route": _route_snapshot(),
		"obstacles": _obstacle_snapshot(),
		"temporaryObstacleCount": _temporary_obstacle_count,
		"injectedIncidents": _incident_log.duplicate(true),
		"actionLog": _event_log.duplicate(true),
		"exerciseTimeline": exercise,
		"equipmentFaultMatrix": exercise.get("fault_matrix", []),
		"advancedMissionRealism": mission_realism,
		"scenarioInjectionSummary": {
			"scenario": _scenario_name(),
			"weather": _weather_name(),
			"controlledShip": _controlled_ship_name(),
			"incidentCount": _incident_log.size(),
			"temporaryObstacleCount": _temporary_obstacle_count
		},
		"assuranceBoundary": {
			"productionAuthority": false,
			"equipmentTimelineChangesMotionModel": false,
			"taskRealismChangesDynamicsWhenActive": bool(mission_realism.get("active", false)),
			"changesPolicy": false,
			"equipmentFaultsAffectDisplaysOnly": true,
			"statement": "研究级教员站与复盘证据，不等同于认可的全任务驾驶台教员站或海上试验。"
		}
	}


func get_instructor_acceptance_snapshot() -> Dictionary:
	var payload := _build_report_payload()
	return {
		"format": payload.get("schemaVersion", ""),
		"exercise": payload.get("exerciseTimeline", {}),
		"fault_matrix": payload.get("equipmentFaultMatrix", []),
		"incident_count": _incident_log.size(),
		"action_count": _event_log.size(),
		"boundary": payload.get("assuranceBoundary", {}),
	}


func _get_controlled_ship() -> Node3D:
	if _fleet_manager == null or not is_instance_valid(_fleet_manager):
		_resolve_sources()
	if _fleet_manager != null and _fleet_manager.has_method("get_controlled_ship"):
		var controlled: Variant = _fleet_manager.call("get_controlled_ship")
		if controlled is Node3D and is_instance_valid(controlled):
			return controlled
	var fallback := get_tree().get_first_node_in_group(&"player")
	if fallback is Node3D:
		return fallback
	return null


func _temporary_obstacle_position(ship: Node3D) -> Vector3:
	var heading_degrees := 0.0
	if ship.has_method("get_ship_telemetry"):
		var telemetry := ship.call("get_ship_telemetry") as Dictionary
		heading_degrees = float(telemetry.get("heading_degrees", 0.0))
	var radians := deg_to_rad(heading_degrees)
	var forward := Vector3(sin(radians), 0.0, cos(radians)).normalized()
	if forward.length_squared() <= 0.001:
		forward = Vector3.FORWARD
	return ship.global_position + forward * 34.0


func _scenario_status() -> Dictionary:
	if _scenario_controller != null and _scenario_controller.has_method("get_scenario_status"):
		return _scenario_controller.call("get_scenario_status") as Dictionary
	return {}


func _weather_status() -> Dictionary:
	if _weather_time != null and _weather_time.has_method("get_weather_time_status"):
		return _weather_time.call("get_weather_time_status") as Dictionary
	return {}


func _fleet_snapshot() -> Array:
	if _fleet_manager != null and _fleet_manager.has_method("get_fleet_snapshot"):
		return _fleet_manager.call("get_fleet_snapshot") as Array
	var records: Array = []
	var ship := _get_controlled_ship()
	if ship != null and ship.has_method("get_ship_telemetry"):
		records.append({"name": ship.name, "telemetry": ship.call("get_ship_telemetry")})
	return records


func _route_snapshot() -> Dictionary:
	if _route_system != null and _route_system.has_method("get_radar_route_data"):
		return _route_system.call("get_radar_route_data") as Dictionary
	return {}


func _obstacle_snapshot() -> Dictionary:
	if _obstacle_system != null and _obstacle_system.has_method("get_radar_obstacle_data"):
		return _obstacle_system.call("get_radar_obstacle_data") as Dictionary
	return {}


func _scenario_name() -> String:
	var status := _scenario_status()
	return String(status.get("name", "开放水域"))


func _weather_name() -> String:
	var status := _weather_status()
	return String(status.get("name", "晴天"))


func _controlled_ship_name() -> String:
	var ship := _get_controlled_ship()
	if ship == null:
		return "LOCAL"
	return ship.name


func _incident_label(key: String) -> String:
	match key:
		"grounding":
			return "搁浅"
		"engine_fault":
			return "动力故障"
		"rudder_fault":
			return "舵机故障"
		_:
			return "碰撞"


func _log(text: String) -> void:
	var entry := "%s  %s" % [Time.get_time_string_from_system(), text]
	_event_log.append({
		"time": Time.get_unix_time_from_system(),
		"clock": Time.get_time_string_from_system(),
		"event": text,
		"scenario": _scenario_name(),
		"weather": _weather_name()
	})
	if _event_log.size() > 40:
		_event_log.remove_at(0)
	_update_log(entry)


func _announce_scenario_action(text: String, color: Color) -> void:
	if _scenario_banner_label == null:
		return
	_scenario_banner_label.text = text
	_scenario_banner_label.add_theme_color_override("font_color", color)
	_scenario_banner_label.add_theme_stylebox_override("normal", _panel_style(COLOR_PANEL, Color(color.r, color.g, color.b, 0.42), 6))


func _sync_button_states() -> void:
	var scenario_index := int(_scenario_status().get("index", -1))
	for key in _scenario_buttons.keys():
		var button := _scenario_buttons[key] as Button
		if button != null:
			button.modulate = Color(1.0, 1.0, 1.0, 1.0) if int(key) == scenario_index else Color(0.72, 0.82, 0.86, 1.0)
	var weather_index := int(_weather_status().get("index", -1))
	for key in _weather_buttons.keys():
		var button := _weather_buttons[key] as Button
		if button != null:
			button.modulate = Color(1.0, 1.0, 1.0, 1.0) if int(key) == weather_index else Color(0.72, 0.82, 0.86, 1.0)


func _open_panel(panel: Node, panel_label: String) -> void:
	if panel == null or not is_instance_valid(panel):
		_resolve_sources()
		if panel_label == "风险态势面板":
			panel = _risk_panel
		elif panel_label == "航行任务面板":
			panel = _navigation_panel
		elif panel_label == "复盘报告面板":
			panel = _review_panel
		elif panel_label == "船队态势面板":
			panel = _ais_panel
	if panel == null or not is_instance_valid(panel):
		_log("%s未就绪" % panel_label)
		return
	if panel.has_method("show_panel"):
		panel.call("show_panel")
		return
	var root := panel.find_child("*Root", false, false) as Control
	if root != null:
		root.visible = true


func _json_safe(value: Variant) -> Variant:
	if value is Dictionary:
		var output := {}
		var source := value as Dictionary
		for key in source.keys():
			output[String(key)] = _json_safe(source[key])
		return output
	if value is Array:
		var items: Array = []
		var source_array := value as Array
		for item in source_array:
			items.append(_json_safe(item))
		return items
	if value is Vector3:
		var vector3 := value as Vector3
		return {"x": vector3.x, "y": vector3.y, "z": vector3.z}
	if value is Vector2:
		var vector2 := value as Vector2
		return {"x": vector2.x, "y": vector2.y}
	if value is Color:
		var color := value as Color
		return {"r": color.r, "g": color.g, "b": color.b, "a": color.a}
	if value is StringName:
		return String(value)
	return value


func _update_log(latest: String = "") -> void:
	if _log_label == null:
		return
	var lines: Array[String] = []
	if not latest.is_empty():
		lines.append(latest)
	else:
		for index in range(maxi(_event_log.size() - 3, 0), _event_log.size()):
			var event := _event_log[index]
			if event.has("event"):
				lines.append(String(event["event"]))
	if lines.is_empty():
		lines.append("SCENARIO STANDBY  教员控制台就绪：所有事故、天气和临障操作都记录为人工场景注入")
	if not _last_report_path.is_empty():
		lines.append("REPORT " + _last_report_path)
	_log_label.text = "\n".join(lines)


func _make_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_font_size_override("font_size", 12)
	button.custom_minimum_size = Vector2(88.0, 28.0)
	button.process_mode = Node.PROCESS_MODE_ALWAYS
	return button


func _make_label(
	text: String,
	font_size: int,
	color: Color,
	alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT
) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = alignment
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.55))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.process_mode = Node.PROCESS_MODE_ALWAYS
	return label


func _panel_style(fill: Color, border: Color, radius: int = 8) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.38)
	style.shadow_size = 12
	return style


func _update_label(key: String, value: String, color: Color = COLOR_TEXT) -> void:
	var control := _labels.get(key) as Control
	if control == null:
		return
	if control is Label:
		var label := control as Label
		label.text = value
		label.add_theme_color_override("font_color", color)
	elif control is Button:
		var button := control as Button
		button.text = value
		button.add_theme_color_override("font_color", color)
		button.add_theme_color_override("font_pressed_color", color)

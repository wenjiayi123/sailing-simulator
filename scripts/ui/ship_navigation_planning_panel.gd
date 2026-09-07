extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_N
const REFRESH_INTERVAL := 0.25
const KNOTS_PER_MPS := 1.943844
const METERS_PER_NAUTICAL_MILE := 1852.0
const WATER_LEVEL_Y := -140.05
const SHIP_Y := -140.73494
const PLAN_EXPORT_PATH := "user://ship_navigation_plan.json"
const COLOR_BG := Color(0.010, 0.020, 0.030, 0.94)
const COLOR_PANEL := Color(0.030, 0.052, 0.064, 0.95)
const COLOR_ACCENT := Color(0.28, 0.96, 1.0, 0.96)
const COLOR_GREEN := Color(0.46, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.72, 0.26, 1.0)
const COLOR_RED := Color(1.0, 0.28, 0.22, 1.0)
const COLOR_TEXT := Color(0.80, 0.94, 1.0, 0.98)
const COLOR_MUTED := Color(0.56, 0.70, 0.76, 0.92)

const MISSION_PRESETS := [
	{
		"name": "开放水域巡航",
		"code": "OPEN-WATER-PATROL",
		"objective": "开放水域航线保持、偏航修正和连续航点巡航",
		"scenario_index": 0,
		"loop": true,
		"arrival_radius": 16.0,
		"planned_speed_knots": 12.0,
		"spawn": Vector3(0.36, SHIP_Y, -0.05),
		"heading": 214.0,
		"points": [
			Vector3(0.0, 0.0, -72.0),
			Vector3(72.0, 0.0, -132.0),
			Vector3(46.0, 0.0, -208.0),
			Vector3(-56.0, 0.0, -190.0),
			Vector3(-92.0, 0.0, -96.0)
		]
	},
	{
		"name": "港口引航",
		"code": "HARBOR-PILOTAGE",
		"objective": "狭水道进港、低速控船和泊位接近",
		"scenario_index": 1,
		"loop": false,
		"arrival_radius": 12.0,
		"planned_speed_knots": 6.0,
		"spawn": Vector3(-148.0, SHIP_Y, -92.0),
		"heading": 84.0,
		"points": [
			Vector3(-118.0, 0.0, -86.0),
			Vector3(-74.0, 0.0, -76.0),
			Vector3(-34.0, 0.0, -50.0),
			Vector3(14.0, 0.0, -33.0),
			Vector3(58.0, 0.0, -10.0),
			Vector3(82.0, 0.0, 30.0)
		]
	},
	{
		"name": "近岸避障",
		"code": "COASTAL-AVOIDANCE",
		"objective": "多障碍物绕航、航迹恢复和 CPA 观察",
		"scenario_index": 0,
		"loop": false,
		"arrival_radius": 14.0,
		"planned_speed_knots": 9.5,
		"spawn": Vector3(-132.0, SHIP_Y, -36.0),
		"heading": 42.0,
		"points": [
			Vector3(-116.0, 0.0, -58.0),
			Vector3(-62.0, 0.0, -130.0),
			Vector3(18.0, 0.0, -104.0),
			Vector3(82.0, 0.0, -168.0),
			Vector3(132.0, 0.0, -76.0)
		]
	},
	{
		"name": "长航线训练",
		"code": "LONG-RANGE-TRAINING",
		"objective": "长距离巡航、航向稳定性和 ETA 管理",
		"scenario_index": 0,
		"loop": true,
		"arrival_radius": 20.0,
		"planned_speed_knots": 15.0,
		"spawn": Vector3(-180.0, SHIP_Y, 86.0),
		"heading": 26.0,
		"points": [
			Vector3(-154.0, 0.0, 18.0),
			Vector3(-96.0, 0.0, -146.0),
			Vector3(42.0, 0.0, -226.0),
			Vector3(172.0, 0.0, -122.0),
			Vector3(136.0, 0.0, 66.0),
			Vector3(-34.0, 0.0, 128.0)
		]
	},
	{
		"name": "靠泊进港",
		"code": "BERTH-APPROACH",
		"objective": "港内减速、末端进泊和停船点控制",
		"scenario_index": 1,
		"loop": false,
		"arrival_radius": 8.0,
		"planned_speed_knots": 4.5,
		"spawn": Vector3(-108.0, SHIP_Y, -104.0),
		"heading": 78.0,
		"points": [
			Vector3(-88.0, 0.0, -84.0),
			Vector3(-42.0, 0.0, -62.0),
			Vector3(12.0, 0.0, -44.0),
			Vector3(52.0, 0.0, -18.0),
			Vector3(78.0, 0.0, 18.0),
			Vector3(84.0, 0.0, 42.0)
		]
	}
]

@export var start_visible: bool = false
@export var player_path: NodePath = NodePath("../Player")
@export var fleet_manager_path: NodePath = NodePath("../ShipFleetManager")
@export var route_system_path: NodePath = NodePath("../ShipRouteSystem")
@export var obstacle_system_path: NodePath = NodePath("../ShipNavigationObstacles")
@export var scenario_path: NodePath = NodePath("../ShipScenarioController")
@export var advanced_mission_controller_path: NodePath = NodePath("../ShipAdvancedMissionController")
@export var advanced_mission_realism_path: NodePath = NodePath("../ShipAdvancedMissionRealismController")
@export var weather_time_path: NodePath = NodePath("../ShipWeatherTimeController")
@export_file("*.json") var mission_profile_path: String = "res://data/ports/default_port_profile.json"
@export var planned_speed_knots: float = 12.0
@export var arrival_radius_meters: float = 16.0
@export var loop_route_enabled: bool = true

var _root: Control
var _tabs: TabContainer
var _mission_option: OptionButton
var _mission_rl_button: Button
var _mission_rl_label: Label
var _mission_rl_pending := false
var _mission_rl_request_id := 0
var _mission_rl_display_state := ""
var _mission_rl_start_error := ""
var _sync_scenario_check: CheckBox
var _teleport_check: CheckBox
var _loop_check: CheckBox
var _overtaking_agreement_check: CheckBox
var _arrival_spin: SpinBox
var _planned_speed_spin: SpinBox
var _chart: NavigationChart
var _labels: Dictionary = {}
var _fleet_manager: Node
var _route_system: Node
var _obstacle_system: Node
var _scenario_source: Node
var _advanced_mission_source: Node
var _advanced_realism_source: Node
var _weather_time_source: Node
var _player: Node3D
var _mission_presets: Array = []
var _mission_profile_status := "built-in fallback"
var _refresh_timer := 0.0
var _active_mission_name := "开放水域巡航"
var _active_mission_code := "OPEN-WATER-PATROL"
var _active_objective := "开放水域航线保持、偏航修正和连续航点巡航"


class NavigationChart:
	extends Control

	var route_points: Array[Vector3] = []
	var obstacle_points: Array[Vector3] = []
	var obstacle_boxes: Array[Dictionary] = []
	var ship_position := Vector3.ZERO
	var active_index := -1
	var route_loop := false
	var mission_name := "--"

	func set_chart_data(
		next_route_points: Array[Vector3],
		next_obstacle_points: Array[Vector3],
		next_obstacle_boxes: Array[Dictionary],
		next_ship_position: Vector3,
		next_active_index: int,
		next_route_loop: bool,
		next_mission_name: String
	) -> void:
		route_points = next_route_points.duplicate()
		obstacle_points = next_obstacle_points.duplicate()
		obstacle_boxes = next_obstacle_boxes.duplicate(true)
		ship_position = next_ship_position
		active_index = next_active_index
		route_loop = next_route_loop
		mission_name = next_mission_name
		queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.010, 0.025, 0.036, 0.92), true)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.28, 0.96, 1.0, 0.36), false, 1.0)
		var plot := Rect2(18.0, 30.0, maxf(size.x - 36.0, 1.0), maxf(size.y - 54.0, 1.0))
		_draw_grid(plot)
		var bounds := _calculate_bounds()
		_draw_route(plot, bounds)
		_draw_obstacles(plot, bounds)
		_draw_ship(plot, bounds)
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(14.0, 20.0), "CHART // " + mission_name, HORIZONTAL_ALIGNMENT_LEFT, size.x - 28.0, 13, Color(0.70, 0.94, 1.0, 0.88))
		draw_string(font, Vector2(14.0, size.y - 12.0), "route %02d wp  obstacles %02d" % [route_points.size(), obstacle_points.size() + obstacle_boxes.size()], HORIZONTAL_ALIGNMENT_LEFT, size.x - 28.0, 11, Color(0.56, 0.70, 0.76, 0.92))

	func _draw_grid(plot: Rect2) -> void:
		for index in range(0, 7):
			var x := plot.position.x + plot.size.x * float(index) / 6.0
			var y := plot.position.y + plot.size.y * float(index) / 6.0
			draw_line(Vector2(x, plot.position.y), Vector2(x, plot.position.y + plot.size.y), Color(0.28, 0.96, 1.0, 0.07), 1.0)
			draw_line(Vector2(plot.position.x, y), Vector2(plot.position.x + plot.size.x, y), Color(0.28, 0.96, 1.0, 0.07), 1.0)

	func _draw_route(plot: Rect2, bounds: Rect2) -> void:
		if route_points.is_empty():
			return
		for index in range(route_points.size() - 1):
			draw_line(_to_chart(route_points[index], plot, bounds), _to_chart(route_points[index + 1], plot, bounds), Color(0.28, 0.96, 1.0, 0.74), 2.0, true)
		if route_loop and route_points.size() > 2:
			draw_line(_to_chart(route_points[route_points.size() - 1], plot, bounds), _to_chart(route_points[0], plot, bounds), Color(0.28, 0.96, 1.0, 0.36), 1.4, true)
		var font := ThemeDB.fallback_font
		for index in range(route_points.size()):
			var point := _to_chart(route_points[index], plot, bounds)
			var active := index == active_index
			var color := Color(1.0, 0.72, 0.26, 1.0) if active else Color(0.46, 1.0, 0.58, 0.92)
			draw_circle(point, 6.0 if active else 4.4, color)
			draw_string(font, point + Vector2(7.0, -7.0), "WP%02d" % (index + 1), HORIZONTAL_ALIGNMENT_LEFT, 48.0, 10, color)

	func _draw_obstacles(plot: Rect2, bounds: Rect2) -> void:
		for obstacle in obstacle_points:
			draw_circle(_to_chart(obstacle, plot, bounds), 4.0, Color(1.0, 0.28, 0.22, 0.84))
		for box in obstacle_boxes:
			var center := box.get("position", Vector3.ZERO) as Vector3
			var size_3d := box.get("size", Vector3.ONE) as Vector3
			var half := Vector2(absf(size_3d.x) * 0.5, absf(size_3d.z) * 0.5)
			var p1 := _to_chart(Vector3(center.x - half.x, 0.0, center.z - half.y), plot, bounds)
			var p2 := _to_chart(Vector3(center.x + half.x, 0.0, center.z + half.y), plot, bounds)
			draw_rect(Rect2(p1, p2 - p1).abs(), Color(1.0, 0.72, 0.26, 0.26), true)
			draw_rect(Rect2(p1, p2 - p1).abs(), Color(1.0, 0.72, 0.26, 0.70), false, 1.0)

	func _draw_ship(plot: Rect2, bounds: Rect2) -> void:
		var point := _to_chart(ship_position, plot, bounds)
		var marker := PackedVector2Array([
			point + Vector2(0.0, -9.0),
			point + Vector2(7.0, 8.0),
			point + Vector2(0.0, 4.0),
			point + Vector2(-7.0, 8.0)
		])
		draw_colored_polygon(marker, Color(0.95, 1.0, 1.0, 0.96))
		draw_polyline(marker + PackedVector2Array([marker[0]]), Color(0.0, 0.0, 0.0, 0.62), 1.0)

	func _calculate_bounds() -> Rect2:
		var min_x := ship_position.x
		var max_x := ship_position.x
		var min_z := ship_position.z
		var max_z := ship_position.z
		for point in route_points:
			min_x = minf(min_x, point.x)
			max_x = maxf(max_x, point.x)
			min_z = minf(min_z, point.z)
			max_z = maxf(max_z, point.z)
		for point in obstacle_points:
			min_x = minf(min_x, point.x)
			max_x = maxf(max_x, point.x)
			min_z = minf(min_z, point.z)
			max_z = maxf(max_z, point.z)
		for box in obstacle_boxes:
			var center := box.get("position", Vector3.ZERO) as Vector3
			var size_3d := box.get("size", Vector3.ONE) as Vector3
			min_x = minf(min_x, center.x - absf(size_3d.x) * 0.5)
			max_x = maxf(max_x, center.x + absf(size_3d.x) * 0.5)
			min_z = minf(min_z, center.z - absf(size_3d.z) * 0.5)
			max_z = maxf(max_z, center.z + absf(size_3d.z) * 0.5)
		var width := maxf(max_x - min_x, 80.0)
		var height := maxf(max_z - min_z, 80.0)
		var padding := maxf(width, height) * 0.12
		return Rect2(Vector2(min_x - padding, min_z - padding), Vector2(width + padding * 2.0, height + padding * 2.0))

	func _to_chart(point: Vector3, plot: Rect2, bounds: Rect2) -> Vector2:
		var x_ratio := (point.x - bounds.position.x) / maxf(bounds.size.x, 1.0)
		var z_ratio := (point.z - bounds.position.y) / maxf(bounds.size.y, 1.0)
		return Vector2(plot.position.x + x_ratio * plot.size.x, plot.position.y + (1.0 - z_ratio) * plot.size.y)


func _ready() -> void:
	layer = 61
	add_to_group(&"ship_navigation_planning_panel")
	_resolve_sources()
	_load_mission_presets()
	_build_interface()
	if _scenario_source != null and _scenario_source.has_signal("scenario_changed"):
		_scenario_source.connect("scenario_changed", _on_external_scenario_changed)
	_update_panel()
	set_process(true)
	set_process_unhandled_input(true)


func _process(delta: float) -> void:
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_INTERVAL
		_update_panel()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return
		if key_event.physical_keycode == TOGGLE_PANEL_KEY:
			_root.visible = not _root.visible
			get_viewport().set_input_as_handled()


func show_panel() -> void:
	if _root == null:
		return
	_root.visible = true
	_refresh_timer = 0.0
	_update_panel()


func hide_panel() -> void:
	if _root != null:
		_root.visible = false


func toggle_panel() -> void:
	if _root == null:
		return
	if _root.visible:
		hide_panel()
	else:
		show_panel()


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipNavigationPlanningRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = start_visible
	add_child(_root)

	var panel := PanelContainer.new()
	panel.name = "NavigationPlanningPanel"
	panel.anchor_left = 0.0
	panel.anchor_top = 0.5
	panel.anchor_right = 0.0
	panel.anchor_bottom = 0.5
	panel.offset_left = 20.0
	panel.offset_top = -336.0
	panel.offset_right = 486.0
	panel.offset_bottom = 336.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
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
	var title := _make_label("航行任务 / Navigation Plan", 16, COLOR_ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var hide_button := _make_button("收起")
	hide_button.pressed.connect(func() -> void: _root.visible = false)
	header.add_child(hide_button)

	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", 8)
	stack.add_child(summary)
	_add_status_pill(summary, "mission_code", "OPEN")
	_add_status_pill(summary, "mission_eta", "ETA --")
	_add_status_pill(summary, "mission_distance", "-- nm")

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(_tabs)
	_tabs.add_child(_build_mission_tab())
	_tabs.add_child(_build_chart_tab())
	_tabs.add_child(_build_waypoints_tab())


func _build_mission_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.name = "任务"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 8)
	scroll.add_child(root)

	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 8)
	root.add_child(preset_row)
	_mission_option = OptionButton.new()
	_mission_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for preset_index in range(_mission_presets.size()):
		var preset: Dictionary = _mission_presets[preset_index]
		_mission_option.add_item(String(preset["name"]), preset_index)
	_mission_option.item_selected.connect(_on_mission_selected)
	preset_row.add_child(_mission_option)
	var apply_button := _make_button("应用任务")
	apply_button.pressed.connect(_on_apply_mission_pressed)
	preset_row.add_child(apply_button)
	var rl_row := VBoxContainer.new()
	rl_row.add_theme_constant_override("separation", 5)
	root.add_child(rl_row)
	_mission_rl_button = _make_button("启用场景强化学习")
	_mission_rl_button.name = "MissionRLButton"
	_mission_rl_button.custom_minimum_size.y = 38.0
	_mission_rl_button.add_theme_font_size_override("font_size", 14)
	_mission_rl_button.toggle_mode = true
	_mission_rl_button.pressed.connect(_on_mission_rl_pressed)
	rl_row.add_child(_mission_rl_button)
	_mission_rl_label = _make_label("正在读取策略验收结果", 13, COLOR_MUTED)
	_mission_rl_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mission_rl_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rl_row.add_child(_mission_rl_label)

	var check_row := HBoxContainer.new()
	check_row.add_theme_constant_override("separation", 10)
	root.add_child(check_row)
	_sync_scenario_check = CheckBox.new()
	_sync_scenario_check.text = "联动场景"
	_sync_scenario_check.button_pressed = true
	_sync_scenario_check.toggled.connect(_on_mission_toggle_changed)
	check_row.add_child(_sync_scenario_check)
	_teleport_check = CheckBox.new()
	_teleport_check.text = "重定位船舶"
	_teleport_check.button_pressed = true
	_teleport_check.toggled.connect(_on_mission_toggle_changed)
	check_row.add_child(_teleport_check)
	_loop_check = CheckBox.new()
	_loop_check.text = "循环航线"
	_loop_check.button_pressed = loop_route_enabled
	_loop_check.toggled.connect(_on_loop_toggled)
	check_row.add_child(_loop_check)
	_overtaking_agreement_check = CheckBox.new()
	_overtaking_agreement_check.text = "追越协议确认"
	_overtaking_agreement_check.button_pressed = false
	_overtaking_agreement_check.toggled.connect(_on_overtaking_agreement_toggled)
	check_row.add_child(_overtaking_agreement_check)

	var parameter_grid := GridContainer.new()
	parameter_grid.columns = 2
	parameter_grid.add_theme_constant_override("h_separation", 10)
	parameter_grid.add_theme_constant_override("v_separation", 7)
	root.add_child(parameter_grid)
	_add_metric(parameter_grid, "mission_name", "当前任务")
	_add_metric(parameter_grid, "mission_objective", "训练目标")
	_add_metric(parameter_grid, "scenario_status", "场景海况")
	_add_metric(parameter_grid, "route_status", "航线状态")
	_add_metric(parameter_grid, "route_source", "任务数据")
	_add_metric(parameter_grid, "advanced_task", "高级任务")
	_add_metric(parameter_grid, "advanced_gate", "验收门槛")
	_add_metric(parameter_grid, "advanced_traffic", "会遇监视")
	_add_metric(parameter_grid, "advanced_hydrodynamics", "浅水/岸效应")
	_add_metric(parameter_grid, "advanced_bridge_readiness", "任务前检查")
	_add_metric(parameter_grid, "advanced_debrief", "客观复盘")
	_add_metric(parameter_grid, "advanced_boundary", "能力边界")

	var control_row := HBoxContainer.new()
	control_row.add_theme_constant_override("separation", 8)
	root.add_child(control_row)
	_arrival_spin = _make_spin(arrival_radius_meters, 4.0, 80.0, 1.0)
	_arrival_spin.value_changed.connect(_on_arrival_radius_changed)
	control_row.add_child(_make_label("到达半径", 11, COLOR_MUTED))
	control_row.add_child(_arrival_spin)
	_planned_speed_spin = _make_spin(planned_speed_knots, 1.0, 32.0, 0.5)
	_planned_speed_spin.value_changed.connect(_on_planned_speed_changed)
	control_row.add_child(_make_label("计划航速", 11, COLOR_MUTED))
	control_row.add_child(_planned_speed_spin)

	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	root.add_child(action_row)
	var apply_settings := _make_button("应用航线参数")
	apply_settings.pressed.connect(_on_apply_route_settings_pressed)
	action_row.add_child(apply_settings)
	var export_button := _make_button("导出任务快照")
	export_button.pressed.connect(_export_plan_snapshot)
	action_row.add_child(export_button)

	var realism_action_row := HBoxContainer.new()
	realism_action_row.add_theme_constant_override("separation", 8)
	root.add_child(realism_action_row)
	var predeparture_button := _make_button("任务前检查")
	predeparture_button.pressed.connect(_on_realism_predeparture_pressed)
	realism_action_row.add_child(predeparture_button)
	var action_mark_button := _make_button("记录关键操船")
	action_mark_button.pressed.connect(_on_realism_action_mark_pressed)
	realism_action_row.add_child(action_mark_button)
	var debrief_button := _make_button("导出结构化复盘")
	debrief_button.pressed.connect(_on_realism_debrief_pressed)
	realism_action_row.add_child(debrief_button)

	var footer := _make_label("", 11, COLOR_MUTED)
	footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	footer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	footer.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	root.add_child(footer)
	_labels["mission_footer"] = footer

	return scroll


func _build_chart_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "海图"
	root.add_theme_constant_override("separation", 8)
	_chart = NavigationChart.new()
	_chart.custom_minimum_size = Vector2(0.0, 358.0)
	_chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_chart)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	root.add_child(grid)
	_add_metric(grid, "chart_active_wp", "当前航点")
	_add_metric(grid, "chart_cross_track", "横向偏差")
	_add_metric(grid, "chart_obstacles", "图上障碍")
	_add_metric(grid, "chart_loop", "闭合状态")
	return root


func _build_waypoints_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "航点"
	root.add_theme_constant_override("separation", 8)
	var waypoint_label := _make_label("", 12, COLOR_TEXT)
	waypoint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	waypoint_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(waypoint_label)
	_labels["waypoint_manifest"] = waypoint_label
	var footer := _make_label("航点坐标会直接来自 ShipRouteSystem 当前航线。", 11, COLOR_MUTED)
	root.add_child(footer)
	return root


func _add_status_pill(parent: Control, key: String, text: String) -> void:
	var label := _make_label(text, 13, COLOR_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	label.custom_minimum_size = Vector2(116.0, 30.0)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_stylebox_override("normal", _panel_style(COLOR_PANEL, COLOR_ACCENT))
	parent.add_child(label)
	_labels[key] = label


func _add_metric(parent: Control, key: String, title: String) -> void:
	var title_label := _make_label(title, 11, COLOR_MUTED)
	title_label.custom_minimum_size = Vector2(96.0, 22.0)
	parent.add_child(title_label)
	var value_label := _make_label("--", 12, COLOR_TEXT)
	value_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value_label.custom_minimum_size = Vector2(300.0, 22.0)
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(value_label)
	_labels[key] = value_label


func _resolve_sources() -> void:
	_player = _resolve_node3d(player_path, &"player")
	_fleet_manager = _resolve_node(fleet_manager_path, &"ship_fleet_manager")
	_route_system = _resolve_node(route_system_path, &"ship_route_system")
	_obstacle_system = _resolve_node(obstacle_system_path, &"ship_navigation_obstacle_system")
	_scenario_source = _resolve_node(scenario_path, &"ship_scenario_system")
	_advanced_mission_source = _resolve_node(advanced_mission_controller_path, &"ship_advanced_mission_controller")
	_advanced_realism_source = _resolve_node(advanced_mission_realism_path, &"ship_advanced_mission_realism_controller")
	_weather_time_source = _resolve_node(weather_time_path, &"ship_weather_time_system")


func _load_mission_presets() -> void:
	_mission_presets = MISSION_PRESETS.duplicate(true)
	var profile: Dictionary = {}
	var loaded_path := ""
	if _scenario_source != null and _scenario_source.has_method("get_port_profile"):
		profile = _scenario_source.call("get_port_profile") as Dictionary
		loaded_path = String(_scenario_source.call("get_port_profile_path"))
	if profile.is_empty():
		var candidates: Array[String] = []
		var environment_path := OS.get_environment("SHIP_PORT_PROFILE")
		if not environment_path.is_empty():
			candidates.append(environment_path)
		candidates.append(ProjectSettings.globalize_path("user://port_profile.json"))
		candidates.append(mission_profile_path)
		for candidate in candidates:
			if not FileAccess.file_exists(candidate):
				continue
			var file := FileAccess.open(candidate, FileAccess.READ)
			if file == null:
				continue
			var parsed = JSON.parse_string(file.get_as_text())
			file.close()
			if parsed is Dictionary and String((parsed as Dictionary).get("schema_version", "")) == "ship_port_profile_v1":
				profile = parsed as Dictionary
				loaded_path = ProjectSettings.globalize_path(candidate)
				break
	var converted: Array = []
	for raw_mission in profile.get("navigation_missions", []) as Array:
		if raw_mission is not Dictionary:
			continue
		var mission := raw_mission as Dictionary
		var spawn_data := mission.get("spawn", {}) as Dictionary
		var points: Array[Vector3] = []
		for raw_point in mission.get("route", []) as Array:
			if raw_point is Dictionary:
				var point := raw_point as Dictionary
				points.append(Vector3(float(point.get("x", 0.0)), 0.0, float(point.get("z", 0.0))))
		if points.is_empty():
			continue
		converted.append({
			"name": String(mission.get("name", "港口航行任务")),
			"code": String(mission.get("code", "PORT-MISSION")),
			"objective": String(mission.get("objective", "数据集驱动航线")),
			"scenario_key": String(mission.get("scenario_key", "open_water")),
			"scenario_index": int(mission.get("scenario_index", 0)),
			"loop": bool(mission.get("loop", false)),
			"arrival_radius": float(mission.get("arrival_radius", 16.0)),
			"planned_speed_knots": float(mission.get("planned_speed_knots", 10.0)),
			"spawn": Vector3(float(spawn_data.get("x", 0.0)), SHIP_Y, float(spawn_data.get("z", 0.0))),
			"heading": float(spawn_data.get("heading_degrees", 0.0)),
			"points": points,
		})
	if not converted.is_empty():
		_mission_presets = converted
		_mission_profile_status = "%s  |  %s" % [String(profile.get("name", "port profile")), loaded_path]


func _resolve_node(path: NodePath, group_name: StringName) -> Node:
	var node := get_node_or_null(path)
	if node == null:
		node = get_tree().get_first_node_in_group(group_name)
	return node


func _resolve_node3d(path: NodePath, group_name: StringName) -> Node3D:
	var node := _resolve_node(path, group_name)
	if node is Node3D:
		return node
	return null


func _update_panel() -> void:
	_update_mission_rl_controls()
	var ship := _get_active_ship()
	var route_data := _get_route_telemetry(ship.global_position if ship != null else Vector3.ZERO)
	var route_radar := _get_route_radar_data()
	var obstacle_data := _get_obstacle_data()
	var route_points := _route_points_from_radar(route_radar)
	var remaining_meters := _estimate_remaining_distance(ship.global_position if ship != null else Vector3.ZERO, route_data, route_radar)
	var speed_mps := _planned_speed_mps()
	var eta_seconds := int(ceil(remaining_meters / maxf(speed_mps, 0.01)))
	var route_active := bool(route_data.get("active", false))
	var active_index := int(route_radar.get("current_index", -1))
	var loop_active := bool(route_radar.get("loop", false))
	var obstacle_points := _obstacle_points(obstacle_data)
	var obstacle_boxes := _obstacle_boxes(obstacle_data)
	var advanced_mission := _get_advanced_mission_snapshot()
	var advanced_realism := _get_advanced_realism_snapshot()

	_update_label("mission_code", _active_mission_code)
	_update_label("mission_eta", "ETA " + _format_seconds(eta_seconds), COLOR_GREEN if route_active else COLOR_AMBER)
	_update_label("mission_distance", "%05.2f nm" % (remaining_meters / METERS_PER_NAUTICAL_MILE))
	_update_label("mission_name", _active_mission_name)
	_update_label("mission_objective", _active_objective)
	_update_label("scenario_status", _scenario_weather_text())
	_update_label("route_status", "%s  radius %.0fm  %s" % ["ACTIVE" if route_active else "STANDBY", _current_arrival_radius(route_radar), "LOOP" if loop_active else "ONE-WAY"], COLOR_GREEN if route_active else COLOR_AMBER)
	_update_label("route_source", _mission_profile_status)
	_update_advanced_mission_labels(advanced_mission)
	_update_advanced_realism_labels(advanced_realism)
	_update_label("mission_footer", "N 打开航行任务面板  |  当前计划航速 %.1fkn  |  到达半径 %.0fm  |  航点 %d" % [planned_speed_knots, arrival_radius_meters, route_points.size()])
	_update_chart_labels(route_data, route_radar, obstacle_points.size() + obstacle_boxes.size())
	_update_waypoint_manifest(route_points, active_index)
	if _chart != null:
		_chart.set_chart_data(route_points, obstacle_points, obstacle_boxes, ship.global_position if ship != null else Vector3.ZERO, active_index, loop_active, _active_mission_name)


func _get_active_ship() -> Node3D:
	if _fleet_manager == null or not is_instance_valid(_fleet_manager):
		_resolve_sources()
	if _fleet_manager != null and _fleet_manager.has_method("get_controlled_ship"):
		var controlled_ship: Variant = _fleet_manager.call("get_controlled_ship")
		if controlled_ship is Node3D and is_instance_valid(controlled_ship):
			return controlled_ship
	if _player == null or not is_instance_valid(_player) or not _player.is_in_group(&"player"):
		_player = _resolve_node3d(player_path, &"player")
	return _player


func _get_route_telemetry(ship_position: Vector3) -> Dictionary:
	if _route_system == null or not is_instance_valid(_route_system):
		_route_system = _resolve_node(route_system_path, &"ship_route_system")
	if _route_system != null and _route_system.has_method("get_route_telemetry"):
		return _route_system.call("get_route_telemetry", ship_position) as Dictionary
	return {"active": false}


func _get_route_radar_data() -> Dictionary:
	if _route_system == null or not is_instance_valid(_route_system):
		_route_system = _resolve_node(route_system_path, &"ship_route_system")
	if _route_system != null and _route_system.has_method("get_radar_route_data"):
		return _route_system.call("get_radar_route_data") as Dictionary
	return {"active": false, "points": []}


func _get_obstacle_data() -> Dictionary:
	if _obstacle_system == null or not is_instance_valid(_obstacle_system):
		_obstacle_system = _resolve_node(obstacle_system_path, &"ship_navigation_obstacle_system")
	if _obstacle_system != null and _obstacle_system.has_method("get_radar_obstacle_data"):
		return _obstacle_system.call("get_radar_obstacle_data") as Dictionary
	return {"rocks": [], "boxes": []}


func _on_mission_selected(index: int) -> void:
	_cancel_mission_rl_request()
	var preset := _preset_by_index(index)
	if _overtaking_agreement_check != null:
		_overtaking_agreement_check.set_pressed_no_signal(false)
	_apply_preset_values_to_controls(preset)
	_update_label("mission_footer", "任务参数已载入；点击“应用任务”后才写入场景、船位与航线。", COLOR_AMBER)
	_update_mission_rl_controls()


func _on_external_scenario_changed(_snapshot: Dictionary) -> void:
	_cancel_mission_rl_request()
	var current_key := String((_scenario_source.call("get_scenario_status") as Dictionary).get("key", ""))
	for index in range(_mission_presets.size()):
		var preset := _mission_presets[index] as Dictionary
		if String(preset.get("scenario_key", "")) != current_key:
			continue
		_mission_option.select(index)
		_active_mission_name = String(preset["name"])
		_active_mission_code = String(preset["code"])
		_active_objective = String(preset["objective"])
		_apply_preset_values_to_controls(preset)
		if _overtaking_agreement_check != null:
			_overtaking_agreement_check.set_pressed_no_signal(false)
		_update_panel()
		return


func _on_mission_toggle_changed(_enabled: bool) -> void:
	_update_label("mission_footer", "联动选项已变更；点击“应用任务”后生效。", COLOR_AMBER)


func _on_overtaking_agreement_toggled(confirmed: bool) -> void:
	if _advanced_mission_source == null or not is_instance_valid(_advanced_mission_source):
		_advanced_mission_source = _resolve_node(advanced_mission_controller_path, &"ship_advanced_mission_controller")
	if _advanced_mission_source == null or not _advanced_mission_source.has_method("confirm_overtaking_agreement"):
		_update_label("mission_footer", "追越协议确认失败：高级任务控制器不可用。", COLOR_RED)
		return
	var receipt := _advanced_mission_source.call(
		"confirm_overtaking_agreement",
		confirmed,
		"navigation_planning_panel" if confirmed else ""
	) as Dictionary
	var accepted := String(receipt.get("status", "")) == "ACCEPTED_SIMULATION_ONLY"
	var message := "追越模拟协议已%s；不代表真实甚高频通信授权。" % ("确认" if confirmed else "撤销") \
		if accepted else "当前不是追越场景，未写入协议。"
	_update_label("mission_footer", message, COLOR_GREEN if accepted and confirmed else COLOR_AMBER)


func _on_apply_mission_pressed() -> void:
	_cancel_mission_rl_request()
	var preset := _preset_by_index(_mission_option.selected)
	_active_mission_name = String(preset["name"])
	_active_mission_code = String(preset["code"])
	_active_objective = String(preset["objective"])
	_apply_preset_values_to_controls(preset)
	var linked := _sync_scenario_check != null and _sync_scenario_check.button_pressed
	if linked:
		_apply_scenario_from_preset(preset)
	# Linked scenarios already reset the vessel to their authoritative spawn.
	# A legacy mission-preset spawn must not overwrite the validated scene state.
	if not linked and _teleport_check != null and _teleport_check.button_pressed:
		_place_active_ship(preset.get("spawn", Vector3.ZERO) as Vector3, float(preset.get("heading", 0.0)))
	var ship := _get_active_ship()
	var leg_start := ship.global_position if ship != null else preset.get("spawn", Vector3.ZERO) as Vector3
	_apply_route_to_system(preset.get("points", []) as Array, loop_route_enabled, leg_start)
	_export_plan_snapshot(false)
	_update_panel()


func _on_loop_toggled(enabled: bool) -> void:
	loop_route_enabled = enabled


func _on_arrival_radius_changed(value: float) -> void:
	arrival_radius_meters = value


func _on_planned_speed_changed(value: float) -> void:
	planned_speed_knots = value
	_update_panel()


func _on_apply_route_settings_pressed() -> void:
	if _loop_check != null:
		loop_route_enabled = _loop_check.button_pressed
	var ship := _get_active_ship()
	var leg_start := ship.global_position if ship != null else Vector3.ZERO
	_apply_route_to_system(_current_route_points_for_config(), loop_route_enabled, leg_start)
	_update_panel()


func _on_realism_predeparture_pressed() -> void:
	var source := _get_advanced_realism_source()
	if source == null or not source.has_method("run_predeparture_check"):
		_update_label("mission_footer", "任务前检查不可用：现实性控制器未连接。", COLOR_RED)
		return
	var receipt := source.call("run_predeparture_check", "navigation_operator") as Dictionary
	var passed := String(receipt.get("status", "")) == "PASS"
	_update_label("mission_footer", "任务前检查%s。" % ("通过" if passed else "被门禁阻断"), COLOR_GREEN if passed else COLOR_RED)
	_update_panel()


func _on_realism_action_mark_pressed() -> void:
	var source := _get_advanced_realism_source()
	if source == null or not source.has_method("record_operator_action"):
		_update_label("mission_footer", "操作者行动回执不可用。", COLOR_RED)
		return
	var receipt := source.call("record_operator_action", "decisive_manoeuvre", "navigation_operator") as Dictionary
	var accepted := String(receipt.get("status", "")) == "ACCEPTED_SIMULATION_ONLY"
	_update_label("mission_footer", "关键操船行动%s记录。" % ("已" if accepted else "未"), COLOR_GREEN if accepted else COLOR_RED)
	_update_panel()


func _on_realism_debrief_pressed() -> void:
	var source := _get_advanced_realism_source()
	if source == null or not source.has_method("finalize_mission_debrief"):
		_update_label("mission_footer", "结构化复盘不可用。", COLOR_RED)
		return
	var receipt := source.call("finalize_mission_debrief", "navigation_operator") as Dictionary
	var exported := String(receipt.get("status", "")) == "EXPORTED"
	var detail := receipt.get("detail", {}) as Dictionary
	_update_label(
		"mission_footer",
		"复盘%s：%s  score=%s" % ["已导出" if exported else "导出失败", detail.get("path", "--"), str(detail.get("score", "--"))],
		COLOR_GREEN if exported else COLOR_RED,
	)
	_update_panel()


func _apply_preset_values_to_controls(preset: Dictionary) -> void:
	arrival_radius_meters = float(preset.get("arrival_radius", arrival_radius_meters))
	planned_speed_knots = float(preset.get("planned_speed_knots", planned_speed_knots))
	loop_route_enabled = bool(preset.get("loop", loop_route_enabled))
	if _arrival_spin != null:
		_arrival_spin.set_block_signals(true)
		_arrival_spin.value = arrival_radius_meters
		_arrival_spin.set_block_signals(false)
	if _planned_speed_spin != null:
		_planned_speed_spin.set_block_signals(true)
		_planned_speed_spin.value = planned_speed_knots
		_planned_speed_spin.set_block_signals(false)
	if _loop_check != null:
		_loop_check.set_pressed_no_signal(loop_route_enabled)


func _apply_scenario_from_preset(preset: Dictionary) -> void:
	if _scenario_source == null or not is_instance_valid(_scenario_source):
		_scenario_source = _resolve_node(scenario_path, &"ship_scenario_system")
	if _scenario_source != null and _scenario_source.has_method("apply_scenario"):
		var scenario_index := int(preset.get("scenario_index", 0))
		if _scenario_source.has_method("get_scenario_index_by_key"):
			scenario_index = int(_scenario_source.call("get_scenario_index_by_key", String(preset.get("scenario_key", "open_water"))))
		var teleport := bool(_teleport_check != null and _teleport_check.button_pressed)
		_scenario_source.call("apply_scenario", scenario_index, teleport)


func _place_active_ship(position: Vector3, heading_degrees: float) -> void:
	var ship := _get_active_ship()
	if ship == null:
		return
	if ship.has_method("set_ship_navigation_spawn"):
		ship.call("set_ship_navigation_spawn", position, heading_degrees)
	else:
		ship.global_position = position


func _apply_route_to_system(raw_points: Array, loop_enabled: bool, leg_start: Vector3) -> void:
	if _route_system == null or not is_instance_valid(_route_system):
		_route_system = _resolve_node(route_system_path, &"ship_route_system")
	if _route_system == null or not _route_system.has_method("configure_route"):
		return
	var points: Array[Vector3] = []
	for raw_point in raw_points:
		if raw_point is Vector3:
			var point := raw_point as Vector3
			points.append(Vector3(point.x, 0.0, point.z))
	if points.is_empty():
		return
	_route_system.set("arrival_radius", arrival_radius_meters)
	_route_system.call("configure_route", points, loop_enabled, leg_start)


func _preset_by_index(index: int) -> Dictionary:
	if _mission_presets.is_empty():
		_mission_presets = MISSION_PRESETS.duplicate(true)
	var safe_index := clampi(index, 0, _mission_presets.size() - 1)
	return _mission_presets[safe_index]


func _current_route_points_for_config() -> Array:
	var points: Array[Vector3] = _route_points_from_radar(_get_route_radar_data())
	var raw_points: Array = []
	for point in points:
		raw_points.append(Vector3(point.x, 0.0, point.z))
	return raw_points


func _route_points_from_radar(route_radar: Dictionary) -> Array[Vector3]:
	var points: Array[Vector3] = []
	var raw_points: Array = route_radar.get("points", []) as Array
	for raw_point in raw_points:
		if raw_point is Dictionary:
			var point_data := raw_point as Dictionary
			var position := point_data.get("position", Vector3.ZERO) as Vector3
			points.append(position)
	return points


func _obstacle_points(obstacle_data: Dictionary) -> Array[Vector3]:
	var points: Array[Vector3] = []
	var rocks: Array = obstacle_data.get("rocks", []) as Array
	for raw_rock in rocks:
		if raw_rock is Dictionary:
			var rock := raw_rock as Dictionary
			points.append(rock.get("position", Vector3.ZERO) as Vector3)
	return points


func _obstacle_boxes(obstacle_data: Dictionary) -> Array[Dictionary]:
	var boxes: Array[Dictionary] = []
	var raw_boxes: Array = obstacle_data.get("boxes", []) as Array
	for raw_box in raw_boxes:
		if raw_box is Dictionary:
			boxes.append((raw_box as Dictionary).duplicate(true))
	return boxes


func _estimate_remaining_distance(ship_position: Vector3, route_data: Dictionary, route_radar: Dictionary) -> float:
	if not bool(route_radar.get("active", false)):
		return 0.0
	var points := _route_points_from_radar(route_radar)
	if points.is_empty():
		return 0.0
	var current_index := clampi(int(route_radar.get("current_index", 0)), 0, points.size() - 1)
	var distance := _horizontal_distance(ship_position, points[current_index])
	for index in range(current_index, points.size() - 1):
		distance += _horizontal_distance(points[index], points[index + 1])
	if bool(route_radar.get("loop", false)) and points.size() > 2:
		distance += _horizontal_distance(points[points.size() - 1], points[0])
	return distance


func _current_arrival_radius(route_radar: Dictionary) -> float:
	return float(route_radar.get("arrival_radius", arrival_radius_meters))


func _planned_speed_mps() -> float:
	return maxf(planned_speed_knots / KNOTS_PER_MPS, 0.01)


func _cancel_mission_rl_request() -> void:
	# A pending click must never start a different task after selection/application.
	_mission_rl_request_id += 1
	_mission_rl_pending = false
	_mission_rl_start_error = ""


func _mission_rl_selection_applied() -> bool:
	var preset := _preset_by_index(_mission_option.selected)
	if _scenario_source == null:
		return false
	var current_key := String((_scenario_source.call("get_scenario_status") as Dictionary).get("key", ""))
	return String(preset.get("scenario_key", "")) == current_key and String(preset.get("code", "")) == _active_mission_code


func _set_mission_rl_presentation(state: String, title: String, message: String, color: Color, disabled: bool, running: bool = false) -> void:
	_mission_rl_button.text = title
	_mission_rl_button.disabled = disabled
	_mission_rl_button.set_pressed_no_signal(running)
	_mission_rl_button.tooltip_text = message
	_mission_rl_label.text = message
	_mission_rl_label.tooltip_text = message
	if state == _mission_rl_display_state:
		return
	_mission_rl_display_state = state
	_mission_rl_label.add_theme_color_override("font_color", color)
	for theme_name in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_disabled_color", "font_focus_color"]:
		_mission_rl_button.add_theme_color_override(theme_name, color)
	for theme_name in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var fill := Color(color.r * 0.12, color.g * 0.12, color.b * 0.12, 1.0)
		if theme_name in ["pressed", "hover_pressed"]:
			fill = Color(color.r * 0.28, color.g * 0.28, color.b * 0.28, 1.0)
		elif theme_name in ["hover", "focus"]:
			fill = Color(color.r * 0.20, color.g * 0.20, color.b * 0.20, 1.0)
		var style := _panel_style(fill, color)
		style.shadow_size = 0
		_mission_rl_button.add_theme_stylebox_override(theme_name, style)


func _update_mission_rl_controls() -> void:
	if _mission_rl_button == null:
		return
	var controller := get_tree().get_first_node_in_group(&"mission_rl_controller")
	if controller == null:
		_set_mission_rl_presentation("unavailable", "暂不可用 · 强化学习模块未就绪", "未找到场景强化学习模块，请重新启动模拟器。", COLOR_AMBER, true)
		return
	var running := bool(controller.get("active"))
	var applied := _mission_rl_selection_applied()
	if running:
		var total := (controller.get("route") as Array).size()
		var progress := "已运行 %.1f 秒 · 航点 %d/%d" % [float(controller.get("elapsed")), int(controller.get("waypoint")) + 1, total]
		var message := "%s：SAC 正在自主操船\n%s；按 N 收起面板观看。" % [_active_mission_name, progress]
		if not applied:
			message = "%s仍由 SAC 控制；所选新任务尚未应用。\n点击“应用任务”后切换；此按钮可停止当前策略。" % _active_mission_name
		_set_mission_rl_presentation("running", "已接管 · 点击停止强化学习", message, COLOR_GREEN, false, true)
		return
	if _mission_rl_pending:
		_set_mission_rl_presentation("starting", "正在启用强化学习…", "已收到操作，正在核验当前任务与策略，请稍候。", COLOR_AMBER, true)
		return
	if not applied:
		_set_mission_rl_presentation("unapplied", "请先应用所选任务", "任务选择已改变。点击“应用任务”后，才会显示该任务的强化学习状态。", COLOR_AMBER, true)
		return
	var entry := controller.call("current_strategy") as Dictionary
	if not bool(entry.get("live_switch_admitted", false)):
		var reason := String(entry.get("status_zh", "本场景尚无通过验收的强化学习策略"))
		if String(entry.get("status", "")) == "NOT_CONVERGED":
			reason = "完整任务尚未收敛，策略未通过验收，暂不能接管。"
		_set_mission_rl_presentation("unavailable", "暂不可用 · 未通过策略验收", "%s：%s\n请切换至已通过验收的任务。" % [_active_mission_name, reason], COLOR_AMBER, true)
		return
	var notice := String(controller.get("status"))
	if not _mission_rl_start_error.is_empty():
		notice = _mission_rl_start_error
	if notice == "强化学习任务完成":
		_set_mission_rl_presentation("completed", "任务已完成 · 请重新应用任务", "强化学习已完成本次航行。重新观看：勾选“重定位船舶”，再点击“应用任务”。", COLOR_GREEN, true)
	elif notice.begins_with("任务失败"):
		_set_mission_rl_presentation("failed", "运行已中止 · 请重新应用任务", notice + "。请重新应用任务后再启用。", COLOR_RED, true)
	elif not _mission_rl_start_error.is_empty() or notice.begins_with("拒绝") or notice.begins_with("请先") or notice.begins_with("航线"):
		_set_mission_rl_presentation("rejected", "启用失败 · 点击重试", notice, COLOR_RED, false)
	elif notice.begins_with("已停止") or notice == "强化学习已停止":
		_set_mission_rl_presentation("stopped", "已停止 · 启用场景强化学习", "已停止强化学习接管。如已驶离起点，请先勾选“重定位船舶”并重新应用任务。", COLOR_AMBER, false)
	else:
		_set_mission_rl_presentation("ready", "启用场景强化学习", "策略已通过验收。点击启用后，当前三维画面将显示 SAC 实时自主航行。", COLOR_ACCENT, false)


func _on_mission_rl_pressed() -> void:
	if _mission_rl_pending:
		return
	var controller := get_tree().get_first_node_in_group(&"mission_rl_controller")
	if controller == null:
		_update_mission_rl_controls()
		return
	if bool(controller.get("active")):
		_cancel_mission_rl_request()
		controller.set("auto_switch", false)
		controller.call("stop", "已停止场景强化学习")
	else:
		var entry := controller.call("current_strategy") as Dictionary
		if not _mission_rl_selection_applied() or not bool(entry.get("live_switch_admitted", false)):
			_update_mission_rl_controls()
			return
		_mission_rl_start_error = ""
		_mission_rl_pending = true
		_mission_rl_request_id += 1
		var request_id := _mission_rl_request_id
		_update_mission_rl_controls()
		# Allow a rendered acknowledgement before synchronous model verification.
		await get_tree().create_timer(0.1).timeout
		if request_id != _mission_rl_request_id:
			return
		_mission_rl_pending = false
		if not is_instance_valid(controller):
			_update_mission_rl_controls()
			return
		var started := bool(controller.call("start_current"))
		if not started:
			_mission_rl_start_error = String(controller.get("status"))
			if _mission_rl_start_error.is_empty():
				_mission_rl_start_error = "策略未能启用，请重新应用任务后重试。"
	_update_panel()


func _update_chart_labels(route_data: Dictionary, route_radar: Dictionary, obstacle_count: int) -> void:
	var current_name := String(route_data.get("current_name", "--"))
	var current_distance := float(route_data.get("current_distance", 0.0))
	var deviation := float(route_data.get("deviation_distance", 0.0))
	var side := String(route_data.get("deviation_side", "ON TRACK"))
	_update_label("chart_active_wp", "%s  %05.1f m" % [current_name, current_distance])
	_update_label("chart_cross_track", "%05.1f m  %s" % [deviation, _deviation_text(side)], COLOR_AMBER if deviation > arrival_radius_meters * 2.0 else COLOR_GREEN)
	_update_label("chart_obstacles", "%02d" % obstacle_count)
	_update_label("chart_loop", "LOOP" if bool(route_radar.get("loop", false)) else "ONE-WAY")


func _update_waypoint_manifest(points: Array[Vector3], active_index: int) -> void:
	var lines: Array[String] = []
	lines.append("MISSION  %s" % _active_mission_code)
	lines.append("OBJECT   %s" % _active_objective)
	lines.append("")
	for index in range(points.size()):
		var point := points[index]
		var marker := ">" if index == active_index else " "
		lines.append("%s WP-%02d   X %8.1f   Z %8.1f" % [marker, index + 1, point.x, point.z])
	_update_label("waypoint_manifest", "\n".join(lines))


func _scenario_weather_text() -> String:
	if _scenario_source == null or not is_instance_valid(_scenario_source):
		_scenario_source = _resolve_node(scenario_path, &"ship_scenario_system")
	if _weather_time_source == null or not is_instance_valid(_weather_time_source):
		_weather_time_source = _resolve_node(weather_time_path, &"ship_weather_time_system")
	var scenario_text := "--"
	var weather_text := "--"
	if _scenario_source != null and _scenario_source.has_method("get_scenario_status"):
		var scenario: Dictionary = _scenario_source.call("get_scenario_status")
		scenario_text = String(scenario.get("name", "--"))
	if _weather_time_source != null and _weather_time_source.has_method("get_weather_time_status"):
		var weather: Dictionary = _weather_time_source.call("get_weather_time_status")
		weather_text = "%s %s VIS %s" % [String(weather.get("weather", "--")), String(weather.get("time", "--")), String(weather.get("visibility", "--"))]
	return "%s  |  %s" % [scenario_text, weather_text]


func _export_plan_snapshot(show_status: bool = true) -> void:
	var ship := _get_active_ship()
	var route_radar := _get_route_radar_data()
	var route_points := _route_points_from_radar(route_radar)
	var payload := {
		"missionName": _active_mission_name,
		"missionCode": _active_mission_code,
		"objective": _active_objective,
		"plannedSpeedKnots": planned_speed_knots,
		"arrivalRadiusMeters": arrival_radius_meters,
		"loopRoute": bool(route_radar.get("loop", loop_route_enabled)),
		"ship": _ship_snapshot(ship),
		"waypoints": _waypoints_to_payload(route_points),
		"scenario": _scenario_weather_text(),
		"advancedMission": _get_advanced_mission_snapshot(),
		"advancedMissionRealism": _get_advanced_realism_snapshot(),
	}
	var file := FileAccess.open(PLAN_EXPORT_PATH, FileAccess.WRITE)
	if file == null:
		if show_status:
			_update_label("mission_footer", "任务快照导出失败: " + PLAN_EXPORT_PATH, COLOR_RED)
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	if show_status:
		_update_label("mission_footer", "任务快照已导出: " + ProjectSettings.globalize_path(PLAN_EXPORT_PATH), COLOR_GREEN)


func _ship_snapshot(ship: Node3D) -> Dictionary:
	if ship == null:
		return {}
	var telemetry := {}
	if ship.has_method("get_ship_telemetry"):
		telemetry = ship.call("get_ship_telemetry") as Dictionary
	return {
		"name": ship.name,
		"position": {"x": ship.global_position.x, "y": ship.global_position.y, "z": ship.global_position.z},
		"telemetry": telemetry
	}


func _waypoints_to_payload(points: Array[Vector3]) -> Array:
	var records: Array = []
	for index in range(points.size()):
		var point := points[index]
		records.append({"name": "WP-%02d" % (index + 1), "x": point.x, "z": point.z})
	return records


func _get_advanced_mission_snapshot() -> Dictionary:
	if _advanced_mission_source == null or not is_instance_valid(_advanced_mission_source):
		_advanced_mission_source = _resolve_node(advanced_mission_controller_path, &"ship_advanced_mission_controller")
	if _advanced_mission_source != null and _advanced_mission_source.has_method("get_advanced_mission_snapshot"):
		return _advanced_mission_source.call("get_advanced_mission_snapshot") as Dictionary
	return {}


func _get_advanced_realism_source() -> Node:
	if _advanced_realism_source == null or not is_instance_valid(_advanced_realism_source):
		_advanced_realism_source = _resolve_node(advanced_mission_realism_path, &"ship_advanced_mission_realism_controller")
	return _advanced_realism_source


func _get_advanced_realism_snapshot() -> Dictionary:
	var source := _get_advanced_realism_source()
	if source != null and source.has_method("get_realism_snapshot"):
		return source.call("get_realism_snapshot") as Dictionary
	return {}


func _update_advanced_realism_labels(snapshot: Dictionary) -> void:
	if snapshot.is_empty() or not bool(snapshot.get("active", false)):
		_update_label("advanced_hydrodynamics", "基础场景：任务级浅水/岸效应未启用", COLOR_MUTED)
		_update_label("advanced_bridge_readiness", "高级任务现实性门禁未启用", COLOR_MUTED)
		_update_label("advanced_debrief", "--", COLOR_MUTED)
		return
	var hydro := snapshot.get("hydrodynamics", {}) as Dictionary
	var bank_clearance: Variant = hydro.get("bank_clearance_m")
	var hydro_text := "UKC %.2fm  squat %.3fm  Fh %.2f" % [
		float(hydro.get("under_keel_clearance_m", 0.0)),
		float(hydro.get("squat_m", 0.0)),
		float(hydro.get("depth_froude", 0.0)),
	]
	if bank_clearance != null:
		hydro_text += "  岸距 %.1fm  岸效应 %.0f%%" % [float(bank_clearance), float(hydro.get("bank_proximity", 0.0)) * 100.0]
	var hydro_safe := float(hydro.get("under_keel_clearance_m", 0.0)) >= float(hydro.get("minimum_ukc_m", 0.0))
	_update_label("advanced_hydrodynamics", hydro_text, COLOR_GREEN if hydro_safe else COLOR_RED)
	var bridge := snapshot.get("bridge_readiness", {}) as Dictionary
	var predeparture := bool(snapshot.get("predeparture_passed", false))
	_update_label(
		"advanced_bridge_readiness",
		"设备域 %s  |  任务前检查 %s" % ["READY" if bool(bridge.get("passed", false)) else "BLOCKED", "PASS" if predeparture else "PENDING"],
		COLOR_GREEN if predeparture else COLOR_AMBER,
	)
	var debrief := snapshot.get("debrief", {}) as Dictionary
	_update_label(
		"advanced_debrief",
		"%s  score %.1f/100  样本 %d  行动回执 %d" % [
			String(debrief.get("status", "NOT_YET_PASS")),
			float(debrief.get("score", 0.0)),
			int(debrief.get("sample_count", 0)),
			int(snapshot.get("operator_action_count", 0)),
		],
		COLOR_GREEN if bool(debrief.get("passed", false)) else COLOR_AMBER,
	)


func _update_advanced_mission_labels(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		_update_label("advanced_task", "--", COLOR_AMBER)
		_update_label("advanced_gate", "高级任务运行时不可用", COLOR_AMBER)
		_update_label("advanced_traffic", "--")
		_update_label("advanced_boundary", "仅供模拟与训练")
		return
	var task_type := String(snapshot.get("task_type", "route_following"))
	var rules := snapshot.get("colreg_rule_ids", []) as Array
	var task_text := task_type
	if not rules.is_empty():
		task_text += "  |  COLREG " + ", ".join(rules)
	_update_label("advanced_task", task_text)
	var gate := snapshot.get("gate", {}) as Dictionary
	var gate_status := String(gate.get("status", "MONITOR"))
	var gate_text := gate_status
	match task_type:
		"berthing":
			gate_text += "  泊位距离 %.1fm  首向误差 %.1f°  速度 %.2fkn  横移 %.2fm/s" % [
				float(gate.get("berth_distance_m", 0.0)),
				float(gate.get("heading_error_degrees", 0.0)),
				float(gate.get("speed_knots", 0.0)),
				float(gate.get("sway_mps", 0.0)),
			]
		"unberthing":
			gate_text += "  离泊位 %.1fm  出口速度 %.2fkn" % [
				float(gate.get("clear_distance_m", 0.0)),
				float(gate.get("speed_knots", 0.0)),
			]
		"head_on", "crossing_give_way", "overtaking":
			gate_text += "  最小会遇 %.1fm / 要求 %.1fm" % [
				float(gate.get("minimum_passing_distance_m", 0.0)),
				float(gate.get("required_passing_distance_m", 0.0)),
			]
			if bool(gate.get("overtaking_agreement_required", false)):
				gate_text += "  追越协议 %s" % ("已确认" if bool(gate.get("overtaking_agreement_confirmed", false)) else "未确认")
	var behavioral := snapshot.get("behavioral_assessment", {}) as Dictionary
	if task_type in ["head_on", "crossing_give_way", "overtaking"]:
		gate_text += "  行为证据 %s" % String(behavioral.get("status", "NOT_YET_PASS"))
	var complete_gate := bool(gate.get("passed", false)) \
		and (bool(behavioral.get("passed", false)) if task_type in ["head_on", "crossing_give_way", "overtaking"] else true)
	_update_label("advanced_gate", gate_text, COLOR_GREEN if complete_gate else COLOR_AMBER)
	var traffic_count := int(snapshot.get("traffic_count", 0))
	var traffic_text := "目标船 %d" % traffic_count
	if snapshot.get("nearest_distance_m") != null:
		traffic_text += "  距离 %.1fm  TCPA %.1fs  DCPA %.1fm" % [
			float(snapshot.get("nearest_distance_m", 0.0)),
			float(snapshot.get("nearest_tcpa_s", 0.0)),
			float(snapshot.get("nearest_dcpa_m", 0.0)),
		]
	_update_label("advanced_traffic", traffic_text, COLOR_AMBER if traffic_count > 0 else COLOR_TEXT)
	_update_label("advanced_boundary", String(snapshot.get("claim_boundary", "仅供模拟与训练")), COLOR_MUTED)


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _deviation_text(side: String) -> String:
	if side == "LEFT":
		return "左偏"
	if side == "RIGHT":
		return "右偏"
	return "正航"


func _format_seconds(value: int) -> String:
	var seconds: int = max(value, 0)
	var hours: int = seconds / 3600
	var minutes: int = (seconds % 3600) / 60
	var rest: int = seconds % 60
	if hours > 0:
		return "%02d:%02d:%02d" % [hours, minutes, rest]
	return "%02d:%02d" % [minutes, rest]


func _make_spin(value: float, min_value: float, max_value: float, step: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.value = value
	spin.custom_minimum_size = Vector2(78.0, 0.0)
	return spin


func _make_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_font_size_override("font_size", 12)
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
	return label


func _panel_style(fill: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.38)
	style.shadow_size = 12
	return style


func _update_label(key: String, value: String, color: Color = COLOR_TEXT) -> void:
	var label := _labels.get(key) as Label
	if label == null:
		return
	label.text = value
	label.add_theme_color_override("font_color", color)

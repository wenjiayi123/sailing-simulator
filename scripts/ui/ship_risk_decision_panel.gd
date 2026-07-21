extends CanvasLayer

const KNOTS_PER_MPS := 1.943844
const TOGGLE_PANEL_KEY := KEY_V
const REFRESH_INTERVAL := 0.18
const COLOR_BG := Color(0.010, 0.020, 0.030, 0.94)
const COLOR_PANEL := Color(0.030, 0.052, 0.064, 0.95)
const COLOR_ACCENT := Color(0.28, 0.96, 1.0, 0.96)
const COLOR_GREEN := Color(0.46, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.72, 0.26, 1.0)
const COLOR_RED := Color(1.0, 0.28, 0.22, 1.0)
const COLOR_TEXT := Color(0.80, 0.94, 1.0, 0.98)
const COLOR_MUTED := Color(0.56, 0.70, 0.76, 0.92)

const PRESETS := [
	{
		"name": "标准",
		"safe_clearance_meters": 52.0,
		"warning_clearance_meters": 96.0,
		"cpa_horizon_seconds": 180.0,
		"route_deviation_limit_meters": 48.0,
		"max_advisory_speed_knots": 18.0,
		"risk_sensitivity": 1.0
	},
	{
		"name": "保守",
		"safe_clearance_meters": 72.0,
		"warning_clearance_meters": 132.0,
		"cpa_horizon_seconds": 240.0,
		"route_deviation_limit_meters": 36.0,
		"max_advisory_speed_knots": 14.0,
		"risk_sensitivity": 1.25
	},
	{
		"name": "港口",
		"safe_clearance_meters": 34.0,
		"warning_clearance_meters": 72.0,
		"cpa_horizon_seconds": 120.0,
		"route_deviation_limit_meters": 24.0,
		"max_advisory_speed_knots": 8.0,
		"risk_sensitivity": 1.15
	},
	{
		"name": "夜航",
		"safe_clearance_meters": 86.0,
		"warning_clearance_meters": 156.0,
		"cpa_horizon_seconds": 300.0,
		"route_deviation_limit_meters": 34.0,
		"max_advisory_speed_knots": 10.0,
		"risk_sensitivity": 1.45
	}
]

@export var start_visible: bool = false
@export var player_path: NodePath = NodePath("../Player")
@export var fleet_manager_path: NodePath = NodePath("../ShipFleetManager")
@export var route_system_path: NodePath = NodePath("../ShipRouteSystem")
@export var obstacle_system_path: NodePath = NodePath("../ShipNavigationObstacles")
@export var weather_time_path: NodePath = NodePath("../ShipWeatherTimeController")
@export var scenario_path: NodePath = NodePath("../ShipScenarioController")
@export var validation_bridge_path: NodePath = NodePath("../MalaccaValidationBridge")
@export var safe_clearance_meters: float = 52.0
@export var warning_clearance_meters: float = 96.0
@export var cpa_horizon_seconds: float = 180.0
@export var route_deviation_limit_meters: float = 48.0
@export var max_advisory_speed_knots: float = 18.0
@export_range(0.5, 2.0, 0.05) var risk_sensitivity: float = 1.0

var _root: Control
var _tabs: TabContainer
var _score_graph: RiskScoreGraph
var _labels: Dictionary = {}
var _parameter_controls: Dictionary = {}
var _fleet_manager: Node
var _route_system: Node
var _obstacle_system: Node
var _weather_time_source: Node
var _scenario_source: Node
var _validation_bridge: Node
var _player: Node3D
var _refresh_timer := 0.0
var _last_validation_result: Dictionary = {}
var _last_score := 0.0
var _last_clearance := 0.0
var _last_deviation := 0.0


class RiskScoreGraph:
	extends Control

	var score: float = 0.0
	var clearance: float = 0.0
	var deviation: float = 0.0
	var cpa_distance: float = 0.0
	var safe_threshold: float = 52.0
	var warning_threshold: float = 96.0

	func set_metrics(
		next_score: float,
		next_clearance: float,
		next_deviation: float,
		next_cpa_distance: float,
		next_safe_threshold: float,
		next_warning_threshold: float
	) -> void:
		score = next_score
		clearance = next_clearance
		deviation = next_deviation
		cpa_distance = next_cpa_distance
		safe_threshold = next_safe_threshold
		warning_threshold = next_warning_threshold
		queue_redraw()

	func _draw() -> void:
		var panel_color := Color(0.015, 0.045, 0.060, 0.86)
		draw_rect(Rect2(Vector2.ZERO, size), panel_color, true)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.28, 0.96, 1.0, 0.36), false, 1.0)

		var font := ThemeDB.fallback_font
		var score_color := _score_color(score)
		var bar_rect := Rect2(16.0, 38.0, size.x - 32.0, 14.0)
		draw_rect(bar_rect, Color(0.08, 0.16, 0.18, 0.88), true)
		draw_rect(Rect2(bar_rect.position, Vector2(bar_rect.size.x * clampf(score / 100.0, 0.0, 1.0), bar_rect.size.y)), score_color, true)
		draw_rect(bar_rect, Color(0.70, 0.92, 1.0, 0.30), false, 1.0)

		var score_text := "RISK SCORE %03d" % int(round(score))
		draw_string(font, Vector2(16.0, 24.0), score_text, HORIZONTAL_ALIGNMENT_LEFT, size.x - 32.0, 18, score_color)
		_draw_metric_bar("clear", clearance, warning_threshold, safe_threshold, 72.0, COLOR_ACCENT, COLOR_AMBER)
		_draw_metric_bar("cpa", cpa_distance, warning_threshold, safe_threshold, 100.0, COLOR_GREEN, COLOR_RED)
		draw_string(font, Vector2(16.0, size.y - 18.0), "deviation %05.1f m" % deviation, HORIZONTAL_ALIGNMENT_LEFT, size.x - 32.0, 12, Color(0.70, 0.92, 1.0, 0.78))

	func _draw_metric_bar(label_text: String, value: float, warning: float, safe: float, y: float, ok_color: Color, alert_color: Color) -> void:
		var font := ThemeDB.fallback_font
		var bar_width := size.x - 104.0
		var capped_value := clampf(value / maxf(warning, 1.0), 0.0, 1.0)
		var color := ok_color
		if value < safe:
			color = alert_color
		elif value < warning:
			color = COLOR_AMBER
		draw_string(font, Vector2(16.0, y + 10.0), label_text, HORIZONTAL_ALIGNMENT_LEFT, 54.0, 11, Color(0.70, 0.92, 1.0, 0.76))
		draw_rect(Rect2(72.0, y, bar_width, 8.0), Color(0.08, 0.16, 0.18, 0.88), true)
		draw_rect(Rect2(72.0, y, bar_width * capped_value, 8.0), color, true)
		draw_string(font, Vector2(size.x - 70.0, y + 10.0), "%05.1f" % value, HORIZONTAL_ALIGNMENT_RIGHT, 54.0, 11, color)

	func _score_color(value: float) -> Color:
		if value >= 78.0:
			return COLOR_RED
		if value >= 48.0:
			return COLOR_AMBER
		return COLOR_GREEN


func _ready() -> void:
	layer = 59
	add_to_group(&"ship_risk_decision_panel")
	_build_interface()
	_resolve_sources()
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
	_root.name = "ShipRiskDecisionRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = start_visible
	add_child(_root)

	var panel := PanelContainer.new()
	panel.name = "RiskDecisionPanel"
	panel.anchor_left = 1.0
	panel.anchor_top = 0.5
	panel.anchor_right = 1.0
	panel.anchor_bottom = 0.5
	panel.offset_left = -474.0
	panel.offset_top = -334.0
	panel.offset_right = -20.0
	panel.offset_bottom = 334.0
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

	var title := _make_label("风险态势 / Collision Advisory", 16, COLOR_ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var hide_button := _make_button("收起")
	hide_button.pressed.connect(func() -> void: _root.visible = false)
	header.add_child(hide_button)

	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", 8)
	stack.add_child(summary)
	_add_status_pill(summary, "risk_state", "CLEAR")
	_add_status_pill(summary, "speed_advice", "-- kn")
	_add_status_pill(summary, "turn_advice", "KEEP")

	_score_graph = RiskScoreGraph.new()
	_score_graph.custom_minimum_size = Vector2(0.0, 142.0)
	stack.add_child(_score_graph)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(_tabs)
	_tabs.add_child(_build_situation_tab())
	_tabs.add_child(_build_parameter_tab())
	_tabs.add_child(_build_validation_tab())


func _build_situation_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "态势"
	root.add_theme_constant_override("separation", 8)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 7)
	root.add_child(grid)

	_add_metric(grid, "active_ship", "当前船舶")
	_add_metric(grid, "scenario_weather", "场景海况")
	_add_metric(grid, "route_target", "航线目标")
	_add_metric(grid, "route_deviation", "偏航")
	_add_metric(grid, "nearest_obstacle", "最近障碍")
	_add_metric(grid, "clearance", "安全间距")
	_add_metric(grid, "cpa", "CPA / TCPA")
	_add_metric(grid, "collision_state", "碰撞状态")
	_add_metric(grid, "risk_reason", "主要风险")
	_add_metric(grid, "decision", "处置建议")

	var footer := _make_label("ADVISORY ONLINE", 11, COLOR_MUTED)
	footer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	footer.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	root.add_child(footer)
	_labels["situation_footer"] = footer

	return root


func _build_parameter_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "参数"
	root.add_theme_constant_override("separation", 8)

	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 6)
	root.add_child(preset_row)
	for preset in PRESETS:
		var button := _make_button(String(preset["name"]))
		button.pressed.connect(_apply_preset.bind(preset))
		preset_row.add_child(button)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	var parameter_stack := VBoxContainer.new()
	parameter_stack.add_theme_constant_override("separation", 6)
	scroll.add_child(parameter_stack)

	parameter_stack.add_child(_make_parameter_row("safe_clearance_meters", "安全间距阈值", 8.0, 240.0, 1.0, "m"))
	parameter_stack.add_child(_make_parameter_row("warning_clearance_meters", "预警间距阈值", 20.0, 360.0, 1.0, "m"))
	parameter_stack.add_child(_make_parameter_row("cpa_horizon_seconds", "CPA 预测时窗", 30.0, 600.0, 10.0, "s"))
	parameter_stack.add_child(_make_parameter_row("route_deviation_limit_meters", "偏航容忍距离", 5.0, 160.0, 1.0, "m"))
	parameter_stack.add_child(_make_parameter_row("max_advisory_speed_knots", "建议最高航速", 2.0, 32.0, 0.5, "kn"))
	parameter_stack.add_child(_make_parameter_row("risk_sensitivity", "风险灵敏度", 0.50, 2.00, 0.05, "x"))

	var summary := _make_label("", 11, COLOR_MUTED)
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(summary)
	_labels["parameter_summary"] = summary
	_update_parameter_summary()

	return root


func _build_validation_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "验证"
	root.add_theme_constant_override("separation", 8)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 7)
	root.add_child(grid)
	_add_metric(grid, "validation_status", "验证状态")
	_add_metric(grid, "validation_safe_pass", "安全通过")
	_add_metric(grid, "validation_risk", "综合风险")
	_add_metric(grid, "validation_speed", "推荐航速")
	_add_metric(grid, "validation_eta", "预计耗时")
	_add_metric(grid, "validation_carbon", "碳排模型")
	_add_metric(grid, "validation_scene", "载入场景")
	_add_metric(grid, "validation_summary", "结果摘要")

	var run_button := _make_button("刷新验证结果")
	run_button.pressed.connect(_refresh_validation_from_file)
	root.add_child(run_button)

	var hint := _make_label("user://malacca_validation_result.json", 11, COLOR_MUTED)
	hint.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hint.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	root.add_child(hint)

	return root


func _add_status_pill(parent: Control, key: String, text: String) -> void:
	var label := _make_label(text, 13, COLOR_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	label.custom_minimum_size = Vector2(112.0, 30.0)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_stylebox_override("normal", _panel_style(COLOR_PANEL, COLOR_ACCENT))
	parent.add_child(label)
	_labels[key] = label


func _add_metric(parent: Control, key: String, title: String) -> void:
	var title_label := _make_label(title, 11, COLOR_MUTED)
	title_label.custom_minimum_size = Vector2(112.0, 22.0)
	parent.add_child(title_label)

	var value_label := _make_label("--", 12, COLOR_TEXT)
	value_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value_label.custom_minimum_size = Vector2(260.0, 22.0)
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(value_label)
	_labels[key] = value_label


func _make_parameter_row(
	key: String,
	label_text: String,
	min_value: float,
	max_value: float,
	step: float,
	unit: String
) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var label := _make_label(label_text, 12, COLOR_TEXT)
	label.custom_minimum_size = Vector2(132.0, 0.0)
	row.add_child(label)

	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.value = float(get(key))
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(_on_parameter_changed.bind(key))
	row.add_child(spin)
	_parameter_controls[key] = spin

	var unit_label := _make_label(unit, 11, COLOR_MUTED)
	unit_label.custom_minimum_size = Vector2(28.0, 0.0)
	row.add_child(unit_label)
	return row


func _resolve_sources() -> void:
	_player = _resolve_node3d(player_path, &"player")
	_fleet_manager = _resolve_node(fleet_manager_path, &"ship_fleet_manager")
	_route_system = _resolve_node(route_system_path, &"ship_route_system")
	_obstacle_system = _resolve_node(obstacle_system_path, &"ship_navigation_obstacle_system")
	_weather_time_source = _resolve_node(weather_time_path, &"ship_weather_time_system")
	_scenario_source = _resolve_node(scenario_path, &"ship_scenario_system")
	_validation_bridge = _resolve_node(validation_bridge_path, &"malacca_validation_bridge")
	if _validation_bridge != null and _validation_bridge.has_signal("validation_result_written"):
		var callable := Callable(self, "_on_validation_result_written")
		if not _validation_bridge.validation_result_written.is_connected(callable):
			_validation_bridge.validation_result_written.connect(callable)


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
	if _root == null:
		return
	var ship := _get_active_ship()
	if ship == null:
		_update_label("risk_state", "NO SHIP", COLOR_AMBER)
		_update_label("active_ship", "--")
		return

	var telemetry := _get_ship_telemetry(ship)
	var position := ship.global_position
	var speed_mps := float(telemetry.get("speed", 0.0))
	var speed_knots := absf(speed_mps) * KNOTS_PER_MPS
	var heading := float(telemetry.get("heading_degrees", 0.0))
	var course := float(telemetry.get("course_degrees", heading))
	var route_data := _get_route_data(position)
	var obstacle_data := _get_obstacle_data()
	var nearest := _find_nearest_obstacle(position, obstacle_data)
	var velocity := _course_velocity(course, speed_mps)
	var cpa := _calculate_cpa(position, velocity, obstacle_data)
	var decision := _build_decision(telemetry, route_data, nearest, cpa, speed_knots, heading)

	var risk_score := _calculate_risk_score(telemetry, route_data, nearest, cpa)
	_last_score = risk_score
	_last_clearance = float(nearest.get("clearance", warning_clearance_meters))
	_last_deviation = float(route_data.get("deviation_distance", 0.0))
	var cpa_distance := float(cpa.get("distance", _last_clearance))

	_update_label("risk_state", String(decision["state"]), decision["color"] as Color)
	_update_label("speed_advice", "%04.1f kn" % float(decision["speed_knots"]), decision["color"] as Color)
	_update_label("turn_advice", String(decision["turn"]), decision["color"] as Color)
	_update_label("active_ship", "%s  %s" % [ship.name, String(telemetry.get("agent_id", "--"))])
	_update_label("scenario_weather", _scenario_weather_text())
	_update_route_labels(route_data)
	_update_label("nearest_obstacle", "%s  %05.1f m" % [String(nearest.get("name", "--")), float(nearest.get("distance", 0.0))])
	_update_label("clearance", "%05.1f m  safe %.0f / warn %.0f" % [_last_clearance, safe_clearance_meters, warning_clearance_meters], _clearance_color(_last_clearance))
	_update_label("cpa", "%05.1f m / %s" % [cpa_distance, _format_seconds(int(cpa.get("time", 0.0)))], _clearance_color(cpa_distance))
	_update_label("collision_state", String(telemetry.get("collision_warning", "CLEAR")), COLOR_RED if bool(telemetry.get("collision_warning_active", false)) else COLOR_GREEN)
	_update_label("risk_reason", String(decision["reason"]))
	_update_label("decision", String(decision["detail"]), decision["color"] as Color)
	_update_label("situation_footer", "score=%03d  speed=%04.1fkn  heading=%03d  sensitivity=%.2fx" % [int(round(risk_score)), speed_knots, int(round(heading)) % 360, risk_sensitivity])

	if _score_graph != null:
		_score_graph.set_metrics(risk_score, _last_clearance, _last_deviation, cpa_distance, safe_clearance_meters, warning_clearance_meters)
	_update_validation_labels()


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


func _get_ship_telemetry(ship: Node3D) -> Dictionary:
	if ship != null and ship.has_method("get_ship_telemetry"):
		return ship.call("get_ship_telemetry") as Dictionary
	return {}


func _get_route_data(position: Vector3) -> Dictionary:
	if _route_system == null or not is_instance_valid(_route_system):
		_route_system = _resolve_node(route_system_path, &"ship_route_system")
	if _route_system != null and _route_system.has_method("get_route_telemetry"):
		return _route_system.call("get_route_telemetry", position) as Dictionary
	return {"active": false}


func _get_obstacle_data() -> Dictionary:
	if _obstacle_system == null or not is_instance_valid(_obstacle_system):
		_obstacle_system = _resolve_node(obstacle_system_path, &"ship_navigation_obstacle_system")
	if _obstacle_system != null and _obstacle_system.has_method("get_radar_obstacle_data"):
		return _obstacle_system.call("get_radar_obstacle_data") as Dictionary
	return {"rocks": [], "boxes": []}


func _find_nearest_obstacle(ship_position: Vector3, obstacle_data: Dictionary) -> Dictionary:
	var best := {
		"name": "--",
		"distance": warning_clearance_meters,
		"clearance": warning_clearance_meters,
		"position": ship_position,
		"radius": 0.0
	}
	var best_clearance := INF
	for raw_rock in obstacle_data.get("rocks", []):
		if not raw_rock is Dictionary:
			continue
		var rock := raw_rock as Dictionary
		var position := rock.get("position", Vector3.ZERO) as Vector3
		var radius := float(rock.get("radius", 0.0))
		var distance := _horizontal_distance(ship_position, position)
		var clearance := maxf(0.0, distance - radius)
		if clearance < best_clearance:
			best_clearance = clearance
			best = {
				"name": String(rock.get("name", "rock")),
				"distance": distance,
				"clearance": clearance,
				"position": position,
				"radius": radius
			}
	for raw_box in obstacle_data.get("boxes", []):
		if not raw_box is Dictionary:
			continue
		var box := raw_box as Dictionary
		var position := box.get("position", Vector3.ZERO) as Vector3
		var size := box.get("size", Vector3.ONE) as Vector3
		var closest := _closest_point_on_box_xz(ship_position, position, size)
		var distance := _horizontal_distance(ship_position, closest)
		if distance < best_clearance:
			best_clearance = distance
			best = {
				"name": String(box.get("name", "box")),
				"distance": distance,
				"clearance": distance,
				"position": closest,
				"radius": 0.0
			}
	if best_clearance == INF:
		best["clearance"] = warning_clearance_meters
		best["distance"] = warning_clearance_meters
	return best


func _calculate_cpa(ship_position: Vector3, velocity: Vector3, obstacle_data: Dictionary) -> Dictionary:
	var speed_squared := Vector2(velocity.x, velocity.z).length_squared()
	if speed_squared < 0.0001:
		return {"name": "--", "distance": float(_find_nearest_obstacle(ship_position, obstacle_data).get("clearance", warning_clearance_meters)), "time": 0.0}

	var best := {"name": "--", "distance": INF, "time": 0.0}
	for raw_rock in obstacle_data.get("rocks", []):
		if not raw_rock is Dictionary:
			continue
		var rock := raw_rock as Dictionary
		var cpa := _cpa_against_point(ship_position, velocity, rock.get("position", Vector3.ZERO) as Vector3, float(rock.get("radius", 0.0)))
		cpa["name"] = String(rock.get("name", "rock"))
		if float(cpa["distance"]) < float(best["distance"]):
			best = cpa
	for raw_box in obstacle_data.get("boxes", []):
		if not raw_box is Dictionary:
			continue
		var box := raw_box as Dictionary
		var point := _closest_point_on_box_xz(ship_position, box.get("position", Vector3.ZERO) as Vector3, box.get("size", Vector3.ONE) as Vector3)
		var cpa := _cpa_against_point(ship_position, velocity, point, 0.0)
		cpa["name"] = String(box.get("name", "box"))
		if float(cpa["distance"]) < float(best["distance"]):
			best = cpa
	if float(best["distance"]) == INF:
		best["distance"] = warning_clearance_meters
	return best


func _cpa_against_point(ship_position: Vector3, velocity: Vector3, obstacle_position: Vector3, obstacle_radius: float) -> Dictionary:
	var relative := Vector2(obstacle_position.x - ship_position.x, obstacle_position.z - ship_position.z)
	var velocity_2d := Vector2(velocity.x, velocity.z)
	var speed_squared := maxf(velocity_2d.length_squared(), 0.0001)
	var time_to_cpa := clampf(relative.dot(velocity_2d) / speed_squared, 0.0, cpa_horizon_seconds)
	var cpa_vector := relative - velocity_2d * time_to_cpa
	var cpa_distance := maxf(0.0, cpa_vector.length() - obstacle_radius)
	return {"distance": cpa_distance, "time": time_to_cpa}


func _calculate_risk_score(telemetry: Dictionary, route_data: Dictionary, nearest: Dictionary, cpa: Dictionary) -> float:
	var score := 0.0
	var clearance := float(nearest.get("clearance", warning_clearance_meters))
	var cpa_distance := float(cpa.get("distance", clearance))
	var cpa_time := float(cpa.get("time", cpa_horizon_seconds))
	var deviation := float(route_data.get("deviation_distance", 0.0))

	score += clampf((warning_clearance_meters - clearance) / maxf(warning_clearance_meters - safe_clearance_meters, 1.0), 0.0, 1.0) * 34.0
	score += clampf((warning_clearance_meters - cpa_distance) / maxf(warning_clearance_meters - safe_clearance_meters, 1.0), 0.0, 1.0) * 30.0
	score += clampf(1.0 - cpa_time / maxf(cpa_horizon_seconds, 1.0), 0.0, 1.0) * 12.0
	score += clampf(deviation / maxf(route_deviation_limit_meters, 1.0), 0.0, 1.0) * 14.0
	if bool(telemetry.get("collision_warning_active", false)):
		score += 24.0
	score *= risk_sensitivity
	return clampf(score, 0.0, 100.0)


func _build_decision(
	telemetry: Dictionary,
	route_data: Dictionary,
	nearest: Dictionary,
	cpa: Dictionary,
	speed_knots: float,
	heading: float
) -> Dictionary:
	var clearance := float(nearest.get("clearance", warning_clearance_meters))
	var cpa_distance := float(cpa.get("distance", clearance))
	var deviation := float(route_data.get("deviation_distance", 0.0))
	var collision_active := bool(telemetry.get("collision_warning_active", false))
	var risk_score := _calculate_risk_score(telemetry, route_data, nearest, cpa)
	var turn := _turn_advice(heading, nearest.get("position", Vector3.ZERO) as Vector3)
	var suggested_speed := minf(max_advisory_speed_knots, maxf(2.0, speed_knots))
	var state := "CLEAR"
	var reason := "航线稳定"
	var detail := "KEEP COURSE / 保持航向"
	var color := COLOR_GREEN

	if collision_active:
		state = "IMPACT"
		reason = String(telemetry.get("collision_warning", "碰撞告警"))
		detail = "STOP ENGINE / 倒车脱离并复位航向"
		suggested_speed = 0.0
		color = COLOR_RED
	elif clearance < safe_clearance_meters or cpa_distance < safe_clearance_meters:
		state = "CRITICAL"
		reason = "安全间距低于阈值"
		detail = "%s  |  HALF ASTERN / 立即避让" % turn
		suggested_speed = minf(max_advisory_speed_knots, maxf(2.0, speed_knots * 0.42))
		color = COLOR_RED
	elif risk_score >= 48.0 or deviation > route_deviation_limit_meters:
		state = "CAUTION"
		if deviation > route_deviation_limit_meters:
			reason = "偏航超过容忍距离"
			detail = "RETURN ROUTE / 小舵角回归航线"
		else:
			reason = "CPA 或障碍距离进入预警区"
			detail = "%s  |  SLOW AHEAD / 降速观察" % turn
		suggested_speed = minf(max_advisory_speed_knots, maxf(3.0, speed_knots * 0.72))
		color = COLOR_AMBER
	else:
		suggested_speed = minf(max_advisory_speed_knots, maxf(4.0, speed_knots))

	return {
		"state": state,
		"reason": reason,
		"detail": detail,
		"turn": turn,
		"speed_knots": suggested_speed,
		"color": color
	}


func _turn_advice(heading: float, obstacle_position: Vector3) -> String:
	var ship := _get_active_ship()
	if ship == null:
		return "KEEP"
	var to_obstacle := Vector2(obstacle_position.x - ship.global_position.x, obstacle_position.z - ship.global_position.z)
	if to_obstacle.length() < 0.1:
		return "PORT 20"
	var heading_radians := deg_to_rad(heading)
	var forward := Vector2(sin(heading_radians), cos(heading_radians)).normalized()
	var cross := forward.x * to_obstacle.y - forward.y * to_obstacle.x
	if cross >= 0.0:
		return "STARBOARD 20"
	return "PORT 20"


func _update_route_labels(route_data: Dictionary) -> void:
	if not bool(route_data.get("active", false)):
		_update_label("route_target", "ROUTE STANDBY")
		_update_label("route_deviation", "XTE sampling standby", COLOR_MUTED)
		return
	var current_name := String(route_data.get("current_name", "--"))
	var current_distance := float(route_data.get("current_distance", 0.0))
	var next_name := String(route_data.get("next_name", "--"))
	var deviation := float(route_data.get("deviation_distance", 0.0))
	var side := String(route_data.get("deviation_side", "ON TRACK"))
	_update_label("route_target", "%s -> %s  %05.1f m" % [current_name, next_name, current_distance])
	_update_label("route_deviation", "%05.1f m  %s" % [deviation, _deviation_text(side)], COLOR_AMBER if deviation > route_deviation_limit_meters else COLOR_GREEN)


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


func _on_parameter_changed(value: float, key: String) -> void:
	set(key, value)
	if key == "safe_clearance_meters":
		warning_clearance_meters = maxf(warning_clearance_meters, safe_clearance_meters + 1.0)
		_sync_parameter_controls()
	elif key == "warning_clearance_meters":
		safe_clearance_meters = minf(safe_clearance_meters, warning_clearance_meters - 1.0)
		_sync_parameter_controls()
	_update_parameter_summary()
	_update_panel()


func _apply_preset(preset: Dictionary) -> void:
	for key in preset.keys():
		if key == "name":
			continue
		set(String(key), float(preset[key]))
	_sync_parameter_controls()
	_update_parameter_summary()
	_update_panel()


func _sync_parameter_controls() -> void:
	for key in _parameter_controls.keys():
		var spin := _parameter_controls[key] as SpinBox
		if spin == null:
			continue
		spin.set_block_signals(true)
		spin.value = float(get(String(key)))
		spin.set_block_signals(false)


func _update_parameter_summary() -> void:
	_update_label(
		"parameter_summary",
		"当前阈值: safe %.0fm  warn %.0fm  CPA %.0fs  dev %.0fm  vmax %.1fkn  sensitivity %.2fx" % [
			safe_clearance_meters,
			warning_clearance_meters,
			cpa_horizon_seconds,
			route_deviation_limit_meters,
			max_advisory_speed_knots,
			risk_sensitivity
		],
		COLOR_MUTED
	)


func _on_validation_result_written(result: Dictionary) -> void:
	_last_validation_result = result.duplicate(true)
	_update_validation_labels()


func _refresh_validation_from_file() -> void:
	var path := "user://malacca_validation_result.json"
	if not FileAccess.file_exists(path):
		_update_validation_labels()
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_update_label("validation_status", "读取失败", COLOR_RED)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		_last_validation_result = parsed as Dictionary
		_update_validation_labels()
	else:
		_update_label("validation_status", "JSON 无效", COLOR_RED)


func _update_validation_labels() -> void:
	if _last_validation_result.is_empty():
		var local_risk_level := _local_validation_risk_level()
		var safe_pass := _last_score < 48.0 and _last_clearance >= safe_clearance_meters
		var estimated_minutes := _estimate_route_minutes()
		_update_label("validation_status", "LOCAL LIVE", COLOR_ACCENT)
		_update_label("validation_safe_pass", "YES" if safe_pass else "WATCH", COLOR_GREEN if safe_pass else COLOR_AMBER)
		_update_label("validation_risk", local_risk_level.to_upper(), _risk_level_color(local_risk_level))
		_update_label("validation_speed", "%04.1f kn" % _local_recommended_speed_knots())
		_update_label("validation_eta", "%05.1f min" % estimated_minutes)
		_update_label("validation_carbon", "N/A  未接能耗模型", COLOR_MUTED)
		_update_label("validation_scene", _local_validation_scene_text())
		_update_label("validation_summary", "本地风险模型已接入当前船舶、航线、障碍、海况；外部验证文件写入后会自动覆盖本页。")
		return
	var status := String(_last_validation_result.get("status", "--"))
	var safe_pass := bool(_last_validation_result.get("safePass", false))
	var risk_level := String(_last_validation_result.get("riskLevel", "--"))
	var loaded_scene := _last_validation_result.get("loadedScene", {}) as Dictionary
	_update_label("validation_status", status, COLOR_GREEN if status == "completed" or status == "arrived" else COLOR_AMBER)
	_update_label("validation_safe_pass", "YES" if safe_pass else "NO", COLOR_GREEN if safe_pass else COLOR_RED)
	_update_label("validation_risk", risk_level.to_upper(), _risk_level_color(risk_level))
	_update_label("validation_speed", "%04.1f kn" % float(_last_validation_result.get("recommendedSpeedKnots", 0.0)))
	_update_label("validation_eta", "%05.1f min" % float(_last_validation_result.get("estimatedTravelMinutes", 0.0)))
	if _last_validation_result.has("carbonDeltaTons"):
		_update_label("validation_carbon", "MODEL %+.4f t" % float(_last_validation_result.get("carbonDeltaTons", 0.0)))
	else:
		_update_label("validation_carbon", "N/A  未接能耗模型", COLOR_MUTED)
	_update_label("validation_scene", "route %d  risk %d  temp %d" % [
		int(loaded_scene.get("routePointCount", 0)),
		int(loaded_scene.get("riskZoneCount", 0)),
		int(loaded_scene.get("temporaryObstacleCount", 0))
	])
	_update_label("validation_summary", String(_last_validation_result.get("summary", "--")))


func _local_validation_risk_level() -> String:
	if _last_score >= 78.0 or _last_clearance < safe_clearance_meters:
		return "high"
	if _last_score >= 48.0 or _last_clearance < warning_clearance_meters:
		return "medium"
	return "low"


func _local_recommended_speed_knots() -> float:
	if _last_score >= 78.0:
		return minf(max_advisory_speed_knots, 5.0)
	if _last_score >= 48.0:
		return minf(max_advisory_speed_knots, 8.0)
	return max_advisory_speed_knots


func _estimate_route_minutes() -> float:
	var ship := _get_active_ship()
	if ship == null:
		return 0.0
	if _route_system == null or not is_instance_valid(_route_system):
		_route_system = _resolve_node(route_system_path, &"ship_route_system")
	if _route_system == null or not _route_system.has_method("get_radar_route_data"):
		return 0.0
	var radar := _route_system.call("get_radar_route_data") as Dictionary
	if not bool(radar.get("active", false)):
		return 0.0
	var points := _route_points_from_radar(radar)
	if points.is_empty():
		return 0.0
	var current_index := clampi(int(radar.get("current_index", 0)), 0, points.size() - 1)
	var distance := _horizontal_distance(ship.global_position, points[current_index])
	for index in range(current_index, points.size() - 1):
		distance += _horizontal_distance(points[index], points[index + 1])
	if bool(radar.get("loop", false)) and points.size() > 2:
		distance += _horizontal_distance(points[points.size() - 1], points[0])
	var speed_mps := maxf(_local_recommended_speed_knots() * 0.514444, 0.1)
	return distance / speed_mps / 60.0


func _route_points_from_radar(radar: Dictionary) -> Array[Vector3]:
	var points: Array[Vector3] = []
	var raw_points: Array = radar.get("points", [])
	for raw_point in raw_points:
		if raw_point is Dictionary:
			var position := (raw_point as Dictionary).get("position", Vector3.ZERO) as Vector3
			points.append(position)
	return points


func _local_validation_scene_text() -> String:
	var route_count := 0
	if _route_system == null or not is_instance_valid(_route_system):
		_route_system = _resolve_node(route_system_path, &"ship_route_system")
	if _route_system != null and _route_system.has_method("get_radar_route_data"):
		var radar := _route_system.call("get_radar_route_data") as Dictionary
		route_count = (radar.get("points", []) as Array).size()
	var obstacle_data := _get_obstacle_data()
	var obstacle_count := (obstacle_data.get("rocks", []) as Array).size() + (obstacle_data.get("boxes", []) as Array).size()
	return "route %d  risk %d  model local" % [route_count, obstacle_count]


func _course_velocity(course_degrees: float, speed_mps: float) -> Vector3:
	var radians := deg_to_rad(course_degrees)
	return Vector3(sin(radians), 0.0, cos(radians)) * speed_mps


func _closest_point_on_box_xz(point: Vector3, center: Vector3, size: Vector3) -> Vector3:
	var half_x := absf(size.x) * 0.5
	var half_z := absf(size.z) * 0.5
	return Vector3(
		clampf(point.x, center.x - half_x, center.x + half_x),
		center.y,
		clampf(point.z, center.z - half_z, center.z + half_z)
	)


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _clearance_color(value: float) -> Color:
	if value < safe_clearance_meters:
		return COLOR_RED
	if value < warning_clearance_meters:
		return COLOR_AMBER
	return COLOR_GREEN


func _risk_level_color(risk_level: String) -> Color:
	match risk_level:
		"critical":
			return COLOR_RED
		"high":
			return COLOR_RED
		"medium":
			return COLOR_AMBER
		_:
			return COLOR_GREEN


func _deviation_text(side: String) -> String:
	if side == "LEFT":
		return "左偏"
	if side == "RIGHT":
		return "右偏"
	return "正航"


func _format_seconds(value: int) -> String:
	var seconds: int = max(value, 0)
	var minutes: int = seconds / 60
	var rest: int = seconds % 60
	if minutes >= 100:
		return "99m+"
	return "%02d:%02d" % [minutes, rest]


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

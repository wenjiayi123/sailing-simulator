extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_P
const SAMPLE_INTERVAL := 0.35
const MAX_SAMPLES := 720
const KNOTS_PER_MPS := 1.943844
const METERS_PER_NAUTICAL_MILE := 1852.0
const EXPORT_PATH := "user://ship_simulation_review.json"
const COLOR_BG := Color(0.010, 0.020, 0.030, 0.94)
const COLOR_PANEL := Color(0.030, 0.052, 0.064, 0.95)
const COLOR_ACCENT := Color(0.28, 0.96, 1.0, 0.96)
const COLOR_GREEN := Color(0.46, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.72, 0.26, 1.0)
const COLOR_RED := Color(1.0, 0.28, 0.22, 1.0)
const COLOR_TEXT := Color(0.80, 0.94, 1.0, 0.98)
const COLOR_MUTED := Color(0.56, 0.70, 0.76, 0.92)

@export var start_visible: bool = false
@export var player_path: NodePath = NodePath("../Player")
@export var fleet_manager_path: NodePath = NodePath("../ShipFleetManager")
@export var route_system_path: NodePath = NodePath("../ShipRouteSystem")
@export var weather_time_path: NodePath = NodePath("../ShipWeatherTimeController")
@export var validation_bridge_path: NodePath = NodePath("../MalaccaValidationBridge")
@export var policy_replay_controller_path: NodePath = NodePath("../ShipPolicyReplayController")
@export_range(1.0, 5000.0, 1.0) var reference_propulsion_power_kw: float = 180.0
@export_range(0.5, 60.0, 0.1) var reference_speed_knots: float = 12.0
@export_range(0.0, 1000.0, 1.0) var hotel_load_kw: float = 12.0
@export_range(0.05, 1.0, 0.001) var specific_fuel_consumption_kg_per_kwh: float = 0.205
@export_range(0.0, 10.0, 0.001) var co2_tons_per_fuel_ton: float = 3.114

var _root: Control
var _tabs: TabContainer
var _strategy_option: OptionButton
var _trace_plot: TrajectoryPlot
var _labels: Dictionary = {}
var _fleet_manager: Node
var _route_system: Node
var _weather_time_source: Node
var _validation_bridge: Node
var _policy_replay_controller: Node
var _player: Node3D
var _recording := false
var _elapsed_seconds := 0.0
var _sample_timer := 0.0
var _distance_meters := 0.0
var _last_position := Vector3.ZERO
var _has_last_position := false
var _samples: Array[Dictionary] = []
var _speed_sum_mps := 0.0
var _max_speed_mps := 0.0
var _deviation_sum := 0.0
var _max_deviation := 0.0
var _weather_wind_sum := 0.0
var _weather_wave_sum := 0.0
var _sample_count := 0
var _collision_count := 0
var _grounding_count := 0
var _last_collision_active := false
var _last_collision_text := "CLEAR"
var _risk_event_resolved_count := 0
var _last_validation_result: Dictionary = {}
var _control_mode_counts := {"human": 0, "rl": 0}
var _active_strategy_key := "human"
var _active_strategy_label := "人工驾驶"
var _last_summary: Dictionary = {}
var _runs_by_strategy: Dictionary = {}
var _instructor_report_path := ""
var _instructor_debrief: Dictionary = {}


class TrajectoryPlot:
	extends Control

	var samples: Array[Dictionary] = []
	var score := 0.0
	var strategy_label := "--"

	func set_run_data(next_samples: Array[Dictionary], next_score: float, next_strategy_label: String) -> void:
		samples = next_samples.duplicate(true)
		score = next_score
		strategy_label = next_strategy_label
		queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.010, 0.032, 0.046, 0.90), true)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.28, 0.96, 1.0, 0.36), false, 1.0)
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(14.0, 20.0), "TRACK // " + strategy_label, HORIZONTAL_ALIGNMENT_LEFT, size.x - 28.0, 13, Color(0.70, 0.94, 1.0, 0.88))
		draw_string(font, Vector2(size.x - 128.0, 20.0), "SCORE %03d" % int(round(score)), HORIZONTAL_ALIGNMENT_RIGHT, 114.0, 13, _score_color(score))
		var plot := Rect2(18.0, 34.0, maxf(size.x - 36.0, 1.0), maxf(size.y - 58.0, 1.0))
		_draw_grid(plot)
		if samples.size() <= 1:
			draw_string(font, Vector2(0.0, size.y * 0.5), "等待航行采样", HORIZONTAL_ALIGNMENT_CENTER, size.x, 13, Color(0.56, 0.70, 0.76, 0.92))
			return
		var bounds := _sample_bounds()
		var previous := _to_plot(samples[0], plot, bounds)
		for index in range(1, samples.size()):
			var current := _to_plot(samples[index], plot, bounds)
			var sample := samples[index]
			var deviation := float(sample.get("deviation", 0.0))
			var color := Color(0.46, 1.0, 0.58, 0.86)
			if deviation > 80.0:
				color = Color(1.0, 0.28, 0.22, 0.92)
			elif deviation > 35.0:
				color = Color(1.0, 0.72, 0.26, 0.90)
			draw_line(previous, current, color, 2.0, true)
			previous = current
		var start := _to_plot(samples[0], plot, bounds)
		var finish := _to_plot(samples[samples.size() - 1], plot, bounds)
		draw_circle(start, 5.0, Color(0.28, 0.96, 1.0, 0.96))
		draw_circle(finish, 6.0, Color(1.0, 0.72, 0.26, 0.96))

	func _draw_grid(plot: Rect2) -> void:
		for index in range(0, 7):
			var x := plot.position.x + plot.size.x * float(index) / 6.0
			var y := plot.position.y + plot.size.y * float(index) / 6.0
			draw_line(Vector2(x, plot.position.y), Vector2(x, plot.position.y + plot.size.y), Color(0.28, 0.96, 1.0, 0.07), 1.0)
			draw_line(Vector2(plot.position.x, y), Vector2(plot.position.x + plot.size.x, y), Color(0.28, 0.96, 1.0, 0.07), 1.0)

	func _sample_bounds() -> Rect2:
		var first := samples[0]
		var min_x := float(first.get("x", 0.0))
		var max_x := min_x
		var min_z := float(first.get("z", 0.0))
		var max_z := min_z
		for sample in samples:
			var x := float(sample.get("x", 0.0))
			var z := float(sample.get("z", 0.0))
			min_x = minf(min_x, x)
			max_x = maxf(max_x, x)
			min_z = minf(min_z, z)
			max_z = maxf(max_z, z)
		var width := maxf(max_x - min_x, 24.0)
		var height := maxf(max_z - min_z, 24.0)
		var padding := maxf(width, height) * 0.16
		return Rect2(Vector2(min_x - padding, min_z - padding), Vector2(width + padding * 2.0, height + padding * 2.0))

	func _to_plot(sample: Dictionary, plot: Rect2, bounds: Rect2) -> Vector2:
		var x_ratio := (float(sample.get("x", 0.0)) - bounds.position.x) / maxf(bounds.size.x, 1.0)
		var z_ratio := (float(sample.get("z", 0.0)) - bounds.position.y) / maxf(bounds.size.y, 1.0)
		return Vector2(plot.position.x + x_ratio * plot.size.x, plot.position.y + (1.0 - z_ratio) * plot.size.y)

	func _score_color(value: float) -> Color:
		if value >= 82.0:
			return COLOR_GREEN
		if value >= 62.0:
			return COLOR_AMBER
		return COLOR_RED


func _ready() -> void:
	layer = 63
	add_to_group(&"ship_simulation_review_panel")
	_build_interface()
	_resolve_sources()
	_update_idle_labels()
	_update_compare_labels()
	_update_trace_plot()
	set_process(true)
	set_process_unhandled_input(true)


func _process(delta: float) -> void:
	if _recording:
		_elapsed_seconds += delta
		_sample_timer -= delta
		if _sample_timer <= 0.0:
			_sample_timer = SAMPLE_INTERVAL
			_record_sample()
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


func mark_instructor_report_generated(report_path: String) -> void:
	_instructor_report_path = report_path
	show_panel()
	_update_label("record_state", "REPORT", COLOR_GREEN)
	_update_label("score_pill", "REPORT READY", COLOR_GREEN)
	_update_label("score_notes", "教员报告已生成：" + report_path)


func ingest_instructor_debrief(payload: Dictionary) -> void:
	_instructor_debrief = payload.duplicate(true)
	_update_label("record_state", "DEBRIEF", COLOR_GREEN)
	_update_label("score_pill", "AUDIT READY", COLOR_GREEN)
	var exercise := _instructor_debrief.get("exerciseTimeline", {}) as Dictionary
	_update_label(
		"score_notes",
		"教员复盘已接收：%s，%d 个执行回执"
		% [exercise.get("template_name", "未载入时间线"), (exercise.get("receipts", []) as Array).size()],
	)


func get_debrief_acceptance_snapshot() -> Dictionary:
	var exercise := _instructor_debrief.get("exerciseTimeline", {}) as Dictionary
	return {
		"format": _instructor_debrief.get("schemaVersion", ""),
		"received": not _instructor_debrief.is_empty(),
		"template_key": exercise.get("template_key", ""),
		"receipt_count": (exercise.get("receipts", []) as Array).size(),
		"fault_matrix_count": (_instructor_debrief.get("equipmentFaultMatrix", []) as Array).size(),
		"boundary": _instructor_debrief.get("assuranceBoundary", {}),
	}


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipSimulationReviewRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = start_visible
	add_child(_root)

	var panel := PanelContainer.new()
	panel.name = "SimulationReviewPanel"
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -286.0
	panel.offset_top = -338.0
	panel.offset_right = 286.0
	panel.offset_bottom = 338.0
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
	var title := _make_label("仿真复盘 / Run Review", 16, COLOR_ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var hide_button := _make_button("收起")
	hide_button.pressed.connect(func() -> void: _root.visible = false)
	header.add_child(hide_button)

	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", 8)
	stack.add_child(summary)
	_add_status_pill(summary, "record_state", "READY")
	_add_status_pill(summary, "score_pill", "SCORE --")
	_add_status_pill(summary, "mode_pill", "--")

	_trace_plot = TrajectoryPlot.new()
	_trace_plot.custom_minimum_size = Vector2(0.0, 178.0)
	stack.add_child(_trace_plot)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(_tabs)
	_tabs.add_child(_build_record_tab())
	_tabs.add_child(_build_score_tab())
	_tabs.add_child(_build_compare_tab())


func _build_record_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "记录"
	root.add_theme_constant_override("separation", 8)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 8)
	root.add_child(top_row)
	_strategy_option = OptionButton.new()
	_strategy_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_strategy_option.add_item("自动识别", 0)
	_strategy_option.add_item("人工驾驶", 1)
	_strategy_option.add_item("RL策略", 2)
	_strategy_option.item_selected.connect(_on_strategy_option_selected)
	top_row.add_child(_strategy_option)

	var start_button := _make_button("开始记录")
	start_button.pressed.connect(_start_recording)
	top_row.add_child(start_button)
	var stop_button := _make_button("结束评分")
	stop_button.pressed.connect(_stop_recording)
	top_row.add_child(stop_button)

	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	root.add_child(action_row)
	var reset_button := _make_button("清空本次")
	reset_button.pressed.connect(_reset_current_run)
	action_row.add_child(reset_button)
	var export_button := _make_button("导出复盘")
	export_button.pressed.connect(_export_review)
	action_row.add_child(export_button)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 7)
	root.add_child(grid)
	_add_metric(grid, "live_time", "用时")
	_add_metric(grid, "live_distance", "航程")
	_add_metric(grid, "live_deviation", "偏航")
	_add_metric(grid, "live_collision", "碰撞/搁浅")
	_add_metric(grid, "live_fuel", "模型油耗/碳排")
	_add_metric(grid, "live_risk", "风险事件")
	return root


func _build_score_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "评分"
	root.add_theme_constant_override("separation", 8)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 7)
	root.add_child(grid)
	_add_metric(grid, "score_total", "总分")
	_add_metric(grid, "score_safety", "安全")
	_add_metric(grid, "score_route", "航线")
	_add_metric(grid, "score_efficiency", "效率")
	_add_metric(grid, "score_emission", "模型油耗碳排")
	_add_metric(grid, "score_notes", "扣分说明")
	return root


func _build_compare_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "对比"
	root.add_theme_constant_override("separation", 8)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 7)
	root.add_child(grid)
	_add_compare_header(grid, "指标")
	_add_compare_header(grid, "人工驾驶")
	_add_compare_header(grid, "RL策略")
	_add_compare_metric(grid, "cmp_score", "总分")
	_add_compare_metric(grid, "cmp_time", "用时")
	_add_compare_metric(grid, "cmp_distance", "航程")
	_add_compare_metric(grid, "cmp_deviation", "平均偏航")
	_add_compare_metric(grid, "cmp_collision", "碰撞")
	_add_compare_metric(grid, "cmp_carbon", "模型碳排")
	_add_compare_metric(grid, "cmp_delta", "差异")
	return root


func _add_status_pill(parent: Control, key: String, text: String) -> void:
	var label := _make_label(text, 13, COLOR_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	label.custom_minimum_size = Vector2(124.0, 30.0)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_stylebox_override("normal", _panel_style(COLOR_PANEL, COLOR_ACCENT))
	parent.add_child(label)
	_labels[key] = label


func _add_metric(parent: Control, key: String, title: String) -> void:
	var title_label := _make_label(title, 11, COLOR_MUTED)
	title_label.custom_minimum_size = Vector2(94.0, 22.0)
	parent.add_child(title_label)
	var value_label := _make_label("--", 12, COLOR_TEXT)
	value_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value_label.custom_minimum_size = Vector2(348.0, 22.0)
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(value_label)
	_labels[key] = value_label


func _add_compare_header(parent: Control, text: String) -> void:
	var label := _make_label(text, 11, COLOR_ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	label.custom_minimum_size = Vector2(150.0, 22.0)
	parent.add_child(label)


func _add_compare_metric(parent: Control, key: String, title: String) -> void:
	parent.add_child(_make_label(title, 11, COLOR_MUTED))
	var human_label := _make_label("--", 11, COLOR_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	var rl_label := _make_label("--", 11, COLOR_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	parent.add_child(human_label)
	parent.add_child(rl_label)
	_labels[key + "_human"] = human_label
	_labels[key + "_rl"] = rl_label


func _resolve_sources() -> void:
	_player = _resolve_node3d(player_path, &"player")
	_fleet_manager = _resolve_node(fleet_manager_path, &"ship_fleet_manager")
	_route_system = _resolve_node(route_system_path, &"ship_route_system")
	_weather_time_source = _resolve_node(weather_time_path, &"ship_weather_time_system")
	_validation_bridge = _resolve_node(validation_bridge_path, &"malacca_validation_bridge")
	if _validation_bridge != null and _validation_bridge.has_signal("validation_result_written"):
		var callable := Callable(self, "_on_validation_result_written")
		if not _validation_bridge.validation_result_written.is_connected(callable):
			_validation_bridge.validation_result_written.connect(callable)
	_policy_replay_controller = _resolve_node(policy_replay_controller_path, &"ship_policy_replay_controller")
	if _policy_replay_controller != null:
		_connect_policy_replay_signal("replay_started", "_on_policy_replay_started")
		_connect_policy_replay_signal("replay_finished", "_on_policy_replay_finished")
		_connect_policy_replay_signal("replay_stopped", "_on_policy_replay_stopped")


func _connect_policy_replay_signal(signal_name: StringName, method_name: StringName) -> void:
	if _policy_replay_controller == null or not _policy_replay_controller.has_signal(signal_name):
		return
	var callable := Callable(self, method_name)
	if not _policy_replay_controller.is_connected(signal_name, callable):
		_policy_replay_controller.connect(signal_name, callable)


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


func _start_recording() -> void:
	_reset_current_run()
	var ship := _get_active_ship()
	if ship == null:
		_update_label("record_state", "NO SHIP", COLOR_RED)
		return
	var telemetry := _get_ship_telemetry(ship)
	_active_strategy_key = _selected_strategy_key(telemetry)
	_active_strategy_label = _strategy_label(_active_strategy_key)
	_recording = true
	_sample_timer = 0.0
	_update_label("record_state", "REC", COLOR_GREEN)
	_update_label("mode_pill", _active_strategy_label, COLOR_ACCENT)


func _on_strategy_option_selected(_index: int) -> void:
	if _strategy_option == null:
		return
	var selected_key := "human"
	if _strategy_option.selected == 2:
		selected_key = "rl"
	elif _strategy_option.selected == 0:
		var ship := _get_active_ship()
		selected_key = _selected_strategy_key(_get_ship_telemetry(ship)) if ship != null else "human"
	_update_label("mode_pill", _strategy_label(selected_key), COLOR_ACCENT)


func _stop_recording() -> void:
	if _recording:
		_record_sample()
	_recording = false
	if _samples.is_empty():
		_update_label("record_state", "EMPTY", COLOR_AMBER)
		return
	_last_summary = _build_summary()
	var strategy_key := String(_last_summary.get("strategy_key", _active_strategy_key))
	if strategy_key == "mixed":
		strategy_key = _active_strategy_key
	_last_summary["strategy_key"] = strategy_key
	_last_summary["strategy_label"] = _strategy_label(strategy_key)
	_runs_by_strategy[strategy_key] = _last_summary.duplicate(true)
	_update_summary_labels(_last_summary)
	_update_compare_labels()
	_update_trace_plot()
	_update_label("record_state", "DONE", COLOR_GREEN)


func _reset_current_run() -> void:
	_recording = false
	_elapsed_seconds = 0.0
	_sample_timer = 0.0
	_distance_meters = 0.0
	_last_position = Vector3.ZERO
	_has_last_position = false
	_samples.clear()
	_speed_sum_mps = 0.0
	_max_speed_mps = 0.0
	_deviation_sum = 0.0
	_max_deviation = 0.0
	_weather_wind_sum = 0.0
	_weather_wave_sum = 0.0
	_sample_count = 0
	_collision_count = 0
	_grounding_count = 0
	_last_collision_active = false
	_last_collision_text = "CLEAR"
	_risk_event_resolved_count = 0
	_control_mode_counts = {"human": 0, "rl": 0}
	_last_summary.clear()
	_update_trace_plot()
	_update_label("record_state", "READY", COLOR_TEXT)
	_update_idle_labels()


func _record_sample() -> void:
	var ship := _get_active_ship()
	if ship == null:
		return
	var telemetry := _get_ship_telemetry(ship)
	var route_data := _get_route_data(ship.global_position)
	var weather := _get_weather_status()
	var position := ship.global_position
	if _has_last_position:
		_distance_meters += _horizontal_distance(_last_position, position)
	_last_position = position
	_has_last_position = true

	var speed_mps := absf(float(telemetry.get("speed", 0.0)))
	var deviation := float(route_data.get("deviation_distance", 0.0))
	_speed_sum_mps += speed_mps
	_max_speed_mps = maxf(_max_speed_mps, speed_mps)
	_deviation_sum += deviation
	_max_deviation = maxf(_max_deviation, deviation)
	_weather_wind_sum += float(weather.get("wind_speed_knots", 0.0))
	_weather_wave_sum += float(weather.get("wave_height_meters", 0.0))
	_sample_count += 1
	_update_collision_counters(telemetry)
	_update_mode_counts(telemetry)

	_samples.append({
		"t": snapped(_elapsed_seconds, 0.01),
		"x": snapped(position.x, 0.01),
		"z": snapped(position.z, 0.01),
		"speed_knots": snapped(speed_mps * KNOTS_PER_MPS, 0.01),
		"deviation": snapped(deviation, 0.01),
		"collision": bool(telemetry.get("collision_warning_active", false))
	})
	while _samples.size() > MAX_SAMPLES:
		_samples.remove_at(0)
	_update_trace_plot()


func _update_collision_counters(telemetry: Dictionary) -> void:
	var active := bool(telemetry.get("collision_warning_active", false))
	var text := String(telemetry.get("collision_warning", "CLEAR"))
	if active and (not _last_collision_active or text != _last_collision_text):
		if text.to_lower().contains("grounding"):
			_grounding_count += 1
		else:
			_collision_count += 1
	elif _last_collision_active and not active:
		_risk_event_resolved_count += 1
	_last_collision_active = active
	_last_collision_text = text


func _update_mode_counts(telemetry: Dictionary) -> void:
	if bool(telemetry.get("external_agent_control_enabled", false)):
		_control_mode_counts["rl"] = int(_control_mode_counts["rl"]) + 1
	else:
		_control_mode_counts["human"] = int(_control_mode_counts["human"]) + 1


func _build_summary() -> Dictionary:
	var avg_speed_mps := _speed_sum_mps / maxf(float(_sample_count), 1.0)
	var avg_speed_knots := avg_speed_mps * KNOTS_PER_MPS
	var avg_deviation := _deviation_sum / maxf(float(_sample_count), 1.0)
	var avg_wind := _weather_wind_sum / maxf(float(_sample_count), 1.0)
	var avg_wave := _weather_wave_sum / maxf(float(_sample_count), 1.0)
	var distance_nm := _distance_meters / METERS_PER_NAUTICAL_MILE
	var fuel_tons := _estimate_fuel_tons(distance_nm, avg_speed_knots, avg_wind, avg_wave)
	var carbon_tons := fuel_tons * co2_tons_per_fuel_ton
	var score_parts := _calculate_score(avg_deviation, fuel_tons, carbon_tons)
	var strategy_key := _resolved_strategy_key()
	return {
		"strategy_key": strategy_key,
		"strategy_label": _strategy_label(strategy_key),
		"elapsed_seconds": snapped(_elapsed_seconds, 0.01),
		"distance_nm": snapped(distance_nm, 0.001),
		"average_speed_knots": snapped(avg_speed_knots, 0.01),
		"max_speed_knots": snapped(_max_speed_mps * KNOTS_PER_MPS, 0.01),
		"average_deviation_meters": snapped(avg_deviation, 0.01),
		"max_deviation_meters": snapped(_max_deviation, 0.01),
		"collision_count": _collision_count,
		"grounding_count": _grounding_count,
		"fuel_tons": snapped(fuel_tons, 0.001),
		"carbon_tons": snapped(carbon_tons, 0.001),
		"fuel_estimate_model": {
			"name": "cubic_propulsion_sfoc_v1",
			"measured": false,
			"reference_propulsion_power_kw": reference_propulsion_power_kw,
			"reference_speed_knots": reference_speed_knots,
			"hotel_load_kw": hotel_load_kw,
			"specific_fuel_consumption_kg_per_kwh": specific_fuel_consumption_kg_per_kwh,
			"co2_tons_per_fuel_ton": co2_tons_per_fuel_ton,
		},
		"risk_event_resolved_count": _risk_event_resolved_count,
		"score": score_parts["score"],
		"safety_score": score_parts["safety"],
		"route_score": score_parts["route"],
		"efficiency_score": score_parts["efficiency"],
		"emission_score": score_parts["emission"],
		"notes": String(score_parts["notes"]),
		"samples": _samples.duplicate(true),
		"validation": _last_validation_result.duplicate(true)
	}


func _estimate_fuel_tons(distance_nm: float, avg_speed_knots: float, avg_wind: float, avg_wave: float) -> float:
	if distance_nm <= 0.001:
		return 0.0
	var effective_speed := maxf(avg_speed_knots, 0.5)
	var voyage_hours := distance_nm / effective_speed
	var speed_factor := pow(effective_speed / maxf(reference_speed_knots, 0.5), 3.0)
	var sea_factor := 1.0 + clampf(avg_wind / 60.0, 0.0, 1.0) * 0.18 + clampf(avg_wave / 8.0, 0.0, 1.0) * 0.24
	var average_power_kw := hotel_load_kw + reference_propulsion_power_kw * speed_factor * sea_factor
	return average_power_kw * voyage_hours * specific_fuel_consumption_kg_per_kwh / 1000.0


func _calculate_score(avg_deviation: float, fuel_tons: float, carbon_tons: float) -> Dictionary:
	var safety_score := clampf(100.0 - float(_collision_count) * 18.0 - float(_grounding_count) * 12.0 + float(_risk_event_resolved_count) * 2.0, 0.0, 100.0)
	var route_score := clampf(100.0 - minf(avg_deviation * 0.42, 34.0) - minf(_max_deviation * 0.18, 24.0), 0.0, 100.0)
	var efficiency_score := clampf(100.0 - minf(_elapsed_seconds / 18.0, 18.0) - minf(float(_collision_count + _grounding_count) * 6.0, 18.0), 0.0, 100.0)
	var emission_score := clampf(100.0 - minf(carbon_tons * 38.0, 34.0) - minf(fuel_tons * 42.0, 18.0), 0.0, 100.0)
	var score := safety_score * 0.34 + route_score * 0.28 + efficiency_score * 0.20 + emission_score * 0.18
	var notes: Array[String] = []
	if _collision_count > 0:
		notes.append("碰撞 %d 次" % _collision_count)
	if _grounding_count > 0:
		notes.append("搁浅 %d 次" % _grounding_count)
	if _max_deviation > 60.0:
		notes.append("最大偏航 %.1fm" % _max_deviation)
	if carbon_tons > 0.5:
		notes.append("碳排偏高 %.2ft" % carbon_tons)
	if notes.is_empty():
		notes.append("航迹稳定，无重大扣分")
	return {
		"score": snapped(clampf(score, 0.0, 100.0), 0.1),
		"safety": snapped(safety_score, 0.1),
		"route": snapped(route_score, 0.1),
		"efficiency": snapped(efficiency_score, 0.1),
		"emission": snapped(emission_score, 0.1),
		"notes": "；".join(notes)
	}


func _update_panel() -> void:
	if _recording:
		_update_live_labels()
		return
	if not _last_summary.is_empty():
		_update_summary_labels(_last_summary)
	else:
		_update_idle_labels()
	_update_compare_labels()


func _update_idle_labels() -> void:
	var mode_label := _active_strategy_label
	var ship := _get_active_ship()
	if ship != null:
		mode_label = _strategy_label(_selected_strategy_key(_get_ship_telemetry(ship)))
	_update_label("record_state", "READY", COLOR_GREEN)
	_update_label("score_pill", "SCORE READY", COLOR_ACCENT)
	_update_label("mode_pill", mode_label, COLOR_ACCENT)
	_update_label("live_time", "00:00")
	_update_label("live_distance", "00.00 nm")
	_update_label("live_deviation", "avg 0.0m  max 0.0m")
	_update_label("live_collision", "碰撞 0  搁浅 0", COLOR_GREEN)
	_update_label("live_fuel", "0.000t / 0.000t CO2")
	_update_label("live_risk", "0 resolved")
	_update_label("score_total", "待记录", COLOR_ACCENT)
	_update_label("score_safety", "实时采样后生成")
	_update_label("score_route", "实时采样后生成")
	_update_label("score_efficiency", "实时采样后生成")
	_update_label("score_emission", "实时采样后生成")
	_update_label("score_notes", "复盘系统待命；开始记录后轨迹、碰撞、偏航、用时和碳排会进入评分。")
	if not _instructor_report_path.is_empty():
		_update_label("record_state", "REPORT", COLOR_GREEN)
		_update_label("score_pill", "REPORT READY", COLOR_GREEN)
		_update_label("score_notes", "教员报告已生成：" + _instructor_report_path)


func _update_live_labels() -> void:
	var avg_deviation := _deviation_sum / maxf(float(_sample_count), 1.0)
	var fuel := _estimate_fuel_tons(_distance_meters / METERS_PER_NAUTICAL_MILE, (_speed_sum_mps / maxf(float(_sample_count), 1.0)) * KNOTS_PER_MPS, _weather_wind_sum / maxf(float(_sample_count), 1.0), _weather_wave_sum / maxf(float(_sample_count), 1.0))
	var carbon := fuel * co2_tons_per_fuel_ton
	_update_label("record_state", "REC", COLOR_GREEN)
	_update_label("mode_pill", _active_strategy_label, COLOR_ACCENT)
	_update_label("live_time", _format_seconds(int(_elapsed_seconds)))
	_update_label("live_distance", "%05.2f nm" % (_distance_meters / METERS_PER_NAUTICAL_MILE))
	_update_label("live_deviation", "avg %.1fm  max %.1fm" % [avg_deviation, _max_deviation])
	_update_label("live_collision", "碰撞 %d  搁浅 %d" % [_collision_count, _grounding_count], COLOR_RED if _collision_count + _grounding_count > 0 else COLOR_GREEN)
	_update_label("live_fuel", "%.3ft / %.3ft CO2" % [fuel, carbon])
	_update_label("live_risk", "%d resolved" % _risk_event_resolved_count)


func _update_summary_labels(summary: Dictionary) -> void:
	var score := float(summary.get("score", 0.0))
	_update_label("score_pill", "SCORE %03d" % int(round(score)), _score_color(score))
	_update_label("mode_pill", String(summary.get("strategy_label", "--")), COLOR_ACCENT)
	_update_label("live_time", _format_seconds(int(summary.get("elapsed_seconds", 0.0))))
	_update_label("live_distance", "%05.2f nm" % float(summary.get("distance_nm", 0.0)))
	_update_label("live_deviation", "avg %.1fm  max %.1fm" % [float(summary.get("average_deviation_meters", 0.0)), float(summary.get("max_deviation_meters", 0.0))])
	_update_label("live_collision", "碰撞 %d  搁浅 %d" % [int(summary.get("collision_count", 0)), int(summary.get("grounding_count", 0))], COLOR_RED if int(summary.get("collision_count", 0)) + int(summary.get("grounding_count", 0)) > 0 else COLOR_GREEN)
	_update_label("live_fuel", "%.3ft / %.3ft CO2" % [float(summary.get("fuel_tons", 0.0)), float(summary.get("carbon_tons", 0.0))])
	_update_label("live_risk", "%d resolved" % int(summary.get("risk_event_resolved_count", 0)))
	_update_label("score_total", "%.1f / 100" % score, _score_color(score))
	_update_label("score_safety", "%.1f" % float(summary.get("safety_score", 0.0)))
	_update_label("score_route", "%.1f" % float(summary.get("route_score", 0.0)))
	_update_label("score_efficiency", "%.1f" % float(summary.get("efficiency_score", 0.0)))
	_update_label("score_emission", "%.1f" % float(summary.get("emission_score", 0.0)))
	_update_label("score_notes", String(summary.get("notes", "--")))


func _update_compare_labels() -> void:
	var human := _comparison_summary("human")
	var rl := _comparison_summary("rl")
	_set_compare_value("cmp_score", human, rl, "score", "%.1f")
	_set_compare_value("cmp_time", human, rl, "elapsed_seconds", "time")
	_set_compare_value("cmp_distance", human, rl, "distance_nm", "%.2f nm")
	_set_compare_value("cmp_deviation", human, rl, "average_deviation_meters", "%.1f m")
	_set_compare_value("cmp_collision", human, rl, "collision_count", "%d")
	_set_compare_value("cmp_carbon", human, rl, "carbon_tons", "%.3f t")
	if not human.is_empty() and not rl.is_empty():
		var delta := float(rl.get("score", 0.0)) - float(human.get("score", 0.0))
		_update_label("cmp_delta_human", "recorded baseline")
		_update_label("cmp_delta_rl", "%+.1f score" % delta, COLOR_GREEN if delta >= 0.0 else COLOR_RED)
	else:
		_update_label("cmp_delta_human", "--")
		_update_label("cmp_delta_rl", "--")


func _comparison_summary(strategy_key: String) -> Dictionary:
	var recorded := _runs_by_strategy.get(strategy_key, {}) as Dictionary
	return recorded.duplicate(true)


func _set_compare_value(key: String, human: Dictionary, rl: Dictionary, field: String, format_text: String) -> void:
	_update_label(key + "_human", _format_summary_value(human, field, format_text))
	_update_label(key + "_rl", _format_summary_value(rl, field, format_text))


func _format_summary_value(summary: Dictionary, field: String, format_text: String) -> String:
	if summary.is_empty():
		return "--"
	if format_text == "time":
		return _format_seconds(int(summary.get(field, 0.0)))
	if format_text == "%d":
		return "%d" % int(summary.get(field, 0))
	return format_text % float(summary.get(field, 0.0))


func _update_trace_plot() -> void:
	if _trace_plot == null:
		return
	var score := float(_last_summary.get("score", 0.0))
	var label := String(_last_summary.get("strategy_label", _active_strategy_label))
	_trace_plot.set_run_data(_samples, score, label)


func _export_review() -> void:
	var payload := {
		"currentRun": _last_summary,
		"runsByStrategy": _runs_by_strategy,
		"instructorDebrief": _instructor_debrief,
		"exportPath": EXPORT_PATH
	}
	var file := FileAccess.open(EXPORT_PATH, FileAccess.WRITE)
	if file == null:
		_update_label("record_state", "EXPORT ERR", COLOR_RED)
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	_update_label("record_state", "EXPORTED", COLOR_GREEN)


func _on_validation_result_written(result: Dictionary) -> void:
	_last_validation_result = result.duplicate(true)
	if _recording:
		_risk_event_resolved_count = maxi(_risk_event_resolved_count, int(result.get("riskEventResolvedCount", 0)))


func _on_policy_replay_started(_status: Dictionary) -> void:
	_reset_current_run()
	var ship := _get_active_ship()
	if ship == null:
		_update_label("record_state", "NO SHIP", COLOR_RED)
		return
	if _strategy_option != null:
		_strategy_option.select(2)
	_active_strategy_key = "rl"
	_active_strategy_label = _strategy_label(_active_strategy_key)
	_recording = true
	_sample_timer = 0.0
	_update_label("record_state", "REC RL", COLOR_GREEN)
	_update_label("mode_pill", _active_strategy_label, COLOR_ACCENT)


func _on_policy_replay_finished(_status: Dictionary) -> void:
	_finalize_policy_replay_recording()


func _on_policy_replay_stopped() -> void:
	_finalize_policy_replay_recording()


func _finalize_policy_replay_recording() -> void:
	if not _recording or _active_strategy_key != "rl":
		return
	_stop_recording()
	_update_label("record_state", "RL DONE", COLOR_GREEN)


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
	return {"active": false, "deviation_distance": 0.0}


func _get_weather_status() -> Dictionary:
	if _weather_time_source == null or not is_instance_valid(_weather_time_source):
		_weather_time_source = _resolve_node(weather_time_path, &"ship_weather_time_system")
	if _weather_time_source != null and _weather_time_source.has_method("get_weather_time_status"):
		return _weather_time_source.call("get_weather_time_status") as Dictionary
	return {}


func _selected_strategy_key(telemetry: Dictionary) -> String:
	if _strategy_option != null:
		match _strategy_option.selected:
			1:
				return "human"
			2:
				return "rl"
	if bool(telemetry.get("external_agent_control_enabled", false)):
		return "rl"
	return "human"


func _resolved_strategy_key() -> String:
	if _strategy_option != null and _strategy_option.selected == 1:
		return "human"
	if _strategy_option != null and _strategy_option.selected == 2:
		return "rl"
	var human_count := int(_control_mode_counts.get("human", 0))
	var rl_count := int(_control_mode_counts.get("rl", 0))
	if human_count > 0 and rl_count > 0:
		return "mixed"
	if rl_count > human_count:
		return "rl"
	return "human"


func _strategy_label(key: String) -> String:
	match key:
		"rl":
			return "RL策略"
		"mixed":
			return "混合控制"
		_:
			return "人工驾驶"


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _format_seconds(value: int) -> String:
	var seconds: int = max(value, 0)
	var minutes: int = seconds / 60
	var rest: int = seconds % 60
	return "%02d:%02d" % [minutes, rest]


func _score_color(value: float) -> Color:
	if value >= 82.0:
		return COLOR_GREEN
	if value >= 62.0:
		return COLOR_AMBER
	return COLOR_RED


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

extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_B
const REFRESH_INTERVAL := 0.25
const COLOR_BG := Color(0.008, 0.018, 0.028, 0.97)
const COLOR_PANEL := Color(0.025, 0.048, 0.060, 0.97)
const COLOR_ACCENT := Color(0.28, 0.96, 1.0, 0.96)
const COLOR_GREEN := Color(0.46, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.72, 0.26, 1.0)
const COLOR_RED := Color(1.0, 0.28, 0.22, 1.0)
const COLOR_TEXT := Color(0.80, 0.94, 1.0, 0.98)
const COLOR_MUTED := Color(0.56, 0.70, 0.76, 0.92)

@export var start_visible := false
@export var equipment_suite_path: NodePath = NodePath("../ShipNavigationEquipmentSuite")

var _root: Control
var _tabs: TabContainer
var _radar_display: RadarDisplay
var _ecdis_display: EcdisDisplay
var _equipment_suite: Node
var _labels: Dictionary = {}
var _refresh_timer := 0.0
var _last_snapshot: Dictionary = {}


class RadarDisplay:
	extends Control
	var snapshot: Dictionary = {}

	func set_snapshot(value: Dictionary) -> void:
		snapshot = value.duplicate(true)
		queue_redraw()

	func _draw() -> void:
		var radar := snapshot.get("radar", {}) as Dictionary
		var ownship := snapshot.get("ownship", {}) as Dictionary
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.43
		draw_circle(center, radius + 14.0, Color(0.002, 0.016, 0.018, 0.98))
		draw_arc(center, radius + 13.0, 0.0, TAU, 160, COLOR_ACCENT, 1.2, true)
		for ratio in [0.25, 0.5, 0.75, 1.0]:
			draw_arc(center, radius * float(ratio), 0.0, TAU, 100, Color(0.28, 0.96, 1.0, 0.18), 1.0, true)
		for bearing in range(0, 360, 30):
			var angle := deg_to_rad(float(bearing) - 90.0)
			draw_line(center, center + Vector2(cos(angle), sin(angle)) * radius, Color(0.28, 0.96, 1.0, 0.10), 1.0)
		var power := bool(radar.get("power", false))
		if power:
			var sweep := deg_to_rad(float(radar.get("sweep_degrees", 0.0)) - 90.0)
			draw_line(center, center + Vector2(cos(sweep), sin(sweep)) * radius, Color(0.46, 1.0, 0.58, 0.64), 1.4, true)
			for raw_contact in radar.get("contacts", []) as Array:
				var contact := raw_contact as Dictionary
				var display_bearing := _display_bearing(float(contact.get("bearing_degrees", 0.0)), radar, ownship)
				var contact_angle := deg_to_rad(display_bearing - 90.0)
				var range_ratio := float(contact.get("range_nm", 0.0)) / maxf(float(radar.get("range_nm", 1.0)), 0.001)
				var point := center + Vector2(cos(contact_angle), sin(contact_angle)) * radius * clampf(range_ratio, 0.0, 1.0)
				var acquired := bool(contact.get("arpa_acquired", false))
				var risk := String(contact.get("risk", "UNTRACKED"))
				var color := COLOR_RED if risk == "DANGER" else (COLOR_AMBER if risk == "CAUTION" else COLOR_GREEN)
				draw_circle(point, 4.6 if acquired else 3.1, color)
				if acquired:
					draw_rect(Rect2(point - Vector2(8.0, 8.0), Vector2(16.0, 16.0)), color, false, 1.0)
					var velocity := contact.get("velocity_xz_mps", Vector2.ZERO) as Vector2
					var vector_scale := minf(34.0, velocity.length() * 8.0)
					var course_angle := deg_to_rad(_display_bearing(float(contact.get("course_degrees", 0.0)), radar, ownship) - 90.0)
					draw_line(point, point + Vector2(cos(course_angle), sin(course_angle)) * vector_scale, color, 1.2, true)
		else:
			draw_string(ThemeDB.fallback_font, Vector2(0.0, center.y), "RADAR POWER FAIL", HORIZONTAL_ALIGNMENT_CENTER, size.x, 18, COLOR_RED)
		var footer := "%s  %.2f NM  GAIN %.0f%%  ECHO %d" % [String(radar.get("orientation", "--")), float(radar.get("range_nm", 0.0)), float(radar.get("gain", 0.0)) * 100.0, int(radar.get("false_echo_count", 0))]
		draw_string(ThemeDB.fallback_font, Vector2(8.0, size.y - 8.0), footer, HORIZONTAL_ALIGNMENT_LEFT, size.x - 16.0, 10, COLOR_MUTED)

	func _display_bearing(bearing: float, radar: Dictionary, ownship: Dictionary) -> float:
		match String(radar.get("orientation", "HEAD_UP")):
			"HEAD_UP":
				return fposmod(bearing - float(ownship.get("heading_degrees", 0.0)), 360.0)
			"COURSE_UP":
				return fposmod(bearing - float(ownship.get("course_degrees", 0.0)), 360.0)
		return bearing


class EcdisDisplay:
	extends Control
	var snapshot: Dictionary = {}

	func set_snapshot(value: Dictionary) -> void:
		snapshot = value.duplicate(true)
		queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.015, 0.052, 0.078, 0.98), true)
		var ecdis := snapshot.get("ecdis", {}) as Dictionary
		var ownship := snapshot.get("ownship", {}) as Dictionary
		var plot := Rect2(18.0, 24.0, maxf(size.x - 36.0, 1.0), maxf(size.y - 48.0, 1.0))
		for index in range(7):
			var x := plot.position.x + plot.size.x * float(index) / 6.0
			var y := plot.position.y + plot.size.y * float(index) / 6.0
			draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), Color(0.30, 0.80, 1.0, 0.10), 1.0)
			draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), Color(0.30, 0.80, 1.0, 0.10), 1.0)
		var bounds := _bounds(ecdis, ownship)
		if bool((ecdis.get("layers", {}) as Dictionary).get("hazards", true)):
			for raw_hazard in ecdis.get("hazards", []) as Array:
				var hazard := raw_hazard as Dictionary
				var center := _to_chart(_xz(hazard.get("position", Vector3.ZERO) as Vector3), plot, bounds)
				var color := Color(0.78, 0.42, 0.16, 0.76)
				if String(hazard.get("shape", "")) == "circle":
					draw_circle(center, 3.8, color)
				else:
					draw_rect(Rect2(center - Vector2(3.5, 3.5), Vector2(7.0, 7.0)), color, true)
		var route := ecdis.get("route", {}) as Dictionary
		var route_points: Array[Vector2] = []
		for raw_point in route.get("points", []) as Array:
			if raw_point is Dictionary:
				route_points.append(_xz((raw_point as Dictionary).get("position", Vector3.ZERO) as Vector3))
		if bool((ecdis.get("layers", {}) as Dictionary).get("route", true)):
			for index in range(route_points.size() - 1):
				draw_line(_to_chart(route_points[index], plot, bounds), _to_chart(route_points[index + 1], plot, bounds), COLOR_ACCENT, 2.0, true)
			for index in range(route_points.size()):
				draw_circle(_to_chart(route_points[index], plot, bounds), 4.0, COLOR_GREEN)
		var ship_position := _xz(ownship.get("position", Vector3.ZERO) as Vector3)
		var ship_point := _to_chart(ship_position, plot, bounds)
		var heading := deg_to_rad(float(ownship.get("heading_degrees", 0.0)))
		var direction := Vector2(sin(heading), -cos(heading))
		var right := Vector2(-direction.y, direction.x)
		var marker := PackedVector2Array([ship_point + direction * 10.0, ship_point - direction * 7.0 + right * 6.0, ship_point - direction * 4.0, ship_point - direction * 7.0 - right * 6.0])
		draw_colored_polygon(marker, Color.WHITE)
		var alarm_count := int(ecdis.get("active_unacknowledged_alarm_count", 0))
		var title_color := COLOR_RED if alarm_count > 0 else COLOR_GREEN
		draw_string(ThemeDB.fallback_font, Vector2(12.0, 17.0), "ECDIS RESEARCH  ROUTE CHECK %s" % ("ALARM" if alarm_count > 0 else "CLEAR"), HORIZONTAL_ALIGNMENT_LEFT, size.x - 24.0, 12, title_color)

	func _bounds(ecdis: Dictionary, ownship: Dictionary) -> Rect2:
		var position := _xz(ownship.get("position", Vector3.ZERO) as Vector3)
		var min_x := position.x - 80.0
		var max_x := position.x + 80.0
		var min_y := position.y - 80.0
		var max_y := position.y + 80.0
		for raw_point in (ecdis.get("route", {}) as Dictionary).get("points", []) as Array:
			if raw_point is Dictionary:
				var point := _xz((raw_point as Dictionary).get("position", Vector3.ZERO) as Vector3)
				min_x = minf(min_x, point.x)
				max_x = maxf(max_x, point.x)
				min_y = minf(min_y, point.y)
				max_y = maxf(max_y, point.y)
		var padding := maxf(max_x - min_x, max_y - min_y) * 0.15
		return Rect2(Vector2(min_x - padding, min_y - padding), Vector2(max_x - min_x + padding * 2.0, max_y - min_y + padding * 2.0))

	func _to_chart(point: Vector2, plot: Rect2, bounds: Rect2) -> Vector2:
		return Vector2(plot.position.x + (point.x - bounds.position.x) / maxf(bounds.size.x, 1.0) * plot.size.x, plot.position.y + (1.0 - (point.y - bounds.position.y) / maxf(bounds.size.y, 1.0)) * plot.size.y)

	func _xz(position: Vector3) -> Vector2:
		return Vector2(position.x, position.z)


func _ready() -> void:
	layer = 66
	add_to_group(&"ship_integrated_bridge_panel")
	_equipment_suite = get_node_or_null(equipment_suite_path)
	_build_interface()
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
		if key_event.pressed and not key_event.echo and key_event.physical_keycode == TOGGLE_PANEL_KEY:
			toggle_panel()
			get_viewport().set_input_as_handled()


func show_panel() -> void:
	_root.visible = true
	_refresh_timer = 0.0
	_update_panel()


func hide_panel() -> void:
	_root.visible = false


func toggle_panel() -> void:
	_root.visible = not _root.visible
	if _root.visible:
		_update_panel()


func get_acceptance_snapshot() -> Dictionary:
	return _last_snapshot.duplicate(true)


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipIntegratedBridgeRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = start_visible
	add_child(_root)
	var panel := PanelContainer.new()
	panel.name = "IntegratedBridgePanel"
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -470.0
	panel.offset_top = -350.0
	panel.offset_right = 470.0
	panel.offset_bottom = 350.0
	panel.add_theme_stylebox_override("panel", _panel_style(COLOR_BG, COLOR_ACCENT))
	_root.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 7)
	margin.add_child(stack)
	var header := HBoxContainer.new()
	stack.add_child(header)
	var title := _make_label("综合驾驶台 / RADAR · ARPA · ECDIS · CONNING", 16, COLOR_ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var boundary := _make_label("研究级｜非型式认可", 11, COLOR_AMBER)
	header.add_child(boundary)
	var close_button := _make_button("收起")
	close_button.pressed.connect(hide_panel)
	header.add_child(close_button)
	var summary := HBoxContainer.new()
	stack.add_child(summary)
	_add_status_pill(summary, "radar_status", "RADAR --")
	_add_status_pill(summary, "arpa_status", "ARPA --")
	_add_status_pill(summary, "ecdis_status", "ECDIS --")
	_add_status_pill(summary, "sensor_status", "SENSOR --")
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(_tabs)
	_tabs.add_child(_build_radar_tab())
	_tabs.add_child(_build_ecdis_tab())
	_tabs.add_child(_build_conning_tab())
	var footer := _make_label("B 打开/收起｜所有量测来自场景、历史AIS或显式故障模型，不代表实船设备输出。", 10, COLOR_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	stack.add_child(footer)


func _build_radar_tab() -> Control:
	var root := HBoxContainer.new()
	root.name = "雷达与自动标绘"
	root.add_theme_constant_override("separation", 10)
	_radar_display = RadarDisplay.new()
	_radar_display.custom_minimum_size = Vector2(520.0, 480.0)
	_radar_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_radar_display)
	var controls := VBoxContainer.new()
	controls.custom_minimum_size = Vector2(350.0, 0.0)
	controls.add_theme_constant_override("separation", 7)
	root.add_child(controls)
	controls.add_child(_make_label("雷达操作", 14, COLOR_ACCENT))
	var range_row := HBoxContainer.new()
	controls.add_child(range_row)
	var range_down := _make_button("量程 -")
	range_down.pressed.connect(func() -> void: _call_suite("step_radar_range", [-1]))
	range_row.add_child(range_down)
	var range_up := _make_button("量程 +")
	range_up.pressed.connect(func() -> void: _call_suite("step_radar_range", [1]))
	range_row.add_child(range_up)
	var orientation := _make_button("显示方式")
	orientation.pressed.connect(func() -> void: _call_suite("cycle_radar_orientation"))
	range_row.add_child(orientation)
	controls.add_child(_slider_row("增益", 0.72, func(value: float) -> void: _call_suite("set_radar_gain", [value])))
	controls.add_child(_slider_row("海浪杂波抑制", 0.35, func(value: float) -> void: _call_suite("set_sea_clutter_rejection", [value])))
	controls.add_child(_slider_row("雨雪杂波抑制", 0.28, func(value: float) -> void: _call_suite("set_rain_clutter_rejection", [value])))
	var arpa_row := HBoxContainer.new()
	controls.add_child(arpa_row)
	var acquire := _make_button("捕获最近目标")
	acquire.pressed.connect(_acquire_nearest)
	arpa_row.add_child(acquire)
	var drop := _make_button("清除跟踪")
	drop.pressed.connect(func() -> void: _call_suite("drop_all_arpa_tracks"))
	arpa_row.add_child(drop)
	_add_metric(controls, "radar_limits", "量测边界")
	_add_metric(controls, "contact_list", "目标/自动标绘")
	return root


func _build_ecdis_tab() -> Control:
	var root := HBoxContainer.new()
	root.name = "电子海图"
	root.add_theme_constant_override("separation", 10)
	_ecdis_display = EcdisDisplay.new()
	_ecdis_display.custom_minimum_size = Vector2(570.0, 480.0)
	_ecdis_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_ecdis_display)
	var controls := VBoxContainer.new()
	controls.custom_minimum_size = Vector2(300.0, 0.0)
	controls.add_theme_constant_override("separation", 7)
	root.add_child(controls)
	controls.add_child(_make_label("电子海图航线监控", 14, COLOR_ACCENT))
	controls.add_child(_number_row("安全等深线 m", 10.0, 1.0, 50.0, func(value: float) -> void: _call_suite("set_safety_contour", [value])))
	controls.add_child(_number_row("安全水深 m", 5.0, 1.0, 30.0, func(value: float) -> void: _call_suite("set_safety_depth", [value])))
	for layer_name in ["route", "hazards", "ais", "safety_contour"]:
		var check := CheckBox.new()
		check.text = {"route": "航线", "hazards": "危险物", "ais": "AIS叠加", "safety_contour": "安全等深线"}[layer_name]
		check.button_pressed = true
		check.toggled.connect(func(enabled: bool, key: String = layer_name) -> void: _call_suite("set_chart_layer", [key, enabled]))
		controls.add_child(check)
	var action_row := HBoxContainer.new()
	controls.add_child(action_row)
	var check_route := _make_button("重新检查航线")
	check_route.pressed.connect(func() -> void: _call_suite("force_refresh"))
	action_row.add_child(check_route)
	var acknowledge := _make_button("确认报警")
	acknowledge.pressed.connect(func() -> void: _call_suite("acknowledge_navigation_alarms"))
	action_row.add_child(acknowledge)
	_add_metric(controls, "chart_source", "海图来源")
	_add_metric(controls, "route_check", "航线检查")
	_add_metric(controls, "alarm_list", "报警")
	return root


func _build_conning_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "综合驾驶信息"
	root.add_theme_constant_override("separation", 9)
	root.add_child(_make_label("综合驾驶信息显示", 15, COLOR_ACCENT))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 9)
	root.add_child(grid)
	for specification in [
		["conning_mode", "控制模式"], ["conning_heading", "艏向"], ["conning_course", "航向"],
		["conning_speed", "航速"], ["conning_rudder", "舵角"], ["conning_throttle", "车钟"],
		["conning_drift", "漂角"], ["conning_waypoint", "下一航点"], ["conning_xte", "横向偏差"],
		["conning_sensors", "传感器有效性"],
	]:
		_add_grid_metric(grid, String(specification[0]), String(specification[1]))
	var boundary := _make_label("该显示复制驾驶台信息组织方式，但不改变操船模型、不接管控制权，也不是经型式认可的综合驾驶台系统。", 12, COLOR_AMBER)
	boundary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(boundary)
	return root


func _update_panel() -> void:
	if _equipment_suite == null or not is_instance_valid(_equipment_suite):
		_equipment_suite = get_node_or_null(equipment_suite_path)
	if _equipment_suite == null or not _equipment_suite.has_method("get_bridge_snapshot"):
		return
	_last_snapshot = _equipment_suite.call("get_bridge_snapshot") as Dictionary
	if _last_snapshot.is_empty():
		_last_snapshot = _equipment_suite.call("force_refresh") as Dictionary
	if _radar_display != null:
		_radar_display.set_snapshot(_last_snapshot)
	if _ecdis_display != null:
		_ecdis_display.set_snapshot(_last_snapshot)
	_update_summary()
	_update_radar_labels()
	_update_ecdis_labels()
	_update_conning_labels()


func _update_summary() -> void:
	var radar := _last_snapshot.get("radar", {}) as Dictionary
	var ecdis := _last_snapshot.get("ecdis", {}) as Dictionary
	var conning := _last_snapshot.get("conning", {}) as Dictionary
	_set_label("radar_status", "RADAR %s %.2fNM" % ["ON" if bool(radar.get("power", false)) else "FAIL", float(radar.get("range_nm", 0.0))], COLOR_GREEN if bool(radar.get("power", false)) else COLOR_RED)
	_set_label("arpa_status", "ARPA %d/%d" % [int(radar.get("acquired_track_count", 0)), int(radar.get("detected_contact_count", 0))], COLOR_GREEN)
	var alarm_count := int(ecdis.get("active_unacknowledged_alarm_count", 0))
	_set_label("ecdis_status", "ECDIS %s" % ("ALARM %d" % alarm_count if alarm_count > 0 else "CLEAR"), COLOR_RED if alarm_count > 0 else COLOR_GREEN)
	var validity := conning.get("sensor_validity", {}) as Dictionary
	var valid_count := validity.values().filter(func(value: Variant) -> bool: return bool(value)).size()
	_set_label("sensor_status", "SENSOR %d/%d" % [valid_count, validity.size()], COLOR_GREEN if valid_count == validity.size() else COLOR_AMBER)


func _update_radar_labels() -> void:
	var radar := _last_snapshot.get("radar", {}) as Dictionary
	_set_label("radar_limits", "增益 %.0f%%｜海杂波 %.0f%%｜雨杂波 %.0f%%\n误差、漏检、假回波和电源/偏置故障已建模；无原始射频视频。" % [float(radar.get("gain", 0.0)) * 100.0, float(radar.get("weather_clutter", {}).get("sea", 0.0)) * 100.0, float(radar.get("weather_clutter", {}).get("rain", 0.0)) * 100.0], COLOR_MUTED)
	var lines: Array[String] = []
	for raw_contact in (radar.get("contacts", []) as Array).slice(0, 8):
		var contact := raw_contact as Dictionary
		var cpa_text := "未捕获"
		if bool(contact.get("arpa_acquired", false)):
			cpa_text = "DCPA %.0fm / TCPA %.0fs / %s" % [float(contact.get("dcpa_meters", 0.0)), float(contact.get("tcpa_seconds", 0.0)), String(contact.get("risk", "--"))]
		lines.append("%s  %.2fNM  %03d°  %s" % [String(contact.get("label", "--")).left(16), float(contact.get("range_nm", 0.0)), int(round(float(contact.get("bearing_degrees", 0.0)))) % 360, cpa_text])
	_set_label("contact_list", "\n".join(lines) if not lines.is_empty() else "当前量程无有效回波", COLOR_TEXT)


func _update_ecdis_labels() -> void:
	var ecdis := _last_snapshot.get("ecdis", {}) as Dictionary
	_set_label("chart_source", "%s\n官方在航海图：否｜更新服务：未连接｜S-100：未接入" % String(ecdis.get("chart_source", "--")), COLOR_AMBER)
	_set_label("route_check", "航线检查：%s｜危险物 %d｜安全等深线 %.1fm" % ["通过" if bool(ecdis.get("route_check_passed", false)) else "存在报警", (ecdis.get("hazards", []) as Array).size(), float(ecdis.get("safety_contour_meters", 0.0))], COLOR_GREEN if bool(ecdis.get("route_check_passed", false)) else COLOR_RED)
	var alarm_lines: Array[String] = []
	for raw_alarm in (ecdis.get("alarms", []) as Array).slice(0, 7):
		var alarm := raw_alarm as Dictionary
		alarm_lines.append("%s %s" % ["[已确认]" if bool(alarm.get("acknowledged", false)) else "[未确认]", String(alarm.get("message", "--"))])
	_set_label("alarm_list", "\n".join(alarm_lines) if not alarm_lines.is_empty() else "无活动报警", COLOR_RED if int(ecdis.get("active_unacknowledged_alarm_count", 0)) > 0 else COLOR_GREEN)


func _update_conning_labels() -> void:
	var conning := _last_snapshot.get("conning", {}) as Dictionary
	var route := conning.get("route", {}) as Dictionary
	_set_label("conning_mode", String(conning.get("control_mode", "--")), COLOR_GREEN)
	_set_label("conning_heading", _format_optional(conning.get("heading_degrees"), "%06.2f°"), COLOR_TEXT)
	_set_label("conning_course", _format_optional(conning.get("course_degrees"), "%06.2f°"), COLOR_TEXT)
	_set_label("conning_speed", _format_optional(conning.get("speed_knots"), "%05.2f kn"), COLOR_TEXT)
	_set_label("conning_rudder", _format_optional(conning.get("rudder"), "%+.2f"), COLOR_TEXT)
	_set_label("conning_throttle", _format_optional(conning.get("throttle"), "%+.2f"), COLOR_TEXT)
	_set_label("conning_drift", _format_optional(conning.get("drift_angle_degrees"), "%+.2f°"), COLOR_TEXT)
	_set_label("conning_waypoint", "%s / %.0fm" % [String(route.get("current_name", "--")), float(route.get("current_distance", 0.0))], COLOR_ACCENT)
	_set_label("conning_xte", "%.1fm %s" % [float(route.get("deviation_distance", 0.0)), String(route.get("deviation_side", "--"))], COLOR_TEXT)
	var validity := conning.get("sensor_validity", {}) as Dictionary
	var status_parts: Array[String] = []
	for key in validity:
		status_parts.append("%s:%s" % [String(key).to_upper(), "OK" if bool(validity[key]) else "FAIL"])
	_set_label("conning_sensors", "  ".join(status_parts), COLOR_GREEN if validity.values().all(func(value: Variant) -> bool: return bool(value)) else COLOR_AMBER)


func _acquire_nearest() -> void:
	var result := _call_suite("acquire_nearest_contact") as Dictionary
	if not bool(result.get("accepted", false)):
		_set_label("contact_list", "捕获失败：%s" % String(result.get("reason", "UNKNOWN")), COLOR_AMBER)


func _call_suite(method: String, arguments: Array = []) -> Variant:
	if _equipment_suite == null or not _equipment_suite.has_method(method):
		return {}
	var result: Variant = _equipment_suite.callv(method, arguments)
	_update_panel()
	return result


func _slider_row(title: String, value: float, callback: Callable) -> Control:
	var row := HBoxContainer.new()
	var label := _make_label(title, 11, COLOR_MUTED)
	label.custom_minimum_size = Vector2(116.0, 0.0)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(callback)
	row.add_child(slider)
	return row


func _number_row(title: String, value: float, minimum: float, maximum: float, callback: Callable) -> Control:
	var row := HBoxContainer.new()
	var label := _make_label(title, 11, COLOR_MUTED)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = 1.0
	spin.value = value
	spin.value_changed.connect(callback)
	row.add_child(spin)
	return row


func _add_metric(parent: VBoxContainer, key: String, title: String) -> void:
	parent.add_child(_make_label(title, 11, COLOR_MUTED))
	var label := _make_label("--", 11, COLOR_TEXT)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(0.0, 42.0)
	_labels[key] = label
	parent.add_child(label)


func _add_grid_metric(parent: GridContainer, key: String, title: String) -> void:
	parent.add_child(_make_label(title, 12, COLOR_MUTED))
	var label := _make_label("--", 14, COLOR_TEXT)
	label.custom_minimum_size = Vector2(360.0, 30.0)
	_labels[key] = label
	parent.add_child(label)


func _add_status_pill(parent: HBoxContainer, key: String, text: String) -> void:
	var label := _make_label(text, 11, COLOR_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	label.custom_minimum_size = Vector2(170.0, 27.0)
	label.add_theme_stylebox_override("normal", _panel_style(COLOR_PANEL, COLOR_MUTED))
	_labels[key] = label
	parent.add_child(label)


func _set_label(key: String, text: String, color: Color) -> void:
	var label := _labels.get(key) as Label
	if label != null:
		label.text = text
		label.add_theme_color_override("font_color", color)


func _format_optional(value: Variant, pattern: String) -> String:
	return "INVALID" if value == null else pattern % float(value)


func _make_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_font_size_override("font_size", 11)
	return button


func _make_label(text: String, font_size: int, color: Color, alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = alignment
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _panel_style(color: Color, border_color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = Color(border_color.r, border_color.g, border_color.b, 0.55)
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	style.content_margin_left = 6.0
	style.content_margin_right = 6.0
	return style

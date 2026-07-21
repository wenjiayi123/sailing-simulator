extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_I
const REFRESH_INTERVAL := 0.35
const KNOTS_PER_MPS := 1.943844
const COLOR_BG := Color(0.010, 0.020, 0.030, 0.94)
const COLOR_PANEL := Color(0.030, 0.052, 0.064, 0.95)
const COLOR_ROW := Color(0.036, 0.068, 0.082, 0.92)
const COLOR_ACCENT := Color(0.28, 0.96, 1.0, 0.96)
const COLOR_GREEN := Color(0.46, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.72, 0.26, 1.0)
const COLOR_RED := Color(1.0, 0.28, 0.22, 1.0)
const COLOR_TEXT := Color(0.80, 0.94, 1.0, 0.98)
const COLOR_MUTED := Color(0.56, 0.70, 0.76, 0.92)

@export var start_visible: bool = false
@export var fleet_manager_path: NodePath = NodePath("../ShipFleetManager")
@export var route_system_path: NodePath = NodePath("../ShipRouteSystem")
@export_file("*.json") var ais_targets_path: String = "user://public_data/ais_targets.json"

var _root: Control
var _ship_list: VBoxContainer
var _plot: AISPlot
var _fleet_manager: Node
var _route_system: Node
var _labels: Dictionary = {}
var _ship_nodes: Array[Node3D] = []
var _refresh_timer := 0.0
var _external_ais_records: Array[Dictionary] = []
var _ais_data_source := "SIM ONLY"


class AISPlot:
	extends Control

	var ships: Array[Dictionary] = []
	var route_points: Array[Dictionary] = []

	func set_data(next_ships: Array[Dictionary], next_route_points: Array[Dictionary]) -> void:
		ships = next_ships.duplicate(true)
		route_points = next_route_points.duplicate(true)
		queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.010, 0.032, 0.046, 0.90), true)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.28, 0.96, 1.0, 0.34), false, 1.0)
		var plot := Rect2(18.0, 18.0, maxf(size.x - 36.0, 1.0), maxf(size.y - 36.0, 1.0))
		_draw_grid(plot)
		var bounds := _bounds()
		_draw_route(plot, bounds)
		_draw_ships(plot, bounds)

	func _draw_grid(plot: Rect2) -> void:
		for index in range(0, 7):
			var x := plot.position.x + plot.size.x * float(index) / 6.0
			var y := plot.position.y + plot.size.y * float(index) / 6.0
			draw_line(Vector2(x, plot.position.y), Vector2(x, plot.position.y + plot.size.y), Color(0.28, 0.96, 1.0, 0.07), 1.0)
			draw_line(Vector2(plot.position.x, y), Vector2(plot.position.x + plot.size.x, y), Color(0.28, 0.96, 1.0, 0.07), 1.0)

	func _draw_route(plot: Rect2, bounds: Rect2) -> void:
		if route_points.is_empty():
			return
		var previous := _to_plot(_point_position(route_points[0]), plot, bounds)
		for index in range(1, route_points.size()):
			var current := _to_plot(_point_position(route_points[index]), plot, bounds)
			draw_line(previous, current, Color(0.28, 0.96, 1.0, 0.36), 1.4, true)
			previous = current
		for index in range(route_points.size()):
			var point := route_points[index]
			var position := _point_position(point)
			var center := _to_plot(position, plot, bounds)
			var active := bool(point.get("active", false))
			draw_circle(center, 4.2 if active else 3.0, Color(1.0, 0.72, 0.26, 0.96) if active else Color(0.28, 0.96, 1.0, 0.68))

	func _draw_ships(plot: Rect2, bounds: Rect2) -> void:
		if ships.is_empty():
			var font := ThemeDB.fallback_font
			draw_string(font, Vector2(0.0, size.y * 0.5), "AIS STANDBY // LOCAL VESSEL READY", HORIZONTAL_ALIGNMENT_CENTER, size.x, 13, Color(0.56, 0.70, 0.76, 0.92))
			return
		for record in ships:
			var position := _record_position(record)
			var center := _to_plot(position, plot, bounds)
			var heading := deg_to_rad(float(record.get("heading", 0.0)))
			var forward := Vector2(sin(heading), -cos(heading)).normalized()
			if forward.length() <= 0.001:
				forward = Vector2.UP
			var side := Vector2(-forward.y, forward.x)
			var color := _risk_color(int(record.get("risk_level", 0)))
			var marker := PackedVector2Array([
				center + forward * 9.0,
				center - forward * 6.0 + side * 5.0,
				center - forward * 6.0 - side * 5.0
			])
			draw_colored_polygon(marker, color)
			draw_polyline(PackedVector2Array([marker[0], marker[1], marker[2], marker[0]]), Color(0.0, 0.0, 0.0, 0.72), 1.0, true)
			if bool(record.get("selected", false)):
				draw_circle(center, 12.0, Color(0.28, 0.96, 1.0, 0.28))
			if bool(record.get("controlled", false)):
				draw_rect(Rect2(center - Vector2(11.0, 11.0), Vector2(22.0, 22.0)), Color(1.0, 0.72, 0.26, 0.84), false, 1.5)

	func _bounds() -> Rect2:
		var has_point := false
		var min_x := 0.0
		var max_x := 0.0
		var min_z := 0.0
		var max_z := 0.0
		for record in ships:
			var position := _record_position(record)
			if not has_point:
				min_x = position.x
				max_x = position.x
				min_z = position.z
				max_z = position.z
				has_point = true
			else:
				min_x = minf(min_x, position.x)
				max_x = maxf(max_x, position.x)
				min_z = minf(min_z, position.z)
				max_z = maxf(max_z, position.z)
		for point in route_points:
			var route_position := _point_position(point)
			if not has_point:
				min_x = route_position.x
				max_x = route_position.x
				min_z = route_position.z
				max_z = route_position.z
				has_point = true
			else:
				min_x = minf(min_x, route_position.x)
				max_x = maxf(max_x, route_position.x)
				min_z = minf(min_z, route_position.z)
				max_z = maxf(max_z, route_position.z)
		if not has_point:
			return Rect2(Vector2(-64.0, -64.0), Vector2(128.0, 128.0))
		var width := maxf(max_x - min_x, 42.0)
		var height := maxf(max_z - min_z, 42.0)
		var padding := maxf(width, height) * 0.18
		return Rect2(Vector2(min_x - padding, min_z - padding), Vector2(width + padding * 2.0, height + padding * 2.0))

	func _to_plot(position: Vector3, plot: Rect2, bounds: Rect2) -> Vector2:
		var x_ratio := (position.x - bounds.position.x) / maxf(bounds.size.x, 1.0)
		var z_ratio := (position.z - bounds.position.y) / maxf(bounds.size.y, 1.0)
		return Vector2(plot.position.x + x_ratio * plot.size.x, plot.position.y + (1.0 - z_ratio) * plot.size.y)

	func _record_position(record: Dictionary) -> Vector3:
		var value: Variant = record.get("position", Vector3.ZERO)
		if value is Vector3:
			return value
		return Vector3.ZERO

	func _point_position(point: Dictionary) -> Vector3:
		var value: Variant = point.get("position", Vector3.ZERO)
		if value is Vector3:
			return value
		return Vector3.ZERO

	func _risk_color(level: int) -> Color:
		if level >= 2:
			return COLOR_RED
		if level == 1:
			return COLOR_AMBER
		return COLOR_GREEN


func _ready() -> void:
	layer = 62
	_build_interface()
	_resolve_sources()
	_refresh_fleet_view()
	set_process(true)
	set_process_unhandled_input(true)


func _process(delta: float) -> void:
	if not _root.visible:
		return
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_INTERVAL
		_refresh_fleet_view()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return
		if key_event.physical_keycode == TOGGLE_PANEL_KEY:
			_root.visible = not _root.visible
			if _root.visible:
				_refresh_timer = 0.0
				_refresh_fleet_view()
			get_viewport().set_input_as_handled()


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipAISFleetRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = start_visible
	add_child(_root)

	var panel := PanelContainer.new()
	panel.name = "ShipAISFleetPanel"
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -384.0
	panel.offset_top = -322.0
	panel.offset_right = 384.0
	panel.offset_bottom = 322.0
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
	var title := _make_label("AIS / 船队态势", 16, COLOR_ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var hide_button := _make_button("收起")
	hide_button.pressed.connect(func() -> void: _root.visible = false)
	header.add_child(hide_button)

	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", 8)
	stack.add_child(summary)
	_add_status_pill(summary, "ship_count", "00 SHIPS")
	_add_status_pill(summary, "selected_ship", "SEL --")
	_add_status_pill(summary, "follow_ship", "FOLLOW --")
	_add_status_pill(summary, "risk_count", "RISK 00")
	_add_status_pill(summary, "data_source", "SIM ONLY")

	_plot = AISPlot.new()
	_plot.custom_minimum_size = Vector2(0.0, 168.0)
	stack.add_child(_plot)

	var table_header := HBoxContainer.new()
	table_header.add_theme_constant_override("separation", 6)
	stack.add_child(table_header)
	_add_header_cell(table_header, "船名", 138.0)
	_add_header_cell(table_header, "航速", 66.0)
	_add_header_cell(table_header, "航向", 62.0)
	_add_header_cell(table_header, "模式", 74.0)
	_add_header_cell(table_header, "目标航点", 128.0)
	_add_header_cell(table_header, "风险", 92.0)
	_add_header_cell(table_header, "", 118.0)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	stack.add_child(scroll)
	_ship_list = VBoxContainer.new()
	_ship_list.add_theme_constant_override("separation", 5)
	_ship_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_ship_list)


func _add_status_pill(parent: Control, key: String, text: String) -> void:
	var label := _make_label(text, 12, COLOR_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	label.custom_minimum_size = Vector2(120.0, 30.0)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_stylebox_override("normal", _panel_style(COLOR_PANEL, COLOR_ACCENT))
	parent.add_child(label)
	_labels[key] = label


func _add_header_cell(parent: Control, text: String, width: float) -> void:
	var label := _make_label(text, 11, COLOR_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	label.custom_minimum_size = Vector2(width, 22.0)
	parent.add_child(label)


func _refresh_fleet_view() -> void:
	if _fleet_manager == null or not is_instance_valid(_fleet_manager):
		_resolve_sources()
	_clear_ship_rows()
	_ship_nodes.clear()
	var selected_ship := _get_selected_ship()
	var controlled_ship := _get_controlled_ship()
	var records: Array[Dictionary] = []
	var risk_count := 0
	var raw_ships := _get_ship_nodes()
	for raw_ship in raw_ships:
		if not (raw_ship is Node3D) or not is_instance_valid(raw_ship):
			continue
		var ship := raw_ship as Node3D
		_ship_nodes.append(ship)
		var record := _make_ship_record(ship, selected_ship, controlled_ship)
		records.append(record)
		if int(record.get("risk_level", 0)) > 0:
			risk_count += 1
		_add_ship_row(ship, record)
	_load_external_ais_records()
	for external_record in _external_ais_records:
		records.append(external_record)
		_add_external_ship_row(external_record)
	if records.is_empty():
		_add_empty_fleet_row()
	_update_label("ship_count", "%02d SHIPS" % records.size())
	_update_label("selected_ship", "SEL " + _short_ship_name(selected_ship))
	_update_label("follow_ship", "FOLLOW " + _short_ship_name(controlled_ship))
	_update_label("risk_count", "RISK %02d" % risk_count, COLOR_GREEN if risk_count == 0 else COLOR_AMBER)
	_update_label("data_source", _ais_data_source, COLOR_GREEN if not _external_ais_records.is_empty() else COLOR_MUTED)
	if _plot != null:
		_plot.set_data(records, _get_route_points())


func _clear_ship_rows() -> void:
	if _ship_list == null:
		return
	for child in _ship_list.get_children():
		_ship_list.remove_child(child)
		child.queue_free()


func _add_ship_row(ship: Node3D, record: Dictionary) -> void:
	var selected := bool(record.get("selected", false))
	var controlled := bool(record.get("controlled", false))
	var risk_level := int(record.get("risk_level", 0))
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0.0, 38.0)
	var border_color := COLOR_ACCENT if selected else Color(0.28, 0.96, 1.0, 0.20)
	if controlled:
		border_color = COLOR_AMBER
	row.add_theme_stylebox_override("panel", _panel_style(COLOR_ROW, border_color, 6))
	_ship_list.add_child(row)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	row.add_child(line)
	_add_row_label(line, String(record.get("name", "--")), 138.0, COLOR_ACCENT if selected else COLOR_TEXT, HORIZONTAL_ALIGNMENT_LEFT)
	_add_row_label(line, "%.1f kn" % float(record.get("speed_knots", 0.0)), 66.0, COLOR_TEXT)
	_add_row_label(line, "%03d deg" % int(round(float(record.get("heading", 0.0)))), 62.0, COLOR_TEXT)
	_add_row_label(line, String(record.get("mode", "--")), 74.0, COLOR_GREEN if controlled else COLOR_TEXT)
	_add_row_label(line, String(record.get("waypoint", "--")), 128.0, COLOR_TEXT, HORIZONTAL_ALIGNMENT_LEFT)
	_add_row_label(line, String(record.get("risk", "--")), 92.0, _risk_color(risk_level))

	var select_button := _make_button("选中")
	select_button.custom_minimum_size = Vector2(56.0, 28.0)
	select_button.disabled = selected
	select_button.pressed.connect(_on_select_ship_pressed.bind(ship))
	line.add_child(select_button)

	var follow_button := _make_button("跟随")
	follow_button.custom_minimum_size = Vector2(56.0, 28.0)
	follow_button.disabled = controlled
	follow_button.pressed.connect(_on_follow_ship_pressed.bind(ship))
	line.add_child(follow_button)


func _add_empty_fleet_row() -> void:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0.0, 42.0)
	row.add_theme_stylebox_override("panel", _panel_style(COLOR_ROW, Color(0.28, 0.96, 1.0, 0.20), 6))
	_ship_list.add_child(row)
	var label := _make_label("AIS DATA EMPTY  设置 SHIP_AIS_TARGETS 或运行 public_data_pipeline.py ais；不会生成虚构目标。", 12, COLOR_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)


func _add_external_ship_row(record: Dictionary) -> void:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0.0, 38.0)
	row.add_theme_stylebox_override("panel", _panel_style(COLOR_ROW, Color(0.46, 1.0, 0.58, 0.30), 6))
	_ship_list.add_child(row)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	row.add_child(line)
	_add_row_label(line, String(record.get("name", "--")), 138.0, COLOR_GREEN, HORIZONTAL_ALIGNMENT_LEFT)
	_add_row_label(line, "%.1f kn" % float(record.get("speed_knots", 0.0)), 66.0, COLOR_TEXT)
	_add_row_label(line, "%03d deg" % int(round(float(record.get("heading", 0.0)))), 62.0, COLOR_TEXT)
	_add_row_label(line, "AIS历史", 74.0, COLOR_GREEN)
	_add_row_label(line, String(record.get("timestamp", "--")).right(16), 128.0, COLOR_TEXT, HORIZONTAL_ALIGNMENT_LEFT)
	_add_row_label(line, "观测数据", 92.0, COLOR_GREEN)
	_add_row_label(line, "只读", 118.0, COLOR_MUTED)


func _load_external_ais_records() -> void:
	_external_ais_records.clear()
	_ais_data_source = "SIM ONLY"
	var candidates: Array[String] = []
	var environment_path := OS.get_environment("SHIP_AIS_TARGETS")
	if not environment_path.is_empty():
		candidates.append(environment_path)
	candidates.append(ProjectSettings.globalize_path(ais_targets_path))
	for candidate in candidates:
		if not FileAccess.file_exists(candidate):
			continue
		var file := FileAccess.open(candidate, FileAccess.READ)
		if file == null:
			continue
		var parsed = JSON.parse_string(file.get_as_text())
		file.close()
		if parsed is not Dictionary:
			continue
		var payload := parsed as Dictionary
		if String(payload.get("format", "")) != "ship_ais_targets_v1":
			continue
		var source := payload.get("source", {}) as Dictionary
		_ais_data_source = "NOAA AIS" if String(source.get("provider", "")).contains("NOAA") else "PUBLIC AIS"
		for raw_target in payload.get("targets", []) as Array:
			var target := raw_target as Dictionary
			_external_ais_records.append({
				"name": String(target.get("name", "MMSI " + String(target.get("mmsi", "--")))),
				"position": Vector3(float(target.get("x", 0.0)), 0.0, float(target.get("z", 0.0))),
				"speed_knots": float(target.get("speed_knots", 0.0)),
				"heading": float(target.get("heading_degrees", 0.0)),
				"timestamp": String(target.get("timestamp", "")),
				"risk_level": 0,
				"selected": false,
				"controlled": false,
			})
		return


func _add_row_label(parent: Control, text: String, width: float, color: Color, alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> void:
	var label := _make_label(text, 11, color, alignment)
	label.custom_minimum_size = Vector2(width, 28.0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.clip_text = true
	parent.add_child(label)


func _make_ship_record(ship: Node3D, selected_ship: Node3D, controlled_ship: Node3D) -> Dictionary:
	var telemetry := _get_ship_telemetry(ship)
	var route_data := _get_route_data(ship.global_position)
	var risk_data := _risk_status(telemetry, route_data)
	return {
		"name": _display_ship_name(ship, telemetry),
		"position": ship.global_position,
		"speed_knots": absf(float(telemetry.get("speed", 0.0))) * KNOTS_PER_MPS,
		"heading": fposmod(float(telemetry.get("heading_degrees", 0.0)), 360.0),
		"mode": _control_mode(ship, telemetry, controlled_ship),
		"waypoint": _waypoint_label(route_data),
		"risk": String(risk_data.get("label", "--")),
		"risk_level": int(risk_data.get("level", 0)),
		"selected": ship == selected_ship,
		"controlled": ship == controlled_ship
	}


func _resolve_sources() -> void:
	_fleet_manager = get_node_or_null(fleet_manager_path)
	if _fleet_manager == null:
		_fleet_manager = get_tree().get_first_node_in_group(&"ship_fleet_manager")
	_route_system = get_node_or_null(route_system_path)
	if _route_system == null:
		_route_system = get_tree().get_first_node_in_group(&"ship_route_system")
	_connect_fleet_signal("fleet_changed")
	_connect_fleet_signal("ship_selected")
	_connect_fleet_signal("controlled_ship_changed")


func _connect_fleet_signal(signal_name: StringName) -> void:
	if _fleet_manager == null or not _fleet_manager.has_signal(signal_name):
		return
	var callable := Callable(self, "_on_fleet_changed")
	if not _fleet_manager.is_connected(signal_name, callable):
		_fleet_manager.connect(signal_name, callable)


func _on_fleet_changed(_ship: Node3D = null) -> void:
	if _root != null and _root.visible:
		_refresh_timer = 0.0


func _get_ship_nodes() -> Array:
	if _fleet_manager != null and _fleet_manager.has_method("get_ship_records"):
		return _fleet_manager.call("get_ship_records") as Array
	return get_tree().get_nodes_in_group(&"ship_agent")


func _get_selected_ship() -> Node3D:
	if _fleet_manager != null and _fleet_manager.has_method("get_selected_ship"):
		var selected: Variant = _fleet_manager.call("get_selected_ship")
		if selected is Node3D and is_instance_valid(selected):
			return selected
	return null


func _get_controlled_ship() -> Node3D:
	if _fleet_manager != null and _fleet_manager.has_method("get_controlled_ship"):
		var controlled: Variant = _fleet_manager.call("get_controlled_ship")
		if controlled is Node3D and is_instance_valid(controlled):
			return controlled
	return null


func _get_ship_telemetry(ship: Node3D) -> Dictionary:
	if ship != null and ship.has_method("get_ship_telemetry"):
		return ship.call("get_ship_telemetry") as Dictionary
	return {}


func _get_route_data(position: Vector3) -> Dictionary:
	if _route_system == null or not is_instance_valid(_route_system):
		_route_system = get_node_or_null(route_system_path)
		if _route_system == null:
			_route_system = get_tree().get_first_node_in_group(&"ship_route_system")
	if _route_system != null and _route_system.has_method("get_route_telemetry"):
		return _route_system.call("get_route_telemetry", position) as Dictionary
	return {"active": false}


func _get_route_points() -> Array[Dictionary]:
	var points: Array[Dictionary] = []
	if _route_system == null or not is_instance_valid(_route_system):
		_route_system = get_tree().get_first_node_in_group(&"ship_route_system")
	if _route_system == null or not _route_system.has_method("get_radar_route_data"):
		return points
	var radar_data := _route_system.call("get_radar_route_data") as Dictionary
	var raw_points: Array = radar_data.get("points", [])
	for point in raw_points:
		if point is Dictionary:
			points.append(point)
	return points


func _display_ship_name(ship: Node3D, telemetry: Dictionary) -> String:
	var agent_id := String(telemetry.get("agent_id", ""))
	if agent_id.is_empty():
		return ship.name
	return "%s / %s" % [agent_id, ship.name]


func _control_mode(ship: Node3D, telemetry: Dictionary, controlled_ship: Node3D) -> String:
	if ship == controlled_ship:
		return "跟随"
	if bool(telemetry.get("external_agent_control_enabled", false)):
		return "RL"
	if bool(telemetry.get("human_control_enabled", false)):
		return "人工"
	return "待机"


func _waypoint_label(route_data: Dictionary) -> String:
	if not bool(route_data.get("active", false)):
		return "ROUTE IDLE"
	var name := String(route_data.get("current_name", "--"))
	var distance := float(route_data.get("current_distance", 0.0))
	return "%s  %04.0fm" % [name, distance]


func _risk_status(telemetry: Dictionary, route_data: Dictionary) -> Dictionary:
	if bool(telemetry.get("collision_warning_active", false)):
		var warning := String(telemetry.get("collision_warning", "COLLISION"))
		return {"label": warning, "level": 2}
	var deviation := float(route_data.get("deviation_distance", 0.0))
	if deviation >= 80.0:
		return {"label": "偏航高", "level": 2}
	if deviation >= 35.0:
		return {"label": "偏航", "level": 1}
	return {"label": "正常", "level": 0}


func _on_select_ship_pressed(ship: Node3D) -> void:
	if _fleet_manager != null and is_instance_valid(ship) and _fleet_manager.has_method("select_ship"):
		_fleet_manager.call("select_ship", ship)
	_refresh_fleet_view()


func _on_follow_ship_pressed(ship: Node3D) -> void:
	if _fleet_manager != null and is_instance_valid(ship) and _fleet_manager.has_method("take_control_of_ship"):
		_fleet_manager.call("take_control_of_ship", ship)
	_refresh_fleet_view()


func _short_ship_name(ship: Node3D) -> String:
	if ship == null or not is_instance_valid(ship):
		return "LOCAL"
	return ship.name


func _risk_color(level: int) -> Color:
	if level >= 2:
		return COLOR_RED
	if level == 1:
		return COLOR_AMBER
	return COLOR_GREEN


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
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.34)
	style.shadow_size = 10
	return style


func _update_label(key: String, value: String, color: Color = COLOR_TEXT) -> void:
	var label := _labels.get(key) as Label
	if label == null:
		return
	label.text = value
	label.add_theme_color_override("font_color", color)

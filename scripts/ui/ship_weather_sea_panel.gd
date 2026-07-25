extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_W
const REFRESH_INTERVAL := 0.25
const COLOR_BG := Color(0.010, 0.020, 0.030, 0.94)
const COLOR_PANEL := Color(0.030, 0.052, 0.064, 0.95)
const COLOR_ACCENT := Color(0.28, 0.96, 1.0, 0.96)
const COLOR_GREEN := Color(0.46, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.72, 0.26, 1.0)
const COLOR_RED := Color(1.0, 0.28, 0.22, 1.0)
const COLOR_TEXT := Color(0.80, 0.94, 1.0, 0.98)
const COLOR_MUTED := Color(0.56, 0.70, 0.76, 0.92)

const WEATHER_MODE_NAMES := ["晴天", "薄雾", "黄昏", "夜航"]

@export var start_visible: bool = false
@export var weather_time_path: NodePath = NodePath("../ShipWeatherTimeController")

var _root: Control
var _tabs: TabContainer
var _weather_time_source: Node
var _labels: Dictionary = {}
var _spins: Dictionary = {}
var _gauge: SeaStateGauge
var _refresh_timer := 0.0
var _syncing_controls := false


class SeaStateGauge:
	extends Control

	var wind_speed := 0.0
	var wave_height := 0.0
	var visibility := 20.0
	var current_speed := 0.0
	var tide := 0.0
	var label_text := "CALM"

	func set_state(
		next_wind_speed: float,
		next_wave_height: float,
		next_visibility: float,
		next_current_speed: float,
		next_tide: float,
		next_label: String
	) -> void:
		wind_speed = next_wind_speed
		wave_height = next_wave_height
		visibility = next_visibility
		current_speed = next_current_speed
		tide = next_tide
		label_text = next_label
		queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.010, 0.032, 0.046, 0.90), true)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.28, 0.96, 1.0, 0.36), false, 1.0)
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(16.0, 24.0), "SEA STATE // " + label_text, HORIZONTAL_ALIGNMENT_LEFT, size.x - 32.0, 16, _state_color())
		_draw_bar("wind", wind_speed, 60.0, 48.0, COLOR_ACCENT)
		_draw_bar("wave", wave_height, 8.0, 78.0, COLOR_AMBER)
		_draw_bar("vis", visibility, 30.0, 108.0, COLOR_GREEN)
		_draw_bar("current", current_speed, 8.0, 138.0, Color(0.64, 0.80, 1.0, 1.0))
		draw_string(font, Vector2(16.0, size.y - 16.0), "tide %+0.1fm" % tide, HORIZONTAL_ALIGNMENT_LEFT, size.x - 32.0, 12, Color(0.70, 0.92, 1.0, 0.82))

	func _draw_bar(title: String, value: float, max_value: float, y: float, color: Color) -> void:
		var font := ThemeDB.fallback_font
		var x := 82.0
		var width := maxf(size.x - 156.0, 60.0)
		var ratio := clampf(value / maxf(max_value, 0.001), 0.0, 1.0)
		draw_string(font, Vector2(16.0, y + 9.0), title, HORIZONTAL_ALIGNMENT_LEFT, 58.0, 11, Color(0.70, 0.92, 1.0, 0.72))
		draw_rect(Rect2(x, y, width, 8.0), Color(0.08, 0.16, 0.18, 0.88), true)
		draw_rect(Rect2(x, y, width * ratio, 8.0), color, true)
		draw_string(font, Vector2(x + width + 8.0, y + 9.0), "%04.1f" % value, HORIZONTAL_ALIGNMENT_RIGHT, 54.0, 11, color)

	func _state_color() -> Color:
		if wave_height >= 4.0 or wind_speed >= 34.0:
			return COLOR_RED
		if wave_height >= 2.0 or wind_speed >= 22.0:
			return COLOR_AMBER
		return COLOR_GREEN


func _ready() -> void:
	layer = 62
	_build_interface()
	_resolve_weather_time_source()
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
	_root.visible = true
	_refresh_timer = 0.0
	_update_panel()


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipWeatherSeaRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = start_visible
	add_child(_root)

	var panel := PanelContainer.new()
	panel.name = "WeatherSeaPanel"
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -238.0
	panel.offset_top = -334.0
	panel.offset_right = 238.0
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
	var title := _make_label("气象海况 / Weather Sea", 16, COLOR_ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var refresh_button := _make_button("刷新公开数据")
	refresh_button.pressed.connect(_on_refresh_public_weather_pressed)
	header.add_child(refresh_button)
	var hide_button := _make_button("收起")
	hide_button.pressed.connect(func() -> void: _root.visible = false)
	header.add_child(hide_button)

	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", 8)
	stack.add_child(summary)
	_add_status_pill(summary, "weather_mode", "--")
	_add_status_pill(summary, "weather_time", "--")
	_add_status_pill(summary, "sea_label", "--")
	_add_status_pill(summary, "data_status", "DATA --")

	_gauge = SeaStateGauge.new()
	_gauge.custom_minimum_size = Vector2(0.0, 178.0)
	stack.add_child(_gauge)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(_tabs)
	_tabs.add_child(_build_weather_tab())
	_tabs.add_child(_build_sea_tab())
	_tabs.add_child(_build_time_tab())


func _build_weather_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "气象"
	root.add_theme_constant_override("separation", 8)

	var mode_row := GridContainer.new()
	mode_row.columns = 4
	mode_row.add_theme_constant_override("h_separation", 6)
	root.add_child(mode_row)
	for index in range(WEATHER_MODE_NAMES.size()):
		var button := _make_button(WEATHER_MODE_NAMES[index])
		button.pressed.connect(_on_weather_mode_pressed.bind(index))
		mode_row.add_child(button)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 7)
	root.add_child(grid)
	_add_metric(grid, "weather_readout", "天气模式")
	_add_metric(grid, "visibility_readout", "能见度")
	_add_metric(grid, "fog_readout", "雾效联动")
	_add_metric(grid, "audio_readout", "风浪音效")
	_add_metric(grid, "data_source", "公开数据源")
	_add_metric(grid, "observed_at", "数据时间")

	root.add_child(_make_spin_row("visibility_km", "能见度", 0.1, 30.0, 0.1, "km"))
	root.add_child(_make_spin_row("wind_speed_knots", "风速", 0.0, 60.0, 0.5, "kn"))
	root.add_child(_make_spin_row("wind_direction_degrees", "风向", 0.0, 359.0, 1.0, "deg"))

	var footer := _make_label("天气按钮会套用基础光照；能见度会实时驱动雾效。", 11, COLOR_MUTED)
	footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(footer)
	return root


func _build_sea_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "海况"
	root.add_theme_constant_override("separation", 8)
	root.add_child(_make_spin_row("wave_height_meters", "浪高", 0.0, 8.0, 0.1, "m"))
	root.add_child(_make_spin_row("current_speed_knots", "海流速度", 0.0, 8.0, 0.1, "kn"))
	root.add_child(_make_spin_row("current_direction_degrees", "海流方向", 0.0, 359.0, 1.0, "deg"))
	root.add_child(_make_spin_row("tide_meters", "潮位", -5.0, 5.0, 0.1, "m"))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 7)
	root.add_child(grid)
	_add_metric(grid, "wave_readout", "浪况等级")
	_add_metric(grid, "current_readout", "海流向量")
	_add_metric(grid, "tide_readout", "潮汐状态")
	_add_metric(grid, "sea_effect_readout", "真实联动")
	return root


func _build_time_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "时间"
	root.add_theme_constant_override("separation", 8)
	root.add_child(_make_spin_row("time_scale", "时间倍率", 0.0, 240.0, 1.0, "x"))

	var quick_row := HBoxContainer.new()
	quick_row.add_theme_constant_override("separation", 6)
	root.add_child(quick_row)
	for value in [0.0, 1.0, 30.0, 60.0, 120.0]:
		var button := _make_button("%dx" % int(value))
		button.pressed.connect(_set_time_scale.bind(value))
		quick_row.add_child(button)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 7)
	root.add_child(grid)
	_add_metric(grid, "time_readout", "模拟时间")
	_add_metric(grid, "time_scale_readout", "时间倍率")
	_add_metric(grid, "sun_readout", "光照联动")
	_add_metric(grid, "status_payload", "状态输出")
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
	title_label.custom_minimum_size = Vector2(96.0, 22.0)
	parent.add_child(title_label)
	var value_label := _make_label("--", 12, COLOR_TEXT)
	value_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value_label.custom_minimum_size = Vector2(286.0, 22.0)
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(value_label)
	_labels[key] = value_label


func _make_spin_row(key: String, title: String, min_value: float, max_value: float, step: float, unit: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var label := _make_label(title, 12, COLOR_TEXT)
	label.custom_minimum_size = Vector2(108.0, 0.0)
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(_on_sea_state_spin_changed)
	row.add_child(spin)
	_spins[key] = spin
	var unit_label := _make_label(unit, 11, COLOR_MUTED)
	unit_label.custom_minimum_size = Vector2(34.0, 0.0)
	row.add_child(unit_label)
	return row


func _resolve_weather_time_source() -> void:
	_weather_time_source = get_node_or_null(weather_time_path)
	if _weather_time_source == null:
		_weather_time_source = get_tree().get_first_node_in_group(&"ship_weather_time_system")


func _update_panel() -> void:
	if _weather_time_source == null or not is_instance_valid(_weather_time_source):
		_resolve_weather_time_source()
	if _weather_time_source == null or not _weather_time_source.has_method("get_weather_time_status"):
		return
	var status: Dictionary = _weather_time_source.call("get_weather_time_status")
	_sync_controls_from_status(status)

	var sea_label := String(status.get("sea_state_label", "--"))
	var wind_speed := float(status.get("wind_speed_knots", 0.0))
	var wave_height := float(status.get("wave_height_meters", 0.0))
	var visibility := float(status.get("visibility_km", 0.0))
	var current_speed := float(status.get("current_speed_knots", 0.0))
	var tide := float(status.get("tide_meters", 0.0))

	_update_label("weather_mode", String(status.get("name", "--")))
	_update_label("weather_time", String(status.get("time", "--")))
	_update_label("sea_label", sea_label, _sea_color(wind_speed, wave_height))
	_update_label("data_status", "DATA " + String(status.get("data_status", "--")).to_upper(), COLOR_GREEN if String(status.get("data_status", "")) == "live" else COLOR_AMBER)
	_update_label("weather_readout", "%s  %s" % [String(status.get("name", "--")), String(status.get("weather", "--"))])
	_update_label("visibility_readout", "%.1f km" % visibility, COLOR_RED if visibility < 2.0 else COLOR_AMBER if visibility < 8.0 else COLOR_GREEN)
	_update_label("fog_readout", "visibility -> Environment fog density")
	_update_label("audio_readout", "wind %.1f kn / wave %.1f m -> ambient mix" % [wind_speed, wave_height])
	_update_label("data_source", String(status.get("data_source", "--")))
	_update_label("observed_at", String(status.get("observed_at", "--")))
	_update_label("wave_readout", sea_label, _sea_color(wind_speed, wave_height))
	_update_label("current_readout", "%.1f kn @ %03d deg" % [current_speed, int(round(float(status.get("current_direction_degrees", 0.0)))) % 360])
	_update_label("tide_readout", "%+.1f m" % tide, COLOR_AMBER if absf(tide) > 2.0 else COLOR_GREEN)
	_update_label("sea_effect_readout", "controller status + fog + ambient wind/water")
	_update_label("time_readout", String(status.get("time", "--")))
	_update_label("time_scale_readout", "%.0fx" % float(status.get("time_scale", 0.0)))
	_update_label("sun_readout", "time scale -> sun energy / angle")
	_update_label("status_payload", "ShipWeatherTimeController.get_weather_time_status()")

	if _gauge != null:
		_gauge.set_state(wind_speed, wave_height, visibility, current_speed, tide, sea_label)


func _sync_controls_from_status(status: Dictionary) -> void:
	if _spins.is_empty():
		return
	_syncing_controls = true
	_set_spin_value("wind_speed_knots", float(status.get("wind_speed_knots", 0.0)))
	_set_spin_value("wind_direction_degrees", float(status.get("wind_direction_degrees", 0.0)))
	_set_spin_value("wave_height_meters", float(status.get("wave_height_meters", 0.0)))
	_set_spin_value("visibility_km", float(status.get("visibility_km", 0.0)))
	_set_spin_value("current_speed_knots", float(status.get("current_speed_knots", 0.0)))
	_set_spin_value("current_direction_degrees", float(status.get("current_direction_degrees", 0.0)))
	_set_spin_value("tide_meters", float(status.get("tide_meters", 0.0)))
	_set_spin_value("time_scale", float(status.get("time_scale", 0.0)))
	_syncing_controls = false


func _set_spin_value(key: String, value: float) -> void:
	var spin := _spins.get(key) as SpinBox
	if spin == null:
		return
	spin.set_block_signals(true)
	spin.value = value
	spin.set_block_signals(false)


func _on_weather_mode_pressed(index: int) -> void:
	if _weather_time_source == null or not is_instance_valid(_weather_time_source):
		_resolve_weather_time_source()
	if _weather_time_source != null and _weather_time_source.has_method("apply_mode"):
		_weather_time_source.call("apply_mode", index)
	_update_panel()


func _on_refresh_public_weather_pressed() -> void:
	if _weather_time_source == null or not is_instance_valid(_weather_time_source):
		_resolve_weather_time_source()
	if _weather_time_source != null and _weather_time_source.has_method("refresh_public_weather"):
		_weather_time_source.call("refresh_public_weather")
	_update_panel()


func _on_sea_state_spin_changed(_value: float) -> void:
	if _syncing_controls:
		return
	_apply_current_controls()


func _set_time_scale(value: float) -> void:
	_set_spin_value("time_scale", value)
	_apply_current_controls()


func _apply_current_controls() -> void:
	if _weather_time_source == null or not is_instance_valid(_weather_time_source):
		_resolve_weather_time_source()
	if _weather_time_source == null or not _weather_time_source.has_method("apply_sea_state"):
		return
	var payload := {}
	for key in _spins.keys():
		var spin := _spins[key] as SpinBox
		if spin != null:
			payload[String(key)] = spin.value
	_weather_time_source.call("apply_sea_state", payload)
	_update_panel()


func _sea_color(wind_speed: float, wave_height: float) -> Color:
	if wave_height >= 4.0 or wind_speed >= 34.0:
		return COLOR_RED
	if wave_height >= 2.0 or wind_speed >= 22.0:
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

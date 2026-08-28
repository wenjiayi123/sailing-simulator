extends CanvasLayer
class_name ShipMultisensorFusionPanel

const TOGGLE_PANEL_KEY := KEY_K
const REFRESH_INTERVAL := 0.25
const COLOR_BG := Color(0.008, 0.020, 0.030, 0.97)
const COLOR_PANEL := Color(0.026, 0.052, 0.068, 0.97)
const COLOR_CYAN := Color(0.28, 0.94, 1.0, 1.0)
const COLOR_GREEN := Color(0.42, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.73, 0.25, 1.0)
const COLOR_RED := Color(1.0, 0.34, 0.29, 1.0)
const COLOR_TEXT := Color(0.84, 0.95, 1.0, 1.0)
const COLOR_MUTED := Color(0.56, 0.70, 0.77, 1.0)

@export var start_visible := false
@export var fusion_suite_path: NodePath = NodePath("../ShipMultisensorFusionSuite")

var _root: Control
var _fusion_suite: Node
var _labels: Dictionary = {}
var _refresh_timer := 0.0
var _last_snapshot: Dictionary = {}


func _ready() -> void:
	layer = 67
	add_to_group(&"ship_multisensor_fusion_panel")
	_fusion_suite = get_node_or_null(fusion_suite_path)
	_build_interface()
	_update_panel()
	set_process(true)
	set_process_unhandled_input(true)


func _process(delta: float) -> void:
	if not _root.visible:
		return
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
	_root.name = "ShipMultisensorFusionRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = start_visible
	add_child(_root)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -470.0
	panel.offset_top = -330.0
	panel.offset_right = 470.0
	panel.offset_bottom = 330.0
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_BG
	style.border_color = COLOR_CYAN
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	panel.add_theme_stylebox_override("panel", style)
	_root.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 9)
	margin.add_child(stack)

	var header := HBoxContainer.new()
	stack.add_child(header)
	var title := _label("多源传感融合 / RADAR · AIS · EO · IR · GNSS · INS", 18, COLOR_CYAN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	header.add_child(_label("仿真/回放｜实设备未验证", 11, COLOR_AMBER))
	var close := Button.new()
	close.text = "收起 K"
	close.pressed.connect(hide_panel)
	header.add_child(close)

	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 7)
	stack.add_child(status_row)
	for sensor_id in ["RADAR", "AIS", "EO", "IR", "GNSS", "INS"]:
		var sensor_label := _pill(sensor_id + " --")
		_labels["sensor_" + sensor_id] = sensor_label
		status_row.add_child(sensor_label)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 10)
	stack.add_child(columns)

	var fusion_column := _column("融合状态 / FUSION HEALTH")
	fusion_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(fusion_column)
	_add_metric(fusion_column, "fusion_mode", "模式")
	_add_metric(fusion_column, "navigation", "本船组合导航")
	_add_metric(fusion_column, "disagreement", "GNSS/INS差异")
	_add_metric(fusion_column, "track_count", "融合目标")
	_add_metric(fusion_column, "decision_gate", "决策输入门禁")
	_add_metric(fusion_column, "rl_gateway", "强化学习观测出口")

	var track_column := _column("目标来源 / TRACK PROVENANCE")
	track_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(track_column)
	var track_list := RichTextLabel.new()
	track_list.bbcode_enabled = true
	track_list.fit_content = false
	track_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	track_list.custom_minimum_size = Vector2(370.0, 300.0)
	track_list.add_theme_color_override("default_color", COLOR_TEXT)
	_labels["track_list"] = track_list
	track_column.add_child(track_list)

	var fault_column := _column("故障注入 / FAULT INJECTION")
	fault_column.custom_minimum_size.x = 245.0
	columns.add_child(fault_column)
	fault_column.add_child(_button("雷达掉线", func() -> void: _set_fault("radar_dropout", true)))
	fault_column.add_child(_button("光电遮挡 80%", func() -> void: _set_fault("eo_occlusion_ratio", 0.8)))
	fault_column.add_child(_button("红外误报 ×3", func() -> void: _set_fault("ir_false_alarm_count", 3)))
	fault_column.add_child(_button("AIS 延迟 2.5s", func() -> void: _set_fault("ais_latency_ms", 2500.0)))
	fault_column.add_child(_button("GNSS 欺骗偏移", func() -> void: _set_fault("gnss_spoof_offset_m", Vector2(220.0, -140.0))))
	fault_column.add_child(_button("INS 首向偏差", func() -> void: _set_fault("ins_heading_bias_deg", 8.0)))
	var restore := _button("全部恢复", _clear_faults)
	restore.add_theme_color_override("font_color", COLOR_GREEN)
	fault_column.add_child(restore)
	_add_metric(fault_column, "external_ingest", "实传感接入")
	_add_metric(fault_column, "receipt_count", "审计回执")

	var boundary := _label("所有通道均携带时间、来源、质量、完整性和硬件验证标记。当前数据来自仿真或历史回放；未接入物理雷达、光电/红外、GNSS、INS，生产控制保持关闭。", 11, COLOR_AMBER)
	boundary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(boundary)


func _column(title_text: String) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 7)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_PANEL
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)
	column.add_child(panel)
	panel.add_child(_label("  " + title_text, 14, COLOR_CYAN))
	return column


func _add_metric(parent: Control, key: String, title_text: String) -> void:
	var label := _label(title_text + "：--", 12, COLOR_TEXT)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_labels[key] = label
	parent.add_child(label)


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _pill(text_value: String) -> Label:
	var label := _label("  " + text_value + "  ", 11, COLOR_MUTED)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.08, 0.10, 0.92)
	style.border_color = Color(0.28, 0.94, 1.0, 0.34)
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	label.add_theme_stylebox_override("normal", style)
	return label


func _button(text_value: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text_value
	button.custom_minimum_size.y = 34.0
	button.pressed.connect(callback)
	return button


func _set_fault(name: String, value: Variant) -> void:
	if _fusion_suite != null and _fusion_suite.has_method("set_sensor_fault"):
		_fusion_suite.call("set_sensor_fault", name, value)
		_fusion_suite.call("advance_simulation_time_for_test", 1.0)
	_update_panel()


func _clear_faults() -> void:
	if _fusion_suite != null and _fusion_suite.has_method("clear_sensor_faults"):
		_fusion_suite.call("clear_sensor_faults")
	_update_panel()


func _update_panel() -> void:
	if _fusion_suite == null or not is_instance_valid(_fusion_suite):
		_fusion_suite = get_node_or_null(fusion_suite_path)
	if _fusion_suite == null or not _fusion_suite.has_method("get_fusion_snapshot"):
		return
	_last_snapshot = _fusion_suite.call("get_fusion_snapshot") as Dictionary
	if _last_snapshot.is_empty():
		_last_snapshot = _fusion_suite.call("advance_simulation_time_for_test", 1.0) as Dictionary
	var channels := _last_snapshot.get("channels", {}) as Dictionary
	for sensor_id in ["RADAR", "AIS", "EO", "IR", "GNSS", "INS"]:
		var health := channels.get(sensor_id, {}) as Dictionary
		var status := String(health.get("status", "OFFLINE"))
		var label := _labels.get("sensor_" + sensor_id) as Label
		label.text = "  %s %s  " % [sensor_id, status]
		label.add_theme_color_override("font_color", _status_color(status))
	var ownship := _last_snapshot.get("ownship_fusion", {}) as Dictionary
	_set_text("fusion_mode", "模式：%s" % String(_last_snapshot.get("fusion_mode", "--")))
	_set_text("navigation", "本船组合导航：%s" % String(ownship.get("mode", "--")))
	var disagreement: Variant = ownship.get("gnss_ins_disagreement_meters")
	_set_text("disagreement", "GNSS/INS差异：%s" % ("--" if disagreement == null else "%.1f m" % float(disagreement)))
	_set_text("track_count", "融合目标：确认 %d / 待确认 %d" % [int(_last_snapshot.get("confirmed_track_count", 0)), int(_last_snapshot.get("unconfirmed_track_count", 0))])
	_set_text("decision_gate", "决策输入门禁：%s" % ("VALID" if bool(_last_snapshot.get("decision_input_valid", false)) else "BLOCKED"))
	var gateway := _last_snapshot.get("rl_observation_gateway", {}) as Dictionary
	_set_text("rl_gateway", "强化学习观测出口：%s｜现策略未改接" % ("READY" if bool(gateway.get("available", false)) else "BLOCKED"))
	_set_text("external_ingest", "实传感接入：DISABLED")
	_set_text("receipt_count", "审计回执：%d" % int(_last_snapshot.get("receipt_count", 0)))
	var lines: Array[String] = []
	for raw_track in (_last_snapshot.get("fused_tracks", []) as Array).slice(0, 12):
		var track := raw_track as Dictionary
		var source_names: Array[String] = []
		for source in track.get("sources", []) as Array:
			source_names.append(str(source))
		var identity: Variant = track.get("identity")
		var identity_text := "UNIDENTIFIED" if identity == null else str(identity)
		lines.append("[color=%s]%s[/color]  src=%s  conf=%.2f  %s" % ["#86ff9b" if bool(track.get("confirmed", false)) else "#ffbd40", String(track.get("track_id", "--")), "+".join(source_names), float(track.get("confidence", 0.0)), identity_text])
	(_labels["track_list"] as RichTextLabel).text = "\n".join(lines) if not lines.is_empty() else "[color=#8faebf]暂无融合目标；通道健康和失效降级仍在运行。[/color]"


func _set_text(key: String, value: String) -> void:
	if _labels.has(key):
		(_labels[key] as Label).text = value


func _status_color(status: String) -> Color:
	if status == "ONLINE":
		return COLOR_GREEN
	if status == "DEGRADED" or status == "STALE":
		return COLOR_AMBER
	return COLOR_RED

extends CanvasLayer
class_name ShipExecutionControlPanel

const TOGGLE_PANEL_KEY := KEY_L
const REFRESH_INTERVAL := 0.20
const COLOR_BG := Color(0.008, 0.018, 0.027, 0.98)
const COLOR_PANEL := Color(0.024, 0.048, 0.064, 0.98)
const COLOR_CYAN := Color(0.28, 0.94, 1.0, 1.0)
const COLOR_GREEN := Color(0.42, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.73, 0.25, 1.0)
const COLOR_RED := Color(1.0, 0.29, 0.25, 1.0)
const COLOR_TEXT := Color(0.84, 0.95, 1.0, 1.0)
const COLOR_MUTED := Color(0.56, 0.70, 0.77, 1.0)

@export var start_visible := false
@export var execution_suite_path: NodePath = NodePath("../ShipExecutionControlSuite")

var _root: Control
var _execution_suite: Node
var _labels: Dictionary = {}
var _refresh_timer := 0.0
var _last_snapshot: Dictionary = {}


func _ready() -> void:
	layer = 68
	add_to_group(&"ship_execution_control_panel")
	_execution_suite = get_node_or_null(execution_suite_path)
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
	_root.name = "ShipExecutionControlRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = start_visible
	add_child(_root)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -460.0
	panel.offset_top = -318.0
	panel.offset_right = 460.0
	panel.offset_bottom = 318.0
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
	var title := _label("执行控制闭环 / AUTOPILOT · PROPULSION · AUTHORITY", 18, COLOR_CYAN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	header.add_child(_label("仿真执行器｜实设备未验证", 11, COLOR_AMBER))
	var close := _button("收起 L", hide_panel)
	header.add_child(close)

	var authority_row := HBoxContainer.new()
	authority_row.add_theme_constant_override("separation", 8)
	stack.add_child(authority_row)
	for item in [["armed", "ARM --"], ["authority", "AUTH --"], ["mode", "MODE --"], ["estop", "E-STOP --"]]:
		var pill := _pill(String(item[1]))
		pill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_labels[String(item[0])] = pill
		authority_row.add_child(pill)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 10)
	stack.add_child(columns)

	var status_column := _column("命令与反馈 / COMMAND & FEEDBACK")
	status_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(status_column)
	_add_metric(status_column, "requested", "请求指令")
	_add_metric(status_column, "effective", "限幅输出")
	_add_metric(status_column, "target_feedback", "控制器目标回读")
	_add_metric(status_column, "actual_feedback", "执行器实际反馈")
	_add_metric(status_column, "ack", "反馈确认")
	_add_metric(status_column, "watchdog", "指令看门狗")
	_add_metric(status_column, "rl_gateway", "强化学习命令出口")

	var control_column := _column("控制权 / AUTHORITY CONTROL")
	control_column.custom_minimum_size.x = 250.0
	columns.add_child(control_column)
	control_column.add_child(_button("武装仿真执行层", _arm))
	control_column.add_child(_button("申请 RL 控制权", _request_rl))
	control_column.add_child(_button("发送 RL 测试指令", _send_rl_test))
	control_column.add_child(_button("自动舵：当前首向 +20°", _engage_autopilot))
	var manual := _button("人工立即接管", _manual_takeover)
	manual.add_theme_color_override("font_color", COLOR_GREEN)
	control_column.add_child(manual)
	var estop := _button("紧急停止并锁存", _emergency_stop)
	estop.add_theme_color_override("font_color", COLOR_RED)
	control_column.add_child(estop)
	control_column.add_child(_button("人工确认并复位急停", _reset_emergency_stop))

	var fault_column := _column("故障与边界 / FAULTS & BOUNDARY")
	fault_column.custom_minimum_size.x = 250.0
	columns.add_child(fault_column)
	fault_column.add_child(_button("指令链路掉线", func() -> void: _set_fault("command_link_loss", true)))
	fault_column.add_child(_button("舵角反馈丢失", func() -> void: _set_fault("rudder_feedback_loss", true)))
	fault_column.add_child(_button("转向执行器卡滞", func() -> void: _set_fault("steering_actuator_jam", true)))
	fault_column.add_child(_button("推进执行器卡滞", func() -> void: _set_fault("propulsion_actuator_jam", true)))
	fault_column.add_child(_button("恢复执行层故障", _clear_faults))
	_add_metric(fault_column, "remote", "远程控制中心")
	_add_metric(fault_column, "physical", "物理执行器/急停")
	_add_metric(fault_column, "receipts", "审计回执")

	var boundary := _label("默认未武装。人工接管和急停优先于远程、自动舵与 RL；当前仅驱动仿真船公开控制接口。物理自动舵、主机/喷水推进、船桥操纵系统、独立双通道急停和实船权限均未验证。", 11, COLOR_AMBER)
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


func _arm() -> void:
	_call_suite("arm_simulation_execution", ["BRIDGE_OPERATOR"])


func _request_rl() -> void:
	_call_suite("request_control", ["RL"])


func _send_rl_test() -> void:
	_call_suite("submit_rl_action", [0.42, 0.18])


func _engage_autopilot() -> void:
	var heading := 0.0
	var player := get_node_or_null(NodePath("../Player"))
	if player != null and player.has_method("get_ship_telemetry"):
		heading = float((player.call("get_ship_telemetry") as Dictionary).get("heading_degrees", 0.0))
	_call_suite("engage_autopilot", [heading + 20.0, 3.0])


func _manual_takeover() -> void:
	_call_suite("manual_immediate_takeover", ["BRIDGE_HELM_TAKEOVER"])


func _emergency_stop() -> void:
	_call_suite("trigger_emergency_stop", ["BRIDGE_ESTOP_BUTTON"])


func _reset_emergency_stop() -> void:
	_call_suite("release_emergency_stop", [true])


func _set_fault(name: String, value: bool) -> void:
	_call_suite("set_execution_fault", [name, value])


func _clear_faults() -> void:
	_call_suite("clear_execution_faults")


func _call_suite(method: String, arguments: Array = []) -> void:
	_resolve_suite()
	if _execution_suite != null and _execution_suite.has_method(method):
		_execution_suite.callv(method, arguments)
	_update_panel()


func _update_panel() -> void:
	_resolve_suite()
	if _execution_suite == null or not _execution_suite.has_method("get_execution_snapshot"):
		return
	_last_snapshot = _execution_suite.call("get_execution_snapshot") as Dictionary
	var armed := bool(_last_snapshot.get("armed", false))
	var authority := String(_last_snapshot.get("authority", "--"))
	var mode := String(_last_snapshot.get("mode", "--"))
	var emergency := _last_snapshot.get("emergency_stop", {}) as Dictionary
	_set_pill("armed", "ARM %s" % ("ON" if armed else "OFF"), COLOR_GREEN if armed else COLOR_AMBER)
	_set_pill("authority", "AUTH " + authority, COLOR_GREEN if authority == "MANUAL" else COLOR_CYAN)
	_set_pill("mode", "MODE " + mode, COLOR_AMBER if mode.contains("FAIL") or mode.contains("DEGRADED") else COLOR_CYAN)
	_set_pill("estop", "E-STOP %s" % ("LATCHED" if bool(emergency.get("latched", false)) else "READY"), COLOR_RED if bool(emergency.get("latched", false)) else COLOR_GREEN)
	var requested := _last_snapshot.get("requested_command", {}) as Dictionary
	var effective := _last_snapshot.get("effective_command", {}) as Dictionary
	var feedback := _last_snapshot.get("actuator_feedback", {}) as Dictionary
	_set_text("requested", "请求指令：车钟 %+.2f｜舵 %+.2f" % [float(requested.get("throttle", 0.0)), float(requested.get("rudder", 0.0))])
	_set_text("effective", "限幅输出：车钟 %+.2f｜舵 %+.2f" % [float(effective.get("throttle", 0.0)), float(effective.get("rudder", 0.0))])
	_set_text("target_feedback", "控制器目标回读：车钟 %s｜舵 %s" % [_optional_number(feedback.get("target_throttle")), _optional_number(feedback.get("target_rudder"))])
	_set_text("actual_feedback", "执行器实际反馈：车钟 %s｜舵 %s" % [_optional_number(feedback.get("actual_throttle")), _optional_number(feedback.get("actual_rudder"))])
	_set_text("ack", "反馈确认：命令 %s｜跟踪 %s" % ["ACK" if bool(feedback.get("command_acknowledged", false)) else "WAIT/LOST", "OK" if bool(feedback.get("actual_tracking_within_tolerance", false)) else "TRANSIENT/LOST"])
	var watchdog := _last_snapshot.get("watchdog", {}) as Dictionary
	_set_text("watchdog", "指令看门狗：%s｜%.2fs" % ["TRIPPED" if bool(watchdog.get("timed_out", false)) else "READY", float(watchdog.get("timeout_seconds", 0.0))])
	var gateway := _last_snapshot.get("rl_command_gateway", {}) as Dictionary
	_set_text("rl_gateway", "强化学习命令出口：OPT-IN｜现策略未改接=%s" % str(not bool(gateway.get("existing_policy_adapter_wired", false))))
	var remote := _last_snapshot.get("remote_control_center", {}) as Dictionary
	_set_text("remote", "远程控制中心：%s" % ("VERIFIED" if bool(remote.get("site_authorized", false)) else "BLOCKED"))
	_set_text("physical", "物理执行器/急停：UNVERIFIED")
	_set_text("receipts", "审计回执：%d" % int(_last_snapshot.get("receipt_count", 0)))


func _resolve_suite() -> void:
	if _execution_suite == null or not is_instance_valid(_execution_suite):
		_execution_suite = get_node_or_null(execution_suite_path)


func _set_pill(key: String, value: String, color: Color) -> void:
	var label := _labels.get(key) as Label
	if label != null:
		label.text = "  " + value + "  "
		label.add_theme_color_override("font_color", color)


func _set_text(key: String, value: String) -> void:
	var label := _labels.get(key) as Label
	if label != null:
		label.text = value


func _optional_number(value: Variant) -> String:
	return "--" if value == null else "%+.2f" % float(value)

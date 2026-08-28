extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_J
const EXPORT_PATH := "user://ship_bridge_team_collaboration.json"
const COLOR_BG := Color(0.008, 0.019, 0.030, 0.97)
const COLOR_PANEL := Color(0.025, 0.052, 0.068, 0.96)
const COLOR_CYAN := Color(0.27, 0.94, 1.0, 1.0)
const COLOR_GREEN := Color(0.42, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.73, 0.25, 1.0)
const COLOR_RED := Color(1.0, 0.36, 0.31, 1.0)
const COLOR_TEXT := Color(0.84, 0.95, 1.0, 1.0)
const COLOR_MUTED := Color(0.55, 0.70, 0.77, 1.0)
const ROLE_OPTIONS := ["MASTER", "OOW", "HELM", "RADAR", "ECDIS", "ENGINE", "MOORING_FORE", "MOORING_AFT", "INSTRUCTOR"]
const CATEGORY_OPTIONS := ["COMMAND", "REPORT", "CHALLENGE", "RESPONSE", "ALERT"]

@export var start_visible: bool = false
@export var controller_path: NodePath = NodePath("../ShipBridgeTeamCollaborationController")

var _root: Control
var _controller: Node
var _session_name: LineEdit
var _join_role: OptionButton
var _operator_id: LineEdit
var _active_station: OptionButton
var _target_role: OptionButton
var _category: OptionButton
var _message_text: LineEdit
var _requires_readback: CheckBox
var _readback_text: LineEdit
var _hazard_text: LineEdit
var _plan_text: LineEdit
var _contingency_text: LineEdit
var _status_label: RichTextLabel
var _messages_label: RichTextLabel
var _last_receipt: Dictionary = {}


func _ready() -> void:
	layer = 61
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_interface()
	_resolve_controller()
	_refresh()
	set_process(true)
	set_process_unhandled_input(true)


func _process(_delta: float) -> void:
	if _root.visible:
		_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.physical_keycode == TOGGLE_PANEL_KEY:
			_root.visible = not _root.visible
			if _root.visible:
				_refresh()
			get_viewport().set_input_as_handled()


func show_panel() -> void:
	_root.visible = true
	_refresh()


func get_acceptance_snapshot() -> Dictionary:
	_resolve_controller()
	var collaboration := {}
	if _controller != null and _controller.has_method("get_collaboration_snapshot"):
		collaboration = _controller.call("get_collaboration_snapshot") as Dictionary
	return {
		"format": "ship_bridge_team_panel_v1",
		"collaboration": collaboration,
		"last_receipt": _last_receipt.duplicate(true),
		"production_authority": false,
		"remote_control_authority": false,
	}


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipBridgeTeamRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = start_visible
	add_child(_root)
	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.0, 0.006, 0.012, 0.80)
	_root.add_child(backdrop)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -470.0
	panel.offset_top = -342.0
	panel.offset_right = 470.0
	panel.offset_bottom = 342.0
	panel.add_theme_stylebox_override("panel", _style(COLOR_BG, COLOR_CYAN))
	_root.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 8)
	margin.add_child(stack)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	stack.add_child(header)
	var title := _label("多驾驶台协同 / BRIDGE TEAM", 20, COLOR_CYAN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var team_check := _button("团队检查")
	team_check.pressed.connect(_on_team_check_pressed)
	header.add_child(team_check)
	var export_button := _button("导出记录")
	export_button.pressed.connect(_on_export_pressed)
	header.add_child(export_button)
	var close_button := _button("关闭 J")
	close_button.pressed.connect(func() -> void: _root.visible = false)
	header.add_child(close_button)

	var session_row := HBoxContainer.new()
	session_row.add_theme_constant_override("separation", 7)
	stack.add_child(session_row)
	session_row.add_child(_label("会话", 12, COLOR_MUTED))
	_session_name = _line("港内协同训练")
	_session_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	session_row.add_child(_session_name)
	var create_button := _button("新建会话")
	create_button.pressed.connect(_on_create_session_pressed)
	session_row.add_child(create_button)
	var udp_start := _button("启动本机 UDP")
	udp_start.pressed.connect(_on_udp_start_pressed)
	session_row.add_child(udp_start)
	var udp_probe := _button("发送探针")
	udp_probe.pressed.connect(_on_udp_probe_pressed)
	session_row.add_child(udp_probe)
	var udp_stop := _button("停止 UDP")
	udp_stop.pressed.connect(_on_udp_stop_pressed)
	session_row.add_child(udp_stop)

	var station_row := HBoxContainer.new()
	station_row.add_theme_constant_override("separation", 7)
	stack.add_child(station_row)
	station_row.add_child(_label("加入岗位", 12, COLOR_MUTED))
	_join_role = OptionButton.new()
	for role in ROLE_OPTIONS:
		_join_role.add_item(role)
	_join_role.item_selected.connect(func(_index: int) -> void: _refresh())
	station_row.add_child(_join_role)
	_operator_id = _line("operator-01")
	_operator_id.custom_minimum_size.x = 140.0
	station_row.add_child(_operator_id)
	var join_button := _button("加入")
	join_button.pressed.connect(_on_join_pressed)
	station_row.add_child(join_button)
	station_row.add_child(_label("当前岗位", 12, COLOR_MUTED))
	_active_station = OptionButton.new()
	_active_station.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_active_station.item_selected.connect(func(_index: int) -> void: _refresh())
	station_row.add_child(_active_station)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 10)
	stack.add_child(columns)
	var comms := _section("闭环通信 / CLOSED LOOP")
	comms.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(comms)
	var target_row := HBoxContainer.new()
	target_row.add_theme_constant_override("separation", 6)
	comms.add_child(target_row)
	_target_role = OptionButton.new()
	_target_role.add_item("ALL")
	for role in ROLE_OPTIONS:
		_target_role.add_item(role)
	_target_role.item_selected.connect(func(_index: int) -> void: _refresh())
	target_row.add_child(_target_role)
	_category = OptionButton.new()
	for category in CATEGORY_OPTIONS:
		_category.add_item(category)
	_category.item_selected.connect(func(_index: int) -> void: _refresh())
	target_row.add_child(_category)
	_requires_readback = CheckBox.new()
	_requires_readback.text = "需要复诵"
	_requires_readback.button_pressed = true
	_requires_readback.toggled.connect(func(_pressed: bool) -> void: _refresh())
	target_row.add_child(_requires_readback)
	_message_text = _line("输入标准指令、报告或质疑")
	comms.add_child(_message_text)
	var send_button := _button("发送消息")
	send_button.pressed.connect(_on_send_pressed)
	comms.add_child(send_button)
	_readback_text = _line("输入完整复诵")
	comms.add_child(_readback_text)
	var ack_button := _button("复诵并关闭最新消息")
	ack_button.pressed.connect(_on_ack_pressed)
	comms.add_child(ack_button)

	var brm := _section("驾驶台资源管理 / BRM")
	brm.custom_minimum_size.x = 340.0
	columns.add_child(brm)
	_hazard_text = _line("主要危险")
	brm.add_child(_hazard_text)
	_plan_text = _line("共同计划")
	brm.add_child(_plan_text)
	_contingency_text = _line("中止/应急方案")
	brm.add_child(_contingency_text)
	var brief_button := _button("提交态势简报")
	brief_button.pressed.connect(_on_brief_pressed)
	brm.add_child(brief_button)
	_status_label = _rich("会话待创建", 130.0)
	brm.add_child(_status_label)

	_messages_label = _rich("MESSAGE LOG --", 92.0)
	stack.add_child(_messages_label)
	var boundary := _label("本机 UDP + 角色/复诵/质疑闭环；消息不映射舵、车钟或策略，非甚高频/全球海上遇险与安全系统。", 11, COLOR_AMBER)
	boundary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(boundary)


func _resolve_controller() -> void:
	_controller = get_node_or_null(controller_path)
	if _controller == null:
		_controller = get_tree().get_first_node_in_group(&"ship_bridge_team_collaboration_controller")


func _on_create_session_pressed() -> void:
	_resolve_controller()
	if _controller != null:
		_last_receipt = _controller.call("create_session", _session_name.text) as Dictionary
	_refresh()


func _on_join_pressed() -> void:
	_resolve_controller()
	if _controller != null:
		_last_receipt = _controller.call("join_station", _join_role.get_item_text(_join_role.selected), _operator_id.text, _operator_id.text) as Dictionary
	_refresh()


func _on_send_pressed() -> void:
	var station_id := _selected_station_id()
	if _controller == null or station_id.is_empty():
		_show_rejected("请先加入并选择岗位")
		return
	_last_receipt = _controller.call(
		"send_bridge_message",
		station_id,
		_target_role.get_item_text(_target_role.selected),
		_category.get_item_text(_category.selected),
		_message_text.text,
		_requires_readback.button_pressed,
		"bridge_team_panel",
	) as Dictionary
	_refresh()


func _on_ack_pressed() -> void:
	var station_id := _selected_station_id()
	var message_id := _latest_open_message_for_station(station_id)
	if _controller == null or station_id.is_empty() or message_id.is_empty():
		_show_rejected("当前岗位没有可复诵消息")
		return
	_last_receipt = _controller.call("acknowledge_message", message_id, station_id, _readback_text.text) as Dictionary
	_refresh()


func _on_brief_pressed() -> void:
	var station_id := _selected_station_id()
	if _controller == null or station_id.is_empty():
		_show_rejected("请先加入并选择岗位")
		return
	_last_receipt = _controller.call("record_situation_brief", station_id, _hazard_text.text, _plan_text.text, _contingency_text.text) as Dictionary
	_refresh()


func _on_team_check_pressed() -> void:
	_resolve_controller()
	if _controller != null:
		var check := _controller.call("run_brm_team_check") as Dictionary
		_last_receipt = {
			"receipt_id": "BRM-CHECK",
			"status": "EXECUTED" if bool(check.get("passed", false)) else "REJECTED",
			"detail": {"reason": ", ".join(check.get("gaps", []) as Array)},
		}
	_refresh()


func _on_udp_start_pressed() -> void:
	if _controller != null:
		_last_receipt = _controller.call("enable_udp_transport", 0, "127.0.0.1", false) as Dictionary
	_refresh()


func _on_udp_probe_pressed() -> void:
	var station_id := _selected_station_id()
	if _controller == null or station_id.is_empty():
		_show_rejected("请先加入并选择岗位")
		return
	_last_receipt = _controller.call("send_udp_loopback_probe", station_id) as Dictionary
	_refresh()


func _on_udp_stop_pressed() -> void:
	if _controller != null:
		_last_receipt = _controller.call("stop_udp_transport") as Dictionary
	_refresh()


func _on_export_pressed() -> void:
	var snapshot := get_acceptance_snapshot()
	snapshot["export_path"] = EXPORT_PATH
	var file := FileAccess.open(EXPORT_PATH, FileAccess.WRITE)
	if file == null:
		_show_rejected("导出失败")
		return
	file.store_string(JSON.stringify(snapshot, "\t") + "\n")
	file.close()
	_last_receipt = {"receipt_id": "BRM-EXPORT", "status": "EXECUTED", "detail": {"path": ProjectSettings.globalize_path(EXPORT_PATH)}}
	_refresh()


func _refresh() -> void:
	_resolve_controller()
	if _controller == null:
		_show_rejected("协同控制器未就绪")
		return
	var snapshot := _controller.call("get_collaboration_snapshot") as Dictionary
	_sync_station_options(snapshot.get("stations", []) as Array)
	var check := snapshot.get("brm_check", {}) as Dictionary
	var udp := snapshot.get("udp", {}) as Dictionary
	_status_label.text = (
		"[color=#73f5ff][b]%s[/b][/color]\n"
		+ "岗位 %d  ·  简报 %d  ·  未闭环 %d\n"
		+ "BRM %s  ·  UDP %s:%s  RX %d / REJECT %d"
	) % [
		snapshot.get("session_name", "会话待创建"),
		(snapshot.get("stations", []) as Array).size(),
		(snapshot.get("situation_briefs", []) as Array).size(),
		(check.get("open_loop_messages", []) as Array).size(),
		"PASS" if bool(check.get("passed", false)) else "GAPS " + ",".join(check.get("gaps", []) as Array),
		udp.get("bind_address", "OFF"),
		str(udp.get("port", 0)),
		int(udp.get("received_packets", 0)),
		int(udp.get("rejected_packets", 0)),
	]
	var lines: Array[String] = []
	var messages := snapshot.get("messages", []) as Array
	for index in range(maxi(messages.size() - 4, 0), messages.size()):
		var message := messages[index] as Dictionary
		lines.append("%s  %s→%s  %s  %s" % [message.get("message_id", "--"), message.get("sender_role", "--"), message.get("target_role", "--"), message.get("status", "--"), message.get("content", "")])
	if lines.is_empty():
		lines.append("尚无驾驶台通信记录")
	if not _last_receipt.is_empty():
		lines.append("RECEIPT %s  %s" % [_last_receipt.get("receipt_id", "--"), _last_receipt.get("status", "--")])
	_messages_label.text = "\n".join(lines)


func _sync_station_options(stations: Array) -> void:
	var selected_id := _selected_station_id()
	_active_station.clear()
	for raw in stations:
		var station := raw as Dictionary
		_active_station.add_item("%s / %s" % [station.get("role", "--"), station.get("operator_id", "--")])
		_active_station.set_item_metadata(_active_station.item_count - 1, station.get("station_id", ""))
		if String(station.get("station_id", "")) == selected_id:
			_active_station.select(_active_station.item_count - 1)


func _selected_station_id() -> String:
	if _active_station == null or _active_station.item_count == 0 or _active_station.selected < 0:
		return ""
	return String(_active_station.get_item_metadata(_active_station.selected))


func _latest_open_message_for_station(station_id: String) -> String:
	if station_id.is_empty() or _controller == null:
		return ""
	var snapshot := _controller.call("get_collaboration_snapshot") as Dictionary
	var role := ""
	for raw in snapshot.get("stations", []) as Array:
		var station := raw as Dictionary
		if String(station.get("station_id", "")) == station_id:
			role = String(station.get("role", ""))
	for index in range((snapshot.get("messages", []) as Array).size() - 1, -1, -1):
		var message := (snapshot.get("messages", []) as Array)[index] as Dictionary
		if String(message.get("status", "")) == "OPEN" and String(message.get("target_role", "")) in [role, "ALL"]:
			return String(message.get("message_id", ""))
	return ""


func _show_rejected(reason: String) -> void:
	_last_receipt = {"receipt_id": "NO-RECEIPT", "status": "REJECTED", "detail": {"reason": reason}}
	if _messages_label != null:
		_messages_label.text = "[color=#ff5c4f]REJECTED[/color] " + reason


func _section(title: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	var heading := _label(title, 13, COLOR_CYAN)
	heading.add_theme_stylebox_override("normal", _style(COLOR_PANEL, Color(COLOR_CYAN.r, COLOR_CYAN.g, COLOR_CYAN.b, 0.36), 6))
	box.add_child(heading)
	return box


func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 30.0
	button.add_theme_font_size_override("font_size", 12)
	return button


func _line(placeholder: String) -> LineEdit:
	var line := LineEdit.new()
	line.placeholder_text = placeholder
	line.text = ""
	line.text_changed.connect(func(_value: String) -> void: pass)
	return line


func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _rich(text: String, height: float) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.text = text
	label.custom_minimum_size.y = height
	label.fit_content = false
	label.add_theme_font_size_override("normal_font_size", 12)
	return label


func _style(fill: Color, border: Color, radius: int = 8) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	return style

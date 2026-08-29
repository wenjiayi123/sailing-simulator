extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_F12
const EXPORT_PATH := "user://ship_full_mission_bridge_snapshot.json"
const COLOR_BG := Color(0.006, 0.016, 0.027, 0.98)
const COLOR_PANEL := Color(0.022, 0.050, 0.069, 0.97)
const COLOR_CYAN := Color(0.28, 0.95, 1.0, 1.0)
const COLOR_GREEN := Color(0.43, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.73, 0.25, 1.0)
const COLOR_RED := Color(1.0, 0.34, 0.29, 1.0)
const COLOR_TEXT := Color(0.84, 0.95, 1.0, 1.0)
const COLOR_MUTED := Color(0.55, 0.70, 0.78, 1.0)

@export var start_visible := false
@export var bridge_suite_path: NodePath = NodePath("../ShipFullMissionBridgeSuite")
@export var communication_suite_path: NodePath = NodePath("../ShipGmdssCommunicationsSuite")

var _root: Control
var _bridge_suite: Node
var _communication_suite: Node
var _system_status: RichTextLabel
var _communication_log: RichTextLabel
var _mission_status: RichTextLabel
var _last_receipt: Dictionary = {}
var _prepared_distress_id := ""


func _ready() -> void:
	layer = 72
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"ship_full_mission_bridge_panel")
	_resolve_suites()
	_build_interface()
	_refresh()
	set_process(true)
	set_process_unhandled_input(true)


func _process(_delta: float) -> void:
	if _root != null and _root.visible:
		_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.physical_keycode == TOGGLE_PANEL_KEY:
			toggle_panel()
			get_viewport().set_input_as_handled()


func show_panel() -> void:
	_root.visible = true
	_refresh()


func hide_panel() -> void:
	_root.visible = false


func toggle_panel() -> void:
	_root.visible = not _root.visible
	if _root.visible:
		_refresh()


func get_acceptance_snapshot() -> Dictionary:
	_resolve_suites()
	var bridge := {}
	var communication := {}
	if _bridge_suite != null and _bridge_suite.has_method("get_full_mission_snapshot"):
		bridge = _bridge_suite.call("get_full_mission_snapshot") as Dictionary
	if _communication_suite != null and _communication_suite.has_method("get_communication_snapshot"):
		communication = _communication_suite.call("get_communication_snapshot") as Dictionary
	return {
		"schema_version": "ship_full_mission_bridge_panel_v1",
		"bridge": bridge,
		"communications": communication,
		"last_receipt": _last_receipt.duplicate(true),
		"training_performed": false,
		"base_ship_motion_model_replaced": false,
		"advanced_task_hydrodynamic_extension_enabled": true,
		"existing_policy_modified": false,
		"physical_full_mission_bridge_verified": false,
		"production_authority": false,
	}


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipFullMissionBridgeRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = start_visible
	add_child(_root)
	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.0, 0.004, 0.010, 0.84)
	_root.add_child(backdrop)
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -500.0
	panel.offset_top = -356.0
	panel.offset_right = 500.0
	panel.offset_bottom = 356.0
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
	header.add_theme_constant_override("separation", 7)
	stack.add_child(header)
	var title := _label("全任务软件船桥 / FULL-MISSION RL BRIDGE", 20, COLOR_CYAN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var check_button := _button("离港检查")
	check_button.pressed.connect(_on_predeparture)
	header.add_child(check_button)
	var export_button := _button("导出证据")
	export_button.pressed.connect(_on_export)
	header.add_child(export_button)
	var close_button := _button("关闭 F12")
	close_button.pressed.connect(hide_panel)
	header.add_child(close_button)

	var subsystem_row := HBoxContainer.new()
	subsystem_row.add_theme_constant_override("separation", 6)
	stack.add_child(subsystem_row)
	for spec in [
		["雷达/自动标绘/电子海图", "ShipIntegratedBridgePanel"],
		["自动舵/推进台", "ShipExecutionControlPanel"],
		["多学员驾驶台", "ShipBridgeTeamPanel"],
		["教员站", "ShipInstructorConsolePanel"],
		["复盘", "ShipSimulationReviewPanel"],
	]:
		var button := _button(String(spec[0]))
		button.pressed.connect(func(node_name: String = String(spec[1])) -> void: _open_panel(node_name))
		subsystem_row.add_child(button)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 10)
	stack.add_child(columns)
	var left := _section("任务链与操船 / MISSION + CONNING")
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(left)
	var mission_row := HBoxContainer.new()
	mission_row.add_theme_constant_override("separation", 6)
	left.add_child(mission_row)
	var prepare := _button("准备受限能见度任务")
	prepare.pressed.connect(_on_prepare_mission)
	mission_row.add_child(prepare)
	var autopilot := _button("模拟自动舵 090° / 3m/s")
	autopilot.pressed.connect(_on_autopilot)
	mission_row.add_child(autopilot)
	var takeover := _button("人工立即接管")
	takeover.pressed.connect(_on_manual_takeover)
	mission_row.add_child(takeover)
	left.add_child(_label("软件全向视景（八扇区，45°/扇区）", 12, COLOR_MUTED))
	var sector_grid := GridContainer.new()
	sector_grid.columns = 4
	sector_grid.add_theme_constant_override("h_separation", 5)
	sector_grid.add_theme_constant_override("v_separation", 5)
	left.add_child(sector_grid)
	for sector in [
		["正前", "FORWARD"], ["右前", "STARBOARD_BOW"], ["正右", "STARBOARD_BEAM"], ["右后", "STARBOARD_QUARTER"],
		["正后", "AFT"], ["左后", "PORT_QUARTER"], ["正左", "PORT_BEAM"], ["左前", "PORT_BOW"],
	]:
		var sector_button := _button(String(sector[0]))
		sector_button.pressed.connect(func(sector_id: String = String(sector[1])) -> void: _on_sector(sector_id))
		sector_grid.add_child(sector_button)
	var sweep := _button("执行 360° 八扇区扫描")
	sweep.pressed.connect(_on_sweep)
	left.add_child(sweep)
	_system_status = _rich("系统状态待刷新", 210.0)
	left.add_child(_system_status)

	var right := _section("通信与遇险程序 / GMDSS · VHF · DSC")
	right.custom_minimum_size.x = 420.0
	columns.add_child(right)
	var distress_row := HBoxContainer.new()
	distress_row.add_theme_constant_override("separation", 6)
	right.add_child(distress_row)
	var prepare_distress := _button("准备遇险报警")
	prepare_distress.pressed.connect(_on_prepare_distress)
	distress_row.add_child(prepare_distress)
	var transmit_distress := _button("确认按压 3 秒")
	transmit_distress.pressed.connect(_on_transmit_distress)
	distress_row.add_child(transmit_distress)
	var voice := _button("16 频道话音跟进")
	voice.pressed.connect(_on_voice_follow_up)
	distress_row.add_child(voice)
	var routine_row := HBoxContainer.new()
	routine_row.add_theme_constant_override("separation", 6)
	right.add_child(routine_row)
	for spec in [["紧急呼叫", "URGENCY"], ["安全呼叫", "SAFETY"], ["常规呼叫", "ROUTINE"]]:
		var call_button := _button(String(spec[0]))
		call_button.pressed.connect(func(priority: String = String(spec[1])) -> void: _on_dsc_call(priority))
		routine_row.add_child(call_button)
	var cancel := _button("取消当前遇险报警（训练）")
	cancel.pressed.connect(_on_cancel_distress)
	right.add_child(cancel)
	_communication_log = _rich("通信日志待刷新", 228.0)
	right.add_child(_communication_log)

	_mission_status = _rich("RECEIPT --", 52.0)
	stack.add_child(_mission_status)
	var boundary := _label("功能完整的软件训练船桥：不发射无线电、不使用官方海图、不声明物理 360° 投影/型式认可/教员资质；不改运动模型或策略。", 11, COLOR_AMBER)
	boundary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(boundary)


func _on_prepare_mission() -> void:
	_call_bridge("prepare_training_mission", ["全任务船桥功能演练", "restricted_visibility_bridge"])


func _on_predeparture() -> void:
	_call_bridge("run_predeparture_check")


func _on_autopilot() -> void:
	_call_bridge("arm_and_engage_autopilot", [90.0, 3.0, "INSTRUCTOR_SIMULATION"])


func _on_manual_takeover() -> void:
	_call_bridge("manual_immediate_takeover", ["FULL_MISSION_PANEL"])


func _on_sector(sector_id: String) -> void:
	_call_bridge("set_visual_sector", [sector_id])


func _on_sweep() -> void:
	_call_bridge("sweep_all_visual_sectors")


func _on_prepare_distress() -> void:
	var receipt := _call_communication("prepare_distress_alert", ["COLLISION", "student-oow-01"])
	if String(receipt.get("status", "")) == "PREPARED_GUARDED":
		_prepared_distress_id = String(receipt.get("subject", ""))


func _on_transmit_distress() -> void:
	if _prepared_distress_id.is_empty():
		_show_local_rejection("请先准备遇险报警")
		return
	_call_communication("transmit_prepared_distress", [_prepared_distress_id, 3.0, "student-oow-01"])


func _on_voice_follow_up() -> void:
	if _prepared_distress_id.is_empty():
		_show_local_rejection("当前无遇险报警")
		return
	_call_communication("record_voice_follow_up", [_prepared_distress_id, "16", "MAYDAY training exercise follow-up", "student-oow-01"])


func _on_cancel_distress() -> void:
	if _prepared_distress_id.is_empty():
		_show_local_rejection("当前无遇险报警")
		return
	_call_communication("cancel_distress_alert", [_prepared_distress_id, "TRAINING RESET", "student-oow-01"])


func _on_dsc_call(priority: String) -> void:
	_call_communication("send_dsc_call", [priority, "TRAINING COAST STATION", "%s PROCEDURE EXERCISE" % priority, "student-oow-01"])


func _on_export() -> void:
	var payload := get_acceptance_snapshot()
	payload["export_path"] = EXPORT_PATH
	var file := FileAccess.open(EXPORT_PATH, FileAccess.WRITE)
	if file == null:
		_show_local_rejection("导出失败")
		return
	file.store_string(JSON.stringify(payload, "\t") + "\n")
	file.close()
	_last_receipt = {"receipt_id": "FMB-EXPORT", "status": "EXECUTED", "detail": {"path": ProjectSettings.globalize_path(EXPORT_PATH)}}
	_refresh()


func _open_panel(node_name: String) -> void:
	var panel := get_node_or_null("../" + node_name)
	if panel != null and panel.has_method("show_panel"):
		hide_panel()
		panel.call("show_panel")


func _call_bridge(method: String, arguments: Array = []) -> Dictionary:
	_resolve_suites()
	if _bridge_suite == null or not _bridge_suite.has_method(method):
		_show_local_rejection("全任务船桥控制器不可用")
		return _last_receipt
	_last_receipt = _bridge_suite.callv(method, arguments) as Dictionary
	_refresh()
	return _last_receipt


func _call_communication(method: String, arguments: Array = []) -> Dictionary:
	_resolve_suites()
	if _communication_suite == null or not _communication_suite.has_method(method):
		_show_local_rejection("通信训练控制器不可用")
		return _last_receipt
	_last_receipt = _communication_suite.callv(method, arguments) as Dictionary
	_refresh()
	return _last_receipt


func _show_local_rejection(reason: String) -> void:
	_last_receipt = {"receipt_id": "FMB-LOCAL", "status": "REJECTED", "detail": {"reason": reason}}
	_refresh()


func _resolve_suites() -> void:
	_bridge_suite = get_node_or_null(bridge_suite_path)
	_communication_suite = get_node_or_null(communication_suite_path)
	if _bridge_suite == null:
		_bridge_suite = get_tree().get_first_node_in_group(&"ship_full_mission_bridge_suite")
	if _communication_suite == null:
		_communication_suite = get_tree().get_first_node_in_group(&"ship_gmdss_communications_suite")


func _refresh() -> void:
	if _system_status == null:
		return
	var snapshot := get_acceptance_snapshot()
	var bridge := snapshot.get("bridge", {}) as Dictionary
	var components := bridge.get("component_presence", {}) as Dictionary
	var visual := bridge.get("visual", {}) as Dictionary
	_system_status.text = (
		"[color=#73f5ff][b]FULL-MISSION SOFTWARE %s[/b][/color]\n"
		+ "导航设备 %s  ·  通信 %s  ·  执行控制 %s\n"
		+ "多学员 %s  ·  教员时间线 %s\n"
		+ "视景 %s / 8 扇区  ·  当前 %s\n"
		+ "物理 360°：未验证  ·  型式认可：无"
	) % [
		"PASS" if bool(bridge.get("functional_software_bridge_complete", false)) else "GAPS",
		_ok(bool(components.get("navigation_equipment", false))),
		_ok(bool(components.get("gmdss_communications", false))),
		_ok(bool(components.get("execution_control", false))),
		_ok(bool(components.get("multi_station_collaboration", false))),
		_ok(bool(components.get("instructor_exercise", false))),
		int(visual.get("visited_sector_count", 0)),
		String(visual.get("current_sector", "--")),
	]
	var communication := snapshot.get("communications", {}) as Dictionary
	var calls := communication.get("calls", []) as Array
	var lines: Array[String] = []
	lines.append("CH16 %s  ·  CH70 %s  ·  CALLS %d" % [_ok(bool(communication.get("channel_watch", {}).get("16", false))), _ok(bool(communication.get("channel_watch", {}).get("70", false))), calls.size()])
	for raw_call in calls.slice(maxi(calls.size() - 5, 0), calls.size()):
		var call := raw_call as Dictionary
		lines.append("%s  %s  %s" % [call.get("call_id", "--"), call.get("priority", "--"), call.get("status", "--")])
	lines.append("实发射：0  ·  岸台连接：0  ·  训练身份：%s" % communication.get("training_identity", "--"))
	_communication_log.text = "\n".join(lines)
	_mission_status.text = "RECEIPT %s  ·  %s  ·  %s" % [_last_receipt.get("receipt_id", "--"), _last_receipt.get("status", "--"), _last_receipt.get("detail", {}).get("reason", "")]


func _ok(value: bool) -> String:
	return "OK" if value else "GAP"


func _section(title: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	var heading := _label(title, 14, COLOR_CYAN)
	heading.add_theme_stylebox_override("normal", _style(COLOR_PANEL, COLOR_MUTED))
	box.add_child(heading)
	return box


func _rich(text: String, minimum_height: float) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.text = text
	label.fit_content = false
	label.custom_minimum_size.y = minimum_height
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("normal_font_size", 11)
	label.add_theme_color_override("default_color", COLOR_TEXT)
	return label


func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_font_size_override("font_size", 11)
	return button


func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = Color(border.r, border.g, border.b, 0.55)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 7.0
	style.content_margin_right = 7.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	return style

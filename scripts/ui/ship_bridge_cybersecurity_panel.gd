extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_F11
const EXPORT_PATH := "user://ship_bridge_cybersecurity_snapshot.json"
const COLOR_BG := Color(0.005, 0.013, 0.022, 0.98)
const COLOR_PANEL := Color(0.020, 0.046, 0.064, 0.98)
const COLOR_CYAN := Color(0.28, 0.95, 1.0, 1.0)
const COLOR_GREEN := Color(0.43, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.73, 0.25, 1.0)
const COLOR_RED := Color(1.0, 0.34, 0.29, 1.0)
const COLOR_TEXT := Color(0.84, 0.95, 1.0, 1.0)
const COLOR_MUTED := Color(0.55, 0.70, 0.78, 1.0)

@export var start_visible := false
@export var cybersecurity_suite_path: NodePath = NodePath("../ShipBridgeCybersecuritySuite")

var _root: Control
var _suite: Node
var _username: LineEdit
var _password: LineEdit
var _nonce: LineEdit
var _identity_status: RichTextLabel
var _control_status: RichTextLabel
var _alert_status: RichTextLabel
var _receipt_status: RichTextLabel
var _session_token := ""
var _last_recovery_id := ""
var _last_receipt: Dictionary = {}
var _nonce_sequence := 0


func _ready() -> void:
	layer = 74
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"ship_bridge_cybersecurity_panel")
	_resolve_suite()
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
	_resolve_suite()
	var security := {}
	if _suite != null and _suite.has_method("get_security_snapshot"):
		security = _suite.call("get_security_snapshot") as Dictionary
	return {
		"schema_version": "ship_bridge_cybersecurity_panel_v1",
		"security": security,
		"last_receipt": _redact_receipt(_last_receipt),
		"authenticated_training_session": not _session_token.is_empty(),
		"recovery_snapshot_prepared": not _last_recovery_id.is_empty(),
		"training_performed": false,
		"ship_motion_model_modified": false,
		"observation_space_modified": false,
		"action_space_modified": false,
		"reward_function_modified": false,
		"existing_policy_modified": false,
		"network_messages_mapped_to_actuation": false,
		"production_network_segmentation_verified": false,
		"hardware_secure_boot_verified": false,
		"production_ids_verified": false,
		"independent_penetration_test_completed": false,
		"class_or_flag_cyber_approval": false,
		"production_authority": false,
	}


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipBridgeCybersecurityRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = start_visible
	add_child(_root)
	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.0, 0.003, 0.009, 0.86)
	_root.add_child(backdrop)
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -510.0
	panel.offset_top = -360.0
	panel.offset_right = 510.0
	panel.offset_bottom = 360.0
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
	var title := _label("船舶网络安全靶场 / BRIDGE CYBER RANGE", 20, COLOR_CYAN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var export_button := _button("导出安全证据")
	export_button.pressed.connect(_on_export)
	header.add_child(export_button)
	var close_button := _button("关闭 F11")
	close_button.pressed.connect(hide_panel)
	header.add_child(close_button)

	var login_row := HBoxContainer.new()
	login_row.add_theme_constant_override("separation", 6)
	stack.add_child(login_row)
	_username = LineEdit.new()
	_username.name = "CyberUsername"
	_username.placeholder_text = "训练账户"
	_username.text = "security_admin"
	_username.custom_minimum_size.x = 150.0
	login_row.add_child(_username)
	_password = LineEdit.new()
	_password.name = "CyberPassword"
	_password.placeholder_text = "训练口令"
	_password.secret = true
	_password.custom_minimum_size.x = 210.0
	login_row.add_child(_password)
	_nonce = LineEdit.new()
	_nonce.name = "CyberNonce"
	_nonce.placeholder_text = "一次性随机数"
	_nonce.custom_minimum_size.x = 200.0
	login_row.add_child(_nonce)
	var login := _button("登录训练身份")
	login.pressed.connect(_on_login)
	login_row.add_child(login)
	var logout := _button("退出会话")
	logout.pressed.connect(_on_logout)
	login_row.add_child(logout)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 10)
	stack.add_child(columns)
	var left := _section("零信任访问 / 分区 · 身份 · 最小权限")
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(left)
	var flow_row := HBoxContainer.new()
	flow_row.add_theme_constant_override("separation", 6)
	left.add_child(flow_row)
	var allowed_flow := _button("允许导航遥测流")
	allowed_flow.pressed.connect(_on_allowed_flow)
	flow_row.add_child(allowed_flow)
	var blocked_flow := _button("阻断外部直控流")
	blocked_flow.pressed.connect(_on_blocked_flow)
	flow_row.add_child(blocked_flow)
	var integrity_row := HBoxContainer.new()
	integrity_row.add_theme_constant_override("separation", 6)
	left.add_child(integrity_row)
	var boot := _button("启动完整性检查")
	boot.pressed.connect(_on_boot_integrity)
	integrity_row.add_child(boot)
	var signed_update := _button("验证签名更新")
	signed_update.pressed.connect(_on_signed_update)
	integrity_row.add_child(signed_update)
	var tampered_update := _button("验证篡改更新")
	tampered_update.pressed.connect(_on_tampered_update)
	integrity_row.add_child(tampered_update)
	_identity_status = _rich("身份状态待刷新", 235.0)
	left.add_child(_identity_status)

	var right := _section("检测响应 / IDS · 审计 · 恢复 · 渗透测试")
	right.custom_minimum_size.x = 470.0
	columns.add_child(right)
	var recovery_row := HBoxContainer.new()
	recovery_row.add_theme_constant_override("separation", 6)
	right.add_child(recovery_row)
	var create_recovery := _button("创建恢复点")
	create_recovery.pressed.connect(_on_create_recovery)
	recovery_row.add_child(create_recovery)
	var restore_recovery := _button("确认恢复")
	restore_recovery.pressed.connect(_on_restore_recovery)
	recovery_row.add_child(restore_recovery)
	var penetration := _button("运行八项渗透测试")
	penetration.pressed.connect(_on_penetration_campaign)
	right.add_child(penetration)
	var acknowledge := _button("确认最新告警")
	acknowledge.pressed.connect(_on_acknowledge_latest_alert)
	right.add_child(acknowledge)
	_alert_status = _rich("告警状态待刷新", 180.0)
	right.add_child(_alert_status)
	_control_status = _rich("控制状态待刷新", 80.0)
	right.add_child(_control_status)

	_receipt_status = _rich("RECEIPT --", 52.0)
	stack.add_child(_receipt_status)
	var boundary := _label("离线强化学习航行模拟器网络安全功能层：不转发报文、不映射船舶执行器；硬件信任根、生产身份源、安全运营中心、独立渗透测试与船级认可仍为阻断项。", 11, COLOR_AMBER)
	boundary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(boundary)


func _on_login() -> void:
	_resolve_suite()
	if _suite == null:
		_reject_local("安全控制器不可用")
		return
	var nonce := _nonce.text.strip_edges()
	if nonce.is_empty():
		nonce = _next_nonce("LOGIN")
	_last_receipt = _suite.call("authenticate", _username.text, _password.text, nonce) as Dictionary
	if String(_last_receipt.get("status", "")) == "AUTHENTICATED_TRAINING_ONLY":
		_session_token = String(_last_receipt.get("subject", ""))
	_password.clear()
	_nonce.clear()
	_refresh()


func _on_logout() -> void:
	_call_suite("logout", [_session_token])
	_session_token = ""


func _on_allowed_flow() -> void:
	_call_suite("request_network_flow", [_session_token, "NAVIGATION_SENSOR", "BRIDGE_OPERATIONS", "NAV_TELEMETRY", _next_nonce("FLOW-ALLOW")])


func _on_blocked_flow() -> void:
	_call_suite("request_network_flow", [_session_token, "EXTERNAL_EXCHANGE", "SAFETY_CONTROL", "DIRECT_CONTROL", _next_nonce("FLOW-DENY")])


func _on_boot_integrity() -> void:
	_call_suite("verify_boot_integrity", [_session_token])


func _on_signed_update() -> void:
	_call_suite("verify_signed_update", [_session_token, false])


func _on_tampered_update() -> void:
	_call_suite("verify_signed_update", [_session_token, true])


func _on_create_recovery() -> void:
	var receipt := _call_suite("create_recovery_snapshot", [_session_token])
	if String(receipt.get("status", "")) == "CREATED_IN_MEMORY_TRAINING_ONLY":
		_last_recovery_id = String(receipt.get("subject", ""))


func _on_restore_recovery() -> void:
	if _last_recovery_id.is_empty():
		_reject_local("请先创建恢复点")
		return
	_call_suite("restore_recovery_snapshot", [_session_token, _last_recovery_id, true])


func _on_penetration_campaign() -> void:
	_call_suite("run_penetration_campaign", [_session_token])


func _on_acknowledge_latest_alert() -> void:
	_resolve_suite()
	if _suite == null:
		_reject_local("安全控制器不可用")
		return
	var alerts := _suite.call("get_alerts") as Array
	if alerts.is_empty():
		_reject_local("当前无告警")
		return
	_call_suite("acknowledge_alert", [_session_token, String((alerts[-1] as Dictionary).get("alert_id", ""))])


func _on_export() -> void:
	var payload := get_acceptance_snapshot()
	payload["export_path"] = EXPORT_PATH
	var file := FileAccess.open(EXPORT_PATH, FileAccess.WRITE)
	if file == null:
		_reject_local("导出失败")
		return
	file.store_string(JSON.stringify(payload, "\t") + "\n")
	file.close()
	_last_receipt = {"receipt_id": "CYBER-EXPORT", "status": "EXECUTED", "detail": {"path": ProjectSettings.globalize_path(EXPORT_PATH), "session_token_exported": false}}
	_refresh()


func _call_suite(method: String, arguments: Array = []) -> Dictionary:
	_resolve_suite()
	if _suite == null or not _suite.has_method(method):
		_reject_local("安全控制器方法不可用")
		return _last_receipt
	_last_receipt = _suite.callv(method, arguments) as Dictionary
	_refresh()
	return _last_receipt


func _reject_local(reason: String) -> void:
	_last_receipt = {"receipt_id": "CYBER-LOCAL", "status": "REJECTED", "detail": {"reason": reason}}
	_refresh()


func _resolve_suite() -> void:
	_suite = get_node_or_null(cybersecurity_suite_path)
	if _suite == null and get_tree() != null:
		_suite = get_tree().get_first_node_in_group(&"ship_bridge_cybersecurity_suite")


func _refresh() -> void:
	if _identity_status == null:
		return
	var snapshot := get_acceptance_snapshot().get("security", {}) as Dictionary
	var active := snapshot.get("active_sessions", []) as Array
	_identity_status.text = (
		"[color=#73f5ff][b]DEFAULT DENY %s[/b][/color]\n"
		+ "网络分区 %d  ·  许可流 %d  ·  训练身份 %d\n"
		+ "活动会话 %d  ·  最小权限 %s\n"
		+ "报文转执行器：否  ·  生产网分区验证：否"
	) % ["ON" if bool(snapshot.get("default_deny", false)) else "OFF", int(snapshot.get("zone_count", 0)), int(snapshot.get("allowed_flow_count", 0)), int(snapshot.get("identity_count", 0)), active.size(), _ok(bool(snapshot.get("least_privilege", false)))]
	var alerts := snapshot.get("alerts", []) as Array
	var lines: Array[String] = []
	lines.append("IDS 规则告警 %d  ·  未确认 %d" % [int(snapshot.get("alert_count", 0)), int(snapshot.get("unacknowledged_alert_count", 0))])
	for raw_alert in alerts.slice(maxi(alerts.size() - 5, 0), alerts.size()):
		var alert := raw_alert as Dictionary
		lines.append("%s  %s  %s%s" % [alert.get("alert_id", "--"), alert.get("severity", "--"), alert.get("rule_id", "--"), "  ✓" if bool(alert.get("acknowledged", false)) else ""])
	_alert_status.text = "\n".join(lines)
	var chain := snapshot.get("audit_chain", {}) as Dictionary
	_control_status.text = "审计链 %s · %d 条\n恢复点 %d · 硬件信任根/生产 IDS：未验证" % [_ok(bool(chain.get("passed", false))), int(chain.get("record_count", 0)), int(snapshot.get("recovery_snapshot_count", 0))]
	_receipt_status.text = "RECEIPT %s  ·  %s  ·  %s" % [_last_receipt.get("receipt_id", "--"), _last_receipt.get("status", "--"), (_last_receipt.get("detail", {}) as Dictionary).get("reason", "")]


func _next_nonce(prefix: String) -> String:
	_nonce_sequence += 1
	return "%s-%d-%d" % [prefix, Time.get_ticks_usec(), _nonce_sequence]


func _redact_receipt(receipt: Dictionary) -> Dictionary:
	var redacted := receipt.duplicate(true)
	if String(redacted.get("action", "")) == "authenticate" and String(redacted.get("status", "")) == "AUTHENTICATED_TRAINING_ONLY":
		redacted["subject"] = "REDACTED_SESSION_TOKEN"
	return redacted


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

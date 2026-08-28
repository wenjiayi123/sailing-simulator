extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_F10
const EXPORT_PATH := "user://ship_port_integration_snapshot.json"
const COLOR_BG := Color(0.005, 0.015, 0.025, 0.98)
const COLOR_PANEL := Color(0.020, 0.050, 0.070, 0.98)
const COLOR_CYAN := Color(0.28, 0.95, 1.0, 1.0)
const COLOR_GREEN := Color(0.43, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.73, 0.25, 1.0)
const COLOR_RED := Color(1.0, 0.34, 0.29, 1.0)
const COLOR_TEXT := Color(0.84, 0.95, 1.0, 1.0)
const COLOR_MUTED := Color(0.55, 0.70, 0.78, 1.0)

@export var start_visible := false
@export var gateway_path: NodePath = NodePath("../ShipPortProductionGateway")

var _root: Control
var _gateway: Node
var _adapter_option: OptionButton
var _source_status: RichTextLabel
var _coordination_status: RichTextLabel
var _receipt_status: RichTextLabel
var _last_receipt: Dictionary = {}
var _last_request_id := ""
var _fixture_sequence := 1000


func _ready() -> void:
	layer = 75
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"ship_port_integration_panel")
	_resolve_gateway()
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
	_resolve_gateway()
	var gateway := {}
	if _gateway != null and _gateway.has_method("get_port_link_snapshot"):
		gateway = _gateway.call("get_port_link_snapshot") as Dictionary
	return {
		"schema_version": "ship_port_integration_panel_v1",
		"gateway": gateway,
		"last_receipt": _last_receipt.duplicate(true),
		"last_request_id": _last_request_id,
		"live_data_verified": false,
		"dispatch_allowed": false,
		"production_authority": false,
		"ship_motion_model_modified": false,
		"observation_space_modified": false,
		"action_space_modified": false,
		"reward_function_modified": false,
		"existing_policy_modified": false,
		"training_performed": false,
	}


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipPortIntegrationRoot"
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
	panel.offset_top = -355.0
	panel.offset_right = 510.0
	panel.offset_bottom = 355.0
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
	var title := _label("港口生产联动网关 / PORT LINK GATEWAY", 20, COLOR_CYAN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var export_button := _button("导出联动证据")
	export_button.pressed.connect(_on_export)
	header.add_child(export_button)
	var close_button := _button("关闭 F10")
	close_button.pressed.connect(hide_panel)
	header.add_child(close_button)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 6)
	stack.add_child(toolbar)
	_adapter_option = OptionButton.new()
	_adapter_option.name = "PortAdapterOption"
	_adapter_option.custom_minimum_size.x = 230.0
	_adapter_option.item_selected.connect(_on_adapter_selected)
	toolbar.add_child(_adapter_option)
	var ingest_one := _button("接入所选签名夹具")
	ingest_one.pressed.connect(_on_ingest_one)
	toolbar.add_child(ingest_one)
	var ingest_all := _button("接入六类签名夹具")
	ingest_all.pressed.connect(_on_ingest_all)
	toolbar.add_child(ingest_all)
	var disconnect := _button("模拟断链降级")
	disconnect.pressed.connect(_on_disconnect)
	toolbar.add_child(disconnect)
	var reconnect := _button("恢复离线链路")
	reconnect.pressed.connect(_on_reconnect)
	toolbar.add_child(reconnect)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 10)
	stack.add_child(columns)
	var left := _section("数据权威链 / VTS · TOS · 引航 · 拖轮 · 泊位 · 通告")
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(left)
	var watchdog := _button("运行时效与 SLA 看门狗")
	watchdog.pressed.connect(_on_watchdog)
	left.add_child(watchdog)
	_source_status = _rich("数据源状态待刷新", 310.0)
	left.add_child(_source_status)

	var right := _section("协调回执 / 人工确认 · 降级 · 审计")
	right.custom_minimum_size.x = 450.0
	columns.add_child(right)
	var request_pilot := _button("人工确认引航 ETA 请求")
	request_pilot.pressed.connect(_on_pilot_request)
	right.add_child(request_pilot)
	var request_tug := _button("人工确认拖轮就绪请求")
	request_tug.pressed.connect(_on_tug_request)
	right.add_child(request_tug)
	var ack := _button("接收夹具调度回执")
	ack.pressed.connect(_on_ack)
	right.add_child(ack)
	_coordination_status = _rich("协调状态待刷新", 260.0)
	right.add_child(_coordination_status)

	_receipt_status = _rich("RECEIPT --", 52.0)
	stack.add_child(_receipt_status)
	var boundary := _label("六类接口均为签名离线夹具；无真实 VTS/TOS/引航/拖轮/泊位/通告凭证，不外发调度、不映射执行器，现场 SLA、影子运行和授权仍需外部验收。", 11, COLOR_AMBER)
	boundary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(boundary)


func _resolve_gateway() -> void:
	_gateway = get_node_or_null(gateway_path)
	if _gateway == null and get_tree() != null:
		_gateway = get_tree().get_first_node_in_group(&"ship_port_production_gateway")
	if _gateway != null and _adapter_option != null and _adapter_option.item_count == 0:
		for raw_adapter in _gateway.call("list_adapters") as Array:
			var adapter := raw_adapter as Dictionary
			_adapter_option.add_item("%s / %s" % [adapter.get("adapter_id", "--"), adapter.get("system_type", "--")])
			_adapter_option.set_item_metadata(_adapter_option.item_count - 1, adapter.get("adapter_id", ""))


func _selected_adapter() -> String:
	if _adapter_option == null or _adapter_option.item_count == 0:
		return ""
	return String(_adapter_option.get_item_metadata(_adapter_option.selected))


func _on_adapter_selected(_index: int) -> void:
	_refresh()


func _on_ingest_one() -> void:
	_fixture_sequence += 10
	_call_gateway("ingest_training_fixture", [_selected_adapter(), _fixture_sequence])


func _on_ingest_all() -> void:
	_fixture_sequence += 100
	_call_gateway("ingest_all_training_fixtures", [_fixture_sequence])


func _on_disconnect() -> void:
	_call_gateway("set_adapter_link", [_selected_adapter(), false, "port-link-panel-operator"])


func _on_reconnect() -> void:
	_call_gateway("set_adapter_link", [_selected_adapter(), true, "port-link-panel-operator"])


func _on_watchdog() -> void:
	_call_gateway("run_freshness_watchdog")


func _on_pilot_request() -> void:
	var receipt := _call_gateway("create_coordination_request", ["PILOTAGE_ORDER", "PILOT_ETA_UPDATE", {"eta_delta_minutes": 5}, "port-link-panel-operator", true])
	if String(receipt.get("status", "")) == "QUEUED_REHEARSAL_ONLY":
		_last_request_id = String(receipt.get("subject", ""))


func _on_tug_request() -> void:
	var receipt := _call_gateway("create_coordination_request", ["TUG_ORDER", "TUG_READINESS_CONFIRMATION", {"readiness": "READY_FIXTURE"}, "port-link-panel-operator", true])
	if String(receipt.get("status", "")) == "QUEUED_REHEARSAL_ONLY":
		_last_request_id = String(receipt.get("subject", ""))


func _on_ack() -> void:
	if _last_request_id.is_empty():
		_reject_local("请先创建协调请求")
		return
	var snapshot := _gateway.call("get_port_link_snapshot") as Dictionary
	var adapter_id := ""
	for raw_request in (snapshot.get("coordination_requests", []) as Array):
		var request := raw_request as Dictionary
		if String(request.get("request_id", "")) == _last_request_id:
			adapter_id = String(request.get("adapter_id", ""))
	_call_gateway("receive_coordination_ack", [adapter_id, _last_request_id, "ACKNOWLEDGED", "fixture-service-operator"])


func _on_export() -> void:
	var payload := get_acceptance_snapshot()
	payload["export_path"] = EXPORT_PATH
	var file := FileAccess.open(EXPORT_PATH, FileAccess.WRITE)
	if file == null:
		_reject_local("导出失败")
		return
	file.store_string(JSON.stringify(payload, "\t") + "\n")
	file.close()
	_last_receipt = {"receipt_id": "PORTLINK-EXPORT", "status": "EXECUTED", "detail": {"path": ProjectSettings.globalize_path(EXPORT_PATH)}}
	_refresh()


func _call_gateway(method: String, arguments: Array = []) -> Dictionary:
	_resolve_gateway()
	if _gateway == null or not _gateway.has_method(method):
		_reject_local("港口联动网关不可用")
		return _last_receipt
	_last_receipt = _gateway.callv(method, arguments) as Dictionary
	_refresh()
	return _last_receipt


func _reject_local(reason: String) -> void:
	_last_receipt = {"receipt_id": "PORTLINK-LOCAL", "status": "REJECTED", "detail": {"reason": reason}}
	_refresh()


func _refresh() -> void:
	_resolve_gateway()
	if _source_status == null or _gateway == null:
		return
	var snapshot := _gateway.call("get_port_link_snapshot") as Dictionary
	var states := snapshot.get("adapter_states", {}) as Dictionary
	var lines: Array[String] = []
	for adapter_id in states:
		var state := states[adapter_id] as Dictionary
		lines.append("%s  %s  seq=%d  %s" % [adapter_id, state.get("link_state", "--"), int(state.get("last_sequence", -1)), "DEGRADED:%s" % state.get("degraded_reason", "") if bool(state.get("degraded", true)) else "FRESH FIXTURE"])
	_source_status.text = "\n".join(lines)
	var requests := snapshot.get("coordination_requests", []) as Array
	var request_lines: Array[String] = []
	request_lines.append("请求 %d  ·  审计链 %s / %d 条" % [requests.size(), "PASS" if bool(snapshot.get("audit_chain", {}).get("passed", false)) else "FAIL", int(snapshot.get("audit_chain", {}).get("record_count", 0))])
	for raw_request in requests.slice(maxi(requests.size() - 5, 0), requests.size()):
		var request := raw_request as Dictionary
		request_lines.append("%s  %s  %s" % [request.get("request_id", "--"), request.get("adapter_id", "--"), request.get("status", "--")])
	request_lines.append("实时数据：未验证  ·  外发调度：0  ·  执行器映射：0")
	_coordination_status.text = "\n".join(request_lines)
	_receipt_status.text = "RECEIPT %s  ·  %s  ·  %s" % [_last_receipt.get("receipt_id", "--"), _last_receipt.get("status", "--"), (_last_receipt.get("detail", {}) as Dictionary).get("reason", "")]


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

extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_Y
const EXPORT_PATH := "user://ship_port_operations_training.json"
const COLOR_BG := Color(0.008, 0.019, 0.030, 0.97)
const COLOR_PANEL := Color(0.025, 0.052, 0.068, 0.96)
const COLOR_CYAN := Color(0.27, 0.94, 1.0, 1.0)
const COLOR_GREEN := Color(0.42, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.73, 0.25, 1.0)
const COLOR_RED := Color(1.0, 0.36, 0.31, 1.0)
const COLOR_TEXT := Color(0.84, 0.95, 1.0, 1.0)
const COLOR_MUTED := Color(0.55, 0.70, 0.77, 1.0)

@export var start_visible: bool = false
@export var controller_path: NodePath = NodePath("../ShipPortOperationsTrainingController")

var _root: Control
var _controller: Node
var _procedure_option: OptionButton
var _confirmed_check: CheckBox
var _readback_check: CheckBox
var _geometry_check: CheckBox
var _dry_run_check: CheckBox
var _title_label: Label
var _step_label: RichTextLabel
var _gate_label: RichTextLabel
var _receipt_label: RichTextLabel
var _boundary_label: Label
var _last_receipt: Dictionary = {}


func _ready() -> void:
	layer = 62
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
	var operation := {}
	if _controller != null and _controller.has_method("get_operation_snapshot"):
		operation = _controller.call("get_operation_snapshot") as Dictionary
	return {
		"format": "ship_port_operations_panel_v1",
		"operation": operation,
		"last_receipt": _last_receipt.duplicate(true),
		"production_authority": false,
		"changes_motion_model": false,
		"changes_policy": false,
		"applies_physical_forces": false,
	}


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipPortOperationsRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = start_visible
	add_child(_root)

	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.0, 0.006, 0.012, 0.78)
	_root.add_child(backdrop)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -440.0
	panel.offset_top = -330.0
	panel.offset_right = 440.0
	panel.offset_bottom = 330.0
	panel.add_theme_stylebox_override("panel", _style(COLOR_BG, COLOR_CYAN))
	_root.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 10)
	margin.add_child(stack)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	stack.add_child(header)
	_title_label = _label("港内作业训练 / PORT OPERATIONS", 20, COLOR_CYAN)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title_label)
	var close_button := _button("关闭 Y")
	close_button.pressed.connect(func() -> void: _root.visible = false)
	header.add_child(close_button)

	var selector_row := HBoxContainer.new()
	selector_row.add_theme_constant_override("separation", 8)
	stack.add_child(selector_row)
	selector_row.add_child(_label("训练程序", 12, COLOR_MUTED))
	_procedure_option = OptionButton.new()
	_procedure_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_procedure_option.item_selected.connect(_on_procedure_selected)
	selector_row.add_child(_procedure_option)
	var start_button := _button("开始程序")
	start_button.pressed.connect(_on_start_pressed)
	selector_row.add_child(start_button)
	var reset_button := _button("复位程序")
	reset_button.pressed.connect(_on_reset_pressed)
	selector_row.add_child(reset_button)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 10)
	stack.add_child(columns)
	var procedure_box := _section("当前步骤 / CURRENT STEP")
	procedure_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(procedure_box)
	_step_label = _rich("未选择程序", 155.0)
	procedure_box.add_child(_step_label)
	_gate_label = _rich("等待程序启动", 105.0)
	procedure_box.add_child(_gate_label)

	var evidence_box := _section("显式证据 / EXPLICIT EVIDENCE")
	evidence_box.custom_minimum_size.x = 310.0
	columns.add_child(evidence_box)
	_confirmed_check = _check("我已完成并确认当前操作")
	evidence_box.add_child(_confirmed_check)
	_readback_check = _check("闭环通信与复诵已确认")
	evidence_box.add_child(_readback_check)
	_geometry_check = _check("已确认仅使用训练几何/水深")
	evidence_box.add_child(_geometry_check)
	_dry_run_check = _check("侧推器仅程序干运行")
	evidence_box.add_child(_dry_run_check)
	var submit_button := _button("提交当前步骤")
	submit_button.pressed.connect(_on_submit_pressed)
	evidence_box.add_child(submit_button)
	var runtime_button := _button("刷新运行时门槛")
	runtime_button.pressed.connect(_on_refresh_pressed)
	evidence_box.add_child(runtime_button)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	stack.add_child(footer)
	_receipt_label = _rich("RECEIPT --", 70.0)
	_receipt_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_receipt_label)
	var export_button := _button("导出训练记录")
	export_button.pressed.connect(_on_export_pressed)
	footer.add_child(export_button)

	_boundary_label = _label("程序训练：不施加拖轮/锚链/缆绳/侧推力；非真实泊位、非生产授权。", 11, COLOR_AMBER)
	_boundary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_boundary_label)


func _resolve_controller() -> void:
	_controller = get_node_or_null(controller_path)
	if _controller == null:
		_controller = get_tree().get_first_node_in_group(&"ship_port_operations_training_controller")
	if _controller != null and _procedure_option != null and _procedure_option.item_count == 0:
		for raw in _controller.call("list_procedures") as Array:
			var item := raw as Dictionary
			_procedure_option.add_item(String(item.get("name", item.get("key", "--"))))
			_procedure_option.set_item_metadata(_procedure_option.item_count - 1, item.get("key", ""))


func _on_procedure_selected(_index: int) -> void:
	_refresh()


func _on_start_pressed() -> void:
	_resolve_controller()
	if _controller == null or _procedure_option.item_count == 0:
		_show_rejected("训练控制器未就绪")
		return
	var key := String(_procedure_option.get_item_metadata(_procedure_option.selected))
	_last_receipt = _controller.call("start_procedure", key) as Dictionary
	_reset_evidence()
	_refresh()


func _on_submit_pressed() -> void:
	_resolve_controller()
	if _controller == null:
		_show_rejected("训练控制器未就绪")
		return
	var evidence := {
		"confirmed": _confirmed_check.button_pressed,
		"readback_confirmed": _readback_check.button_pressed,
		"training_geometry_acknowledged": _geometry_check.button_pressed,
		"dry_run_confirmed": _dry_run_check.button_pressed,
		"submitted_from": "port_operations_panel",
	}
	_last_receipt = _controller.call("submit_current_step", evidence) as Dictionary
	if String(_last_receipt.get("status", "")) != "REJECTED":
		_reset_evidence()
	_refresh()


func _on_reset_pressed() -> void:
	_resolve_controller()
	if _controller != null:
		_last_receipt = _controller.call("reset_procedure") as Dictionary
	_reset_evidence()
	_refresh()


func _on_refresh_pressed() -> void:
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
	_last_receipt = {
		"receipt_id": "PORTOPS-EXPORT",
		"status": "EXECUTED",
		"detail": {"path": ProjectSettings.globalize_path(EXPORT_PATH)},
	}
	_refresh()


func _refresh() -> void:
	_resolve_controller()
	if _controller == null:
		_show_rejected("训练控制器未就绪")
		return
	var snapshot := _controller.call("get_operation_snapshot") as Dictionary
	var current := snapshot.get("current_step", {}) as Dictionary
	var complete := bool(snapshot.get("complete", false))
	_title_label.text = "港内作业训练 / %s" % snapshot.get("procedure_name", "PORT OPERATIONS")
	if current.is_empty():
		_step_label.text = "[color=#86ff9b][b]程序完成[/b][/color]" if complete else "[color=#ffbd40]请选择并开始训练程序[/color]"
	else:
		_step_label.text = (
			"[color=#73f5ff][b]%s[/b][/color]  STEP %d/%d\n\n%s\n\n[color=#8baebd]%s[/color]"
			% [
				current.get("id", "--"),
				int(snapshot.get("step_index", 0)) + 1,
				int(snapshot.get("step_count", 0)),
				current.get("label", "--"),
				snapshot.get("objective", ""),
			]
		)
	var runtime := _controller.call("get_runtime_gate_snapshot") as Dictionary
	_gate_label.text = _gate_text(current, runtime, snapshot)
	if not _last_receipt.is_empty():
		var rejected := String(_last_receipt.get("status", "")) == "REJECTED"
		_receipt_label.text = (
			"[color=%s][b]%s[/b][/color]  %s\n%s"
			% [
				"#ff5c4f" if rejected else "#86ff9b",
				_last_receipt.get("status", "--"),
				_last_receipt.get("receipt_id", "--"),
				str((_last_receipt.get("detail", {}) as Dictionary).get("reason", (_last_receipt.get("detail", {}) as Dictionary).get("path", "步骤状态已记录"))),
			]
		)


func _gate_text(step: Dictionary, runtime: Dictionary, snapshot: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("[b]运行时门槛[/b]  航速 %.2f kn" % float(runtime.get("speed_knots", 0.0)))
	if step.has("max_speed_knots"):
		lines.append("航速上限 %.1f kn" % float(step.get("max_speed_knots", 0.0)))
	if bool(step.get("requires_readback", false)):
		lines.append("需要闭环复诵")
	if bool(step.get("requires_training_geometry_ack", false)):
		lines.append("需要确认训练几何/水深非官方")
	if bool(step.get("requires_thruster_dry_run", false)):
		lines.append("需要确认侧推器干运行")
	lines.append("已完成 %d/%d；物理力施加：否" % [(snapshot.get("completed_steps", []) as Array).size(), int(snapshot.get("step_count", 0))])
	return "\n".join(lines)


func _show_rejected(reason: String) -> void:
	_last_receipt = {"receipt_id": "NO-RECEIPT", "status": "REJECTED", "detail": {"reason": reason}}
	if _receipt_label != null:
		_receipt_label.text = "[color=#ff5c4f][b]REJECTED[/b][/color]  " + reason


func _reset_evidence() -> void:
	for check in [_confirmed_check, _readback_check, _geometry_check, _dry_run_check]:
		if check != null:
			check.button_pressed = false


func _section(title: String) -> VBoxContainer:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	var title_label := _label(title, 13, COLOR_CYAN)
	title_label.add_theme_stylebox_override("normal", _style(COLOR_PANEL, Color(COLOR_CYAN.r, COLOR_CYAN.g, COLOR_CYAN.b, 0.35), 6))
	root.add_child(title_label)
	return root


func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 32.0
	button.add_theme_font_size_override("font_size", 12)
	return button


func _check(text: String) -> CheckBox:
	var check := CheckBox.new()
	check.text = text
	check.toggled.connect(func(_pressed: bool) -> void: _refresh())
	return check


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
	label.add_theme_font_size_override("normal_font_size", 13)
	return label


func _style(fill: Color, border: Color, radius: int = 8) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	return style

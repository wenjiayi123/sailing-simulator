extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_R
const CATALOG_PATH := "res://data/verification/colreg_complex_scenario_catalog_v2.json"
const LOCAL_RULES_PATH := "res://data/verification/local_navigation_rules_template_v1.json"
const REPORT_PATH := "res://reports/colreg_complex_assurance_v2.json"
const EXPORT_DIRECTORY := "user://colreg_complex_evidence"
const COLOR_BG := Color(0.008, 0.019, 0.030, 0.98)
const COLOR_PANEL := Color(0.025, 0.052, 0.068, 0.97)
const COLOR_CYAN := Color(0.27, 0.94, 1.0, 1.0)
const COLOR_GREEN := Color(0.42, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.73, 0.25, 1.0)
const COLOR_RED := Color(1.0, 0.36, 0.31, 1.0)
const COLOR_TEXT := Color(0.84, 0.95, 1.0, 1.0)

@export var start_visible: bool = false

var _root: Control
var _status_label: RichTextLabel
var _scenario_option: OptionButton
var _duty_label: RichTextLabel
var _signal_label: RichTextLabel
var _case_label: RichTextLabel
var _report: Dictionary = {}
var _catalog: Dictionary = {}
var _local_rules: Dictionary = {}
var _case_index := 0
var _last_exit_code := -1
var _last_command_output := ""
var _last_export: Dictionary = {}


func _ready() -> void:
	layer = 63
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_interface()
	_reload()
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.physical_keycode == TOGGLE_PANEL_KEY:
			_root.visible = not _root.visible
			if _root.visible:
				_reload()
			get_viewport().set_input_as_handled()


func show_panel() -> void:
	_root.visible = true
	_reload()


func get_acceptance_snapshot() -> Dictionary:
	var selected := _selected_result()
	return {
		"schema_version": "ship_colreg_complex_panel_snapshot_v1",
		"report": _report.duplicate(true),
		"selected_scenario": selected.duplicate(true),
		"selected_case_index": _case_index,
		"last_exit_code": _last_exit_code,
		"last_command_output": _last_command_output,
		"last_export": _last_export.duplicate(true),
		"legacy_v1_replaced": false,
		"training_performed": false,
		"existing_policy_modified": false,
		"ship_motion_model_modified": false,
		"official_local_rules_connected": false,
		"colreg_certified": false,
		"production_authority": false,
	}


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipColregComplexRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = start_visible
	add_child(_root)
	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.0, 0.006, 0.012, 0.84)
	_root.add_child(backdrop)
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -600.0
	panel.offset_top = -350.0
	panel.offset_right = 600.0
	panel.offset_bottom = 350.0
	panel.add_theme_stylebox_override("panel", _style(COLOR_BG, COLOR_CYAN))
	_root.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 9)
	margin.add_child(stack)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	stack.add_child(header)
	var title := _label("复杂避碰规则 / MULTI-SHIP · RULE 9/10/18/19 · SIGNALS", 19, COLOR_CYAN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	header.add_child(_button("重新运行规则验收", _run_assessment))
	header.add_child(_button("导出场景证据包", _export_evidence))
	header.add_child(_button("重新载入", _reload))
	header.add_child(_button("关闭 R", func() -> void: _root.visible = false))
	_status_label = _rich("等待复杂规则报告", 88.0)
	stack.add_child(_status_label)
	var chooser := HBoxContainer.new()
	chooser.add_theme_constant_override("separation", 8)
	stack.add_child(chooser)
	chooser.add_child(_label("训练/验收场景", 13, COLOR_TEXT))
	_scenario_option = OptionButton.new()
	_scenario_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scenario_option.item_selected.connect(_on_scenario_selected)
	chooser.add_child(_scenario_option)
	chooser.add_child(_button("上一个", _previous_scenario))
	chooser.add_child(_button("下一个", _next_scenario))
	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 10)
	stack.add_child(columns)
	var duty_box := _section("逐目标责任图与水域约束", 430.0)
	columns.add_child(duty_box)
	_duty_label = _rich("--", 390.0)
	duty_box.add_child(_duty_label)
	var signal_box := _section("船舶身份、灯号号型与声号", 330.0)
	columns.add_child(signal_box)
	_signal_label = _rich("--", 390.0)
	signal_box.add_child(_signal_label)
	var case_box := _section("正反动作案例", 360.0)
	case_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(case_box)
	_case_label = _rich("--", 340.0)
	case_box.add_child(_case_label)
	case_box.add_child(_button("检查下一个案例", _next_case))
	var boundary := _label("功能验收已覆盖复杂场景；地方规则仍是仿真模板，规则适用性和法律解释必须由主管机关/有权专家决定，系统不授予实船控制权限。", 11, COLOR_AMBER)
	boundary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(boundary)


func _run_assessment() -> void:
	var python_path := ProjectSettings.globalize_path("res://.venv/bin/python")
	var script_path := ProjectSettings.globalize_path("res://tools/run_colreg_complex_assurance.py")
	if not FileAccess.file_exists(python_path) or not FileAccess.file_exists(script_path):
		_last_exit_code = -1
		_last_command_output = "Python 环境或复杂规则检查器缺失"
		_refresh()
		return
	var output: Array = []
	_last_exit_code = OS.execute(python_path, PackedStringArray([script_path, "generate"]), output, true, false)
	_last_command_output = "\n".join(output)
	_reload()


func _export_evidence() -> void:
	var absolute_directory := ProjectSettings.globalize_path(EXPORT_DIRECTORY)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK:
		_last_export = {"passed": false, "error": error_string(directory_error)}
		_refresh()
		return
	var mappings := {
		CATALOG_PATH: EXPORT_DIRECTORY + "/colreg_complex_scenario_catalog_v2.json",
		LOCAL_RULES_PATH: EXPORT_DIRECTORY + "/local_navigation_rules_template_v1.json",
		REPORT_PATH: EXPORT_DIRECTORY + "/colreg_complex_assurance_v2.json",
	}
	var hashes := {}
	var passed := true
	for source_path in mappings:
		var target_path := String(mappings[source_path])
		var source := FileAccess.open(String(source_path), FileAccess.READ)
		var target := FileAccess.open(target_path, FileAccess.WRITE)
		if source == null or target == null:
			passed = false
			continue
		var bytes := source.get_buffer(source.get_length())
		target.store_buffer(bytes)
		source.close()
		target.close()
		hashes[target_path] = FileAccess.get_sha256(target_path)
	_last_export = {"passed": passed, "directory": EXPORT_DIRECTORY, "files_sha256": hashes}
	_refresh()


func _reload() -> void:
	_report = _read_json(REPORT_PATH)
	_catalog = _read_json(CATALOG_PATH)
	_local_rules = _read_json(LOCAL_RULES_PATH)
	_sync_scenarios()
	_refresh()


func _sync_scenarios() -> void:
	var selected_id := ""
	if _scenario_option.item_count > 0 and _scenario_option.selected >= 0:
		selected_id = String(_scenario_option.get_item_metadata(_scenario_option.selected))
	_scenario_option.clear()
	var result := _report.get("complex_assurance", {}) as Dictionary
	for raw in result.get("results", []) as Array:
		var item := raw as Dictionary
		var assessment := item.get("assessment", {}) as Dictionary
		_scenario_option.add_item("%s · %s" % [item.get("scenario_id", "--"), assessment.get("primary_duty", "--")])
		_scenario_option.set_item_metadata(_scenario_option.item_count - 1, item.get("scenario_id", ""))
		if String(item.get("scenario_id", "")) == selected_id:
			_scenario_option.select(_scenario_option.item_count - 1)
	if _scenario_option.item_count > 0 and _scenario_option.selected < 0:
		_scenario_option.select(0)


func _selected_result() -> Dictionary:
	if _scenario_option.item_count == 0 or _scenario_option.selected < 0:
		return {}
	var selected_id := String(_scenario_option.get_item_metadata(_scenario_option.selected))
	var complex_result := _report.get("complex_assurance", {}) as Dictionary
	for raw in complex_result.get("results", []) as Array:
		var item := raw as Dictionary
		if String(item.get("scenario_id", "")) == selected_id:
			return item
	return {}


func _refresh() -> void:
	if _report.is_empty() or _catalog.is_empty() or _local_rules.is_empty():
		_status_label.text = "[color=#ff5c4f][b]BLOCKED[/b][/color] 场景、地方规则模板或验收报告缺失。"
		return
	var result := _report.get("complex_assurance", {}) as Dictionary
	var legacy := _report.get("legacy_v1_regression", {}) as Dictionary
	_status_label.text = (
		"[color=#86ff9b][b]COMPLEX COLREG %s · %d/%d 场景 · %d/%d 案例[/b][/color]\n"
		+ "V1基线 %d场景/%d案例 · V1替换=false · 地方规则官方授权=false · 训练=false · 策略/运动模型未改 · 最近退出码=%d %s"
	) % [
		"PASS" if bool(_report.get("functional_assurance_passed", false)) else "FAIL",
		int(result.get("scenario_passed_count", 0)),
		int(result.get("scenario_count", 0)),
		int(result.get("case_matched_count", 0)),
		int(result.get("case_count", 0)),
		int(legacy.get("scenario_count", 0)),
		int(legacy.get("action_case_count", 0)),
		_last_exit_code,
		_last_command_output.strip_edges(),
	]
	var selected := _selected_result()
	if selected.is_empty():
		_duty_label.text = "--"
		_signal_label.text = "--"
		_case_label.text = "--"
		return
	var assessment := selected.get("assessment", {}) as Dictionary
	var graph_lines: Array[String] = []
	for raw in assessment.get("multi_ship_duty_graph", []) as Array:
		var edge := raw as Dictionary
		graph_lines.append(
			"• %s → %s / %s · TCPA=%s · DCPA=%sm"
			% [edge.get("target_id", "--"), edge.get("role", "--"), edge.get("encounter", "--"), str(edge.get("tcpa_s", "--")), str(edge.get("dcpa_m", "--"))]
		)
	if graph_lines.is_empty():
		graph_lines.append("• 无碰撞危险目标，继续监视水域约束")
	_duty_label.text = (
		"[color=#73f5ff][b]%s[/b][/color]\n主要责任：[color=#ffbd40]%s[/color]\n优先目标：%s · 风险目标：%d/%d\n水域：%s · 当前约束：%s\n规则：%s\n\n%s"
	) % [selected.get("scenario_id", "--"), assessment.get("primary_duty", "--"), str(assessment.get("priority_target_id", "--")), int(assessment.get("risk_target_count", 0)), int(assessment.get("target_count", 0)), assessment.get("waterway", "--"), "PASS" if bool(assessment.get("context_compliant", false)) else "VIOLATION: " + ", ".join(assessment.get("context_violations", []) as Array), ", ".join(assessment.get("rules", []) as Array), "\n".join(graph_lines)]
	var visual := assessment.get("expected_visual_signal", {}) as Dictionary
	_signal_label.text = (
		"[color=#73f5ff][b]身份：%s[/b][/color]\n灯号：\n• %s\n号型：\n• %s\n能见度不良声号：%s\n\n地方规则来源：%s\nofficial_authorization_verified=%s"
	) % [assessment.get("signal_subject_status", "--"), "\n• ".join(visual.get("lights", []) as Array), "\n• ".join(visual.get("shapes", []) as Array), str(assessment.get("expected_sound_signal", "不适用")), _local_rules.get("source_class", "--"), str(_local_rules.get("official_authorization_verified", false))]
	_refresh_case(selected)


func _refresh_case(selected: Dictionary) -> void:
	var cases := selected.get("cases", []) as Array
	if cases.is_empty():
		_case_label.text = "没有可验收案例。"
		return
	_case_index %= cases.size()
	var item := cases[_case_index] as Dictionary
	_case_label.text = (
		"[color=#73f5ff][b]%d/%d · %s[/b][/color]\n类型：%s\n实际判定：%s\n预期判定：%s\n结果匹配：[color=%s]%s[/color]\n\n理由：\n• %s"
	) % [_case_index + 1, cases.size(), item.get("case_id", "--"), item.get("kind", "--"), str(item.get("passed", false)), str(item.get("expected_passed", false)), "#86ff9b" if bool(item.get("matched", false)) else "#ff5c4f", "PASS" if bool(item.get("matched", false)) else "FAIL", "\n• ".join(item.get("reasons", []) as Array)]


func _on_scenario_selected(_index: int) -> void:
	_case_index = 0
	_refresh()


func _previous_scenario() -> void:
	if _scenario_option.item_count == 0:
		return
	_scenario_option.select((_scenario_option.selected - 1 + _scenario_option.item_count) % _scenario_option.item_count)
	_case_index = 0
	_refresh()


func _next_scenario() -> void:
	if _scenario_option.item_count == 0:
		return
	_scenario_option.select((_scenario_option.selected + 1) % _scenario_option.item_count)
	_case_index = 0
	_refresh()


func _next_case() -> void:
	var selected := _selected_result()
	var cases := selected.get("cases", []) as Array
	if cases.is_empty():
		return
	_case_index = (_case_index + 1) % cases.size()
	_refresh_case(selected)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var value: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return value if value is Dictionary else {}


func _section(title: String, width: float) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = width
	box.add_theme_constant_override("separation", 7)
	var heading := _label(title, 13, COLOR_CYAN)
	heading.add_theme_stylebox_override("normal", _style(COLOR_PANEL, Color(COLOR_CYAN.r, COLOR_CYAN.g, COLOR_CYAN.b, 0.35), 6))
	box.add_child(heading)
	return box


func _button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 30.0
	button.add_theme_font_size_override("font_size", 12)
	button.pressed.connect(callback)
	return button


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

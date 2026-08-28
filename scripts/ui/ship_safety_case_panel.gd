extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_Q
const CASE_PATH := "res://data/verification/mass_safety_case_v1.json"
const ACCEPTANCE_TEMPLATE_PATH := "res://data/verification/mass_safety_case_acceptance_manifest.template.json"
const REPORT_PATH := "res://reports/mass_safety_case_assessment_v1.json"
const EXPORT_DIRECTORY := "user://mass_safety_case_evidence"
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
var _hazard_label: RichTextLabel
var _mrc_label: RichTextLabel
var _claim_label: RichTextLabel
var _odd_demo_label: RichTextLabel
var _hazard_option: OptionButton
var _mrc_option: OptionButton
var _claim_option: OptionButton
var _case: Dictionary = {}
var _report: Dictionary = {}
var _last_exit_code := -1
var _last_command_output := ""
var _last_export: Dictionary = {}
var _acceptance_gap_index := 0
var _odd_case_index := 0
var _selected_acceptance_gap := ""
var _selected_odd_case: Dictionary = {}


func _ready() -> void:
	layer = 62
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
	return {
		"schema_version": "ship_safety_case_panel_snapshot_v1",
		"report": _report.duplicate(true),
		"case": _case.duplicate(true),
		"last_exit_code": _last_exit_code,
		"last_command_output": _last_command_output,
		"last_export": _last_export.duplicate(true),
		"selected_acceptance_gap": _selected_acceptance_gap,
		"selected_odd_case": _selected_odd_case.duplicate(true),
		"training_performed": false,
		"existing_model_modified": false,
		"independent_review_complete": false,
		"mass_safety_certificate": false,
		"production_authority": false,
	}


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipSafetyCaseRoot"
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
	panel.offset_left = -575.0
	panel.offset_top = -345.0
	panel.offset_right = 575.0
	panel.offset_bottom = 345.0
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
	var title := _label("法规与安全论证 / ODD · HAZARD · MRC · FTA · RCC", 19, COLOR_CYAN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	header.add_child(_button("重新运行安全案例", _run_assessment))
	header.add_child(_button("导出外部审查包", _export_review_package))
	header.add_child(_button("重新载入", _reload))
	header.add_child(_button("关闭 Q", func() -> void: _root.visible = false))
	_status_label = _rich("等待安全案例报告", 100.0)
	stack.add_child(_status_label)
	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 10)
	stack.add_child(columns)
	var hazard_box := _section("运行设计域与危险日志", 345.0)
	columns.add_child(hazard_box)
	_hazard_option = OptionButton.new()
	_hazard_option.item_selected.connect(_on_hazard_selected)
	hazard_box.add_child(_hazard_option)
	_hazard_label = _rich("--", 260.0)
	hazard_box.add_child(_hazard_label)
	_odd_demo_label = _rich("ODD 越界演练尚未执行", 72.0)
	hazard_box.add_child(_odd_demo_label)
	hazard_box.add_child(_button("演示 ODD 越界→MRC", _cycle_odd_breach))
	var mrc_box := _section("最小风险状态与故障树", 345.0)
	columns.add_child(mrc_box)
	_mrc_option = OptionButton.new()
	_mrc_option.item_selected.connect(_on_mrc_selected)
	mrc_box.add_child(_mrc_option)
	_mrc_label = _rich("--", 345.0)
	mrc_box.add_child(_mrc_label)
	var claim_box := _section("主张、责任与外部审查", 390.0)
	claim_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(claim_box)
	_claim_option = OptionButton.new()
	_claim_option.item_selected.connect(_on_claim_selected)
	claim_box.add_child(_claim_option)
	_claim_label = _rich("--", 330.0)
	claim_box.add_child(_claim_label)
	claim_box.add_child(_button("下一个外部证据缺口", _next_acceptance_gap))
	var boundary := _label("安全案例功能闭环已实现；法规适用性、剩余风险接受、独立审查、主管机关/船级批准和生产权限必须由外部有权方决定。", 11, COLOR_AMBER)
	boundary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(boundary)


func _run_assessment() -> void:
	var python_path := ProjectSettings.globalize_path("res://.venv/bin/python")
	var script_path := ProjectSettings.globalize_path("res://tools/run_mass_safety_case.py")
	if not FileAccess.file_exists(python_path) or not FileAccess.file_exists(script_path):
		_last_exit_code = -1
		_last_command_output = "Python 环境或安全案例检查器缺失"
		_refresh()
		return
	var output: Array = []
	_last_exit_code = OS.execute(python_path, PackedStringArray([script_path, "generate"]), output, true, false)
	_last_command_output = "\n".join(output)
	_reload()


func _export_review_package() -> void:
	var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EXPORT_DIRECTORY))
	if directory_error != OK:
		_last_export = {"passed": false, "error": error_string(directory_error)}
		_refresh()
		return
	var mappings := {
		CASE_PATH: EXPORT_DIRECTORY + "/mass_safety_case_v1.json",
		ACCEPTANCE_TEMPLATE_PATH: EXPORT_DIRECTORY + "/mass_safety_case_acceptance_manifest.json",
		REPORT_PATH: EXPORT_DIRECTORY + "/mass_safety_case_assessment_v1.json",
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
	_case = _read_json(CASE_PATH)
	_report = _read_json(REPORT_PATH)
	_sync_options()
	_refresh()


func _sync_options() -> void:
	_sync_option(_hazard_option, _case.get("hazard_log", []) as Array, "hazard_id", "category")
	_sync_option(_mrc_option, _case.get("minimum_risk_conditions", []) as Array, "mrc_id", "name")
	_sync_option(_claim_option, _case.get("claim_graph", []) as Array, "claim_id", "status")


func _sync_option(option: OptionButton, records: Array, id_key: String, label_key: String) -> void:
	var selected_id := ""
	if option.item_count > 0 and option.selected >= 0:
		selected_id = String(option.get_item_metadata(option.selected))
	option.clear()
	for raw in records:
		var item := raw as Dictionary
		option.add_item("%s · %s" % [item.get(id_key, "--"), item.get(label_key, "--")])
		option.set_item_metadata(option.item_count - 1, item.get(id_key, ""))
		if String(item.get(id_key, "")) == selected_id:
			option.select(option.item_count - 1)


func _refresh() -> void:
	if _report.is_empty() or _case.is_empty():
		_status_label.text = "[color=#ff5c4f][b]BLOCKED[/b][/color] 安全案例或评估报告缺失。"
		return
	var sections := _report.get("section_results", {}) as Dictionary
	var odd := sections.get("operational_design_domain", {}) as Dictionary
	var hazards := sections.get("hazard_log", {}) as Dictionary
	var mrc := sections.get("minimum_risk_conditions", {}) as Dictionary
	var trees := sections.get("fault_trees", {}) as Dictionary
	var monitor := _report.get("runtime_odd_monitor_smoke", {}) as Dictionary
	_status_label.text = (
		"[color=#86ff9b][b]FUNCTIONAL SAFETY CASE %s · %d/12[/b][/color]  [color=#ffbd40]%s[/color]\n"
		+ "ODD %d · 危险 %d · 控制 %d · MRC %d · FTA %d · ODD越界演练 %d/12\n"
		+ "independent_review=false · flag/class/type/MASS_certificate=false · production=false · 最近退出码=%d %s"
	) % [
		"PASS" if bool(_report.get("functional_safety_case_complete", false)) else "FAIL",
		_count_true(_report.get("checks", {}) as Dictionary),
		_report.get("status", "--"),
		int(odd.get("dimension_count", 0)),
		int(hazards.get("hazard_count", 0)),
		int(hazards.get("control_count", 0)),
		int(mrc.get("mrc_count", 0)),
		int(trees.get("tree_count", 0)),
		int(monitor.get("breach_case_count", 0)),
		_last_exit_code,
		_last_command_output.strip_edges(),
	]
	_refresh_hazard()
	_refresh_mrc()
	_refresh_claim()


func _on_hazard_selected(_index: int) -> void:
	_refresh_hazard()


func _on_mrc_selected(_index: int) -> void:
	_refresh_mrc()


func _on_claim_selected(_index: int) -> void:
	_refresh_claim()


func _selected_record(option: OptionButton, records: Array, id_key: String) -> Dictionary:
	if option.item_count == 0 or option.selected < 0:
		return {}
	var selected_id := String(option.get_item_metadata(option.selected))
	for raw in records:
		var item := raw as Dictionary
		if String(item.get(id_key, "")) == selected_id:
			return item
	return {}


func _refresh_hazard() -> void:
	var item := _selected_record(_hazard_option, _case.get("hazard_log", []) as Array, "hazard_id")
	var controls := item.get("controls", []) as Array
	var control_lines: Array[String] = []
	for raw in controls:
		var control := raw as Dictionary
		control_lines.append("• %s [%s] %s" % [control.get("control_id", "--"), control.get("type", "--"), control.get("description", "--")])
	_hazard_label.text = (
		"[color=#73f5ff][b]%s · %s[/b][/color]\n%s\n\n初始风险：[color=#ff5c4f]%s[/color]  剩余风险：[color=#ffbd40]%s[/color]\n风险所有者：%s\nMRC：%s\n\n控制：\n%s"
	) % [item.get("hazard_id", "--"), item.get("category", "--"), item.get("description", "--"), item.get("initial_risk", "--"), item.get("residual_risk", "--"), item.get("risk_owner_role", "--"), ", ".join(item.get("mrc_ids", []) as Array), "\n".join(control_lines)]


func _refresh_mrc() -> void:
	var item := _selected_record(_mrc_option, _case.get("minimum_risk_conditions", []) as Array, "mrc_id")
	_mrc_label.text = (
		"[color=#73f5ff][b]%s · %s[/b][/color]\n权限：%s  超时：%ss\n回退：%s\n\n触发：%s\n\n动作：\n• %s\n\n成功判据：\n• %s"
	) % [item.get("mrc_id", "--"), item.get("name", "--"), item.get("command_authority", "--"), str(item.get("timeout_s", "--")), item.get("fallback_mrc_id", "--"), ", ".join(item.get("trigger_categories", []) as Array), "\n• ".join(item.get("actions", []) as Array), "\n• ".join(item.get("success_criteria", []) as Array)]


func _refresh_claim() -> void:
	var item := _selected_record(_claim_option, _case.get("claim_graph", []) as Array, "claim_id")
	var acceptance := _report.get("acceptance_evidence", {}) as Dictionary
	var responsibility := (_report.get("section_results", {}) as Dictionary).get("responsibility_model", {}) as Dictionary
	var regulatory := (_report.get("section_results", {}) as Dictionary).get("regulatory_applicability", {}) as Dictionary
	_claim_label.text = (
		"[color=#73f5ff][b]%s[/b][/color]\n%s\n状态：[color=#ffbd40]%s[/color]\n证据：%s\n\nRACI：%d 角色 / %d 活动\n法规路由：%d 类，全部待外部决定\nRCC site_authorized=false\n\n外部证据：%s\n当前缺口：%s\n导出：%s"
	) % [item.get("claim_id", "--"), item.get("statement", "--"), item.get("status", "--"), ", ".join(item.get("evidence_ids", []) as Array), int(responsibility.get("role_count", 0)), int(responsibility.get("activity_count", 0)), int(regulatory.get("instrument_count", 0)), "COMPLETE" if bool(acceptance.get("passed", false)) else "BLOCKED", _selected_acceptance_gap if not _selected_acceptance_gap.is_empty() else "点击浏览", str(_last_export.get("directory", "未导出"))]


func _cycle_odd_breach() -> void:
	var monitor := _report.get("runtime_odd_monitor_smoke", {}) as Dictionary
	var cases := monitor.get("breach_cases", {}) as Dictionary
	var ids := cases.keys()
	ids.sort()
	if ids.is_empty():
		_selected_odd_case = {}
		_odd_demo_label.text = "没有可用的 ODD 越界案例。"
		return
	_odd_case_index %= ids.size()
	var dimension_id := String(ids[_odd_case_index])
	var result := cases.get(dimension_id, {}) as Dictionary
	_selected_odd_case = {"dimension_id": dimension_id, "result": result.duplicate(true)}
	_odd_demo_label.text = "[color=#ffbd40][b]ODD EXIT %s[/b][/color]\n只给出 MRC 路由，不下发生产指令：%s" % [dimension_id, ", ".join(result.get("required_mrc_ids", []) as Array)]
	_odd_case_index = (_odd_case_index + 1) % ids.size()


func _next_acceptance_gap() -> void:
	var acceptance := _report.get("acceptance_evidence", {}) as Dictionary
	var missing := acceptance.get("missing_or_invalid", []) as Array
	if missing.is_empty():
		_selected_acceptance_gap = "等待有权方最终决定"
	else:
		_acceptance_gap_index %= missing.size()
		_selected_acceptance_gap = String(missing[_acceptance_gap_index])
		_acceptance_gap_index = (_acceptance_gap_index + 1) % missing.size()
	_refresh_claim()


func _count_true(values: Dictionary) -> int:
	var count := 0
	for value in values.values():
		if value is bool and bool(value):
			count += 1
	return count


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

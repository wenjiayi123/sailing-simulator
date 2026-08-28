extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_U
const REPORT_PATH := "res://reports/physical_bridge_readiness_v1.json"
const RUNTIME_REPORT_PATH := "res://reports/physical_hil_runtime_functional_smoke_v1.json"
const MAPPING_PATH := "res://data/verification/simulator_standards_mapping_v1.json"
const MANIFEST_TEMPLATE_PATH := "res://data/verification/physical_bridge_hil_manifest.template.json"
const WITNESS_TEMPLATE_PATH := "res://data/verification/physical_hil_witnessed_test_csv_template.csv"
const RUNTIME_PROFILE_PATH := "res://data/verification/physical_hil_runtime_profile_v1.json"
const EXPORT_DIRECTORY := "user://physical_hil_evidence"
const COLOR_BG := Color(0.008, 0.019, 0.030, 0.97)
const COLOR_PANEL := Color(0.025, 0.052, 0.068, 0.96)
const COLOR_CYAN := Color(0.27, 0.94, 1.0, 1.0)
const COLOR_GREEN := Color(0.42, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.73, 0.25, 1.0)
const COLOR_RED := Color(1.0, 0.36, 0.31, 1.0)
const COLOR_TEXT := Color(0.84, 0.95, 1.0, 1.0)
const COLOR_MUTED := Color(0.55, 0.70, 0.77, 1.0)

@export var start_visible: bool = false

var _root: Control
var _status_label: RichTextLabel
var _hardware_label: RichTextLabel
var _runtime_label: RichTextLabel
var _standards_label: RichTextLabel
var _requirement_option: OptionButton
var _report: Dictionary = {}
var _mapping: Dictionary = {}
var _runtime_report: Dictionary = {}
var _last_command_output := ""
var _last_exit_code := -1
var _last_runtime_output := ""
var _last_runtime_exit_code := -1
var _last_export: Dictionary = {}


func _ready() -> void:
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_interface()
	_reload_evidence()
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.physical_keycode == TOGGLE_PANEL_KEY:
			_root.visible = not _root.visible
			if _root.visible:
				_reload_evidence()
			get_viewport().set_input_as_handled()


func show_panel() -> void:
	_root.visible = true
	_reload_evidence()


func get_acceptance_snapshot() -> Dictionary:
	return {
		"format": "ship_physical_bridge_readiness_panel_v1",
		"report": _report.duplicate(true),
		"mapping": _mapping.duplicate(true),
		"runtime_report": _runtime_report.duplicate(true),
		"last_exit_code": _last_exit_code,
		"last_command_output": _last_command_output,
		"last_runtime_exit_code": _last_runtime_exit_code,
		"last_runtime_output": _last_runtime_output,
		"last_export": _last_export.duplicate(true),
		"training_performed": false,
		"existing_model_modified": false,
		"production_authority": false,
		"physical_hil_verified": false,
		"site_delivery_ready": false,
		"certified": false,
	}


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipPhysicalBridgeReadinessRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = start_visible
	add_child(_root)
	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.0, 0.006, 0.012, 0.82)
	_root.add_child(backdrop)
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -465.0
	panel.offset_top = -330.0
	panel.offset_right = 465.0
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
	stack.add_theme_constant_override("separation", 9)
	margin.add_child(stack)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	stack.add_child(header)
	var title := _label("物理驾驶台 / HIL / 认证就绪", 20, COLOR_CYAN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var run_button := _button("重新运行检查")
	run_button.pressed.connect(_on_run_check_pressed)
	header.add_child(run_button)
	var runtime_button := _button("运行 HIL 状态机烟测")
	runtime_button.pressed.connect(_on_run_runtime_smoke_pressed)
	header.add_child(runtime_button)
	var export_button := _button("导出现场测试模板")
	export_button.pressed.connect(_export_site_templates)
	header.add_child(export_button)
	var reload_button := _button("重新载入")
	reload_button.pressed.connect(_reload_evidence)
	header.add_child(reload_button)
	var close_button := _button("关闭 U")
	close_button.pressed.connect(func() -> void: _root.visible = false)
	header.add_child(close_button)

	_status_label = _rich("等待报告", 118.0)
	stack.add_child(_status_label)
	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 10)
	stack.add_child(columns)
	var hardware_box := _section("硬件、通道与联锁")
	hardware_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(hardware_box)
	_hardware_label = _rich("--", 245.0)
	hardware_box.add_child(_hardware_label)
	_runtime_label = _rich("--", 122.0)
	hardware_box.add_child(_runtime_label)
	var standards_box := _section("STCW / DNV 追踪")
	standards_box.custom_minimum_size.x = 430.0
	columns.add_child(standards_box)
	_requirement_option = OptionButton.new()
	_requirement_option.item_selected.connect(_on_requirement_selected)
	standards_box.add_child(_requirement_option)
	_standards_label = _rich("--", 260.0)
	standards_box.add_child(_standards_label)
	var boundary := _label("目标控制器状态机和故障烟测可执行；当前未连接物理硬件、真实 I/O 或 RTOS，未获外部见证/认证，生产权限关闭。", 11, COLOR_AMBER)
	boundary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(boundary)


func _on_run_check_pressed() -> void:
	var python_path := ProjectSettings.globalize_path("res://.venv/bin/python")
	var script_path := ProjectSettings.globalize_path("res://tools/run_physical_bridge_readiness.py")
	if not FileAccess.file_exists(python_path) or not FileAccess.file_exists(script_path):
		_last_exit_code = -1
		_last_command_output = "Python 环境或检查器缺失"
		_refresh_labels()
		return
	var output: Array = []
	_last_exit_code = OS.execute(
		python_path,
		PackedStringArray([script_path, "generate"]),
		output,
		true,
		false,
	)
	_last_command_output = "\n".join(output)
	_reload_evidence()


func _on_run_runtime_smoke_pressed() -> void:
	var python_path := ProjectSettings.globalize_path("res://.venv/bin/python")
	var script_path := ProjectSettings.globalize_path("res://tools/run_physical_hil_runtime.py")
	if not FileAccess.file_exists(python_path) or not FileAccess.file_exists(script_path):
		_last_runtime_exit_code = -1
		_last_runtime_output = "Python 环境或 HIL 运行时检查器缺失"
		_refresh_labels()
		return
	var output: Array = []
	_last_runtime_exit_code = OS.execute(
		python_path,
		PackedStringArray([script_path, "generate"]),
		output,
		true,
		false,
	)
	_last_runtime_output = "\n".join(output)
	_reload_evidence()


func _export_site_templates() -> void:
	var absolute_directory := ProjectSettings.globalize_path(EXPORT_DIRECTORY)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK:
		_last_export = {"passed": false, "error": error_string(directory_error)}
		_refresh_labels()
		return
	var mappings := {
		MANIFEST_TEMPLATE_PATH: EXPORT_DIRECTORY + "/physical_bridge_hil_manifest.json",
		WITNESS_TEMPLATE_PATH: EXPORT_DIRECTORY + "/physical_hil_witnessed_test.csv",
		RUNTIME_PROFILE_PATH: EXPORT_DIRECTORY + "/physical_hil_runtime_profile.json",
	}
	var copied := {}
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
		copied[target_path] = FileAccess.get_sha256(target_path)
	_last_export = {"passed": passed, "directory": EXPORT_DIRECTORY, "files_sha256": copied}
	_refresh_labels()


func _reload_evidence() -> void:
	_report = _read_json(REPORT_PATH)
	_mapping = _read_json(MAPPING_PATH)
	_runtime_report = _read_json(RUNTIME_REPORT_PATH)
	_sync_requirement_options()
	_refresh_labels()


func _sync_requirement_options() -> void:
	var selected_id := ""
	if _requirement_option.item_count > 0 and _requirement_option.selected >= 0:
		selected_id = String(_requirement_option.get_item_metadata(_requirement_option.selected))
	_requirement_option.clear()
	for raw in _mapping.get("requirements", []) as Array:
		var item := raw as Dictionary
		_requirement_option.add_item("%s · %s" % [item.get("requirement_id", "--"), item.get("status", "--")])
		_requirement_option.set_item_metadata(_requirement_option.item_count - 1, item.get("requirement_id", ""))
		if String(item.get("requirement_id", "")) == selected_id:
			_requirement_option.select(_requirement_option.item_count - 1)


func _on_requirement_selected(_index: int) -> void:
	_refresh_standard_detail()


func _refresh_labels() -> void:
	if _report.is_empty():
		_status_label.text = "[color=#ff5c4f][b]BLOCKED[/b][/color]  就绪报告缺失；请运行检查。"
		_hardware_label.text = "未载入硬件证据清单。"
		_runtime_label.text = "未载入 HIL 运行时烟测。"
		_standards_label.text = "未载入标准追踪。"
		return
	var evaluation := _report.get("evaluation", {}) as Dictionary
	var claims := _report.get("claims", {}) as Dictionary
	_status_label.text = (
		"[color=#86ff9b][b]SOFTWARE GATE %s[/b][/color]  ·  [color=#ffbd40]%s[/color]\n"
		+ "physical_hil_verified=%s  site_delivery_ready=%s  stcw_approved=%s  dnv_certified=%s  production_authority=%s\n"
		+ "最近运行退出码：%d  %s"
	) % [
		"PASS" if bool(_report.get("software_readiness_gate_passed", false)) else "FAIL",
		evaluation.get("status", "--"),
		str(claims.get("physical_hil_verified", false)),
		str(claims.get("site_delivery_ready", false)),
		str(claims.get("stcw_approved", false)),
		str(claims.get("dnv_certified", false)),
		str(claims.get("production_authority", false)),
		_last_exit_code,
		_last_command_output.strip_edges(),
	]
	var hardware := evaluation.get("hardware_inventory", {}) as Dictionary
	var io := evaluation.get("io_contract", {}) as Dictionary
	var interlocks := evaluation.get("safety_interlocks", {}) as Dictionary
	var timing := evaluation.get("timing", {}) as Dictionary
	var site := evaluation.get("site_and_test_evidence", {}) as Dictionary
	var target_runtime := evaluation.get("target_runtime_and_witnessed_tests", {}) as Dictionary
	_hardware_label.text = (
		"[b]物理硬件[/b]  %s\n缺失：%s\n\n"
		+ "[b]输入输出通道[/b]  %s\n缺失：%s\n\n"
		+ "[b]独立安全联锁[/b]  %s\n缺失：%s\n\n"
		+ "[b]时延/抖动/WCET/时钟[/b]  %s\n"
		+ "[b]目标控制器/RTOS/真实 I/O/见证[/b]  %s\n"
		+ "[b]现场/标定/见证/签字[/b]  %s"
	) % [
		"PASS" if bool(hardware.get("passed", false)) else "BLOCKED",
		", ".join(hardware.get("missing_roles", []) as Array),
		"PASS" if bool(io.get("passed", false)) else "BLOCKED",
		", ".join(io.get("missing_channels", []) as Array),
		"PASS" if bool(interlocks.get("passed", false)) else "BLOCKED",
		", ".join(interlocks.get("failed_or_missing", []) as Array),
		"PASS" if bool(timing.get("passed", false)) else "BLOCKED",
		"PASS" if bool(target_runtime.get("passed", false)) else "BLOCKED",
		"PASS" if bool(site.get("passed", false)) else "BLOCKED",
	]
	_refresh_runtime_detail()
	_refresh_standard_detail()


func _refresh_runtime_detail() -> void:
	if _runtime_report.is_empty():
		_runtime_label.text = "[color=#ff5c4f][b]HIL RUNTIME MISSING[/b][/color]"
		return
	var timing := _runtime_report.get("timing", {}) as Dictionary
	var estop := _runtime_report.get("dual_channel_emergency_stop", {}) as Dictionary
	_runtime_label.text = (
		"[color=#86ff9b][b]状态机烟测 %s[/b][/color]  %d/17\n"
		+ "WCET max %.3f ms / deadline %.1f ms · 样本 %d\n"
		+ "双通道急停 A=%s B=%s · 掉线恢复/时钟漂移/超期均中性化\n"
		+ "target=false · real_io=false · rtos=false · 最近退出码=%d\n"
		+ "模板导出：%s"
	) % [
		"PASS" if bool(_runtime_report.get("passed", false)) else "FAIL",
		(_runtime_report.get("checks", {}) as Dictionary).values().filter(func(value: Variant) -> bool: return value is bool and bool(value)).size(),
		float(timing.get("maximum_ms", 0.0)),
		float(timing.get("deadline_ms", 0.0)),
		int(timing.get("sample_count", 0)),
		str((estop.get("channel_a", {}) as Dictionary).get("tripped", false)),
		str((estop.get("channel_b", {}) as Dictionary).get("tripped", false)),
		_last_runtime_exit_code,
		str(_last_export.get("directory", "未导出")),
	]


func _refresh_standard_detail() -> void:
	if _requirement_option.item_count == 0 or _requirement_option.selected < 0:
		_standards_label.text = "没有标准追踪条目。"
		return
	var requirement_id := String(_requirement_option.get_item_metadata(_requirement_option.selected))
	for raw in _mapping.get("requirements", []) as Array:
		var item := raw as Dictionary
		if String(item.get("requirement_id", "")) != requirement_id:
			continue
		_standards_label.text = (
			"[color=#73f5ff][b]%s[/b][/color]\n%s\n\n"
			+ "状态：[color=#ffbd40]%s[/color]\n\n"
			+ "已有证据：\n%s\n\n"
			+ "仍缺：\n%s"
		) % [
			item.get("requirement_id", "--"),
			item.get("topic", "--"),
			item.get("status", "--"),
			"\n".join(item.get("evidence", []) as Array) if not (item.get("evidence", []) as Array).is_empty() else "无",
			item.get("gap", "--"),
		]
		return


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var value: Variant = JSON.parse_string(file.get_as_text())
	return value if value is Dictionary else {}


func _section(title: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	var heading := _label(title, 13, COLOR_CYAN)
	heading.add_theme_stylebox_override("normal", _style(COLOR_PANEL, Color(COLOR_CYAN.r, COLOR_CYAN.g, COLOR_CYAN.b, 0.35), 6))
	box.add_child(heading)
	return box


func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 30.0
	button.add_theme_font_size_override("font_size", 12)
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

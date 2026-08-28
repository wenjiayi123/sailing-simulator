extends CanvasLayer
class_name ShipNamedVesselTwinPanel

const TOGGLE_PANEL_KEY := KEY_G
const READINESS_PATH := "res://reports/named_vessel_twin_readiness_v1.json"
const SMOKE_PATH := "res://reports/named_vessel_twin_functional_smoke_v1.json"
const MANIFEST_TEMPLATE_PATH := "res://data/verification/named_vessel_twin_manifest.template.json"
const CSV_TEMPLATE_PATH := "res://data/verification/named_vessel_trial_csv_template.csv"
const COLOR_BG := Color(0.008, 0.018, 0.027, 0.98)
const COLOR_PANEL := Color(0.024, 0.048, 0.064, 0.98)
const COLOR_CYAN := Color(0.28, 0.94, 1.0, 1.0)
const COLOR_GREEN := Color(0.42, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.73, 0.25, 1.0)
const COLOR_RED := Color(1.0, 0.29, 0.25, 1.0)
const COLOR_TEXT := Color(0.84, 0.95, 1.0, 1.0)
const COLOR_MUTED := Color(0.56, 0.70, 0.77, 1.0)

@export var start_visible := false

var _root: Control
var _labels: Dictionary = {}
var _maneuver_option: OptionButton
var _readiness: Dictionary = {}
var _smoke: Dictionary = {}
var _missing_index := 0
var _last_export: Dictionary = {}
var _acceptance: Dictionary = {}


func _ready() -> void:
	layer = 69
	add_to_group(&"ship_named_vessel_twin_panel")
	_build_interface()
	_reload_reports()
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.physical_keycode == TOGGLE_PANEL_KEY:
			toggle_panel()
			get_viewport().set_input_as_handled()


func show_panel() -> void:
	_root.visible = true
	_reload_reports()


func hide_panel() -> void:
	_root.visible = false


func toggle_panel() -> void:
	_root.visible = not _root.visible
	if _root.visible:
		_reload_reports()


func get_acceptance_snapshot() -> Dictionary:
	return _acceptance.duplicate(true)


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipNamedVesselTwinRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = start_visible
	add_child(_root)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -455.0
	panel.offset_top = -315.0
	panel.offset_right = 455.0
	panel.offset_bottom = 315.0
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
	var title := _label("指定船舶数字孪生 / IDENTIFICATION · ERROR ENVELOPE", 18, COLOR_CYAN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	header.add_child(_label("现模型冻结｜待实船校准", 11, COLOR_AMBER))
	header.add_child(_button("收起 G", hide_panel))

	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 8)
	stack.add_child(status_row)
	for item in [["readiness", "READINESS --"], ["smoke", "FUNCTION --"], ["calibrated", "CALIBRATED --"]]:
		var pill := _pill(String(item[1]))
		pill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_labels[String(item[0])] = pill
		status_row.add_child(pill)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 10)
	stack.add_child(columns)

	var evidence_column := _column("实船证据覆盖 / EVIDENCE COVERAGE")
	evidence_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(evidence_column)
	_add_metric(evidence_column, "identity", "船舶身份")
	_add_metric(evidence_column, "maneuvers", "操纵试验")
	_add_metric(evidence_column, "loads", "装载工况")
	_add_metric(evidence_column, "review", "独立审查")
	_add_metric(evidence_column, "missing", "当前缺口")
	evidence_column.add_child(_button("查看下一条缺失证据", _next_missing))

	var envelope_column := _column("模型误差包络 / ERROR ENVELOPE")
	envelope_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(envelope_column)
	_maneuver_option = OptionButton.new()
	_maneuver_option.item_selected.connect(_on_maneuver_selected)
	envelope_column.add_child(_maneuver_option)
	_add_metric(envelope_column, "trial", "当前试验")
	_add_metric(envelope_column, "position", "位置 P95")
	_add_metric(envelope_column, "heading", "首向 P95")
	_add_metric(envelope_column, "speed", "纵向速度 RMSE")
	_add_metric(envelope_column, "yaw", "艏摇角速度 RMSE")
	_add_metric(envelope_column, "identification", "参数辨识")

	var action_column := _column("工作流 / CALIBRATION WORKFLOW")
	action_column.custom_minimum_size.x = 245.0
	columns.add_child(action_column)
	action_column.add_child(_button("重新载入评估报告", _reload_reports))
	action_column.add_child(_button("导出实船证据模板", _export_templates))
	action_column.add_child(_button("下一项操纵试验", _next_trial))
	_add_metric(action_column, "export", "模板导出")
	_add_metric(action_column, "model", "冻结模型")
	_add_metric(action_column, "training", "训练状态")

	var boundary := _label("软件冒烟使用仿真生成试验，仅证明读取、重放、辨识和误差包络功能。只有指定船舶原始 GNSS/INS、舵/推进反馈、同步环境记录、三个装载工况和独立见证审查齐全后，才可形成校准候选；系统不会自动改写现有模型。", 11, COLOR_AMBER)
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


func _reload_reports() -> void:
	_readiness = _read_json(READINESS_PATH)
	_smoke = _read_json(SMOKE_PATH)
	_populate_maneuvers()
	_update_view()


func _populate_maneuvers() -> void:
	var previous := _maneuver_option.selected if _maneuver_option.item_count > 0 else 0
	_maneuver_option.clear()
	for raw in _smoke.get("trial_results", []) as Array:
		var trial := raw as Dictionary
		_maneuver_option.add_item(String(trial.get("maneuver", "UNKNOWN")))
	if _maneuver_option.item_count > 0:
		_maneuver_option.select(clampi(previous, 0, _maneuver_option.item_count - 1))


func _next_missing() -> void:
	var errors := _readiness.get("errors", []) as Array
	if not errors.is_empty():
		_missing_index = (_missing_index + 1) % errors.size()
	_update_view()


func _next_trial() -> void:
	if _maneuver_option.item_count > 0:
		_maneuver_option.select((_maneuver_option.selected + 1) % _maneuver_option.item_count)
	_update_view()


func _on_maneuver_selected(_index: int) -> void:
	_update_view()


func _export_templates() -> void:
	var directory := "user://named_vessel_twin_evidence"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var manifest_target := directory + "/named_vessel_twin_manifest.json"
	var csv_target := directory + "/named_vessel_trial_template.csv"
	var manifest_ok := _copy_file(MANIFEST_TEMPLATE_PATH, manifest_target)
	var csv_ok := _copy_file(CSV_TEMPLATE_PATH, csv_target)
	_last_export = {
		"passed": manifest_ok and csv_ok,
		"manifest_path": manifest_target,
		"csv_path": csv_target,
	}
	_update_view()


func _copy_file(source: String, target: String) -> bool:
	var source_file := FileAccess.open(source, FileAccess.READ)
	if source_file == null:
		return false
	var bytes := source_file.get_buffer(source_file.get_length())
	source_file.close()
	var target_file := FileAccess.open(target, FileAccess.WRITE)
	if target_file == null:
		return false
	target_file.store_buffer(bytes)
	target_file.close()
	return true


func _update_view() -> void:
	var status := String(_readiness.get("status", "NO_REPORT"))
	var smoke_passed := bool(_smoke.get("passed", false))
	var calibrated := bool(_readiness.get("named_vessel_dynamics_calibrated", false))
	_set_pill("readiness", "READINESS " + ("CANDIDATE" if status.contains("CANDIDATE") else "BLOCKED"), COLOR_GREEN if status.contains("CANDIDATE") else COLOR_AMBER)
	_set_pill("smoke", "FUNCTION " + ("PASS" if smoke_passed else "FAIL"), COLOR_GREEN if smoke_passed else COLOR_RED)
	_set_pill("calibrated", "CALIBRATED " + ("YES" if calibrated else "NO"), COLOR_GREEN if calibrated else COLOR_AMBER)
	var identity := _readiness.get("vessel_identity", {}) as Dictionary
	_set_text("identity", "船舶身份：%s" % (String(identity.get("vessel_name", "")).strip_edges() if not String(identity.get("vessel_name", "")).strip_edges().is_empty() else "MISSING"))
	var required := _readiness.get("required_maneuvers", []) as Array
	var covered := _readiness.get("covered_maneuvers", []) as Array
	_set_text("maneuvers", "操纵试验：%d/%d" % [covered.size(), required.size()])
	var load_counts := _readiness.get("loading_condition_trial_counts", {}) as Dictionary
	_set_text("loads", "装载工况：轻载 %d｜设计 %d｜最大 %d" % [int(load_counts.get("lightship", 0)), int(load_counts.get("design_payload", 0)), int(load_counts.get("maximum_operating", 0))])
	_set_text("review", "独立审查：%s" % ("COMPLETE" if bool(_readiness.get("independent_review_complete", false)) else "MISSING"))
	var errors := _readiness.get("errors", []) as Array
	_set_text("missing", "当前缺口：%s" % ("NONE" if errors.is_empty() else String(errors[_missing_index % errors.size()])))
	var trials := _smoke.get("trial_results", []) as Array
	var selected := clampi(_maneuver_option.selected, 0, maxi(trials.size() - 1, 0))
	var trial := trials[selected] as Dictionary if not trials.is_empty() else {}
	var envelope := trial.get("error_envelope", {}) as Dictionary
	_set_text("trial", "当前试验：%s｜%s" % [String(trial.get("maneuver", "--")), String(trial.get("loading_condition", "--"))])
	_set_text("position", "位置 P95：%.3f m" % float(envelope.get("position_error_p95_m", 0.0)))
	_set_text("heading", "首向 P95：%.3f°" % float(envelope.get("heading_error_p95_deg", 0.0)))
	_set_text("speed", "纵向速度 RMSE：%.3f m/s" % float(envelope.get("surge_speed_rmse_mps", 0.0)))
	_set_text("yaw", "艏摇角速度 RMSE：%.3f°/s" % float(envelope.get("yaw_rate_rmse_deg_s", 0.0)))
	var identified := trial.get("identified_response", {}) as Dictionary
	_set_text("identification", "参数辨识：SURGE %s｜NOMOTO %s" % ["READY" if identified.has("surge_first_order") else "--", "READY" if identified.has("nomoto_first_order") else "--"])
	_set_text("export", "模板导出：%s" % ("READY" if bool(_last_export.get("passed", false)) else "NOT EXPORTED"))
	_set_text("model", "冻结模型：taoyuan_catamaran_usv_3dof_twin_waterjet_v2")
	_set_text("training", "训练状态：NOT PERFORMED")
	_acceptance = {
		"schema_version": "ship_named_vessel_twin_panel_snapshot_v1",
		"readiness_status": status,
		"functional_smoke_passed": smoke_passed,
		"required_maneuver_count": required.size(),
		"functional_maneuver_count": int(_smoke.get("maneuver_count", 0)),
		"loading_conditions_covered": _smoke.get("loading_conditions_covered", []),
		"named_vessel_dynamics_calibrated": calibrated,
		"existing_model_modified": bool(_smoke.get("existing_model_modified", true)),
		"training_performed": bool(_smoke.get("training_performed", true)),
		"last_export": _last_export.duplicate(true),
		"production_authority": false,
	}


func _set_pill(key: String, value: String, color: Color) -> void:
	var label := _labels.get(key) as Label
	if label != null:
		label.text = "  " + value + "  "
		label.add_theme_color_override("font_color", color)


func _set_text(key: String, value: String) -> void:
	var label := _labels.get(key) as Label
	if label != null:
		label.text = value


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed as Dictionary if parsed is Dictionary else {}

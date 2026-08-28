extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_T
const CAMPAIGN_PATH := "res://data/verification/rl_generalization_campaign_v1.json"
const RESULTS_TEMPLATE_PATH := "res://data/verification/rl_generalization_results_manifest.template.json"
const REPORT_PATH := "res://reports/rl_generalization_assurance_v1.json"
const PLAN_PATH := "res://reports/rl_generalization_evaluation_plan_v1.json"
const EXPORT_DIRECTORY := "user://rl_generalization_evidence"
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
var _domain_option: OptionButton
var _domain_label: RichTextLabel
var _fixture_option: OptionButton
var _fixture_label: RichTextLabel
var _gate_label: RichTextLabel
var _campaign: Dictionary = {}
var _report: Dictionary = {}
var _plan: Dictionary = {}
var _last_exit_code := -1
var _last_command_output := ""
var _last_export: Dictionary = {}
var _gap_index := 0
var _selected_gap := ""


func _ready() -> void:
	layer = 64
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
		"schema_version": "ship_rl_generalization_panel_snapshot_v1",
		"report": _report.duplicate(true),
		"plan": _plan.duplicate(true),
		"campaign": _campaign.duplicate(true),
		"selected_domain_id": _selected_metadata(_domain_option),
		"selected_fixture_id": _selected_metadata(_fixture_option),
		"selected_gap": _selected_gap,
		"last_exit_code": _last_exit_code,
		"last_command_output": _last_command_output,
		"last_export": _last_export.duplicate(true),
		"training_performed": false,
		"convergence_demonstrated": false,
		"existing_policy_modified": false,
		"ship_motion_model_modified": false,
		"real_multi_port_generalization_demonstrated": false,
		"real_multi_season_generalization_demonstrated": false,
		"shadow_operation_completed": false,
		"production_authority": false,
	}


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipRlGeneralizationRoot"
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
	var title := _label("RL 泛化可信度 / MULTI-DOMAIN · OOD · ABLATION · STRESS · SHADOW", 18, COLOR_CYAN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	header.add_child(_button("重新运行框架验收", _run_assessment))
	header.add_child(_button("导出冻结评测包", _export_evidence))
	header.add_child(_button("重新载入", _reload))
	header.add_child(_button("关闭 T", func() -> void: _root.visible = false))
	_status_label = _rich("等待泛化保障报告", 96.0)
	stack.add_child(_status_label)
	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 10)
	stack.add_child(columns)
	var domain_box := _section("多域清单", 350.0)
	columns.add_child(domain_box)
	_domain_option = OptionButton.new()
	_domain_option.item_selected.connect(_on_domain_selected)
	domain_box.add_child(_domain_option)
	_domain_label = _rich("--", 335.0)
	domain_box.add_child(_domain_label)
	var fixture_box := _section("响应式交通功能夹具", 390.0)
	columns.add_child(fixture_box)
	_fixture_option = OptionButton.new()
	_fixture_option.item_selected.connect(_on_fixture_selected)
	fixture_box.add_child(_fixture_option)
	_fixture_label = _rich("--", 295.0)
	fixture_box.add_child(_fixture_label)
	fixture_box.add_child(_button("下一个功能夹具", _next_fixture))
	var gate_box := _section("训练、域外与影子门禁", 400.0)
	gate_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(gate_box)
	_gate_label = _rich("--", 335.0)
	gate_box.add_child(_gate_label)
	gate_box.add_child(_button("查看下一条证据缺口", _next_gap))
	var boundary := _label("本页证明评测功能与拒绝门禁可执行，不证明策略已经收敛或跨港泛化。统一训练前保持 training=false；真实多港、多季节和影子运行证据为空时必须阻断结论。", 11, COLOR_AMBER)
	boundary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(boundary)


func _run_assessment() -> void:
	var python_path := ProjectSettings.globalize_path("res://.venv/bin/python")
	var script_path := ProjectSettings.globalize_path("res://tools/run_rl_generalization_assurance.py")
	if not FileAccess.file_exists(python_path) or not FileAccess.file_exists(script_path):
		_last_exit_code = -1
		_last_command_output = "Python 环境或泛化检查器缺失"
		_refresh()
		return
	var output: Array = []
	_last_exit_code = OS.execute(python_path, PackedStringArray([script_path, "generate"]), output, true, false)
	_last_command_output = "\n".join(output)
	_reload()


func _export_evidence() -> void:
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EXPORT_DIRECTORY))
	if error != OK:
		_last_export = {"passed": false, "error": error_string(error)}
		_refresh()
		return
	var mappings := {
		CAMPAIGN_PATH: EXPORT_DIRECTORY + "/rl_generalization_campaign_v1.json",
		RESULTS_TEMPLATE_PATH: EXPORT_DIRECTORY + "/rl_generalization_results_manifest.json",
		REPORT_PATH: EXPORT_DIRECTORY + "/rl_generalization_assurance_v1.json",
		PLAN_PATH: EXPORT_DIRECTORY + "/rl_generalization_evaluation_plan_v1.json",
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
	_campaign = _read_json(CAMPAIGN_PATH)
	_report = _read_json(REPORT_PATH)
	_plan = _read_json(PLAN_PATH)
	_sync_options()
	_refresh()


func _sync_options() -> void:
	var previous_domain := _selected_metadata(_domain_option)
	_domain_option.clear()
	var dimensions := _campaign.get("domain_dimensions", {}) as Dictionary
	for category in ["ports", "seasons", "vessel_profiles", "traffic_behaviors"]:
		for raw in dimensions.get(category, []) as Array:
			var item := raw as Dictionary
			_domain_option.add_item("%s · %s" % [category, item.get("name", item.get("behavior", item.get("domain_id", "--")))])
			_domain_option.set_item_metadata(_domain_option.item_count - 1, item.get("domain_id", ""))
			if String(item.get("domain_id", "")) == previous_domain:
				_domain_option.select(_domain_option.item_count - 1)
	if _domain_option.item_count > 0 and _domain_option.selected < 0:
		_domain_option.select(0)
	var previous_fixture := _selected_metadata(_fixture_option)
	_fixture_option.clear()
	var smoke := _report.get("functional_smoke", {}) as Dictionary
	for raw in smoke.get("results", []) as Array:
		var item := raw as Dictionary
		_fixture_option.add_item("%s · %s" % [item.get("fixture_id", "--"), "PASS" if bool(item.get("passed", false)) else "FAIL"])
		_fixture_option.set_item_metadata(_fixture_option.item_count - 1, item.get("fixture_id", ""))
		if String(item.get("fixture_id", "")) == previous_fixture:
			_fixture_option.select(_fixture_option.item_count - 1)
	if _fixture_option.item_count > 0 and _fixture_option.selected < 0:
		_fixture_option.select(0)


func _selected_metadata(option: OptionButton) -> String:
	if option == null or option.item_count == 0 or option.selected < 0:
		return ""
	return String(option.get_item_metadata(option.selected))


func _selected_domain() -> Dictionary:
	var selected_id := _selected_metadata(_domain_option)
	var dimensions := _campaign.get("domain_dimensions", {}) as Dictionary
	for category in ["ports", "seasons", "vessel_profiles", "traffic_behaviors"]:
		for raw in dimensions.get(category, []) as Array:
			var item := raw as Dictionary
			if String(item.get("domain_id", "")) == selected_id:
				var result := item.duplicate(true)
				result["category"] = category
				return result
	return {}


func _selected_fixture() -> Dictionary:
	var selected_id := _selected_metadata(_fixture_option)
	var smoke := _report.get("functional_smoke", {}) as Dictionary
	for raw in smoke.get("results", []) as Array:
		var item := raw as Dictionary
		if String(item.get("fixture_id", "")) == selected_id:
			return item
	return {}


func _refresh() -> void:
	if _campaign.is_empty() or _report.is_empty() or _plan.is_empty():
		_status_label.text = "[color=#ff5c4f][b]BLOCKED[/b][/color] 泛化活动、评估计划或保障报告缺失。"
		return
	var domains := _report.get("domain_summary", {}) as Dictionary
	var policy := _report.get("preserved_policy_inventory", {}) as Dictionary
	_status_label.text = (
		"[color=#86ff9b][b]FUNCTIONAL FRAMEWORK %s · 16/16 · %d PLANNED CELLS[/b][/color]  [color=#ffbd40]%s[/color]\n"
		+ "港口 %d（真实%d/合成%d）· 季节 %d（真实%d/叠加%d）· 船型族 %d · 种子 %d · 响应交通 %d · OOD %d · 消融 %d · 压力 %d\n"
		+ "既有策略哈希 %d/10 · training=false · convergence=false · real cross-port=false · shadow=false · 最近退出码=%d %s"
	) % ["PASS" if bool(_report.get("functional_framework_complete", false)) else "FAIL", int(_plan.get("total_planned_cell_count", 0)), _report.get("status", "--"), int(domains.get("declared_port_archetype_count", 0)), int(domains.get("real_observed_port_count", 0)), int(domains.get("synthetic_port_domain_count", 0)), int(domains.get("declared_season_count", 0)), int(domains.get("real_observed_season_count", 0)), int(domains.get("synthetic_season_overlay_count", 0)), int(domains.get("vessel_family_count", 0)), int(domains.get("random_seed_count", 0)), int(domains.get("interactive_traffic_behavior_count", 0)), int(domains.get("ood_suite_count", 0)), int(domains.get("ablation_count", 0)), int(domains.get("stress_case_count", 0)), int(policy.get("policy_count", 0)), _last_exit_code, _last_command_output.strip_edges()]
	_refresh_domain()
	_refresh_fixture()
	_refresh_gate()


func _refresh_domain() -> void:
	var item := _selected_domain()
	if item.is_empty():
		_domain_label.text = "--"
		return
	var lines: Array[String] = []
	for key in item:
		if key in ["domain_id", "name", "category"]:
			continue
		lines.append("• %s = %s" % [key, str(item[key])])
	_domain_label.text = "[color=#73f5ff][b]%s[/b][/color]\n%s · %s\n\n%s" % [item.get("domain_id", "--"), item.get("category", "--"), item.get("name", item.get("behavior", "--")), "\n".join(lines)]


func _refresh_fixture() -> void:
	var item := _selected_fixture()
	if item.is_empty():
		_fixture_label.text = "--"
		return
	_fixture_label.text = (
		"[color=#73f5ff][b]%s · %s[/b][/color]\n港口：%s\n季节：%s\n船型：%s\n交通：%s\n种子：%s\n\n45维观测：%s · 回执：%d · 哈希链：%s\n本船模型改动=%s · 策略改动=%s"
	) % [item.get("fixture_id", "--"), "PASS" if bool(item.get("passed", false)) else "FAIL", item.get("port_domain_id", "--"), item.get("season_domain_id", "--"), item.get("vessel_domain_id", "--"), item.get("traffic_domain_id", "--"), str(item.get("seed", "--")), str(item.get("observations_valid", false)), int(item.get("interaction_receipt_count", 0)), str(item.get("receipt_chain_valid", false)), str(item.get("own_ship_motion_model_modified", true)), str(item.get("policy_modified", true))]


func _refresh_gate() -> void:
	var gate := _report.get("results_evidence_gate", {}) as Dictionary
	var shadow := _report.get("shadow_receipt_smoke", {}) as Dictionary
	_gate_label.text = (
		"[color=#ffbd40][b]EVIDENCE BLOCKED[/b][/color]\n训练种子：%d/%d · 训练完成：%s\n收敛：%s · 矩阵：%s · 置信区间：%s\n真实港口：%d/3 · 真实季节：%d/4\nOOD：%s · 真实影子：%s\n\n只读影子功能烟测：%d 建议 / %d 下发\n当前缺口：[color=#ffbd40]%s[/color]\nproduction_authority=false"
	) % [int(gate.get("training_seed_count", 0)), int(gate.get("minimum_training_seed_count", 5)), str(gate.get("training_completed", false)), str(gate.get("convergence_demonstrated", false)), str(gate.get("matrix_complete", false)), str(gate.get("confidence_intervals_complete", false)), int(gate.get("real_port_domain_count", 0)), int(gate.get("real_season_domain_count", 0)), str(gate.get("ood_acceptance_passed", false)), str(gate.get("shadow_operation_completed", false)), int(shadow.get("recommendation_count", 0)), int(shadow.get("dispatch_count", 0)), _selected_gap if not _selected_gap.is_empty() else "点击浏览"]


func _on_domain_selected(_index: int) -> void:
	_refresh_domain()


func _on_fixture_selected(_index: int) -> void:
	_refresh_fixture()


func _next_fixture() -> void:
	if _fixture_option.item_count == 0:
		return
	_fixture_option.select((_fixture_option.selected + 1) % _fixture_option.item_count)
	_refresh_fixture()


func _next_gap() -> void:
	var gaps := [
		"至少3个真实港口数据包，目前1个",
		"至少4个真实季节，目前1个",
		"5随机种子统一长预算训练尚未运行",
		"320基础矩阵、20 OOD、30消融、40压力单元尚未执行",
		"逐种子曲线与95%分层配对bootstrap区间缺失",
		"不少于30天/1000场只读影子运行缺失",
		"独立评审与结果清单哈希缺失",
	]
	_gap_index %= gaps.size()
	_selected_gap = String(gaps[_gap_index])
	_gap_index = (_gap_index + 1) % gaps.size()
	_refresh_gate()


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

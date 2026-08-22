extends CanvasLayer

const TOGGLE_PANEL_KEY := KEY_M
const COLOR_BG := Color(0.008, 0.018, 0.027, 0.97)
const COLOR_PANEL := Color(0.025, 0.052, 0.068, 0.96)
const COLOR_ROW := Color(0.035, 0.075, 0.091, 0.96)
const COLOR_CYAN := Color(0.27, 0.94, 1.0, 1.0)
const COLOR_GREEN := Color(0.42, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.73, 0.25, 1.0)
const COLOR_RED := Color(1.0, 0.36, 0.31, 1.0)
const COLOR_TEXT := Color(0.84, 0.95, 1.0, 1.0)
const COLOR_MUTED := Color(0.55, 0.70, 0.77, 1.0)

@export var start_visible: bool = false
@export var rl_panel_path: NodePath = NodePath("../ShipRLControlPanel")
@export var navigation_panel_path: NodePath = NodePath("../ShipNavigationPlanningPanel")
@export var risk_panel_path: NodePath = NodePath("../ShipRiskDecisionPanel")
@export var weather_panel_path: NodePath = NodePath("../ShipWeatherSeaPanel")
@export var review_panel_path: NodePath = NodePath("../ShipSimulationReviewPanel")
@export var ais_panel_path: NodePath = NodePath("../ShipAISFleetPanel")
@export var instructor_panel_path: NodePath = NodePath("../ShipInstructorConsolePanel")

var _root: Control
var _dataset_label: RichTextLabel
var _matrix_box: VBoxContainer
var _advisor_label: RichTextLabel
var _status_label: Label
var _capture_output := ""
var _capture_frames := -1


func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_interface()
	set_process_unhandled_input(true)
	if OS.get_environment("SHIP_HR_EVIDENCE") == "1":
		_root.visible = true
	var screenshot_output := OS.get_environment("SHIP_SCREENSHOT_OUTPUT")
	if not screenshot_output.is_empty():
		_capture_output = screenshot_output
		_capture_frames = 90
		call_deferred("_prepare_capture_mode")


func _process(_delta: float) -> void:
	if _capture_frames < 0:
		return
	_capture_frames -= 1
	if _capture_frames == 0:
		_capture_current_view()


func _prepare_capture_mode() -> void:
	var mode := OS.get_environment("SHIP_HR_EVIDENCE_MODE")
	if mode == "training":
		_root.visible = false
		var training := _node(rl_panel_path)
		if training != null and training.has_method("show_training_center"):
			training.call("show_training_center")
	elif mode == "settings":
		_root.visible = false
		var training := _node(rl_panel_path)
		if training != null and training.has_method("show_training_center"):
			training.call("show_training_center")
			training.call("_on_training_parameters_pressed")
	elif mode == "assistant":
		_root.visible = false
		var assistant := _node(instructor_panel_path)
		if assistant != null and assistant.has_method("show_panel"):
			assistant.call("show_panel")
	elif mode == "navigation":
		_root.visible = false
		var player := get_node_or_null("../Player")
		if player != null and player.has_method("set_ship_agent_command"):
			player.call("set_ship_agent_command", 0.65, 0.12)
	else:
		_root.visible = true


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.physical_keycode == TOGGLE_PANEL_KEY:
			_root.visible = not _root.visible
			if _root.visible:
				_refresh_evidence()
			get_viewport().set_input_as_handled()


func show_panel() -> void:
	_root.visible = true
	_refresh_evidence()


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipHREvidenceRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = start_visible
	add_child(_root)

	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = COLOR_BG
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(backdrop)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_bottom", 20)
	_root.add_child(margin)

	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 12)
	margin.add_child(page)
	page.add_child(_build_header())

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 12)
	page.add_child(columns)

	var data_column := _column("训练与数据证据", "DATA + TRAINING", COLOR_CYAN)
	data_column.custom_minimum_size.x = 410.0
	data_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(data_column)
	_dataset_label = _rich_label("", 520.0)
	data_column.add_child(_dataset_label)
	data_column.add_child(_action_button("打开训练中心  ·  TRAINING CENTER", COLOR_CYAN, _open_training_center))
	data_column.add_child(_action_button("校验 v2 港口数据契约", COLOR_GREEN, _validate_port_contract))
	data_column.add_child(_action_button("航线规划 / 风险决策 / 海况", COLOR_AMBER, _open_navigation))
	data_column.add_child(_action_button("AIS 船队态势", COLOR_CYAN, _open_ais))

	var matrix_column := _column("十算法基准矩阵", "10 BASE POLICIES + ADDITIVE SAFETY V3", COLOR_GREEN)
	matrix_column.custom_minimum_size.x = 500.0
	matrix_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(matrix_column)
	_matrix_box = VBoxContainer.new()
	_matrix_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_matrix_box.add_theme_constant_override("separation", 7)
	matrix_column.add_child(_matrix_box)
	matrix_column.add_child(_small_note("原十策略与失败记录保留；Safety V3 仅作为并列组合策略。每个产物保留 checkpoint、SHA-256、独立验证与测试轨迹。"))
	matrix_column.add_child(_action_button("打开训练结果复盘", COLOR_GREEN, _open_review))

	var xiaoyi_column := _column("小懿训练顾问", "XIAOYI SYSTEM ADVISOR", COLOR_AMBER)
	xiaoyi_column.custom_minimum_size.x = 390.0
	xiaoyi_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(xiaoyi_column)
	var portrait_row := HBoxContainer.new()
	portrait_row.add_theme_constant_override("separation", 12)
	xiaoyi_column.add_child(portrait_row)
	var portrait := TextureRect.new()
	portrait.texture = load("res://assets/ui/xiaoyi/xiaoyi-maritime-officer.png")
	portrait.custom_minimum_size = Vector2(164.0, 184.0)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait_row.add_child(portrait)
	var identity := _rich_label("[font_size=19][color=#73f5ff]小懿 / XIAOYI[/color][/font_size]\n\n[color=#86ff9b]● 证据链在线[/color]\n训练顾问 · 系统联动\n港口适配 · 安全审查", 184.0)
	identity.custom_minimum_size.x = 185.0
	portrait_row.add_child(identity)
	_advisor_label = _rich_label("", 220.0)
	xiaoyi_column.add_child(_advisor_label)
	xiaoyi_column.add_child(_action_button("小懿全系统助手", COLOR_AMBER, _open_instructor))
	xiaoyi_column.add_child(_action_button("训练顾问：查看算法选择依据", COLOR_CYAN, _advisor_review))
	xiaoyi_column.add_child(_action_button("运行环境与数据边界审查", COLOR_GREEN, _boundary_review))

	_status_label = Label.new()
	_status_label.text = "M 打开/关闭证据中心  ·  所有按钮连接实际系统模块"
	_status_label.add_theme_color_override("font_color", COLOR_MUTED)
	_status_label.add_theme_font_size_override("font_size", 13)
	page.add_child(_status_label)
	_refresh_evidence()


func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.custom_minimum_size.y = 72.0
	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title_box)
	var title := Label.new()
	title.text = "PORT AI  ·  可落地船舶智能航行证据中心"
	title.add_theme_color_override("font_color", COLOR_TEXT)
	title.add_theme_font_size_override("font_size", 28)
	title_box.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "PORT-REPLACEABLE CONTRACT  /  HEADLESS TRAINING  /  HELD-OUT TEST  /  FAIL-CLOSED DEPLOYMENT"
	subtitle.add_theme_color_override("font_color", COLOR_CYAN)
	subtitle.add_theme_font_size_override("font_size", 13)
	title_box.add_child(subtitle)
	var pills := HBoxContainer.new()
	pills.add_theme_constant_override("separation", 8)
	header.add_child(pills)
	pills.add_child(_pill("v1 已冻结", COLOR_GREEN))
	pills.add_child(_pill("v2 AIS + ENC", COLOR_CYAN))
	pills.add_child(_pill("v3 安全监督", COLOR_GREEN))
	pills.add_child(_pill("实船控制未授权", COLOR_AMBER))
	var close_button := Button.new()
	close_button.text = "关闭  M"
	close_button.custom_minimum_size = Vector2(96.0, 36.0)
	close_button.pressed.connect(func() -> void: _root.visible = false)
	pills.add_child(close_button)
	return header


func _column(title_text: String, code_text: String, accent: Color) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = COLOR_PANEL
	panel_style.border_color = accent
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(9)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style)
	panel.custom_minimum_size.y = 62.0
	box.add_child(panel)
	var heading := VBoxContainer.new()
	heading.add_theme_constant_override("separation", 0)
	panel.add_child(heading)
	var title := Label.new()
	title.text = "  " + title_text
	title.add_theme_color_override("font_color", COLOR_TEXT)
	title.add_theme_font_size_override("font_size", 21)
	heading.add_child(title)
	var code := Label.new()
	code.text = "   " + code_text
	code.add_theme_color_override("font_color", accent)
	code.add_theme_font_size_override("font_size", 11)
	heading.add_child(code)
	return box


func _pill(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = "  " + text + "  "
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", 13)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(color.r, color.g, color.b, 0.12)
	style.border_color = Color(color.r, color.g, color.b, 0.65)
	style.set_border_width_all(1)
	style.set_corner_radius_all(14)
	label.add_theme_stylebox_override("normal", style)
	return label


func _rich_label(text: String, minimum_height: float) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = false
	label.custom_minimum_size.y = minimum_height
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	label.text = text
	label.add_theme_color_override("default_color", COLOR_TEXT)
	label.add_theme_font_size_override("normal_font_size", 14)
	return label


func _small_note(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", COLOR_MUTED)
	label.add_theme_font_size_override("font_size", 12)
	return label


func _action_button(text: String, accent: Color, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 38.0
	button.add_theme_color_override("font_color", accent)
	button.pressed.connect(callback)
	return button


func _refresh_evidence() -> void:
	if _dataset_label == null or _matrix_box == null or _advisor_label == null:
		return
	var v1 := _read_json("res://reports/navigation_benchmark_v1.json")
	var v2_contract := _read_json("res://reports/port_dataset_contract_v2.json")
	var v2 := _read_json("res://reports/port_ops_benchmark_v2.json")
	var v3 := _read_json("res://reports/safety_supervisor_benchmark_v3.json")
	var v3_utility := _read_json("res://reports/safety_supervisor_utility_audit_v3.json")
	var v1_data: Dictionary = v1.get("data", {})
	var split_sizes: Dictionary = v1_data.get("split_sizes", {})
	var contract_status := "构建中"
	var task_count := 0
	var ais_rows := 0
	var mmsi_count := 0
	var v2_splits: Dictionary = {}
	if not v2_contract.is_empty():
		contract_status = (
			"通过"
			if bool(v2_contract.get("research_training_ready", false))
			else "未通过"
		)
		task_count = int(v2_contract.get("task_count", 0))
		ais_rows = int(v2_contract.get("filtered_ais_rows", 0))
		mmsi_count = int(v2_contract.get("distinct_mmsi", 0))
		v2_splits = v2_contract.get("split_sizes", {})
	_dataset_label.text = (
		"[color=#73f5ff][b]v1 冻结可复核基准[/b][/color]\n"
		+ "Open-Meteo 2024 · %s 小时\n" % str(v1_data.get("hourly_rows", 0))
		+ "时序拆分 %s / %s / %s 场景\n" % [
			str(int(split_sizes.get("train", 0))),
			str(int(split_sizes.get("validation", 0))),
			str(int(split_sizes.get("test", 0)))
		]
		+ "旧证据：4 RL 共 80,480 step + LOS-PID\n\n"
		+ "[color=#86ff9b][b]v2 港口落地数据包[/b][/color]\n"
		+ "NOAA AccessAIS 2025 + NOAA ENC Direct\n"
		+ "Open-Meteo 海况/能见度/潮位 · 45维观测\n"
		+ "真实 AIS 航迹、船型尺度、动态交通\n"
		+ "%s AIS行 · %s MMSI · %d任务\n" % [
			_format_integer(ais_rows),
			_format_integer(mmsi_count),
			task_count
		]
		+ "时序拆分 %s / %s / %s · 7 RL + 3控制\n" % [
			str(int(v2_splits.get("train", 0))),
			str(int(v2_splits.get("validation", 0))),
			str(int(v2_splits.get("test", 0)))
		]
		+ "数据契约：%s · 10/10研究因素覆盖\n" % contract_status
		+ "策略库：10 原策略 + 10 Safety-V3 组合策略\n\n"
		+ "[color=#ffbd40]部署边界[/color]\n"
		+ "研究训练可用；实船控制默认 fail-closed。\n"
		+ "换港需通过数据契约与当地主管机关校核。"
	)
	for child in _matrix_box.get_children():
		child.queue_free()
	var artifacts: Array = v1.get("artifacts", [])
	for algorithm in ["ppo", "sac", "td3", "dqn", "a2c", "ddpg", "trpo", "los_pid", "lqr", "mpc"]:
		var artifact := _find_artifact(artifacts, algorithm)
		_matrix_box.add_child(_algorithm_row(algorithm, artifact, v2, v3))
	var v2_state := "待构建/训练"
	if not v2.is_empty():
		v2_state = "独立测试报告已生成"
	var v3_state := "验证中；原 V2 产物不变"
	if not v3.is_empty():
		var admission_source := v3_utility if not v3_utility.is_empty() else v3
		var admitted: Array = admission_source.get("admitted_offline_strategies", [])
		var passed := bool(admission_source.get("passed", v3.get("safety_effectiveness_gate", false)))
		v3_state = "%s · 离线准入 %d/10" % [
			"PASS" if passed else "FAIL-CLOSED",
			admitted.size()
		]
	_advisor_label.text = (
		"[b]当前建议[/b]\n"
		+ "v1 用于证明完整训练与可复核证据链；v2 用于证明真实港口数据适配能力。\n\n"
		+ "[b]算法选择[/b]\n"
		+ "v2 覆盖 PPO / SAC / TD3 / DQN / A2C / DDPG / TRPO，与 LOS-PID / LQR / MPC；不用单一“最好分数”代替安全门槛。\n\n"
		+ "[b]v2 状态[/b]\n%s\n\n" % v2_state
		+ "[b]Safety V3 状态[/b]\n%s\n\n" % v3_state
		+ "[color=#ffbd40]小懿不会把历史 AIS 回放描述成实时调度或实船控制。[/color]"
	)


func _algorithm_row(
	algorithm: String,
	artifact: Dictionary,
	v2_report: Dictionary,
	v3_report: Dictionary
) -> Control:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_ROW
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size.y = 42.0
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 9)
	panel.add_child(row)
	var name_label := Label.new()
	name_label.text = algorithm.to_upper().replace("_", "-")
	name_label.custom_minimum_size.x = 76.0
	var is_control := algorithm in ["los_pid", "lqr", "mpc"]
	name_label.add_theme_color_override("font_color", COLOR_AMBER if is_control else COLOR_CYAN)
	name_label.add_theme_font_size_override("font_size", 14)
	row.add_child(name_label)
	var details := Label.new()
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if artifact.is_empty():
		details.text = "v1 未纳入 · v2 可执行实现"
		details.add_theme_color_override("font_color", COLOR_MUTED)
	else:
		var test: Dictionary = artifact.get("test", artifact.get("validation", {}))
		var metrics: Dictionary = test.get("metrics", {})
		var training: Dictionary = artifact.get("training", {})
		var steps := int(training.get("actual_timesteps", 0))
		var safe_rate := float(metrics.get("safe_completion_rate", 0.0)) * 100.0
		var collisions := int(metrics.get("total_collisions", 0))
		details.text = "v1 TEST 安全到达 %4.1f%% · 碰撞 %d · %d step" % [safe_rate, collisions, steps]
		details.add_theme_color_override("font_color", COLOR_TEXT)
	row.add_child(details)
	var badge := Label.new()
	var has_v2 := _v2_has_algorithm(v2_report, algorithm)
	var has_v3 := _v3_has_algorithm(v3_report, algorithm)
	badge.text = "V2✓ V3✓" if has_v3 else ("V2✓ V3…" if has_v2 else "V2… V3…")
	badge.add_theme_color_override("font_color", COLOR_GREEN if has_v3 else (COLOR_AMBER if has_v2 else COLOR_MUTED))
	row.add_child(badge)
	return panel


func _find_artifact(artifacts: Array, algorithm: String) -> Dictionary:
	for entry in artifacts:
		if entry is Dictionary and String(entry.get("algorithm", "")) == algorithm:
			return entry
	return {}


func _v2_has_algorithm(report: Dictionary, algorithm: String) -> bool:
	var artifacts: Array = report.get("artifacts", [])
	return not _find_artifact(artifacts, algorithm).is_empty()


func _v3_has_algorithm(report: Dictionary, algorithm: String) -> bool:
	var results: Array = report.get("test_results", [])
	return not _find_artifact(results, algorithm).is_empty()


func _format_integer(value: int) -> String:
	var raw := str(value)
	var result := ""
	while raw.length() > 3:
		result = "," + raw.right(3) + result
		raw = raw.left(raw.length() - 3)
	return raw + result


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var value: Variant = JSON.parse_string(file.get_as_text())
	return value if value is Dictionary else {}


func _node(path: NodePath) -> Node:
	return get_node_or_null(path)


func _hide_self() -> void:
	_root.visible = false


func _open_training_center() -> void:
	var panel := _node(rl_panel_path)
	if panel != null and panel.has_method("show_training_center"):
		_hide_self()
		panel.call("show_training_center")


func _open_navigation() -> void:
	_hide_self()
	for path in [navigation_panel_path, risk_panel_path, weather_panel_path]:
		var panel := _node(path)
		if panel != null and panel.has_method("show_panel"):
			panel.call("show_panel")


func _open_ais() -> void:
	var panel := _node(ais_panel_path)
	if panel != null and panel.has_method("show_panel"):
		_hide_self()
		panel.call("show_panel")


func _open_review() -> void:
	var panel := _node(review_panel_path)
	if panel != null and panel.has_method("show_panel"):
		_hide_self()
		panel.call("show_panel")


func _open_instructor() -> void:
	var panel := _node(instructor_panel_path)
	if panel != null and panel.has_method("show_panel"):
		_hide_self()
		panel.call("show_panel")


func _advisor_review() -> void:
	_status_label.text = "小懿建议：先比较 held-out test 的安全完成、碰撞/搁浅/COLREG/航道违例，再比较效率。"


func _boundary_review() -> void:
	_status_label.text = "边界审查：历史 AIS + 公开 ENC 可做研究训练；实船控制需实时数据、官方航海产品、硬件联调与人工授权。"


func _validate_port_contract() -> void:
	var python_path := ProjectSettings.globalize_path("res://.venv/bin/python")
	var script_path := ProjectSettings.globalize_path("res://tools/validate_port_package.py")
	var data_path := ProjectSettings.globalize_path("res://data/rl/long_beach_ais_port_ops_benchmark_v2.json")
	if not FileAccess.file_exists(data_path):
		_status_label.text = "v2 数据包尚未生成；请先运行公开数据构建命令。"
		return
	var process_id := OS.create_process(
		python_path,
		PackedStringArray([script_path, data_path, "--require-research-ready"])
	)
	_status_label.text = "已启动真实契约校验进程 PID %d；结果写入终端与报告。" % process_id


func _capture_current_view() -> void:
	var viewport_texture := get_viewport().get_texture()
	if viewport_texture == null:
		push_error("Screenshot requires a rendering display")
		get_tree().quit()
		return
	var image := viewport_texture.get_image()
	if image == null:
		push_error("Screenshot image is unavailable")
		get_tree().quit()
		return
	var error := image.save_png(_capture_output)
	if error != OK:
		push_error("Screenshot save failed: %s" % error_string(error))
	get_tree().quit()

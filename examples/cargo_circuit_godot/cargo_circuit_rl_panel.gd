extends CanvasLayer
class_name CargoCircuitRLPanel

const TOGGLE_PANEL_KEY := KEY_H
const CONFIG_PATH := "res://data/rl/cargo_circuit_experiment_v1.json"
const TRAINING_SCRIPT := "res://tools/cargo_rl_train.py"
const MANUAL_FEASIBILITY_SCRIPT := "res://tools/cargo_rl_manual_feasibility.py"
const MANUAL_FEASIBILITY_REPORT := "res://reports/cargo_circuit_manual_feasibility_v1.json"
const MANUAL_FEASIBILITY_TRAJECTORY := RELEASE_DIR + "/manual_feasibility_trajectory.json"
const RELEASE_DIR := "res://reports/artifacts/cargo_circuit_rl_v1"
const RELEASE_CHECKPOINT := RELEASE_DIR + "/cargo_policy_checkpoint.json"
const RELEASE_TRAJECTORY := RELEASE_DIR + "/cargo_policy_test_trajectory.json"
const DYNAMIC_CONFIG_PATH := "res://data/rl/cargo_circuit_dynamic_experiment_v2.json"
const DYNAMIC_RELEASE_DIR := "res://reports/artifacts/cargo_circuit_dynamic_rl_v2"
const DYNAMIC_RELEASE_CHECKPOINT := DYNAMIC_RELEASE_DIR + "/cargo_dynamic_policy_checkpoint.json"
const DYNAMIC_RELEASE_TRAJECTORY := DYNAMIC_RELEASE_DIR + "/cargo_dynamic_policy_test_trajectory.json"
const USER_ROOT := "user://cargo_rl"
const LATEST_MANIFEST := USER_ROOT + "/latest_run.json"
const STRATEGY_STATIC_SAC := 0
const STRATEGY_DYNAMIC_RESIDUAL_SAC := 1
const STRATEGY_MANUAL_FEASIBILITY := 2
const STRATEGY_PERSONAL_LATEST := 3
const HUB_MODULES := [
	{"label": "进入 RL 训练中心", "node": "ShipRLControlPanel", "method": "show_training_center"},
	{"label": "航线规划", "node": "ShipNavigationPlanningPanel", "method": "show_panel"},
	{"label": "风险决策", "node": "ShipRiskDecisionPanel", "method": "show_panel"},
	{"label": "海况与时间", "node": "ShipWeatherSeaPanel", "method": "show_panel"},
	{"label": "AIS 船队态势", "node": "ShipAISFleetPanel", "method": "show_panel"},
	{"label": "训练与仿真复盘", "node": "ShipSimulationReviewPanel", "method": "show_panel"},
	{"label": "小懿系统助手", "node": "ShipInstructorConsolePanel", "method": "show_panel"},
	{"label": "证据与指标中心", "node": "ShipHREvidenceCenter", "method": "show_panel"},
]

@export var replay_controller_path: NodePath = NodePath("../CargoCircuitReplayController")
@export var start_visible: bool = false

var _root: Control
var _panel: PanelContainer
var _algorithm_option: OptionButton
var _timesteps_spin: SpinBox
var _camera_mode_option: OptionButton
var _strategy_option: OptionButton
var _status_label: Label
var _metrics_label: Label
var _progress_bar: ProgressBar
var _train_button: Button
var _manual_gate_button: Button
var _validation_button: Button
var _test_button: Button
var _play_button: Button
var _dynamic_test_button: Button
var _stop_button: Button
var _hub_return_root: Control
var _hub_return_button: Button
var _active_hub_module: Node
var _replay_controller: CargoCircuitReplayController
var _process_id := -1
var _operation := ""
var _split := ""
var _poll_left := 0.0
var _run_dir := ""
var _progress_path := ""
var _checkpoint_path := ""
var _trajectory_path := ""
var _evidence_path := ""
var _latest_personal_run_dir := ""
var _latest_personal_checkpoint_path := ""
var _latest_personal_trajectory_path := ""
var _latest_personal_evidence_path := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 100
	_build_interface()
	_build_hub_return_overlay()
	_resolve_replay_controller()
	_apply_presentation_selection()
	_load_latest_run()
	set_process(true)
	set_process_unhandled_input(true)


func _process(delta: float) -> void:
	if _process_id <= 0:
		return
	_poll_left -= delta
	if _poll_left <= 0.0 and _operation != "manual_feasibility":
		_poll_left = 0.25
		_apply_progress(_read_json(_progress_path))
	if OS.is_process_running(_process_id):
		return
	var exit_code := OS.get_process_exit_code(_process_id)
	_process_id = -1
	var result := _read_json(_progress_path)
	if _operation != "manual_feasibility":
		_apply_progress(result)
	_set_buttons_enabled(true)
	if _operation == "manual_feasibility":
		var gate := result.get("acceptance_gate", {}) as Dictionary
		if exit_code == 0 and bool(gate.get("passed", false)):
			var aggregate := result.get("aggregate", {}) as Dictionary
			_status_label.text = "● 人工可达性 PASS  episodes=%d  collision=%d  min_clearance=%.2fm" % [
				int(aggregate.get("episodes", 0)),
				int(aggregate.get("total_collisions", 0)),
				float(aggregate.get("minimum_safety_envelope_clearance_meters", 0.0)),
			]
		else:
			_status_label.text = "● 人工可达性 BLOCKED  任务或动力学未通过，RL 训练保持禁用"
		return
	if exit_code != 0 or String(result.get("status", "")) != "complete":
		_status_label.text = "● FAILED  %s" % String(result.get("error", "后台进程失败"))
		return
	if _operation == "train":
		_write_latest_manifest()
		_refresh_strategy_options()
		_status_label.text = "● 训练完成  checkpoint 已保存；下一步点击“验证策略”"
		_validation_button.disabled = false
		_test_button.disabled = false
	elif _split == "validation":
		var metrics := result.get("evaluation_metrics", {}) as Dictionary
		_status_label.text = "● 验证完成（无渲染）  success=%s  检查点=%d/%d  collision=%d" % [
			str(bool(metrics.get("success", false))),
			int(metrics.get("checkpoints_passed", 0)),
			int(metrics.get("total_checkpoints", 0)),
			int(metrics.get("collisions", 0)),
		]
	else:
		var gate := result.get("acceptance_gate", {}) as Dictionary
		if bool(gate.get("passed", false)):
			if _operation == "evaluate":
				_write_latest_manifest()
				_refresh_strategy_options()
			_status_label.text = "● TEST PASS  测试轨迹已生成，开始可视化"
			_play_button.disabled = false
			_start_replay(_trajectory_path)
		else:
			_status_label.text = "● TEST BLOCKED  策略未满足全检查点/零碰撞/正净距门槛，不渲染失败策略"


func _unhandled_input(event: InputEvent) -> void:
	if event is not InputEventKey:
		return
	var key_event := event as InputEventKey
	if key_event.pressed and not key_event.echo and key_event.physical_keycode == TOGGLE_PANEL_KEY:
		if _hub_return_root != null and _hub_return_root.visible:
			_return_to_hub()
		elif _root.visible:
			_root.visible = false
		else:
			_show_hub()
		get_viewport().set_input_as_handled()


func show_panel() -> void:
	_show_hub()


func _show_hub() -> void:
	_hide_all_hub_modules()
	_active_hub_module = null
	if _hub_return_root != null:
		_hub_return_root.visible = false
	_refresh_strategy_options()
	_root.visible = true


func _open_hub_module(node_name: String, method_name: String, title: String) -> void:
	var target := get_parent().get_node_or_null(NodePath(node_name))
	if target == null:
		_status_label.text = "● BLOCKED  总控找不到模块：%s" % title
		return
	_hide_all_hub_modules()
	_root.visible = false
	_active_hub_module = target
	if target.has_method(method_name):
		target.call(method_name)
	else:
		var target_root = target.get("_root")
		if target_root is Control:
			(target_root as Control).visible = true
	if _hub_return_button != null:
		_hub_return_button.text = "← 返回 H 总控｜当前：%s" % title
	if _hub_return_root != null:
		_hub_return_root.visible = true


func _return_to_hub() -> void:
	_hide_all_hub_modules()
	_active_hub_module = null
	if _hub_return_root != null:
		_hub_return_root.visible = false
	_refresh_strategy_options()
	_root.visible = true


func _hide_all_hub_modules() -> void:
	for module in HUB_MODULES:
		var record := module as Dictionary
		var target := get_parent().get_node_or_null(NodePath(String(record["node"])))
		if target == null:
			continue
		if target.has_method("hide_panel"):
			target.call("hide_panel")
			continue
		var target_root = target.get("_root")
		if target_root is Control:
			(target_root as Control).visible = false


func _build_hub_return_overlay() -> void:
	_hub_return_root = Control.new()
	_hub_return_root.name = "HubReturnRoot"
	_hub_return_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hub_return_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hub_return_button = _button("← 返回 H 总控", _return_to_hub)
	_hub_return_button.anchor_left = 1.0
	_hub_return_button.anchor_right = 1.0
	_hub_return_button.offset_left = -310.0
	_hub_return_button.offset_top = 22.0
	_hub_return_button.offset_right = -22.0
	_hub_return_button.offset_bottom = 66.0
	_hub_return_button.mouse_filter = Control.MOUSE_FILTER_STOP
	_hub_return_root.add_child(_hub_return_button)
	_hub_return_root.visible = false
	add_child(_hub_return_root)


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "CargoCircuitRLRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	var shade := ColorRect.new()
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.0, 0.01, 0.02, 0.50)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(shade)
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.position = Vector2(-460.0, -450.0)
	_panel.size = Vector2(920.0, 900.0)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.012, 0.026, 0.036, 0.98)
	style.border_color = Color(0.23, 0.92, 1.0, 0.92)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		style.set_content_margin(side, 22.0)
	_panel.add_theme_stylebox_override("panel", style)
	_root.add_child(_panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = 850.0
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 10)
	scroll.add_child(box)
	var title := _label("H 总控核心 · 真实 RL 环图取货系统", 25, Color(0.37, 0.98, 1.0))
	box.add_child(title)
	box.add_child(_label("CARGO CIRCUIT RL  //  HEADLESS TRAIN → HELD-OUT TEST → GODOT REPLAY", 11, Color(0.58, 0.75, 0.81)))
	var boundary := _label(
		"训练只运行数值环境，render=false；Godot 只播放通过门槛的 test split 轨迹。\n所有训练、航线、风险、海况、AIS、复盘和证据功能统一从本总控出发。",
		13,
		Color(0.78, 0.92, 0.98)
	)
	boundary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(boundary)

	var hub_card := _card()
	var hub_box := VBoxContainer.new()
	hub_box.add_theme_constant_override("separation", 7)
	hub_card.add_child(hub_box)
	hub_box.add_child(_label("全系统模块入口 · 子面板右上角可返回 H", 15, Color(1.0, 0.76, 0.30)))
	var hub_grid := GridContainer.new()
	hub_grid.columns = 4
	hub_grid.add_theme_constant_override("h_separation", 8)
	hub_grid.add_theme_constant_override("v_separation", 7)
	for module in HUB_MODULES:
		var record := module as Dictionary
		var hub_button := _button(String(record["label"]), _open_hub_module.bind(
			String(record["node"]), String(record["method"]), String(record["label"])
		))
		hub_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hub_button.custom_minimum_size = Vector2(195.0, 38.0)
		hub_grid.add_child(hub_button)
	hub_box.add_child(hub_grid)
	box.add_child(hub_card)

	var decision := _card()
	var decision_box := VBoxContainer.new()
	decision.add_child(decision_box)
	decision_box.add_child(_label("算法结论", 15, Color(1.0, 0.76, 0.30)))
	decision_box.add_child(_label("SAC 是已验收主策略；PPO / TD3 / A2C / DDPG / TQC / TRPO 均接入真实训练入口，但尚无冻结验收结果。", 12, Color(0.76, 0.90, 0.96)))
	decision_box.add_child(_label("观测 36D  |  动作 2D [-1,1]  |  最大转向 20°/s  |  舵响应 0.7/s  |  加速度 0.9m/s²", 12, Color(0.48, 1.0, 0.60)))
	decision_box.add_child(_label("静态 v1：30万步 SAC 已通过  |  动态 v2：冻结静态策略 + 残差 SAC，6 艘移动交通已通过", 12, Color(1.0, 0.72, 0.30)))
	box.add_child(decision)

	var settings := HBoxContainer.new()
	settings.add_theme_constant_override("separation", 12)
	settings.add_child(_label("算法", 13, Color(0.68, 0.86, 0.92)))
	_algorithm_option = OptionButton.new()
	var algorithms := [
		["SAC｜主策略·已有验收产物", "sac"],
		["PPO｜成熟对照·可训练", "ppo"],
		["TD3｜双延迟确定性·可训练", "td3"],
		["A2C｜轻量 Actor-Critic·可训练", "a2c"],
		["DDPG｜确定性连续控制·可训练", "ddpg"],
		["TQC｜截断分位数评论家·可训练", "tqc"],
		["TRPO｜信赖域策略优化·可训练", "trpo"],
	]
	for index in range(algorithms.size()):
		var algorithm := algorithms[index] as Array
		_algorithm_option.add_item(String(algorithm[0]))
		_algorithm_option.set_item_metadata(index, String(algorithm[1]))
	_algorithm_option.item_selected.connect(_on_algorithm_selected)
	_algorithm_option.custom_minimum_size = Vector2(310.0, 36.0)
	settings.add_child(_algorithm_option)
	settings.add_child(_label("真实训练步数", 13, Color(0.68, 0.86, 0.92)))
	_timesteps_spin = SpinBox.new()
	_timesteps_spin.min_value = 50000
	_timesteps_spin.max_value = 1000000
	_timesteps_spin.step = 50000
	_timesteps_spin.value = 300000
	_timesteps_spin.custom_minimum_size = Vector2(165.0, 36.0)
	settings.add_child(_timesteps_spin)
	box.add_child(settings)

	var strategy_card := _card()
	var strategy_box := VBoxContainer.new()
	strategy_box.add_theme_constant_override("separation", 7)
	strategy_card.add_child(strategy_box)
	strategy_box.add_child(_label("策略选择与可视化 · 名称区分验收状态", 15, Color(1.0, 0.76, 0.30)))
	var strategy_row := HBoxContainer.new()
	strategy_row.add_theme_constant_override("separation", 8)
	_strategy_option = OptionButton.new()
	_strategy_option.add_item("SAC-S1｜静态悬岩环航取货｜TEST PASS", STRATEGY_STATIC_SAC)
	_strategy_option.add_item("RES-SAC-D2｜动态交通避障取货｜TEST PASS", STRATEGY_DYNAMIC_RESIDUAL_SAC)
	_strategy_option.add_item("MANUAL-F0｜人工物理可达性基线｜非 RL", STRATEGY_MANUAL_FEASIBILITY)
	_strategy_option.add_item("PERSONAL-LATEST｜尚无个人训练产物", STRATEGY_PERSONAL_LATEST)
	_strategy_option.set_item_disabled(STRATEGY_PERSONAL_LATEST, true)
	_strategy_option.custom_minimum_size = Vector2(430.0, 38.0)
	_strategy_option.item_selected.connect(_on_strategy_selected)
	strategy_row.add_child(_strategy_option)
	_play_button = _button("播放所选策略", _on_play_selected_strategy_pressed)
	_stop_button = _button("停止并恢复原场景", _on_stop_pressed)
	strategy_row.add_child(_play_button)
	strategy_row.add_child(_stop_button)
	for speed in [1.0, 3.0, 5.0]:
		var speed_button := _button("%.0fx" % speed, _on_speed_pressed.bind(speed))
		speed_button.custom_minimum_size = Vector2(52.0, 38.0)
		strategy_row.add_child(speed_button)
	strategy_box.add_child(strategy_row)
	box.add_child(strategy_card)

	var presentation := _card()
	var presentation_box := VBoxContainer.new()
	presentation_box.add_theme_constant_override("separation", 7)
	presentation.add_child(presentation_box)
	presentation_box.add_child(_label("演示镜头与无人艇", 15, Color(1.0, 0.76, 0.30)))
	var presentation_row := HBoxContainer.new()
	presentation_row.add_theme_constant_override("separation", 10)
	presentation_row.add_child(_label("镜头", 13, Color(0.68, 0.86, 0.92)))
	_camera_mode_option = OptionButton.new()
	_camera_mode_option.add_item("自动跟随旋转")
	_camera_mode_option.add_item("自由镜头（不跟随）")
	_camera_mode_option.custom_minimum_size = Vector2(190.0, 36.0)
	_camera_mode_option.item_selected.connect(_on_camera_mode_selected)
	presentation_row.add_child(_camera_mode_option)
	presentation_row.add_child(_label("船体  3D内置双体无人艇（固定）", 13, Color(0.48, 1.0, 0.60)))
	presentation_box.add_child(presentation_row)
	var presentation_hint := _label(
		"自动镜头：船尾跟随船首；A/D、R/F优先人工接管。无人艇：双体船+雷达+光电云台+航行灯+双推进器。",
		11,
		Color(0.58, 0.82, 0.88)
	)
	presentation_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	presentation_box.add_child(presentation_hint)
	box.add_child(presentation)

	var primary_row := HBoxContainer.new()
	primary_row.add_theme_constant_override("separation", 9)
	_manual_gate_button = _button("0  人工物理可达性验收", _on_manual_gate_pressed)
	_train_button = _button("1  启动无渲染训练", _on_train_pressed)
	_validation_button = _button("2  验证策略（不渲染）", _on_validation_pressed)
	_test_button = _button("3  测试并生成可视化", _on_test_pressed)
	for button in [_manual_gate_button, _train_button, _validation_button, _test_button]:
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		primary_row.add_child(button)
	box.add_child(primary_row)

	var dynamic_row := HBoxContainer.new()
	dynamic_row.add_theme_constant_override("separation", 9)
	_dynamic_test_button = _button("4  重测动态策略（无渲染→播放）", _on_dynamic_test_pressed)
	_dynamic_test_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dynamic_row.add_child(_dynamic_test_button)
	box.add_child(dynamic_row)

	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 100.0
	_progress_bar.value = 0.0
	_progress_bar.custom_minimum_size.y = 20.0
	box.add_child(_progress_bar)
	_status_label = _label("就绪：可直接播放随项目交付的通过测试策略，或重新训练生成个人运行产物。", 13, Color(0.90, 0.96, 1.0))
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status_label)
	_metrics_label = _label("", 12, Color(0.58, 0.78, 0.84))
	_metrics_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_metrics_label)
	var close_button := _button("关闭面板（H）", func() -> void: _root.visible = false)
	box.add_child(close_button)
	_root.visible = start_visible


func _on_manual_gate_pressed() -> void:
	if _process_id > 0:
		return
	_operation = "manual_feasibility"
	_split = "all"
	_progress_path = ProjectSettings.globalize_path(MANUAL_FEASIBILITY_REPORT)
	var arguments := PackedStringArray([
		ProjectSettings.globalize_path(MANUAL_FEASIBILITY_SCRIPT),
		"--config", ProjectSettings.globalize_path(CONFIG_PATH),
		"--report", _progress_path,
		"--trajectory", ProjectSettings.globalize_path(MANUAL_FEASIBILITY_TRAJECTORY),
	])
	_process_id = OS.create_process(_python_executable(), arguments)
	if _process_id <= 0:
		_status_label.text = "● FAILED  无法启动人工可达性后端"
		return
	_status_label.text = "● RUNNING  人工舵令正在遍历 train / validation / test；这不是 RL 证据"
	_metrics_label.text = "相同动力学、悬岩膨胀、海况和边界；要求全部检查点、零碰撞、正净距"
	_set_buttons_enabled(false)


func _on_train_pressed() -> void:
	if _process_id > 0:
		return
	var stamp := Time.get_datetime_string_from_system().replace("-", "").replace(":", "").replace("T", "_")
	_run_dir = ProjectSettings.globalize_path(USER_ROOT.path_join("run_" + stamp))
	DirAccess.make_dir_recursive_absolute(_run_dir)
	_progress_path = _run_dir.path_join("progress.json")
	_checkpoint_path = _run_dir.path_join("cargo_policy_checkpoint.json")
	_trajectory_path = _run_dir.path_join("cargo_policy_test_trajectory.json")
	_evidence_path = _run_dir.path_join("cargo_circuit_rl_evidence.json")
	_operation = "train"
	_split = "train"
	var args := _base_args()
	args.append_array(PackedStringArray([
		"--mode", "train",
		"--algorithm", _selected_algorithm(),
		"--total-timesteps", str(int(_timesteps_spin.value)),
		"--steps", "2400",
		"--agents", "1",
		"--output-dir", _run_dir,
		"--progress-json", _progress_path,
		"--checkpoint-json", _checkpoint_path,
		"--trajectory-json", _trajectory_path,
		"--evidence-json", _evidence_path,
	]))
	_launch(args, "已启动真实无渲染训练：split=train，Godot 不参与环境采样")


func _on_algorithm_selected(index: int) -> void:
	var algorithm := String(_algorithm_option.get_item_metadata(index)).to_upper()
	if algorithm == "SAC":
		_status_label.text = "SAC 已选择：可重新训练；项目内静态与动态冻结策略已有独立 TEST PASS 证据"
	else:
		_status_label.text = "%s 已选择：已连接真实无渲染训练入口；当前没有冻结验收策略，训练后仍须验证和 test" % algorithm


func _on_strategy_selected(index: int) -> void:
	var strategy_name := _strategy_option.get_item_text(index)
	_status_label.text = "策略已选：%s" % strategy_name


func _on_play_selected_strategy_pressed() -> void:
	match _strategy_option.get_selected_id():
		STRATEGY_STATIC_SAC:
			_start_replay(RELEASE_TRAJECTORY)
		STRATEGY_DYNAMIC_RESIDUAL_SAC:
			_on_dynamic_play_pressed()
		STRATEGY_MANUAL_FEASIBILITY:
			_on_manual_play_pressed()
		STRATEGY_PERSONAL_LATEST:
			if _strict_trajectory_passed(_latest_personal_trajectory_path):
				_start_replay(_latest_personal_trajectory_path)
			else:
				_status_label.text = "● BLOCKED  最近个人策略尚未通过 test 门槛，不能可视化"


func _on_camera_mode_selected(_index: int) -> void:
	_apply_presentation_selection()
	_status_label.text = "镜头已选：%s；策略播放中也可即时切换" % _camera_mode_option.get_item_text(_camera_mode_option.selected)


func _apply_presentation_selection() -> void:
	_resolve_replay_controller()
	if _replay_controller == null or _camera_mode_option == null:
		return
	_replay_controller.set_replay_camera_mode("auto_follow" if _camera_mode_option.selected == 0 else "free_camera")


func _on_validation_pressed() -> void:
	_start_evaluation("validation")


func _on_test_pressed() -> void:
	_start_evaluation("test")


func _start_evaluation(split_name: String) -> void:
	if _process_id > 0:
		return
	var checkpoint := _active_checkpoint()
	if checkpoint.is_empty():
		_status_label.text = "● BLOCKED  未找到训练检查点，请先训练或确认 release artifact 存在"
		return
	if _run_dir.is_empty():
		_run_dir = ProjectSettings.globalize_path(USER_ROOT.path_join("evaluation_latest"))
		DirAccess.make_dir_recursive_absolute(_run_dir)
	_progress_path = _run_dir.path_join("%s_progress.json" % split_name)
	_trajectory_path = _run_dir.path_join("cargo_policy_%s_trajectory.json" % split_name)
	_evidence_path = _run_dir.path_join("cargo_circuit_rl_evidence.json")
	_checkpoint_path = checkpoint
	_operation = "evaluate"
	_split = split_name
	var checkpoint_data := _read_json(checkpoint)
	var algorithm := String(checkpoint_data.get("algorithm", _selected_algorithm()))
	var args := _base_args()
	args.append_array(PackedStringArray([
		"--mode", "evaluate",
		"--algorithm", algorithm,
		"--eval-split", split_name,
		"--eval-episodes", "1",
		"--steps", "2400",
		"--output-dir", _run_dir,
		"--progress-json", _progress_path,
		"--checkpoint-json", checkpoint,
		"--trajectory-json", _trajectory_path,
		"--evidence-json", _evidence_path,
	]))
	_launch(args, "正在运行 %s split 确定性评估；render=false" % split_name)


func _on_play_pressed() -> void:
	var trajectory := _active_trajectory()
	if trajectory.is_empty():
		_status_label.text = "● BLOCKED  没有通过门槛的测试轨迹"
		return
	_start_replay(trajectory)


func _on_manual_play_pressed() -> void:
	_resolve_replay_controller()
	if _replay_controller == null:
		_status_label.text = "● BLOCKED  独立回放控制器未就绪"
		return
	if _replay_controller.start_manual_feasibility_replay():
		_root.visible = false
	else:
		_status_label.text = "● BLOCKED  人工可达性报告或轨迹未通过"


func _on_dynamic_test_pressed() -> void:
	if _process_id > 0:
		return
	var stamp := Time.get_datetime_string_from_system().replace("-", "").replace(":", "").replace("T", "_")
	_run_dir = ProjectSettings.globalize_path(USER_ROOT.path_join("dynamic_test_" + stamp))
	DirAccess.make_dir_recursive_absolute(_run_dir)
	_progress_path = _run_dir.path_join("dynamic_test_progress.json")
	_trajectory_path = _run_dir.path_join("cargo_dynamic_policy_test_trajectory.json")
	_evidence_path = _run_dir.path_join("cargo_dynamic_rl_evidence.json")
	_operation = "dynamic_evaluate"
	_split = "test"
	var args := PackedStringArray([
		ProjectSettings.globalize_path(TRAINING_SCRIPT),
		"--config", ProjectSettings.globalize_path(DYNAMIC_CONFIG_PATH),
		"--mode", "evaluate",
		"--algorithm", "sac",
		"--eval-split", "test",
		"--eval-episodes", "1",
		"--steps", "2600",
		"--output-dir", _run_dir,
		"--progress-json", _progress_path,
		"--checkpoint-json", ProjectSettings.globalize_path(DYNAMIC_RELEASE_CHECKPOINT),
		"--trajectory-json", _trajectory_path,
		"--evidence-json", _evidence_path,
	])
	_launch(args, "正在重测动态 v2：6 艘移动交通，render=false")


func _on_dynamic_play_pressed() -> void:
	_resolve_replay_controller()
	if _replay_controller == null:
		_status_label.text = "● BLOCKED  独立回放控制器未就绪"
		return
	if _replay_controller.start_dynamic_replay(DYNAMIC_RELEASE_TRAJECTORY):
		_root.visible = false
	else:
		_status_label.text = "● BLOCKED  动态测试轨迹未通过严格门槛"


func _on_stop_pressed() -> void:
	if _replay_controller != null:
		_replay_controller.stop_replay(true)
	_status_label.text = "已停止独立回放并恢复原自动航行场景"


func _on_speed_pressed(speed: float) -> void:
	if _replay_controller != null:
		_replay_controller.set_playback_speed(speed)
	_status_label.text = "回放速度已设为 %.0fx；只改变展示速度，不改变测试指标" % speed


func _start_replay(path_value: String) -> void:
	_resolve_replay_controller()
	if _replay_controller == null:
		_status_label.text = "● BLOCKED  独立回放控制器未就绪"
		return
	if _replay_controller.start_replay(path_value):
		_root.visible = false
	else:
		_status_label.text = "● BLOCKED  轨迹未通过严格测试门槛"


func _launch(arguments: PackedStringArray, message: String) -> void:
	_process_id = OS.create_process(_python_executable(), arguments)
	if _process_id <= 0:
		_status_label.text = "● FAILED  无法启动 Python RL 后端，请先运行 bash tools/setup_rl_env.sh"
		return
	_poll_left = 0.0
	_progress_bar.value = 0.0
	_status_label.text = "● RUNNING  " + message
	_set_buttons_enabled(false)


func _base_args() -> PackedStringArray:
	return PackedStringArray([
		ProjectSettings.globalize_path(TRAINING_SCRIPT),
		"--config", ProjectSettings.globalize_path(CONFIG_PATH),
	])


func _python_executable() -> String:
	var project_root := ProjectSettings.globalize_path("res://")
	var virtual_python := project_root.path_join(".venv/bin/python")
	if FileAccess.file_exists(virtual_python):
		return virtual_python
	return "python3"


func _selected_algorithm() -> String:
	return String(_algorithm_option.get_item_metadata(_algorithm_option.selected))


func _active_checkpoint() -> String:
	if not _checkpoint_path.is_empty() and FileAccess.file_exists(_checkpoint_path):
		return _checkpoint_path
	if FileAccess.file_exists(RELEASE_CHECKPOINT):
		return ProjectSettings.globalize_path(RELEASE_CHECKPOINT)
	return ""


func _active_trajectory() -> String:
	if not _trajectory_path.is_empty() and _strict_trajectory_passed(_trajectory_path):
		return _trajectory_path
	if _strict_trajectory_passed(RELEASE_TRAJECTORY):
		return RELEASE_TRAJECTORY
	return ""


func _strict_trajectory_passed(path_value: String) -> bool:
	var data := _read_json(path_value)
	var gate := data.get("acceptance_gate", {}) as Dictionary
	return String(data.get("format", "")) == "cargo_circuit_test_rollout_v1" \
		and String(data.get("dataset_split", "")) == "test" \
		and bool(data.get("trained_rl", false)) \
		and bool(gate.get("passed", false))


func _apply_progress(data: Dictionary) -> void:
	if data.is_empty():
		return
	var progress := clampf(float(data.get("progress", 0.0)), 0.0, 1.0)
	_progress_bar.value = progress * 100.0
	var last := data.get("last", {}) as Dictionary
	var completed := int(data.get("completed_timesteps", data.get("completed_episodes", 0)))
	var total := int(data.get("total_timesteps", data.get("total_episodes", 1)))
	_metrics_label.text = (
		"stage=%s  split=%s  render=false  progress=%.1f%%\n"
		+ "sample/episode=%d/%d  reward20=%.2f  success20=%.1f%%  checkpoint=%d/%d  collision=%d"
	) % [
		String(data.get("stage", "--")),
		String(data.get("dataset_split", _split)),
		progress * 100.0,
		completed,
		maxi(total, 1),
		float(data.get("mean_reward_20", last.get("reward", 0.0))),
		float(data.get("success_rate_20", 0.0)) * 100.0,
		int(last.get("checkpoints_passed", 0)),
		int(last.get("total_checkpoints", 7)),
		int(last.get("collisions", 0)),
	]


func _set_buttons_enabled(enabled: bool) -> void:
	_manual_gate_button.disabled = not enabled
	_train_button.disabled = not enabled
	_validation_button.disabled = not enabled
	_test_button.disabled = not enabled
	_play_button.disabled = not enabled
	_dynamic_test_button.disabled = not enabled


func _write_latest_manifest() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(USER_ROOT))
	var file := FileAccess.open(LATEST_MANIFEST, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"run_dir": _run_dir,
		"checkpoint": _checkpoint_path,
		"trajectory": _trajectory_path,
		"evidence": _evidence_path,
	}, "  "))
	file.close()
	_latest_personal_run_dir = _run_dir
	_latest_personal_checkpoint_path = _checkpoint_path
	_latest_personal_trajectory_path = _trajectory_path
	_latest_personal_evidence_path = _evidence_path


func _load_latest_run() -> void:
	var data := _read_json(LATEST_MANIFEST)
	if data.is_empty():
		_refresh_strategy_options()
		return
	_latest_personal_run_dir = String(data.get("run_dir", ""))
	_latest_personal_checkpoint_path = String(data.get("checkpoint", ""))
	_latest_personal_trajectory_path = String(data.get("trajectory", ""))
	_latest_personal_evidence_path = String(data.get("evidence", ""))
	_run_dir = _latest_personal_run_dir
	_checkpoint_path = _latest_personal_checkpoint_path
	_trajectory_path = _latest_personal_trajectory_path
	_evidence_path = _latest_personal_evidence_path
	_refresh_strategy_options()


func _refresh_strategy_options() -> void:
	if _strategy_option == null:
		return
	var checkpoint := _read_json(_latest_personal_checkpoint_path)
	var algorithm := String(checkpoint.get("algorithm", "--")).to_upper()
	var run_name := _latest_personal_run_dir.get_file() if not _latest_personal_run_dir.is_empty() else "未生成"
	var has_checkpoint := not checkpoint.is_empty() and FileAccess.file_exists(_latest_personal_checkpoint_path)
	var test_passed := _strict_trajectory_passed(_latest_personal_trajectory_path)
	var label := "PERSONAL-LATEST｜尚无个人训练产物"
	if has_checkpoint:
		label = "PERSONAL-LATEST｜%s｜%s｜%s" % [
			algorithm,
			"TEST PASS" if test_passed else "待 validation / test",
			run_name,
		]
	_strategy_option.set_item_text(STRATEGY_PERSONAL_LATEST, label)
	_strategy_option.set_item_disabled(STRATEGY_PERSONAL_LATEST, not test_passed)
	if not test_passed and _strategy_option.get_selected_id() == STRATEGY_PERSONAL_LATEST:
		_strategy_option.select(STRATEGY_STATIC_SAC)


func _read_json(path_value: String) -> Dictionary:
	if path_value.is_empty():
		return {}
	var requested := path_value
	if not FileAccess.file_exists(requested):
		requested = ProjectSettings.globalize_path(path_value)
	if not FileAccess.file_exists(requested):
		return {}
	var file := FileAccess.open(requested, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed as Dictionary if parsed is Dictionary else {}


func _resolve_replay_controller() -> void:
	var node := get_node_or_null(replay_controller_path)
	if node is CargoCircuitReplayController:
		_replay_controller = node


func _button(text_value: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text_value
	button.custom_minimum_size = Vector2(150.0, 38.0)
	button.pressed.connect(callback)
	return button


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _card() -> PanelContainer:
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.062, 0.078, 0.94)
	style.border_color = Color(0.16, 0.48, 0.58, 0.72)
	style.set_border_width_all(1)
	style.set_corner_radius_all(7)
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		style.set_content_margin(side, 10.0)
	card.add_theme_stylebox_override("panel", style)
	return card

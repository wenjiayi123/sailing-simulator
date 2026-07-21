extends CanvasLayer

const COLOR_BG := Color(0.015, 0.025, 0.034, 0.92)
const COLOR_PANEL := Color(0.035, 0.060, 0.075, 0.94)
const COLOR_ACCENT := Color(0.28, 0.96, 1.0, 0.96)
const COLOR_GREEN := Color(0.46, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.72, 0.26, 1.0)
const COLOR_TEXT := Color(0.78, 0.94, 1.0, 0.96)
const COLOR_MUTED := Color(0.56, 0.70, 0.76, 0.92)
const TOGGLE_PANEL_KEY := KEY_Z
const FLEET_TAB_KEY := KEY_X
const TRAINING_TAB_KEY := KEY_C

const TRAINING_STAGES := [
	{
		"key": "load_train_split",
		"title": "01 数据校验 / Train Split",
		"detail": "校验数据集指纹与 train / validation / test 隔离，只加载 train split"
	},
	{
		"key": "policy_update",
		"title": "02 采样与更新 / Learn",
		"detail": "无渲染数值环境采样；进度来自 Stable-Baselines3 实际 num_timesteps"
	},
	{
		"key": "checkpoint_ready",
		"title": "03 模型检查点 / Checkpoint",
		"detail": "保存模型、数据集 SHA-256、超参数和训练 episode 指标"
	},
	{
		"key": "test_rollout",
		"title": "04 测试集评估 / Test Rollout",
		"detail": "训练完成后才读取 test split，确定性执行策略并记录真实轨迹与失败"
	},
	{
		"key": "trajectory_ready",
		"title": "05 可视化回放 / Render",
		"detail": "加载刚生成的 test rollout；Godot 此时恢复渲染并播放记录结果"
	}
]

const PARAMETER_DEFS := [
	{"key": "max_forward_speed", "label": "最大前进速度", "min": 2.0, "max": 60.0, "step": 0.1},
	{"key": "max_reverse_speed", "label": "最大倒车速度", "min": 0.0, "max": 24.0, "step": 0.1},
	{"key": "acceleration", "label": "加速度", "min": 0.1, "max": 24.0, "step": 0.1},
	{"key": "deceleration", "label": "自然减速", "min": 0.1, "max": 24.0, "step": 0.1},
	{"key": "brake_acceleration", "label": "制动加速度", "min": 0.1, "max": 36.0, "step": 0.1},
	{"key": "throttle_response", "label": "油门响应", "min": 0.1, "max": 12.0, "step": 0.05},
	{"key": "rudder_response", "label": "舵响应", "min": 0.1, "max": 12.0, "step": 0.05},
	{"key": "max_turn_rate_degrees", "label": "最大转向角速", "min": 8.0, "max": 180.0, "step": 1.0},
	{"key": "low_speed_turn_factor", "label": "低速转向效率", "min": 0.0, "max": 1.0, "step": 0.01},
	{"key": "reverse_turn_factor", "label": "倒车转向效率", "min": 0.0, "max": 1.0, "step": 0.01},
	{"key": "velocity_alignment", "label": "航迹贴合", "min": 0.0, "max": 8.0, "step": 0.05},
	{"key": "impact_speed_retention", "label": "碰撞保速", "min": 0.05, "max": 0.95, "step": 0.01}
]

const RL_PARAMETER_DEFS := [
	{"group": "OPTIMIZER", "key": "learning_rate", "label": "学习率", "min": 0.00001, "max": 0.01, "value": 0.00030, "step": 0.00001, "unit": ""},
	{"group": "OPTIMIZER", "key": "discount_gamma", "label": "折扣因子 gamma", "min": 0.80, "max": 0.999, "value": 0.985, "step": 0.001, "unit": ""},
	{"group": "OPTIMIZER", "key": "gae_lambda", "label": "优势估计 lambda", "min": 0.70, "max": 1.00, "value": 0.94, "step": 0.01, "unit": ""},
	{"group": "OPTIMIZER", "key": "entropy_coef", "label": "探索熵系数", "min": 0.0, "max": 0.20, "value": 0.018, "step": 0.001, "unit": ""},
	{"group": "OPTIMIZER", "key": "value_loss_coef", "label": "价值损失权重", "min": 0.10, "max": 2.00, "value": 0.52, "step": 0.01, "unit": ""},
	{"group": "OPTIMIZER", "key": "clip_range", "label": "策略裁剪范围", "min": 0.02, "max": 0.50, "value": 0.18, "step": 0.01, "unit": ""},
	{"group": "SAMPLER", "key": "rollout_horizon", "label": "单轮采样步长", "min": 64.0, "max": 4096.0, "value": 1024.0, "step": 64.0, "unit": "step"},
	{"group": "SAMPLER", "key": "batch_size", "label": "训练 batch size", "min": 32.0, "max": 4096.0, "value": 512.0, "step": 32.0, "unit": ""},
	{"group": "SAMPLER", "key": "minibatch_size", "label": "mini-batch size", "min": 16.0, "max": 1024.0, "value": 128.0, "step": 16.0, "unit": ""},
	{"group": "SAMPLER", "key": "replay_buffer_size", "label": "回放池容量", "min": 5000.0, "max": 1000000.0, "value": 120000.0, "step": 5000.0, "unit": ""},
	{"group": "SAMPLER", "key": "warmup_steps", "label": "预热采样步数", "min": 0.0, "max": 200000.0, "value": 12000.0, "step": 1000.0, "unit": "step"},
	{"group": "SAMPLER", "key": "target_update_steps", "label": "目标网络更新间隔", "min": 50.0, "max": 20000.0, "value": 1500.0, "step": 50.0, "unit": "step"},
	{"group": "EXPLORATION", "key": "epsilon_start", "label": "epsilon 起始", "min": 0.0, "max": 1.0, "value": 0.92, "step": 0.01, "unit": ""},
	{"group": "EXPLORATION", "key": "epsilon_end", "label": "epsilon 结束", "min": 0.0, "max": 0.5, "value": 0.06, "step": 0.01, "unit": ""},
	{"group": "EXPLORATION", "key": "epsilon_decay_steps", "label": "epsilon 衰减步数", "min": 1000.0, "max": 500000.0, "value": 90000.0, "step": 1000.0, "unit": "step"},
	{"group": "LOS-PID", "key": "los_kp", "label": "LOS 比例增益 Kp", "min": 0.0, "max": 8.0, "value": 1.35, "step": 0.01, "unit": ""},
	{"group": "LOS-PID", "key": "los_ki", "label": "LOS 积分增益 Ki", "min": 0.0, "max": 1.0, "value": 0.015, "step": 0.001, "unit": ""},
	{"group": "LOS-PID", "key": "los_kd", "label": "LOS 微分增益 Kd", "min": 0.0, "max": 4.0, "value": 0.24, "step": 0.01, "unit": ""},
	{"group": "REWARD", "key": "reward_progress", "label": "航线推进奖励", "min": 0.0, "max": 8.0, "value": 2.8, "step": 0.1, "unit": ""},
	{"group": "REWARD", "key": "reward_heading", "label": "航向贴合奖励", "min": 0.0, "max": 8.0, "value": 1.6, "step": 0.1, "unit": ""},
	{"group": "REWARD", "key": "reward_speed", "label": "经济航速奖励", "min": 0.0, "max": 5.0, "value": 0.9, "step": 0.1, "unit": ""},
	{"group": "SAFETY", "key": "penalty_collision", "label": "碰撞惩罚", "min": 1.0, "max": 100.0, "value": 36.0, "step": 1.0, "unit": ""},
	{"group": "SAFETY", "key": "penalty_terrain_collision", "label": "悬岩/地形碰撞惩罚", "min": 1.0, "max": 160.0, "value": 52.0, "step": 1.0, "unit": ""},
	{"group": "SAFETY", "key": "penalty_boundary", "label": "越界惩罚", "min": 1.0, "max": 100.0, "value": 22.0, "step": 1.0, "unit": ""},
	{"group": "SAFETY", "key": "penalty_rudder", "label": "大舵角惩罚", "min": 0.0, "max": 10.0, "value": 1.2, "step": 0.1, "unit": ""},
	{"group": "SAFETY", "key": "penalty_proximity", "label": "侵入安全距离惩罚", "min": 0.0, "max": 10.0, "value": 0.8, "step": 0.1, "unit": ""},
	{"group": "SAFETY", "key": "safe_distance", "label": "最小安全距离", "min": 5.0, "max": 240.0, "value": 42.0, "step": 1.0, "unit": "m"},
	{"group": "ENVIRONMENT", "key": "vessel_radius_m", "label": "船体碰撞半径", "min": 0.5, "max": 30.0, "value": 3.2, "step": 0.1, "unit": "m"},
	{"group": "ENVIRONMENT", "key": "obstacle_inflation_m", "label": "通用障碍膨胀", "min": 0.0, "max": 40.0, "value": 1.5, "step": 0.5, "unit": "m"},
	{"group": "ENVIRONMENT", "key": "cliff_inflation_m", "label": "悬岩/岸线额外净距", "min": 0.0, "max": 80.0, "value": 8.0, "step": 0.5, "unit": "m"},
	{"group": "ENVIRONMENT", "key": "boundary_margin_m", "label": "航区边界内缩", "min": 0.0, "max": 100.0, "value": 4.0, "step": 1.0, "unit": "m"},
	{"group": "ENVIRONMENT", "key": "sensor_range_m", "label": "障碍感知距离", "min": 20.0, "max": 1000.0, "value": 220.0, "step": 10.0, "unit": "m"},
	{"group": "ENVIRONMENT", "key": "tcpa_horizon_seconds", "label": "碰撞时间预测窗", "min": 10.0, "max": 900.0, "value": 180.0, "step": 10.0, "unit": "s"},
	{"group": "ENVIRONMENT", "key": "terminate_on_collision", "label": "碰撞立即终止回合", "type": "bool", "value": 1.0, "unit": ""},
	{"group": "ENVIRONMENT", "key": "merge_scene_obstacles", "label": "合并当前场景障碍", "type": "bool", "value": 1.0, "unit": ""},
	{"group": "RANDOMIZATION", "key": "domain_randomization", "label": "训练域随机化", "type": "bool", "value": 1.0, "unit": ""},
	{"group": "RANDOMIZATION", "key": "randomize_evaluation", "label": "测试集也随机化", "type": "bool", "value": 0.0, "unit": ""},
	{"group": "RANDOMIZATION", "key": "start_position_jitter_m", "label": "起点位置扰动", "min": 0.0, "max": 50.0, "value": 3.0, "step": 0.5, "unit": "m"},
	{"group": "RANDOMIZATION", "key": "start_heading_jitter_degrees", "label": "起始航向扰动", "min": 0.0, "max": 90.0, "value": 6.0, "step": 1.0, "unit": "deg"},
	{"group": "RANDOMIZATION", "key": "obstacle_position_jitter_m", "label": "障碍位置扰动", "min": 0.0, "max": 30.0, "value": 1.5, "step": 0.5, "unit": "m"},
	{"group": "RANDOMIZATION", "key": "obstacle_size_jitter_m", "label": "障碍尺寸扰动", "min": 0.0, "max": 20.0, "value": 0.8, "step": 0.2, "unit": "m"},
	{"group": "RANDOMIZATION", "key": "current_speed_jitter_knots", "label": "流速扰动", "min": 0.0, "max": 5.0, "value": 0.25, "step": 0.05, "unit": "kn"},
	{"group": "RANDOMIZATION", "key": "current_direction_jitter_degrees", "label": "流向扰动", "min": 0.0, "max": 180.0, "value": 10.0, "step": 1.0, "unit": "deg"},
	{"group": "RANDOMIZATION", "key": "wind_speed_jitter_knots", "label": "风速扰动", "min": 0.0, "max": 20.0, "value": 1.5, "step": 0.5, "unit": "kn"},
	{"group": "RANDOMIZATION", "key": "sensor_distance_noise_std_m", "label": "测距噪声标准差", "min": 0.0, "max": 20.0, "value": 0.35, "step": 0.05, "unit": "m"},
	{"group": "RANDOMIZATION", "key": "sensor_bearing_noise_degrees", "label": "方位噪声标准差", "min": 0.0, "max": 15.0, "value": 0.6, "step": 0.1, "unit": "deg"},
	{"group": "RANDOMIZATION", "key": "generated_traffic_count", "label": "训练生成交通船", "min": 0.0, "max": 24.0, "value": 2.0, "step": 1.0, "unit": "ship"},
	{"group": "RANDOMIZATION", "key": "generated_traffic_speed_knots", "label": "生成交通船航速", "min": 0.0, "max": 30.0, "value": 5.0, "step": 0.5, "unit": "kn"},
	{"group": "RANDOMIZATION", "key": "generated_traffic_radius_m", "label": "交通船安全半径", "min": 1.0, "max": 30.0, "value": 6.0, "step": 0.5, "unit": "m"},
	{"group": "RUN", "key": "random_seed", "label": "随机种子", "min": 1.0, "max": 999999.0, "value": 240705.0, "step": 1.0, "unit": ""},
]

@export var fleet_manager_path: NodePath = NodePath("../ShipFleetManager")
@export var policy_replay_controller_path: NodePath = NodePath("../ShipPolicyReplayController")
@export var training_script_path: String = "res://tools/rl_train_baselines.py"
@export var start_visible: bool = false

var _root: Control
var _tabs: TabContainer
var _fleet_manager: ShipFleetManager
var _policy_replay_controller: Node
var _ship_option: OptionButton
var _control_button: Button
var _next_control_button: Button
var _algorithm_option: OptionButton
var _status_label: Label
var _training_status_label: Label
var _training_overlay: Control
var _training_progress_bar: ProgressBar
var _training_phase_label: Label
var _training_detail_label: Label
var _training_percent_label: Label
var _training_metrics_label: Label
var _training_footer_label: Label
var _training_stage_labels: Array[Label] = []
var _training_settings_overlay: Control
var _training_settings_summary_label: Label
var _episode_spin: SpinBox
var _step_spin: SpinBox
var _agent_spin: SpinBox
var _sleep_spin: SpinBox
var _parameter_controls: Dictionary = {}
var _rl_parameter_controls: Dictionary = {}
var _rl_parameter_values: Dictionary = {}
var _ship_nodes: Array[Node3D] = []
var _refresh_timer: float = 0.0
var _training_run_active: bool = false
var _training_run_elapsed: float = 0.0
var _training_run_algorithm: String = ""
var _training_operation: String = "train"
var _launch_replay_after_evaluation: bool = false
var _training_run_config_path: String = ""
var _training_run_parameter_path: String = ""
var _training_run_parameters: Dictionary = {}
var _training_run_episode_target: int = 0
var _training_run_step_target: int = 0
var _training_run_agent_count: int = 0
var _training_run_final_reward: float = 0.0
var _policy_play_button: Button
var _overlay_policy_play_button: Button
var _training_process_id: int = -1
var _training_progress_path: String = ""
var _training_checkpoint_path: String = ""
var _training_trajectory_path: String = ""
var _training_output_dir: String = ""
var _training_progress_poll_left: float = 0.0
var _training_mode_previous_pause: bool = false
var _training_mode_camera: Camera3D
var _training_mode_camera_cull_mask: int = 0
var _training_data_mode_active: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 60
	_initialize_rl_parameter_values()
	_build_interface()
	_resolve_manager()
	set_process(true)
	set_process_unhandled_input(true)


func _process(delta: float) -> void:
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = 0.35
		_refresh_ship_list()
		_sync_selected_config()
	_update_training_run(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return
		if key_event.physical_keycode == TOGGLE_PANEL_KEY:
			_root.visible = not _root.visible
			get_viewport().set_input_as_handled()
		elif key_event.physical_keycode == FLEET_TAB_KEY:
			_root.visible = true
			_tabs.current_tab = 0
			get_viewport().set_input_as_handled()
		elif key_event.physical_keycode == TRAINING_TAB_KEY:
			_root.visible = true
			_tabs.current_tab = 1
			get_viewport().set_input_as_handled()


func _resolve_manager() -> void:
	var manager := get_node_or_null(fleet_manager_path)
	if manager == null:
		manager = get_tree().get_first_node_in_group(&"ship_fleet_manager")
	if manager is ShipFleetManager:
		_fleet_manager = manager
		var fleet_callable := Callable(self, "_on_fleet_changed")
		var selected_callable := Callable(self, "_on_ship_selected")
		var controlled_callable := Callable(self, "_on_controlled_ship_changed")
		if not _fleet_manager.fleet_changed.is_connected(fleet_callable):
			_fleet_manager.fleet_changed.connect(fleet_callable)
		if not _fleet_manager.ship_selected.is_connected(selected_callable):
			_fleet_manager.ship_selected.connect(selected_callable)
		if not _fleet_manager.controlled_ship_changed.is_connected(controlled_callable):
			_fleet_manager.controlled_ship_changed.connect(controlled_callable)
			_refresh_ship_list()
			_sync_selected_config()
	var replay_controller := get_node_or_null(policy_replay_controller_path)
	if replay_controller == null:
		replay_controller = get_tree().get_first_node_in_group(&"ship_policy_replay_controller")
	if replay_controller != null and replay_controller.has_method("start_latest_replay"):
		_policy_replay_controller = replay_controller
		var finished_callable := Callable(self, "_on_policy_replay_finished")
		if replay_controller.has_signal("replay_finished") and not replay_controller.is_connected("replay_finished", finished_callable):
			replay_controller.connect("replay_finished", finished_callable)
		_refresh_policy_replay_buttons()


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "ShipRLControlRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = start_visible
	add_child(_root)

	var panel := PanelContainer.new()
	panel.name = "RLControlPanel"
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -260.0
	panel.offset_top = -300.0
	panel.offset_right = 260.0
	panel.offset_bottom = 300.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _panel_style(COLOR_BG, COLOR_ACCENT))
	_root.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 8)
	margin.add_child(stack)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	stack.add_child(header)
	var title := _make_label("RL 船队控制", 16, COLOR_ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var hide_button := _make_button("收起")
	hide_button.pressed.connect(func() -> void: _root.visible = false)
	header.add_child(hide_button)

	_status_label = _make_label("Z 面板  X 船舶  C 训练", 11, COLOR_MUTED)
	stack.add_child(_status_label)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(_tabs)
	_tabs.add_child(_build_fleet_tab())
	_tabs.add_child(_build_training_tab())
	_build_training_overlay()
	_build_training_settings_overlay()


func _build_fleet_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "船舶模块"
	root.add_theme_constant_override("separation", 8)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 6)
	root.add_child(top_row)

	_ship_option = OptionButton.new()
	_ship_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ship_option.item_selected.connect(_on_ship_option_selected)
	top_row.add_child(_ship_option)

	var add_button := _make_button("+ 新船")
	add_button.pressed.connect(_on_add_ship_pressed)
	top_row.add_child(add_button)

	var clone_button := _make_button("克隆")
	clone_button.pressed.connect(_on_clone_ship_pressed)
	top_row.add_child(clone_button)

	var delete_button := _make_button("删除")
	delete_button.pressed.connect(_on_delete_ship_pressed)
	top_row.add_child(delete_button)

	var control_row := HBoxContainer.new()
	control_row.add_theme_constant_override("separation", 6)
	root.add_child(control_row)

	_control_button = _make_button("接管选中")
	_control_button.pressed.connect(_on_take_control_pressed)
	control_row.add_child(_control_button)

	_next_control_button = _make_button("下一艘")
	_next_control_button.pressed.connect(_on_next_control_pressed)
	control_row.add_child(_next_control_button)

	var control_hint := _make_label("切换后输入和相机会跟随当前船", 11, COLOR_MUTED)
	control_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control_row.add_child(control_hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	var parameter_stack := VBoxContainer.new()
	parameter_stack.add_theme_constant_override("separation", 5)
	scroll.add_child(parameter_stack)
	for definition in PARAMETER_DEFS:
		parameter_stack.add_child(_make_parameter_row(definition))

	return root


func _build_training_tab() -> Control:
	var root := VBoxContainer.new()
	root.name = "训练"
	root.add_theme_constant_override("separation", 8)

	var algorithm_row := HBoxContainer.new()
	algorithm_row.add_theme_constant_override("separation", 8)
	root.add_child(algorithm_row)
	algorithm_row.add_child(_make_fixed_label("算法", 58.0))
	_algorithm_option = OptionButton.new()
	_algorithm_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for algorithm in ["ppo", "sac", "td3", "dqn", "los_pid"]:
		_algorithm_option.add_item(algorithm)
	algorithm_row.add_child(_algorithm_option)

	_episode_spin = _make_training_spin(root, "训练轮数", 1.0, 20000.0, 25.0, 1.0)
	_step_spin = _make_training_spin(root, "steps", 100.0, 20000.0, 800.0, 50.0)
	_agent_spin = _make_training_spin(root, "并行环境", 1.0, 16.0, 1.0, 1.0)
	_sleep_spin = _make_training_spin(root, "评估回合", 1.0, 16.0, 1.0, 1.0)

	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 8)
	root.add_child(button_row)
	var export_button := _make_button("导出配置")
	export_button.pressed.connect(_on_export_training_config_pressed)
	button_row.add_child(export_button)
	var train_button := _make_button("启动训练")
	train_button.pressed.connect(_on_start_training_pressed)
	button_row.add_child(train_button)
	var settings_button := _make_button("算法/环境设置")
	settings_button.pressed.connect(_on_training_parameters_pressed)
	button_row.add_child(settings_button)

	var replay_row := HBoxContainer.new()
	replay_row.add_theme_constant_override("separation", 8)
	root.add_child(replay_row)
	_policy_play_button = _make_button("运行测试集并渲染")
	_policy_play_button.pressed.connect(_on_play_policy_pressed)
	replay_row.add_child(_policy_play_button)
	var stop_replay_button := _make_button("停止策略回放")
	stop_replay_button.pressed.connect(_on_stop_policy_replay_pressed)
	replay_row.add_child(stop_replay_button)
	var replay_hint := _make_label("训练只读 train；此按钮才读取 test 并生成可视化轨迹", 11, COLOR_MUTED)
	replay_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	replay_row.add_child(replay_hint)

	_training_status_label = _make_label("render=false  backend=Stable-Baselines3  split=train", 12, COLOR_GREEN)
	_training_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_training_status_label)

	var baseline_box := PanelContainer.new()
	baseline_box.add_theme_stylebox_override("panel", _panel_style(COLOR_PANEL, COLOR_AMBER))
	root.add_child(baseline_box)
	var baseline_margin := MarginContainer.new()
	baseline_margin.add_theme_constant_override("margin_left", 10)
	baseline_margin.add_theme_constant_override("margin_top", 8)
	baseline_margin.add_theme_constant_override("margin_right", 10)
	baseline_margin.add_theme_constant_override("margin_bottom", 8)
	baseline_box.add_child(baseline_margin)
	var baseline_text := _make_label("真实基线：PPO / SAC / TD3 / DQN + LOS-PID 控制器", 12, COLOR_TEXT)
	baseline_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	baseline_margin.add_child(baseline_text)
	return root


func _build_training_overlay() -> void:
	_training_overlay = Control.new()
	_training_overlay.name = "RLTrainingOverlay"
	_training_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_training_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_training_overlay.visible = false
	_training_overlay.z_index = 30
	_root.add_child(_training_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.98)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_training_overlay.add_child(dim)

	var panel := PanelContainer.new()
	panel.name = "TrainingPipelinePanel"
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -370.0
	panel.offset_top = -238.0
	panel.offset_right = 370.0
	panel.offset_bottom = 238.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.012, 0.022, 0.030, 0.97), COLOR_ACCENT))
	_training_overlay.add_child(panel)

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
	header.add_theme_constant_override("separation", 8)
	stack.add_child(header)
	var title := _make_label("RL TRAINING PIPELINE // HEADLESS RUN", 18, COLOR_ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var stop_button := _make_button("终止")
	stop_button.pressed.connect(_on_stop_training_run_pressed)
	header.add_child(stop_button)
	_overlay_policy_play_button = _make_button("执行本次训练策略")
	_overlay_policy_play_button.pressed.connect(_on_play_policy_pressed)
	header.add_child(_overlay_policy_play_button)
	var close_button := _make_button("关闭")
	close_button.pressed.connect(_on_close_training_overlay_pressed)
	header.add_child(close_button)

	var progress_row := HBoxContainer.new()
	progress_row.add_theme_constant_override("separation", 10)
	stack.add_child(progress_row)
	_training_progress_bar = ProgressBar.new()
	_training_progress_bar.min_value = 0.0
	_training_progress_bar.max_value = 100.0
	_training_progress_bar.value = 0.0
	_training_progress_bar.show_percentage = false
	_training_progress_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_training_progress_bar.custom_minimum_size = Vector2(0.0, 22.0)
	progress_row.add_child(_training_progress_bar)
	_training_percent_label = _make_label("000.0%", 16, COLOR_GREEN)
	_training_percent_label.custom_minimum_size = Vector2(78.0, 0.0)
	progress_row.add_child(_training_percent_label)

	_training_phase_label = _make_label("--", 16, COLOR_TEXT)
	stack.add_child(_training_phase_label)
	_training_detail_label = _make_label("--", 12, COLOR_MUTED)
	_training_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_training_detail_label)

	var stages_box := PanelContainer.new()
	stages_box.add_theme_stylebox_override("panel", _panel_style(Color(0.020, 0.046, 0.054, 0.84), COLOR_ACCENT))
	stack.add_child(stages_box)
	var stages_margin := MarginContainer.new()
	stages_margin.add_theme_constant_override("margin_left", 10)
	stages_margin.add_theme_constant_override("margin_top", 8)
	stages_margin.add_theme_constant_override("margin_right", 10)
	stages_margin.add_theme_constant_override("margin_bottom", 8)
	stages_box.add_child(stages_margin)
	var stages_grid := GridContainer.new()
	stages_grid.columns = 3
	stages_grid.add_theme_constant_override("h_separation", 10)
	stages_grid.add_theme_constant_override("v_separation", 5)
	stages_margin.add_child(stages_grid)
	_training_stage_labels.clear()
	for phase_index in range(TRAINING_STAGES.size()):
		var phase: Dictionary = TRAINING_STAGES[phase_index]
		var stage_label := _make_label("QUEUE  %s" % String(phase["title"]), 11, COLOR_MUTED)
		stage_label.clip_text = true
		stage_label.custom_minimum_size = Vector2(215.0, 18.0)
		_training_stage_labels.append(stage_label)
		stages_grid.add_child(stage_label)

	var metrics_box := PanelContainer.new()
	metrics_box.add_theme_stylebox_override("panel", _panel_style(Color(0.011, 0.034, 0.036, 0.88), COLOR_GREEN))
	stack.add_child(metrics_box)
	var metrics_margin := MarginContainer.new()
	metrics_margin.add_theme_constant_override("margin_left", 10)
	metrics_margin.add_theme_constant_override("margin_top", 8)
	metrics_margin.add_theme_constant_override("margin_right", 10)
	metrics_margin.add_theme_constant_override("margin_bottom", 8)
	metrics_box.add_child(metrics_margin)
	_training_metrics_label = _make_label("--", 12, COLOR_GREEN)
	_training_metrics_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	metrics_margin.add_child(_training_metrics_label)

	_training_footer_label = _make_label("operation=train  dataset_split=train  render=false", 11, COLOR_MUTED)
	_training_footer_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_training_footer_label)


func _build_training_settings_overlay() -> void:
	_training_settings_overlay = Control.new()
	_training_settings_overlay.name = "RLTrainingSettingsOverlay"
	_training_settings_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_training_settings_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_training_settings_overlay.visible = false
	_training_settings_overlay.z_index = 40
	_root.add_child(_training_settings_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.42)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_training_settings_overlay.add_child(dim)

	var panel := PanelContainer.new()
	panel.name = "TrainingSettingsPanel"
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -455.0
	panel.offset_top = -286.0
	panel.offset_right = 455.0
	panel.offset_bottom = 286.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.012, 0.024, 0.034, 0.98), COLOR_ACCENT))
	_training_settings_overlay.add_child(panel)

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
	header.add_theme_constant_override("separation", 8)
	stack.add_child(header)
	var title := _make_label("ALGORITHM + ENVIRONMENT // 算法与环境交互设置", 18, COLOR_ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var preview_button := _make_button("预览安全边界")
	preview_button.pressed.connect(_on_preview_training_environment_pressed)
	header.add_child(preview_button)
	var reset_button := _make_button("恢复默认")
	reset_button.pressed.connect(_on_reset_training_parameters_pressed)
	header.add_child(reset_button)
	var apply_button := _make_button("应用")
	apply_button.pressed.connect(_on_apply_training_parameters_pressed)
	header.add_child(apply_button)
	var close_button := _make_button("关闭")
	close_button.pressed.connect(func() -> void: _training_settings_overlay.visible = false)
	header.add_child(close_button)

	_training_settings_summary_label = _make_label("", 12, COLOR_GREEN)
	_training_settings_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_training_settings_summary_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0.0, 410.0)
	stack.add_child(scroll)

	var groups_stack := VBoxContainer.new()
	groups_stack.add_theme_constant_override("separation", 8)
	scroll.add_child(groups_stack)

	var grouped: Dictionary = {}
	for definition in RL_PARAMETER_DEFS:
		var group_name := String(definition["group"])
		if not grouped.has(group_name):
			grouped[group_name] = []
		var group_items: Array = grouped[group_name]
		group_items.append(definition)

	for group_name in ["OPTIMIZER", "SAMPLER", "EXPLORATION", "LOS-PID", "REWARD", "SAFETY", "ENVIRONMENT", "RANDOMIZATION", "RUN"]:
		if not grouped.has(group_name):
			continue
		groups_stack.add_child(_make_rl_parameter_group(group_name, grouped[group_name]))
	_update_training_settings_summary()


func _make_rl_parameter_group(group_name: String, definitions: Array) -> Control:
	var group_panel := PanelContainer.new()
	group_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.018, 0.042, 0.052, 0.86), COLOR_ACCENT))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	group_panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 6)
	margin.add_child(stack)

	var title := _make_label(group_name, 13, COLOR_AMBER)
	stack.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	stack.add_child(grid)

	for definition in definitions:
		grid.add_child(_make_rl_parameter_row(definition))
	return group_panel


func _make_rl_parameter_row(definition: Dictionary) -> Control:
	var key := String(definition["key"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.custom_minimum_size = Vector2(410.0, 30.0)

	var label := _make_label(String(definition["label"]), 12, COLOR_TEXT)
	label.custom_minimum_size = Vector2(148.0, 0.0)
	label.clip_text = true
	row.add_child(label)

	var control: Control
	if String(definition.get("type", "number")) == "bool":
		var checkbox := CheckBox.new()
		checkbox.text = "启用"
		checkbox.button_pressed = float(_rl_parameter_values.get(key, definition["value"])) >= 0.5
		checkbox.custom_minimum_size = Vector2(112.0, 0.0)
		checkbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		checkbox.toggled.connect(_on_rl_parameter_bool_changed.bind(key))
		control = checkbox
	else:
		var spin := SpinBox.new()
		spin.min_value = float(definition["min"])
		spin.max_value = float(definition["max"])
		spin.step = float(definition["step"])
		spin.value = float(_rl_parameter_values.get(key, definition["value"]))
		spin.custom_minimum_size = Vector2(112.0, 0.0)
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spin.value_changed.connect(_on_rl_parameter_value_changed.bind(key))
		control = spin
	row.add_child(control)

	var unit := _make_label(String(definition["unit"]), 11, COLOR_MUTED)
	unit.custom_minimum_size = Vector2(32.0, 0.0)
	row.add_child(unit)

	_rl_parameter_controls[key] = control
	return row


func _make_parameter_row(definition: Dictionary) -> Control:
	var key := String(definition["key"])
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var label := _make_label(String(definition["label"]), 12, COLOR_TEXT)
	row.add_child(label)

	var control_row := HBoxContainer.new()
	control_row.add_theme_constant_override("separation", 6)
	row.add_child(control_row)

	var slider := HSlider.new()
	slider.min_value = float(definition["min"])
	slider.max_value = float(definition["max"])
	slider.step = float(definition["step"])
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_parameter_value_changed.bind(key, "slider"))
	control_row.add_child(slider)

	var spin := SpinBox.new()
	spin.min_value = slider.min_value
	spin.max_value = slider.max_value
	spin.step = slider.step
	spin.custom_minimum_size = Vector2(82.0, 0.0)
	spin.value_changed.connect(_on_parameter_value_changed.bind(key, "spin"))
	control_row.add_child(spin)

	_parameter_controls[key] = {"slider": slider, "spin": spin}
	return row


func _make_training_spin(
	parent: VBoxContainer,
	title: String,
	min_value: float,
	max_value: float,
	value: float,
	step: float
) -> SpinBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	row.add_child(_make_fixed_label(title, 78.0))
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.value = value
	spin.step = step
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spin)
	return spin


func _refresh_ship_list() -> void:
	if _fleet_manager == null or _ship_option == null:
		_resolve_manager()
		return
	var selected_ship := _fleet_manager.get_selected_ship()
	var controlled_ship := _fleet_manager.get_controlled_ship()
	var records := _fleet_manager.get_ship_records()
	_ship_nodes = records
	_ship_option.clear()
	var selected_index := 0
	for index in range(_ship_nodes.size()):
		var ship := _ship_nodes[index]
		var marker := "  "
		if ship == controlled_ship:
			marker = "▶ "
		elif ship == selected_ship:
			marker = "● "
		var label := "%02d %s%s" % [index + 1, marker, ship.name]
		_ship_option.add_item(label)
		if ship == selected_ship:
			selected_index = index
	if _ship_option.get_item_count() > 0:
		_ship_option.select(selected_index)
	if _control_button != null:
		_control_button.disabled = selected_ship == null or selected_ship == controlled_ship
	if _next_control_button != null:
		_next_control_button.disabled = _ship_nodes.size() <= 1
	if _status_label != null:
		var control_name: String = controlled_ship.name if controlled_ship != null else "--"
		var selected_name: String = selected_ship.name if selected_ship != null else "--"
		_status_label.text = "Z 面板  X 船舶  C 训练  |  控制 %s  选中 %s" % [control_name, selected_name]


func _sync_selected_config() -> void:
	if _fleet_manager == null:
		return
	var config := _fleet_manager.get_selected_ship_config()
	if config.is_empty():
		return
	for key in _parameter_controls.keys():
		if not config.has(key):
			continue
		var controls: Dictionary = _parameter_controls[key]
		var slider := controls.get("slider") as HSlider
		var spin := controls.get("spin") as SpinBox
		var value := float(config[key])
		if slider != null and not slider.has_focus():
			slider.set_block_signals(true)
			slider.value = value
			slider.set_block_signals(false)
		if spin != null and not spin.has_focus():
			spin.set_block_signals(true)
			spin.value = value
			spin.set_block_signals(false)


func _on_parameter_value_changed(value: float, key: String, source: String) -> void:
	if _fleet_manager == null:
		return
	var controls: Dictionary = _parameter_controls.get(key, {})
	var slider := controls.get("slider") as HSlider
	var spin := controls.get("spin") as SpinBox
	if source != "slider" and slider != null:
		slider.set_block_signals(true)
		slider.value = value
		slider.set_block_signals(false)
	if source != "spin" and spin != null:
		spin.set_block_signals(true)
		spin.value = value
		spin.set_block_signals(false)
	var config := _fleet_manager.get_selected_ship_config()
	config[key] = value
	_fleet_manager.apply_config_to_selected_ship(config)


func _on_ship_option_selected(index: int) -> void:
	if _fleet_manager != null:
		_fleet_manager.select_ship_by_index(index)


func _on_add_ship_pressed() -> void:
	if _fleet_manager == null:
		return
	_fleet_manager.start_drag_new_ship(_fleet_manager.get_selected_ship_config())
	_status_label.text = "拖到水面点击放置新船"


func _on_clone_ship_pressed() -> void:
	if _fleet_manager != null:
		var ship := _fleet_manager.duplicate_selected_ship_nearby()
		if ship != null:
			_status_label.text = "已克隆并选中 %s，点击 接管选中 可操作" % ship.name


func _on_delete_ship_pressed() -> void:
	if _fleet_manager != null:
		_fleet_manager.delete_selected_ship()


func _on_take_control_pressed() -> void:
	if _fleet_manager != null:
		_fleet_manager.take_control_of_selected_ship()


func _on_next_control_pressed() -> void:
	if _fleet_manager != null:
		_fleet_manager.cycle_controlled_ship(1)


func _on_export_training_config_pressed() -> void:
	if _fleet_manager == null:
		return
	var path := _fleet_manager.export_training_config("", _collect_rl_training_parameters())
	_training_status_label.text = "已导出: %s" % path


func _initialize_rl_parameter_values() -> void:
	if not _rl_parameter_values.is_empty():
		return
	for definition in RL_PARAMETER_DEFS:
		var key := String(definition["key"])
		_rl_parameter_values[key] = float(definition["value"])


func _on_training_parameters_pressed() -> void:
	if _training_settings_overlay == null:
		return
	_sync_rl_parameter_controls()
	_update_training_settings_summary()
	_training_settings_overlay.visible = true


func _on_reset_training_parameters_pressed() -> void:
	_rl_parameter_values.clear()
	for definition in RL_PARAMETER_DEFS:
		var key := String(definition["key"])
		_rl_parameter_values[key] = float(definition["value"])
	_sync_rl_parameter_controls()
	_update_training_settings_summary()
	_preview_training_environment(false)
	_training_status_label.text = "算法与环境参数已恢复默认，场景安全边界已刷新"


func _on_apply_training_parameters_pressed() -> void:
	_update_training_settings_summary()
	var config_path := ""
	if _fleet_manager != null:
		config_path = _fleet_manager.export_training_config("", _collect_rl_training_parameters())
	var preview := _preview_training_environment(false)
	_training_settings_overlay.visible = false
	_training_status_label.text = "环境已应用并写入训练配置：%s；预览 terrain=%d obstacle=%d" % [
		_short_config_path(config_path),
		int(preview.get("terrain_count", 0)),
		int(preview.get("obstacle_count", 0)),
	]


func _on_preview_training_environment_pressed() -> void:
	var preview := _preview_training_environment(true)
	if not bool(preview.get("ok", false)):
		_training_status_label.text = "环境预览失败：%s" % String(preview.get("error", "unknown"))


func _preview_training_environment(show_status: bool) -> Dictionary:
	if _fleet_manager == null:
		return {"ok": false, "error": "fleet manager unavailable"}
	var preview := _fleet_manager.preview_training_environment(_collect_rl_training_parameters())
	if show_status and bool(preview.get("ok", false)):
		_training_status_label.text = "场景已显示训练安全包络：悬岩/地形 %d，其他障碍 %d，有效边界 %.1fm" % [
			int(preview.get("terrain_count", 0)),
			int(preview.get("obstacle_count", 0)),
			float(preview.get("effective_boundary_half_extent", 0.0)),
		]
	return preview


func _on_rl_parameter_value_changed(value: float, key: String) -> void:
	_rl_parameter_values[key] = value
	_update_training_settings_summary()


func _on_rl_parameter_bool_changed(enabled: bool, key: String) -> void:
	_rl_parameter_values[key] = 1.0 if enabled else 0.0
	_update_training_settings_summary()


func _sync_rl_parameter_controls() -> void:
	for key in _rl_parameter_controls.keys():
		var control := _rl_parameter_controls[key] as Control
		if control is SpinBox:
			var spin := control as SpinBox
			spin.set_block_signals(true)
			spin.value = float(_rl_parameter_values.get(key, spin.value))
			spin.set_block_signals(false)
		elif control is CheckBox:
			var checkbox := control as CheckBox
			checkbox.set_block_signals(true)
			checkbox.button_pressed = float(_rl_parameter_values.get(key, 0.0)) >= 0.5
			checkbox.set_block_signals(false)


func _collect_rl_training_parameters() -> Dictionary:
	var parameters := {}
	for definition in RL_PARAMETER_DEFS:
		var key := String(definition["key"])
		var value := float(_rl_parameter_values.get(key, definition["value"]))
		parameters[key] = value >= 0.5 if String(definition.get("type", "number")) == "bool" else value
	return parameters


func _update_training_settings_summary() -> void:
	if _training_settings_summary_label == null:
		return
	var parameters := _collect_rl_training_parameters()
	var planned_samples: int = int(_episode_spin.value) * int(_step_spin.value) * int(_agent_spin.value)
	_training_settings_summary_label.text = (
		"算法: lr %.5f  gamma %.3f  eps %.2f->%.2f  batch %d  buffer %d  safe %.0fm\n"
		+ "环境: hull %.1fm  cliff +%.1fm  sensor %.0fm  traffic %d  scene=%s  randomize=%s\n"
		+ "真实采样预算 %s timestep；训练只读取 train split，测试按钮才读取 test split"
	) % [
		float(parameters["learning_rate"]),
		float(parameters["discount_gamma"]),
		float(parameters["epsilon_start"]),
		float(parameters["epsilon_end"]),
		int(parameters["batch_size"]),
		int(parameters["replay_buffer_size"]),
		float(parameters["safe_distance"]),
		float(parameters["vessel_radius_m"]),
		float(parameters["cliff_inflation_m"]),
		float(parameters["sensor_range_m"]),
		int(parameters["generated_traffic_count"]),
		"ON" if bool(parameters["merge_scene_obstacles"]) else "OFF",
		"ON" if bool(parameters["domain_randomization"]) else "OFF",
		_format_large_int(planned_samples),
	]


func _on_start_training_pressed() -> void:
	if _fleet_manager == null:
		return
	var parameters := _collect_rl_training_parameters()
	var config_path := _fleet_manager.export_training_config("", parameters)
	if config_path.is_empty():
		_training_status_label.text = "训练配置导出失败"
		return
	var algorithm := _algorithm_option.get_item_text(_algorithm_option.selected)
	_start_training_run(config_path, algorithm)


func _start_training_run(config_path: String, algorithm: String) -> void:
	if _training_process_id > 0 and OS.is_process_running(_training_process_id):
		_training_status_label.text = "训练进程已在运行"
		return
	_training_run_active = true
	_training_run_elapsed = 0.0
	_training_run_algorithm = algorithm
	_training_operation = "train"
	_launch_replay_after_evaluation = false
	_training_run_config_path = config_path
	_training_run_parameters = _collect_rl_training_parameters()
	_training_run_episode_target = int(_episode_spin.value)
	_training_run_step_target = int(_step_spin.value)
	_training_run_agent_count = int(_agent_spin.value)
	_training_run_parameter_path = _write_rl_training_parameter_snapshot(config_path, algorithm, _training_run_parameters)
	_training_run_final_reward = 0.0
	_training_output_dir = ProjectSettings.globalize_path("user://rl_runs")
	DirAccess.make_dir_recursive_absolute(_training_output_dir)
	_training_progress_path = _training_output_dir.path_join("training_progress.json")
	_training_checkpoint_path = _training_output_dir.path_join("policy_checkpoint.json")
	_training_trajectory_path = _training_output_dir.path_join("policy_test_trajectory.json")
	for stale_path in [_training_progress_path, _training_checkpoint_path, _training_trajectory_path]:
		if FileAccess.file_exists(stale_path):
			DirAccess.remove_absolute(stale_path)

	var python_executable := _resolve_python_executable()
	var training_script := ProjectSettings.globalize_path(training_script_path)
	var arguments := PackedStringArray([
		training_script,
		"--mode", "train",
		"--algorithm", algorithm,
		"--config", config_path,
		"--episodes", str(_training_run_episode_target),
		"--steps", str(_training_run_step_target),
		"--agents", str(_training_run_agent_count),
		"--lr", str(float(_training_run_parameters.get("learning_rate", 0.0003))),
		"--gamma", str(float(_training_run_parameters.get("discount_gamma", 0.985))),
		"--gae-lambda", str(float(_training_run_parameters.get("gae_lambda", 0.94))),
		"--entropy-coef", str(float(_training_run_parameters.get("entropy_coef", 0.018))),
		"--value-loss-coef", str(float(_training_run_parameters.get("value_loss_coef", 0.52))),
		"--clip-range", str(float(_training_run_parameters.get("clip_range", 0.18))),
		"--rollout-horizon", str(int(_training_run_parameters.get("rollout_horizon", 1024.0))),
		"--batch-size", str(int(_training_run_parameters.get("batch_size", 512.0))),
		"--minibatch-size", str(int(_training_run_parameters.get("minibatch_size", 128.0))),
		"--replay-buffer-size", str(int(_training_run_parameters.get("replay_buffer_size", 120000.0))),
		"--warmup-steps", str(int(_training_run_parameters.get("warmup_steps", 12000.0))),
		"--target-update-steps", str(int(_training_run_parameters.get("target_update_steps", 1500.0))),
		"--epsilon", str(float(_training_run_parameters.get("epsilon_start", 0.92))),
		"--min-epsilon", str(float(_training_run_parameters.get("epsilon_end", 0.06))),
		"--epsilon-decay-steps", str(int(_training_run_parameters.get("epsilon_decay_steps", 90000.0))),
		"--los-kp", str(float(_training_run_parameters.get("los_kp", 1.35))),
		"--los-ki", str(float(_training_run_parameters.get("los_ki", 0.015))),
		"--los-kd", str(float(_training_run_parameters.get("los_kd", 0.24))),
		"--seed", str(int(_training_run_parameters.get("random_seed", 240705.0))),
		"--output-dir", _training_output_dir,
		"--progress-json", _training_progress_path,
		"--checkpoint-json", _training_checkpoint_path,
	])
	_training_process_id = OS.create_process(python_executable, arguments)
	if _training_process_id <= 0:
		_training_run_active = false
		_training_status_label.text = "无法启动无渲染训练进程：%s" % python_executable
		return

	_enter_training_data_mode()
	_training_progress_poll_left = 0.0
	_root.visible = true
	_tabs.current_tab = 1
	_training_overlay.visible = true
	_training_status_label.text = "真实无渲染训练已启动: %s  pid=%d  split=train  config=%s  params=%s" % [
		algorithm,
		_training_process_id,
		_short_config_path(config_path),
		_short_config_path(_training_run_parameter_path)
	]
	_update_training_run(0.0)


func _on_stop_training_run_pressed() -> void:
	if _training_process_id > 0 and OS.is_process_running(_training_process_id):
		OS.kill(_training_process_id)
	_training_process_id = -1
	_training_run_active = false
	_exit_training_data_mode()
	if _training_overlay != null:
		_training_overlay.visible = false
	if _training_status_label != null:
		_training_status_label.text = "无渲染训练已终止，当前配置仍可重新启动"


func _update_training_run(delta: float) -> void:
	if _training_progress_bar == null:
		return
	if not _training_run_active:
		return

	_training_run_elapsed += delta
	_training_progress_poll_left -= delta
	var progress_data: Dictionary = {}
	if _training_progress_poll_left <= 0.0:
		_training_progress_poll_left = 0.18
		progress_data = _read_json_dictionary(_training_progress_path)
		if not progress_data.is_empty():
			_apply_real_training_progress(progress_data)

	if _training_process_id > 0 and OS.is_process_running(_training_process_id):
		return

	var exit_code := 1
	if _training_process_id > 0:
		exit_code = OS.get_process_exit_code(_training_process_id)
	_training_process_id = -1
	if progress_data.is_empty():
		progress_data = _read_json_dictionary(_training_progress_path)
	if exit_code == 0 and String(progress_data.get("status", "")) == "complete":
		if _training_operation == "train" and FileAccess.file_exists(_training_checkpoint_path):
			_complete_real_training(progress_data)
		elif _training_operation == "evaluate" and FileAccess.file_exists(_training_trajectory_path):
			_complete_real_evaluation(progress_data)
		else:
			_fail_real_training(exit_code, progress_data)
	else:
		_fail_real_training(exit_code, progress_data)


func _apply_real_training_progress(progress_data: Dictionary) -> void:
	var progress: float = clampf(float(progress_data.get("progress", 0.0)), 0.0, 1.0)
	var stage_key := String(progress_data.get("stage", "policy_update"))
	var phase_index := _get_training_stage_index(stage_key)
	var phase: Dictionary = TRAINING_STAGES[phase_index]
	var progress_percent: float = progress * 100.0

	_training_progress_bar.value = progress_percent
	_training_percent_label.text = "%05.1f%%" % progress_percent
	_training_phase_label.text = "%s  |  %s" % [String(phase["title"]), String(progress_data.get("status", "running")).to_upper()]
	_training_detail_label.text = String(phase["detail"])

	var fallback_total: int = maxi(1, _training_run_episode_target * _training_run_step_target * maxi(1, _training_run_agent_count))
	var total_steps := int(progress_data.get("total_timesteps", fallback_total))
	var sampled_steps := int(progress_data.get("completed_timesteps", round(float(total_steps) * progress)))
	var episode_done := int(progress_data.get("episodes_completed", progress_data.get("completed_episodes", 0)))
	var last := progress_data.get("last", {}) as Dictionary
	var reward := float(progress_data.get("mean_reward_20", last.get("reward", 0.0)))
	var reward_prefix: String = "+" if reward >= 0.0 else ""
	var collisions := int(last.get("collisions", 0))
	var terrain_collisions := int(last.get("terrain_collisions", 0))
	var near_misses := int(last.get("near_misses", 0))
	var success_rate := float(progress_data.get("success_rate_20", 0.0))
	var fps := float(progress_data.get("fps", 0.0))
	_training_run_final_reward = reward

	_training_metrics_label.text = (
		"ALG %s  |  TIMESTEP %07d/%07d  |  EPISODES %04d  |  PARALLEL ENV %02d\n"
		+ "render=false  |  Godot physics paused  |  %.1f step/s  |  elapsed %.1fs\n"
		+ "mean_reward_20 %s%.3f  |  success_20 %.1f%%  |  collision %d  terrain %d  near_miss %d"
	) % [
		_training_run_algorithm,
		sampled_steps,
		total_steps,
		episode_done,
		_training_run_agent_count,
		fps,
		_training_run_elapsed,
		reward_prefix,
		reward,
		success_rate * 100.0,
		collisions,
		terrain_collisions,
		near_misses,
	]
	_training_footer_label.text = (
		"operation=%s  dataset_split=%s  backend=stable_baselines3  render=false  pid=%d\n"
		+ "config=%s  checkpoint=%s  trajectory=%s"
	) % [
		String(progress_data.get("operation", _training_operation)),
		String(progress_data.get("dataset_split", "train")),
		_training_process_id,
		_short_config_path(_training_run_config_path),
		_short_config_path(_training_checkpoint_path),
		_short_config_path(_training_trajectory_path),
	]

	for stage_index in range(_training_stage_labels.size()):
		_set_training_stage_state(stage_index, phase_index, progress >= 1.0)



func _complete_real_training(progress_data: Dictionary) -> void:
	_training_run_active = false
	_exit_training_data_mode()
	_apply_real_training_progress(progress_data)
	_training_phase_label.text = "CHECKPOINT READY // train split 训练完成"
	_training_detail_label.text = "训练阶段没有读取 test split，也没有生成展示轨迹。点击“运行测试集并渲染”才开始独立测试。"
	_training_metrics_label.text = (
		"TRAIN COMPLETE  |  reward_20 %+.3f  |  elapsed %.2fs\n"
		+ "timesteps=%d  episodes=%d  split=train  test=NOT_RUN"
	) % [
		_training_run_final_reward,
		float(progress_data.get("elapsed_seconds", _training_run_elapsed)),
		int(progress_data.get("completed_timesteps", 0)),
		int(progress_data.get("episodes_completed", 0)),
	]
	_training_status_label.text = "训练完成：checkpoint=%s；测试集尚未运行" % _training_checkpoint_path
	_refresh_policy_replay_buttons()


func _complete_real_evaluation(progress_data: Dictionary) -> void:
	_training_run_active = false
	_exit_training_data_mode()
	_apply_real_training_progress(progress_data)
	var metrics := progress_data.get("evaluation_metrics", {}) as Dictionary
	_training_phase_label.text = "TEST ROLLOUT READY // test split 评估完成"
	_training_detail_label.text = "以下数值来自模型在未参与训练的 test split 上确定性执行；成功和失败均原样记录。"
	_training_metrics_label.text = (
		"TEST %s  |  reward %+.3f  |  collision=%d terrain=%d near_miss=%d  |  min_clearance=%.1fm\n"
		+ "dynamic=%d  max_XTE=%.1fm  path=%.1fm  elapsed=%.1fs  split=test"
	) % [
		"SUCCESS" if bool(metrics.get("success", false)) else "FAILED",
		float(metrics.get("reward", 0.0)),
		int(metrics.get("collisions", 0)),
		int(metrics.get("terrain_collisions", 0)),
		int(metrics.get("near_misses", 0)),
		float(metrics.get("minimum_clearance_meters", 0.0)),
		int(metrics.get("dynamic_obstacle_count", 0)),
		float(metrics.get("max_cross_track_error_meters", 0.0)),
		float(metrics.get("path_length_meters", 0.0)),
		float(metrics.get("elapsed_seconds", 0.0)),
	]
	_training_status_label.text = "测试完成：trajectory=%s" % _training_trajectory_path
	_refresh_policy_replay_buttons()
	if _launch_replay_after_evaluation:
		_launch_replay_after_evaluation = false
		_play_evaluation_trajectory()


func _fail_real_training(exit_code: int, progress_data: Dictionary) -> void:
	_training_run_active = false
	_exit_training_data_mode()
	_training_phase_label.text = "TRAINING FAILED // 进程异常结束"
	_training_detail_label.text = "exit_code=%d  status=%s  error=%s" % [exit_code, String(progress_data.get("status", "missing")), String(progress_data.get("error", "请检查Python训练器和导出配置"))]
	_training_status_label.text = "%s失败，未进入可视化" % ("测试" if _training_operation == "evaluate" else "训练")


func _resolve_python_executable() -> String:
	var configured := OS.get_environment("PYTHON")
	if not configured.is_empty() and FileAccess.file_exists(configured):
		return configured
	var project_venv := ProjectSettings.globalize_path("res://.venv/bin/python")
	for candidate in [project_venv, "/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"]:
		if FileAccess.file_exists(candidate):
			return candidate
	return "python3"


func _read_json_dictionary(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed as Dictionary if parsed is Dictionary else {}


func _enter_training_data_mode() -> void:
	if _training_data_mode_active:
		return
	_training_data_mode_active = true
	_training_mode_previous_pause = get_tree().paused
	_training_mode_camera = get_viewport().get_camera_3d()
	if _training_mode_camera != null:
		_training_mode_camera_cull_mask = _training_mode_camera.cull_mask
		_training_mode_camera.cull_mask = 0
	get_tree().paused = true


func _exit_training_data_mode() -> void:
	if not _training_data_mode_active:
		return
	if _training_mode_camera != null and is_instance_valid(_training_mode_camera):
		_training_mode_camera.cull_mask = _training_mode_camera_cull_mask
	get_tree().paused = _training_mode_previous_pause
	_training_mode_camera = null
	_training_data_mode_active = false


func _on_play_policy_pressed() -> void:
	if _training_run_active:
		_training_status_label.text = "训练或测试进程尚未完成"
		return
	var checkpoint_path := _resolve_available_policy_checkpoint_path()
	if checkpoint_path.is_empty():
		_training_status_label.text = "未找到训练完成的 checkpoint，请先启动训练"
		return
	_start_policy_evaluation(checkpoint_path)


func _start_policy_evaluation(checkpoint_path: String) -> void:
	var checkpoint := _read_json_dictionary(checkpoint_path)
	var algorithm := String(checkpoint.get("algorithm", ""))
	if algorithm.is_empty():
		_training_status_label.text = "checkpoint 缺少 algorithm 元数据"
		return
	var config_path := String(checkpoint.get("config_path", ""))
	if config_path.is_empty() or not FileAccess.file_exists(config_path):
		config_path = ProjectSettings.globalize_path("user://rl_training_config.json")
	if not FileAccess.file_exists(config_path):
		_training_status_label.text = "找不到训练时配置；为防止数据漂移，测试已停止"
		return
	_training_run_algorithm = algorithm
	_training_run_episode_target = int(_sleep_spin.value)
	_training_run_step_target = int(_step_spin.value)
	_training_run_agent_count = 1
	_training_run_config_path = config_path
	_training_checkpoint_path = checkpoint_path
	_training_output_dir = checkpoint_path.get_base_dir()
	_training_progress_path = _training_output_dir.path_join("evaluation_progress.json")
	_training_trajectory_path = _training_output_dir.path_join("policy_test_trajectory.json")
	for stale_path in [_training_progress_path, _training_trajectory_path]:
		if FileAccess.file_exists(stale_path):
			DirAccess.remove_absolute(stale_path)
	var python_executable := _resolve_python_executable()
	var training_script := ProjectSettings.globalize_path(training_script_path)
	var arguments := PackedStringArray([
		training_script,
		"--mode", "evaluate",
		"--algorithm", algorithm,
		"--config", config_path,
		"--steps", str(int(_step_spin.value)),
		"--eval-episodes", str(int(_sleep_spin.value)),
		"--seed", str(int(_training_run_parameters.get("random_seed", 240705.0))),
		"--output-dir", _training_output_dir,
		"--progress-json", _training_progress_path,
		"--checkpoint-json", _training_checkpoint_path,
		"--trajectory-json", _training_trajectory_path,
	])
	_training_process_id = OS.create_process(python_executable, arguments)
	if _training_process_id <= 0:
		_training_status_label.text = "无法启动独立测试进程：%s" % python_executable
		return
	_training_operation = "evaluate"
	_training_run_active = true
	_training_run_elapsed = 0.0
	_training_progress_poll_left = 0.0
	_launch_replay_after_evaluation = true
	_enter_training_data_mode()
	_root.visible = true
	_tabs.current_tab = 1
	_training_overlay.visible = true
	_training_status_label.text = "测试集评估已启动：%s  split=test  pid=%d" % [algorithm, _training_process_id]
	_update_training_run(0.0)


func _play_evaluation_trajectory() -> void:
	if _policy_replay_controller == null:
		_resolve_manager()
	if _policy_replay_controller == null:
		_training_status_label.text = "策略回放控制器未就绪"
		return
	var requested_path := _resolve_available_policy_trajectory_path()
	if requested_path.is_empty():
		_training_status_label.text = "测试轨迹没有生成"
		return
	if _policy_replay_controller.start_latest_replay(requested_path):
		_training_overlay.visible = false
		_root.visible = false
	else:
		_training_status_label.text = "测试轨迹加载失败：%s" % requested_path


func _on_stop_policy_replay_pressed() -> void:
	if _policy_replay_controller == null:
		_resolve_manager()
	if _policy_replay_controller != null:
		_policy_replay_controller.stop_replay()
	_training_status_label.text = "策略回放已停止，已恢复人工操船"


func _on_policy_replay_finished(result: Dictionary) -> void:
	_training_status_label.text = (
		"策略评估%s：collision=%d  min_clearance=%.1fm  max_XTE=%.1fm  elapsed=%.1fs"
	) % [
		"成功" if bool(result.get("success", false)) else "失败",
		int(result.get("collision_count", 0)),
		float(result.get("minimum_clearance_meters", 0.0)),
		float(result.get("max_route_deviation_meters", 0.0)),
		float(result.get("elapsed_seconds", 0.0)),
	]


func _on_close_training_overlay_pressed() -> void:
	if _training_run_active:
		_training_status_label.text = "无渲染训练运行中；请等待完成或点击终止"
		return
	_training_overlay.visible = false


func _refresh_policy_replay_buttons() -> void:
	var checkpoint_path := _resolve_available_policy_checkpoint_path()
	var available := not checkpoint_path.is_empty()
	if _policy_play_button != null:
		_policy_play_button.disabled = not available
		_policy_play_button.tooltip_text = "使用该 checkpoint 运行 test split：%s" % checkpoint_path if available else "未找到训练 checkpoint"
	if _overlay_policy_play_button != null:
		_overlay_policy_play_button.disabled = not available
	if _training_status_label != null and available and not _training_run_active:
		_training_status_label.text = "checkpoint 已就绪：点击“运行测试集并渲染”"


func _resolve_available_policy_checkpoint_path() -> String:
	var candidates: Array[String] = []
	if not _training_checkpoint_path.is_empty():
		candidates.append(_training_checkpoint_path)
	candidates.append(ProjectSettings.globalize_path("user://rl_runs/policy_checkpoint.json"))
	for candidate in candidates:
		if FileAccess.file_exists(candidate):
			return candidate
	return ""


func _resolve_available_policy_trajectory_path() -> String:
	var candidates: Array[String] = []
	if not _training_trajectory_path.is_empty():
		candidates.append(_training_trajectory_path)
	candidates.append(ProjectSettings.globalize_path("user://rl_runs/policy_test_trajectory.json"))
	for candidate in candidates:
		if FileAccess.file_exists(candidate) or FileAccess.file_exists(ProjectSettings.globalize_path(candidate)):
			return candidate
	return ""


func _exit_tree() -> void:
	if _training_process_id > 0 and OS.is_process_running(_training_process_id):
		OS.kill(_training_process_id)
	_training_process_id = -1
	if is_inside_tree():
		_exit_training_data_mode()


func _get_training_stage_index(stage_key: String) -> int:
	for index in range(TRAINING_STAGES.size()):
		var stage := TRAINING_STAGES[index] as Dictionary
		if String(stage.get("key", "")) == stage_key:
			return index
	return 1


func _set_training_stage_state(stage_index: int, active_index: int, complete: bool) -> void:
	var label: Label = _training_stage_labels[stage_index]
	var phase: Dictionary = TRAINING_STAGES[stage_index]
	var state: String = "QUEUE"
	var color: Color = COLOR_MUTED
	if complete or stage_index < active_index:
		state = "DONE "
		color = COLOR_GREEN
	elif stage_index == active_index:
		state = "RUN  "
		color = COLOR_ACCENT
	label.text = "%s  %s" % [state, String(phase["title"])]
	label.add_theme_color_override("font_color", color)


func _short_config_path(path: String) -> String:
	if path.is_empty():
		return "--"
	return path.get_file()


func _format_seconds(seconds: int) -> String:
	var safe_seconds: int = max(0, seconds)
	var minutes: int = safe_seconds / 60
	var remainder: int = safe_seconds % 60
	if minutes >= 60:
		var hours: int = minutes / 60
		var minute_remainder: int = minutes % 60
		return "%02dh %02dm" % [hours, minute_remainder]
	return "%02dm %02ds" % [minutes, remainder]


func _format_large_int(value: int) -> String:
	if value >= 1000000:
		return "%.2fM" % (float(value) / 1000000.0)
	if value >= 1000:
		return "%.1fk" % (float(value) / 1000.0)
	return str(value)


func _write_rl_training_parameter_snapshot(config_path: String, algorithm: String, parameters: Dictionary) -> String:
	var output_dir := "user://rl_runs"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
	var output_path := "%s/training_parameters.json" % output_dir
	var payload := {
		"algorithm": algorithm,
		"fleet_config": config_path,
		"training_rounds": _training_run_episode_target,
		"steps_per_episode": _training_run_step_target,
		"parallel_environments": _training_run_agent_count,
		"training_split": "train",
		"evaluation_split": "test",
		"rl_parameters": parameters
	}
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	return ProjectSettings.globalize_path(output_path)


func _on_fleet_changed() -> void:
	_refresh_ship_list()
	_sync_selected_config()


func _on_ship_selected(_ship: Node3D) -> void:
	_refresh_ship_list()
	_sync_selected_config()


func _on_controlled_ship_changed(_ship: Node3D) -> void:
	_refresh_ship_list()
	_sync_selected_config()


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _make_fixed_label(text: String, width: float) -> Label:
	var label := _make_label(text, 12, COLOR_TEXT)
	label.custom_minimum_size = Vector2(width, 0.0)
	return label


func _make_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	return button


func _panel_style(fill: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_right = 8
	style.corner_radius_bottom_left = 8
	return style

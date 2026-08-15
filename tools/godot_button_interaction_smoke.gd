extends SceneTree
# gdlint: disable=max-line-length

const REPORT_PATH := "res://reports/godot_button_interaction_smoke_v1.json"
const USER_FILES_TO_PRESERVE := [
	"user://rl_training_config.json",
	"user://ship_navigation_plan.json",
	"user://ship_simulation_review.json",
	"user://ship_instructor_report.json",
]

var _checks: Dictionary = {}
var _errors: Array[String] = []
var _saved_user_files: Dictionary = {}
var _main: Node


func _initialize() -> void:
	call_deferred("_run")


func _record(name: String, passed: bool, detail: Variant) -> void:
	_checks[name] = {"passed": passed, "detail": detail}
	if not passed:
		_errors.append("%s: %s" % [name, str(detail)])


func _panel(name: String) -> Node:
	return _main.get_node_or_null(NodePath(name))


func _root(panel: Node) -> Control:
	return panel.get("_root") as Control if panel != null else null


func _find_button(root: Node, title: String, occurrence: int = 0) -> Button:
	var seen := 0
	for node in root.find_children("*", "Button", true, false):
		var button := node as Button
		if button != null and button.text == title:
			if seen == occurrence:
				return button
			seen += 1
	return null


func _press(root: Node, title: String, occurrence: int = 0) -> Button:
	var button := _find_button(root, title, occurrence)
	if button != null:
		button.pressed.emit()
	return button


func _label_text(panel: Node, key: String) -> String:
	var labels := panel.get("_labels") as Dictionary
	var label := labels.get(key) as Label
	return label.text if label != null else ""


func _snapshot_user_files() -> void:
	for path in USER_FILES_TO_PRESERVE:
		var record := {"existed": FileAccess.file_exists(path), "bytes": PackedByteArray()}
		if bool(record["existed"]):
			var file := FileAccess.open(path, FileAccess.READ)
			if file != null:
				record["bytes"] = file.get_buffer(file.get_length())
				file.close()
		_saved_user_files[path] = record


func _restore_user_files() -> void:
	for path in USER_FILES_TO_PRESERVE:
		var record := _saved_user_files.get(path, {}) as Dictionary
		if bool(record.get("existed", false)):
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file != null:
				file.store_buffer(record.get("bytes", PackedByteArray()) as PackedByteArray)
				file.close()
		elif FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _wait_for_training(panel: Node, timeout_seconds: float = 60.0) -> bool:
	var elapsed := 0.0
	while bool(panel.get("_training_run_active")) and elapsed < timeout_seconds:
		await create_timer(0.10, true, false, true).timeout
		elapsed += 0.10
	return not bool(panel.get("_training_run_active"))


func _run() -> void:
	_snapshot_user_files()
	var scene_status := change_scene_to_file("res://main.tscn")
	_record("main_scene_load", scene_status == OK, scene_status)
	if scene_status != OK:
		_finish()
		return
	for _index in range(24):
		await process_frame
	_main = current_scene
	_record("main_scene_ready", _main != null, _main.name if _main != null else "null")
	if _main == null:
		_finish()
		return

	await _test_evidence_center()
	await _test_rl_control_panel()
	await _test_navigation_panel()
	await _test_risk_panel()
	await _test_weather_panel()
	await _test_review_panel()
	await _test_ais_panel()
	await _test_instructor_panel()
	await _test_cargo_circuit_panel()
	_finish()


func _test_cargo_circuit_panel() -> void:
	var panel := _panel("CargoCircuitRLPanel")
	var root := _root(panel)
	var controller := _main.get_node_or_null("CargoCircuitReplayController") as CargoCircuitReplayController
	_record("cargo_panel_present", panel != null and root != null, panel)
	_record("cargo_replay_controller_present", controller != null, controller)
	if panel == null or root == null or controller == null:
		return
	panel.call("show_panel")
	_record("cargo_panel_show", root.visible, root.visible)
	var camera_option := panel.get("_camera_mode_option") as OptionButton
	var algorithm_option := panel.get("_algorithm_option") as OptionButton
	var strategy_option := panel.get("_strategy_option") as OptionButton
	var player := _main.get_node_or_null("Player")
	var algorithm_ids: Array[String] = []
	if algorithm_option != null:
		for index in range(algorithm_option.item_count):
			algorithm_ids.append(String(algorithm_option.get_item_metadata(index)))
	_record(
		"cargo_seven_algorithm_selector",
		algorithm_ids == ["sac", "ppo", "td3", "a2c", "ddpg", "tqc", "trpo"],
		algorithm_ids
	)
	_record(
		"cargo_named_strategy_selector",
		strategy_option != null and strategy_option.item_count == 4
			and strategy_option.get_item_text(0).begins_with("SAC-S1｜")
			and strategy_option.get_item_text(1).begins_with("RES-SAC-D2｜")
			and strategy_option.get_item_text(2).begins_with("MANUAL-F0｜")
			and strategy_option.get_item_text(3).begins_with("PERSONAL-LATEST｜"),
		strategy_option
	)
	_record(
		"cargo_camera_mode_selector",
		camera_option != null and camera_option.item_count == 2
			and camera_option.get_item_text(0) == "自动跟随旋转"
			and camera_option.get_item_text(1) == "自由镜头（不跟随）",
		camera_option
	)
	_record(
		"cargo_3d_usv_is_sole_renderer",
		player != null
			and player.get_node_or_null("PlayerVisual") == null
			and player.get_node_or_null("ProceduralUSVVisual") != null
			and bool((player.get_node("ProceduralUSVVisual") as Node3D).visible),
		player
	)
	if camera_option != null:
		camera_option.select(1)
		camera_option.item_selected.emit(1)
		var selected_free := controller.get_replay_presentation_status()
		_record(
			"cargo_presentation_selection_before_replay",
			String(selected_free.get("camera_mode", "")) == "free_camera"
				and String(selected_free.get("visual_mode", "")) == "procedural_usv",
			selected_free
		)
	if strategy_option != null:
		strategy_option.select(0)
		strategy_option.item_selected.emit(0)
	_press(root, "播放所选策略")
	await physics_frame
	var static_status := controller.get_replay_status()
	_record(
		"cargo_static_rl_replay_start",
		controller.is_replay_active() and bool(static_status.get("trained_rl", false)) and String(static_status.get("dataset_split", "")) == "test",
		static_status
	)
	if player != null:
		var free_camera_status := player.call("get_ship_camera_heading_follow_status") as Dictionary
		_record(
			"cargo_free_camera_applied_to_3d_usv",
			not bool(free_camera_status.get("enabled", true))
				and bool((player.get_node("ProceduralUSVVisual") as Node3D).visible),
			free_camera_status
		)
	if camera_option != null:
		camera_option.select(0)
		camera_option.item_selected.emit(0)
		var selected_auto_usv := controller.get_replay_presentation_status()
		var active_camera_status := player.call("get_ship_camera_heading_follow_status") as Dictionary if player != null else {}
		_record(
			"cargo_auto_camera_and_3d_usv_applied_live",
			String(selected_auto_usv.get("camera_mode", "")) == "auto_follow"
				and String(selected_auto_usv.get("visual_mode", "")) == "procedural_usv"
				and bool(active_camera_status.get("enabled", false)),
			{"selection": selected_auto_usv, "camera": active_camera_status}
		)
	controller.stop_replay(true)
	await process_frame
	panel.call("show_panel")
	if strategy_option != null:
		strategy_option.select(1)
		strategy_option.item_selected.emit(1)
	_press(root, "播放所选策略")
	await physics_frame
	var dynamic_status := controller.get_replay_status()
	_record(
		"cargo_dynamic_rl_replay_start",
		controller.is_replay_active() and int(dynamic_status.get("dynamic_marker_count", 0)) == 6,
		dynamic_status
	)
	controller.stop_replay(true)
	await process_frame
	panel.call("show_panel")
	if strategy_option != null:
		strategy_option.select(2)
		strategy_option.item_selected.emit(2)
	_press(root, "播放所选策略")
	await physics_frame
	_record("cargo_manual_replay_start", controller.is_replay_active(), controller.get_replay_status())
	panel.call("show_panel")
	_press(root, "5x")
	_record("cargo_replay_speed", is_equal_approx(float(controller.get_replay_status().get("playback_speed", 0.0)), 5.0), controller.get_replay_status())
	_press(root, "停止并恢复原场景")
	await process_frame
	_record("cargo_replay_stop_restore", not controller.is_replay_active(), controller.get_replay_status())

	var module_targets := {
		"进入 RL 训练中心": "ShipRLControlPanel",
		"航线规划": "ShipNavigationPlanningPanel",
		"风险决策": "ShipRiskDecisionPanel",
		"海况与时间": "ShipWeatherSeaPanel",
		"AIS 船队态势": "ShipAISFleetPanel",
		"训练与仿真复盘": "ShipSimulationReviewPanel",
		"小懿系统助手": "ShipInstructorConsolePanel",
		"证据与指标中心": "ShipHREvidenceCenter",
	}
	var return_root := panel.get("_hub_return_root") as Control
	var return_button := panel.get("_hub_return_button") as Button
	for title in module_targets:
		panel.call("show_panel")
		_press(root, String(title))
		await process_frame
		var target := _panel(String(module_targets[title]))
		var target_root := _root(target)
		var target_visible := target_root != null and target_root.visible
		if String(title) == "进入 RL 训练中心" and target != null:
			var tabs := target.get("_tabs") as TabContainer
			target_visible = target_visible and tabs != null and tabs.current_tab == 1
		_record(
			"cargo_hub_open_%s" % String(module_targets[title]),
			target_visible and not root.visible and return_root != null and return_root.visible,
			target_root
		)
		if return_button != null:
			return_button.pressed.emit()
		await process_frame
		_record(
			"cargo_hub_return_%s" % String(module_targets[title]),
			root.visible and (target_root == null or not target_root.visible),
			root.visible
		)

	_press(root, "关闭面板（H）")
	_record("cargo_panel_close", not root.visible, root.visible)
	var required_buttons := [
		"进入 RL 训练中心",
		"航线规划",
		"风险决策",
		"海况与时间",
		"AIS 船队态势",
		"训练与仿真复盘",
		"小懿系统助手",
		"证据与指标中心",
		"0  人工物理可达性验收",
		"1  启动无渲染训练",
		"2  验证策略（不渲染）",
		"3  测试并生成可视化",
		"播放所选策略",
		"停止并恢复原场景",
		"4  重测动态策略（无渲染→播放）",
	]
	for title in required_buttons:
		var button := _find_button(root, title)
		_record(
			"cargo_button_bound_%s" % title,
			button != null and button.get_signal_connection_list("pressed").size() > 0,
			button.text if button != null else "missing"
		)


func _test_evidence_center() -> void:
	var center := _panel("ShipHREvidenceCenter")
	var center_root := _root(center)
	var rl := _panel("ShipRLControlPanel")
	var navigation := _panel("ShipNavigationPlanningPanel")
	var risk := _panel("ShipRiskDecisionPanel")
	var weather := _panel("ShipWeatherSeaPanel")
	var ais := _panel("ShipAISFleetPanel")
	var review := _panel("ShipSimulationReviewPanel")
	var instructor := _panel("ShipInstructorConsolePanel")

	center_root.visible = true
	_press(center_root, "关闭  M")
	_record("evidence_close", not center_root.visible, center_root.visible)
	center_root.visible = true
	_press(center_root, "打开训练中心  ·  TRAINING CENTER")
	await process_frame
	_record("evidence_open_training", _root(rl).visible, _root(rl).visible)
	center_root.visible = true
	_press(center_root, "航线规划 / 风险决策 / 海况")
	await process_frame
	_record(
		"evidence_open_navigation_group",
		_root(navigation).visible and _root(risk).visible and _root(weather).visible,
		[_root(navigation).visible, _root(risk).visible, _root(weather).visible]
	)
	center_root.visible = true
	_press(center_root, "AIS 船队态势")
	await process_frame
	_record("evidence_open_ais", _root(ais).visible, _root(ais).visible)
	center_root.visible = true
	_press(center_root, "打开训练结果复盘")
	await process_frame
	_record("evidence_open_review", _root(review).visible, _root(review).visible)
	center_root.visible = true
	_press(center_root, "小懿全系统助手")
	await process_frame
	_record("evidence_open_instructor", _root(instructor).visible, _root(instructor).visible)
	center_root.visible = true
	_press(center_root, "训练顾问：查看算法选择依据")
	var status := center.get("_status_label") as Label
	_record("evidence_advisor", status.text.begins_with("小懿建议"), status.text)
	_press(center_root, "运行环境与数据边界审查")
	_record("evidence_boundary", status.text.begins_with("边界审查"), status.text)
	_press(center_root, "校验 v2 港口数据契约")
	await process_frame
	_record(
		"evidence_contract_validator",
		status.text.begins_with("已启动真实契约校验进程 PID"),
		status.text
	)


func _test_rl_control_panel() -> void:
	var panel := _panel("ShipRLControlPanel")
	var root := _root(panel)
	var manager := _main.get_node("ShipFleetManager") as ShipFleetManager
	root.visible = true
	_press(root, "收起")
	_record("rl_hide", not root.visible, root.visible)
	root.visible = true

	var dataset := panel.get("_dataset_profile_option") as OptionButton
	var algorithm := panel.get("_algorithm_option") as OptionButton
	dataset.select(1)
	dataset.item_selected.emit(1)
	_record("rl_dataset_v2_inventory", algorithm.item_count == 10, algorithm.item_count)
	var sac_index := -1
	for index in range(algorithm.item_count):
		if algorithm.get_item_text(index) == "sac":
			sac_index = index
			break
	algorithm.select(sac_index)
	algorithm.item_selected.emit(sac_index)
	var training_status := panel.get("_training_status_label") as Label
	_record("rl_algorithm_selection_feedback", training_status.text.contains("sac"), training_status.text)
	dataset.select(0)
	dataset.item_selected.emit(0)
	_record("rl_dataset_v1_inventory", algorithm.item_count == 5, algorithm.item_count)

	_press(root, "+ 新船")
	_record("rl_add_ship_placement_mode", bool(manager.get("_dragging_new_ship")), manager.get("_dragging_new_ship"))
	manager.cancel_drag_new_ship()
	var initial_count := manager.get_ship_records().size()
	_press(root, "克隆")
	await process_frame
	var clone := manager.get_selected_ship()
	_record("rl_clone_ship", manager.get_ship_records().size() == initial_count + 1, manager.get_ship_records().size())
	var delete_button := _find_button(root, "删除")
	_record("rl_delete_clone_enabled", not delete_button.disabled, delete_button.disabled)
	_press(root, "删除")
	await process_frame
	await process_frame
	_record("rl_delete_clone", manager.get_ship_records().size() == initial_count, manager.get_ship_records().size())

	_press(root, "克隆")
	await process_frame
	clone = manager.get_selected_ship()
	var player := manager.get_ship_records()[0] as Node3D
	_press(root, "接管选中")
	_record("rl_take_control", manager.get_controlled_ship() == clone, manager.get_controlled_ship().name)
	var controlled_before := manager.get_controlled_ship()
	_press(root, "下一艘")
	_record("rl_next_controlled_ship", manager.get_controlled_ship() != controlled_before, manager.get_controlled_ship().name)
	manager.select_ship(player)
	await process_frame
	_record("rl_prototype_delete_disabled", _find_button(root, "删除").disabled, _find_button(root, "删除").disabled)
	var ship_option := panel.get("_ship_option") as OptionButton
	ship_option.select(1)
	ship_option.item_selected.emit(1)
	_record("rl_ship_selector", manager.get_selected_ship() == clone, manager.get_selected_ship().name)

	dataset.select(0)
	dataset.item_selected.emit(0)
	_press(root, "导出配置")
	_record(
		"rl_export_config",
		training_status.text.begins_with("已导出:") and FileAccess.file_exists("user://rl_training_config.json"),
		training_status.text
	)
	_press(root, "算法/环境设置")
	var settings := panel.get("_training_settings_overlay") as Control
	_record("rl_open_settings", settings.visible, settings.visible)
	_press(settings, "预览安全边界")
	_record("rl_preview_safety_boundary", training_status.text.begins_with("场景已显示训练安全包络"), training_status.text)
	var parameter_controls := panel.get("_rl_parameter_controls") as Dictionary
	var parameter_values := panel.get("_rl_parameter_values") as Dictionary
	for key in ["terminate_on_collision", "merge_scene_obstacles", "domain_randomization", "randomize_evaluation"]:
		var checkbox := parameter_controls.get(key) as CheckBox
		var next_value := not checkbox.button_pressed
		checkbox.button_pressed = next_value
		checkbox.toggled.emit(next_value)
		_record("rl_toggle_%s" % key, bool(parameter_values.get(key, not next_value)) == next_value, parameter_values.get(key))
	_press(settings, "恢复默认")
	parameter_values = panel.get("_rl_parameter_values") as Dictionary
	_record("rl_restore_defaults", is_equal_approx(float(parameter_values.get("learning_rate", 0.0)), 0.0003), parameter_values.get("learning_rate"))
	_press(settings, "应用")
	_record("rl_apply_settings", not settings.visible and training_status.text.begins_with("环境已应用"), training_status.text)
	_press(root, "算法/环境设置")
	_press(settings, "关闭")
	_record("rl_close_settings", not settings.visible, settings.visible)
	_press(root, "停止策略回放")
	_record("rl_stop_replay", training_status.text.begins_with("策略回放已停止"), training_status.text)

	dataset.select(1)
	dataset.item_selected.emit(1)
	var los_index := -1
	for index in range(algorithm.item_count):
		if algorithm.get_item_text(index) == "los_pid":
			los_index = index
			break
	algorithm.select(los_index)
	algorithm.item_selected.emit(los_index)
	(panel.get("_episode_spin") as SpinBox).value = 1
	(panel.get("_step_spin") as SpinBox).value = 100
	(panel.get("_agent_spin") as SpinBox).value = 1
	(panel.get("_sleep_spin") as SpinBox).value = 1
	_press(root, "启动训练")
	var training_started := bool(panel.get("_training_run_active")) and int(panel.get("_training_process_id")) > 0
	_record("rl_start_headless_training", training_started, training_status.text)
	var training_finished := await _wait_for_training(panel)
	var checkpoint_path := String(panel.get("_training_checkpoint_path"))
	_record(
		"rl_training_checkpoint",
		training_finished and FileAccess.file_exists(checkpoint_path),
		{"finished": training_finished, "checkpoint": checkpoint_path, "status": training_status.text}
	)
	var training_overlay := panel.get("_training_overlay") as Control
	_press(training_overlay, "关闭")
	_record("rl_close_finished_training", not training_overlay.visible, training_overlay.visible)
	var test_button := _find_button(root, "运行测试集并渲染")
	_record("rl_test_button_enabled", test_button != null and not test_button.disabled, test_button.disabled if test_button != null else "missing")
	if test_button != null and not test_button.disabled:
		test_button.pressed.emit()
		var evaluation_started := bool(panel.get("_training_run_active")) and String(panel.get("_training_operation")) == "evaluate"
		_record("rl_start_held_out_test", evaluation_started, training_status.text)
		var evaluation_finished := await _wait_for_training(panel)
		var trajectory_path := String(panel.get("_training_trajectory_path"))
		_record(
			"rl_test_trajectory",
			evaluation_finished and FileAccess.file_exists(trajectory_path),
			{"finished": evaluation_finished, "trajectory": trajectory_path, "status": training_status.text}
		)
		var replay := _main.get_node("ShipPolicyReplayController") as ShipPolicyReplayController
		_record("rl_test_replay_started", replay.is_replay_active(), replay.get_replay_status())
		replay.stop_replay()
		_record("rl_test_replay_stopped", not replay.is_replay_active(), replay.get_replay_status())
	else:
		_record("rl_start_held_out_test", false, "button disabled")
		_record("rl_test_trajectory", false, "button disabled")
		_record("rl_test_replay_started", false, "button disabled")
		_record("rl_test_replay_stopped", false, "button disabled")


func _test_navigation_panel() -> void:
	var panel := _panel("ShipNavigationPlanningPanel")
	var root := _root(panel)
	root.visible = true
	_press(root, "收起")
	_record("navigation_hide", not root.visible, root.visible)
	root.visible = true
	var mission := panel.get("_mission_option") as OptionButton
	var target_index := mini(1, mission.item_count - 1)
	mission.select(target_index)
	mission.item_selected.emit(target_index)
	_record("navigation_mission_pending_feedback", bool(panel.get("_pending_mission_changes")), _label_text(panel, "mission_footer"))
	var sync_check := panel.get("_sync_scenario_check") as CheckBox
	sync_check.button_pressed = not sync_check.button_pressed
	sync_check.toggled.emit(sync_check.button_pressed)
	_record("navigation_sync_toggle", bool(panel.get("_pending_mission_changes")), _label_text(panel, "mission_footer"))
	sync_check.button_pressed = true
	sync_check.toggled.emit(true)
	var teleport_check := panel.get("_teleport_check") as CheckBox
	teleport_check.button_pressed = true
	teleport_check.toggled.emit(true)
	_press(root, "应用任务")
	var route := _main.get_node("ShipRouteSystem")
	var radar := route.call("get_radar_route_data") as Dictionary
	_record("navigation_apply_mission", bool(radar.get("active", false)) and not bool(panel.get("_pending_mission_changes")), radar)
	_record("navigation_apply_mission_export", FileAccess.file_exists("user://ship_navigation_plan.json"), "user://ship_navigation_plan.json")
	var loop_check := panel.get("_loop_check") as CheckBox
	loop_check.button_pressed = not loop_check.button_pressed
	loop_check.toggled.emit(loop_check.button_pressed)
	_record("navigation_loop_pending_feedback", bool(panel.get("_pending_route_settings")), _label_text(panel, "mission_footer"))
	var arrival := panel.get("_arrival_spin") as SpinBox
	arrival.value = minf(arrival.value + 1.0, arrival.max_value)
	arrival.value_changed.emit(arrival.value)
	var speed := panel.get("_planned_speed_spin") as SpinBox
	speed.value = minf(speed.value + 0.5, speed.max_value)
	speed.value_changed.emit(speed.value)
	_press(root, "应用航线参数")
	radar = route.call("get_radar_route_data") as Dictionary
	_record(
		"navigation_apply_route_settings",
		bool(radar.get("loop", false)) == loop_check.button_pressed and not bool(panel.get("_pending_route_settings")),
		radar
	)
	_press(root, "导出任务快照")
	_record("navigation_export_snapshot", _label_text(panel, "mission_footer").begins_with("任务快照已导出"), _label_text(panel, "mission_footer"))


func _test_risk_panel() -> void:
	var panel := _panel("ShipRiskDecisionPanel")
	var root := _root(panel)
	root.visible = true
	_press(root, "收起")
	_record("risk_hide", not root.visible, root.visible)
	root.visible = true
	var expected_clearance := {"标准": 52.0, "保守": 72.0, "港口": 34.0, "夜航": 86.0}
	for title in expected_clearance.keys():
		_press(root, title)
		_record(
			"risk_preset_%s" % title,
			is_equal_approx(float(panel.get("safe_clearance_meters")), float(expected_clearance[title])),
			panel.get("safe_clearance_meters")
		)
	_press(root, "刷新验证结果")
	var validation_status := _label_text(panel, "validation_status")
	_record("risk_refresh_validation", not validation_status.is_empty() and validation_status != "--", validation_status)


func _test_weather_panel() -> void:
	var panel := _panel("ShipWeatherSeaPanel")
	var root := _root(panel)
	var controller := _main.get_node("ShipWeatherTimeController")
	root.visible = true
	_press(root, "收起")
	_record("weather_hide", not root.visible, root.visible)
	root.visible = true
	_press(root, "刷新公开数据")
	var status := controller.call("get_weather_time_status") as Dictionary
	_record("weather_refresh_public", String(status.get("data_status", "")).length() > 0, status.get("data_status"))
	for index in range(4):
		var title: String = ["晴天", "薄雾", "黄昏", "夜航"][index]
		_press(root, title)
		status = controller.call("get_weather_time_status") as Dictionary
		_record("weather_mode_%s" % title, int(status.get("index", -1)) == index, status.get("index"))
	for value in [0, 1, 30, 60, 120]:
		_press(root, "%dx" % value)
		status = controller.call("get_weather_time_status") as Dictionary
		_record("weather_time_%dx" % value, is_equal_approx(float(status.get("time_scale", -1.0)), float(value)), status.get("time_scale"))
	controller.call("apply_sea_state", {"time_scale": 1.0, "preserve_source": true})
	Engine.time_scale = 1.0


func _test_review_panel() -> void:
	var panel := _panel("ShipSimulationReviewPanel")
	var root := _root(panel)
	root.visible = true
	_press(root, "收起")
	_record("review_hide", not root.visible, root.visible)
	root.visible = true
	var strategy := panel.get("_strategy_option") as OptionButton
	strategy.select(1)
	strategy.item_selected.emit(1)
	_record("review_strategy_human", _label_text(panel, "mode_pill") == "人工驾驶", _label_text(panel, "mode_pill"))
	strategy.select(2)
	strategy.item_selected.emit(2)
	_record("review_strategy_rl", _label_text(panel, "mode_pill") == "RL策略", _label_text(panel, "mode_pill"))
	_press(root, "开始记录")
	_record("review_start_recording", bool(panel.get("_recording")), panel.get("_recording"))
	for _index in range(4):
		await physics_frame
	_press(root, "结束评分")
	_record("review_stop_and_score", not bool(panel.get("_recording")) and not (panel.get("_last_summary") as Dictionary).is_empty(), panel.get("_last_summary"))
	_press(root, "导出复盘")
	_record("review_export", FileAccess.file_exists("user://ship_simulation_review.json") and _label_text(panel, "record_state") == "EXPORTED", _label_text(panel, "record_state"))
	_press(root, "清空本次")
	_record("review_clear", (panel.get("_samples") as Array).is_empty() and _label_text(panel, "record_state") in ["READY", "REPORT"], _label_text(panel, "record_state"))


func _test_ais_panel() -> void:
	var panel := _panel("ShipAISFleetPanel")
	var root := _root(panel)
	var manager := _main.get_node("ShipFleetManager") as ShipFleetManager
	panel.call("show_panel")
	for _index in range(3):
		await process_frame
	var select_buttons: Array[Button] = []
	for node in root.find_children("*", "Button", true, false):
		var button := node as Button
		if button != null and button.text == "选中":
			select_buttons.append(button)
	_record("ais_rows_available", select_buttons.size() == manager.get_ship_records().size(), select_buttons.size())
	if select_buttons.size() >= 2:
		select_buttons[1].pressed.emit()
		await process_frame
		var target := manager.get_ship_records()[1] as Node3D
		_record("ais_select_ship", manager.get_selected_ship() == target, manager.get_selected_ship().name)
		var follow_buttons: Array[Button] = []
		for node in root.find_children("*", "Button", true, false):
			var button := node as Button
			if button != null and button.text == "跟随":
				follow_buttons.append(button)
		if follow_buttons.size() >= 2:
			follow_buttons[1].pressed.emit()
			await process_frame
			_record("ais_follow_ship", manager.get_controlled_ship() == target, manager.get_controlled_ship().name)
		else:
			_record("ais_follow_ship", false, follow_buttons.size())
	else:
		_record("ais_select_ship", false, select_buttons.size())
		_record("ais_follow_ship", false, select_buttons.size())
	_press(root, "收起")
	_record("ais_hide", not root.visible, root.visible)


func _test_instructor_panel() -> void:
	var panel := _panel("ShipInstructorConsolePanel")
	var root := _root(panel)
	var manager := _main.get_node("ShipFleetManager") as ShipFleetManager
	var scenario := _main.get_node("ShipScenarioController")
	var weather := _main.get_node("ShipWeatherTimeController")
	var obstacles := _main.get_node("ShipNavigationObstacles")
	panel.call("show_panel")
	_press(root, "暂停")
	_record("instructor_pause", paused, paused)
	_press(root, "继续")
	_record("instructor_resume", not paused, paused)
	for value in [0.5, 1.0, 2.0, 4.0]:
		_press(root, "%.1fx" % value)
		_record("instructor_speed_%.1fx" % value, is_equal_approx(Engine.time_scale, value), Engine.time_scale)
	Engine.time_scale = 1.0
	for index in range(2):
		var title: String = ["开放水域", "简易港口"][index]
		_press(root, title)
		var scenario_status := scenario.call("get_scenario_status") as Dictionary
		_record("instructor_scenario_%s" % title, int(scenario_status.get("index", -1)) == index, scenario_status)
	var incident_log := panel.get("_incident_log") as Array
	for title in ["碰撞", "搁浅", "动力故障", "舵机故障"]:
		var before := incident_log.size()
		_press(root, title)
		incident_log = panel.get("_incident_log") as Array
		_record("instructor_incident_%s" % title, incident_log.size() == before + 1, incident_log.size())
	var before_boxes: int = (obstacles.call("get_radar_obstacle_data") as Dictionary).get("boxes", []).size()
	_press(root, "船首障碍")
	var after_boxes: int = (obstacles.call("get_radar_obstacle_data") as Dictionary).get("boxes", []).size()
	_record("instructor_add_obstacle", after_boxes == before_boxes + 1, [before_boxes, after_boxes])
	_press(root, "清除临障")
	var cleared_boxes: int = (obstacles.call("get_radar_obstacle_data") as Dictionary).get("boxes", []).size()
	_record("instructor_clear_obstacle", cleared_boxes == before_boxes, [before_boxes, cleared_boxes])
	for index in range(4):
		var title: String = ["晴天", "薄雾", "黄昏", "夜航"][index]
		_press(root, title)
		var weather_status := weather.call("get_weather_time_status") as Dictionary
		_record("instructor_weather_%s" % title, int(weather_status.get("index", -1)) == index, weather_status.get("index"))
	_press(root, "重置受控")
	var controlled := manager.get_controlled_ship()
	_record("instructor_reset_controlled", controlled != null and absf(float(controlled.get("ship_forward_speed"))) < 0.01, controlled.get("ship_forward_speed"))
	_press(root, "重置船队")
	var fleet_stopped := true
	for ship in manager.get_ship_records():
		fleet_stopped = fleet_stopped and absf(float(ship.get("ship_forward_speed"))) < 0.01
	_record("instructor_reset_fleet", fleet_stopped, manager.get_ship_records().size())
	_press(root, "生成报告")
	_record("instructor_report", FileAccess.file_exists("user://ship_instructor_report.json") and _root(_panel("ShipSimulationReviewPanel")).visible, panel.get("_last_report_path"))

	var pills := panel.get("_labels") as Dictionary
	var run_pill := pills.get("sim_state") as Button
	run_pill.pressed.emit()
	_record("instructor_status_run_toggle", paused, paused)
	run_pill.pressed.emit()
	var scenario_before := int((scenario.call("get_scenario_status") as Dictionary).get("index", 0))
	(pills.get("scenario") as Button).pressed.emit()
	var scenario_after := int((scenario.call("get_scenario_status") as Dictionary).get("index", 0))
	_record("instructor_status_scenario_cycle", scenario_after != scenario_before, [scenario_before, scenario_after])
	var weather_before := int((weather.call("get_weather_time_status") as Dictionary).get("index", 0))
	(pills.get("weather") as Button).pressed.emit()
	var weather_after := int((weather.call("get_weather_time_status") as Dictionary).get("index", 0))
	_record("instructor_status_weather_cycle", weather_after != weather_before, [weather_before, weather_after])
	var control_before := manager.get_controlled_ship()
	(pills.get("ship") as Button).pressed.emit()
	_record("instructor_status_ship_cycle", manager.get_controlled_ship() != control_before, manager.get_controlled_ship().name)
	_press(root, "收起")
	_record("instructor_hide", not root.visible, root.visible)
	Engine.time_scale = 1.0
	paused = false


func _finish() -> void:
	if _main != null:
		var replay := _main.get_node_or_null("ShipPolicyReplayController")
		if replay != null and replay.has_method("stop_replay"):
			replay.call("stop_replay")
		var rl := _main.get_node_or_null("ShipRLControlPanel")
		if rl != null and int(rl.get("_training_process_id")) > 0:
			rl.call("_on_stop_training_run_pressed")
	Engine.time_scale = 1.0
	paused = false
	_restore_user_files()
	var passed_count := 0
	for check in _checks.values():
		if bool((check as Dictionary).get("passed", false)):
			passed_count += 1
	var payload := {
		"schema_version": "godot_button_interaction_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"checks": _checks,
		"passed_checks": passed_count,
		"total_checks": _checks.size(),
		"errors": _errors,
		"passed": _errors.is_empty(),
		"boundary": "Runtime action-outcome regression for every visible button group. The LOS-PID run is a short wiring test in an isolated output directory, not convergence or sea-trial evidence.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("BUTTON_INTERACTION_SMOKE:%s:%d/%d" % ["PASS" if _errors.is_empty() else "FAIL", passed_count, _checks.size()])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

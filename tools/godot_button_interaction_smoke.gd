extends SceneTree
# gdlint: disable=max-line-length

const REPORT_PATH := "res://reports/godot_button_interaction_smoke_v1.json"
const USER_FILES_TO_PRESERVE := [
	"user://rl_training_config.json",
	"user://rl_runs/training_parameters.json",
	"user://rl_runs/scene_v1/training_progress.json",
	"user://rl_runs/scene_v1/policy_checkpoint.json",
	"user://rl_runs/scene_v1/policy_test_trajectory.json",
	"user://ship_navigation_plan.json",
	"user://ship_simulation_review.json",
	"user://ship_instructor_report.json",
	"user://ship_full_mission_bridge_snapshot.json",
	"user://ship_bridge_cybersecurity_snapshot.json",
	"user://ship_port_integration_snapshot.json",
]

var _checks: Dictionary = {}
var _errors: Array[String] = []
var _saved_user_files: Dictionary = {}
var _main: Node
var _kept_clone: Node3D


func _initialize() -> void:
	call_deferred("_run")


func _record(name: String, passed: bool, detail: Variant) -> void:
	var public_detail: Variant = _public_value(detail)
	_checks[name] = {"passed": passed, "detail": public_detail}
	if not passed:
		_errors.append("%s: %s" % [name, str(public_detail)])


func _public_value(value: Variant) -> Variant:
	if value is Dictionary:
		var clean_dictionary := {}
		for key in value:
			clean_dictionary[key] = _public_value(value[key])
		return clean_dictionary
	if value is Array:
		var clean_array: Array = []
		for item in value:
			clean_array.append(_public_value(item))
		return clean_array
	if value is String or value is StringName:
		var project_root := ProjectSettings.globalize_path("res://").trim_suffix("/")
		var user_root := ProjectSettings.globalize_path("user://").trim_suffix("/")
		return String(value).replace(project_root + "/", "res://").replace(user_root + "/", "user://")
	return value


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


func _equipment_faults_clear(faults: Dictionary) -> bool:
	for value in faults.values():
		if value is bool and bool(value):
			return false
		if (value is float or value is int) and not is_zero_approx(float(value)):
			return false
	return true


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

	await _test_overview()
	await _test_cargo_hub()
	await _test_rl_control()
	await _test_navigation()
	_test_risk()
	await _test_weather()
	await _test_review()
	await _test_ais()
	await _test_instructor()
	_test_inventory_coverage()
	_finish()


func _test_overview() -> void:
	var panel := _panel("ShipSystemOverviewPanel")
	var root := _root(panel)
	_record("overview_present", panel != null and root != null, panel)
	if root == null:
		return
	panel.call("show_panel")
	_press(root, "关闭  M")
	_record("overview_close", not root.visible, root.visible)
	var targets := {
		"打开训练中心  ·  TRAINING CENTER": ["ShipRLControlPanel"],
		"航线规划 / 风险决策 / 海况": ["ShipNavigationPlanningPanel", "ShipRiskDecisionPanel", "ShipWeatherSeaPanel"],
		"AIS 船队态势": ["ShipAISFleetPanel"],
		"综合驾驶台 / RADAR · ARPA · ECDIS": ["ShipIntegratedBridgePanel"],
		"全任务软件船桥 / GMDSS · 推进台 · 多学员 · 360°": ["ShipFullMissionBridgePanel"],
		"多源传感融合 / RADAR · AIS · EO · IR · GNSS · INS": ["ShipMultisensorFusionPanel"],
		"执行控制闭环 / 自动舵 · 推进 · 仲裁 · 急停": ["ShipExecutionControlPanel"],
		"指定船舶数字孪生 / 海试辨识 · 误差包络": ["ShipNamedVesselTwinPanel"],
		"港内作业训练 / 靠离泊 · 拖轮 · 锚泊 · 系泊": ["ShipPortOperationsPanel"],
		"多驾驶台协同 / 通信 · 复诵 · BRM": ["ShipBridgeTeamPanel"],
		"物理驾驶台 / HIL · 标准 · 现场准入": ["ShipPhysicalBridgeReadinessPanel"],
		"安全案例 / ODD · 危险 · MRC · FTA · RCC": ["ShipSafetyCasePanel"],
		"复杂避碰规则 / 多船 · 狭水道 · 分道 · 灯号声号": ["ShipColregComplexPanel"],
		"RL 泛化可信度 / 多域 · OOD · 消融 · 压力 · 影子": ["ShipRlGeneralizationPanel"],
		"船舶网络安全 / 分区 · 身份 · 签名更新 · IDS · 恢复": ["ShipBridgeCybersecurityPanel"],
		"港口生产联动 / VTS · TOS · 引航 · 拖轮 · 泊位 · 通告": ["ShipPortIntegrationPanel"],
		"打开训练结果复盘": ["ShipSimulationReviewPanel"],
		"舷鸥全系统助手": ["ShipInstructorConsolePanel"],
	}
	for title in targets:
		panel.call("show_panel")
		_press(root, String(title))
		await process_frame
		var opened := not root.visible
		for target_name in targets[title]:
			opened = opened and _root(_panel(String(target_name))).visible
		_record("overview_open_%s" % String(title), opened, targets[title])
	panel.call("show_panel")
	var status := panel.get("_status_label") as Label
	_press(root, "训练顾问：查看算法选择依据")
	_record("overview_advisor", status.text.begins_with("舷鸥建议"), status.text)
	_press(root, "运行环境与数据边界审查")
	_record("overview_boundary", status.text.begins_with("边界审查"), status.text)
	_press(root, "校验 v2 港口数据契约")
	_record(
		"overview_contract_receipt",
		status.text.begins_with("契约校验通过") and status.text.contains("live-control=false"),
		status.text,
	)


func _test_cargo_hub() -> void:
	var panel := _panel("CargoCircuitRLPanel")
	var root := _root(panel)
	var controller := _main.get_node_or_null("CargoCircuitReplayController")
	_record("cargo_present", panel != null and root != null and controller != null, panel)
	if root == null or controller == null:
		return
	panel.call("show_panel")
	var algorithm := panel.get("_algorithm_option") as OptionButton
	var strategy := panel.get("_strategy_option") as OptionButton
	var camera := panel.get("_camera_mode_option") as OptionButton
	var algorithms: Array[String] = []
	for index in range(algorithm.item_count):
		algorithms.append(String(algorithm.get_item_metadata(index)))
		algorithm.select(index)
		algorithm.item_selected.emit(index)
	_record("cargo_algorithm_options", algorithms == ["sac", "ppo", "td3", "a2c", "ddpg", "tqc", "trpo"], algorithms)
	for index in range(camera.item_count):
		camera.select(index)
		camera.item_selected.emit(index)
		var expected := "auto_follow" if index == 0 else "free_camera"
		_record("cargo_camera_%d" % index, String(controller.call("get_replay_status").get("camera_mode", "")) == expected, controller.call("get_replay_status"))
	for index in [0, 1, 2]:
		strategy.select(index)
		strategy.item_selected.emit(index)
		_press(root, "播放所选策略")
		await physics_frame
		var replay_status := controller.call("get_replay_status") as Dictionary
		_record(
			"cargo_strategy_%d_replay" % index,
			bool(replay_status.get("active", false))
			and String(replay_status.get("dataset_split", "")) == "test"
			and (bool(replay_status.get("trained_rl", false)) == (index != 2)),
			replay_status,
		)
		controller.call("stop_replay", true)
		await process_frame
		panel.call("show_panel")
	for speed in [1, 3, 5]:
		_press(root, "%dx" % speed)
		var speed_status := controller.call("get_replay_status") as Dictionary
		_record("cargo_speed_%dx" % speed, is_equal_approx(float(speed_status.get("playback_speed", 0.0)), float(speed)), speed_status)
	_press(root, "停止并恢复原场景")
	_record("cargo_stop_restore", not bool((controller.call("get_replay_status") as Dictionary).get("active", false)), controller.call("get_replay_status"))

	var unavailable := {
		"0  人工物理可达性验收": "_on_manual_gate_pressed",
		"1  启动无渲染训练": "_on_train_pressed",
		"2  验证策略（不渲染）": "_on_validation_pressed",
		"3  测试并生成可视化": "_on_test_pressed",
		"4  重测动态策略（无渲染→播放）": "_on_dynamic_test_pressed",
	}
	for title in unavailable:
		var button := _find_button(root, String(title))
		_record("cargo_private_boundary_%s" % String(title), button != null and button.disabled and not button.tooltip_text.is_empty(), button.tooltip_text if button != null else "missing")
		panel.call(String(unavailable[title]))
		var status := panel.get("_status_label") as Label
		_record("cargo_private_guard_%s" % String(title), status.text.begins_with("● BLOCKED"), status.text)

	var module_targets := {
		"进入 RL 训练中心": "ShipRLControlPanel",
		"航线规划": "ShipNavigationPlanningPanel",
		"风险决策": "ShipRiskDecisionPanel",
		"海况与时间": "ShipWeatherSeaPanel",
		"AIS 船队态势": "ShipAISFleetPanel",
		"训练与仿真复盘": "ShipSimulationReviewPanel",
		"舷鸥系统助手": "ShipInstructorConsolePanel",
		"系统与指标总览": "ShipSystemOverviewPanel",
	}
	var return_root := panel.get("_hub_return_root") as Control
	var return_button := panel.get("_hub_return_button") as Button
	for title in module_targets:
		panel.call("show_panel")
		_press(root, String(title))
		await process_frame
		var target_root := _root(_panel(String(module_targets[title])))
		_record("cargo_open_%s" % String(title), target_root.visible and not root.visible and return_root.visible, target_root.visible)
		return_button.pressed.emit()
		await process_frame
		_record("cargo_return_%s" % String(title), root.visible and not target_root.visible, root.visible)
	_press(root, "关闭面板（H）")
	_record("cargo_close", not root.visible, root.visible)


func _test_rl_control() -> void:
	var panel := _panel("ShipRLControlPanel")
	var root := _root(panel)
	var manager := _main.get_node("ShipFleetManager") as ShipFleetManager
	panel.call("show_training_center")
	_press(root, "收起")
	_record("rl_close", not root.visible, root.visible)
	root.visible = true
	var dataset := panel.get("_dataset_profile_option") as OptionButton
	var algorithm := panel.get("_algorithm_option") as OptionButton
	var strategy := panel.get("_strategy_option") as OptionButton
	for profile_index in [0, 1]:
		dataset.select(profile_index)
		dataset.item_selected.emit(profile_index)
		_record("rl_dataset_%d_algorithms" % profile_index, algorithm.item_count == (5 if profile_index == 0 else 10), algorithm.item_count)
		for index in range(algorithm.item_count):
			algorithm.select(index)
			algorithm.item_selected.emit(index)
			var status := panel.get("_training_status_label") as Label
			_record("rl_algorithm_%d_%d" % [profile_index, index], status.text.begins_with("已选择"), status.text)
	_record("rl_strategy_inventory", strategy.item_count == 21, strategy.item_count)
	for index in range(strategy.item_count):
		strategy.select(index)
		strategy.item_selected.emit(index)
		_record("rl_strategy_select_%d" % index, strategy.selected == index, strategy.get_item_text(index))

	var initial_count := manager.get_ship_records().size()
	_press(root, "+ 新船")
	_record("rl_add_ship_mode", bool(manager.get("_dragging_new_ship")), manager.get("_dragging_new_ship"))
	manager.cancel_drag_new_ship()
	_press(root, "克隆")
	await process_frame
	_kept_clone = manager.get_selected_ship()
	_record("rl_clone_keep", manager.get_ship_records().size() == initial_count + 1, manager.get_ship_records().size())
	_press(root, "克隆")
	await process_frame
	_record("rl_clone_for_delete", manager.get_ship_records().size() == initial_count + 2, manager.get_ship_records().size())
	_press(root, "删除")
	await process_frame
	await process_frame
	_record("rl_delete", manager.get_ship_records().size() == initial_count + 1, manager.get_ship_records().size())
	manager.select_ship(_kept_clone)
	await process_frame
	_press(root, "接管选中")
	_record("rl_take_control", manager.get_controlled_ship() == _kept_clone, manager.get_controlled_ship().name)
	var before_cycle := manager.get_controlled_ship()
	_press(root, "下一艘")
	_record("rl_next_ship", manager.get_controlled_ship() != before_cycle, manager.get_controlled_ship().name)

	dataset.select(0)
	dataset.item_selected.emit(0)
	_press(root, "导出配置")
	var training_status := panel.get("_training_status_label") as Label
	_record("rl_export_config", training_status.text.begins_with("已导出:") and FileAccess.file_exists("user://rl_training_config.json"), training_status.text)
	_press(root, "算法/环境设置")
	var settings := panel.get("_training_settings_overlay") as Control
	_record("rl_settings_open", settings.visible, settings.visible)
	_press(settings, "预览安全边界")
	_record("rl_settings_preview", training_status.text.begins_with("场景已显示训练安全包络"), training_status.text)
	var parameter_controls := panel.get("_rl_parameter_controls") as Dictionary
	var parameter_values := panel.get("_rl_parameter_values") as Dictionary
	for key in ["terminate_on_collision", "merge_scene_obstacles", "domain_randomization", "randomize_evaluation"]:
		var checkbox := parameter_controls.get(key) as CheckBox
		var next_value := not checkbox.button_pressed
		checkbox.set_pressed(next_value)
		_record("rl_setting_%s" % key, bool(parameter_values.get(key, not next_value)) == next_value, parameter_values.get(key))
	_press(settings, "恢复默认")
	_record("rl_settings_reset", is_equal_approx(float((panel.get("_rl_parameter_values") as Dictionary).get("learning_rate", 0.0)), 0.0003), panel.get("_rl_parameter_values"))
	_press(settings, "应用")
	_record("rl_settings_apply", not settings.visible and training_status.text.begins_with("环境已应用"), training_status.text)
	_press(root, "算法/环境设置")
	_press(settings, "关闭")
	_record("rl_settings_close", not settings.visible, settings.visible)

	var los_index := -1
	for index in range(algorithm.item_count):
		if algorithm.get_item_text(index) == "los_pid":
			los_index = index
	algorithm.select(los_index)
	algorithm.item_selected.emit(los_index)
	(panel.get("_episode_spin") as SpinBox).value = 1
	(panel.get("_step_spin") as SpinBox).value = 100
	(panel.get("_agent_spin") as SpinBox).value = 1
	_press(root, "启动训练")
	var training_overlay := panel.get("_training_overlay") as Control
	_record("rl_training_started", bool(panel.get("_training_run_active")) and training_overlay.visible, training_status.text)
	_press(training_overlay, "终止")
	_record("rl_training_terminated", not bool(panel.get("_training_run_active")) and not training_overlay.visible, training_status.text)

	dataset.select(0)
	dataset.item_selected.emit(0)
	strategy.select(0)
	strategy.item_selected.emit(0)
	_press(root, "运行测试集并渲染")
	await physics_frame
	var replay := _main.get_node("ShipPolicyReplayController")
	_record("rl_frozen_replay", bool(replay.call("is_replay_active")), replay.call("get_replay_status"))
	_press(root, "停止策略回放")
	_record("rl_replay_stop", not bool(replay.call("is_replay_active")), training_status.text)
	training_overlay.visible = true
	_press(training_overlay, "执行本次训练策略")
	await physics_frame
	_record("rl_overlay_replay", bool(replay.call("is_replay_active")), replay.call("get_replay_status"))
	replay.call("stop_replay")
	training_overlay.visible = true
	_press(training_overlay, "关闭")
	_record("rl_overlay_close", not training_overlay.visible, training_overlay.visible)


func _test_navigation() -> void:
	var panel := _panel("ShipNavigationPlanningPanel")
	var root := _root(panel)
	panel.call("show_panel")
	_press(root, "收起")
	_record("navigation_close", not root.visible, root.visible)
	root.visible = true
	var mission := panel.get("_mission_option") as OptionButton
	for index in range(mission.item_count):
		mission.select(index)
		mission.item_selected.emit(index)
		_record("navigation_mission_%d" % index, _label_text(panel, "mission_footer").begins_with("任务参数已载入"), _label_text(panel, "mission_footer"))
	var sync := panel.get("_sync_scenario_check") as CheckBox
	var teleport := panel.get("_teleport_check") as CheckBox
	sync.set_pressed(false)
	teleport.set_pressed(false)
	_record("navigation_link_toggles", _label_text(panel, "mission_footer").begins_with("联动选项已变更"), _label_text(panel, "mission_footer"))
	sync.set_pressed(true)
	teleport.set_pressed(true)
	_press(root, "应用任务")
	var route := _main.get_node("ShipRouteSystem")
	var radar := route.call("get_radar_route_data") as Dictionary
	_record("navigation_apply_mission", bool(radar.get("active", false)) and FileAccess.file_exists("user://ship_navigation_plan.json"), radar)
	var loop := panel.get("_loop_check") as CheckBox
	loop.set_pressed(not loop.button_pressed)
	_press(root, "应用航线参数")
	radar = route.call("get_radar_route_data") as Dictionary
	_record("navigation_apply_settings", bool(radar.get("loop", false)) == loop.button_pressed, radar)
	_press(root, "导出任务快照")
	_record("navigation_export", _label_text(panel, "mission_footer").begins_with("任务快照已导出"), _label_text(panel, "mission_footer"))


func _test_risk() -> void:
	var panel := _panel("ShipRiskDecisionPanel")
	var root := _root(panel)
	panel.call("show_panel")
	_press(root, "收起")
	_record("risk_close", not root.visible, root.visible)
	root.visible = true
	var expected := {"标准": 52.0, "保守": 72.0, "港口": 34.0, "夜航": 86.0}
	for title in expected:
		_press(root, String(title))
		_record("risk_%s" % String(title), is_equal_approx(float(panel.get("safe_clearance_meters")), float(expected[title])), panel.get("safe_clearance_meters"))
	_press(root, "刷新验证结果")
	_record("risk_refresh", _label_text(panel, "validation_status") != "--", _label_text(panel, "validation_status"))


func _test_weather() -> void:
	var panel := _panel("ShipWeatherSeaPanel")
	var root := _root(panel)
	var controller := _main.get_node("ShipWeatherTimeController")
	panel.call("show_panel")
	_press(root, "收起")
	_record("weather_close", not root.visible, root.visible)
	root.visible = true
	_press(root, "刷新公开数据")
	var status := controller.call("get_weather_time_status") as Dictionary
	_record("weather_refresh", String(status.get("data_status", "")) in ["refreshing", "live", "cache_fallback", "cache"], status)
	for index in range(4):
		var title: String = ["晴天", "薄雾", "黄昏", "夜航"][index]
		_press(root, title)
		status = controller.call("get_weather_time_status") as Dictionary
		_record("weather_%s" % title, int(status.get("index", -1)) == index, status.get("index"))
	for value in [0, 1, 30, 60, 120]:
		_press(root, "%dx" % value)
		status = controller.call("get_weather_time_status") as Dictionary
		_record("weather_time_%d" % value, is_equal_approx(float(status.get("time_scale", -1.0)), float(value)), status.get("time_scale"))
	controller.call("apply_mode", 0)
	controller.call("apply_sea_state", {"time_scale": 1.0, "preserve_source": true})
	Engine.time_scale = 1.0


func _test_review() -> void:
	var panel := _panel("ShipSimulationReviewPanel")
	var root := _root(panel)
	panel.call("show_panel")
	_press(root, "收起")
	_record("review_close", not root.visible, root.visible)
	root.visible = true
	var strategy := panel.get("_strategy_option") as OptionButton
	for index in range(strategy.item_count):
		strategy.select(index)
		strategy.item_selected.emit(index)
		_record("review_strategy_%d" % index, _label_text(panel, "mode_pill") in ["人工驾驶", "RL策略"], _label_text(panel, "mode_pill"))
	_press(root, "开始记录")
	_record("review_start", bool(panel.get("_recording")), panel.get("_recording"))
	for _index in range(4):
		await physics_frame
	_press(root, "结束评分")
	_record("review_score", not bool(panel.get("_recording")) and not (panel.get("_last_summary") as Dictionary).is_empty(), panel.get("_last_summary"))
	_press(root, "导出复盘")
	_record("review_export", FileAccess.file_exists("user://ship_simulation_review.json") and _label_text(panel, "record_state") == "EXPORTED", _label_text(panel, "record_state"))
	_press(root, "清空本次")
	_record("review_clear", (panel.get("_samples") as Array).is_empty(), panel.get("_samples"))


func _test_ais() -> void:
	var panel := _panel("ShipAISFleetPanel")
	var root := _root(panel)
	var manager := _main.get_node("ShipFleetManager") as ShipFleetManager
	panel.call("show_panel")
	for _index in range(3):
		await process_frame
	var select_buttons: Array[Button] = []
	var follow_buttons: Array[Button] = []
	for node in root.find_children("*", "Button", true, false):
		var button := node as Button
		if button.text == "选中":
			select_buttons.append(button)
		elif button.text == "跟随":
			follow_buttons.append(button)
	_record("ais_rows", select_buttons.size() == manager.get_ship_records().size() and follow_buttons.size() == select_buttons.size(), [select_buttons.size(), follow_buttons.size()])
	if select_buttons.size() >= 2:
		select_buttons[1].pressed.emit()
		await process_frame
		var target := manager.get_ship_records()[1]
		_record("ais_select", manager.get_selected_ship() == target, manager.get_selected_ship().name)
		follow_buttons.clear()
		for node in root.find_children("*", "Button", true, false):
			var refreshed_button := node as Button
			if refreshed_button != null and refreshed_button.text == "跟随":
				follow_buttons.append(refreshed_button)
		if follow_buttons.size() < 2:
			_record("ais_follow", false, follow_buttons.size())
			return
		follow_buttons[1].pressed.emit()
		await process_frame
		_record("ais_follow", manager.get_controlled_ship() == target, manager.get_controlled_ship().name)
	else:
		_record("ais_select", false, select_buttons.size())
		_record("ais_follow", false, follow_buttons.size())
	_press(root, "收起")
	_record("ais_close", not root.visible, root.visible)


func _test_instructor() -> void:
	var panel := _panel("ShipInstructorConsolePanel")
	var root := _root(panel)
	var manager := _main.get_node("ShipFleetManager") as ShipFleetManager
	var scenario := _main.get_node("ShipScenarioController")
	var weather := _main.get_node("ShipWeatherTimeController")
	var obstacles := _main.get_node("ShipNavigationObstacles")
	var equipment := _main.get_node("ShipNavigationEquipmentSuite")
	var exercise := _main.get_node("ShipInstructorExerciseController")
	panel.call("show_panel")
	_press(root, "暂停")
	_record("instructor_pause", paused, paused)
	_press(root, "继续")
	_record("instructor_continue", not paused, paused)
	for speed in [0.5, 1.0, 2.0, 4.0]:
		_press(root, "%.1fx" % speed)
		_record("instructor_speed_%.1f" % speed, is_equal_approx(Engine.time_scale, speed), Engine.time_scale)
	Engine.time_scale = 1.0
	for index in range(2):
		var title: String = ["开放水域", "简易港口"][index]
		_press(root, title)
		_record("instructor_scene_%s" % title, int((scenario.call("get_scenario_status") as Dictionary).get("index", -1)) == index, scenario.call("get_scenario_status"))
	var incident_log := panel.get("_incident_log") as Array
	for title in ["碰撞", "搁浅", "动力故障", "舵机故障"]:
		var before := incident_log.size()
		_press(root, title)
		incident_log = panel.get("_incident_log") as Array
		_record("instructor_incident_%s" % title, incident_log.size() == before + 1, incident_log.size())
	var before_boxes := ((obstacles.call("get_radar_obstacle_data") as Dictionary).get("boxes", []) as Array).size()
	_press(root, "船首障碍")
	var added_boxes := ((obstacles.call("get_radar_obstacle_data") as Dictionary).get("boxes", []) as Array).size()
	_record("instructor_obstacle_add", added_boxes == before_boxes + 1, [before_boxes, added_boxes])
	_press(root, "清除临障")
	var cleared_boxes := ((obstacles.call("get_radar_obstacle_data") as Dictionary).get("boxes", []) as Array).size()
	_record("instructor_obstacle_clear", cleared_boxes == before_boxes, [before_boxes, cleared_boxes])
	for index in range(4):
		var title: String = ["晴天", "薄雾", "黄昏", "夜航"][index]
		_press(root, title)
		_record("instructor_weather_%s" % title, int((weather.call("get_weather_time_status") as Dictionary).get("index", -1)) == index, weather.call("get_weather_time_status"))
	_press(root, "雷达黑屏")
	_record("instructor_equipment_radar_fault", bool((equipment.call("get_fault_state") as Dictionary).get("radar_power_loss", false)), equipment.call("get_fault_state"))
	_press(root, "AIS 丢失")
	_record("instructor_equipment_ais_fault", bool((equipment.call("get_fault_state") as Dictionary).get("ais_loss", false)), equipment.call("get_fault_state"))
	_press(root, "罗经 +7.5°")
	_record("instructor_equipment_gyro_bias", is_equal_approx(float((equipment.call("get_fault_state") as Dictionary).get("gyro_bias_deg", 0.0)), 7.5), equipment.call("get_fault_state"))
	_press(root, "恢复设备")
	var restored_faults := equipment.call("get_fault_state") as Dictionary
	_record("instructor_equipment_restore", _equipment_faults_clear(restored_faults), restored_faults)
	_press(root, "受限能见度")
	var exercise_snapshot := exercise.call("get_exercise_snapshot") as Dictionary
	_record("instructor_timeline_load_visibility", String(exercise_snapshot.get("template_key", "")) == "restricted_visibility_bridge", exercise_snapshot.get("template_key"))
	_press(root, "启动时间线")
	exercise_snapshot = exercise.call("get_exercise_snapshot") as Dictionary
	_record("instructor_timeline_start", bool(exercise_snapshot.get("running", false)) and int(exercise_snapshot.get("next_event_index", 0)) >= 1, exercise_snapshot)
	_press(root, "下一事件")
	_record("instructor_timeline_next_event", bool((equipment.call("get_fault_state") as Dictionary).get("radar_power_loss", false)), equipment.call("get_fault_state"))
	_press(root, "暂停时间线")
	_record("instructor_timeline_pause", not bool((exercise.call("get_exercise_snapshot") as Dictionary).get("running", true)), exercise.call("get_exercise_snapshot"))
	_press(root, "复位时间线")
	_record("instructor_timeline_reset", int((exercise.call("get_exercise_snapshot") as Dictionary).get("next_event_index", -1)) == 0 and not bool((equipment.call("get_fault_state") as Dictionary).get("radar_power_loss", true)), exercise.call("get_exercise_snapshot"))
	_press(root, "传感器矛盾")
	_record("instructor_timeline_load_disagreement", String((exercise.call("get_exercise_snapshot") as Dictionary).get("template_key", "")) == "sensor_disagreement", exercise.call("get_exercise_snapshot"))
	_press(root, "重置受控")
	var controlled := manager.get_controlled_ship()
	_record("instructor_reset_controlled", controlled != null and absf(float(controlled.get("ship_forward_speed"))) < 0.01, controlled.get("ship_forward_speed"))
	_press(root, "重置船队")
	var stopped := true
	for ship in manager.get_ship_records():
		stopped = stopped and absf(float(ship.get("ship_forward_speed"))) < 0.01
	_record("instructor_reset_fleet", stopped, manager.get_ship_records().size())
	_press(root, "生成报告")
	_record("instructor_report", FileAccess.file_exists("user://ship_instructor_report.json") and _root(_panel("ShipSimulationReviewPanel")).visible, panel.get("_last_report_path"))
	var pills := panel.get("_labels") as Dictionary
	(pills.get("sim_state") as Button).pressed.emit()
	_record("instructor_pill_run", paused, paused)
	(pills.get("sim_state") as Button).pressed.emit()
	var scenario_before := int((scenario.call("get_scenario_status") as Dictionary).get("index", 0))
	(pills.get("scenario") as Button).pressed.emit()
	_record("instructor_pill_scene", int((scenario.call("get_scenario_status") as Dictionary).get("index", 0)) != scenario_before, scenario.call("get_scenario_status"))
	var weather_before := int((weather.call("get_weather_time_status") as Dictionary).get("index", 0))
	(pills.get("weather") as Button).pressed.emit()
	_record("instructor_pill_weather", int((weather.call("get_weather_time_status") as Dictionary).get("index", 0)) != weather_before, weather.call("get_weather_time_status"))
	var ship_before := manager.get_controlled_ship()
	(pills.get("ship") as Button).pressed.emit()
	_record("instructor_pill_ship", manager.get_controlled_ship() != ship_before, manager.get_controlled_ship().name)
	_press(root, "收起")
	_record("instructor_close", not root.visible, root.visible)


func _test_inventory_coverage() -> void:
	var inventory := _read_json("res://reports/godot_button_inventory_v1.json")
	_record(
		"runtime_inventory_coverage",
		bool(inventory.get("passed", false)) and int(inventory.get("button_count", 0)) >= 130,
		{"button_count": inventory.get("button_count", 0), "errors": inventory.get("errors", [])},
	)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed as Dictionary if parsed is Dictionary else {}


func _finish() -> void:
	if _main != null:
		var cargo := _main.get_node_or_null("CargoCircuitReplayController")
		if cargo != null and cargo.has_method("stop_replay"):
			cargo.call("stop_replay", true)
		var replay := _main.get_node_or_null("ShipPolicyReplayController")
		if replay != null and replay.has_method("stop_replay"):
			replay.call("stop_replay")
		var rl := _main.get_node_or_null("ShipRLControlPanel")
		if rl != null and int(rl.get("_training_process_id")) > 0:
			rl.call("_on_stop_training_run_pressed")
		if _kept_clone != null and is_instance_valid(_kept_clone):
			var manager := _main.get_node_or_null("ShipFleetManager") as ShipFleetManager
			if manager != null:
				manager.select_ship(_kept_clone)
				manager.delete_selected_ship()
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
		"boundary": "Runtime action-outcome regression for every visible button group. The short LOS-PID process is immediately terminated after launch to verify busy-state/termination wiring; it is not convergence or sea-trial evidence.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("BUTTON_INTERACTION_SMOKE:%s:%d/%d" % ["PASS" if _errors.is_empty() else "FAIL", passed_count, _checks.size()])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

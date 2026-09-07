extends SceneTree
## Exercise native mouse hit testing and actual scene-policy takeovers.
## Rejection/failure fixtures are UI checks, never policy success evidence.
var report_path := ""
var capture_dir := ""
var checks: Array = []
var panel: Node
var controller: Node
var scenarios: Node
var button: Button
var option: OptionButton
var ui_source_sha256 := ""

func _initialize() -> void:
	call_deferred("run")

func record(name: String, passed: bool, detail: Variant = null) -> void:
	checks.append({"name": name, "passed": passed, "detail": detail})
	print("MISSION_RL_UI_CHECK:", name, ":", "PASS" if passed else "FAIL")
	if not passed:
		print("MISSION_RL_UI_FAILURE:", detail)

func state() -> String:
	panel.call("_update_panel")
	return String(panel.get("_mission_rl_display_state"))

func snapshot() -> Dictionary:
	return {"state": state(), "button": button.text, "disabled": button.disabled,
		"pressed": button.button_pressed, "message": (panel.get("_mission_rl_label") as Label).text,
		"active": controller.get("active"), "status": controller.get("status")}

func click(target: Button) -> void:
	var position := target.get_global_rect().get_center()
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = position
		event.global_position = position
		event.pressed = pressed
		root.push_input(event, true)
		await process_frame

func find_button(title: String) -> Button:
	for child in panel.find_children("*", "Button", true, false):
		if (child as Button).text == title:
			return child as Button
	return null

func apply_task(index: int, automatic: bool = false) -> void:
	if not automatic:
		controller.set("auto_switch", false)
		controller.call("stop", "UI 验收切换")
	option.select(index)
	option.item_selected.emit(index)
	await click(find_button("应用任务"))
	for i in range(6):
		await physics_frame
	panel.call("_update_panel")

func capture(name: String) -> void:
	if capture_dir.is_empty():
		return
	await process_frame
	await RenderingServer.frame_post_draw
	var file_path := capture_dir.path_join(name + ".png")
	var error := root.get_texture().get_image().save_png(file_path)
	record("capture_" + name, error == OK, file_path)

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			report_path = arg.trim_prefix("--output=")
		if arg.begins_with("--capture-dir="):
			capture_dir = arg.trim_prefix("--capture-dir=")
	if report_path.is_empty() or FileAccess.file_exists(report_path):
		push_error("Provide a new --output path; existing acceptance receipts are preserved.")
		quit(2)
		return
	ui_source_sha256 = FileAccess.get_sha256("res://scripts/ui/ship_navigation_planning_panel.gd")
	change_scene_to_file("res://main.tscn")
	for i in range(24):
		await process_frame
	panel = current_scene.get_node("ShipNavigationPlanningPanel")
	controller = current_scene.get_node("MissionRLController")
	scenarios = current_scene.get_node("ShipScenarioController")
	button = panel.get("_mission_rl_button") as Button
	option = panel.get("_mission_option") as OptionButton
	panel.call("show_panel")
	var presets := panel.get("_mission_presets") as Array
	var qualified: Array[int] = []
	var berthing_index := -1
	var blocked_index := -1
	for index in range(presets.size()):
		await apply_task(index)
		var key := String(presets[index].get("scenario_key", ""))
		var entry := controller.call("current_strategy") as Dictionary
		var config := scenarios.call("get_current_scenario_config") as Dictionary
		var spawn := config.get("spawn", {}) as Dictionary
		var own := current_scene.get_node("ShipFleetManager").call("get_controlled_ship") as Node3D
		var spawn_error := Vector2(own.global_position.x - float(spawn["x"]), own.global_position.z - float(spawn["z"])).length()
		record(key + "_applied_spawn_matches_scene", spawn_error < 1.0, spawn_error)
		if key == "auto_berthing":
			berthing_index = index
		if not bool(entry.get("live_switch_admitted", false)):
			blocked_index = index
			record(key + "_unavailable_reason", state() == "unavailable" and button.disabled and button.text.contains("未通过"), snapshot())
			await click(button)
			record(key + "_blocked_click", not bool(controller.get("active")), snapshot())
			await capture("unavailable")
			continue
		qualified.append(index)
		record(key + "_ready", state() == "ready" and not button.disabled, snapshot())
		if key == "auto_berthing":
			await capture("ready")
		await click(button)
		record(key + "_click_acknowledged", state() in ["starting", "running"], snapshot())
		# A repeated request while pending cannot toggle or launch a second job.
		if state() == "starting":
			panel.call("_on_mission_rl_pressed")
		await create_timer(0.3).timeout
		record(key + "_running", state() == "running" and button.button_pressed and bool(controller.get("active")), snapshot())
		record(key + "_neural_commands", bool(controller.get("active")) and int(controller.get("inference_count")) > 0 and (controller.get("actor") as Dictionary).get("scenario") == key, controller.get("last_action"))
		if key == "auto_berthing":
			await capture("running")
		await click(button)
		await create_timer(0.3).timeout
		record(key + "_stop_persists", state() == "stopped" and not button.button_pressed and not bool(controller.get("active")), snapshot())
		if key == "auto_berthing":
			await capture("stopped")

	# Check every qualified destination through the actual Apply button.
	for index in qualified:
		await apply_task(index, true)
		if index == qualified[0]:
			await click(button)
			await create_timer(0.3).timeout
		var actor := controller.get("actor") as Dictionary
		record("auto_switch_" + str(index), state() == "running" and actor.get("scenario") == presets[index].get("scenario_key"), snapshot())
	await apply_task(blocked_index, true)
	record("auto_switch_unqualified", state() == "unavailable" and not bool(controller.get("active")), snapshot())

	await apply_task(berthing_index)
	option.select(blocked_index)
	option.item_selected.emit(blocked_index)
	record("selected_but_not_applied", state() == "unapplied" and button.disabled, snapshot())
	await click(button)
	record("unapplied_click_cannot_start_previous_task", not bool(controller.get("active")), snapshot())

	await apply_task(berthing_index)
	await click(button)
	# Change selection during the acknowledgement delay: the old click is cancelled.
	option.select(blocked_index)
	option.item_selected.emit(blocked_index)
	await create_timer(0.3).timeout
	record("pending_start_cancelled_by_selection", state() == "unapplied" and not bool(controller.get("active")), snapshot())

	await apply_task(berthing_index)
	var ship := current_scene.get_node("ShipFleetManager").call("get_controlled_ship") as Node3D
	ship.global_position += Vector3(8, 0, 0)
	await click(button)
	await create_timer(0.3).timeout
	record("outside_spawn_rejected_visibly", state() == "rejected" and not bool(controller.get("active")) and button.text.contains("失败"), snapshot())
	await capture("rejected")
	await create_timer(0.3).timeout
	record("rejection_persists_after_refresh", state() == "rejected", snapshot())

	await apply_task(berthing_index)
	await click(button)
	await create_timer(0.3).timeout
	record("reset_and_retry", state() == "running", snapshot())
	controller.call("stop", "任务失败：发生碰撞")
	await create_timer(0.3).timeout
	record("failure_fixture_persists", state() == "failed" and button.disabled, snapshot())
	await capture("failure_fixture")

	# Real complete berthing episode: no relocation after the initial Apply.
	await apply_task(berthing_index)
	await click(button)
	await create_timer(0.3).timeout
	var frames := 0
	while bool(controller.get("active")) and frames < 9000:
		await physics_frame
		frames += 1
		if frames % 1800 == 0:
			print("MISSION_RL_UI_BERTHING_PROGRESS:", frames)
	await create_timer(0.3).timeout
	record("real_berthing_completion_visible", state() == "completed" and button.disabled and not bool(controller.get("active")), snapshot())
	await capture("completed")
	panel.call("hide_panel")
	panel.call("show_panel")
	record("completion_survives_panel_reopen", state() == "completed", snapshot())
	await apply_task(berthing_index)
	await create_timer(0.3).timeout
	record("completed_task_can_be_reapplied", state() in ["ready", "running"], snapshot())
	controller.set("auto_switch", false)
	controller.call("stop", "UI 验收完成")
	record("ui_source_unchanged_during_execution", ui_source_sha256 == FileAccess.get_sha256("res://scripts/ui/ship_navigation_planning_panel.gd"))
	var passed := true
	for check in checks:
		passed = passed and bool(check["passed"])
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"schema_version": "mission_rl_ui_acceptance_v1", "passed": passed,
		"checks": checks, "qualified_scenarios": qualified.size(), "all_task_count": presets.size(),
		"input_method": "native_viewport_mouse_events", "berthing_completion": "actual_neural_closed_loop",
		"fixtures": ["spawn_offset_for_rejection", "injected_collision_stop_for_failure_display"],
		"ui_source_sha256": ui_source_sha256,
		"production_authority": false}, "\t"))
	file.close()
	print("MISSION_RL_UI:", "PASS" if passed else "FAIL", ":", checks.size())
	quit(0 if passed else 1)

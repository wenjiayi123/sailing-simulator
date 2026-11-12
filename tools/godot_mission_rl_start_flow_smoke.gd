extends SceneTree
## Native panel startup for every scene; complete overtaking from the real spawn.
var checks: Array = []
var panel: Node
var controller: Node
var mission: Node
var button: Button
var agreement: CheckBox

func _initialize() -> void:
	call_deferred("run")

func record(name: String, passed: bool, detail: Variant = null) -> void:
	checks.append({"name": name, "passed": passed, "detail": detail})
	print("START_FLOW:", name, ":", passed, ":", detail if not passed else "")

func apply(key: String) -> void:
	controller.set("auto_switch", false)
	controller.call("stop")
	var presets := panel.get("_mission_presets") as Array
	for index in range(presets.size()):
		if String(presets[index].get("scenario_key", "")) == key:
			var option := panel.get("_mission_option") as OptionButton
			option.select(index)
			option.item_selected.emit(index)
			(panel.get("_sync_scenario_check") as CheckBox).set_pressed_no_signal(true)
			(panel.get("_teleport_check") as CheckBox).set_pressed_no_signal(true)
			panel.call("_on_apply_mission_pressed")
			return

func settle_start() -> void:
	for frame in range(90):
		await physics_frame
		if bool(controller.get("active")) and int(controller.get("inference_count")) > 0:
			return

func run() -> void:
	change_scene_to_file("res://main.tscn")
	for frame in range(24):
		await process_frame
	panel = current_scene.get_node("ShipNavigationPlanningPanel")
	controller = current_scene.get_node("MissionRLController")
	mission = current_scene.get_node("ShipAdvancedMissionController")
	button = panel.get("_mission_rl_button") as Button
	agreement = panel.get("_overtaking_agreement_check") as CheckBox
	var catalog := JSON.parse_string(FileAccess.get_file_as_string("res://data/rl/mission_rl_catalog_v1.json")) as Dictionary
	for key in ["open_water", "harbor", "auto_berthing", "auto_unberthing", "narrow_channel_head_on", "crossing_starboard", "narrow_channel_overtaking"]:
		apply(key)
		button.pressed.emit()
		await settle_start()
		var entry := (catalog["scenarios"] as Dictionary)[key] as Dictionary
		record("trained_network_start_" + key, bool(controller.get("active")) and String(controller.get("key")) == key and int(entry.get("actor_critic_updates", 0)) > 0, controller.get("status"))
	apply("narrow_channel_overtaking")
	# Reproduce the old missing-agreement rejection through the native gate.
	record("unconfirmed_direct_start_blocked", not bool(controller.call("start_current")))
	panel.set("_mission_rl_start_error", controller.get("status"))
	panel.call("_update_panel")
	record("agreement_is_prerequisite_not_training_failure", String(panel.get("_mission_rl_display_state")) == "agreement_required" and button.text.contains("确认模拟协议"))
	agreement.set_pressed(true)
	record("manual_confirmation_clears_stale_error", String(panel.get("_mission_rl_start_error")).is_empty() and String(panel.get("_mission_rl_display_state")) == "ready")
	apply("narrow_channel_overtaking")
	button.pressed.emit()
	agreement.set_pressed(false)
	for frame in range(12):
		await physics_frame
	record("revocation_cancels_pending_start", not bool(controller.get("active")) and not bool(panel.get("_mission_rl_pending")))
	apply("narrow_channel_overtaking")
	button.pressed.emit()
	await settle_start()
	agreement.set_pressed(false)
	record("revocation_stops_active_policy", not bool(controller.get("active")))
	apply("narrow_channel_overtaking")
	button.pressed.emit()
	await settle_start()
	var snapshot := mission.call("get_advanced_mission_snapshot") as Dictionary
	record("one_click_confirms_and_starts", bool(controller.get("active")) and bool(snapshot.get("overtaking_agreement_confirmed", false)) and agreement.button_pressed)
	# Suspend display refresh only after checking the actual panel flow.
	for layer in current_scene.find_children("*", "CanvasLayer", true, false):
		layer.process_mode = Node.PROCESS_MODE_DISABLED
	var frames := 0
	while bool(controller.get("active")) and frames < 9000:
		await physics_frame
		frames += 1
		if frames % 1800 == 0:
			print("OVERTAKING_PROGRESS:", frames, ":", controller.get("waypoint"))
	snapshot = mission.call("get_advanced_mission_snapshot") as Dictionary
	var behavior := snapshot.get("behavioral_assessment", {}) as Dictionary
	record("overtaking_mission_completed", String(controller.get("status")) == "强化学习任务完成" and bool(behavior.get("passed", false)), controller.get("status"))
	var passed := checks.all(func(row: Dictionary) -> bool: return bool(row["passed"]))
	var file := FileAccess.open("res://reports/mission_rl_start_flow_20261020.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed": passed, "checks": checks, "ui_source_sha256": FileAccess.get_sha256("res://scripts/ui/ship_navigation_planning_panel.gd"), "mission": snapshot, "inference_count": controller.get("inference_count"), "elapsed_seconds": controller.get("elapsed"), "production_authority": false}, "\t"))
	file.close()
	print("MISSION_RL_START_FLOW:", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)

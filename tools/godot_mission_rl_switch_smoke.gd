extends SceneTree
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	change_scene_to_file("res://main.tscn")
	for i in range(24):
		await process_frame
	var main := current_scene
	var scenes := main.get_node("ShipScenarioController")
	var fleet := main.get_node("ShipFleetManager")
	var controller := main.get_node("MissionRLController")
	var panel := main.get_node("ShipNavigationPlanningPanel")
	var rows: Array = []
	for key in ["narrow_channel_head_on", "crossing_starboard", "narrow_channel_overtaking", "auto_unberthing", "narrow_channel_head_on"]:
		controller.set("auto_switch", false)
		controller.call("stop", "切换回归")
		scenes.call("apply_scenario", scenes.call("get_scenario_index_by_key", key), true)
		for i in range(6):
			await physics_frame
		var config := scenes.call("get_current_scenario_config") as Dictionary
		var spawn := config.get("spawn", {}) as Dictionary
		var own := fleet.call("get_controlled_ship") as Node3D
		var distance := Vector2(own.global_position.x-float(spawn["x"]), own.global_position.z-float(spawn["z"])).length()
		var armed := true
		for target in get_nodes_in_group(&"ship_advanced_mission_traffic"):
			armed = armed and target.collision_layer != 0 and target.collision_mask != 0
		var presets := panel.get("_mission_presets") as Array
		var selection := (panel.get("_mission_option") as OptionButton).selected
		var panel_matches: bool = (presets[selection] as Dictionary).get("scenario_key") == key
		rows.append({"scenario":key,"initial_spawn_error_m":distance,"target_collision_armed":armed,"panel_matches_scene":panel_matches,"passed":distance<1.0 and armed and panel_matches})
	var entry := controller.call("current_strategy") as Dictionary
	var available := bool(entry.get("live_switch_admitted", false))
	var started := bool(controller.call("start_current"))
	rows.append({"check":"qualified_strategy_start","passed":started and available,"started":started})
	if started:
		scenes.call("apply_scenario", scenes.call("get_scenario_index_by_key", "crossing_starboard"), true)
		for i in range(6):
			await physics_frame
		var next_entry := controller.call("current_strategy") as Dictionary
		var matching: bool = (controller.get("actor") as Dictionary).get("scenario") == "crossing_starboard"
		rows.append({"check":"automatic_matching_scene_switch","passed":bool(controller.get("active")) and bool(next_entry.get("live_switch_admitted", false)) and matching,"strategy":(controller.get("actor") as Dictionary).get("scenario")})
		scenes.call("apply_scenario", scenes.call("get_scenario_index_by_key", "narrow_channel_overtaking"), true)
		for i in range(6):
			await physics_frame
		var overtaking_entry := controller.call("current_strategy") as Dictionary
		if not bool(overtaking_entry.get("live_switch_admitted", false)):
			rows.append({"check":"unqualified_scene_cannot_take_control","passed":not bool(controller.get("active")) and not bool(controller.call("start_current"))})
	controller.call("stop", "回归结束")
	var all_passed := true
	for row in rows:
		all_passed = all_passed and bool(row["passed"])
	var f := FileAccess.open("res://reports/mission_rl_switch_smoke_v1.json",FileAccess.WRITE)
	f.store_string(JSON.stringify({"passed":all_passed,"checks":rows,"production_authority":false},"\t"));f.close()
	print("MISSION_RL_SWITCH:","PASS" if all_passed else "FAIL")
	quit(0 if all_passed else 1)

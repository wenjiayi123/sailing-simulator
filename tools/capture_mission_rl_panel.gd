extends SceneTree
## Render the actual navigation panel with the qualified RL action visible.
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	change_scene_to_file("res://main.tscn")
	for i in range(36):
		await process_frame
	var scenes := current_scene.get_node("ShipScenarioController")
	scenes.call("apply_scenario", scenes.call("get_scenario_index_by_key", "auto_berthing"), true)
	var panel := current_scene.get_node("ShipNavigationPlanningPanel")
	panel.call("show_panel")
	for i in range(12):
		await process_frame
	var screenshot := root.get_texture().get_image()
	var result := screenshot.save_png("res://reports/artifacts/mission_rl_v1/navigation_rl_panel.png")
	print("MISSION_RL_PANEL_CAPTURE:", result)
	panel.call("_on_mission_rl_pressed")
	for i in range(12):
		await process_frame
	var active_image := root.get_texture().get_image()
	active_image.save_png("res://reports/artifacts/mission_rl_v1/navigation_rl_active_panel.png")
	print("MISSION_RL_PANEL_STARTED:",current_scene.get_node("MissionRLController").get("active"))
	quit(result)

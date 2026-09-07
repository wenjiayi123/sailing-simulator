extends SceneTree
class TestShip:
	extends Node3D
	var surge := 2.0
	func get_ship_telemetry() -> Dictionary:
		return {"speed":4.0,"surge_mps":surge,"heading_degrees":0.0}
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	change_scene_to_file("res://main.tscn")
	for i in range(24):
		await process_frame
	var scenarios := current_scene.get_node("ShipScenarioController")
	scenarios.call("apply_scenario",scenarios.call("get_scenario_index_by_key","narrow_channel_overtaking"),true)
	var realism := current_scene.get_node("ShipAdvancedMissionRealismController")
	var mock := TestShip.new()
	current_scene.add_child(mock)
	var rows: Array = []
	for surge in [2.0,-2.0,0.0]:
		mock.surge = surge
		var actual := realism.call("get_hydrodynamic_forcing",mock) as Dictionary
		var expected := realism.call("evaluate_hydrodynamic_state",Vector3.ZERO,0.0,surge) as Dictionary
		var force := actual.get("hydrodynamic_force_body_n") as Vector2
		var expected_force := expected.get("hydrodynamic_force_body_n") as Vector2
		rows.append({"surge_mps":surge,"ground_speed_mps":4.0,"force_x_n":force.x,"passed":force.distance_to(expected_force)<0.00001 and absf(float(actual.get("squat_m"))-float(expected.get("squat_m")))<0.00001})
	var passed := true
	for row in rows:passed = passed and bool(row["passed"])
	var file := FileAccess.open("res://reports/mission_rl_hydro_contract_v1.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed":passed,"checks":rows,"source_sha256":FileAccess.get_sha256("res://scripts/training/ship_advanced_mission_realism_controller.gd")},"\t"));file.close()
	print("MISSION_RL_HYDRO:","PASS" if passed else "FAIL")
	quit(0 if passed else 1)

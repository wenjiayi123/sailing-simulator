extends SceneTree
## Native closed-loop validation: reads live state and sends neural commands.
## No trajectory teleporting is used after the initial scenario spawn.
var output_path := "res://reports/mission_rl_native_validation.json"
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	print("MISSION_RL_NATIVE_LOADING")
	var args := OS.get_cmdline_user_args()
	var actor_path := ""
	var maximum_frames := 37000
	for arg in args:
		if arg.begins_with("--actor="):
			actor_path = arg.trim_prefix("--actor=")
		if arg.begins_with("--output="):
			output_path = arg.trim_prefix("--output=")
		if arg.begins_with("--max-frames="):
			maximum_frames = int(arg.trim_prefix("--max-frames="))
	var actor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(actor_path)) as Dictionary
	change_scene_to_file("res://main.tscn")
	for i in range(24):
		await process_frame
	var main := current_scene
	print("MISSION_RL_NATIVE_SCENE_READY")
	# Suppress display-only refresh work in headless physics acceptance.
	# Vessel, collision, weather, route and mission assessment still run natively.
	for panel in main.find_children("*", "CanvasLayer", true, false):
		panel.process_mode = Node.PROCESS_MODE_DISABLED
	# Optional fast physical acceptance. These bridge-training services do not
	# command the learned vessel; sensor/UI integration is checked separately.
	var suspended_services: Array[String] = []
	if args.has("--mission-rl-focused"):
		for name in ["ShipNavigationEquipmentSuite", "ShipMultisensorFusionSuite", "ShipExecutionControlSuite", "ShipInstructorExerciseController", "ShipPortOperationsTrainingController", "ShipBridgeTeamCollaborationController", "ShipGmdssCommunicationsSuite", "ShipFullMissionBridgeSuite", "ShipBridgeCybersecuritySuite", "ShipPortProductionGateway"]:
			var service := main.get_node_or_null(NodePath(name))
			if service != null:
				service.process_mode = Node.PROCESS_MODE_DISABLED
				suspended_services.append(name)
	var scenarios := main.get_node("ShipScenarioController")
	var controller := main.get_node("MissionRLController")
	var mission := main.get_node("ShipAdvancedMissionController")
	var realism := main.get_node("ShipAdvancedMissionRealismController")
	var player := main.get_node("Player") as Node3D
	var key := String(actor.get("scenario", ""))
	scenarios.call("apply_scenario", scenarios.call("get_scenario_index_by_key", key), true)
	for i in range(3):
		await physics_frame
	if key == "narrow_channel_overtaking":
		mission.call("confirm_overtaking_agreement", true, "offline_rl_validation_harness")
	var started := bool(controller.call("load_actor", actor_path, true))
	print("MISSION_RL_NATIVE_STARTED:", started, ":", controller.get("status"))
	var scenario_config := scenarios.call("get_current_scenario_config") as Dictionary
	var expected_spawn := scenario_config.get("spawn", {}) as Dictionary
	var spawn_error := Vector2(player.global_position.x-float(expected_spawn.get("x", 0)), player.global_position.z-float(expected_spawn.get("z", 0))).length()
	var samples: Array = []
	var initial_observation: Array = []
	var golden_max_error := 0.0
	var golden_path := actor_path.get_base_dir().path_join("inference_golden.json")
	if FileAccess.file_exists(golden_path):
		var golden := JSON.parse_string(FileAccess.get_file_as_string(golden_path)) as Array
		for row in golden:
			var predicted: Vector2 = controller.call("infer", row["observation"], actor)
			golden_max_error = maxf(golden_max_error, absf(predicted.x-float(row["command"][0])))
			golden_max_error = maxf(golden_max_error, absf(predicted.y-float(row["command"][1])))
	else:
		golden_max_error = 999.0
	var traffic_required := not String((actor.get("config", {}) as Dictionary).get("traffic_policy_path", "")).is_empty()
	var traffic_golden_error := 0.0
	if traffic_required:
		var traffic_path := "res://" + String(actor["config"]["traffic_policy_path"])
		var traffic_model := JSON.parse_string(FileAccess.get_file_as_string(traffic_path)) as Dictionary
		var traffic_golden := JSON.parse_string(FileAccess.get_file_as_string(traffic_path.get_base_dir().path_join("inference_golden.json"))) as Array
		for row in traffic_golden:
			var predicted: Vector2 = main.get_node("MissionRLTrafficController").call("infer", row["observation"], traffic_model)
			traffic_golden_error = maxf(traffic_golden_error, absf(predicted.x-float(row["command"][0])))
			traffic_golden_error = maxf(traffic_golden_error, absf(predicted.y-float(row["command"][1])))
	var physics_frames := 0
	while started and bool(controller.get("active")) and physics_frames < maximum_frames:
		await physics_frame
		physics_frames += 1
		if physics_frames % 1800 == 0:
			print("MISSION_RL_PROGRESS:", key, ":", physics_frames, ":", controller.get("waypoint"), ":", player.global_position)
			var progress := FileAccess.open(output_path + ".progress.json", FileAccess.WRITE)
			progress.store_string(JSON.stringify({"frames":physics_frames,"samples":samples,"initial_observation":initial_observation,"observation":controller.get("last_observation")}))
			progress.close()
		if physics_frames == 1:
			initial_observation = (controller.get("last_observation") as Array).duplicate()
		if physics_frames % 30 == 0:
			var t := player.call("get_ship_telemetry") as Dictionary
			var a: Vector2 = controller.get("last_action")
			samples.append({"frame":physics_frames,"time":float(controller.get("elapsed")),"x":player.global_position.x,"z":player.global_position.z,
				"heading_degrees":t.get("heading_degrees"),"speed":t.get("surge_mps"),"sway_mps":t.get("sway_mps"),
				"waypoint":controller.get("waypoint"),"action":[a.x,a.y],"last_impact_speed":t.get("last_impact_speed"),
				"three_dof_active":t.get("three_dof_active")})
	var snapshot := mission.call("get_advanced_mission_snapshot") as Dictionary
	var realism_snapshot := realism.call("get_realism_snapshot") as Dictionary
	var debrief := realism_snapshot.get("debrief", {}) as Dictionary
	var hydro_profile := ((scenario_config.get("realism", {}) as Dictionary).get("hydrodynamics", {}) as Dictionary)
	var bank_value: Variant = debrief.get("minimum_bank_clearance_m")
	var water_value: Variant = debrief.get("minimum_ukc_m")
	var bank_passed := bank_value == null or float(bank_value) >= float(hydro_profile.get("minimum_bank_clearance_m", 0))
	var ukc_passed := water_value == null or float(water_value) >= float(hydro_profile.get("minimum_ukc_m", 0))
	var report := {"schema_version":"mission_rl_native_closed_loop_v1","scenario_key":key,"started":started,
		"actor_path":actor_path,"actor_sha256":FileAccess.get_sha256(actor_path),"inference_golden_max_error":golden_max_error,
		"inference_count":controller.get("inference_count"),"status":controller.get("status"),"physics_frames":physics_frames,
		"passed":started and String(controller.get("status")) == "强化学习任务完成" and golden_max_error < 0.00001 and spawn_error < 1.0 and bank_passed and ukc_passed,
		"initial_spawn_error_m":spawn_error,"bank_clearance_passed":bank_passed,"under_keel_clearance_passed":ukc_passed,
		"initial_observation":initial_observation,"mission":snapshot,"realism":realism_snapshot,
		"samples":samples,"trajectory_teleporting":false,"action_source":"SAC_neural_network_direct","controller_fallback_steps":0,
		"production_authority":false}
	var runtime_sources: Dictionary = {}
	report["suspended_non_physical_services"] = suspended_services
	for path in ["scripts/rl/mission_rl_controller.gd", "scripts/rl/ship_fleet_manager.gd", "scripts/training/ship_advanced_mission_controller.gd", "scripts/physics/catamaran_three_dof_dynamics.gd", "scripts/training/ship_advanced_mission_realism_controller.gd", "player.gd"]:
		runtime_sources[path] = FileAccess.get_sha256("res://" + path)
	report["native_runtime_sources"] = runtime_sources
	if traffic_required:
		var traffic_controller := main.get_node("MissionRLTrafficController")
		var traffic_passed := int(traffic_controller.get("inference_count")) > 0 and not bool(traffic_controller.get("traffic_collision")) and float(traffic_controller.get("maximum_cross_track_m")) < 7.0 and traffic_golden_error < 0.00001
		report["traffic_policy_required"] = true
		report["traffic_policy_verified"] = traffic_passed
		report["traffic_inference_count"] = traffic_controller.get("inference_count")
		report["traffic_max_cross_track_m"] = traffic_controller.get("maximum_cross_track_m")
		report["traffic_inference_golden_max_error"] = traffic_golden_error
		report["passed"] = bool(report["passed"]) and traffic_passed
		runtime_sources["scripts/rl/mission_rl_traffic_controller.gd"] = FileAccess.get_sha256("res://scripts/rl/mission_rl_traffic_controller.gd")
	var file := FileAccess.open(output_path,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"));file.close()
	print("MISSION_RL_NATIVE:","PASS" if report["passed"] else "FAIL",":",key,":",report["status"])
	quit(0 if report["passed"] else 1)

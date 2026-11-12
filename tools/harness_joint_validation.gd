extends SceneTree

# Reuse the admitted native SAC actor without changing the interactive instance.
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var request_path := OS.get_environment("XIAOYI_JOINT_REQUEST")
	var result_path := OS.get_environment("XIAOYI_JOINT_RESULT")
	if request_path.is_empty() or result_path.is_empty():
		quit(2)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(request_path))
	if not parsed is Dictionary or change_scene_to_file("res://main.tscn") != OK:
		quit(3)
		return
	for _index in range(24):
		await process_frame
	var main := current_scene
	for panel in main.find_children("*", "CanvasLayer", true, false):
		panel.process_mode = Node.PROCESS_MODE_DISABLED
	var suspended: Array[String] = []
	for name in ["ShipNavigationEquipmentSuite", "ShipMultisensorFusionSuite", "ShipExecutionControlSuite", "ShipInstructorExerciseController", "ShipPortOperationsTrainingController", "ShipBridgeTeamCollaborationController", "ShipGmdssCommunicationsSuite", "ShipFullMissionBridgeSuite", "ShipBridgeCybersecuritySuite", "ShipPortProductionGateway"]:
		var service := main.get_node_or_null(NodePath(name))
		if service != null:
			service.process_mode = Node.PROCESS_MODE_DISABLED
			suspended.append(name)
	var scenarios := main.get_node("ShipScenarioController")
	var controller := main.get_node("MissionRLController")
	var player := main.get_node("Player") as Node3D
	scenarios.call("apply_scenario", scenarios.call("get_scenario_index_by_key", "open_water"), true)
	for _index in range(3):
		await physics_frame
	var started := bool(controller.call("start_current"))
	var strategy := controller.call("current_strategy") as Dictionary
	var origin := player.global_position
	var minimum_clearance := 1.0e9
	var impacts := 0
	var samples: Array = []
	var frame_count := 0
	while started and bool(controller.get("active")) and frame_count < 240:
		await physics_frame
		frame_count += 1
		var sample := player.call("get_ship_telemetry") as Dictionary
		minimum_clearance = minf(minimum_clearance, float(controller.call("_clearance", Vector2(player.global_position.x, player.global_position.z))))
		if float(sample.get("last_impact_speed", 0.0)) > 0.0:
			impacts += 1
		if frame_count % 30 == 0:
			var action: Vector2 = controller.get("last_action")
			samples.append({"frame": frame_count, "state": controller.get("last_observation"),
				"action": [action.x, action.y], "x": player.global_position.x, "z": player.global_position.z,
				"surge_mps": sample.get("surge_mps"), "minimum_clearance_m": minimum_clearance})
	var telemetry := player.call("get_ship_telemetry") as Dictionary
	var speed_knots := absf(float(telemetry.get("surge_mps", 0.0))) * 1.943844
	var moved := Vector2(player.global_position.x, player.global_position.z).distance_to(Vector2(origin.x, origin.z))
	var passed := started and moved > 0.2 and impacts == 0 and minimum_clearance >= 20.0 and int(controller.get("inference_count")) > 0
	var result := {
		"schema": "xiaoyi-godot-joint-receipt.v2", "requestId": parsed.get("requestId"),
		"source_request_sha256": FileAccess.get_sha256(request_path), "scene_loaded": main != null,
		"scene_path": "res://main.tscn", "production_authority": false,
		"execution_scope": "isolated_native_4_second_sample", "action_source": "admitted_existing_SAC_actor",
		"strategy_id": strategy.get("strategy_id"), "actor_sha256": strategy.get("actor_sha256"),
		"actor_loaded": started, "inference_count": controller.get("inference_count"),
		"controller_status": controller.get("status"), "physics_frames": frame_count,
		"suspended_non_physical_services": suspended,
		"samples": samples, "moved_m": moved,
		"validation": {"safePass": passed, "status": "sample_passed" if passed else "sample_failed",
			"requestId": parsed.get("requestId"), "collisionCount": impacts, "groundingCount": null,
			"grounding_observed": false, "minClearanceMeters": minimum_clearance,
			"averageSpeedKnots": speed_knots, "delayDeltaMinutes": null, "delay_observed": false,
			"simulatedDurationSeconds": float(controller.get("elapsed")), "reachedDestination": false,
			"summary": "已准入开放水域策略的短时原生动作验证，不代表完整航次或真实马六甲场景。"},
	}
	var sources := {}
	for path in ["scripts/rl/mission_rl_controller.gd", "player.gd", "scripts/physics/catamaran_three_dof_dynamics.gd"]:
		sources[path] = FileAccess.get_sha256("res://" + path)
	result["runtime_sources"] = sources
	controller.call("stop", "联合任务短时样本已结束")
	var file := FileAccess.open(result_path, FileAccess.WRITE)
	if file == null:
		quit(4)
		return
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	print("JOINT_SAILING_RECEIPT ", parsed.get("requestId"), " ", passed, " moved=", moved)
	quit(0)

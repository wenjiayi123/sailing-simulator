extends SceneTree

# Full task completion through the original admitted controller and physics.
const ALLOWED := ["open_water", "harbor", "auto_berthing", "auto_unberthing", "narrow_channel_head_on", "crossing_starboard", "narrow_channel_overtaking"]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var request_path := OS.get_environment("XIAOYI_JOINT_REQUEST")
	var result_path := OS.get_environment("XIAOYI_JOINT_RESULT")
	var request: Variant = JSON.parse_string(FileAccess.get_file_as_string(request_path))
	if not request is Dictionary or result_path.is_empty():
		quit(2)
		return
	var key := String(request.get("voyage_scenario", "open_water"))
	if not ALLOWED.has(key) or change_scene_to_file("res://main.tscn") != OK:
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
	var mission := main.get_node("ShipAdvancedMissionController")
	var realism := main.get_node("ShipAdvancedMissionRealismController")
	var player := main.get_node("Player") as Node3D
	scenarios.call("apply_scenario", scenarios.call("get_scenario_index_by_key", key), true)
	for _index in range(3):
		await physics_frame
	if key == "narrow_channel_overtaking" and bool(request.get("overtaking_agreement_confirmed", false)):
		mission.call("confirm_overtaking_agreement", true, "explicit_harness_simulation_request")
	var started := bool(controller.call("start_current"))
	var strategy := controller.call("current_strategy") as Dictionary
	var scenario := scenarios.call("get_current_scenario_config") as Dictionary
	var route := scenario.get("route", []) as Array
	var origin := player.global_position
	var previous := Vector2(origin.x, origin.z)
	var distance_m := 0.0
	var impacts := 0
	var speed_sum := 0.0
	var frame_count := 0
	var samples: Array = []
	var all_trace_path := result_path + ".trace.ndjson"
	var trace := FileAccess.open(all_trace_path, FileAccess.WRITE)
	if trace == null:
		quit(4)
		return
	while started and bool(controller.get("active")) and frame_count < 36100:
		await physics_frame
		frame_count += 1
		var telemetry := player.call("get_ship_telemetry") as Dictionary
		var position := Vector2(player.global_position.x, player.global_position.z)
		distance_m += position.distance_to(previous)
		previous = position
		speed_sum += absf(float(telemetry.get("surge_mps", 0))) * 1.943844
		if float(telemetry.get("last_impact_speed", 0)) > 0:
			impacts += 1
		if frame_count % 30 == 0:
			var action: Vector2 = controller.get("last_action")
			var sample := {"frame": frame_count, "simulation_seconds": controller.get("elapsed"), "waypoint": controller.get("waypoint"), "state": controller.get("last_observation"), "action": [action.x, action.y], "x": position.x, "z": position.y, "surge_mps": telemetry.get("surge_mps"), "impact_speed": telemetry.get("last_impact_speed")}
			trace.store_line(JSON.stringify(sample))
			if frame_count % 300 == 0:
				samples.append(sample)
		if frame_count % 1800 == 0:
			trace.flush()
			var progress := FileAccess.open(result_path + ".progress.json", FileAccess.WRITE)
			progress.store_string(JSON.stringify({"frames": frame_count, "simulation_seconds": controller.get("elapsed"), "waypoint": controller.get("waypoint"), "waypoints_total": route.size(), "position": [position.x, position.y], "status": controller.get("status")}))
			progress.close()
	trace.close()
	var completed := started and String(controller.get("status")) == "强化学习任务完成"
	var realism_snapshot := realism.call("get_realism_snapshot") as Dictionary
	var debrief := realism_snapshot.get("debrief", {}) as Dictionary
	var hydro := ((scenario.get("realism", {}) as Dictionary).get("hydrodynamics", {}) as Dictionary)
	var ukc: Variant = debrief.get("minimum_ukc_m")
	var bank: Variant = debrief.get("minimum_bank_clearance_m")
	var ukc_pass := ukc == null or float(ukc) >= float(hydro.get("minimum_ukc_m", 0))
	var bank_pass := bank == null or float(bank) >= float(hydro.get("minimum_bank_clearance_m", 0))
	var passed := completed and impacts == 0 and ukc_pass and bank_pass and int(controller.get("inference_count")) > 0
	var final_position := Vector2(player.global_position.x, player.global_position.z)
	var target: Dictionary = route.back() if not route.is_empty() else {}
	var final_distance := final_position.distance_to(Vector2(float(target.get("x", 0)), float(target.get("z", 0))))
	var result := {"schema": "xiaoyi-godot-full-voyage.v1", "requestId": request.get("requestId"), "source_request_sha256": FileAccess.get_sha256(request_path), "scenario": key, "production_authority": false, "scene_loaded": true, "scene_path": "res://main.tscn", "execution_scope": "isolated_full_native_mission", "action_source": "admitted_existing_SAC_actor", "actor_loaded": started, "strategy_id": strategy.get("strategy_id"), "actor_sha256": strategy.get("actor_sha256"), "inference_count": controller.get("inference_count"), "controller_status": controller.get("status"), "physics_frames": frame_count, "suspended_non_physical_services": suspended, "trajectory_teleporting": false, "trace_path": all_trace_path, "trace_sha256": FileAccess.get_sha256(all_trace_path), "samples": samples, "distance_m": distance_m, "final_distance_to_goal_m": final_distance, "waypoint": controller.get("waypoint"), "waypoints_total": route.size(), "mission": mission.call("get_advanced_mission_snapshot"), "realism": realism_snapshot, "validation": {"safePass": passed, "status": "full_voyage_passed" if passed else "full_voyage_failed", "reachedDestination": completed, "collisionCount": impacts, "groundingCount": null, "grounding_observed": false, "minimum_ukc_m": ukc, "ukc_observed": ukc != null, "under_keel_clearance_passed": ukc_pass, "minimum_bank_clearance_m": bank, "bank_observed": bank != null, "bank_clearance_passed": bank_pass, "simulatedDurationSeconds": controller.get("elapsed"), "averageSpeedKnots": speed_sum / maxf(frame_count, 1), "delayDeltaMinutes": null, "delay_observed": false, "summary": "原生起点至任务终点的完整闭环；未观测字段保持空值，不代表真实港口航行或实船准入。"}}
	var sources := {}
	for path in ["scripts/rl/mission_rl_controller.gd", "player.gd", "scripts/physics/catamaran_three_dof_dynamics.gd", "scripts/training/ship_advanced_mission_controller.gd", "scripts/training/ship_advanced_mission_realism_controller.gd", "tools/harness_full_voyage.gd"]:
		sources[path] = FileAccess.get_sha256("res://" + path)
	result["runtime_sources"] = sources
	controller.call("stop", "完整联合航次实例结束")
	var file := FileAccess.open(result_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	print("JOINT_FULL_VOYAGE ", key, " ", passed, " seconds=", controller.get("elapsed"), " status=", result["controller_status"])
	quit(0 if passed else 5)

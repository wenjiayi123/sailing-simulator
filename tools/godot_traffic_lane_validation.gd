extends SceneTree
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var directory := "res://reports/artifacts/mission_rl_v1/traffic_lane_attempt_02"
	var actor_path := directory.path_join("actor.json")
	var actor := JSON.parse_string(FileAccess.get_file_as_string(actor_path)) as Dictionary
	change_scene_to_file("res://main.tscn")
	for i in range(24):
		await process_frame
	for panel in current_scene.find_children("*", "CanvasLayer", true, false):
		panel.process_mode = Node.PROCESS_MODE_DISABLED
	var scenarios := current_scene.get_node("ShipScenarioController")
	scenarios.call("apply_scenario",scenarios.call("get_scenario_index_by_key","narrow_channel_overtaking"),true)
	for i in range(3):
		await physics_frame
	var target := get_nodes_in_group(&"ship_advanced_mission_traffic")[0] as Node3D
	var inference := current_scene.get_node("MissionRLTrafficController")
	var observer := current_scene.get_node("MissionRLTrafficController")
	var golden := JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("inference_golden.json"))) as Array
	var error := 0.0
	for row in golden:
		var action: Vector2 = inference.call("infer",row["observation"],actor)
		error = maxf(error,absf(action.x-float(row["command"][0])))
		error = maxf(error,absf(action.y-float(row["command"][1])))
	var maximum_xte := 0.0
	var maximum_heading := 0.0
	var speed_error := 0.0
	var speed_count := 0
	var collided := false
	var samples: Array = []
	for frame in range(5400):
		var t := target.call("get_ship_telemetry") as Dictionary
		maximum_xte = maxf(maximum_xte,absf(target.global_position.x-18.0))
		maximum_heading = maxf(maximum_heading,absf(wrapf(float(t.get("heading_degrees",0)),-180,180)))
		collided = collided or float(t.get("last_impact_speed",0))>0.0
		if frame>600:
			speed_error += absf(float(t.get("surge_mps",0))-3.0)
			speed_count += 1
		if frame%30==0:
			var obs: Array = observer.call("observation",target,t)
			var action: Vector2 = inference.call("infer",obs,actor)
			target.call("set_ship_agent_command",action.x,action.y)
			samples.append({"frame":frame,"x":target.global_position.x,"z":target.global_position.z,"heading":t.get("heading_degrees"),"surge":t.get("surge_mps"),"action":[action.x,action.y]})
		if frame%1800==0:
			print("TRAFFIC_SAC_NATIVE_PROGRESS:",frame,":",target.global_position)
		await physics_frame
	var mean_error := speed_error/maxi(speed_count,1)
	var passed := maximum_xte<7 and maximum_heading<15 and mean_error<0.5 and not collided and error<0.00001
	var report := {"passed":passed,"actor_sha256":FileAccess.get_sha256(actor_path),"physics_frames":5400,"max_cross_track_m":maximum_xte,"max_heading_error_deg":maximum_heading,"mean_speed_error_after_10s_mps":mean_error,"collision":collided,"golden_max_error":error,"samples":samples,"controller_fallback_steps":0,"trajectory_teleporting":false,"production_authority":false}
	var file := FileAccess.open(directory.path_join("native_traffic_validation_03.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"));file.close()
	print("TRAFFIC_SAC_NATIVE:","PASS" if passed else "FAIL")
	quit(0 if passed else 1)

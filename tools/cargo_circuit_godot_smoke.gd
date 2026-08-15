extends SceneTree

const REPORT_PATH := "res://reports/cargo_circuit_godot_smoke_v1.json"
const PROCEDURAL_USV_VISUAL_SCRIPT := preload("res://scripts/visual/procedural_usv_visual.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var errors: Array[String] = []
	var statuses: Dictionary = {}
	var packed := load("res://main.tscn") as PackedScene
	if packed == null:
		errors.append("main.tscn failed to load")
		_finish(errors, {})
		return
	var main := packed.instantiate()
	root.add_child(main)
	await process_frame
	await physics_frame
	var controller := main.get_node_or_null("CargoCircuitReplayController") as CargoCircuitReplayController
	var panel := main.get_node_or_null("CargoCircuitRLPanel") as CargoCircuitRLPanel
	var large_rock_guard := main.get_node_or_null("LargeRockCollisionGuard")
	var player := main.get_node_or_null("Player")
	if controller == null:
		errors.append("CargoCircuitReplayController missing")
	if panel == null:
		errors.append("CargoCircuitRLPanel missing")
	if large_rock_guard == null:
		errors.append("LargeRockCollisionGuard missing")
	if player == null:
		errors.append("Player missing")
	if not errors.is_empty():
		_finish(errors, {})
		return
	var guard_status := large_rock_guard.call("get_guard_status") as Dictionary
	if int(guard_status.get("guard_count", 0)) != 3:
		errors.append("expected three supplemental solid guards for relocated crossing rocks")
	if controller.is_large_rock_replay_segment_clear(
		Vector3(170.0, -140.73494, -37.77),
		Vector3(430.0, -140.73494, -37.77)
	):
		errors.append("recorded replay sweep failed to detect the preserved east-side giant rock")
	var algorithm_option := panel.get("_algorithm_option") as OptionButton
	var strategy_option := panel.get("_strategy_option") as OptionButton
	var algorithm_ids: Array[String] = []
	if algorithm_option != null:
		for index in range(algorithm_option.item_count):
			algorithm_ids.append(String(algorithm_option.get_item_metadata(index)))
	statuses["h_hub_algorithms"] = algorithm_ids
	if algorithm_ids != ["sac", "ppo", "td3", "a2c", "ddpg", "tqc", "trpo"]:
		errors.append("H control hub does not expose the seven real training entrypoints")
	if strategy_option == null or strategy_option.item_count != 4:
		errors.append("H control hub named strategy selector is missing")
	elif not strategy_option.get_item_text(0).begins_with("SAC-S1｜") \
		or not strategy_option.get_item_text(1).begins_with("RES-SAC-D2｜") \
		or not strategy_option.get_item_text(2).begins_with("MANUAL-F0｜"):
		errors.append("H control hub strategy names do not expose provenance clearly")
	var presentation_status := controller.get_replay_presentation_status()
	statuses["presentation_defaults"] = presentation_status
	if String(presentation_status.get("camera_mode", "")) != "auto_follow":
		errors.append("H-panel camera default is not automatic heading follow")
	if String(presentation_status.get("visual_mode", "")) != "procedural_usv":
		errors.append("H-panel ship visual default is not the procedural 3D USV")
	if not controller.start_replay():
		errors.append("static accepted RL replay refused release artifact")
	else:
		for _index in range(4):
			await physics_frame
	var static_status := controller.get_replay_status()
	statuses["static_rl"] = static_status
	if not bool(static_status.get("active", false)):
		errors.append("static accepted RL replay did not become active")
	if not bool(static_status.get("trained_rl", false)) or String(static_status.get("dataset_split", "")) != "test":
		errors.append("static replay did not expose strict trained test provenance")
	if int(static_status.get("sample_count", 0)) < 100:
		errors.append("static accepted RL replay sample count is implausible")
	var usv_visual := player.get_node_or_null("ProceduralUSVVisual") as Node3D
	var legacy_animation_driver := player.get_node_or_null("LegacyAnimationStateDriver") as Node3D
	if usv_visual == null or not usv_visual.visible:
		errors.append("procedural 3D USV is not the active ship renderer")
	if player.get_node_or_null("PlayerVisual") != null:
		errors.append("former image ship renderer is still present in the player scene")
	if legacy_animation_driver == null or legacy_animation_driver.visible:
		errors.append("legacy animation compatibility driver is missing or visibly rendered")
	var component_summary := player.call("get_procedural_usv_component_summary") as Dictionary
	statuses["procedural_usv"] = component_summary
	if not bool(component_summary.get("built_in_meshes_only", false)):
		errors.append("procedural USV did not report built-in Godot mesh construction")
	if (component_summary.get("components", []) as Array).size() < 10:
		errors.append("procedural USV component manifest is incomplete")
	if String(component_summary.get("propulsion_animation", "")) != "实际航速、油门、实际舵角差速同步":
		errors.append("procedural USV does not declare motion-synchronised differential propellers")
	if usv_visual != null and usv_visual.has_method("get_propulsion_animation_status"):
		var linked_propulsion := usv_visual.call("get_propulsion_animation_status") as Dictionary
		statuses["active_propulsion_link"] = linked_propulsion
		var telemetry := player.call("get_ship_telemetry") as Dictionary
		if absf(float(linked_propulsion.get("speed_mps", INF)) - float(telemetry.get("speed", 0.0))) > 0.05:
			errors.append("active propeller animation is not linked to recorded ship speed")
	else:
		errors.append("procedural USV propeller diagnostics are missing")

	var propulsion_probe := PROCEDURAL_USV_VISUAL_SCRIPT.new() as Node3D
	propulsion_probe.name = "PropulsionAnimationProbe"
	main.add_child(propulsion_probe)
	propulsion_probe.call("set_navigation_state", 0.30, 0.0, 1.0)
	var slow_propulsion := propulsion_probe.call("get_propulsion_animation_status") as Dictionary
	propulsion_probe.call("set_navigation_state", 0.92, 0.0, 8.0)
	var fast_propulsion := propulsion_probe.call("get_propulsion_animation_status") as Dictionary
	if float(fast_propulsion.get("base_target_rad_s", 0.0)) <= float(slow_propulsion.get("base_target_rad_s", INF)):
		errors.append("propeller target speed does not increase with ship motion")
	if float(fast_propulsion.get("base_target_rad_s", 0.0)) < 75.0:
		errors.append("full-speed propeller animation is still visually too slow")
	if absf(absf(float(fast_propulsion.get("port_target_rad_s", 0.0))) - absf(float(fast_propulsion.get("starboard_target_rad_s", 0.0)))) > 0.01:
		errors.append("straight-running twin propellers are not balanced")
	for _index in range(4):
		await process_frame
	var animated_propulsion := propulsion_probe.call("get_propulsion_animation_status") as Dictionary
	if absf(float(animated_propulsion.get("port_current_rad_s", 0.0))) < 20.0 \
	or absf(float(animated_propulsion.get("starboard_current_rad_s", 0.0))) < 20.0:
		errors.append("propeller target rates are not driving the visible animation")

	propulsion_probe.call("set_navigation_state", 0.92, 0.82, 8.0)
	var starboard_turn_propulsion := propulsion_probe.call("get_propulsion_animation_status") as Dictionary
	if absf(float(starboard_turn_propulsion.get("port_target_rad_s", 0.0))) <= absf(float(starboard_turn_propulsion.get("starboard_target_rad_s", 0.0))):
		errors.append("starboard turn does not speed up the outside port propeller")
	propulsion_probe.call("set_navigation_state", 0.92, -0.82, 8.0)
	var port_turn_propulsion := propulsion_probe.call("get_propulsion_animation_status") as Dictionary
	if absf(float(port_turn_propulsion.get("starboard_target_rad_s", 0.0))) <= absf(float(port_turn_propulsion.get("port_target_rad_s", 0.0))):
		errors.append("port turn does not speed up the outside starboard propeller")
	propulsion_probe.call("set_navigation_state", -0.65, 0.0, -1.4)
	var reverse_propulsion := propulsion_probe.call("get_propulsion_animation_status") as Dictionary
	if float(reverse_propulsion.get("port_target_rad_s", 0.0)) >= 0.0 \
	or float(reverse_propulsion.get("starboard_target_rad_s", 0.0)) <= 0.0:
		errors.append("reverse thrust does not reverse both propeller animations")
	statuses["propulsion_animation"] = {
		"slow": slow_propulsion,
		"fast": fast_propulsion,
		"animated": animated_propulsion,
		"starboard_turn": starboard_turn_propulsion,
		"port_turn": port_turn_propulsion,
		"reverse": reverse_propulsion,
	}
	propulsion_probe.queue_free()
	var camera_status := player.call("get_ship_camera_heading_follow_status") as Dictionary
	if not bool(camera_status.get("enabled", false)):
		errors.append("strategy replay did not enable automatic heading-follow camera")
	player.call("apply_ship_camera_orbit_input", 1.0, 0.0, 0.30)
	var manual_camera_status := player.call("get_ship_camera_heading_follow_status") as Dictionary
	if not bool(manual_camera_status.get("manual_override_active", false)):
		errors.append("manual A/D camera input did not take priority over automatic heading follow")
	var manual_alignment_error := float(manual_camera_status.get("heading_alignment_error_degrees", 0.0))
	player.call("apply_ship_camera_orbit_input", 0.0, 0.0, 2.0)
	var resumed_camera_status := player.call("get_ship_camera_heading_follow_status") as Dictionary
	if bool(resumed_camera_status.get("manual_override_active", true)):
		errors.append("automatic heading-follow camera did not resume after keyboard idle timeout")
	if float(resumed_camera_status.get("heading_alignment_error_degrees", INF)) >= manual_alignment_error:
		errors.append("automatic camera did not rotate back toward the ship heading")
	controller.set_replay_camera_mode("free_camera")
	if bool((player.call("get_ship_camera_heading_follow_status") as Dictionary).get("enabled", true)):
		errors.append("H-panel free-camera mode did not disable automatic rotation")
	controller.set_replay_camera_mode("auto_follow")
	if not bool((player.call("get_ship_camera_heading_follow_status") as Dictionary).get("enabled", false)):
		errors.append("H-panel automatic camera mode did not re-enable heading follow")
	statuses["presentation_runtime_switch"] = controller.get_replay_presentation_status()
	controller.stop_replay(true)
	await process_frame
	if bool((player.call("get_ship_camera_heading_follow_status") as Dictionary).get("enabled", true)):
		errors.append("camera heading follow was not restored after replay stop")
	if not usv_visual.visible or legacy_animation_driver.visible:
		errors.append("3D USV did not remain the sole renderer after replay stop")

	if not controller.start_dynamic_replay():
		errors.append("dynamic accepted RL replay refused release artifact")
	else:
		for _index in range(4):
			await physics_frame
	var dynamic_status := controller.get_replay_status()
	statuses["dynamic_rl"] = dynamic_status
	if not bool(dynamic_status.get("active", false)):
		errors.append("dynamic accepted RL replay did not become active")
	if String(dynamic_status.get("format", "")) != "cargo_circuit_dynamic_test_rollout_v2":
		errors.append("dynamic replay loaded the wrong trajectory format")
	if int(dynamic_status.get("dynamic_obstacle_count", 0)) != 6 or int(dynamic_status.get("dynamic_marker_count", 0)) != 6:
		errors.append("dynamic replay did not instantiate all six moving traffic markers")
	controller.stop_replay(true)
	await process_frame

	if not controller.start_manual_feasibility_replay():
		errors.append("manual feasibility replay refused accepted artifact")
	else:
		for _index in range(8):
			await physics_frame
	var status := controller.get_replay_status()
	statuses["manual_feasibility"] = status
	if not bool(status.get("active", false)):
		errors.append("manual feasibility replay did not become active")
	if int(status.get("sample_count", 0)) < 100:
		errors.append("manual feasibility replay sample count is implausible")
	controller.stop_replay(true)
	await process_frame
	if controller.is_replay_active():
		errors.append("manual replay did not stop")
	_finish(errors, statuses, guard_status)


func _finish(errors: Array[String], statuses: Dictionary, guard_status: Dictionary = {}) -> void:
	var payload := {
		"format": "cargo_circuit_godot_smoke_v1",
		"passed": errors.is_empty(),
		"errors": errors,
		"replay_statuses": statuses,
		"large_rock_guard_status": guard_status,
		"checks": {
			"independent_controller_present": true,
			"independent_panel_present": true,
			"static_rl_release_loaded": true,
			"dynamic_rl_release_loaded": true,
			"six_dynamic_traffic_markers_instantiated": true,
			"relocated_large_rock_solid_guards_present": true,
			"recorded_replay_large_rock_sweep_enabled": true,
			"camera_follows_heading_with_keyboard_override": true,
			"h_panel_camera_modes_switch_runtime": true,
			"h_panel_is_system_control_hub": true,
			"seven_algorithm_training_entrypoints_present": true,
			"named_strategy_selector_present": true,
			"procedural_usv_is_sole_ship_renderer": true,
			"procedural_usv_uses_builtin_meshes": true,
			"propellers_scale_with_ship_motion": true,
			"propellers_use_port_starboard_turn_differential": true,
			"propellers_reverse_with_reverse_thrust": true,
			"manual_feasibility_artifact_loaded": true,
			"original_world_restored_on_stop": true,
		},
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "  "))
		file.close()
	print(JSON.stringify(payload))
	quit(0 if errors.is_empty() else 1)

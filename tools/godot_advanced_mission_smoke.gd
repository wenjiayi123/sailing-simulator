extends SceneTree

const REPORT_PATH := "res://reports/godot_advanced_mission_smoke_v1.json"
const ADVANCED_SCENARIOS := {
	"auto_berthing": {"task_type": "berthing", "traffic_count": 0},
	"auto_unberthing": {"task_type": "unberthing", "traffic_count": 0},
	"narrow_channel_head_on": {"task_type": "head_on", "traffic_count": 1},
	"crossing_starboard": {"task_type": "crossing_give_way", "traffic_count": 1},
	"narrow_channel_overtaking": {"task_type": "overtaking", "traffic_count": 1},
}
const FROZEN_POLICY_PATHS := [
	"res://reports/artifacts/cargo_circuit_rl_v1/cargo_sac_policy.zip",
	"res://reports/artifacts/cargo_circuit_dynamic_rl_v2/cargo_dynamic_sac_policy.zip",
]

var _checks: Dictionary = {}
var _errors: Array[String] = []
var _scenario_records: Array[Dictionary] = []
var _completion_records: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _record(name: String, passed: bool, detail: Variant) -> void:
	_checks[name] = {"passed": passed, "detail": detail}
	if not passed:
		_errors.append("%s: %s" % [name, str(detail)])


func _policy_hashes() -> Dictionary:
	var result := {}
	for path in FROZEN_POLICY_PATHS:
		result[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "MISSING"
	return result


func _exercise_low_difficulty_completion(
	main: Node,
	scenario_controller: Node,
	mission_controller: Node,
	scenario_key: String,
) -> Dictionary:
	var player := main.get_node_or_null("Player") as Node3D
	var route_system := main.get_node_or_null("ShipRouteSystem")
	if player == null or route_system == null or not player.has_method("set_ship_navigation_spawn"):
		return {
			"passed": false,
			"reason": "RUNTIME_COMPONENT_UNAVAILABLE",
			"scenario_key": scenario_key,
		}
	var scenario := scenario_controller.call("get_current_scenario_config") as Dictionary
	var evaluation := scenario.get("evaluation", {}) as Dictionary
	var completion_method := ""
	match scenario_key:
		"auto_berthing":
			var target := evaluation.get("berth_target", {}) as Dictionary
			player.call(
				"set_ship_navigation_spawn",
				Vector3(float(target.get("x", 0.0)), player.global_position.y, float(target.get("z", 0.0))),
				float(target.get("heading_degrees", 0.0)),
			)
			completion_method = "stopped_at_berth_target"
		"auto_unberthing":
			var route := scenario.get("route", []) as Array
			if route.is_empty():
				return {"passed": false, "reason": "ROUTE_UNAVAILABLE", "scenario_key": scenario_key}
			var exit_point := route[-1] as Dictionary
			player.call(
				"set_ship_navigation_spawn",
				Vector3(float(exit_point.get("x", 0.0)), player.global_position.y, float(exit_point.get("z", 0.0))),
				float((scenario.get("spawn", {}) as Dictionary).get("heading_degrees", 0.0)),
			)
			completion_method = "stopped_beyond_minimum_clear_distance"
		"narrow_channel_head_on", "crossing_starboard", "narrow_channel_overtaking":
			# Test-only deterministic traversal validates the route and mission-gate
			# state machine. It is deliberately not reported as policy performance.
			for raw_point in scenario.get("route", []) as Array:
				var point := raw_point as Dictionary
				player.call(
					"set_ship_navigation_spawn",
					Vector3(float(point.get("x", 0.0)), player.global_position.y, float(point.get("z", 0.0))),
					float((scenario.get("spawn", {}) as Dictionary).get("heading_degrees", 0.0)),
				)
				route_system.call("_advance_route_if_needed")
			completion_method = "deterministic_waypoint_gate_traversal"
		_:
			return {"passed": false, "reason": "UNSUPPORTED_SCENARIO", "scenario_key": scenario_key}
	var snapshot := mission_controller.call("get_advanced_mission_snapshot") as Dictionary
	var gate := snapshot.get("gate", {}) as Dictionary
	return {
		"scenario_key": scenario_key,
		"passed": bool(gate.get("passed", false)) and String(gate.get("status", "")) == "PASS",
		"gate": gate,
		"completion_method": completion_method,
		"policy_performance_claimed": false,
		"production_authority": false,
	}


func _run() -> void:
	var before_hashes := _policy_hashes()
	var scene_status := change_scene_to_file("res://main.tscn")
	_record("main_scene_load_request", scene_status == OK, scene_status)
	for _index in range(24):
		await process_frame
	var main := current_scene
	if main == null:
		_record("main_scene_ready", false, "current_scene is null")
		_finish(before_hashes)
		return
	var scenario_controller := main.get_node_or_null("ShipScenarioController")
	var mission_controller := main.get_node_or_null("ShipAdvancedMissionController")
	var planning_panel := main.get_node_or_null("ShipNavigationPlanningPanel")
	var weather_time := main.get_node_or_null("ShipWeatherTimeController")
	_record(
		"advanced_mission_components_present",
		scenario_controller != null and mission_controller != null and planning_panel != null,
		{
			"scenario_controller": scenario_controller != null,
			"mission_controller": mission_controller != null,
			"planning_panel": planning_panel != null,
		},
	)
	if scenario_controller == null or mission_controller == null or planning_panel == null:
		_finish(before_hashes)
		return
	_record("seven_scenarios_available", int(scenario_controller.call("get_scenario_count")) == 7, scenario_controller.call("list_scenarios"))
	var mission_option := planning_panel.get("_mission_option") as OptionButton
	_record("seven_profile_missions_visible", mission_option != null and mission_option.item_count == 7, mission_option.item_count if mission_option != null else -1)
	var labels := planning_panel.get("_labels") as Dictionary
	_record(
		"advanced_metrics_visible_in_navigation_panel",
		labels.has("advanced_task") and labels.has("advanced_gate") and labels.has("advanced_traffic") and labels.has("advanced_boundary"),
		labels.keys(),
	)
	var controlled_before: Node3D = main.get_node_or_null("Player") as Node3D
	for scenario_key in ADVANCED_SCENARIOS:
		weather_time.call("apply_mode", 3)
		var expectation := ADVANCED_SCENARIOS[scenario_key] as Dictionary
		var scenario_index := int(scenario_controller.call("get_scenario_index_by_key", scenario_key))
		scenario_controller.call("apply_scenario", scenario_index, true)
		var immediate_own_position := {"x": controlled_before.global_position.x, "z": controlled_before.global_position.z}
		var scenario_player := scenario_controller.get("_player") as Node3D
		for _frame in range(4):
			await process_frame
		await physics_frame
		var snapshot := mission_controller.call("get_advanced_mission_snapshot") as Dictionary
		var dedicated_snapshot := scenario_controller.call("get_active_dedicated_scene_snapshot") as Dictionary
		var base_environment := main.get_node_or_null("NavigationEnvironment") as Node3D
		var large_rock_guard := main.get_node_or_null("LargeRockCollisionGuard")
		var shared_background := base_environment.get_node_or_null("BackgroundWalls") as Node3D if base_environment != null else null
		var legacy_terrain := base_environment.get_node_or_null("TerrainUpperWalkableRegions") as Node3D if base_environment != null else null
		var visual_profile := dedicated_snapshot.get("visual_profile", {}) as Dictionary
		var weather_status := weather_time.call("get_weather_time_status") as Dictionary
		var task_visual_profile_valid: bool = (
			String(visual_profile.get("profile_id", "")) == scenario_key
			and String(visual_profile.get("wallpaper_status", "")) == "TASK_VISUAL_PROFILE"
			and String(visual_profile.get("water_status", "")) == "TASK_VISUAL_PROFILE"
			and String(visual_profile.get("wall_orientation_status", "")) == "VERTICAL_LOCKED"
			and bool(visual_profile.get("walls_vertical", false))
			and is_zero_approx(float(visual_profile.get("wall_tilt_degrees", -1.0)))
			and String(visual_profile.get("wallpaper_bottom_composition", "")) == "landline_at_bottom"
			and float(visual_profile.get("wallpaper_sea_band_max_fraction", 1.0)) <= 0.03
		)
		var dedicated_scene_valid: bool = (
			bool(dedicated_snapshot.get("dedicated_scene", false))
			and String(dedicated_snapshot.get("scene_key", "")) == scenario_key
			and not bool(dedicated_snapshot.get("uses_legacy_rock_environment", true))
			and task_visual_profile_valid
			and int(dedicated_snapshot.get("visual_node_count", 0)) >= 60
			and (dedicated_snapshot.get("feature_tags", []) as Array).size() >= 5
			and int(dedicated_snapshot.get("task_wall_count", 0)) == 4
			and bool(dedicated_snapshot.get("task_walls_vertical", false))
			and String(dedicated_snapshot.get("task_wallpaper_texture", "")) == String(visual_profile.get("wallpaper_texture", ""))
			and base_environment != null
			and base_environment.visible
			and shared_background != null
			and shared_background.visible
			and legacy_terrain != null
			and not legacy_terrain.visible
			and large_rock_guard != null
			and not bool((large_rock_guard.call("get_guard_status") as Dictionary).get("base_environment_active", true))
			and bool((large_rock_guard.call("get_guard_status") as Dictionary).get("shared_background_active", false))
		)
		_record("dedicated_scene_%s" % scenario_key, dedicated_scene_valid, dedicated_snapshot)
		_record(
			"vertical_landline_wallpaper_%s" % scenario_key,
			task_visual_profile_valid,
			visual_profile,
		)
		_record(
			"default_clear_weather_%s" % scenario_key,
			String(weather_status.get("key", "")) == "clear"
			and int(weather_status.get("index", -1)) == 0
			and not bool(weather_status.get("fog_enabled", true))
			and is_zero_approx(float(weather_status.get("fog_density", -1.0)))
			and is_zero_approx(float(weather_status.get("atmosphere_overlay_alpha", -1.0)))
			and bool(weather_status.get("zero_fog_visual", false)),
			weather_status,
		)
		if scenario_key == "narrow_channel_overtaking":
			var rejected_agreement := mission_controller.call("confirm_overtaking_agreement", true, "") as Dictionary
			_record("overtaking_blank_authorizer_rejected", String(rejected_agreement.get("status", "")) == "REJECTED", rejected_agreement)
			var agreement := mission_controller.call("confirm_overtaking_agreement", true, "native_smoke") as Dictionary
			_record("overtaking_agreement_explicitly_confirmed", String(agreement.get("status", "")) == "ACCEPTED_SIMULATION_ONLY", agreement)
			snapshot = mission_controller.call("get_advanced_mission_snapshot") as Dictionary
		var gate := snapshot.get("gate", {}) as Dictionary
		var traffic := snapshot.get("traffic", []) as Array
		var passed: bool = (
			String(snapshot.get("scenario_key", "")) == scenario_key
			and String(snapshot.get("task_type", "")) == String(expectation["task_type"])
			and int(snapshot.get("traffic_count", -1)) == int(expectation["traffic_count"])
			and bool(snapshot.get("own_ship_commanded_by_controller", true)) == false
			and bool(snapshot.get("existing_policy_modified", true)) == false
			and bool(snapshot.get("production_authority", true)) == false
			and not gate.is_empty()
		)
		if int(expectation["traffic_count"]) > 0:
			passed = passed and snapshot.get("nearest_distance_m") != null and snapshot.get("nearest_tcpa_s") != null and snapshot.get("nearest_dcpa_m") != null
			passed = passed and traffic.size() == 1
			if traffic.size() == 1:
				var traffic_record := traffic[0] as Dictionary
				passed = passed and float(snapshot.get("nearest_distance_m", 0.0)) > 50.0
				passed = passed and bool(traffic_record.get("external_agent_control_enabled", false))
				passed = passed and int(traffic_record.get("collision_layer", 0)) > 0
				passed = passed and float(traffic_record.get("speed_knots", 0.0)) > 0.0
		if scenario_key == "narrow_channel_overtaking":
			passed = passed and bool(gate.get("overtaking_agreement_confirmed", false))
		var controlled_after := main.get_node("ShipFleetManager").call("get_controlled_ship") as Node3D
		passed = passed and controlled_after == controlled_before
		_scenario_records.append({
			"scenario_key": scenario_key,
			"passed": passed,
			"task_type": snapshot.get("task_type"),
			"traffic_count": snapshot.get("traffic_count"),
			"immediate_own_position": immediate_own_position,
			"scenario_player_name": scenario_player.name if scenario_player != null else "MISSING",
			"own_ship": snapshot.get("own_ship"),
			"traffic": snapshot.get("traffic"),
			"gate": gate,
			"nearest_distance_m": snapshot.get("nearest_distance_m"),
			"nearest_tcpa_s": snapshot.get("nearest_tcpa_s"),
			"nearest_dcpa_m": snapshot.get("nearest_dcpa_m"),
			"dedicated_scene": dedicated_snapshot,
		})
		_record("runtime_%s" % scenario_key, passed, _scenario_records[-1])
		var completion := _exercise_low_difficulty_completion(
			main,
			scenario_controller,
			mission_controller,
			scenario_key,
		)
		_completion_records.append(completion)
		_record("low_difficulty_completion_%s" % scenario_key, bool(completion.get("passed", false)), completion)
	_record("all_five_advanced_scenarios_runtime_valid", _scenario_records.all(func(item: Dictionary) -> bool: return bool(item.get("passed", false))), _scenario_records)
	_record(
		"all_five_low_difficulty_function_gates_reach_pass",
		_completion_records.all(func(item: Dictionary) -> bool: return bool(item.get("passed", false))),
		_completion_records,
	)
	for base_scenario_key in ["open_water", "harbor"]:
		weather_time.call("apply_mode", 3)
		var base_index := int(scenario_controller.call("get_scenario_index_by_key", base_scenario_key))
		scenario_controller.call("apply_scenario", base_index, true)
		await process_frame
		await physics_frame
		var base_weather := weather_time.call("get_weather_time_status") as Dictionary
		_record(
			"default_clear_weather_%s" % base_scenario_key,
			String(base_weather.get("key", "")) == "clear"
			and int(base_weather.get("index", -1)) == 0
			and not bool(base_weather.get("fog_enabled", true))
			and is_zero_approx(float(base_weather.get("fog_density", -1.0)))
			and is_zero_approx(float(base_weather.get("atmosphere_overlay_alpha", -1.0)))
			and bool(base_weather.get("zero_fog_visual", false)),
			base_weather,
		)
		var base_player := main.get_node_or_null("Player") as Node3D
		var base_route_system := main.get_node_or_null("ShipRouteSystem")
		var base_scenario := scenario_controller.call("get_current_scenario_config") as Dictionary
		var base_completion := {
			"scenario_key": base_scenario_key,
			"passed": false,
			"completion_method": "deterministic_waypoint_gate_traversal",
			"policy_performance_claimed": false,
			"production_authority": false,
		}
		if base_player != null and base_route_system != null:
			for raw_base_point in base_scenario.get("route", []) as Array:
				var base_point := raw_base_point as Dictionary
				base_player.call(
					"set_ship_navigation_spawn",
					Vector3(float(base_point.get("x", 0.0)), base_player.global_position.y, float(base_point.get("z", 0.0))),
					float((base_scenario.get("spawn", {}) as Dictionary).get("heading_degrees", 0.0)),
				)
				base_route_system.call("_advance_route_if_needed")
			var base_route_data := base_route_system.call("get_radar_route_data") as Dictionary
			var expected_loop: bool = base_scenario_key == "open_water"
			base_completion["route"] = base_route_data
			base_completion["expected_loop"] = expected_loop
			base_completion["passed"] = (
				bool(base_route_data.get("loop", not expected_loop)) == expected_loop
				and (
					(bool(base_route_data.get("active", false)) and int(base_route_data.get("current_index", -1)) == 0)
					if expected_loop
					else not bool(base_route_data.get("active", true))
				)
			)
		_completion_records.append(base_completion)
		_record("low_difficulty_completion_%s" % base_scenario_key, bool(base_completion.get("passed", false)), base_completion)
	_record(
		"all_seven_low_difficulty_function_flows_valid",
		_completion_records.size() == 7 and _completion_records.all(func(item: Dictionary) -> bool: return bool(item.get("passed", false))),
		_completion_records,
	)
	var repeated_switches_valid := true
	for switch_index in range(18):
		var repeated_key := "narrow_channel_head_on" if switch_index % 2 == 0 else "crossing_starboard"
		var repeated_index := int(scenario_controller.call("get_scenario_index_by_key", repeated_key))
		scenario_controller.call("apply_scenario", repeated_index, true)
		await process_frame
		await physics_frame
		var repeated_snapshot := mission_controller.call("get_advanced_mission_snapshot") as Dictionary
		if String(repeated_snapshot.get("scenario_key", "")) != repeated_key or int(repeated_snapshot.get("traffic_count", 0)) != 1:
			repeated_switches_valid = false
			break
	_record("repeated_scenario_switches_do_not_exhaust_fleet", repeated_switches_valid, {"switches": 18})
	var open_water_index := int(scenario_controller.call("get_scenario_index_by_key", "open_water"))
	scenario_controller.call("apply_scenario", open_water_index, true)
	for _restore_frame in range(3):
		await process_frame
		await physics_frame
	var restored_base := main.get_node_or_null("NavigationEnvironment") as Node3D
	var restored_guard := main.get_node_or_null("LargeRockCollisionGuard")
	var restored_dedicated := scenario_controller.call("get_active_dedicated_scene_snapshot") as Dictionary
	var wallpaper_root := restored_base.get_node_or_null("BackgroundWalls") if restored_base != null else null
	_record(
		"open_water_restores_original_environment_wallpaper_and_collisions",
		restored_base != null
		and restored_base.visible
		and restored_guard != null
		and bool((restored_guard.call("get_guard_status") as Dictionary).get("base_environment_active", false))
		and not bool(restored_dedicated.get("dedicated_scene", true))
		and wallpaper_root != null
		and String(wallpaper_root.get_meta("wallpaper_override_status", "")) == "STARTUP_PORT_HORIZON",
		{
			"base_visible": restored_base.visible if restored_base != null else false,
			"guard": restored_guard.call("get_guard_status") if restored_guard != null else {},
			"dedicated": restored_dedicated,
			"wallpaper_status": wallpaper_root.get_meta("wallpaper_override_status", "MISSING") if wallpaper_root != null else "MISSING",
		},
	)
	var receipts := mission_controller.call("get_receipts") as Array
	_record("scenario_activation_receipts_emitted", receipts.size() >= 6, {"count": receipts.size(), "last": receipts[-1] if not receipts.is_empty() else {}})
	_finish(before_hashes)


func _finish(before_hashes: Dictionary) -> void:
	var after_hashes := _policy_hashes()
	_record("frozen_36_44_policy_artifacts_unchanged", before_hashes == after_hashes and not before_hashes.values().has("MISSING"), {"before": before_hashes, "after": after_hashes})
	var payload := {
		"schema_version": "godot_advanced_mission_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": _errors.is_empty(),
		"passed_checks": _checks.values().filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"total_checks": _checks.size(),
		"checks": _checks,
		"scenario_records": _scenario_records,
		"completion_records": _completion_records,
		"errors": _errors,
		"acceptance_scope": "Low-difficulty deterministic function-gate acceptance; not reinforcement-learning policy performance.",
		"boundary": "Simulation and operator-training task maps only; no calibrated port geometry, certification, legal advice, or live-vessel actuation authority.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("ADVANCED_MISSION_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_checks"], payload["total_checks"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

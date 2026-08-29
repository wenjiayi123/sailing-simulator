extends SceneTree

const DYNAMICS_SCRIPT := preload("res://scripts/physics/catamaran_three_dof_dynamics.gd")
const REPORT_PATH := "res://reports/godot_advanced_mission_realism_smoke_v1.json"
const SCENARIO_KEYS := [
	"auto_berthing",
	"auto_unberthing",
	"narrow_channel_head_on",
	"crossing_starboard",
	"narrow_channel_overtaking",
]
const FROZEN_POLICY_PATHS := [
	"res://reports/artifacts/cargo_circuit_rl_v1/cargo_sac_policy.zip",
	"res://reports/artifacts/cargo_circuit_dynamic_rl_v2/cargo_dynamic_sac_policy.zip",
]

var _checks: Dictionary = {}
var _errors: Array[String] = []
var _records: Array[Dictionary] = []


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


func _simulate_dynamics(forcing: Dictionary) -> Dictionary:
	var dynamics := DYNAMICS_SCRIPT.new()
	if not dynamics.configure_from_json("res://data/verification/catamaran_usv_dynamics_reference_v2.json"):
		return {"configured": false}
	dynamics.reset(0.0)
	var status: Dictionary = {}
	for _step in range(120):
		status = dynamics.step(0.55, 0.0, 1.0 / 60.0, forcing)
	status["configured"] = true
	return status


func _validate_forcing_changes_dynamics() -> Dictionary:
	var baseline := _simulate_dynamics({})
	var port_loss := _simulate_dynamics({"port_thrust_factor": 0.5})
	var steering_bias := _simulate_dynamics({"steering_bias_deg": 8.0})
	var shallow_drag := _simulate_dynamics({"hydrodynamic_force_body_n": Vector2(-900.0, 0.0)})
	var passed := (
		bool(baseline.get("configured", false))
		and float(port_loss.get("surge_mps", INF)) < float(baseline.get("surge_mps", 0.0))
		and absf(float(port_loss.get("yaw_rate_deg_s", 0.0))) > 0.01
		and absf(float(steering_bias.get("yaw_rate_deg_s", 0.0))) > 0.01
		and float(shallow_drag.get("surge_mps", INF)) < float(baseline.get("surge_mps", 0.0))
	)
	return {
		"passed": passed,
		"baseline_surge_mps": baseline.get("surge_mps"),
		"port_loss_surge_mps": port_loss.get("surge_mps"),
		"port_loss_yaw_rate_deg_s": port_loss.get("yaw_rate_deg_s"),
		"steering_bias_yaw_rate_deg_s": steering_bias.get("yaw_rate_deg_s"),
		"shallow_drag_surge_mps": shallow_drag.get("surge_mps"),
	}


func _exercise_behavioral_evidence(main: Node, scenario_key: String, scenario: Node, mission: Node, player: Node3D) -> Dictionary:
	var config := scenario.call("get_current_scenario_config") as Dictionary
	var spawn := config.get("spawn", {}) as Dictionary
	var initial_heading := float(spawn.get("heading_degrees", 0.0))
	var start_position := player.global_position
	if scenario_key == "auto_berthing":
		var target := (config.get("evaluation", {}) as Dictionary).get("berth_target", {}) as Dictionary
		player.call("set_ship_navigation_spawn", Vector3(float(target.get("x", 0.0)), player.global_position.y, float(target.get("z", 0.0))), float(target.get("heading_degrees", 0.0)))
		return ((mission.call("get_advanced_mission_snapshot") as Dictionary).get("behavioral_assessment", {}) as Dictionary)
	if scenario_key == "auto_unberthing":
		var route := config.get("route", []) as Array
		if route.is_empty():
			return {"passed": false, "reason": "ROUTE_UNAVAILABLE"}
		var exit_point := route[-1] as Dictionary
		player.call("set_ship_navigation_spawn", Vector3(float(exit_point.get("x", 0.0)), player.global_position.y, float(exit_point.get("z", 0.0))), initial_heading)
		return ((mission.call("get_advanced_mission_snapshot") as Dictionary).get("behavioral_assessment", {}) as Dictionary)
	if scenario_key not in ["narrow_channel_head_on", "crossing_starboard", "narrow_channel_overtaking"]:
		return {}
	if scenario_key in ["narrow_channel_head_on", "crossing_starboard"]:
		player.call("set_ship_navigation_spawn", start_position, initial_heading + 30.0)
		mission.call("get_advanced_mission_snapshot")
	var traffic_ships := mission.get("_traffic_ships") as Array[Node3D]
	if traffic_ships.is_empty():
		return {"passed": false, "reason": "TRAFFIC_UNAVAILABLE"}
	var traffic := traffic_ships[0]
	var traffic_telemetry := traffic.call("get_ship_telemetry") as Dictionary
	var traffic_heading := deg_to_rad(float(traffic_telemetry.get("heading_degrees", 0.0)))
	var traffic_forward := Vector3(sin(traffic_heading), 0.0, cos(traffic_heading))
	if scenario_key == "crossing_starboard":
		player.call("set_ship_navigation_spawn", traffic.global_position - traffic_forward * 32.0, initial_heading + 30.0)
		mission.call("get_advanced_mission_snapshot")
	elif scenario_key == "narrow_channel_overtaking":
		mission.call("confirm_overtaking_agreement", true, "native_realism_smoke")
		player.call("set_ship_navigation_spawn", traffic.global_position + traffic_forward * 32.0, initial_heading)
		mission.call("get_advanced_mission_snapshot")
	var route_system := main.get_node_or_null("ShipRouteSystem")
	if route_system == null:
		return {"passed": false, "reason": "ROUTE_SYSTEM_UNAVAILABLE"}
	for raw_point in config.get("route", []) as Array:
		var point := raw_point as Dictionary
		var heading := initial_heading + 30.0 if scenario_key in ["narrow_channel_head_on", "crossing_starboard"] else initial_heading
		player.call("set_ship_navigation_spawn", Vector3(float(point.get("x", 0.0)), player.global_position.y, float(point.get("z", 0.0))), heading)
		route_system.call("_advance_route_if_needed")
	var snapshot := mission.call("get_advanced_mission_snapshot") as Dictionary
	return snapshot.get("behavioral_assessment", {}) as Dictionary


func _run() -> void:
	var before_hashes := _policy_hashes()
	var forcing_validation := _validate_forcing_changes_dynamics()
	_record("realism_forcing_changes_three_dof_dynamics", bool(forcing_validation.get("passed", false)), forcing_validation)
	_record("main_scene_load_request", change_scene_to_file("res://main.tscn") == OK, "res://main.tscn")
	for _index in range(30):
		await process_frame
		await physics_frame
	var main := current_scene
	if main == null:
		_record("main_scene_ready", false, "current_scene is null")
		_finish(before_hashes)
		return
	var scenario := main.get_node_or_null("ShipScenarioController")
	var realism := main.get_node_or_null("ShipAdvancedMissionRealismController")
	var mission := main.get_node_or_null("ShipAdvancedMissionController")
	var player := main.get_node_or_null("Player") as Node3D
	_record("realism_components_present", scenario != null and realism != null and mission != null and player != null, {
		"scenario": scenario != null,
		"realism": realism != null,
		"mission": mission != null,
		"player": player != null,
	})
	if scenario == null or realism == null or mission == null or player == null:
		_finish(before_hashes)
		return
	var blank_operator := realism.call("run_predeparture_check", "") as Dictionary
	_record("blank_predeparture_operator_rejected", String(blank_operator.get("status", "")) == "REJECTED", blank_operator)
	for scenario_key in SCENARIO_KEYS:
		scenario.call("apply_scenario", int(scenario.call("get_scenario_index_by_key", scenario_key)), true)
		for _frame in range(5):
			await process_frame
			await physics_frame
		var snapshot := realism.call("get_realism_snapshot") as Dictionary
		var bridge := snapshot.get("bridge_readiness", {}) as Dictionary
		var hydro := snapshot.get("hydrodynamics", {}) as Dictionary
		var predeparture := realism.call("run_predeparture_check", "native_realism_smoke") as Dictionary
		var action := realism.call("record_operator_action", "decisive_manoeuvre", "native_realism_smoke") as Dictionary
		var behavioral := _exercise_behavioral_evidence(main, scenario_key, scenario, mission, player)
		var invalid_fault := realism.call("inject_machinery_fault", "unknown_fault", 0.5, "native_realism_smoke") as Dictionary
		var fault := realism.call("inject_machinery_fault", "port_propulsion_loss", 0.5, "native_realism_smoke") as Dictionary
		var fault_forcing := realism.call("get_hydrodynamic_forcing", player) as Dictionary
		var restore := realism.call("restore_machinery_faults", "native_realism_smoke") as Dictionary
		var profile := snapshot.get("profile", {}) as Dictionary
		var hydro_profile := profile.get("hydrodynamics", {}) as Dictionary
		var near_bank: Dictionary = {}
		if bool(hydro_profile.get("bank_effect_enabled", false)):
			var vessel := profile.get("vessel", {}) as Dictionary
			var near_bank_x := float(hydro_profile.get("navigable_half_width_m", 0.0)) - float(vessel.get("beam_m", 0.0)) * 0.5 - 2.0
			near_bank = realism.call("evaluate_hydrodynamic_state", Vector3(near_bank_x, player.global_position.y, 0.0), 0.0, 3.0) as Dictionary
		var debrief := realism.call("get_debrief_report") as Dictionary
		var debrief_export := realism.call("finalize_mission_debrief", "native_realism_smoke") as Dictionary
		var passed: bool = (
			bool(snapshot.get("active", false))
			and String(snapshot.get("scenario_key", "")) == scenario_key
			and bool(snapshot.get("environment_applied", false))
			and bool(bridge.get("passed", false))
			and String(predeparture.get("status", "")) == "PASS"
			and String(action.get("status", "")) == "ACCEPTED_SIMULATION_ONLY"
			and String(invalid_fault.get("status", "")) == "REJECTED"
			and String(fault.get("status", "")) == "EXECUTED_SIMULATION_ONLY"
			and is_equal_approx(float(fault_forcing.get("port_thrust_factor", 1.0)), 0.5)
			and String(restore.get("status", "")) == "EXECUTED_SIMULATION_ONLY"
			and String(hydro.get("model_id", "")) == "bounded_shallow_bank_proxy_v1"
			and float(hydro.get("static_ukc_m", -1.0)) >= float(hydro.get("minimum_ukc_m", 0.0))
			and float(hydro.get("squat_m", -1.0)) >= 0.0
			and String(debrief.get("schema_version", "")) == "ship_advanced_mission_debrief_v1"
			and String(debrief_export.get("status", "")) == "EXPORTED"
			and bool(debrief.get("named_vessel_dynamics_calibrated", true)) == false
			and bool(debrief.get("physical_hil_verified", true)) == false
			and bool(debrief.get("production_authority", true)) == false
		)
		passed = passed and bool(behavioral.get("passed", false)) and bool(debrief.get("passed", false))
		if bool(hydro_profile.get("bank_effect_enabled", false)):
			passed = passed \
				and float(near_bank.get("bank_proximity", 0.0)) > 0.0 \
				and (near_bank.get("hydrodynamic_force_body_n", Vector2.ZERO) as Vector2).length() > 0.0 \
				and not is_zero_approx(float(near_bank.get("hydrodynamic_yaw_moment_nm", 0.0)))
		var record := {
			"scenario_key": scenario_key,
			"passed": passed,
			"bridge_ready": bridge.get("passed"),
			"predeparture_status": predeparture.get("status"),
			"static_ukc_m": hydro.get("static_ukc_m"),
			"squat_m": hydro.get("squat_m"),
			"depth_froude": hydro.get("depth_froude"),
			"bank_effect_enabled": hydro.get("bank_effect_enabled"),
			"near_bank_proximity": near_bank.get("bank_proximity") if not near_bank.is_empty() else null,
			"fault_factor_during_test": fault_forcing.get("port_thrust_factor"),
			"debrief_status": debrief.get("status"),
			"debrief_score": debrief.get("score"),
			"debrief_export_status": debrief_export.get("status"),
			"behavioral_status": behavioral.get("status") if not behavioral.is_empty() else "MISSING",
		}
		_records.append(record)
		_record("runtime_realism_%s" % scenario_key, passed, record)
	_record("all_five_realism_profiles_runtime_valid", _records.all(func(item: Dictionary) -> bool: return bool(item.get("passed", false))), _records)
	var base_index := int(scenario.call("get_scenario_index_by_key", "open_water"))
	scenario.call("apply_scenario", base_index, true)
	for _frame in range(3):
		await process_frame
		await physics_frame
	var base_snapshot := realism.call("get_realism_snapshot") as Dictionary
	_record("base_scenario_disables_task_realism_forcing", not bool(base_snapshot.get("active", true)), base_snapshot)
	_finish(before_hashes)


func _finish(before_hashes: Dictionary) -> void:
	var after_hashes := _policy_hashes()
	_record("frozen_36_44_policy_artifacts_unchanged", before_hashes == after_hashes and not before_hashes.values().has("MISSING"), {
		"before": before_hashes,
		"after": after_hashes,
	})
	var payload := {
		"schema_version": "godot_advanced_mission_realism_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": _errors.is_empty(),
		"passed_checks": _checks.values().filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"total_checks": _checks.size(),
		"checks": _checks,
		"scenario_records": _records,
		"errors": _errors,
		"acceptance_scope": "Deterministic software function and synthetic completion evidence; not operator or reinforcement-learning policy performance.",
		"boundary": "Runtime validates bounded software hydrodynamics, faults, predeparture and debrief only; no named-vessel calibration, physical HIL, sea trial or certification claim.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("ADVANCED_MISSION_REALISM_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_checks"], payload["total_checks"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

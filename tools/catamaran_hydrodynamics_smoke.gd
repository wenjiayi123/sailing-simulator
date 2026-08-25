extends SceneTree

const DYNAMICS_SCRIPT := preload("res://scripts/physics/catamaran_three_dof_dynamics.gd")
const CONFIG_PATH := "res://data/verification/catamaran_usv_dynamics_reference_v2.json"
const REPORT_PATH := "res://reports/catamaran_hydrodynamics_smoke_v2.json"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var errors: Array[String] = []
	var straight := _rollout(0.72, 0.0, 40.0)
	var starboard := _rollout(0.62, 0.45, 35.0)
	var port := _rollout(0.62, -0.45, 35.0)
	var full_rudder := _rollout(0.62, 1.0, 35.0)
	var full_astern := _rollout(-1.0, 0.0, 40.0)
	var repeated := _rollout(0.62, 0.45, 35.0)
	if not bool(straight.get("finite_state", false)) or not bool(starboard.get("finite_state", false)):
		errors.append("3-DOF integration produced a non-finite state")
	var straight_speed := float(straight.get("surge_mps", 0.0))
	if straight_speed < 8.9 or straight_speed > 9.5:
		errors.append("calm-water cruise speed is outside the declared reference envelope")
	if float(starboard.get("yaw_rate_deg_s", 0.0)) <= 0.0 or float(port.get("yaw_rate_deg_s", 0.0)) >= 0.0:
		errors.append("twin-waterjet steering direction is incorrect")
	var symmetry_error := absf(float(starboard.get("yaw_rate_deg_s", 0.0)) + float(port.get("yaw_rate_deg_s", 0.0)))
	if symmetry_error > 0.05:
		errors.append("port/starboard manoeuvring symmetry exceeded tolerance")
	var turn_rate := absf(float(starboard.get("yaw_rate_deg_s", 0.0)))
	if turn_rate < 7.0 or turn_rate > 22.0:
		errors.append("calm-water yaw response is outside the stable handling envelope")
	var full_rudder_turn_rate := absf(float(full_rudder.get("yaw_rate_deg_s", 0.0)))
	if full_rudder_turn_rate < 18.0 or full_rudder_turn_rate > 26.0:
		errors.append("full-rudder yaw response is outside the declared reference envelope")
	var astern_speed := absf(float(full_astern.get("surge_mps", 0.0)))
	if astern_speed < 3.7 or astern_speed > 4.3:
		errors.append("full-astern speed is outside the declared reference envelope")
	var turn_drift_degrees := rad_to_deg(atan2(absf(float(starboard.get("sway_mps", 0.0))), maxf(absf(float(starboard.get("surge_mps", 0.0))), 0.001)))
	if turn_drift_degrees > 20.0:
		errors.append("calm-water turning sideslip exceeds the stable handling envelope")
	var deterministic_error := 0.0
	for key in ["surge_mps", "sway_mps", "yaw_rate_deg_s", "heading_rad"]:
		deterministic_error = maxf(deterministic_error, absf(float(starboard.get(key, 0.0)) - float(repeated.get(key, 0.0))))
	if deterministic_error > 0.000001:
		errors.append("same-input 3-DOF rollout is not deterministic")
	var decay_model := _new_model()
	decay_model.reset(0.0, 4.0)
	for _index in range(1200):
		decay_model.step(0.0, 0.0, 0.05)
	var decay := decay_model.get_status()
	if absf(float(decay.get("surge_mps", INF))) >= 0.5:
		errors.append("nonlinear hydrodynamic damping did not dissipate coasting energy")
	var forced_model := _new_model()
	forced_model.reset(0.0)
	var forcing := {
		"current_vector_mps": Vector3(0.8, 0.0, 0.2),
		"wind_force_body_n": Vector2(0.0, 240.0),
		"wave_force_body_n": Vector2(0.0, 180.0),
		"environment_yaw_moment_nm": 120.0,
	}
	var forced: Dictionary = {}
	for _index in range(400):
		forced = forced_model.step(0.0, 0.0, 0.05, forcing)
	if absf(float(forced.get("sway_mps", 0.0))) <= 0.01 or absf(float(forced.get("yaw_rate_deg_s", 0.0))) <= 0.01:
		errors.append("wind/wave forcing is not coupled into sway and yaw")
	var ground_velocity := forced.get("ground_velocity", Vector3.ZERO) as Vector3
	var water_velocity := forced.get("water_relative_velocity", Vector3.ZERO) as Vector3
	if ground_velocity.distance_to(water_velocity) < 0.5:
		errors.append("current is not coupled into over-ground velocity")
	var runtime_telemetry: Dictionary = {}
	if change_scene_to_file("res://main.tscn") != OK:
		errors.append("main scene failed to load")
	else:
		for _index in range(18):
			await process_frame
		var player := current_scene.get_node_or_null("Player")
		if player == null or not player.has_method("get_ship_telemetry"):
			errors.append("runtime ship telemetry is unavailable")
		else:
			runtime_telemetry = player.call("get_ship_telemetry") as Dictionary
			if String(runtime_telemetry.get("dynamics_model_id", "")) != "taoyuan_catamaran_usv_3dof_twin_waterjet_v2":
				errors.append("runtime player is not using the catamaran 3-DOF model")
			if not bool(runtime_telemetry.get("three_dof_active", false)):
				errors.append("runtime human control is not using the catamaran 3-DOF model")
			if absf(float(runtime_telemetry.get("drift_angle_degrees", 180.0))) > 0.1:
				errors.append("calm-water near-rest drift display is not suppressed")
			if bool(runtime_telemetry.get("named_vessel_dynamics_calibrated", true)):
				errors.append("unverified reference parameters are incorrectly marked calibrated")
	_finish({
		"model_id": String(straight.get("model_id", "")),
		"model_family": String(straight.get("model_family", "")),
		"straight_speed_mps": float(straight.get("surge_mps", 0.0)),
		"turn_drift_degrees": turn_drift_degrees,
		"full_rudder_yaw_rate_deg_s": full_rudder_turn_rate,
		"full_astern_speed_mps": astern_speed,
		"starboard_yaw_rate_deg_s": float(starboard.get("yaw_rate_deg_s", 0.0)),
		"port_yaw_rate_deg_s": float(port.get("yaw_rate_deg_s", 0.0)),
		"turn_symmetry_error_deg_s": symmetry_error,
		"deterministic_error": deterministic_error,
		"decay_final_surge_mps": float(decay.get("surge_mps", 0.0)),
		"forced_sway_mps": float(forced.get("sway_mps", 0.0)),
		"forced_yaw_rate_deg_s": float(forced.get("yaw_rate_deg_s", 0.0)),
		"current_ground_water_velocity_delta_mps": ground_velocity.distance_to(water_velocity),
		"runtime_telemetry": runtime_telemetry,
		"software_factors": [
			"surge", "sway", "yaw", "rigid_body_inertia", "added_mass",
			"linear_drag", "quadratic_drag", "twin_waterjet_differential_thrust",
			"waterjet_steering", "actuator_lag", "actuator_rate_limits",
			"current", "wind", "wave_drift", "RK4_substeps", "collision_energy_retention",
		],
		"named_vessel_calibrated": false,
		"boundary": "Software-level geometry-informed reference; requires identified coefficients and sea-trial validation before vessel-specific claims.",
	}, errors)


func _new_model() -> CatamaranThreeDofDynamics:
	var model := DYNAMICS_SCRIPT.new() as CatamaranThreeDofDynamics
	if not model.configure_from_json(CONFIG_PATH):
		push_error("catamaran dynamics config failed to load")
	model.reset(0.0)
	return model


func _rollout(throttle: float, steering: float, duration: float) -> Dictionary:
	var model := _new_model()
	var status: Dictionary = {}
	for _index in range(roundi(duration / 0.05)):
		status = model.step(throttle, steering, 0.05)
	return status


func _finish(payload: Dictionary, errors: Array[String]) -> void:
	var report := payload.duplicate(true)
	report["format"] = "catamaran_hydrodynamics_smoke_v2"
	report["passed"] = errors.is_empty()
	report["errors"] = errors
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	print("CATAMARAN_HYDRODYNAMICS:%s:%d" % ["PASS" if errors.is_empty() else "FAIL", int((report.get("software_factors", []) as Array).size())])
	quit(0 if errors.is_empty() else 1)

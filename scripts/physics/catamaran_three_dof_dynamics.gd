extends RefCounted
class_name CatamaranThreeDofDynamics

# Deterministic planar manoeuvring plant for the procedural twin-hull USV.
# It is a software reference model, not a named-vessel hydrodynamic calibration.

var config: Dictionary = {}
var surge_mps := 0.0
var sway_mps := 0.0
var yaw_rate_radps := 0.0
var heading_rad := 0.0
var port_throttle := 0.0
var starboard_throttle := 0.0
var steering_angle_rad := 0.0
var simulation_time_s := 0.0
var finite_state := true


func configure_from_json(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is not Dictionary:
		return false
	config = (parsed as Dictionary).duplicate(true)
	return _validate_config()


func reset(initial_heading_rad: float, initial_surge_mps: float = 0.0) -> void:
	heading_rad = wrapf(initial_heading_rad, -PI, PI)
	surge_mps = initial_surge_mps
	sway_mps = 0.0
	yaw_rate_radps = 0.0
	port_throttle = 0.0
	starboard_throttle = 0.0
	steering_angle_rad = 0.0
	simulation_time_s = 0.0
	finite_state = true


func step(throttle_command: float, steering_command: float, delta: float, forcing: Dictionary = {}) -> Dictionary:
	if config.is_empty() or delta <= 0.0:
		return get_status(forcing)
	var substeps := clampi(int(config.get("integration_substeps", 4)), 1, 16)
	var step_delta := minf(delta, 0.25) / float(substeps)
	var throttle_target := clampf(throttle_command, -1.0, 1.0)
	var steering_target := clampf(steering_command, -1.0, 1.0)
	var differential := _f("differential_thrust_gain") * steering_target
	var port_target := clampf(throttle_target + differential, -1.0, 1.0)
	var starboard_target := clampf(throttle_target - differential, -1.0, 1.0)
	var steering_bias := deg_to_rad(float(forcing.get("steering_bias_deg", 0.0)))
	var maximum_steering := deg_to_rad(_f("max_steering_angle_deg"))
	var angle_target := clampf(maximum_steering * steering_target + steering_bias, -maximum_steering, maximum_steering)
	for _index in range(substeps):
		port_throttle = _actuator_step(
			port_throttle,
			port_target,
			_f("propeller_time_constant_s"),
			_f("max_throttle_rate_per_s"),
			step_delta
		)
		starboard_throttle = _actuator_step(
			starboard_throttle,
			starboard_target,
			_f("propeller_time_constant_s"),
			_f("max_throttle_rate_per_s"),
			step_delta
		)
		steering_angle_rad = _actuator_step(
			steering_angle_rad,
			angle_target,
			_f("steering_time_constant_s"),
			deg_to_rad(_f("max_steering_rate_deg_s")),
			step_delta
		)
		var state := Vector4(surge_mps, sway_mps, yaw_rate_radps, heading_rad)
		var k1 := _derivative(state, forcing)
		var k2 := _derivative(state + k1 * (step_delta * 0.5), forcing)
		var k3 := _derivative(state + k2 * (step_delta * 0.5), forcing)
		var k4 := _derivative(state + k3 * step_delta, forcing)
		state += (k1 + k2 * 2.0 + k3 * 2.0 + k4) * (step_delta / 6.0)
		surge_mps = state.x
		sway_mps = state.y
		yaw_rate_radps = state.z
		heading_rad = wrapf(state.w, -PI, PI)
		simulation_time_s += step_delta
		finite_state = is_finite(surge_mps) and is_finite(sway_mps) \
			and is_finite(yaw_rate_radps) and is_finite(heading_rad)
		if not finite_state:
			reset(0.0)
			break
	return get_status(forcing)


func apply_collision_retention(retention: float) -> void:
	var bounded := clampf(retention, 0.0, 1.0)
	surge_mps *= bounded
	sway_mps *= bounded
	yaw_rate_radps *= bounded


func set_recorded_state(recorded_heading_rad: float, recorded_speed_mps: float) -> void:
	heading_rad = wrapf(recorded_heading_rad, -PI, PI)
	surge_mps = recorded_speed_mps
	sway_mps = 0.0
	yaw_rate_radps = 0.0


func get_status(forcing: Dictionary = {}) -> Dictionary:
	var forward := Vector3(sin(heading_rad), 0.0, cos(heading_rad))
	var starboard := Vector3(cos(heading_rad), 0.0, -sin(heading_rad))
	var current := forcing.get("current_vector_mps", Vector3.ZERO) as Vector3
	var water_relative_velocity := forward * surge_mps + starboard * sway_mps
	return {
		"model_id": String(config.get("model_id", "unconfigured_catamaran_3dof")),
		"model_family": "3DOF_surge_sway_yaw_twin_waterjet_RK4",
		"calibration_status": String(config.get("calibration_status", "unverified_reference")),
		"named_vessel_calibrated": false,
		"surge_mps": surge_mps,
		"sway_mps": sway_mps,
		"yaw_rate_radps": yaw_rate_radps,
		"yaw_rate_deg_s": rad_to_deg(yaw_rate_radps),
		"heading_rad": heading_rad,
		"port_throttle": port_throttle,
		"starboard_throttle": starboard_throttle,
		"steering_angle_deg": rad_to_deg(steering_angle_rad),
		"water_relative_velocity": water_relative_velocity,
		"ground_velocity": water_relative_velocity + current,
		"current_vector_mps": current,
		"wind_force_body_n": forcing.get("wind_force_body_n", Vector2.ZERO),
		"wave_force_body_n": forcing.get("wave_force_body_n", Vector2.ZERO),
		"hydrodynamic_force_body_n": forcing.get("hydrodynamic_force_body_n", Vector2.ZERO),
		"hydrodynamic_yaw_moment_nm": float(forcing.get("hydrodynamic_yaw_moment_nm", 0.0)),
		"port_thrust_factor": clampf(float(forcing.get("port_thrust_factor", 1.0)), 0.0, 1.0),
		"starboard_thrust_factor": clampf(float(forcing.get("starboard_thrust_factor", 1.0)), 0.0, 1.0),
		"steering_bias_deg": float(forcing.get("steering_bias_deg", 0.0)),
		"simulation_time_s": simulation_time_s,
		"integration_substeps": int(config.get("integration_substeps", 4)),
		"finite_state": finite_state,
	}


func get_config_snapshot() -> Dictionary:
	return config.duplicate(true)


func _derivative(state: Vector4, forcing: Dictionary) -> Vector4:
	var surge := state.x
	var sway := state.y
	var yaw_rate := state.z
	var port_thrust := _signed_thrust(port_throttle) * clampf(float(forcing.get("port_thrust_factor", 1.0)), 0.0, 1.0)
	var starboard_thrust := _signed_thrust(starboard_throttle) * clampf(float(forcing.get("starboard_thrust_factor", 1.0)), 0.0, 1.0)
	var combined_thrust := port_thrust + starboard_thrust
	var axial_thrust := combined_thrust * cos(steering_angle_rad)
	var steering_lateral := -combined_thrust * sin(steering_angle_rad) * _f("steering_lateral_efficiency")
	var surge_drag := _f("surge_drag_linear_n_per_mps") * surge \
		+ _f("surge_drag_quadratic_n_per_mps2") * absf(surge) * surge
	var sway_drag := _f("sway_drag_linear_n_per_mps") * sway \
		+ _f("sway_drag_quadratic_n_per_mps2") * absf(sway) * sway
	var yaw_drag := _f("yaw_drag_linear_nm_per_radps") * yaw_rate \
		+ _f("yaw_drag_quadratic_nm_per_radps2") * absf(yaw_rate) * yaw_rate
	var wind_force := forcing.get("wind_force_body_n", Vector2.ZERO) as Vector2
	var wave_force := forcing.get("wave_force_body_n", Vector2.ZERO) as Vector2
	var hydrodynamic_force := forcing.get("hydrodynamic_force_body_n", Vector2.ZERO) as Vector2
	var environment_yaw := float(forcing.get("environment_yaw_moment_nm", 0.0)) \
		+ float(forcing.get("hydrodynamic_yaw_moment_nm", 0.0))
	var force_x := axial_thrust - surge_drag + wind_force.x + wave_force.x + hydrodynamic_force.x
	var force_y := steering_lateral - sway_drag + wind_force.y + wave_force.y + hydrodynamic_force.y
	var differential_moment := (port_thrust - starboard_thrust) * _f("twin_waterjet_half_spacing_m")
	var steering_moment := _f("steering_x_m") * steering_lateral
	var moment := differential_moment + steering_moment - yaw_drag + environment_yaw
	var mass_surge := _f("mass_kg") + _f("added_mass_surge_kg")
	var mass_sway := _f("mass_kg") + _f("added_mass_sway_kg")
	var yaw_inertia := _f("yaw_inertia_kg_m2") + _f("added_yaw_inertia_kg_m2")
	var surge_dot := (force_x + mass_sway * sway * yaw_rate) / maxf(mass_surge, 1.0)
	var sway_dot := (force_y - mass_surge * surge * yaw_rate) / maxf(mass_sway, 1.0)
	var yaw_dot := moment / maxf(yaw_inertia, 1.0)
	return Vector4(surge_dot, sway_dot, yaw_dot, yaw_rate)


func _signed_thrust(throttle: float) -> float:
	var ratio := 1.0 if throttle >= 0.0 else _f("astern_thrust_ratio")
	# max_ahead_thrust_n is the combined rating, split equally between jets.
	return 0.5 * _f("max_ahead_thrust_n") * throttle * ratio


func _actuator_step(actual: float, target: float, time_constant: float, rate_limit: float, delta: float) -> float:
	var requested_rate := (target - actual) / maxf(time_constant, 0.001)
	return actual + clampf(requested_rate, -rate_limit, rate_limit) * delta


func _f(key: String) -> float:
	return float(config.get(key, 0.0))


func _validate_config() -> bool:
	for key in [
		"mass_kg", "yaw_inertia_kg_m2", "surge_drag_quadratic_n_per_mps2",
		"sway_drag_quadratic_n_per_mps2", "yaw_drag_quadratic_nm_per_radps2",
		"max_ahead_thrust_n", "propeller_time_constant_s", "max_throttle_rate_per_s",
		"twin_waterjet_half_spacing_m", "max_steering_angle_deg", "steering_time_constant_s",
		"max_steering_rate_deg_s", "integration_substeps",
	]:
		if _f(key) <= 0.0:
			return false
	return true

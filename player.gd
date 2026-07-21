extends CharacterBody3D

## Runtime controller for one surface vessel.
##
## The controller intentionally uses only ship-domain state. Visuals are built
## from Godot primitive meshes in main.tscn, so the public project has no
## dependency on character sprites or externally sourced art.

const INITIAL_HEADING_YAW := PI
const SELECTION_RING_COLOR := Color(0.28, 0.96, 1.0, 0.74)

@export_group("Ship Handling")
@export var ship_max_forward_speed: float = 18.0
@export var ship_max_reverse_speed: float = 5.5
@export var ship_acceleration: float = 3.6
@export var ship_deceleration: float = 2.2
@export var ship_brake_acceleration: float = 6.4
@export var ship_throttle_response: float = 1.65
@export var ship_rudder_response: float = 2.45
@export var ship_max_turn_rate_degrees: float = 82.0
@export_range(0.0, 1.0, 0.01) var ship_low_speed_turn_factor: float = 0.18
@export_range(0.0, 1.0, 0.01) var ship_reverse_turn_factor: float = 0.58
@export var ship_velocity_alignment: float = 1.25
@export var ship_heading_settle_speed: float = 0.30
@export var ship_heading_error_full_rudder_degrees: float = 70.0

@export_group("Collision Feedback")
@export var ship_impact_min_speed: float = 1.7
@export_range(0.05, 0.95, 0.01) var ship_impact_speed_retention: float = 0.36
@export var ship_impact_rebound_speed: float = 1.05
@export var ship_impact_warning_duration: float = 1.35
@export var ship_impact_feedback_cooldown: float = 0.36

@export_group("Ship Agent Control")
@export var ship_agent_id: StringName = &"ship_00"
@export var human_control_enabled: bool = true
@export var external_agent_control_enabled: bool = false
@export var camera_enabled: bool = true
@export var selectable_ship_agent: bool = true

@export_group("Camera")
@export var camera_focus_height: float = 1.2
@export var camera_distance: float = 18.4
@export var camera_pitch_degrees: float = 24.0
@export var camera_orbit_sensitivity: float = 0.004
@export var camera_zoom_step: float = 1.2
@export var camera_min_distance: float = 8.0
@export var camera_max_distance: float = 34.0

var ship_heading_yaw: float = INITIAL_HEADING_YAW
var ship_target_heading_yaw: float = INITIAL_HEADING_YAW
var ship_course_yaw: float = INITIAL_HEADING_YAW
var ship_heading_error: float = 0.0
var ship_drift_angle: float = 0.0
var ship_target_throttle: float = 0.0
var ship_throttle: float = 0.0
var ship_target_rudder: float = 0.0
var ship_rudder: float = 0.0
var ship_forward_speed: float = 0.0
var ship_turn_authority: float = 0.0
var ship_external_throttle: float = 0.0
var ship_external_rudder: float = 0.0
var ship_collision_warning_text: String = "CLEAR"
var ship_last_impact_speed: float = 0.0
var ship_impact_warning_time_left: float = 0.0
var ship_impact_feedback_cooldown_left: float = 0.0
var _camera_yaw: float = 0.0
var _selection_indicator: MeshInstance3D

@onready var player_camera: Camera3D = $Camera3D
@onready var ship_visual: Node3D = $ShipVisual


func _ready() -> void:
	add_to_group(&"ship_agent")
	if human_control_enabled:
		add_to_group(&"player")
	_update_ship_visual()
	_ensure_ship_selection_indicator()
	set_ship_camera_enabled(camera_enabled)
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if not camera_enabled:
		return
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		var motion := event as InputEventMouseMotion
		_camera_yaw -= motion.relative.x * camera_orbit_sensitivity
		camera_pitch_degrees = clampf(
			camera_pitch_degrees + motion.relative.y * rad_to_deg(camera_orbit_sensitivity),
			10.0,
			70.0
		)
		_update_camera_mount()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_distance = maxf(camera_min_distance, camera_distance - camera_zoom_step)
			_update_camera_mount()
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance = minf(camera_max_distance, camera_distance + camera_zoom_step)
			_update_camera_mount()


func _physics_process(delta: float) -> void:
	if external_agent_control_enabled:
		_update_ship_direct_motion(delta, ship_external_throttle, ship_external_rudder)
	else:
		var input_vector := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down") if human_control_enabled else Vector2.ZERO
		var local_direction := Vector3(input_vector.x, 0.0, input_vector.y).normalized()
		var target_direction := local_direction.rotated(Vector3.UP, _camera_yaw)
		_update_ship_motion(delta, target_direction, clampf(input_vector.length(), 0.0, 1.0))

	var pre_slide_horizontal_velocity := Vector3(velocity.x, 0.0, velocity.z)
	velocity.y = 0.0
	move_and_slide()
	_process_ship_collision_feedback(pre_slide_horizontal_velocity)
	_update_feedback_timers(delta)
	_update_ship_visual()


func _update_ship_motion(delta: float, target_direction: Vector3, input_strength: float) -> void:
	_update_ship_direct_motion(
		delta,
		input_strength,
		_get_target_rudder_for_direction(target_direction),
		target_direction
	)


func _update_ship_direct_motion(
	delta: float,
	throttle_command: float,
	rudder_command: float,
	target_direction: Vector3 = Vector3.ZERO
) -> void:
	ship_target_throttle = clampf(throttle_command, -1.0, 1.0)
	ship_target_rudder = clampf(rudder_command, -1.0, 1.0)
	ship_throttle = move_toward(ship_throttle, ship_target_throttle, ship_throttle_response * delta)
	ship_rudder = move_toward(ship_rudder, ship_target_rudder, ship_rudder_response * delta)

	if target_direction != Vector3.ZERO and absf(ship_forward_speed) <= ship_heading_settle_speed:
		ship_heading_yaw = atan2(target_direction.x, target_direction.z)
		ship_target_heading_yaw = ship_heading_yaw
		ship_rudder = 0.0
		ship_target_rudder = 0.0
		ship_heading_error = 0.0

	var target_speed := ship_throttle * ship_max_forward_speed
	if ship_throttle < 0.0:
		target_speed = ship_throttle * ship_max_reverse_speed

	var current_horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var acceleration_rate := ship_deceleration
	if target_direction != Vector3.ZERO and current_horizontal.length() > 0.05 and current_horizontal.normalized().dot(target_direction) < -0.25:
		acceleration_rate = ship_brake_acceleration
	elif absf(target_speed) > absf(ship_forward_speed):
		acceleration_rate = ship_acceleration
	ship_forward_speed = move_toward(ship_forward_speed, target_speed, acceleration_rate * delta)

	var speed_reference := ship_max_forward_speed if ship_forward_speed >= 0.0 else ship_max_reverse_speed
	var speed_ratio := clampf(absf(ship_forward_speed) / maxf(speed_reference, 0.001), 0.0, 1.0)
	var low_speed_factor := ship_low_speed_turn_factor if ship_forward_speed >= -0.05 else ship_reverse_turn_factor
	ship_turn_authority = lerpf(low_speed_factor, 1.0, speed_ratio)
	var reverse_turn_sign := 1.0 if ship_forward_speed >= -0.05 else -1.0
	ship_heading_yaw += ship_rudder * deg_to_rad(ship_max_turn_rate_degrees) * ship_turn_authority * reverse_turn_sign * delta

	var desired_velocity := _get_ship_forward_vector() * ship_forward_speed
	var alignment := clampf(ship_velocity_alignment * lerpf(0.45, 1.0, ship_turn_authority) * delta, 0.0, 1.0)
	current_horizontal = current_horizontal.lerp(desired_velocity, alignment)
	velocity.x = current_horizontal.x
	velocity.z = current_horizontal.z
	if current_horizontal.length_squared() > 0.001:
		ship_course_yaw = atan2(current_horizontal.x, current_horizontal.z)
	else:
		ship_course_yaw = ship_heading_yaw
	ship_drift_angle = wrapf(ship_heading_yaw - ship_course_yaw, -PI, PI)


func _get_target_rudder_for_direction(target_direction: Vector3) -> float:
	if target_direction == Vector3.ZERO:
		ship_heading_error = 0.0
		return 0.0
	ship_target_heading_yaw = atan2(target_direction.x, target_direction.z)
	ship_heading_error = wrapf(ship_target_heading_yaw - ship_heading_yaw, -PI, PI)
	return clampf(
		ship_heading_error / maxf(deg_to_rad(ship_heading_error_full_rudder_degrees), 0.001),
		-1.0,
		1.0
	)


func _get_ship_forward_vector() -> Vector3:
	return Vector3(sin(ship_heading_yaw), 0.0, cos(ship_heading_yaw)).normalized()


func _get_ship_signed_speed() -> float:
	return Vector3(velocity.x, 0.0, velocity.z).dot(_get_ship_forward_vector())


func _update_ship_visual() -> void:
	if ship_visual != null:
		ship_visual.rotation.y = ship_heading_yaw - INITIAL_HEADING_YAW


func _update_camera_mount() -> void:
	if player_camera == null:
		return
	var pitch := deg_to_rad(camera_pitch_degrees)
	var horizontal := cos(pitch) * camera_distance
	player_camera.position = Vector3(
		sin(_camera_yaw) * horizontal,
		sin(pitch) * camera_distance,
		cos(_camera_yaw) * horizontal
	)
	player_camera.look_at(global_position + Vector3.UP * camera_focus_height, Vector3.UP)


func _process_ship_collision_feedback(pre_slide_velocity: Vector3) -> void:
	var strongest_speed := 0.0
	var strongest_normal := Vector3.ZERO
	var strongest_collider: Object
	for index in range(get_slide_collision_count()):
		var collision := get_slide_collision(index)
		var normal := collision.get_normal()
		var horizontal_normal := Vector3(normal.x, 0.0, normal.z)
		if horizontal_normal.length_squared() <= 0.001:
			continue
		horizontal_normal = horizontal_normal.normalized()
		var impact_speed := maxf(0.0, -pre_slide_velocity.dot(horizontal_normal))
		if impact_speed > strongest_speed:
			strongest_speed = impact_speed
			strongest_normal = horizontal_normal
			strongest_collider = collision.get_collider()
	if strongest_normal == Vector3.ZERO or strongest_speed < ship_impact_min_speed:
		return
	ship_forward_speed *= ship_impact_speed_retention
	ship_throttle *= ship_impact_speed_retention
	var deflected := Vector3(velocity.x, 0.0, velocity.z).slide(strongest_normal) * ship_impact_speed_retention
	deflected += strongest_normal * ship_impact_rebound_speed
	velocity.x = deflected.x
	velocity.z = deflected.z
	if ship_impact_feedback_cooldown_left <= 0.0:
		_trigger_collision_feedback(_collision_feedback_text(strongest_collider), strongest_speed)


func _collision_feedback_text(collider: Object) -> String:
	var collider_node := collider as Node
	if collider_node == null:
		return "IMPACT // 船体碰撞"
	var lower_name := String(collider_node.name).to_lower()
	if lower_name.contains("boundary"):
		return "BOUNDARY IMPACT // 边界碰撞"
	if lower_name.contains("rock"):
		return "ROCK IMPACT // 岩体碰撞"
	return "NAV OBSTACLE // 航行障碍"


func _trigger_collision_feedback(message: String, impact_speed: float) -> void:
	ship_collision_warning_text = message
	ship_last_impact_speed = impact_speed
	ship_impact_warning_time_left = ship_impact_warning_duration
	ship_impact_feedback_cooldown_left = ship_impact_feedback_cooldown


func _update_feedback_timers(delta: float) -> void:
	ship_impact_warning_time_left = maxf(0.0, ship_impact_warning_time_left - delta)
	ship_impact_feedback_cooldown_left = maxf(0.0, ship_impact_feedback_cooldown_left - delta)
	if ship_impact_warning_time_left <= 0.0:
		ship_collision_warning_text = "CLEAR"


func inject_ship_incident(incident_key: String = "collision", severity: float = 1.0) -> void:
	var intensity := clampf(severity, 0.1, 2.0)
	var warning := "COLLISION DRILL // 碰撞事故注入"
	if incident_key == "grounding":
		warning = "GROUNDING DRILL // 搁浅事故注入"
	elif incident_key == "engine_fault":
		warning = "ENGINE FAULT // 动力故障注入"
		ship_target_throttle = 0.0
		ship_external_throttle = 0.0
	elif incident_key == "rudder_fault":
		warning = "RUDDER FAULT // 舵机故障注入"
		ship_target_rudder = clampf(ship_target_rudder + 0.35 * intensity, -1.0, 1.0)
	var slowdown := clampf(1.0 - 0.26 * intensity, 0.22, 0.86)
	ship_forward_speed *= slowdown
	velocity.x *= slowdown
	velocity.z *= slowdown
	_trigger_collision_feedback(warning, maxf(ship_impact_min_speed, ship_max_forward_speed * 0.35 * intensity))


func get_ship_telemetry() -> Dictionary:
	return {
		"agent_id": String(ship_agent_id),
		"human_control_enabled": human_control_enabled,
		"external_agent_control_enabled": external_agent_control_enabled,
		"throttle": ship_throttle,
		"target_throttle": ship_target_throttle,
		"speed": _get_ship_signed_speed(),
		"max_forward_speed": ship_max_forward_speed,
		"max_reverse_speed": ship_max_reverse_speed,
		"acceleration": ship_acceleration,
		"deceleration": ship_deceleration,
		"brake_acceleration": ship_brake_acceleration,
		"rudder": ship_rudder,
		"target_rudder": ship_target_rudder,
		"rudder_response": ship_rudder_response,
		"throttle_response": ship_throttle_response,
		"max_turn_rate_degrees": ship_max_turn_rate_degrees,
		"low_speed_turn_factor": ship_low_speed_turn_factor,
		"reverse_turn_factor": ship_reverse_turn_factor,
		"velocity_alignment": ship_velocity_alignment,
		"turn_authority": ship_turn_authority,
		"heading_degrees": fposmod(rad_to_deg(ship_heading_yaw), 360.0),
		"target_heading_degrees": fposmod(rad_to_deg(ship_target_heading_yaw), 360.0),
		"course_degrees": fposmod(rad_to_deg(ship_course_yaw), 360.0),
		"heading_error_degrees": rad_to_deg(ship_heading_error),
		"drift_angle_degrees": rad_to_deg(ship_drift_angle),
		"heading_settle_speed": ship_heading_settle_speed,
		"heading_error_full_rudder_degrees": ship_heading_error_full_rudder_degrees,
		"collision_warning": ship_collision_warning_text,
		"collision_warning_active": ship_impact_warning_time_left > 0.0,
		"last_impact_speed": ship_last_impact_speed
	}


func get_ship_performance_config() -> Dictionary:
	return {
		"agent_id": String(ship_agent_id),
		"max_forward_speed": ship_max_forward_speed,
		"max_reverse_speed": ship_max_reverse_speed,
		"acceleration": ship_acceleration,
		"deceleration": ship_deceleration,
		"brake_acceleration": ship_brake_acceleration,
		"throttle_response": ship_throttle_response,
		"rudder_response": ship_rudder_response,
		"max_turn_rate_degrees": ship_max_turn_rate_degrees,
		"low_speed_turn_factor": ship_low_speed_turn_factor,
		"reverse_turn_factor": ship_reverse_turn_factor,
		"velocity_alignment": ship_velocity_alignment,
		"heading_settle_speed": ship_heading_settle_speed,
		"heading_error_full_rudder_degrees": ship_heading_error_full_rudder_degrees,
		"impact_speed_retention": ship_impact_speed_retention,
		"impact_rebound_speed": ship_impact_rebound_speed
	}


func apply_ship_performance_config(config: Dictionary) -> void:
	ship_max_forward_speed = _config_float(config, "max_forward_speed", ship_max_forward_speed, 0.1, 120.0)
	ship_max_reverse_speed = _config_float(config, "max_reverse_speed", ship_max_reverse_speed, 0.0, 60.0)
	ship_acceleration = _config_float(config, "acceleration", ship_acceleration, 0.01, 60.0)
	ship_deceleration = _config_float(config, "deceleration", ship_deceleration, 0.01, 60.0)
	ship_brake_acceleration = _config_float(config, "brake_acceleration", ship_brake_acceleration, 0.01, 80.0)
	ship_throttle_response = _config_float(config, "throttle_response", ship_throttle_response, 0.01, 30.0)
	ship_rudder_response = _config_float(config, "rudder_response", ship_rudder_response, 0.01, 30.0)
	ship_max_turn_rate_degrees = _config_float(config, "max_turn_rate_degrees", ship_max_turn_rate_degrees, 1.0, 360.0)
	ship_low_speed_turn_factor = _config_float(config, "low_speed_turn_factor", ship_low_speed_turn_factor, 0.0, 1.0)
	ship_reverse_turn_factor = _config_float(config, "reverse_turn_factor", ship_reverse_turn_factor, 0.0, 1.0)
	ship_velocity_alignment = _config_float(config, "velocity_alignment", ship_velocity_alignment, 0.0, 30.0)
	ship_heading_settle_speed = _config_float(config, "heading_settle_speed", ship_heading_settle_speed, 0.0, 20.0)
	ship_heading_error_full_rudder_degrees = _config_float(config, "heading_error_full_rudder_degrees", ship_heading_error_full_rudder_degrees, 1.0, 180.0)
	ship_impact_speed_retention = _config_float(config, "impact_speed_retention", ship_impact_speed_retention, 0.05, 0.95)
	ship_impact_rebound_speed = _config_float(config, "impact_rebound_speed", ship_impact_rebound_speed, 0.0, 20.0)


func set_ship_agent_command(throttle_command: float, rudder_command: float) -> void:
	external_agent_control_enabled = true
	ship_external_throttle = clampf(throttle_command, -1.0, 1.0)
	ship_external_rudder = clampf(rudder_command, -1.0, 1.0)


func clear_ship_agent_command() -> void:
	external_agent_control_enabled = false
	ship_external_throttle = 0.0
	ship_external_rudder = 0.0


func set_ship_human_control_enabled(enabled: bool) -> void:
	human_control_enabled = enabled
	if enabled:
		add_to_group(&"player")
	else:
		remove_from_group(&"player")


func set_ship_camera_enabled(enabled: bool) -> void:
	camera_enabled = enabled
	if player_camera != null:
		player_camera.current = enabled
		if enabled:
			_update_camera_mount()


func set_ship_selection_highlight(selected: bool) -> void:
	_ensure_ship_selection_indicator()
	if _selection_indicator != null:
		_selection_indicator.visible = selected


func reset_ship_motion_state() -> void:
	velocity = Vector3.ZERO
	ship_target_throttle = 0.0
	ship_throttle = 0.0
	ship_target_rudder = 0.0
	ship_rudder = 0.0
	ship_forward_speed = 0.0
	ship_turn_authority = 0.0
	ship_heading_error = 0.0
	ship_drift_angle = 0.0
	ship_external_throttle = 0.0
	ship_external_rudder = 0.0
	ship_course_yaw = ship_heading_yaw
	ship_target_heading_yaw = ship_heading_yaw
	ship_impact_warning_time_left = 0.0
	ship_impact_feedback_cooldown_left = 0.0
	ship_collision_warning_text = "CLEAR"
	ship_last_impact_speed = 0.0


func prepare_ship_fleet_spawn(world_position: Vector3, heading_degrees: float) -> void:
	global_position = world_position
	ship_heading_yaw = deg_to_rad(heading_degrees)
	reset_ship_motion_state()
	set_ship_camera_enabled(false)
	set_ship_selection_highlight(false)
	_update_ship_visual()


func set_ship_navigation_spawn(world_position: Vector3, heading_degrees: float) -> void:
	global_position = world_position
	ship_heading_yaw = deg_to_rad(heading_degrees)
	reset_ship_motion_state()
	_update_ship_visual()
	_update_camera_mount()


func _ensure_ship_selection_indicator() -> void:
	if _selection_indicator != null and is_instance_valid(_selection_indicator):
		return
	_selection_indicator = get_node_or_null("ShipSelectionRing") as MeshInstance3D
	if _selection_indicator == null:
		_selection_indicator = MeshInstance3D.new()
		_selection_indicator.name = "ShipSelectionRing"
		_selection_indicator.position = Vector3(0.0, 0.12, 0.0)
		var ring_mesh := TorusMesh.new()
		ring_mesh.inner_radius = 2.2
		ring_mesh.outer_radius = 2.32
		_selection_indicator.mesh = ring_mesh
		var material := StandardMaterial3D.new()
		material.albedo_color = SELECTION_RING_COLOR
		material.emission_enabled = true
		material.emission = SELECTION_RING_COLOR
		material.emission_energy_multiplier = 1.8
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_selection_indicator.material_override = material
		_selection_indicator.visible = false
		add_child(_selection_indicator)


func _config_float(config: Dictionary, key: String, fallback: float, min_value: float, max_value: float) -> float:
	if not config.has(key):
		return fallback
	return clampf(float(config[key]), min_value, max_value)

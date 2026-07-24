extends Node3D

const WAKE_SHADER: Shader = preload("res://shaders/ship_wake_foam.gdshader")

@export var player_path: NodePath = ^"../Player"
@export var water_surface_offset: float = 0.60
@export var surface_lift: float = 0.035
@export var stern_offset: float = 1.45
@export var min_spawn_speed: float = 0.55
@export var spawn_interval: float = 0.07
@export var wake_length: float = 2.35
@export var wake_width: float = 1.08
@export var wake_lifetime: float = 2.05
@export var speed_lifetime_boost: float = 0.95
@export var side_wake_angle_degrees: float = 24.0
@export var turn_wake_threshold: float = 0.16
@export var turn_wake_curve_degrees: float = 58.0
@export var turn_wake_width_boost: float = 0.82
@export var max_pieces: int = 190

var _player: Node3D
var _spawn_timer: float = 0.0
var _pieces: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 20260705
	_resolve_player()


func _process(delta: float) -> void:
	if _player == null or not is_instance_valid(_player) or not _player.is_in_group(&"player"):
		_resolve_player()

	_update_pieces(delta)

	if _player == null or not _player.has_method("get_ship_telemetry"):
		return

	var telemetry: Dictionary = _player.call("get_ship_telemetry")
	var signed_speed := float(telemetry.get("speed", 0.0))
	var speed := absf(signed_speed)
	if _player is CharacterBody3D:
		var ship_body := _player as CharacterBody3D
		var horizontal_velocity := Vector3(ship_body.velocity.x, 0.0, ship_body.velocity.z)
		speed = maxf(speed, horizontal_velocity.length())

	var max_forward_speed := maxf(float(telemetry.get("max_forward_speed", 1.0)), 0.001)
	var speed_ratio := clampf(speed / max_forward_speed, 0.0, 1.0)
	if speed < min_spawn_speed:
		_spawn_timer = minf(_spawn_timer, spawn_interval)
		return

	_spawn_timer -= delta
	if _spawn_timer > 0.0:
		return

	var heading_yaw := deg_to_rad(float(telemetry.get("heading_degrees", 0.0)))
	var forward := Vector3(sin(heading_yaw), 0.0, cos(heading_yaw)).normalized()
	var turn_axis := float(telemetry.get("rudder", 0.0))
	var target_rudder := float(telemetry.get("target_rudder", 0.0))
	var heading_error_degrees := float(telemetry.get("heading_error_degrees", 0.0))
	var drift_angle_degrees := float(telemetry.get("drift_angle_degrees", 0.0))
	var turn_strength := _get_turn_wake_strength(
		turn_axis,
		target_rudder,
		heading_error_degrees,
		drift_angle_degrees,
		speed_ratio
	)
	var turn_sign := _get_turn_sign(turn_axis, target_rudder, heading_error_degrees, drift_angle_degrees)
	_spawn_wake_burst(forward, signed_speed, speed_ratio, turn_strength, turn_sign)
	_spawn_timer = lerpf(spawn_interval * 1.25, spawn_interval * 0.48, speed_ratio) * lerpf(1.0, 0.72, turn_strength)


func _resolve_player() -> void:
	var found_player := get_tree().get_first_node_in_group(&"player")
	if found_player == null:
		found_player = get_node_or_null(player_path)
	if found_player is Node3D:
		_player = found_player


func _get_turn_wake_strength(
	rudder: float,
	target_rudder: float,
	heading_error_degrees: float,
	drift_angle_degrees: float,
	speed_ratio: float
) -> float:
	var rudder_strength := maxf(absf(rudder), absf(target_rudder) * 0.72)
	var heading_strength := clampf(absf(heading_error_degrees) / 70.0, 0.0, 1.0)
	var drift_strength := clampf(absf(drift_angle_degrees) / 44.0, 0.0, 1.0)
	var speed_gate := smoothstep(0.06, 0.36, speed_ratio)
	return clampf(maxf(rudder_strength, maxf(heading_strength * 0.78, drift_strength * 0.92)) * speed_gate, 0.0, 1.0)


func _get_turn_sign(
	rudder: float,
	target_rudder: float,
	heading_error_degrees: float,
	drift_angle_degrees: float
) -> float:
	var source := rudder
	if absf(source) < 0.05:
		source = target_rudder
	if absf(source) < 0.05:
		source = heading_error_degrees
	if absf(source) < 0.05:
		source = drift_angle_degrees
	if source > 0.0:
		return 1.0
	if source < 0.0:
		return -1.0
	return 0.0


func _spawn_wake_burst(
	forward: Vector3,
	signed_speed: float,
	speed_ratio: float,
	turn_strength: float = 0.0,
	turn_sign: float = 0.0
) -> void:
	var travel_sign := 1.0 if signed_speed >= 0.0 else -1.0
	var wake_direction := (-forward * travel_sign).normalized()
	var side := Vector3(forward.z, 0.0, -forward.x).normalized()
	var water_y := _player.global_position.y + water_surface_offset + surface_lift
	var wake_anchor := Vector3(_player.global_position.x, water_y, _player.global_position.z) - forward * stern_offset * travel_sign
	var life := wake_lifetime + speed_lifetime_boost * speed_ratio
	var center_length := wake_length * lerpf(0.72, 1.42, speed_ratio)
	var center_width := wake_width * lerpf(0.56, 1.10, speed_ratio)
	center_width *= 1.0 + turn_wake_width_boost * turn_strength
	center_length *= 1.0 + turn_strength * 0.16
	var center_alpha := lerpf(0.38, 0.92, speed_ratio)
	center_alpha = clampf(center_alpha + turn_strength * 0.12, 0.0, 1.0)
	var drift_speed := lerpf(0.16, 0.55, speed_ratio)
	var jitter := side * _rng.randf_range(-0.12, 0.12)

	_add_piece(
		wake_anchor + jitter + wake_direction * center_length * 0.48,
		wake_direction,
		center_width,
		center_length,
		center_alpha,
		life,
		wake_direction * drift_speed,
		Color(0.95, 0.99, 1.0, 0.86),
		0.72,
		0.20
	)

	var side_angle := deg_to_rad(side_wake_angle_degrees)
	for side_value in [-1.0, 1.0]:
		var side_sign := float(side_value)
		var feather_direction: Vector3 = wake_direction.rotated(Vector3.UP, side_angle * side_sign).normalized()
		var side_offset: Vector3 = side * side_sign * center_width * lerpf(0.32, 0.56, speed_ratio)
		_add_piece(
			wake_anchor + side_offset + feather_direction * center_length * 0.42,
			feather_direction,
			center_width * 0.34,
			center_length * 0.92,
			center_alpha * 0.62,
			life * 0.88,
			(feather_direction + side * side_sign * 0.35).normalized() * drift_speed * 0.75,
			Color(0.84, 0.95, 1.0, 0.70),
			0.95,
			0.12
			)

	if turn_strength >= turn_wake_threshold and turn_sign != 0.0:
		_spawn_turning_wake(
			wake_anchor,
			wake_direction,
			side,
			turn_sign,
			turn_strength,
			speed_ratio,
			center_width,
			center_length,
			center_alpha,
			life,
			drift_speed
		)

	var fleck_count := int(round(lerpf(1.0, 4.0, speed_ratio)))
	for index in fleck_count:
		var fleck_direction := wake_direction.rotated(Vector3.UP, _rng.randf_range(-0.36, 0.36)).normalized()
		var fleck_distance := _rng.randf_range(0.18, center_length * 0.86)
		var fleck_side := side * _rng.randf_range(-center_width * 0.54, center_width * 0.54)
		var fleck_size := _rng.randf_range(0.18, 0.34) * lerpf(0.85, 1.25, speed_ratio)
		_add_piece(
			wake_anchor + wake_direction * fleck_distance + fleck_side,
			fleck_direction,
			fleck_size,
			fleck_size * _rng.randf_range(1.4, 2.6),
			center_alpha * _rng.randf_range(0.34, 0.55),
			life * _rng.randf_range(0.48, 0.72),
			wake_direction * drift_speed * _rng.randf_range(0.50, 0.88),
			Color(0.98, 1.0, 1.0, 0.74),
			1.10,
			0.16
		)

	_trim_oldest_pieces()


func _spawn_turning_wake(
	wake_anchor: Vector3,
	wake_direction: Vector3,
	side: Vector3,
	turn_sign: float,
	turn_strength: float,
	speed_ratio: float,
	center_width: float,
	center_length: float,
	center_alpha: float,
	life: float,
	drift_speed: float
) -> void:
	var outer_side := side * turn_sign
	var curve_radians := deg_to_rad(turn_wake_curve_degrees * lerpf(0.36, 1.0, turn_strength))
	var arc_segments := 2 + int(round(turn_strength * 2.0))
	var outside_band_direction := wake_direction.rotated(Vector3.UP, curve_radians * 0.34 * turn_sign).normalized()
	var outside_band_center := wake_anchor \
		+ outer_side * center_width * lerpf(0.62, 0.95, turn_strength) \
		+ wake_direction * center_length * 0.38

	_add_piece(
		outside_band_center,
		outside_band_direction,
		center_width * lerpf(0.46, 0.82, turn_strength),
		center_length * lerpf(0.72, 1.10, turn_strength),
		center_alpha * lerpf(0.34, 0.62, turn_strength),
		life * 0.98,
		(outside_band_direction + outer_side * 0.42).normalized() * drift_speed * 0.92,
		Color(0.78, 0.94, 1.0, 0.62),
		1.35,
		0.18
	)

	for segment_index in range(arc_segments):
		var t := (float(segment_index) + 0.5) / float(arc_segments)
		var segment_curve := curve_radians * t * turn_sign
		var segment_direction := wake_direction.rotated(Vector3.UP, segment_curve).normalized()
		var side_distance := center_width * lerpf(0.54, 1.48, t) * lerpf(0.82, 1.26, turn_strength)
		var back_distance := center_length * lerpf(0.18, 0.88, t)
		var arc_center := wake_anchor + outer_side * side_distance + wake_direction * back_distance
		var segment_width := center_width * lerpf(0.24, 0.54, turn_strength) * lerpf(0.84, 1.18, t)
		var segment_length := center_length * lerpf(0.42, 0.76, turn_strength) * lerpf(1.06, 0.82, t)
		var segment_alpha := center_alpha * lerpf(0.40, 0.78, turn_strength) * lerpf(1.0, 0.72, t)
		var segment_drift := (segment_direction + outer_side * lerpf(0.18, 0.58, t)).normalized() * drift_speed * lerpf(0.76, 1.15, t)

		_add_piece(
			arc_center,
			segment_direction,
			segment_width,
			segment_length,
			segment_alpha,
			life * lerpf(0.82, 1.08, t),
			segment_drift,
			Color(0.88, 0.98, 1.0, 0.76),
			1.16,
			0.16
		)


func _add_piece(
	center: Vector3,
	direction: Vector3,
	width: float,
	length: float,
	alpha: float,
	life: float,
	drift: Vector3,
	color: Color,
	spread_x: float,
	spread_z: float
) -> void:
	var flat_direction := Vector3(direction.x, 0.0, direction.z)
	if flat_direction.length_squared() <= 0.0001:
		return
	flat_direction = flat_direction.normalized()

	var mesh := PlaneMesh.new()
	mesh.size = Vector2(maxf(width, 0.05), maxf(length, 0.05))

	var material := ShaderMaterial.new()
	material.shader = WAKE_SHADER
	material.set_shader_parameter("foam_color", color)
	material.set_shader_parameter("alpha", alpha)
	material.set_shader_parameter("seed", _rng.randf_range(0.0, 1000.0))

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.material_override = material
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.extra_cull_margin = 3.0
	mesh_instance.name = "WakeFoam"
	add_child(mesh_instance)

	var yaw := atan2(flat_direction.x, flat_direction.z)
	mesh_instance.global_transform = Transform3D(Basis(Vector3.UP, yaw), center)
	_pieces.append({
		"node": mesh_instance,
		"age": 0.0,
		"life": maxf(life, 0.05),
		"alpha": alpha,
		"drift": drift,
		"spread_x": spread_x,
		"spread_z": spread_z
	})


func _update_pieces(delta: float) -> void:
	for index in range(_pieces.size() - 1, -1, -1):
		var piece := _pieces[index]
		var mesh_instance := piece["node"] as MeshInstance3D
		if not is_instance_valid(mesh_instance):
			_pieces.remove_at(index)
			continue

		var age := float(piece["age"]) + delta
		var life := float(piece["life"])
		var fade := clampf(1.0 - age / life, 0.0, 1.0)
		if fade <= 0.0:
			mesh_instance.queue_free()
			_pieces.remove_at(index)
			continue

		var material := mesh_instance.material_override as ShaderMaterial
		if material != null:
			material.set_shader_parameter("alpha", float(piece["alpha"]) * pow(fade, 1.45))

		var drift: Vector3 = piece["drift"]
		var spread_x := float(piece["spread_x"])
		var spread_z := float(piece["spread_z"])
		var progress := clampf(age / life, 0.0, 1.0)
		mesh_instance.global_position += drift * delta
		mesh_instance.scale = Vector3(1.0 + progress * spread_x, 1.0, 1.0 + progress * spread_z)

		piece["age"] = age
		_pieces[index] = piece


func _trim_oldest_pieces() -> void:
	while _pieces.size() > max_pieces:
		var piece: Dictionary = _pieces.pop_front()
		var mesh_instance := piece["node"] as MeshInstance3D
		if is_instance_valid(mesh_instance):
			mesh_instance.queue_free()

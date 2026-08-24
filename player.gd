extends CharacterBody3D

const CATAMARAN_DYNAMICS_SCRIPT := preload("res://scripts/physics/catamaran_three_dof_dynamics.gd")

const SHIP_CAMERA_DEFAULT_POSITION := Vector3(0.0, 7.0, 16.0)
const SHIP_CAMERA_DEFAULT_ROTATION_DEGREES := Vector3(-0.5, 0.0, 0.0)
const SHIP_VISUAL_DEFAULT_POSITION := Vector3(0.0, 1, 0.0)
const SHIP_VISUAL_DEFAULT_SCALE := Vector3.ONE
const SHIP_INITIAL_FORWARD := Vector3(0.0, 0.0, -1.0)
const SHIP_VISUAL_RENDER_PRIORITY := 8
const SHIP_SELECTION_RING_POSITION := Vector3(0.0, 0.72, 0.0)
const SHIP_SELECTION_RING_COLOR := Color(0.28, 0.96, 1.0, 0.74)

@export var move_speed: float = 5.0
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
@export var ship_animation_speed_threshold: float = 0.18
@export_group("Ship Hydrodynamics")
@export var ship_three_dof_enabled: bool = true
@export_file("*.json") var ship_dynamics_config_path: String = "res://data/verification/catamaran_usv_dynamics_reference_v2.json"
@export_group("Ship Collision Feedback")
@export var ship_impact_min_speed: float = 1.7
@export_range(0.05, 0.95, 0.01) var ship_impact_speed_retention: float = 0.36
@export var ship_impact_rebound_speed: float = 1.05
@export var ship_impact_warning_duration: float = 1.35
@export var ship_impact_feedback_cooldown: float = 0.36
@export var ship_impact_shake_duration: float = 0.32
@export var ship_impact_camera_shake: float = 0.42
@export_group("Ship Agent Control")
@export var ship_agent_id: StringName = &"ship_00"
@export var human_control_enabled: bool = true
@export var external_agent_control_enabled: bool = false
@export var camera_enabled: bool = true
@export var selectable_ship_agent: bool = true
@export_group("")
@export var jump_velocity: float = 9.5
@export var double_jump_velocity: float = 13
@export var gravity: float = 20.0

@export var lightness_speed: float = 11.0
@export var lightness_duration: float = 4.0
@export var lightness_fall_speed: float = -1.2
@export var lightness_hold_time: float = 0.25
@export var lightness_jump_velocity: float = 8.0 # 定高模式下不再参与控制，可保留
@export var lightness_rise_height: float = 5.0 # 大轻功启动后上升的目标高度（米）
@export var lightness_rise_speed: float = 8.0 # 上升与定高修正速度
@export var lightness_height_tolerance: float = 0.05 # 目标高度允许误差
@export var lightness_vertical_brake_duration: float = 2.0 # 接近目标高度后，竖直速度平滑减到 0 的时间
@export var visual_turn_speed: float = 7.0
@export var use_continuous_ship_turn_visual: bool = true
@export var continuous_ship_visual_turn_rate_degrees: float = 82.0
@export var camera_yaw_speed: float = 1.6
@export var camera_pitch_speed: float = 1.2
@export var camera_min_pitch_degrees: float = 12.0
@export var camera_max_pitch_degrees: float = 72.0
@export var camera_focus_height: float = 1.4
@export_group("Ship Camera Feel")
@export var camera_follow_damping: float = 4.8
@export var camera_focus_damping: float = 6.4
@export var camera_speed_pullback: float = 7.4
@export var camera_speed_height_boost: float = 1.55
@export var camera_speed_fov_boost: float = 5.8
@export var camera_turn_side_offset: float = 2.25
@export var camera_turn_back_offset: float = 1.15
@export var camera_turn_focus_offset: float = 0.82
@export var camera_turn_response: float = 3.7
@export_group("Ship Camera Autopilot")
@export var camera_heading_follow_reactivation_delay: float = 1.25
@export var camera_heading_follow_response: float = 8.0
@export_group("")
@export var idle_action_delay: float = 5.0
@export var idle_action_interval: float = 5.0
@export var combo_window: float = 0.55

@export var down_attack_scale: float = 1.20
@export var up_attack_scale: float = 1.30
@export var diagonal_attack_scale: float = 1.15
@export var northeast_attack_scale: float = 1.25
@export var right_attack_scale: float = 1.15

# 跳跃 / 大轻功的独立人物缩放。
# 左侧方向使用右侧动画的镜像，因此会自动沿用对应右侧动画的缩放比例。
@export var down_jump_scale: float = 0.80
@export var northeast_jump_scale: float = 1.15

@export var down_double_jump_scale: float = 0.80
@export var right_double_jump_scale: float = 0.80
@export var northeast_double_jump_scale: float = 0.80
@export var southeast_double_jump_scale: float = 0.80

@export var up_lightness_scale: float = 1.20
@export var down_lightness_scale: float = 1.20
@export var right_lightness_scale: float = 0.80
@export var southeast_lightness_scale: float = 0.80

@export var southeast_idle_action_animation: StringName = &"attack-2"
@export var northeast_idle_action_animation: StringName = &"待机_攻击_northeast"
@export var right_idle_action_animation: StringName = &"待机正向_right"
@export var down_idle_action_animation: StringName = &"待机面向主角_down"

@export var southeast_attack_animation: StringName = &"普攻1"
@export var southeast_attack2_animation: StringName = &"普攻2右下和下-2"
@export var southeast_attack3_animation: StringName = &"普攻3右下"

@export var northeast_attack_animation: StringName = &"普攻1右上"
@export var northeast_attack2_animation: StringName = &"普攻2右上"
@export var northeast_attack3_animation: StringName = &"普攻3右上"

@export var down_attack_animation: StringName = &"普攻1下"
@export var down_attack2_animation: StringName = &"普攻2下"
@export var down_attack3_animation: StringName = &"普攻3下"

@export var up_attack_animation: StringName = &"普攻1上"
@export var up_attack2_animation: StringName = &"普攻2上"
@export var up_attack3_animation: StringName = &"普攻3上"

@export var right_attack_animation: StringName = &"普攻1右"
@export var right_attack2_animation: StringName = &"普攻2右"
@export var right_attack3_animation: StringName = &"普攻3右"

@export var down_jump_animation: StringName = &"跳跃1下"
@export var right_jump_animation: StringName = &"跳跃1右"
@export var northeast_jump_animation: StringName = &"跳跃1右上"
@export var southeast_jump_animation: StringName = &"跳跃1右下"

@export var double_jump_up_animation: StringName = &"跟头上"
@export var double_jump_down_animation: StringName = &"跟头下"
@export var double_jump_right_animation: StringName = &"跟头右"
@export var double_jump_northeast_animation: StringName = &"跟头右上"
@export var double_jump_southwest_animation: StringName = &"跟头左下"

@export var lightness_up_animation: StringName = &"御剑上"
@export var lightness_down_animation: StringName = &"御剑下"
@export var lightness_right_animation: StringName = &"御剑右"
@export var lightness_northeast_animation: StringName = &"御剑右上"
@export var lightness_southeast_animation: StringName = &"御剑右下"


var jumps_used: int = 0
var lightness_used: bool = false
var lightness_time_left: float = 0.0
var lightness_target_height: float = 0.0
var lightness_is_braking: bool = false
var lightness_brake_time: float = 0.0
var lightness_brake_start_velocity: float = 0.0
var jump_hold_time: float = 0.0

var last_direction: Vector3 = SHIP_INITIAL_FORWARD
var visual_direction: Vector3 = SHIP_INITIAL_FORWARD
var last_run_animation: StringName = &""
var is_reversing_run_north_northeast: bool = false
var reversing_run_north_northeast_flip_h: bool = false

var idle_action_wait_left: float = 0.0
var is_playing_idle_action: bool = false
var is_playing_attack: bool = false
var current_idle_action_key: String = ""

var normal_visual_scale: Vector3 = Vector3.ONE

var current_attack_animation: StringName = &""
var current_attack_key: String = ""

var next_attack_queued: bool = false
var combo_time_left: float = 0.0
var last_finished_attack_key: String = ""

var lower_diagonal_attack_flip_h: bool = false
var upper_diagonal_attack_flip_h: bool = false
var right_attack_flip_h: bool = false

var j_was_down: bool = false
var camera_yaw: float = 0.0
var camera_pitch: float = 0.0
var camera_distance: float = 0.0
var camera_base_fov: float = 65.0
var camera_follow_position: Vector3 = Vector3.ZERO
var camera_focus_position: Vector3 = Vector3.ZERO
var camera_turn_sway: float = 0.0
var camera_heading_follow_enabled: bool = false
var camera_manual_override_time_left: float = 0.0
var player_visual_base_position: Vector3 = Vector3.ZERO
var ship_visual_heading_roll: float = 0.0
var ship_heading_yaw: float = 0.0
var ship_target_throttle: float = 0.0
var ship_throttle: float = 0.0
var ship_target_rudder: float = 0.0
var ship_rudder: float = 0.0
var ship_forward_speed: float = 0.0
var ship_turn_authority: float = 0.0
var ship_target_heading_yaw: float = 0.0
var ship_course_yaw: float = 0.0
var ship_heading_error: float = 0.0
var ship_drift_angle: float = 0.0
var ship_impact_warning_time_left: float = 0.0
var ship_impact_feedback_cooldown_left: float = 0.0
var ship_impact_shake_time_left: float = 0.0
var ship_impact_shake_strength: float = 0.0
var ship_collision_warning_text: String = "CLEAR"
var ship_last_impact_speed: float = 0.0
var ship_external_throttle: float = 0.0
var ship_external_rudder: float = 0.0
var _catamaran_dynamics: CatamaranThreeDofDynamics
var _catamaran_dynamics_ready := false
var _catamaran_dynamics_status: Dictionary = {}
var _selection_indicator: MeshInstance3D


@onready var player_camera: Camera3D = $Camera3D
@onready var player_visual: AnimatedSprite3D = $LegacyAnimationStateDriver
@onready var procedural_usv_visual: Node3D = $ProceduralUSVVisual
@onready var ship_collision_shape: CollisionShape3D = $CollisionShape3D
@onready var action_lock: PlayerActionLock = $ActionLock


func _ready() -> void:
	add_to_group(&"ship_agent")
	if human_control_enabled:
		add_to_group(&"player")
	_configure_ship_visual_rendering()
	player_visual.visible = false
	if procedural_usv_visual != null:
		procedural_usv_visual.call("set_active", true)
	player_visual.position = SHIP_VISUAL_DEFAULT_POSITION
	normal_visual_scale = player_visual.scale
	player_visual_base_position = player_visual.position
	ship_heading_yaw = atan2(last_direction.x, last_direction.z)
	ship_target_heading_yaw = ship_heading_yaw
	ship_course_yaw = ship_heading_yaw
	_catamaran_dynamics = CATAMARAN_DYNAMICS_SCRIPT.new() as CatamaranThreeDofDynamics
	_catamaran_dynamics_ready = _catamaran_dynamics.configure_from_json(ship_dynamics_config_path)
	if _catamaran_dynamics_ready:
		_catamaran_dynamics.reset(ship_heading_yaw)
		_catamaran_dynamics_status = _catamaran_dynamics.get_status()
	elif ship_three_dof_enabled:
		push_error("Catamaran 3-DOF dynamics configuration is invalid: %s" % ship_dynamics_config_path)
	if camera_enabled:
		_setup_camera_orbit()
	else:
		player_camera.current = false

	player_visual.play(&"idle_up")
	player_visual.frame = 0
	player_visual.flip_h = false

	idle_action_wait_left = idle_action_delay

	var sprite_frames: SpriteFrames = player_visual.sprite_frames

	if sprite_frames:
		_set_animation_not_looping(sprite_frames, southeast_idle_action_animation)
		_set_animation_not_looping(sprite_frames, northeast_idle_action_animation)
		_set_animation_not_looping(sprite_frames, right_idle_action_animation)
		_set_animation_not_looping(sprite_frames, down_idle_action_animation)

		_set_animation_not_looping(sprite_frames, southeast_attack_animation)
		_set_animation_not_looping(sprite_frames, southeast_attack2_animation)
		_set_animation_not_looping(sprite_frames, southeast_attack3_animation)

		_set_animation_not_looping(sprite_frames, northeast_attack_animation)
		_set_animation_not_looping(sprite_frames, northeast_attack2_animation)
		_set_animation_not_looping(sprite_frames, northeast_attack3_animation)

		_set_animation_not_looping(sprite_frames, down_attack_animation)
		_set_animation_not_looping(sprite_frames, down_attack2_animation)
		_set_animation_not_looping(sprite_frames, down_attack3_animation)

		_set_animation_not_looping(sprite_frames, up_attack_animation)
		_set_animation_not_looping(sprite_frames, up_attack2_animation)
		_set_animation_not_looping(sprite_frames, up_attack3_animation)

		_set_animation_not_looping(sprite_frames, right_attack_animation)
		_set_animation_not_looping(sprite_frames, right_attack2_animation)
		_set_animation_not_looping(sprite_frames, right_attack3_animation)

		_set_animation_not_looping(sprite_frames, down_jump_animation)
		_set_animation_not_looping(sprite_frames, right_jump_animation)
		_set_animation_not_looping(sprite_frames, northeast_jump_animation)
		_set_animation_not_looping(sprite_frames, southeast_jump_animation)

		_set_animation_not_looping(sprite_frames, double_jump_up_animation)
		_set_animation_not_looping(sprite_frames, double_jump_down_animation)
		_set_animation_not_looping(sprite_frames, double_jump_right_animation)
		_set_animation_not_looping(sprite_frames, double_jump_northeast_animation)
		_set_animation_not_looping(sprite_frames, double_jump_southwest_animation)

		_set_animation_not_looping(sprite_frames, &"run_north_northeast")

		player_visual.animation_finished.connect(_on_player_visual_animation_finished)


func _configure_ship_visual_rendering() -> void:
	player_visual.modulate = Color.WHITE
	player_visual.no_depth_test = true
	player_visual.render_priority = SHIP_VISUAL_RENDER_PRIORITY
	player_visual.shaded = false


func _apply_continuous_ship_heading(facing_direction: Vector3) -> void:
	if facing_direction == Vector3.ZERO:
		return

	# The neutral ship texture points toward screen-up. Rotate that same texture
	# continuously instead of restarting a direction clip at frame zero.
	ship_visual_heading_roll = -atan2(facing_direction.x, -facing_direction.z)
	player_visual.flip_h = false
	_update_visual_camera_facing()


func _play_continuous_ship_animation(animation_name: StringName) -> void:
	var sprite_frames := player_visual.sprite_frames
	if sprite_frames == null or not sprite_frames.has_animation(animation_name):
		return

	if player_visual.animation == animation_name:
		if not player_visual.is_playing():
			player_visual.play()
		return

	var previous_phase: float = 0.0
	if sprite_frames.has_animation(player_visual.animation):
		var previous_frame_count := sprite_frames.get_frame_count(player_visual.animation)
		if previous_frame_count > 0:
			previous_phase = (
				float(player_visual.frame) + player_visual.frame_progress
			) / float(previous_frame_count)

	player_visual.play(animation_name)

	var target_frame_count := sprite_frames.get_frame_count(animation_name)
	if target_frame_count <= 0:
		return

	var target_frame_position := fposmod(previous_phase, 1.0) * float(target_frame_count)
	var target_frame := mini(int(floor(target_frame_position)), target_frame_count - 1)
	player_visual.set_frame_and_progress(
		target_frame,
		target_frame_position - float(target_frame)
	)


func _ensure_ship_selection_indicator() -> void:
	if _selection_indicator != null and is_instance_valid(_selection_indicator):
		return
	_selection_indicator = get_node_or_null("ShipSelectionRing") as MeshInstance3D
	if _selection_indicator != null:
		return

	_selection_indicator = MeshInstance3D.new()
	_selection_indicator.name = "ShipSelectionRing"
	_selection_indicator.position = SHIP_SELECTION_RING_POSITION
	_selection_indicator.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 0.82
	ring_mesh.outer_radius = 0.88
	_selection_indicator.mesh = ring_mesh
	_selection_indicator.material_override = _make_ship_selection_ring_material()
	_selection_indicator.visible = false
	add_child(_selection_indicator)


func _make_ship_selection_ring_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = SHIP_SELECTION_RING_COLOR
	material.emission_enabled = true
	material.emission = SHIP_SELECTION_RING_COLOR
	material.emission_energy_multiplier = 1.8
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	material.render_priority = SHIP_VISUAL_RENDER_PRIORITY + 1
	return material


func _set_animation_not_looping(sprite_frames: SpriteFrames, animation_name: StringName) -> void:
	if sprite_frames.has_animation(animation_name):
		sprite_frames.set_animation_loop(animation_name, false)


func _set_normal_visual_scale() -> void:
	player_visual.scale = normal_visual_scale


func _set_air_visual_scale(scale_multiplier: float) -> void:
	player_visual.scale = normal_visual_scale * scale_multiplier


func _set_down_attack_visual_scale() -> void:
	player_visual.scale = normal_visual_scale * down_attack_scale


func _set_up_attack_visual_scale() -> void:
	player_visual.scale = normal_visual_scale * up_attack_scale


func _set_diagonal_attack_visual_scale() -> void:
	player_visual.scale = normal_visual_scale * diagonal_attack_scale


# 右上普攻动画与左上镜像共用这一套缩放。
func _set_northeast_attack_visual_scale() -> void:
	player_visual.scale = normal_visual_scale * northeast_attack_scale


func _set_right_attack_visual_scale() -> void:
	player_visual.scale = normal_visual_scale * right_attack_scale


func _setup_camera_orbit() -> void:
	var initial_camera_global_position := player_camera.global_position
	var camera_offset: Vector3 = player_camera.position
	camera_distance = maxf(camera_offset.length(), 0.001)
	camera_base_fov = player_camera.fov
	camera_follow_position = initial_camera_global_position
	camera_focus_position = global_position + Vector3.UP * camera_focus_height
	player_camera.top_level = true

	var horizontal_distance := Vector2(camera_offset.x, camera_offset.z).length()
	camera_yaw = atan2(camera_offset.x, camera_offset.z)
	camera_pitch = atan2(camera_offset.y, horizontal_distance)
	_apply_camera_orbit(0.0, true)


func _update_camera_orbit(delta: float) -> void:
	var yaw_input: float = 0.0
	if Input.is_key_pressed(KEY_A):
		yaw_input += 1.0
	if Input.is_key_pressed(KEY_D):
		yaw_input -= 1.0

	var pitch_input: float = 0.0
	if Input.is_key_pressed(KEY_R):
		pitch_input -= 1.0
	if Input.is_key_pressed(KEY_F):
		pitch_input += 1.0

	apply_ship_camera_orbit_input(yaw_input, pitch_input, delta)
	_apply_camera_orbit(delta)


func apply_ship_camera_orbit_input(yaw_input: float, pitch_input: float, delta: float) -> void:
	var has_manual_input := not is_zero_approx(yaw_input) or not is_zero_approx(pitch_input)
	if has_manual_input:
		camera_manual_override_time_left = maxf(camera_heading_follow_reactivation_delay, 0.0)
		camera_yaw += yaw_input * camera_yaw_speed * delta

		var min_pitch := deg_to_rad(camera_min_pitch_degrees)
		var max_pitch := deg_to_rad(camera_max_pitch_degrees)
		camera_pitch = clampf(camera_pitch + pitch_input * camera_pitch_speed * delta, min_pitch, max_pitch)
		return
	if not camera_heading_follow_enabled:
		return
	camera_manual_override_time_left = maxf(camera_manual_override_time_left - delta, 0.0)
	if camera_manual_override_time_left > 0.0:
		return
	camera_yaw = lerp_angle(
		camera_yaw,
		_get_camera_heading_follow_yaw(),
		_damping_alpha(camera_heading_follow_response, delta)
	)


func _get_camera_heading_follow_yaw() -> float:
	# camera_yaw is the camera's offset around the ship. Adding PI places the
	# camera behind the bow so look_at() faces along the recorded ship heading.
	return wrapf(ship_heading_yaw + PI, -PI, PI)


func _apply_camera_orbit(delta: float = 0.0, immediate: bool = false) -> void:
	var speed_ratio := _get_camera_speed_ratio()
	var speed_curve := _smooth_unit(speed_ratio)
	var dynamic_distance := camera_distance + camera_speed_pullback * speed_curve
	var horizontal_distance := cos(camera_pitch) * dynamic_distance
	var orbit_offset := Vector3(
		sin(camera_yaw) * horizontal_distance,
		sin(camera_pitch) * dynamic_distance + camera_speed_height_boost * speed_curve,
		cos(camera_yaw) * horizontal_distance
	)

	var ship_forward := _get_ship_forward_vector()
	var ship_side := Vector3(ship_forward.z, 0.0, -ship_forward.x).normalized()
	var drift_sway := clampf(ship_drift_angle / deg_to_rad(52.0), -1.0, 1.0)
	var turn_target := clampf(ship_rudder * 0.74 + drift_sway * 0.26, -1.0, 1.0) * speed_curve
	var turn_alpha := 1.0 if immediate else _damping_alpha(camera_turn_response, delta)
	camera_turn_sway = lerpf(camera_turn_sway, turn_target, turn_alpha)

	var turn_offset := -ship_side * camera_turn_sway * camera_turn_side_offset
	turn_offset += -ship_forward * absf(camera_turn_sway) * camera_turn_back_offset

	var target_camera_position := global_position + orbit_offset + turn_offset
	var target_focus_position := global_position + Vector3.UP * camera_focus_height
	target_focus_position += ship_forward * speed_curve * 0.85
	target_focus_position += ship_side * camera_turn_sway * camera_turn_focus_offset

	if immediate:
		camera_follow_position = target_camera_position
		camera_focus_position = target_focus_position
		player_camera.fov = camera_base_fov + camera_speed_fov_boost * speed_curve
	else:
		camera_follow_position = camera_follow_position.lerp(
			target_camera_position,
			_damping_alpha(camera_follow_damping, delta)
		)
		camera_focus_position = camera_focus_position.lerp(
			target_focus_position,
			_damping_alpha(camera_focus_damping, delta)
		)
		player_camera.fov = lerpf(
			player_camera.fov,
			camera_base_fov + camera_speed_fov_boost * speed_curve,
			_damping_alpha(camera_focus_damping, delta)
		)

	player_camera.global_position = camera_follow_position + _get_camera_shake_offset()
	if player_camera.global_position.distance_squared_to(camera_focus_position) > 0.001:
		player_camera.look_at(camera_focus_position, Vector3.UP)
	_update_visual_camera_facing()


func _get_camera_speed_ratio() -> float:
	var horizontal_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var camera_speed := maxf(absf(ship_forward_speed), horizontal_velocity.length())
	return clampf(camera_speed / maxf(ship_max_forward_speed, 0.001), 0.0, 1.0)


func _smooth_unit(value: float) -> float:
	var clamped_value := clampf(value, 0.0, 1.0)
	return clamped_value * clamped_value * (3.0 - 2.0 * clamped_value)


func _damping_alpha(response: float, delta: float) -> float:
	if delta <= 0.0:
		return 1.0
	return clampf(1.0 - exp(-maxf(response, 0.0) * delta), 0.0, 1.0)


func _get_camera_shake_offset() -> Vector3:
	if ship_impact_shake_time_left <= 0.0 or ship_impact_shake_strength <= 0.0:
		return Vector3.ZERO
	var duration := maxf(ship_impact_shake_duration, 0.001)
	var fade := clampf(ship_impact_shake_time_left / duration, 0.0, 1.0)
	var strength := ship_impact_shake_strength * fade * fade
	var time := Time.get_ticks_msec() * 0.001
	return Vector3(
		sin(time * 73.0) * strength,
		sin(time * 91.0 + 0.7) * strength * 0.34,
		cos(time * 67.0 + 1.9) * strength
	)


func _update_visual_camera_facing() -> void:
	var camera_facing_basis := Basis(Vector3.UP, camera_yaw)
	player_visual.position = camera_facing_basis * player_visual_base_position
	var heading_roll := ship_visual_heading_roll if use_continuous_ship_turn_visual else 0.0
	player_visual.rotation = Vector3(0.0, camera_yaw, heading_roll)
	if procedural_usv_visual != null:
		procedural_usv_visual.rotation = Vector3(0.0, ship_heading_yaw, 0.0)
		procedural_usv_visual.call("set_navigation_state", ship_throttle, ship_rudder, ship_forward_speed)
	if ship_collision_shape != null:
		ship_collision_shape.rotation.y = ship_heading_yaw


func _get_camera_relative_direction(input_direction: Vector3) -> Vector3:
	if input_direction == Vector3.ZERO:
		return Vector3.ZERO

	return (Basis(Vector3.UP, camera_yaw) * input_direction).normalized()


func _physics_process(delta: float) -> void:
	if camera_enabled:
		_update_camera_orbit(delta)

	if action_lock.is_locked(PlayerActionLock.Channel.FREEZE_BODY):
		velocity = Vector3.ZERO
		ship_target_throttle = 0.0
		ship_throttle = 0.0
		ship_target_rudder = 0.0
		ship_rudder = 0.0
		ship_forward_speed = 0.0
		ship_turn_authority = 0.0
		ship_heading_error = 0.0
		ship_drift_angle = 0.0
		if _catamaran_dynamics_ready:
			_catamaran_dynamics.reset(ship_heading_yaw)
		jump_hold_time = 0.0
		j_was_down = false
		return

	var movement_locked := action_lock.is_locked(PlayerActionLock.Channel.MOVEMENT)
	if external_agent_control_enabled:
		_update_ship_direct_motion(delta, ship_external_throttle, ship_external_rudder)
	else:
		var input_vector := Vector2.ZERO if movement_locked or not human_control_enabled else _get_ship_direction_input()
		var input_direction := Vector3(input_vector.x, 0.0, input_vector.y).normalized()
		var target_direction := _get_camera_relative_direction(input_direction)
		_update_ship_motion(delta, target_direction, clampf(input_vector.length(), 0.0, 1.0))

	if combo_time_left > 0.0 and not is_playing_attack:
		combo_time_left = maxf(combo_time_left - delta, 0.0)

		if combo_time_left <= 0.0:
			last_finished_attack_key = ""

	if is_playing_attack:
		is_reversing_run_north_northeast = false
	elif _is_ship_visibly_moving():
		_set_normal_visual_scale()
		_reset_idle_action_state()
		_update_run_animation(visual_direction)
	elif is_on_floor():
		is_reversing_run_north_northeast = false
		_set_normal_visual_scale()
		_reset_idle_action_state()
		_update_idle_animation(visual_direction, 0.0)
	elif lightness_time_left > 0.0:
		is_reversing_run_north_northeast = false
		_set_normal_visual_scale()
		_reset_idle_action_state()
		_update_lightness_animation(visual_direction)
	else:
		is_reversing_run_north_northeast = false
		_set_normal_visual_scale()
		_reset_idle_action_state()
		_update_air_animation(visual_direction)

	j_was_down = false

	var pre_slide_horizontal_velocity := Vector3(velocity.x, 0.0, velocity.z)
	move_and_slide()
	_process_ship_collision_feedback(pre_slide_horizontal_velocity)
	_update_ship_feedback_timers(delta)


func _get_ship_direction_input() -> Vector2:
	var input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if input.length() > 1.0:
		return input.normalized()
	return input


func _process_ship_collision_feedback(pre_slide_horizontal_velocity: Vector3) -> void:
	var strongest_impact_speed := 0.0
	var strongest_normal := Vector3.ZERO
	var strongest_collider: Object = null

	for index in range(get_slide_collision_count()):
		var collision := get_slide_collision(index)
		var normal := collision.get_normal()
		if normal.y > 0.45:
			continue

		var horizontal_normal := Vector3(normal.x, 0.0, normal.z)
		if horizontal_normal.length_squared() <= 0.001:
			continue
		horizontal_normal = horizontal_normal.normalized()

		var impact_speed := maxf(0.0, -pre_slide_horizontal_velocity.dot(horizontal_normal))
		if impact_speed > strongest_impact_speed:
			strongest_impact_speed = impact_speed
			strongest_normal = horizontal_normal
			strongest_collider = collision.get_collider()

	if strongest_normal == Vector3.ZERO:
		return

	if strongest_impact_speed < ship_impact_min_speed:
		if ship_throttle > 0.35 and ship_impact_feedback_cooldown_left <= 0.0:
			_trigger_ship_collision_feedback("GROUNDING // 搁浅，动力受限", ship_impact_min_speed)
		return

	_apply_ship_impact_slowdown(strongest_normal)
	if ship_impact_feedback_cooldown_left <= 0.0:
		_trigger_ship_collision_feedback(_collision_feedback_text(strongest_collider), strongest_impact_speed)


func _apply_ship_impact_slowdown(collision_normal: Vector3) -> void:
	var retention := clampf(ship_impact_speed_retention, 0.05, 0.95)
	ship_forward_speed *= retention
	if _catamaran_dynamics_ready:
		_catamaran_dynamics.apply_collision_retention(retention)
	ship_throttle *= lerpf(0.55, 0.78, retention)
	ship_target_throttle = minf(ship_target_throttle, ship_throttle)

	var horizontal_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var deflected_velocity := horizontal_velocity.slide(collision_normal) * retention
	deflected_velocity += collision_normal * ship_impact_rebound_speed
	velocity.x = deflected_velocity.x
	velocity.z = deflected_velocity.z
	if deflected_velocity.length_squared() > 0.001:
		ship_course_yaw = atan2(deflected_velocity.x, deflected_velocity.z)
	ship_drift_angle = wrapf(ship_heading_yaw - ship_course_yaw, -PI, PI)


func _trigger_ship_collision_feedback(message: String, impact_speed: float) -> void:
	ship_last_impact_speed = impact_speed
	ship_collision_warning_text = message
	ship_impact_warning_time_left = ship_impact_warning_duration
	ship_impact_feedback_cooldown_left = ship_impact_feedback_cooldown
	ship_impact_shake_time_left = ship_impact_shake_duration
	var impact_ratio := clampf(impact_speed / maxf(ship_max_forward_speed, 0.001), 0.0, 1.0)
	ship_impact_shake_strength = ship_impact_camera_shake * lerpf(0.45, 1.0, impact_ratio)


func inject_ship_incident(incident_key: String = "collision", severity: float = 1.0) -> void:
	var intensity := clampf(severity, 0.1, 2.0)
	var warning := "IMPACT DRILL // 事故注入"
	match incident_key:
		"grounding":
			warning = "GROUNDING DRILL // 搁浅事故注入"
		"engine_fault":
			warning = "ENGINE FAULT // 动力故障注入"
		"rudder_fault":
			warning = "RUDDER FAULT // 舵机故障注入"
		_:
			warning = "COLLISION DRILL // 碰撞事故注入"

	var slowdown := clampf(1.0 - 0.26 * intensity, 0.22, 0.86)
	ship_forward_speed *= slowdown
	ship_throttle *= slowdown
	ship_target_throttle = minf(ship_target_throttle, ship_throttle)
	if incident_key == "engine_fault":
		ship_target_throttle = 0.0
		ship_external_throttle = 0.0
	if incident_key == "rudder_fault":
		ship_target_rudder = clampf(ship_target_rudder + 0.35 * intensity, -1.0, 1.0)
		ship_external_rudder = clampf(ship_external_rudder + 0.35 * intensity, -1.0, 1.0)
	velocity.x *= slowdown
	velocity.z *= slowdown
	_trigger_ship_collision_feedback(warning, maxf(ship_impact_min_speed, ship_max_forward_speed * 0.35 * intensity))


func _update_ship_feedback_timers(delta: float) -> void:
	ship_impact_feedback_cooldown_left = maxf(ship_impact_feedback_cooldown_left - delta, 0.0)
	ship_impact_shake_time_left = maxf(ship_impact_shake_time_left - delta, 0.0)
	ship_impact_warning_time_left = maxf(ship_impact_warning_time_left - delta, 0.0)
	if ship_impact_warning_time_left <= 0.0:
		ship_collision_warning_text = "CLEAR"


func _collision_feedback_text(collider: Object) -> String:
	var collider_node := collider as Node
	if collider_node == null:
		return "IMPACT // 船体碰撞"
	var collider_name := collider_node.name.to_lower()
	if collider_name.contains("boundary"):
		return "BOUNDARY IMPACT // 边界碰撞，已减速"
	if collider_name.contains("rock"):
		return "ROCK IMPACT // 岩体碰撞，已减速"
	if collider_node.is_in_group(&"ship_navigation_obstacle"):
		return "NAV OBSTACLE // 航行障碍，已减速"
	return "GROUNDING // 搁浅碰撞，已减速"


func _update_ship_motion(delta: float, target_direction: Vector3, input_strength: float) -> void:
	_update_ship_direct_motion(delta, input_strength, _get_target_rudder_for_direction(target_direction), target_direction)


func _update_ship_direct_motion(
	delta: float,
	throttle_command: float,
	rudder_command: float,
	target_direction: Vector3 = Vector3.ZERO
) -> void:
	if ship_three_dof_enabled and _catamaran_dynamics_ready:
		_update_ship_three_dof_motion(delta, throttle_command, rudder_command)
		return
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

	var speed_delta := absf(target_speed) - absf(ship_forward_speed)
	var acceleration_rate := ship_deceleration
	var current_horizontal_velocity := Vector3(velocity.x, 0.0, velocity.z)
	if target_direction != Vector3.ZERO \
	and current_horizontal_velocity.length() > 0.05 \
	and current_horizontal_velocity.normalized().dot(target_direction) < -0.25:
		acceleration_rate = ship_brake_acceleration
	elif speed_delta > 0.0:
		acceleration_rate = ship_acceleration

	ship_forward_speed = move_toward(ship_forward_speed, target_speed, acceleration_rate * delta)

	var speed_reference := ship_max_forward_speed if ship_forward_speed >= 0.0 else ship_max_reverse_speed
	var speed_ratio := clampf(absf(ship_forward_speed) / maxf(speed_reference, 0.001), 0.0, 1.0)
	var low_speed_factor := ship_low_speed_turn_factor if ship_forward_speed >= -0.05 else ship_reverse_turn_factor
	ship_turn_authority = lerpf(low_speed_factor, 1.0, speed_ratio)

	var turn_rate := deg_to_rad(ship_max_turn_rate_degrees) * ship_turn_authority
	var rudder_direction := 1.0 if ship_forward_speed >= -0.05 else -1.0
	ship_heading_yaw += ship_rudder * turn_rate * rudder_direction * delta

	var heading_direction := _get_ship_forward_vector()
	var desired_horizontal_velocity := heading_direction * ship_forward_speed
	var course_follow_factor := lerpf(0.45, 1.0, ship_turn_authority)
	var alignment := clampf(ship_velocity_alignment * course_follow_factor * delta, 0.0, 1.0)
	current_horizontal_velocity = current_horizontal_velocity.lerp(desired_horizontal_velocity, alignment)
	velocity.x = current_horizontal_velocity.x
	velocity.z = current_horizontal_velocity.z
	if current_horizontal_velocity.length_squared() > 0.001:
		ship_course_yaw = atan2(current_horizontal_velocity.x, current_horizontal_velocity.z)
	else:
		ship_course_yaw = ship_heading_yaw
	ship_drift_angle = wrapf(ship_heading_yaw - ship_course_yaw, -PI, PI)

	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

	_update_ship_visual_direction(delta)


func _update_ship_three_dof_motion(delta: float, throttle_command: float, rudder_command: float) -> void:
	ship_target_throttle = clampf(throttle_command, -1.0, 1.0)
	ship_target_rudder = clampf(rudder_command, -1.0, 1.0)
	var forcing := _get_ship_environment_forcing()
	_catamaran_dynamics_status = _catamaran_dynamics.step(
		ship_target_throttle,
		ship_target_rudder,
		delta,
		forcing
	)
	ship_heading_yaw = float(_catamaran_dynamics_status.get("heading_rad", ship_heading_yaw))
	ship_forward_speed = float(_catamaran_dynamics_status.get("surge_mps", 0.0))
	ship_throttle = 0.5 * (
		float(_catamaran_dynamics_status.get("port_throttle", 0.0))
		+ float(_catamaran_dynamics_status.get("starboard_throttle", 0.0))
	)
	var maximum_steering := maxf(float((_catamaran_dynamics.get_config_snapshot()).get("max_steering_angle_deg", 24.0)), 0.1)
	ship_rudder = clampf(float(_catamaran_dynamics_status.get("steering_angle_deg", 0.0)) / maximum_steering, -1.0, 1.0)
	var speed_ratio := clampf(absf(ship_forward_speed) / maxf(ship_max_forward_speed, 0.001), 0.0, 1.0)
	ship_turn_authority = lerpf(ship_low_speed_turn_factor, 1.0, speed_ratio)
	var ground_velocity := _catamaran_dynamics_status.get("ground_velocity", Vector3.ZERO) as Vector3
	velocity.x = ground_velocity.x
	velocity.z = ground_velocity.z
	if ground_velocity.length_squared() > 0.001:
		ship_course_yaw = atan2(ground_velocity.x, ground_velocity.z)
	else:
		ship_course_yaw = ship_heading_yaw
	ship_drift_angle = wrapf(ship_heading_yaw - ship_course_yaw, -PI, PI)
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta
	_update_ship_visual_direction(delta)


func _get_ship_environment_forcing() -> Dictionary:
	var weather := get_tree().get_first_node_in_group(&"ship_weather_time_system")
	var status: Dictionary = weather.call("get_sea_state_status") as Dictionary \
		if weather != null and weather.has_method("get_sea_state_status") else {}
	var config := _catamaran_dynamics.get_config_snapshot()
	var wind_speed_mps := float(status.get("wind_speed_knots", 0.0)) * 0.514444
	var wind_direction := deg_to_rad(float(status.get("wind_direction_degrees", 0.0)))
	var wind_magnitude := 0.5 * float(config.get("air_density_kg_m3", 1.225)) \
		* float(config.get("wind_drag_coefficient", 1.0)) \
		* float(config.get("wind_lateral_area_m2", 1.0)) * wind_speed_mps * wind_speed_mps
	var wave_height := float(status.get("wave_height_meters", 0.0))
	var wave_direction := deg_to_rad(float(status.get("wave_direction_degrees", status.get("wind_direction_degrees", 0.0))))
	var wave_period := maxf(float(status.get("wave_period_seconds", 6.0)), 1.0)
	var wave_phase := sin(float(_catamaran_dynamics_status.get("simulation_time_s", 0.0)) * TAU / wave_period)
	var wave_magnitude := float(config.get("wave_drift_force_n_per_meter", 0.0)) \
		* wave_height * (0.65 + 0.35 * wave_phase)
	var wind_body := _world_force_to_body(wind_magnitude, wind_direction)
	var wave_body := _world_force_to_body(wave_magnitude, wave_direction)
	var current_speed := float(status.get("current_speed_knots", 0.0)) * 0.514444
	var current_direction := deg_to_rad(float(status.get("current_direction_degrees", 0.0)))
	var current_vector := Vector3(sin(current_direction), 0.0, cos(current_direction)) * current_speed
	var yaw_arm := float(config.get("environment_yaw_arm_m", 0.0))
	return {
		"current_vector_mps": current_vector,
		"wind_force_body_n": wind_body,
		"wave_force_body_n": wave_body,
		"environment_yaw_moment_nm": (wind_body.y + wave_body.y) * yaw_arm,
	}


func _world_force_to_body(magnitude: float, direction_rad: float) -> Vector2:
	var world_force := Vector3(sin(direction_rad), 0.0, cos(direction_rad)) * magnitude
	var forward := _get_ship_forward_vector()
	var starboard := Vector3(forward.z, 0.0, -forward.x)
	return Vector2(world_force.dot(forward), world_force.dot(starboard))


func _update_ship_visual_direction(delta: float) -> void:
	var target_visual_direction := _get_ship_visual_direction()
	if target_visual_direction != Vector3.ZERO:
		last_direction = target_visual_direction
		if visual_direction == Vector3.ZERO:
			visual_direction = target_visual_direction
		else:
			# Angle interpolation keeps the shortest continuous turn even across the
			# -PI/PI seam and for an immediate 180-degree target change.
			var current_visual_yaw := atan2(visual_direction.x, -visual_direction.z)
			var target_visual_yaw := atan2(target_visual_direction.x, -target_visual_direction.z)
			var smoothed_visual_yaw: float
			if use_continuous_ship_turn_visual:
				smoothed_visual_yaw = rotate_toward(
					current_visual_yaw,
					target_visual_yaw,
					deg_to_rad(maxf(continuous_ship_visual_turn_rate_degrees, 1.0)) * delta
				)
			else:
				smoothed_visual_yaw = lerp_angle(
					current_visual_yaw,
					target_visual_yaw,
					clampf(visual_turn_speed * delta, 0.0, 1.0)
				)
			visual_direction = Vector3(
				sin(smoothed_visual_yaw),
				0.0,
				-cos(smoothed_visual_yaw)
			)


func _get_target_rudder_for_direction(target_direction: Vector3) -> float:
	if target_direction == Vector3.ZERO:
		ship_heading_error = 0.0
		return 0.0

	ship_target_heading_yaw = atan2(target_direction.x, target_direction.z)
	ship_heading_error = wrapf(ship_target_heading_yaw - ship_heading_yaw, -PI, PI)
	var full_rudder_angle := deg_to_rad(ship_heading_error_full_rudder_degrees)
	return clampf(ship_heading_error / maxf(full_rudder_angle, 0.001), -1.0, 1.0)


func _get_ship_forward_vector() -> Vector3:
	return Vector3(sin(ship_heading_yaw), 0.0, cos(ship_heading_yaw)).normalized()


func _get_ship_visual_direction() -> Vector3:
	var camera_inverse := Basis(Vector3.UP, -camera_yaw)
	return (camera_inverse * _get_ship_forward_vector()).normalized()


func _is_ship_visibly_moving() -> bool:
	return absf(_get_ship_signed_speed()) >= ship_animation_speed_threshold \
		or absf(ship_throttle) >= 0.04 \
		or absf(ship_rudder) >= 0.04


func _get_ship_signed_speed() -> float:
	var horizontal_velocity := Vector3(velocity.x, 0.0, velocity.z)
	return horizontal_velocity.dot(_get_ship_forward_vector())


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
		"animation_speed_threshold": ship_animation_speed_threshold,
		"collision_warning": ship_collision_warning_text,
		"collision_warning_active": ship_impact_warning_time_left > 0.0,
		"last_impact_speed": ship_last_impact_speed,
		"dynamics_model_id": String(_catamaran_dynamics_status.get("model_id", "legacy_kinematic_v1")) if ship_three_dof_enabled and _catamaran_dynamics_ready else "legacy_kinematic_v1",
		"dynamics_model_family": String(_catamaran_dynamics_status.get("model_family", "kinematic")) if ship_three_dof_enabled and _catamaran_dynamics_ready else "kinematic",
		"dynamics_calibration_status": String(_catamaran_dynamics_status.get("calibration_status", "not_applicable")),
		"named_vessel_dynamics_calibrated": bool(_catamaran_dynamics_status.get("named_vessel_calibrated", false)),
		"surge_mps": float(_catamaran_dynamics_status.get("surge_mps", ship_forward_speed)),
		"sway_mps": float(_catamaran_dynamics_status.get("sway_mps", 0.0)),
		"yaw_rate_deg_s": float(_catamaran_dynamics_status.get("yaw_rate_deg_s", 0.0)),
		"port_throttle": float(_catamaran_dynamics_status.get("port_throttle", ship_throttle)),
		"starboard_throttle": float(_catamaran_dynamics_status.get("starboard_throttle", ship_throttle)),
		"steering_angle_deg": float(_catamaran_dynamics_status.get("steering_angle_deg", ship_rudder)),
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
		"impact_rebound_speed": ship_impact_rebound_speed,
		"dynamics_enabled": ship_three_dof_enabled and _catamaran_dynamics_ready,
		"dynamics_contract": _catamaran_dynamics.get_config_snapshot() if _catamaran_dynamics_ready else {
			"model_id": "legacy_kinematic_v1",
			"calibration_status": "not_applicable",
		}
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
	player_camera.current = enabled
	if enabled:
		if not player_camera.top_level:
			_setup_camera_orbit()
		else:
			_apply_camera_orbit(0.0, true)


func set_ship_camera_heading_follow_enabled(enabled: bool, align_immediately: bool = false) -> void:
	camera_heading_follow_enabled = enabled
	camera_manual_override_time_left = 0.0
	if enabled and align_immediately:
		camera_yaw = _get_camera_heading_follow_yaw()
		_apply_camera_orbit(0.0, true)


func get_ship_camera_heading_follow_status() -> Dictionary:
	var target_yaw := _get_camera_heading_follow_yaw()
	return {
		"enabled": camera_heading_follow_enabled,
		"manual_override_active": camera_manual_override_time_left > 0.0,
		"manual_override_seconds_left": camera_manual_override_time_left,
		"camera_yaw_degrees": fposmod(rad_to_deg(camera_yaw), 360.0),
		"target_yaw_degrees": fposmod(rad_to_deg(target_yaw), 360.0),
		"heading_alignment_error_degrees": absf(rad_to_deg(wrapf(target_yaw - camera_yaw, -PI, PI))),
	}


func set_ship_selection_highlight(selected: bool) -> void:
	player_visual.modulate = Color.WHITE
	_ensure_ship_selection_indicator()
	if _selection_indicator != null:
		_selection_indicator.visible = selected


func get_procedural_usv_component_summary() -> Dictionary:
	return procedural_usv_visual.call("get_component_summary") as Dictionary if procedural_usv_visual != null else {}


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
	ship_impact_shake_time_left = 0.0
	ship_impact_shake_strength = 0.0
	ship_collision_warning_text = "CLEAR"
	ship_last_impact_speed = 0.0
	if _catamaran_dynamics_ready:
		_catamaran_dynamics.reset(ship_heading_yaw)
		_catamaran_dynamics_status = _catamaran_dynamics.get_status(_get_ship_environment_forcing())


func prepare_ship_fleet_spawn(world_position: Vector3, heading_degrees: float) -> void:
	_reset_ship_clone_mounts()
	global_position = world_position
	rotation = Vector3.ZERO
	ship_heading_yaw = deg_to_rad(heading_degrees)
	ship_course_yaw = ship_heading_yaw
	ship_target_heading_yaw = ship_heading_yaw
	reset_ship_motion_state()
	last_direction = _get_ship_visual_direction()
	visual_direction = last_direction
	_update_idle_animation(visual_direction, 0.0)
	_update_visual_camera_facing()


func set_ship_navigation_spawn(world_position: Vector3, heading_degrees: float) -> void:
	global_position = world_position
	ship_heading_yaw = deg_to_rad(heading_degrees)
	ship_course_yaw = ship_heading_yaw
	ship_target_heading_yaw = ship_heading_yaw
	reset_ship_motion_state()
	last_direction = _get_ship_visual_direction()
	visual_direction = last_direction
	_update_idle_animation(visual_direction, 0.0)
	_apply_camera_orbit(0.0, true)


func apply_recorded_ship_state(
	world_position: Vector3,
	heading_degrees: float,
	speed_mps: float,
	actual_throttle: float,
	actual_rudder: float
) -> void:
	# Test-only visualization API. The numeric RL environment already integrated
	# these states headlessly; Godot interpolates the immutable held-out rollout.
	global_position = world_position
	ship_heading_yaw = deg_to_rad(heading_degrees)
	ship_course_yaw = ship_heading_yaw
	ship_target_heading_yaw = ship_heading_yaw
	ship_forward_speed = speed_mps
	ship_throttle = clampf(actual_throttle, -1.0, 1.0)
	ship_target_throttle = ship_throttle
	ship_rudder = clampf(actual_rudder, -1.0, 1.0)
	ship_target_rudder = ship_rudder
	if _catamaran_dynamics_ready:
		_catamaran_dynamics.set_recorded_state(ship_heading_yaw, speed_mps)
		_catamaran_dynamics_status = _catamaran_dynamics.get_status()
	var forward := _get_ship_forward_vector()
	velocity = forward * speed_mps
	last_direction = forward
	visual_direction = _get_ship_visual_direction()
	_apply_continuous_ship_heading(visual_direction)


func _reset_ship_clone_mounts() -> void:
	player_camera.top_level = false
	player_camera.current = false
	player_camera.position = SHIP_CAMERA_DEFAULT_POSITION
	player_camera.rotation_degrees = SHIP_CAMERA_DEFAULT_ROTATION_DEGREES
	player_camera.fov = 65.3
	camera_distance = maxf(SHIP_CAMERA_DEFAULT_POSITION.length(), 0.001)
	camera_base_fov = player_camera.fov
	camera_yaw = atan2(SHIP_CAMERA_DEFAULT_POSITION.x, SHIP_CAMERA_DEFAULT_POSITION.z)
	var horizontal_distance := Vector2(SHIP_CAMERA_DEFAULT_POSITION.x, SHIP_CAMERA_DEFAULT_POSITION.z).length()
	camera_pitch = atan2(SHIP_CAMERA_DEFAULT_POSITION.y, horizontal_distance)
	camera_follow_position = global_position + SHIP_CAMERA_DEFAULT_POSITION
	camera_focus_position = global_position + Vector3.UP * camera_focus_height
	camera_turn_sway = 0.0

	player_visual.top_level = false
	_configure_ship_visual_rendering()
	_ensure_ship_selection_indicator()
	if _selection_indicator != null:
		_selection_indicator.visible = false
	player_visual.position = SHIP_VISUAL_DEFAULT_POSITION
	player_visual.rotation = Vector3.ZERO
	player_visual.scale = SHIP_VISUAL_DEFAULT_SCALE
	player_visual_base_position = SHIP_VISUAL_DEFAULT_POSITION
	normal_visual_scale = SHIP_VISUAL_DEFAULT_SCALE
	player_visual.flip_h = false
	player_visual.play(&"idle_up")
	player_visual.frame = 0
	player_visual.visible = false
	if procedural_usv_visual != null:
		procedural_usv_visual.top_level = false
		procedural_usv_visual.call("set_active", true)
		procedural_usv_visual.rotation = Vector3(0.0, ship_heading_yaw, 0.0)
		procedural_usv_visual.call("set_navigation_state", ship_throttle, ship_rudder, ship_forward_speed)


func _config_float(config: Dictionary, key: String, fallback: float, min_value: float, max_value: float) -> float:
	if not config.has(key):
		return fallback
	return clampf(float(config[key]), min_value, max_value)


func _is_lower_diagonal_combo_attack_key(attack_key: String) -> bool:
	return attack_key == "southeast_attack_1" \
	or attack_key == "southwest_attack_1" \
	or attack_key == "southeast_attack_2" \
	or attack_key == "southwest_attack_2"


func _is_lower_diagonal_first_attack_key(attack_key: String) -> bool:
	return attack_key == "southeast_attack_1" or attack_key == "southwest_attack_1"


func _is_lower_diagonal_second_attack_key(attack_key: String) -> bool:
	return attack_key == "southeast_attack_2" or attack_key == "southwest_attack_2"


func _is_upper_diagonal_combo_attack_key(attack_key: String) -> bool:
	return attack_key == "northeast_attack_1" \
	or attack_key == "northwest_attack_1" \
	or attack_key == "northeast_attack_2" \
	or attack_key == "northwest_attack_2"


func _is_upper_diagonal_first_attack_key(attack_key: String) -> bool:
	return attack_key == "northeast_attack_1" or attack_key == "northwest_attack_1"


func _is_upper_diagonal_second_attack_key(attack_key: String) -> bool:
	return attack_key == "northeast_attack_2" or attack_key == "northwest_attack_2"


func _is_right_combo_attack_key(attack_key: String) -> bool:
	return attack_key == "right_attack_1" \
	or attack_key == "left_attack_1" \
	or attack_key == "right_attack_2" \
	or attack_key == "left_attack_2"


func _is_right_first_attack_key(attack_key: String) -> bool:
	return attack_key == "right_attack_1" or attack_key == "left_attack_1"


func _is_right_second_attack_key(attack_key: String) -> bool:
	return attack_key == "right_attack_2" or attack_key == "left_attack_2"


func _is_down_combo_attack_key(attack_key: String) -> bool:
	return attack_key == "down_attack_1" or attack_key == "down_attack_2"


func _is_up_combo_attack_key(attack_key: String) -> bool:
	return attack_key == "up_attack_1" or attack_key == "up_attack_2"


func _reset_combo_state() -> void:
	next_attack_queued = false
	combo_time_left = 0.0
	last_finished_attack_key = ""


func _clear_current_attack_state() -> void:
	current_attack_animation = &""
	current_attack_key = ""


func _handle_attack_input() -> void:
	if is_playing_attack:
		if _is_lower_diagonal_combo_attack_key(current_attack_key) \
		or _is_upper_diagonal_combo_attack_key(current_attack_key) \
		or _is_down_combo_attack_key(current_attack_key) \
		or _is_up_combo_attack_key(current_attack_key) \
		or _is_right_combo_attack_key(current_attack_key):

			next_attack_queued = true

			if current_attack_key == "southwest_attack_1" or current_attack_key == "southwest_attack_2":
				lower_diagonal_attack_flip_h = true
			elif current_attack_key == "southeast_attack_1" or current_attack_key == "southeast_attack_2":
				lower_diagonal_attack_flip_h = false
			elif current_attack_key == "northwest_attack_1" or current_attack_key == "northwest_attack_2":
				upper_diagonal_attack_flip_h = true
			elif current_attack_key == "northeast_attack_1" or current_attack_key == "northeast_attack_2":
				upper_diagonal_attack_flip_h = false
			elif current_attack_key == "left_attack_1" or current_attack_key == "left_attack_2":
				right_attack_flip_h = true
			elif current_attack_key == "right_attack_1" or current_attack_key == "right_attack_2":
				right_attack_flip_h = false

		return

	if _is_lower_diagonal_first_attack_key(last_finished_attack_key) and combo_time_left > 0.0:
		lower_diagonal_attack_flip_h = last_finished_attack_key == "southwest_attack_1"
		_start_southeast_second_attack()
		return

	if _is_lower_diagonal_second_attack_key(last_finished_attack_key) and combo_time_left > 0.0:
		lower_diagonal_attack_flip_h = last_finished_attack_key == "southwest_attack_2"
		_start_southeast_third_attack()
		return

	if _is_upper_diagonal_first_attack_key(last_finished_attack_key) and combo_time_left > 0.0:
		upper_diagonal_attack_flip_h = last_finished_attack_key == "northwest_attack_1"
		_start_northeast_second_attack()
		return

	if _is_upper_diagonal_second_attack_key(last_finished_attack_key) and combo_time_left > 0.0:
		upper_diagonal_attack_flip_h = last_finished_attack_key == "northwest_attack_2"
		_start_northeast_third_attack()
		return

	if last_finished_attack_key == "down_attack_1" and combo_time_left > 0.0:
		_start_down_second_attack()
		return

	if last_finished_attack_key == "down_attack_2" and combo_time_left > 0.0:
		_start_down_third_attack()
		return

	if last_finished_attack_key == "up_attack_1" and combo_time_left > 0.0:
		_start_up_second_attack()
		return

	if last_finished_attack_key == "up_attack_2" and combo_time_left > 0.0:
		_start_up_third_attack()
		return

	if _is_right_first_attack_key(last_finished_attack_key) and combo_time_left > 0.0:
		right_attack_flip_h = last_finished_attack_key == "left_attack_1"
		_start_right_second_attack()
		return

	if _is_right_second_attack_key(last_finished_attack_key) and combo_time_left > 0.0:
		right_attack_flip_h = last_finished_attack_key == "left_attack_2"
		_start_right_third_attack()
		return

	_try_start_attack()


func _prepare_attack_start() -> void:
	_set_normal_visual_scale()

	is_playing_idle_action = false
	lightness_time_left = 0.0
	idle_action_wait_left = idle_action_delay
	current_idle_action_key = ""

	_reset_combo_state()


func _start_southeast_second_attack() -> void:
	var sprite_frames: SpriteFrames = player_visual.sprite_frames

	if sprite_frames == null or not sprite_frames.has_animation(southeast_attack2_animation):
		is_playing_attack = false
		_reset_combo_state()
		_clear_current_attack_state()
		_set_normal_visual_scale()
		return

	_prepare_attack_start()

	player_visual.flip_h = lower_diagonal_attack_flip_h
	_set_diagonal_attack_visual_scale()
	player_visual.play(southeast_attack2_animation)
	player_visual.frame = 0

	current_attack_animation = southeast_attack2_animation
	current_attack_key = "southwest_attack_2" if lower_diagonal_attack_flip_h else "southeast_attack_2"
	is_playing_attack = true


func _start_southeast_third_attack() -> void:
	var sprite_frames: SpriteFrames = player_visual.sprite_frames

	if sprite_frames == null or not sprite_frames.has_animation(southeast_attack3_animation):
		is_playing_attack = false
		_reset_combo_state()
		_clear_current_attack_state()
		_set_normal_visual_scale()
		return

	_prepare_attack_start()

	player_visual.flip_h = lower_diagonal_attack_flip_h
	_set_diagonal_attack_visual_scale()
	player_visual.play(southeast_attack3_animation)
	player_visual.frame = 0

	current_attack_animation = southeast_attack3_animation
	current_attack_key = "southwest_attack_3" if lower_diagonal_attack_flip_h else "southeast_attack_3"
	is_playing_attack = true


func _start_northeast_second_attack() -> void:
	var sprite_frames: SpriteFrames = player_visual.sprite_frames

	if sprite_frames == null or not sprite_frames.has_animation(northeast_attack2_animation):
		is_playing_attack = false
		_reset_combo_state()
		_clear_current_attack_state()
		_set_normal_visual_scale()
		return

	_prepare_attack_start()

	player_visual.flip_h = upper_diagonal_attack_flip_h
	_set_northeast_attack_visual_scale()
	player_visual.play(northeast_attack2_animation)
	player_visual.frame = 0

	current_attack_animation = northeast_attack2_animation
	current_attack_key = "northwest_attack_2" if upper_diagonal_attack_flip_h else "northeast_attack_2"
	is_playing_attack = true


func _start_northeast_third_attack() -> void:
	var sprite_frames: SpriteFrames = player_visual.sprite_frames

	if sprite_frames == null or not sprite_frames.has_animation(northeast_attack3_animation):
		is_playing_attack = false
		_reset_combo_state()
		_clear_current_attack_state()
		_set_normal_visual_scale()
		return

	_prepare_attack_start()

	player_visual.flip_h = upper_diagonal_attack_flip_h
	_set_northeast_attack_visual_scale()
	player_visual.play(northeast_attack3_animation)
	player_visual.frame = 0

	current_attack_animation = northeast_attack3_animation
	current_attack_key = "northwest_attack_3" if upper_diagonal_attack_flip_h else "northeast_attack_3"
	is_playing_attack = true


func _start_down_second_attack() -> void:
	var sprite_frames: SpriteFrames = player_visual.sprite_frames

	if sprite_frames == null or not sprite_frames.has_animation(down_attack2_animation):
		is_playing_attack = false
		_reset_combo_state()
		_clear_current_attack_state()
		_set_normal_visual_scale()
		return

	_prepare_attack_start()

	player_visual.flip_h = false
	_set_down_attack_visual_scale()
	player_visual.play(down_attack2_animation)
	player_visual.frame = 0

	current_attack_animation = down_attack2_animation
	current_attack_key = "down_attack_2"
	is_playing_attack = true


func _start_down_third_attack() -> void:
	var sprite_frames: SpriteFrames = player_visual.sprite_frames

	if sprite_frames == null or not sprite_frames.has_animation(down_attack3_animation):
		is_playing_attack = false
		_reset_combo_state()
		_clear_current_attack_state()
		_set_normal_visual_scale()
		return

	_prepare_attack_start()

	player_visual.flip_h = false
	_set_down_attack_visual_scale()
	player_visual.play(down_attack3_animation)
	player_visual.frame = 0

	current_attack_animation = down_attack3_animation
	current_attack_key = "down_attack_3"
	is_playing_attack = true


func _start_up_second_attack() -> void:
	var sprite_frames: SpriteFrames = player_visual.sprite_frames

	if sprite_frames == null or not sprite_frames.has_animation(up_attack2_animation):
		is_playing_attack = false
		_reset_combo_state()
		_clear_current_attack_state()
		_set_normal_visual_scale()
		return

	_prepare_attack_start()

	player_visual.flip_h = false
	_set_up_attack_visual_scale()
	player_visual.play(up_attack2_animation)
	player_visual.frame = 0

	current_attack_animation = up_attack2_animation
	current_attack_key = "up_attack_2"
	is_playing_attack = true


func _start_up_third_attack() -> void:
	var sprite_frames: SpriteFrames = player_visual.sprite_frames

	if sprite_frames == null or not sprite_frames.has_animation(up_attack3_animation):
		is_playing_attack = false
		_reset_combo_state()
		_clear_current_attack_state()
		_set_normal_visual_scale()
		return

	_prepare_attack_start()

	player_visual.flip_h = false
	_set_up_attack_visual_scale()
	player_visual.play(up_attack3_animation)
	player_visual.frame = 0

	current_attack_animation = up_attack3_animation
	current_attack_key = "up_attack_3"
	is_playing_attack = true


func _start_right_second_attack() -> void:
	var sprite_frames: SpriteFrames = player_visual.sprite_frames

	if sprite_frames == null or not sprite_frames.has_animation(right_attack2_animation):
		is_playing_attack = false
		_reset_combo_state()
		_clear_current_attack_state()
		_set_normal_visual_scale()
		return

	_prepare_attack_start()

	player_visual.flip_h = right_attack_flip_h
	_set_right_attack_visual_scale()
	player_visual.play(right_attack2_animation)
	player_visual.frame = 0

	current_attack_animation = right_attack2_animation
	current_attack_key = "left_attack_2" if right_attack_flip_h else "right_attack_2"
	is_playing_attack = true


func _start_right_third_attack() -> void:
	var sprite_frames: SpriteFrames = player_visual.sprite_frames

	if sprite_frames == null or not sprite_frames.has_animation(right_attack3_animation):
		is_playing_attack = false
		_reset_combo_state()
		_clear_current_attack_state()
		_set_normal_visual_scale()
		return

	_prepare_attack_start()

	player_visual.flip_h = right_attack_flip_h
	_set_right_attack_visual_scale()
	player_visual.play(right_attack3_animation)
	player_visual.frame = 0

	current_attack_animation = right_attack3_animation
	current_attack_key = "left_attack_3" if right_attack_flip_h else "right_attack_3"
	is_playing_attack = true


func _try_start_attack() -> void:
	var x: float = visual_direction.x
	var z: float = visual_direction.z

	var abs_x: float = absf(x)
	var abs_z: float = absf(z)

	var horizontal_ratio: float = abs_z / maxf(abs_x, 0.001)
	var vertical_ratio: float = abs_x / maxf(abs_z, 0.001)

	_prepare_attack_start()

	if abs_x >= abs_z and horizontal_ratio < 0.35:
		var is_left: bool = x < 0.0

		player_visual.flip_h = is_left
		right_attack_flip_h = is_left

		_set_right_attack_visual_scale()
		player_visual.play(right_attack_animation)
		player_visual.frame = 0

		current_attack_animation = right_attack_animation
		current_attack_key = "left_attack_1" if is_left else "right_attack_1"
		is_playing_attack = true
		return

	if z < 0.0 and abs_z > abs_x and vertical_ratio < 0.35:
		player_visual.flip_h = false
		_set_up_attack_visual_scale()
		player_visual.play(up_attack_animation)
		player_visual.frame = 0

		current_attack_animation = up_attack_animation
		current_attack_key = "up_attack_1"
		is_playing_attack = true
		return

	if z > 0.0 and abs_z > abs_x and vertical_ratio < 0.35:
		player_visual.flip_h = false
		_set_down_attack_visual_scale()
		player_visual.play(down_attack_animation)
		player_visual.frame = 0

		current_attack_animation = down_attack_animation
		current_attack_key = "down_attack_1"
		is_playing_attack = true
		return

	if z > 0.0:
		var is_lower_diagonal: bool = false

		if abs_x >= abs_z:
			is_lower_diagonal = horizontal_ratio >= 0.35
		else:
			is_lower_diagonal = vertical_ratio >= 0.35

		if is_lower_diagonal:
			var is_left_lower_diagonal: bool = x < 0.0

			player_visual.flip_h = is_left_lower_diagonal
			lower_diagonal_attack_flip_h = is_left_lower_diagonal

			_set_diagonal_attack_visual_scale()
			player_visual.play(southeast_attack_animation)
			player_visual.frame = 0

			current_attack_animation = southeast_attack_animation
			current_attack_key = "southwest_attack_1" if is_left_lower_diagonal else "southeast_attack_1"
			is_playing_attack = true
			return

	if z < 0.0:
		var is_upper_diagonal: bool = false

		if abs_x >= abs_z:
			is_upper_diagonal = horizontal_ratio >= 0.35
		else:
			is_upper_diagonal = vertical_ratio >= 0.35

		if is_upper_diagonal:
			var is_left_upper_diagonal: bool = x < 0.0

			player_visual.flip_h = is_left_upper_diagonal
			upper_diagonal_attack_flip_h = is_left_upper_diagonal

			_set_northeast_attack_visual_scale()
			player_visual.play(northeast_attack_animation)
			player_visual.frame = 0

			current_attack_animation = northeast_attack_animation
			current_attack_key = "northwest_attack_1" if is_left_upper_diagonal else "northeast_attack_1"
			is_playing_attack = true
			return


func _reset_idle_action_state() -> void:
	idle_action_wait_left = idle_action_delay
	is_playing_idle_action = false
	current_idle_action_key = ""


func _finish_attack_without_combo() -> void:
	_set_normal_visual_scale()
	is_playing_attack = false
	_reset_combo_state()
	_clear_current_attack_state()
	_reset_idle_action_state()


func _on_player_visual_animation_finished() -> void:
	var finished_animation: StringName = player_visual.animation

	if finished_animation == &"run_north_northeast" and is_reversing_run_north_northeast:
		is_reversing_run_north_northeast = false
		last_run_animation = &"run_up"
		player_visual.flip_h = false
		player_visual.play(&"run_up")
		player_visual.frame = 0
		return

	if finished_animation == southeast_attack_animation:
		_set_normal_visual_scale()
		is_playing_attack = false

		if _is_lower_diagonal_first_attack_key(current_attack_key):
			if next_attack_queued:
				lower_diagonal_attack_flip_h = current_attack_key == "southwest_attack_1"
				_start_southeast_second_attack()
				return

			last_finished_attack_key = current_attack_key
			combo_time_left = combo_window
		else:
			_reset_combo_state()

		_clear_current_attack_state()
		_reset_idle_action_state()
		return

	if finished_animation == southeast_attack2_animation:
		_set_normal_visual_scale()
		is_playing_attack = false

		if _is_lower_diagonal_second_attack_key(current_attack_key):
			if next_attack_queued:
				lower_diagonal_attack_flip_h = current_attack_key == "southwest_attack_2"
				_start_southeast_third_attack()
				return

			last_finished_attack_key = current_attack_key
			combo_time_left = combo_window
		else:
			_reset_combo_state()

		_clear_current_attack_state()
		_reset_idle_action_state()
		return

	if finished_animation == northeast_attack_animation:
		_set_normal_visual_scale()
		is_playing_attack = false

		if _is_upper_diagonal_first_attack_key(current_attack_key):
			if next_attack_queued:
				upper_diagonal_attack_flip_h = current_attack_key == "northwest_attack_1"
				_start_northeast_second_attack()
				return

			last_finished_attack_key = current_attack_key
			combo_time_left = combo_window
		else:
			_reset_combo_state()

		_clear_current_attack_state()
		_reset_idle_action_state()
		return

	if finished_animation == northeast_attack2_animation:
		_set_normal_visual_scale()
		is_playing_attack = false

		if _is_upper_diagonal_second_attack_key(current_attack_key):
			if next_attack_queued:
				upper_diagonal_attack_flip_h = current_attack_key == "northwest_attack_2"
				_start_northeast_third_attack()
				return

			last_finished_attack_key = current_attack_key
			combo_time_left = combo_window
		else:
			_reset_combo_state()

		_clear_current_attack_state()
		_reset_idle_action_state()
		return

	if finished_animation == right_attack_animation:
		_set_normal_visual_scale()
		is_playing_attack = false

		if _is_right_first_attack_key(current_attack_key):
			if next_attack_queued:
				right_attack_flip_h = current_attack_key == "left_attack_1"
				_start_right_second_attack()
				return

			last_finished_attack_key = current_attack_key
			combo_time_left = combo_window
		else:
			_reset_combo_state()

		_clear_current_attack_state()
		_reset_idle_action_state()
		return

	if finished_animation == right_attack2_animation:
		_set_normal_visual_scale()
		is_playing_attack = false

		if _is_right_second_attack_key(current_attack_key):
			if next_attack_queued:
				right_attack_flip_h = current_attack_key == "left_attack_2"
				_start_right_third_attack()
				return

			last_finished_attack_key = current_attack_key
			combo_time_left = combo_window
		else:
			_reset_combo_state()

		_clear_current_attack_state()
		_reset_idle_action_state()
		return

	if finished_animation == up_attack_animation:
		_set_normal_visual_scale()
		is_playing_attack = false

		if current_attack_key == "up_attack_1":
			if next_attack_queued:
				_start_up_second_attack()
				return

			last_finished_attack_key = "up_attack_1"
			combo_time_left = combo_window
		else:
			_reset_combo_state()

		_clear_current_attack_state()
		_reset_idle_action_state()
		return

	if finished_animation == up_attack2_animation:
		_set_normal_visual_scale()
		is_playing_attack = false

		if current_attack_key == "up_attack_2":
			if next_attack_queued:
				_start_up_third_attack()
				return

			last_finished_attack_key = "up_attack_2"
			combo_time_left = combo_window
		else:
			_reset_combo_state()

		_clear_current_attack_state()
		_reset_idle_action_state()
		return

	if finished_animation == down_attack_animation:
		_set_normal_visual_scale()
		is_playing_attack = false

		if current_attack_key == "down_attack_1":
			if next_attack_queued:
				_start_down_second_attack()
				return

			last_finished_attack_key = "down_attack_1"
			combo_time_left = combo_window
		else:
			_reset_combo_state()

		_clear_current_attack_state()
		_reset_idle_action_state()
		return

	if finished_animation == down_attack2_animation:
		_set_normal_visual_scale()
		is_playing_attack = false

		if current_attack_key == "down_attack_2":
			if next_attack_queued:
				_start_down_third_attack()
				return

			last_finished_attack_key = "down_attack_2"
			combo_time_left = combo_window
		else:
			_reset_combo_state()

		_clear_current_attack_state()
		_reset_idle_action_state()
		return

	if finished_animation == southeast_attack3_animation \
	or finished_animation == northeast_attack3_animation \
	or finished_animation == down_attack3_animation \
	or finished_animation == up_attack3_animation \
	or finished_animation == right_attack3_animation:

		_finish_attack_without_combo()
		return

	if finished_animation == southeast_idle_action_animation \
	or finished_animation == northeast_idle_action_animation \
	or finished_animation == right_idle_action_animation \
	or finished_animation == down_idle_action_animation:

		is_playing_idle_action = false
		idle_action_wait_left = idle_action_interval


func _play_air_animation(
	animation_name: StringName,
	should_flip: bool,
	restart_when_stopped: bool = false,
	scale_multiplier: float = 1.0
) -> bool:
	var sprite_frames: SpriteFrames = player_visual.sprite_frames

	if sprite_frames == null or not sprite_frames.has_animation(animation_name):
		return false

	_set_air_visual_scale(scale_multiplier)
	player_visual.flip_h = should_flip

	if player_visual.animation != animation_name:
		player_visual.play(animation_name)
		player_visual.frame = 0
	elif restart_when_stopped and not player_visual.is_playing():
		player_visual.play()

	return true


func _update_air_animation(facing_direction: Vector3) -> void:
	if jumps_used >= 2:
		if _update_double_jump_animation(facing_direction):
			return

	if _update_first_jump_animation(facing_direction):
		return

	_update_idle_animation(facing_direction, 0.0)


func _update_first_jump_animation(facing_direction: Vector3) -> bool:
	var x: float = facing_direction.x
	var z: float = facing_direction.z

	var abs_x: float = absf(x)
	var abs_z: float = absf(z)

	var horizontal_ratio: float = abs_z / maxf(abs_x, 0.001)
	var vertical_ratio: float = abs_x / maxf(abs_z, 0.001)

	if abs_x >= abs_z:
		if horizontal_ratio < 0.35:
			return _play_air_animation(right_jump_animation, x < 0.0)

		if z < 0.0:
			return _play_air_animation(northeast_jump_animation, x < 0.0, false, northeast_jump_scale)

		return _play_air_animation(southeast_jump_animation, x < 0.0)

	if z < 0.0:
		if vertical_ratio >= 0.35:
			return _play_air_animation(northeast_jump_animation, x < 0.0, false, northeast_jump_scale)

		return false

	if vertical_ratio < 0.35:
		return _play_air_animation(down_jump_animation, false, false, down_jump_scale)

	return _play_air_animation(southeast_jump_animation, x < 0.0)


func _update_double_jump_animation(facing_direction: Vector3) -> bool:
	var x: float = facing_direction.x
	var z: float = facing_direction.z

	var abs_x: float = absf(x)
	var abs_z: float = absf(z)

	var horizontal_ratio: float = abs_z / maxf(abs_x, 0.001)
	var vertical_ratio: float = abs_x / maxf(abs_z, 0.001)

	if abs_x >= abs_z:
		if horizontal_ratio < 0.35:
			return _play_air_animation(double_jump_right_animation, x < 0.0, false, right_double_jump_scale)

		if z < 0.0:
			return _play_air_animation(double_jump_northeast_animation, x < 0.0, false, northeast_double_jump_scale)

		return _play_air_animation(double_jump_southwest_animation, x >= 0.0, false, southeast_double_jump_scale)

	if z < 0.0:
		if vertical_ratio < 0.35:
			return _play_air_animation(double_jump_up_animation, false)

		return _play_air_animation(double_jump_northeast_animation, x < 0.0, false, northeast_double_jump_scale)

	if vertical_ratio < 0.35:
		return _play_air_animation(double_jump_down_animation, false, false, down_double_jump_scale)

	return _play_air_animation(double_jump_southwest_animation, x >= 0.0, false, southeast_double_jump_scale)


func _update_lightness_animation(facing_direction: Vector3) -> bool:
	var x: float = facing_direction.x
	var z: float = facing_direction.z

	var abs_x: float = absf(x)
	var abs_z: float = absf(z)

	var horizontal_ratio: float = abs_z / maxf(abs_x, 0.001)
	var vertical_ratio: float = abs_x / maxf(abs_z, 0.001)

	if abs_x >= abs_z:
		if horizontal_ratio < 0.35:
			return _play_air_animation(lightness_right_animation, x < 0.0, true, right_lightness_scale)

		if z < 0.0:
			return _play_air_animation(lightness_northeast_animation, x < 0.0, true)

		return _play_air_animation(lightness_southeast_animation, x < 0.0, true, southeast_lightness_scale)

	if z < 0.0:
		if vertical_ratio < 0.35:
			return _play_air_animation(lightness_up_animation, false, true, up_lightness_scale)

		return _play_air_animation(lightness_northeast_animation, x < 0.0, true)

	if vertical_ratio < 0.35:
		return _play_air_animation(lightness_down_animation, false, true, down_lightness_scale)

	return _play_air_animation(lightness_southeast_animation, x < 0.0, true, southeast_lightness_scale)


func _update_idle_animation(facing_direction: Vector3, delta: float) -> void:
	if use_continuous_ship_turn_visual:
		is_playing_idle_action = false
		current_idle_action_key = ""
		idle_action_wait_left = idle_action_delay
		_apply_continuous_ship_heading(facing_direction)
		_play_continuous_ship_animation(&"idle_up")
		return

	if is_playing_idle_action:
		return

	var target_animation: StringName = &"idle_right"
	var should_flip: bool = false

	var action_animation: StringName = &""
	var action_flip: bool = false
	var action_key: String = ""
	var can_trigger_idle_action: bool = false

	var x: float = facing_direction.x
	var z: float = facing_direction.z

	var abs_x: float = absf(x)
	var abs_z: float = absf(z)

	var horizontal_ratio: float = abs_z / maxf(abs_x, 0.001)
	var vertical_ratio: float = abs_x / maxf(abs_z, 0.001)

	if abs_x >= abs_z:
		if horizontal_ratio < 0.35:
			target_animation = &"idle_right"
			should_flip = x < 0.0

			can_trigger_idle_action = true
			action_animation = right_idle_action_animation
			action_key = "right" if x >= 0.0 else "left"
			action_flip = x < 0.0

		elif z < 0.0:
			target_animation = &"idle_northeast"
			should_flip = x < 0.0

			can_trigger_idle_action = true
			action_animation = northeast_idle_action_animation
			action_key = "northeast" if x >= 0.0 else "northwest"
			action_flip = x > 0.0

		else:
			target_animation = &"idle_southeast"
			should_flip = x > 0.0

			can_trigger_idle_action = true
			action_animation = southeast_idle_action_animation
			action_key = "southeast" if x >= 0.0 else "southwest"
			action_flip = x < 0.0

	else:
		if z < 0.0:
			if vertical_ratio < 0.35:
				target_animation = &"idle_up"
				should_flip = false

			else:
				target_animation = &"idle_northeast"
				should_flip = x < 0.0

				can_trigger_idle_action = true
				action_animation = northeast_idle_action_animation
				action_key = "northeast" if x >= 0.0 else "northwest"
				action_flip = x > 0.0

		else:
			if vertical_ratio < 0.35:
				target_animation = &"idle_down"
				should_flip = false

				can_trigger_idle_action = true
				action_animation = down_idle_action_animation
				action_key = "down"
				action_flip = false

			else:
				target_animation = &"idle_southeast"
				should_flip = x > 0.0

				can_trigger_idle_action = true
				action_animation = southeast_idle_action_animation
				action_key = "southeast" if x >= 0.0 else "southwest"
				action_flip = x < 0.0

	if not can_trigger_idle_action:
		current_idle_action_key = ""
		idle_action_wait_left = idle_action_delay
	else:
		if action_key != current_idle_action_key:
			current_idle_action_key = action_key
			idle_action_wait_left = idle_action_delay
		else:
			idle_action_wait_left = maxf(idle_action_wait_left - delta, 0.0)

		if idle_action_wait_left <= 0.0:
			player_visual.flip_h = action_flip
			player_visual.play(action_animation)
			player_visual.frame = 0

			is_playing_idle_action = true
			return

	player_visual.flip_h = should_flip

	if player_visual.animation != target_animation:
		player_visual.play(target_animation)
		player_visual.frame = 0
	elif not player_visual.is_playing():
		player_visual.play()


func _update_run_animation(facing_direction: Vector3) -> void:
	if use_continuous_ship_turn_visual:
		is_reversing_run_north_northeast = false
		_apply_continuous_ship_heading(facing_direction)
		_play_continuous_ship_animation(&"run_up")
		return

	var target_animation: StringName = &"run_right"
	var should_flip: bool = false

	var x: float = facing_direction.x
	var z: float = facing_direction.z

	var abs_x: float = absf(x)
	var abs_z: float = absf(z)

	var horizontal_ratio: float = abs_z / maxf(abs_x, 0.001)
	var vertical_ratio: float = abs_x / maxf(abs_z, 0.001)

	if abs_x >= abs_z:
		if horizontal_ratio < 0.35:
			target_animation = &"run_right"
			should_flip = x < 0.0

		elif z < 0.0:
			if horizontal_ratio < 0.80:
				target_animation = &"run_east_northeast"
				should_flip = x < 0.0
			else:
				target_animation = &"run_northeast"
				should_flip = x < 0.0

		else:
			if horizontal_ratio < 0.80:
				target_animation = &"run_east_southeast"
				should_flip = x < 0.0
			else:
				target_animation = &"run_southeast"
				should_flip = x < 0.0

	else:
		if z < 0.0:
			if vertical_ratio < 0.35:
				target_animation = &"run_up"
				should_flip = false

			elif vertical_ratio < 0.80:
				target_animation = &"run_north_northeast"
				should_flip = x < 0.0
			else:
				target_animation = &"run_northeast"
				should_flip = x < 0.0

		else:
			if vertical_ratio < 0.35:
				target_animation = &"run_down"
				should_flip = false

			elif vertical_ratio < 0.80:
				target_animation = &"run_south_southeast"
				should_flip = x < 0.0
			else:
				target_animation = &"run_southeast"
				should_flip = x < 0.0

	if is_reversing_run_north_northeast:
		if target_animation == &"run_up" or target_animation == &"run_north_northeast":
			# Keep the side that started the reverse turn until every transition frame
			# has finished. run_up itself is not mirrored, so applying its false flip
			# early made northwest -> north visibly jump while northeast stayed smooth.
			player_visual.flip_h = reversing_run_north_northeast_flip_h

			if player_visual.animation != &"run_north_northeast":
				player_visual.play(&"run_north_northeast", -1.0, true)

			if not player_visual.is_playing() and player_visual.frame <= 0:
				is_reversing_run_north_northeast = false
				last_run_animation = &"run_up"
				player_visual.flip_h = false
				player_visual.play(&"run_up")
				player_visual.frame = 0

			return

		is_reversing_run_north_northeast = false

	if (
		last_run_animation == &"run_northeast"
		and (target_animation == &"run_north_northeast" or target_animation == &"run_up")
	):
		is_reversing_run_north_northeast = true
		reversing_run_north_northeast_flip_h = player_visual.flip_h
		last_run_animation = target_animation
		player_visual.flip_h = reversing_run_north_northeast_flip_h
		player_visual.play(&"run_north_northeast", -1.0, true)
		return

	player_visual.flip_h = should_flip

	if player_visual.animation != target_animation:
		player_visual.play(target_animation)
		player_visual.frame = 0
	elif not player_visual.is_playing() and target_animation != &"run_north_northeast":
		player_visual.play()

	last_run_animation = target_animation

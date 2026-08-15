extends Node3D
class_name ProceduralUSVVisual

const REFERENCE_FORWARD_SPEED_MPS := 8.5
const PROPELLER_MIN_MOVING_RATE := 24.0
const PROPELLER_MAX_RATE := 84.0
const PROPELLER_TURN_DIFFERENTIAL := 0.52
const PROPELLER_RATE_RESPONSE := 10.0

var _motion_root: Node3D
var _radar_scanner: Node3D
var _sensor_gimbal: Node3D
var _left_propeller: Node3D
var _right_propeller: Node3D
var _beacon_material: StandardMaterial3D
var _throttle := 0.0
var _rudder := 0.0
var _speed_mps := 0.0
var _animation_time := 0.0
var _propeller_drive_ratio := 0.0
var _propeller_drive_direction := 1.0
var _propeller_turn_direction := 0.0
var _base_propeller_target_rate := 0.0
var _left_propeller_target_rate := 0.0
var _right_propeller_target_rate := 0.0
var _left_propeller_rate := 0.0
var _right_propeller_rate := 0.0


func _ready() -> void:
	if get_child_count() == 0:
		_build_unmanned_surface_vessel()
	set_active(visible)


func set_active(active: bool) -> void:
	visible = active
	set_process(active)


func set_navigation_state(throttle: float, rudder: float, speed_mps: float) -> void:
	_throttle = clampf(throttle, -1.0, 1.0)
	_rudder = clampf(rudder, -1.0, 1.0)
	_speed_mps = speed_mps
	_refresh_propeller_targets()


func get_propulsion_animation_status() -> Dictionary:
	return {
		"sync_mode": "actual_speed_throttle_rudder_differential",
		"throttle": _throttle,
		"rudder": _rudder,
		"speed_mps": _speed_mps,
		"drive_ratio": _propeller_drive_ratio,
		"drive_direction": _propeller_drive_direction,
		"turn_direction": _propeller_turn_direction,
		"turn_side": _propeller_turn_side(),
		"base_target_rad_s": _base_propeller_target_rate,
		"port_target_rad_s": _left_propeller_target_rate,
		"starboard_target_rad_s": _right_propeller_target_rate,
		"port_current_rad_s": _left_propeller_rate,
		"starboard_current_rad_s": _right_propeller_rate,
		"port_target_rpm": absf(_left_propeller_target_rate) * 60.0 / TAU,
		"starboard_target_rpm": absf(_right_propeller_target_rate) * 60.0 / TAU,
	}


func get_component_summary() -> Dictionary:
	return {
		"visual_type": "procedural_unmanned_surface_vessel",
		"built_in_meshes_only": true,
		"components": [
			"双体浮筒", "中央甲板", "防撞船首", "低矮驾驶舱", "双太阳能板",
			"旋转雷达", "双光电摄像头", "GNSS天线", "红绿航行灯", "双推进器",
		],
		"propulsion_animation": "实际航速、油门、实际舵角差速同步",
	}


func _process(delta: float) -> void:
	_animation_time += delta
	if _radar_scanner != null:
		_radar_scanner.rotation.y = fposmod(_radar_scanner.rotation.y + delta * 2.8, TAU)
	if _sensor_gimbal != null:
		_sensor_gimbal.rotation.y = lerp_angle(_sensor_gimbal.rotation.y, -_rudder * 0.42, _damping_alpha(5.0, delta))
	_refresh_propeller_targets()
	var propeller_alpha := _damping_alpha(PROPELLER_RATE_RESPONSE, delta)
	_left_propeller_rate = lerpf(_left_propeller_rate, _left_propeller_target_rate, propeller_alpha)
	_right_propeller_rate = lerpf(_right_propeller_rate, _right_propeller_target_rate, propeller_alpha)
	if _left_propeller != null:
		_left_propeller.rotation.z = fposmod(_left_propeller.rotation.z + delta * _left_propeller_rate, TAU)
	if _right_propeller != null:
		_right_propeller.rotation.z = fposmod(_right_propeller.rotation.z + delta * _right_propeller_rate, TAU)
	if _motion_root != null:
		var moving_ratio := clampf(absf(_speed_mps) / 8.5, 0.0, 1.0)
		_motion_root.position.y = 0.58 + sin(_animation_time * 2.1) * lerpf(0.018, 0.055, moving_ratio)
		_motion_root.rotation.z = lerpf(_motion_root.rotation.z, -_rudder * 0.075 * moving_ratio, _damping_alpha(4.2, delta))
		_motion_root.rotation.x = sin(_animation_time * 1.35) * 0.012 * moving_ratio
	if _beacon_material != null:
		_beacon_material.emission_energy_multiplier = 2.4 + (sin(_animation_time * 5.2) * 0.5 + 0.5) * 2.8


func _refresh_propeller_targets() -> void:
	var speed_ratio := clampf(absf(_speed_mps) / REFERENCE_FORWARD_SPEED_MPS, 0.0, 1.0)
	var throttle_ratio := clampf(absf(_throttle), 0.0, 1.0)
	_propeller_drive_ratio = maxf(speed_ratio, throttle_ratio * 0.78)
	if _propeller_drive_ratio <= 0.01:
		_base_propeller_target_rate = 0.0
		_left_propeller_target_rate = 0.0
		_right_propeller_target_rate = 0.0
		_propeller_turn_direction = 0.0
		return

	# Use commanded thrust for spin direction while the screws are powered, then
	# fall back to water-driven rotation while the vessel is coasting.
	var signed_drive_reference := _throttle if absf(_throttle) >= 0.05 else _speed_mps
	_propeller_drive_direction = -1.0 if signed_drive_reference < 0.0 else 1.0
	var travel_direction := -1.0 if _speed_mps < -0.05 else 1.0
	_propeller_turn_direction = _rudder * travel_direction
	_base_propeller_target_rate = lerpf(
		PROPELLER_MIN_MOVING_RATE,
		PROPELLER_MAX_RATE,
		sqrt(_propeller_drive_ratio)
	)

	# Positive forward rudder turns to starboard: the port (outside) screw gains
	# speed and the starboard (inside) screw slows. Reverse motion swaps the sides.
	var differential := _propeller_turn_direction * PROPELLER_TURN_DIFFERENTIAL
	var port_multiplier := clampf(1.0 + differential, 0.28, 1.72)
	var starboard_multiplier := clampf(1.0 - differential, 0.28, 1.72)
	_left_propeller_target_rate = _base_propeller_target_rate * port_multiplier * _propeller_drive_direction
	_right_propeller_target_rate = -_base_propeller_target_rate * starboard_multiplier * _propeller_drive_direction


func _propeller_turn_side() -> String:
	if _propeller_turn_direction > 0.02:
		return "starboard"
	if _propeller_turn_direction < -0.02:
		return "port"
	return "straight"


func _build_unmanned_surface_vessel() -> void:
	_motion_root = Node3D.new()
	_motion_root.name = "USV_MotionRoot"
	_motion_root.position.y = 0.58
	add_child(_motion_root)

	var hull_material := _material(Color(0.025, 0.075, 0.105, 1.0), 0.78, 0.24)
	var hull_edge_material := _material(Color(0.06, 0.22, 0.27, 1.0), 0.70, 0.28)
	var deck_material := _material(Color(0.12, 0.17, 0.18, 1.0), 0.66, 0.42)
	var safety_material := _material(Color(1.0, 0.34, 0.055, 1.0), 0.48, 0.36, Color(1.0, 0.13, 0.02), 0.8)
	var metal_material := _material(Color(0.42, 0.53, 0.56, 1.0), 0.84, 0.23)
	var black_material := _material(Color(0.015, 0.025, 0.032, 1.0), 0.58, 0.24)
	var glass_material := _material(Color(0.045, 0.38, 0.48, 0.76), 0.42, 0.12, Color(0.02, 0.50, 0.68), 0.9, true)
	var solar_material := _material(Color(0.025, 0.11, 0.22, 1.0), 0.48, 0.18, Color(0.02, 0.20, 0.42), 0.35)
	var cyan_material := _material(Color(0.08, 0.92, 1.0, 1.0), 0.26, 0.20, Color(0.02, 0.82, 1.0), 2.4)
	var red_light := _material(Color(1.0, 0.05, 0.04, 1.0), 0.05, 0.30, Color(1.0, 0.01, 0.01), 4.5)
	var green_light := _material(Color(0.04, 1.0, 0.26, 1.0), 0.05, 0.30, Color(0.01, 1.0, 0.16), 4.5)
	_beacon_material = _material(Color(1.0, 0.78, 0.08, 1.0), 0.08, 0.28, Color(1.0, 0.50, 0.02), 3.0)

	# Twin semi-submersible hulls keep the silhouette unmistakably unmanned and
	# make heading changes much clearer than the original camera-facing sprite.
	_add_capsule("PortHull", Vector3(-0.92, 0.02, 0.0), Vector3(0.54, 2.85, 0.54), Vector3(90.0, 0.0, 0.0), hull_material)
	_add_capsule("StarboardHull", Vector3(0.92, 0.02, 0.0), Vector3(0.54, 2.85, 0.54), Vector3(90.0, 0.0, 0.0), hull_material)
	_add_box("PortHullStripe", Vector3(-0.92, 0.22, 0.18), Vector3(1.10, 0.14, 4.55), Vector3.ZERO, hull_edge_material)
	_add_box("StarboardHullStripe", Vector3(0.92, 0.22, 0.18), Vector3(1.10, 0.14, 4.55), Vector3.ZERO, hull_edge_material)
	_add_box("BridgeDeck", Vector3(0.0, 0.54, -0.05), Vector3(2.65, 0.22, 3.85), Vector3.ZERO, deck_material)
	_add_box("BowCrossBeam", Vector3(0.0, 0.56, 1.92), Vector3(2.95, 0.30, 0.34), Vector3.ZERO, safety_material)
	_add_box("SternCrossBeam", Vector3(0.0, 0.47, -1.92), Vector3(2.72, 0.26, 0.34), Vector3.ZERO, metal_material)
	_add_box("BowBumper", Vector3(0.0, 0.38, 2.55), Vector3(2.25, 0.40, 0.40), Vector3.ZERO, safety_material)

	_add_box("AutonomyCabin", Vector3(0.0, 1.04, 0.12), Vector3(1.58, 0.72, 1.62), Vector3(-4.0, 0.0, 0.0), deck_material)
	_add_box("ForwardGlass", Vector3(0.0, 1.17, 0.96), Vector3(1.38, 0.42, 0.08), Vector3(-8.0, 0.0, 0.0), glass_material)
	_add_box("PortWindow", Vector3(-0.82, 1.17, 0.12), Vector3(0.07, 0.40, 0.88), Vector3.ZERO, glass_material)
	_add_box("StarboardWindow", Vector3(0.82, 1.17, 0.12), Vector3(0.07, 0.40, 0.88), Vector3.ZERO, glass_material)
	_add_box("PortSolarPanel", Vector3(-0.83, 0.81, -0.86), Vector3(1.10, 0.07, 1.24), Vector3(-5.0, 0.0, 0.0), solar_material)
	_add_box("StarboardSolarPanel", Vector3(0.83, 0.81, -0.86), Vector3(1.10, 0.07, 1.24), Vector3(-5.0, 0.0, 0.0), solar_material)
	for x in [-1.12, 1.12]:
		for z in [-0.30, 0.10, 0.50]:
			_add_box("DeckLight", Vector3(x, 0.72, z), Vector3(0.07, 0.06, 0.22), Vector3.ZERO, cyan_material)

	_add_cylinder("RadarMast", Vector3(0.0, 1.83, -0.02), 0.075, 1.28, Vector3.ZERO, metal_material, 12)
	_add_cylinder("MastCollar", Vector3(0.0, 1.31, -0.02), 0.17, 0.18, Vector3.ZERO, safety_material, 16)
	_radar_scanner = Node3D.new()
	_radar_scanner.name = "RotatingRadarScanner"
	_radar_scanner.position = Vector3(0.0, 2.44, -0.02)
	_motion_root.add_child(_radar_scanner)
	_add_box_to(_radar_scanner, "RadarBar", Vector3.ZERO, Vector3(1.26, 0.10, 0.16), Vector3.ZERO, cyan_material)
	_add_cylinder_to(_radar_scanner, "RadarHub", Vector3(0.0, -0.03, 0.0), 0.15, 0.18, Vector3.ZERO, black_material, 16)

	_sensor_gimbal = Node3D.new()
	_sensor_gimbal.name = "ElectroOpticalGimbal"
	_sensor_gimbal.position = Vector3(0.0, 1.55, 0.98)
	_motion_root.add_child(_sensor_gimbal)
	_add_sphere_to(_sensor_gimbal, "GimbalBody", Vector3.ZERO, 0.24, metal_material)
	_add_cylinder_to(_sensor_gimbal, "PortCamera", Vector3(-0.15, 0.0, 0.18), 0.075, 0.22, Vector3(90.0, 0.0, 0.0), glass_material, 16)
	_add_cylinder_to(_sensor_gimbal, "StarboardCamera", Vector3(0.15, 0.0, 0.18), 0.075, 0.22, Vector3(90.0, 0.0, 0.0), glass_material, 16)

	_add_cylinder("GNSSAntennaPort", Vector3(-0.48, 2.00, -0.20), 0.045, 0.72, Vector3.ZERO, metal_material, 10)
	_add_sphere("GNSSCapPort", Vector3(-0.48, 2.37, -0.20), 0.09, Color.WHITE, black_material)
	_add_cylinder("GNSSAntennaStarboard", Vector3(0.48, 2.00, -0.20), 0.045, 0.72, Vector3.ZERO, metal_material, 10)
	_add_sphere("GNSSCapStarboard", Vector3(0.48, 2.37, -0.20), 0.09, Color.WHITE, black_material)
	_add_sphere("PortNavigationLight", Vector3(-1.20, 0.91, 1.35), 0.11, Color.WHITE, red_light)
	_add_sphere("StarboardNavigationLight", Vector3(1.20, 0.91, 1.35), 0.11, Color.WHITE, green_light)
	_add_sphere("AutonomyBeacon", Vector3(0.0, 2.67, -0.02), 0.12, Color.WHITE, _beacon_material)

	_left_propeller = _build_propeller("PortWaterjet", Vector3(-0.92, 0.08, -2.72), metal_material, safety_material)
	_right_propeller = _build_propeller("StarboardWaterjet", Vector3(0.92, 0.08, -2.72), metal_material, safety_material)

	# Lightweight rails and sensor bumper complete the silhouette without using
	# imported models or textures.
	for x in [-1.30, 1.30]:
		for z in [-1.35, -0.45, 0.45, 1.35]:
			_add_cylinder("RailPost", Vector3(x, 0.96, z), 0.025, 0.50, Vector3.ZERO, metal_material, 8)
		_add_box("SideRail", Vector3(x, 1.20, 0.0), Vector3(0.04, 0.04, 3.10), Vector3.ZERO, metal_material)


func _build_propeller(name_value: String, position_value: Vector3, hub_material: Material, blade_material: Material) -> Node3D:
	var root := Node3D.new()
	root.name = name_value
	root.position = position_value
	_motion_root.add_child(root)
	_add_cylinder_to(root, "Hub", Vector3.ZERO, 0.16, 0.30, Vector3(90.0, 0.0, 0.0), hub_material, 14)
	_add_box_to(root, "BladeA", Vector3(0.0, 0.0, -0.18), Vector3(0.62, 0.10, 0.08), Vector3(0.0, 0.0, 20.0), blade_material)
	_add_box_to(root, "BladeB", Vector3(0.0, 0.0, -0.18), Vector3(0.62, 0.10, 0.08), Vector3(0.0, 0.0, 110.0), blade_material)
	return root


func _add_box(name_value: String, position_value: Vector3, size_value: Vector3, rotation_degrees_value: Vector3, material: Material) -> MeshInstance3D:
	return _add_box_to(_motion_root, name_value, position_value, size_value, rotation_degrees_value, material)


func _add_box_to(parent: Node3D, name_value: String, position_value: Vector3, size_value: Vector3, rotation_degrees_value: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size_value
	return _add_mesh(parent, name_value, mesh, position_value, rotation_degrees_value, material)


func _add_capsule(name_value: String, position_value: Vector3, scale_value: Vector3, rotation_degrees_value: Vector3, material: Material) -> MeshInstance3D:
	var mesh := CapsuleMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	var node := _add_mesh(_motion_root, name_value, mesh, position_value, rotation_degrees_value, material)
	node.scale = scale_value
	return node


func _add_cylinder(name_value: String, position_value: Vector3, radius: float, height: float, rotation_degrees_value: Vector3, material: Material, segments: int) -> MeshInstance3D:
	return _add_cylinder_to(_motion_root, name_value, position_value, radius, height, rotation_degrees_value, material, segments)


func _add_cylinder_to(parent: Node3D, name_value: String, position_value: Vector3, radius: float, height: float, rotation_degrees_value: Vector3, material: Material, segments: int) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = segments
	return _add_mesh(parent, name_value, mesh, position_value, rotation_degrees_value, material)


func _add_sphere(name_value: String, position_value: Vector3, radius: float, _color: Color, material: Material) -> MeshInstance3D:
	return _add_sphere_to(_motion_root, name_value, position_value, radius, material)


func _add_sphere_to(parent: Node3D, name_value: String, position_value: Vector3, radius: float, material: Material) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	return _add_mesh(parent, name_value, mesh, position_value, Vector3.ZERO, material)


func _add_mesh(parent: Node3D, name_value: String, mesh: Mesh, position_value: Vector3, rotation_degrees_value: Vector3, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name_value
	node.mesh = mesh
	node.position = position_value
	node.rotation_degrees = rotation_degrees_value
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(node)
	return node


func _material(
	color: Color,
	metallic: float,
	roughness: float,
	emission_color: Color = Color.BLACK,
	emission_energy: float = 0.0,
	transparent: bool = false
) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if emission_energy > 0.0:
		material.emission_enabled = true
		material.emission = emission_color
		material.emission_energy_multiplier = emission_energy
	return material


func _damping_alpha(response: float, delta: float) -> float:
	if delta <= 0.0:
		return 1.0
	return clampf(1.0 - exp(-maxf(response, 0.0) * delta), 0.0, 1.0)

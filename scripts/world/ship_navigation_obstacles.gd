extends Node3D

@export var water_level_y: float = -140.05
@export var boundary_half_extent: float = 780.0
@export var boundary_wall_thickness: float = 7.0
@export var boundary_wall_height: float = 8.0
@export var obstacle_lift: float = 0.25
@export var rock_positions: Array[Vector3] = [
	Vector3(-48.0, 0.0, -118.0),
	Vector3(98.0, 0.0, -88.0),
	Vector3(112.0, 0.0, -184.0),
	Vector3(-126.0, 0.0, -178.0),
	Vector3(-128.0, 0.0, -42.0)
]
@export var scene_hazards: Array[Dictionary] = [
	{
		"name": "SCENE_CLIFF_WEST_CHANNEL",
		"position": Vector3(-55.0, 0.0, -40.0),
		"radius": 16.0,
		"detection_range": 76.0,
		"avoid_side": 1.0,
		"kind": "cliff"
	}
]
@export var autonomy_course_rock_indices: Array[int] = [1]
@export var box_obstacles: Array[Dictionary] = []

var _temporary_obstacle_index := 0
var _evaluation_visual_clock := 0.0
var _training_environment_preview: Node3D


func _ready() -> void:
	name = "ShipNavigationObstacles"
	add_to_group(&"ship_navigation_obstacle_system")
	_build_boundary()
	_build_rocks()
	_build_box_obstacles()
	set_process(true)


func _process(delta: float) -> void:
	_evaluation_visual_clock += delta
	var pulse := 1.0 + sin(_evaluation_visual_clock * 3.4) * 0.11
	for node in get_tree().get_nodes_in_group(&"rl_evaluation_beacon"):
		if node is Node3D and is_instance_valid(node):
			(node as Node3D).scale = Vector3(pulse, pulse, pulse)
			(node as Node3D).rotation.y += delta * 0.85


func get_radar_obstacle_data() -> Dictionary:
	var rocks: Array[Dictionary] = []
	for index in range(rock_positions.size()):
		var point := rock_positions[index]
		rocks.append({
			"name": "NavigationRock_%02d" % (index + 1),
			"position": Vector3(point.x, water_level_y, point.z),
			"radius": 5.5 + float(index % 3) * 1.35
		})
	for raw_hazard in scene_hazards:
		var hazard := raw_hazard as Dictionary
		var hazard_position := hazard.get("position", Vector3.ZERO) as Vector3
		rocks.append({
			"name": String(hazard.get("name", "SceneHazard")),
			"position": Vector3(hazard_position.x, water_level_y, hazard_position.z),
			"radius": float(hazard.get("radius", 10.0)),
			"kind": String(hazard.get("kind", "scene"))
		})
	var boxes: Array[Dictionary] = []
	for obstacle in box_obstacles:
		boxes.append({
			"name": String(obstacle.get("name", "BoxObstacle")),
			"kind": String(obstacle.get("kind", "obstacle")),
			"position": obstacle.get("position", Vector3.ZERO) as Vector3,
			"size": obstacle.get("size", Vector3.ONE) as Vector3
		})
	return {
		"boundary_half_extent": boundary_half_extent,
		"rocks": rocks,
		"boxes": boxes
	}


func get_autonomy_course_hazards() -> Array[Dictionary]:
	var hazards: Array[Dictionary] = []
	for raw_hazard in scene_hazards:
		var hazard := raw_hazard as Dictionary
		var hazard_position := hazard.get("position", Vector3.ZERO) as Vector3
		hazards.append({
			"name": String(hazard.get("name", "SceneHazard")),
			"position": {"x": hazard_position.x, "z": hazard_position.z},
			"radius": float(hazard.get("radius", 10.0)),
			"detection_range": float(hazard.get("detection_range", 64.0)),
			"avoid_side": float(hazard.get("avoid_side", 1.0)),
			"kind": String(hazard.get("kind", "scene"))
		})
	for rock_index in autonomy_course_rock_indices:
		if rock_index < 0 or rock_index >= rock_positions.size():
			continue
		var point := rock_positions[rock_index]
		hazards.append({
			"name": "NavigationRock_%02d_黑色障碍" % (rock_index + 1),
			"position": {"x": point.x, "z": point.z},
			"radius": 5.5 + float(rock_index % 3) * 1.35,
			"detection_range": 58.0,
			"avoid_side": -1.0,
			"kind": "navigation_rock"
		})
	return hazards


func configure_navigation_area(
	new_boundary_half_extent: float,
	new_rock_positions: Array[Vector3],
	new_box_obstacles: Array[Dictionary] = []
) -> void:
	boundary_half_extent = new_boundary_half_extent
	var next_rocks: Array[Vector3] = []
	for point in new_rock_positions:
		next_rocks.append(point)
	rock_positions = next_rocks
	var next_boxes: Array[Dictionary] = []
	for obstacle in new_box_obstacles:
		next_boxes.append(obstacle.duplicate(true))
	box_obstacles = next_boxes
	_rebuild_navigation_obstacles()


func add_temporary_box_obstacle(
	center_position: Vector3,
	size: Vector3 = Vector3(12.0, 6.0, 12.0),
	label: String = "",
	kind: String = "obstacle"
) -> Dictionary:
	_temporary_obstacle_index += 1
	var obstacle_name := label
	if obstacle_name.is_empty():
		obstacle_name = "InstructorTemporaryObstacle_%02d" % _temporary_obstacle_index
	var obstacle := {
		"name": obstacle_name,
		"position": Vector3(center_position.x, 0.0, center_position.z),
		"size": size,
		"kind": kind,
		"color": Color(1.0, 0.42, 0.18, 0.82),
		"temporary": true
	}
	box_obstacles.append(obstacle)
	_rebuild_navigation_obstacles()
	return obstacle.duplicate(true)


func clear_temporary_obstacles() -> int:
	var removed := 0
	for index in range(box_obstacles.size() - 1, -1, -1):
		var obstacle := box_obstacles[index]
		if bool(obstacle.get("temporary", false)):
			box_obstacles.remove_at(index)
			removed += 1
	if removed > 0:
		_rebuild_navigation_obstacles()
	return removed


func set_temporary_obstacle_position(obstacle_name: String, center_position: Vector3) -> bool:
	for index in range(box_obstacles.size()):
		var obstacle := box_obstacles[index]
		if not bool(obstacle.get("temporary", false)) or String(obstacle.get("name", "")) != obstacle_name:
			continue
		obstacle["position"] = Vector3(center_position.x, 0.0, center_position.z)
		box_obstacles[index] = obstacle
		var body := get_node_or_null(NodePath(obstacle_name)) as Node3D
		if body != null:
			var size := obstacle.get("size", Vector3.ONE) as Vector3
			body.position = Vector3(center_position.x, water_level_y + size.y * 0.5, center_position.z)
		return true
	return false


func apply_training_environment_preview(settings: Dictionary) -> Dictionary:
	clear_training_environment_preview()
	_training_environment_preview = Node3D.new()
	_training_environment_preview.name = "TrainingEnvironmentPreview"
	add_child(_training_environment_preview)

	var vessel_radius := maxf(float(settings.get("vessel_radius_m", 3.2)), 0.1)
	var obstacle_inflation := maxf(float(settings.get("obstacle_inflation_m", 1.5)), 0.0)
	var cliff_inflation := maxf(float(settings.get("cliff_inflation_m", 8.0)), 0.0)
	var boundary_margin := maxf(float(settings.get("boundary_margin_m", 4.0)), 0.0)
	var radar := get_radar_obstacle_data()
	var terrain_count := 0
	var obstacle_count := 0
	for raw_rock in radar.get("rocks", []) as Array:
		var rock := raw_rock as Dictionary
		var kind := String(rock.get("kind", "rock"))
		var extra := cliff_inflation if kind in ["cliff", "terrain", "shoreline"] else 0.0
		var radius := float(rock.get("radius", 1.0)) + vessel_radius + obstacle_inflation + extra
		_add_training_preview_ring(
			String(rock.get("name", "Obstacle")),
			rock.get("position", Vector3.ZERO) as Vector3,
			radius,
			kind
		)
		if kind in ["cliff", "terrain", "shoreline"]:
			terrain_count += 1
		else:
			obstacle_count += 1
	for raw_box in radar.get("boxes", []) as Array:
		var obstacle := raw_box as Dictionary
		var position := obstacle.get("position", Vector3.ZERO) as Vector3
		var size := obstacle.get("size", Vector3.ONE) as Vector3
		_add_training_preview_box(
			String(obstacle.get("name", "BoxObstacle")),
			position,
			Vector3(size.x + (vessel_radius + obstacle_inflation) * 2.0, 0.12, size.z + (vessel_radius + obstacle_inflation) * 2.0)
		)
		obstacle_count += 1
	_add_training_boundary_preview(maxf(boundary_half_extent - boundary_margin - vessel_radius, 1.0))
	return {
		"ok": true,
		"terrain_count": terrain_count,
		"obstacle_count": obstacle_count,
		"effective_boundary_half_extent": maxf(boundary_half_extent - boundary_margin - vessel_radius, 1.0),
		"vessel_radius_m": vessel_radius,
		"cliff_inflation_m": cliff_inflation,
	}


func clear_training_environment_preview() -> void:
	if _training_environment_preview != null and is_instance_valid(_training_environment_preview):
		_training_environment_preview.queue_free()
	_training_environment_preview = null


func _add_training_preview_ring(label: String, center: Vector3, radius: float, kind: String) -> void:
	var ring := MeshInstance3D.new()
	ring.name = "SafetyEnvelope_%s" % label
	var mesh := TorusMesh.new()
	mesh.inner_radius = maxf(radius - 0.55, 0.1)
	mesh.outer_radius = radius
	ring.mesh = mesh
	ring.position = Vector3(center.x, water_level_y + 0.32, center.z)
	var color := Color(1.0, 0.31, 0.08, 0.88) if kind in ["cliff", "terrain", "shoreline"] else Color(0.18, 0.96, 1.0, 0.72)
	ring.material_override = _make_emissive_material(color, 2.8, true)
	_training_environment_preview.add_child(ring)


func _add_training_preview_box(label: String, center: Vector3, size: Vector3) -> void:
	var visual := MeshInstance3D.new()
	visual.name = "SafetyEnvelope_%s" % label
	var mesh := BoxMesh.new()
	mesh.size = size
	visual.mesh = mesh
	visual.position = Vector3(center.x, water_level_y + 0.18, center.z)
	visual.material_override = _make_emissive_material(Color(0.18, 0.96, 1.0, 0.25), 1.8, true)
	_training_environment_preview.add_child(visual)


func _add_training_boundary_preview(effective_half_extent: float) -> void:
	var span := effective_half_extent * 2.0
	for definition in [
		[Vector3(0.0, water_level_y + 0.22, -effective_half_extent), Vector3(span, 0.10, 0.65)],
		[Vector3(0.0, water_level_y + 0.22, effective_half_extent), Vector3(span, 0.10, 0.65)],
		[Vector3(-effective_half_extent, water_level_y + 0.22, 0.0), Vector3(0.65, 0.10, span)],
		[Vector3(effective_half_extent, water_level_y + 0.22, 0.0), Vector3(0.65, 0.10, span)],
	]:
		var line := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = definition[1]
		line.mesh = mesh
		line.position = definition[0]
		line.material_override = _make_emissive_material(Color(0.46, 1.0, 0.58, 0.66), 2.4, true)
		_training_environment_preview.add_child(line)


func _build_boundary() -> void:
	var size := boundary_half_extent * 2.0
	_add_wall(
		"NorthBoundary",
		Vector3(0.0, water_level_y + boundary_wall_height * 0.5, -boundary_half_extent),
		Vector3(size, boundary_wall_height, boundary_wall_thickness)
	)
	_add_wall(
		"SouthBoundary",
		Vector3(0.0, water_level_y + boundary_wall_height * 0.5, boundary_half_extent),
		Vector3(size, boundary_wall_height, boundary_wall_thickness)
	)
	_add_wall(
		"WestBoundary",
		Vector3(-boundary_half_extent, water_level_y + boundary_wall_height * 0.5, 0.0),
		Vector3(boundary_wall_thickness, boundary_wall_height, size)
	)
	_add_wall(
		"EastBoundary",
		Vector3(boundary_half_extent, water_level_y + boundary_wall_height * 0.5, 0.0),
		Vector3(boundary_wall_thickness, boundary_wall_height, size)
	)


func _build_rocks() -> void:
	for index in range(rock_positions.size()):
		var point := rock_positions[index]
		var radius := 5.5 + float(index % 3) * 1.35
		var height := 5.8 + float(index % 2) * 1.7
		_add_rock("NavigationRock_%02d" % (index + 1), Vector3(point.x, water_level_y, point.z), radius, height)


func _build_box_obstacles() -> void:
	for index in range(box_obstacles.size()):
		var obstacle := box_obstacles[index]
		var obstacle_name := String(obstacle.get("name", "HarborObstacle_%02d" % (index + 1)))
		var position := obstacle.get("position", Vector3.ZERO) as Vector3
		var size := obstacle.get("size", Vector3.ONE) as Vector3
		var color := obstacle.get("color", Color(0.16, 0.85, 1.0, 0.22)) as Color
		_add_box_obstacle(obstacle_name, position, size, color)


func _rebuild_navigation_obstacles() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_build_boundary()
	_build_rocks()
	_build_box_obstacles()


func _add_wall(body_name: String, position: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = body_name
	body.add_to_group(&"ship_navigation_obstacle")
	body.collision_layer = 1
	body.collision_mask = 1
	body.position = position
	add_child(body)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)

	var visual := MeshInstance3D.new()
	visual.name = "HologridVisual"
	var mesh := BoxMesh.new()
	mesh.size = size
	visual.mesh = mesh
	visual.material_override = _make_material(Color(0.16, 0.85, 1.0, 0.16), true)
	body.add_child(visual)


func _add_box_obstacle(body_name: String, center_position: Vector3, size: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.name = body_name
	body.add_to_group(&"ship_navigation_obstacle")
	body.collision_layer = 1
	body.collision_mask = 1
	body.position = Vector3(center_position.x, water_level_y + size.y * 0.5, center_position.z)
	add_child(body)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)

	var visual := MeshInstance3D.new()
	visual.name = "HarborObstacleVisual"
	var mesh := BoxMesh.new()
	mesh.size = size
	visual.mesh = mesh
	visual.material_override = _make_material(color, color.a < 1.0)
	body.add_child(visual)

	if body_name.begins_with("RL_OBSTACLE"):
		_add_rl_evaluation_visuals(body, body_name, size, color)


func _add_rl_evaluation_visuals(body: StaticBody3D, body_name: String, size: Vector3, color: Color) -> void:
	var visual := body.get_node_or_null("HarborObstacleVisual") as MeshInstance3D
	if visual != null:
		visual.visible = false

	var obstacle_core := MeshInstance3D.new()
	obstacle_core.name = "AutonomyObstacleCore"
	var core_mesh := CylinderMesh.new()
	core_mesh.top_radius = 2.2
	core_mesh.bottom_radius = 4.2
	core_mesh.height = size.y * 1.08
	obstacle_core.mesh = core_mesh
	obstacle_core.material_override = _make_emissive_material(Color(1.0, 0.28, 0.06, 0.88), 2.2, true)
	body.add_child(obstacle_core)

	for corner_index in range(4):
		var corner_angle := float(corner_index) * TAU / 4.0 + PI * 0.25
		var marker_post := MeshInstance3D.new()
		marker_post.name = "SafetyBoundaryPost_%02d" % (corner_index + 1)
		var post_mesh := CylinderMesh.new()
		post_mesh.top_radius = 0.34
		post_mesh.bottom_radius = 0.48
		post_mesh.height = size.y * 0.82
		marker_post.mesh = post_mesh
		marker_post.position = Vector3(cos(corner_angle) * size.x * 0.46, 0.0, sin(corner_angle) * size.z * 0.46)
		marker_post.material_override = _make_emissive_material(Color(1.0, 0.78, 0.18, 0.92), 3.4, true)
		body.add_child(marker_post)

	var safety_zone := MeshInstance3D.new()
	safety_zone.name = "AISDetectionZone"
	var zone_mesh := CylinderMesh.new()
	zone_mesh.top_radius = maxf(size.x, size.z) * 1.08
	zone_mesh.bottom_radius = zone_mesh.top_radius
	zone_mesh.height = 0.18
	safety_zone.mesh = zone_mesh
	safety_zone.position.y = -size.y * 0.5 + 0.16
	safety_zone.material_override = _make_emissive_material(Color(1.0, 0.30, 0.08, 0.30), 1.4, true)
	safety_zone.add_to_group(&"rl_evaluation_beacon")
	body.add_child(safety_zone)

	var beacon := MeshInstance3D.new()
	beacon.name = "RotatingRiskBeacon"
	var beacon_mesh := TorusMesh.new()
	beacon_mesh.inner_radius = maxf(size.x, size.z) * 0.56
	beacon_mesh.outer_radius = beacon_mesh.inner_radius + 0.55
	beacon.mesh = beacon_mesh
	beacon.position.y = size.y * 0.5 + 1.1
	beacon.material_override = _make_emissive_material(Color(1.0, 0.78, 0.18, 0.96), 4.0, true)
	beacon.add_to_group(&"rl_evaluation_beacon")
	body.add_child(beacon)

	var marker := Label3D.new()
	marker.name = "AutonomyObstacleLabel"
	marker.text = "AI SENSOR TARGET\n%s" % body_name.replace("_", " ")
	marker.position.y = size.y * 0.5 + 4.2
	marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	marker.fixed_size = true
	marker.font_size = 30
	marker.outline_size = 8
	marker.modulate = Color(1.0, 0.86, 0.34, 1.0)
	marker.outline_modulate = Color(0.04, 0.01, 0.0, 0.94)
	body.add_child(marker)

	var light := OmniLight3D.new()
	light.name = "RiskPulseLight"
	light.light_color = Color(1.0, 0.24, 0.08, 1.0)
	light.light_energy = 1.4
	light.omni_range = maxf(size.x, size.z) * 1.35
	light.position.y = size.y * 0.5 + 1.0
	body.add_child(light)


func _add_rock(body_name: String, position: Vector3, radius: float, height: float) -> void:
	var body := StaticBody3D.new()
	body.name = body_name
	body.add_to_group(&"ship_navigation_obstacle")
	body.collision_layer = 1
	body.collision_mask = 1
	body.position = position + Vector3.UP * (height * 0.5 + obstacle_lift)
	add_child(body)

	var collision := CollisionShape3D.new()
	var cylinder := CylinderShape3D.new()
	cylinder.radius = radius
	cylinder.height = height
	collision.shape = cylinder
	body.add_child(collision)

	var visual := MeshInstance3D.new()
	visual.name = "RockVisual"
	var rock_mesh := CylinderMesh.new()
	rock_mesh.top_radius = radius * 0.68
	rock_mesh.bottom_radius = radius
	rock_mesh.height = height
	visual.mesh = rock_mesh
	visual.material_override = _make_material(Color(0.18, 0.22, 0.24, 0.92), true)
	body.add_child(visual)

	var cap := MeshInstance3D.new()
	cap.name = "ImpactBeacon"
	var beacon_mesh := TorusMesh.new()
	beacon_mesh.inner_radius = radius * 0.84
	beacon_mesh.outer_radius = radius * 0.94
	cap.mesh = beacon_mesh
	cap.position.y = height * 0.5 + 0.18
	cap.material_override = _make_material(Color(1.0, 0.70, 0.24, 0.72), true)
	body.add_child(cap)


func _make_material(color: Color, transparent: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


func _make_emissive_material(color: Color, energy: float, transparent: bool) -> StandardMaterial3D:
	var material := _make_material(color, transparent)
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b, 1.0)
	material.emission_energy_multiplier = energy
	return material

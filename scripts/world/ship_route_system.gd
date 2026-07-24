extends Node3D

const DEFAULT_WAYPOINTS: Array[Vector3] = [
	Vector3(0.0, 0.0, -72.0),
	Vector3(72.0, 0.0, -132.0),
	Vector3(46.0, 0.0, -208.0),
	Vector3(-56.0, 0.0, -190.0),
	Vector3(-92.0, 0.0, -96.0)
]

@export var player_path: NodePath = NodePath("../Player")
@export var waypoint_positions: Array[Vector3] = DEFAULT_WAYPOINTS
@export var water_level_y: float = -140.05
@export var arrival_radius: float = 16.0
@export var loop_route: bool = true
@export var route_line_lift: float = 0.24
@export var marker_lift: float = 0.58

var current_waypoint_index: int = 0
var _player: Node3D
var _leg_start_position: Vector3 = Vector3.ZERO
var _has_leg_start := false
var _route_completed := false
var _marker_nodes: Array[Dictionary] = []
var _line_mesh := ImmediateMesh.new()
var _line_instance: MeshInstance3D


func _ready() -> void:
	add_to_group(&"ship_route_system")
	_resolve_player()
	if _player != null:
		_leg_start_position = _player.global_position
		_has_leg_start = true
	_build_route_visuals()
	set_process(true)


func _process(delta: float) -> void:
	if _player == null or not is_instance_valid(_player) or not _player.is_in_group(&"player"):
		var previous_player := _player
		_resolve_player()
		if _player != null and (_player != previous_player or not _has_leg_start):
			_leg_start_position = _player.global_position
			_has_leg_start = true

	if _player == null or _route_completed or waypoint_positions.is_empty():
		return

	_advance_route_if_needed()
	_update_marker_animation(delta)


func get_route_telemetry(ship_position: Vector3) -> Dictionary:
	if waypoint_positions.is_empty():
		return {"active": false}

	var current_index := clampi(current_waypoint_index, 0, waypoint_positions.size() - 1)
	var next_index := _get_next_waypoint_index(current_index)
	var target_position := _get_waypoint_world_position(current_index)
	var next_position := _get_waypoint_world_position(next_index)
	var signed_deviation := _signed_cross_track_distance(ship_position, target_position)
	return {
		"active": not _route_completed,
		"current_index": current_index,
		"current_name": _waypoint_name(current_index),
		"current_position": target_position,
		"current_distance": _horizontal_distance(ship_position, target_position),
		"next_index": next_index,
		"next_name": _waypoint_name(next_index),
		"next_position": next_position,
		"signed_deviation": signed_deviation,
		"deviation_distance": absf(signed_deviation),
		"deviation_side": _deviation_side(signed_deviation),
		"target_bearing_degrees": _bearing_degrees(ship_position, target_position),
		"arrival_radius": arrival_radius
	}


func get_radar_route_data() -> Dictionary:
	var points: Array[Dictionary] = []
	for index in range(waypoint_positions.size()):
		points.append({
			"name": _waypoint_name(index),
			"position": _get_waypoint_world_position(index),
			"active": index == current_waypoint_index and not _route_completed
		})
	return {
		"active": not _route_completed and not waypoint_positions.is_empty(),
		"current_index": clampi(current_waypoint_index, 0, max(waypoint_positions.size() - 1, 0)),
		"arrival_radius": arrival_radius,
		"loop": loop_route,
		"points": points
	}


func configure_route(points: Array[Vector3], loop_enabled: bool, leg_start_position: Vector3) -> void:
	var next_points: Array[Vector3] = []
	for point in points:
		next_points.append(point)
	waypoint_positions = next_points
	loop_route = loop_enabled
	current_waypoint_index = 0
	_route_completed = waypoint_positions.is_empty()
	_leg_start_position = leg_start_position
	_has_leg_start = true
	_rebuild_route_visuals()


func _resolve_player() -> void:
	var found_player := get_tree().get_first_node_in_group(&"player")
	if found_player == null:
		found_player = get_node_or_null(player_path)
	if found_player is Node3D:
		_player = found_player


func _advance_route_if_needed() -> void:
	var target_position := _get_waypoint_world_position(current_waypoint_index)
	if _horizontal_distance(_player.global_position, target_position) > arrival_radius:
		return

	_leg_start_position = target_position
	_has_leg_start = true
	if current_waypoint_index >= waypoint_positions.size() - 1:
		if loop_route:
			current_waypoint_index = 0
		else:
			_route_completed = true
	else:
		current_waypoint_index += 1
	_refresh_marker_state()


func _build_route_visuals() -> void:
	_line_instance = MeshInstance3D.new()
	_line_instance.name = "RouteGuideLine"
	_line_instance.mesh = _line_mesh
	_line_instance.material_override = _make_material(Color(0.20, 0.90, 1.0, 0.82), true)
	add_child(_line_instance)
	_rebuild_route_line()

	for index in range(waypoint_positions.size()):
		var marker := Node3D.new()
		marker.name = _waypoint_name(index)
		marker.position = _get_waypoint_world_position(index)
		add_child(marker)

		var halo := MeshInstance3D.new()
		halo.name = "ArrivalRing"
		var halo_mesh := CylinderMesh.new()
		halo_mesh.top_radius = arrival_radius
		halo_mesh.bottom_radius = arrival_radius
		halo_mesh.height = 0.035
		halo.mesh = halo_mesh
		halo.material_override = _make_material(Color(0.22, 0.90, 1.0, 0.18), true)
		marker.add_child(halo)

		var buoy := MeshInstance3D.new()
		buoy.name = "WaypointBuoy"
		var buoy_mesh := SphereMesh.new()
		buoy_mesh.radius = 1.75
		buoy_mesh.height = 3.5
		buoy.mesh = buoy_mesh
		buoy.position.y = marker_lift
		buoy.material_override = _make_material(Color(1.0, 0.70, 0.24, 0.96) if index == 0 else Color(0.20, 0.90, 1.0, 0.88), true)
		marker.add_child(buoy)

		var label := Label3D.new()
		label.name = "WaypointLabel"
		label.text = _waypoint_name(index)
		label.position = Vector3(0.0, marker_lift + 3.4, 0.0)
		label.font_size = 36
		label.modulate = Color(0.68, 0.98, 1.0, 0.92)
		label.outline_size = 8
		label.outline_modulate = Color(0.0, 0.05, 0.08, 0.9)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		marker.add_child(label)

		_marker_nodes.append({
			"root": marker,
			"halo": halo,
			"buoy": buoy,
			"label": label
		})

	_refresh_marker_state()


func _rebuild_route_visuals() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_marker_nodes.clear()
	_line_mesh = ImmediateMesh.new()
	_build_route_visuals()


func _rebuild_route_line() -> void:
	_line_mesh.clear_surfaces()
	if waypoint_positions.is_empty():
		return

	_line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	if _has_leg_start:
		_line_mesh.surface_add_vertex(Vector3(
			_leg_start_position.x,
			water_level_y + route_line_lift,
			_leg_start_position.z
		))
		_line_mesh.surface_add_vertex(_get_waypoint_world_position(0) + Vector3.UP * route_line_lift)
	for index in range(waypoint_positions.size() - 1):
		_line_mesh.surface_add_vertex(_get_waypoint_world_position(index) + Vector3.UP * route_line_lift)
		_line_mesh.surface_add_vertex(_get_waypoint_world_position(index + 1) + Vector3.UP * route_line_lift)
	if loop_route:
		_line_mesh.surface_add_vertex(_get_waypoint_world_position(waypoint_positions.size() - 1) + Vector3.UP * route_line_lift)
		_line_mesh.surface_add_vertex(_get_waypoint_world_position(0) + Vector3.UP * route_line_lift)
	_line_mesh.surface_end()


func _refresh_marker_state() -> void:
	for index in range(_marker_nodes.size()):
		var marker := _marker_nodes[index]
		var active := index == current_waypoint_index and not _route_completed
		var completed := index < current_waypoint_index and not loop_route
		var buoy := marker["buoy"] as MeshInstance3D
		var halo := marker["halo"] as MeshInstance3D
		var label := marker["label"] as Label3D
		if active:
			buoy.material_override = _make_material(Color(1.0, 0.70, 0.24, 0.96), true)
			halo.material_override = _make_material(Color(1.0, 0.70, 0.24, 0.24), true)
			label.modulate = Color(1.0, 0.78, 0.35, 1.0)
		elif completed:
			buoy.material_override = _make_material(Color(0.36, 1.0, 0.52, 0.62), true)
			halo.material_override = _make_material(Color(0.36, 1.0, 0.52, 0.12), true)
			label.modulate = Color(0.54, 1.0, 0.66, 0.72)
		else:
			buoy.material_override = _make_material(Color(0.20, 0.90, 1.0, 0.82), true)
			halo.material_override = _make_material(Color(0.20, 0.90, 1.0, 0.14), true)
			label.modulate = Color(0.68, 0.98, 1.0, 0.82)


func _update_marker_animation(delta: float) -> void:
	var time := Time.get_ticks_msec() * 0.001
	for index in range(_marker_nodes.size()):
		var marker := _marker_nodes[index]
		var root := marker["root"] as Node3D
		var buoy := marker["buoy"] as MeshInstance3D
		var active := index == current_waypoint_index
		var pulse := sin(time * (3.0 if active else 1.6) + float(index)) * (0.20 if active else 0.08)
		buoy.position.y = marker_lift + pulse
		root.rotate_y(delta * (0.95 if active else 0.28))


func _get_waypoint_world_position(index: int) -> Vector3:
	var point := waypoint_positions[clampi(index, 0, waypoint_positions.size() - 1)]
	return Vector3(point.x, water_level_y, point.z)


func _get_next_waypoint_index(index: int) -> int:
	if waypoint_positions.size() <= 1:
		return index
	if index >= waypoint_positions.size() - 1:
		return 0 if loop_route else index
	return index + 1


func _waypoint_name(index: int) -> String:
	return "WP-%02d" % (index + 1)


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _bearing_degrees(from_position: Vector3, to_position: Vector3) -> float:
	var delta := Vector2(to_position.x - from_position.x, to_position.z - from_position.z)
	if delta.length() <= 0.001:
		return 0.0
	return fposmod(rad_to_deg(atan2(delta.x, delta.y)), 360.0)


func _signed_cross_track_distance(ship_position: Vector3, target_position: Vector3) -> float:
	if not _has_leg_start:
		return 0.0
	var start := Vector2(_leg_start_position.x, _leg_start_position.z)
	var target := Vector2(target_position.x, target_position.z)
	var ship := Vector2(ship_position.x, ship_position.z)
	var leg := target - start
	if leg.length() <= 0.001:
		return 0.0
	var offset := ship - start
	return (leg.x * offset.y - leg.y * offset.x) / leg.length()


func _deviation_side(value: float) -> String:
	if absf(value) < 0.5:
		return "ON TRACK"
	if value > 0.0:
		return "LEFT"
	return "RIGHT"


func _make_material(color: Color, transparent: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material

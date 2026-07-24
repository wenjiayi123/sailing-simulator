extends Node3D
class_name ShipFleetManager

signal fleet_changed
signal ship_selected(ship: Node3D)
signal controlled_ship_changed(ship: Node3D)

const DEFAULT_TRAINING_CONFIG_PATH := "user://rl_training_config.json"
const ENVIRONMENT_PARAMETER_KEYS := [
	"vessel_radius_m",
	"obstacle_inflation_m",
	"cliff_inflation_m",
	"boundary_margin_m",
	"sensor_range_m",
	"tcpa_horizon_seconds",
	"terminate_on_collision",
	"merge_scene_obstacles",
	"domain_randomization",
	"randomize_evaluation",
	"start_position_jitter_m",
	"start_heading_jitter_degrees",
	"obstacle_position_jitter_m",
	"obstacle_size_jitter_m",
	"current_speed_jitter_knots",
	"current_direction_jitter_degrees",
	"wind_speed_jitter_knots",
	"sensor_distance_noise_std_m",
	"sensor_bearing_noise_degrees",
	"generated_traffic_count",
	"generated_traffic_speed_knots",
	"generated_traffic_radius_m",
]

@export var prototype_ship_path: NodePath = NodePath("../Player")
@export var water_level_y: float = -140.05
@export var spawn_lift: float = 0.55
@export var max_ship_count: int = 16
@export var clone_spacing: float = 9.5
@export var training_config_path: String = DEFAULT_TRAINING_CONFIG_PATH
@export_file("*.json") var port_training_dataset_path: String = "res://data/rl/default_port_dataset.json"

var _prototype_ship: Node3D
var _selected_ship: Node3D
var _controlled_ship: Node3D
var _ships: Array[Node3D] = []
var _dragging_new_ship := false
var _drag_config: Dictionary = {}
var _preview_root: Node3D
var _next_ship_index := 1
var _last_drag_position := Vector3.ZERO


func _ready() -> void:
	add_to_group(&"ship_fleet_manager")
	_resolve_prototype()
	_register_existing_ships()
	if _prototype_ship != null:
		take_control_of_ship(_prototype_ship)
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if _dragging_new_ship:
		if event is InputEventMouseMotion:
			_update_drag_preview(event.position)
			get_viewport().set_input_as_handled()
		elif event is InputEventMouseButton:
			var mouse_event := event as InputEventMouseButton
			if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
				_update_drag_preview(mouse_event.position)
				spawn_ship_at(_last_drag_position, _drag_config)
				cancel_drag_new_ship()
				get_viewport().set_input_as_handled()
			elif mouse_event.button_index == MOUSE_BUTTON_RIGHT and mouse_event.pressed:
				cancel_drag_new_ship()
				get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			var picked_ship := pick_ship_from_screen(mouse_event.position)
			if picked_ship != null:
				select_ship(picked_ship)


func start_drag_new_ship(config: Dictionary = {}) -> void:
	if _ships.size() >= max_ship_count:
		return
	_dragging_new_ship = true
	_drag_config = config.duplicate(true)
	_ensure_preview()


func cancel_drag_new_ship() -> void:
	_dragging_new_ship = false
	_drag_config.clear()
	if _preview_root != null and is_instance_valid(_preview_root):
		_preview_root.queue_free()
	_preview_root = null


func duplicate_selected_ship_nearby() -> Node3D:
	if _selected_ship == null:
		return null
	var source_position := _selected_ship.global_position
	var offset := Vector3(clone_spacing, 0.0, 0.0)
	var config := get_selected_ship_config()
	return spawn_ship_at(source_position + offset, config)


func spawn_ship_at(position: Vector3, config: Dictionary = {}) -> Node3D:
	_resolve_prototype()
	if _prototype_ship == null or _ships.size() >= max_ship_count:
		return null

	var source := _selected_ship if _selected_ship != null else _prototype_ship
	var source_heading_degrees := _get_ship_heading_degrees(source)
	var duplicate_flags := Node.DUPLICATE_SCRIPTS | Node.DUPLICATE_USE_INSTANTIATION
	var ship := source.duplicate(duplicate_flags) as Node3D
	if ship == null:
		return null

	var agent_id := _make_next_agent_id()
	ship.name = "ShipAgent_%s" % agent_id.replace("ship_", "")
	ship.set("ship_agent_id", StringName(agent_id))
	ship.set("human_control_enabled", false)
	ship.set("external_agent_control_enabled", false)
	ship.set("camera_enabled", false)
	ship.set("selectable_ship_agent", true)

	var parent := _prototype_ship.get_parent()
	parent.add_child(ship)
	var spawn_position := Vector3(position.x, _prototype_ship.global_position.y, position.z)
	if ship.has_method("prepare_ship_fleet_spawn"):
		ship.call("prepare_ship_fleet_spawn", spawn_position, source_heading_degrees)
	else:
		ship.global_position = spawn_position
	_set_ship_control_enabled(ship, false)
	if ship.has_method("apply_ship_performance_config"):
		var source_config := config if not config.is_empty() else get_selected_ship_config()
		ship.call("apply_ship_performance_config", source_config)
	if not ship.has_method("prepare_ship_fleet_spawn") and ship.has_method("reset_ship_motion_state"):
		ship.call("reset_ship_motion_state")
	_register_ship(ship)
	select_ship(ship)
	fleet_changed.emit()
	return ship


func select_ship(ship: Node3D) -> void:
	if ship == null or not is_instance_valid(ship):
		return
	if not _ships.has(ship):
		_register_ship(ship)
	if _selected_ship != null and is_instance_valid(_selected_ship) and _selected_ship.has_method("set_ship_selection_highlight"):
		_selected_ship.call("set_ship_selection_highlight", false)
	_selected_ship = ship
	if _selected_ship.has_method("set_ship_selection_highlight"):
		_selected_ship.call("set_ship_selection_highlight", true)
	ship_selected.emit(_selected_ship)
	fleet_changed.emit()


func select_ship_by_index(index: int) -> void:
	_prune_invalid_ships()
	if index < 0 or index >= _ships.size():
		return
	select_ship(_ships[index])


func take_control_of_selected_ship() -> void:
	take_control_of_ship(_selected_ship)


func take_control_of_ship(ship: Node3D) -> void:
	if ship == null or not is_instance_valid(ship):
		return
	if not _ships.has(ship):
		_register_ship(ship)
	for record in _ships:
		if record == null or not is_instance_valid(record):
			continue
		_set_ship_control_enabled(record, record == ship)
	_controlled_ship = ship
	select_ship(ship)
	controlled_ship_changed.emit(_controlled_ship)


func cycle_controlled_ship(direction: int = 1) -> void:
	_prune_invalid_ships()
	if _ships.is_empty():
		return
	var step := 1 if direction >= 0 else -1
	var current_index := _ships.find(_controlled_ship)
	if current_index < 0:
		current_index = _ships.find(_selected_ship)
	if current_index < 0:
		current_index = 0
	var next_index := wrapi(current_index + step, 0, _ships.size())
	take_control_of_ship(_ships[next_index])


func delete_selected_ship() -> void:
	if _selected_ship == null or _selected_ship == _prototype_ship:
		return
	var ship_to_delete := _selected_ship
	var deleting_controlled := ship_to_delete == _controlled_ship
	var delete_index := _ships.find(ship_to_delete)
	_ships.erase(ship_to_delete)
	if is_instance_valid(ship_to_delete):
		ship_to_delete.queue_free()
	if deleting_controlled:
		var fallback_ship := _prototype_ship
		if not _ships.is_empty():
			fallback_ship = _ships[clampi(delete_index, 0, _ships.size() - 1)]
		take_control_of_ship(fallback_ship)
	else:
		_selected_ship = _prototype_ship
		if _selected_ship != null:
			select_ship(_selected_ship)
	fleet_changed.emit()


func get_selected_ship() -> Node3D:
	return _selected_ship


func get_controlled_ship() -> Node3D:
	if _controlled_ship != null and not is_instance_valid(_controlled_ship):
		_controlled_ship = null
	return _controlled_ship


func get_selected_ship_config() -> Dictionary:
	if _selected_ship != null and _selected_ship.has_method("get_ship_performance_config"):
		return _selected_ship.call("get_ship_performance_config") as Dictionary
	if _prototype_ship != null and _prototype_ship.has_method("get_ship_performance_config"):
		return _prototype_ship.call("get_ship_performance_config") as Dictionary
	return {}


func apply_config_to_selected_ship(config: Dictionary) -> void:
	if _selected_ship != null and _selected_ship.has_method("apply_ship_performance_config"):
		_selected_ship.call("apply_ship_performance_config", config)
		fleet_changed.emit()


func get_ship_records() -> Array[Node3D]:
	_prune_invalid_ships()
	return _ships.duplicate()


func get_fleet_snapshot() -> Array:
	_prune_invalid_ships()
	var records: Array = []
	for ship in _ships:
		var telemetry := {}
		var performance := {}
		if ship.has_method("get_ship_telemetry"):
			telemetry = ship.call("get_ship_telemetry") as Dictionary
		if ship.has_method("get_ship_performance_config"):
			performance = ship.call("get_ship_performance_config") as Dictionary
		records.append({
			"name": ship.name,
			"agent_id": String(telemetry.get("agent_id", ship.name)),
			"selected": ship == _selected_ship,
			"controlled": ship == _controlled_ship,
			"position": _vector3_to_dict(ship.global_position),
			"telemetry": telemetry,
			"performance": performance
		})
	return records


func export_training_config(path: String = "", rl_parameters: Dictionary = {}) -> String:
	var target_path := path if not path.is_empty() else training_config_path
	var dataset_path := _resolve_training_dataset_path()
	var environment_parameters := {}
	var algorithm_parameters := {}
	for key in rl_parameters.keys():
		if ENVIRONMENT_PARAMETER_KEYS.has(String(key)):
			environment_parameters[key] = rl_parameters[key]
		else:
			algorithm_parameters[key] = rl_parameters[key]
	var payload := {
		"schema_version": "ship_training_experiment_v3",
		"headless": true,
		"render": false,
		"delta": 0.1,
		"algorithms": ["ppo", "sac", "td3", "dqn", "los_pid"],
		"dataset": {
			"path": dataset_path,
			"required_splits": ["train", "validation", "test"],
			"training_split": "train",
			"evaluation_split": "test",
		},
		"rl_parameters": algorithm_parameters,
		"environment_parameters": environment_parameters,
		"ships": get_fleet_snapshot(),
		"world": _get_world_training_snapshot()
	}
	var file := FileAccess.open(target_path, FileAccess.WRITE)
	if file == null:
		push_warning("无法写入训练配置：%s" % target_path)
		return ""
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	return ProjectSettings.globalize_path(target_path)


func preview_training_environment(parameters: Dictionary) -> Dictionary:
	var obstacles := get_node_or_null("../ShipNavigationObstacles")
	if obstacles == null:
		obstacles = get_tree().get_first_node_in_group(&"ship_navigation_obstacle_system")
	if obstacles == null or not obstacles.has_method("apply_training_environment_preview"):
		return {"ok": false, "error": "navigation obstacle system unavailable"}
	return obstacles.call("apply_training_environment_preview", parameters) as Dictionary


func pick_ship_from_screen(screen_position: Vector2) -> Node3D:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return null
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 4000.0)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return null
	return _find_ship_agent(result.get("collider") as Node)


func _resolve_prototype() -> void:
	var found_ship := get_node_or_null(prototype_ship_path)
	if found_ship == null:
		found_ship = get_tree().get_first_node_in_group(&"player")
	if found_ship is Node3D:
		_prototype_ship = found_ship


func _register_existing_ships() -> void:
	_prune_invalid_ships()
	for node in get_tree().get_nodes_in_group(&"ship_agent"):
		if node is Node3D:
			_register_ship(node)
	if _prototype_ship != null:
		_register_ship(_prototype_ship)
	fleet_changed.emit()


func _register_ship(ship: Node3D) -> void:
	if ship == null or _ships.has(ship):
		return
	_ships.append(ship)
	_next_ship_index = max(_next_ship_index, _ships.size() + 1)


func _prune_invalid_ships() -> void:
	for index in range(_ships.size() - 1, -1, -1):
		if not is_instance_valid(_ships[index]):
			if _ships[index] == _selected_ship:
				_selected_ship = null
			if _ships[index] == _controlled_ship:
				_controlled_ship = null
			_ships.remove_at(index)


func _set_ship_control_enabled(ship: Node3D, enabled: bool) -> void:
	if ship == null or not is_instance_valid(ship):
		return
	if ship.has_method("clear_ship_agent_command"):
		ship.call("clear_ship_agent_command")
	if ship.has_method("set_ship_human_control_enabled"):
		ship.call("set_ship_human_control_enabled", enabled)
	else:
		ship.set("human_control_enabled", enabled)
		if enabled:
			ship.add_to_group(&"player")
		else:
			ship.remove_from_group(&"player")
	if ship.has_method("set_ship_camera_enabled"):
		ship.call("set_ship_camera_enabled", enabled)
	else:
		ship.set("camera_enabled", enabled)


func _make_next_agent_id() -> String:
	var agent_id := "ship_%02d" % _next_ship_index
	_next_ship_index += 1
	return agent_id


func _ensure_preview() -> void:
	if _preview_root != null and is_instance_valid(_preview_root):
		return
	_preview_root = Node3D.new()
	_preview_root.name = "ShipSpawnPreview"
	add_child(_preview_root)

	var hull := MeshInstance3D.new()
	hull.name = "PreviewHull"
	var mesh := CapsuleMesh.new()
	mesh.radius = 1.0
	mesh.height = 4.4
	hull.mesh = mesh
	hull.rotation_degrees.z = 90.0
	hull.material_override = _make_preview_material()
	_preview_root.add_child(hull)

	var ring := MeshInstance3D.new()
	ring.name = "PreviewDropRing"
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 2.6
	ring_mesh.outer_radius = 2.75
	ring.mesh = ring_mesh
	ring.position.y = -spawn_lift
	ring.material_override = _make_preview_material(Color(0.46, 1.0, 0.58, 0.42))
	_preview_root.add_child(ring)


func _update_drag_preview(screen_position: Vector2) -> void:
	_last_drag_position = _mouse_to_water(screen_position)
	if _preview_root != null and is_instance_valid(_preview_root):
		_preview_root.global_position = _last_drag_position


func _mouse_to_water(screen_position: Vector2) -> Vector3:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return Vector3.ZERO
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	if absf(direction.y) <= 0.0001:
		return origin + direction * 48.0
	var target_y := water_level_y + spawn_lift
	var distance := (target_y - origin.y) / direction.y
	if distance < 0.0:
		distance = 48.0
	return origin + direction * distance


func _find_ship_agent(node: Node) -> Node3D:
	var cursor := node
	while cursor != null:
		if cursor is Node3D and cursor.is_in_group(&"ship_agent"):
			return cursor as Node3D
		cursor = cursor.get_parent()
	return null


func _get_world_training_snapshot() -> Dictionary:
	return {
		"water_level_y": water_level_y,
		"route": _get_route_snapshot(),
		"obstacles": _get_obstacle_snapshot(),
		"sea_state": _get_sea_state_snapshot(),
	}


func _resolve_training_dataset_path() -> String:
	var environment_path := OS.get_environment("SHIP_RL_DATASET")
	if not environment_path.is_empty() and FileAccess.file_exists(environment_path):
		return environment_path
	var user_path := ProjectSettings.globalize_path("user://port_training_dataset.json")
	if FileAccess.file_exists(user_path):
		return user_path
	return ProjectSettings.globalize_path(port_training_dataset_path)


func _get_sea_state_snapshot() -> Dictionary:
	var weather := get_node_or_null("../ShipWeatherTimeController")
	if weather == null:
		weather = get_tree().get_first_node_in_group(&"ship_weather_time_system")
	if weather != null and weather.has_method("get_sea_state_status"):
		return weather.call("get_sea_state_status") as Dictionary
	return {}


func _get_route_snapshot() -> Dictionary:
	var route_system := get_node_or_null("../ShipRouteSystem")
	if route_system == null:
		route_system = get_tree().get_first_node_in_group(&"ship_route_system")
	if route_system == null:
		return {"waypoints": []}
	var waypoints: Array = []
	var raw_waypoints: Array = route_system.get("waypoint_positions")
	for point in raw_waypoints:
		if point is Vector3:
			waypoints.append(_vector3_to_dict(point))
	return {
		"waypoints": waypoints,
		"arrival_radius": float(route_system.get("arrival_radius")),
		"loop_route": bool(route_system.get("loop_route"))
	}


func _get_obstacle_snapshot() -> Dictionary:
	var obstacles := get_node_or_null("../ShipNavigationObstacles")
	if obstacles == null:
		return {"boundary_half_extent": 780.0, "rocks": [], "boxes": []}
	if obstacles.has_method("get_radar_obstacle_data"):
		var radar := obstacles.call("get_radar_obstacle_data") as Dictionary
		var radar_rocks: Array = []
		for raw_rock in radar.get("rocks", []) as Array:
			var rock := raw_rock as Dictionary
			var position := rock.get("position", Vector3.ZERO) as Vector3
			radar_rocks.append({
				"name": String(rock.get("name", "NavigationRock")),
				"kind": String(rock.get("kind", "rock")),
				"shape": "circle",
				"x": position.x,
				"z": position.z,
				"radius": float(rock.get("radius", 8.0)),
			})
		var radar_boxes: Array = []
		for raw_box in radar.get("boxes", []) as Array:
			var obstacle := raw_box as Dictionary
			var box_position := obstacle.get("position", Vector3.ZERO) as Vector3
			var box_size := obstacle.get("size", Vector3.ONE) as Vector3
			radar_boxes.append({
				"name": String(obstacle.get("name", "BoxObstacle")),
				"kind": String(obstacle.get("kind", "obstacle")),
				"shape": "box",
				"position": _vector3_to_dict(box_position),
				"size": _vector3_to_dict(box_size),
			})
		return {
			"boundary_half_extent": float(radar.get("boundary_half_extent", 780.0)),
			"rocks": radar_rocks,
			"boxes": radar_boxes,
		}
	var rocks: Array = []
	var raw_rocks: Array = obstacles.get("rock_positions")
	for point in raw_rocks:
		if point is Vector3:
			rocks.append(_vector3_to_dict(point))
	return {
		"boundary_half_extent": float(obstacles.get("boundary_half_extent")),
		"rocks": rocks,
		"boxes": [],
	}


func _get_ship_heading_degrees(ship: Node3D) -> float:
	if ship != null and ship.has_method("get_ship_telemetry"):
		var telemetry := ship.call("get_ship_telemetry") as Dictionary
		return float(telemetry.get("heading_degrees", 0.0))
	return 0.0


func _vector3_to_dict(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}


func _make_preview_material(color: Color = Color(0.28, 0.96, 1.0, 0.36)) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

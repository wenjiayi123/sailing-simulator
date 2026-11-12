extends Node

class_name ShipScenarioController

signal scenario_changed(status: Dictionary)

const TOGGLE_SCENARIO_KEY := KEY_G
const WATER_LEVEL_Y := -140.05
const SHIP_Y := -140.73494
const OPEN_WATER_BOUNDARY_HALF_EXTENT := 780.0
const HARBOR_BOUNDARY_HALF_EXTENT := 180.0

@export var player_path: NodePath = NodePath("../Player")
@export var route_system_path: NodePath = NodePath("../ShipRouteSystem")
@export var obstacle_system_path: NodePath = NodePath("../ShipNavigationObstacles")
@export var base_environment_path: NodePath = NodePath("../NavigationEnvironment")
@export var large_rock_guard_path: NodePath = NodePath("../LargeRockCollisionGuard")
@export var weather_time_path: NodePath = NodePath("../ShipWeatherTimeController")
@export_file("*.json") var port_profile_path: String = "res://data/ports/default_port_profile.json"

var _player: Node3D
var _route_system: Node
var _obstacle_system: Node
var _base_environment: Node3D
var _large_rock_guard: Node
var _weather_time: Node
var _background_controller: Node
var _harbor_root: Node3D
var _dedicated_scene_root: Node3D
var _active_dedicated_scene: Node3D
var _active_dedicated_scene_path := ""
var _dedicated_scene_error := ""
var _scenario_index := 0
var _scenario_keys: Array[String] = ["open_water", "harbor"]
var _port_profile: Dictionary = {}
var _port_profile_loaded_path := ""


func _ready() -> void:
	add_to_group(&"ship_scenario_system")
	_resolve_targets()
	_load_port_profile()
	_build_harbor_visuals()
	_ensure_dedicated_scene_root()
	var startup_key := OS.get_environment("SHIP_START_SCENARIO_KEY").strip_edges()
	if startup_key.is_empty():
		apply_scenario(0, false)
	else:
		# A dedicated PackedScene cannot be attached while the main scene is still
		# inside its child-setup pass. Defer only the inspection/startup override.
		call_deferred("_apply_startup_scenario", startup_key)
	set_process_unhandled_input(true)


func _apply_startup_scenario(startup_key: String) -> void:
	apply_scenario(get_scenario_index_by_key(startup_key), true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return
		if key_event.physical_keycode == TOGGLE_SCENARIO_KEY:
			apply_scenario(_scenario_index + 1, true)
			get_viewport().set_input_as_handled()


func apply_scenario(index: int, teleport_ship: bool = true) -> void:
	_scenario_index = wrapi(index, 0, maxi(_scenario_keys.size(), 1))
	if _route_system == null or _obstacle_system == null or _player == null or not is_instance_valid(_player) or not _player.is_in_group(&"player"):
		_resolve_targets()
	var key := _scenario_keys[_scenario_index] if not _scenario_keys.is_empty() else "open_water"
	_reset_default_clear_weather()
	if _harbor_root != null:
		_harbor_root.visible = key == "harbor"
	if not _apply_profile_scenario(key, teleport_ship):
		if key == "harbor":
			_apply_harbor(teleport_ship)
		else:
			_apply_open_water(teleport_ship)

	if key == "open_water" and _background_controller != null:
		_background_controller.call("apply_startup_port_background")
	scenario_changed.emit(get_scenario_status())


func get_scenario_status() -> Dictionary:
	var key := _scenario_keys[_scenario_index] if not _scenario_keys.is_empty() else "open_water"
	var scenarios := _port_profile.get("scenarios", {}) as Dictionary
	var scenario := scenarios.get(key, {}) as Dictionary
	return {
		"index": _scenario_index,
		"key": key,
		"name": String(scenario.get("name", "港口引航水域" if key == "harbor" else "开放水域")),
		"description": String(scenario.get("description", "PORT PROFILE")),
		"task_type": String(scenario.get("task_type", "route_following")),
		"visual_family": String(scenario.get("visual_family", key)),
		"colreg_rule_ids": (scenario.get("colreg_rule_ids", []) as Array).duplicate(),
		"traffic_count": (scenario.get("traffic", []) as Array).size(),
		"claim_boundary": String(scenario.get("claim_boundary", "simulation only")),
		"dedicated_scene_path": String(scenario.get("dedicated_scene_path", "")),
		"dedicated_scene_active": _active_dedicated_scene != null and is_instance_valid(_active_dedicated_scene),
		"base_environment_active": _active_dedicated_scene == null or not is_instance_valid(_active_dedicated_scene),
		"dedicated_scene_error": _dedicated_scene_error,
		"data_profile": String(_port_profile.get("name", "built-in fallback")),
		"data_source": _port_profile.get("source", {}),
		"profile_path": _port_profile_loaded_path,
		"default_weather_mode": "clear",
	}


func get_port_profile() -> Dictionary:
	return _port_profile.duplicate(true)


func get_port_profile_path() -> String:
	return _port_profile_loaded_path


func get_scenario_index_by_key(key: String) -> int:
	var found := _scenario_keys.find(key)
	return found if found >= 0 else 0


func get_scenario_count() -> int:
	return _scenario_keys.size()


func list_scenarios() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var scenarios := _port_profile.get("scenarios", {}) as Dictionary
	for index in range(_scenario_keys.size()):
		var key := _scenario_keys[index]
		var scenario := scenarios.get(key, {}) as Dictionary
		result.append({
			"index": index,
			"key": key,
			"name": String(scenario.get("name", key)),
			"task_type": String(scenario.get("task_type", "route_following")),
			"traffic_count": (scenario.get("traffic", []) as Array).size(),
		})
	return result


func get_current_scenario_config() -> Dictionary:
	if _scenario_keys.is_empty():
		return {}
	var scenarios := _port_profile.get("scenarios", {}) as Dictionary
	return (scenarios.get(_scenario_keys[_scenario_index], {}) as Dictionary).duplicate(true)


func get_active_dedicated_scene_snapshot() -> Dictionary:
	if _active_dedicated_scene == null or not is_instance_valid(_active_dedicated_scene):
		return {
			"dedicated_scene": false,
			"scene_path": "",
			"base_environment_active": true,
		}
	var snapshot: Dictionary = {}
	if _active_dedicated_scene.has_method("get_scene_snapshot"):
		snapshot = _active_dedicated_scene.call("get_scene_snapshot") as Dictionary
	snapshot["scene_path"] = _active_dedicated_scene_path
	snapshot["base_environment_active"] = false
	if _background_controller != null and _background_controller.has_method("get_visual_profile_status"):
		snapshot["visual_profile"] = _background_controller.call("get_visual_profile_status")
	return snapshot


func _apply_open_water(teleport_ship: bool) -> void:
	_activate_visual_scene({}, "open_water")
	if _harbor_root != null:
		_harbor_root.visible = false
	var spawn := Vector3(0.36, SHIP_Y, -0.05)
	_configure_route(_open_water_route(), true, spawn)
	_configure_obstacles(OPEN_WATER_BOUNDARY_HALF_EXTENT, _open_water_rocks(), [], true)
	if teleport_ship:
		_place_ship(spawn, 214.0)


func _apply_harbor(teleport_ship: bool) -> void:
	_activate_visual_scene({}, "harbor")
	if _harbor_root != null:
		_harbor_root.visible = true
	var spawn := Vector3(-148.0, SHIP_Y, -92.0)
	_configure_route(_harbor_route(), false, spawn)
	_configure_obstacles(HARBOR_BOUNDARY_HALF_EXTENT, _harbor_buoy_rocks(), _harbor_box_obstacles(), true)
	if teleport_ship:
		_place_ship(spawn, 84.0)


func _configure_route(points: Array[Vector3], loop_enabled: bool, leg_start: Vector3) -> void:
	if _route_system != null and _route_system.has_method("configure_route"):
		_route_system.call("configure_route", points, loop_enabled, leg_start)


func _configure_obstacles(
	boundary_half_extent: float,
	rocks: Array[Vector3],
	boxes: Array[Dictionary],
	builtin_visuals_enabled: bool,
) -> void:
	if _obstacle_system != null and _obstacle_system.has_method("configure_navigation_area"):
		_obstacle_system.call("configure_navigation_area", boundary_half_extent, rocks, boxes)
	if _obstacle_system != null and _obstacle_system.has_method("set_runtime_visuals_enabled"):
		_obstacle_system.call("set_runtime_visuals_enabled", builtin_visuals_enabled)


func _place_ship(position: Vector3, heading_degrees: float) -> void:
	if _player == null or not is_instance_valid(_player) or not _player.is_in_group(&"player"):
		_resolve_targets()
	if _player == null:
		return
	if _player.has_method("set_ship_navigation_spawn"):
		_player.call("set_ship_navigation_spawn", position, heading_degrees)
	else:
		_player.global_position = position


func _load_port_profile() -> void:
	var candidates: Array[String] = []
	var environment_path := OS.get_environment("SHIP_PORT_PROFILE")
	if not environment_path.is_empty():
		candidates.append(environment_path)
	candidates.append(ProjectSettings.globalize_path("user://port_profile.json"))
	candidates.append(port_profile_path)
	for candidate in candidates:
		if not FileAccess.file_exists(candidate):
			continue
		var file := FileAccess.open(candidate, FileAccess.READ)
		if file == null:
			continue
		var parsed = JSON.parse_string(file.get_as_text())
		file.close()
		if parsed is not Dictionary:
			continue
		var payload := parsed as Dictionary
		if String(payload.get("schema_version", "")) != "ship_port_profile_v1":
			continue
		_port_profile = payload
		_port_profile_loaded_path = ProjectSettings.globalize_path(candidate)
		_refresh_scenario_keys()
		return


func _refresh_scenario_keys() -> void:
	var scenarios := _port_profile.get("scenarios", {}) as Dictionary
	var ordered: Array[String] = []
	for raw_key in _port_profile.get("scenario_order", []) as Array:
		var key := String(raw_key)
		if scenarios.has(key) and not ordered.has(key):
			ordered.append(key)
	for raw_key in scenarios.keys():
		var key := String(raw_key)
		if not ordered.has(key):
			ordered.append(key)
	if not ordered.is_empty():
		_scenario_keys = ordered


func _apply_profile_scenario(key: String, teleport_ship: bool) -> bool:
	var scenarios := _port_profile.get("scenarios", {}) as Dictionary
	var scenario := scenarios.get(key, {}) as Dictionary
	if scenario.is_empty():
		return false
	var dedicated_scene_active := _activate_visual_scene(scenario, key)
	if _harbor_root != null:
		_harbor_root.visible = not dedicated_scene_active and String(scenario.get("visual_family", key)) == "harbor"
	var route: Array[Vector3] = []
	for raw_point in scenario.get("route", []) as Array:
		var point := raw_point as Dictionary
		route.append(Vector3(float(point.get("x", 0.0)), 0.0, float(point.get("z", 0.0))))
	var rocks: Array[Vector3] = []
	for raw_rock in scenario.get("rocks", []) as Array:
		var rock := raw_rock as Dictionary
		rocks.append(Vector3(float(rock.get("x", 0.0)), 0.0, float(rock.get("z", 0.0))))
	var boxes: Array[Dictionary] = []
	for raw_box in scenario.get("boxes", []) as Array:
		var box := raw_box as Dictionary
		var position := box.get("position", {}) as Dictionary
		var size := box.get("size", {}) as Dictionary
		boxes.append({
			"name": String(box.get("name", "PortObstacle")),
			"position": Vector3(float(position.get("x", 0.0)), 0.0, float(position.get("z", 0.0))),
			"size": Vector3(float(size.get("x", 1.0)), float(size.get("y", 5.0)), float(size.get("z", 1.0))),
			"color": Color(0.24, 0.28, 0.30, 0.96),
		})
	var spawn_data := scenario.get("spawn", {}) as Dictionary
	var spawn := Vector3(float(spawn_data.get("x", 0.0)), SHIP_Y, float(spawn_data.get("z", 0.0)))
	_apply_profile_route_parameters(key)
	_configure_route(route, bool(scenario.get("loop_route", false)), spawn)
	_configure_obstacles(float(scenario.get("boundary_half_extent", 180.0)), rocks, boxes, not dedicated_scene_active)
	if teleport_ship:
		_place_ship(spawn, float(spawn_data.get("heading_degrees", 180.0)))
	return true


func _apply_profile_route_parameters(key: String) -> void:
	if _route_system == null:
		return
	for raw_mission in _port_profile.get("navigation_missions", []) as Array:
		var mission := raw_mission as Dictionary
		if String(mission.get("scenario_key", "")) != key:
			continue
		_route_system.set("arrival_radius", float(mission.get("arrival_radius", _route_system.get("arrival_radius"))))
		return


func _resolve_targets() -> void:
	var found_player := get_tree().get_first_node_in_group(&"player")
	if found_player == null:
		found_player = get_node_or_null(player_path)
	if found_player is Node3D:
		_player = found_player

	_route_system = get_node_or_null(route_system_path)
	if _route_system == null:
		_route_system = get_tree().get_first_node_in_group(&"ship_route_system")

	_obstacle_system = get_node_or_null(obstacle_system_path)
	if _obstacle_system == null:
		_obstacle_system = get_tree().get_first_node_in_group(&"ship_navigation_obstacle_system")

	_base_environment = get_node_or_null(base_environment_path) as Node3D
	_large_rock_guard = get_node_or_null(large_rock_guard_path)
	_weather_time = get_node_or_null(weather_time_path)
	if _weather_time == null:
		_weather_time = get_tree().get_first_node_in_group(&"ship_weather_time_system")
	_background_controller = _base_environment.get_node_or_null("BackgroundWalls") if _base_environment != null else null


func _reset_default_clear_weather() -> void:
	if _weather_time == null or not is_instance_valid(_weather_time):
		_weather_time = get_node_or_null(weather_time_path)
		if _weather_time == null:
			_weather_time = get_tree().get_first_node_in_group(&"ship_weather_time_system")
	if _weather_time != null and _weather_time.has_method("apply_zero_fog_clear_baseline"):
		_weather_time.call("apply_zero_fog_clear_baseline", {})
	elif _weather_time != null and _weather_time.has_method("apply_mode"):
		_weather_time.call("apply_mode", 0)


func _ensure_dedicated_scene_root() -> void:
	if _dedicated_scene_root != null and is_instance_valid(_dedicated_scene_root):
		return
	_dedicated_scene_root = Node3D.new()
	_dedicated_scene_root.name = "DedicatedTaskSceneRoot"
	get_parent().add_child.call_deferred(_dedicated_scene_root)


func _activate_visual_scene(scenario: Dictionary, key: String) -> bool:
	_dedicated_scene_error = ""
	var scene_path := String(scenario.get("dedicated_scene_path", "")).strip_edges()
	if scene_path.is_empty():
		_clear_dedicated_scene()
		_restore_base_visual_profile()
		_set_base_environment_active(true)
		return false
	_set_base_environment_active(false)
	if (
		_active_dedicated_scene != null
		and is_instance_valid(_active_dedicated_scene)
		and _active_dedicated_scene_path == scene_path
	):
		return true
	_clear_dedicated_scene()
	_ensure_dedicated_scene_root()
	if _dedicated_scene_root.get_parent() == null:
		get_parent().add_child(_dedicated_scene_root)
	if not ResourceLoader.exists(scene_path, "PackedScene"):
		_dedicated_scene_error = "SCENE_RESOURCE_UNAVAILABLE: %s" % scene_path
		push_error(_dedicated_scene_error)
		_set_base_environment_active(true)
		return false
	var packed_variant: Variant = load(scene_path)
	if not (packed_variant is PackedScene):
		_dedicated_scene_error = "SCENE_RESOURCE_INVALID: %s" % scene_path
		push_error(_dedicated_scene_error)
		_set_base_environment_active(true)
		return false
	var instance_variant: Variant = (packed_variant as PackedScene).instantiate()
	if not (instance_variant is Node3D):
		_dedicated_scene_error = "SCENE_ROOT_INVALID: %s" % scene_path
		push_error(_dedicated_scene_error)
		_set_base_environment_active(true)
		return false
	_active_dedicated_scene = instance_variant as Node3D
	_active_dedicated_scene.name = "Dedicated_%s" % key
	_dedicated_scene_root.add_child(_active_dedicated_scene)
	_active_dedicated_scene_path = scene_path
	_apply_task_visual_profile(scenario, key)
	return true


func _clear_dedicated_scene() -> void:
	if _active_dedicated_scene != null and is_instance_valid(_active_dedicated_scene):
		if _active_dedicated_scene.get_parent() != null:
			_active_dedicated_scene.get_parent().remove_child(_active_dedicated_scene)
		_active_dedicated_scene.queue_free()
	_active_dedicated_scene = null
	_active_dedicated_scene_path = ""


func _apply_task_visual_profile(scenario: Dictionary, key: String) -> void:
	if _background_controller == null or not is_instance_valid(_background_controller):
		_resolve_targets()
	if _background_controller == null:
		return
	var profile := scenario.get("visual_profile", {}) as Dictionary
	var wallpaper_path := String(profile.get("wallpaper_texture", "")).strip_edges()
	var water_path := String(profile.get("water_texture", "")).strip_edges()
	var wallpaper_bottom_composition := String(profile.get("wallpaper_bottom_composition", "landline_at_bottom"))
	var wallpaper_sea_band_max_fraction := minf(float(profile.get("wallpaper_sea_band_max_fraction", 0.03)), 0.03)
	if wallpaper_path.is_empty() or water_path.is_empty():
		_restore_base_visual_profile()
		return
	if _background_controller.has_method("apply_task_visual_profile"):
		var result := _background_controller.call(
			"apply_task_visual_profile",
			key,
			wallpaper_path,
			water_path,
			0.0,
			wallpaper_bottom_composition,
			wallpaper_sea_band_max_fraction,
		) as Dictionary
		if not bool(result.get("applied", false)):
			_dedicated_scene_error = "TASK_VISUAL_PROFILE_FAILED: %s" % str(result)
	if _active_dedicated_scene != null and _active_dedicated_scene.has_method("apply_task_visual_profile"):
		var dedicated_result := _active_dedicated_scene.call(
			"apply_task_visual_profile",
			wallpaper_path,
			water_path,
			wallpaper_bottom_composition,
			wallpaper_sea_band_max_fraction,
		) as Dictionary
		if not bool(dedicated_result.get("applied", false)):
			_dedicated_scene_error = "DEDICATED_TASK_VISUAL_PROFILE_FAILED: %s" % str(dedicated_result)


func _restore_base_visual_profile() -> void:
	if _background_controller == null or not is_instance_valid(_background_controller):
		_resolve_targets()
	if _background_controller != null and _background_controller.has_method("restore_base_visuals"):
		_background_controller.call("restore_base_visuals")


func _set_base_environment_active(active: bool) -> void:
	if _large_rock_guard == null or not is_instance_valid(_large_rock_guard):
		_large_rock_guard = get_node_or_null(large_rock_guard_path)
	if _large_rock_guard != null and _large_rock_guard.has_method("set_base_environment_active"):
		_large_rock_guard.call("set_base_environment_active", active)
	elif _base_environment != null:
		_base_environment.visible = active


func _open_water_route() -> Array[Vector3]:
	var points: Array[Vector3] = [
		Vector3(0.0, 0.0, -72.0),
		Vector3(72.0, 0.0, -132.0),
		Vector3(46.0, 0.0, -208.0),
		Vector3(-56.0, 0.0, -190.0),
		Vector3(-92.0, 0.0, -96.0)
	]
	return points


func _open_water_rocks() -> Array[Vector3]:
	var rocks: Array[Vector3] = [
		Vector3(-48.0, 0.0, -118.0),
		Vector3(98.0, 0.0, -88.0),
		Vector3(112.0, 0.0, -184.0),
		Vector3(-126.0, 0.0, -178.0),
		Vector3(-128.0, 0.0, -42.0)
	]
	return rocks


func _harbor_route() -> Array[Vector3]:
	var points: Array[Vector3] = [
		Vector3(-118.0, 0.0, -86.0),
		Vector3(-74.0, 0.0, -76.0),
		Vector3(-34.0, 0.0, -50.0),
		Vector3(14.0, 0.0, -33.0),
		Vector3(58.0, 0.0, -10.0),
		Vector3(82.0, 0.0, 30.0)
	]
	return points


func _harbor_buoy_rocks() -> Array[Vector3]:
	var rocks: Array[Vector3] = [
		Vector3(-96.0, 0.0, -104.0),
		Vector3(-64.0, 0.0, -52.0),
		Vector3(-10.0, 0.0, -68.0),
		Vector3(38.0, 0.0, -14.0),
		Vector3(74.0, 0.0, 20.0)
	]
	return rocks


func _harbor_box_obstacles() -> Array[Dictionary]:
	var boxes: Array[Dictionary] = [
		_box("WestBreakwater", Vector3(-144.0, 0.0, -12.0), Vector3(16.0, 7.0, 142.0), Color(0.20, 0.24, 0.27, 0.96)),
		_box("EastBreakwater", Vector3(132.0, 0.0, -66.0), Vector3(16.0, 7.0, 106.0), Color(0.20, 0.24, 0.27, 0.96)),
		_box("NorthPier", Vector3(6.0, 0.0, -92.0), Vector3(126.0, 5.0, 16.0), Color(0.24, 0.28, 0.30, 0.96)),
		_box("SouthPier", Vector3(24.0, 0.0, 58.0), Vector3(138.0, 5.0, 16.0), Color(0.24, 0.28, 0.30, 0.96)),
		_box("CargoQuay", Vector3(104.0, 0.0, 18.0), Vector3(26.0, 6.0, 118.0), Color(0.30, 0.32, 0.34, 0.96)),
		_box("BerthFinger", Vector3(64.0, 0.0, 36.0), Vector3(72.0, 4.0, 12.0), Color(0.28, 0.31, 0.33, 0.96))
	]
	return boxes


func _box(obstacle_name: String, position: Vector3, size: Vector3, color: Color) -> Dictionary:
	return {
		"name": obstacle_name,
		"position": position,
		"size": size,
		"color": color
	}


func _build_harbor_visuals() -> void:
	_harbor_root = Node3D.new()
	_harbor_root.name = "GeneratedHarborScene"
	_harbor_root.visible = false
	add_child(_harbor_root)

	for obstacle in _harbor_box_obstacles():
		_add_box_mesh(
			_harbor_root,
			String(obstacle["name"]) + "_Visual",
			obstacle["position"] as Vector3,
			obstacle["size"] as Vector3,
			obstacle["color"] as Color
		)

	_add_container_yard()
	_add_harbor_crane(Vector3(106.0, 0.0, -36.0), "Crane_A")
	_add_harbor_crane(Vector3(106.0, 0.0, 26.0), "Crane_B")
	_add_berth_markers()
	_add_harbor_label(Vector3(8.0, WATER_LEVEL_Y + 9.0, 80.0), "HARBOR PILOTAGE // 简易港口")
	_add_harbor_label(Vector3(82.0, WATER_LEVEL_Y + 6.0, 48.0), "BERTH A-01")


func _add_container_yard() -> void:
	var colors := [
		Color(0.13, 0.54, 0.86, 0.98),
		Color(0.92, 0.36, 0.20, 0.98),
		Color(0.96, 0.74, 0.24, 0.98),
		Color(0.18, 0.72, 0.42, 0.98)
	]
	var index := 0
	for z_index in range(0, 5):
		for lane in range(0, 2):
			var position := Vector3(118.0 + float(lane) * 12.0, 0.0, -44.0 + float(z_index) * 20.0)
			var height := 4.0 + float((z_index + lane) % 2) * 2.0
			_add_box_mesh(
				_harbor_root,
				"Container_%02d" % index,
				position,
				Vector3(10.0, height, 8.0),
				colors[index % colors.size()]
			)
			index += 1


func _add_harbor_crane(position: Vector3, crane_name: String) -> void:
	var base_color := Color(1.0, 0.72, 0.20, 0.96)
	_add_box_mesh(_harbor_root, crane_name + "_Tower", position + Vector3(0.0, 0.0, 0.0), Vector3(4.0, 28.0, 4.0), base_color)
	_add_box_mesh(_harbor_root, crane_name + "_Boom", position + Vector3(-28.0, 25.0, 0.0), Vector3(58.0, 3.0, 3.0), base_color)
	_add_box_mesh(_harbor_root, crane_name + "_Counterweight", position + Vector3(12.0, 22.0, 0.0), Vector3(12.0, 8.0, 8.0), Color(0.22, 0.24, 0.26, 0.96))


func _add_berth_markers() -> void:
	for index in range(0, 5):
		_add_buoy(Vector3(70.0, 0.0, -14.0 + float(index) * 14.0), "BerthLight_%02d" % index, Color(0.46, 1.0, 0.58, 0.92))
	for index in range(0, 4):
		_add_buoy(Vector3(-94.0 + float(index) * 28.0, 0.0, -72.0 + float(index % 2) * 22.0), "ApproachBuoy_%02d" % index, Color(1.0, 0.70, 0.24, 0.92))


func _add_buoy(position: Vector3, buoy_name: String, color: Color) -> void:
	var buoy := MeshInstance3D.new()
	buoy.name = buoy_name
	var mesh := CylinderMesh.new()
	mesh.top_radius = 1.2
	mesh.bottom_radius = 1.6
	mesh.height = 3.6
	buoy.mesh = mesh
	buoy.position = Vector3(position.x, WATER_LEVEL_Y + 2.0, position.z)
	buoy.material_override = _make_material(color, true)
	_harbor_root.add_child(buoy)


func _add_harbor_label(position: Vector3, text: String) -> void:
	var label := Label3D.new()
	label.name = text.replace(" ", "_")
	label.text = text
	label.position = position
	label.font_size = 34
	label.modulate = Color(0.70, 0.95, 1.0, 0.92)
	label.outline_size = 7
	label.outline_modulate = Color(0.0, 0.04, 0.06, 0.88)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_harbor_root.add_child(label)


func _add_box_mesh(parent: Node3D, mesh_name: String, center_position: Vector3, size: Vector3, color: Color) -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = mesh_name
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh_instance.mesh = mesh
	mesh_instance.position = Vector3(center_position.x, WATER_LEVEL_Y + size.y * 0.5 + center_position.y, center_position.z)
	mesh_instance.material_override = _make_material(color, color.a < 1.0)
	parent.add_child(mesh_instance)


func _make_material(color: Color, transparent: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.82
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material

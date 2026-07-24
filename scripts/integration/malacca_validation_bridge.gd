extends Node
class_name MalaccaValidationBridge

signal validation_request_received(request: Dictionary)
signal validation_result_written(result: Dictionary)

const DEFAULT_REQUEST_FILE_PATH := "user://malacca_validation_request.json"
const DEFAULT_RESULT_FILE_PATH := "user://malacca_validation_result.json"
const SHIP_Y := -140.73494
const GEO_LAT_MIN := 0.8
const GEO_LAT_MAX := 6.2
const GEO_LON_MIN := 98.0
const GEO_LON_MAX := 104.6
const WORLD_X_MIN := -220.0
const WORLD_X_MAX := 220.0
const WORLD_Z_MIN := 160.0
const WORLD_Z_MAX := -220.0
const SAFE_CLEARANCE_METERS := 20.0
const RISK_ZONE_Y := SHIP_Y + 1.2
const RISK_ZONE_HEIGHT := 0.18
const RISK_ZONE_BASE_RADIUS := 20.0
const TEMPORARY_BOX_HEIGHT := 8.0
const WORLD_UNIT_TO_NAUTICAL_MILES := 1.0 / 1852.0
const KNOTS_PER_MPS := 1.943844
const REFERENCE_PROPULSION_POWER_KW := 180.0
const REFERENCE_SPEED_KNOTS := 12.0
const HOTEL_LOAD_KW := 12.0
const SPECIFIC_FUEL_CONSUMPTION_KG_PER_KWH := 0.205
const CO2_TONS_PER_FUEL_TON := 3.114

@export var request_file_path: String = DEFAULT_REQUEST_FILE_PATH
@export var result_file_path: String = DEFAULT_RESULT_FILE_PATH
@export var auto_poll_request_file: bool = true
@export var poll_interval_seconds: float = 1.0
@export var validation_duration_seconds: float = 2.0
@export var show_risk_zones: bool = true
@export var build_temporary_obstacles: bool = true
@export var finalize_immediately_in_headless: bool = true
@export var fleet_manager_path: NodePath = NodePath("../ShipFleetManager")
@export var player_path: NodePath = NodePath("../Player")
@export var route_system_path: NodePath = NodePath("../ShipRouteSystem")
@export var obstacle_system_path: NodePath = NodePath("../ShipNavigationObstacles")

var _fleet_manager: Node
var _player: Node3D
var _route_system: Node
var _obstacle_system: Node
var _poll_elapsed := 0.0
var _last_request_signature := ""
var _active_request: Dictionary = {}
var _active_ship: Node3D
var _validation_scene_root: Node3D
var _validation_elapsed := 0.0
var _start_position := Vector3.ZERO
var _collision_count := 0
var _grounding_count := 0
var _last_collision_active := false
var _min_clearance_meters := 1.0e9
var _route_points: Array[Vector3] = []
var _risk_zone_count := 0
var _temporary_obstacle_count := 0
var _obstacle_snapshot: Dictionary = {}


func _ready() -> void:
	add_to_group(&"malacca_validation_bridge")
	process_mode = Node.PROCESS_MODE_ALWAYS
	_resolve_targets()
	_ensure_validation_scene_root()
	set_process(true)
	if auto_poll_request_file:
		_poll_request_file.call_deferred(true)


func _process(delta: float) -> void:
	if auto_poll_request_file:
		_poll_elapsed += delta
		if _poll_elapsed >= maxf(poll_interval_seconds, 0.1):
			_poll_elapsed = 0.0
			_poll_request_file(false)

	if not _active_request.is_empty():
		_update_active_validation(delta)


func process_validation_request(path: String = "") -> Dictionary:
	var source_path := path if not path.is_empty() else request_file_path
	if not FileAccess.file_exists(source_path):
		var missing_result := _failure_result({}, "未找到外部验证请求文件：%s" % source_path)
		_write_validation_result(missing_result)
		return missing_result

	var file := FileAccess.open(source_path, FileAccess.READ)
	if file == null:
		var open_result := _failure_result({}, "无法读取外部验证请求文件：%s" % source_path)
		_write_validation_result(open_result)
		return open_result

	var raw_payload := file.get_as_text()
	file.close()
	return process_validation_payload(raw_payload)


func process_validation_payload(raw_payload: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(raw_payload)
	if not parsed is Dictionary:
		var invalid_result := _failure_result({}, "外部验证请求不是有效 JSON 对象")
		_write_validation_result(invalid_result)
		return invalid_result

	var request := parsed as Dictionary
	validation_request_received.emit(request)
	return apply_validation_request(request)


func apply_validation_request(request: Dictionary) -> Dictionary:
	_resolve_targets()
	if not _active_request.is_empty():
		_clear_active_validation()
	_reset_validation_scene()

	var ship := _find_or_create_ship(request)
	if ship == null:
		var no_ship_result := _failure_result(request, "无法找到或创建验证船舶")
		_write_validation_result(no_ship_result)
		return no_ship_result

	_active_request = request.duplicate(true)
	_active_ship = ship
	_validation_elapsed = 0.0
	_start_position = ship.global_position
	_collision_count = 0
	_grounding_count = 0
	_last_collision_active = false
	_min_clearance_meters = 1.0e9

	_route_points = _apply_route_from_request(request, ship)
	_load_validation_scene_from_request(request, ship, _route_points)
	_apply_speed_from_request(request, ship)
	_min_clearance_meters = _estimate_min_clearance(ship.global_position)
	set_process(true)

	var running_result := _build_validation_result(request, ship, "running", false)
	_write_validation_result(running_result)
	if _should_finalize_immediately():
		_complete_immediate_validation.call_deferred()
	return running_result


func _poll_request_file(force: bool) -> void:
	if not FileAccess.file_exists(request_file_path):
		return

	_resolve_targets()
	var file := FileAccess.open(request_file_path, FileAccess.READ)
	if file == null:
		return

	var raw_payload := file.get_as_text()
	file.close()
	var signature := "%s:%d" % [request_file_path, raw_payload.hash()]
	if not force and signature == _last_request_signature:
		return

	_last_request_signature = signature
	process_validation_payload(raw_payload)


func _update_active_validation(delta: float) -> void:
	if _active_ship == null or not is_instance_valid(_active_ship):
		var lost_result := _failure_result(_active_request, "验证过程中船舶节点失效")
		_write_validation_result(lost_result)
		_clear_active_validation()
		return

	_validation_elapsed += delta
	var telemetry := _get_ship_telemetry(_active_ship)
	var collision_active := bool(telemetry.get("collision_warning_active", false))
	if collision_active and not _last_collision_active:
		_collision_count += 1
	_last_collision_active = collision_active
	_min_clearance_meters = minf(_min_clearance_meters, _estimate_min_clearance(_active_ship.global_position))

	if _validation_elapsed < maxf(validation_duration_seconds, 0.2):
		return

	var status := _resolve_final_status()
	var final_result := _build_validation_result(_active_request, _active_ship, status, true)
	_write_validation_result(final_result)
	_clear_active_validation()


func _complete_immediate_validation() -> void:
	if _active_request.is_empty() or _active_ship == null or not is_instance_valid(_active_ship):
		return

	_validation_elapsed = maxf(_validation_elapsed, validation_duration_seconds)
	_min_clearance_meters = minf(_min_clearance_meters, _estimate_min_clearance(_active_ship.global_position))
	var status := _resolve_final_status()
	var final_result := _build_validation_result(_active_request, _active_ship, status, true)
	_write_validation_result(final_result)
	_clear_active_validation()


func _should_finalize_immediately() -> bool:
	if not finalize_immediately_in_headless:
		return false
	return DisplayServer.get_name() == "headless"


func _clear_active_validation() -> void:
	_restore_obstacle_snapshot()
	_active_request.clear()
	_active_ship = null
	_validation_elapsed = 0.0
	_last_collision_active = false


func _reset_validation_scene() -> void:
	_restore_obstacle_snapshot()
	_route_points.clear()
	_risk_zone_count = 0
	_temporary_obstacle_count = 0

	var root := _ensure_validation_scene_root()
	if root == null:
		return

	for child in root.get_children():
		root.remove_child(child)
		child.queue_free()


func _ensure_validation_scene_root() -> Node3D:
	if _validation_scene_root != null and is_instance_valid(_validation_scene_root):
		return _validation_scene_root

	_validation_scene_root = Node3D.new()
	_validation_scene_root.name = "GeneratedMalaccaValidationScene"
	add_child(_validation_scene_root)
	return _validation_scene_root


func _find_or_create_ship(request: Dictionary) -> Node3D:
	var vessel_id := _string_value(request, "vesselId", "malacca_external_ship")
	var ship := _find_ship_by_agent_id(vessel_id)
	var spawn_position := _validation_start_position(request)
	var heading_degrees := _float_value(request, "headingDeg", 0.0)

	if ship == null and _fleet_manager != null and _fleet_manager.has_method("spawn_ship_at"):
		var speed_profile := _dictionary_value(request, "speedProfile")
		var spawn_config := {
			"agent_id": vessel_id,
			"max_forward_speed": _float_value(speed_profile, "maxSafeKnots", 18.0)
		}
		var created: Variant = _fleet_manager.call("spawn_ship_at", spawn_position, spawn_config)
		if created is Node3D:
			ship = created as Node3D

	if ship == null:
		ship = _player

	if ship == null:
		return null

	_set_node_property_if_exists(ship, "ship_agent_id", StringName(vessel_id))
	_set_node_property_if_exists(ship, "selectable_ship_agent", true)

	if _fleet_manager != null and _fleet_manager.has_method("take_control_of_ship"):
		_fleet_manager.call("take_control_of_ship", ship)

	if ship.has_method("set_ship_navigation_spawn"):
		ship.call("set_ship_navigation_spawn", spawn_position, heading_degrees)
	else:
		ship.global_position = spawn_position

	if ship.has_method("apply_ship_performance_config"):
		var speed_profile := _dictionary_value(request, "speedProfile")
		var max_safe_knots := _float_value(speed_profile, "maxSafeKnots", 18.0)
		ship.call("apply_ship_performance_config", {"max_forward_speed": max_safe_knots})

	return ship


func _apply_route_from_request(request: Dictionary, ship: Node3D) -> Array[Vector3]:
	var start_position := ship.global_position
	var destination := _endpoint_to_world(_dictionary_value(request, "destination"), start_position + Vector3(96.0, 0.0, -96.0))
	var route_points: Array[Vector3] = [start_position, destination]
	if _route_system != null and _route_system.has_method("configure_route"):
		_route_system.call("configure_route", route_points, false, start_position)
	return route_points


func _load_validation_scene_from_request(request: Dictionary, ship: Node3D, route_points: Array[Vector3]) -> void:
	_apply_temporary_obstacles_from_request(request, route_points)
	_build_route_endpoint_markers(request, route_points)
	_build_risk_zones_from_request(request, route_points)


func _build_route_endpoint_markers(request: Dictionary, route_points: Array[Vector3]) -> void:
	if route_points.size() < 2:
		return

	var origin := _dictionary_value(request, "origin")
	var destination := _dictionary_value(request, "destination")
	_add_endpoint_marker("ValidationOrigin", route_points[0], _string_value(origin, "portName", "验证起点"), Color(0.22, 0.92, 0.62, 0.92))
	_add_endpoint_marker("ValidationDestination", route_points[route_points.size() - 1], _string_value(destination, "portName", "验证终点"), Color(0.26, 0.74, 1.0, 0.92))


func _add_endpoint_marker(marker_name: String, world_position: Vector3, label_text: String, color: Color) -> void:
	var root := _ensure_validation_scene_root()
	if root == null:
		return

	var marker := Node3D.new()
	marker.name = marker_name
	marker.position = Vector3(world_position.x, RISK_ZONE_Y + 0.5, world_position.z)
	root.add_child(marker)

	var base := MeshInstance3D.new()
	base.name = "MarkerBase"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 4.8
	mesh.bottom_radius = 4.8
	mesh.height = 0.8
	mesh.radial_segments = 32
	base.mesh = mesh
	base.material_override = _make_validation_material(Color(color.r, color.g, color.b, 0.5), true)
	marker.add_child(base)

	var label := Label3D.new()
	label.name = "MarkerLabel"
	label.text = label_text
	label.position = Vector3(0.0, 6.0, 0.0)
	label.font_size = 28
	label.modulate = color
	label.outline_size = 3
	label.outline_modulate = Color(0.0, 0.0, 0.0, 0.72)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	marker.add_child(label)


func _build_risk_zones_from_request(request: Dictionary, route_points: Array[Vector3]) -> void:
	if not show_risk_zones:
		return

	var risk_events := _array_value(request, "riskEvents")
	var total := risk_events.size()
	for index in range(total):
		var raw_event: Variant = risk_events[index]
		if not raw_event is Dictionary:
			continue

		var event := raw_event as Dictionary
		var position := _risk_event_position(index, total, route_points)
		var radius := _risk_event_radius(event)
		_add_risk_zone(event, position, radius)
		_risk_zone_count += 1


func _add_risk_zone(event: Dictionary, world_position: Vector3, radius: float) -> void:
	var root := _ensure_validation_scene_root()
	if root == null:
		return

	var zone := Node3D.new()
	zone.name = "RiskZone_%02d_%s" % [_risk_zone_count + 1, _sanitize_node_name(_string_value(event, "id", "event"))]
	zone.position = Vector3(world_position.x, RISK_ZONE_Y, world_position.z)
	zone.add_to_group(&"malacca_validation_risk_zone")
	root.add_child(zone)

	var disc := MeshInstance3D.new()
	disc.name = "RiskAreaDisc"
	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius = radius
	disc_mesh.bottom_radius = radius
	disc_mesh.height = RISK_ZONE_HEIGHT
	disc_mesh.radial_segments = 64
	disc.mesh = disc_mesh
	var color := _risk_event_color(event)
	disc.material_override = _make_validation_material(Color(color.r, color.g, color.b, 0.24), true)
	zone.add_child(disc)

	var label := Label3D.new()
	label.name = "RiskAreaLabel"
	label.text = "%s\n%s" % [
		_string_value(event, "label", "风险事件"),
		_string_value(event, "affectedArea", _string_value(event, "type", "risk"))
	]
	label.position = Vector3(0.0, 7.2, 0.0)
	label.font_size = 24
	label.modulate = Color(color.r, color.g, color.b, 0.96)
	label.outline_size = 3
	label.outline_modulate = Color(0.0, 0.0, 0.0, 0.78)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	zone.add_child(label)


func _apply_temporary_obstacles_from_request(request: Dictionary, route_points: Array[Vector3]) -> void:
	if not build_temporary_obstacles:
		return
	if _obstacle_system == null or not _obstacle_system.has_method("configure_navigation_area"):
		return

	var risk_events := _array_value(request, "riskEvents")
	if risk_events.is_empty():
		return

	var generated_rocks: Array[Vector3] = []
	var generated_boxes: Array[Dictionary] = []
	for index in range(risk_events.size()):
		var raw_event: Variant = risk_events[index]
		if raw_event is Dictionary:
			_temporary_obstacle_count += _append_temporary_obstacles_for_event(raw_event as Dictionary, index, risk_events.size(), route_points, generated_rocks, generated_boxes)

	if generated_rocks.is_empty() and generated_boxes.is_empty():
		return

	_obstacle_snapshot = _snapshot_obstacle_system()
	var next_rocks: Array[Vector3] = _duplicate_vector3_array(_obstacle_snapshot.get("rock_positions", []))
	var next_boxes: Array[Dictionary] = _duplicate_dictionary_array(_obstacle_snapshot.get("box_obstacles", []))
	next_rocks.append_array(generated_rocks)
	next_boxes.append_array(generated_boxes)
	var boundary_half_extent := _float_value(_obstacle_snapshot, "boundary_half_extent", 780.0)
	_obstacle_system.call("configure_navigation_area", boundary_half_extent, next_rocks, next_boxes)


func _append_temporary_obstacles_for_event(
	event: Dictionary,
	index: int,
	total: int,
	route_points: Array[Vector3],
	rocks: Array[Vector3],
	boxes: Array[Dictionary]
) -> int:
	var before_count := rocks.size() + boxes.size()
	var event_type := _string_value(event, "type", "manual-event")
	var severity_scale := _risk_severity_scale(event)
	var position := _risk_event_position(index, total, route_points)
	var direction := _route_direction(route_points)
	var side := _route_side_vector(direction)
	var color := _risk_event_color(event)

	match event_type:
		"channel-closure":
			boxes.append(_temporary_box(
				"MalaccaChannelClosure_%02d" % (index + 1),
				position,
				Vector3(34.0 * severity_scale, TEMPORARY_BOX_HEIGHT, 12.0 * severity_scale),
				color
			))
		"collision-risk":
			rocks.append(_xz_position(position + side * 13.5 * severity_scale))
			rocks.append(_xz_position(position - side * 13.5 * severity_scale))
		"port-paralysis":
			var port_position := route_points[route_points.size() - 1] if route_points.size() > 1 else position
			boxes.append(_temporary_box(
				"MalaccaPortParalysis_%02d" % (index + 1),
				port_position - direction * 18.0,
				Vector3(26.0 * severity_scale, TEMPORARY_BOX_HEIGHT, 18.0 * severity_scale),
				color
			))
		"extreme-weather":
			if _string_value(event, "severity", "warning") == "danger":
				boxes.append(_temporary_box(
					"MalaccaExtremeWeather_%02d" % (index + 1),
					position,
					Vector3(42.0, TEMPORARY_BOX_HEIGHT * 0.5, 24.0),
					color
				))
		_:
			pass

	return rocks.size() + boxes.size() - before_count


func _temporary_box(obstacle_name: String, world_position: Vector3, size: Vector3, color: Color) -> Dictionary:
	return {
		"name": obstacle_name,
		"position": Vector3(world_position.x, SHIP_Y, world_position.z),
		"size": size,
		"color": Color(color.r, color.g, color.b, 0.38)
	}


func _snapshot_obstacle_system() -> Dictionary:
	if _obstacle_system == null:
		return {}

	return {
		"boundary_half_extent": _float_from_variant(_obstacle_system.get("boundary_half_extent"), 780.0),
		"rock_positions": _duplicate_vector3_array(_obstacle_system.get("rock_positions")),
		"box_obstacles": _duplicate_dictionary_array(_obstacle_system.get("box_obstacles"))
	}


func _restore_obstacle_snapshot() -> void:
	if _obstacle_snapshot.is_empty():
		return

	if _obstacle_system != null and _obstacle_system.has_method("configure_navigation_area"):
		var restored_rocks := _duplicate_vector3_array(_obstacle_snapshot.get("rock_positions", []))
		var restored_boxes := _duplicate_dictionary_array(_obstacle_snapshot.get("box_obstacles", []))
		var boundary_half_extent := _float_value(_obstacle_snapshot, "boundary_half_extent", 780.0)
		_obstacle_system.call("configure_navigation_area", boundary_half_extent, restored_rocks, restored_boxes)

	_obstacle_snapshot.clear()


func _apply_speed_from_request(request: Dictionary, ship: Node3D) -> void:
	if ship == null or not ship.has_method("set_ship_agent_command"):
		return

	var speed_profile := _dictionary_value(request, "speedProfile")
	var target_knots := _float_value(speed_profile, "targetKnots", _float_value(speed_profile, "initialKnots", 8.0))
	var max_safe_knots := maxf(_float_value(speed_profile, "maxSafeKnots", 18.0), 0.1)
	var throttle := clampf(target_knots / max_safe_knots, -1.0, 1.0)
	ship.call("set_ship_agent_command", throttle, 0.0)


func _build_validation_result(request: Dictionary, ship: Node3D, status: String, final_result: bool) -> Dictionary:
	var telemetry := _get_ship_telemetry(ship)
	var route_telemetry := _get_route_telemetry(ship)
	var arrival_radius := _float_value(route_telemetry, "arrival_radius", 16.0)
	var destination_distance := _distance_to_validation_destination(ship, route_telemetry)
	var reached_destination := final_result and destination_distance <= arrival_radius
	var average_speed_knots := absf(_float_value(telemetry, "speed", 0.0)) * KNOTS_PER_MPS
	var risk_events := _array_value(request, "riskEvents")
	var resolved_count := _resolved_risk_count(risk_events, status)
	var risk_level := _resolve_risk_level(request, status)
	var recommended_speed := _recommended_speed_knots(request, status, risk_level)
	var estimated_travel_minutes := _estimate_travel_minutes(request, recommended_speed, risk_level, status)
	var delay_delta := _estimate_delay_delta_minutes(request, average_speed_knots)
	var carbon_delta := _estimate_carbon_delta_tons(request)
	return {
		"requestId": _string_value(request, "requestId", ""),
		"vesselId": _string_value(request, "vesselId", ""),
		"status": status,
		"safePass": _is_safe_pass(status),
		"estimatedTravelMinutes": snapped(estimated_travel_minutes, 0.01),
		"riskLevel": risk_level,
		"recommendedSpeedKnots": snapped(recommended_speed, 0.1),
		"simulatedDurationSeconds": snapped(_validation_elapsed, 0.01),
		"reachedDestination": reached_destination,
		"averageSpeedKnots": snapped(average_speed_knots, 0.01),
		"minClearanceMeters": snapped(_min_clearance_meters, 0.01),
		"collisionCount": _collision_count,
		"groundingCount": _grounding_count,
		"riskEventResolvedCount": resolved_count,
		"delayDeltaMinutes": snapped(delay_delta, 0.01),
		"carbonDeltaTons": snapped(carbon_delta, 0.0001),
		"carbonModel": {
			"name": "cubic_propulsion_sfoc_v1",
			"measured": false,
			"referencePropulsionPowerKw": REFERENCE_PROPULSION_POWER_KW,
			"referenceSpeedKnots": REFERENCE_SPEED_KNOTS,
			"hotelLoadKw": HOTEL_LOAD_KW,
			"specificFuelConsumptionKgPerKwh": SPECIFIC_FUEL_CONSUMPTION_KG_PER_KWH,
			"co2TonsPerFuelTon": CO2_TONS_PER_FUEL_TON,
		},
		"loadedScene": _loaded_scene_summary(),
		"summary": _result_summary(status, reached_destination, risk_events.size())
	}


func _write_validation_result(result: Dictionary) -> void:
	var file := FileAccess.open(result_file_path, FileAccess.WRITE)
	if file == null:
		push_warning("无法写入马六甲验证结果：%s" % result_file_path)
		return
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	validation_result_written.emit(result)


func _failure_result(request: Dictionary, reason: String) -> Dictionary:
	var risk_level := "critical"
	return {
		"requestId": _string_value(request, "requestId", ""),
		"vesselId": _string_value(request, "vesselId", ""),
		"status": "failed",
		"safePass": false,
		"estimatedTravelMinutes": 0.0,
		"riskLevel": risk_level,
		"recommendedSpeedKnots": snapped(_recommended_speed_knots(request, "failed", risk_level), 0.1),
		"simulatedDurationSeconds": snapped(_validation_elapsed, 0.01),
		"reachedDestination": false,
		"averageSpeedKnots": 0.0,
		"minClearanceMeters": 0.0,
		"collisionCount": _collision_count,
		"groundingCount": _grounding_count,
		"riskEventResolvedCount": 0,
		"delayDeltaMinutes": 0.0,
		"carbonDeltaTons": 0.0,
		"carbonModel": {
			"name": "cubic_propulsion_sfoc_v1",
			"measured": false,
			"referencePropulsionPowerKw": REFERENCE_PROPULSION_POWER_KW,
			"referenceSpeedKnots": REFERENCE_SPEED_KNOTS,
			"hotelLoadKw": HOTEL_LOAD_KW,
			"specificFuelConsumptionKgPerKwh": SPECIFIC_FUEL_CONSUMPTION_KG_PER_KWH,
			"co2TonsPerFuelTon": CO2_TONS_PER_FUEL_TON,
		},
		"loadedScene": _loaded_scene_summary(),
		"summary": reason
	}


func _resolve_final_status() -> String:
	if _collision_count > 0 or _grounding_count > 0 or _min_clearance_meters < 0.0:
		return "failed"
	if _min_clearance_meters < SAFE_CLEARANCE_METERS:
		return "degraded"
	return "passed"


func _is_safe_pass(status: String) -> bool:
	return (
		status == "passed" and
		_collision_count == 0 and
		_grounding_count == 0 and
		_min_clearance_meters >= SAFE_CLEARANCE_METERS
	)


func _result_summary(status: String, reached_destination: bool, risk_event_count: int) -> String:
	if status == "running":
		return "已接收 Web 外部参数，已加载 %d 段航线、%d 个风险区和 %d 个临时障碍，正在执行单船航行验证。" % [
			maxi(_route_points.size() - 1, 0),
			_risk_zone_count,
			_temporary_obstacle_count
		]
	if status == "failed":
		return "验证未通过：航行过程中出现碰撞、搁浅或安全间距不足。"
	if status == "degraded":
		return "验证降级通过：未发生碰撞，但安全间距偏低，需要继续限速或绕行。"
	if reached_destination:
		return "验证通过：船舶已抵达目标航段终点，风险事件处理数量 %d。" % risk_event_count
	return "验证通过：外部船舶参数已适配到 Godot，当前验证窗口内未触发碰撞或搁浅。"


func _find_ship_by_agent_id(agent_id: String) -> Node3D:
	if _fleet_manager != null and _fleet_manager.has_method("get_ship_records"):
		for ship in _fleet_manager.call("get_ship_records"):
			if ship is Node3D and _ship_agent_id(ship as Node3D) == agent_id:
				return ship as Node3D

	for node in get_tree().get_nodes_in_group(&"ship_agent"):
		if node is Node3D and _ship_agent_id(node as Node3D) == agent_id:
			return node as Node3D

	if _player != null and _ship_agent_id(_player) == agent_id:
		return _player

	return null


func _ship_agent_id(ship: Node3D) -> String:
	if ship == null:
		return ""
	if ship.has_method("get_ship_telemetry"):
		var telemetry := ship.call("get_ship_telemetry") as Dictionary
		return String(telemetry.get("agent_id", ""))
	var raw_value: Variant = ship.get("ship_agent_id")
	if raw_value == null:
		return ""
	return String(raw_value)


func _validation_start_position(request: Dictionary) -> Vector3:
	var origin := _endpoint_to_world(_dictionary_value(request, "origin"), Vector3.ZERO)
	var destination := _endpoint_to_world(_dictionary_value(request, "destination"), origin + Vector3(96.0, 0.0, -96.0))
	var progress := clampf(_float_value(request, "progressPercent", 0.0) / 100.0, 0.0, 1.0)
	return origin.lerp(destination, progress)


func _endpoint_to_world(endpoint: Dictionary, fallback: Vector3) -> Vector3:
	var geo := _dictionary_value(endpoint, "geo")
	if geo.is_empty():
		return Vector3(fallback.x, SHIP_Y, fallback.z)

	var lat := clampf(_float_value(geo, "lat", 0.0), GEO_LAT_MIN, GEO_LAT_MAX)
	var lon := clampf(_float_value(geo, "lon", 0.0), GEO_LON_MIN, GEO_LON_MAX)
	var lon_ratio := inverse_lerp(GEO_LON_MIN, GEO_LON_MAX, lon)
	var lat_ratio := inverse_lerp(GEO_LAT_MIN, GEO_LAT_MAX, lat)
	var world_x := lerpf(WORLD_X_MIN, WORLD_X_MAX, lon_ratio)
	var world_z := lerpf(WORLD_Z_MAX, WORLD_Z_MIN, lat_ratio)
	return Vector3(world_x, SHIP_Y, world_z)


func _get_ship_telemetry(ship: Node3D) -> Dictionary:
	if ship != null and ship.has_method("get_ship_telemetry"):
		return ship.call("get_ship_telemetry") as Dictionary
	return {}


func _get_route_telemetry(ship: Node3D) -> Dictionary:
	if _route_system != null and _route_system.has_method("get_route_telemetry") and ship != null:
		return _route_system.call("get_route_telemetry", ship.global_position) as Dictionary
	return {}


func _distance_to_validation_destination(ship: Node3D, route_telemetry: Dictionary) -> float:
	if ship != null and _route_points.size() >= 2:
		var destination := _route_points[_route_points.size() - 1]
		return Vector2(ship.global_position.x, ship.global_position.z).distance_to(Vector2(destination.x, destination.z))
	return _float_value(route_telemetry, "current_distance", 0.0)


func _estimate_min_clearance(ship_position: Vector3) -> float:
	if _obstacle_system == null or not _obstacle_system.has_method("get_radar_obstacle_data"):
		return 9999.0

	var obstacle_data := _obstacle_system.call("get_radar_obstacle_data") as Dictionary
	var min_clearance := 9999.0
	for rock in _array_value(obstacle_data, "rocks"):
		if not rock is Dictionary:
			continue
		var rock_position := (rock as Dictionary).get("position", Vector3.ZERO) as Vector3
		var radius := _float_value(rock as Dictionary, "radius", 0.0)
		var distance := Vector2(ship_position.x, ship_position.z).distance_to(Vector2(rock_position.x, rock_position.z)) - radius
		min_clearance = minf(min_clearance, distance)

	for box in _array_value(obstacle_data, "boxes"):
		if not box is Dictionary:
			continue
		var box_position := (box as Dictionary).get("position", Vector3.ZERO) as Vector3
		var box_size := (box as Dictionary).get("size", Vector3.ONE) as Vector3
		var dx := absf(ship_position.x - box_position.x) - box_size.x * 0.5
		var dz := absf(ship_position.z - box_position.z) - box_size.z * 0.5
		var clearance := Vector2(maxf(dx, 0.0), maxf(dz, 0.0)).length()
		if dx < 0.0 and dz < 0.0:
			clearance = maxf(dx, dz)
		min_clearance = minf(min_clearance, clearance)

	return min_clearance


func _resolved_risk_count(risk_events: Array, status: String) -> int:
	if status == "failed" or status == "running":
		return 0
	var resolved := 0
	for raw_event in risk_events:
		if raw_event is Dictionary and bool((raw_event as Dictionary).get("resolved", false)):
			resolved += 1
	return resolved


func _estimate_delay_delta_minutes(request: Dictionary, average_speed_knots: float) -> float:
	var speed_profile := _dictionary_value(request, "speedProfile")
	var target_knots := _float_value(speed_profile, "targetKnots", average_speed_knots)
	if target_knots <= 0.0:
		return 0.0
	var effective_speed := average_speed_knots
	if effective_speed <= 0.1:
		effective_speed = _float_value(speed_profile, "initialKnots", target_knots)
	var distance_nm := maxf(_route_distance_world_units() * WORLD_UNIT_TO_NAUTICAL_MILES, 0.0)
	return snapped((distance_nm / maxf(effective_speed, 0.1) - distance_nm / target_knots) * 60.0, 0.01)


func _estimate_carbon_delta_tons(request: Dictionary) -> float:
	var speed_profile := _dictionary_value(request, "speedProfile")
	var initial_knots := _float_value(speed_profile, "initialKnots", 0.0)
	var target_knots := _float_value(speed_profile, "targetKnots", initial_knots)
	var distance_nm := maxf(_route_distance_world_units() * WORLD_UNIT_TO_NAUTICAL_MILES, 0.0)
	var initial_carbon := _estimated_carbon_tons(distance_nm, initial_knots)
	var target_carbon := _estimated_carbon_tons(distance_nm, target_knots)
	return snapped(target_carbon - initial_carbon, 0.0001)


func _estimated_carbon_tons(distance_nm: float, speed_knots: float) -> float:
	if distance_nm <= 0.0 or speed_knots <= 0.1:
		return 0.0
	var voyage_hours := distance_nm / speed_knots
	var speed_factor := pow(speed_knots / REFERENCE_SPEED_KNOTS, 3.0)
	var power_kw := HOTEL_LOAD_KW + REFERENCE_PROPULSION_POWER_KW * speed_factor
	var fuel_tons := power_kw * voyage_hours * SPECIFIC_FUEL_CONSUMPTION_KG_PER_KWH / 1000.0
	return fuel_tons * CO2_TONS_PER_FUEL_TON


func _resolve_risk_level(request: Dictionary, status: String) -> String:
	if status == "failed":
		return "critical"

	var score := 0.0
	if status == "degraded":
		score += 2.0
	if _min_clearance_meters < SAFE_CLEARANCE_METERS:
		score += 2.0
	elif _min_clearance_meters < SAFE_CLEARANCE_METERS * 1.5:
		score += 1.0

	score += float(_temporary_obstacle_count) * 0.5

	for raw_event in _array_value(request, "riskEvents"):
		if not raw_event is Dictionary:
			continue
		var event := raw_event as Dictionary
		match _string_value(event, "severity", "warning"):
			"danger":
				score += 2.0
			"warning":
				score += 1.0
			_:
				score += 0.25

		match _string_value(event, "type", "manual-event"):
			"channel-closure", "port-paralysis":
				score += 0.75
			"collision-risk", "extreme-weather":
				score += 0.5
			_:
				pass

	if score >= 5.0:
		return "critical"
	if score >= 3.0:
		return "high"
	if score >= 1.2:
		return "medium"
	return "low"


func _recommended_speed_knots(request: Dictionary, status: String, risk_level: String) -> float:
	var speed_profile := _dictionary_value(request, "speedProfile")
	var initial_knots := _float_value(speed_profile, "initialKnots", 12.0)
	var target_knots := _float_value(speed_profile, "targetKnots", initial_knots)
	var min_safe_knots := maxf(_float_value(speed_profile, "minSafeKnots", 6.0), 0.1)
	var max_safe_knots := maxf(_float_value(speed_profile, "maxSafeKnots", maxf(initial_knots, target_knots)), min_safe_knots)
	var recommended := target_knots

	match risk_level:
		"critical":
			recommended = min_safe_knots
		"high":
			recommended = minf(target_knots, maxf(min_safe_knots, initial_knots * 0.72))
		"medium":
			recommended = minf(target_knots, maxf(min_safe_knots, initial_knots * 0.86))
		_:
			recommended = target_knots

	if status == "failed":
		recommended = min_safe_knots
	elif status == "degraded":
		recommended = minf(recommended, maxf(min_safe_knots, target_knots * 0.85))

	return clampf(recommended, min_safe_knots, max_safe_knots)


func _estimate_travel_minutes(request: Dictionary, recommended_speed_knots: float, risk_level: String, status: String) -> float:
	var distance_nm := maxf(_route_distance_world_units() * WORLD_UNIT_TO_NAUTICAL_MILES, 0.2)
	var base_minutes := (distance_nm / maxf(recommended_speed_knots, 0.1)) * 60.0
	var risk_delay_minutes := _estimate_risk_delay_minutes(request, risk_level, status)
	return maxf(base_minutes + risk_delay_minutes, validation_duration_seconds / 60.0)


func _estimate_risk_delay_minutes(request: Dictionary, risk_level: String, status: String) -> float:
	var delay_minutes := float(_temporary_obstacle_count) * 4.0
	for raw_event in _array_value(request, "riskEvents"):
		if not raw_event is Dictionary:
			continue
		var event := raw_event as Dictionary
		var duration := _float_value(event, "expectedDurationMinutes", 0.0)
		var weight := 0.03
		match _string_value(event, "severity", "warning"):
			"danger":
				weight = 0.12
			"warning":
				weight = 0.07
			_:
				weight = 0.03
		delay_minutes += minf(duration * weight, 45.0)

	match risk_level:
		"critical":
			delay_minutes += 20.0
		"high":
			delay_minutes += 8.0
		"medium":
			delay_minutes += 4.0
		_:
			pass

	if status == "failed":
		delay_minutes += 20.0
	elif status == "degraded":
		delay_minutes += 6.0

	return delay_minutes


func _route_distance_world_units() -> float:
	if _route_points.size() < 2:
		return 0.0

	var distance := 0.0
	for index in range(1, _route_points.size()):
		var previous := _route_points[index - 1]
		var current := _route_points[index]
		distance += Vector2(previous.x, previous.z).distance_to(Vector2(current.x, current.z))
	return distance


func _loaded_scene_summary() -> Dictionary:
	return {
		"routePointCount": _route_points.size(),
		"riskZoneCount": _risk_zone_count,
		"temporaryObstacleCount": _temporary_obstacle_count
	}


func _risk_event_position(index: int, total: int, route_points: Array[Vector3]) -> Vector3:
	if route_points.size() >= 2:
		var start_position := route_points[0]
		var end_position := route_points[route_points.size() - 1]
		var t := float(index + 1) / float(total + 1)
		var direction := _route_direction(route_points)
		var side := _route_side_vector(direction)
		var side_offset := (-1.0 if index % 2 == 0 else 1.0) * 8.0
		return start_position.lerp(end_position, t) + side * side_offset

	if _active_ship != null and is_instance_valid(_active_ship):
		return _active_ship.global_position + Vector3(float(index) * 12.0, 0.0, -42.0)

	return Vector3(float(index) * 12.0, SHIP_Y, -42.0)


func _risk_event_radius(event: Dictionary) -> float:
	var event_type := _string_value(event, "type", "manual-event")
	var radius := RISK_ZONE_BASE_RADIUS * _risk_severity_scale(event)
	match event_type:
		"channel-closure":
			radius += 10.0
		"extreme-weather":
			radius += 18.0
		"port-paralysis":
			radius += 8.0
		"energy-control":
			radius += 5.0
		_:
			pass
	return radius


func _risk_severity_scale(event: Dictionary) -> float:
	match _string_value(event, "severity", "warning"):
		"danger":
			return 1.35
		"warning":
			return 1.0
		_:
			return 0.78


func _risk_event_color(event: Dictionary) -> Color:
	match _string_value(event, "severity", "warning"):
		"danger":
			return Color(1.0, 0.24, 0.16, 0.94)
		"warning":
			return Color(1.0, 0.72, 0.18, 0.9)
		_:
			return Color(0.18, 0.86, 1.0, 0.86)


func _route_direction(route_points: Array[Vector3]) -> Vector3:
	if route_points.size() >= 2:
		var direction := route_points[route_points.size() - 1] - route_points[0]
		direction.y = 0.0
		if direction.length() > 0.01:
			return direction.normalized()
	return Vector3.FORWARD


func _route_side_vector(direction: Vector3) -> Vector3:
	var side := Vector3(-direction.z, 0.0, direction.x)
	if side.length() <= 0.01:
		return Vector3.RIGHT
	return side.normalized()


func _xz_position(world_position: Vector3) -> Vector3:
	return Vector3(world_position.x, 0.0, world_position.z)


func _make_validation_material(color: Color, transparent: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


func _duplicate_vector3_array(source: Variant) -> Array[Vector3]:
	var output: Array[Vector3] = []
	if not source is Array:
		return output

	for value in source as Array:
		if value is Vector3:
			output.append(value as Vector3)
	return output


func _duplicate_dictionary_array(source: Variant) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	if not source is Array:
		return output

	for value in source as Array:
		if value is Dictionary:
			output.append((value as Dictionary).duplicate(true))
	return output


func _sanitize_node_name(raw_value: String) -> String:
	var safe := raw_value
	safe = safe.replace(" ", "_")
	safe = safe.replace("-", "_")
	safe = safe.replace(":", "_")
	safe = safe.replace("/", "_")
	return safe


func _resolve_targets() -> void:
	_fleet_manager = get_node_or_null(fleet_manager_path)
	if _fleet_manager == null:
		_fleet_manager = get_tree().get_first_node_in_group(&"ship_fleet_manager")

	var found_player := get_node_or_null(player_path)
	if found_player == null:
		found_player = get_tree().get_first_node_in_group(&"player")
	if found_player is Node3D:
		_player = found_player as Node3D

	_route_system = get_node_or_null(route_system_path)
	if _route_system == null:
		_route_system = get_tree().get_first_node_in_group(&"ship_route_system")

	_obstacle_system = get_node_or_null(obstacle_system_path)
	if _obstacle_system == null:
		_obstacle_system = get_tree().get_first_node_in_group(&"ship_navigation_obstacle_system")


func _set_node_property_if_exists(node: Object, property_name: String, value: Variant) -> void:
	for property in node.get_property_list():
		if String(property.get("name", "")) == property_name:
			node.set(property_name, value)
			return


func _dictionary_value(source: Dictionary, key: String) -> Dictionary:
	var value: Variant = source.get(key, {})
	if value is Dictionary:
		return value as Dictionary
	return {}


func _array_value(source: Dictionary, key: String) -> Array:
	var value: Variant = source.get(key, [])
	if value is Array:
		return value as Array
	return []


func _string_value(source: Dictionary, key: String, fallback: String) -> String:
	var value: Variant = source.get(key, fallback)
	if value == null:
		return fallback
	return String(value)


func _float_value(source: Dictionary, key: String, fallback: float) -> float:
	var value: Variant = source.get(key, fallback)
	return _float_from_variant(value, fallback)


func _float_from_variant(value: Variant, fallback: float) -> float:
	if value == null:
		return fallback
	if value is int or value is float:
		return float(value)
	var text := String(value)
	if text.is_valid_float():
		return text.to_float()
	return fallback

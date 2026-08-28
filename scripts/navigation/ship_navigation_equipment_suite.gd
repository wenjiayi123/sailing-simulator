extends Node
class_name ShipNavigationEquipmentSuite

## Research-grade bridge equipment model.
##
## This node turns scene truth into bounded radar measurements, ARPA tracks,
## ECDIS route-monitoring alarms and conning data.  It deliberately models
## sensor settings, weather clutter, measurement error and injected faults
## instead of presenting the scene's exact coordinates as a certified radar or
## official chart.  It never commands the vessel or changes a policy.

const KNOTS_PER_MPS := 1.943844
const METERS_PER_NAUTICAL_MILE := 1852.0
const RADAR_RANGES_NM := [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]
const REFRESH_INTERVAL := 0.25
const MAX_ARPA_TCPA_SECONDS := 1800.0

@export var player_path: NodePath = NodePath("../Player")
@export var route_system_path: NodePath = NodePath("../ShipRouteSystem")
@export var obstacle_system_path: NodePath = NodePath("../ShipNavigationObstacles")
@export var fleet_manager_path: NodePath = NodePath("../ShipFleetManager")
@export var weather_time_path: NodePath = NodePath("../ShipWeatherTimeController")
@export var ais_panel_path: NodePath = NodePath("../ShipAISFleetPanel")

var radar_range_index := 2
var radar_gain := 0.72
var sea_clutter_rejection := 0.35
var rain_clutter_rejection := 0.28
var radar_orientation := "HEAD_UP"
var vector_minutes := 6.0
var safety_contour_meters := 10.0
var safety_depth_meters := 5.0
var chart_layers := {
	"route": true,
	"hazards": true,
	"ais": true,
	"safety_contour": true,
}

var _player: Node3D
var _route_system: Node
var _obstacle_system: Node
var _fleet_manager: Node
var _weather_time: Node
var _ais_panel: Node
var _refresh_timer := 0.0
var _scan_index := 0
var _elapsed_seconds := 0.0
var _acquired_tracks: Dictionary = {}
var _track_memory: Dictionary = {}
var _snapshot: Dictionary = {}
var _acknowledged_alarm_ids: Dictionary = {}
var _frozen_gnss_position := Vector3.ZERO
var _faults := {
	"radar_power_loss": false,
	"radar_range_bias_m": 0.0,
	"radar_bearing_bias_deg": 0.0,
	"gyro_bias_deg": 0.0,
	"gnss_frozen": false,
	"ais_loss": false,
	"speed_log_loss": false,
	"rudder_feedback_loss": false,
	"depth_sensor_loss": false,
}


func _ready() -> void:
	add_to_group(&"ship_navigation_equipment_suite")
	_resolve_sources()
	_refresh_snapshot()
	set_process(true)


func _process(delta: float) -> void:
	_elapsed_seconds += delta
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_INTERVAL
		_refresh_snapshot()


func _resolve_sources() -> void:
	_player = get_node_or_null(player_path) as Node3D
	_route_system = get_node_or_null(route_system_path)
	_obstacle_system = get_node_or_null(obstacle_system_path)
	_fleet_manager = get_node_or_null(fleet_manager_path)
	_weather_time = get_node_or_null(weather_time_path)
	_ais_panel = get_node_or_null(ais_panel_path)
	if _player != null:
		_frozen_gnss_position = _player.global_position


func get_bridge_snapshot() -> Dictionary:
	return _snapshot.duplicate(true)


func force_refresh() -> Dictionary:
	_refresh_snapshot()
	return get_bridge_snapshot()


func set_radar_range_index(index: int) -> void:
	radar_range_index = clampi(index, 0, RADAR_RANGES_NM.size() - 1)
	_refresh_snapshot()


func step_radar_range(direction: int) -> void:
	set_radar_range_index(radar_range_index + signi(direction))


func set_radar_gain(value: float) -> void:
	radar_gain = clampf(value, 0.0, 1.0)
	_refresh_snapshot()


func set_sea_clutter_rejection(value: float) -> void:
	sea_clutter_rejection = clampf(value, 0.0, 1.0)
	_refresh_snapshot()


func set_rain_clutter_rejection(value: float) -> void:
	rain_clutter_rejection = clampf(value, 0.0, 1.0)
	_refresh_snapshot()


func cycle_radar_orientation() -> String:
	var modes := ["HEAD_UP", "NORTH_UP", "COURSE_UP"]
	var index := modes.find(radar_orientation)
	radar_orientation = modes[(index + 1) % modes.size()]
	_refresh_snapshot()
	return radar_orientation


func set_vector_minutes(value: float) -> void:
	vector_minutes = clampf(value, 1.0, 30.0)


func acquire_nearest_contact() -> Dictionary:
	var contacts: Array = _snapshot.get("radar", {}).get("contacts", [])
	if contacts.is_empty():
		return {"accepted": false, "reason": "NO_RADAR_CONTACT"}
	var nearest := contacts[0] as Dictionary
	for raw_contact in contacts:
		var contact := raw_contact as Dictionary
		if float(contact.get("range_meters", INF)) < float(nearest.get("range_meters", INF)):
			nearest = contact
	var contact_id := String(nearest.get("id", ""))
	if contact_id.is_empty():
		return {"accepted": false, "reason": "INVALID_CONTACT"}
	_acquired_tracks[contact_id] = true
	_refresh_snapshot()
	return {"accepted": true, "contact_id": contact_id, "label": nearest.get("label", contact_id)}


func drop_all_arpa_tracks() -> void:
	_acquired_tracks.clear()
	_track_memory.clear()
	_refresh_snapshot()


func set_safety_contour(value: float) -> void:
	safety_contour_meters = clampf(value, 1.0, 50.0)
	_refresh_snapshot()


func set_safety_depth(value: float) -> void:
	safety_depth_meters = clampf(value, 1.0, 30.0)
	_refresh_snapshot()


func set_chart_layer(layer_name: String, enabled: bool) -> void:
	if chart_layers.has(layer_name):
		chart_layers[layer_name] = enabled
		_refresh_snapshot()


func acknowledge_navigation_alarms() -> void:
	for raw_alarm in _snapshot.get("ecdis", {}).get("alarms", []) as Array:
		var alarm := raw_alarm as Dictionary
		_acknowledged_alarm_ids[String(alarm.get("id", ""))] = true
	_refresh_snapshot()


func set_equipment_fault(fault_name: String, value: Variant) -> bool:
	if not _faults.has(fault_name):
		return false
	_faults[fault_name] = value
	if fault_name == "gnss_frozen" and bool(value) and _player != null:
		_frozen_gnss_position = _player.global_position
	_refresh_snapshot()
	return true


func clear_equipment_faults() -> void:
	for key in _faults.keys():
		_faults[key] = 0.0 if String(key).ends_with("_m") or String(key).ends_with("_deg") else false
	_refresh_snapshot()


func get_fault_state() -> Dictionary:
	return _faults.duplicate(true)


func get_simulator_sensor_truth_frame() -> Dictionary:
	## Explicit simulator-only source for independently modeled sensor channels.
	## The returned truth frame must never be labelled as a physical measurement.
	if _player == null or not is_instance_valid(_player):
		_resolve_sources()
	if _player == null:
		return {
			"available": false,
			"source_mode": "SIMULATOR_TRUTH_INTERNAL",
			"hardware_verified": false,
		}
	var telemetry: Dictionary = {}
	if _player.has_method("get_ship_telemetry"):
		telemetry = _player.call("get_ship_telemetry") as Dictionary
	var heading := fposmod(float(telemetry.get("heading_degrees", 0.0)), 360.0)
	var course := fposmod(float(telemetry.get("course_degrees", heading)), 360.0)
	var speed_mps := absf(float(telemetry.get("speed", 0.0)))
	var ownship := {
		"available": true,
		"position": _player.global_position,
		"heading_degrees": heading,
		"course_degrees": course,
		"speed_mps": speed_mps,
		"velocity_xz_mps": _velocity_from_course(course, speed_mps),
	}
	return {
		"available": true,
		"simulation_time_seconds": _elapsed_seconds,
		"ownship": ownship,
		"contacts": _collect_truth_contacts(ownship, true),
		"weather": _weather_snapshot(),
		"source_mode": "SIMULATOR_TRUTH_INTERNAL",
		"hardware_verified": false,
		"boundary": "internal truth used only to generate declared simulated sensor measurements",
	}


func _refresh_snapshot() -> void:
	if _player == null or not is_instance_valid(_player):
		_resolve_sources()
	_scan_index += 1
	var ownship := _ownship_snapshot()
	var truth_contacts := _collect_truth_contacts(ownship)
	var radar := _build_radar_snapshot(ownship, truth_contacts)
	var ecdis := _build_ecdis_snapshot(ownship, truth_contacts)
	_snapshot = {
		"format": "ship_integrated_bridge_snapshot_v1",
		"generated_at_simulation_seconds": _elapsed_seconds,
		"ownship": ownship,
		"radar": radar,
		"ecdis": ecdis,
		"conning": _build_conning_snapshot(ownship),
		"faults": _faults.duplicate(true),
		"production_authority": false,
		"official_navigation_product": false,
		"boundary": "research simulator equipment model; not type-approved radar, ECDIS or live-vessel authority",
	}


func _ownship_snapshot() -> Dictionary:
	if _player == null:
		return {"available": false}
	var telemetry: Dictionary = {}
	if _player.has_method("get_ship_telemetry"):
		telemetry = _player.call("get_ship_telemetry") as Dictionary
	var true_position := _player.global_position
	var position := _frozen_gnss_position if bool(_faults["gnss_frozen"]) else true_position
	var heading := fposmod(float(telemetry.get("heading_degrees", 0.0)) + float(_faults["gyro_bias_deg"]), 360.0)
	var course := fposmod(float(telemetry.get("course_degrees", heading)) + float(_faults["gyro_bias_deg"]), 360.0)
	var speed_mps := absf(float(telemetry.get("speed", 0.0)))
	var velocity := _velocity_from_course(course, speed_mps)
	return {
		"available": true,
		"position": position,
		"true_position": true_position,
		"gnss_valid": not bool(_faults["gnss_frozen"]),
		"heading_degrees": heading,
		"course_degrees": course,
		"speed_mps": speed_mps,
		"speed_knots": speed_mps * KNOTS_PER_MPS,
		"velocity_xz_mps": velocity,
		"rudder": null if bool(_faults["rudder_feedback_loss"]) else telemetry.get("rudder", 0.0),
		"throttle": telemetry.get("throttle", 0.0),
		"speed_log_valid": not bool(_faults["speed_log_loss"]),
		"control_mode": "RL" if bool(telemetry.get("external_agent_control_enabled", false)) else "HUMAN",
		"collision_warning": telemetry.get("collision_warning", "CLEAR"),
		"drift_angle_degrees": telemetry.get("drift_angle_degrees", 0.0),
	}


func _collect_truth_contacts(ownship: Dictionary, include_ais_during_fault: bool = false) -> Array[Dictionary]:
	var contacts: Array[Dictionary] = []
	var known_ids: Dictionary = {}
	if _obstacle_system != null and _obstacle_system.has_method("get_radar_obstacle_data"):
		var radar_data := _obstacle_system.call("get_radar_obstacle_data") as Dictionary
		for raw_rock in radar_data.get("rocks", []) as Array:
			var rock := raw_rock as Dictionary
			var rock_id := "STATIC_ROCK::" + String(rock.get("name", contacts.size()))
			contacts.append(_truth_contact(rock_id, String(rock.get("name", "ROCK")), rock.get("position", Vector3.ZERO), Vector2.ZERO, "STATIC", maxf(float(rock.get("radius", 6.0)), 4.0)))
			known_ids[rock_id] = true
		for raw_box in radar_data.get("boxes", []) as Array:
			var box := raw_box as Dictionary
			var box_id := "STATIC_BOX::" + String(box.get("name", contacts.size()))
			var size_3d := box.get("size", Vector3.ONE) as Vector3
			contacts.append(_truth_contact(box_id, String(box.get("name", "HAZARD")), box.get("position", Vector3.ZERO), Vector2.ZERO, String(box.get("kind", "STATIC")).to_upper(), maxf(size_3d.x, size_3d.z) * 0.25))
			known_ids[box_id] = true
	if _fleet_manager != null and _fleet_manager.has_method("get_ship_records"):
		for raw_ship in _fleet_manager.call("get_ship_records") as Array:
			if raw_ship is not Node3D:
				continue
			var ship := raw_ship as Node3D
			if ship == _player:
				continue
			var telemetry: Dictionary = {}
			if ship.has_method("get_ship_telemetry"):
				telemetry = ship.call("get_ship_telemetry") as Dictionary
			var speed := absf(float(telemetry.get("speed", 0.0)))
			var course := float(telemetry.get("course_degrees", telemetry.get("heading_degrees", 0.0)))
			var ship_id := "SIM_SHIP::" + String(telemetry.get("agent_id", ship.name))
			contacts.append(_truth_contact(ship_id, String(telemetry.get("agent_id", ship.name)), ship.global_position, _velocity_from_course(course, speed), "VESSEL", 18.0))
			known_ids[ship_id] = true
	if (include_ais_during_fault or not bool(_faults["ais_loss"])) and _ais_panel != null and _ais_panel.has_method("get_equipment_ais_records"):
		for raw_record in _ais_panel.call("get_equipment_ais_records") as Array:
			var record := raw_record as Dictionary
			var record_id := "AIS::" + String(record.get("name", contacts.size()))
			if known_ids.has(record_id):
				continue
			var speed_mps := float(record.get("speed_knots", 0.0)) / KNOTS_PER_MPS
			contacts.append(_truth_contact(record_id, String(record.get("name", "AIS TARGET")), record.get("position", Vector3.ZERO), _velocity_from_course(float(record.get("heading", 0.0)), speed_mps), "AIS_HISTORY", 14.0))
	return contacts


func _truth_contact(contact_id: String, label: String, position_value: Variant, velocity: Vector2, kind: String, radar_cross_section: float) -> Dictionary:
	var position := position_value as Vector3 if position_value is Vector3 else Vector3.ZERO
	return {
		"id": contact_id,
		"label": label,
		"position": position,
		"velocity_xz_mps": velocity,
		"kind": kind,
		"radar_cross_section": radar_cross_section,
	}


func _build_radar_snapshot(ownship: Dictionary, truth_contacts: Array[Dictionary]) -> Dictionary:
	var range_nm := float(RADAR_RANGES_NM[radar_range_index])
	var range_meters := range_nm * METERS_PER_NAUTICAL_MILE
	var weather := _weather_snapshot()
	var sea_state := float(weather.get("sea_state", 0.0))
	var precipitation := float(weather.get("precipitation", 0.0))
	var residual_sea_clutter := sea_state / 9.0 * (1.0 - sea_clutter_rejection)
	var residual_rain_clutter := precipitation * (1.0 - rain_clutter_rejection)
	var contacts: Array[Dictionary] = []
	if not bool(_faults["radar_power_loss"]) and bool(ownship.get("available", false)):
		var own_position := ownship.get("position", Vector3.ZERO) as Vector3
		for truth in truth_contacts:
			var relative := _xz(truth.get("position", Vector3.ZERO) as Vector3) - _xz(own_position)
			var true_range := relative.length()
			if true_range <= 1.0 or true_range > range_meters:
				continue
			var rcs := float(truth.get("radar_cross_section", 8.0))
			var normalized_range := true_range / maxf(range_meters, 1.0)
			var received_strength := radar_gain * minf(1.0, rcs / 18.0) / maxf(0.18, pow(normalized_range, 4.0))
			var threshold := 0.22 + residual_sea_clutter * 0.48 + residual_rain_clutter * 0.42
			if received_strength < threshold:
				continue
			var phase := float(abs(hash(String(truth.get("id", "")))) % 10000) * 0.001 + float(_scan_index) * 0.37
			var range_error := sin(phase) * (1.8 + residual_sea_clutter * 8.0 + residual_rain_clutter * 6.0) + float(_faults["radar_range_bias_m"])
			var bearing_error := cos(phase * 0.73) * (0.18 + residual_sea_clutter * 1.1 + residual_rain_clutter * 0.8) + float(_faults["radar_bearing_bias_deg"])
			var true_bearing := _bearing_from_relative(relative)
			var measured_range := maxf(0.0, true_range + range_error)
			var measured_bearing := fposmod(true_bearing + bearing_error, 360.0)
			var measured_position := _xz(own_position) + _velocity_from_course(measured_bearing, measured_range)
			var contact := _radar_contact_record(truth, ownship, measured_position, measured_range, measured_bearing, received_strength)
			contacts.append(contact)
	contacts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["range_meters"]) < float(b["range_meters"]))
	var false_echo_count := 0 if bool(_faults["radar_power_loss"]) else int(round((residual_sea_clutter * 5.0 + residual_rain_clutter * 4.0) * range_nm))
	return {
		"power": not bool(_faults["radar_power_loss"]),
		"range_nm": range_nm,
		"gain": radar_gain,
		"sea_clutter_rejection": sea_clutter_rejection,
		"rain_clutter_rejection": rain_clutter_rejection,
		"orientation": radar_orientation,
		"scan_index": _scan_index,
		"sweep_degrees": fposmod(float(_scan_index) * 19.0, 360.0),
		"contacts": contacts,
		"detected_contact_count": contacts.size(),
		"acquired_track_count": contacts.filter(func(item: Dictionary) -> bool: return bool(item.get("arpa_acquired", false))).size(),
		"false_echo_count": false_echo_count,
		"weather_clutter": {"sea": residual_sea_clutter, "rain": residual_rain_clutter},
		"limitations_modeled": ["range", "gain", "sea_clutter", "rain_clutter", "measurement_error", "power_and_bias_faults"],
		"type_approved": false,
		"boundary": "bounded scene-driven radar/ARPA model; not raw RF radar video or IMO type approval",
	}


func _radar_contact_record(truth: Dictionary, ownship: Dictionary, measured_position: Vector2, measured_range: float, measured_bearing: float, strength: float) -> Dictionary:
	var contact_id := String(truth.get("id", ""))
	var previous := _track_memory.get(contact_id, {}) as Dictionary
	var velocity := truth.get("velocity_xz_mps", Vector2.ZERO) as Vector2
	if not previous.is_empty():
		var elapsed := maxf(_elapsed_seconds - float(previous.get("time", _elapsed_seconds)), REFRESH_INTERVAL)
		var measured_velocity := (measured_position - (previous.get("position", measured_position) as Vector2)) / elapsed
		velocity = (previous.get("velocity", velocity) as Vector2).lerp(measured_velocity, 0.35)
	_track_memory[contact_id] = {"position": measured_position, "velocity": velocity, "time": _elapsed_seconds}
	var acquired := _acquired_tracks.has(contact_id)
	var cpa := {"tcpa_seconds": null, "dcpa_meters": null, "risk": "UNTRACKED"}
	if acquired:
		var own_position := _xz(ownship.get("position", Vector3.ZERO) as Vector3)
		var own_velocity := ownship.get("velocity_xz_mps", Vector2.ZERO) as Vector2
		cpa = compute_cpa_tcpa(measured_position - own_position, velocity - own_velocity)
	return {
		"id": contact_id,
		"label": truth.get("label", contact_id),
		"kind": truth.get("kind", "UNKNOWN"),
		"range_meters": measured_range,
		"range_nm": measured_range / METERS_PER_NAUTICAL_MILE,
		"bearing_degrees": measured_bearing,
		"measured_position_xz": measured_position,
		"relative_position_xz": _velocity_from_course(measured_bearing, measured_range),
		"velocity_xz_mps": velocity,
		"speed_knots": velocity.length() * KNOTS_PER_MPS,
		"course_degrees": _bearing_from_relative(velocity),
		"signal_strength": strength,
		"arpa_acquired": acquired,
		"tcpa_seconds": cpa.get("tcpa_seconds"),
		"dcpa_meters": cpa.get("dcpa_meters"),
		"risk": cpa.get("risk", "UNTRACKED"),
	}


static func compute_cpa_tcpa(relative_position: Vector2, relative_velocity: Vector2) -> Dictionary:
	var speed_squared := relative_velocity.length_squared()
	if speed_squared <= 0.000001:
		return {"tcpa_seconds": MAX_ARPA_TCPA_SECONDS, "dcpa_meters": relative_position.length(), "risk": "STATIONARY_RELATIVE"}
	var raw_tcpa := -relative_position.dot(relative_velocity) / speed_squared
	var tcpa := MAX_ARPA_TCPA_SECONDS if raw_tcpa <= 0.0 else minf(raw_tcpa, MAX_ARPA_TCPA_SECONDS)
	var dcpa := (relative_position + relative_velocity * tcpa).length()
	var risk := "CLEAR"
	if raw_tcpa > 0.0 and tcpa <= 300.0 and dcpa < 32.0:
		risk = "DANGER"
	elif raw_tcpa > 0.0 and tcpa <= 600.0 and dcpa < 80.0:
		risk = "CAUTION"
	return {"tcpa_seconds": tcpa, "dcpa_meters": dcpa, "risk": risk}


func _build_ecdis_snapshot(ownship: Dictionary, truth_contacts: Array[Dictionary]) -> Dictionary:
	var route_data: Dictionary = {"active": false, "points": []}
	if _route_system != null and _route_system.has_method("get_radar_route_data"):
		route_data = _route_system.call("get_radar_route_data") as Dictionary
	var hazards := _chart_hazards()
	var route_alarms := _route_check_alarms(route_data.get("points", []) as Array, hazards)
	var alarms: Array[Dictionary] = []
	for alarm in route_alarms:
		var record := (alarm as Dictionary).duplicate(true)
		record["acknowledged"] = _acknowledged_alarm_ids.has(String(record.get("id", "")))
		alarms.append(record)
	if bool(_faults["gnss_frozen"]):
		alarms.append(_alarm("GNSS_FROZEN", "GNSS位置冻结，电子海图船位不可信", "DANGER"))
	if bool(_faults["depth_sensor_loss"]):
		alarms.append(_alarm("DEPTH_SENSOR_LOSS", "测深输入不可用", "CAUTION"))
	var active_unacknowledged := alarms.filter(func(item: Dictionary) -> bool: return not bool(item.get("acknowledged", false))).size()
	return {
		"chart_source": "project port profile + research ENC/GeoJSON-derived hazards",
		"chart_standard": "research_vector_chart_v1",
		"official_chart": false,
		"s100_ready": false,
		"safety_contour_meters": safety_contour_meters,
		"safety_depth_meters": safety_depth_meters,
		"depth_sensor_valid": not bool(_faults["depth_sensor_loss"]),
		"layers": chart_layers.duplicate(true),
		"route": route_data,
		"hazards": hazards,
		"ais_targets": [] if bool(_faults["ais_loss"]) else truth_contacts.filter(func(item: Dictionary) -> bool: return String(item.get("kind", "")) in ["VESSEL", "AIS_HISTORY"]),
		"alarms": alarms,
		"active_unacknowledged_alarm_count": active_unacknowledged,
		"route_check_passed": route_alarms.is_empty(),
		"update_service_connected": false,
		"boundary": "research route monitoring; not an official, corrected or type-approved ECDIS",
	}


func _chart_hazards() -> Array[Dictionary]:
	var hazards: Array[Dictionary] = []
	if _obstacle_system == null or not _obstacle_system.has_method("get_radar_obstacle_data"):
		return hazards
	var data := _obstacle_system.call("get_radar_obstacle_data") as Dictionary
	for raw_rock in data.get("rocks", []) as Array:
		var rock := raw_rock as Dictionary
		hazards.append({"id": "ROCK::" + String(rock.get("name", hazards.size())), "name": rock.get("name", "ROCK"), "shape": "circle", "position": rock.get("position", Vector3.ZERO), "radius": float(rock.get("radius", 5.0)), "category": rock.get("kind", "rock")})
	for raw_box in data.get("boxes", []) as Array:
		var box := raw_box as Dictionary
		hazards.append({"id": "BOX::" + String(box.get("name", hazards.size())), "name": box.get("name", "HAZARD"), "shape": "box", "position": box.get("position", Vector3.ZERO), "size": box.get("size", Vector3.ONE), "category": box.get("kind", "obstacle")})
	return hazards


func _route_check_alarms(raw_points: Array, hazards: Array[Dictionary]) -> Array[Dictionary]:
	var points: Array[Vector2] = []
	for raw in raw_points:
		if raw is Dictionary:
			points.append(_xz((raw as Dictionary).get("position", Vector3.ZERO) as Vector3))
	var alarms: Array[Dictionary] = []
	if points.size() < 2:
		return alarms
	for leg_index in range(points.size() - 1):
		var start := points[leg_index]
		var finish := points[leg_index + 1]
		for hazard in hazards:
			var center := _xz(hazard.get("position", Vector3.ZERO) as Vector3)
			var radius := float(hazard.get("radius", 0.0))
			if String(hazard.get("shape", "")) == "box":
				var size_3d := hazard.get("size", Vector3.ONE) as Vector3
				radius = 0.5 * Vector2(size_3d.x, size_3d.z).length()
			var clearance := _distance_point_to_segment(center, start, finish) - radius - 5.0
			if clearance < 0.0:
				var alarm_id := "ROUTE_HAZARD::%d::%s" % [leg_index + 1, String(hazard.get("id", "UNKNOWN"))]
				alarms.append(_alarm(alarm_id, "航段 %d 与 %s 安全包络相交" % [leg_index + 1, String(hazard.get("name", "危险物"))], "DANGER"))
				if alarms.size() >= 12:
					return alarms
	return alarms


func _build_conning_snapshot(ownship: Dictionary) -> Dictionary:
	var route_telemetry: Dictionary = {"active": false}
	if _route_system != null and _route_system.has_method("get_route_telemetry") and bool(ownship.get("available", false)):
		route_telemetry = _route_system.call("get_route_telemetry", ownship.get("position", Vector3.ZERO)) as Dictionary
	return {
		"heading_degrees": ownship.get("heading_degrees"),
		"course_degrees": ownship.get("course_degrees"),
		"speed_knots": null if bool(_faults["speed_log_loss"]) else ownship.get("speed_knots"),
		"rudder": ownship.get("rudder"),
		"throttle": ownship.get("throttle"),
		"drift_angle_degrees": ownship.get("drift_angle_degrees"),
		"control_mode": ownship.get("control_mode", "UNKNOWN"),
		"route": route_telemetry,
		"sensor_validity": {
			"gnss": ownship.get("gnss_valid", false),
			"gyro": absf(float(_faults["gyro_bias_deg"])) < 0.001,
			"speed_log": not bool(_faults["speed_log_loss"]),
			"rudder_feedback": not bool(_faults["rudder_feedback_loss"]),
		},
		"boundary": "conning replica driven by simulator telemetry; not a type-approved integrated bridge display",
	}


func _weather_snapshot() -> Dictionary:
	if _weather_time != null and _weather_time.has_method("get_weather_time_status"):
		var status := _weather_time.call("get_weather_time_status") as Dictionary
		var weather_name := String(status.get("weather", "")).to_lower()
		var precipitation := 0.0
		if weather_name.contains("rain") or weather_name.contains("雨"):
			precipitation = 0.65
		elif weather_name.contains("storm") or weather_name.contains("暴"):
			precipitation = 1.0
		return {"sea_state": status.get("sea_state", 0.0), "precipitation": precipitation, "source": status}
	return {"sea_state": 0.0, "precipitation": 0.0, "source": {}}


func _alarm(alarm_id: String, message: String, severity: String) -> Dictionary:
	return {"id": alarm_id, "message": message, "severity": severity, "acknowledged": _acknowledged_alarm_ids.has(alarm_id)}


static func _distance_point_to_segment(point: Vector2, start: Vector2, finish: Vector2) -> float:
	var segment := finish - start
	if segment.length_squared() <= 0.000001:
		return point.distance_to(start)
	var ratio := clampf((point - start).dot(segment) / segment.length_squared(), 0.0, 1.0)
	return point.distance_to(start + segment * ratio)


static func _velocity_from_course(course_degrees: float, magnitude: float) -> Vector2:
	var angle := deg_to_rad(course_degrees)
	return Vector2(sin(angle), cos(angle)) * magnitude


static func _bearing_from_relative(relative: Vector2) -> float:
	if relative.length_squared() <= 0.000001:
		return 0.0
	return fposmod(rad_to_deg(atan2(relative.x, relative.y)), 360.0)


static func _xz(position: Vector3) -> Vector2:
	return Vector2(position.x, position.z)

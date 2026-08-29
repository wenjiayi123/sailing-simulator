extends Node

class_name ShipWeatherTimeController

signal weather_time_changed(status: Dictionary)

const CYCLE_KEY := KEY_T
const MODE_KEYS := {
	KEY_1: 0,
	KEY_2: 1,
	KEY_3: 2,
	KEY_4: 3
}

const MODES := [
	{
		"key": "clear",
		"name": "晴天",
		"weather": "CLEAR SKY",
		"time": "10:20",
		"visibility": "20 km",
		"background": Color(0.48, 0.82, 1.0, 1.0),
		"ambient": Color(0.86, 0.93, 1.0, 1.0),
		"ambient_energy": 0.92,
		"fog": false,
		"fog_color": Color(0.70, 0.91, 1.0, 1.0),
		"fog_density": 0.000,
		"sun_color": Color(1.0, 0.94, 0.78, 1.0),
		"sun_energy": 1.18,
		"sun_rotation": Vector3(-52.0, -36.0, 0.0),
		"overlay": Color(0.10, 0.42, 0.78, 0.00),
		"sea_state": {"wind_speed_knots": 3.0, "wind_direction_degrees": 38.0, "wave_height_meters": 0.12, "wave_direction_degrees": 54.0, "wave_period_seconds": 5.5, "visibility_km": 20.0, "current_speed_knots": 0.1, "current_direction_degrees": 65.0, "tide_meters": 0.2, "time_scale": 1.0}
	},
	{
		"key": "mist",
		"name": "薄雾",
		"weather": "LIGHT MIST",
		"time": "07:40",
		"visibility": "2.5 km",
		"background": Color(0.62, 0.78, 0.84, 1.0),
		"ambient": Color(0.78, 0.88, 0.90, 1.0),
		"ambient_energy": 0.72,
		"fog": true,
		"fog_color": Color(0.70, 0.84, 0.86, 1.0),
		"fog_density": 0.022,
		"sun_color": Color(0.84, 0.93, 0.92, 1.0),
		"sun_energy": 0.72,
		"sun_rotation": Vector3(-30.0, -18.0, 0.0),
		"overlay": Color(0.70, 0.88, 0.90, 0.14),
		"sea_state": {"wind_speed_knots": 10.0, "wind_direction_degrees": 52.0, "wave_height_meters": 0.8, "wave_direction_degrees": 61.0, "wave_period_seconds": 6.2, "visibility_km": 2.5, "current_speed_knots": 0.7, "current_direction_degrees": 42.0, "tide_meters": 0.4, "time_scale": 1.0}
	},
	{
		"key": "dusk",
		"name": "黄昏",
		"weather": "DUSK GLOW",
		"time": "18:35",
		"visibility": "8 km",
		"background": Color(0.64, 0.35, 0.28, 1.0),
		"ambient": Color(0.58, 0.42, 0.55, 1.0),
		"ambient_energy": 0.58,
		"fog": true,
		"fog_color": Color(0.78, 0.46, 0.32, 1.0),
		"fog_density": 0.010,
		"sun_color": Color(1.0, 0.58, 0.26, 1.0),
		"sun_energy": 0.94,
		"sun_rotation": Vector3(-10.0, -62.0, 0.0),
		"overlay": Color(0.95, 0.38, 0.12, 0.12),
		"sea_state": {"wind_speed_knots": 14.0, "wind_direction_degrees": 88.0, "wave_height_meters": 1.2, "wave_direction_degrees": 96.0, "wave_period_seconds": 7.0, "visibility_km": 8.0, "current_speed_knots": 1.1, "current_direction_degrees": 102.0, "tide_meters": 0.7, "time_scale": 1.0}
	},
	{
		"key": "night",
		"name": "夜晚",
		"weather": "NIGHT OPS",
		"time": "22:30",
		"visibility": "4 km",
		"background": Color(0.015, 0.035, 0.095, 1.0),
		"ambient": Color(0.12, 0.22, 0.34, 1.0),
		"ambient_energy": 0.30,
		"fog": true,
		"fog_color": Color(0.05, 0.12, 0.22, 1.0),
		"fog_density": 0.014,
		"sun_color": Color(0.42, 0.58, 0.90, 1.0),
		"sun_energy": 0.22,
		"sun_rotation": Vector3(-72.0, 32.0, 0.0),
		"overlay": Color(0.0, 0.02, 0.12, 0.36),
		"sea_state": {"wind_speed_knots": 18.0, "wind_direction_degrees": 126.0, "wave_height_meters": 1.6, "wave_direction_degrees": 138.0, "wave_period_seconds": 7.8, "visibility_km": 4.0, "current_speed_knots": 1.4, "current_direction_degrees": 128.0, "tide_meters": 1.0, "time_scale": 1.0}
	}
]

@export var world_environment_path: NodePath = NodePath("../WorldEnvironment")
@export var directional_light_path: NodePath = NodePath("../DirectionalLight3D")
@export var water_surface_path: NodePath = NodePath("../NavigationEnvironment/BackgroundWalls/LakeSurfaceMotion")
@export_range(0, 3, 1) var start_mode_index: int = 0
@export_range(0.0, 60.0, 0.1) var wind_speed_knots: float = 3.0
@export_range(0.0, 359.0, 1.0) var wind_direction_degrees: float = 38.0
@export_range(0.0, 8.0, 0.1) var wave_height_meters: float = 0.12
@export_range(0.0, 359.0, 1.0) var wave_direction_degrees: float = 54.0
@export_range(1.0, 30.0, 0.1) var wave_period_seconds: float = 5.5
@export_range(0.1, 30.0, 0.1) var visibility_km: float = 20.0
@export_range(0.0, 8.0, 0.1) var current_speed_knots: float = 0.1
@export_range(0.0, 359.0, 1.0) var current_direction_degrees: float = 65.0
@export_range(-5.0, 5.0, 0.1) var tide_meters: float = 0.2
@export_range(0.0, 240.0, 1.0) var time_scale: float = 1.0
@export var public_weather_enabled: bool = true
@export var apply_public_weather_on_startup: bool = false
@export_range(-90.0, 90.0, 0.0001) var public_weather_latitude: float = 1.2644
@export_range(-180.0, 180.0, 0.0001) var public_weather_longitude: float = 103.8223
@export_file("*.json") var bundled_weather_cache_path: String = "res://data/public_cache/marine_weather_singapore.json"

var _world_environment: WorldEnvironment
var _environment: Environment
var _directional_light: DirectionalLight3D
var _water_surface: MeshInstance3D
var _water_surface_material: ShaderMaterial
var _overlay_layer: CanvasLayer
var _overlay_rect: ColorRect
var _mode_index := 0
var _simulated_minutes := 0.0
var _status_emit_timer := 0.0
var _atmosphere_request: HTTPRequest
var _marine_request: HTTPRequest
var _atmosphere_payload: Dictionary = {}
var _marine_payload: Dictionary = {}
var _data_source := "scenario_override"
var _data_observed_at := ""
var _data_fetched_at := ""
var _data_status := "fallback"


func _ready() -> void:
	add_to_group(&"ship_weather_time_system")
	_resolve_targets()
	_build_overlay()
	apply_mode(start_mode_index)
	if OS.get_environment("SHIP_CAPTURE_WEATHER") == "clear":
		public_weather_enabled = false
		set_process(true)
		set_process_unhandled_input(true)
		return
	if public_weather_enabled and apply_public_weather_on_startup:
		_load_public_weather_cache()
		_build_public_weather_requests()
		refresh_public_weather.call_deferred()
	set_process(true)
	set_process_unhandled_input(true)


func _process(delta: float) -> void:
	if time_scale > 0.0:
		_simulated_minutes = fposmod(_simulated_minutes + delta * time_scale / 60.0, 1440.0)
		_apply_time_of_day_lighting()
		_status_emit_timer -= delta
		if _status_emit_timer <= 0.0:
			_status_emit_timer = 0.5
			weather_time_changed.emit(get_weather_time_status())


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return
		if MODE_KEYS.has(key_event.physical_keycode):
			apply_mode(int(MODE_KEYS[key_event.physical_keycode]))
			get_viewport().set_input_as_handled()
		elif key_event.physical_keycode == CYCLE_KEY:
			apply_mode(_mode_index + 1)
			get_viewport().set_input_as_handled()


func apply_mode(index: int) -> void:
	_mode_index = wrapi(index, 0, MODES.size())
	var mode: Dictionary = MODES[_mode_index]
	if _environment == null or _directional_light == null:
		_resolve_targets()
	_simulated_minutes = _parse_clock_minutes(String(mode["time"]))
	_apply_mode_sea_state(mode)
	_data_source = "scenario_override"
	_data_observed_at = ""
	_data_status = "manual_scenario"

	if _environment != null:
		_environment.background_mode = Environment.BG_COLOR
		_environment.background_color = mode["background"] as Color
		_environment.ambient_light_color = mode["ambient"] as Color
		_environment.ambient_light_energy = float(mode["ambient_energy"])
		_environment.fog_light_color = mode["fog_color"] as Color

	if _directional_light != null:
		_directional_light.light_color = mode["sun_color"] as Color
		_directional_light.light_energy = float(mode["sun_energy"])
		_directional_light.rotation_degrees = mode["sun_rotation"] as Vector3

	_apply_sea_state_effects()
	_apply_time_of_day_lighting()

	weather_time_changed.emit(get_weather_time_status())


func cycle_mode() -> void:
	apply_mode(_mode_index + 1)


func get_weather_time_status() -> Dictionary:
	var mode: Dictionary = MODES[_mode_index]
	var fog_enabled := _environment != null and _environment.fog_enabled
	var fog_density := float(_environment.fog_density) if _environment != null else 0.0
	var overlay_alpha := float(_overlay_rect.color.a) if _overlay_rect != null else 0.0
	return {
		"index": _mode_index,
		"key": String(mode["key"]),
		"name": String(mode["name"]),
		"weather": String(mode["weather"]),
		"time": _format_clock(_simulated_minutes),
		"base_time": String(mode["time"]),
		"visibility": "%.1f km" % visibility_km,
		"visibility_km": visibility_km,
		"fog_enabled": fog_enabled,
		"fog_density": fog_density,
		"atmosphere_overlay_alpha": overlay_alpha,
		"zero_fog_visual": not fog_enabled and is_zero_approx(fog_density) and is_zero_approx(overlay_alpha),
		"wind_speed_knots": wind_speed_knots,
		"wind_direction_degrees": wind_direction_degrees,
		"wave_height_meters": wave_height_meters,
		"wave_direction_degrees": wave_direction_degrees,
		"wave_period_seconds": wave_period_seconds,
		"current_speed_knots": current_speed_knots,
		"current_direction_degrees": current_direction_degrees,
		"tide_meters": tide_meters,
		"time_scale": time_scale,
		"current_vector": get_current_vector_mps(),
		"sea_state_label": _sea_state_label(),
		"data_source": _data_source,
		"data_status": _data_status,
		"observed_at": _data_observed_at,
		"fetched_at": _data_fetched_at,
		"public_location": {"latitude": public_weather_latitude, "longitude": public_weather_longitude},
		"water_surface_visual": get_water_surface_visual_status(),
	}


func get_water_surface_visual_status() -> Dictionary:
	if _water_surface_material == null:
		return {"connected": false}
	return {
		"connected": true,
		"vertex_wave_height": float(_water_surface_material.get_shader_parameter("vertex_wave_height")),
		"wave_speed": float(_water_surface_material.get_shader_parameter("wave_speed")),
		"flow_direction": _water_surface_material.get_shader_parameter("flow_direction") as Vector2,
	}


func apply_sea_state(config: Dictionary) -> void:
	wind_speed_knots = clampf(float(config.get("wind_speed_knots", wind_speed_knots)), 0.0, 60.0)
	wind_direction_degrees = fposmod(float(config.get("wind_direction_degrees", wind_direction_degrees)), 360.0)
	wave_height_meters = clampf(float(config.get("wave_height_meters", wave_height_meters)), 0.0, 8.0)
	wave_direction_degrees = fposmod(float(config.get("wave_direction_degrees", wave_direction_degrees)), 360.0)
	wave_period_seconds = clampf(float(config.get("wave_period_seconds", wave_period_seconds)), 1.0, 30.0)
	visibility_km = clampf(float(config.get("visibility_km", visibility_km)), 0.1, 30.0)
	current_speed_knots = clampf(float(config.get("current_speed_knots", current_speed_knots)), 0.0, 8.0)
	current_direction_degrees = fposmod(float(config.get("current_direction_degrees", current_direction_degrees)), 360.0)
	tide_meters = clampf(float(config.get("tide_meters", tide_meters)), -5.0, 5.0)
	time_scale = clampf(float(config.get("time_scale", time_scale)), 0.0, 240.0)
	if config.has("time"):
		_simulated_minutes = _parse_clock_minutes(String(config["time"]))
	if not bool(config.get("preserve_source", false)):
		_data_source = "manual_override"
		_data_status = "manual"
		_data_observed_at = ""
	_apply_sea_state_effects()
	_apply_time_of_day_lighting()
	weather_time_changed.emit(get_weather_time_status())


func apply_zero_fog_clear_baseline(config: Dictionary = {}) -> void:
	# Scene entry is always a genuinely clear visual baseline. Mission-specific
	# wind, wave, current and tide remain active, while restricted visibility and
	# task time are opt-in weather changes rather than hidden entry haze.
	apply_mode(0)
	var clear_config := config.duplicate(true)
	clear_config.erase("visibility_km")
	clear_config.erase("time")
	clear_config.erase("time_scale")
	if not clear_config.is_empty():
		apply_sea_state(clear_config)
	visibility_km = 20.0
	_force_zero_fog_visual()
	_data_source = "scenario_clear_baseline"
	_data_status = "zero_fog_default"
	_data_observed_at = ""
	weather_time_changed.emit(get_weather_time_status())


func _force_zero_fog_visual() -> void:
	if _environment == null:
		_resolve_targets()
	if _environment != null:
		_environment.fog_enabled = false
		_environment.fog_density = 0.0
	if _overlay_rect != null:
		var clear_overlay := MODES[0]["overlay"] as Color
		clear_overlay.a = 0.0
		_overlay_rect.color = clear_overlay


func get_current_vector_mps() -> Vector3:
	var radians := deg_to_rad(current_direction_degrees)
	var speed_mps := current_speed_knots * 0.514444
	return Vector3(sin(radians), 0.0, cos(radians)) * speed_mps


func get_sea_state_status() -> Dictionary:
	return get_weather_time_status()


func refresh_public_weather() -> void:
	if not public_weather_enabled:
		return
	_build_public_weather_requests()
	if _atmosphere_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED \
	or _marine_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	_atmosphere_payload.clear()
	_marine_payload.clear()
	_data_status = "refreshing"
	var location := "latitude=%.4f&longitude=%.4f" % [public_weather_latitude, public_weather_longitude]
	var headers := PackedStringArray(["User-Agent: ship-simulator-open-data/1.0"])
	var atmosphere_url := "https://api.open-meteo.com/v1/forecast?%s&current=wind_speed_10m,wind_direction_10m,visibility&wind_speed_unit=kn&timezone=UTC&forecast_days=1" % location
	var marine_url := "https://marine-api.open-meteo.com/v1/marine?%s&hourly=wave_height,wave_direction,wave_period,ocean_current_velocity,ocean_current_direction,sea_surface_temperature&wind_speed_unit=kn&timezone=UTC&forecast_days=1" % location
	_atmosphere_request.request(atmosphere_url, headers)
	_marine_request.request(marine_url, headers)


func _build_public_weather_requests() -> void:
	if _atmosphere_request == null:
		_atmosphere_request = HTTPRequest.new()
		_atmosphere_request.name = "OpenMeteoAtmosphereRequest"
		add_child(_atmosphere_request)
		_atmosphere_request.request_completed.connect(_on_public_weather_response.bind("atmosphere"))
	if _marine_request == null:
		_marine_request = HTTPRequest.new()
		_marine_request.name = "OpenMeteoMarineRequest"
		add_child(_marine_request)
		_marine_request.request_completed.connect(_on_public_weather_response.bind("marine"))


func _on_public_weather_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, kind: String) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_data_status = "cache_fallback"
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if parsed is not Dictionary:
		_data_status = "cache_fallback"
		return
	if kind == "atmosphere":
		_atmosphere_payload = parsed as Dictionary
	else:
		_marine_payload = parsed as Dictionary
	if not _atmosphere_payload.is_empty() and not _marine_payload.is_empty():
		_apply_open_meteo_payloads(_atmosphere_payload, _marine_payload)


func _apply_open_meteo_payloads(atmosphere: Dictionary, marine: Dictionary) -> void:
	var current := atmosphere.get("current", {}) as Dictionary
	var hourly := marine.get("hourly", {}) as Dictionary
	var sea_state := {
		"wind_speed_knots": float(current.get("wind_speed_10m", wind_speed_knots)),
		"wind_direction_degrees": float(current.get("wind_direction_10m", wind_direction_degrees)),
		"visibility_km": float(current.get("visibility", visibility_km * 1000.0)) / 1000.0,
		"wave_height_meters": _first_hourly_value(hourly, "wave_height", wave_height_meters),
		"wave_direction_degrees": _first_hourly_value(hourly, "wave_direction", wave_direction_degrees),
		"wave_period_seconds": _first_hourly_value(hourly, "wave_period", wave_period_seconds),
		"current_speed_knots": _first_hourly_value(hourly, "ocean_current_velocity", current_speed_knots),
		"current_direction_degrees": _first_hourly_value(hourly, "ocean_current_direction", current_direction_degrees),
		"tide_meters": tide_meters,
		"time_scale": time_scale,
		"preserve_source": true,
	}
	_data_source = "Open-Meteo live · CC BY 4.0"
	_data_observed_at = String(current.get("time", ""))
	_data_fetched_at = Time.get_datetime_string_from_system(true, true)
	_data_status = "live"
	apply_sea_state(sea_state)
	_write_public_weather_cache(sea_state)


func _first_hourly_value(hourly: Dictionary, key: String, fallback: float) -> float:
	var values := hourly.get(key, []) as Array
	return float(values[0]) if not values.is_empty() else fallback


func _load_public_weather_cache() -> void:
	var candidates := [ProjectSettings.globalize_path("user://public_data/marine_weather_latest.json"), bundled_weather_cache_path]
	for path in candidates:
		if not FileAccess.file_exists(path):
			continue
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var parsed = JSON.parse_string(file.get_as_text())
		file.close()
		if parsed is not Dictionary:
			continue
		var payload := parsed as Dictionary
		var sea_state := payload.get("sea_state", {}) as Dictionary
		sea_state["preserve_source"] = true
		_data_source = "Open-Meteo cache · CC BY 4.0"
		_data_observed_at = String(payload.get("observed_at", ""))
		_data_fetched_at = String(payload.get("fetched_at", ""))
		_data_status = "cache"
		apply_sea_state(sea_state)
		return


func _write_public_weather_cache(sea_state: Dictionary) -> void:
	var path := ProjectSettings.globalize_path("user://public_data/marine_weather_latest.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"format": "ship_marine_weather_v1",
		"source": {"provider": "Open-Meteo", "license": "CC BY 4.0", "attribution": "Weather data by Open-Meteo.com"},
		"observed_at": _data_observed_at,
		"fetched_at": _data_fetched_at,
		"location": {"latitude": public_weather_latitude, "longitude": public_weather_longitude, "crs": "WGS84"},
		"sea_state": sea_state,
	}, "\t"))
	file.close()


func _resolve_targets() -> void:
	var environment_node := get_node_or_null(world_environment_path)
	if environment_node is WorldEnvironment:
		_world_environment = environment_node
		if _world_environment.environment == null:
			_world_environment.environment = Environment.new()
		else:
			_world_environment.environment = _world_environment.environment.duplicate()
		_environment = _world_environment.environment

	var light_node := get_node_or_null(directional_light_path)
	if light_node is DirectionalLight3D:
		_directional_light = light_node

	var surface_node := get_node_or_null(water_surface_path)
	if surface_node is MeshInstance3D:
		_water_surface = surface_node as MeshInstance3D
		if _water_surface_material == null:
			var active_material := _water_surface.get_active_material(0)
			if active_material is ShaderMaterial:
				_water_surface_material = active_material.duplicate() as ShaderMaterial
				_water_surface.set_surface_override_material(0, _water_surface_material)


func _build_overlay() -> void:
	if _overlay_layer != null:
		return
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "WeatherAtmosphereOverlay"
	_overlay_layer.layer = 5
	add_child(_overlay_layer)

	_overlay_rect = ColorRect.new()
	_overlay_rect.name = "AtmosphereTint"
	_overlay_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_layer.add_child(_overlay_rect)


func _apply_mode_sea_state(mode: Dictionary) -> void:
	var sea_state := mode.get("sea_state", {}) as Dictionary
	wind_speed_knots = float(sea_state.get("wind_speed_knots", wind_speed_knots))
	wind_direction_degrees = float(sea_state.get("wind_direction_degrees", wind_direction_degrees))
	wave_height_meters = float(sea_state.get("wave_height_meters", wave_height_meters))
	wave_direction_degrees = float(sea_state.get("wave_direction_degrees", wave_direction_degrees))
	wave_period_seconds = float(sea_state.get("wave_period_seconds", wave_period_seconds))
	visibility_km = float(sea_state.get("visibility_km", _parse_visibility_km(String(mode.get("visibility", "20 km")))))
	current_speed_knots = float(sea_state.get("current_speed_knots", current_speed_knots))
	current_direction_degrees = float(sea_state.get("current_direction_degrees", current_direction_degrees))
	tide_meters = float(sea_state.get("tide_meters", tide_meters))
	time_scale = float(sea_state.get("time_scale", time_scale))


func _apply_sea_state_effects() -> void:
	var mode: Dictionary = MODES[_mode_index]
	if _environment != null:
		var visibility_density := _visibility_to_fog_density(visibility_km)
		var wave_density := clampf(wave_height_meters / 8.0, 0.0, 1.0) * 0.004
		var fog_density := maxf(float(mode["fog_density"]), visibility_density + wave_density)
		_environment.fog_enabled = bool(mode["fog"]) or visibility_km < 18.0 or wave_height_meters > 1.8
		_environment.fog_light_color = mode["fog_color"] as Color
		_environment.fog_density = fog_density

	if _overlay_rect != null:
		var overlay := mode["overlay"] as Color
		var weather_alpha := clampf((12.0 - visibility_km) / 12.0, 0.0, 1.0) * 0.28
		var sea_alpha := clampf((wave_height_meters - 1.5) / 6.5, 0.0, 1.0) * 0.18
		overlay.a = clampf(overlay.a + weather_alpha + sea_alpha * 0.45, 0.0, 0.58)
		_overlay_rect.color = overlay

	_apply_water_surface_sea_state()


func _apply_water_surface_sea_state() -> void:
	if _water_surface_material == null:
		_resolve_targets()
	if _water_surface_material == null:
		return
	var visible_wave_height := clampf(0.03 + wave_height_meters * 0.16, 0.03, 0.75)
	var wave_factor := clampf(wave_height_meters / 2.5, 0.0, 1.0)
	var wave_direction := deg_to_rad(wave_direction_degrees)
	_water_surface_material.set_shader_parameter(
		"flow_direction",
		Vector2(sin(wave_direction), cos(wave_direction)).normalized()
	)
	_water_surface_material.set_shader_parameter("vertex_wave_height", visible_wave_height)
	_water_surface_material.set_shader_parameter("wave_speed", clampf(1.2 / wave_period_seconds, 0.05, 0.35))
	_water_surface_material.set_shader_parameter("directional_wave_strength", lerpf(0.16, 0.62, wave_factor))
	_water_surface_material.set_shader_parameter("distortion_strength", lerpf(0.006, 0.032, wave_factor))
	_water_surface_material.set_shader_parameter("normal_strength", lerpf(0.28, 0.92, wave_factor))


func _apply_time_of_day_lighting() -> void:
	if _directional_light == null:
		return
	var hour := _simulated_minutes / 60.0
	var sun_phase := sin((hour - 6.0) / 24.0 * TAU)
	var mode: Dictionary = MODES[_mode_index]
	var base_rotation := mode["sun_rotation"] as Vector3
	var base_energy := float(mode["sun_energy"])
	_directional_light.rotation_degrees = Vector3(
		clampf(base_rotation.x + sun_phase * 18.0, -78.0, -4.0),
		base_rotation.y,
		base_rotation.z
	)
	var night_factor := 1.0
	if hour < 5.5 or hour > 19.5:
		night_factor = 0.45
	elif hour < 7.0:
		night_factor = lerpf(0.45, 1.0, (hour - 5.5) / 1.5)
	elif hour > 18.0:
		night_factor = lerpf(1.0, 0.45, (hour - 18.0) / 1.5)
	_directional_light.light_energy = base_energy * night_factor


func _visibility_to_fog_density(value_km: float) -> float:
	if value_km >= 20.0:
		return 0.0
	# Convert meteorological optical range from kilometres to the exponential
	# extinction scale used by the renderer. The old 0.0-0.03 interpolation
	# treated kilometres like scene metres: a declared 12 km clear-weather range
	# became dense fog within a few hundred metres and erased task backdrops.
	var visibility_m := maxf(value_km * 1000.0, 100.0)
	return clampf(3.912 / visibility_m, 0.0, 0.040)


func _parse_visibility_km(text: String) -> float:
	var normalized := text.strip_edges().to_lower().replace("km", "").strip_edges()
	if normalized.is_valid_float():
		return float(normalized)
	return 20.0


func _parse_clock_minutes(text: String) -> float:
	var parts := text.split(":")
	if parts.size() < 2:
		return 0.0
	return float(clampi(int(parts[0]), 0, 23) * 60 + clampi(int(parts[1]), 0, 59))


func _format_clock(minutes_value: float) -> String:
	var whole_minutes := int(floor(fposmod(minutes_value, 1440.0)))
	var hours: int = whole_minutes / 60
	var minutes: int = whole_minutes % 60
	return "%02d:%02d" % [hours, minutes]


func _sea_state_label() -> String:
	if wave_height_meters >= 4.0 or wind_speed_knots >= 34.0:
		return "ROUGH SEA"
	if wave_height_meters >= 2.0 or wind_speed_knots >= 22.0:
		return "MODERATE"
	if wave_height_meters >= 0.8 or wind_speed_knots >= 12.0:
		return "LIGHT SEA"
	return "CALM"

extends Node

const MIX_RATE := 22050.0
const BUFFER_LENGTH := 0.18
const TAU_F := TAU

@export var player_path: NodePath = NodePath("../Player")
@export var weather_time_path: NodePath = NodePath("../ShipWeatherTimeController")
@export_range(0.0, 1.0, 0.01) var master_gain: float = 0.82
@export_range(0.0, 1.0, 0.01) var wind_gain: float = 0.38
@export_range(0.0, 1.0, 0.01) var water_gain: float = 0.54
@export_range(0.0, 1.0, 0.01) var engine_gain: float = 0.50
@export_range(0.0, 1.0, 0.01) var rudder_gain: float = 0.30

var _player: Node3D
var _weather_time_source: Node
var _players: Dictionary = {}
var _playbacks: Dictionary = {}
var _phase_engine := 0.0
var _phase_engine_harmonic := 0.0
var _phase_water := 0.0
var _phase_rudder := 0.0
var _phase_rudder_tick := 0.0
var _wind_noise := 0.0
var _water_noise := 0.0
var _water_last_noise := 0.0
var _engine_intensity := 0.0
var _water_intensity := 0.0
var _wind_intensity := 0.0
var _rudder_intensity := 0.0
var _speed_ratio := 0.0
var _throttle := 0.0
var _rudder := 0.0
var _weather_wind_factor := 0.0
var _weather_wave_factor := 0.0


func _ready() -> void:
	_resolve_player()
	_resolve_weather_time_source()
	_make_generator_player("wind", -10.5)
	_make_generator_player("water", -8.0)
	_make_generator_player("engine", -10.0)
	_make_generator_player("rudder", -14.0)
	set_process(true)


func _process(delta: float) -> void:
	if _player == null or not is_instance_valid(_player) or not _player.is_in_group(&"player"):
		_resolve_player()
	if _weather_time_source == null or not is_instance_valid(_weather_time_source):
		_resolve_weather_time_source()

	_update_motion_mix(delta)
	_fill_channel("wind")
	_fill_channel("water")
	_fill_channel("engine")
	_fill_channel("rudder")


func _exit_tree() -> void:
	for audio_player in _players.values():
		if audio_player is AudioStreamPlayer:
			var player := audio_player as AudioStreamPlayer
			player.stop()
			player.stream = null
	_players.clear()
	_playbacks.clear()


func _resolve_player() -> void:
	var found_player := get_tree().get_first_node_in_group(&"player")
	if found_player == null:
		found_player = get_node_or_null(player_path)
	if found_player is Node3D:
		_player = found_player


func _resolve_weather_time_source() -> void:
	_weather_time_source = get_node_or_null(weather_time_path)
	if _weather_time_source == null:
		_weather_time_source = get_tree().get_first_node_in_group(&"ship_weather_time_system")


func _make_generator_player(channel_name: String, volume_db: float) -> void:
	var audio_player := AudioStreamPlayer.new()
	audio_player.name = "%sAmbience" % channel_name.capitalize()
	audio_player.volume_db = volume_db
	audio_player.bus = &"Master"

	var generator := AudioStreamGenerator.new()
	generator.mix_rate = MIX_RATE
	generator.buffer_length = BUFFER_LENGTH
	audio_player.stream = generator
	add_child(audio_player)
	audio_player.play()

	_players[channel_name] = audio_player
	_playbacks[channel_name] = audio_player.get_stream_playback() as AudioStreamGeneratorPlayback


func _update_motion_mix(delta: float) -> void:
	var target_speed_ratio := 0.0
	var target_throttle := 0.0
	var target_rudder := 0.0

	if _player != null and _player.has_method("get_ship_telemetry"):
		var telemetry: Dictionary = _player.call("get_ship_telemetry")
		var signed_speed := absf(float(telemetry.get("speed", 0.0)))
		if _player is CharacterBody3D:
			var ship_body := _player as CharacterBody3D
			var horizontal_velocity := Vector3(ship_body.velocity.x, 0.0, ship_body.velocity.z)
			signed_speed = maxf(signed_speed, horizontal_velocity.length())
		var max_speed := maxf(float(telemetry.get("max_forward_speed", 1.0)), 0.001)
		target_speed_ratio = clampf(signed_speed / max_speed, 0.0, 1.35)
		target_throttle = absf(float(telemetry.get("throttle", 0.0)))
		target_rudder = absf(float(telemetry.get("rudder", 0.0)))

	_update_weather_mix()

	var alpha := _damping_alpha(2.8, delta)
	_speed_ratio = lerpf(_speed_ratio, target_speed_ratio, alpha)
	_throttle = lerpf(_throttle, target_throttle, alpha)
	_rudder = lerpf(_rudder, target_rudder, alpha)

	_engine_intensity = clampf(_speed_ratio * 0.62 + _throttle * 0.42, 0.0, 1.0)
	_water_intensity = clampf(_speed_ratio * 0.82 + _weather_wave_factor * 0.58, 0.0, 1.0)
	_wind_intensity = clampf(0.16 + _speed_ratio * 0.42 + _weather_wind_factor * 0.72, 0.0, 1.0)
	_rudder_intensity = clampf(_rudder * (0.18 + _speed_ratio * 0.82), 0.0, 1.0)


func _update_weather_mix() -> void:
	if _weather_time_source == null or not _weather_time_source.has_method("get_weather_time_status"):
		_weather_wind_factor = 0.0
		_weather_wave_factor = 0.0
		return
	var status: Dictionary = _weather_time_source.call("get_weather_time_status")
	_weather_wind_factor = clampf(float(status.get("wind_speed_knots", 0.0)) / 42.0, 0.0, 1.0)
	_weather_wave_factor = clampf(float(status.get("wave_height_meters", 0.0)) / 5.0, 0.0, 1.0)


func _fill_channel(channel_name: String) -> void:
	var playback := _playbacks.get(channel_name) as AudioStreamGeneratorPlayback
	if playback == null:
		return

	var frames_available := playback.get_frames_available()
	for _frame in range(frames_available):
		var sample := _sample_channel(channel_name)
		playback.push_frame(sample)


func _sample_channel(channel_name: String) -> Vector2:
	match channel_name:
		"wind":
			return _sample_wind()
		"water":
			return _sample_water()
		"engine":
			return _sample_engine()
		"rudder":
			return _sample_rudder()
	return Vector2.ZERO


func _sample_engine() -> Vector2:
	var frequency := 38.0 + _engine_intensity * 86.0 + _throttle * 18.0
	_phase_engine = fposmod(_phase_engine + TAU_F * frequency / MIX_RATE, TAU_F)
	_phase_engine_harmonic = fposmod(_phase_engine_harmonic + TAU_F * (frequency * 1.93) / MIX_RATE, TAU_F)
	var rumble := sin(_phase_engine) * 0.74 + sin(_phase_engine_harmonic) * 0.21
	var beat := sin(_phase_engine * 0.47) * 0.08
	var amplitude := master_gain * engine_gain * (0.08 + _engine_intensity * 0.36)
	var sample := (rumble + beat) * amplitude
	return Vector2(sample * 0.94, sample)


func _sample_water() -> Vector2:
	var noise := randf_range(-1.0, 1.0)
	_water_noise = lerpf(_water_noise, noise, 0.36)
	var splash := _water_noise - _water_last_noise
	_water_last_noise = _water_noise
	var wave_frequency := 0.7 + _water_intensity * 4.2 + _weather_wave_factor * 2.2
	_phase_water = fposmod(_phase_water + TAU_F * wave_frequency / MIX_RATE, TAU_F)
	var wave := sin(_phase_water) * 0.18 + sin(_phase_water * 2.7) * 0.06
	var amplitude := master_gain * water_gain * (0.05 + _water_intensity * 0.58 + _weather_wave_factor * 0.18)
	var sample := (splash * 1.65 + wave) * amplitude
	return Vector2(sample, sample * 0.86)


func _sample_wind() -> Vector2:
	var noise := randf_range(-1.0, 1.0)
	_wind_noise = lerpf(_wind_noise, noise, 0.018 + _speed_ratio * 0.010 + _weather_wind_factor * 0.012)
	var gust := 0.82 + sin(Time.get_ticks_msec() * (0.0017 + _weather_wind_factor * 0.0015)) * (0.18 + _weather_wind_factor * 0.18)
	var amplitude := master_gain * wind_gain * (0.10 + _wind_intensity * 0.32 + _weather_wind_factor * 0.18) * gust
	var sample := _wind_noise * amplitude
	return Vector2(sample * 0.82, sample)


func _sample_rudder() -> Vector2:
	if _rudder_intensity <= 0.015:
		return Vector2.ZERO
	var frequency := 210.0 + _rudder * 210.0 + _speed_ratio * 80.0
	_phase_rudder = fposmod(_phase_rudder + TAU_F * frequency / MIX_RATE, TAU_F)
	_phase_rudder_tick = fposmod(_phase_rudder_tick + TAU_F * (7.5 + _rudder * 11.0) / MIX_RATE, TAU_F)
	var servo := sin(_phase_rudder) * 0.72 + sin(_phase_rudder * 2.01) * 0.12
	var pulse := maxf(sin(_phase_rudder_tick), 0.0) * 0.22
	var amplitude := master_gain * rudder_gain * _rudder_intensity * 0.30
	var pan := clampf(_rudder, 0.0, 1.0) * 0.18
	return Vector2((servo + pulse) * amplitude * (1.0 - pan), (servo + pulse) * amplitude * (1.0 + pan))


func _damping_alpha(response: float, delta: float) -> float:
	if delta <= 0.0:
		return 1.0
	return clampf(1.0 - exp(-maxf(response, 0.0) * delta), 0.0, 1.0)

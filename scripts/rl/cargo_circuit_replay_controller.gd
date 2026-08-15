extends Node
class_name CargoCircuitReplayController

signal replay_started(status: Dictionary)
signal replay_finished(status: Dictionary)
signal replay_stopped

const WATER_LEVEL_Y := -140.73494
const RELEASE_TRAJECTORY := "res://reports/artifacts/cargo_circuit_rl_v1/cargo_policy_test_trajectory.json"
const DYNAMIC_RELEASE_TRAJECTORY := "res://reports/artifacts/cargo_circuit_dynamic_rl_v2/cargo_dynamic_policy_test_trajectory.json"
const MANUAL_FEASIBILITY_TRAJECTORY := "res://reports/artifacts/cargo_circuit_rl_v1/manual_feasibility_trajectory.json"
const CAMERA_MODE_AUTO_FOLLOW := "auto_follow"
const CAMERA_MODE_FREE := "free_camera"
const VISUAL_MODE_PROCEDURAL_USV := "procedural_usv"

@export var player_path: NodePath = NodePath("../Player")
@export var route_system_path: NodePath = NodePath("../ShipRouteSystem")
@export var obstacle_system_path: NodePath = NodePath("../ShipNavigationObstacles")
@export var playback_speed: float = 3.0

var _ship: Node3D
var _route_system: Node
var _obstacle_system: Node3D
var _trajectory: Dictionary = {}
var _samples: Array = []
var _sample_index := 0
var _elapsed := 0.0
var _active := false
var _world_prepared := false
var _mission_root: Node3D
var _dynamic_traffic_nodes: Dictionary = {}
var _original_ship: Dictionary = {}
var _original_route: Dictionary = {}
var _original_obstacles_visible := true
var _last_result: Dictionary = {}
var _replay_guard_blocks := 0
var _replay_camera_mode := CAMERA_MODE_AUTO_FOLLOW

var _hud_layer: CanvasLayer
var _hud_panel: PanelContainer
var _status_label: Label
var _checkpoint_label: Label
var _action_label: Label
var _safety_label: Label
var _progress_bar: ProgressBar


func _ready() -> void:
	add_to_group(&"cargo_circuit_replay_controller")
	_resolve_nodes()
	_build_hud()
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	if not _active:
		return
	if _ship == null or _samples.size() < 2:
		_finish(false, "回放对象或测试轨迹失效")
		return
	_elapsed += delta * maxf(playback_speed, 0.1)
	while _sample_index < _samples.size() - 2 and float((_samples[_sample_index + 1] as Dictionary).get("time", INF)) <= _elapsed:
		_sample_index += 1
	var current := _samples[_sample_index] as Dictionary
	var next := _samples[mini(_sample_index + 1, _samples.size() - 1)] as Dictionary
	var current_time := float(current.get("time", 0.0))
	var next_time := float(next.get("time", current_time))
	var alpha := clampf((_elapsed - current_time) / maxf(next_time - current_time, 0.0001), 0.0, 1.0)
	if not _apply_interpolated_state(current, next, alpha):
		return
	_update_hud(current, next, alpha)
	if _sample_index >= _samples.size() - 2 and _elapsed >= float(next.get("time", 0.0)):
		var metrics := _trajectory.get("evaluation_metrics", {}) as Dictionary
		_finish(bool(metrics.get("success", false)), "环图取货测试轨迹播放完成")


func start_replay(path_override: String = "") -> bool:
	if _world_prepared:
		stop_replay(true)
	var requested := path_override
	if requested.is_empty():
		requested = RELEASE_TRAJECTORY
	if not _load_trajectory(requested, false):
		_show_error("轨迹不可用或未通过测试门槛：%s" % ProjectSettings.globalize_path(requested))
		return false
	_resolve_nodes()
	if _ship == null or _route_system == null:
		_show_error("船或航线系统未就绪")
		return false
	_snapshot_world()
	_prepare_mission_world()
	var start := _trajectory.get("start", {}) as Dictionary
	var spawn := _point(start)
	var heading := float(start.get("heading_degrees", 0.0))
	if _ship.has_method("set_ship_human_control_enabled"):
		_ship.call("set_ship_human_control_enabled", false)
	if _ship.has_method("set_ship_navigation_spawn"):
		_ship.call("set_ship_navigation_spawn", spawn, heading)
	_apply_replay_presentation(true)
	_sample_index = 0
	_elapsed = 0.0
	_last_result.clear()
	_replay_guard_blocks = 0
	_active = true
	_hud_layer.visible = true
	replay_started.emit(get_replay_status())
	return true


func start_manual_feasibility_replay(path_override: String = "") -> bool:
	if _world_prepared:
		stop_replay(true)
	var requested := path_override if not path_override.is_empty() else MANUAL_FEASIBILITY_TRAJECTORY
	if not _load_trajectory(requested, true):
		_show_error("人工可达性轨迹不存在或未通过：%s" % ProjectSettings.globalize_path(requested))
		return false
	_resolve_nodes()
	if _ship == null or _route_system == null:
		_show_error("船或航线系统未就绪")
		return false
	_snapshot_world()
	_prepare_mission_world()
	var start := _trajectory.get("start", {}) as Dictionary
	if _ship.has_method("set_ship_human_control_enabled"):
		_ship.call("set_ship_human_control_enabled", false)
	if _ship.has_method("set_ship_navigation_spawn"):
		_ship.call("set_ship_navigation_spawn", _point(start), float(start.get("heading_degrees", 0.0)))
	_apply_replay_presentation(true)
	_sample_index = 0
	_elapsed = 0.0
	_last_result.clear()
	_replay_guard_blocks = 0
	_active = true
	_hud_layer.visible = true
	replay_started.emit(get_replay_status())
	return true


func start_dynamic_replay(path_override: String = "") -> bool:
	return start_replay(path_override if not path_override.is_empty() else DYNAMIC_RELEASE_TRAJECTORY)


func stop_replay(restore_world: bool = true) -> void:
	var was_active := _active
	_active = false
	if _ship != null and _ship.has_method("clear_ship_agent_command"):
		_ship.call("clear_ship_agent_command")
	if restore_world:
		_restore_world()
	if _hud_layer != null:
		_hud_layer.visible = false
	if was_active:
		replay_stopped.emit()


func set_playback_speed(value: float) -> void:
	playback_speed = clampf(value, 0.5, 8.0)


func set_replay_camera_mode(mode: String) -> void:
	_replay_camera_mode = CAMERA_MODE_FREE if mode == CAMERA_MODE_FREE else CAMERA_MODE_AUTO_FOLLOW
	if _active:
		_apply_replay_camera_mode(_replay_camera_mode == CAMERA_MODE_AUTO_FOLLOW)


func get_replay_presentation_status() -> Dictionary:
	return {
		"camera_mode": _replay_camera_mode,
		"camera_auto_follow": _replay_camera_mode == CAMERA_MODE_AUTO_FOLLOW,
		"visual_mode": VISUAL_MODE_PROCEDURAL_USV,
		"visual_label": "3D内置模组无人艇（固定）",
		"applied_to_active_replay": _active,
	}


func is_replay_active() -> bool:
	return _active


func get_replay_status() -> Dictionary:
	var metrics := _trajectory.get("evaluation_metrics", {}) as Dictionary
	return {
		"active": _active,
		"format": String(_trajectory.get("format", "")),
		"module": String(_trajectory.get("module", "cargo_circuit_rl")),
		"algorithm": String(_trajectory.get("algorithm", "--")),
		"dataset_split": String(_trajectory.get("dataset_split", "")),
		"trained_rl": bool(_trajectory.get("trained_rl", false)),
		"dynamic_obstacle_count": int(metrics.get("dynamic_obstacle_count", 0)),
		"dynamic_marker_count": _dynamic_traffic_nodes.size(),
		"progress": float(_sample_index) / float(maxi(_samples.size() - 1, 1)),
		"sample_index": _sample_index,
		"sample_count": _samples.size(),
		"elapsed_seconds": _elapsed,
		"playback_speed": playback_speed,
		"camera_mode": _replay_camera_mode,
		"visual_mode": VISUAL_MODE_PROCEDURAL_USV,
		"large_rock_replay_guard_blocks": _replay_guard_blocks,
		"last_result": _last_result.duplicate(true),
	}


func has_release_trajectory() -> bool:
	return FileAccess.file_exists(RELEASE_TRAJECTORY)


func _load_trajectory(path_value: String, allow_manual_feasibility: bool) -> bool:
	var requested := path_value
	if not FileAccess.file_exists(requested):
		requested = ProjectSettings.globalize_path(path_value)
	if not FileAccess.file_exists(requested):
		return false
	var file := FileAccess.open(requested, FileAccess.READ)
	if file == null:
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is not Dictionary:
		return false
	var payload := parsed as Dictionary
	var gate := payload.get("acceptance_gate", {}) as Dictionary
	var format := String(payload.get("format", ""))
	var is_manual := format == "cargo_circuit_manual_feasibility_rollout_v1"
	if is_manual:
		if not allow_manual_feasibility or bool(payload.get("trained_rl", true)):
			return false
	elif format != "cargo_circuit_test_rollout_v1" and format != "cargo_circuit_dynamic_test_rollout_v2":
		return false
	if String(payload.get("dataset_split", "")) != "test":
		return false
	if not is_manual and not bool(payload.get("trained_rl", false)):
		return false
	if not bool(gate.get("passed", false)):
		return false
	var samples := payload.get("samples", []) as Array
	if samples.size() < 2:
		return false
	_trajectory = payload
	_samples = samples
	return true


func _resolve_nodes() -> void:
	_ship = get_node_or_null(player_path) as Node3D
	_route_system = get_node_or_null(route_system_path)
	_obstacle_system = get_node_or_null(obstacle_system_path) as Node3D


func _snapshot_world() -> void:
	_original_ship = {
		"position": _ship.global_position,
		"heading_degrees": float(_ship.get_ship_telemetry().get("heading_degrees", 0.0)) if _ship.has_method("get_ship_telemetry") else 0.0,
		"human_control": bool(_ship.get("human_control_enabled")),
		"camera_heading_follow": bool((_ship.call("get_ship_camera_heading_follow_status") as Dictionary).get("enabled", false)) if _ship.has_method("get_ship_camera_heading_follow_status") else false,
	}
	_original_route = {
		"points": (_route_system.get("waypoint_positions") as Array).duplicate(),
		"loop": bool(_route_system.get("loop_route")),
		"arrival_radius": float(_route_system.get("arrival_radius")),
	}
	if _obstacle_system != null:
		_original_obstacles_visible = _obstacle_system.visible
	_world_prepared = true


func _prepare_mission_world() -> void:
	if _obstacle_system != null:
		_obstacle_system.visible = false
	var route_points: Array[Vector3] = []
	for raw_point in _trajectory.get("route_points", []) as Array:
		route_points.append(_point(raw_point as Dictionary))
	if _route_system.has_method("configure_route"):
		_route_system.set("arrival_radius", 14.0)
		_route_system.call("configure_route", route_points, false, _point(_trajectory.get("start", {}) as Dictionary))
	_build_mission_visuals()


func _restore_world() -> void:
	if not _world_prepared:
		return
	_clear_mission_visuals()
	if _route_system != null and _route_system.has_method("configure_route"):
		_route_system.set("arrival_radius", float(_original_route.get("arrival_radius", 16.0)))
		var restored: Array[Vector3] = []
		for raw_point in _original_route.get("points", []) as Array:
			if raw_point is Vector3:
				restored.append(raw_point as Vector3)
		_route_system.call(
			"configure_route",
			restored,
			bool(_original_route.get("loop", true)),
			_original_ship.get("position", Vector3.ZERO) as Vector3
		)
	if _obstacle_system != null:
		_obstacle_system.visible = _original_obstacles_visible
	if _ship != null:
		if _ship.has_method("set_ship_navigation_spawn"):
			_ship.call(
				"set_ship_navigation_spawn",
				_original_ship.get("position", Vector3.ZERO) as Vector3,
				float(_original_ship.get("heading_degrees", 0.0))
			)
		if _ship.has_method("set_ship_human_control_enabled"):
			_ship.call("set_ship_human_control_enabled", bool(_original_ship.get("human_control", true)))
		if _ship.has_method("set_ship_camera_heading_follow_enabled"):
			_ship.call("set_ship_camera_heading_follow_enabled", bool(_original_ship.get("camera_heading_follow", false)), false)
	_world_prepared = false


func _apply_replay_presentation(align_camera_immediately: bool = false) -> void:
	_apply_replay_camera_mode(align_camera_immediately)


func _apply_replay_camera_mode(align_immediately: bool = false) -> void:
	if _ship != null and _ship.has_method("set_ship_camera_heading_follow_enabled"):
		var enabled := _replay_camera_mode == CAMERA_MODE_AUTO_FOLLOW
		_ship.call("set_ship_camera_heading_follow_enabled", enabled, enabled and align_immediately)

func _apply_interpolated_state(current: Dictionary, next: Dictionary, alpha: float) -> bool:
	var position := _point(current).lerp(_point(next), alpha)
	if not is_large_rock_replay_segment_clear(_ship.global_position, position):
		_replay_guard_blocks += 1
		_finish(false, "Godot 大型悬岩碰撞守卫已阻止穿模回放")
		_safety_label.text = "可视化穿模已拦截  |  轨迹未改写  |  请检查场景岩石布局"
		return false
	var heading := rad_to_deg(lerp_angle(
		deg_to_rad(float(current.get("heading_degrees", 0.0))),
		deg_to_rad(float(next.get("heading_degrees", 0.0))),
		alpha
	))
	var speed := lerpf(float(current.get("speed_mps", 0.0)), float(next.get("speed_mps", 0.0)), alpha)
	var throttle := lerpf(float(current.get("actual_throttle", current.get("throttle", 0.0))), float(next.get("actual_throttle", next.get("throttle", 0.0))), alpha)
	var rudder := lerpf(float(current.get("actual_rudder", current.get("rudder", 0.0))), float(next.get("actual_rudder", next.get("rudder", 0.0))), alpha)
	if _ship.has_method("set_ship_agent_command"):
		_ship.call("set_ship_agent_command", float(current.get("throttle", 0.0)), float(current.get("rudder", 0.0)))
	if _ship.has_method("apply_recorded_ship_state"):
		_ship.call("apply_recorded_ship_state", position, heading, speed, throttle, rudder)
	_update_dynamic_traffic(current, next, alpha)
	return true


func is_large_rock_replay_segment_clear(from_position: Vector3, to_position: Vector3) -> bool:
	if _ship == null or not is_instance_valid(_ship):
		return false
	var motion := to_position - from_position
	if motion.length_squared() <= 0.000001:
		return true
	var query := PhysicsRayQueryParameters3D.create(from_position, to_position, 2)
	# Large-rock builders retain layer 1 for normal navigation and additionally
	# expose layer 2 so replay rays do not confuse the water/floor with cliffs.
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.hit_back_faces = true
	query.hit_from_inside = true
	if _ship is CollisionObject3D:
		query.exclude = [(_ship as CollisionObject3D).get_rid()]
	return _ship.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _build_mission_visuals() -> void:
	_clear_mission_visuals()
	_mission_root = Node3D.new()
	_mission_root.name = "CargoCircuitTestVisuals"
	get_parent().add_child(_mission_root)
	for raw_obstacle in _trajectory.get("evaluation_obstacles", []) as Array:
		var obstacle := raw_obstacle as Dictionary
		if bool(obstacle.get("dynamic", false)):
			_add_dynamic_traffic(obstacle)
		else:
			_add_floating_cliff(obstacle)
	var route_points := _trajectory.get("route_points", []) as Array
	for index in range(route_points.size()):
		_add_checkpoint_label(route_points[index] as Dictionary, index, index == route_points.size() - 1)


func _clear_mission_visuals() -> void:
	if _mission_root != null and is_instance_valid(_mission_root):
		_mission_root.queue_free()
	_mission_root = null
	_dynamic_traffic_nodes.clear()


func _add_dynamic_traffic(obstacle: Dictionary) -> void:
	var root := Node3D.new()
	var traffic_name := String(obstacle.get("name", "动态交通"))
	root.name = traffic_name
	root.position = _point(obstacle)
	_mission_root.add_child(root)
	_dynamic_traffic_nodes[traffic_name] = root
	var hull := MeshInstance3D.new()
	var hull_mesh := BoxMesh.new()
	hull_mesh.size = Vector3(4.0, 2.0, 10.0)
	hull.mesh = hull_mesh
	hull.position.y = 1.2
	hull.material_override = _material(Color(1.0, 0.68, 0.12, 1.0), 1.2, true)
	root.add_child(hull)
	var ring := MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = float(obstacle.get("radius", 5.0)) + 4.5
	ring_mesh.outer_radius = float(obstacle.get("radius", 5.0)) + 5.2
	ring.mesh = ring_mesh
	ring.position.y = 0.25
	ring.material_override = _material(Color(1.0, 0.82, 0.20, 0.78), 2.2, true)
	root.add_child(ring)
	var label := Label3D.new()
	label.text = traffic_name
	label.position.y = 6.0
	label.font_size = 24
	label.modulate = Color(1.0, 0.86, 0.32, 0.96)
	label.outline_size = 7
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	root.add_child(label)


func _update_dynamic_traffic(current: Dictionary, next: Dictionary, alpha: float) -> void:
	var next_by_name: Dictionary = {}
	for raw_next in next.get("dynamic_obstacles", []) as Array:
		var next_obstacle := raw_next as Dictionary
		next_by_name[String(next_obstacle.get("name", ""))] = next_obstacle
	for raw_current in current.get("dynamic_obstacles", []) as Array:
		var current_obstacle := raw_current as Dictionary
		var traffic_name := String(current_obstacle.get("name", ""))
		var node := _dynamic_traffic_nodes.get(traffic_name) as Node3D
		if node == null:
			continue
		var next_obstacle := next_by_name.get(traffic_name, current_obstacle) as Dictionary
		node.position = _point(current_obstacle).lerp(_point(next_obstacle), alpha)


func _add_floating_cliff(obstacle: Dictionary) -> void:
	if bool(obstacle.get("dynamic", false)):
		return
	var root := Node3D.new()
	root.name = String(obstacle.get("name", "FloatingCliff"))
	root.position = _point(obstacle)
	_mission_root.add_child(root)
	var radius := float(obstacle.get("radius", 14.0))
	for definition in [
		{"offset": Vector3(-radius * 0.18, 2.0, radius * 0.10), "scale": Vector3(radius * 0.75, 7.0, radius * 0.68)},
		{"offset": Vector3(radius * 0.20, 4.2, -radius * 0.12), "scale": Vector3(radius * 0.58, 11.0, radius * 0.55)},
		{"offset": Vector3(0.0, 7.4, 0.0), "scale": Vector3(radius * 0.36, 15.0, radius * 0.34)},
	]:
		var rock := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 1.0
		mesh.height = 2.0
		rock.mesh = mesh
		rock.position = definition["offset"] as Vector3
		rock.scale = definition["scale"] as Vector3
		rock.material_override = _material(Color(0.08, 0.10, 0.11, 1.0), 0.25, false)
		root.add_child(rock)
	var ring := MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = radius + 7.5
	ring_mesh.outer_radius = radius + 8.3
	ring.mesh = ring_mesh
	ring.position.y = 0.3
	ring.material_override = _material(Color(1.0, 0.30, 0.12, 0.82), 2.6, true)
	root.add_child(ring)
	var label := Label3D.new()
	label.text = String(obstacle.get("name", "悬岩"))
	label.position.y = 19.0
	label.font_size = 28
	label.modulate = Color(1.0, 0.65, 0.34, 0.95)
	label.outline_size = 7
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	root.add_child(label)


func _add_checkpoint_label(point: Dictionary, index: int, is_destination: bool) -> void:
	var marker := Node3D.new()
	marker.name = "CargoDestination" if is_destination else "CargoCheckpoint_%02d" % (index + 1)
	marker.position = _point(point) + Vector3.UP * 0.4
	_mission_root.add_child(marker)
	var ring := MeshInstance3D.new()
	var mesh := TorusMesh.new()
	mesh.inner_radius = 13.2
	mesh.outer_radius = 14.0
	ring.mesh = mesh
	ring.material_override = _material(Color(0.42, 1.0, 0.46, 0.9) if is_destination else Color(0.20, 0.90, 1.0, 0.82), 2.8, true)
	marker.add_child(ring)
	var label := Label3D.new()
	label.text = String(point.get("name", "取货站" if is_destination else "检查点 %d" % (index + 1)))
	label.position.y = 5.2
	label.font_size = 30
	label.modulate = Color(0.54, 1.0, 0.62, 0.96) if is_destination else Color(0.66, 0.97, 1.0, 0.94)
	label.outline_size = 8
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	marker.add_child(label)


func _material(color: Color, emission_energy: float, transparent: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.92
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.emission_enabled = emission_energy > 0.0
	material.emission = Color(color.r, color.g, color.b, 1.0)
	material.emission_energy_multiplier = emission_energy
	return material


func _build_hud() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 78
	add_child(_hud_layer)
	_hud_panel = PanelContainer.new()
	_hud_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_hud_panel.position = Vector2(-470.0, 18.0)
	_hud_panel.size = Vector2(450.0, 238.0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.012, 0.025, 0.034, 0.94)
	style.border_color = Color(0.20, 0.90, 1.0, 0.82)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(14.0)
	_hud_panel.add_theme_stylebox_override("panel", style)
	_hud_layer.add_child(_hud_panel)
	var box := VBoxContainer.new()
	box.add_child(_label("SAC 环图取货 · HELD-OUT TEST REPLAY", 17, Color(0.34, 0.96, 1.0)))
	_status_label = _label("", 12, Color(0.76, 0.92, 0.98))
	_checkpoint_label = _label("", 13, Color(0.48, 1.0, 0.58))
	_action_label = _label("", 12, Color(1.0, 0.78, 0.35))
	_safety_label = _label("", 12, Color(0.80, 0.92, 0.96))
	for label in [_status_label, _checkpoint_label, _action_label, _safety_label]:
		box.add_child(label)
	_progress_bar = ProgressBar.new()
	_progress_bar.show_percentage = false
	_progress_bar.custom_minimum_size.y = 8.0
	box.add_child(_progress_bar)
	_hud_panel.add_child(box)
	_hud_layer.visible = false


func _update_hud(current: Dictionary, next: Dictionary, alpha: float) -> void:
	var total := int(current.get("total_checkpoints", 7))
	var passed := int(current.get("checkpoints_passed", 0))
	var speed := lerpf(float(current.get("speed_mps", 0.0)), float(next.get("speed_mps", 0.0)), alpha)
	var actual_rudder := lerpf(float(current.get("actual_rudder", 0.0)), float(next.get("actual_rudder", 0.0)), alpha)
	var yaw_rate := lerpf(float(current.get("yaw_rate_degrees_per_second", 0.0)), float(next.get("yaw_rate_degrees_per_second", 0.0)), alpha)
	var clearance := lerpf(float(current.get("nearest_clearance_meters", 0.0)), float(next.get("nearest_clearance_meters", 0.0)), alpha)
	var source_label := "真实训练策略" if bool(_trajectory.get("trained_rl", false)) else "人工舵令可达性（非 RL）"
	_status_label.text = "%s  |  split=test  |  连续油门/舵角  |  %.1fx" % [source_label, playback_speed]
	_checkpoint_label.text = "检查点 %d/%d  ·  %s" % [passed, total, "返航取货完成" if passed >= total else "按序巡回中"]
	_action_label.text = "航速 %.2f m/s  |  实际舵 %.3f  |  转向角速 %.2f°/s（上限 20°/s）" % [speed, actual_rudder, yaw_rate]
	_safety_label.text = "最近 %s  |  安全包络净距 %.2f m  |  碰撞=false" % [String(current.get("nearest_obstacle_name", "--")), clearance]
	_progress_bar.value = float(_sample_index) / float(maxi(_samples.size() - 1, 1)) * 100.0


func _finish(success: bool, message: String) -> void:
	_active = false
	if _ship != null and _ship.has_method("clear_ship_agent_command"):
		_ship.call("clear_ship_agent_command")
	_last_result = {"success": success, "message": message, "elapsed_seconds": _elapsed}
	_status_label.text = ("● PASS  " if success else "● FAIL  ") + message
	replay_finished.emit(get_replay_status())


func _show_error(message: String) -> void:
	if _hud_layer == null:
		return
	_hud_layer.visible = true
	_status_label.text = "● BLOCKED  " + message
	_checkpoint_label.text = "仅接受 trained_rl=true、split=test 且 acceptance_gate=passed 的轨迹"
	_action_label.text = ""
	_safety_label.text = ""


func _point(value: Dictionary) -> Vector3:
	var position := value.get("position", value) as Dictionary
	return Vector3(float(position.get("x", 0.0)), WATER_LEVEL_Y, float(position.get("z", 0.0)))


func _label(text_value: String, size_value: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", size_value)
	label.add_theme_color_override("font_color", color)
	return label

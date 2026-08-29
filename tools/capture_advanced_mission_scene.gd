extends SceneTree

## Native rendered-frame capture for one advanced mission. This is a visual
## diagnostic, not a simulation-performance or policy-evaluation result.

const DEFAULT_SCENARIO := "crossing_starboard"
const DEFAULT_OUTPUT := "/tmp/advanced_mission_scene.png"
const ALL_SCENE_REPORT := "res://reports/godot_all_scenario_visual_smoke_v1.json"


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var scenario_key := OS.get_environment("SHIP_CAPTURE_SCENARIO").strip_edges()
	if scenario_key.is_empty():
		scenario_key = DEFAULT_SCENARIO
	var output_path := OS.get_environment("SHIP_CAPTURE_OUTPUT").strip_edges()
	if output_path.is_empty():
		output_path = DEFAULT_OUTPUT
	var scene_status := change_scene_to_file("res://main.tscn")
	if scene_status != OK:
		push_error("ADVANCED_SCENE_CAPTURE: main scene load failed: %s" % scene_status)
		quit(1)
		return
	for _index in range(36):
		await process_frame
		await physics_frame
	var main := current_scene
	var scenario_controller := main.get_node_or_null("ShipScenarioController") if main != null else null
	if scenario_controller == null:
		push_error("ADVANCED_SCENE_CAPTURE: scenario controller unavailable")
		quit(1)
		return
	if OS.get_environment("SHIP_CAPTURE_ALL") == "1":
		await _capture_all_scenarios(main, scenario_controller, output_path)
		return
	var scenario_index := int(scenario_controller.call("get_scenario_index_by_key", scenario_key))
	if scenario_index < 0:
		push_error("ADVANCED_SCENE_CAPTURE: unknown scenario %s" % scenario_key)
		quit(1)
		return
	scenario_controller.call("apply_scenario", scenario_index, true)
	for _index in range(48):
		await process_frame
		await physics_frame
	var camera := main.get_node_or_null("Player/Camera3D") as Camera3D
	var background := main.get_node_or_null("NavigationEnvironment/BackgroundWalls") as Node3D
	var walls: Array[Dictionary] = []
	if background != null:
		for raw_child in background.get_children():
			var wall := raw_child as MeshInstance3D
			if wall == null or not String(wall.name).begins_with("FarBackground_"):
				continue
			var material := wall.material_override as StandardMaterial3D
			walls.append({
				"name": String(wall.name),
				"visible": wall.visible,
				"visible_in_tree": wall.is_visible_in_tree(),
				"global_position": wall.global_position,
				"global_aabb": wall.global_transform * wall.get_aabb(),
				"layer_mask": wall.layers,
				"material": material.resource_name if material != null else "MISSING",
				"texture": material.albedo_texture.resource_path if material != null and material.albedo_texture != null else "MISSING",
				"center_behind_camera": camera.is_position_behind(wall.global_position) if camera != null else null,
				"center_screen": camera.unproject_position(wall.global_position) if camera != null else null,
				"bottom_screen": camera.unproject_position(Vector3(wall.global_position.x, -140.1, wall.global_position.z)) if camera != null else null,
			})
	var image := root.get_texture().get_image()
	var save_status := image.save_png(output_path)
	var detail := {
		"scenario_key": scenario_key,
		"output_path": output_path,
		"save_status": save_status,
		"image_size": image.get_size(),
		"camera_position": camera.global_position if camera != null else null,
		"camera_rotation_degrees": camera.global_rotation_degrees if camera != null else null,
		"camera_current": camera.current if camera != null else false,
		"camera_cull_mask": camera.cull_mask if camera != null else 0,
		"background_visible": background != null and background.is_visible_in_tree(),
		"walls": walls,
		"dedicated_scene": scenario_controller.call("get_active_dedicated_scene_snapshot"),
	}
	print("ADVANCED_SCENE_CAPTURE:%s" % JSON.stringify(detail))
	quit(0 if save_status == OK else 1)


func _capture_all_scenarios(main: Node, scenario_controller: Node, output_path: String) -> void:
	var output_dir := output_path
	if output_dir.ends_with(".png"):
		output_dir = output_dir.get_base_dir().path_join("all_scenario_visuals")
	DirAccess.make_dir_recursive_absolute(output_dir)
	var weather_time := main.get_node_or_null("ShipWeatherTimeController")
	var records: Array[Dictionary] = []
	for raw_scenario in scenario_controller.call("list_scenarios") as Array:
		var scenario_record := raw_scenario as Dictionary
		var key := String(scenario_record.get("key", ""))
		weather_time.call("apply_mode", 3)
		var index := int(scenario_controller.call("get_scenario_index_by_key", key))
		scenario_controller.call("apply_scenario", index, true)
		for _frame in range(24):
			await process_frame
			await physics_frame
		var image := root.get_texture().get_image()
		var image_path := output_dir.path_join("%s.png" % key)
		var save_status := image.save_png(image_path)
		var metrics := _visual_metrics(image)
		var weather := weather_time.call("get_weather_time_status") as Dictionary
		var dedicated := scenario_controller.call("get_active_dedicated_scene_snapshot") as Dictionary
		var dedicated_expected := key not in ["open_water", "harbor"]
		var dedicated_valid := (
			not dedicated_expected
			or (
				bool(dedicated.get("dedicated_scene", false))
				and int(dedicated.get("task_wall_count", 0)) == 4
				and bool(dedicated.get("task_walls_vertical", false))
				and not String(dedicated.get("task_wallpaper_texture", "")).is_empty()
			)
		)
		var passed := (
			save_status == OK
			and String(weather.get("key", "")) == "clear"
			and not bool(weather.get("fog_enabled", true))
			and is_zero_approx(float(weather.get("fog_density", -1.0)))
			and is_zero_approx(float(weather.get("atmosphere_overlay_alpha", -1.0)))
			and bool(weather.get("zero_fog_visual", false))
			and bool(metrics.get("rendered_scene_not_flat_clear_color", false))
			and dedicated_valid
		)
		records.append({
			"scenario_key": key,
			"passed": passed,
			"image_path": _portable_capture_path(image_path),
			"weather_key": weather.get("key"),
			"weather_name": weather.get("name"),
			"fog_enabled": weather.get("fog_enabled"),
			"fog_density": weather.get("fog_density"),
			"atmosphere_overlay_alpha": weather.get("atmosphere_overlay_alpha"),
			"zero_fog_visual": weather.get("zero_fog_visual"),
			"visual_metrics": metrics,
			"dedicated_scene_expected": dedicated_expected,
			"dedicated_scene_valid": dedicated_valid,
			"task_wall_count": dedicated.get("task_wall_count", 0),
			"task_walls_vertical": dedicated.get("task_walls_vertical", false),
		})
	var passed := records.all(func(item: Dictionary) -> bool: return bool(item.get("passed", false)))
	var payload := {
		"schema_version": "godot_all_scenario_visual_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": passed,
		"passed_scenarios": records.filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"total_scenarios": records.size(),
		"records": records,
		"boundary": "Native rendered-pixel scene-entry acceptance; not policy performance or training evidence.",
	}
	var report := FileAccess.open(ALL_SCENE_REPORT, FileAccess.WRITE)
	if report != null:
		report.store_string(JSON.stringify(payload, "\t") + "\n")
		report.close()
	print("ALL_SCENARIO_VISUAL_SMOKE:%s:%d/%d" % ["PASS" if passed else "FAIL", payload["passed_scenarios"], payload["total_scenarios"]])
	quit(0 if passed else 1)


func _portable_capture_path(path: String) -> String:
	var project_root := ProjectSettings.globalize_path("res://").trim_suffix("/")
	var project_prefix := project_root + "/"
	if path.begins_with(project_prefix):
		return "res://" + path.substr(project_prefix.length())
	return path


func _visual_metrics(image: Image) -> Dictionary:
	var width := image.get_width()
	var height := image.get_height()
	var x_start := int(width * 0.26)
	var x_end := int(width * 0.74)
	var y_start := int(height * 0.15)
	var y_end := int(height * 0.31)
	var unique_quantized := {}
	var minimum := Vector3(1.0, 1.0, 1.0)
	var maximum := Vector3.ZERO
	var sample_count := 0
	for y in range(y_start, y_end, 6):
		for x in range(x_start, x_end, 6):
			var color := image.get_pixel(x, y)
			minimum.x = minf(minimum.x, color.r)
			minimum.y = minf(minimum.y, color.g)
			minimum.z = minf(minimum.z, color.b)
			maximum.x = maxf(maximum.x, color.r)
			maximum.y = maxf(maximum.y, color.g)
			maximum.z = maxf(maximum.z, color.b)
			var key := "%02d-%02d-%02d" % [int(color.r * 15.0), int(color.g * 15.0), int(color.b * 15.0)]
			unique_quantized[key] = true
			sample_count += 1
	var channel_span := maximum - minimum
	var maximum_span := maxf(channel_span.x, maxf(channel_span.y, channel_span.z))
	return {
		"sample_count": sample_count,
		"unique_quantized_color_count": unique_quantized.size(),
		"maximum_channel_span": maximum_span,
		"rendered_scene_not_flat_clear_color": unique_quantized.size() >= 12 and maximum_span >= 0.08,
	}

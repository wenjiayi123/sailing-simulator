extends SceneTree

const REPORT_PATH := "res://reports/godot_background_wallpaper_smoke_v1.json"
const CONFIG_PATH := "user://navigation_visual_overrides.json"

var _checks: Dictionary = {}
var _errors: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _record(name: String, passed: bool, detail: Variant) -> void:
	_checks[name] = {"passed": passed, "detail": detail}
	if not passed:
		_errors.append("%s: %s" % [name, str(detail)])


func _run() -> void:
	var status := change_scene_to_file("res://main.tscn")
	_record("main_scene_load_request", status == OK, status)
	for _index in range(12):
		await process_frame
	var main := current_scene
	var background := main.get_node_or_null("NavigationEnvironment/BackgroundWalls") if main != null else null
	_record("background_wall_root_present", background != null, background)
	if background == null:
		_finish()
		return
	var walls: Array[MeshInstance3D] = []
	for child in background.get_children():
		if child is MeshInstance3D and String(child.name).begins_with("FarBackground_"):
			walls.append(child as MeshInstance3D)
	_record("four_background_walls_present", walls.size() == 4, walls.map(func(wall: MeshInstance3D) -> String: return wall.name))
	_record("four_background_walls_visible", walls.all(func(wall: MeshInstance3D) -> bool: return wall.visible), walls.map(func(wall: MeshInstance3D) -> bool: return wall.visible))
	var walls_vertical := walls.all(func(wall: MeshInstance3D) -> bool:
		return absf(wall.transform.basis.y.normalized().dot(Vector3.UP)) >= 0.9999
	)
	_record(
		"four_background_walls_are_vertical",
		walls_vertical
		and String(background.get_meta("wall_orientation_status", "")) == "VERTICAL_LOCKED"
		and is_zero_approx(float(background.get_meta("task_wall_tilt_degrees", 0.0))),
		walls.map(func(wall: MeshInstance3D) -> Dictionary: return {
			"name": String(wall.name),
			"up_dot": absf(wall.transform.basis.y.normalized().dot(Vector3.UP)),
		}),
	)
	var override_status := String(background.get_meta("wallpaper_override_status", "MISSING"))
	var water_status := String(background.get_meta("water_override_status", "MISSING"))
	var local_config_present := FileAccess.file_exists(CONFIG_PATH)
	_record(
		"startup_scene_uses_port_wallpaper",
		override_status == "STARTUP_PORT_HORIZON",
		{"config_present": local_config_present, "status": override_status},
	)
	_record(
		"local_water_applied_when_configured",
		not local_config_present or water_status == "APPLIED_LOCAL_WATER",
		{"config_present": local_config_present, "status": water_status},
	)
	if local_config_present:
		var all_overrides_valid := true
		var texture_paths: Array[String] = []
		for wall in walls:
			var material := wall.material_override as StandardMaterial3D
			var texture_path := "MISSING"
			if material != null and material.albedo_texture != null:
				texture_path = material.albedo_texture.resource_path
			else:
				all_overrides_valid = false
			texture_paths.append(texture_path)
		_record(
			"all_walls_use_local_material_override",
			all_overrides_valid,
			texture_paths,
		)
	_finish()


func _finish() -> void:
	var payload := {
		"schema_version": "godot_background_wallpaper_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": _errors.is_empty(),
		"passed_checks": _checks.values().filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"total_checks": _checks.size(),
		"checks": _checks,
		"errors": _errors,
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("BACKGROUND_WALLPAPER_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_checks"], payload["total_checks"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

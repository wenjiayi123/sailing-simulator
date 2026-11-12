extends SceneTree
## Button-signal/state regression. Visual presentation is checked by the owner.
const SAVE := "user://ship_demo_guide_v1.cfg"
const REPORT := "res://reports/demo_guide_regression_20261020.json"
var checks: Array = []
var saved: PackedByteArray
var had_save := false
var guide: Node

func _initialize() -> void:
	call_deferred("run")

func record(name: String, passed: bool, detail: Variant = null) -> void:
	checks.append({"name": name, "passed": passed, "detail": detail})
	print("DEMO_CHECK:", name, ":", passed, ":", detail if not passed else "")

func settle() -> void:
	for frame in range(1200):
		await process_frame
		if not bool(guide.get("_busy")):
			return

func run() -> void:
	had_save = FileAccess.file_exists(SAVE)
	if had_save:
		saved = FileAccess.get_file_as_bytes(SAVE)
	change_scene_to_file("res://main.tscn")
	for frame in range(24):
		await process_frame
	guide = current_scene.get_node("ShipDemoGuide")
	guide.call("_restart")
	var steps := guide.get("_steps") as Array
	var primary := guide.get("_primary") as Button
	var background := current_scene.get_node("NavigationEnvironment/BackgroundWalls")
	for index in range(steps.size()):
		# Exactly one signal per step: ready -> advance AND execute next.
		primary.pressed.emit()
		await settle()
		var status := String(guide.get("_status"))
		record("single_click_" + String(steps[index]["id"]), int(guide.get("_step_index")) == index and status == "ready", guide.get("_message"))
		if status != "ready":
			break
		if String(steps[index].get("kind", "")) == "mission_policy":
			var scene_system := current_scene.get_node("ShipScenarioController")
			var config := scene_system.call("get_current_scenario_config") as Dictionary
			var key := String(steps[index]["scenario_key"])
			var expected := String((config.get("visual_profile", {}) as Dictionary).get("wallpaper_texture", background.get("_base_wallpaper_texture_path")))
			if key == "open_water":
				expected = background.PORT_HORIZON
			var paths: Array[String] = []
			for wall in background.get_children():
				if wall is MeshInstance3D and String(wall.name).begins_with("FarBackground_"):
					var material := wall.material_override as StandardMaterial3D
					if material == null and wall.mesh != null:
						material = wall.mesh.surface_get_material(0) as StandardMaterial3D
					paths.append(material.albedo_texture.resource_path if material != null and material.albedo_texture != null else "")
			record("scene_wallpaper_" + key, paths.size() == 4 and paths.all(func(path: String) -> bool: return path == expected), paths)
			var dedicated := scene_system.get("_active_dedicated_scene") as Node
			if dedicated != null:
				var task_paths: Array[String] = []
				for wall in dedicated.call("_task_walls") as Array:
					var material := wall.material_override as StandardMaterial3D
					task_paths.append(material.albedo_texture.resource_path if material != null and material.albedo_texture != null else "")
				record("dedicated_scene_wallpaper_" + key, task_paths.size() == 4 and task_paths.all(func(path: String) -> bool: return path == expected), task_paths)
	guide.call("_on_n_scene_pressed", "policy-narrow_channel_head_on")
	guide.call("_on_n_scene_pressed", "policy-narrow_channel_overtaking")
	await settle()
	var controller := current_scene.get_node("MissionRLController")
	record("pending_scene_switch_cancels_old_start", String(guide.get("_status")) == "ready" and String(controller.get("key")) == "narrow_channel_overtaking" and bool(controller.get("active")), guide.get("_message"))
	guide.call("_on_manual_stop")
	record("manual_stop_available", not bool(guide.get("_busy")) and not bool(controller.get("active")))
	var mission := current_scene.get_node("ShipAdvancedMissionController")
	mission.call("confirm_overtaking_agreement", false, "")
	record("unconfirmed_overtaking_rejected", not bool(controller.call("start_current")) and String(controller.get("status")).contains("协议"))
	guide.call("_jump_to_step", 2, true)
	await settle()
	guide.call("_previous_step")
	await settle()
	record("previous_executes_destination", int(guide.get("_step_index")) == 1 and String(guide.get("_status")) == "ready", guide.get("_message"))
	var picker := guide.get("_step_picker") as OptionButton
	picker.item_selected.emit(0)
	await settle()
	record("picker_executes_destination", int(guide.get("_step_index")) == 0 and String(guide.get("_status")) == "ready")
	guide.call("_on_n_scene_pressed", "policy-open_water")
	guide.call("_on_manual_stop")
	for frame in range(15):
		await process_frame
	record("pending_start_stays_cancelled", not bool(controller.get("active")) and not bool(guide.get("_busy")))
	guide.call("_restore_mission_scene")
	var passed := checks.all(func(row: Dictionary) -> bool: return bool(row["passed"]))
	var file := FileAccess.open(REPORT, FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed": passed, "checks": checks, "step_count": steps.size(), "visual_acceptance": "owner_manual", "production_authority": false}, "\t"))
	file.close()
	# The test must not replace the presenter's saved progress.
	if had_save:
		var original := FileAccess.open(SAVE, FileAccess.WRITE)
		original.store_buffer(saved)
		original.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE))
	print("DEMO_GUIDE_REGRESSION:", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)

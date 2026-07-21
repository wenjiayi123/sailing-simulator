extends SceneTree

const MAIN_SCENE := preload("res://main.tscn")

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var world := MAIN_SCENE.instantiate()
	root.add_child(world)
	await process_frame
	await physics_frame

	var manager := world.get_node_or_null("ShipFleetManager") as ShipFleetManager
	_expect(manager != null, "缺少 ShipFleetManager")
	if manager == null:
		_finish(world)
		return

	var before_count := manager.get_ship_records().size()
	var selected_config := manager.get_selected_ship_config()
	_expect(not selected_config.is_empty(), "没有读到选中船舶参数")

	var spawned := manager.spawn_ship_at(Vector3(24.0, -140.0, -24.0), selected_config)
	await process_frame
	_expect(spawned != null, "克隆船舶失败")
	_expect(manager.get_ship_records().size() == before_count + 1, "船队数量没有增加")
	if spawned != null:
		_expect(not bool(spawned.get("human_control_enabled")), "克隆船仍在读取人类输入")
		_expect(not bool(spawned.get("camera_enabled")), "克隆船仍启用独立摄像机")
		_expect(spawned.has_method("apply_ship_performance_config"), "克隆船缺少参数应用接口")

	var training_parameters := {
		"learning_rate": 0.0003,
		"vessel_radius_m": 3.2,
		"cliff_inflation_m": 8.0,
		"merge_scene_obstacles": true,
		"domain_randomization": true,
	}
	var exported_path := manager.export_training_config("user://ship_rl_smoke_config.json", training_parameters)
	_expect(not exported_path.is_empty(), "训练配置导出路径为空")
	_expect(FileAccess.file_exists("user://ship_rl_smoke_config.json"), "训练配置文件没有生成")
	var config_file := FileAccess.open("user://ship_rl_smoke_config.json", FileAccess.READ)
	var config = JSON.parse_string(config_file.get_as_text()) if config_file != null else null
	if config_file != null:
		config_file.close()
	_expect(config is Dictionary, "训练配置不是 JSON 字典")
	if config is Dictionary:
		var payload := config as Dictionary
		_expect(String(payload.get("schema_version", "")) == "ship_training_experiment_v3", "训练配置版本不是 v3")
		_expect(float((payload.get("environment_parameters", {}) as Dictionary).get("cliff_inflation_m", 0.0)) == 8.0, "悬岩净距没有进入环境参数")
		_expect((payload.get("rl_parameters", {}) as Dictionary).has("learning_rate"), "算法参数没有进入 rl_parameters")
		var world_snapshot := payload.get("world", {}) as Dictionary
		var obstacle_snapshot := world_snapshot.get("obstacles", {}) as Dictionary
		var rocks := obstacle_snapshot.get("rocks", []) as Array
		var has_scene_cliff := false
		for raw_rock in rocks:
			var rock := raw_rock as Dictionary
			if String(rock.get("kind", "")) == "cliff":
				has_scene_cliff = true
				break
		_expect(has_scene_cliff, "场景悬岩没有进入训练快照")
	var preview := manager.preview_training_environment(training_parameters)
	_expect(bool(preview.get("ok", false)), "环境安全包络预览失败")
	_expect(int(preview.get("terrain_count", 0)) >= 1, "预览没有识别场景悬岩")

	_finish(world)


func _finish(world: Node) -> void:
	world.queue_free()
	await process_frame
	if failures.is_empty():
		print("SHIP_RL_OK: clone, v3 config split, scene cliff merge, safety preview")
		quit(0)
		return
	for failure in failures:
		push_error("SHIP_RL_FAIL: %s" % failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

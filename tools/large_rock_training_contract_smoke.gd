extends SceneTree

const LARGE_ROCK_MANIFEST := preload("res://scripts/world/large_rock_obstacle_manifest.gd")
const REPORT_PATH := "res://reports/large_rock_training_contract_v1.json"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var errors: Array[String] = []
	if change_scene_to_file("res://main.tscn") != OK:
		_finish({}, ["main scene failed to load"])
		return
	for _index in range(18):
		await process_frame
	var environment := current_scene.get_node_or_null("NavigationEnvironment") as Node3D
	var guard := current_scene.get_node_or_null("LargeRockCollisionGuard")
	var navigation := current_scene.get_node_or_null("ShipNavigationObstacles")
	var fleet := current_scene.get_node_or_null("ShipFleetManager")
	if environment == null or guard == null or navigation == null or fleet == null:
		_finish({}, ["required runtime systems are missing"])
		return
	var roots: Array[Node3D] = []
	for collection_path in LARGE_ROCK_MANIFEST.collection_paths():
		var collection := environment.get_node_or_null(collection_path)
		if collection == null:
			errors.append("large-rock collection missing: %s" % collection_path)
			continue
		for child in collection.get_children():
			if child is Node3D and LARGE_ROCK_MANIFEST.has_rock(String(child.name)):
				roots.append(child as Node3D)
	if roots.size() != LARGE_ROCK_MANIFEST.expected_rock_count():
		errors.append("canonical scene rock count mismatch")
	var transform_match_count := 0
	var physics_obstacle_count := 0
	var collision_shape_count := 0
	var unique_names: Dictionary = {}
	for rock_root in roots:
		var rock_name := String(rock_root.name)
		unique_names[rock_name] = true
		if rock_root.transform.is_equal_approx(LARGE_ROCK_MANIFEST.canonical_transform(rock_name)):
			transform_match_count += 1
		for raw_body in rock_root.find_children("*", "CollisionObject3D", true, false):
			var body := raw_body as CollisionObject3D
			if body == null:
				continue
			if body.is_in_group(&"ship_navigation_obstacle") and (body.collision_layer & 1) != 0:
				physics_obstacle_count += 1
		for raw_shape in rock_root.find_children("*", "CollisionShape3D", true, false):
			var shape_node := raw_shape as CollisionShape3D
			if shape_node != null and shape_node.shape != null and not shape_node.disabled:
				collision_shape_count += 1
	if transform_match_count != roots.size():
		errors.append("one or more large-rock transforms differ from the canonical layout")
	if unique_names.size() != roots.size():
		errors.append("large-rock names are not unique")
	if physics_obstacle_count < roots.size() * 2 or collision_shape_count < roots.size() * 2:
		errors.append("one or more large rocks are missing exact navigation collision bodies")
	var radar := navigation.call("get_radar_obstacle_data") as Dictionary
	var radar_large_rocks := _manifest_boxes(radar.get("boxes", []) as Array)
	if radar_large_rocks.size() != roots.size():
		errors.append("navigation radar does not contain every canonical large rock")
	var export_path := fleet.call(
		"export_training_config",
		"user://large_rock_training_contract_smoke.json",
		{"merge_scene_obstacles": true}
	) as String
	var training_large_rocks: Array[Dictionary] = []
	if export_path.is_empty() or not FileAccess.file_exists(export_path):
		errors.append("training config export failed")
	else:
		var file := FileAccess.open(export_path, FileAccess.READ)
		var parsed = JSON.parse_string(file.get_as_text()) if file != null else null
		if file != null:
			file.close()
		if parsed is not Dictionary:
			errors.append("training config is not valid JSON")
		else:
			var world := (parsed as Dictionary).get("world", {}) as Dictionary
			var obstacles := world.get("obstacles", {}) as Dictionary
			training_large_rocks = _manifest_boxes(obstacles.get("boxes", []) as Array)
			if training_large_rocks.size() != roots.size():
				errors.append("training snapshot does not contain every canonical large rock")
	var restore_probe_passed := false
	if not roots.is_empty():
		var probe := roots[0]
		var canonical := LARGE_ROCK_MANIFEST.canonical_transform(String(probe.name))
		probe.position.x += 3.0
		guard.call("rebuild_guards")
		restore_probe_passed = probe.transform.is_equal_approx(canonical)
		if not restore_probe_passed:
			errors.append("runtime transform lock did not restore a displaced large rock")
	var guard_status := guard.call("get_guard_status") as Dictionary
	if int(guard_status.get("registered_obstacle_count", 0)) != roots.size():
		errors.append("large-rock guard registry count mismatch")
	_finish({
		"manifest_schema_version": LARGE_ROCK_MANIFEST.manifest_schema_version(),
		"manifest_id": LARGE_ROCK_MANIFEST.manifest_id(),
		"canonical_rock_count": roots.size(),
		"transform_match_count": transform_match_count,
		"unique_name_count": unique_names.size(),
		"physics_navigation_body_count": physics_obstacle_count,
		"collision_shape_count": collision_shape_count,
		"radar_large_rock_count": radar_large_rocks.size(),
		"training_snapshot_large_rock_count": training_large_rocks.size(),
		"transform_restore_probe_passed": restore_probe_passed,
		"guard_status": guard_status,
	}, errors)


func _manifest_boxes(raw_boxes: Array) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for raw_box in raw_boxes:
		var obstacle := raw_box as Dictionary
		if String(obstacle.get("manifest_id", "")) == LARGE_ROCK_MANIFEST.manifest_id():
			records.append(obstacle)
	return records


func _finish(payload: Dictionary, errors: Array[String]) -> void:
	var report := payload.duplicate(true)
	report["format"] = "large_rock_training_contract_v1"
	report["passed"] = errors.is_empty()
	report["errors"] = errors
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	print("LARGE_ROCK_TRAINING_CONTRACT:%s:%d:%d" % [
		"PASS" if errors.is_empty() else "FAIL",
		int(report.get("canonical_rock_count", 0)),
		int(report.get("training_snapshot_large_rock_count", 0)),
	])
	quit(0 if errors.is_empty() else 1)

extends SceneTree

const WATER_LEVEL_Y := -140.73494
const DEMO_CLEARANCE_METERS := 18.0
const PRESERVED_DEMO_ENCOUNTERS := {
	"GroundedPlate_06_TwistedButtressMesa": "用户确认该东侧巨岩由策略近距离避让，保留以展示真实转向操作",
}
const RELOCATED_CROSSING_ROCKS := {
	"GroundedPlate_01_BroadLandMass": Vector2(-460.0, 280.0),
	"GroundedPlate_04_WideBridgeSlab": Vector2(-520.0, -200.0),
	"GroundedPlate_07_AncientWallPlate": Vector2(-120.0, 520.0),
}
const REPORT_PATH := "res://reports/large_rock_collision_audit_v1.json"
const TRAJECTORY_PATHS := [
	"res://reports/artifacts/cargo_circuit_rl_v1/cargo_policy_test_trajectory.json",
	"res://reports/artifacts/cargo_circuit_dynamic_rl_v2/cargo_dynamic_policy_test_trajectory.json",
]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var status := change_scene_to_file("res://main.tscn")
	if status != OK:
		_finish([], ["main scene load failed: %s" % error_string(status)])
		return
	for _index in range(18):
		await process_frame
	var environment := current_scene.get_node_or_null("NavigationEnvironment") as Node3D
	if environment == null:
		_finish([], ["NavigationEnvironment missing"])
		return
	var samples := _load_trajectory_points()
	var roots: Array[Node3D] = []
	for path in [
		"TerrainUpperWalkableRegions/FloatingPlates/Rock3A_Comparison_Set",
		"TerrainUpperWalkableRegions/FloatingPlates/GroundedRockPlate_Comparison_Set",
	]:
		var collection := environment.get_node_or_null(path)
		if collection == null:
			continue
		for child in collection.get_children():
			if child is Node3D:
				roots.append(child as Node3D)
	var records: Array[Dictionary] = []
	for root_node in roots:
		records.append(_audit_root(root_node, samples))
	var errors: Array[String] = []
	var conflicts := records.filter(func(record: Dictionary) -> bool: return bool(record.get("trajectory_conflict", false)))
	if not conflicts.is_empty():
		errors.append("%d large-rock render surfaces are still crossed by a cargo replay trajectory" % conflicts.size())
	for record in records:
		if not bool(record.get("relocated_for_crossing_fix", false)):
			continue
		var target := RELOCATED_CROSSING_ROCKS[String(record.get("name", ""))] as Vector2
		var position := record.get("local_position", {}) as Dictionary
		if not is_equal_approx(float(position.get("x", INF)), target.x) or not is_equal_approx(float(position.get("z", INF)), target.y):
			errors.append("relocated crossing rock is not at its reviewed safe position: %s" % String(record.get("name", "")))
	var waterline_rocks := records.filter(func(record: Dictionary) -> bool: return bool(record.get("visual_overlaps_waterline", false)))
	for record in waterline_rocks:
		if int(record.get("collision_shape_count", 0)) < 2 or not bool(record.get("collision_overlaps_waterline", false)):
			errors.append("visible waterline rock is missing its generated mesh collision: %s" % String(record.get("name", "")))
		if int(record.get("replay_guard_collision_shape_count", 0)) < 2:
			errors.append("visible waterline rock collision is not exposed to the replay sweep layer: %s" % String(record.get("name", "")))
	var expected_supplemental_guards := RELOCATED_CROSSING_ROCKS.size()
	var guard: Node = current_scene.get_node_or_null("LargeRockCollisionGuard")
	var guard_status: Dictionary = guard.call("get_guard_status") as Dictionary if guard != null else {}
	if guard == null:
		errors.append("LargeRockCollisionGuard missing")
	elif int(guard_status.get("guard_count", 0)) != expected_supplemental_guards:
		errors.append("supplemental collision guard count does not match relocated crossing rock count")
	await physics_frame
	await physics_frame
	var physics_hits := _count_physics_guard_hits(guard)
	if guard != null and physics_hits != int(guard_status.get("guard_count", 0)):
		errors.append("one or more waterline guard centers are missing from the physics space")
	var blocking_hits := await _count_blocking_guard_hits(guard)
	if guard != null and blocking_hits != int(guard_status.get("guard_count", 0)):
		errors.append("one or more waterline guards failed the ship-sized physics sweep")
	var replay_sweep_block_records := _trajectory_replay_sweep_blocks(samples)
	if not replay_sweep_block_records.is_empty():
		errors.append("released cargo trajectory is blocked by one or more large-rock physics shapes")
	_finish(records, errors, guard_status, physics_hits, blocking_hits, replay_sweep_block_records)


func _audit_root(root_node: Node3D, samples: Array[Vector2]) -> Dictionary:
	var visual_aabb := AABB()
	var collision_aabb := AABB()
	var has_visual := false
	var has_collision := false
	var collision_shapes := 0
	var replay_guard_collision_shapes := 0
	for raw_mesh in root_node.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := raw_mesh as MeshInstance3D
		if mesh_node == null or mesh_node.mesh == null or not mesh_node.visible:
			continue
		var world_box: AABB = mesh_node.global_transform * mesh_node.get_aabb()
		visual_aabb = visual_aabb.merge(world_box) if has_visual else world_box
		has_visual = true
	for raw_shape in root_node.find_children("*", "CollisionShape3D", true, false):
		var shape_node := raw_shape as CollisionShape3D
		if shape_node == null or shape_node.shape == null or shape_node.disabled:
			continue
		collision_shapes += 1
		var collision_body := shape_node.get_parent() as CollisionObject3D
		if collision_body != null and (collision_body.collision_layer & 2) != 0:
			replay_guard_collision_shapes += 1
		var debug_mesh := shape_node.shape.get_debug_mesh()
		if debug_mesh == null:
			continue
		var world_box: AABB = shape_node.global_transform * debug_mesh.get_aabb()
		collision_aabb = collision_aabb.merge(world_box) if has_collision else world_box
		has_collision = true
	var visual_distance := _minimum_xz_distance(samples, visual_aabb) if has_visual else INF
	var collision_distance := _minimum_xz_distance(samples, collision_aabb) if has_collision else INF
	var surface_crossing := _trajectory_crosses_render_surface(root_node, samples, visual_aabb) if has_visual else false
	var preserved_encounter := PRESERVED_DEMO_ENCOUNTERS.has(String(root_node.name))
	var raw_envelope_overlap := has_visual and visual_aabb.position.y <= WATER_LEVEL_Y + 2.5 and visual_aabb.end.y >= WATER_LEVEL_Y - 2.5 and visual_distance < DEMO_CLEARANCE_METERS
	return {
		"name": root_node.name,
		"path": String(root_node.get_path()),
		"global_position": _vector(root_node.global_position),
		"local_position": _vector(root_node.position),
		"visual_aabb": _aabb(visual_aabb) if has_visual else {},
		"collision_aabb": _aabb(collision_aabb) if has_collision else {},
		"visual_overlaps_waterline": has_visual and visual_aabb.position.y <= WATER_LEVEL_Y + 2.5 and visual_aabb.end.y >= WATER_LEVEL_Y - 2.5,
		"collision_overlaps_waterline": has_collision and collision_aabb.position.y <= WATER_LEVEL_Y + 2.5 and collision_aabb.end.y >= WATER_LEVEL_Y - 2.5,
		"collision_shape_count": collision_shapes,
		"replay_guard_collision_shape_count": replay_guard_collision_shapes,
		"minimum_trajectory_distance_to_visual_aabb_m": visual_distance,
		"minimum_trajectory_distance_to_collision_aabb_m": collision_distance,
		"raw_trajectory_envelope_overlap": raw_envelope_overlap,
		"render_surface_crossing": surface_crossing,
		"preserved_demo_encounter": preserved_encounter,
		"preserved_reason": String(PRESERVED_DEMO_ENCOUNTERS.get(String(root_node.name), "")),
		"relocated_for_crossing_fix": RELOCATED_CROSSING_ROCKS.has(String(root_node.name)),
		"trajectory_conflict": surface_crossing and not preserved_encounter,
	}


func _trajectory_crosses_render_surface(root_node: Node3D, samples: Array[Vector2], visual_aabb: AABB) -> bool:
	if visual_aabb.position.y > WATER_LEVEL_Y or visual_aabb.end.y < WATER_LEVEL_Y:
		return false
	var triangles: Array[PackedVector3Array] = []
	for raw_mesh in root_node.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := raw_mesh as MeshInstance3D
		if mesh_node == null or mesh_node.mesh == null or not mesh_node.is_visible_in_tree():
			continue
		if not String(mesh_node.get_path()).contains("Rock_Body"):
			continue
		var faces := mesh_node.mesh.get_faces()
		for index in range(0, faces.size(), 3):
			if index + 2 >= faces.size():
				break
			var a: Vector3 = mesh_node.global_transform * faces[index]
			var b: Vector3 = mesh_node.global_transform * faces[index + 1]
			var c: Vector3 = mesh_node.global_transform * faces[index + 2]
			if minf(a.y, minf(b.y, c.y)) > WATER_LEVEL_Y or maxf(a.y, maxf(b.y, c.y)) < WATER_LEVEL_Y:
				continue
			triangles.append(PackedVector3Array([a, b, c]))
	if triangles.is_empty():
		return false
	for index in range(samples.size() - 1):
		var from_2d := samples[index]
		var to_2d := samples[index + 1]
		if maxf(from_2d.x, to_2d.x) < visual_aabb.position.x or minf(from_2d.x, to_2d.x) > visual_aabb.end.x:
			continue
		if maxf(from_2d.y, to_2d.y) < visual_aabb.position.z or minf(from_2d.y, to_2d.y) > visual_aabb.end.z:
			continue
		var from := Vector3(from_2d.x, WATER_LEVEL_Y, from_2d.y)
		var to := Vector3(to_2d.x, WATER_LEVEL_Y, to_2d.y)
		for triangle in triangles:
			# Geometry3D's triangle test is winding-sensitive. Test both directions so
			# a surface crossing cannot be hidden by the approach side of the replay.
			if (
				Geometry3D.segment_intersects_triangle(from, to, triangle[0], triangle[1], triangle[2]) != null
				or Geometry3D.segment_intersects_triangle(from, to, triangle[0], triangle[2], triangle[1]) != null
			):
				return true
	return false


func _count_physics_guard_hits(guard: Node) -> int:
	if guard == null:
		return 0
	var hit_count := 0
	var space: PhysicsDirectSpaceState3D = current_scene.get_world_3d().direct_space_state
	for child in guard.get_children():
		if child is not StaticBody3D:
			continue
		var body := child as StaticBody3D
		var query := PhysicsPointQueryParameters3D.new()
		query.position = body.global_position
		query.collision_mask = 1
		query.collide_with_bodies = true
		query.collide_with_areas = false
		var hits: Array[Dictionary] = space.intersect_point(query, 64)
		var found := false
		for hit in hits:
			if (hit as Dictionary).get("collider") == body:
				found = true
				break
		if found:
			hit_count += 1
	return hit_count


func _count_blocking_guard_hits(guard: Node) -> int:
	if guard == null:
		return 0
	var sphere := SphereShape3D.new()
	sphere.radius = 0.05
	var space: PhysicsDirectSpaceState3D = current_scene.get_world_3d().direct_space_state
	var blocking_hits := 0
	for child in guard.get_children():
		if child is not StaticBody3D:
			continue
		var body := child as StaticBody3D
		var collision_shape := body.get_node_or_null("SolidWaterlineCollision") as CollisionShape3D
		if collision_shape == null or collision_shape.shape is not BoxShape3D:
			continue
		var box := collision_shape.shape as BoxShape3D
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = sphere
		query.transform = Transform3D(Basis.IDENTITY, body.global_position + Vector3(box.size.x * 0.5 + 4.0, 0.0, 0.0))
		query.motion = Vector3(-8.0, 0.0, 0.0)
		query.collision_mask = 2
		query.collide_with_bodies = true
		query.collide_with_areas = false
		var fractions := space.cast_motion(query)
		if not fractions.is_empty() and float(fractions[0]) < 0.999:
			blocking_hits += 1
	return blocking_hits


func _trajectory_replay_sweep_blocks(samples: Array[Vector2]) -> Array[Dictionary]:
	var space: PhysicsDirectSpaceState3D = current_scene.get_world_3d().direct_space_state
	var blocking_segments: Array[Dictionary] = []
	for index in range(samples.size() - 1):
		var from_2d := samples[index]
		var to_2d := samples[index + 1]
		if from_2d.distance_squared_to(to_2d) <= 0.000001:
			continue
		var from := Vector3(from_2d.x, WATER_LEVEL_Y, from_2d.y)
		var to := Vector3(to_2d.x, WATER_LEVEL_Y, to_2d.y)
		var query := PhysicsRayQueryParameters3D.create(from, to, 2)
		query.collide_with_bodies = true
		query.collide_with_areas = false
		query.hit_back_faces = true
		query.hit_from_inside = true
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			var collider := hit.get("collider") as Object
			var hit_name := String(collider.get_meta("source_large_rock", collider.get_path() if collider is Node else "unknown")) if collider != null else "unknown"
			var hit_position := hit.get("position", from) as Vector3
			blocking_segments.append({
				"sample_index": index,
				"from": {"x": from_2d.x, "z": from_2d.y},
				"to": {"x": to_2d.x, "z": to_2d.y},
				"hit": {"x": hit_position.x, "z": hit_position.z},
				"collider": hit_name,
			})
	return blocking_segments


func _load_trajectory_points() -> Array[Vector2]:
	var points: Array[Vector2] = []
	for path in TRAJECTORY_PATHS:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var parsed = JSON.parse_string(file.get_as_text())
		file.close()
		if parsed is not Dictionary:
			continue
		for raw_sample in (parsed as Dictionary).get("samples", []) as Array:
			var sample := raw_sample as Dictionary
			points.append(Vector2(float(sample.get("x", 0.0)), float(sample.get("z", 0.0))))
	return points


func _minimum_xz_distance(points: Array[Vector2], box: AABB) -> float:
	var minimum := INF
	for point in points:
		var dx := maxf(maxf(box.position.x - point.x, 0.0), point.x - box.end.x)
		var dz := maxf(maxf(box.position.z - point.y, 0.0), point.y - box.end.z)
		minimum = minf(minimum, Vector2(dx, dz).length())
	return minimum


func _vector(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}


func _aabb(value: AABB) -> Dictionary:
	return {"position": _vector(value.position), "size": _vector(value.size), "end": _vector(value.end)}


func _finish(
	records: Array[Dictionary],
	errors: Array[String],
	guard_status: Dictionary = {},
	physics_guard_hits: int = 0,
	ship_sized_sweep_blocking_hits: int = 0,
	released_trajectory_replay_sweep_blocks: Array[Dictionary] = []
) -> void:
	var conflicts := records.filter(func(record: Dictionary) -> bool: return bool(record.get("trajectory_conflict", false)))
	var preserved_encounters := records.filter(func(record: Dictionary) -> bool: return bool(record.get("preserved_demo_encounter", false)))
	var payload := {
		"format": "large_rock_collision_audit_v1",
		"passed": errors.is_empty(),
		"water_level_y": WATER_LEVEL_Y,
		"required_demo_clearance_meters": DEMO_CLEARANCE_METERS,
		"large_rock_count": records.size(),
		"waterline_guard_status": guard_status,
		"physics_guard_center_hits": physics_guard_hits,
		"ship_sized_sweep_blocking_hits": ship_sized_sweep_blocking_hits,
		"released_trajectory_replay_sweep_block_count": released_trajectory_replay_sweep_blocks.size(),
		"released_trajectory_replay_sweep_blocks": released_trajectory_replay_sweep_blocks,
		"trajectory_conflict_count": conflicts.size(),
		"trajectory_conflicts": conflicts,
		"preserved_demo_encounter_count": preserved_encounters.size(),
		"preserved_demo_encounters": preserved_encounters,
		"rocks": records,
		"errors": errors,
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "  "))
		file.close()
	print("LARGE_ROCK_AUDIT:%s:%d:%d" % ["PASS" if errors.is_empty() else "FAIL", records.size(), conflicts.size()])
	for conflict in conflicts:
		print("CONFLICT:%s:%.2f" % [String(conflict.get("name", "")), float(conflict.get("minimum_trajectory_distance_to_visual_aabb_m", INF))])
	quit(0 if errors.is_empty() else 1)

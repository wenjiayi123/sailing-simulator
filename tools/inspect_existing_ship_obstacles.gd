extends SceneTree


func _initialize() -> void:
	call_deferred("_inspect")


func _inspect() -> void:
	var packed := load("res://main.tscn") as PackedScene
	if packed == null:
		quit(1)
		return
	var world := packed.instantiate()
	root.add_child(world)
	for index in range(4):
		await process_frame
	print("EXISTING_NAVIGATION_DATA: %s" % JSON.stringify((world.get_node("ShipNavigationObstacles") as Node).call("get_radar_obstacle_data")))
	for node in world.find_children("*", "CollisionShape3D", true, false):
		var collision := node as CollisionShape3D
		if collision == null or collision.shape == null:
			continue
		var owner_path := String(collision.get_path())
		if not ("GroundedPlate" in owner_path or "FloatingRock" in owner_path or "NavigationRock" in owner_path):
			continue
		var bounds := _world_xz_bounds(collision)
		if bounds.is_empty():
			continue
		var center := Vector2(
			(float(bounds["min_x"]) + float(bounds["max_x"])) * 0.5,
			(float(bounds["min_z"]) + float(bounds["max_z"])) * 0.5
		)
		if center.length() > 230.0:
			continue
		print("EXISTING_COLLIDER: path=%s center=(%.1f,%.1f) x=[%.1f,%.1f] z=[%.1f,%.1f] y=[%.1f,%.1f]" % [
			owner_path,
			center.x,
			center.y,
			float(bounds["min_x"]),
			float(bounds["max_x"]),
			float(bounds["min_z"]),
			float(bounds["max_z"]),
			float(bounds["min_y"]),
			float(bounds["max_y"]),
		])
	quit(0)


func _world_xz_bounds(collision: CollisionShape3D) -> Dictionary:
	var points := PackedVector3Array()
	if collision.shape is ConcavePolygonShape3D:
		points = (collision.shape as ConcavePolygonShape3D).get_faces()
	elif collision.shape is CylinderShape3D:
		var cylinder := collision.shape as CylinderShape3D
		for x_sign in [-1.0, 1.0]:
			for y_sign in [-1.0, 1.0]:
				for z_sign in [-1.0, 1.0]:
					points.append(Vector3(x_sign * cylinder.radius, y_sign * cylinder.height * 0.5, z_sign * cylinder.radius))
	else:
		return {}
	if points.is_empty():
		return {}
	var first := collision.global_transform * points[0]
	var min_x := first.x
	var max_x := first.x
	var min_y := first.y
	var max_y := first.y
	var min_z := first.z
	var max_z := first.z
	for point in points:
		var world_point := collision.global_transform * point
		min_x = minf(min_x, world_point.x)
		max_x = maxf(max_x, world_point.x)
		min_y = minf(min_y, world_point.y)
		max_y = maxf(max_y, world_point.y)
		min_z = minf(min_z, world_point.z)
		max_z = maxf(max_z, world_point.z)
	return {
		"min_x": min_x,
		"max_x": max_x,
		"min_y": min_y,
		"max_y": max_y,
		"min_z": min_z,
		"max_z": max_z,
	}

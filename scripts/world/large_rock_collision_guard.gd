extends Node3D
class_name LargeRockCollisionGuard

const LARGE_ROCK_MANIFEST := preload("res://scripts/world/large_rock_obstacle_manifest.gd")

@export var navigation_environment_path: NodePath = NodePath("../NavigationEnvironment")
@export var water_level_y: float = -140.73494
@export var guard_height_meters: float = 10.0
@export var minimum_guard_span_meters: float = 8.0
@export var minimum_training_span_meters: float = 2.0
@export var supplemental_guard_roots: Array[String] = [
	"GroundedPlate_01_BroadLandMass",
	"GroundedPlate_04_WideBridgeSlab",
	"GroundedPlate_07_AncientWallPlate",
]

var _guard_records: Array[Dictionary] = []
var _obstacle_records: Array[Dictionary] = []
var _missing_manifest_rocks: Array[String] = []
var _unexpected_scene_rocks: Array[String] = []
var _restored_transform_count := 0
var _registered_collision_body_count := 0
var _base_environment_active := true


func _ready() -> void:
	add_to_group(&"large_rock_collision_guard_system")
	call_deferred("rebuild_guards")


func rebuild_guards() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_guard_records.clear()
	_obstacle_records.clear()
	_missing_manifest_rocks.clear()
	_unexpected_scene_rocks.clear()
	_restored_transform_count = 0
	_registered_collision_body_count = 0
	var environment := get_node_or_null(navigation_environment_path) as Node3D
	if environment == null:
		push_error("LargeRockCollisionGuard: NavigationEnvironment is missing")
		return
	var found_names: Dictionary = {}
	for collection_path in LARGE_ROCK_MANIFEST.collection_paths():
		var collection := environment.get_node_or_null(collection_path)
		if collection == null:
			continue
		for child in collection.get_children():
			if child is Node3D:
				var rock_root := child as Node3D
				var rock_name := String(rock_root.name)
				found_names[rock_name] = true
				if not LARGE_ROCK_MANIFEST.has_rock(rock_name):
					if rock_root is Label3D:
						continue
					_unexpected_scene_rocks.append(rock_name)
					continue
				var canonical := LARGE_ROCK_MANIFEST.canonical_transform(rock_name)
				if not rock_root.transform.is_equal_approx(canonical):
					rock_root.transform = canonical
					_restored_transform_count += 1
				_register_navigation_obstacle(rock_root)
				_add_waterline_guard(rock_root)
	for raw_name in LARGE_ROCK_MANIFEST.rock_names():
		var rock_name := String(raw_name)
		if not found_names.has(rock_name):
			_missing_manifest_rocks.append(rock_name)
	_apply_base_environment_state()


func set_base_environment_active(active: bool) -> void:
	_base_environment_active = active
	_apply_base_environment_state()


func is_base_environment_active() -> bool:
	return _base_environment_active


func get_guard_status() -> Dictionary:
	var environment := get_node_or_null(navigation_environment_path) as Node3D
	var shared_background := environment.get_node_or_null("BackgroundWalls") as Node3D if environment != null else null
	return {
		"base_environment_active": _base_environment_active,
		"shared_background_active": shared_background != null and shared_background.visible,
		"manifest_schema_version": LARGE_ROCK_MANIFEST.manifest_schema_version(),
		"manifest_id": LARGE_ROCK_MANIFEST.manifest_id(),
		"expected_rock_count": LARGE_ROCK_MANIFEST.expected_rock_count(),
		"registered_obstacle_count": _obstacle_records.size(),
		"registered_collision_body_count": _registered_collision_body_count,
		"restored_transform_count": _restored_transform_count,
		"missing_manifest_rocks": _missing_manifest_rocks.duplicate(),
		"unexpected_scene_rocks": _unexpected_scene_rocks.duplicate(),
		"guard_count": _guard_records.size(),
		"water_level_y": water_level_y,
		"rocks": _guard_records.duplicate(true),
	}


func get_navigation_obstacle_records() -> Array[Dictionary]:
	if not _base_environment_active:
		return []
	if _obstacle_records.is_empty():
		rebuild_guards()
	return _obstacle_records.duplicate(true)


func _apply_base_environment_state() -> void:
	var environment := get_node_or_null(navigation_environment_path) as Node3D
	if environment != null:
		# The original four-wall panorama and bright lake surface are the shared
		# visual foundation for every task. Dedicated tasks only suppress the old
		# floating-rock world and its collision bodies.
		environment.visible = true
		_set_legacy_visual_tree_enabled(environment, _base_environment_active)
		_set_collision_tree_enabled(environment, _base_environment_active)
	visible = _base_environment_active
	_set_collision_tree_enabled(self, _base_environment_active)


func _set_legacy_visual_tree_enabled(environment: Node3D, enabled: bool) -> void:
	var shared_background := environment.get_node_or_null("BackgroundWalls") as Node3D
	for raw_child in environment.get_children():
		var child := raw_child as Node3D
		if child == null:
			continue
		if child == shared_background:
			child.visible = true
			continue
		if enabled:
			child.visible = bool(child.get_meta("dedicated_scene_saved_visible", child.visible))
		else:
			if not child.has_meta("dedicated_scene_saved_visible"):
				child.set_meta("dedicated_scene_saved_visible", child.visible)
			child.visible = false


func _set_collision_tree_enabled(root: Node, enabled: bool) -> void:
	var collision_nodes: Array[Node] = []
	if root is CollisionObject3D:
		collision_nodes.append(root)
	for child in root.find_children("*", "CollisionObject3D", true, false):
		collision_nodes.append(child)
	for raw_node in collision_nodes:
		var body := raw_node as CollisionObject3D
		if body == null:
			continue
		if enabled:
			body.collision_layer = int(body.get_meta("dedicated_scene_saved_collision_layer", body.collision_layer))
			body.collision_mask = int(body.get_meta("dedicated_scene_saved_collision_mask", body.collision_mask))
		else:
			if not body.has_meta("dedicated_scene_saved_collision_layer"):
				body.set_meta("dedicated_scene_saved_collision_layer", body.collision_layer)
				body.set_meta("dedicated_scene_saved_collision_mask", body.collision_mask)
			body.collision_layer = 0
			body.collision_mask = 0


func _register_navigation_obstacle(rock_root: Node3D) -> void:
	rock_root.add_to_group(&"ship_navigation_obstacle")
	rock_root.add_to_group(&"large_rock_navigation_obstacle")
	rock_root.set_meta("large_rock_manifest_id", LARGE_ROCK_MANIFEST.manifest_id())
	var collision_shape_count := 0
	for raw_body in rock_root.find_children("*", "CollisionObject3D", true, false):
		var body := raw_body as CollisionObject3D
		if body == null:
			continue
		body.collision_layer |= 3
		body.collision_mask |= 1
		body.add_to_group(&"ship_navigation_obstacle")
		body.add_to_group(&"large_rock_exact_collision")
		body.set_meta("source_large_rock", String(rock_root.name))
		body.set_meta("large_rock_manifest_id", LARGE_ROCK_MANIFEST.manifest_id())
		_registered_collision_body_count += 1
	for raw_shape in rock_root.find_children("*", "CollisionShape3D", true, false):
		var shape_node := raw_shape as CollisionShape3D
		if shape_node != null and shape_node.shape != null and not shape_node.disabled:
			collision_shape_count += 1
	var collision_bounds := _collision_world_bounds(rock_root)
	var bounds := collision_bounds if not collision_bounds.is_empty() else _visible_world_bounds(rock_root)
	if bounds.is_empty():
		return
	var box := bounds.get("aabb", AABB()) as AABB
	var span_x := maxf(box.size.x, minimum_training_span_meters)
	var span_z := maxf(box.size.z, minimum_training_span_meters)
	_obstacle_records.append({
		"name": String(rock_root.name),
		"kind": "terrain",
		"shape": "box",
		"position": Vector3(box.get_center().x, water_level_y, box.get_center().z),
		"size": Vector3(span_x, maxf(box.size.y, 1.0), span_z),
		"source": "large_rock_manifest",
		"manifest_id": LARGE_ROCK_MANIFEST.manifest_id(),
		"collision_shape_count": collision_shape_count,
		"collision_bounds_used": not collision_bounds.is_empty(),
		"canonical_local_transform": rock_root.transform,
	})


func _add_waterline_guard(rock_root: Node3D) -> void:
	# Route-side rocks keep their exact generated concave collision meshes. A
	# broad AABB guard there would incorrectly block valid close avoidance. Only
	# the reviewed legacy rocks whose rendered surfaces crossed the released replay
	# receive this supplemental solid guard after relocation.
	if String(rock_root.name) not in supplemental_guard_roots:
		return
	var visible_bounds := _visible_world_bounds(rock_root)
	if visible_bounds.is_empty():
		return
	var box := visible_bounds.get("aabb", AABB()) as AABB
	if box.position.y > water_level_y + guard_height_meters * 0.5:
		return
	if box.end.y < water_level_y - guard_height_meters * 0.5:
		return
	var span_x := maxf(box.size.x, minimum_guard_span_meters)
	var span_z := maxf(box.size.z, minimum_guard_span_meters)
	var body := StaticBody3D.new()
	body.name = "WaterlineGuard_%s" % rock_root.name
	body.add_to_group(&"ship_navigation_obstacle")
	body.add_to_group(&"large_rock_waterline_guard")
	# Layer 1 blocks the ship. Layer 2 is also set so the release audit can
	# isolate this solid guard from the legacy concave rock collision meshes.
	body.collision_layer = 3
	body.collision_mask = 1
	body.position = Vector3(box.get_center().x, water_level_y, box.get_center().z)
	body.set_meta("source_large_rock", String(rock_root.name))
	body.set_meta("visible_world_aabb", box)
	add_child(body)
	var collision := CollisionShape3D.new()
	collision.name = "SolidWaterlineCollision"
	var shape := BoxShape3D.new()
	shape.size = Vector3(span_x, guard_height_meters, span_z)
	collision.shape = shape
	body.add_child(collision)
	_guard_records.append({
		"rock": String(rock_root.name),
		"guard": String(body.name),
		"center": {"x": body.global_position.x, "y": body.global_position.y, "z": body.global_position.z},
		"size": {"x": span_x, "y": guard_height_meters, "z": span_z},
	})


func _visible_world_bounds(root_node: Node3D) -> Dictionary:
	var combined := AABB()
	var found := false
	for raw_mesh in root_node.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := raw_mesh as MeshInstance3D
		if mesh_node == null or mesh_node.mesh == null or not mesh_node.is_visible_in_tree():
			continue
		var world_box: AABB = mesh_node.global_transform * mesh_node.get_aabb()
		combined = combined.merge(world_box) if found else world_box
		found = true
	return {"aabb": combined} if found else {}


func _collision_world_bounds(root_node: Node3D) -> Dictionary:
	var combined := AABB()
	var found := false
	for raw_shape in root_node.find_children("*", "CollisionShape3D", true, false):
		var shape_node := raw_shape as CollisionShape3D
		if shape_node == null or shape_node.shape == null or shape_node.disabled:
			continue
		var debug_mesh := shape_node.shape.get_debug_mesh()
		if debug_mesh == null:
			continue
		var world_box: AABB = shape_node.global_transform * debug_mesh.get_aabb()
		combined = combined.merge(world_box) if found else world_box
		found = true
	return {"aabb": combined} if found else {}

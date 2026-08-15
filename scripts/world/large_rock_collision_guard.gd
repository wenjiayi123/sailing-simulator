extends Node3D
class_name LargeRockCollisionGuard

@export var navigation_environment_path: NodePath = NodePath("../NavigationEnvironment")
@export var water_level_y: float = -140.73494
@export var guard_height_meters: float = 10.0
@export var minimum_guard_span_meters: float = 8.0
@export var supplemental_guard_roots: Array[String] = [
	"GroundedPlate_01_BroadLandMass",
	"GroundedPlate_04_WideBridgeSlab",
	"GroundedPlate_07_AncientWallPlate",
]

var _guard_records: Array[Dictionary] = []


func _ready() -> void:
	add_to_group(&"large_rock_collision_guard_system")
	call_deferred("rebuild_guards")


func rebuild_guards() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_guard_records.clear()
	var environment := get_node_or_null(navigation_environment_path) as Node3D
	if environment == null:
		push_error("LargeRockCollisionGuard: NavigationEnvironment is missing")
		return
	for collection_path in [
		"TerrainUpperWalkableRegions/FloatingPlates/Rock3A_Comparison_Set",
		"TerrainUpperWalkableRegions/FloatingPlates/GroundedRockPlate_Comparison_Set",
	]:
		var collection := environment.get_node_or_null(collection_path)
		if collection == null:
			continue
		for child in collection.get_children():
			if child is Node3D:
				_add_waterline_guard(child as Node3D)


func get_guard_status() -> Dictionary:
	return {
		"guard_count": _guard_records.size(),
		"water_level_y": water_level_y,
		"rocks": _guard_records.duplicate(true),
	}


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

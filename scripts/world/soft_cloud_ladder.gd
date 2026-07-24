@tool
extends Node3D

@export var start_surface_path: NodePath = NodePath()
@export var end_surface_path: NodePath = NodePath()
@export var start_point := Vector3(38.4, 1.75, 82.5)
@export var end_point := Vector3(44.0, 16.2, -111.0)
@export_range(2.0, 8.0, 0.1) var width := 4.6
@export_range(0.0, 4.0, 0.05) var sag := 1.15
@export_range(4, 36, 1) var segments := 20
@export_range(0.0, 1.5, 0.05) var side_sway := 0.38
@export_range(0.0, 2.0, 0.01) var endpoint_outset := 0.0
@export_range(0.0, 4.0, 0.01) var endpoint_platform_overlap := 0.03
@export_range(-1.0, 2.0, 0.01) var endpoint_height_offset := -0.04
@export_range(0.0, 1.0, 0.01) var end_anchor_center_blend := 0.0
@export_range(1.0, 8.0, 0.1) var landing_length := 3.2
@export var collision_enabled := true
@export_group("Cloud Skin")
@export_file("*.png") var deck_skin_path := "res://assets/textures/world/soft_cloud_ladder/cloud_bridge_deck_skin.png"
@export_file("*.png") var step_skin_path := "res://assets/textures/world/soft_cloud_ladder/cloud_bridge_step_skin.png"
@export_file("*.png") var rope_skin_path := "res://assets/textures/world/soft_cloud_ladder/cloud_bridge_rope_skin.png"
@export_file("*.png") var puff_skin_path := "res://assets/textures/world/soft_cloud_ladder/cloud_bridge_puff_skin.png"
@export_range(0.0, 1.0, 0.01) var cloud_skin_glow := 0.24

var _route_start := Vector3.ZERO
var _route_end := Vector3.ZERO
var _active_sag := 0.0
var _active_segments := 0


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	_clear_generated()
	if segments <= 0:
		return

	_resolve_route()
	var horizontal_delta := Vector3(_route_end.x - _route_start.x, 0.0, _route_end.z - _route_start.z)
	if horizontal_delta.length_squared() <= 0.001:
		return

	var direction := horizontal_delta.normalized()
	var side := Vector3(direction.z, 0.0, -direction.x).normalized()
	_active_segments = maxi(segments, int(ceil((_route_end - _route_start).length() / 4.4)))
	_active_sag = maxf(sag, horizontal_delta.length() * 0.06)

	var generated := Node3D.new()
	generated.name = "GeneratedSoftCloudLadder"
	add_child(generated)

	var deck_mat := _make_material("mat_soft_cloud_ladder_deck", Color(0.70, 0.92, 1.0, 0.38), 0.20, _load_skin_texture(deck_skin_path), Color(0.40, 0.78, 1.0, 1), cloud_skin_glow * 0.72)
	var step_mat := _make_material("mat_soft_cloud_ladder_steps", Color(0.88, 0.98, 1.0, 0.52), 0.18, _load_skin_texture(step_skin_path), Color(0.66, 0.90, 1.0, 1), cloud_skin_glow * 0.96)
	var rope_mat := _make_material("mat_soft_cloud_ladder_rope", Color(0.68, 0.84, 0.96, 0.76), 0.52, _load_skin_texture(rope_skin_path), Color(0.38, 0.70, 0.94, 1), cloud_skin_glow * 0.42)
	var puff_mat := _make_material("mat_soft_cloud_ladder_puffs", Color(0.84, 0.96, 1.0, 0.40), 0.34, _load_skin_texture(puff_skin_path), Color(0.54, 0.84, 1.0, 1), cloud_skin_glow * 0.54)

	_build_endpoint_landings(generated, direction, deck_mat)
	_build_deck(generated, side, deck_mat)
	_build_soft_steps(generated, side, step_mat)
	_build_side_ropes(generated, side, rope_mat)
	_build_cloud_puffs(generated, side, puff_mat)


func _clear_generated() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()


func _build_deck(parent: Node3D, side: Vector3, mat: Material) -> void:
	for i in range(_active_segments):
		var t0 := float(i) / float(_active_segments)
		var t1 := float(i + 1) / float(_active_segments)
		var a := _point_at(t0, side)
		var b := _point_at(t1, side)
		_add_oriented_box(parent, "CloudLadder_Deck_%02d" % i, a, b, width, 0.22, mat, collision_enabled)


func _build_endpoint_landings(parent: Node3D, direction: Vector3, mat: Material) -> void:
	var inner := clampf(endpoint_platform_overlap, 0.01, landing_length * 0.25)
	var outer := maxf(landing_length - inner, 0.4)
	_add_oriented_box(
		parent,
		"CloudLadder_TailorCornerLanding",
		_route_start - direction * inner,
		_route_start + direction * outer,
		width * 1.12,
		0.20,
		mat,
		collision_enabled
	)
	_add_oriented_box(
		parent,
		"CloudLadder_PeachArrayCornerLanding",
		_route_end - direction * outer,
		_route_end + direction * inner,
		width * 1.12,
		0.20,
		mat,
		collision_enabled
	)


func _build_soft_steps(parent: Node3D, side: Vector3, mat: Material) -> void:
	for i in range(_active_segments + 1):
		var t := float(i) / float(_active_segments)
		var center := _point_at(t, side) + Vector3.UP * 0.16
		var half_width := width * (0.34 + 0.05 * sin(t * PI))
		_add_oriented_box(
			parent,
			"CloudLadder_SoftStep_%02d" % i,
			center - side * half_width,
			center + side * half_width,
			0.38,
			0.13,
			mat,
			false
		)


func _build_side_ropes(parent: Node3D, side: Vector3, mat: Material) -> void:
	for i in range(_active_segments):
		var t0 := float(i) / float(_active_segments)
		var t1 := float(i + 1) / float(_active_segments)
		var rise0 := Vector3.UP * (0.74 + 0.10 * sin(t0 * PI))
		var rise1 := Vector3.UP * (0.74 + 0.10 * sin(t1 * PI))
		var base0 := _point_at(t0, side)
		var base1 := _point_at(t1, side)
		var rail_offset := side * width * 0.54
		_add_oriented_box(parent, "CloudLadder_RopeLeft_%02d" % i, base0 + rail_offset + rise0, base1 + rail_offset + rise1, 0.13, 0.13, mat, false)
		_add_oriented_box(parent, "CloudLadder_RopeRight_%02d" % i, base0 - rail_offset + rise0, base1 - rail_offset + rise1, 0.13, 0.13, mat, false)

	for i in range(0, _active_segments + 1, 3):
		var t := float(i) / float(_active_segments)
		var deck := _point_at(t, side) + Vector3.UP * 0.24
		var rail_height := Vector3.UP * (0.78 + 0.10 * sin(t * PI))
		for direction in [-1.0, 1.0]:
			var rail: Vector3 = deck + side * width * 0.54 * direction + rail_height
			var lower: Vector3 = deck + side * width * 0.40 * direction
			_add_oriented_box(parent, "CloudLadder_Hanger_%02d_%s" % [i, "L" if direction < 0.0 else "R"], rail, lower, 0.08, 0.08, mat, false)


func _build_cloud_puffs(parent: Node3D, side: Vector3, mat: Material) -> void:
	for i in range(_active_segments + 1):
		if i % 2 != 0:
			continue
		var t := float(i) / float(_active_segments)
		var center := _point_at(t, side) + Vector3.UP * 0.03
		var scale_base := 0.82 + 0.16 * sin(t * PI)
		_add_puff(parent, "CloudLadder_PuffCenter_%02d" % i, center, Vector3(scale_base * 1.35, 0.20, scale_base * 0.72), mat)
		_add_puff(parent, "CloudLadder_PuffLeft_%02d" % i, center + side * width * 0.34, Vector3(scale_base * 0.96, 0.18, scale_base * 0.54), mat)
		_add_puff(parent, "CloudLadder_PuffRight_%02d" % i, center - side * width * 0.34, Vector3(scale_base * 0.96, 0.18, scale_base * 0.54), mat)

	_add_anchor_puffs(parent, "TailorAnchorCloud", _route_start, side, mat)
	_add_anchor_puffs(parent, "PeachArrayAltarAnchorCloud", _route_end, side, mat)


func _add_anchor_puffs(parent: Node3D, label: String, point: Vector3, side: Vector3, mat: Material) -> void:
	_add_puff(parent, "%s_00" % label, point + Vector3.UP * 0.12, Vector3(1.65, 0.28, 0.95), mat)
	_add_puff(parent, "%s_01" % label, point + side * 1.15 + Vector3.UP * 0.08, Vector3(1.05, 0.22, 0.70), mat)
	_add_puff(parent, "%s_02" % label, point - side * 1.15 + Vector3.UP * 0.08, Vector3(1.05, 0.22, 0.70), mat)


func _point_at(t: float, side: Vector3) -> Vector3:
	var eased := _route_start.lerp(_route_end, t)
	var sag_offset := sin(t * PI) * _active_sag
	var sway_offset := sin(t * TAU * 1.5) * side_sway * sin(t * PI)
	return eased - Vector3.UP * sag_offset + side * sway_offset


func _resolve_route() -> void:
	var start_surface := get_node_or_null(start_surface_path) as MeshInstance3D
	var end_surface := get_node_or_null(end_surface_path) as MeshInstance3D
	var start_center := _surface_top_center(start_surface, start_point)
	var end_center := _surface_top_center(end_surface, end_point)
	var toward_end := _flat_direction(start_center, end_center)
	var toward_start := -toward_end
	_route_start = _surface_edge_point(start_surface, toward_end, start_point, 0.0)
	_route_end = _surface_edge_point(end_surface, toward_start, end_point, end_anchor_center_blend)


func _surface_top_center(surface: MeshInstance3D, fallback: Vector3) -> Vector3:
	if surface == null:
		return fallback
	var aabb := surface.get_aabb()
	return surface.global_transform * (aabb.get_center() + Vector3(0.0, aabb.size.y * 0.5, 0.0))


func _surface_edge_point(surface: MeshInstance3D, toward: Vector3, fallback: Vector3, center_blend: float) -> Vector3:
	if surface == null:
		return fallback

	var aabb := surface.get_aabb()
	var center_local := aabb.get_center()
	var center_world: Vector3 = surface.global_transform * (center_local + Vector3(0.0, aabb.size.y * 0.5, 0.0))
	var best_point := center_world
	var best_score := -1.0e20
	var edge_midpoints := [
		center_local + Vector3(aabb.size.x * 0.5, aabb.size.y * 0.5, 0.0),
		center_local + Vector3(-aabb.size.x * 0.5, aabb.size.y * 0.5, 0.0),
		center_local + Vector3(0.0, aabb.size.y * 0.5, aabb.size.z * 0.5),
		center_local + Vector3(0.0, aabb.size.y * 0.5, -aabb.size.z * 0.5),
	]
	for local_point in edge_midpoints:
		var world_point: Vector3 = surface.global_transform * (local_point as Vector3)
		var flat_delta := Vector3(world_point.x - center_world.x, 0.0, world_point.z - center_world.z)
		var score := flat_delta.dot(toward)
		if score > best_score:
			best_score = score
			best_point = world_point
	var edge_point := best_point + toward * endpoint_outset - toward * endpoint_platform_overlap
	return edge_point.lerp(center_world, clampf(center_blend, 0.0, 1.0)) + Vector3.UP * endpoint_height_offset


func _flat_direction(from: Vector3, to: Vector3) -> Vector3:
	var delta := Vector3(to.x - from.x, 0.0, to.z - from.z)
	if delta.length_squared() <= 0.001:
		return Vector3.FORWARD
	return delta.normalized()


func _add_oriented_box(parent: Node3D, name: String, start: Vector3, end: Vector3, box_width: float, box_height: float, mat: Material, add_collision: bool) -> MeshInstance3D:
	var delta := end - start
	var length := delta.length()
	if length <= 0.001:
		return _add_box(parent, name, start, Vector3(box_width, box_height, box_width), mat, add_collision)

	var forward := delta / length
	var side := Vector3(forward.z, 0.0, -forward.x)
	if side.length_squared() <= 0.0001:
		side = Vector3.RIGHT
	else:
		side = side.normalized()

	var normal := forward.cross(side).normalized()
	if normal.y < 0.0:
		normal = -normal
		side = -side

	var node := _add_box(parent, name, Vector3.ZERO, Vector3(box_width, box_height, length), mat, add_collision)
	node.transform = Transform3D(Basis(side, normal, forward), start.lerp(end, 0.5))
	return node


func _add_box(parent: Node3D, name: String, position: Vector3, size: Vector3, mat: Material, add_collision: bool) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = mat

	var node := MeshInstance3D.new()
	node.name = name
	node.mesh = mesh
	node.position = position
	parent.add_child(node)
	if add_collision:
		_add_local_box_collision(node, "%s_collision" % name, size)
	return node


func _add_puff(parent: Node3D, name: String, position: Vector3, puff_scale: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 24
	mesh.rings = 12
	mesh.material = mat

	var node := MeshInstance3D.new()
	node.name = name
	node.mesh = mesh
	node.position = position
	node.scale = puff_scale
	parent.add_child(node)
	return node


func _add_local_box_collision(parent: Node3D, name: String, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = name
	parent.add_child(body)

	var shape := CollisionShape3D.new()
	shape.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)


func _load_skin_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if ResourceLoader.exists(path, "Texture2D"):
		var texture := ResourceLoader.load(path, "Texture2D") as Texture2D
		if texture != null:
			return texture
	if not path.begins_with("res://"):
		return null
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null or image.is_empty():
		return null
	return ImageTexture.create_from_image(image)


func _make_material(name: String, color: Color, roughness: float, albedo_texture: Texture2D = null, emission_color := Color.TRANSPARENT, emission_strength := 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.resource_name = name
	mat.albedo_color = color
	mat.albedo_texture = albedo_texture
	mat.roughness = roughness
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mat.uv1_scale = Vector3(1.0, 1.0, 1.0)
	if emission_strength > 0.0:
		mat.emission_enabled = true
		mat.emission = emission_color
		mat.emission_energy_multiplier = emission_strength
	if color.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat

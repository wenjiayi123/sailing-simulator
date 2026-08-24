@tool
extends Node3D

const MAT_TOP: Material = preload("res://assets/materials/floating_rock_3a_demo/Top_Ground.tres")
const MAT_DRY: Material = preload("res://assets/materials/floating_rock_3a_demo/Premium_Reference_Rock_Dry.tres")
const MAT_WET: Material = preload("res://assets/materials/floating_rock_3a_demo/Premium_Reference_Rock_Wet.tres")
const MAT_BOTTOM: Material = preload("res://assets/materials/floating_rock_3a_demo/Premium_Reference_Rock_Bottom.tres")
const MAT_CAVE: Material = preload("res://assets/materials/floating_rock_3a_demo/Premium_Reference_Cave_Rock.tres")
const MAT_MOSS: Material = preload("res://assets/materials/floating_rock_3a_demo/Moss_Region.tres")

const SEGMENTS_TOP := 112

@export_range(0.0, 5000.0, 1.0) var variant_seed := 0.0
@export_range(0.72, 1.45, 0.01) var plate_length_scale := 1.0
@export_range(0.72, 1.45, 0.01) var plate_width_scale := 1.0
@export_range(0.78, 1.42, 0.01) var grounded_mass_scale := 1.0
@export_range(0.78, 1.36, 0.01) var ground_depth_scale := 1.0
@export_range(0.62, 1.45, 0.01) var wall_irregularity := 1.0
@export_range(0.72, 1.45, 0.01) var buttress_scale := 1.0
@export_range(-1.4, 1.4, 0.01) var primary_cave_angle_offset := 0.0
@export_range(-1.4, 1.4, 0.01) var secondary_cave_angle_offset := 0.0
@export_range(0.72, 1.35, 0.01) var cave_scale := 1.0
@export var secondary_cave_enabled := true
@export_range(-1.2, 1.2, 0.01) var waterfall_angle_offset := 0.0
@export_range(0.7, 1.45, 0.01) var debris_density := 1.0
@export var rebuild_on_ready := true

var _top_collision_faces := PackedVector3Array()
var _body_collision_faces := PackedVector3Array()
var _marker_materials: Dictionary = {}


func _ready() -> void:
	if rebuild_on_ready:
		_rebuild_demo()


func _rebuild_demo() -> void:
	_top_collision_faces = PackedVector3Array()
	_body_collision_faces = PackedVector3Array()

	_build_rock_body()
	_build_fx_placeholders()
	_build_vegetation_placeholders()
	_build_collision()


func _build_rock_body() -> void:
	_set_mesh("Rock_Body/Top_Platform_Main", _build_top_platform_data(), MAT_TOP, true, false)
	_set_mesh("Rock_Body/Top_Edge_Cliff", _build_top_edge_cliff_data(), MAT_DRY, false, true)
	_set_mesh("Rock_Body/Side_Rock_Large_A", _build_side_panel_data(-PI, -PI * 0.5, 28, 14, _phase(10.0)), MAT_DRY, false, true)
	_set_mesh("Rock_Body/Side_Rock_Large_B", _build_side_panel_data(-PI * 0.5, 0.0, 28, 14, _phase(11.0)), MAT_DRY, false, true)
	_set_mesh("Rock_Body/Side_Rock_Large_C", _build_side_panel_data(0.0, PI * 0.5, 28, 14, _phase(12.0)), MAT_DRY, false, true)
	_set_mesh("Rock_Body/Side_Rock_Large_D", _build_side_panel_data(PI * 0.5, PI, 28, 14, _phase(13.0)), MAT_DRY, false, true)

	_set_mesh("Rock_Body/Side_Rock_Buttress_A", _build_buttress_data(-2.45 + _variant_signed(20.0) * 0.24, 0.06, 0.92, 0.72, 0.70, _phase(21.0)), MAT_DRY, false, true)
	_set_mesh("Rock_Body/Side_Rock_Buttress_B", _build_buttress_data(-0.38 + _variant_signed(22.0) * 0.28, 0.16, 1.00, 0.56, 0.92, _phase(23.0)), MAT_DRY, false, true)
	_set_mesh("Rock_Body/Side_Rock_Buttress_C", _build_buttress_data(1.84 + _variant_signed(24.0) * 0.30, 0.04, 0.96, 0.66, 0.78, _phase(25.0)), MAT_DRY, false, true)

	_set_mesh("Rock_Body/Ground_Contact_Base_Main", _build_ground_contact_base_data(), MAT_BOTTOM, false, true)
	_set_mesh("Rock_Body/Ground_Contact_Foot_A", _build_buttress_data(-2.92 + _variant_signed(31.0) * 0.20, 0.46, 1.0, 0.90, 0.34, _phase(32.0)), MAT_BOTTOM, false, true)
	_set_mesh("Rock_Body/Ground_Contact_Foot_B", _build_buttress_data(0.18 + _variant_signed(33.0) * 0.22, 0.42, 1.0, 0.82, 0.38, _phase(34.0)), MAT_BOTTOM, false, true)
	_set_mesh("Rock_Body/Ground_Contact_Foot_C", _build_buttress_data(2.38 + _variant_signed(35.0) * 0.25, 0.50, 1.0, 0.74, 0.34, _phase(36.0)), MAT_BOTTOM, false, true)

	_set_mesh("Rock_Body/Hollow_Cave_Main", _build_cave_disc_data(_primary_cave_angle(), 0.42, 0.0), MAT_CAVE, false, true)
	if secondary_cave_enabled:
		_set_mesh("Rock_Body/Hollow_Cave_Secondary", _build_cave_disc_data(_secondary_cave_angle(), 0.58, 1.0), MAT_CAVE, false, true)
	else:
		_set_mesh("Rock_Body/Hollow_Cave_Secondary", {"vertices": [], "indices": PackedInt32Array()}, MAT_CAVE, false, false)
	_set_mesh("Rock_Body/Hollow_Cave_Edge_A", _build_cave_edge_data(_primary_cave_angle(), 0.42, _phase(41.0)), MAT_DRY, false, true)
	_set_mesh("Rock_Body/Hollow_Cave_Edge_B", _build_cave_edge_data(_secondary_cave_angle(), 0.58, _phase(42.0)), MAT_BOTTOM, false, true)

	_set_mesh("Rock_Body/Overhang_Shelf_A", _build_blob_data(_body_point(-1.38, 0.25, 0.90), _radial_dir(-1.38), Vector3.UP, _tangent_dir(-1.38), Vector3(1.55, 0.34, 0.62) * buttress_scale, _phase(51.0), 8, 22), MAT_DRY, false, true)
	_set_mesh("Rock_Body/Overhang_Shelf_B", _build_blob_data(_body_point(1.12, 0.34, 0.74), _tangent_dir(1.12), Vector3.UP, _radial_dir(1.12), Vector3(0.70, 0.42, 1.45) * buttress_scale, _phase(52.0), 8, 22), MAT_DRY, false, true)

	_populate_debris_cluster("Rock_Body/Debris_Cluster_A", _body_point(-2.70, 0.08, 0.42), Vector3(1.20, 0.28, 0.74), max(6, int(round(9.0 * debris_density))), _phase(61.0))
	_populate_debris_cluster("Rock_Body/Debris_Cluster_B", _body_point(0.95, 0.52, 0.38), Vector3(0.92, 0.85, 0.70), max(6, int(round(8.0 * debris_density))), _phase(62.0))
	_populate_debris_cluster("Rock_Body/Debris_Cluster_C", _body_point(2.35, 0.88, 0.26), Vector3(0.80, 0.48, 0.56), max(5, int(round(7.0 * debris_density))), _phase(63.0))


func _build_fx_placeholders() -> void:
	_set_mesh("FX_Placeholders/Waterfall_Channel_A", _build_waterfall_channel_data(), MAT_WET, false, false)
	var water_angle := _waterfall_angle()
	_set_marker("FX_Placeholders/Mist_Point_A", _body_point(water_angle, 0.44, 0.40), Color(0.65, 0.82, 0.86, 1.0), 0.20)
	_set_marker("FX_Placeholders/Mist_Point_B", _body_point(water_angle, 0.92, 0.28), Color(0.60, 0.76, 0.80, 1.0), 0.16)


func _build_vegetation_placeholders() -> void:
	_set_mesh("Vegetation_Placeholders/Moss_Area_A", _build_patch_data(Vector3(-2.1, 0.24, 1.25), Vector3.RIGHT, Vector3.FORWARD, 1.70, 0.95, _phase(71.0)), MAT_MOSS, false, false)
	var moss_angle := 1.45 + _variant_signed(72.0) * 0.36
	_set_mesh("Vegetation_Placeholders/Moss_Area_B", _build_patch_data(_body_point(moss_angle, 0.24, 0.10), _tangent_dir(moss_angle), Vector3.UP, 0.88, 0.74, _phase(73.0)), MAT_MOSS, false, false)
	var moss_angle_c := -2.05 + _variant_signed(74.0) * 0.30
	_set_mesh("Vegetation_Placeholders/Moss_Area_C", _build_patch_data(_body_point(moss_angle_c, 0.52, 0.08), _tangent_dir(moss_angle_c), Vector3.UP, 0.72, 0.84, _phase(75.0)), MAT_MOSS, false, false)
	_set_marker("Vegetation_Placeholders/Root_Vine_Attach_A", _body_point(-1.72, 0.22, 0.18), Color(0.22, 0.48, 0.20, 1.0), 0.13)
	_set_marker("Vegetation_Placeholders/Root_Vine_Attach_B", _body_point(1.76, 0.38, 0.18), Color(0.20, 0.42, 0.18, 1.0), 0.13)


func _build_collision() -> void:
	_configure_navigation_collision_body(get_node_or_null("Collision/Walkable_Collision") as StaticBody3D)
	_configure_navigation_collision_body(get_node_or_null("Collision/Body_Collision") as StaticBody3D)
	var walk_shape := get_node_or_null("Collision/Walkable_Collision/Walkable_CollisionShape") as CollisionShape3D
	if walk_shape != null:
		var top_shape := ConcavePolygonShape3D.new()
		top_shape.set_faces(_top_collision_faces)
		walk_shape.shape = top_shape

	var body_shape := get_node_or_null("Collision/Body_Collision/Body_CollisionShape") as CollisionShape3D
	if body_shape != null:
		var coarse_shape := ConcavePolygonShape3D.new()
		coarse_shape.set_faces(_body_collision_faces)
		body_shape.shape = coarse_shape


func _configure_navigation_collision_body(body: StaticBody3D) -> void:
	if body == null:
		return
	# Keep layer 1 for normal CharacterBody3D navigation. Layer 2 lets recorded
	# replay sweeps isolate large-rock geometry without mistaking the water/floor
	# body for an obstacle.
	body.collision_layer |= 2
	body.collision_mask = 1
	body.add_to_group(&"ship_navigation_obstacle")
	body.add_to_group(&"large_rock_exact_collision")
	body.set_meta("source_large_rock", String(name))


func _set_mesh(path: String, data: Dictionary, material: Material, collect_top: bool, collect_body: bool) -> void:
	var node := get_node_or_null(path) as MeshInstance3D
	if node == null:
		return

	var vertices: Array = data["vertices"]
	var indices: PackedInt32Array = data["indices"]
	var uvs: Array = data.get("uvs", [])
	node.mesh = _make_array_mesh(vertices, indices, material, uvs)
	node.extra_cull_margin = 3.0
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	if collect_top or collect_body:
		_collect_collision_faces(vertices, indices, collect_top, collect_body)


func _make_array_mesh(vertices: Array, indices: PackedInt32Array, material: Material, uvs: Array = []) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for idx in indices:
		var v: Vector3 = vertices[idx]
		if not uvs.is_empty():
			st.set_uv(uvs[idx])
		else:
			st.set_uv(_rock_side_uv(v))
		st.add_vertex(v)
	st.generate_normals()
	var mesh := st.commit()
	mesh.surface_set_material(0, material)
	return mesh


func _rock_side_uv(point: Vector3) -> Vector2:
	var angle: float = atan2(point.z, point.x)
	var u: float = fposmod(angle / TAU + 1.0, 1.0)
	var depth_span: float = maxf(8.0, _ground_depth() + 0.70)
	var v: float = clamp((-point.y + 0.25) / depth_span, 0.0, 1.0)
	return Vector2(u, v)


func _collect_collision_faces(vertices: Array, indices: PackedInt32Array, collect_top: bool, collect_body: bool) -> void:
	# ConcavePolygonShape3D uses triangle winding to choose its blocking side.
	# Keep the render mesh unchanged and reverse the collision-only copy so the
	# exterior/top blocks entry while the hollow inner side remains escapable.
	for triangle_start in range(0, indices.size(), 3):
		if triangle_start + 2 >= indices.size():
			break

		var a: Vector3 = vertices[indices[triangle_start]]
		var b: Vector3 = vertices[indices[triangle_start + 1]]
		var c: Vector3 = vertices[indices[triangle_start + 2]]
		if collect_top:
			_top_collision_faces.append(a)
			_top_collision_faces.append(c)
			_top_collision_faces.append(b)
		if collect_body:
			_body_collision_faces.append(a)
			_body_collision_faces.append(c)
			_body_collision_faces.append(b)


func _build_top_platform_data() -> Dictionary:
	var rings := 10
	var segments := SEGMENTS_TOP
	var vertices: Array = []
	var indices := PackedInt32Array()

	vertices.append(Vector3(0.0, 0.20, 0.0))
	for r in range(1, rings + 1):
		var t := float(r) / float(rings)
		for i in range(segments):
			var angle := TAU * float(i) / float(segments)
			var edge := _top_edge_point(angle)
			var p := Vector3(edge.x * t, _top_height(angle, t), edge.z * t)
			vertices.append(p)

	for i in range(segments):
		_tri(indices, 0, _ring_index(1, (i + 1) % segments, segments), _ring_index(1, i, segments))

	for r in range(1, rings):
		for i in range(segments):
			var a := _ring_index(r, i, segments)
			var b := _ring_index(r, (i + 1) % segments, segments)
			var c := _ring_index(r + 1, i, segments)
			var d := _ring_index(r + 1, (i + 1) % segments, segments)
			_tri(indices, a, d, c)
			_tri(indices, a, b, d)

	return {"vertices": vertices, "indices": indices}


func _build_top_edge_cliff_data() -> Dictionary:
	var levels := 6
	var segments := SEGMENTS_TOP
	var vertices: Array = []
	var indices := PackedInt32Array()

	for j in range(levels):
		var v := float(j) / float(levels - 1)
		for i in range(segments):
			var angle := TAU * float(i) / float(segments)
			var top := _top_edge_point(angle)
			top.y = _top_height(angle, 1.0) - 0.02
			var lower := _body_point(angle, 0.105, 0.03)
			var radial := _radial_dir(angle)
			var broken := (sin(angle * 7.0 + v * 8.0 + _phase(80.0)) * 0.16 + sin(angle * 15.0 + _phase(81.0)) * 0.07) * wall_irregularity
			var p: Vector3 = top.lerp(lower, v)
			p += radial * broken
			p.y -= abs(sin(angle * 5.0 + v * 5.0 + _phase(82.0))) * 0.10 * v
			vertices.append(p)

	for j in range(levels - 1):
		for i in range(segments):
			var a := j * segments + i
			var b := j * segments + ((i + 1) % segments)
			var c := (j + 1) * segments + i
			var d := (j + 1) * segments + ((i + 1) % segments)
			_tri(indices, a, b, d)
			_tri(indices, a, d, c)

	return {"vertices": vertices, "indices": indices}


func _build_side_panel_data(angle_start: float, angle_end: float, segments: int, levels: int, seed_offset: float) -> Dictionary:
	var vertices: Array = []
	var indices := PackedInt32Array()
	var cols := segments + 1

	for j in range(levels + 1):
		var v := float(j) / float(levels)
		for i in range(cols):
			var u := float(i) / float(segments)
			var angle: float = lerp(angle_start, angle_end, u)
			var p := _body_point(angle, v, _panel_outward_noise(angle, v, seed_offset))
			p += _tangent_dir(angle) * (sin(v * 14.0 + angle * 4.0 + seed_offset) * 0.06 * wall_irregularity)
			vertices.append(p)

	for j in range(levels):
		for i in range(segments):
			var angle_mid: float = lerp(angle_start, angle_end, (float(i) + 0.5) / float(segments))
			var v_mid := (float(j) + 0.5) / float(levels)
			if _inside_any_cave(angle_mid, v_mid):
				continue
			var a := j * cols + i
			var b := j * cols + i + 1
			var c := (j + 1) * cols + i
			var d := (j + 1) * cols + i + 1
			_tri(indices, a, b, d)
			_tri(indices, a, d, c)

	return {"vertices": vertices, "indices": indices}


func _build_ground_contact_base_data() -> Dictionary:
	var levels := 5
	var segments := 96
	var vertices: Array = []
	var indices := PackedInt32Array()

	for j in range(levels):
		var v: float = lerp(0.78, 1.0, float(j) / float(levels - 1))
		for i in range(segments):
			var angle := TAU * float(i) / float(segments)
			var p := _body_point(angle, v, 0.03)
			p.y -= float(j) * 0.06
			vertices.append(p)

	for j in range(levels - 1):
		for i in range(segments):
			var a := j * segments + i
			var b := j * segments + ((i + 1) % segments)
			var c := (j + 1) * segments + i
			var d := (j + 1) * segments + ((i + 1) % segments)
			_tri(indices, a, b, d)
			_tri(indices, a, d, c)

	var center_index := vertices.size()
	vertices.append(Vector3(0.0, -_ground_depth() - 0.28, 0.0))
	var last_start := (levels - 1) * segments
	for i in range(segments):
		_tri(indices, center_index, last_start + i, last_start + ((i + 1) % segments))

	return {"vertices": vertices, "indices": indices}


func _build_buttress_data(angle: float, start_v: float, end_v: float, width: float, outward: float, seed: float) -> Dictionary:
	var levels := 11
	var segments := 18
	var vertices: Array = []
	var indices := PackedInt32Array()
	var radial := _radial_dir(angle)
	var tangent := _tangent_dir(angle)

	for j in range(levels):
		var t := float(j) / float(levels - 1)
		var v: float = lerp(start_v, end_v, t)
		var center := _body_point(angle + sin(t * PI + seed) * 0.04, v, outward * buttress_scale)
		var radius_t: float = width * buttress_scale * lerp(1.08, 0.78, t)
		var radius_r: float = width * 0.50 * buttress_scale * lerp(1.0, 0.84, t)
		for i in range(segments):
			var a := TAU * float(i) / float(segments)
			var rough := 0.88 + _hash(seed + float(i) * 1.9, float(j) * 4.7) * 0.24
			vertices.append(center + tangent * (cos(a) * radius_t * rough) + radial * (sin(a) * radius_r * rough))

	for j in range(levels - 1):
		for i in range(segments):
			var a0 := j * segments + i
			var b0 := j * segments + ((i + 1) % segments)
			var c0 := (j + 1) * segments + i
			var d0 := (j + 1) * segments + ((i + 1) % segments)
			_tri(indices, a0, b0, d0)
			_tri(indices, a0, d0, c0)

	return {"vertices": vertices, "indices": indices}


func _build_cave_disc_data(angle: float, v: float, slot: float) -> Dictionary:
	var rings := 5
	var segments := 48
	var vertices: Array = []
	var indices := PackedInt32Array()
	var radial := _radial_dir(angle)
	var tangent := _tangent_dir(angle)
	var center := _body_point(angle, v, -0.82 * cave_scale)
	center.y -= 0.10

	vertices.append(center - radial * 0.24)
	for r in range(1, rings + 1):
		var t := float(r) / float(rings)
		for i in range(segments):
			var a := TAU * float(i) / float(segments)
			var jag := 1.0 + sin(a * 5.0 + _phase(90.0 + slot)) * 0.14 + sin(a * 11.0 + _phase(91.0 + slot)) * 0.09
			var p := center + tangent * (cos(a) * 1.42 * cave_scale * t * jag) + Vector3.UP * (sin(a) * 0.98 * cave_scale * t * jag)
			p -= radial * (0.32 + (1.0 - t) * 0.36 + sin(a * 3.0 + _phase(92.0 + slot)) * 0.05)
			vertices.append(p)

	for i in range(segments):
		_tri(indices, 0, _ring_index(1, i, segments), _ring_index(1, (i + 1) % segments, segments))

	for r in range(1, rings):
		for i in range(segments):
			var a0 := _ring_index(r, i, segments)
			var b0 := _ring_index(r, (i + 1) % segments, segments)
			var c0 := _ring_index(r + 1, i, segments)
			var d0 := _ring_index(r + 1, (i + 1) % segments, segments)
			_tri(indices, a0, c0, d0)
			_tri(indices, a0, d0, b0)

	return {"vertices": vertices, "indices": indices}


func _build_cave_edge_data(angle: float, v: float, seed: float) -> Dictionary:
	var segments := 42
	var vertices: Array = []
	var indices := PackedInt32Array()
	var radial := _radial_dir(angle)
	var tangent := _tangent_dir(angle)
	var center := _body_point(angle, v, 0.08)

	for i in range(segments + 1):
		var theta := -PI * 0.12 + PI * 1.24 * float(i) / float(segments)
		var rough := 1.0 + sin(theta * 4.0 + seed) * 0.14 + sin(theta * 9.0 + seed * 1.7) * 0.07
		var outer := center + tangent * (cos(theta) * 1.84 * cave_scale * rough) + Vector3.UP * (sin(theta) * 1.22 * cave_scale * rough) + radial * 0.24
		var inner := center + tangent * (cos(theta) * 1.16 * cave_scale * rough) + Vector3.UP * (sin(theta) * 0.74 * cave_scale * rough) - radial * 0.14
		vertices.append(outer)
		vertices.append(inner)

	for i in range(segments):
		var a := i * 2
		var b := i * 2 + 1
		var c := (i + 1) * 2
		var d := (i + 1) * 2 + 1
		_tri(indices, a, c, d)
		_tri(indices, a, d, b)

	return {"vertices": vertices, "indices": indices}


func _build_waterfall_channel_data() -> Dictionary:
	var angle := _waterfall_angle()
	var levels := 18
	var columns := 5
	var vertices: Array = []
	var uvs: Array = []
	var indices := PackedInt32Array()

	for j in range(levels + 1):
		var t := float(j) / float(levels)
		var v: float = lerp(0.02, 1.0, t)
		for i in range(columns):
			var lane := (float(i) / float(columns - 1) - 0.5)
			var local_angle := angle + lane * 0.13
			var outward: float = lerp(0.11, 0.18, smoothstep(0.74, 1.0, v)) - abs(lane) * 0.04
			var p := _body_point(local_angle, v, outward)
			p.y += sin(t * 17.0 + lane * 3.0 + _phase(101.0)) * 0.04
			vertices.append(p)
			uvs.append(Vector2(float(i) / float(columns - 1), t))

	for j in range(levels):
		for i in range(columns - 1):
			var a := j * columns + i
			var b := j * columns + i + 1
			var c := (j + 1) * columns + i
			var d := (j + 1) * columns + i + 1
			_tri(indices, a, b, d)
			_tri(indices, a, d, c)

	return {"vertices": vertices, "indices": indices, "uvs": uvs}


func _build_blob_data(center: Vector3, axis_x: Vector3, axis_y: Vector3, axis_z: Vector3, scale: Vector3, seed: float, rings: int, segments: int) -> Dictionary:
	var vertices: Array = []
	var indices := PackedInt32Array()
	var ax := axis_x.normalized()
	var ay := axis_y.normalized()
	var az := axis_z.normalized()

	for j in range(rings + 1):
		var lat := -PI * 0.5 + PI * float(j) / float(rings)
		var y := sin(lat)
		var ring := cos(lat)
		for i in range(segments):
			var a := TAU * float(i) / float(segments)
			var rough := 0.78 + _hash(seed + float(i) * 3.1, float(j) * 7.7) * 0.36 + sin(a * 5.0 + seed) * 0.055
			var p := center
			p += ax * (cos(a) * ring * scale.x * rough)
			p += ay * (y * scale.y * (0.88 + _hash(seed, float(j)) * 0.18))
			p += az * (sin(a) * ring * scale.z * rough)
			vertices.append(p)

	for j in range(rings):
		for i in range(segments):
			var a0 := j * segments + i
			var b0 := j * segments + ((i + 1) % segments)
			var c0 := (j + 1) * segments + i
			var d0 := (j + 1) * segments + ((i + 1) % segments)
			_tri(indices, a0, b0, d0)
			_tri(indices, a0, d0, c0)

	return {"vertices": vertices, "indices": indices}


func _build_patch_data(center: Vector3, axis_u: Vector3, axis_v: Vector3, radius_u: float, radius_v: float, seed: float) -> Dictionary:
	var rings := 4
	var segments := 34
	var vertices: Array = []
	var indices := PackedInt32Array()
	var u_axis := axis_u.normalized()
	var v_axis := axis_v.normalized()
	var normal := u_axis.cross(v_axis).normalized()
	if normal.length() < 0.001:
		normal = Vector3.UP
	vertices.append(center + normal * 0.04)

	for r in range(1, rings + 1):
		var t := float(r) / float(rings)
		for i in range(segments):
			var a := TAU * float(i) / float(segments)
			var rough := 1.0 + sin(a * 4.0 + seed) * 0.13 + sin(a * 9.0 + seed) * 0.065
			var p := center + normal * 0.045
			p += u_axis * (cos(a) * radius_u * t * rough)
			p += v_axis * (sin(a) * radius_v * t * rough)
			vertices.append(p)

	for i in range(segments):
		_tri(indices, 0, _ring_index(1, (i + 1) % segments, segments), _ring_index(1, i, segments))

	for r in range(1, rings):
		for i in range(segments):
			var a0 := _ring_index(r, i, segments)
			var b0 := _ring_index(r, (i + 1) % segments, segments)
			var c0 := _ring_index(r + 1, i, segments)
			var d0 := _ring_index(r + 1, (i + 1) % segments, segments)
			_tri(indices, a0, d0, c0)
			_tri(indices, a0, b0, d0)

	return {"vertices": vertices, "indices": indices}


func _populate_debris_cluster(path: String, center: Vector3, spread: Vector3, count: int, seed: float) -> void:
	var cluster := get_node_or_null(path) as Node3D
	if cluster == null:
		return
	_clear_children(cluster)

	for i in range(count):
		var fi := float(i)
		var offset := Vector3(
			(_hash(seed, fi) - 0.5) * 2.0 * spread.x,
			(_hash(seed + 12.0, fi) - 0.5) * 2.0 * spread.y,
			(_hash(seed + 24.0, fi) - 0.5) * 2.0 * spread.z
		)
		var size := Vector3(
			lerp(0.14, 0.42, _hash(seed + 3.0, fi)),
			lerp(0.10, 0.32, _hash(seed + 5.0, fi)),
			lerp(0.12, 0.38, _hash(seed + 7.0, fi))
		)
		var data := _build_blob_data(center + offset, Vector3.RIGHT, Vector3.UP, Vector3.FORWARD, size, seed + fi * 13.0, 5, 12)
		var stone := MeshInstance3D.new()
		stone.name = "Rock_%02d" % (i + 1)
		stone.mesh = _make_array_mesh(data["vertices"], data["indices"], MAT_DRY)
		stone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		cluster.add_child(stone)
		_collect_collision_faces(data["vertices"], data["indices"], false, true)


func _set_marker(path: String, position_value: Vector3, color: Color, size: float) -> void:
	var marker := get_node_or_null(path) as Marker3D
	if marker == null:
		return
	marker.position = position_value
	_clear_children(marker)

	var box := BoxMesh.new()
	box.size = Vector3.ONE * size
	var preview := MeshInstance3D.new()
	preview.name = "Preview_Point"
	preview.mesh = box
	preview.material_override = _marker_material(color)
	marker.add_child(preview)


func _marker_material(color: Color) -> Material:
	var key := color.to_html()
	if _marker_materials.has(key):
		return _marker_materials[key]
	var mat := StandardMaterial3D.new()
	mat.resource_name = "Marker_%s" % key
	mat.albedo_color = color
	mat.roughness = 0.85
	_marker_materials[key] = mat
	return mat


func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.free()


func _top_edge_point(angle: float) -> Vector3:
	var shape := 1.0
	shape += sin(angle * 2.0 + _phase(111.0)) * 0.08
	shape += sin(angle * 3.0 + _phase(112.0)) * 0.13
	shape += sin(angle * 6.0 + _phase(113.0)) * 0.06
	shape += sin(angle * 11.0 + _phase(114.0)) * 0.035
	return Vector3(cos(angle) * 7.20 * plate_length_scale * shape, 0.0, sin(angle) * 5.10 * plate_width_scale * shape)


func _top_height(angle: float, radial_t: float) -> float:
	var lift := 0.18
	lift += sin(angle * 2.0 + radial_t * 2.0 + _phase(121.0)) * 0.035
	lift += sin(angle * 7.0 + radial_t * 6.0 + _phase(122.0)) * 0.026 * radial_t
	lift -= smoothstep(0.78, 1.0, radial_t) * 0.10
	return lift


func _body_point(angle: float, v: float, outward: float = 0.0) -> Vector3:
	var t: float = clamp(v, 0.0, 1.0)
	var y: float = lerp(-0.42, -_ground_depth(), pow(t, 1.02))
	var base_factor: float = lerp(1.0, grounded_mass_scale * (0.92 + sin(angle * 2.0 + _phase(131.0)) * 0.10), smoothstep(0.30, 1.0, t))
	var rx: float = 6.88 * plate_length_scale * base_factor
	var rz: float = 4.86 * plate_width_scale * base_factor
	var large := 1.0
	large += sin(angle * 3.0 + _phase(132.0)) * 0.12 * wall_irregularity
	large += sin(angle * 5.0 + t * 2.8 + _phase(133.0)) * 0.08 * wall_irregularity
	large += sin(angle * 9.0 + t * 7.2 + _phase(134.0)) * 0.045 * wall_irregularity
	var strata := sin(t * PI * 11.0 + angle * 2.0 + _phase(135.0)) * 0.16 * wall_irregularity
	var ledge := sin(floor(t * 10.0) * 1.4 + angle * 3.5 + _phase(136.0)) * 0.10 * wall_irregularity
	var radial := _radial_dir(angle)
	var p := Vector3(cos(angle) * rx * large, y, sin(angle) * rz * large)
	p += radial * (strata + ledge + outward)
	return p


func _panel_outward_noise(angle: float, v: float, seed_offset: float) -> float:
	return (sin(angle * 6.0 + v * 12.0 + seed_offset) * 0.10 + sin(angle * 13.0 + seed_offset) * 0.045) * wall_irregularity


func _inside_any_cave(angle: float, v: float) -> bool:
	if _inside_cave(angle, v, _primary_cave_angle(), 0.42, cave_scale):
		return true
	if secondary_cave_enabled and _inside_cave(angle, v, _secondary_cave_angle(), 0.58, cave_scale * 0.82):
		return true
	return false


func _inside_cave(angle: float, v: float, cave_angle: float, cave_v: float, scale_value: float) -> bool:
	var da := _angle_delta(angle, cave_angle) / (0.33 * scale_value)
	var dv := (v - cave_v) / (0.145 * scale_value)
	var ragged := 1.0 + sin(angle * 18.0 + v * 12.0 + _phase(141.0)) * 0.22 + sin(angle * 8.0 + _phase(142.0)) * 0.12
	return da * da + dv * dv < ragged


func _primary_cave_angle() -> float:
	return 0.54 + primary_cave_angle_offset + _variant_signed(151.0) * 0.16


func _secondary_cave_angle() -> float:
	return -2.26 + secondary_cave_angle_offset + _variant_signed(152.0) * 0.18


func _waterfall_angle() -> float:
	return 1.25 + waterfall_angle_offset + _variant_signed(153.0) * 0.14


func _ground_depth() -> float:
	return 12.4 * ground_depth_scale


func _ring_index(ring: int, i: int, segments: int) -> int:
	return 1 + (ring - 1) * segments + i


func _tri(indices: PackedInt32Array, a: int, b: int, c: int) -> void:
	indices.append(a)
	indices.append(b)
	indices.append(c)


func _angle_delta(a: float, b: float) -> float:
	return abs(fposmod(a - b + PI, TAU) - PI)


func _radial_dir(angle: float) -> Vector3:
	return Vector3(cos(angle), 0.0, sin(angle)).normalized()


func _tangent_dir(angle: float) -> Vector3:
	return Vector3(-sin(angle), 0.0, cos(angle)).normalized()


func _phase(slot: float) -> float:
	return variant_seed * 0.173 + slot * 2.317


func _variant_hash(slot: float) -> float:
	return _hash(variant_seed + slot * 17.13, slot * 3.77)


func _variant_signed(slot: float) -> float:
	return _variant_hash(slot) * 2.0 - 1.0


func _hash(a: float, b: float) -> float:
	return fposmod(sin(a * 12.9898 + b * 78.233) * 43758.5453123, 1.0)

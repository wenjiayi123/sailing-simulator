@tool
extends Node3D

const MAT_TOP: Material = preload("res://assets/materials/floating_rock_3a_demo/Top_Ground.tres")
const MAT_DRY: Material = preload("res://assets/materials/floating_rock_3a_demo/Premium_Reference_Rock_Dry.tres")
const MAT_WET: Material = preload("res://assets/materials/floating_rock_3a_demo/Premium_Reference_Rock_Wet.tres")
const MAT_BOTTOM: Material = preload("res://assets/materials/floating_rock_3a_demo/Premium_Reference_Rock_Bottom.tres")
const MAT_CAVE: Material = preload("res://assets/materials/floating_rock_3a_demo/Premium_Reference_Cave_Rock.tres")
const MAT_MOSS: Material = preload("res://assets/materials/floating_rock_3a_demo/Moss_Region.tres")

const CAVE_ANGLE := 0.28
const CAVE_V := 0.43
const SEGMENTS_TOP := 96

@export_range(0.8, 1.4, 0.01) var shape_scale := 1.0
@export_range(0.0, 5000.0, 1.0) var variant_seed := 0.0
@export_range(0.72, 1.35, 0.01) var silhouette_x := 1.0
@export_range(0.72, 1.35, 0.01) var silhouette_z := 1.0
@export_range(0.82, 1.35, 0.01) var root_depth_scale := 1.0
@export_range(0.78, 1.42, 0.01) var root_width_scale := 1.0
@export_range(0.72, 1.42, 0.01) var protrusion_scale := 1.0
@export_range(-1.1, 1.1, 0.01) var cave_angle_offset := 0.0
@export_range(-0.14, 0.14, 0.01) var cave_vertical_offset := 0.0
@export_range(0.74, 1.34, 0.01) var cave_scale := 1.0
@export_range(-1.1, 1.1, 0.01) var waterfall_angle_offset := 0.0
@export_range(0.75, 1.35, 0.01) var debris_density := 1.0
@export_range(0.72, 1.42, 0.01) var hanging_rock_scale := 1.0
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
	_build_preview_setup()


func _build_rock_body() -> void:
	_set_mesh("Rock_Body/Top_Platform_Main", _build_top_platform_data(), MAT_TOP, true, false)
	_set_mesh("Rock_Body/Top_Edge_Cliff", _build_top_edge_cliff_data(), MAT_DRY, false, true)
	_set_mesh("Rock_Body/Side_Rock_Large_A", _build_side_panel_data(-2.65, -0.82, 26, 13, false, _phase(10.0)), MAT_DRY, false, true)
	_set_mesh("Rock_Body/Side_Rock_Large_B", _build_side_panel_data(-0.82, 0.92, 30, 13, true, _phase(11.0)), MAT_DRY, false, true)
	_set_mesh("Rock_Body/Side_Rock_Large_C", _build_side_panel_data(0.92, 3.63, 42, 13, false, _phase(12.0)), MAT_DRY, false, true)

	var protrusion_angle_a := -1.24 + _variant_signed(21.0) * 0.38
	var radial_a := _radial_dir(protrusion_angle_a)
	var tangent_a := _tangent_dir(protrusion_angle_a)
	_set_mesh(
		"Rock_Body/Side_Rock_Protrusion_A",
		_build_blob_data(
			_body_point(protrusion_angle_a, 0.30 + _variant_hash(22.0) * 0.16, 0.72 * protrusion_scale),
			radial_a,
			Vector3.UP,
			tangent_a,
			Vector3(2.15, 0.42, 0.88) * protrusion_scale * lerp(0.88, 1.16, _variant_hash(23.0)),
			_phase(24.0),
			9,
			24
		),
		MAT_DRY,
		false,
		true
	)

	var protrusion_angle_b := 2.18 + _variant_signed(25.0) * 0.44
	var radial_b := _radial_dir(protrusion_angle_b)
	var tangent_b := _tangent_dir(protrusion_angle_b)
	_set_mesh(
		"Rock_Body/Side_Rock_Protrusion_B",
		_build_blob_data(
			_body_point(protrusion_angle_b, 0.44 + _variant_hash(26.0) * 0.16, 0.46 * protrusion_scale),
			tangent_b,
			Vector3.UP,
			radial_b,
			Vector3(0.58, 1.75, 0.96) * protrusion_scale * lerp(0.86, 1.18, _variant_hash(27.0)),
			_phase(28.0),
			10,
			22
		),
		MAT_DRY,
		false,
		true
	)

	_set_mesh("Rock_Body/Bottom_Root_Main", _build_bottom_root_main_data(), MAT_BOTTOM, false, true)
	_set_mesh("Rock_Body/Bottom_Root_Sub_A", _build_sub_root_data(-0.62 + _variant_signed(31.0) * 0.34, 0.66 + _variant_hash(32.0) * 0.12, 3.65 * root_depth_scale * lerp(0.88, 1.18, _variant_hash(33.0)), Vector2(0.74, 0.52) * root_width_scale, _phase(34.0)), MAT_BOTTOM, false, true)
	_set_mesh("Rock_Body/Bottom_Root_Sub_B", _build_sub_root_data(2.42 + _variant_signed(35.0) * 0.36, 0.68 + _variant_hash(36.0) * 0.12, 3.15 * root_depth_scale * lerp(0.84, 1.22, _variant_hash(37.0)), Vector2(0.62, 0.48) * root_width_scale, _phase(38.0)), MAT_BOTTOM, false, true)

	_set_mesh("Rock_Body/Hollow_Cave_Main", _build_cave_disc_data(), MAT_CAVE, false, true)
	_set_mesh("Rock_Body/Hollow_Cave_Edge_A", _build_cave_edge_data(-0.28, PI * 1.08, 0.0), MAT_DRY, false, true)
	_set_mesh("Rock_Body/Hollow_Cave_Edge_B", _build_cave_edge_data(PI * 0.98, TAU + 0.25, 1.0), MAT_BOTTOM, false, true)

	_set_mesh(
		"Rock_Body/Hanging_Rock_A",
		_build_blob_data(_hanging_center(-1.82, 0.84, 1.0), Vector3.RIGHT, Vector3.UP, Vector3.FORWARD, Vector3(0.55, 0.82, 0.46) * hanging_rock_scale * lerp(0.86, 1.18, _variant_hash(41.0)), _phase(42.0), 8, 18),
		MAT_BOTTOM,
		false,
		true
	)
	_set_mesh(
		"Rock_Body/Hanging_Rock_B",
		_build_blob_data(_hanging_center(2.52, 0.92, 2.0), Vector3.RIGHT, Vector3.UP, Vector3.FORWARD, Vector3(0.42, 1.05, 0.50) * hanging_rock_scale * lerp(0.82, 1.24, _variant_hash(43.0)), _phase(44.0), 8, 18),
		MAT_BOTTOM,
		false,
		true
	)
	_set_mesh(
		"Rock_Body/Hanging_Rock_C",
		_build_blob_data(_hanging_center(0.75, 1.0, 3.0), Vector3.RIGHT, Vector3.UP, Vector3.FORWARD, Vector3(0.35, 0.58, 0.34) * hanging_rock_scale * lerp(0.78, 1.28, _variant_hash(45.0)), _phase(46.0), 7, 16),
		MAT_BOTTOM,
		false,
		true
	)

	_populate_debris_cluster("Rock_Body/Debris_Cluster_A", _debris_center(-2.70, 0.07, 51.0), Vector3(1.15, 0.28, 0.72) * lerp(0.86, 1.18, _variant_hash(52.0)), max(5, int(round(9.0 * debris_density))), _phase(53.0))
	_populate_debris_cluster("Rock_Body/Debris_Cluster_B", _debris_center(1.18, 0.68, 54.0), Vector3(0.85, 1.15, 0.62) * lerp(0.82, 1.24, _variant_hash(55.0)), max(5, int(round(8.0 * debris_density))), _phase(56.0))


func _build_fx_placeholders() -> void:
	_set_mesh("FX_Placeholders/Waterfall_Channel_A", _build_waterfall_channel_data(), MAT_WET, false, false)

	var water_angle := _waterfall_angle()
	_set_marker("FX_Placeholders/Mist_Point_A", _body_point(water_angle, 0.28, 0.28) + Vector3.DOWN * 0.58, Color(0.65, 0.82, 0.86, 1.0), 0.18)
	_set_marker("FX_Placeholders/Mist_Point_B", _body_point(water_angle, 0.78, 0.12) + Vector3.DOWN * 0.46, Color(0.60, 0.76, 0.80, 1.0), 0.14)
	_set_marker("FX_Placeholders/Floating_Debris_Point_A", _hanging_center(-2.85 + _variant_signed(61.0) * 0.22, 0.50, 61.0), Color(0.48, 0.44, 0.36, 1.0), 0.16)
	_set_marker("FX_Placeholders/Floating_Debris_Point_B", _hanging_center(1.85 + _variant_signed(62.0) * 0.22, 0.60, 62.0), Color(0.46, 0.42, 0.35, 1.0), 0.13)


func _build_vegetation_placeholders() -> void:
	_set_mesh(
		"Vegetation_Placeholders/Moss_Area_A",
		_build_patch_data(Vector3(-1.42, 0.24, 1.04), Vector3.RIGHT, Vector3.FORWARD, 1.45, 0.82, 411.0),
		MAT_MOSS,
		false,
		false
	)

	var moss_angle := 1.23 + _variant_signed(71.0) * 0.44
	_set_mesh(
		"Vegetation_Placeholders/Moss_Area_B",
		_build_patch_data(_body_point(moss_angle, 0.27, 0.11), _tangent_dir(moss_angle), Vector3.UP, 0.78, 0.66, 412.0),
		MAT_MOSS,
		false,
		false
	)

	_set_marker("Vegetation_Placeholders/Root_Vine_Attach_A", _body_point(-1.82 + _variant_signed(72.0) * 0.32, 0.18, 0.18), Color(0.22, 0.48, 0.20, 1.0), 0.12)
	_set_marker("Vegetation_Placeholders/Root_Vine_Attach_B", _body_point(1.45 + _variant_signed(73.0) * 0.36, 0.40, 0.16), Color(0.20, 0.42, 0.18, 1.0), 0.12)


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
	body.add_to_group(&"large_rock_exact_collision")
	body.set_meta("source_large_rock", String(name))


func _build_preview_setup() -> void:
	var env_node := get_node_or_null("Preview_Setup/WorldEnvironment") as WorldEnvironment
	if env_node != null:
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.62, 0.76, 0.84, 1.0)
		env.ambient_light_color = Color(0.76, 0.82, 0.78, 1.0)
		env.ambient_light_energy = 0.85
		env.fog_enabled = true
		env.fog_light_color = Color(0.72, 0.83, 0.82, 1.0)
		env.fog_density = 0.008
		env_node.environment = env

	var light := get_node_or_null("Preview_Setup/DirectionalLight3D") as DirectionalLight3D
	if light != null:
		light.light_energy = 2.35
		light.shadow_enabled = true
		light.rotation_degrees = Vector3(-46.0, 38.0, 0.0)

	var camera := get_node_or_null("Preview_Setup/Camera3D") as Camera3D
	if camera != null:
		camera.position = Vector3(8.0, 4.8, 9.5)
		camera.look_at(Vector3(0.0, -3.1, 0.0), Vector3.UP)
		camera.fov = 42.0
		camera.current = true


func _set_mesh(path: String, data: Dictionary, material: Material, collect_top: bool, collect_body: bool) -> void:
	var node := get_node_or_null(path) as MeshInstance3D
	if node == null:
		return

	var vertices: Array = data["vertices"]
	var indices: PackedInt32Array = data["indices"]
	var uvs: Array = data.get("uvs", [])
	node.mesh = _make_array_mesh(vertices, indices, material, uvs)
	node.extra_cull_margin = 2.0
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
		st.add_vertex(v * shape_scale)
	st.generate_normals()
	var mesh := st.commit()
	mesh.surface_set_material(0, material)
	return mesh


func _rock_side_uv(point: Vector3) -> Vector2:
	var angle: float = atan2(point.z, point.x)
	var u: float = fposmod(angle / TAU + 1.0, 1.0)
	var root_span: float = max(8.0, 11.95 * root_depth_scale)
	var v: float = clamp((-point.y + 0.25) / root_span, 0.0, 1.0)
	return Vector2(u, v)


func _collect_collision_faces(vertices: Array, indices: PackedInt32Array, collect_top: bool, collect_body: bool) -> void:
	# ConcavePolygonShape3D uses triangle winding to choose its blocking side.
	# The render mesh winding is correct visually, but feeding that same order to
	# physics made the hollow inside block while the exterior let ships through.
	# Reverse only the collision copy so outside/top is solid and trapped bodies
	# can still leave through the non-blocking inner face.
	for triangle_start in range(0, indices.size(), 3):
		if triangle_start + 2 >= indices.size():
			break

		var a: Vector3 = vertices[indices[triangle_start]] * shape_scale
		var b: Vector3 = vertices[indices[triangle_start + 1]] * shape_scale
		var c: Vector3 = vertices[indices[triangle_start + 2]] * shape_scale
		if collect_top:
			_top_collision_faces.append(a)
			_top_collision_faces.append(c)
			_top_collision_faces.append(b)
		if collect_body:
			_body_collision_faces.append(a)
			_body_collision_faces.append(c)
			_body_collision_faces.append(b)


func _build_top_platform_data() -> Dictionary:
	var rings := 9
	var segments := SEGMENTS_TOP
	var vertices: Array = []
	var indices := PackedInt32Array()

	vertices.append(Vector3(0.0, 0.18, 0.0))
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
			var lower := _body_point(angle, 0.145, 0.0)
			var radial := _radial_dir(angle)
			var broken := (sin(angle * 7.0 + v * 9.0) * 0.12 + sin(angle * 15.0) * 0.055) * (1.0 - v * 0.35)
			var p := top.lerp(lower, v)
			p += radial * broken
			p.y -= abs(sin(angle * 5.0 + v * 6.0)) * 0.08 * v
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


func _build_side_panel_data(angle_start: float, angle_end: float, segments: int, levels: int, has_cave: bool, seed_offset: float) -> Dictionary:
	var vertices: Array = []
	var indices := PackedInt32Array()
	var cols := segments + 1

	for j in range(levels + 1):
		var v := float(j) / float(levels)
		for i in range(cols):
			var u := float(i) / float(segments)
			var angle: float = lerp(angle_start, angle_end, u)
			var p := _body_point(angle, v, _panel_outward_noise(angle, v, seed_offset))
			p += _tangent_dir(angle) * (sin(v * 16.0 + angle * 5.0 + seed_offset) * 0.045)
			vertices.append(p)

	for j in range(levels):
		for i in range(segments):
			var angle_mid: float = lerp(angle_start, angle_end, (float(i) + 0.5) / float(segments))
			var v_mid := (float(j) + 0.5) / float(levels)
			if has_cave and _inside_cave_opening(angle_mid, v_mid):
				continue
			var a := j * cols + i
			var b := j * cols + i + 1
			var c := (j + 1) * cols + i
			var d := (j + 1) * cols + i + 1
			_tri(indices, a, b, d)
			_tri(indices, a, d, c)

	return {"vertices": vertices, "indices": indices}


func _build_bottom_root_main_data() -> Dictionary:
	var levels := 13
	var segments := 72
	var vertices: Array = []
	var indices := PackedInt32Array()

	for j in range(levels):
		var t := float(j) / float(levels - 1)
		var y: float = lerp(-5.75 * root_depth_scale, -11.20 * root_depth_scale, pow(t, 1.05))
		var rx: float = lerp(2.28 * root_width_scale * silhouette_x, 0.16 * root_width_scale, pow(t, 1.22))
		var rz: float = lerp(1.55 * root_width_scale * silhouette_z, 0.11 * root_width_scale, pow(t, 1.18))
		var layer_push := sin(t * PI * 9.0 + _phase(81.0)) * 0.13 * (1.0 - t)
		for i in range(segments):
			var angle := TAU * float(i) / float(segments)
			var rough := 1.0 + sin(angle * 4.0 + t * 2.0 + _phase(82.0)) * 0.13 + sin(angle * 9.0 + t * 11.0 + _phase(83.0)) * 0.06
			var p := Vector3(cos(angle) * (rx + layer_push) * rough, y, sin(angle) * (rz + layer_push * 0.55) * rough)
			p += Vector3(0.18 * sin(t * 5.5 + _phase(84.0)), 0.0, -0.14 * sin(t * 4.2 + _phase(85.0)))
			vertices.append(p)

	for j in range(levels - 1):
		for i in range(segments):
			var a := j * segments + i
			var b := j * segments + ((i + 1) % segments)
			var c := (j + 1) * segments + i
			var d := (j + 1) * segments + ((i + 1) % segments)
			_tri(indices, a, b, d)
			_tri(indices, a, d, c)

	var tip_index := vertices.size()
	vertices.append(Vector3(0.12 + _variant_signed(86.0) * 0.10, -11.62 * root_depth_scale, -0.07 + _variant_signed(87.0) * 0.10))
	var last_start := (levels - 1) * segments
	for i in range(segments):
		_tri(indices, last_start + i, tip_index, last_start + ((i + 1) % segments))

	return {"vertices": vertices, "indices": indices}


func _build_sub_root_data(angle: float, start_v: float, length: float, radii: Vector2, seed: float) -> Dictionary:
	var levels := 10
	var segments := 34
	var vertices: Array = []
	var indices := PackedInt32Array()
	var radial := _radial_dir(angle)
	var tangent := _tangent_dir(angle)
	var start := _body_point(angle, start_v, 0.18)

	for j in range(levels):
		var t := float(j) / float(levels - 1)
		var center := start + radial * (0.30 + t * 0.42) + Vector3.DOWN * (length * t) + tangent * (sin(t * PI * 1.7 + seed) * 0.18)
		var rx: float = lerp(radii.x, 0.10, pow(t, 1.18))
		var rz: float = lerp(radii.y, 0.08, pow(t, 1.24))
		for i in range(segments):
			var a := TAU * float(i) / float(segments)
			var rough := 1.0 + sin(a * 5.0 + seed) * 0.10 + sin(a * 11.0 + t * 6.0) * 0.055
			vertices.append(center + tangent * (cos(a) * rx * rough) + radial * (sin(a) * rz * rough))

	for j in range(levels - 1):
		for i in range(segments):
			var a0 := j * segments + i
			var b0 := j * segments + ((i + 1) % segments)
			var c0 := (j + 1) * segments + i
			var d0 := (j + 1) * segments + ((i + 1) % segments)
			_tri(indices, a0, b0, d0)
			_tri(indices, a0, d0, c0)

	return {"vertices": vertices, "indices": indices}


func _build_cave_disc_data() -> Dictionary:
	var rings := 5
	var segments := 44
	var vertices: Array = []
	var indices := PackedInt32Array()
	var cave_angle := _cave_angle()
	var cave_v := _cave_v()
	var cave_mult := _cave_mult()
	var radial := _radial_dir(cave_angle)
	var tangent := _tangent_dir(cave_angle)
	var center := _body_point(cave_angle, cave_v, -0.92 * cave_mult)
	center.y -= 0.12

	vertices.append(center - radial * 0.22)
	for r in range(1, rings + 1):
		var t := float(r) / float(rings)
		for i in range(segments):
			var a := TAU * float(i) / float(segments)
			var jag := 1.0 + sin(a * 5.0 + _phase(91.0)) * 0.12 + sin(a * 11.0 + _phase(92.0)) * 0.08
			var p := center + tangent * (cos(a) * 1.38 * cave_mult * t * jag) + Vector3.UP * (sin(a) * 1.03 * cave_mult * t * jag)
			p -= radial * (0.34 + (1.0 - t) * 0.36 + sin(a * 3.0 + _phase(93.0)) * 0.05)
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


func _build_cave_edge_data(theta_start: float, theta_end: float, seed: float) -> Dictionary:
	var segments := 34
	var vertices: Array = []
	var indices := PackedInt32Array()
	var cave_angle := _cave_angle()
	var cave_v := _cave_v()
	var cave_mult := _cave_mult()
	var radial := _radial_dir(cave_angle)
	var tangent := _tangent_dir(cave_angle)
	var center := _body_point(cave_angle, cave_v, 0.04)
	center.y -= 0.05

	for i in range(segments + 1):
		var u := float(i) / float(segments)
		var theta: float = lerp(theta_start, theta_end, u)
		var rough := 1.0 + sin(theta * 4.0 + seed) * 0.14 + sin(theta * 9.0 + seed * 2.0) * 0.07
		var outer := center + tangent * (cos(theta) * 1.77 * cave_mult * rough) + Vector3.UP * (sin(theta) * 1.34 * cave_mult * rough) + radial * 0.22
		var inner := center + tangent * (cos(theta) * 1.18 * cave_mult * rough) + Vector3.UP * (sin(theta) * 0.82 * cave_mult * rough) - radial * 0.18
		outer += radial * (sin(theta * 6.0 + seed) * 0.10)
		inner += radial * (sin(theta * 5.0 + seed) * 0.08)
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
	var levels := 20
	var columns := 5
	var vertices: Array = []
	var uvs: Array = []
	var indices := PackedInt32Array()

	for j in range(levels + 1):
		var t := float(j) / float(levels)
		for i in range(columns):
			var lane := (float(i) / float(columns - 1) - 0.5)
			var local_angle := angle + lane * 0.17
			var p := _waterfall_channel_point(local_angle, t, lane)
			p.y += sin(t * 18.0 + lane * 3.0) * 0.035
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


func _waterfall_channel_point(angle: float, depth_t: float, lane: float) -> Vector3:
	var t: float = clamp(depth_t, 0.0, 1.0)
	var outward: float = 0.11 - absf(lane) * 0.035
	var body_limit: float = 0.62
	if t <= body_limit:
		var body_v: float = lerp(0.02, 0.86, t / body_limit)
		return _body_point(angle, body_v, outward)

	var root_t: float = (t - body_limit) / (1.0 - body_limit)
	var root_angle: float = angle + sin(root_t * PI * 1.35 + _phase(171.0)) * 0.045
	var root_point: Vector3 = _bottom_root_surface_point(root_angle, root_t, outward * lerp(1.0, 0.35, root_t))
	var seam_point: Vector3 = _body_point(angle, 0.86, outward)
	var seam_blend: float = smoothstep(0.0, 0.16, root_t)
	return seam_point.lerp(root_point, seam_blend)


func _bottom_root_surface_point(angle: float, root_t: float, outward: float) -> Vector3:
	var t: float = clamp(root_t, 0.0, 1.0)
	var y: float = lerp(-5.75 * root_depth_scale, -11.20 * root_depth_scale, pow(t, 1.05))
	var rx: float = lerp(2.28 * root_width_scale * silhouette_x, 0.16 * root_width_scale, pow(t, 1.22))
	var rz: float = lerp(1.55 * root_width_scale * silhouette_z, 0.11 * root_width_scale, pow(t, 1.18))
	var layer_push := sin(t * PI * 9.0 + _phase(81.0)) * 0.13 * (1.0 - t)
	var rough := 1.0 + sin(angle * 4.0 + t * 2.0 + _phase(82.0)) * 0.13 + sin(angle * 9.0 + t * 11.0 + _phase(83.0)) * 0.06
	var radial := _radial_dir(angle)
	var p := Vector3(cos(angle) * (rx + layer_push) * rough, y, sin(angle) * (rz + layer_push * 0.55) * rough)
	p += Vector3(0.18 * sin(t * 5.5 + _phase(84.0)), 0.0, -0.14 * sin(t * 4.2 + _phase(85.0)))
	p += radial * outward
	return p


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
			var h := _hash(seed + float(i) * 3.1, float(j) * 7.7)
			var rough := 0.78 + h * 0.36 + sin(a * 5.0 + seed) * 0.055
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
	vertices.append(center + normal * 0.035)

	for r in range(1, rings + 1):
		var t := float(r) / float(rings)
		for i in range(segments):
			var a := TAU * float(i) / float(segments)
			var rough := 1.0 + sin(a * 4.0 + seed) * 0.13 + sin(a * 9.0 + seed) * 0.065
			var p := center + normal * 0.038
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
			lerp(0.12, 0.36, _hash(seed + 3.0, fi)),
			lerp(0.08, 0.28, _hash(seed + 5.0, fi)),
			lerp(0.10, 0.34, _hash(seed + 7.0, fi))
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
	marker.position = position_value * shape_scale
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


func _ring_index(ring: int, i: int, segments: int) -> int:
	return 1 + (ring - 1) * segments + i


func _tri(indices: PackedInt32Array, a: int, b: int, c: int) -> void:
	indices.append(a)
	indices.append(b)
	indices.append(c)


func _top_edge_point(angle: float) -> Vector3:
	var shape := 1.0
	shape += sin(angle * 3.0 + 0.40 + _phase(101.0)) * 0.115
	shape += sin(angle * 5.0 + 1.70 + _phase(102.0)) * 0.070
	shape += sin(angle * 9.0 - 0.25 + _phase(103.0)) * 0.038
	shape += sin(angle * 2.0 + _phase(104.0)) * 0.045 * _variant_signed(105.0)
	return Vector3(cos(angle) * 5.72 * silhouette_x * shape, 0.0, sin(angle) * 4.54 * silhouette_z * shape)


func _top_height(angle: float, radial_t: float) -> float:
	var lift := 0.16
	lift += sin(angle * 2.0 + radial_t * 3.0 + _phase(111.0)) * 0.035
	lift += sin(angle * 6.0 + radial_t * 7.0 + _phase(112.0)) * 0.026 * radial_t
	lift -= smoothstep(0.76, 1.0, radial_t) * 0.11
	return lift


func _body_point(angle: float, v: float, outward: float = 0.0) -> Vector3:
	var t: float = clamp(v, 0.0, 1.0)
	var y: float = lerp(-0.48, -6.42 * root_depth_scale, pow(t, 1.02))
	var lower_width: float = lerp(1.0, root_width_scale, smoothstep(0.45, 1.0, t))
	var rx: float = lerp(5.36 * silhouette_x, 1.88 * silhouette_x * lower_width, pow(t, 0.92))
	var rz: float = lerp(4.20 * silhouette_z, 1.23 * silhouette_z * lower_width, pow(t, 1.08))
	var large := 1.0
	large += sin(angle * 3.0 + 0.6 + _phase(121.0)) * 0.13
	large += sin(angle * 5.0 + 1.8 + _phase(122.0)) * 0.085
	large += sin(angle * 8.0 + t * 5.2 + _phase(123.0)) * 0.046
	var strata: float = sin(t * PI * 10.0 + angle * 2.2 + _phase(124.0)) * 0.13 * (1.0 - t * 0.18)
	var ledge := sin(floor(t * 9.0) * 1.7 + angle * 3.0 + _phase(125.0)) * 0.08
	var radial := _radial_dir(angle)
	var p := Vector3(cos(angle) * rx * large, y, sin(angle) * rz * large)
	p += radial * (strata + ledge + outward)
	return p


func _panel_outward_noise(angle: float, v: float, seed_offset: float) -> float:
	return sin(angle * 6.0 + v * 13.0 + seed_offset) * 0.075 + sin(angle * 13.0 + seed_offset) * 0.035


func _inside_cave_opening(angle: float, v: float) -> bool:
	var da := _angle_delta(angle, _cave_angle()) / (0.42 * _cave_mult())
	var dv := (v - _cave_v()) / (0.205 * _cave_mult())
	var ragged := 1.0 + sin(angle * 18.0 + v * 12.0 + _phase(131.0)) * 0.20 + sin(angle * 8.0 + _phase(132.0)) * 0.10
	return da * da + dv * dv < ragged


func _angle_delta(a: float, b: float) -> float:
	return abs(fposmod(a - b + PI, TAU) - PI)


func _radial_dir(angle: float) -> Vector3:
	return Vector3(cos(angle), 0.0, sin(angle)).normalized()


func _tangent_dir(angle: float) -> Vector3:
	return Vector3(-sin(angle), 0.0, cos(angle)).normalized()


func _cave_angle() -> float:
	return CAVE_ANGLE + cave_angle_offset + _variant_signed(3.0) * 0.18


func _cave_v() -> float:
	return clamp(CAVE_V + cave_vertical_offset + _variant_signed(4.0) * 0.04, 0.28, 0.58)


func _cave_mult() -> float:
	return cave_scale * lerp(0.90, 1.10, _variant_hash(5.0))


func _waterfall_angle() -> float:
	return 1.17 + waterfall_angle_offset + _variant_signed(6.0) * 0.20


func _hanging_center(base_angle: float, v: float, slot: float) -> Vector3:
	var angle := base_angle + _variant_signed(slot) * 0.42
	var radial := _radial_dir(angle)
	var tangent := _tangent_dir(angle)
	var p := _body_point(angle, v, 0.30 + _variant_hash(slot + 1.0) * 0.18)
	p += Vector3.DOWN * lerp(0.65, 1.65, _variant_hash(slot + 2.0)) * root_depth_scale
	p += radial * lerp(0.40, 1.05, _variant_hash(slot + 3.0))
	p += tangent * _variant_signed(slot + 4.0) * 0.45
	return p


func _debris_center(base_angle: float, v: float, slot: float) -> Vector3:
	var angle := base_angle + _variant_signed(slot) * 0.36
	var p := _body_point(angle, v, 0.18 + _variant_hash(slot + 1.0) * 0.22)
	p.y += lerp(-0.22, 0.38, _variant_hash(slot + 2.0))
	return p


func _phase(slot: float) -> float:
	return variant_seed * 0.173 + slot * 2.317


func _variant_hash(slot: float) -> float:
	return _hash(variant_seed + slot * 17.13, slot * 3.77)


func _variant_signed(slot: float) -> float:
	return _variant_hash(slot) * 2.0 - 1.0


func _hash(a: float, b: float) -> float:
	return fposmod(sin(a * 12.9898 + b * 78.233) * 43758.5453123, 1.0)

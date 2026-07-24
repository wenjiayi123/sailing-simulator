@tool
extends Node3D

const BUILD_REVISION := 10
# Legacy filename retained as a resource-path compatibility contract.
const WATER_FLOW_SHADER_PATH := "res://shaders/taoyuan_cliff_water_flow.gdshader"

@export_node_path("MeshInstance3D") var source_surface_path: NodePath
@export_range(2.0, 260.0, 0.1) var cliff_depth := 120.0
@export_range(-8.0, 4.0, 0.05) var outward_offset := 0.18
@export_range(0.6, 1.8, 0.05) var bottom_width_scale := 1.0
@export_range(0.0, 0.45, 0.01) var corner_overlap_ratio := 0.02
@export_range(0.0, 0.45, 0.01) var corner_guard_ratio := 0.0
@export_range(0.0, 0.40, 0.005) var corner_wrap_ratio := 0.36
@export_range(0.01, 0.32, 0.005) var corner_wrap_uv_ratio := 0.28
@export_range(1, 8, 1) var corner_wrap_segments := 7
@export_range(128, 1024, 1) var texture_width := 512
@export_range(256, 2048, 1) var texture_height := 1024
@export var cliff_texture: Texture2D
@export var front_texture: Texture2D
@export var left_texture: Texture2D
@export var right_texture: Texture2D
@export var back_texture: Texture2D
@export var seed := 4609
@export var live_update_in_editor := true
@export var water_flow_enabled := true
@export_range(0.0, 0.30, 0.001) var water_flow_speed := 0.145
@export_range(0.0, 0.35, 0.005) var water_flow_strength := 0.35
@export_range(0.0, 0.30, 0.005) var water_shimmer_strength := 0.3
@export_range(0.0, 20.0, 0.05) var water_flow_bend_amount := 1.0
@export_range(0.0, 8.0, 0.05) var water_flow_lane_randomness := 1.0
@export_range(1.0, 240.0, 1.0) var water_flow_lane_count := 34.0

var _last_signature := ""


func _ready() -> void:
	_rebuild_if_changed(true)
	set_process(Engine.is_editor_hint())


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint() or not live_update_in_editor:
		return
	_rebuild_if_changed(false)


func _rebuild_if_changed(force: bool) -> void:
	var source := get_node_or_null(source_surface_path) as MeshInstance3D
	if source == null or source.mesh == null:
		return

	var bounds := _source_bounds(source)
	if bounds.size.x <= 0.01 or bounds.size.z <= 0.01:
		return

	var signature := "%d|%s|%s|%.2f|%.2f|%.2f|%.2f|%.2f|%.3f|%.3f|%d|%s|%s|%d|%d|%d|%d|%.3f|%.3f|%.3f|%.3f|%.3f|%.1f" % [
		BUILD_REVISION,
		source.transform,
		source.mesh.get_aabb(),
		cliff_depth,
		outward_offset,
		bottom_width_scale,
		corner_overlap_ratio,
		corner_guard_ratio,
		corner_wrap_ratio,
		corner_wrap_uv_ratio,
		corner_wrap_segments,
		_texture_signature(),
		_default_texture_signature(),
		seed,
		texture_width,
		texture_height,
		int(water_flow_enabled),
		water_flow_speed,
		water_flow_strength,
		water_shimmer_strength,
		water_flow_bend_amount,
		water_flow_lane_randomness,
		water_flow_lane_count,
	]
	if not force and signature == _last_signature:
		return

	_last_signature = signature
	_clear_generated()
	_build_sprite_shell(bounds)


func _source_bounds(source: MeshInstance3D) -> AABB:
	var source_aabb := source.mesh.get_aabb()
	var has_point := false
	var result := AABB()

	for x in [source_aabb.position.x, source_aabb.end.x]:
		for y in [source_aabb.position.y, source_aabb.end.y]:
			for z in [source_aabb.position.z, source_aabb.end.z]:
				var point := to_local(source.to_global(Vector3(x, y, z)))
				if not has_point:
					result = AABB(point, Vector3.ZERO)
					has_point = true
				else:
					result = result.expand(point)

	return result


func _build_sprite_shell(bounds: AABB) -> void:
	var top_y := bounds.end.y - 0.02
	var bottom_y := top_y - cliff_depth
	var center := bounds.get_center()
	var top_half_x := bounds.size.x * 0.5 + outward_offset
	var top_half_z := bounds.size.z * 0.5 + outward_offset
	var bottom_half_x := top_half_x * bottom_width_scale
	var bottom_half_z := top_half_z * bottom_width_scale
	var top_overlap_x := top_half_x * corner_overlap_ratio
	var top_overlap_z := top_half_z * corner_overlap_ratio
	var bottom_overlap_x := bottom_half_x * corner_overlap_ratio
	var bottom_overlap_z := bottom_half_z * corner_overlap_ratio
	var default_front_texture := _default_panel_texture("front")
	var default_left_texture := _default_panel_texture("left")
	var front_material := _make_sprite_material(_resolve_panel_texture(front_texture, cliff_texture, default_front_texture))
	var left_material := _make_sprite_material(_resolve_panel_texture(left_texture, cliff_texture, default_left_texture))
	var right_material := _make_sprite_material(_resolve_panel_texture(right_texture, left_texture, cliff_texture, default_left_texture))
	var back_material := _make_sprite_material(_resolve_panel_texture(back_texture, front_texture, cliff_texture, default_front_texture))

	_add_panel(
		"sprite_cliff_south",
		Vector3(center.x - top_half_x - top_overlap_x, top_y, center.z + top_half_z),
		Vector3(center.x + top_half_x + top_overlap_x, top_y, center.z + top_half_z),
		Vector3(center.x + bottom_half_x + bottom_overlap_x, bottom_y, center.z + bottom_half_z),
		Vector3(center.x - bottom_half_x - bottom_overlap_x, bottom_y, center.z + bottom_half_z),
		front_material
	)
	_add_panel(
		"sprite_cliff_north",
		Vector3(center.x + top_half_x + top_overlap_x, top_y, center.z - top_half_z),
		Vector3(center.x - top_half_x - top_overlap_x, top_y, center.z - top_half_z),
		Vector3(center.x - bottom_half_x - bottom_overlap_x, bottom_y, center.z - bottom_half_z),
		Vector3(center.x + bottom_half_x + bottom_overlap_x, bottom_y, center.z - bottom_half_z),
		back_material
	)
	_add_panel(
		"sprite_cliff_east",
		Vector3(center.x + top_half_x, top_y, center.z + top_half_z + top_overlap_z),
		Vector3(center.x + top_half_x, top_y, center.z - top_half_z - top_overlap_z),
		Vector3(center.x + bottom_half_x, bottom_y, center.z - bottom_half_z - bottom_overlap_z),
		Vector3(center.x + bottom_half_x, bottom_y, center.z + bottom_half_z + bottom_overlap_z),
		right_material
	)
	_add_panel(
		"sprite_cliff_west",
		Vector3(center.x - top_half_x, top_y, center.z - top_half_z - top_overlap_z),
		Vector3(center.x - top_half_x, top_y, center.z + top_half_z + top_overlap_z),
		Vector3(center.x - bottom_half_x, bottom_y, center.z + bottom_half_z + bottom_overlap_z),
		Vector3(center.x - bottom_half_x, bottom_y, center.z - bottom_half_z - bottom_overlap_z),
		left_material
	)

	if corner_guard_ratio > 0.0:
		_add_corner_guard("sprite_cliff_corner_southeast", center, top_y, bottom_y, top_half_x, top_half_z, bottom_half_x, bottom_half_z, top_overlap_x, top_overlap_z, bottom_overlap_x, bottom_overlap_z, 1.0, 1.0, front_material)
		_add_corner_guard("sprite_cliff_corner_southwest", center, top_y, bottom_y, top_half_x, top_half_z, bottom_half_x, bottom_half_z, top_overlap_x, top_overlap_z, bottom_overlap_x, bottom_overlap_z, -1.0, 1.0, front_material)
		_add_corner_guard("sprite_cliff_corner_northeast", center, top_y, bottom_y, top_half_x, top_half_z, bottom_half_x, bottom_half_z, top_overlap_x, top_overlap_z, bottom_overlap_x, bottom_overlap_z, 1.0, -1.0, back_material)
		_add_corner_guard("sprite_cliff_corner_northwest", center, top_y, bottom_y, top_half_x, top_half_z, bottom_half_x, bottom_half_z, top_overlap_x, top_overlap_z, bottom_overlap_x, bottom_overlap_z, -1.0, -1.0, back_material)

	if corner_wrap_ratio > 0.0:
		_add_corner_wrap("sprite_cliff_wrap_southeast", center, top_y, bottom_y, top_half_x, top_half_z, bottom_half_x, bottom_half_z, 1.0, 1.0, front_material)
		_add_corner_wrap("sprite_cliff_wrap_southwest", center, top_y, bottom_y, top_half_x, top_half_z, bottom_half_x, bottom_half_z, -1.0, 1.0, front_material)
		_add_corner_wrap("sprite_cliff_wrap_northeast", center, top_y, bottom_y, top_half_x, top_half_z, bottom_half_x, bottom_half_z, 1.0, -1.0, back_material)
		_add_corner_wrap("sprite_cliff_wrap_northwest", center, top_y, bottom_y, top_half_x, top_half_z, bottom_half_x, bottom_half_z, -1.0, -1.0, back_material)


func _add_corner_wrap(
	name: String,
	center: Vector3,
	top_y: float,
	bottom_y: float,
	top_half_x: float,
	top_half_z: float,
	bottom_half_x: float,
	bottom_half_z: float,
	x_sign: float,
	z_sign: float,
	material: Material
) -> void:
	var segments := maxi(corner_wrap_segments, 1)
	var top_wrap_x := minf(top_half_x * corner_wrap_ratio, top_half_x * 0.45)
	var top_wrap_z := minf(top_half_z * corner_wrap_ratio, top_half_z * 0.45)
	var bottom_wrap_x := minf(bottom_half_x * corner_wrap_ratio, bottom_half_x * 0.45)
	var bottom_wrap_z := minf(bottom_half_z * corner_wrap_ratio, bottom_half_z * 0.45)
	var uv_width := clampf(corner_wrap_uv_ratio, 0.01, 0.32)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(segments):
		var t0 := float(index) / float(segments)
		var t1 := float(index + 1) / float(segments)
		var top_0 := _corner_wrap_point(center, top_y, top_half_x, top_half_z, top_wrap_x, top_wrap_z, x_sign, z_sign, t0)
		var top_1 := _corner_wrap_point(center, top_y, top_half_x, top_half_z, top_wrap_x, top_wrap_z, x_sign, z_sign, t1)
		var bottom_0 := _corner_wrap_point(center, bottom_y, bottom_half_x, bottom_half_z, bottom_wrap_x, bottom_wrap_z, x_sign, z_sign, t0)
		var bottom_1 := _corner_wrap_point(center, bottom_y, bottom_half_x, bottom_half_z, bottom_wrap_x, bottom_wrap_z, x_sign, z_sign, t1)
		var u0 := _corner_wrap_u(x_sign, uv_width, t0)
		var u1 := _corner_wrap_u(x_sign, uv_width, t1)

		st.set_uv(Vector2(u0, 0.0))
		st.add_vertex(top_0)
		st.set_uv(Vector2(u1, 0.0))
		st.add_vertex(top_1)
		st.set_uv(Vector2(u1, 1.0))
		st.add_vertex(bottom_1)

		st.set_uv(Vector2(u0, 0.0))
		st.add_vertex(top_0)
		st.set_uv(Vector2(u1, 1.0))
		st.add_vertex(bottom_1)
		st.set_uv(Vector2(u0, 1.0))
		st.add_vertex(bottom_0)

	st.generate_normals()
	var mesh := st.commit()
	if mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, material)

	var node := MeshInstance3D.new()
	node.name = name
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)


func _corner_wrap_point(
	center: Vector3,
	y: float,
	half_x: float,
	half_z: float,
	wrap_x: float,
	wrap_z: float,
	x_sign: float,
	z_sign: float,
	t: float
) -> Vector3:
	var angle := t * PI * 0.5
	var inner_x := center.x + x_sign * (half_x - wrap_x)
	var inner_z := center.z + z_sign * (half_z - wrap_z)
	return Vector3(
		inner_x + x_sign * sin(angle) * wrap_x,
		y,
		inner_z + z_sign * cos(angle) * wrap_z
	)


func _corner_wrap_u(x_sign: float, uv_width: float, t: float) -> float:
	if x_sign > 0.0:
		return lerpf(1.0 - uv_width, 1.0, t)
	return lerpf(uv_width, 0.0, t)


func _add_corner_guard(
	name: String,
	center: Vector3,
	top_y: float,
	bottom_y: float,
	top_half_x: float,
	top_half_z: float,
	bottom_half_x: float,
	bottom_half_z: float,
	top_overlap_x: float,
	top_overlap_z: float,
	bottom_overlap_x: float,
	bottom_overlap_z: float,
	x_sign: float,
	z_sign: float,
	material: Material
) -> void:
	var top_guard_x := top_half_x * corner_guard_ratio
	var top_guard_z := top_half_z * corner_guard_ratio
	var bottom_guard_x := bottom_half_x * corner_guard_ratio
	var bottom_guard_z := bottom_half_z * corner_guard_ratio

	_add_panel(
		name,
		Vector3(center.x + x_sign * (top_half_x + top_overlap_x * 0.45), top_y, center.z + z_sign * (top_half_z - top_guard_z)),
		Vector3(center.x + x_sign * (top_half_x - top_guard_x), top_y, center.z + z_sign * (top_half_z + top_overlap_z * 0.45)),
		Vector3(center.x + x_sign * (bottom_half_x - bottom_guard_x), bottom_y, center.z + z_sign * (bottom_half_z + bottom_overlap_z * 0.45)),
		Vector3(center.x + x_sign * (bottom_half_x + bottom_overlap_x * 0.45), bottom_y, center.z + z_sign * (bottom_half_z - bottom_guard_z)),
		material,
		0.18,
		0.04,
		0.82,
		0.96
	)


func _add_panel(
	name: String,
	top_left: Vector3,
	top_right: Vector3,
	bottom_right: Vector3,
	bottom_left: Vector3,
	material: Material,
	uv_left := 0.0,
	uv_top := 0.0,
	uv_right := 1.0,
	uv_bottom := 1.0
) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	st.set_uv(Vector2(uv_left, uv_top))
	st.add_vertex(top_left)
	st.set_uv(Vector2(uv_right, uv_top))
	st.add_vertex(top_right)
	st.set_uv(Vector2(uv_right, uv_bottom))
	st.add_vertex(bottom_right)

	st.set_uv(Vector2(uv_left, uv_top))
	st.add_vertex(top_left)
	st.set_uv(Vector2(uv_right, uv_bottom))
	st.add_vertex(bottom_right)
	st.set_uv(Vector2(uv_left, uv_bottom))
	st.add_vertex(bottom_left)

	st.generate_normals()
	var mesh := st.commit()
	if mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, material)

	var node := MeshInstance3D.new()
	node.name = name
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)


func _make_sprite_material(texture: Texture2D = null) -> Material:
	var resolved_texture := texture if texture != null else _make_cliff_texture()
	if water_flow_enabled and _should_use_water_flow(resolved_texture):
		return _make_water_flow_material(resolved_texture)
	return _make_plain_sprite_material(resolved_texture)


func _make_plain_sprite_material(texture: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.resource_name = "mat_sprite_cliff_alpha"
	mat.albedo_texture = texture
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mat.roughness = 1.0
	return mat


func _make_water_flow_material(texture: Texture2D) -> Material:
	var shader := load(WATER_FLOW_SHADER_PATH) as Shader
	if shader == null:
		return _make_plain_sprite_material(texture)
	var mat := ShaderMaterial.new()
	mat.resource_name = "mat_sprite_cliff_water_flow"
	mat.shader = shader
	mat.set_shader_parameter("cliff_texture", texture)
	mat.set_shader_parameter("flow_speed", water_flow_speed)
	mat.set_shader_parameter("flow_strength", water_flow_strength)
	mat.set_shader_parameter("shimmer_strength", water_shimmer_strength)
	mat.set_shader_parameter("flow_bend_amount", water_flow_bend_amount)
	mat.set_shader_parameter("flow_lane_randomness", water_flow_lane_randomness)
	mat.set_shader_parameter("flow_lane_count", water_flow_lane_count)
	return mat


func _should_use_water_flow(texture: Texture2D) -> bool:
	if texture == null:
		return false
	return texture.resource_path.to_lower().contains("waterfall")


func _resolve_panel_texture(primary: Texture2D, secondary: Texture2D = null, tertiary: Texture2D = null, fallback: Texture2D = null) -> Texture2D:
	if primary != null:
		return primary
	if secondary != null:
		return secondary
	if tertiary != null:
		return tertiary
	return fallback


func _texture_signature() -> String:
	var paths := []
	for texture in [cliff_texture, front_texture, left_texture, right_texture, back_texture]:
		paths.append(texture.resource_path if texture != null else "")
	return ",".join(paths)


func _default_texture_signature() -> String:
	return "%s|%s" % [_default_panel_texture_path("front"), _default_panel_texture_path("left")]


func _default_panel_texture(side: String) -> Texture2D:
	var path := _default_panel_texture_path(side)
	if path == "":
		return null
	return ResourceLoader.load(path) as Texture2D


func _default_panel_texture_path(side: String) -> String:
	return ""


func _make_cliff_texture() -> ImageTexture:
	var width := maxi(texture_width, 128)
	var height := maxi(texture_height, 256)
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	for y in range(height):
		var v := float(y) / float(height - 1)
		var left_edge := 0.08 + _wave(v, 0.0) * 0.055 + smoothstep(0.65, 1.0, v) * 0.10
		var right_edge := 0.92 - _wave(v, 2.4) * 0.055 - smoothstep(0.65, 1.0, v) * 0.10
		var top_grass := v < 0.13
		var bottom_fade := smoothstep(0.86, 1.0, v)

		for x in range(width):
			var u := float(x) / float(width - 1)
			var edge_feather := _edge_alpha(u, left_edge, right_edge)
			if edge_feather <= 0.0:
				continue

			var crack := _vertical_crack(u, v)
			var ridge := _ridge_light(u, v)
			var moss := _moss_mask(u, v)
			var shade := clampf(0.82 - v * 0.34 + ridge * 0.30 - crack * 0.48, 0.18, 1.0)
			var color := Color(0.36, 0.34, 0.29, 1.0).lerp(Color(0.18, 0.19, 0.18, 1.0), crack * 0.85)
			color = color.lerp(Color(0.50, 0.47, 0.36, 1.0), ridge * 0.48)
			color = color * shade

			if top_grass or moss > 0.45:
				color = color.lerp(Color(0.17, 0.36, 0.17, 1.0), clampf(0.45 + moss * 0.55, 0.0, 1.0))

			var alpha := edge_feather * (1.0 - bottom_fade * 0.28)
			if top_grass:
				alpha = maxf(alpha, edge_feather * 0.92)
			image.set_pixel(x, y, Color(color.r, color.g, color.b, alpha))

	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func _edge_alpha(u: float, left_edge: float, right_edge: float) -> float:
	var left := smoothstep(left_edge - 0.02, left_edge + 0.018, u)
	var right := 1.0 - smoothstep(right_edge - 0.018, right_edge + 0.02, u)
	return clampf(left * right, 0.0, 1.0)


func _vertical_crack(u: float, v: float) -> float:
	var total := 0.0
	var centers := [0.18, 0.33, 0.52, 0.68, 0.82]
	for i in range(centers.size()):
		var center := float(centers[i]) + sin(v * 8.0 + float(i) * 1.7 + float(seed) * 0.001) * 0.025
		var distance := absf(u - center)
		total = maxf(total, 1.0 - smoothstep(0.006, 0.035 + float(i % 2) * 0.014, distance))
	return clampf(total, 0.0, 1.0)


func _ridge_light(u: float, v: float) -> float:
	return clampf(
		0.55
		+ sin(u * 31.0 + v * 7.0 + float(seed) * 0.003) * 0.25
		+ cos(u * 17.0 - v * 19.0) * 0.20,
		0.0,
		1.0
	)


func _moss_mask(u: float, v: float) -> float:
	var top := 1.0 - smoothstep(0.04, 0.24, v)
	var side := maxf(1.0 - smoothstep(0.03, 0.18, u), smoothstep(0.82, 0.98, u))
	var patch := maxf(0.0, sin(u * 21.0 + float(seed) * 0.01) * cos(v * 27.0))
	return clampf(maxf(top, side * 0.55) * (0.55 + patch * 0.45), 0.0, 1.0)


func _wave(v: float, phase: float) -> float:
	return sin(v * 9.0 + phase + float(seed) * 0.001) * 0.55 + cos(v * 17.0 + phase * 0.7) * 0.45


func _clear_generated() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

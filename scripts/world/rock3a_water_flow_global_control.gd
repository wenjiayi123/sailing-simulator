@tool
extends Node

const ROCK_BODY_MATERIALS: Array[String] = [
	"res://assets/materials/floating_rock_3a_demo/Premium_Reference_Rock_Wet.tres",
	"res://assets/materials/floating_rock_3a_demo/Premium_Reference_Rock_Dry.tres",
	"res://assets/materials/floating_rock_3a_demo/Premium_Reference_Rock_Bottom.tres",
	"res://assets/materials/floating_rock_3a_demo/Premium_Reference_Cave_Rock.tres",
]

const WATERFALL_RIBBON_MATERIAL := "res://assets/materials/floating_rock_3a_demo/Premium_Waterfall_Ribbon.tres"
const WATERFALL_MIST_MATERIAL := "res://assets/materials/floating_rock_3a_demo/Premium_Waterfall_Mist.tres"
# Legacy filename retained as a resource-path compatibility contract.
const WATERFALL_RIBBON_SHADER := "res://shaders/taoyuan_premium_waterfall_ribbon.gdshader"
const ROCK_BODY_SHADER := "res://shaders/floating_rock_3a_demo_rock.gdshader"
const ROCK_WATER_LANE_COUNT := 10.0
const RIBBON_WATER_LANE_COUNT := 34.0
const ROCK_BODY_MATERIAL_NAMES := {
	"Premium_Reference_Rock_Wet": true,
	"Premium_Reference_Rock_Dry": true,
	"Premium_Reference_Rock_Bottom": true,
	"Premium_Reference_Cave_Rock": true,
}

@export_category("3A悬岩统一水流控制")
@export var 编辑器实时应用 := true:
	set(value):
		编辑器实时应用 = value
		_request_sync()

@export var 保存材质文件 := true:
	set(value):
		保存材质文件 = value
		_request_sync()

@export_group("编辑器实时预览")
@export_range(0.0, 3.0, 0.01) var 预览时间倍率 := 1.0:
	set(value):
		预览时间倍率 = value
		set_process(预览时间倍率 > 0.0)

@export_group("水流自然变化")
@export_range(0.0, 20.0, 0.05) var 自然弯曲程度 := 1.0:
	set(value):
		自然弯曲程度 = value
		_request_sync()

@export_range(0.0, 8.0, 0.05) var 水流间距随机度 := 1.0:
	set(value):
		水流间距随机度 = value
		_request_sync()

@export_range(0.2, 6.0, 0.05) var 水流数量倍率 := 1.0:
	set(value):
		水流数量倍率 = value
		_request_sync()

@export_group("岩体表面水痕")
@export_range(0.0, 0.5, 0.005) var 岩体流速 := 0.20:
	set(value):
		岩体流速 = value
		_request_sync()

@export_range(0.0, 1.5, 0.005) var 岩体蓝色强度 := 1.15:
	set(value):
		岩体蓝色强度 = value
		_request_sync()

@export_range(0.0, 1.5, 0.005) var 表面水膜强度 := 0.78:
	set(value):
		表面水膜强度 = value
		_request_sync()

@export_range(0.0, 1.0, 0.005) var 表面水膜覆盖 := 0.62:
	set(value):
		表面水膜覆盖 = value
		_request_sync()

@export_range(0.0, 1.5, 0.005) var 岩体流光强度 := 1.05:
	set(value):
		岩体流光强度 = value
		_request_sync()

@export_range(0.0, 1.5, 0.005) var 柔和水痕强度 := 0.88:
	set(value):
		柔和水痕强度 = value
		_request_sync()

@export_range(0.0, 1.0, 0.005) var 水痕亮芯强度 := 0.34:
	set(value):
		水痕亮芯强度 = value
		_request_sync()

@export_range(0.0, 1.5, 0.005) var 水痕下延强度 := 0.90:
	set(value):
		水痕下延强度 = value
		_request_sync()

@export_range(0.0, 0.8, 0.005) var 水痕下延长度 := 0.50:
	set(value):
		水痕下延长度 = value
		_request_sync()

@export_range(0.0, 1.0, 0.005) var 横向水痕压制 := 0.48:
	set(value):
		横向水痕压制 = value
		_request_sync()

@export var 水痕边缘颜色 := Color(0.30, 0.66, 0.82, 1.0):
	set(value):
		水痕边缘颜色 = value
		_request_sync()

@export var 水痕亮芯颜色 := Color(0.68, 0.90, 0.98, 1.0):
	set(value):
		水痕亮芯颜色 = value
		_request_sync()

@export var 水流蓝色染色 := Color(0.24, 0.58, 0.84, 1.0):
	set(value):
		水流蓝色染色 = value
		_request_sync()

@export_group("外层半透明瀑布带")
@export_range(0.0, 0.5, 0.005) var 瀑布带流速 := 0.32:
	set(value):
		瀑布带流速 = value
		_request_sync()

@export_range(0.0, 1.5, 0.005) var 瀑布带水流强度 := 1.05:
	set(value):
		瀑布带水流强度 = value
		_request_sync()

@export_range(0.0, 1.5, 0.005) var 瀑布带流光强度 := 1.12:
	set(value):
		瀑布带流光强度 = value
		_request_sync()

@export_range(0.0, 1.0, 0.005) var 瀑布带亮芯强度 := 0.46:
	set(value):
		瀑布带亮芯强度 = value
		_request_sync()

@export_range(0.0, 1.0, 0.005) var 瀑布带细丝强度 := 0.56:
	set(value):
		瀑布带细丝强度 = value
		_request_sync()

@export_range(0.0, 2.0, 0.005) var 瀑布带脉冲强度 := 1.05:
	set(value):
		瀑布带脉冲强度 = value
		_request_sync()

@export_range(0.1, 2.5, 0.005) var 瀑布带脉冲速度 := 1.0:
	set(value):
		瀑布带脉冲速度 = value
		_request_sync()

@export var 瀑布带水色 := Color(0.52, 0.82, 0.94, 1.0):
	set(value):
		瀑布带水色 = value
		_request_sync()

@export var 瀑布带泡沫色 := Color(0.88, 0.97, 1.0, 1.0):
	set(value):
		瀑布带泡沫色 = value
		_request_sync()

@export var 瀑布带流动染色 := Color(0.48, 0.82, 1.0, 1.0):
	set(value):
		瀑布带流动染色 = value
		_request_sync()

@export_group("雾带跟随强度")
@export_range(0.0, 1.0, 0.005) var 雾带跟随强度 := 0.24:
	set(value):
		雾带跟随强度 = value
		_request_sync()

var _sync_queued := false
var _sync_in_progress := false
var _flow_time := 0.0
var _cache_refresh_elapsed := 999.0
var _live_rock_materials: Array[ShaderMaterial] = []
var _live_ribbon_materials: Array[ShaderMaterial] = []
var _resource_rock_materials: Array[ShaderMaterial] = []
var _resource_ribbon_materials: Array[ShaderMaterial] = []


func _ready() -> void:
	set_process(true)
	_request_sync()


func _process(delta: float) -> void:
	if Engine.is_editor_hint() and not 编辑器实时应用:
		return
	if not is_inside_tree():
		return
	_update_flow_time(delta)
	_cache_refresh_elapsed += delta
	if _live_rock_materials.is_empty() or _live_ribbon_materials.is_empty() or _cache_refresh_elapsed > 0.65:
		_cache_refresh_elapsed = 0.0
		_sync_live_scene_instances()
	else:
		_sync_live_flow_time()


func _request_sync() -> void:
	if Engine.is_editor_hint() and not 编辑器实时应用:
		return
	if not is_inside_tree():
		return
	if _sync_queued or _sync_in_progress:
		return
	_sync_queued = true
	_sync_all_water_materials()


func _sync_all_water_materials() -> void:
	_sync_queued = false
	if _sync_in_progress:
		return
	_sync_in_progress = true
	_update_flow_time(0.0)
	_resource_rock_materials.clear()
	_resource_ribbon_materials.clear()
	for path in ROCK_BODY_MATERIALS:
		var material := load(path) as ShaderMaterial
		if material == null:
			continue
		_apply_rock_material(material)
		_track_live_material(_resource_rock_materials, material)
		_save_material_if_needed(material, path)

	_sync_ribbon_material(WATERFALL_RIBBON_MATERIAL, 1.0)
	_sync_ribbon_material(WATERFALL_MIST_MATERIAL, 雾带跟随强度)
	_sync_live_scene_instances()
	_sync_in_progress = false


func _update_flow_time(delta: float) -> void:
	if Engine.is_editor_hint():
		_flow_time = fposmod(float(Time.get_ticks_msec()) * 0.001 * 预览时间倍率, 10000.0)
	else:
		_flow_time = fposmod(_flow_time + delta * 预览时间倍率, 10000.0)


func _sync_ribbon_material(path: String, scale: float) -> void:
	var material := load(path) as ShaderMaterial
	if material == null:
		return
	_apply_ribbon_material(material, scale)
	_track_live_material(_resource_ribbon_materials, material)
	_save_material_if_needed(material, path)


func _apply_rock_material(material: ShaderMaterial) -> void:
	material.set_shader_parameter("side_water_flow_speed", 岩体流速)
	material.set_shader_parameter("side_water_flow_strength", 岩体蓝色强度)
	material.set_shader_parameter("side_water_surface_sheet_strength", 表面水膜强度)
	material.set_shader_parameter("side_water_surface_sheet_coverage", 表面水膜覆盖)
	material.set_shader_parameter("side_water_shimmer_strength", 岩体流光强度)
	material.set_shader_parameter("side_water_soft_line_strength", 柔和水痕强度)
	material.set_shader_parameter("side_water_line_core_strength", 水痕亮芯强度)
	material.set_shader_parameter("side_water_extension_strength", 水痕下延强度)
	material.set_shader_parameter("side_water_extension_length", 水痕下延长度)
	material.set_shader_parameter("side_water_horizontal_suppression", 横向水痕压制)
	material.set_shader_parameter("side_water_line_edge_color", 水痕边缘颜色)
	material.set_shader_parameter("side_water_line_core_color", 水痕亮芯颜色)
	material.set_shader_parameter("side_water_flow_tint", 水流蓝色染色)
	material.set_shader_parameter("side_water_bend_amount", 自然弯曲程度)
	material.set_shader_parameter("side_water_lane_randomness", 水流间距随机度)
	material.set_shader_parameter("side_water_lane_count", ROCK_WATER_LANE_COUNT * 水流数量倍率)


func _apply_ribbon_material(material: ShaderMaterial, scale: float) -> void:
	material.set_shader_parameter("flow_speed", 瀑布带流速)
	material.set_shader_parameter("flow_strength", 瀑布带水流强度 * scale)
	material.set_shader_parameter("shimmer_strength", 瀑布带流光强度 * scale)
	material.set_shader_parameter("core_strength", 瀑布带亮芯强度 * scale)
	material.set_shader_parameter("thread_strength", 瀑布带细丝强度 * scale)
	material.set_shader_parameter("pulse_strength", 瀑布带脉冲强度 * scale)
	material.set_shader_parameter("pulse_speed", 瀑布带脉冲速度)
	material.set_shader_parameter("water_color", 瀑布带水色)
	material.set_shader_parameter("foam_color", 瀑布带泡沫色)
	material.set_shader_parameter("flow_tint", 瀑布带流动染色)
	material.set_shader_parameter("flow_bend_amount", 自然弯曲程度)
	material.set_shader_parameter("flow_lane_randomness", 水流间距随机度)
	material.set_shader_parameter("flow_lane_count", RIBBON_WATER_LANE_COUNT * 水流数量倍率)


func _sync_live_scene_instances() -> void:
	_live_rock_materials.clear()
	_live_ribbon_materials.clear()
	var tree := get_tree()
	if tree == null:
		return
	var scene_root: Node = null
	if Engine.is_editor_hint():
		scene_root = tree.edited_scene_root
	if scene_root == null:
		scene_root = tree.current_scene
	if scene_root == null:
		scene_root = tree.root
	_sync_node_recursive(scene_root)
	_sync_live_flow_time()


func _sync_node_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		_sync_mesh_instance(node as MeshInstance3D)
	for child in node.get_children():
		_sync_node_recursive(child)


func _sync_mesh_instance(mesh_instance: MeshInstance3D) -> void:
	var mesh := mesh_instance.mesh
	if mesh == null:
		return
	var node_name := String(mesh_instance.name)

	var material_override := mesh_instance.material_override as ShaderMaterial
	if material_override != null:
		_apply_material_for_node(material_override, node_name, 1.0)

	for surface_index in range(mesh.get_surface_count()):
		var expected_material := _expected_material_for_node(node_name)
		if expected_material != null:
			mesh.surface_set_material(surface_index, expected_material)
			_apply_material_for_node(expected_material, node_name, 1.0)

		var surface_override := mesh_instance.get_surface_override_material(surface_index) as ShaderMaterial
		if surface_override != null:
			_apply_material_for_node(surface_override, node_name, 1.0)

		var surface_material := mesh.surface_get_material(surface_index) as ShaderMaterial
		if surface_material != null:
			_apply_material_for_node(surface_material, node_name, 1.0)

		var active_material := mesh_instance.get_active_material(surface_index) as ShaderMaterial
		if active_material != null:
			_apply_material_for_node(active_material, node_name, 1.0)


func _expected_material_for_node(node_name: String) -> ShaderMaterial:
	if node_name.begins_with("Waterfall_Ribbon"):
		return load(WATERFALL_RIBBON_MATERIAL) as ShaderMaterial
	if node_name.begins_with("Waterfall_Mist"):
		return load(WATERFALL_MIST_MATERIAL) as ShaderMaterial
	return null


func _apply_material_for_node(material: ShaderMaterial, node_name: String, scale: float) -> void:
	var material_name := String(material.resource_name)
	if node_name.begins_with("Waterfall_Mist") or material_name == "Premium_Waterfall_Mist":
		_apply_ribbon_material(material, 雾带跟随强度)
		_track_live_material(_live_ribbon_materials, material)
	elif node_name.begins_with("Waterfall_Ribbon") or material_name == "Premium_Waterfall_Ribbon" or _uses_shader(material, WATERFALL_RIBBON_SHADER):
		_apply_ribbon_material(material, scale)
		_track_live_material(_live_ribbon_materials, material)
	elif ROCK_BODY_MATERIAL_NAMES.has(material_name) or _uses_shader(material, ROCK_BODY_SHADER):
		_apply_rock_material(material)
		_track_live_material(_live_rock_materials, material)


func _uses_shader(material: ShaderMaterial, shader_path: String) -> bool:
	if material.shader == null:
		return false
	return material.shader.resource_path == shader_path


func _track_live_material(list: Array[ShaderMaterial], material: ShaderMaterial) -> void:
	if not list.has(material):
		list.append(material)


func _sync_live_flow_time() -> void:
	for material in _resource_rock_materials:
		if is_instance_valid(material):
			material.set_shader_parameter("side_water_flow_time", _flow_time)
	for material in _resource_ribbon_materials:
		if is_instance_valid(material):
			material.set_shader_parameter("flow_time", _flow_time)
	for material in _live_rock_materials:
		if is_instance_valid(material):
			material.set_shader_parameter("side_water_flow_time", _flow_time)
	for material in _live_ribbon_materials:
		if is_instance_valid(material):
			material.set_shader_parameter("flow_time", _flow_time)


func _save_material_if_needed(material: ShaderMaterial, path: String) -> void:
	if not Engine.is_editor_hint():
		return
	if not 保存材质文件:
		return
	ResourceSaver.save(material, path)

extends Node3D

## Applies optional machine-local wallpaper and water textures.
##
## The tracked scene keeps the project-authored release-safe texture. A local
## user:// override can restore the owner's original wallpaper without adding a
## provenance-incomplete asset to the public runtime contract.

const CONFIG_PATH := "user://navigation_visual_overrides.json"
const WALL_PREFIX := "FarBackground_"
const VERTICAL_WALL_STATUS := "VERTICAL_LOCKED"

var _base_wall_materials: Dictionary = {}
var _base_wall_transforms: Dictionary = {}
var _base_floor_material: Material
var _base_surface_material: Material
var _base_wallpaper_status := "DEFAULT_RELEASE_TEXTURE"
var _base_water_status := "DEFAULT_RELEASE_TEXTURE"


func _ready() -> void:
	set_meta("wallpaper_override_status", "DEFAULT_RELEASE_TEXTURE")
	set_meta("water_override_status", "DEFAULT_RELEASE_TEXTURE")
	set_meta("wall_orientation_status", VERTICAL_WALL_STATUS)
	set_meta("wallpaper_wall_count", _background_walls().size())
	_apply_machine_local_override()
	_capture_base_material_state()
	set_meta("active_visual_profile", "base")


func _apply_machine_local_override() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if not (parsed is Dictionary):
		set_meta("wallpaper_override_status", "INVALID_CONFIG")
		return
	var config := parsed as Dictionary
	if not bool(config.get("enabled", false)):
		set_meta("wallpaper_override_status", "DISABLED")
		set_meta("water_override_status", "DISABLED")
		return
	_apply_wallpaper_override(config)
	_apply_water_override(config)


func _apply_wallpaper_override(config: Dictionary) -> void:
	var texture_path := String(config.get("far_horizon_texture", "")).strip_edges()
	if texture_path.is_empty() or not ResourceLoader.exists(texture_path, "Texture2D"):
		set_meta("wallpaper_override_status", "TEXTURE_UNAVAILABLE")
		return
	var texture_variant: Variant = load(texture_path)
	if not (texture_variant is Texture2D):
		set_meta("wallpaper_override_status", "TEXTURE_INVALID")
		return
	_apply_wallpaper_texture(texture_variant as Texture2D, "mat_navigation_local_wallpaper")
	var walls := _background_walls()
	set_meta("wallpaper_override_status", "APPLIED_LOCAL_WALLPAPER")
	set_meta("wallpaper_texture_path", texture_path)
	set_meta("wallpaper_wall_count", walls.size())


func _apply_water_override(config: Dictionary) -> void:
	var texture_path := String(config.get("water_texture", "")).strip_edges()
	if texture_path.is_empty() or not ResourceLoader.exists(texture_path, "Texture2D"):
		set_meta("water_override_status", "TEXTURE_UNAVAILABLE")
		return
	var texture_variant: Variant = load(texture_path)
	if not (texture_variant is Texture2D):
		set_meta("water_override_status", "TEXTURE_INVALID")
		return
	if not _apply_water_texture(texture_variant as Texture2D, "mat_navigation_local_water"):
		set_meta("water_override_status", "WATER_MATERIALS_UNAVAILABLE")
		return
	set_meta("water_override_status", "APPLIED_LOCAL_WATER")
	set_meta("water_texture_path", texture_path)


func apply_task_visual_profile(
	profile_id: String,
	wallpaper_texture_path: String,
	water_texture_path: String,
	_requested_wall_tilt_degrees: float = 0.0,
	wallpaper_bottom_composition: String = "landline_at_bottom",
	wallpaper_sea_band_max_fraction: float = 0.03,
) -> Dictionary:
	var wallpaper_variant: Variant = load(wallpaper_texture_path) if ResourceLoader.exists(wallpaper_texture_path, "Texture2D") else null
	var water_variant: Variant = load(water_texture_path) if ResourceLoader.exists(water_texture_path, "Texture2D") else null
	if not (wallpaper_variant is Texture2D) or not (water_variant is Texture2D):
		return {
			"applied": false,
			"profile_id": profile_id,
			"error": "TASK_TEXTURE_UNAVAILABLE",
			"wallpaper_texture": wallpaper_texture_path,
			"water_texture": water_texture_path,
		}
	_apply_wallpaper_texture(wallpaper_variant as Texture2D, "mat_task_%s_wallpaper" % profile_id)
	_enforce_vertical_wall_transforms()
	if not _apply_water_texture(water_variant as Texture2D, "mat_task_%s_water" % profile_id):
		restore_base_visuals()
		return {"applied": false, "profile_id": profile_id, "error": "TASK_WATER_MATERIAL_UNAVAILABLE"}
	set_meta("wallpaper_override_status", "TASK_VISUAL_PROFILE")
	set_meta("water_override_status", "TASK_VISUAL_PROFILE")
	set_meta("wallpaper_texture_path", wallpaper_texture_path)
	set_meta("water_texture_path", water_texture_path)
	set_meta("active_visual_profile", profile_id)
	set_meta("wall_orientation_status", VERTICAL_WALL_STATUS)
	set_meta("wallpaper_bottom_composition", wallpaper_bottom_composition)
	set_meta("wallpaper_sea_band_max_fraction", clampf(wallpaper_sea_band_max_fraction, 0.0, 0.03))
	return get_visual_profile_status()


func restore_base_visuals() -> void:
	if _base_wall_materials.is_empty():
		_capture_base_material_state()
	for wall in _background_walls():
		wall.material_override = _base_wall_materials.get(String(wall.name)) as Material
		if _base_wall_transforms.has(String(wall.name)):
			wall.transform = _base_wall_transforms[String(wall.name)] as Transform3D
	var floor := get_node_or_null("LakeFloor") as MeshInstance3D
	var surface := get_node_or_null("LakeSurfaceMotion") as MeshInstance3D
	if floor != null:
		floor.material_override = _base_floor_material
	if surface != null:
		surface.material_override = _base_surface_material
	set_meta("wallpaper_override_status", _base_wallpaper_status)
	set_meta("water_override_status", _base_water_status)
	set_meta("active_visual_profile", "base")
	set_meta("task_wall_tilt_degrees", 0.0)
	set_meta("wall_orientation_status", VERTICAL_WALL_STATUS)
	set_meta("wallpaper_bottom_composition", "base_release_texture")
	set_meta("wallpaper_sea_band_max_fraction", 0.0)


func get_visual_profile_status() -> Dictionary:
	return {
		"applied": true,
		"profile_id": String(get_meta("active_visual_profile", "base")),
		"wallpaper_status": String(get_meta("wallpaper_override_status", "UNKNOWN")),
		"water_status": String(get_meta("water_override_status", "UNKNOWN")),
		"wallpaper_texture": String(get_meta("wallpaper_texture_path", "")),
		"water_texture": String(get_meta("water_texture_path", "")),
		"wall_count": _background_walls().size(),
		"wall_tilt_degrees": float(get_meta("task_wall_tilt_degrees", 0.0)),
		"wall_orientation_status": String(get_meta("wall_orientation_status", VERTICAL_WALL_STATUS)),
		"walls_vertical": are_background_walls_vertical(),
		"wallpaper_bottom_composition": String(get_meta("wallpaper_bottom_composition", "unknown")),
		"wallpaper_sea_band_max_fraction": float(get_meta("wallpaper_sea_band_max_fraction", 0.0)),
	}


func are_background_walls_vertical() -> bool:
	for wall in _background_walls():
		var wall_up := wall.transform.basis.y.normalized()
		if absf(wall_up.dot(Vector3.UP)) < 0.9999:
			return false
	return true


func _capture_base_material_state() -> void:
	_base_wall_materials.clear()
	_base_wall_transforms.clear()
	for wall in _background_walls():
		_base_wall_materials[String(wall.name)] = wall.material_override
		_base_wall_transforms[String(wall.name)] = wall.transform
	var floor := get_node_or_null("LakeFloor") as MeshInstance3D
	var surface := get_node_or_null("LakeSurfaceMotion") as MeshInstance3D
	_base_floor_material = floor.material_override if floor != null else null
	_base_surface_material = surface.material_override if surface != null else null
	_base_wallpaper_status = String(get_meta("wallpaper_override_status", "DEFAULT_RELEASE_TEXTURE"))
	_base_water_status = String(get_meta("water_override_status", "DEFAULT_RELEASE_TEXTURE"))
	set_meta("task_wall_tilt_degrees", 0.0)
	set_meta("wall_orientation_status", VERTICAL_WALL_STATUS)


func _enforce_vertical_wall_transforms() -> void:
	for wall in _background_walls():
		var wall_name := String(wall.name)
		if not _base_wall_transforms.has(wall_name):
			continue
		wall.transform = _base_wall_transforms[wall_name] as Transform3D
	set_meta("task_wall_tilt_degrees", 0.0)
	set_meta("wall_orientation_status", VERTICAL_WALL_STATUS)


func _apply_wallpaper_texture(texture: Texture2D, material_name: String) -> void:
	var material := StandardMaterial3D.new()
	material.resource_name = material_name
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_texture = texture
	for wall in _background_walls():
		wall.material_override = material


func _apply_water_texture(texture: Texture2D, material_name: String) -> bool:
	var floor := get_node_or_null("LakeFloor") as MeshInstance3D
	var surface := get_node_or_null("LakeSurfaceMotion") as MeshInstance3D
	if floor == null or surface == null or floor.mesh == null or surface.mesh == null:
		return false
	var floor_source := floor.material_override as StandardMaterial3D
	if floor_source == null:
		floor_source = floor.mesh.surface_get_material(0) as StandardMaterial3D
	var surface_source := surface.material_override as ShaderMaterial
	if surface_source == null:
		surface_source = surface.mesh.surface_get_material(0) as ShaderMaterial
	if floor_source == null or surface_source == null:
		return false
	var floor_material := floor_source.duplicate() as StandardMaterial3D
	floor_material.resource_name = material_name + "_floor"
	floor_material.albedo_texture = texture
	floor.material_override = floor_material
	var surface_material := surface_source.duplicate() as ShaderMaterial
	surface_material.resource_name = material_name + "_surface"
	surface_material.set_shader_parameter("lake_texture", texture)
	surface.material_override = surface_material
	return true


func _background_walls() -> Array[MeshInstance3D]:
	var walls: Array[MeshInstance3D] = []
	for child in get_children():
		if child is MeshInstance3D and String(child.name).begins_with(WALL_PREFIX):
			walls.append(child as MeshInstance3D)
	return walls

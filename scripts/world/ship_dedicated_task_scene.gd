extends Node3D
class_name ShipDedicatedTaskScene

## Procedural visual construction for five isolated maritime task scenes.
## Each scene is a separate PackedScene and owns its task structures, lights and
## landmarks. Every task owns a vertical landline-at-bottom wallpaper profile;
## the dynamic water material is shared. Collision authority remains in
## ShipNavigationObstacles so rendered geometry and safety gates stay auditable.

const WATER_Y := -140.05
const SKY_RADIUS := 540.0
const TASK_WALL_RADIUS := 460.0
const TASK_WALL_HEIGHT := 620.0
const TASK_WALL_PREFIX := "TaskBackdrop_"

@export_enum(
	"auto_berthing",
	"auto_unberthing",
	"narrow_channel_head_on",
	"crossing_starboard",
	"narrow_channel_overtaking"
) var scene_key := "auto_berthing"
@export var scene_title := "DEDICATED MARITIME TASK"

var _feature_tags: Array[String] = []
var _visual_node_count := 0
var _task_wall_root: Node3D
var _task_wallpaper_texture_path := ""
var _task_water_texture_path := ""


func _ready() -> void:
	add_to_group(&"ship_dedicated_task_scene")
	_build_common_environment()
	match scene_key:
		"auto_berthing":
			_build_auto_berthing_scene()
		"auto_unberthing":
			_build_auto_unberthing_scene()
		"narrow_channel_head_on":
			_build_head_on_channel_scene()
		"crossing_starboard":
			_build_crossing_scene()
		"narrow_channel_overtaking":
			_build_overtaking_channel_scene()
		_:
			push_error("Unknown dedicated task scene: %s" % scene_key)
	set_meta("dedicated_scene_key", scene_key)
	set_meta("dedicated_scene_title", scene_title)
	set_meta("dedicated_scene_visual_node_count", _visual_node_count)
	set_meta("dedicated_scene_feature_tags", _feature_tags.duplicate())


func get_scene_snapshot() -> Dictionary:
	return {
		"scene_key": scene_key,
		"scene_title": scene_title,
		"dedicated_scene": true,
		"uses_legacy_rock_environment": false,
		"visual_node_count": _visual_node_count,
		"feature_tags": _feature_tags.duplicate(),
		"task_wall_count": _task_walls().size(),
		"task_walls_vertical": _task_walls_vertical(),
		"task_wallpaper_texture": _task_wallpaper_texture_path,
		"task_water_texture": _task_water_texture_path,
		"production_authority": false,
	}


func _build_common_environment() -> void:
	# BackgroundWalls is re-skinned by ShipScenarioController with the active
	# task's vertical landline wallpaper and shared water texture. This scene adds
	# task geometry only.
	_feature_tags.append("task_specific_wallpaper_and_water")
	_build_task_backdrop_walls()


func apply_task_visual_profile(
	wallpaper_texture_path: String,
	water_texture_path: String,
	wallpaper_bottom_composition: String = "landline_at_bottom",
	wallpaper_sea_band_max_fraction: float = 0.03,
) -> Dictionary:
	var wallpaper_variant: Variant = load(wallpaper_texture_path) if ResourceLoader.exists(wallpaper_texture_path, "Texture2D") else null
	var water_variant: Variant = load(water_texture_path) if ResourceLoader.exists(water_texture_path, "Texture2D") else null
	if not (wallpaper_variant is Texture2D) or not (water_variant is Texture2D):
		return {
			"applied": false,
			"error": "TASK_TEXTURE_UNAVAILABLE",
			"wallpaper_texture": wallpaper_texture_path,
			"water_texture": water_texture_path,
		}
	var material := StandardMaterial3D.new()
	material.resource_name = "mat_dedicated_%s_vertical_wallpaper" % scene_key
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_texture = wallpaper_variant as Texture2D
	for wall in _task_walls():
		wall.material_override = material
	_task_wallpaper_texture_path = wallpaper_texture_path
	_task_water_texture_path = water_texture_path
	return {
		"applied": true,
		"wall_count": _task_walls().size(),
		"walls_vertical": _task_walls_vertical(),
		"wallpaper_texture": wallpaper_texture_path,
		"water_texture": water_texture_path,
		"wallpaper_bottom_composition": wallpaper_bottom_composition,
		"wallpaper_sea_band_max_fraction": clampf(wallpaper_sea_band_max_fraction, 0.0, 0.03),
	}


func _build_task_backdrop_walls() -> void:
	_task_wall_root = Node3D.new()
	_task_wall_root.name = "DedicatedTaskBackdropWalls"
	add_child(_task_wall_root)
	_add_task_wall("North", Vector3(0.0, WATER_Y + TASK_WALL_HEIGHT * 0.5, -TASK_WALL_RADIUS), 0.0)
	_add_task_wall("South", Vector3(0.0, WATER_Y + TASK_WALL_HEIGHT * 0.5, TASK_WALL_RADIUS), PI)
	_add_task_wall("East", Vector3(TASK_WALL_RADIUS, WATER_Y + TASK_WALL_HEIGHT * 0.5, 0.0), -PI * 0.5)
	_add_task_wall("West", Vector3(-TASK_WALL_RADIUS, WATER_Y + TASK_WALL_HEIGHT * 0.5, 0.0), PI * 0.5)


func _add_task_wall(direction: String, position_value: Vector3, yaw: float) -> void:
	var wall := MeshInstance3D.new()
	wall.name = TASK_WALL_PREFIX + direction
	var mesh := QuadMesh.new()
	mesh.size = Vector2(TASK_WALL_RADIUS * 2.0, TASK_WALL_HEIGHT)
	wall.mesh = mesh
	wall.position = position_value
	wall.rotation.y = yaw
	wall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	wall.extra_cull_margin = TASK_WALL_RADIUS * 2.0
	_task_wall_root.add_child(wall)
	_visual_node_count += 1


func _task_walls() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if _task_wall_root == null:
		return result
	for raw_child in _task_wall_root.get_children():
		if raw_child is MeshInstance3D and String(raw_child.name).begins_with(TASK_WALL_PREFIX):
			result.append(raw_child as MeshInstance3D)
	return result


func _task_walls_vertical() -> bool:
	for wall in _task_walls():
		if absf(wall.transform.basis.y.normalized().dot(Vector3.UP)) < 0.9999:
			return false
	return not _task_walls().is_empty()


func _scene_palette() -> Dictionary:
	match scene_key:
		"auto_berthing":
			return {
				"sky": Color(0.12, 0.40, 0.62, 1.0),
				"water": Color(0.10, 0.52, 0.60, 1.0),
				"wake": Color(0.18, 0.96, 1.0, 0.34),
				"sun": Color(1.0, 0.78, 0.42, 1.0),
			}
		"auto_unberthing":
			return {
				"sky": Color(0.19, 0.46, 0.66, 1.0),
				"water": Color(0.12, 0.56, 0.63, 1.0),
				"wake": Color(0.36, 1.0, 0.82, 0.30),
				"sun": Color(1.0, 0.86, 0.58, 1.0),
			}
		"narrow_channel_head_on":
			return {
				"sky": Color(0.20, 0.36, 0.50, 1.0),
				"water": Color(0.08, 0.40, 0.48, 1.0),
				"wake": Color(0.30, 0.82, 1.0, 0.28),
				"sun": Color(1.0, 0.72, 0.38, 1.0),
			}
		"crossing_starboard":
			return {
				"sky": Color(0.11, 0.49, 0.76, 1.0),
				"water": Color(0.08, 0.58, 0.74, 1.0),
				"wake": Color(0.42, 1.0, 0.94, 0.30),
				"sun": Color(1.0, 0.90, 0.62, 1.0),
			}
		"narrow_channel_overtaking":
			return {
				"sky": Color(0.23, 0.35, 0.47, 1.0),
				"water": Color(0.09, 0.43, 0.51, 1.0),
				"wake": Color(0.22, 0.86, 1.0, 0.28),
				"sun": Color(1.0, 0.66, 0.30, 1.0),
			}
	return {}


func _build_auto_berthing_scene() -> void:
	scene_title = "BERTH A-17 // PRECISION APPROACH BASIN"
	_feature_tags.assign([
		"precision_berth_target",
		"container_terminal",
		"gantry_cranes",
		"fenders_and_bollards",
		"leading_lights",
	])
	_add_breakwater(Vector3(-174.0, 0.0, 0.0), Vector3(12.0, 8.0, 140.0), "WestBreakwater")
	_add_breakwater(Vector3(132.0, 0.0, -66.0), Vector3(16.0, 8.0, 106.0), "EastBreakwater")
	_add_quay(Vector3(104.0, 0.0, 18.0), Vector3(26.0, 8.0, 118.0), "PrecisionCargoQuay", Color(0.25, 0.29, 0.32, 1.0))
	_add_quay(Vector3(64.0, 0.0, 36.0), Vector3(72.0, 5.0, 12.0), "BerthFinger", Color(0.30, 0.32, 0.34, 1.0))
	_add_quay(Vector3(6.0, 0.0, -92.0), Vector3(126.0, 6.0, 16.0), "NorthServicePier", Color(0.22, 0.26, 0.29, 1.0))
	_add_quay(Vector3(24.0, 0.0, 58.0), Vector3(138.0, 6.0, 16.0), "SouthMooringPier", Color(0.24, 0.28, 0.30, 1.0))
	for z in [-28.0, -4.0, 20.0, 44.0, 68.0]:
		_add_fender(Vector3(90.2, 0.0, z), "QuayFender_%03d" % int(z + 40.0))
		_add_bollard(Vector3(88.0, 0.0, z + 7.0), "MooringBollard_%03d" % int(z + 40.0), Color(1.0, 0.72, 0.20, 1.0))
	_add_berth_target(Vector3(82.0, 0.0, 18.0), 0.0)
	_add_gantry_crane(Vector3(112.0, 0.0, -24.0), "GantryCrane_A", Color(1.0, 0.62, 0.12, 1.0))
	_add_gantry_crane(Vector3(112.0, 0.0, 32.0), "GantryCrane_B", Color(1.0, 0.72, 0.18, 1.0))
	_add_container_yard(Vector3(124.0, 0.0, -12.0), 3, 5)
	_add_warehouse(Vector3(134.0, 0.0, 82.0), Vector3(42.0, 13.0, 30.0), "TerminalWarehouse")
	for index in range(6):
		_add_navigation_buoy(
			Vector3(-98.0 + float(index) * 30.0, 0.0, -74.0 + float(index % 2) * 12.0),
			"ApproachLight_%02d" % index,
			Color(0.30, 1.0, 0.58, 1.0) if index % 2 == 0 else Color(1.0, 0.24, 0.18, 1.0)
		)
	_add_scene_label(Vector3(72.0, WATER_Y + 18.0, 56.0), "BERTH A-17  //  LOW-SPEED PRECISION ZONE", Color(0.42, 1.0, 0.72, 1.0))


func _build_auto_unberthing_scene() -> void:
	scene_title = "PILOT SERVICE HARBOUR // DEPARTURE BASIN"
	_feature_tags.assign([
		"turning_basin",
		"pilot_station",
		"tug_service_docks",
		"departure_gate",
		"speed_control_lights",
	])
	_add_far_hills(Color(0.13, 0.27, 0.31, 1.0), 14)
	_add_quay(Vector3(104.0, 0.0, 18.0), Vector3(26.0, 8.0, 118.0), "DepartureQuay", Color(0.23, 0.30, 0.33, 1.0))
	_add_quay(Vector3(64.0, 0.0, 36.0), Vector3(72.0, 5.0, 12.0), "ServiceFinger", Color(0.28, 0.34, 0.36, 1.0))
	_add_breakwater(Vector3(-144.0, 0.0, -12.0), Vector3(16.0, 8.0, 142.0), "DepartureWestArm")
	_add_breakwater(Vector3(132.0, 0.0, -66.0), Vector3(16.0, 8.0, 106.0), "DepartureEastArm")
	_add_quay(Vector3(6.0, 0.0, -92.0), Vector3(126.0, 6.0, 16.0), "PilotStationPier", Color(0.20, 0.28, 0.32, 1.0))
	_add_quay(Vector3(24.0, 0.0, 58.0), Vector3(138.0, 6.0, 16.0), "TugServicePier", Color(0.20, 0.30, 0.32, 1.0))
	_add_turning_basin(Vector3(24.0, 0.0, -18.0), 54.0)
	_add_control_tower(Vector3(72.0, 0.0, 50.0), "PilotControlTower", Color(0.22, 0.88, 1.0, 1.0))
	_add_warehouse(Vector3(112.0, 0.0, 72.0), Vector3(34.0, 11.0, 24.0), "TugWorkshop")
	for index in range(3):
		_add_decorative_service_boat(Vector3(50.0 - float(index) * 18.0, 0.0, 46.0), "ServiceBoat_%02d" % index, Color(1.0, 0.48 + float(index) * 0.12, 0.12, 1.0))
	for index in range(5):
		_add_navigation_buoy(
			Vector3(-116.0 + float(index) * 42.0, 0.0, -78.0 + float(index % 2) * 10.0),
			"DepartureGate_%02d" % index,
			Color(0.36, 1.0, 0.62, 1.0) if index % 2 == 0 else Color(1.0, 0.25, 0.16, 1.0)
		)
	_add_scene_label(Vector3(-76.0, WATER_Y + 17.0, -98.0), "OUTBOUND GATE  //  MAX 5.0 kn", Color(0.38, 1.0, 0.68, 1.0))


func _build_head_on_channel_scene() -> void:
	scene_title = "NARROW CHANNEL N-14 // HEAD-ON PASSING"
	_feature_tags.assign([
		"stone_revetment_channel",
		"starboard_lane_lights",
		"reciprocal_traffic_gate",
		"distance_marker_posts",
		"rule_9_14_signage",
	])
	_add_far_hills(Color(0.10, 0.20, 0.24, 1.0), 20)
	_add_channel_bank(-88.0, 70.0, 430.0, "WestRevetment", Color(0.20, 0.26, 0.28, 1.0), true)
	_add_channel_bank(88.0, 70.0, 430.0, "EastRevetment", Color(0.20, 0.26, 0.28, 1.0), false)
	_add_channel_lane_markings(-22.0, -206.0, 206.0, Color(0.28, 0.86, 1.0, 0.36))
	for index in range(10):
		var z := -190.0 + float(index) * 42.0
		_add_navigation_buoy(Vector3(-45.0, 0.0, z), "WestGreen_%02d" % index, Color(0.24, 1.0, 0.52, 1.0))
		_add_navigation_buoy(Vector3(45.0, 0.0, z + 18.0), "EastRed_%02d" % index, Color(1.0, 0.20, 0.16, 1.0))
		_add_distance_post(Vector3(-57.0, 0.0, z), "CH-%02d" % (index + 1), Color(0.40, 0.94, 1.0, 1.0))
	_add_leading_light_pair(Vector3(-22.0, 0.0, -214.0), 180.0, "SouthLeadingLights")
	_add_leading_light_pair(Vector3(-22.0, 0.0, 214.0), 0.0, "NorthLeadingLights")
	_add_scene_label(Vector3(-22.0, WATER_Y + 24.0, 202.0), "RULE 9 / 14  //  KEEP TO STARBOARD", Color(1.0, 0.78, 0.26, 1.0))


func _build_crossing_scene() -> void:
	scene_title = "OFFSHORE CROSSING RANGE C-15 // GIVE-WAY"
	_feature_tags.assign([
		"open_sea_crossing_range",
		"traffic_separation_guides",
		"starboard_sector_beacons",
		"offshore_lighthouse",
		"cpa_reference_grid",
	])
	_add_low_island_ring()
	_add_crossing_lane(Vector3(0.0, 0.0, -18.0), 90.0, Color(0.22, 0.90, 1.0, 0.18), "OwnShipLane")
	_add_crossing_lane(Vector3(30.0, 0.0, -16.0), 0.0, Color(1.0, 0.42, 0.20, 0.18), "StandOnLane")
	_add_cpa_reference_grid(Vector3(18.0, 0.0, -34.0), 84.0)
	for index in range(6):
		_add_navigation_buoy(Vector3(-150.0 + float(index) * 60.0, 0.0, -58.0), "OwnLane_%02d" % index, Color(0.26, 0.94, 1.0, 1.0))
		_add_navigation_buoy(Vector3(62.0, 0.0, -152.0 + float(index) * 60.0), "CrossLane_%02d" % index, Color(1.0, 0.32, 0.18, 1.0))
	_add_lighthouse(Vector3(-204.0, 0.0, 158.0), "NorthWestLighthouse")
	_add_lighthouse(Vector3(198.0, 0.0, -164.0), "SouthEastLighthouse")
	_add_scene_label(Vector3(12.0, WATER_Y + 28.0, 126.0), "RULE 15 / 16  //  STARBOARD CROSSING RANGE", Color(1.0, 0.84, 0.28, 1.0))


func _build_overtaking_channel_scene() -> void:
	scene_title = "INDUSTRIAL CANAL O-13 // CONTROLLED OVERTAKING"
	_feature_tags.assign([
		"industrial_canal",
		"overtaking_clearance_lane",
		"slow_vessel_corridor",
		"communication_gate_board",
		"mile_marker_lights",
	])
	_add_horizon_city(Color(0.12, 0.18, 0.21, 1.0), 20)
	_add_channel_bank(-96.0, 74.0, 430.0, "GreenWestLevee", Color(0.16, 0.27, 0.22, 1.0), true)
	_add_channel_bank(96.0, 74.0, 430.0, "IndustrialEastQuay", Color(0.24, 0.27, 0.29, 1.0), false)
	_add_channel_lane_markings(18.0, -210.0, 210.0, Color(1.0, 0.70, 0.20, 0.34))
	_add_channel_lane_markings(-18.0, -210.0, 210.0, Color(0.26, 0.92, 1.0, 0.25))
	for index in range(7):
		var z := -174.0 + float(index) * 58.0
		_add_warehouse(Vector3(126.0, 0.0, z), Vector3(26.0, 6.0 + float(index % 2) * 3.0, 24.0), "CanalWarehouse_%02d" % index)
		_add_distance_post(Vector3(-58.0, 0.0, z), "MILE %02d" % (index + 1), Color(1.0, 0.76, 0.24, 1.0))
		_add_navigation_buoy(Vector3(50.0, 0.0, z + 22.0), "CanalRed_%02d" % index, Color(1.0, 0.22, 0.14, 1.0))
		_add_navigation_buoy(Vector3(-50.0, 0.0, z), "CanalGreen_%02d" % index, Color(0.24, 1.0, 0.50, 1.0))
	_add_gantry_crane(Vector3(118.0, 0.0, -86.0), "CanalCrane_A", Color(1.0, 0.58, 0.14, 1.0))
	_add_gantry_crane(Vector3(118.0, 0.0, 88.0), "CanalCrane_B", Color(1.0, 0.68, 0.18, 1.0))
	_add_agreement_gate(Vector3(0.0, 0.0, -116.0))
	_add_scene_label(Vector3(0.0, WATER_Y + 26.0, 150.0), "RULE 9 / 13  //  AGREEMENT REQUIRED", Color(1.0, 0.66, 0.22, 1.0))


func _add_sky_dome(color: Color) -> void:
	var dome := MeshInstance3D.new()
	dome.name = "DedicatedSkyDome"
	var mesh := SphereMesh.new()
	mesh.radius = SKY_RADIUS
	mesh.height = SKY_RADIUS * 2.0
	mesh.radial_segments = 48
	mesh.rings = 24
	dome.mesh = mesh
	dome.position = Vector3(0.0, 30.0, 0.0)
	var material := _material(color, 0.04)
	material.cull_mode = BaseMaterial3D.CULL_FRONT
	dome.material_override = material
	add_child(dome)
	_visual_node_count += 1


func _add_water_field(color: Color, wake_color: Color) -> void:
	_add_box(self, "DedicatedWaterDepth", Vector3(0.0, WATER_Y - 1.4, 0.0), Vector3(520.0, 2.8, 520.0), color.darkened(0.28))
	var surface := MeshInstance3D.new()
	surface.name = "DedicatedWaterSurface"
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(520.0, 520.0)
	mesh.subdivide_width = 32
	mesh.subdivide_depth = 32
	surface.mesh = mesh
	surface.position.y = WATER_Y + 0.04
	var material := _material(Color(color.r * 1.25, color.g * 1.18, color.b * 1.16, 0.88), 0.20, true)
	material.metallic = 0.18
	material.roughness = 0.22
	surface.material_override = material
	add_child(surface)
	_visual_node_count += 1
	for index in range(18):
		var z := -238.0 + float(index) * 28.0
		_add_box(
			self,
			"WaveGlint_%02d" % index,
			Vector3(float((index * 37) % 62) - 31.0, WATER_Y + 0.10, z),
			Vector3(46.0 + float(index % 4) * 12.0, 0.025, 0.16),
			wake_color,
			1.2,
			true
		)


func _add_sun_disc(color: Color) -> void:
	var sun := MeshInstance3D.new()
	sun.name = "DedicatedSunDisc"
	var mesh := SphereMesh.new()
	mesh.radius = 16.0
	mesh.height = 32.0
	sun.mesh = mesh
	sun.position = Vector3(-290.0, 210.0, -360.0)
	sun.material_override = _material(color, 4.0)
	add_child(sun)
	_visual_node_count += 1


func _add_horizon_city(color: Color, count: int) -> void:
	for index in range(count):
		var angle := TAU * float(index) / float(count)
		var radius := 330.0
		var height := 12.0 + float((index * 17) % 18)
		var width := 12.0 + float((index * 11) % 12)
		_add_box(
			self,
			"HorizonStructure_%02d" % index,
			Vector3(cos(angle) * radius, WATER_Y + height * 0.5, sin(angle) * radius),
			Vector3(width, height, width * 0.72),
			color.lightened(float(index % 3) * 0.05)
		)


func _add_far_hills(color: Color, count: int) -> void:
	for index in range(count):
		var angle := TAU * float(index) / float(count)
		var radius := 340.0
		var rock := MeshInstance3D.new()
		rock.name = "FarShore_%02d" % index
		var mesh := PrismMesh.new()
		mesh.size = Vector3(60.0 + float(index % 4) * 12.0, 18.0 + float(index % 3) * 7.0, 50.0)
		rock.mesh = mesh
		rock.position = Vector3(cos(angle) * radius, WATER_Y + mesh.size.y * 0.45, sin(angle) * radius)
		rock.rotation.y = -angle
		rock.material_override = _material(color.lightened(float(index % 2) * 0.06), 0.04)
		add_child(rock)
		_visual_node_count += 1


func _add_low_island_ring() -> void:
	for index in range(12):
		var angle := TAU * float(index) / 12.0
		var radius := 318.0 + float(index % 3) * 18.0
		var island := MeshInstance3D.new()
		island.name = "OffshoreIsland_%02d" % index
		var mesh := CylinderMesh.new()
		mesh.top_radius = 30.0 + float(index % 4) * 9.0
		mesh.bottom_radius = mesh.top_radius * 1.22
		mesh.height = 8.0 + float(index % 3) * 4.0
		island.mesh = mesh
		island.position = Vector3(cos(angle) * radius, WATER_Y + mesh.height * 0.5, sin(angle) * radius)
		island.material_override = _material(Color(0.12, 0.29, 0.25, 1.0), 0.05)
		add_child(island)
		_visual_node_count += 1


func _add_breakwater(position: Vector3, size: Vector3, item_name: String) -> void:
	_add_box(self, item_name + "_Core", Vector3(position.x, WATER_Y + size.y * 0.5, position.z), size, Color(0.19, 0.23, 0.25, 1.0))
	var length := int(maxf(size.x, size.z) / 12.0)
	for index in range(length):
		var offset := -maxf(size.x, size.z) * 0.5 + 6.0 + float(index) * 12.0
		var rock_position := Vector3(position.x, WATER_Y + 2.6, position.z)
		if size.z > size.x:
			rock_position.z += offset
		else:
			rock_position.x += offset
		_add_cylinder(self, item_name + "_Armour_%02d" % index, rock_position, 5.2, 5.2, Color(0.26, 0.29, 0.30, 1.0))


func _add_quay(position: Vector3, size: Vector3, item_name: String, color: Color) -> void:
	_add_box(self, item_name, Vector3(position.x, WATER_Y + size.y * 0.5, position.z), size, color)
	_add_box(self, item_name + "_Edge", Vector3(position.x - size.x * 0.5 - 0.35, WATER_Y + size.y - 0.45, position.z), Vector3(0.7, 0.9, size.z), Color(0.72, 0.76, 0.72, 1.0))


func _add_fender(position: Vector3, item_name: String) -> void:
	_add_box(self, item_name, Vector3(position.x, WATER_Y + 2.2, position.z), Vector3(1.4, 4.4, 6.0), Color(0.03, 0.04, 0.045, 1.0))


func _add_bollard(position: Vector3, item_name: String, color: Color) -> void:
	_add_cylinder(self, item_name + "_Base", Vector3(position.x, WATER_Y + 5.8, position.z), 0.65, 1.2, color)
	_add_cylinder(self, item_name + "_Cap", Vector3(position.x, WATER_Y + 6.5, position.z), 0.95, 0.30, color.lightened(0.18))


func _add_berth_target(position: Vector3, heading_degrees: float) -> void:
	var ring := MeshInstance3D.new()
	ring.name = "PrecisionBerthTarget"
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 5.2
	ring_mesh.outer_radius = 6.0
	ring.mesh = ring_mesh
	ring.position = Vector3(position.x, WATER_Y + 0.18, position.z)
	ring.rotation.y = deg_to_rad(heading_degrees)
	ring.material_override = _material(Color(0.24, 1.0, 0.62, 0.88), 3.6, true)
	add_child(ring)
	_visual_node_count += 1
	_add_box(self, "BerthHeadingVector", Vector3(position.x, WATER_Y + 0.20, position.z - 11.0), Vector3(0.6, 0.12, 22.0), Color(0.24, 1.0, 0.62, 0.72), 2.8, true)


func _add_gantry_crane(position: Vector3, item_name: String, color: Color) -> void:
	for side in [-1.0, 1.0]:
		_add_box(self, item_name + "_Leg_%s" % ("L" if side < 0.0 else "R"), Vector3(position.x, WATER_Y + 16.0, position.z + side * 11.0), Vector3(3.0, 32.0, 3.0), color)
	_add_box(self, item_name + "_Bridge", Vector3(position.x, WATER_Y + 31.0, position.z), Vector3(4.0, 3.0, 27.0), color)
	_add_box(self, item_name + "_Boom", Vector3(position.x - 24.0, WATER_Y + 29.0, position.z), Vector3(50.0, 2.0, 3.2), color)
	_add_box(self, item_name + "_Cab", Vector3(position.x - 9.0, WATER_Y + 26.0, position.z), Vector3(7.0, 5.0, 6.0), Color(0.10, 0.26, 0.31, 1.0))


func _add_container_yard(origin: Vector3, columns: int, rows: int) -> void:
	var colors := [
		Color(0.12, 0.48, 0.78, 1.0),
		Color(0.88, 0.28, 0.16, 1.0),
		Color(0.92, 0.68, 0.16, 1.0),
		Color(0.16, 0.62, 0.38, 1.0),
	]
	for column in range(columns):
		for row in range(rows):
			var height := 3.0 + float((column + row) % 3) * 2.4
			_add_box(
				self,
				"Container_%02d_%02d" % [column, row],
				Vector3(origin.x + float(column) * 9.0, WATER_Y + 8.0 + height * 0.5, origin.z + float(row) * 13.0),
				Vector3(7.5, height, 11.0),
				colors[(column + row) % colors.size()]
			)


func _add_warehouse(position: Vector3, size: Vector3, item_name: String) -> void:
	_add_box(self, item_name + "_Body", Vector3(position.x, WATER_Y + size.y * 0.5 + 4.0, position.z), size, Color(0.28, 0.34, 0.37, 1.0))
	_add_box(self, item_name + "_Roof", Vector3(position.x, WATER_Y + size.y + 4.5, position.z), Vector3(size.x + 2.0, 1.0, size.z + 2.0), Color(0.14, 0.19, 0.22, 1.0))
	for door_index in range(3):
		_add_box(self, item_name + "_Door_%02d" % door_index, Vector3(position.x - size.x * 0.5 - 0.15, WATER_Y + 7.2, position.z - 7.0 + float(door_index) * 7.0), Vector3(0.35, 5.6, 4.5), Color(0.08, 0.14, 0.17, 1.0))


func _add_turning_basin(position: Vector3, radius: float) -> void:
	for ring_index in range(3):
		var ring := MeshInstance3D.new()
		ring.name = "TurningBasinRing_%02d" % ring_index
		var mesh := TorusMesh.new()
		mesh.inner_radius = radius - float(ring_index) * 10.0 - 0.35
		mesh.outer_radius = radius - float(ring_index) * 10.0
		ring.mesh = mesh
		ring.position = Vector3(position.x, WATER_Y + 0.12, position.z)
		ring.material_override = _material(Color(0.34, 1.0, 0.78, 0.36 - float(ring_index) * 0.08), 1.6, true)
		add_child(ring)
		_visual_node_count += 1


func _add_control_tower(position: Vector3, item_name: String, accent: Color) -> void:
	_add_cylinder(self, item_name + "_Shaft", Vector3(position.x, WATER_Y + 16.0, position.z), 4.2, 26.0, Color(0.22, 0.28, 0.31, 1.0))
	_add_box(self, item_name + "_Cab", Vector3(position.x, WATER_Y + 31.0, position.z), Vector3(14.0, 7.0, 14.0), Color(0.08, 0.28, 0.36, 0.96), 0.8, true)
	_add_cylinder(self, item_name + "_Radar", Vector3(position.x, WATER_Y + 37.0, position.z), 0.8, 5.0, accent)
	_add_box(self, item_name + "_RadarBar", Vector3(position.x, WATER_Y + 40.0, position.z), Vector3(12.0, 0.5, 0.8), accent, 2.4)


func _add_decorative_service_boat(position: Vector3, item_name: String, color: Color) -> void:
	_add_box(self, item_name + "_Hull", Vector3(position.x, WATER_Y + 0.8, position.z), Vector3(5.0, 1.6, 12.0), color)
	_add_box(self, item_name + "_Cabin", Vector3(position.x, WATER_Y + 2.4, position.z - 1.0), Vector3(4.0, 2.0, 5.0), Color(0.82, 0.93, 0.96, 1.0))


func _add_channel_bank(x: float, width: float, length: float, item_name: String, color: Color, west: bool) -> void:
	_add_box(self, item_name + "_Foundation", Vector3(x, WATER_Y + 5.0, 0.0), Vector3(width, 10.0, length), color)
	var inner_x := x + width * 0.5 if west else x - width * 0.5
	for step_index in range(3):
		var offset := float(step_index) * 4.0 * (1.0 if west else -1.0)
		_add_box(
			self,
			item_name + "_Revetment_%02d" % step_index,
			Vector3(inner_x + offset, WATER_Y + 1.2 + float(step_index) * 1.5, 0.0),
			Vector3(8.0, 2.4 + float(step_index), length),
			color.lightened(0.05 + float(step_index) * 0.04)
		)
	for marker_index in range(9):
		var z := -190.0 + float(marker_index) * 47.0
		_add_light_post(Vector3(inner_x + (12.0 if west else -12.0), 0.0, z), item_name + "_Light_%02d" % marker_index, Color(1.0, 0.76, 0.30, 1.0))


func _add_channel_lane_markings(x: float, start_z: float, end_z: float, color: Color) -> void:
	var count := int((end_z - start_z) / 24.0)
	for index in range(count):
		_add_box(self, "LaneMark_%s_%02d" % [str(int(x)), index], Vector3(x, WATER_Y + 0.12, start_z + float(index) * 24.0 + 7.0), Vector3(0.6, 0.04, 14.0), color, 1.2, true)


func _add_distance_post(position: Vector3, text: String, color: Color) -> void:
	_add_cylinder(self, "DistancePost_%s" % text, Vector3(position.x, WATER_Y + 5.0, position.z), 0.5, 10.0, color)
	_add_scene_label(Vector3(position.x, WATER_Y + 12.0, position.z), text, color)


func _add_leading_light_pair(position: Vector3, heading_degrees: float, item_name: String) -> void:
	var direction := Vector3(sin(deg_to_rad(heading_degrees)), 0.0, cos(deg_to_rad(heading_degrees)))
	for index in range(2):
		var point := position + direction * float(index) * 18.0
		_add_control_tower(point, item_name + "_%02d" % index, Color(0.32, 1.0, 0.62, 1.0))


func _add_crossing_lane(center: Vector3, heading_degrees: float, color: Color, item_name: String) -> void:
	var lane := MeshInstance3D.new()
	lane.name = item_name
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(360.0, 34.0)
	lane.mesh = mesh
	lane.position = Vector3(center.x, WATER_Y + 0.09, center.z)
	lane.rotation.y = deg_to_rad(heading_degrees)
	lane.material_override = _material(color, 1.0, true)
	add_child(lane)
	_visual_node_count += 1


func _add_cpa_reference_grid(center: Vector3, radius: float) -> void:
	for ring_index in range(1, 5):
		var ring := MeshInstance3D.new()
		ring.name = "CPAReferenceRing_%02d" % ring_index
		var mesh := TorusMesh.new()
		mesh.inner_radius = radius * float(ring_index) / 4.0 - 0.22
		mesh.outer_radius = radius * float(ring_index) / 4.0
		ring.mesh = mesh
		ring.position = Vector3(center.x, WATER_Y + 0.13, center.z)
		ring.material_override = _material(Color(0.30, 0.96, 1.0, 0.20), 1.2, true)
		add_child(ring)
		_visual_node_count += 1


func _add_lighthouse(position: Vector3, item_name: String) -> void:
	_add_cylinder(self, item_name + "_Tower", Vector3(position.x, WATER_Y + 11.0, position.z), 4.0, 22.0, Color(0.86, 0.88, 0.84, 1.0))
	_add_cylinder(self, item_name + "_Band", Vector3(position.x, WATER_Y + 12.0, position.z), 4.2, 4.0, Color(0.88, 0.16, 0.12, 1.0))
	_add_cylinder(self, item_name + "_Lantern", Vector3(position.x, WATER_Y + 23.0, position.z), 2.2, 3.0, Color(1.0, 0.84, 0.32, 0.96), 4.0, true)
	_add_point_light(Vector3(position.x, WATER_Y + 24.0, position.z), Color(1.0, 0.82, 0.36, 1.0), 22.0, 2.4, item_name + "_Light")


func _add_agreement_gate(position: Vector3) -> void:
	for side in [-1.0, 1.0]:
		_add_control_tower(Vector3(position.x + side * 48.0, 0.0, position.z), "AgreementPylon_%s" % ("P" if side < 0.0 else "S"), Color(1.0, 0.62, 0.18, 1.0))
	_add_scene_label(Vector3(position.x, WATER_Y + 25.0, position.z), "SIMULATED AGREEMENT GATE", Color(1.0, 0.64, 0.18, 1.0))


func _add_navigation_buoy(position: Vector3, item_name: String, color: Color) -> void:
	_add_cylinder(self, item_name + "_Float", Vector3(position.x, WATER_Y + 0.65, position.z), 1.15, 1.30, Color(0.12, 0.16, 0.18, 1.0))
	_add_cylinder(self, item_name + "_Post", Vector3(position.x, WATER_Y + 2.4, position.z), 0.32, 3.4, color)
	var lamp := MeshInstance3D.new()
	lamp.name = item_name + "_Lamp"
	var mesh := SphereMesh.new()
	mesh.radius = 0.62
	mesh.height = 1.24
	lamp.mesh = mesh
	lamp.position = Vector3(position.x, WATER_Y + 4.2, position.z)
	lamp.material_override = _material(color, 4.0)
	add_child(lamp)
	_visual_node_count += 1
	_add_point_light(lamp.position, color, 12.0, 1.0, item_name + "_Omni")


func _add_light_post(position: Vector3, item_name: String, color: Color) -> void:
	_add_cylinder(self, item_name + "_Pole", Vector3(position.x, WATER_Y + 7.0, position.z), 0.22, 14.0, Color(0.16, 0.20, 0.22, 1.0))
	_add_box(self, item_name + "_Head", Vector3(position.x, WATER_Y + 14.0, position.z), Vector3(1.2, 0.5, 1.2), color, 3.0)
	_add_point_light(Vector3(position.x, WATER_Y + 13.6, position.z), color, 15.0, 0.8, item_name + "_Light")


func _add_scene_label(position: Vector3, text: String, color: Color) -> void:
	var label := Label3D.new()
	label.name = "TaskLabel_%04d" % _visual_node_count
	label.text = text
	label.position = position
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = false
	label.pixel_size = 0.03
	label.font_size = 28
	label.outline_size = 9
	label.modulate = color
	label.outline_modulate = Color(0.01, 0.03, 0.04, 0.94)
	add_child(label)
	_visual_node_count += 1


func _add_point_light(position: Vector3, color: Color, light_range: float, energy: float, item_name: String) -> void:
	var light := OmniLight3D.new()
	light.name = item_name
	light.position = position
	light.light_color = color
	light.omni_range = light_range
	light.light_energy = energy
	light.shadow_enabled = false
	add_child(light)
	_visual_node_count += 1


func _add_box(
	parent: Node3D,
	item_name: String,
	position: Vector3,
	size: Vector3,
	color: Color,
	emission_energy: float = 0.0,
	transparent: bool = false,
) -> MeshInstance3D:
	var visual := MeshInstance3D.new()
	visual.name = item_name
	var mesh := BoxMesh.new()
	mesh.size = size
	visual.mesh = mesh
	visual.position = position
	visual.material_override = _material(color, emission_energy, transparent)
	parent.add_child(visual)
	_visual_node_count += 1
	return visual


func _add_cylinder(
	parent: Node3D,
	item_name: String,
	position: Vector3,
	radius: float,
	height: float,
	color: Color,
	emission_energy: float = 0.0,
	transparent: bool = false,
) -> MeshInstance3D:
	var visual := MeshInstance3D.new()
	visual.name = item_name
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius * 0.88
	mesh.bottom_radius = radius
	mesh.height = height
	visual.mesh = mesh
	visual.position = position
	visual.material_override = _material(color, emission_energy, transparent)
	parent.add_child(visual)
	_visual_node_count += 1
	return visual


func _material(color: Color, emission_energy: float = 0.0, transparent: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.72
	material.metallic = 0.02
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if transparent or color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if emission_energy > 0.0:
		material.emission_enabled = true
		material.emission = Color(color.r, color.g, color.b, 1.0)
		material.emission_energy_multiplier = emission_energy
	return material

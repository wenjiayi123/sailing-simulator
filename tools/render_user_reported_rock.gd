extends SceneTree

const WATER_LEVEL_Y := -140.73494
const OUTPUT_ORIGINAL := "res://output/user_reported_rock_original.png"
const OUTPUT_LABELLED := "res://output/user_reported_rock_labelled.png"
const OUTPUT_WITHOUT_A := "res://output/user_reported_rock_without_grounded06.png"
const OUTPUT_WITHOUT_B := "res://output/user_reported_rock_without_rock3a12.png"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	change_scene_to_file("res://main.tscn")
	await scene_changed
	for _index in range(20):
		await process_frame
	var main := current_scene
	var controller := main.get_node_or_null("CargoCircuitReplayController")
	if controller == null:
		push_error("render_user_reported_rock: CargoCircuitReplayController missing")
		quit(2)
		return
	controller.call("set_playback_speed", 8.0)
	controller.call("set_replay_camera_mode", "auto_follow")
	if not bool(controller.call("start_dynamic_replay")):
		push_error("render_user_reported_rock: 44D replay did not start")
		quit(3)
		return
	var status := controller.call("get_replay_status") as Dictionary
	while bool(status.get("active", false)) and int(status.get("sample_index", 0)) < 393:
		await physics_frame
		status = controller.call("get_replay_status") as Dictionary
	controller.set_physics_process(false)
	RenderingServer.force_draw(false, 0.0)
	var original := root.get_texture().get_image()
	original.save_png(OUTPUT_ORIGINAL)
	var center_hit := _center_camera_hit(main)
	await _capture_without(
		main,
		"NavigationEnvironment/TerrainUpperWalkableRegions/FloatingPlates/"
		+ "GroundedRockPlate_Comparison_Set/GroundedPlate_06_TwistedButtressMesa",
		OUTPUT_WITHOUT_A
	)
	await _capture_without(
		main,
		"NavigationEnvironment/TerrainUpperWalkableRegions/FloatingPlates/"
		+ "Rock3A_Comparison_Set/Rock3A_12_AsymmetricBrokenWing",
		OUTPUT_WITHOUT_B
	)
	_add_label(
		main,
		"NavigationEnvironment/TerrainUpperWalkableRegions/FloatingPlates/"
		+ "GroundedRockPlate_Comparison_Set/GroundedPlate_06_TwistedButtressMesa",
		"CANDIDATE A\nGroundedPlate_06",
		Color(1.0, 0.18, 0.08, 1.0),
		Vector3(0.0, 78.0, 0.0)
	)
	_add_label(
		main,
		"NavigationEnvironment/TerrainUpperWalkableRegions/FloatingPlates/"
		+ "Rock3A_Comparison_Set/Rock3A_12_AsymmetricBrokenWing",
		"CANDIDATE B\nRock3A_12",
		Color(1.0, 0.85, 0.08, 1.0),
		Vector3(0.0, 34.0, 0.0)
	)
	for _index in range(2):
		await process_frame
	RenderingServer.force_draw(false, 0.0)
	var labelled := root.get_texture().get_image()
	labelled.save_png(OUTPUT_LABELLED)
	print(JSON.stringify({
		"original": ProjectSettings.globalize_path(OUTPUT_ORIGINAL),
		"labelled": ProjectSettings.globalize_path(OUTPUT_LABELLED),
		"without_grounded06": ProjectSettings.globalize_path(OUTPUT_WITHOUT_A),
		"without_rock3a12": ProjectSettings.globalize_path(OUTPUT_WITHOUT_B),
		"strategy": "RES-SAC-D2",
		"observation_dimension": 44,
		"replay_status": controller.call("get_replay_status"),
		"center_camera_hit": center_hit,
	}))
	quit()


func _capture_without(main: Node, path: String, output_path: String) -> void:
	var rock := main.get_node_or_null(path) as Node3D
	if rock == null:
		push_error("render_user_reported_rock: candidate missing: %s" % path)
		return
	rock.visible = false
	await process_frame
	RenderingServer.force_draw(false, 0.0)
	root.get_texture().get_image().save_png(output_path)
	rock.visible = true
	await process_frame


func _add_label(main: Node, path: String, text_value: String, color: Color, offset: Vector3) -> void:
	var rock := main.get_node_or_null(path) as Node3D
	if rock == null:
		push_error("render_user_reported_rock: candidate missing: %s" % path)
		return
	var label := Label3D.new()
	label.text = text_value
	label.font_size = 64
	label.outline_size = 14
	label.modulate = color
	label.no_depth_test = true
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	main.add_child(label)
	label.global_position = rock.global_position + offset


func _center_camera_hit(main: Node) -> Dictionary:
	var camera := main.get_node_or_null("Player/Camera3D") as Camera3D
	var player := main.get_node_or_null("Player") as CollisionObject3D
	if camera == null:
		return {"error": "Camera3D missing"}
	var screen_center := camera.get_viewport().get_visible_rect().size * 0.5
	var origin := camera.project_ray_origin(screen_center)
	var endpoint := origin + camera.project_ray_normal(screen_center) * 1200.0
	var query := PhysicsRayQueryParameters3D.create(origin, endpoint, 2)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.hit_back_faces = true
	query.hit_from_inside = true
	if player != null:
		query.exclude = [player.get_rid()]
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {"hit": false}
	var collider := hit.get("collider") as Object
	return {
		"hit": true,
		"collider": String(collider.name) if collider != null and collider is Node else "unknown",
		"source_large_rock": String(collider.get_meta("source_large_rock", "")) if collider != null else "",
		"position": hit.get("position", Vector3.ZERO),
	}

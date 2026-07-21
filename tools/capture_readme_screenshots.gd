extends SceneTree

const OUTPUT_DIR := "res://docs/images"


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	root.size = Vector2i(1920, 1080)
	var packed := load("res://main.tscn") as PackedScene
	if packed == null:
		push_error("README_CAPTURE_FAIL: main scene unavailable")
		quit(1)
		return
	var world := packed.instantiate()
	root.add_child(world)
	var player := world.get_node_or_null("Player")
	var weather := world.get_node_or_null("ShipWeatherTimeController")
	var hud := world.get_node_or_null("ShipTelemetryHUD")
	if weather != null and weather.has_method("apply_mode"):
		weather.call("apply_mode", 0)
		weather.set_process(false)
	_apply_capture_lighting(world, Color(0.018, 0.075, 0.12, 1.0))
	if player != null:
		player.camera_distance = 14.0
		player.camera_pitch_degrees = 27.0
		player._camera_yaw = -0.32
		player._update_camera_mount()
	for _frame in range(36):
		await process_frame
	await _save_frame("simulator-overview.png")

	var navigation_panel := world.get_node_or_null("ShipNavigationPlanningPanel")
	_apply_capture_lighting(world, Color(0.012, 0.052, 0.09, 1.0))
	if player != null:
		player.camera_distance = 18.0
		player.camera_pitch_degrees = 29.0
		player._camera_yaw = -0.24
		player._update_camera_mount()
	if navigation_panel != null and navigation_panel.has_method("show_panel"):
		navigation_panel.call("show_panel")
	for _frame in range(12):
		await process_frame
	await _save_frame("navigation-planning.png")
	if navigation_panel != null and navigation_panel.has_method("hide_panel"):
		navigation_panel.call("hide_panel")

	var rl_panel := world.get_node_or_null("ShipRLControlPanel")
	_apply_capture_lighting(world, Color(0.012, 0.052, 0.09, 1.0))
	if hud != null:
		hud._hud_root.visible = true
	if player != null:
		player.camera_distance = 18.0
		player.camera_pitch_degrees = 29.0
		player._camera_yaw = -0.24
		player._update_camera_mount()
	if rl_panel != null:
		rl_panel._root.visible = true
		rl_panel._tabs.current_tab = 1
	for _frame in range(12):
		await process_frame
	await _save_frame("rl-training-console.png")

	print("README_CAPTURE_OK: overview, navigation planning, rl console")
	quit(0)


func _apply_capture_lighting(world: Node, background: Color) -> void:
	var world_environment := world.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_environment != null and world_environment.environment != null:
		var environment := world_environment.environment
		environment.background_mode = Environment.BG_COLOR
		environment.background_color = background
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.ambient_light_color = Color(0.52, 0.80, 0.92, 1.0)
		environment.ambient_light_energy = 1.15
		environment.fog_enabled = false
	var sun := world.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun != null:
		sun.light_color = Color(0.88, 0.96, 1.0, 1.0)
		sun.light_energy = 1.65
		sun.rotation_degrees = Vector3(-54.0, -28.0, 0.0)


func _save_frame(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("README_CAPTURE_FAIL: empty image %s" % file_name)
		quit(1)
		return
	var output_path := ProjectSettings.globalize_path("%s/%s" % [OUTPUT_DIR, file_name])
	var error := image.save_png(output_path)
	if error != OK:
		push_error("README_CAPTURE_FAIL: cannot save %s" % output_path)
		quit(1)

extends SceneTree

const OUTPUT_PATH := "/tmp/ship_autonomous_policy_preview.png"


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var packed := load("res://main.tscn") as PackedScene
	if packed == null:
		push_error("Autonomous policy capture could not load main.tscn")
		quit(1)
		return
	var world := packed.instantiate()
	root.add_child(world)
	await process_frame
	await process_frame
	var panel := world.get_node_or_null("ShipRLControlPanel")
	var replay := world.get_node_or_null("ShipPolicyReplayController")
	if panel == null or replay == null:
		push_error("Autonomous policy capture could not resolve policy nodes")
		quit(1)
		return
	panel._on_play_policy_pressed()
	var deadline := Time.get_ticks_msec() + 25000
	while replay.is_replay_active() and Time.get_ticks_msec() < deadline:
		await physics_frame
		if replay._elapsed >= 5.0 and "AVOIDANCE" in replay._policy_phase:
			break
	for index in range(4):
		await process_frame
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("Autonomous policy capture returned an empty viewport image")
		quit(1)
		return
	var error := image.save_png(OUTPUT_PATH)
	if error != OK:
		push_error("Autonomous policy capture failed to save: %s" % error_string(error))
		quit(1)
		return
	print("SHIP_AUTONOMOUS_POLICY_CAPTURE_OK: %s" % OUTPUT_PATH)
	quit(0)

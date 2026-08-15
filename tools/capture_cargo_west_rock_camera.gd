extends SceneTree

const OUTPUT_PATH := "res://reports/cargo_circuit_west_rock_camera_after.png"
const TARGET_POSITION := Vector2(-165.0, 119.0)
const WATER_LEVEL_Y := -140.73494


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var packed := load("res://main.tscn") as PackedScene
	if packed == null:
		push_error("west-rock camera capture could not load main.tscn")
		quit(1)
		return
	var world := packed.instantiate()
	root.add_child(world)
	for _index in range(12):
		await process_frame
	var controller := world.get_node_or_null("CargoCircuitReplayController") as CargoCircuitReplayController
	var ship := world.get_node_or_null("Player")
	if controller == null or ship == null or not controller.start_replay():
		push_error("west-rock camera capture could not start accepted replay")
		quit(1)
		return
	var samples := controller.get("_samples") as Array
	var best_index := 0
	var best_distance := INF
	for index in range(samples.size()):
		var sample := samples[index] as Dictionary
		var distance := TARGET_POSITION.distance_to(Vector2(float(sample.get("x", 0.0)), float(sample.get("z", 0.0))))
		if distance < best_distance:
			best_distance = distance
			best_index = index
	var selected := samples[best_index] as Dictionary
	ship.call(
		"set_ship_navigation_spawn",
		Vector3(float(selected.get("x", 0.0)), WATER_LEVEL_Y, float(selected.get("z", 0.0))),
		float(selected.get("heading_degrees", 0.0))
	)
	ship.call("set_ship_camera_heading_follow_enabled", true, true)
	controller.set("_sample_index", best_index)
	controller.set("_elapsed", float(selected.get("time", 0.0)))
	await physics_frame
	for _index in range(18):
		await process_frame
	var camera_status := ship.call("get_ship_camera_heading_follow_status") as Dictionary
	print("WEST_ROCK_CAMERA_STATUS:%s" % JSON.stringify(camera_status))
	if float(camera_status.get("heading_alignment_error_degrees", INF)) > 5.0:
		push_error("west-rock camera capture is not aligned with the ship heading")
		quit(1)
		return
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("west-rock camera capture returned an empty viewport image")
		quit(1)
		return
	var output := ProjectSettings.globalize_path(OUTPUT_PATH)
	var error := image.save_png(output)
	if error != OK:
		push_error("west-rock camera capture failed: %s" % error_string(error))
		quit(1)
		return
	print("CARGO_WEST_ROCK_CAMERA_CAPTURE_OK:%s:sample=%d:distance=%.2f:error=%.2f" % [
		output,
		best_index,
		best_distance,
		float(camera_status.get("heading_alignment_error_degrees", INF)),
	])
	quit(0)

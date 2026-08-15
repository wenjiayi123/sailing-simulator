extends SceneTree

const OUTPUT_PATH := "res://reports/cargo_circuit_rock_clearance_after.png"
const TARGET_POSITION := Vector2(225.0, 31.0)


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var packed := load("res://main.tscn") as PackedScene
	if packed == null:
		push_error("cargo clearance capture could not load main.tscn")
		quit(1)
		return
	var world := packed.instantiate()
	root.add_child(world)
	for _index in range(12):
		await process_frame
	var controller := world.get_node_or_null("CargoCircuitReplayController") as CargoCircuitReplayController
	if controller == null or not controller.start_replay():
		push_error("cargo clearance capture could not start accepted replay")
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
	var ship := world.get_node_or_null("Player")
	if ship == null or not ship.has_method("set_ship_navigation_spawn"):
		push_error("cargo clearance capture could not position the ship at the reviewed sample")
		quit(1)
		return
	ship.call(
		"set_ship_navigation_spawn",
		Vector3(float(selected.get("x", 0.0)), -140.73494, float(selected.get("z", 0.0))),
		float(selected.get("heading_degrees", 0.0))
	)
	controller.set("_sample_index", best_index)
	controller.set("_elapsed", float(selected.get("time", 0.0)))
	await physics_frame
	for _index in range(8):
		await process_frame
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("cargo clearance capture returned an empty viewport image")
		quit(1)
		return
	var output := ProjectSettings.globalize_path(OUTPUT_PATH)
	var error := image.save_png(output)
	if error != OK:
		push_error("cargo clearance capture failed: %s" % error_string(error))
		quit(1)
		return
	print("CARGO_ROCK_CLEARANCE_CAPTURE_OK:%s:sample=%d:distance=%.2f" % [output, best_index, best_distance])
	quit(0)

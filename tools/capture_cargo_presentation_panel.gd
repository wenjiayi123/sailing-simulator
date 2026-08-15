extends SceneTree

const OUTPUT_PATH := "res://reports/cargo_circuit_presentation_panel.png"


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var packed := load("res://main.tscn") as PackedScene
	if packed == null:
		push_error("cargo presentation panel capture could not load main.tscn")
		quit(1)
		return
	var world := packed.instantiate()
	root.add_child(world)
	for _index in range(16):
		await process_frame
	var controller := world.get_node_or_null("CargoCircuitReplayController") as CargoCircuitReplayController
	var panel := world.get_node_or_null("CargoCircuitRLPanel") as CargoCircuitRLPanel
	if controller == null or panel == null or not controller.start_replay():
		push_error("cargo presentation panel capture could not start accepted replay")
		quit(1)
		return
	panel.show_panel()
	for _index in range(12):
		await process_frame
	var presentation := controller.get_replay_presentation_status()
	if String(presentation.get("camera_mode", "")) != "auto_follow" \
		or String(presentation.get("visual_mode", "")) != "procedural_usv":
		push_error("cargo presentation panel defaults were not applied")
		quit(1)
		return
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("cargo presentation panel capture returned an empty viewport image")
		quit(1)
		return
	var output := ProjectSettings.globalize_path(OUTPUT_PATH)
	var error := image.save_png(output)
	if error != OK:
		push_error("cargo presentation panel capture failed: %s" % error_string(error))
		quit(1)
		return
	print("CARGO_PRESENTATION_PANEL_CAPTURE_OK:%s:%s" % [output, JSON.stringify(presentation)])
	quit(0)

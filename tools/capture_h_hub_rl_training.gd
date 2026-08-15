extends SceneTree

const OUTPUT_PATH := "res://reports/h_hub_rl_training_center.png"


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var packed := load("res://main.tscn") as PackedScene
	if packed == null:
		push_error("H hub RL training capture could not load main.tscn")
		quit(1)
		return
	var world := packed.instantiate()
	root.add_child(world)
	for _index in range(18):
		await process_frame
	var hub := world.get_node_or_null("CargoCircuitRLPanel") as CargoCircuitRLPanel
	var training := world.get_node_or_null("ShipRLControlPanel")
	if hub == null or training == null:
		push_error("H hub or RL training panel is missing")
		quit(1)
		return
	hub.call("_open_hub_module", "ShipRLControlPanel", "show_training_center", "进入 RL 训练中心")
	for _index in range(12):
		await process_frame
	var training_root := training.get("_root") as Control
	var tabs := training.get("_tabs") as TabContainer
	var return_root := hub.get("_hub_return_root") as Control
	if training_root == null or not training_root.visible or tabs == null or tabs.current_tab != 1 \
		or return_root == null or not return_root.visible:
		push_error("H hub did not open the RL training tab with a return path")
		quit(1)
		return
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("H hub RL training capture returned an empty image")
		quit(1)
		return
	var output := ProjectSettings.globalize_path(OUTPUT_PATH)
	var error := image.save_png(output)
	if error != OK:
		push_error("H hub RL training capture failed: %s" % error_string(error))
		quit(1)
		return
	print("H_HUB_RL_TRAINING_CAPTURE_OK:%s" % output)
	quit(0)

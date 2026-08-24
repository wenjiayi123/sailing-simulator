extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://main.tscn") as PackedScene
	_expect(packed != null, "main scene loads")
	if packed == null:
		_finish()
		return
	var world := packed.instantiate()
	root.add_child(world)
	await process_frame
	await process_frame

	var panel := world.get_node_or_null("ShipRLControlPanel")
	var replay := world.get_node_or_null("ShipPolicyReplayController")
	var review := world.get_node_or_null("ShipSimulationReviewPanel")
	_expect(panel != null, "RL panel exists")
	_expect(replay != null, "policy replay controller exists")
	_expect(review != null, "simulation review panel exists")
	if panel == null or replay == null or review == null:
		_finish()
		return

	panel._algorithm_option.select(4) # LOS-PID: deterministic, fast end-to-end pipeline check.
	panel._episode_spin.value = 1
	panel._step_spin.value = 220
	panel._agent_spin.value = 1
	panel._sleep_spin.value = 1
	panel._on_start_training_pressed()
	_expect(panel._training_run_active, "real headless training starts")
	_expect(paused, "world pauses during data-only training")

	var training_deadline := Time.get_ticks_msec() + 30000
	while panel._training_run_active and Time.get_ticks_msec() < training_deadline:
		await process_frame
	_expect(not panel._training_run_active, "headless training completes")
	_expect(not paused, "world recovers after training")
	_expect(FileAccess.file_exists(panel._training_checkpoint_path), "checkpoint is written")
	_expect(not FileAccess.file_exists(panel._training_trajectory_path), "training does not create a test trajectory")

	panel._on_play_policy_pressed()
	_expect(panel._training_run_active, "independent test rollout starts")
	_expect(paused, "world pauses during numeric test rollout")
	var evaluation_deadline := Time.get_ticks_msec() + 30000
	while panel._training_run_active and Time.get_ticks_msec() < evaluation_deadline:
		await process_frame
	_expect(not panel._training_run_active, "test rollout completes")
	_expect(FileAccess.file_exists(panel._training_trajectory_path), "test trajectory is written only after evaluation")

	if not FileAccess.file_exists(panel._training_trajectory_path):
		_finish()
		return
	_expect(replay.is_replay_active(), "recorded test rollout starts rendering")
	var replay_deadline := Time.get_ticks_msec() + 90000
	while replay.is_replay_active() and Time.get_ticks_msec() < replay_deadline:
		await physics_frame
	var status := replay.get_replay_status() as Dictionary
	var result := status.get("last_result", {}) as Dictionary
	_expect(not replay.is_replay_active(), "policy replay finishes")
	_expect(result.has("success"), "replay preserves the measured test outcome")
	_expect(result.has("collision_count"), "replay preserves measured collision count")
	_expect(result.has("minimum_clearance_meters"), "replay preserves measured clearance")
	_expect(FileAccess.file_exists(ProjectSettings.globalize_path(replay.evaluation_result_path)), "evaluation result is written")
	_expect(review._runs_by_strategy.has("rl"), "policy replay is captured by run review")
	var rl_review := review._runs_by_strategy.get("rl", {}) as Dictionary
	_expect(float(rl_review.get("elapsed_seconds", 0.0)) > 0.0, "RL review contains sampled runtime")
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("SHIP_RL_CLOSED_LOOP_OK: train split -> checkpoint -> test split -> recorded render")
		quit(0)
		return
	for failure in failures:
		push_error("SHIP_RL_CLOSED_LOOP_FAIL: %s" % failure)
	quit(1)

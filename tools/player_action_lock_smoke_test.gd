extends SceneTree

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var player := CharacterBody3D.new()
	player.name = "Player"
	var action_lock := PlayerActionLock.new()
	action_lock.name = "ActionLock"
	player.add_child(action_lock)
	var controller := InteractionController3D.new()
	controller.name = "InteractionController"
	var detector := Area3D.new()
	detector.name = "Detector"
	controller.add_child(detector)
	player.add_child(controller)
	root.add_child(player)
	await process_frame

	action_lock.acquire(
		&"dialogue",
		PlayerActionLock.Channel.MOVEMENT | PlayerActionLock.Channel.INTERACTION
	)
	_expect(action_lock.is_locked(PlayerActionLock.Channel.MOVEMENT), "对白锁没有锁住移动")
	_expect(action_lock.is_locked(PlayerActionLock.Channel.INTERACTION), "对白锁没有锁住互动")
	_expect(not action_lock.is_locked(PlayerActionLock.Channel.JUMP), "对白锁误锁了跳跃")
	_expect(controller.is_interaction_locked(), "交互控制器没有读取统一锁")

	action_lock.acquire(&"cutscene", PlayerActionLock.ALL)
	_expect(action_lock.get_active_sources().size() == 2, "叠加锁来源数量错误")
	action_lock.release(&"dialogue")
	_expect(action_lock.has_source(&"cutscene"), "释放对白锁时误删了过场锁")
	_expect(action_lock.is_locked(PlayerActionLock.Channel.INTERACTION), "过场锁仍在时互动被提前解锁")

	action_lock.acquire(&"cutscene", PlayerActionLock.Channel.ATTACK)
	_expect(action_lock.get_active_sources().size() == 1, "同来源重复加锁产生了重复项")
	_expect(action_lock.is_locked(PlayerActionLock.Channel.ATTACK), "同来源更新后攻击锁丢失")
	_expect(not action_lock.is_locked(PlayerActionLock.Channel.MOVEMENT), "同来源更新后保留了旧移动锁")

	var interrupt_capture := {"reason": &""}
	action_lock.interrupt_requested.connect(
		func(reason: StringName): interrupt_capture["reason"] = reason
	)
	action_lock.request_interrupt(&"scene_change")
	_expect(interrupt_capture["reason"] == &"scene_change", "中断请求没有传递原因")

	action_lock.acquire(&"gathering:tree_a", PlayerActionLock.ALL)
	action_lock.acquire(&"gathering:tree_b", PlayerActionLock.ALL)
	action_lock.release_prefix("gathering:")
	_expect(not action_lock.has_source(&"gathering:tree_a"), "前缀释放遗漏第一把采集锁")
	_expect(not action_lock.has_source(&"gathering:tree_b"), "前缀释放遗漏第二把采集锁")
	_expect(action_lock.has_source(&"cutscene"), "前缀释放误删其他系统锁")

	action_lock.release(&"cutscene")
	_expect(not action_lock.is_any_locked(), "所有来源释放后仍处于锁定状态")
	_expect(not controller.is_interaction_locked(), "所有来源释放后互动没有恢复")

	player.queue_free()
	await process_frame
	if failures.is_empty():
		print("PLAYER_ACTION_LOCK_OK: channels, stacking, source release, interrupt, controller")
		quit(0)
		return
	for failure in failures:
		push_error("PLAYER_ACTION_LOCK_FAIL: %s" % failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

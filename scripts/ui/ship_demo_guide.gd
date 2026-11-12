extends CanvasLayer

## Presentation UI only. Business actions use existing panel methods and button
## signals; no model, authority, training result or safety gate is rewritten.
const STEPS_PATH := "res://data/demo/sailing_demo_steps_v1.json"
const SAVE_PATH := "user://ship_demo_guide_v1.cfg"
const CYAN := Color("65f5ff")
const GREEN := Color("76f7c5")
const AMBER := Color("ffc46b")
const RED := Color("ff7b88")
const BACKGROUND := Color("0a1930")

var _steps: Array[Dictionary] = []
var _step_index := 0
var _completed: Dictionary = {}
var _is_open := false
var _collapsed := false
var _busy := false
var _status := "idle"
var _message := "执行当前操作，看到结果后再进入下一步。"
var _trace_id := ""
var _revision := 0
var _custom_position := false
var _position_ratio := Vector2.ZERO
var _dragging := false
var _drag_start := Vector2.ZERO
var _panel_start := Vector2.ZERO
var _root: Control
var _panel: PanelContainer
var _entry: Button
var _collapsed_button: Button
var _header: Label
var _step_picker: OptionButton
var _progress: ProgressBar
var _title: Label
var _narration: Label
var _expected: Label
var _status_label: Label
var _trace_label: Label
var _primary: Button
var _previous: Button
var _more: MenuButton
var _policy_info: Label
var _body_scroll: ScrollContainer
var _policy_monitor: Timer
var _owned_mission_policy := false
var _mission_restore_index := -1
var _mission_restore_flags: Dictionary = {}
var _mission_entry: Dictionary = {}
var _manual_stop: Button
var _compact_stop: Button
var _n_scene_toggle: Button
var _n_scene_grid: GridContainer
var _n_scene_buttons: Array[Button] = []
var _n_scenes_expanded := true
var _manual_stopping := false
var _native_sync_suppressed := false
var _evidence_panel: PanelContainer
var _evidence_picker: OptionButton
var _evidence_text: RichTextLabel
var _evidence_scenes: Array = []
var _action_watchdog: Timer


func _ready() -> void:
	layer = 250
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"ship_demo_guide")
	_load_steps()
	if _steps.is_empty():
		push_error("演示引导步骤文件不可用：" + STEPS_PATH)
		return
	_restore_progress()
	_build_interface()
	_policy_monitor = Timer.new()
	_policy_monitor.wait_time = 0.35
	_policy_monitor.timeout.connect(_update_policy_info)
	add_child(_policy_monitor)
	_action_watchdog = Timer.new()
	_action_watchdog.one_shot = true
	_action_watchdog.wait_time = 15.0
	_action_watchdog.timeout.connect(_on_action_timeout)
	add_child(_action_watchdog)
	_refresh()
	get_viewport().size_changed.connect(_relayout)
	get_tree().node_added.connect(_on_node_added)
	call_deferred("_bind_existing_buttons")
	call_deferred("_build_n_scene_shortcuts")
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.physical_keycode == KEY_F8:
			if _is_open:
				_close_guide()
			else:
				_open_guide()
			get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not _steps.is_empty():
		_save_progress()


func _load_steps() -> void:
	if not FileAccess.file_exists(STEPS_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(STEPS_PATH))
	if not parsed is Dictionary:
		return
	var data := parsed as Dictionary
	if String(data.get("schema", "")) != "sailing_demo_steps_v1":
		return
	var records: Variant = data.get("steps", [])
	if not records is Array:
		return
	for record in records:
		if record is Dictionary and not String(record.get("id", "")).is_empty():
			_steps.append(record as Dictionary)


func _build_interface() -> void:
	_root = Control.new()
	_root.name = "SailingDemoGuideRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_entry = _button("▶ 演示开始", _open_guide)
	_entry.name = "DemoGuideStart"
	_entry.custom_minimum_size = Vector2(148, 44)
	_root.add_child(_entry)
	_collapsed_button = _button("演示引导", _toggle_collapsed)
	_collapsed_button.name = "DemoGuideExpand"
	_collapsed_button.custom_minimum_size = Vector2(56, 148)
	_root.add_child(_collapsed_button)
	_compact_stop = _button("■ 手动停止策略 / 回放", _on_manual_stop)
	_compact_stop.name = "DemoGuideCompactStop"
	_compact_stop.add_theme_stylebox_override("normal", _style(Color("632133"), RED, 10))
	_root.add_child(_compact_stop)

	_panel = PanelContainer.new()
	_panel.name = "DemoGuidePanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var panel_style := _style(BACKGROUND, Color("356b80"), 18)
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		panel_style.set_content_margin(side, 14.0)
	_panel.add_theme_stylebox_override("panel", panel_style)
	_root.add_child(_panel)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 9)
	_panel.add_child(stack)

	var header_row := HBoxContainer.new()
	stack.add_child(header_row)
	_header = _label("航行模拟器 · 演示引导", 17, CYAN)
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header.mouse_filter = Control.MOUSE_FILTER_STOP
	_header.mouse_default_cursor_shape = Control.CURSOR_DRAG
	_header.tooltip_text = "拖动标题可移动演示栏；F8 显示 / 隐藏"
	_header.gui_input.connect(_on_header_input)
	header_row.add_child(_header)
	var collapse := _button("›", _toggle_collapsed)
	collapse.tooltip_text = "折叠，留出完整场景"
	header_row.add_child(collapse)
	var close := _button("×", _close_guide)
	close.tooltip_text = "关闭引导，保留进度"
	header_row.add_child(close)

	_progress = ProgressBar.new()
	_progress.custom_minimum_size.y = 5
	_progress.show_percentage = false
	_progress.add_theme_stylebox_override("background", _style(Color("122a4a"), Color.TRANSPARENT, 3))
	_progress.add_theme_stylebox_override("fill", _style(CYAN, CYAN, 3))
	stack.add_child(_progress)
	_step_picker = OptionButton.new()
	_step_picker.name = "DemoGuideStepPicker"
	_step_picker.fit_to_longest_item = false
	_step_picker.clip_text = true
	_step_picker.add_theme_font_size_override("font_size", 14)
	_step_picker.custom_minimum_size.y = 34
	_step_picker.item_selected.connect(func(index: int) -> void: _jump_to_step(index, true))
	for index in range(_steps.size()):
		_step_picker.add_item("%02d · %s" % [index + 1, String(_steps[index]["title"])])
	stack.add_child(_step_picker)
	_title = _label("", 19, Color.WHITE)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_title)
	_n_scene_toggle = _button("▾ N 场景 · 点击直接切换演示", _toggle_n_scenes)
	_n_scene_toggle.add_theme_font_size_override("font_size", 13)
	stack.add_child(_n_scene_toggle)
	_n_scene_grid = GridContainer.new()
	_n_scene_grid.columns = 2
	_n_scene_grid.add_theme_constant_override("h_separation", 5)
	_n_scene_grid.add_theme_constant_override("v_separation", 5)

	var scroll := ScrollContainer.new()
	_body_scroll = scroll
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	scroll.add_child(body)
	body.add_child(_n_scene_grid)
	body.add_child(_label("演说台词", 13, Color("8ebbff")))
	_narration = _wrapped_label(16, Color("d9e7f9"))
	body.add_child(_narration)
	body.add_child(_label("可见变化", 13, GREEN))
	_expected = _wrapped_label(14, GREEN)
	body.add_child(_expected)
	body.add_child(_label("操作状态", 13, CYAN))
	_status_label = _wrapped_label(13, Color("9dc8f8"))
	body.add_child(_status_label)
	_policy_info = _wrapped_label(13, GREEN)
	_policy_info.name = "DemoPolicyRuntimeStatus"
	_policy_info.visible = false
	body.add_child(_policy_info)
	body.move_child(_policy_info, 1)
	body.add_child(_wrapped_text("范围：仿真 / 历史证据；无实船生产控制权。", 12, AMBER))

	_trace_label = _label("", 10, Color("7894bd"))
	_trace_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	stack.add_child(_trace_label)
	# Independent of the primary action: cancellation must remain reachable
	# while the guide is waiting for a native actor or a presentation result.
	_manual_stop = _button("■ 手动停止策略 / 回放", _on_manual_stop)
	_manual_stop.name = "DemoGuideManualStop"
	_manual_stop.custom_minimum_size.y = 38
	_manual_stop.add_theme_font_size_override("font_size", 14)
	_manual_stop.add_theme_stylebox_override("normal", _style(Color("632133"), RED, 10))
	_manual_stop.add_theme_stylebox_override("hover", _style(Color("8a2941"), RED, 10))
	_manual_stop.tooltip_text = "取消尚未完成的策略启动，停止当前仿真策略与回放；当前场景保留。"
	stack.add_child(_manual_stop)
	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 6)
	stack.add_child(controls)
	_previous = _button("‹", _previous_step)
	_previous.tooltip_text = "上一步"
	controls.add_child(_previous)
	_primary = _button("执行当前操作", _on_primary_pressed)
	_primary.name = "DemoGuidePrimary"
	_primary.clip_text = true
	_primary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_primary.custom_minimum_size.y = 44
	_primary.add_theme_font_size_override("font_size", 14)
	controls.add_child(_primary)
	_more = MenuButton.new()
	_more.text = "···"
	_more.tooltip_text = "更多演示控制"
	_more.focus_mode = Control.FOCUS_NONE
	_more.add_theme_font_size_override("font_size", 18)
	var menu := _more.get_popup()
	menu.add_item("重试本步", 0)
	menu.add_item("重置本步", 1)
	menu.add_item("重新开始", 2)
	menu.add_separator()
	menu.add_item("保底跳过本步", 3)
	menu.add_item("恢复右上角位置", 4)
	menu.id_pressed.connect(_on_menu_selected)
	controls.add_child(_more)
	_relayout()


func _relayout() -> void:
	if _panel == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	_layout_evidence()
	var panel_width := minf(366.0, maxf(200.0, viewport_size.x - 28.0))
	var panel_height := minf(clampf(viewport_size.y * 0.54, 350.0, 620.0), maxf(viewport_size.y - 100.0, 180.0))
	_panel.size = Vector2(panel_width, panel_height)
	var default_position := Vector2(viewport_size.x - panel_width - 22.0, 82.0)
	_panel.position = _clamp_position(_position_ratio * viewport_size if _custom_position else default_position)
	_entry.size = Vector2(148, 44)
	_entry.position = Vector2(maxf(12.0, viewport_size.x - 170.0), 82.0)
	_collapsed_button.size = Vector2(56, 148)
	_collapsed_button.position = Vector2(maxf(12.0, viewport_size.x - 78.0), clampf(_panel.position.y, 12.0, maxf(12.0, viewport_size.y - 160.0)))
	_compact_stop.size = Vector2(214, 40)
	_compact_stop.position = Vector2(maxf(8.0, viewport_size.x - 236.0), clampf(_collapsed_button.position.y + 154.0, 12.0, maxf(12.0, viewport_size.y - 52.0)))


func _clamp_position(point: Vector2) -> Vector2:
	var viewport_size := get_viewport().get_visible_rect().size
	return Vector2(
		clampf(point.x, 8.0, maxf(8.0, viewport_size.x - _panel.size.x - 8.0)),
		clampf(point.y, 8.0, maxf(8.0, viewport_size.y - _panel.size.y - 8.0))
	)


func _on_header_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var click := event as InputEventMouseButton
		if click.button_index == MOUSE_BUTTON_LEFT:
			_dragging = click.pressed
			if _dragging:
				_drag_start = _root.get_global_mouse_position()
				_panel_start = _panel.position
			else:
				_save_progress()
			_header.accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_panel.position = _clamp_position(_panel_start + _root.get_global_mouse_position() - _drag_start)
		_custom_position = true
		_position_ratio = _panel.position / get_viewport().get_visible_rect().size
		_header.accept_event()


func _refresh() -> void:
	if _panel == null:
		return
	var step := _steps[_step_index]
	_panel.visible = _is_open and not _collapsed
	_entry.visible = not _is_open
	_collapsed_button.visible = _is_open and _collapsed
	_compact_stop.visible = not (_is_open and not _collapsed)
	_collapsed_button.text = "%d/%d\n演示\n引导\n‹" % [_step_index + 1, _steps.size()]
	_header.text = "演示 %d/%d · 可拖动" % [_step_index + 1, _steps.size()]
	_step_picker.selected = _step_index
	_step_picker.disabled = _busy
	_title.text = "%s · %s" % [String(step["section"]), String(step["title"])]
	_narration.text = String(step["narration"])
	_expected.text = String(step["expected_change"])
	_status_label.text = _message
	_status_label.add_theme_color_override("font_color", RED if _status == "failed" else GREEN if _status == "ready" else AMBER if _status == "skipped" else CYAN)
	_trace_label.text = "Trace ID  " + (_trace_id if not _trace_id.is_empty() else "开始后生成")
	_previous.disabled = _busy or _step_index == 0
	_primary.disabled = _busy
	_manual_stop.disabled = false
	if _busy:
		_primary.text = "正在执行真实操作…"
	elif _status == "ready" or _status == "skipped":
		if _step_index == _steps.size() - 1:
			_primary.text = "演示完成 · 可重新开始"
		elif _owned_mission_policy:
			_primary.text = "恢复场景 · 下一步" if String(step.get("kind", "")) == "mission_unavailable" else "停止策略 · 下一步"
		else:
			_primary.text = "下一步并演示"
	else:
		_primary.text = String(step["action_label"])
	_n_scene_grid.visible = _n_scenes_expanded
	_n_scene_toggle.text = ("▾" if _n_scenes_expanded else "▸") + " N 场景 · 点击直接切换演示"
	_progress.value = float(_completed.size()) / float(_steps.size()) * 100.0
	for index in range(_steps.size()):
		var id := String(_steps[index]["id"])
		var marker := "✓ " if _completed.get(id, "") == "ready" else "↷ " if _completed.get(id, "") == "skipped" else ""
		_step_picker.set_item_text(index, "%s%02d · %s" % [marker, index + 1, String(_steps[index]["title"])])
	for index in [0, 1, 2]:
		_more.get_popup().set_item_disabled(index, _busy)


func _open_guide() -> void:
	_is_open = true
	_collapsed = false
	if _trace_id.is_empty():
		_trace_id = _new_trace_id()
	_refresh()
	_save_progress()


func _close_guide() -> void:
	_is_open = false
	_refresh()
	_save_progress()


func _toggle_collapsed() -> void:
	_collapsed = not _collapsed
	_refresh()
	_save_progress()


func _toggle_n_scenes() -> void:
	_n_scenes_expanded = not _n_scenes_expanded
	_refresh()
	_save_progress()


func _build_n_scene_shortcuts() -> void:
	var navigation := get_parent().get_node_or_null("ShipNavigationPlanningPanel")
	if navigation == null:
		return
	var presets: Variant = _property(navigation, "_mission_presets")
	if not presets is Array:
		return
	var catalog: Dictionary = {}
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/rl/mission_rl_catalog_v1.json"))
	if raw is Dictionary:
		catalog = (raw as Dictionary).get("scenarios", {}) as Dictionary
	for value in presets:
		var preset := value as Dictionary
		var key := String(preset.get("scenario_key", ""))
		var step_id := ""
		for step in _steps:
			if String(step.get("scenario_key", "")) == key and String(step.get("kind", "")) in ["mission_policy", "mission_unavailable"]:
				step_id = String(step["id"])
				break
		if step_id.is_empty():
			continue
		var button := _button(String(preset.get("name", key)), _on_n_scene_pressed.bind(step_id))
		button.name = "NScene_" + key
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.clip_text = true
		button.add_theme_font_size_override("font_size", 12)
		var entry := catalog.get(key, {}) as Dictionary
		var admitted := bool(entry.get("live_switch_admitted", false))
		button.add_theme_stylebox_override("normal", _style(Color("123b35") if admitted else Color("49351e"), GREEN if admitted else AMBER, 9))
		button.tooltip_text = "与 N 面板相同的场景：%s。点击应用场景、切换周围环境，并通过原生入口演示已登记策略。" % button.text if admitted else "应用 N 面板同名场景并展示未准入提示，不运行未通过验收的候选。"
		_n_scene_grid.add_child(button)
		_n_scene_buttons.append(button)


func _on_n_scene_pressed(step_id: String) -> void:
	var index := -1
	for candidate in range(_steps.size()):
		if String(_steps[candidate]["id"]) == step_id:
			index = candidate
			break
	if index < 0:
		return
	# Scene shortcuts remain clickable while another start is pending. Cancel
	# that pending native request before applying the newly requested scene.
	_on_manual_stop()
	if _status == "failed":
		return
	_jump_to_step(index)
	if not _busy and _step_index == index and _status == "idle":
		_run_current_step()


func _on_manual_stop() -> void:
	_revision += 1
	_action_watchdog.stop()
	_manual_stopping = true
	_busy = false
	var errors: Array[String] = []
	var error := _stop_mission_native()
	if not error.is_empty():
		errors.append(error)
	for name in ["CargoCircuitReplayController", "ShipPolicyReplayController"]:
		var replay := get_parent().get_node_or_null(NodePath(name))
		if replay == null or not replay.has_method("is_replay_active") or not bool(replay.call("is_replay_active")):
			continue
		if replay.has_method("stop_replay"):
			replay.call("stop_replay")
		if bool(replay.call("is_replay_active")):
			errors.append(name + " 尚未停止。")
	_manual_stopping = false
	_status = "stopped" if errors.is_empty() else "failed"
	_message = "已取消等待并停止策略 / 回放。N 任务场景保留，回放按原生逻辑恢复；可点击另一个 N 场景按钮或重新演示本步。" if errors.is_empty() else "\n".join(errors)
	_update_policy_info()
	_refresh()
	_save_progress()


func _on_action_timeout() -> void:
	if not _busy:
		return
	_on_manual_stop()
	_status = "failed"
	_message = "等待原生操作结果超时，已取消尚未完成的启动并请求停止。可重新点击 N 场景按钮；原生失败提示仍保留在 N 面板。"
	_refresh()
	_save_progress()


func _on_primary_pressed() -> void:
	if _busy:
		return
	if _status == "ready" or _status == "skipped":
		if _step_index == _steps.size() - 1:
			_restart()
			if _step_index == 0 and _status == "idle":
				_run_current_step()
		else:
			_jump_to_step(_step_index + 1, true)
	else:
		_run_current_step()


func _previous_step() -> void:
	_jump_to_step(_step_index - 1, true)


func _jump_to_step(index: int, execute: bool = false) -> void:
	if _busy or index < 0 or index >= _steps.size():
		return
	var cleanup_error := _restore_mission_scene()
	if not cleanup_error.is_empty():
		_status = "failed"
		_message = cleanup_error
		_refresh()
		return
	_policy_monitor.stop()
	_action_watchdog.stop()
	_policy_info.visible = false
	_revision += 1
	_step_index = index
	_body_scroll.scroll_vertical = 0
	_status = "idle"
	_message = "本步已就绪。"
	_refresh()
	_save_progress()
	if execute:
		_run_current_step()


func _on_menu_selected(id: int) -> void:
	match id:
		0, 1:
			if _busy:
				return
			var cleanup_error := _restore_mission_scene()
			if not cleanup_error.is_empty():
				_status = "failed"
				_message = cleanup_error
				_refresh()
				return
			_policy_monitor.stop()
			_policy_info.visible = false
			_revision += 1
			_status = "idle"
			_completed.erase(String(_steps[_step_index]["id"]))
			_message = "已重置本步引导状态；真实场景、训练与报告保持原有状态。"
		2:
			if not _busy:
				_restart()
			return
		3:
			_revision += 1
			var cleanup_error := _restore_mission_scene()
			if not cleanup_error.is_empty():
				_busy = false
				_status = "failed"
				_message = cleanup_error
				_refresh()
				return
			_busy = false
			_policy_monitor.stop()
			_policy_info.visible = false
			_status = "skipped"
			_completed[String(_steps[_step_index]["id"])] = "skipped"
			_message = "本步已明确跳过，未声明功能执行成功。可继续下一步。"
		4:
			_custom_position = false
			_relayout()
	_refresh()
	_save_progress()


func _restart() -> void:
	var cleanup_error := _restore_mission_scene()
	if not cleanup_error.is_empty():
		_status = "failed"
		_message = cleanup_error
		_refresh()
		return
	_policy_monitor.stop()
	_policy_info.visible = false
	_revision += 1
	_step_index = 0
	_completed.clear()
	_status = "idle"
	_busy = false
	_is_open = true
	_collapsed = false
	_trace_id = _new_trace_id()
	_message = "新的演示会话已就绪；不会清空真实训练或复盘报告。"
	_refresh()
	_save_progress()


func _run_current_step() -> void:
	_busy = true
	_action_watchdog.start()
	_status = "running"
	_message = "正在调用原生页面操作…"
	_revision += 1
	var token := _revision
	var step := _steps[_step_index]
	_refresh()
	_save_progress()
	var error := ""
	if String(step.get("kind", "")) in ["mission_policy", "mission_unavailable"]:
		error = await _perform_mission_policy(step, token)
	else:
		error = _perform_action(step)
	if error.is_empty():
		await get_tree().process_frame
		await get_tree().process_frame
		if token != _revision:
			return
		error = _observe_result(step)
	if token == _revision:
		_finish_action(step, error)


func _perform_action(step: Dictionary) -> String:
	if String(step.get("kind", "")) == "evidence":
		return _show_trained_evidence()
	if _evidence_panel != null:
		_evidence_panel.hide()
	var kind := String(step.get("kind", "panel"))
	if kind == "scene":
		_hide_other_panels(null)
		return ""
	var target := _target(step)
	if target == null:
		return "找不到原生模块：" + String(step.get("node", ""))
	var method := String(step.get("show_method", "show_panel"))
	if not target.has_method(method):
		return "模块缺少展示入口：" + method
	_hide_other_panels(target)
	target.call(method)
	if kind == "panel":
		return ""
	if kind == "play":
		var selector := _property(target, "_strategy_option") as OptionButton
		if selector == null:
			return "策略选择入口不可用。"
		var strategy_index := selector.get_item_index(int(step.get("strategy_id", 0)))
		if strategy_index < 0:
			return "当前演示指定的已发布策略未登记，未切换到其他策略。"
		if selector.is_item_disabled(strategy_index):
			return "指定策略被原生入口禁用，未使用其他策略替代。"
		selector.select(strategy_index)
		selector.item_selected.emit(strategy_index)
	if kind == "mission":
		if _replay_active():
			return "策略回放仍在运行，请先执行“停止并恢复原场景”。"
		var options := _property(target, "_mission_option") as OptionButton
		if options == null:
			return "任务选择入口不可用。"
		var selected := -1
		for index in range(options.item_count):
			if options.get_item_text(index).contains(String(step["mission_name"])):
				selected = index
				break
		if selected < 0:
			return "任务预设未登记：" + String(step["mission_name"])
		options.select(selected)
		options.item_selected.emit(selected)
	var button := _native_button(step, target)
	if button == null:
		return "原生按钮尚未就绪，可重试或保底跳过。"
	if button.disabled:
		return "原生按钮被业务门槛禁用，演示栏不会绕过。"
	button.pressed.emit()
	return ""


func _observe_result(step: Dictionary) -> String:
	if String(step.get("kind", "")) == "evidence":
		return "" if _evidence_panel != null and _evidence_panel.visible and not _evidence_scenes.is_empty() else "训练场景清单未显示。"
	var kind := String(step.get("kind", "panel"))
	if kind == "scene":
		return ""
	var target := _target(step)
	if target == null:
		return "模块已离开场景。"
	if kind == "play":
		if not _replay_active():
			return _native_status(target, "原生回放未启动，可能缺少通过门槛的测试轨迹。")
		return ""
	if kind == "stop":
		return "回放尚未停止，请重试原生停止入口。" if _replay_active() else ""
	if kind == "mission_policy":
		var controller := _mission_controller()
		if controller == null:
			return "场景强化学习控制器不可用。"
		if String(controller.get("key")) != String(step["scenario_key"]):
			return "当前执行的 actor 与演示场景不一致。"
		if not bool(controller.get("active")) or int(controller.get("inference_count")) < 1:
			return String(controller.get("status"))
		return ""
	if kind == "mission_unavailable":
		var controller := _mission_controller()
		if controller == null:
			return "场景强化学习控制器不可用。"
		var entry: Dictionary = controller.call("current_strategy")
		var button := _property(target, "_mission_rl_button") as Button
		if bool(entry.get("live_switch_admitted", false)):
			return "准入状态已变化，请更新本步骤说明后再展示。"
		return "" if button != null and button.disabled and not bool(controller.get("active")) else "未准入场景的原生禁用状态尚未出现。"
	if kind == "mission":
		var name := String(_property(target, "_active_mission_name"))
		return "任务尚未应用，请核对原生任务状态。" if not name.contains(String(step["mission_name"])) else ""
	var root := _property(target, String(step.get("result_property", "_root"))) as Control
	return "目标面板未显示，请重试或检查模块状态。" if root == null or not root.is_visible_in_tree() else ""


func _finish_action(step: Dictionary, error: String) -> void:
	_action_watchdog.stop()
	_busy = false
	if error.is_empty():
		_status = "ready"
		_completed[String(step["id"])] = "ready"
		_message = "原生页面结果已出现。完成当前讲解后，再进入下一步。"
		if String(step.get("kind", "")) == "play":
			var replay := get_parent().get_node_or_null("CargoCircuitReplayController")
			if replay != null and replay.has_method("get_replay_status"):
				var result: Dictionary = replay.call("get_replay_status")
				_message = "回放已启动：%s · %s split · %d 个样本。请在场景中观察航迹。" % [String(result.get("algorithm", "--")), String(result.get("dataset_split", "--")), int(result.get("sample_count", 0))]
		if String(step.get("kind", "")) == "mission_policy":
			_message = "N 面板的场景、周围环境和对应 SAC 已切换。绿色原生按钮显示接管状态；可直接点击栏内其他 N 场景，或使用独立手动停止。"
		if String(step.get("kind", "")) == "mission_unavailable":
			_message = "已展示原生准入边界；该场景未被标记为策略运行成功。"
		if String(step.get("kind", "")) in ["mission_policy", "mission_unavailable", "play"]:
			_update_policy_info()
			_body_scroll.scroll_vertical = 0
			_policy_monitor.start()
	else:
		_status = "failed"
		_message = error + " 可重试、重置本步或保底跳过。"
		if String(step.get("kind", "")) in ["mission_policy", "mission_unavailable"]:
			var cleanup_error := _restore_mission_scene()
			if not cleanup_error.is_empty():
				_message += "\n" + cleanup_error
	_refresh()
	_save_progress()


func _mission_controller() -> Node:
	return get_tree().get_first_node_in_group(&"mission_rl_controller")


func _mission_index(target: Node, scenario_key: String) -> int:
	var presets: Variant = _property(target, "_mission_presets")
	if not presets is Array:
		return -1
	for index in range(presets.size()):
		var preset := presets[index] as Dictionary
		if String(preset.get("scenario_key", "")) == scenario_key:
			return index
	return -1


func _stop_mission_native() -> String:
	var controller := _mission_controller()
	if controller == null:
		return "无法停止场景策略：控制器不可用。"
	var target := get_parent().get_node_or_null("ShipNavigationPlanningPanel")
	if target == null or not target.has_method("show_panel"):
		return "无法停止场景策略：原生任务面板不可用。"
	if target.has_method("_cancel_mission_rl_request"):
		target.call("_cancel_mission_rl_request")
	# A completed actor leaves auto_switch enabled in the native controller.
	# Disable only that presentation lifecycle flag before applying another scene.
	controller.set("auto_switch", false)
	if not bool(controller.get("active")):
		return ""
	target.call("show_panel")
	var button := _property(target, "_mission_rl_button") as Button
	if button == null or button.disabled:
		# Stopping remains available even if the combined native start/stop
		# control is temporarily disabled during presentation updates.
		if not controller.has_method("stop"):
			return "场景策略停止入口不可用。"
		controller.call("stop", "已手动停止场景强化学习")
	else:
		_native_sync_suppressed = true
		button.pressed.emit()
		_native_sync_suppressed = false
	return "原生场景策略尚未停止，请先手动停止。" if bool(controller.get("active")) else ""


func _apply_mission_selection(target: Node, index: int) -> String:
	var options := _property(target, "_mission_option") as OptionButton
	var linked := _property(target, "_sync_scenario_check") as CheckBox
	var teleport := _property(target, "_teleport_check") as CheckBox
	var apply := _find_button(target, "应用任务")
	if options == null or linked == null or teleport == null or apply == null:
		return "原生任务选择、场景联动或重定位入口不可用。"
	if index < 0 or index >= options.item_count or apply.disabled:
		return "任务不存在或原生应用入口已禁用。"
	linked.set_pressed_no_signal(true)
	teleport.set_pressed_no_signal(true)
	options.select(index)
	_native_sync_suppressed = true
	options.item_selected.emit(index)
	apply.pressed.emit()
	_native_sync_suppressed = false
	return ""


func _perform_mission_policy(step: Dictionary, token: int) -> String:
	var error := _restore_mission_scene()
	if not error.is_empty():
		return error
	var target := _target(step)
	var controller := _mission_controller()
	var scenarios := get_tree().get_first_node_in_group(&"ship_scenario_system")
	if target == null or controller == null or scenarios == null:
		return "任务面板、场景或强化学习模块未就绪。"
	var selection := _mission_index(target, String(step["scenario_key"]))
	if selection < 0:
		return "当前任务目录中找不到匹配的场景。"
	# Stop previous playback through its original stop button before handing
	# the same vessel to the scene-specific neural policy.
	if _replay_active():
		var cargo := get_parent().get_node_or_null("CargoCircuitRLPanel")
		var stop: Button = null
		if cargo != null:
			stop = _property(cargo, "_stop_button") as Button
		if stop == null or stop.disabled:
			return "请先停止货运回放，再展示场景策略。"
		stop.pressed.emit()
		if _replay_active():
			return "货运回放尚未停止。"
	error = _stop_mission_native()
	if not error.is_empty():
		return error
	var current: Dictionary = scenarios.call("get_scenario_status")
	_mission_restore_index = _mission_index(target, String(current.get("key", "")))
	if _mission_restore_index < 0:
		return "当前场景不在任务目录中，无法保证演示后的场景恢复。"
	var linked := _property(target, "_sync_scenario_check") as CheckBox
	var teleport := _property(target, "_teleport_check") as CheckBox
	if linked == null or teleport == null:
		return "原生场景联动与重定位选项不可用。"
	_mission_restore_flags = {"linked": linked.button_pressed, "teleport": teleport.button_pressed}
	_owned_mission_policy = true
	_hide_other_panels(target)
	target.call("show_panel")
	error = _apply_mission_selection(target, selection)
	if not error.is_empty():
		return error
	await get_tree().process_frame
	await get_tree().process_frame
	if token != _revision:
		return "场景策略演示已取消。"
	current = scenarios.call("get_scenario_status")
	if String(current.get("key", "")) != String(step["scenario_key"]):
		return "原生任务未切换到指定场景。"
	var scene_error := String(current.get("dedicated_scene_error", ""))
	if not scene_error.is_empty():
		return "N 场景环境加载失败：" + scene_error
	if bool(step.get("dedicated_environment", false)) and not bool(current.get("dedicated_scene_active", false)):
		return "N 面板的专用场景环境尚未加载，未标记为场景演示成功。"
	_mission_entry = controller.call("current_strategy")
	var button := _property(target, "_mission_rl_button") as Button
	if String(step["kind"]) == "mission_unavailable":
		return ""
	if not bool(_mission_entry.get("live_switch_admitted", false)):
		return String(_mission_entry.get("status_zh", "该场景已训练候选尚未通过接管准入。"))
	if String(step["scenario_key"]) == "narrow_channel_overtaking":
		# This demo preset explicitly assumes simulated bridge communication.
		# Use the native agreement receipt; it conveys no real VHF authority.
		var agreement := _property(target, "_overtaking_agreement_check") as CheckBox
		if agreement == null:
			return "模拟追越协议入口不可用。"
		agreement.set_pressed(true)
	if button == null or button.disabled:
		return "原生策略入口未启用，请核对任务应用状态和原生准入提示。"
	_message = "正在通过原生入口核对已训练 actor、场景合同与来源指纹…"
	_refresh()
	button.pressed.emit()
	error = await _await_mission_start(step, token)
	if not error.is_empty():
		return error
	# Leave N visible: the scenario selector and its native green status are
	# part of the requested demonstration, alongside the changed 3D environment.
	_hide_other_panels(target)
	target.call("show_panel")
	return ""


func _await_mission_start(step: Dictionary, token: int) -> String:
	var deadline := Time.get_ticks_msec() + 8000
	while token == _revision and Time.get_ticks_msec() < deadline:
		var controller := _mission_controller()
		var target := _target(step)
		if controller == null or target == null:
			return "场景策略模块已退出。"
		if bool(controller.get("active")):
			if String(controller.get("key")) != String(step["scenario_key"]):
				return "启动的 actor 不属于当前演示场景。"
			if int(controller.get("inference_count")) > 0:
				return ""
		elif not bool(_property(target, "_mission_rl_pending")):
			return "原生入口未开始接管：" + String(controller.get("status"))
		await get_tree().create_timer(0.05, true).timeout
	return "原生策略尚未出现首个推理动作，或本步已取消；不会标记为启动成功。"


func _restore_mission_scene() -> String:
	if not _owned_mission_policy:
		return ""
	var error := _stop_mission_native()
	if not error.is_empty():
		return error
	var target := get_parent().get_node_or_null("ShipNavigationPlanningPanel")
	if target == null:
		return "无法恢复场景：任务面板不可用。"
	if _mission_restore_index >= 0:
		error = _apply_mission_selection(target, _mission_restore_index)
		if not error.is_empty():
			return "策略已停止，但场景恢复失败：" + error
	var linked := _property(target, "_sync_scenario_check") as CheckBox
	var teleport := _property(target, "_teleport_check") as CheckBox
	if linked != null:
		linked.set_pressed_no_signal(bool(_mission_restore_flags.get("linked", true)))
	if teleport != null:
		teleport.set_pressed_no_signal(bool(_mission_restore_flags.get("teleport", true)))
	_owned_mission_policy = false
	_mission_restore_index = -1
	_mission_restore_flags.clear()
	_mission_entry.clear()
	_hide_other_panels(null)
	return ""


func _update_policy_info() -> void:
	if _policy_info == null or _steps.is_empty():
		return
	var step := _steps[_step_index]
	var kind := String(step.get("kind", ""))
	var text := ""
	var color := GREEN
	if kind in ["mission_policy", "mission_unavailable"]:
		var controller := _mission_controller()
		if controller == null:
			text = "原生场景策略模块不可用。"
			color = RED
		else:
			var route: Array = controller.get("route")
			var action: Vector2 = controller.get("last_action")
			var entry := _mission_entry
			if entry.is_empty():
				entry = controller.call("current_strategy")
			text = "N 场景：%s\n环境：%s\n策略：%s\n已登记训练步数：%d（历史训练记录）\n本次：%.1f 秒 · 航点 %d/%d · 推理 %d 次\n归一化动作：油门 %.2f / 舵角 %.2f\n原生状态：%s" % [
				String(step.get("mission_name", "")), String(step.get("environment_note", "以 N 场景配置为准")), String(entry.get("strategy_id", "未准入")), int(entry.get("timesteps", 0)),
				float(controller.get("elapsed")), mini(int(controller.get("waypoint")) + 1, route.size()), route.size(), int(controller.get("inference_count")),
				action.x, action.y, String(controller.get("status"))]
			if String(step.get("scenario_key", "")) == "narrow_channel_head_on":
				var advanced := get_tree().get_first_node_in_group(&"ship_advanced_mission_controller")
				if advanced != null:
					var snapshot := advanced.call("get_advanced_mission_snapshot") as Dictionary
					var behavior := snapshot.get("behavioral_assessment", {}) as Dictionary
					var traffic := snapshot.get("traffic", []) as Array
					var phase := "识别对遇 · 监测 CPA"
					if not traffic.is_empty() and float(traffic[0].get("own_along_traffic_track_m", 0)) < 0:
						phase = "已驶过对向船 · 恢复航线"
					elif String(behavior.get("first_substantial_action_side", "")) == "STARBOARD":
						phase = "已向右转向 · 保持右侧航道"
					text += "\n会遇阶段：%s\n预测最近会遇距离 %.1f 米 / 时间 %.1f 秒\n本次最小船间距 %.1f 米" % [phase, float(snapshot.get("nearest_dcpa_m", 0)), float(snapshot.get("nearest_tcpa_s", 0)), float(snapshot.get("minimum_observed_separation_m", 0))]
			if kind == "mission_unavailable":
				text = "候选状态：%s\n%s\n未运行该候选；训练过不等于已准入。" % [String(entry.get("status", "未登记")), String(entry.get("status_zh", "未通过策略准入"))]
				color = AMBER
			elif String(controller.get("status")).begins_with("任务失败"):
				color = RED
			elif not bool(controller.get("active")) and String(controller.get("status")) != "强化学习任务完成":
				color = AMBER
	elif kind == "play":
		var replay := get_parent().get_node_or_null("CargoCircuitReplayController")
		if replay != null and replay.has_method("get_replay_status"):
			var result: Dictionary = replay.call("get_replay_status")
			text = "测试轨迹回放：%s\n%s split · %d 个样本 · 进度 %.1f%%\n动态障碍 %d · 运行 %.1f 秒\n状态：%s" % [
				String(result.get("algorithm", "--")), String(result.get("dataset_split", "--")), int(result.get("sample_count", 0)),
				float(result.get("progress", 0.0)) * 100.0, int(result.get("dynamic_obstacle_count", 0)), float(result.get("elapsed_seconds", 0.0)),
				"播放中" if bool(result.get("active", false)) else "已停止 / 已结束；结论以原生回执为准"]
	_policy_info.visible = not text.is_empty()
	if _policy_info.text != text:
		_policy_info.text = text
	_policy_info.add_theme_color_override("font_color", color)


func _target(step: Dictionary) -> Node:
	var path := String(step.get("node", ""))
	return null if path.is_empty() else get_parent().get_node_or_null(NodePath(path))


func _hide_other_panels(keep: Node) -> void:
	for node in get_parent().get_children():
		if not node is CanvasLayer or node == self:
			continue
		for property in ["_root", "_training_settings_overlay", "_training_overlay", "_hub_return_root"]:
			if node == keep and property == "_root":
				continue
			var control := _property(node, property) as Control
			if control != null:
				control.visible = false


func _property(object: Object, key: String) -> Variant:
	for entry in object.get_property_list():
		if String(entry["name"]) == key:
			return object.get(key)
	return null


func _native_button(step: Dictionary, target: Node) -> Button:
	var key := String(step.get("button_property", ""))
	if not key.is_empty():
		return _property(target, key) as Button
	var text := String(step.get("button_text", ""))
	return null if text.is_empty() else _find_button(target, text)


func _find_button(node: Node, text: String) -> Button:
	for child in node.get_children():
		if child is Button and String((child as Button).text).strip_edges() == text:
			return child as Button
		var found := _find_button(child, text)
		if found != null:
			return found
	return null


func _native_status(target: Node, fallback: String) -> String:
	var label := _property(target, "_status_label") as Label
	return label.text if label != null and not label.text.is_empty() else fallback


func _replay_active() -> bool:
	var replay := get_parent().get_node_or_null("CargoCircuitReplayController")
	return replay != null and replay.has_method("is_replay_active") and bool(replay.call("is_replay_active"))


func _bind_existing_buttons() -> void:
	for node in get_parent().get_children():
		if node is CanvasLayer and node != self:
			_bind_buttons_in(node)


func _bind_buttons_in(node: Node) -> void:
	if node is Button and not node is OptionButton:
		_register_button(node as Button)
	for child in node.get_children():
		_bind_buttons_in(child)


func _on_node_added(node: Node) -> void:
	if node is Button and not node is OptionButton:
		call_deferred("_register_button_reference", weakref(node))


func _register_button_reference(reference: WeakRef) -> void:
	var button := reference.get_ref() as Button
	if button != null:
		_register_button(button)


func _register_button(button: Button) -> void:
	if not is_instance_valid(button) or is_ancestor_of(button) or button.has_meta("sailing_demo_bound"):
		return
	button.set_meta("sailing_demo_bound", true)
	var callback := _on_native_button_pressed.bind(weakref(button))
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)


func _on_native_button_pressed(reference: WeakRef) -> void:
	if not _is_open or _busy or _manual_stopping or _native_sync_suppressed:
		return
	var button := reference.get_ref() as Button
	if button == null:
		return
	for index in range(_steps.size()):
		var step := _steps[index]
		var kind := String(step.get("kind", ""))
		var target := _target(step)
		if target == null or kind == "scene":
			continue
		# Shared native controls must resolve to the selected strategy/scene,
		# rather than always matching the first static replay or first actor.
		if kind in ["play", "stop"]:
			var selector := _property(target, "_strategy_option") as OptionButton
			if selector == null or selector.get_selected_id() != int(step.get("strategy_id", 0)):
				continue
		if kind == "mission_policy":
			var scenarios := get_tree().get_first_node_in_group(&"ship_scenario_system")
			if scenarios == null:
				continue
			var current: Dictionary = scenarios.call("get_scenario_status")
			if String(current.get("key", "")) != String(step["scenario_key"]):
				continue
		if kind == "mission" and not String(_property(target, "_active_mission_name")).contains(String(step.get("mission_name", ""))):
			continue
		var matches_action := target.is_ancestor_of(button) and _native_button(step, target) == button
		var matches_entry := not String(step.get("entry_button", "")).is_empty() and button.text == String(step["entry_button"])
		if not matches_action and not matches_entry:
			continue
		if kind == "mission_policy":
			var controller := _mission_controller()
			if controller != null and not bool(controller.get("active")) and not bool(_property(target, "_mission_rl_pending")):
				_message = "原生场景策略已停止；可重新应用场景，或继续下一步。"
				_refresh()
				return
		_step_index = index
		_busy = true
		_action_watchdog.start()
		_status = "running"
		_message = "已识别原生按钮，正在同步本步画面结果…"
		_revision += 1
		_refresh()
		_save_progress()
		_observe_native_action(step, _revision)
		return


func _observe_native_action(step: Dictionary, token: int) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if String(step.get("kind", "")) == "mission_policy":
		var error := await _await_mission_start(step, token)
		if not error.is_empty():
			if token == _revision:
				_finish_action(step, error)
			return
	if token == _revision:
		_finish_action(step, _observe_result(step))


func _restore_progress() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return
	_is_open = bool(config.get_value("guide", "open", false))
	_collapsed = bool(config.get_value("guide", "collapsed", false))
	_n_scenes_expanded = bool(config.get_value("guide", "n_scenes_expanded", true))
	_trace_id = String(config.get_value("guide", "trace", ""))
	var step_id := String(config.get_value("guide", "step_id", ""))
	for index in range(_steps.size()):
		if String(_steps[index]["id"]) == step_id:
			_step_index = index
			break
	var completed: Variant = config.get_value("guide", "completed", {})
	if completed is Dictionary:
		for step in _steps:
			var id := String(step["id"])
			if completed.get(id, "") in ["ready", "skipped"]:
				_completed[id] = completed[id]
	var saved_position: Variant = config.get_value("guide", "position_ratio", Vector2.ZERO)
	if saved_position is Vector2:
		_position_ratio = saved_position
		_custom_position = bool(config.get_value("guide", "custom_position", false))
	_message = "已恢复第 %d 步。点击重开本步页面，不会自动开始训练或回放。" % [_step_index + 1]


func _save_progress() -> void:
	if _steps.is_empty():
		return
	var config := ConfigFile.new()
	config.set_value("guide", "version", 1)
	config.set_value("guide", "open", _is_open)
	config.set_value("guide", "collapsed", _collapsed)
	config.set_value("guide", "n_scenes_expanded", _n_scenes_expanded)
	config.set_value("guide", "step_id", String(_steps[_step_index]["id"]))
	config.set_value("guide", "completed", _completed)
	config.set_value("guide", "trace", _trace_id)
	config.set_value("guide", "custom_position", _custom_position)
	config.set_value("guide", "position_ratio", _position_ratio)
	if config.save(SAVE_PATH) != OK and _status_label != null:
		_status_label.text += "\n本机进度暂未写入，下次启动可能无法恢复。"


func _new_trace_id() -> String:
	return "SAILING-%d-%06x" % [int(Time.get_unix_time_from_system()), randi() % 0xFFFFFF]


func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_filter = Control.MOUSE_FILTER_STOP
	button.custom_minimum_size = Vector2(34, 34)
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", Color("eaf4ff"))
	button.add_theme_stylebox_override("normal", _style(Color("123e66"), Color("356b80"), 10))
	button.add_theme_stylebox_override("hover", _style(Color("1769a0"), CYAN, 10))
	button.add_theme_stylebox_override("pressed", _style(Color("1769e0"), CYAN, 10))
	button.pressed.connect(action)
	return button


func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _wrapped_label(font_size: int, color: Color) -> Label:
	var label := _label("", font_size, color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _wrapped_text(text: String, font_size: int, color: Color) -> Label:
	var label := _wrapped_label(font_size, color)
	label.text = text
	return label


func _style(fill: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		style.set_content_margin(side, 7.0)
	return style


func _show_trained_evidence() -> String:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/demo/trained_scene_evidence.json"))
	if not parsed is Dictionary or not (parsed as Dictionary).get("scenarios", []) is Array:
		return "已训练场景清单不可读取。"
	_evidence_scenes = (parsed as Dictionary)["scenarios"] as Array
	if _evidence_scenes.is_empty():
		return "没有可核验的已训练场景。"
	if _evidence_panel == null:
		_evidence_panel = PanelContainer.new()
		_evidence_panel.name = "TrainedSceneEvidencePanel"
		_evidence_panel.add_theme_stylebox_override("panel", _style(Color("081d31"), CYAN, 14))
		_root.add_child(_evidence_panel)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 10)
		_evidence_panel.add_child(box)
		var row := HBoxContainer.new()
		box.add_child(row)
		var heading := _label("已训练场景 · 算法与数据清单", 20, CYAN)
		heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(heading)
		row.add_child(_button("关闭 ×", func() -> void: _evidence_panel.hide()))
		_evidence_picker = OptionButton.new()
		_evidence_picker.name = "TrainedEvidenceScenePicker"
		_evidence_picker.fit_to_longest_item = false
		_evidence_picker.custom_minimum_size.y = 40
		_evidence_picker.item_selected.connect(_render_evidence_scene)
		box.add_child(_evidence_picker)
		_evidence_text = RichTextLabel.new()
		_evidence_text.name = "TrainedEvidenceFields"
		_evidence_text.bbcode_enabled = false
		_evidence_text.selection_enabled = true
		_evidence_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_evidence_text.add_theme_font_size_override("normal_font_size", 15)
		box.add_child(_evidence_text)
	_evidence_picker.clear()
	for index in range(_evidence_scenes.size()):
		_evidence_picker.add_item("%02d · %s" % [index + 1, String((_evidence_scenes[index] as Dictionary).get("name", ""))])
	_evidence_panel.show()
	_layout_evidence()
	_render_evidence_scene(0)
	return ""


func _layout_evidence() -> void:
	if _evidence_panel == null:
		return
	var view := get_viewport().get_visible_rect().size
	_evidence_panel.position = Vector2(16, 82)
	_evidence_panel.size = Vector2(maxf(220.0, view.x - 420.0), maxf(200.0, view.y - 100.0))


func _render_evidence_scene(index: int) -> void:
	if index < 0 or index >= _evidence_scenes.size():
		return
	var scene := _evidence_scenes[index] as Dictionary
	var text := "%s\n%s\n公开观测、工程派生、仿真交互分别标注；历史已训练不等于现场部署。\n" % [String(scene.get("name", "")), String(scene.get("status", ""))]
	var data: Variant = scene.get("datasets", {})
	var data_line := "数据名称与样本分区见下方；缺失原始文件会明确标注。"
	if data is Dictionary:
		var dataset := data as Dictionary
		data_line = String(dataset.get("name", dataset.get("id", "已登记数据集")))
		if dataset.has("interaction_steps"):
			data_line += " · 交互 %d 步 · 验证 %d 回合 / 独立测试 %d 回合 · 实船记录 %d" % [int(dataset.get("interaction_steps", 0)), int(dataset.get("validation_episodes", 0)), int(dataset.get("independent_test_episodes", 0)), int(dataset.get("real_world_training_rows", 0))]
		elif dataset.has("split_scenarios"):
			data_line += " · 场景分区 " + JSON.stringify(dataset["split_scenarios"])
	var state: Variant = scene.get("state", [])
	var state_line := "%d 个状态量（完整顺序见下方）" % (state as Array).size() if state is Array else JSON.stringify((state as Dictionary).get("dimension", "见契约")) + "维状态（完整顺序见下方）" if state is Dictionary else String(state)
	var reward: Variant = scene.get("reward", {})
	var reward_line := String((reward as Dictionary).get("base", (reward as Dictionary).get("formula", "按源码奖励权重计算进度、效率、安全与动作代价"))) if reward is Dictionary else String(reward)
	text += "\n具体算法：%s\n数据：%s\nState：%s\nReward：%s\nAction：油门 throttle / 舵角 rudder（具体限幅和离散档位见下方）\n输出：动作、航迹、任务完成、碰撞/净距、收益与模型校验结果。\n\n──────── 完整可核验清单 ────────\n" % [JSON.stringify(scene.get("algorithm")), data_line, state_line, reward_line]
	var labels := {"algorithm":"具体算法", "datasets":"数据集名称、数量与来源", "state":"State 状态（模型看到什么）", "reward":"Reward 奖励（怎样判断好坏）", "actions":"Action 动作（模型能决定什么）", "outputs":"输出清单与验证结果", "training":"训练记录与复现参数", "sources":"证据文件与 SHA-256"}
	for key: String in labels:
		text += "\n━━ %s ━━\n%s\n" % [String(labels[key]), JSON.stringify(scene.get(key, "未登记（缺证据）"), "  ")]
	_evidence_text.text = text
	_evidence_text.scroll_to_line(0)

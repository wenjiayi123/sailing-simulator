extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var checks := {}
	var panel_script: Script = load("res://scripts/ui/ship_navigation_planning_panel.gd")
	if panel_script == null or not panel_script.can_instantiate():
		push_error("planning panel did not compile")
		quit(1)
		return
	var panel: Node = panel_script.new()
	var tab: Control = panel.call("_build_demo_data_tab")
	root.add_child(tab)
	panel.call("_refresh_demo_data_readiness")
	var state: Dictionary = panel.call("get_demo_data_readiness_snapshot")
	checks["read_current_report"] = bool(state.get("export_enabled", false))
	checks["research_tasks_visible"] = String(state.get("text", "")).contains("409")
	checks["source_and_pending_visible"] = String(state.get("text", "")).contains("待接入/验收") and String(state.get("text", "")).contains("user://port_profile.json")
	checks["no_authority"] = not bool(state.get("production_authority", true)) and not bool((state.get("report", {}) as Dictionary).get("live_control_ready", true))
	panel.set("demo_data_readiness_path", "res://reports/not-provided-data-review.json")
	panel.call("_refresh_demo_data_readiness")
	state = panel.call("get_demo_data_readiness_snapshot")
	checks["missing_clears_report_and_export"] = not bool(state.get("export_enabled", true)) and (state.get("report", {}) as Dictionary).is_empty()
	var passed := true
	for value in checks.values():
		passed = passed and bool(value)
	var report := {"checks": checks, "passed": passed, "headless_widget_check": true,
		"visual_desktop_verified": false, "production_authority": false, "existing_models_modified": false}
	var file := FileAccess.open("res://reports/demo_data_panel_smoke_20261023.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print(JSON.stringify(report))
	tab.queue_free()
	panel.free()
	quit(0 if passed else 1)

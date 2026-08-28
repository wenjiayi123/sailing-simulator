extends SceneTree

const REPORT_PATH := "res://reports/godot_colreg_complex_smoke_v1.json"
const EXPORTS := [
	"user://colreg_complex_evidence/colreg_complex_scenario_catalog_v2.json",
	"user://colreg_complex_evidence/local_navigation_rules_template_v1.json",
	"user://colreg_complex_evidence/colreg_complex_assurance_v2.json",
]

var _checks: Dictionary = {}
var _errors: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _record(name: String, passed: bool, detail: Variant) -> void:
	_checks[name] = {"passed": passed, "detail": _public_value(detail)}
	if not passed:
		_errors.append("%s: %s" % [name, str(_public_value(detail))])


func _public_value(value: Variant) -> Variant:
	if value is Dictionary:
		var cleaned := {}
		for key in value:
			cleaned[key] = _public_value(value[key])
		return cleaned
	if value is Array:
		var cleaned_array: Array = []
		for item in value:
			cleaned_array.append(_public_value(item))
		return cleaned_array
	if value is String or value is StringName:
		var project_root := ProjectSettings.globalize_path("res://").trim_suffix("/")
		var user_root := ProjectSettings.globalize_path("user://").trim_suffix("/")
		return String(value).replace(project_root + "/", "res://").replace(user_root + "/", "user://")
	return value


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var value: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return value if value is Dictionary else {}


func _find_button(root: Node, title: String) -> Button:
	for node in root.find_children("*", "Button", true, false):
		var button := node as Button
		if button != null and button.text == title:
			return button
	return null


func _select_scenario(panel: Node, scenario_id: String) -> bool:
	var option := panel.get("_scenario_option") as OptionButton
	for index in range(option.item_count):
		if String(option.get_item_metadata(index)) == scenario_id:
			option.select(index)
			option.item_selected.emit(index)
			return true
	return false


func _run() -> void:
	var scene_status := change_scene_to_file("res://main.tscn")
	_record("main_scene_load", scene_status == OK, scene_status)
	for _index in range(24):
		await process_frame
	var main := current_scene
	if main == null:
		_record("main_scene_ready", false, "current_scene unavailable")
		_finish()
		return
	var panel := main.get_node_or_null("ShipColregComplexPanel")
	_record("complex_colreg_panel_present", panel != null, "ShipColregComplexPanel")
	if panel == null:
		_finish()
		return
	var root := panel.get("_root") as Control
	_record("complex_colreg_panel_root_present", root != null, root)
	panel.call("show_panel")
	_record("show_panel_opens", root.visible, root.visible)
	var snapshot := panel.call("get_acceptance_snapshot") as Dictionary
	var report := snapshot.get("report", {}) as Dictionary
	var complex_result := report.get("complex_assurance", {}) as Dictionary
	_record(
		"functional_report_passes_16_scenarios_45_cases",
		bool(report.get("functional_assurance_passed", false))
		and int(complex_result.get("scenario_count", 0)) == 16
		and int(complex_result.get("scenario_passed_count", 0)) == 16
		and int(complex_result.get("case_count", 0)) == 45
		and int(complex_result.get("case_matched_count", 0)) == 45,
		{"scenario_count": complex_result.get("scenario_count"), "case_count": complex_result.get("case_count")},
	)
	_record(
		"all_complex_capabilities_covered",
		bool(complex_result.get("coverage_complete", false))
		and (complex_result.get("missing_capabilities", []) as Array).is_empty()
		and (complex_result.get("covered_capabilities", []) as Array).size() == 10,
		complex_result.get("covered_capabilities", []),
	)
	var legacy := report.get("legacy_v1_regression", {}) as Dictionary
	_record(
		"legacy_v1_preserved",
		bool(legacy.get("passed", false))
		and int(legacy.get("scenario_count", 0)) == 6
		and int(legacy.get("action_case_count", 0)) >= 11
		and not bool(legacy.get("legacy_v1_replaced", true)),
		legacy,
	)
	var selected := snapshot.get("selected_scenario", {}) as Dictionary
	var assessment := selected.get("assessment", {}) as Dictionary
	_record(
		"multi_ship_duty_graph_visible",
		String(selected.get("scenario_id", "")) == "multi_ship_mixed_duties"
		and (assessment.get("multi_ship_duty_graph", []) as Array).size() == 3
		and String(assessment.get("priority_target_id", "")) == "NUC-A",
		assessment.get("multi_ship_duty_graph", []),
	)
	_record(
		"scenario_selector_has_all_scenarios",
		(panel.get("_scenario_option") as OptionButton).item_count == 16,
		(panel.get("_scenario_option") as OptionButton).item_count,
	)
	_record("narrow_channel_scenario_selectable", _select_scenario(panel, "narrow_channel_crossing_impedance"), "narrow_channel_crossing_impedance")
	snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	selected = snapshot.get("selected_scenario", {}) as Dictionary
	assessment = selected.get("assessment", {}) as Dictionary
	_record(
		"narrow_channel_rule_9_and_violation_visible",
		(assessment.get("rules", []) as Array).has("Rule 9")
		and not bool(assessment.get("context_compliant", true))
		and (assessment.get("context_violations", []) as Array).size() > 0,
		assessment,
	)
	_record("ram_signal_scenario_selectable", _select_scenario(panel, "give_way_to_ram_and_verify_signals"), "give_way_to_ram_and_verify_signals")
	snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	selected = snapshot.get("selected_scenario", {}) as Dictionary
	assessment = selected.get("assessment", {}) as Dictionary
	var visual := assessment.get("expected_visual_signal", {}) as Dictionary
	_record(
		"ram_lights_and_shapes_visible",
		(visual.get("lights", []) as Array).size() == 3
		and (visual.get("shapes", []) as Array).size() == 3
		and (assessment.get("rules", []) as Array).has("Rule 27"),
		visual,
	)
	_record("restricted_visibility_sound_scenario_selectable", _select_scenario(panel, "restricted_visibility_nuc_sound"), "restricted_visibility_nuc_sound")
	snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	selected = snapshot.get("selected_scenario", {}) as Dictionary
	assessment = selected.get("assessment", {}) as Dictionary
	_record(
		"nuc_sound_pattern_and_rule_35_visible",
		String(assessment.get("expected_sound_signal", "")) == "one_prolonged_two_short"
		and (assessment.get("rules", []) as Array).has("Rule 35"),
		assessment.get("expected_sound_signal"),
	)
	var before_case := int(snapshot.get("selected_case_index", -1))
	panel.call("_next_case")
	snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	_record("next_case_cycles_real_case", int(snapshot.get("selected_case_index", -1)) != before_case, snapshot.get("selected_case_index"))
	var status_label := panel.get("_status_label") as RichTextLabel
	_record("status_exposes_pass_and_boundaries", status_label.text.contains("16/16") and status_label.text.contains("45/45") and status_label.text.contains("地方规则官方授权=false") and status_label.text.contains("策略/运动模型未改"), status_label.text)
	root.visible = false
	var event := InputEventKey.new()
	event.pressed = true
	event.physical_keycode = KEY_R
	panel.call("_unhandled_input", event)
	_record("hotkey_R_opens_complex_colreg_panel", root.visible, root.visible)
	var next_button := _find_button(root, "下一个")
	var previous_button := _find_button(root, "上一个")
	var next_case_button := _find_button(root, "检查下一个案例")
	_record("scenario_and_case_buttons_connected", next_button != null and previous_button != null and next_case_button != null, {"next": next_button != null, "previous": previous_button != null, "case": next_case_button != null})
	var run_button := _find_button(root, "重新运行规则验收")
	_record("real_checker_button_present", run_button != null, "重新运行规则验收")
	if run_button != null:
		run_button.pressed.emit()
	snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	_record(
		"ui_runs_real_complex_colreg_checker",
		int(snapshot.get("last_exit_code", -1)) == 0
		and String(snapshot.get("last_command_output", "")).contains("COLREG_COMPLEX:PASS:16/16:45/45")
		and bool((snapshot.get("report", {}) as Dictionary).get("functional_assurance_passed", false)),
		{"exit_code": snapshot.get("last_exit_code"), "output": snapshot.get("last_command_output")},
	)
	var export_button := _find_button(root, "导出场景证据包")
	_record("export_button_present", export_button != null, "导出场景证据包")
	if export_button != null:
		export_button.pressed.emit()
	snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	var export_result := snapshot.get("last_export", {}) as Dictionary
	var hashes := export_result.get("files_sha256", {}) as Dictionary
	var exports_valid := bool(export_result.get("passed", false)) and hashes.size() == 3
	for path in EXPORTS:
		exports_valid = exports_valid and FileAccess.file_exists(path) and String(hashes.get(path, "")) == FileAccess.get_sha256(path)
	_record("exported_evidence_hashes_match", exports_valid, export_result)
	_record(
		"external_authority_boundaries_remain_false",
		not bool(snapshot.get("official_local_rules_connected", true))
		and not bool(snapshot.get("colreg_certified", true))
		and not bool(snapshot.get("production_authority", true))
		and not bool(snapshot.get("training_performed", true))
		and not bool(snapshot.get("existing_policy_modified", true))
		and not bool(snapshot.get("ship_motion_model_modified", true)),
		snapshot,
	)
	var close_button := _find_button(root, "关闭 R")
	if close_button != null:
		close_button.pressed.emit()
	_record("close_button_hides_panel", close_button != null and not root.visible, root.visible)
	_finish()


func _finish() -> void:
	var passed := _errors.is_empty()
	var payload := {
		"schema_version": "godot_colreg_complex_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"checks": _checks,
		"passed_count": _checks.size() - _errors.size(),
		"check_count": _checks.size(),
		"errors": _errors,
		"passed": passed,
		"training_performed": false,
		"existing_policy_modified": false,
		"ship_motion_model_modified": false,
		"official_local_rules_connected": false,
		"colreg_certified": false,
		"production_authority": false,
		"boundary": "Godot UI and deterministic scenario-functional evidence only; not legal interpretation or field authority.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("COLREG_COMPLEX_UI:%s:%d/%d" % ["PASS" if passed else "FAIL", payload["passed_count"], payload["check_count"]])
	for error in _errors:
		push_error(error)
	quit(0 if passed else 1)

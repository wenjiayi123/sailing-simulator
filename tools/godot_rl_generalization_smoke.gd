extends SceneTree

const REPORT_PATH := "res://reports/godot_rl_generalization_smoke_v1.json"
const EXPORTS := [
	"user://rl_generalization_evidence/rl_generalization_campaign_v1.json",
	"user://rl_generalization_evidence/rl_generalization_results_manifest.json",
	"user://rl_generalization_evidence/rl_generalization_assurance_v1.json",
	"user://rl_generalization_evidence/rl_generalization_evaluation_plan_v1.json",
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


func _find_button(root: Node, title: String) -> Button:
	for node in root.find_children("*", "Button", true, false):
		var button := node as Button
		if button != null and button.text == title:
			return button
	return null


func _select_metadata(option: OptionButton, identifier: String) -> bool:
	for index in range(option.item_count):
		if String(option.get_item_metadata(index)) == identifier:
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
	var panel := main.get_node_or_null("ShipRlGeneralizationPanel")
	_record("generalization_panel_present", panel != null, "ShipRlGeneralizationPanel")
	if panel == null:
		_finish()
		return
	var root := panel.get("_root") as Control
	_record("generalization_panel_root_present", root != null, root)
	panel.call("show_panel")
	_record("show_panel_opens", root.visible, root.visible)
	var snapshot := panel.call("get_acceptance_snapshot") as Dictionary
	var report := snapshot.get("report", {}) as Dictionary
	var plan := snapshot.get("plan", {}) as Dictionary
	_record(
		"functional_framework_passes_all_checks",
		bool(report.get("functional_framework_complete", false))
		and (report.get("checks", {}) as Dictionary).size() == 16
		and not (report.get("checks", {}) as Dictionary).values().has(false),
		report.get("checks", {}),
	)
	_record(
		"frozen_plan_has_410_cells",
		int(plan.get("base_matrix_cell_count", 0)) == 320
		and int(plan.get("ablation_pair_count", 0)) == 30
		and int(plan.get("stress_cell_count", 0)) == 40
		and int(plan.get("ood_cell_count", 0)) == 20
		and int(plan.get("total_planned_cell_count", 0)) == 410
		and (plan.get("cells", []) as Array).size() == 410,
		{"base": plan.get("base_matrix_cell_count"), "total": plan.get("total_planned_cell_count")},
	)
	_record("plan_has_not_accessed_results", plan.get("test_results_accessed") is bool and not bool(plan.get("test_results_accessed")) and not bool(plan.get("training_performed", true)), {"test_results_accessed": plan.get("test_results_accessed"), "training_performed": plan.get("training_performed")})
	var domains := report.get("domain_summary", {}) as Dictionary
	_record("multi_domain_counts_visible", int(domains.get("declared_port_archetype_count", 0)) == 4 and int(domains.get("declared_season_count", 0)) == 4 and int(domains.get("vessel_family_count", 0)) == 4 and int(domains.get("random_seed_count", 0)) == 5, domains)
	_record("real_data_boundary_is_one_port_one_season", int(domains.get("real_observed_port_count", 0)) == 1 and int(domains.get("real_observed_season_count", 0)) == 1 and int(domains.get("synthetic_port_domain_count", 0)) == 3 and int(domains.get("synthetic_season_overlay_count", 0)) == 3, domains)
	var inventory := report.get("preserved_policy_inventory", {}) as Dictionary
	_record("ten_existing_policy_artifacts_hash_verified", bool(inventory.get("passed", false)) and int(inventory.get("policy_count", 0)) == 10 and (inventory.get("errors", []) as Array).is_empty(), inventory)
	var smoke := report.get("functional_smoke", {}) as Dictionary
	_record("four_interactive_traffic_fixtures_pass", bool(smoke.get("passed", false)) and int(smoke.get("fixture_count", 0)) == 4 and int(smoke.get("passed_count", 0)) == 4, smoke.get("results", []))
	var receipt_total := 0
	var contracts_preserved := true
	for raw in smoke.get("results", []) as Array:
		var item := raw as Dictionary
		receipt_total += int(item.get("interaction_receipt_count", 0))
		contracts_preserved = contracts_preserved and bool(item.get("receipt_chain_valid", false)) and not bool(item.get("own_ship_motion_model_modified", true)) and not bool(item.get("observation_contract_modified", true)) and not bool(item.get("action_contract_modified", true)) and not bool(item.get("policy_modified", true))
	_record("interactive_receipts_are_chained", receipt_total > 0 and contracts_preserved, {"receipt_total": receipt_total, "contracts_preserved": contracts_preserved})
	var shadow := report.get("shadow_receipt_smoke", {}) as Dictionary
	_record("shadow_function_is_read_only", bool(shadow.get("passed", false)) and int(shadow.get("recommendation_count", 0)) == 4 and int(shadow.get("dispatch_count", -1)) == 0 and not bool(shadow.get("real_shadow_operation", true)), shadow)
	var gate := report.get("results_evidence_gate", {}) as Dictionary
	_record("empty_results_fail_closed", bool(gate.get("structural_contract_complete", false)) and not bool(gate.get("training_completed", true)) and not bool(gate.get("convergence_demonstrated", true)) and not bool(gate.get("matrix_complete", true)) and not bool(gate.get("confidence_intervals_complete", true)) and not bool(gate.get("generalization_evidence_complete", true)), gate)
	var domain_option := panel.get("_domain_option") as OptionButton
	var fixture_option := panel.get("_fixture_option") as OptionButton
	_record("domain_selector_has_16_entries", domain_option.item_count == 16, domain_option.item_count)
	_record("fixture_selector_has_4_entries", fixture_option.item_count == 4, fixture_option.item_count)
	_record("interactive_traffic_domain_selectable", _select_metadata(domain_option, "traffic_adversarial_closing"), "traffic_adversarial_closing")
	snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	_record("selected_domain_receipt_is_visible", String(snapshot.get("selected_domain_id", "")) == "traffic_adversarial_closing", snapshot.get("selected_domain_id"))
	_record("fixture_selectable", _select_metadata(fixture_option, "smoke_archipelago_bulk_adversarial"), "smoke_archipelago_bulk_adversarial")
	snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	_record("selected_fixture_receipt_is_visible", String(snapshot.get("selected_fixture_id", "")) == "smoke_archipelago_bulk_adversarial", snapshot.get("selected_fixture_id"))
	var before_fixture := String(snapshot.get("selected_fixture_id", ""))
	panel.call("_next_fixture")
	snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	_record("next_fixture_cycles", String(snapshot.get("selected_fixture_id", "")) != before_fixture, snapshot.get("selected_fixture_id"))
	panel.call("_next_gap")
	snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	_record("evidence_gap_browser_works", not String(snapshot.get("selected_gap", "")).is_empty(), snapshot.get("selected_gap"))
	var status_label := panel.get("_status_label") as RichTextLabel
	_record("status_exposes_410_and_fail_closed_boundaries", status_label.text.contains("410 PLANNED CELLS") and status_label.text.contains("training=false") and status_label.text.contains("real cross-port=false") and status_label.text.contains("shadow=false"), status_label.text)
	root.visible = false
	var event := InputEventKey.new()
	event.pressed = true
	event.physical_keycode = KEY_T
	panel.call("_unhandled_input", event)
	_record("hotkey_T_opens_generalization_panel", root.visible, root.visible)
	var run_button := _find_button(root, "重新运行框架验收")
	_record("real_checker_button_present", run_button != null, "重新运行框架验收")
	if run_button != null:
		run_button.pressed.emit()
	snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	_record("ui_runs_real_generalization_checker", int(snapshot.get("last_exit_code", -1)) == 0 and String(snapshot.get("last_command_output", "")).contains("RL_GENERALIZATION:PASS:16/16:plan=410:training=false") and bool((snapshot.get("report", {}) as Dictionary).get("functional_framework_complete", false)), {"exit_code": snapshot.get("last_exit_code"), "output": snapshot.get("last_command_output")})
	var export_button := _find_button(root, "导出冻结评测包")
	_record("export_button_present", export_button != null, "导出冻结评测包")
	if export_button != null:
		export_button.pressed.emit()
	snapshot = panel.call("get_acceptance_snapshot") as Dictionary
	var export_result := snapshot.get("last_export", {}) as Dictionary
	var hashes := export_result.get("files_sha256", {}) as Dictionary
	var exports_valid := bool(export_result.get("passed", false)) and hashes.size() == 4
	for path in EXPORTS:
		exports_valid = exports_valid and FileAccess.file_exists(path) and String(hashes.get(path, "")) == FileAccess.get_sha256(path)
	_record("exported_frozen_package_hashes_match", exports_valid, export_result)
	_record("all_claim_boundaries_remain_false", not bool(snapshot.get("training_performed", true)) and not bool(snapshot.get("convergence_demonstrated", true)) and not bool(snapshot.get("existing_policy_modified", true)) and not bool(snapshot.get("ship_motion_model_modified", true)) and not bool(snapshot.get("real_multi_port_generalization_demonstrated", true)) and not bool(snapshot.get("real_multi_season_generalization_demonstrated", true)) and not bool(snapshot.get("shadow_operation_completed", true)) and not bool(snapshot.get("production_authority", true)), snapshot)
	var close_button := _find_button(root, "关闭 T")
	if close_button != null:
		close_button.pressed.emit()
	_record("close_button_hides_panel", close_button != null and not root.visible, root.visible)
	_finish()


func _finish() -> void:
	var passed := _errors.is_empty()
	var payload := {
		"schema_version": "godot_rl_generalization_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"checks": _checks,
		"passed_count": _checks.size() - _errors.size(),
		"check_count": _checks.size(),
		"errors": _errors,
		"passed": passed,
		"training_performed": false,
		"convergence_demonstrated": false,
		"existing_policy_modified": false,
		"ship_motion_model_modified": false,
		"real_multi_port_generalization_demonstrated": false,
		"real_multi_season_generalization_demonstrated": false,
		"shadow_operation_completed": false,
		"production_authority": false,
		"boundary": "Functional framework and UI evidence only; no training, convergence, real cross-port or field-shadow claim.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("RL_GENERALIZATION_UI:%s:%d/%d" % ["PASS" if passed else "FAIL", payload["passed_count"], payload["check_count"]])
	for error in _errors:
		push_error(error)
	quit(0 if passed else 1)

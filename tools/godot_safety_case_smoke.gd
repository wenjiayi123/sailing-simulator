extends SceneTree

const REPORT_PATH := "res://reports/godot_safety_case_smoke_v1.json"
const FROZEN_ARTIFACT_PATHS := [
	"res://player.gd",
	"res://scripts/physics/catamaran_three_dof_dynamics.gd",
	"res://data/verification/catamaran_usv_dynamics_reference_v2.json",
	"res://data/rl/long_beach_ais_port_ops_benchmark_v2.json",
	"res://data/rl/port_ops_safety_supervisor_v3.json",
	"res://reports/artifacts/cargo_circuit_rl_v1/cargo_sac_policy.zip",
	"res://reports/artifacts/cargo_circuit_dynamic_rl_v2/cargo_dynamic_sac_policy.zip",
]
const USER_FILES_TO_PRESERVE := [
	"user://mass_safety_case_evidence/mass_safety_case_v1.json",
	"user://mass_safety_case_evidence/mass_safety_case_acceptance_manifest.json",
	"user://mass_safety_case_evidence/mass_safety_case_assessment_v1.json",
]

var _checks: Dictionary = {}
var _errors: Array[String] = []
var _saved_user_files: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _record(name: String, passed: bool, detail: Variant) -> void:
	_checks[name] = {"passed": passed, "detail": detail}
	if not passed:
		_errors.append("%s: %s" % [name, str(detail)])


func _frozen_hashes() -> Dictionary:
	var hashes := {}
	for path in FROZEN_ARTIFACT_PATHS:
		hashes[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "MISSING"
	return hashes


func _snapshot_user_files() -> void:
	for path in USER_FILES_TO_PRESERVE:
		var record := {"existed": FileAccess.file_exists(path), "bytes": PackedByteArray()}
		if bool(record["existed"]):
			var file := FileAccess.open(path, FileAccess.READ)
			if file != null:
				record["bytes"] = file.get_buffer(file.get_length())
				file.close()
		_saved_user_files[path] = record


func _restore_user_files() -> void:
	for path in USER_FILES_TO_PRESERVE:
		var record := _saved_user_files.get(path, {}) as Dictionary
		if bool(record.get("existed", false)):
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file != null:
				file.store_buffer(record.get("bytes", PackedByteArray()) as PackedByteArray)
				file.close()
		elif FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _find_button(root: Node, title: String) -> Button:
	for node in root.find_children("*", "Button", true, false):
		var button := node as Button
		if button != null and button.text == title:
			return button
	return null


func _count_true(values: Dictionary) -> int:
	var count := 0
	for value in values.values():
		if value is bool and bool(value):
			count += 1
	return count


func _run() -> void:
	_snapshot_user_files()
	var before_hashes := _frozen_hashes()
	var scene_status := change_scene_to_file("res://main.tscn")
	_record("main_scene_load_request", scene_status == OK, scene_status)
	for _index in range(24):
		await process_frame
	var main := current_scene
	if main == null:
		_record("main_scene_ready", false, "current_scene is null")
		_finish(before_hashes)
		return
	var panel := main.get_node_or_null("ShipSafetyCasePanel")
	_record("safety_case_panel_present", panel != null, "ShipSafetyCasePanel")
	if panel == null:
		_finish(before_hashes)
		return
	var snapshot := panel.call("get_acceptance_snapshot") as Dictionary
	var report := snapshot.get("report", {}) as Dictionary
	var checks := report.get("checks", {}) as Dictionary
	_record(
		"functional_safety_case_passes_all_sections",
		String(report.get("schema_version", "")) == "mass_safety_case_assessment_v1"
		and bool(report.get("functional_safety_case_complete", false))
		and checks.size() == 12
		and _count_true(checks) == 12,
		checks,
	)
	_record(
		"external_acceptance_and_certification_fail_closed",
		String(report.get("status", "")) == "FUNCTIONAL_SAFETY_CASE_COMPLETE_EXTERNAL_ACCEPTANCE_BLOCKED"
		and report.get("independent_review_complete") == false
		and report.get("flag_state_approval") == false
		and report.get("coastal_state_approval") == false
		and report.get("class_approval") == false
		and report.get("type_approval") == false
		and report.get("mass_safety_certificate") == false
		and report.get("sea_trial_completed") == false
		and report.get("production_authority") == false,
		report.get("boundary", ""),
	)
	var sections := report.get("section_results", {}) as Dictionary
	var odd := sections.get("operational_design_domain", {}) as Dictionary
	_record("odd_covers_twelve_monitored_dimensions", bool(odd.get("passed", false)) and int(odd.get("dimension_count", 0)) == 12, odd)
	var hazards := sections.get("hazard_log", {}) as Dictionary
	_record("hazard_log_covers_twelve_categories_and_controls", bool(hazards.get("passed", false)) and int(hazards.get("hazard_count", 0)) == 12 and int(hazards.get("control_count", 0)) == 24, hazards)
	var mrc := sections.get("minimum_risk_conditions", {}) as Dictionary
	_record("six_minimum_risk_conditions_are_complete", bool(mrc.get("passed", false)) and int(mrc.get("mrc_count", 0)) == 6, mrc)
	var trees := sections.get("fault_trees", {}) as Dictionary
	_record("five_fault_trees_cover_every_hazard", bool(trees.get("passed", false)) and int(trees.get("tree_count", 0)) == 5 and (trees.get("uncovered_hazard_ids", []) as Array).is_empty(), trees)
	var rcc := sections.get("remote_control_centre", {}) as Dictionary
	_record("remote_control_centre_contract_is_complete_but_not_site_authorized", bool(rcc.get("passed", false)) and rcc.get("site_authorized") == false, rcc)
	var responsibilities := sections.get("responsibility_model", {}) as Dictionary
	_record("personnel_responsibility_raci_is_complete", bool(responsibilities.get("passed", false)) and int(responsibilities.get("role_count", 0)) == 9 and int(responsibilities.get("activity_count", 0)) == 7, responsibilities)
	var regulatory := sections.get("regulatory_applicability", {}) as Dictionary
	_record("five_regulatory_routes_require_external_decisions", bool(regulatory.get("passed", false)) and int(regulatory.get("instrument_count", 0)) == 5 and bool(regulatory.get("all_external_determination_required", false)), regulatory)
	var evidence := sections.get("evidence_registry", {}) as Dictionary
	_record("ten_evidence_records_are_hash_bound", bool(evidence.get("passed", false)) and int(evidence.get("evidence_count", 0)) == 10 and (report.get("evidence_sha256", {}) as Dictionary).size() == 10, evidence)
	var claims := sections.get("claim_graph", {}) as Dictionary
	_record("claim_graph_is_traceable_and_acyclic", bool(claims.get("passed", false)) and int(claims.get("claim_count", 0)) == 7 and String(claims.get("root_claim_id", "")) == "SC-TOP", claims)
	var monitor := report.get("runtime_odd_monitor_smoke", {}) as Dictionary
	_record("every_odd_breach_maps_to_mrc_without_production_authority", bool(monitor.get("passed", false)) and int(monitor.get("breach_case_count", 0)) == 12 and monitor.get("production_command_authority") == false, monitor)
	var root := panel.get("_root") as Control
	root.visible = false
	var key_event := InputEventKey.new()
	key_event.pressed = true
	key_event.physical_keycode = KEY_Q
	panel.call("_unhandled_input", key_event)
	await process_frame
	_record("hotkey_Q_opens_safety_case_panel", root.visible, root.visible)
	var hazard_option := panel.get("_hazard_option") as OptionButton
	var mrc_option := panel.get("_mrc_option") as OptionButton
	var claim_option := panel.get("_claim_option") as OptionButton
	_record("hazard_catalog_is_browsable", hazard_option != null and hazard_option.item_count == 12, hazard_option.item_count if hazard_option != null else -1)
	_record("mrc_catalog_is_browsable", mrc_option != null and mrc_option.item_count == 6, mrc_option.item_count if mrc_option != null else -1)
	_record("claim_graph_is_browsable", claim_option != null and claim_option.item_count == 7, claim_option.item_count if claim_option != null else -1)
	if hazard_option != null:
		var before_hazard := (panel.get("_hazard_label") as RichTextLabel).text
		hazard_option.select(1)
		hazard_option.item_selected.emit(1)
		_record("hazard_selection_updates_detail", (panel.get("_hazard_label") as RichTextLabel).text != before_hazard, (panel.get("_hazard_label") as RichTextLabel).text)
	if mrc_option != null:
		var before_mrc := (panel.get("_mrc_label") as RichTextLabel).text
		mrc_option.select(1)
		mrc_option.item_selected.emit(1)
		_record("mrc_selection_updates_detail", (panel.get("_mrc_label") as RichTextLabel).text != before_mrc, (panel.get("_mrc_label") as RichTextLabel).text)
	if claim_option != null:
		var before_claim := (panel.get("_claim_label") as RichTextLabel).text
		claim_option.select(1)
		claim_option.item_selected.emit(1)
		_record("claim_selection_updates_detail", (panel.get("_claim_label") as RichTextLabel).text != before_claim, (panel.get("_claim_label") as RichTextLabel).text)
	var odd_button := _find_button(root, "演示 ODD 越界→MRC")
	_record("odd_breach_demo_button_present", odd_button != null, "演示 ODD 越界→MRC")
	if odd_button != null:
		odd_button.pressed.emit()
		await process_frame
	var odd_snapshot := panel.call("get_acceptance_snapshot") as Dictionary
	var odd_case := odd_snapshot.get("selected_odd_case", {}) as Dictionary
	_record("odd_breach_demo_returns_mrc_route_only", not odd_case.is_empty() and not ((odd_case.get("result", {}) as Dictionary).get("required_mrc_ids", []) as Array).is_empty() and odd_snapshot.get("production_authority") == false, odd_case)
	var gap_button := _find_button(root, "下一个外部证据缺口")
	_record("external_gap_browser_button_present", gap_button != null, "下一个外部证据缺口")
	if gap_button != null:
		gap_button.pressed.emit()
		await process_frame
	var gap_snapshot := panel.call("get_acceptance_snapshot") as Dictionary
	_record("external_gap_browser_returns_named_gap", not String(gap_snapshot.get("selected_acceptance_gap", "")).is_empty(), gap_snapshot.get("selected_acceptance_gap"))
	var run_button := _find_button(root, "重新运行安全案例")
	_record("safety_case_checker_button_present", run_button != null, "重新运行安全案例")
	if run_button != null:
		run_button.pressed.emit()
		await process_frame
	var rerun := panel.call("get_acceptance_snapshot") as Dictionary
	_record("ui_runs_real_safety_case_checker", int(rerun.get("last_exit_code", -1)) == 0 and String(rerun.get("last_command_output", "")).contains("MASS_SAFETY_CASE:PASS:12/12") and bool((rerun.get("report", {}) as Dictionary).get("functional_safety_case_complete", false)), {"exit_code": rerun.get("last_exit_code"), "output": rerun.get("last_command_output")})
	var export_button := _find_button(root, "导出外部审查包")
	_record("external_review_export_button_present", export_button != null, "导出外部审查包")
	if export_button != null:
		export_button.pressed.emit()
		await process_frame
	var exported := (panel.call("get_acceptance_snapshot") as Dictionary).get("last_export", {}) as Dictionary
	var export_hashes := exported.get("files_sha256", {}) as Dictionary
	_record(
		"external_review_package_exports_exact_reviewed_bytes",
		bool(exported.get("passed", false))
		and export_hashes.size() == 3
		and export_hashes.get("user://mass_safety_case_evidence/mass_safety_case_v1.json") == FileAccess.get_sha256("res://data/verification/mass_safety_case_v1.json")
		and export_hashes.get("user://mass_safety_case_evidence/mass_safety_case_acceptance_manifest.json") == FileAccess.get_sha256("res://data/verification/mass_safety_case_acceptance_manifest.template.json")
		and export_hashes.get("user://mass_safety_case_evidence/mass_safety_case_assessment_v1.json") == FileAccess.get_sha256("res://reports/mass_safety_case_assessment_v1.json"),
		exported,
	)
	var final_snapshot := panel.call("get_acceptance_snapshot") as Dictionary
	_record("panel_never_trains_or_modifies_existing_model", final_snapshot.get("training_performed") == false and final_snapshot.get("existing_model_modified") == false and final_snapshot.get("mass_safety_certificate") == false and final_snapshot.get("production_authority") == false, final_snapshot.get("schema_version"))
	_finish(before_hashes)


func _finish(before_hashes: Dictionary) -> void:
	var after_hashes := _frozen_hashes()
	_record("motion_model_and_existing_policy_artifacts_unchanged", before_hashes == after_hashes and not before_hashes.values().has("MISSING"), {"before": before_hashes, "after": after_hashes})
	_restore_user_files()
	var payload := {
		"schema_version": "godot_safety_case_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": _errors.is_empty(),
		"passed_checks": _checks.values().filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"total_checks": _checks.size(),
		"checks": _checks,
		"errors": _errors,
		"training_performed": false,
		"existing_model_modified": false,
		"independent_review_complete": false,
		"mass_safety_certificate": false,
		"production_authority": false,
		"boundary": "Executable simulator safety-case and ODD-to-MRC acceptance only; no external legal determination, residual-risk acceptance, independent approval, certification or production authority.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("SAFETY_CASE_GODOT_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_checks"], payload["total_checks"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

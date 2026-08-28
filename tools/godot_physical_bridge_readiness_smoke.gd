extends SceneTree

const REPORT_PATH := "res://reports/godot_physical_bridge_readiness_smoke_v1.json"
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
	"user://physical_hil_evidence/physical_bridge_hil_manifest.json",
	"user://physical_hil_evidence/physical_hil_witnessed_test.csv",
	"user://physical_hil_evidence/physical_hil_runtime_profile.json",
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


func _policy_hashes() -> Dictionary:
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


func _find_button(root: Control, text: String) -> Button:
	for node in root.find_children("*", "Button", true, false):
		var button := node as Button
		if button != null and button.text == text:
			return button
	return null


func _run() -> void:
	_snapshot_user_files()
	var before_hashes := _policy_hashes()
	var scene_status := change_scene_to_file("res://main.tscn")
	_record("main_scene_load_request", scene_status == OK, scene_status)
	for _index in range(24):
		await process_frame
	var main := current_scene
	if main == null:
		_record("main_scene_ready", false, "current_scene is null")
		_finish(before_hashes)
		return
	var panel := main.get_node_or_null("ShipPhysicalBridgeReadinessPanel")
	_record("physical_bridge_readiness_panel_present", panel != null, "ShipPhysicalBridgeReadinessPanel")
	if panel == null:
		_finish(before_hashes)
		return
	var snapshot := panel.call("get_acceptance_snapshot") as Dictionary
	var report := snapshot.get("report", {}) as Dictionary
	var evaluation := report.get("evaluation", {}) as Dictionary
	var claims := report.get("claims", {}) as Dictionary
	var target_runtime := evaluation.get("target_runtime_and_witnessed_tests", {}) as Dictionary
	_record(
		"readiness_report_contract",
		String(report.get("schema_version", "")) == "physical_bridge_readiness_report_v1"
		and bool(report.get("software_readiness_gate_passed", false)),
		report.get("boundary", ""),
	)
	_record(
		"external_gates_fail_closed",
		String(evaluation.get("status", "")) == "BLOCKED_PHYSICAL_BRIDGE_EVIDENCE_INCOMPLETE"
		and claims.get("physical_hil_verified") == false
		and claims.get("site_delivery_ready") == false
		and claims.get("stcw_approved") == false
		and claims.get("dnv_certified") == false
		and claims.get("production_authority") == false,
		claims,
	)
	_record(
		"target_controller_rtos_io_and_witness_gate_present",
		target_runtime.has("section_checks")
		and target_runtime.has("dual_channel_emergency_stop_checks")
		and (target_runtime.get("required_witnessed_test_cases", []) as Array).size() == 12
		and not bool(target_runtime.get("passed", true)),
		target_runtime,
	)
	var runtime_report := snapshot.get("runtime_report", {}) as Dictionary
	var runtime_checks := runtime_report.get("checks", {}) as Dictionary
	_record(
		"target_controller_runtime_fault_campaign_passes",
		String(runtime_report.get("schema_version", "")) == "physical_hil_runtime_functional_smoke_v1"
		and bool(runtime_report.get("passed", false))
		and runtime_checks.size() == 17
		and not runtime_checks.values().has(false),
		runtime_checks,
	)
	var timing := runtime_report.get("timing", {}) as Dictionary
	_record(
		"bench_wcet_is_measured_against_deadline",
		int(timing.get("sample_count", 0)) >= 1000
		and bool(timing.get("deadline_met", false))
		and float(timing.get("maximum_ms", 99.0)) <= float(timing.get("deadline_ms", 0.0)),
		timing,
	)
	var state_coverage := runtime_report.get("state_coverage", []) as Array
	_record(
		"runtime_covers_fail_safe_state_machine",
		state_coverage.size() == 9
		and state_coverage.has("DISCONNECTED")
		and state_coverage.has("RECOVERY_PENDING")
		and state_coverage.has("DEADLINE_OVERRUN")
		and state_coverage.has("ESTOP_LATCHED"),
		state_coverage,
	)
	var estop := runtime_report.get("dual_channel_emergency_stop", {}) as Dictionary
	_record(
		"dual_estop_channels_trip_and_require_manual_key_reset",
		(estop.get("channel_a", {}) as Dictionary).values().filter(func(value: Variant) -> bool: return value is bool and bool(value)).size() == 6
		and (estop.get("channel_b", {}) as Dictionary).values().filter(func(value: Variant) -> bool: return value is bool and bool(value)).size() == 6,
		estop,
	)
	_record(
		"runtime_smoke_never_claims_physical_connection",
		runtime_report.get("target_controller_connected") == false
		and runtime_report.get("real_io_connected") == false
		and runtime_report.get("rtos_verified") == false
		and runtime_report.get("physical_hil_verified") == false
		and runtime_report.get("site_delivery_ready") == false
		and runtime_report.get("production_authority") == false
		and runtime_report.get("training_performed") == false
		and runtime_report.get("existing_model_modified") == false,
		runtime_report.get("boundary", ""),
	)
	var mapping := snapshot.get("mapping", {}) as Dictionary
	_record(
		"standards_mapping_loaded",
		String(mapping.get("schema_version", "")) == "simulator_standards_mapping_v1"
		and (mapping.get("requirements", []) as Array).size() >= 13
		and mapping.get("certification_claim_allowed") == false,
		{"requirements": (mapping.get("requirements", []) as Array).size(), "boundary": mapping.get("boundary", "")},
	)
	var option := panel.get("_requirement_option") as OptionButton
	_record("standards_requirements_browsable", option != null and option.item_count == (mapping.get("requirements", []) as Array).size(), option.item_count if option != null else -1)
	var root := panel.get("_root") as Control
	root.visible = false
	var key_event := InputEventKey.new()
	key_event.pressed = true
	key_event.physical_keycode = KEY_U
	panel.call("_unhandled_input", key_event)
	await process_frame
	_record("hotkey_U_opens_readiness_panel", root.visible, root.visible)
	var run_button := _find_button(root, "重新运行检查")
	_record("readiness_check_button_present", run_button != null, "重新运行检查")
	if run_button != null:
		run_button.pressed.emit()
		await process_frame
	var rerun := panel.call("get_acceptance_snapshot") as Dictionary
	_record(
		"ui_runs_real_readiness_checker",
		int(rerun.get("last_exit_code", -1)) == 0
		and String(rerun.get("last_command_output", "")).contains("physical bridge readiness: PASS"),
		{"exit_code": rerun.get("last_exit_code"), "output": rerun.get("last_command_output")},
	)
	var rerun_claims := (rerun.get("report", {}) as Dictionary).get("claims", {}) as Dictionary
	_record(
		"rerun_cannot_self_authorize",
		rerun_claims.get("physical_hil_verified") == false
		and rerun_claims.get("site_delivery_ready") == false
		and rerun_claims.get("dnv_certified") == false
		and rerun_claims.get("production_authority") == false,
		rerun_claims,
	)
	var runtime_button := _find_button(root, "运行 HIL 状态机烟测")
	_record("runtime_smoke_button_present", runtime_button != null, "运行 HIL 状态机烟测")
	if runtime_button != null:
		runtime_button.pressed.emit()
		await process_frame
	var runtime_rerun := panel.call("get_acceptance_snapshot") as Dictionary
	_record(
		"ui_runs_real_target_runtime_smoke",
		int(runtime_rerun.get("last_runtime_exit_code", -1)) == 0
		and String(runtime_rerun.get("last_runtime_output", "")).contains("PHYSICAL_HIL_RUNTIME_SMOKE:PASS:17/17")
		and bool((runtime_rerun.get("runtime_report", {}) as Dictionary).get("passed", false)),
		{"exit_code": runtime_rerun.get("last_runtime_exit_code"), "output": runtime_rerun.get("last_runtime_output")},
	)
	var export_button := _find_button(root, "导出现场测试模板")
	_record("site_template_export_button_present", export_button != null, "导出现场测试模板")
	if export_button != null:
		export_button.pressed.emit()
		await process_frame
	var exported := (panel.call("get_acceptance_snapshot") as Dictionary).get("last_export", {}) as Dictionary
	var export_hashes := exported.get("files_sha256", {}) as Dictionary
	_record(
		"site_templates_export_exact_reviewed_bytes",
		bool(exported.get("passed", false))
		and export_hashes.size() == 3
		and export_hashes.get("user://physical_hil_evidence/physical_bridge_hil_manifest.json") == FileAccess.get_sha256("res://data/verification/physical_bridge_hil_manifest.template.json")
		and export_hashes.get("user://physical_hil_evidence/physical_hil_witnessed_test.csv") == FileAccess.get_sha256("res://data/verification/physical_hil_witnessed_test_csv_template.csv")
		and export_hashes.get("user://physical_hil_evidence/physical_hil_runtime_profile.json") == FileAccess.get_sha256("res://data/verification/physical_hil_runtime_profile_v1.json"),
		exported,
	)
	_finish(before_hashes)


func _finish(before_hashes: Dictionary) -> void:
	var after_hashes := _policy_hashes()
	_record("motion_model_and_existing_policy_artifacts_unchanged", before_hashes == after_hashes and not before_hashes.values().has("MISSING"), {"before": before_hashes, "after": after_hashes})
	_restore_user_files()
	var payload := {
		"schema_version": "godot_physical_bridge_readiness_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": _errors.is_empty(),
		"passed_checks": _checks.values().filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"total_checks": _checks.size(),
		"checks": _checks,
		"errors": _errors,
		"training_performed": false,
		"existing_model_modified": false,
		"physical_hil_verified": false,
		"production_authority": false,
		"boundary": "Target-controller runtime, HIL manifest, standards mapping and UI refusal-gate acceptance; no physical hardware, real I/O, RTOS, external witness, certification or production authority.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("PHYSICAL_BRIDGE_READINESS_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_checks"], payload["total_checks"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

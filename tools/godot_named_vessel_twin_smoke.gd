extends SceneTree

const REPORT_PATH := "res://reports/godot_named_vessel_twin_smoke_v1.json"
const READINESS_PATH := "res://reports/named_vessel_twin_readiness_v1.json"
const FUNCTIONAL_PATH := "res://reports/named_vessel_twin_functional_smoke_v1.json"
const MANIFEST_TEMPLATE_PATH := "res://data/verification/named_vessel_twin_manifest.template.json"
const CSV_TEMPLATE_PATH := "res://data/verification/named_vessel_trial_csv_template.csv"
const USER_DIRECTORY := "user://named_vessel_twin_evidence"
const USER_FILES := [
	"user://named_vessel_twin_evidence/named_vessel_twin_manifest.json",
	"user://named_vessel_twin_evidence/named_vessel_trial_template.csv",
]
const FROZEN_PATHS := [
	"res://player.gd",
	"res://scripts/physics/catamaran_three_dof_dynamics.gd",
	"res://data/verification/catamaran_usv_dynamics_reference_v2.json",
	"res://data/rl/long_beach_ais_port_ops_benchmark_v2.json",
	"res://data/rl/port_ops_safety_supervisor_v3.json",
	"res://reports/artifacts/cargo_circuit_rl_v1/cargo_sac_policy.zip",
	"res://reports/artifacts/cargo_circuit_dynamic_rl_v2/cargo_dynamic_sac_policy.zip",
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


func _hashes() -> Dictionary:
	var result := {}
	for path in FROZEN_PATHS:
		result[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "MISSING"
	return result


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed as Dictionary if parsed is Dictionary else {}


func _snapshot_user_files() -> void:
	for path in USER_FILES:
		var record := {"existed": FileAccess.file_exists(path), "bytes": PackedByteArray()}
		if bool(record["existed"]):
			var file := FileAccess.open(path, FileAccess.READ)
			if file != null:
				record["bytes"] = file.get_buffer(file.get_length())
				file.close()
		_saved_user_files[path] = record


func _restore_user_files() -> void:
	for path in USER_FILES:
		var record := _saved_user_files.get(path, {}) as Dictionary
		if bool(record.get("existed", false)):
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file != null:
				file.store_buffer(record.get("bytes", PackedByteArray()) as PackedByteArray)
				file.close()
		elif FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(USER_DIRECTORY)):
		var directory := DirAccess.open(USER_DIRECTORY)
		if directory != null and directory.get_files().is_empty() and directory.get_directories().is_empty():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(USER_DIRECTORY))


func _run() -> void:
	_snapshot_user_files()
	var hashes_before := _hashes()
	var readiness := _read_json(READINESS_PATH)
	var functional := _read_json(FUNCTIONAL_PATH)
	_record(
		"readiness_report_fails_closed",
		String(readiness.get("schema_version", "")) == "named_vessel_twin_assessment_v1"
		and String(readiness.get("status", "")) == "BLOCKED_NAMED_VESSEL_EVIDENCE_INCOMPLETE"
		and readiness.get("named_vessel_dynamics_calibrated") == false
		and readiness.get("production_authority") == false,
		{"status": readiness.get("status"), "errors": (readiness.get("errors", []) as Array).size()},
	)
	_record(
		"functional_report_covers_seven_maneuvers",
		String(functional.get("schema_version", "")) == "named_vessel_twin_functional_smoke_v1"
		and bool(functional.get("passed", false))
		and int(functional.get("maneuver_count", 0)) == 7
		and (functional.get("trial_results", []) as Array).size() == 7,
		functional.get("maneuver_count"),
	)
	_record(
		"functional_report_covers_three_loading_conditions",
		(functional.get("loading_conditions_covered", []) as Array).size() == 3,
		functional.get("loading_conditions_covered"),
	)
	_record(
		"functional_smoke_does_not_claim_calibration",
		functional.get("training_performed") == false
		and functional.get("existing_model_modified") == false
		and functional.get("named_vessel_dynamics_calibrated") == false
		and functional.get("production_authority") == false,
		functional.get("boundary"),
	)
	var envelopes := functional.get("cross_trial_error_envelope", {}) as Dictionary
	_record(
		"cross_trial_error_envelope_is_machine_readable",
		envelopes.has("position_error_p95_m")
		and envelopes.has("heading_error_p95_deg")
		and envelopes.has("surge_speed_rmse_mps")
		and envelopes.has("yaw_rate_rmse_deg_s"),
		envelopes.keys(),
	)
	var load_envelopes := functional.get("error_envelope_by_loading_condition", {}) as Dictionary
	_record(
		"each_loading_condition_has_an_error_envelope",
		load_envelopes.has("lightship")
		and load_envelopes.has("design_payload")
		and load_envelopes.has("maximum_operating")
		and not (load_envelopes.get("lightship", {}) as Dictionary).is_empty()
		and not (load_envelopes.get("design_payload", {}) as Dictionary).is_empty()
		and not (load_envelopes.get("maximum_operating", {}) as Dictionary).is_empty(),
		load_envelopes.keys(),
	)
	var identification := functional.get("identified_parameter_summary", {}) as Dictionary
	_record(
		"cross_trial_identification_summary_is_machine_readable",
		identification.has("surge_time_constant_s")
		and identification.has("surge_speed_gain_mps_per_throttle")
		and identification.has("nomoto_time_constant_s")
		and identification.has("nomoto_gain_radps_per_rad"),
		identification.keys(),
	)
	var trial_contracts_ok := true
	for raw in functional.get("trial_results", []) as Array:
		var trial := raw as Dictionary
		trial_contracts_ok = trial_contracts_ok \
			and trial.has("maneuver_metrics") \
			and trial.has("identified_response") \
			and trial.has("error_envelope") \
			and bool(trial.get("thresholds_passed", false))
	_record("each_trial_has_metrics_identification_and_envelope", trial_contracts_ok, "seven trials")

	var scene_status := change_scene_to_file("res://main.tscn")
	_record("main_scene_load_request", scene_status == OK, scene_status)
	for _index in range(24):
		await process_frame
	var main := current_scene
	var panel := main.get_node_or_null("ShipNamedVesselTwinPanel") if main != null else null
	_record("named_vessel_panel_present", panel != null, "ShipNamedVesselTwinPanel")
	if panel == null:
		_finish(hashes_before)
		return
	var acceptance := panel.call("get_acceptance_snapshot") as Dictionary
	_record(
		"panel_receives_fail_closed_reports",
		String(acceptance.get("schema_version", "")) == "ship_named_vessel_twin_panel_snapshot_v1"
		and String(acceptance.get("readiness_status", "")) == "BLOCKED_NAMED_VESSEL_EVIDENCE_INCOMPLETE"
		and bool(acceptance.get("functional_smoke_passed", false))
		and acceptance.get("named_vessel_dynamics_calibrated") == false,
		acceptance,
	)
	var option := panel.get("_maneuver_option") as OptionButton
	_record("panel_lists_all_maneuvers", option != null and option.item_count == 7, option.item_count if option != null else -1)
	var first_selection := option.selected
	panel.call("_next_trial")
	_record("panel_cycles_trial_detail", option.selected != first_selection, {"before": first_selection, "after": option.selected})
	var labels := panel.get("_labels") as Dictionary
	var missing_before := (labels.get("missing") as Label).text
	panel.call("_next_missing")
	var missing_after := (labels.get("missing") as Label).text
	_record("panel_cycles_missing_evidence", missing_after != missing_before, {"before": missing_before, "after": missing_after})

	panel.call("_export_templates")
	acceptance = panel.call("get_acceptance_snapshot") as Dictionary
	var export := acceptance.get("last_export", {}) as Dictionary
	var manifest_user := String(export.get("manifest_path", ""))
	var csv_user := String(export.get("csv_path", ""))
	_record(
		"panel_exports_site_evidence_templates",
		bool(export.get("passed", false))
		and FileAccess.file_exists(manifest_user)
		and FileAccess.file_exists(csv_user)
		and FileAccess.get_sha256(manifest_user) == FileAccess.get_sha256(MANIFEST_TEMPLATE_PATH)
		and FileAccess.get_sha256(csv_user) == FileAccess.get_sha256(CSV_TEMPLATE_PATH),
		export,
	)
	var panel_root := panel.get("_root") as Control
	panel_root.visible = false
	var event := InputEventKey.new()
	event.pressed = true
	event.physical_keycode = KEY_G
	panel.call("_unhandled_input", event)
	await process_frame
	_record("hotkey_G_opens_named_vessel_panel", panel_root.visible, panel_root.visible)
	_finish(hashes_before)


func _finish(hashes_before: Dictionary) -> void:
	var hashes_after := _hashes()
	_record(
		"motion_model_and_existing_policy_artifacts_unchanged",
		hashes_before == hashes_after and not hashes_before.values().has("MISSING"),
		{"before": hashes_before, "after": hashes_after},
	)
	_restore_user_files()
	var payload := {
		"schema_version": "godot_named_vessel_twin_smoke_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"passed": _errors.is_empty(),
		"passed_checks": _checks.values().filter(func(item: Dictionary) -> bool: return bool(item.get("passed", false))).size(),
		"total_checks": _checks.size(),
		"checks": _checks,
		"errors": _errors,
		"training_performed": false,
		"motion_model_changed": false,
		"existing_policy_changed": false,
		"named_vessel_dynamics_calibrated": false,
		"boundary": "Functional calibration workflow acceptance only; no real named-vessel trial, parameter application, independent acceptance or production claim.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print("NAMED_VESSEL_TWIN_GODOT_SMOKE:%s:%d/%d" % ["PASS" if payload["passed"] else "FAIL", payload["passed_checks"], payload["total_checks"]])
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

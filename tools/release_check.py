#!/usr/bin/env python3
"""Verify checked-in datasets, model artifacts, and benchmark consistency."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timedelta
import hashlib
import json
from pathlib import Path
from typing import Any

from ship_rl.port_contract import validate_port_dataset


ROOT = Path(__file__).resolve().parents[1]
HOURLY = ROOT / "data/public/long_beach_open_meteo_2024_01_04_hourly.csv"
PROVENANCE = ROOT / "data/public/long_beach_open_meteo_2024_01_04.provenance.json"
DATASET = ROOT / "data/rl/long_beach_public_weather_benchmark_v1.json"
EXPERIMENT = ROOT / "data/rl/long_beach_public_weather_experiment_v1.json"
PREPARED = ROOT / "reports/navigation_benchmark_v1_prepared.json"
REPORT = ROOT / "reports/navigation_benchmark_v1.json"
PORT_DATASET = ROOT / "data/rl/long_beach_ais_port_ops_benchmark_v2.json"
PORT_EXPERIMENT = ROOT / "data/rl/long_beach_ais_port_ops_experiment_v2.json"
PORT_CONTRACT_REPORT = ROOT / "reports/port_dataset_contract_v2.json"
PORT_PREPARED = ROOT / "reports/port_ops_benchmark_v2_prepared.json"
PORT_REPORT = ROOT / "reports/port_ops_benchmark_v2.json"
SAFETY_PREPARED = ROOT / "reports/safety_supervisor_benchmark_v3_prepared.json"
SAFETY_REPORT = ROOT / "reports/safety_supervisor_benchmark_v3.json"
SAFETY_UTILITY_AUDIT = ROOT / "reports/safety_supervisor_utility_audit_v3.json"
RELIABILITY_CURRENT = ROOT / "reports/simulator_reliability_audit_v3.json"
MARITIME_ASSURANCE = ROOT / "reports/maritime_assurance_v1.json"
COLREG_COMPLEX_ASSURANCE = ROOT / "reports/colreg_complex_assurance_v2.json"
COLREG_COMPLEX_UI = ROOT / "reports/godot_colreg_complex_smoke_v1.json"
RL_GENERALIZATION_ASSURANCE = ROOT / "reports/rl_generalization_assurance_v1.json"
RL_GENERALIZATION_PLAN = ROOT / "reports/rl_generalization_evaluation_plan_v1.json"
RL_GENERALIZATION_UI = ROOT / "reports/godot_rl_generalization_smoke_v1.json"
FULL_MISSION_BRIDGE_ASSURANCE = ROOT / "reports/full_mission_bridge_assurance_v1.json"
FULL_MISSION_BRIDGE_UI = ROOT / "reports/godot_full_mission_bridge_smoke_v1.json"
MARITIME_CYBERSECURITY_ASSURANCE = ROOT / "reports/maritime_cybersecurity_assurance_v1.json"
MARITIME_CYBERSECURITY_UI = ROOT / "reports/godot_bridge_cybersecurity_smoke_v1.json"
PORT_PRODUCTION_INTEGRATION_ASSURANCE = ROOT / "reports/port_production_integration_assurance_v1.json"
PORT_PRODUCTION_INTEGRATION_UI = ROOT / "reports/godot_port_production_integration_smoke_v1.json"
FULL_VISUAL_ASSET_RELEASE = ROOT / "reports/full_visual_asset_release_v1.json"
CARGO_EVIDENCE = ROOT / "reports/cargo_circuit_public_evidence_v1.json"
ALGORITHMS = ("ppo", "sac", "td3", "dqn", "los_pid")
PORT_ALGORITHMS = (
    "ppo",
    "sac",
    "td3",
    "dqn",
    "a2c",
    "ddpg",
    "trpo",
    "los_pid",
    "lqr",
    "mpc",
)
EXPECTED_SPLITS = {"train": 60, "validation": 31, "test": 30}
REQUIRED_FILES = (
    "README.md",
    "LICENSE",
    "NOTICE",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "reports/navigation_benchmark_runtime_legacy.lock",
    ".github/workflows/rl-tests.yml",
    ".github/workflows/codeql.yml",
    ".github/workflows/dependency-review.yml",
    ".github/workflows/scorecard.yml",
    ".github/workflows/sbom.yml",
    "docs/DATA_SOURCES.md",
    "docs/ALGORITHM_PARAMETERS.md",
    "docs/PORT_ADAPTER_GUIDE.md",
    "docs/PROJECT_METRICS.md",
    "docs/SIMULATOR_METRICS.md",
    "docs/THREAT_MODEL.md",
    "docs/PRODUCTION_READINESS.md",
    "docs/MODEL_CARD.md",
    "docs/DATA_CARD.md",
    "docs/OBSERVATION_ACTION_REWARD_SPEC.md",
    "docs/TOP_SYSTEM_GAP_AUDIT.md",
    "docs/MARITIME_ASSURANCE_GUIDE.md",
    "docs/COLREG_COMPLEX_SCENARIO_ASSURANCE.md",
    "docs/RL_GENERALIZATION_ASSURANCE.md",
    "docs/FULL_MISSION_BRIDGE.md",
    "docs/MARITIME_CYBERSECURITY.md",
    "docs/PORT_PRODUCTION_INTEGRATION.md",
    "docs/ASSET_LICENSE_AUDIT.md",
    "THIRD_PARTY_ASSETS.md",
    "LICENSES/LicenseRef-User-Authorized-Public-Redistribution.txt",
    "data/verification/vessel_dynamics_reference_v1.json",
    "data/verification/colreg_encounter_catalog_v1.json",
    "data/verification/colreg_complex_scenario_catalog_v2.json",
    "data/verification/local_navigation_rules_template_v1.json",
    "data/verification/rl_generalization_campaign_v1.json",
    "data/verification/rl_generalization_results_manifest.template.json",
    "data/verification/full_mission_bridge_profile_v1.json",
    "data/verification/full_mission_bridge_acceptance_manifest.template.json",
    "data/verification/maritime_cybersecurity_profile_v1.json",
    "data/verification/maritime_cybersecurity_acceptance_manifest.template.json",
    "data/verification/bridge_secure_boot_manifest_v1.json",
    "data/verification/cyber_range_signed_update_payload_v1.json",
    "data/verification/cyber_range_signed_update_signature_v1.json",
    "data/verification/cyber_range_update_public_key_v1.pem",
    "data/verification/port_production_integration_profile_v1.json",
    "data/verification/port_production_site_acceptance_manifest.template.json",
    "data/verification/visual_asset_release_manifest_v1.json",
    "data/verification/hil_loopback_profile_v1.json",
    "data/verification/sea_trial_protocol_v1.json",
    "data/verification/sea_trial_evidence_manifest.template.json",
    "reports/navigation_benchmark_v1.md",
    "reports/godot_acceptance_v1.json",
    "reports/godot_acceptance_v3.json",
    "reports/godot_ui_navigation_smoke_v1.json",
    "reports/godot_button_inventory_v1.json",
    "reports/godot_button_interaction_smoke_v1.json",
    "reports/godot_safety_strategy_smoke_v3.json",
    "reports/simulator_reliability_audit_v1.json",
    "reports/simulator_reliability_audit_v1.md",
    "reports/simulator_reliability_audit_v3.json",
    "reports/simulator_reliability_audit_v3.md",
    "reports/maritime_assurance_v1.json",
    "reports/maritime_assurance_v1.md",
    "reports/colreg_complex_assurance_v2.json",
    "reports/colreg_complex_assurance_v2.md",
    "reports/godot_colreg_complex_smoke_v1.json",
    "reports/rl_generalization_assurance_v1.json",
    "reports/rl_generalization_assurance_v1.md",
    "reports/rl_generalization_evaluation_plan_v1.json",
    "reports/godot_rl_generalization_smoke_v1.json",
    "reports/full_mission_bridge_assurance_v1.json",
    "reports/full_mission_bridge_assurance_v1.md",
    "reports/godot_full_mission_bridge_smoke_v1.json",
    "reports/maritime_cybersecurity_assurance_v1.json",
    "reports/maritime_cybersecurity_assurance_v1.md",
    "reports/godot_bridge_cybersecurity_smoke_v1.json",
    "reports/port_production_integration_assurance_v1.json",
    "reports/port_production_integration_assurance_v1.md",
    "reports/godot_port_production_integration_smoke_v1.json",
    "reports/full_visual_asset_release_v1.json",
    "reports/full_visual_asset_release_v1.md",
    "reports/cargo_circuit_public_evidence_v1.json",
    "data/ports/port_package_manifest_v3.example.json",
    "reports/port_ops_benchmark_v2.md",
    "reports/safety_supervisor_benchmark_v3.md",
    "reports/safety_supervisor_utility_audit_v3.json",
    "reports/safety_supervisor_utility_audit_v3.md",
    "tools/build_research_core_release.py",
    "tools/run_nonmutating_deep_verify.py",
    "tools/audit_safety_supervisor_utility_v3.py",
    "tools/run_maritime_assurance.py",
    "tools/run_colreg_complex_assurance.py",
    "tools/ship_assurance/colreg_complex.py",
    "tools/godot_colreg_complex_smoke.gd",
    "tools/run_rl_generalization_assurance.py",
    "tools/ship_rl/generalization_environment.py",
    "tools/ship_rl/generalization_assurance.py",
    "tools/godot_rl_generalization_smoke.gd",
    "tools/run_full_mission_bridge_assurance.py",
    "tools/ship_assurance/full_mission_bridge.py",
    "tools/godot_full_mission_bridge_smoke.gd",
    "tools/run_maritime_cybersecurity_assurance.py",
    "tools/ship_assurance/maritime_cybersecurity.py",
    "tools/godot_bridge_cybersecurity_smoke.gd",
    "tools/run_port_production_integration_assurance.py",
    "tools/ship_assurance/port_production_integration.py",
    "tools/godot_port_production_integration_smoke.gd",
    "tools/audit_full_visual_release.py",
    "tools/build_full_visual_release.py",
    "tools/godot_button_inventory.gd",
    "tools/godot_button_interaction_smoke.gd",
    "tools/run_cargo_collision_regression.py",
    "tools/evaluate_sea_trial.py",
    "tests/test_maritime_assurance.py",
    "tests/test_colreg_complex.py",
    "tests/test_rl_generalization_assurance.py",
    "tests/test_full_mission_bridge.py",
    "tests/test_maritime_cybersecurity.py",
    "tests/test_port_production_integration.py",
    "tests/test_full_visual_asset_release.py",
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _require_file(relative: str, errors: list[str]) -> None:
    if not (ROOT / relative).is_file():
        errors.append(f"missing required release file: {relative}")


def _verify_hourly_and_splits(errors: list[str]) -> None:
    provenance = _load_json(PROVENANCE)
    dataset = _load_json(DATASET)
    with HOURLY.open("r", newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) != 2_904:
        errors.append(f"hourly row count is {len(rows)}, expected 2904")
    timestamps = [
        datetime.fromisoformat(str(row["timestamp"]).replace("Z", "+00:00"))
        for row in rows
    ]
    if timestamps:
        expected = [
            timestamps[0] + timedelta(hours=index)
            for index in range(len(timestamps))
        ]
        if timestamps != expected:
            errors.append("hourly timestamps are not a complete monotonic hourly series")
        if timestamps[0].date().isoformat() != "2024-01-01":
            errors.append("hourly series does not start on 2024-01-01")
        if timestamps[-1].date().isoformat() != "2024-04-30":
            errors.append("hourly series does not end on 2024-04-30")
    hourly_hash = _sha256(HOURLY)
    if provenance.get("hourly_sha256") != hourly_hash:
        errors.append("provenance hourly SHA-256 does not match the CSV")
    source = dataset.get("source", {})
    if source.get("hourly_sha256") != hourly_hash:
        errors.append("dataset hourly SHA-256 does not match the CSV")
    if source.get("observed_ais") is not False:
        errors.append("public benchmark must not claim observed AIS")
    if source.get("counterfactual_actions") != "simulator_only":
        errors.append("counterfactual action boundary is missing")
    split_dates: dict[str, set[str]] = {}
    for split, expected_count in EXPECTED_SPLITS.items():
        tasks = dataset.get("splits", {}).get(split, [])
        if len(tasks) != expected_count:
            errors.append(
                f"{split} contains {len(tasks)} scenarios, expected {expected_count}"
            )
        split_dates[split] = {
            str(task.get("public_forcing", {}).get("source_date", ""))
            for task in tasks
        }
        if len(split_dates[split]) != len(tasks):
            errors.append(f"{split} contains duplicate or missing source dates")
    for first, second in (("train", "validation"), ("train", "test"), ("validation", "test")):
        if split_dates[first] & split_dates[second]:
            errors.append(f"date leakage between {first} and {second}")
    if split_dates["train"] and max(split_dates["train"]) != "2024-02-29":
        errors.append("train split end date changed")
    if split_dates["validation"] and min(split_dates["validation"]) != "2024-03-01":
        errors.append("validation split start date changed")
    if split_dates["test"] and min(split_dates["test"]) != "2024-04-01":
        errors.append("test split start date changed")


def _verify_report(errors: list[str]) -> None:
    experiment = _load_json(EXPERIMENT)
    prepared = _load_json(PREPARED)
    report = _load_json(REPORT)
    if experiment.get("headless") is not True or experiment.get("render") is not False:
        errors.append("fixed experiment must train headlessly without rendering")
    required_rewards = {
        "reward_progress",
        "reward_heading",
        "reward_speed",
        "penalty_collision",
        "penalty_terrain_collision",
        "penalty_boundary",
        "penalty_proximity",
        "penalty_predicted_collision",
        "penalty_cross_track",
        "penalty_rudder",
        "penalty_action_slew",
        "penalty_step",
    }
    missing_rewards = required_rewards - set(experiment.get("rl_parameters", {}))
    if missing_rewards:
        errors.append(f"fixed reward contract is incomplete: {sorted(missing_rewards)}")
    if prepared.get("test_split_accessed") is not False:
        errors.append("prepared manifest must freeze artifacts before test access")
    if report.get("test_split_accessed") is not True:
        errors.append("final report does not record final-test access")
    if report.get("passed") is not True:
        errors.append("final reliability gate is not PASS")
    if report.get("experiment", {}).get("algorithms") != list(ALGORITHMS):
        errors.append("final report does not contain the five declared methods")
    if report.get("data", {}).get("split_sizes") != EXPECTED_SPLITS:
        errors.append("report split sizes differ from the fixed contract")
    evidence = report.get("evidence_sha256", {})
    for relative, expected_hash in evidence.items():
        path = ROOT / relative
        if not path.is_file() or _sha256(path) != expected_hash:
            errors.append(f"report evidence changed: {relative}")
    if prepared.get("evidence_sha256") != evidence:
        errors.append("prepared and final evidence inventories differ")
    results = report.get("test_results", [])
    if [item.get("algorithm") for item in results] != list(ALGORITHMS):
        errors.append("final result inventory is incomplete or reordered")
    completed = sum(int(item.get("episodes", 0)) for item in results)
    if completed != 150 or report.get("test_episode_count") != 150:
        errors.append(f"final test rollout count is {completed}, expected 150")
    for result in results:
        algorithm = str(result.get("algorithm", "unknown"))
        if result.get("dataset_split") != "test" or result.get("render_ready") is not True:
            errors.append(f"test replay boundary failed: {algorithm}")
        trajectory = ROOT / str(result.get("trajectory", ""))
        if not trajectory.is_file() or _sha256(trajectory) != result.get(
            "trajectory_sha256"
        ):
            errors.append(f"test trajectory hash failed: {algorithm}")
        elif _load_json(trajectory).get("format") != "ship_policy_test_rollout_v3":
            errors.append(f"test trajectory format failed: {algorithm}")
    artifacts = prepared.get("artifacts", [])
    if [item.get("algorithm") for item in artifacts] != list(ALGORITHMS):
        errors.append("prepared artifact inventory is incomplete or reordered")
    for artifact in artifacts:
        algorithm = str(artifact.get("algorithm", "unknown"))
        checkpoint = ROOT / str(artifact.get("checkpoint", ""))
        if not checkpoint.is_file() or _sha256(checkpoint) != artifact.get(
            "checkpoint_sha256"
        ):
            errors.append(f"checkpoint hash failed: {algorithm}")
        model_relative = artifact.get("model")
        if model_relative:
            model = ROOT / str(model_relative)
            if not model.is_file() or _sha256(model) != artifact.get("model_sha256"):
                errors.append(f"model hash failed: {algorithm}")


def _verify_port_ops_v2(errors: list[str]) -> None:
    dataset = _load_json(PORT_DATASET)
    experiment = _load_json(PORT_EXPERIMENT)
    contract = validate_port_dataset(dataset)
    checked_contract = _load_json(PORT_CONTRACT_REPORT)
    prepared = _load_json(PORT_PREPARED)
    report = _load_json(PORT_REPORT)
    if contract.get("errors"):
        errors.append(f"v2 port contract errors: {contract['errors']}")
    if contract.get("research_training_ready") is not True:
        errors.append("v2 dataset is not research-training ready")
    if contract.get("live_control_ready") is not False:
        errors.append("v2 dataset must remain fail-closed for live control")
    if checked_contract.get("dataset_file_sha256") != _sha256(PORT_DATASET):
        errors.append("v2 contract report dataset file hash changed")
    source = dataset.get("source", {})
    if source.get("observed_ais") is not True:
        errors.append("v2 dataset does not declare observed historical AIS")
    raw_files = source.get("raw_files", [])
    if len(raw_files) != 7 or any(
        len(str(item.get("sha256", ""))) != 64 for item in raw_files
    ):
        errors.append("v2 AIS seven-day source inventory is incomplete")
    if (
        experiment.get("headless") is not True
        or experiment.get("render") is not False
        or experiment.get("dataset", {}).get("observation_profile")
        != "port_ops_45"
    ):
        errors.append("v2 experiment headless/45-D boundary failed")
    if prepared.get("test_split_accessed") is not False:
        errors.append("v2 prepared report must freeze before test access")
    if report.get("test_split_accessed") is not True:
        errors.append("v2 final report does not record fixed-test access")
    if report.get("benchmark_complete") is not True:
        errors.append("v2 ten-method benchmark is incomplete")
    if report.get("experiment", {}).get("algorithms") != list(PORT_ALGORITHMS):
        errors.append("v2 report does not contain the ten declared methods")
    if int(report.get("experiment", {}).get("observation_size", 0)) != 45:
        errors.append("v2 report observation size is not 45")
    if int(report.get("experiment", {}).get("rl_timesteps_per_algorithm", 0)) < 2_000:
        errors.append("v2 coverage run is below 2,000 steps per RL method")
    if (
        report.get("experiment", {}).get("evaluation_intent")
        != "simulator factor and ten-baseline execution coverage; not an algorithm-convergence claim"
    ):
        errors.append("v2 report does not preserve its non-convergence evidence boundary")
    evidence = report.get("evidence_sha256", {})
    for relative, expected_hash in evidence.items():
        path = ROOT / relative
        if not path.is_file() or _sha256(path) != expected_hash:
            errors.append(f"v2 report evidence changed: {relative}")
    if prepared.get("evidence_sha256") != evidence:
        errors.append("v2 prepared and final evidence inventories differ")
    test_results = report.get("test_results", [])
    if [item.get("algorithm") for item in test_results] != list(PORT_ALGORITHMS):
        errors.append("v2 final result inventory is incomplete or reordered")
    expected_test = int(report.get("data", {}).get("split_sizes", {}).get("test", 0))
    completed = sum(int(item.get("episodes", 0)) for item in test_results)
    if completed != expected_test * len(PORT_ALGORITHMS):
        errors.append("v2 final test rollout count is incomplete")
    for result in test_results:
        trajectory = ROOT / str(result.get("trajectory", ""))
        if not trajectory.is_file() or _sha256(trajectory) != result.get(
            "trajectory_sha256"
        ):
            errors.append(f"v2 trajectory hash failed: {result.get('algorithm')}")
        elif _load_json(trajectory).get("format") != "ship_port_policy_test_rollout_v1":
            errors.append(f"v2 trajectory format failed: {result.get('algorithm')}")


def _verify_safety_supervisor_v3(errors: list[str]) -> None:
    prepared = _load_json(SAFETY_PREPARED)
    report = _load_json(SAFETY_REPORT)
    if prepared.get("test_split_accessed") is not False:
        errors.append("V3 safety prepared report must freeze before test access")
    if report.get("test_split_accessed") is not True:
        errors.append("V3 safety final report does not record test access")
    if report.get("benchmark_complete") is not True:
        errors.append("V3 safety ten-strategy benchmark is incomplete")
    experiment = report.get("experiment", {})
    expected_strategies = [f"{algorithm}+safety_v3" for algorithm in PORT_ALGORITHMS]
    if experiment.get("algorithms") != list(PORT_ALGORITHMS):
        errors.append("V3 safety base algorithm inventory changed")
    if experiment.get("strategy_inventory") != expected_strategies:
        errors.append("V3 additive safety strategy inventory is incomplete")
    if experiment.get("base_strategy_count") != 10 or experiment.get(
        "additive_strategy_count"
    ) != 10:
        errors.append("V3 must preserve ten base and add ten supervised strategies")
    if report.get("live_control_authorized") is not False:
        errors.append("V3 must remain unauthorized for live control")
    if report.get("deployment_decision") != "offline_research_only_fail_closed_for_live_control":
        errors.append("V3 deployment boundary changed")
    evidence = report.get("evidence_sha256", {})
    for relative, expected_hash in evidence.items():
        path = ROOT / relative
        if not path.is_file() or _sha256(path) != expected_hash:
            errors.append(f"V3 safety evidence changed: {relative}")
    if prepared.get("evidence_sha256") != evidence:
        errors.append("V3 prepared/final evidence inventories differ")
    base_artifacts = report.get("base_artifacts", [])
    if [item.get("algorithm") for item in base_artifacts] != list(PORT_ALGORITHMS):
        errors.append("V3 base policy preservation inventory is incomplete")
    for artifact in base_artifacts:
        checkpoint = ROOT / str(artifact.get("checkpoint", ""))
        if not checkpoint.is_file() or _sha256(checkpoint) != artifact.get(
            "checkpoint_sha256"
        ):
            errors.append(f"V3 base checkpoint changed: {artifact.get('algorithm')}")
        model_value = artifact.get("model")
        if model_value:
            model = ROOT / str(model_value)
            if not model.is_file() or _sha256(model) != artifact.get("model_sha256"):
                errors.append(f"V3 base model changed: {artifact.get('algorithm')}")
    test_results = report.get("test_results", [])
    if [item.get("algorithm") for item in test_results] != list(PORT_ALGORITHMS):
        errors.append("V3 test result inventory is incomplete")
    for result in test_results:
        trajectory = ROOT / str(result.get("trajectory", ""))
        if not trajectory.is_file() or _sha256(trajectory) != result.get(
            "trajectory_sha256"
        ):
            errors.append(f"V3 trajectory hash failed: {result.get('algorithm')}")
        else:
            payload = _load_json(trajectory)
            expected_format = "ship_port_policy_test_safety_v3"
            if payload.get("format") != expected_format:
                errors.append(f"V3 trajectory format failed: {result.get('algorithm')}")
            if payload.get("port_contract", {}).get("deployment_authority") is not False:
                errors.append(f"V3 trajectory authority failed: {result.get('algorithm')}")


def _verify_safety_utility_audit_v3(errors: list[str]) -> None:
    audit = _load_json(SAFETY_UTILITY_AUDIT)
    if audit.get("schema_version") != "ship_port_safety_utility_audit_v3":
        errors.append("V3 utility-aware safety audit schema changed")
    methods = audit.get("methods", [])
    if [item.get("algorithm") for item in methods] != list(PORT_ALGORITHMS):
        errors.append("V3 utility-aware safety audit strategy inventory is incomplete")
    if audit.get("live_control_authorized") is not False:
        errors.append("V3 utility-aware audit must not authorize live control")
    expected_decision = (
        "offline_research_candidate"
        if bool(audit.get("passed", False))
        else "rejected_fail_closed"
    )
    if audit.get("deployment_decision") != expected_decision:
        errors.append("V3 utility-aware admission decision is inconsistent")
    expected_sources = {
        "reports/port_ops_benchmark_v2.json": _sha256(PORT_REPORT),
        "reports/safety_supervisor_benchmark_v3.json": _sha256(SAFETY_REPORT),
    }
    if audit.get("source_reports") != expected_sources:
        errors.append("V3 utility-aware audit source hashes changed")


def _verify_maritime_assurance_v1(errors: list[str]) -> None:
    report = _load_json(MARITIME_ASSURANCE)
    if report.get("schema_version") != "maritime_assurance_report_v1":
        errors.append("maritime assurance schema changed")
    if report.get("overall", {}).get("software_assurance_passed") is not True:
        errors.append("maritime software assurance is not PASS")
    if report.get("overall", {}).get("production_authority") is not False:
        errors.append("maritime assurance must not grant production authority")
    claims = report.get("claim_matrix", {})
    required_true = (
        "three_dof_software_model_verified",
        "three_dof_rl_environment_connected",
        "colreg_scenario_regression_verified",
        "colreg_complex_scenario_regression_verified",
        "software_hil_loopback_verified",
        "sea_trial_protocol_and_refusal_gate_verified",
    )
    required_false = (
        "named_vessel_dynamics_calibrated",
        "colreg_certified",
        "physical_hil_verified",
        "real_vessel_sea_trial_completed",
    )
    for name in required_true:
        if claims.get(name) is not True:
            errors.append(f"maritime assurance claim must be true: {name}")
    for name in required_false:
        if claims.get(name) is not False:
            errors.append(f"maritime external-evidence boundary changed: {name}")
    for relative, expected_hash in report.get("inputs_sha256", {}).items():
        path = ROOT / str(relative)
        if not path.is_file() or _sha256(path) != expected_hash:
            errors.append(f"maritime assurance input changed: {relative}")
    if report.get("dynamics", {}).get("passed") is not True:
        errors.append("3-DOF dynamics acceptance is not PASS")
    if report.get("connected_environment", {}).get("passed") is not True:
        errors.append("3-DOF/COLREG RL environment connection is not PASS")
    if report.get("colreg", {}).get("passed") is not True:
        errors.append("COLREG scenario regression is not PASS")
    if report.get("colreg_complex", {}).get("passed") is not True:
        errors.append("complex COLREG scenario regression is not PASS")
    if claims.get("official_local_rules_connected") is not False:
        errors.append("official local-rule boundary changed")
    if report.get("hil", {}).get("passed") is not True:
        errors.append("HIL software loopback is not PASS")
    if report.get("sea_trial", {}).get("evidence_completeness_refusal_gate_passed") is not True:
        errors.append("sea-trial evidence-completeness refusal gate is not PASS")


def _verify_colreg_complex_v2(errors: list[str]) -> None:
    report = _load_json(COLREG_COMPLEX_ASSURANCE)
    if report.get("schema_version") != "colreg_complex_assurance_v2":
        errors.append("complex COLREG assurance schema changed")
    if report.get("functional_assurance_passed") is not True:
        errors.append("complex COLREG functional assurance is not PASS")
    legacy = report.get("legacy_v1_regression", {})
    if not (
        legacy.get("passed") is True
        and legacy.get("scenario_count") == 6
        and int(legacy.get("action_case_count", 0)) >= 11
        and legacy.get("legacy_v1_replaced") is False
    ):
        errors.append("legacy V1 COLREG baseline was not preserved")
    complex_result = report.get("complex_assurance", {})
    if not (
        complex_result.get("passed") is True
        and complex_result.get("scenario_count") == 16
        and complex_result.get("scenario_passed_count") == 16
        and complex_result.get("case_count") == 45
        and complex_result.get("case_matched_count") == 45
        and complex_result.get("coverage_complete") is True
        and complex_result.get("missing_capabilities") == []
    ):
        errors.append("complex COLREG scenario/case coverage is incomplete")
    claims = report.get("claim_matrix", {})
    for name in (
        "official_local_rules_connected",
        "colreg_certified",
        "production_authority",
    ):
        if claims.get(name) is not False:
            errors.append(f"complex COLREG external boundary changed: {name}")
    boundary = report.get("source_boundary", {})
    for name in (
        "training_performed",
        "existing_policy_modified",
        "ship_motion_model_modified",
    ):
        if boundary.get(name) is not False:
            errors.append(f"complex COLREG preservation boundary changed: {name}")
    for relative, expected_hash in report.get("inputs_sha256", {}).items():
        path = ROOT / str(relative)
        if not path.is_file() or _sha256(path) != expected_hash:
            errors.append(f"complex COLREG assurance input changed: {relative}")
    ui = _load_json(COLREG_COMPLEX_UI)
    if not (
        ui.get("schema_version") == "godot_colreg_complex_smoke_v1"
        and ui.get("passed") is True
        and ui.get("passed_count") == ui.get("check_count")
        and int(ui.get("check_count", 0)) >= 25
        and ui.get("training_performed") is False
        and ui.get("existing_policy_modified") is False
        and ui.get("ship_motion_model_modified") is False
        and ui.get("official_local_rules_connected") is False
        and ui.get("colreg_certified") is False
        and ui.get("production_authority") is False
    ):
        errors.append("complex COLREG Godot UI smoke is not PASS or crossed a boundary")


def _verify_rl_generalization_v1(errors: list[str]) -> None:
    report = _load_json(RL_GENERALIZATION_ASSURANCE)
    if report.get("schema_version") != "rl_generalization_assurance_v1":
        errors.append("RL generalization assurance schema changed")
    if report.get("functional_framework_complete") is not True:
        errors.append("RL generalization functional framework is not PASS")
    if report.get("status") != "FUNCTIONAL_FRAMEWORK_COMPLETE_TRAINING_AND_FIELD_EVIDENCE_BLOCKED":
        errors.append("RL generalization status is not fail-closed")
    checks = report.get("checks", {})
    if len(checks) != 16 or not all(value is True for value in checks.values()):
        errors.append("RL generalization framework checks are incomplete")
    domains = report.get("domain_summary", {})
    expected_domains = {
        "declared_port_archetype_count": 4,
        "real_observed_port_count": 1,
        "synthetic_port_domain_count": 3,
        "declared_season_count": 4,
        "real_observed_season_count": 1,
        "synthetic_season_overlay_count": 3,
        "vessel_family_count": 4,
        "random_seed_count": 5,
        "interactive_traffic_behavior_count": 4,
        "ood_suite_count": 4,
        "ablation_count": 6,
        "stress_case_count": 8,
    }
    for name, expected in expected_domains.items():
        if domains.get(name) != expected:
            errors.append(f"RL generalization domain count changed: {name}")
    policy_inventory = report.get("preserved_policy_inventory", {})
    if not (
        policy_inventory.get("passed") is True
        and policy_inventory.get("policy_count") == 10
        and policy_inventory.get("errors") == []
    ):
        errors.append("existing policy inventory is not hash-preserved")
    summary = report.get("evaluation_plan", {})
    plan = _load_json(RL_GENERALIZATION_PLAN)
    if not (
        summary.get("base_matrix_cell_count") == 320
        and summary.get("ablation_pair_count") == 30
        and summary.get("stress_cell_count") == 40
        and summary.get("ood_cell_count") == 20
        and summary.get("total_planned_cell_count") == 410
        and summary.get("file_sha256") == _sha256(RL_GENERALIZATION_PLAN)
        and plan.get("total_planned_cell_count") == 410
        and len(plan.get("cells", [])) == 410
        and plan.get("test_results_accessed") is False
        and plan.get("training_performed") is False
    ):
        errors.append("RL generalization frozen evaluation plan is incomplete")
    smoke = report.get("functional_smoke", {})
    shadow = report.get("shadow_receipt_smoke", {})
    if not (
        smoke.get("passed") is True
        and smoke.get("fixture_count") == 4
        and smoke.get("passed_count") == 4
        and smoke.get("training_performed") is False
        and smoke.get("existing_policy_modified") is False
        and smoke.get("ship_motion_model_modified") is False
    ):
        errors.append("RL generalization functional smoke is not PASS")
    if not (
        shadow.get("passed") is True
        and shadow.get("recommendation_count") == 4
        and shadow.get("dispatch_count") == 0
        and shadow.get("real_shadow_operation") is False
        and shadow.get("production_authority") is False
    ):
        errors.append("RL shadow receipt smoke crossed its read-only boundary")
    gate = report.get("results_evidence_gate", {})
    if not (
        gate.get("structural_contract_complete") is True
        and gate.get("training_completed") is False
        and gate.get("convergence_demonstrated") is False
        and gate.get("matrix_complete") is False
        and gate.get("confidence_intervals_complete") is False
        and gate.get("generalization_evidence_complete") is False
    ):
        errors.append("RL generalization result evidence gate did not fail closed")
    claims = report.get("claims", {})
    for name in (
        "training_performed",
        "convergence_demonstrated",
        "real_multi_port_generalization_demonstrated",
        "real_multi_season_generalization_demonstrated",
        "ood_acceptance_passed",
        "shadow_operation_completed",
        "existing_policy_modified",
        "ship_motion_model_modified",
        "production_authority",
    ):
        if claims.get(name) is not False:
            errors.append(f"RL generalization boundary changed: {name}")
    for relative, expected_hash in report.get("inputs_sha256", {}).items():
        path = ROOT / str(relative)
        if not path.is_file() or _sha256(path) != expected_hash:
            errors.append(f"RL generalization assurance input changed: {relative}")
    ui = _load_json(RL_GENERALIZATION_UI)
    if not (
        ui.get("schema_version") == "godot_rl_generalization_smoke_v1"
        and ui.get("passed") is True
        and ui.get("passed_count") == ui.get("check_count")
        and int(ui.get("check_count", 0)) >= 30
        and ui.get("training_performed") is False
        and ui.get("convergence_demonstrated") is False
        and ui.get("existing_policy_modified") is False
        and ui.get("ship_motion_model_modified") is False
        and ui.get("real_multi_port_generalization_demonstrated") is False
        and ui.get("real_multi_season_generalization_demonstrated") is False
        and ui.get("shadow_operation_completed") is False
        and ui.get("production_authority") is False
    ):
        errors.append("RL generalization Godot UI smoke is not PASS or crossed a boundary")


def _verify_full_mission_bridge_v1(errors: list[str]) -> None:
    report = _load_json(FULL_MISSION_BRIDGE_ASSURANCE)
    if report.get("schema_version") != "full_mission_bridge_assurance_v1":
        errors.append("full-mission bridge assurance schema changed")
    if report.get("status") != "FUNCTIONAL_SOFTWARE_BRIDGE_COMPLETE_EXTERNAL_ACCEPTANCE_BLOCKED":
        errors.append("full-mission bridge status is not fail-closed")
    if report.get("functional_software_bridge_complete") is not True:
        errors.append("full-mission software bridge functional gate is not PASS")
    checks = report.get("checks", {})
    if len(checks) != 13 or not all(value is True for value in checks.values()):
        errors.append("full-mission bridge framework checks are incomplete")
    profile = report.get("profile_evaluation", {})
    if not (
        profile.get("domain_count") == 10
        and len(profile.get("domain_ids", [])) == 10
        and profile.get("domain_contract_complete") is True
        and profile.get("runtime_components_present") is True
        and profile.get("gmdss_contract_complete") is True
        and profile.get("visual_contract_complete") is True
        and profile.get("multi_student_contract_complete") is True
        and profile.get("instructor_gate_complete") is True
        and profile.get("preservation_boundary_complete") is True
        and profile.get("external_claims_fail_closed") is True
    ):
        errors.append("full-mission bridge profile coverage is incomplete")
    runtime = report.get("runtime_acceptance", {})
    if not (
        runtime.get("passed") is True
        and int(runtime.get("check_count", 0)) >= 38
        and runtime.get("passed_count") == runtime.get("check_count")
        and runtime.get("file_sha256") == _sha256(FULL_MISSION_BRIDGE_UI)
    ):
        errors.append("full-mission bridge runtime acceptance is incomplete")
    policies = report.get("preserved_policy_inventory", {})
    if not (
        policies.get("passed") is True
        and policies.get("policy_count") == 10
        and policies.get("errors") == []
    ):
        errors.append("full-mission bridge did not preserve all ten policies")
    gate = report.get("external_acceptance_gate", {})
    if not (
        gate.get("schema_valid") is True
        and gate.get("evidence_package_complete") is False
        and gate.get("status") == "BLOCKED_EXTERNAL_FULL_MISSION_EVIDENCE_INCOMPLETE"
        and gate.get("physical_full_mission_bridge_verified") is False
        and gate.get("instructor_qualification_verified") is False
        and gate.get("course_approval_verified") is False
        and gate.get("production_authority") is False
        and gate.get("external_decision_required") is True
    ):
        errors.append("full-mission external acceptance gate did not fail closed")
    claims = report.get("claims", {})
    for name in (
        "training_performed",
        "ship_motion_model_modified",
        "observation_space_modified",
        "action_space_modified",
        "reward_function_modified",
        "existing_policy_modified",
        "real_radio_transmission",
        "physical_full_mission_bridge_verified",
        "type_approved_bridge_equipment",
        "instructor_qualification_verified",
        "approved_training_course",
        "production_authority",
    ):
        if claims.get(name) is not False:
            errors.append(f"full-mission bridge boundary changed: {name}")
    for relative, expected_hash in report.get("inputs_sha256", {}).items():
        path = ROOT / str(relative)
        if not path.is_file() or _sha256(path) != expected_hash:
            errors.append(f"full-mission bridge assurance input changed: {relative}")
    ui = _load_json(FULL_MISSION_BRIDGE_UI)
    if not (
        ui.get("schema_version") == "godot_full_mission_bridge_smoke_v1"
        and ui.get("passed") is True
        and ui.get("passed_count") == ui.get("check_count")
        and int(ui.get("check_count", 0)) >= 38
        and ui.get("training_performed") is False
        and ui.get("ship_motion_model_modified") is False
        and ui.get("observation_space_modified") is False
        and ui.get("action_space_modified") is False
        and ui.get("reward_function_modified") is False
        and ui.get("existing_policy_modified") is False
        and ui.get("real_radio_transmission") is False
        and ui.get("physical_360_bridge_verified") is False
        and ui.get("certified_instructor_available") is False
        and ui.get("approved_training_course") is False
        and ui.get("production_authority") is False
    ):
        errors.append("full-mission bridge Godot smoke is not PASS or crossed a boundary")


def _verify_maritime_cybersecurity_v1(errors: list[str]) -> None:
    report = _load_json(MARITIME_CYBERSECURITY_ASSURANCE)
    if report.get("schema_version") != "maritime_cybersecurity_assurance_v1":
        errors.append("maritime cybersecurity assurance schema changed")
    if report.get("status") != "FUNCTIONAL_CYBER_CONTROLS_COMPLETE_EXTERNAL_SECURITY_ASSURANCE_BLOCKED":
        errors.append("maritime cybersecurity status is not fail-closed")
    if report.get("functional_cyber_controls_complete") is not True:
        errors.append("maritime cybersecurity functional gate is not PASS")
    checks = report.get("checks", {})
    if len(checks) != 15 or not all(value is True for value in checks.values()):
        errors.append("maritime cybersecurity functional checks are incomplete")
    profile = report.get("profile_evaluation", {})
    if not (
        len(profile.get("roles", [])) == 4
        and len(profile.get("zone_ids", [])) == 7
        and profile.get("allowed_flow_count") == 8
        and profile.get("identity_contract_complete") is True
        and profile.get("zone_contract_complete") is True
        and profile.get("ids_contract_complete") is True
        and profile.get("recovery_contract_complete") is True
        and profile.get("penetration_contract_complete") is True
        and profile.get("preservation_boundary_complete") is True
        and profile.get("production_claims_fail_closed") is True
    ):
        errors.append("maritime cybersecurity profile coverage is incomplete")
    signature = report.get("signed_update_evaluation", {})
    if not (
        signature.get("passed") is True
        and signature.get("openssl_stdout") == "Verified OK"
        and signature.get("private_key_candidates") == []
        and signature.get("production_signing_key") is False
        and signature.get("hardware_backed_key") is False
    ):
        errors.append("maritime cybersecurity signed-update evidence is incomplete")
    boot = report.get("software_boot_integrity", {})
    if not (
        boot.get("passed") is True
        and int(boot.get("file_count", 0)) >= 7
        and boot.get("hardware_root_of_trust_verified") is False
        and boot.get("measured_boot_verified") is False
    ):
        errors.append("maritime cybersecurity boot allowlist crossed its software boundary")
    runtime = report.get("runtime_acceptance", {})
    if not (
        runtime.get("passed") is True
        and int(runtime.get("check_count", 0)) >= 55
        and runtime.get("passed_count") == runtime.get("check_count")
        and runtime.get("file_sha256") == _sha256(MARITIME_CYBERSECURITY_UI)
    ):
        errors.append("maritime cybersecurity runtime acceptance is incomplete")
    policies = report.get("preserved_policy_inventory", {})
    if not (
        policies.get("passed") is True
        and policies.get("policy_count") == 10
        and policies.get("errors") == []
    ):
        errors.append("maritime cybersecurity work did not preserve all ten policies")
    gate = report.get("external_acceptance_gate", {})
    if not (
        gate.get("schema_valid") is True
        and gate.get("evidence_package_complete") is False
        and gate.get("status") == "BLOCKED_EXTERNAL_CYBERSECURITY_EVIDENCE_INCOMPLETE"
        and gate.get("production_network_segmentation_verified") is False
        and gate.get("hardware_secure_boot_verified") is False
        and gate.get("production_ids_verified") is False
        and gate.get("disaster_recovery_field_verified") is False
        and gate.get("independent_penetration_test_completed") is False
        and gate.get("class_or_flag_cyber_approval") is False
        and gate.get("production_authority") is False
        and gate.get("external_decision_required") is True
    ):
        errors.append("maritime cybersecurity external evidence gate did not fail closed")
    claims = report.get("claims", {})
    if not claims or any(value is not False for value in claims.values()):
        errors.append("maritime cybersecurity claim boundary changed")
    for relative, expected_hash in report.get("inputs_sha256", {}).items():
        path = ROOT / str(relative)
        if not path.is_file() or _sha256(path) != expected_hash:
            errors.append(f"maritime cybersecurity assurance input changed: {relative}")
    ui = _load_json(MARITIME_CYBERSECURITY_UI)
    if not (
        ui.get("schema_version") == "godot_bridge_cybersecurity_smoke_v1"
        and ui.get("passed") is True
        and ui.get("passed_count") == ui.get("check_count")
        and int(ui.get("check_count", 0)) >= 55
        and all(
            ui.get(name) is False
            for name in (
                "training_performed",
                "ship_motion_model_modified",
                "observation_space_modified",
                "action_space_modified",
                "reward_function_modified",
                "existing_policy_modified",
                "network_messages_mapped_to_actuation",
                "production_network_segmentation_verified",
                "hardware_secure_boot_verified",
                "production_ids_verified",
                "disaster_recovery_field_verified",
                "independent_penetration_test_completed",
                "class_or_flag_cyber_approval",
                "production_authority",
            )
        )
    ):
        errors.append("maritime cybersecurity Godot smoke is not PASS or crossed a boundary")


def _verify_port_production_integration_v1(errors: list[str]) -> None:
    report = _load_json(PORT_PRODUCTION_INTEGRATION_ASSURANCE)
    if report.get("schema_version") != "port_production_integration_assurance_v1":
        errors.append("port production-integration assurance schema changed")
    if report.get("status") != "FUNCTIONAL_PORT_INTEGRATION_COMPLETE_EXTERNAL_SITE_ACCEPTANCE_BLOCKED":
        errors.append("port production-integration status is not fail-closed")
    if report.get("functional_port_integration_complete") is not True:
        errors.append("port production-integration functional gate is not PASS")
    checks = report.get("checks", {})
    if len(checks) != 14 or not all(value is True for value in checks.values()):
        errors.append("port production-integration functional checks are incomplete")
    profile = report.get("profile_evaluation", {})
    if not (
        profile.get("adapter_count") == 6
        and profile.get("adapter_contract_complete") is True
        and profile.get("coordination_contract_complete") is True
        and profile.get("degraded_mode_complete") is True
        and profile.get("audit_contract_complete") is True
        and profile.get("preservation_boundary_complete") is True
        and profile.get("site_claims_fail_closed") is True
    ):
        errors.append("port production-integration profile coverage is incomplete")
    runtime = report.get("runtime_acceptance", {})
    if not (
        runtime.get("passed") is True
        and int(runtime.get("check_count", 0)) >= 50
        and runtime.get("passed_count") == runtime.get("check_count")
        and runtime.get("file_sha256") == _sha256(PORT_PRODUCTION_INTEGRATION_UI)
    ):
        errors.append("port production-integration runtime acceptance is incomplete")
    policies = report.get("preserved_policy_inventory", {})
    if not (
        policies.get("passed") is True
        and policies.get("policy_count") == 10
        and policies.get("errors") == []
    ):
        errors.append("port production-integration work did not preserve all ten policies")
    gate = report.get("site_acceptance_gate", {})
    if not (
        gate.get("schema_valid") is True
        and gate.get("evidence_package_complete") is False
        and gate.get("status") == "BLOCKED_EXTERNAL_PORT_SITE_EVIDENCE_INCOMPLETE"
        and gate.get("production_authority") is False
        and gate.get("external_decision_required") is True
    ):
        errors.append("port production-integration external site gate did not fail closed")
    claims = report.get("claims", {})
    if not claims or any(value is not False for value in claims.values()):
        errors.append("port production-integration claim boundary changed")
    for relative, expected_hash in report.get("inputs_sha256", {}).items():
        path = ROOT / str(relative)
        if not path.is_file() or _sha256(path) != expected_hash:
            errors.append(f"port production-integration assurance input changed: {relative}")
    ui = _load_json(PORT_PRODUCTION_INTEGRATION_UI)
    if not (
        ui.get("schema_version") == "godot_port_production_integration_smoke_v1"
        and ui.get("passed") is True
        and ui.get("passed_count") == ui.get("check_count")
        and int(ui.get("check_count", 0)) >= 50
        and all(
            ui.get(name) is False
            for name in (
                "training_performed",
                "ship_motion_model_modified",
                "observation_space_modified",
                "action_space_modified",
                "reward_function_modified",
                "existing_policy_modified",
                "external_dispatch_performed",
                "mapped_to_vessel_actuation",
                "live_vts_connected",
                "live_tos_connected",
                "authorized_pilotage_connected",
                "authorized_tug_dispatch_connected",
                "official_berth_service_connected",
                "official_notices_connected",
                "sla_verified",
                "site_shadow_operation_completed",
                "dispatch_allowed",
                "production_authority",
            )
        )
    ):
        errors.append("port production-integration Godot smoke crossed a boundary")


def _verify_full_visual_asset_release_v1(errors: list[str], strict: bool) -> None:
    report = _load_json(FULL_VISUAL_ASSET_RELEASE)
    if report.get("schema") != "full-visual-asset-release-audit.v1":
        errors.append("full-visual asset audit schema changed")
    if report.get("status") != "FULL_VISUAL_PACKAGE_READY":
        errors.append("full-visual package is not release ready")
    summary = report.get("summary", {})
    if not (
        summary.get("passed") is True
        and summary.get("included_asset_count") == 23
        and summary.get("unregistered_media_count") == 0
        and summary.get("runtime_excluded_reference_count") == 0
        and summary.get("unresolved_included_asset_count") == 0
    ):
        errors.append("full-visual asset inventory is incomplete")
    claims = report.get("claims", {})
    if not (
        claims.get("full_visual_package_ready") is True
        and claims.get("all_included_media_hash_bound") is True
        and claims.get("excluded_local_assets_not_runtime_referenced") is True
        and claims.get("excluded_local_assets_retained_locally") is True
        and claims.get("named_vessel_dynamics_changed") is False
        and claims.get("existing_policy_artifacts_changed") is False
        and claims.get("training_performed") is False
        and claims.get("production_authority") is False
    ):
        errors.append("full-visual release boundary changed")
    if report.get("errors") != []:
        errors.append("full-visual asset audit contains blocking errors")
    try:
        try:
            from audit_full_visual_release import build_report
        except ImportError:
            from tools.audit_full_visual_release import build_report

        current = build_report()
    except (ImportError, OSError, ValueError, json.JSONDecodeError) as exc:
        errors.append(f"full-visual asset audit could not be recomputed: {exc}")
        return
    if current != report:
        errors.append("full-visual asset report is stale or modified")
    if strict and current.get("status") != "FULL_VISUAL_PACKAGE_READY":
        errors.append("strict asset gate is not PASS")


def _verify_cargo_public_artifacts(errors: list[str]) -> None:
    evidence = _load_json(CARGO_EVIDENCE)
    artifacts = evidence.get("release_scope", {}).get("public_artifact_sha256", {})
    if len(artifacts) != 11:
        errors.append("cargo public artifact inventory is incomplete")
        return
    for relative, expected_hash in artifacts.items():
        path = ROOT / str(relative)
        if not path.is_file():
            errors.append(f"missing cargo public artifact: {relative}")
        elif _sha256(path) != expected_hash:
            errors.append(f"cargo public artifact hash changed: {relative}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--strict-assets",
        action="store_true",
        help="require the current fail-closed full-visual asset audit",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    errors: list[str] = []
    for relative in REQUIRED_FILES:
        _require_file(relative, errors)
    for path in (
        HOURLY,
        PROVENANCE,
        DATASET,
        EXPERIMENT,
        PREPARED,
        REPORT,
        PORT_DATASET,
        PORT_EXPERIMENT,
        PORT_CONTRACT_REPORT,
        PORT_PREPARED,
        PORT_REPORT,
        SAFETY_PREPARED,
        SAFETY_REPORT,
        SAFETY_UTILITY_AUDIT,
        RELIABILITY_CURRENT,
        MARITIME_ASSURANCE,
        COLREG_COMPLEX_ASSURANCE,
        COLREG_COMPLEX_UI,
        RL_GENERALIZATION_ASSURANCE,
        RL_GENERALIZATION_PLAN,
        RL_GENERALIZATION_UI,
        FULL_MISSION_BRIDGE_ASSURANCE,
        FULL_MISSION_BRIDGE_UI,
        MARITIME_CYBERSECURITY_ASSURANCE,
        MARITIME_CYBERSECURITY_UI,
        PORT_PRODUCTION_INTEGRATION_ASSURANCE,
        PORT_PRODUCTION_INTEGRATION_UI,
        FULL_VISUAL_ASSET_RELEASE,
        CARGO_EVIDENCE,
    ):
        if not path.is_file():
            errors.append(f"missing benchmark evidence: {path.relative_to(ROOT)}")
    if not errors:
        _verify_hourly_and_splits(errors)
        _verify_report(errors)
        _verify_port_ops_v2(errors)
        _verify_safety_supervisor_v3(errors)
        _verify_safety_utility_audit_v3(errors)
        _verify_maritime_assurance_v1(errors)
        _verify_colreg_complex_v2(errors)
        _verify_rl_generalization_v1(errors)
        _verify_full_mission_bridge_v1(errors)
        _verify_maritime_cybersecurity_v1(errors)
        _verify_port_production_integration_v1(errors)
        _verify_full_visual_asset_release_v1(errors, arguments.strict_assets)
        _verify_cargo_public_artifacts(errors)
        reliability = _load_json(RELIABILITY_CURRENT)
        ui_navigation = _load_json(
            ROOT / "reports/godot_ui_navigation_smoke_v1.json"
        )
        safety_ui = _load_json(
            ROOT / "reports/godot_safety_strategy_smoke_v3.json"
        )
        godot_v3 = _load_json(ROOT / "reports/godot_acceptance_v3.json")
        if ui_navigation.get("passed") is not True:
            errors.append("Godot UI/navigation smoke is not PASS")
        if safety_ui.get("passed") is not True:
            errors.append("Godot Safety V3 strategy smoke is not PASS")
        if godot_v3.get("passed") is not True:
            errors.append("Godot V3 acceptance is not PASS")
        if reliability.get("schema_version") != "simulator_reliability_audit_v3":
            errors.append("current simulator reliability audit is not V3")
        if reliability.get("errors") != []:
            errors.append("current simulator reliability audit records errors")
        if reliability.get("godot_runtime_acceptance", {}).get(
            "receipt_source_hash_matches"
        ) is not True:
            errors.append("current simulator reliability audit is not bound to Godot V3")
        if reliability.get("status") != "PASS":
            errors.append("simulator reliability audit is not PASS")
        if (
            reliability.get("policy_admission_gate", {}).get("status")
            != "REJECTED_ALL"
        ):
            errors.append(
                "current fixed evidence must preserve the fail-closed "
                "controller-admission result"
            )
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        print("project integrity check: FAIL")
        return 1
    print("project integrity check: PASS")
    print("third-party asset licensing: PASS (23 hash-bound public media files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

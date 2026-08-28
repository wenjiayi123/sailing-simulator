"""Executable assurance and refusal gates for RL generalization campaigns."""

from __future__ import annotations

import hashlib
import itertools
import json
from pathlib import Path
from typing import Any, Mapping, Sequence

import numpy as np

from .generalization_environment import GeneralizationEvaluationEnv, INTERACTIVE_BEHAVIORS
from .port_ops_environment import PORT_OPS_OBSERVATION_SIZE


REQUIRED_SEASONS = {
    "season_winter_reference",
    "season_spring_overlay",
    "season_summer_overlay",
    "season_autumn_overlay",
}
REQUIRED_OOD_SUITES = {
    "ood_port_archetype",
    "ood_season_extreme",
    "ood_vessel_scale",
    "ood_compound",
}
REQUIRED_ABLATIONS = {
    "domain_randomization",
    "interactive_traffic",
    "sensor_noise",
    "wind_wave_current",
    "colreg_context",
    "safety_supervision",
}
REQUIRED_STRESS_FACTORS = {
    "traffic_count",
    "visibility_km",
    "current_speed_knots",
    "combined_weather",
    "under_keel_clearance_meters",
    "sensor_latency_ms",
    "gnss_bias_meters",
    "actuator_delay_ms",
}


def _records(value: Any) -> list[Mapping[str, Any]]:
    return [item for item in value if isinstance(item, Mapping)] if isinstance(value, list) else []


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _canonical_sha256(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _by_id(records: Sequence[Mapping[str, Any]]) -> dict[str, Mapping[str, Any]]:
    return {str(item.get("domain_id", "")): item for item in records}


def build_evaluation_plan(campaign: Mapping[str, Any]) -> dict[str, Any]:
    dimensions = campaign.get("domain_dimensions", {})
    dimensions = dimensions if isinstance(dimensions, Mapping) else {}
    ports = _records(dimensions.get("ports"))
    seasons = _records(dimensions.get("seasons"))
    vessels = _records(dimensions.get("vessel_profiles"))
    traffic = _records(dimensions.get("traffic_behaviors"))
    seeds = [int(value) for value in campaign.get("random_seeds", [])]
    base_cells: list[dict[str, Any]] = []
    combinations = itertools.product(
        enumerate(ports), enumerate(seasons), enumerate(vessels), enumerate(seeds)
    )
    for (port_index, port), (season_index, season), (vessel_index, vessel), (seed_index, seed) in combinations:
        traffic_item = traffic[(port_index + season_index + vessel_index + seed_index) % len(traffic)]
        identifiers = (
            port.get("domain_id"),
            season.get("domain_id"),
            vessel.get("domain_id"),
            traffic_item.get("domain_id"),
            seed,
        )
        base_cells.append(
            {
                "cell_id": "base-" + _canonical_sha256(identifiers)[:16],
                "kind": "base_matrix",
                "port_domain_id": identifiers[0],
                "season_domain_id": identifiers[1],
                "vessel_domain_id": identifiers[2],
                "traffic_domain_id": identifiers[3],
                "seed": seed,
                "evidence_class": (
                    "OBSERVED_REFERENCE_CELL"
                    if port.get("real_port_verified") is True
                    and season.get("real_season_verified") is True
                    else "SIMULATOR_FUNCTIONAL_DOMAIN_CELL"
                ),
                "execution_status": "NOT_RUN",
            }
        )
    ablation_pairs = [
        {
            "cell_id": f"ablation-{item.get('ablation_id')}-seed-{seed}",
            "kind": "paired_ablation",
            "ablation_id": item.get("ablation_id"),
            "factor": item.get("factor"),
            "seed": seed,
            "control_value": item.get("control_value"),
            "treatment_value": item.get("treatment_value"),
            "execution_status": "NOT_RUN",
        }
        for item, seed in itertools.product(_records(campaign.get("ablations")), seeds)
    ]
    stress_cells = [
        {
            "cell_id": f"stress-{item.get('stress_id')}-seed-{seed}",
            "kind": "stress",
            "stress_id": item.get("stress_id"),
            "factor": item.get("factor"),
            "value": item.get("value"),
            "seed": seed,
            "execution_status": "NOT_RUN",
        }
        for item, seed in itertools.product(_records(campaign.get("stress_cases")), seeds)
    ]
    ood_cells = [
        {
            "cell_id": f"ood-{item.get('suite_id')}-seed-{seed}",
            "kind": "ood",
            "suite_id": item.get("suite_id"),
            "held_out_dimension": item.get("held_out_dimension"),
            "seed": seed,
            "training_domain_ids": list(item.get("training_domain_ids", [])),
            "evaluation_domain_ids": list(item.get("evaluation_domain_ids", [])),
            "execution_status": "NOT_RUN",
        }
        for item, seed in itertools.product(_records(campaign.get("ood_suites")), seeds)
    ]
    all_cells = [*base_cells, *ablation_pairs, *stress_cells, *ood_cells]
    return {
        "schema_version": "rl_generalization_evaluation_plan_v1",
        "campaign_id": campaign.get("campaign_id"),
        "base_matrix_cell_count": len(base_cells),
        "ablation_pair_count": len(ablation_pairs),
        "stress_cell_count": len(stress_cells),
        "ood_cell_count": len(ood_cells),
        "total_planned_cell_count": len(all_cells),
        "cells": all_cells,
        "plan_sha256": _canonical_sha256(all_cells),
        "test_results_accessed": False,
        "training_performed": False,
    }


def _policy_inventory(report: Mapping[str, Any], root: Path) -> dict[str, Any]:
    records: list[dict[str, Any]] = []
    errors: list[str] = []
    for raw in _records(report.get("artifacts")):
        algorithm = str(raw.get("algorithm", ""))
        record: dict[str, Any] = {"algorithm": algorithm}
        for kind in ("checkpoint", "model"):
            relative = raw.get(kind)
            expected_hash = raw.get(f"{kind}_sha256")
            if relative is None:
                record[kind] = None
                record[f"{kind}_sha256"] = None
                continue
            path = root / str(relative)
            actual_hash = _sha256(path) if path.is_file() else None
            record[kind] = str(relative)
            record[f"{kind}_sha256"] = actual_hash
            if actual_hash != expected_hash:
                errors.append(f"{algorithm}:{kind} hash mismatch")
        records.append(record)
    algorithms = {item["algorithm"] for item in records}
    return {
        "policy_count": len(records),
        "algorithms": sorted(algorithms),
        "records": records,
        "errors": errors,
        "passed": len(records) == 10 and len(algorithms) == 10 and not errors,
    }


def _fixture_task(
    fixture: Mapping[str, Any],
    port: Mapping[str, Any],
    season: Mapping[str, Any],
    vessel: Mapping[str, Any],
    traffic: Mapping[str, Any],
) -> dict[str, Any]:
    interaction = {
        key: value
        for key, value in traffic.items()
        if key not in {"domain_id", "interactive"}
    }
    return {
        "id": fixture.get("fixture_id"),
        "start_timestamp": "2026-01-01T00:00:00Z",
        "source_track": {"mmsi": "SIMULATOR", "start_time": "2026-01-01T00:00:00Z"},
        "port_domain_id": port.get("domain_id"),
        "season_domain_id": season.get("domain_id"),
        "vessel_profile": {
            "name": vessel.get("name"),
            "vessel_type": vessel.get("ais_type_family"),
            "length_meters": vessel.get("length_meters"),
            "width_meters": vessel.get("width_meters"),
            "draft_meters": vessel.get("draft_meters"),
            "max_observed_speed_knots": vessel.get("max_observed_speed_knots"),
        },
        "start": {"x": 0.0, "z": 0.0, "heading_degrees": 0.0},
        "route": [
            {"x": 0.0, "z": 100.0, "timestamp": "2026-01-01T00:01:00Z"},
            {"x": 0.0, "z": 220.0, "timestamp": "2026-01-01T00:02:00Z"},
        ],
        "arrival_radius": 15.0,
        "boundary_half_extent": 500.0,
        "obstacles": [],
        "terrain": [],
        "dynamic_obstacles": [
            {
                "name": "interactive_target",
                "kind": "traffic",
                "shape": "circle",
                "x": 45.0,
                "z": 80.0,
                "radius": 5.0,
                "course_degrees": 270.0,
                "speed_knots": 5.0,
                "interaction": interaction,
            }
        ],
        "navigation_context": {
            "chart_depth_meters": 25.0,
            "speed_limit_knots": 8.0,
            "minimum_under_keel_clearance_meters": 1.0,
            "enforce_fairway": False,
        },
        "sea_state": {
            "wind_speed_knots": season.get("wind_speed_knots"),
            "wind_direction_degrees": 90.0,
            "wave_height_meters": season.get("wave_height_meters"),
            "wave_direction_degrees": 180.0,
            "wave_period_seconds": 7.0,
            "current_speed_knots": season.get("current_speed_knots"),
            "current_direction_degrees": 45.0,
            "visibility_km": season.get("visibility_km"),
            "tide_meters": 1.0,
        },
    }


def _smoke_config() -> dict[str, Any]:
    return {
        "schema_version": "ship_training_experiment_v3",
        "delta": 0.5,
        "rl_parameters": {
            "safe_distance": 40.0,
            "penalty_colreg_give_way": 2.0,
        },
        "environment_parameters": {
            "merge_scene_obstacles": False,
            "domain_randomization": False,
            "randomize_evaluation": False,
            "sensor_range_m": 500.0,
            "tcpa_horizon_seconds": 600.0,
            "generated_traffic_count": 0,
            "terminate_on_collision": True,
            "sensor_distance_noise_std_m": 0.0,
            "sensor_bearing_noise_degrees": 0.0,
        },
        "ships": [
            {
                "performance": {
                    "max_forward_speed": 8.0,
                    "max_reverse_speed": 2.0,
                    "acceleration": 0.2,
                    "deceleration": 0.15,
                    "brake_acceleration": 0.35,
                    "throttle_response": 0.32,
                    "rudder_response": 0.55,
                    "max_turn_rate_degrees": 8.0,
                    "low_speed_turn_factor": 0.12,
                    "reverse_turn_factor": 0.45,
                }
            }
        ],
    }


def run_functional_smoke(campaign: Mapping[str, Any]) -> dict[str, Any]:
    dimensions = campaign.get("domain_dimensions", {})
    dimensions = dimensions if isinstance(dimensions, Mapping) else {}
    ports = _by_id(_records(dimensions.get("ports")))
    seasons = _by_id(_records(dimensions.get("seasons")))
    vessels = _by_id(_records(dimensions.get("vessel_profiles")))
    traffic_behaviors = _by_id(_records(dimensions.get("traffic_behaviors")))
    results: list[dict[str, Any]] = []
    for fixture in _records(campaign.get("functional_smoke_fixtures")):
        port = ports[str(fixture.get("port_domain_id"))]
        season = seasons[str(fixture.get("season_domain_id"))]
        vessel = vessels[str(fixture.get("vessel_domain_id"))]
        traffic = traffic_behaviors[str(fixture.get("traffic_domain_id"))]
        task = _fixture_task(fixture, port, season, vessel, traffic)
        dataset = {
            "schema_version": "ship_port_dataset_v3",
            "shared_environment": {},
            "splits": {"train": [task], "validation": [task], "test": [task]},
        }
        env = GeneralizationEvaluationEnv(
            _smoke_config(),
            dataset,
            split="validation",
            max_steps=8,
            seed=int(fixture.get("seed", 0)),
            task_index=0,
        )
        observation, info = env.reset(seed=int(fixture.get("seed", 0)))
        observations_valid = observation.shape == (PORT_OPS_OBSERVATION_SIZE,) and env.observation_space.contains(observation)
        for _ in range(5):
            observation, _reward, terminated, truncated, info = env.step(
                np.asarray([0.35, 0.1], dtype=np.float32)
            )
            observations_valid = observations_valid and env.observation_space.contains(observation)
            if terminated or truncated:
                break
        receipts = env.interaction_receipts()
        receipt_chain_valid = all(
            item.get("previous_receipt_sha256")
            == ("0" * 64 if index == 0 else receipts[index - 1].get("receipt_sha256"))
            for index, item in enumerate(receipts)
        )
        results.append(
            {
                "fixture_id": fixture.get("fixture_id"),
                "port_domain_id": fixture.get("port_domain_id"),
                "season_domain_id": fixture.get("season_domain_id"),
                "vessel_domain_id": fixture.get("vessel_domain_id"),
                "traffic_domain_id": fixture.get("traffic_domain_id"),
                "seed": fixture.get("seed"),
                "observation_size": int(observation.shape[0]),
                "observations_valid": observations_valid,
                "interaction_receipt_count": len(receipts),
                "receipt_chain_valid": receipt_chain_valid,
                "receipt_head_sha256": info.get("interactive_traffic_receipt_head_sha256"),
                "own_ship_motion_model_modified": info.get("own_ship_motion_model_modified"),
                "observation_contract_modified": info.get("observation_contract_modified"),
                "action_contract_modified": info.get("action_contract_modified"),
                "policy_modified": info.get("policy_modified"),
                "passed": bool(
                    observations_valid
                    and len(receipts) > 0
                    and receipt_chain_valid
                    and info.get("own_ship_motion_model_modified") is False
                    and info.get("observation_contract_modified") is False
                    and info.get("action_contract_modified") is False
                    and info.get("policy_modified") is False
                ),
            }
        )
    return {
        "schema_version": "rl_generalization_functional_smoke_v1",
        "fixture_count": len(results),
        "passed_count": sum(int(item["passed"]) for item in results),
        "results": results,
        "passed": bool(results) and all(item["passed"] for item in results),
        "training_performed": False,
        "policy_performance_measured": False,
        "existing_policy_modified": False,
        "ship_motion_model_modified": False,
    }


def run_shadow_receipt_smoke(campaign: Mapping[str, Any]) -> dict[str, Any]:
    receipts: list[dict[str, Any]] = []
    head = "0" * 64
    for sequence, fixture in enumerate(_records(campaign.get("functional_smoke_fixtures")), start=1):
        input_snapshot = {
            "fixture_id": fixture.get("fixture_id"),
            "seed": fixture.get("seed"),
            "policy_input": [0.2, -0.1, 0.5, 0.0],
        }
        payload = {
            "sequence": sequence,
            "input_snapshot_sha256": _canonical_sha256(input_snapshot),
            "policy_adapter": "FUNCTIONAL_STUB_NO_TRAINED_POLICY",
            "recommendation": [0.35, 0.1],
            "actual_track_action": [0.3, 0.0],
            "divergence_l1": 0.15,
            "dispatch_attempted": False,
            "previous_receipt_sha256": head,
        }
        receipt_hash = _canonical_sha256(payload)
        payload["receipt_sha256"] = receipt_hash
        head = receipt_hash
        receipts.append(payload)
    return {
        "schema_version": "rl_shadow_receipt_functional_smoke_v1",
        "recommendation_count": len(receipts),
        "dispatch_count": sum(int(item["dispatch_attempted"]) for item in receipts),
        "receipts": receipts,
        "receipt_head_sha256": head,
        "passed": bool(receipts) and all(not item["dispatch_attempted"] for item in receipts),
        "real_shadow_operation": False,
        "live_data_verified": False,
        "policy_performance_measured": False,
        "production_authority": False,
    }


def _results_gate(results: Mapping[str, Any], campaign: Mapping[str, Any]) -> dict[str, Any]:
    claims = results.get("claims", {}) if isinstance(results.get("claims"), Mapping) else {}
    shadow = results.get("shadow_operation", {}) if isinstance(results.get("shadow_operation"), Mapping) else {}
    seeds = {int(item.get("seed")) for item in _records(results.get("training_runs")) if isinstance(item.get("seed"), int)}
    minimum_seeds = int(campaign.get("convergence_protocol", {}).get("minimum_random_seeds", 5))
    minimum_steps = int(campaign.get("convergence_protocol", {}).get("minimum_training_steps_per_seed", 100000))
    required_curves = set(str(value) for value in campaign.get("convergence_protocol", {}).get("required_curves", []))
    required_metrics = set(str(value) for value in campaign.get("evaluation_design", {}).get("primary_metrics", []))
    plan = build_evaluation_plan(campaign)
    training_runs = _records(results.get("training_runs"))
    base_results = _records(results.get("base_matrix_results"))
    ood_results = _records(results.get("ood_results"))
    ablation_results = _records(results.get("ablation_results"))
    stress_results = _records(results.get("stress_results"))
    confidence_intervals = results.get("confidence_intervals", {}) if isinstance(results.get("confidence_intervals"), Mapping) else {}
    real_ports = {str(value) for value in results.get("real_port_domain_ids", [])} if isinstance(results.get("real_port_domain_ids"), list) else set()
    real_seasons = {str(value) for value in results.get("real_season_domain_ids", [])} if isinstance(results.get("real_season_domain_ids"), list) else set()
    hashes_bound = all(
        isinstance(results.get(key), str) and len(str(results.get(key))) == 64
        for key in ("policy_sha256", "frozen_source_sha256", "frozen_campaign_sha256")
    )
    training_runs_complete = len(seeds) >= minimum_seeds and all(
        int(item.get("completed_timesteps", 0)) >= minimum_steps
        and required_curves <= set(str(value) for value in item.get("curve_ids", []))
        for item in training_runs
    )
    matrix_complete = (
        len(base_results) == plan["base_matrix_cell_count"]
        and len(ood_results) == plan["ood_cell_count"]
        and len(ablation_results) == plan["ablation_pair_count"]
        and len(stress_results) == plan["stress_cell_count"]
        and all(
            item.get("execution_status") == "COMPLETE" and isinstance(item.get("metrics"), Mapping)
            for item in [*base_results, *ood_results, *ablation_results, *stress_results]
        )
    )
    confidence_intervals_complete = required_metrics <= set(str(key) for key in confidence_intervals)
    structural_contract_complete = all(
        key in results
        for key in (
            "training_runs",
            "real_port_domain_ids",
            "real_season_domain_ids",
            "base_matrix_results",
            "ood_results",
            "ablation_results",
            "stress_results",
            "confidence_intervals",
            "failed_or_diverged_seeds",
            "shadow_operation",
            "claims",
        )
    )
    completed = bool(
        results.get("status") == "COMPLETE"
        and hashes_bound
        and training_runs_complete
        and matrix_complete
        and confidence_intervals_complete
        and len(real_ports) >= int(campaign.get("evaluation_design", {}).get("minimum_real_ports_for_generalization_claim", 3))
        and len(real_seasons) >= int(campaign.get("evaluation_design", {}).get("minimum_real_seasons_for_generalization_claim", 4))
        and claims.get("training_completed") is True
        and claims.get("convergence_demonstrated") is True
        and claims.get("ood_acceptance_passed") is True
        and claims.get("real_multi_port_generalization_demonstrated") is True
        and claims.get("real_multi_season_generalization_demonstrated") is True
        and shadow.get("status") == "COMPLETE"
        and int(shadow.get("days_completed", 0)) >= int(campaign.get("shadow_protocol", {}).get("minimum_days", 30))
        and int(shadow.get("scenarios_completed", 0)) >= int(campaign.get("shadow_protocol", {}).get("minimum_scenarios", 1000))
        and int(shadow.get("dispatch_count", -1)) == 0
        and isinstance(shadow.get("receipt_archive_sha256"), str)
        and len(str(shadow.get("receipt_archive_sha256"))) == 64
        and isinstance(results.get("independent_review_reference"), str)
        and bool(str(results.get("independent_review_reference")).strip())
        and claims.get("production_authority") is False
    )
    return {
        "structural_contract_complete": structural_contract_complete,
        "training_seed_count": len(seeds),
        "minimum_training_seed_count": minimum_seeds,
        "training_completed": claims.get("training_completed") is True,
        "hashes_bound": hashes_bound,
        "training_runs_complete": training_runs_complete,
        "base_matrix_result_count": len(base_results),
        "ood_result_count": len(ood_results),
        "ablation_result_count": len(ablation_results),
        "stress_result_count": len(stress_results),
        "matrix_complete": matrix_complete,
        "confidence_intervals_complete": confidence_intervals_complete,
        "real_port_domain_count": len(real_ports),
        "real_season_domain_count": len(real_seasons),
        "convergence_demonstrated": claims.get("convergence_demonstrated") is True,
        "real_multi_port_generalization_demonstrated": claims.get("real_multi_port_generalization_demonstrated") is True,
        "real_multi_season_generalization_demonstrated": claims.get("real_multi_season_generalization_demonstrated") is True,
        "ood_acceptance_passed": claims.get("ood_acceptance_passed") is True,
        "shadow_operation_completed": claims.get("shadow_operation_completed") is True,
        "production_authority": False,
        "generalization_evidence_complete": completed,
    }


def assess_generalization_campaign(
    campaign: Mapping[str, Any],
    results: Mapping[str, Any],
    *,
    root: Path,
) -> dict[str, Any]:
    dimensions = campaign.get("domain_dimensions", {})
    dimensions = dimensions if isinstance(dimensions, Mapping) else {}
    ports = _records(dimensions.get("ports"))
    seasons = _records(dimensions.get("seasons"))
    vessels = _records(dimensions.get("vessel_profiles"))
    traffic = _records(dimensions.get("traffic_behaviors"))
    seeds = [int(value) for value in campaign.get("random_seeds", [])]
    ood = _records(campaign.get("ood_suites"))
    ablations = _records(campaign.get("ablations"))
    stresses = _records(campaign.get("stress_cases"))
    base_path = root / str(campaign.get("base_dataset", {}).get("path", ""))
    policy_report_path = root / str(campaign.get("preserved_policy_report", ""))
    base_dataset = json.loads(base_path.read_text(encoding="utf-8")) if base_path.is_file() else {}
    policy_report = json.loads(policy_report_path.read_text(encoding="utf-8")) if policy_report_path.is_file() else {}
    policy_inventory = _policy_inventory(policy_report, root)
    domain_ids = {
        str(item.get("domain_id"))
        for item in [*ports, *seasons, *vessels, *traffic]
    }
    ood_leakage_free = all(
        set(str(value) for value in item.get("training_domain_ids", [])).isdisjoint(
            set(str(value) for value in item.get("evaluation_domain_ids", []))
        )
        and set(str(value) for value in item.get("training_domain_ids", [])) <= domain_ids
        and set(str(value) for value in item.get("evaluation_domain_ids", [])) <= domain_ids
        for item in ood
    )
    plan = build_evaluation_plan(campaign)
    functional_smoke = run_functional_smoke(campaign)
    shadow_smoke = run_shadow_receipt_smoke(campaign)
    checks = {
        "campaign_schema_valid": campaign.get("schema_version") == "rl_generalization_campaign_v1",
        "base_dataset_hashable_and_single_port_boundary_explicit": bool(
            base_path.is_file()
            and base_dataset.get("port", {}).get("id") == "us_lgb_long_beach"
            and campaign.get("base_dataset", {}).get("observed_port_count") == 1
            and campaign.get("claims", {}).get("real_multi_port_data_verified") is False
        ),
        "existing_ten_policy_inventory_hash_verified": policy_inventory["passed"],
        "four_port_archetypes_declared": len({str(item.get("archetype")) for item in ports}) >= 4,
        "four_seasons_declared_with_source_class": {str(item.get("domain_id")) for item in seasons} == REQUIRED_SEASONS and all(item.get("evidence_class") for item in seasons),
        "four_vessel_families_declared": len({str(item.get("ais_type_family")) for item in vessels}) >= 4,
        "five_unique_random_seeds_frozen": len(seeds) >= 5 and len(seeds) == len(set(seeds)),
        "interactive_traffic_behaviors_executable": len(traffic) >= 4 and all(item.get("interactive") is True and str(item.get("behavior")) in INTERACTIVE_BEHAVIORS for item in traffic),
        "ood_suites_disjoint_and_complete": {str(item.get("suite_id")) for item in ood} == REQUIRED_OOD_SUITES and ood_leakage_free,
        "paired_ablation_protocol_complete": {str(item.get("factor")) for item in ablations} == REQUIRED_ABLATIONS and all(item.get("paired_seed_required") is True for item in ablations),
        "stress_protocol_complete": {str(item.get("factor")) for item in stresses} == REQUIRED_STRESS_FACTORS,
        "convergence_protocol_rejects_short_smoke": bool(campaign.get("convergence_protocol", {}).get("minimum_training_steps_per_seed", 0) >= 100000 and campaign.get("convergence_protocol", {}).get("short_smoke_can_prove_convergence") is False),
        "shadow_protocol_is_read_only_and_fail_closed": bool(campaign.get("shadow_protocol", {}).get("mode") == "read_only_counterfactual" and campaign.get("shadow_protocol", {}).get("dispatch_allowed") is False and campaign.get("shadow_protocol", {}).get("shadow_operation_completed") is False),
        "evaluation_plan_is_frozen_before_execution": bool(plan["total_planned_cell_count"] == 410 and plan["test_results_accessed"] is False),
        "interactive_environment_functional_smoke_passed": functional_smoke["passed"],
        "shadow_receipt_functional_smoke_passed_without_dispatch": shadow_smoke["passed"] and shadow_smoke["dispatch_count"] == 0,
    }
    results_gate = _results_gate(results, campaign)
    functional_complete = all(checks.values())
    real_port_count = sum(int(item.get("real_port_verified") is True) for item in ports)
    real_season_count = sum(int(item.get("real_season_verified") is True) for item in seasons)
    return {
        "schema_version": "rl_generalization_assurance_v1",
        "campaign_id": campaign.get("campaign_id"),
        "functional_framework_complete": functional_complete,
        "status": (
            "GENERALIZATION_EVIDENCE_COMPLETE_EXTERNAL_REVIEW_REQUIRED"
            if results_gate["generalization_evidence_complete"]
            else "FUNCTIONAL_FRAMEWORK_COMPLETE_TRAINING_AND_FIELD_EVIDENCE_BLOCKED"
            if functional_complete
            else "FUNCTIONAL_FRAMEWORK_INCOMPLETE"
        ),
        "checks": checks,
        "domain_summary": {
            "declared_port_archetype_count": len(ports),
            "real_observed_port_count": real_port_count,
            "synthetic_port_domain_count": len(ports) - real_port_count,
            "declared_season_count": len(seasons),
            "real_observed_season_count": real_season_count,
            "synthetic_season_overlay_count": len(seasons) - real_season_count,
            "vessel_family_count": len({str(item.get("ais_type_family")) for item in vessels}),
            "random_seed_count": len(seeds),
            "interactive_traffic_behavior_count": len(traffic),
            "ood_suite_count": len(ood),
            "ablation_count": len(ablations),
            "stress_case_count": len(stresses),
        },
        "base_dataset": {
            "path": str(base_path.relative_to(root)) if base_path.is_file() else str(base_path),
            "sha256": _sha256(base_path) if base_path.is_file() else None,
            "port_id": base_dataset.get("port", {}).get("id"),
            "period": base_dataset.get("source", {}).get("period"),
            "live_data_verified": base_dataset.get("source", {}).get("live_data_verified") is True,
        },
        "preserved_policy_inventory": policy_inventory,
        "evaluation_plan": plan,
        "functional_smoke": functional_smoke,
        "shadow_receipt_smoke": shadow_smoke,
        "results_evidence_gate": results_gate,
        "claims": {
            "training_performed": False,
            "convergence_demonstrated": results_gate["convergence_demonstrated"],
            "real_multi_port_generalization_demonstrated": results_gate["real_multi_port_generalization_demonstrated"],
            "real_multi_season_generalization_demonstrated": results_gate["real_multi_season_generalization_demonstrated"],
            "ood_acceptance_passed": results_gate["ood_acceptance_passed"],
            "shadow_operation_completed": results_gate["shadow_operation_completed"],
            "existing_policy_modified": False,
            "ship_motion_model_modified": False,
            "production_authority": False,
        },
        "boundary": "Functional readiness covers campaign planning, interactive traffic, deterministic receipts and fail-closed evidence routing. No new policy was trained; synthetic domains do not prove convergence, real cross-port/cross-season generalization, shadow acceptance or production authority.",
    }

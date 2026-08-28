from __future__ import annotations

import csv
from copy import deepcopy
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from tools.ship_assurance.named_vessel_twin import (
    REQUIRED_COLUMNS,
    REQUIRED_LOADING_CONDITIONS,
    REQUIRED_MANEUVERS,
    _synthetic_trial,
    build_functional_smoke,
    evaluate_manifest,
    validate_trial_samples,
)


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "data/verification/named_vessel_twin_manifest.template.json"
DYNAMICS_PATH = ROOT / "data/verification/catamaran_usv_dynamics_reference_v2.json"


def _read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class NamedVesselTwinTests(unittest.TestCase):
    def setUp(self) -> None:
        self.template = _read(MANIFEST_PATH)
        self.config = _read(DYNAMICS_PATH)

    def test_checked_in_template_fails_closed(self) -> None:
        report = evaluate_manifest(
            self.template,
            manifest_path=MANIFEST_PATH,
            dynamics_config_path=DYNAMICS_PATH,
        )
        self.assertEqual(report["status"], "BLOCKED_NAMED_VESSEL_EVIDENCE_INCOMPLETE")
        self.assertFalse(report["evidence_package_complete"])
        self.assertEqual(set(report["missing_maneuvers"]), set(REQUIRED_MANEUVERS))
        self.assertFalse(report["named_vessel_dynamics_calibrated"])
        self.assertFalse(report["production_authority"])

    def test_functional_smoke_covers_maneuvers_and_loads_without_calibration_claim(self) -> None:
        report = build_functional_smoke(self.config, samples_per_trial=80)
        self.assertTrue(report["passed"], report)
        self.assertEqual(report["maneuver_count"], len(REQUIRED_MANEUVERS))
        self.assertEqual(set(report["loading_conditions_covered"]), set(REQUIRED_LOADING_CONDITIONS))
        self.assertEqual(
            set(report["error_envelope_by_loading_condition"]),
            set(REQUIRED_LOADING_CONDITIONS),
        )
        self.assertGreater(
            report["identified_parameter_summary"]["surge_time_constant_s"]["identified_trial_count"],
            0,
        )
        self.assertFalse(report["training_performed"])
        self.assertFalse(report["existing_model_modified"])
        self.assertFalse(report["named_vessel_dynamics_calibrated"])

    def test_trial_timestamp_contract_rejects_replay(self) -> None:
        rows = _synthetic_trial("acceleration", self.config, 20)
        rows[10]["timestamp_s"] = rows[9]["timestamp_s"]
        with self.assertRaisesRegex(ValueError, "strictly increasing"):
            validate_trial_samples(rows)

    def test_complete_simulated_package_is_candidate_only(self) -> None:
        manifest = deepcopy(self.template)
        manifest["manifest_id"] = "functional-contract-only"
        manifest["vessel_identity"] = {
            "vessel_name": "test vessel",
            "official_number_or_mmsi": "test-id",
            "builder_and_hull_number": "test-hull",
            "vessel_type": "twin-waterjet catamaran USV",
            "length_overall_m": 5.7,
            "beam_m": 2.95,
            "propulsion_description": "twin waterjet",
            "steering_description": "vectoring nozzle",
        }
        manifest["instrumentation"] = {
            key: f"test-{key}"
            for key in manifest["instrumentation"]
        }
        for item in manifest["loading_conditions"]:
            item.update(
                {
                    "displacement_kg": 1800.0,
                    "longitudinal_cg_m": 0.0,
                    "transverse_cg_m": 0.0,
                    "draft_fore_m": 0.4,
                    "draft_aft_m": 0.4,
                    "payload_description": "test payload",
                    "measurement_reference": "test measurement",
                }
            )
        manifest["acceptance_thresholds"]["minimum_samples_per_trial"] = 40
        manifest["independent_review"] = {
            "reviewer_name": "test reviewer",
            "organization": "test organization",
            "review_record_reference": "test review",
            "witnessed_trial_reference": "test witness",
        }
        with TemporaryDirectory() as directory:
            base = Path(directory)
            trials = []
            for index, maneuver in enumerate(REQUIRED_MANEUVERS):
                rows = _synthetic_trial(maneuver, self.config, 80)
                path = base / f"trial-{index}.csv"
                with path.open("w", encoding="utf-8", newline="") as handle:
                    writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
                    writer.writeheader()
                    writer.writerows(rows)
                trials.append(
                    {
                        "id": f"trial-{index}",
                        "maneuver": maneuver,
                        "loading_condition": REQUIRED_LOADING_CONDITIONS[index % 3],
                        "trial_date_utc": "2026-01-01T00:00:00Z",
                        "operator": "test operator",
                        "witness": "test witness",
                        "weather_reference": "test weather",
                        "data_file": str(path),
                        "raw_data_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    }
                )
            manifest["trials"] = trials
            manifest_path = base / "manifest.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            report = evaluate_manifest(
                manifest,
                manifest_path=manifest_path,
                dynamics_config_path=DYNAMICS_PATH,
            )
        self.assertEqual(report["status"], "CALIBRATION_CANDIDATE_READY_FOR_INDEPENDENT_ACCEPTANCE")
        self.assertTrue(report["evidence_package_complete"], report["errors"])
        self.assertEqual(len(report["trial_results"]), 7)
        self.assertEqual(
            set(report["error_envelope_by_loading_condition"]),
            set(REQUIRED_LOADING_CONDITIONS),
        )
        self.assertFalse(report["candidate_parameters_apply_automatically"])
        self.assertFalse(report["existing_model_modified"])
        self.assertFalse(report["named_vessel_dynamics_calibrated"])


if __name__ == "__main__":
    unittest.main()

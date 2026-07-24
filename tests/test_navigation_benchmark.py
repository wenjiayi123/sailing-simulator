from __future__ import annotations

import csv
import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOURLY = ROOT / "data/public/long_beach_open_meteo_2024_01_04_hourly.csv"
PROVENANCE = ROOT / "data/public/long_beach_open_meteo_2024_01_04.provenance.json"
DATASET = ROOT / "data/rl/long_beach_public_weather_benchmark_v1.json"
REPORT = ROOT / "reports/navigation_benchmark_v1.json"
RELIABILITY = ROOT / "reports/simulator_reliability_audit_v1.json"
ALGORITHMS = ["ppo", "sac", "td3", "dqn", "los_pid"]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PublicNavigationBenchmarkTests(unittest.TestCase):
    def test_public_hourly_provenance_and_temporal_splits(self) -> None:
        provenance = json.loads(PROVENANCE.read_text(encoding="utf-8"))
        dataset = json.loads(DATASET.read_text(encoding="utf-8"))
        with HOURLY.open("r", newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
        self.assertEqual(len(rows), 2_904)
        self.assertEqual(provenance["hourly_sha256"], sha256(HOURLY))
        self.assertEqual(dataset["source"]["hourly_sha256"], sha256(HOURLY))
        self.assertFalse(dataset["source"]["observed_ais"])
        self.assertEqual(dataset["source"]["counterfactual_actions"], "simulator_only")
        self.assertEqual(
            {name: len(items) for name, items in dataset["splits"].items()},
            {"train": 60, "validation": 31, "test": 30},
        )
        dates = {
            name: {
                task["public_forcing"]["source_date"]
                for task in tasks
            }
            for name, tasks in dataset["splits"].items()
        }
        self.assertFalse(dates["train"] & dates["validation"])
        self.assertFalse(dates["train"] & dates["test"])
        self.assertFalse(dates["validation"] & dates["test"])
        self.assertEqual(max(dates["train"]), "2024-02-29")
        self.assertEqual(min(dates["validation"]), "2024-03-01")
        self.assertEqual(min(dates["test"]), "2024-04-01")

    def test_final_report_has_five_methods_and_150_fixed_test_rollouts(self) -> None:
        report = json.loads(REPORT.read_text(encoding="utf-8"))
        self.assertTrue(report["passed"])
        self.assertTrue(report["test_split_accessed"])
        self.assertEqual(report["experiment"]["algorithms"], ALGORITHMS)
        self.assertEqual(report["test_episode_count"], 150)
        self.assertEqual(
            [item["algorithm"] for item in report["test_results"]],
            ALGORITHMS,
        )
        self.assertTrue(
            all(item["dataset_split"] == "test" for item in report["test_results"])
        )
        self.assertTrue(
            all(item["render_ready"] for item in report["test_results"])
        )
        sac = next(
            item for item in report["test_results"] if item["algorithm"] == "sac"
        )
        pid = next(
            item
            for item in report["test_results"]
            if item["algorithm"] == "los_pid"
        )
        self.assertEqual(sac["metrics"]["safe_completion_rate"], 1.0)
        self.assertEqual(sac["metrics"]["collision_episode_rate"], 0.0)
        self.assertAlmostEqual(
            sac["metrics"]["mean_max_cross_track_error_meters"],
            9.977360905091903,
        )
        self.assertAlmostEqual(
            pid["metrics"]["mean_minimum_clearance_meters"],
            12.012998286909854,
        )
        self.assertIn("p05_minimum_dcpa_meters", sac["metrics"])

    def test_report_evidence_hashes_match_checkout(self) -> None:
        report = json.loads(REPORT.read_text(encoding="utf-8"))
        for relative, expected in report["evidence_sha256"].items():
            path = ROOT / relative
            self.assertTrue(path.is_file(), relative)
            self.assertEqual(sha256(path), expected, relative)
        for result in report["test_results"]:
            trajectory = ROOT / result["trajectory"]
            self.assertEqual(sha256(trajectory), result["trajectory_sha256"])

    def test_simulator_reliability_audit_preserves_metric_semantics(self) -> None:
        audit = json.loads(RELIABILITY.read_text(encoding="utf-8"))
        self.assertEqual(audit["status"], "PASS")
        self.assertEqual(
            audit["scenario_coverage"]["complete_scenario_contracts"],
            121,
        )
        self.assertEqual(
            audit["scenario_coverage"]["test_route_template_counts"],
            {"harbor_approach": 10, "channel_turn": 10, "s_curve": 10},
        )
        self.assertEqual(
            audit["evidence_integrity_gate"]["episode_records_complete"],
            "150/150",
        )
        self.assertEqual(audit["replay_reliability"]["passed_rollouts"], 5)
        self.assertEqual(
            audit["policy_admission_gate"]["status"],
            "REJECTED_ALL",
        )
        self.assertEqual(audit["policy_admission_gate"]["admitted_count"], 0)
        self.assertTrue(
            all(
                item["near_miss_episode_rate"] == 1.0
                for item in audit["algorithm_test_metrics"]
            )
        )
        self.assertTrue(
            all(
                "p05_minimum_dcpa_meters" in item
                for item in audit["algorithm_test_metrics"]
            )
        )


if __name__ == "__main__":
    unittest.main()

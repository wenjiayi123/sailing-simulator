#!/usr/bin/env python3
"""Rerun frozen benchmark rollouts without writing into evidence directories."""

from __future__ import annotations

import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
import json
from pathlib import Path
import sys
import tempfile
from typing import Any, Mapping


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _temporary_root(prefix: str) -> tempfile.TemporaryDirectory[str]:
    return tempfile.TemporaryDirectory(prefix=prefix, dir=ROOT / "reports")


def verify_navigation_v1() -> int:
    from tools import run_navigation_benchmark as benchmark

    if benchmark.verify(deep=False) != 0:
        return 1
    report = _load(benchmark.FINAL_REPORT)
    errors: list[str] = []
    print("non-mutating deep verify: navigation-v1", flush=True)
    with _temporary_root(".navigation-v1-deep-") as temporary:
        temporary_root = Path(temporary)
        for artifact, expected in zip(
            report["artifacts"],
            report["test_results"],
        ):
            algorithm = str(artifact["algorithm"])
            run_dir = temporary_root / algorithm
            current = benchmark.evaluate(
                benchmark.EvaluateRequest(
                    algorithm=algorithm,
                    config_path=benchmark.CONFIG,
                    output_dir=run_dir,
                    progress_path=run_dir / "progress.json",
                    checkpoint_path=ROOT / artifact["checkpoint"],
                    trajectory_path=run_dir / "trajectory.json",
                    max_steps=benchmark.MAX_STEPS,
                    episodes=int(report["data"]["split_sizes"]["test"]),
                    seed=benchmark.SEED,
                    split="test",
                )
            )
            if current["aggregate_metrics"] != expected["metrics"]:
                errors.append(f"deep metrics differ: {algorithm}")
    return _finish("navigation-v1", errors)


def verify_port_v2() -> int:
    from tools import run_port_ops_benchmark as benchmark

    if benchmark.verify(deep=False) != 0:
        return 1
    report = _load(benchmark.FINAL_REPORT)
    errors: list[str] = []
    max_steps = int(report["experiment"]["max_steps_per_episode"])
    test_count = int(report["data"]["split_sizes"]["test"])
    print("non-mutating deep verify: port-v2", flush=True)
    with _temporary_root(".port-v2-deep-") as temporary:
        temporary_root = Path(temporary)
        for artifact, expected in zip(
            report["artifacts"],
            report["test_results"],
        ):
            algorithm = str(artifact["algorithm"])
            print(f"deep verify {algorithm}", flush=True)
            run_dir = temporary_root / algorithm
            current = benchmark.evaluate_port_ops(
                benchmark.EvaluateRequest(
                    algorithm=algorithm,
                    config_path=benchmark.CONFIG,
                    output_dir=run_dir,
                    progress_path=run_dir / "progress.json",
                    checkpoint_path=ROOT / artifact["checkpoint"],
                    trajectory_path=run_dir / "trajectory.json",
                    max_steps=max_steps,
                    episodes=test_count,
                    seed=benchmark.SEED,
                    split="test",
                )
            )
            if current["aggregate_metrics"] != expected["metrics"]:
                errors.append(f"deep metrics differ: {algorithm}")
    return _finish("port-v2", errors)


def _evaluate_safety_worker(
    artifact: Mapping[str, Any],
    max_steps: int,
    temporary_root: str,
) -> dict[str, Any]:
    from tools import run_safety_supervisor_benchmark as benchmark

    benchmark.ARTIFACT_ROOT = Path(temporary_root)
    return benchmark._evaluate_algorithm(artifact, "test", max_steps)


def verify_safety_v3(workers: int) -> int:
    from tools import run_safety_supervisor_benchmark as benchmark

    if benchmark.verify(False, workers) != 0:
        return 1
    report = _load(benchmark.FINAL)
    artifacts = _load(benchmark.V2_PREPARED)["artifacts"]
    expected_by_algorithm = {
        str(item["algorithm"]): item for item in report["test_results"]
    }
    errors: list[str] = []
    max_steps = int(report["experiment"]["max_steps_per_episode"])
    print("non-mutating deep verify: safety-v3", flush=True)
    with _temporary_root(".safety-v3-deep-") as temporary:
        with ProcessPoolExecutor(max_workers=max(1, workers)) as executor:
            futures = {
                executor.submit(
                    _evaluate_safety_worker,
                    artifact,
                    max_steps,
                    temporary,
                ): str(artifact["algorithm"])
                for artifact in artifacts
            }
            for future in as_completed(futures):
                algorithm = futures[future]
                actual = future.result()
                expected = expected_by_algorithm[algorithm]
                if actual["metrics"] != expected["metrics"]:
                    errors.append(f"deep metrics differ: {algorithm}")
                print(f"deep verify {algorithm}", flush=True)
    return _finish("safety-v3", errors)


def _finish(label: str, errors: list[str]) -> int:
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        print(f"non-mutating deep verify: FAIL ({label})")
        return 1
    print(f"non-mutating deep verify: PASS ({label})")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "benchmark",
        choices=("navigation-v1", "port-v2", "safety-v3"),
    )
    parser.add_argument("--workers", type=int, default=4)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    if arguments.benchmark == "navigation-v1":
        return verify_navigation_v1()
    if arguments.benchmark == "port-v2":
        return verify_port_v2()
    return verify_safety_v3(arguments.workers)


if __name__ == "__main__":
    raise SystemExit(main())

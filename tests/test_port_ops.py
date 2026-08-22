from __future__ import annotations

import unittest

import numpy as np

from tools.ship_rl.environment import DISCRETE_ACTIONS
from tools.ship_rl.port_contract import validate_port_dataset
from tools.ship_rl.port_ops_environment import (
    PORT_OPS_OBSERVATION_SIZE,
    PortOpsNavigationEnv,
)
from tools.ship_rl.port_ops_trainer import (
    ALGORITHMS,
    CONTROL_ALGORITHMS,
    RL_ALGORITHMS,
    _load_policy,
)
from tools.ship_rl.safety_supervisor import (
    ModelPredictiveSafetySupervisor,
    SafetySupervisorConfig,
)


def _task(identifier: str, timestamp: str, draft: float = 3.0) -> dict:
    return {
        "id": identifier,
        "start_timestamp": timestamp,
        "source_track": {
            "mmsi": identifier[-1],
            "start_time": timestamp,
        },
        "vessel_profile": {
            "length_meters": 80.0,
            "width_meters": 16.0,
            "draft_meters": draft,
            "max_observed_speed_knots": 8.0,
        },
        "start": {"x": 0.0, "z": 0.0, "heading_degrees": 0.0},
        "route": [
            {"x": 0.0, "z": 100.0, "timestamp": timestamp},
            {"x": 0.0, "z": 200.0, "timestamp": timestamp},
        ],
        "arrival_radius": 20.0,
        "boundary_half_extent": 500.0,
        "obstacles": [],
        "terrain": [],
        "dynamic_obstacles": [
            {
                "name": f"crossing_{identifier}",
                "kind": "traffic",
                "shape": "circle",
                "x": 60.0,
                "z": 80.0,
                "radius": 5.0,
                "course_degrees": 270.0,
                "speed_knots": 5.0,
            }
        ],
        "navigation_context": {
            "chart_depth_meters": 10.0,
            "speed_limit_knots": 6.0,
            "minimum_under_keel_clearance_meters": 1.0,
        },
        "sea_state": {
            "wind_speed_knots": 8.0,
            "wind_direction_degrees": 90.0,
            "wave_height_meters": 0.8,
            "wave_direction_degrees": 180.0,
            "wave_period_seconds": 7.0,
            "current_speed_knots": 0.4,
            "current_direction_degrees": 45.0,
            "visibility_km": 12.0,
            "tide_meters": 0.5,
        },
    }


def _dataset(draft: float = 3.0) -> dict:
    return {
        "schema_version": "ship_port_dataset_v3",
        "port": {
            "id": "fixture",
            "name": "Fixture Port",
            "country": "Test",
            "timezone": "UTC",
        },
        "coordinate_system": {
            "type": "local_cartesian_meters",
            "axes": "x_east_z_north",
            "origin_wgs84": {"latitude": 0.0, "longitude": 0.0},
        },
        "source": {
            "observed_ais": True,
            "filtered_ais_rows": 1000,
            "raw_files": [
                {
                    "url": "https://example.invalid/ais.csv.zst",
                    "sha256": "a" * 64,
                }
            ],
        },
        "shared_environment": {
            "terrain": [
                {
                    "name": "land",
                    "kind": "shoreline",
                    "shape": "polygon",
                    "points": [
                        {"x": 300.0, "z": 300.0},
                        {"x": 400.0, "z": 300.0},
                        {"x": 400.0, "z": 400.0},
                    ],
                    "bbox": [300.0, 300.0, 400.0, 400.0],
                }
            ],
            "obstacles": [],
            "depth_areas": [
                {
                    "name": "depth",
                    "kind": "depth_area",
                    "shape": "polygon",
                    "minimum_depth_meters": 10.0,
                    "points": [
                        {"x": -200.0, "z": -200.0},
                        {"x": 200.0, "z": -200.0},
                        {"x": 200.0, "z": 300.0},
                        {"x": -200.0, "z": 300.0},
                    ],
                    "bbox": [-200.0, -200.0, 200.0, 300.0],
                }
            ],
            "fairways": [
                {
                    "name": "fairway",
                    "kind": "fairway",
                    "shape": "polygon",
                    "points": [
                        {"x": -100.0, "z": -100.0},
                        {"x": 100.0, "z": -100.0},
                        {"x": 100.0, "z": 300.0},
                        {"x": -100.0, "z": 300.0},
                    ],
                    "bbox": [-100.0, -100.0, 100.0, 300.0],
                }
            ],
            "restricted_areas": [],
            "traffic_separation": [],
        },
        "splits": {
            "train": [_task("task_1", "2025-01-01T00:00:00Z", draft)],
            "validation": [_task("task_2", "2025-01-02T00:00:00Z", draft)],
            "test": [_task("task_3", "2025-01-03T00:00:00Z", draft)],
        },
        "live_integration": {
            "telemetry_verified": False,
            "chart_update_verified": False,
            "vessel_model_calibrated": False,
            "control_interface_certified": False,
            "human_authority_configured": False,
        },
    }


def _config() -> dict:
    return {
        "schema_version": "ship_training_experiment_v3",
        "delta": 0.5,
        "rl_parameters": {
            "safe_distance": 80.0,
            "penalty_colreg_give_way": 2.0,
        },
        "environment_parameters": {
            "merge_scene_obstacles": False,
            "domain_randomization": False,
            "sensor_range_m": 500.0,
            "tcpa_horizon_seconds": 600.0,
            "generated_traffic_count": 0,
            "terminate_on_collision": True,
        },
        "ships": [{"performance": {}}],
        "world": {"obstacles": {"rocks": [], "boxes": []}},
    }


class PortOperationsContractTests(unittest.TestCase):

    def test_safety_supervisor_passes_through_clear_low_risk_action(self) -> None:
        dataset = _dataset()
        dataset["splits"]["test"][0]["dynamic_obstacles"] = []
        env = PortOpsNavigationEnv(
            _config(), dataset, split="test", discrete_actions=False,
            max_steps=80, seed=17, task_index=0, render_mode=None,
        )
        env.reset(options={"task_index": 0})
        supervisor = ModelPredictiveSafetySupervisor(
            SafetySupervisorConfig(trigger_clearance_meters=40.0)
        )
        decision = supervisor.project(env, np.asarray([0.25, 0.0], dtype=np.float32))
        self.assertFalse(decision.intervened)
        self.assertTrue(decision.feasible)
        self.assertEqual(decision.reason, "pass_through")

    def test_safety_supervisor_intervenes_on_immediate_collision_course(self) -> None:
        dataset = _dataset()
        task = dataset["splits"]["test"][0]
        task["dynamic_obstacles"] = []
        task["obstacles"] = [
            {
                "name": "blocking_buoy",
                "kind": "buoy",
                "shape": "circle",
                "x": 0.0,
                "z": 45.0,
                "radius": 6.0,
            }
        ]
        env = PortOpsNavigationEnv(
            _config(), dataset, split="test", discrete_actions=False,
            max_steps=80, seed=19, task_index=0, render_mode=None,
        )
        env.reset(options={"task_index": 0})
        env.state[3] = 5.0
        supervisor = ModelPredictiveSafetySupervisor(
            SafetySupervisorConfig(
                trigger_clearance_meters=80.0,
                target_clearance_meters=36.0,
                hard_clearance_meters=2.0,
                horizon_steps=12,
            )
        )
        decision = supervisor.project(env, np.asarray([1.0, 0.0], dtype=np.float32))
        self.assertTrue(decision.intervened)
        self.assertLess(decision.applied_action[0], 1.0)
        self.assertGreater(decision.candidates_evaluated, 1)
        self.assertFalse(decision.predicted_collision)

    def test_safety_supervisor_maps_projected_action_back_to_dqn_space(self) -> None:
        env = PortOpsNavigationEnv(
            _config(), _dataset(), split="test", discrete_actions=True,
            max_steps=80, seed=23, task_index=0, render_mode=None,
        )
        env.reset(options={"task_index": 0})
        supervisor = ModelPredictiveSafetySupervisor()
        decision = supervisor.project(env, 8)
        action = supervisor.environment_action(env, decision)
        self.assertIsInstance(action, int)
        self.assertGreaterEqual(action, 0)
        self.assertLess(action, len(DISCRETE_ACTIONS))
    def test_real_port_contract_is_research_ready_and_live_fail_closed(self) -> None:
        report = validate_port_dataset(_dataset())
        self.assertEqual(report["errors"], [])
        self.assertTrue(report["research_training_ready"])
        self.assertFalse(report["live_control_ready"])
        self.assertEqual(report["split_sizes"], {"train": 1, "validation": 1, "test": 1})

    def test_port_environment_exposes_45_real_factor_observations(self) -> None:
        environment = PortOpsNavigationEnv(
            _config(),
            _dataset(),
            split="train",
            seed=7,
            max_steps=10,
        )
        observation, info = environment.reset()
        self.assertEqual(observation.shape, (PORT_OPS_OBSERVATION_SIZE,))
        self.assertTrue(np.all(observation <= 1.0))
        self.assertTrue(np.all(observation >= -1.0))
        self.assertEqual(info["observation_size"], PORT_OPS_OBSERVATION_SIZE)
        self.assertGreater(info["under_keel_clearance_meters"], 0.0)
        self.assertGreaterEqual(info["traffic_density"], 1)

    def test_under_keel_grounding_is_not_rewritten_as_success(self) -> None:
        environment = PortOpsNavigationEnv(
            _config(),
            _dataset(draft=12.0),
            split="train",
            seed=7,
            max_steps=10,
        )
        environment.reset()
        _observation, _reward, terminated, _truncated, info = environment.step(
            np.asarray([0.2, 0.0], dtype=np.float32)
        )
        self.assertTrue(terminated)
        self.assertGreaterEqual(info["groundings"], 1)
        self.assertGreaterEqual(info["terrain_collisions"], 1)
        self.assertFalse(info["port_compliant_success"])

    def test_ten_method_inventory_has_seven_rl_and_three_control_methods(self) -> None:
        self.assertEqual(len(RL_ALGORITHMS), 7)
        self.assertEqual(CONTROL_ALGORITHMS, ("los_pid", "lqr", "mpc"))
        self.assertEqual(len(ALGORITHMS), 10)

    def test_control_baselines_emit_finite_continuous_actions(self) -> None:
        environment = PortOpsNavigationEnv(
            _config(),
            _dataset(),
            split="train",
            seed=7,
            max_steps=10,
        )
        environment.reset()
        checkpoints = {
            "los_pid": {
                "algorithm": "los_pid",
                "controller": {"kp": 1.35, "ki": 0.015, "kd": 0.24},
            },
            "lqr": {"algorithm": "lqr", "controller": {"type": "discrete_lqr"}},
            "mpc": {
                "algorithm": "mpc",
                "controller": {"type": "receding_horizon_mpc"},
            },
        }
        for algorithm, checkpoint in checkpoints.items():
            with self.subTest(algorithm=algorithm):
                controller = _load_policy(checkpoint)
                controller.reset()
                action = controller.predict(environment)
                self.assertEqual(action.shape, (2,))
                self.assertTrue(np.all(np.isfinite(action)))
                self.assertTrue(np.all(action <= 1.0))
                self.assertTrue(np.all(action >= -1.0))


if __name__ == "__main__":
    unittest.main()

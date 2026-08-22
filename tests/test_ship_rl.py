from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
from gymnasium.utils.env_checker import check_env

from tools.ship_rl.environment import LosPidController, ShipNavigationEnv, dataset_fingerprint, load_experiment
from tools.ship_rl.trainer import EvaluateRequest, TrainRequest, evaluate, train
from tools.public_data_pipeline import normalize_ais, write_public_json_atomic


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "tests" / "fixtures" / "ship_training_config.json"


class ShipEnvironmentTests(unittest.TestCase):
    def test_public_data_writer_rejects_credential_fields(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "public.json"
            with self.assertRaisesRegex(ValueError, "sensitive field"):
                write_public_json_atomic(
                    output,
                    {"location": {"latitude": 33.73, "api_token": "not-public"}},
                )
            self.assertFalse(output.exists())
            write_public_json_atomic(
                output,
                {"location": {"latitude": 33.73, "longitude": -118.27}},
            )
            self.assertEqual(
                json.loads(output.read_text(encoding="utf-8"))["location"]["latitude"],
                33.73,
            )

    def test_environment_contract_and_split_isolation(self) -> None:
        config, dataset, dataset_path = load_experiment(CONFIG)
        self.assertEqual(dataset_path, ROOT / "data" / "rl" / "default_port_dataset.json")
        self.assertNotEqual(dataset["splits"]["train"][0]["id"], dataset["splits"]["test"][0]["id"])
        env = ShipNavigationEnv(config, dataset, split="train", max_steps=40, seed=7)
        check_env(env, skip_render_check=True)
        observation, info = env.reset(seed=7)
        self.assertEqual(observation.shape, (28,))
        self.assertEqual(info["dataset_split"], "train")
        self.assertEqual(info["observation_size"], 28)
        self.assertTrue(any(obstacle.kind == "cliff" for obstacle in env.obstacles))
        self.assertGreaterEqual(info["dynamic_obstacle_count"], 2)
        next_observation, reward, terminated, truncated, next_info = env.step(np.asarray([0.5, 0.0], dtype=np.float32))
        self.assertTrue(env.observation_space.contains(next_observation))
        self.assertIsInstance(reward, float)
        self.assertFalse(terminated and truncated)
        self.assertEqual(next_info["dataset_split"], "train")

    def test_pid_baseline_train_then_test_rollout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            checkpoint = output / "policy_checkpoint.json"
            progress = output / "training_progress.json"
            train_result = train(
                TrainRequest(
                    algorithm="los_pid",
                    config_path=CONFIG,
                    output_dir=output,
                    progress_path=progress,
                    checkpoint_path=checkpoint,
                    max_steps=80,
                )
            )
            self.assertEqual(train_result["dataset_split"], "train")
            self.assertTrue(checkpoint.exists())
            trajectory = output / "policy_test_trajectory.json"
            result = evaluate(
                EvaluateRequest(
                    algorithm="los_pid",
                    config_path=CONFIG,
                    output_dir=output,
                    progress_path=output / "evaluation_progress.json",
                    checkpoint_path=checkpoint,
                    trajectory_path=trajectory,
                    max_steps=80,
                    episodes=1,
                )
            )
            payload = json.loads(trajectory.read_text(encoding="utf-8"))
            self.assertEqual(result["dataset_split"], "test")
            self.assertEqual(payload["dataset_split"], "test")
            self.assertEqual(payload["format"], "ship_policy_test_rollout_v3")
            self.assertEqual(payload["observation_size"], 28)
            self.assertEqual(payload["playback_mode"], "recorded_test_rollout")
            self.assertGreater(len(payload["samples"]), 2)
            self.assertIn("success", payload["evaluation_metrics"])
            self.assertIn("terrain_collisions", payload["evaluation_metrics"])
            self.assertIn("safe_completion_rate", payload["aggregate_metrics"])
            self.assertIn("p95_max_cross_track_error_meters", payload["aggregate_metrics"])
            self.assertIn("p05_minimum_dcpa_meters", payload["aggregate_metrics"])
            self.assertTrue(any(item.get("kind") == "cliff" for item in payload["evaluation_obstacles"]))
            self.assertTrue(any(sample.get("dynamic_obstacles") for sample in payload["samples"]))

    def test_validation_rollout_is_not_render_ready(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            checkpoint = output / "policy_checkpoint.json"
            train(
                TrainRequest(
                    algorithm="los_pid",
                    config_path=CONFIG,
                    output_dir=output,
                    progress_path=output / "training_progress.json",
                    checkpoint_path=checkpoint,
                    max_steps=20,
                )
            )
            result = evaluate(
                EvaluateRequest(
                    algorithm="los_pid",
                    config_path=CONFIG,
                    output_dir=output,
                    progress_path=output / "validation_progress.json",
                    checkpoint_path=checkpoint,
                    trajectory_path=output / "validation_trajectory.json",
                    max_steps=20,
                    split="validation",
                )
            )
            self.assertEqual(result["dataset_split"], "validation")
            self.assertFalse(result["render_ready"])

    def test_shape_aware_terrain_envelope_and_dynamic_obstacles(self) -> None:
        config = {
            "delta": 1.0,
            "rl_parameters": {"safe_distance": 20.0},
            "environment_parameters": {
                "vessel_radius_m": 2.0,
                "obstacle_inflation_m": 0.0,
                "cliff_inflation_m": 3.0,
                "boundary_margin_m": 2.0,
                "sensor_range_m": 150.0,
                "terminate_on_collision": True,
                "merge_scene_obstacles": False,
                "domain_randomization": False,
                "generated_traffic_count": 0,
            },
            "ships": [{}],
        }
        task = {
            "id": "geometry_contract",
            "start": {"x": 0.0, "z": 0.0, "heading_degrees": 0.0},
            "route": [{"x": 0.0, "z": 100.0}],
            "boundary_half_extent": 120.0,
            "obstacles": [
                {"name": "pier", "kind": "pier", "shape": "box", "position": {"x": 30.0, "z": 20.0}, "size": {"x": 12.0, "z": 30.0}}
            ],
            "terrain": [
                {"name": "cliff", "kind": "cliff", "shape": "circle", "x": 0.0, "z": 12.0, "radius": 2.0},
                {"name": "shore", "kind": "shoreline", "shape": "polygon", "points": [{"x": -50.0, "z": 40.0}, {"x": -30.0, "z": 40.0}, {"x": -30.0, "z": 70.0}, {"x": -50.0, "z": 70.0}]},
            ],
            "dynamic_obstacles": [
                {"name": "traffic", "kind": "traffic", "shape": "circle", "x": 40.0, "z": 40.0, "radius": 4.0, "course_degrees": 90.0, "speed_knots": 10.0}
            ],
        }
        dataset = {"splits": {"train": [task], "validation": [task], "test": [task]}}
        env = ShipNavigationEnv(config, dataset, split="train", max_steps=10, seed=12)
        env.reset(seed=12)
        self.assertEqual({item.shape for item in env.obstacles}, {"circle", "box", "polygon"})
        cliff = next(item for item in env.obstacles if item.name == "cliff")
        clearance, _bearing, _x, _z = env._obstacle_distance(cliff)
        self.assertAlmostEqual(clearance, 5.0, places=5)
        polygon = next(item for item in env.obstacles if item.name == "shore")
        self.assertAlmostEqual(polygon.x, -40.0)
        self.assertAlmostEqual(polygon.z, 55.0)
        traffic = next(item for item in env.obstacles if item.name == "traffic")
        before = (traffic.x, traffic.z)
        env.step(np.asarray([0.0, 0.0], dtype=np.float32))
        self.assertNotEqual(before, (traffic.x, traffic.z))
        self.assertTrue(env.trajectory[-1]["dynamic_obstacles"])
        self.assertIn("nearest_dcpa_meters", env.trajectory[-1])
        env.state[0] = 0.0
        env.state[1] = 6.0
        env.collision_active = False
        _observation, _reward, terminated, _truncated, info = env.step(np.asarray([0.0, 0.0], dtype=np.float32))
        self.assertTrue(terminated)
        self.assertEqual(info["terrain_collisions"], 1)
        self.assertEqual(info["last_collision"]["name"], "cliff")

    def test_randomized_environment_is_reproducible_for_same_seed(self) -> None:
        config, dataset, _dataset_path = load_experiment(CONFIG)
        first = ShipNavigationEnv(config, dataset, split="train", max_steps=10, seed=91)
        second = ShipNavigationEnv(config, dataset, split="train", max_steps=10, seed=91)
        first.reset(seed=91, options={"task_index": 0})
        second.reset(seed=91, options={"task_index": 0})
        np.testing.assert_allclose(first.state, second.state)
        self.assertEqual(first.obstacle_export_records(), second.obstacle_export_records())

    def test_wind_wave_and_current_change_the_transition(self) -> None:
        base_config, dataset, _dataset_path = load_experiment(CONFIG)
        calm_config = json.loads(json.dumps(base_config))
        forced_config = json.loads(json.dumps(base_config))
        for config in (calm_config, forced_config):
            config["environment_parameters"]["domain_randomization"] = False
            config["environment_parameters"]["generated_traffic_count"] = 0
            config["environment_parameters"]["wind_leeway_factor"] = 0.02
            config["environment_parameters"]["wave_drift_mps_per_meter"] = 0.1
        task = json.loads(json.dumps(dataset["splits"]["test"][0]))
        task["sea_state"] = {
            "wind_speed_knots": 0.0,
            "wind_direction_degrees": 90.0,
            "wave_height_meters": 0.0,
            "wave_direction_degrees": 90.0,
            "wave_period_seconds": 8.0,
            "current_speed_knots": 0.0,
            "current_direction_degrees": 90.0,
        }
        calm_dataset = {
            "splits": {"train": [task], "validation": [task], "test": [task]}
        }
        forced_task = json.loads(json.dumps(task))
        forced_task["sea_state"].update(
            {
                "wind_speed_knots": 20.0,
                "wave_height_meters": 3.0,
                "current_speed_knots": 1.0,
            }
        )
        forced_dataset = {
            "splits": {
                "train": [forced_task],
                "validation": [forced_task],
                "test": [forced_task],
            }
        }
        calm = ShipNavigationEnv(calm_config, calm_dataset, split="test", seed=1)
        forced = ShipNavigationEnv(
            forced_config,
            forced_dataset,
            split="test",
            seed=1,
        )
        calm.reset(seed=1)
        forced.reset(seed=1)
        action = np.asarray([0.5, 0.0], dtype=np.float32)
        calm.step(action)
        forced.step(action)
        self.assertFalse(np.allclose(calm.state[:2], forced.state[:2]))

    def test_evaluation_rejects_changed_environment_settings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            config_payload = json.loads(CONFIG.read_text(encoding="utf-8"))
            config_payload["dataset"]["path"] = str(ROOT / "data" / "rl" / "default_port_dataset.json")
            config_path = output / "experiment.json"
            config_path.write_text(json.dumps(config_payload, ensure_ascii=False), encoding="utf-8")
            checkpoint = output / "policy_checkpoint.json"
            train(
                TrainRequest(
                    algorithm="los_pid",
                    config_path=config_path,
                    output_dir=output,
                    progress_path=output / "training_progress.json",
                    checkpoint_path=checkpoint,
                    max_steps=20,
                )
            )
            config_payload["environment_parameters"]["cliff_inflation_m"] = 18.0
            config_path.write_text(json.dumps(config_payload, ensure_ascii=False), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "environment or training configuration changed"):
                evaluate(
                    EvaluateRequest(
                        algorithm="los_pid",
                        config_path=config_path,
                        output_dir=output,
                        progress_path=output / "evaluation_progress.json",
                        checkpoint_path=checkpoint,
                        trajectory_path=output / "trajectory.json",
                        max_steps=20,
                    )
                )

    def test_public_ais_normalizer_produces_required_splits(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            result = normalize_ais(
                ROOT / "tests" / "fixtures" / "ais_sample.csv",
                output / "dataset.json",
                output / "targets.json",
                33.73,
                -118.27,
                minimum_points=3,
                maximum_vessels=20,
                bbox=None,
                environment_geojson=ROOT / "tests" / "fixtures" / "port_environment.geojson",
            )
            dataset = json.loads((output / "dataset.json").read_text(encoding="utf-8"))
            targets = json.loads((output / "targets.json").read_text(encoding="utf-8"))
            self.assertEqual(set(result["split_sizes"]), {"train", "validation", "test"})
            self.assertTrue(all(dataset["splits"][name] for name in ("train", "validation", "test")))
            self.assertEqual(dataset["schema_version"], "ship_port_dataset_v2")
            first_task = next(iter(dataset["splits"]["train"]))
            self.assertEqual(first_task["terrain"][0]["kind"], "cliff")
            self.assertEqual(first_task["obstacles"][0]["shape"], "box")
            self.assertEqual(dataset["source"]["environment_geojson"]["feature_count"], 2)
            self.assertEqual(targets["format"], "ship_ais_targets_v1")
            self.assertEqual(len(targets["targets"]), 3)


if __name__ == "__main__":
    unittest.main()

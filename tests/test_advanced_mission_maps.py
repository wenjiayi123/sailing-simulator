from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = ROOT / "data/ports/default_port_profile.json"

ADVANCED_SCENARIOS = {
    "auto_berthing": "berthing",
    "auto_unberthing": "unberthing",
    "narrow_channel_head_on": "head_on",
    "crossing_starboard": "crossing_give_way",
    "narrow_channel_overtaking": "overtaking",
}

ADVANCED_MISSION_CODES = {
    "AUTO-BERTHING-BENCHMARK",
    "AUTO-UNBERTHING-BENCHMARK",
    "COLREG-HEAD-ON-CHANNEL",
    "COLREG-CROSSING-GIVE-WAY",
    "COLREG-OVERTAKING-CHANNEL",
}


class AdvancedMissionMapContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.profile = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))
        cls.scenarios = cls.profile["scenarios"]

    def test_profile_exposes_seven_runtime_scenarios(self) -> None:
        order = self.profile["scenario_order"]
        self.assertEqual(len(order), 7)
        self.assertEqual(set(order), set(self.scenarios))
        for key, task_type in ADVANCED_SCENARIOS.items():
            self.assertEqual(self.scenarios[key]["task_type"], task_type)

    def test_navigation_panel_receives_all_advanced_missions(self) -> None:
        missions = self.profile["navigation_missions"]
        codes = {mission["code"] for mission in missions}
        self.assertTrue(ADVANCED_MISSION_CODES.issubset(codes))
        by_scenario = {mission["scenario_key"]: mission for mission in missions}
        for scenario_key in ADVANCED_SCENARIOS:
            self.assertIn(scenario_key, by_scenario)
            self.assertGreaterEqual(len(by_scenario[scenario_key]["route"]), 5)

    def test_every_advanced_task_owns_a_distinct_dedicated_scene(self) -> None:
        scene_paths: set[str] = set()
        for scenario_key in ADVANCED_SCENARIOS:
            scene_path = self.scenarios[scenario_key].get("dedicated_scene_path", "")
            self.assertTrue(scene_path.startswith("res://scenes/worlds/tasks/"))
            self.assertTrue(scene_path.endswith("_task_scene.tscn"))
            local_path = ROOT / scene_path.removeprefix("res://")
            self.assertTrue(local_path.is_file(), msg=f"missing {local_path}")
            source = local_path.read_text(encoding="utf-8")
            self.assertIn(f'scene_key = "{scenario_key}"', source)
            scene_paths.add(scene_path)
        self.assertEqual(len(scene_paths), len(ADVANCED_SCENARIOS))

    def test_every_advanced_task_uses_a_vertical_landline_wallpaper_profile(self) -> None:
        wallpaper_paths: set[str] = set()
        for scenario_key in ADVANCED_SCENARIOS:
            profile = self.scenarios[scenario_key].get("visual_profile", {})
            self.assertEqual(profile.get("wall_orientation"), "vertical")
            self.assertEqual(float(profile.get("wall_tilt_degrees", -1.0)), 0.0)
            self.assertEqual(
                profile.get("wallpaper_bottom_composition"), "landline_at_bottom"
            )
            self.assertLessEqual(
                float(profile.get("wallpaper_sea_band_max_fraction", 1.0)), 0.03
            )
            wallpaper_path = str(profile.get("wallpaper_texture", ""))
            water_path = str(profile.get("water_texture", ""))
            self.assertTrue((ROOT / wallpaper_path.removeprefix("res://")).is_file())
            self.assertTrue((ROOT / water_path.removeprefix("res://")).is_file())
            wallpaper_paths.add(wallpaper_path)
        self.assertEqual(len(wallpaper_paths), len(ADVANCED_SCENARIOS))

    def test_dedicated_scene_keeps_shared_backdrop_but_disables_legacy_obstacles(self) -> None:
        controller = (ROOT / "scripts/world/ship_scenario_controller.gd").read_text(
            encoding="utf-8"
        )
        guard = (ROOT / "scripts/world/large_rock_collision_guard.gd").read_text(
            encoding="utf-8"
        )
        builder = (ROOT / "scripts/world/ship_dedicated_task_scene.gd").read_text(
            encoding="utf-8"
        )
        background_controller = (
            ROOT / "scripts/world/ship_background_wallpaper_controller.gd"
        ).read_text(encoding="utf-8")
        self.assertIn("func _activate_visual_scene", controller)
        self.assertIn("set_base_environment_active", controller)
        self.assertIn("body.collision_layer = 0", guard)
        self.assertIn("body.collision_mask = 0", guard)
        self.assertIn('"task_specific_wallpaper_and_water"', builder)
        self.assertIn('"uses_legacy_rock_environment": false', builder)
        self.assertIn(
            'const VERTICAL_WALL_STATUS := "VERTICAL_LOCKED"',
            background_controller,
        )
        self.assertIn("func _enforce_vertical_wall_transforms", background_controller)

    def test_camera_pitch_keys_no_longer_conflict_with_colreg_panel(self) -> None:
        player = (ROOT / "player.gd").read_text(encoding="utf-8")
        panel = (ROOT / "scripts/ui/ship_colreg_complex_panel.gd").read_text(
            encoding="utf-8"
        )
        self.assertIn("Input.is_key_pressed(KEY_R)", player)
        self.assertIn("Input.is_key_pressed(KEY_F)", player)
        self.assertIn("const TOGGLE_PANEL_KEY := KEY_F9", panel)
        self.assertNotIn("const TOGGLE_PANEL_KEY := KEY_R", panel)

    def test_routes_spawns_traffic_and_obstacles_stay_inside_boundaries(self) -> None:
        for key, scenario in self.scenarios.items():
            extent = float(scenario["boundary_half_extent"])
            positions = [scenario["spawn"], *scenario["route"], *scenario.get("rocks", [])]
            positions.extend(item["spawn"] for item in scenario.get("traffic", []))
            for position in positions:
                with self.subTest(scenario=key, position=position):
                    self.assertLessEqual(abs(float(position["x"])), extent)
                    self.assertLessEqual(abs(float(position["z"])), extent)
            for box in scenario.get("boxes", []):
                size = box["size"]
                position = box["position"]
                self.assertGreater(float(size["x"]), 0.0)
                self.assertGreater(float(size["y"]), 0.0)
                self.assertGreater(float(size["z"]), 0.0)
                self.assertLessEqual(abs(float(position["x"])) + float(size["x"]) / 2.0, extent)
                self.assertLessEqual(abs(float(position["z"])) + float(size["z"]) / 2.0, extent)

    def test_berthing_and_unberthing_have_measurable_inertia_gates(self) -> None:
        berthing = self.scenarios["auto_berthing"]["evaluation"]
        self.assertEqual(
            set(berthing),
            {
                "berth_target",
                "position_tolerance_m",
                "heading_tolerance_degrees",
                "maximum_speed_knots",
                "maximum_sway_mps",
            },
        )
        self.assertLessEqual(float(berthing["maximum_speed_knots"]), 1.0)
        self.assertLessEqual(float(berthing["maximum_sway_mps"]), 0.25)
        unberthing = self.scenarios["auto_unberthing"]["evaluation"]
        self.assertGreaterEqual(float(unberthing["minimum_clear_distance_m"]), 100.0)
        self.assertLessEqual(float(unberthing["maximum_exit_speed_knots"]), 5.0)

    def test_each_colreg_encounter_has_deterministic_traffic_and_cpa_gate(self) -> None:
        encounter_keys = (
            "narrow_channel_head_on",
            "crossing_starboard",
            "narrow_channel_overtaking",
        )
        traffic_ids: set[str] = set()
        for key in encounter_keys:
            scenario = self.scenarios[key]
            traffic = scenario["traffic"]
            self.assertEqual(len(traffic), 1)
            traffic_ids.add(traffic[0]["id"])
            self.assertGreater(float(traffic[0]["throttle"]), 0.0)
            self.assertGreaterEqual(len(scenario["colreg_rule_ids"]), 2)
            evaluation = scenario["evaluation"]
            self.assertGreaterEqual(float(evaluation["minimum_passing_distance_m"]), 20.0)
            self.assertGreater(float(evaluation["tcpa_horizon_seconds"]), 0.0)
        self.assertEqual(len(traffic_ids), len(encounter_keys))
        self.assertTrue(
            self.scenarios["narrow_channel_overtaking"]["evaluation"][
                "overtaking_agreement_required"
            ]
        )

    def test_new_maps_fail_closed_at_simulation_boundary(self) -> None:
        for key in ADVANCED_SCENARIOS:
            boundary = self.scenarios[key]["claim_boundary"].lower()
            self.assertTrue("training" in boundary or "benchmark" in boundary)
            self.assertTrue(
                "no " in boundary or "not " in boundary,
                msg=f"{key} must explicitly deny field authority",
            )

    def test_runtime_controller_does_not_command_own_ship_or_modify_policy(self) -> None:
        source = (ROOT / "scripts/training/ship_advanced_mission_controller.gd").read_text(
            encoding="utf-8"
        )
        self.assertIn('"own_ship_commanded_by_controller": false', source)
        self.assertIn('"existing_policy_modified": false', source)
        self.assertIn('"production_authority": false', source)
        self.assertNotIn("own.call(\"set_ship_agent_command\"", source)
        self.assertIn("func confirm_overtaking_agreement", source)
        self.assertIn("func _behavioral_assessment", source)
        self.assertIn('"passed_astern"', source)
        self.assertIn('"starboard_lane_compliant"', source)
        self.assertIn('"test_only_waypoint_traversal_is_not_behavioral_evidence"', source)
        self.assertIn('"AUTHORIZER_REQUIRED"', source)

    def test_every_advanced_task_has_runtime_realism_and_bridge_domains(self) -> None:
        required_domains = {
            "radar_arpa",
            "ecdis",
            "conning",
            "gmdss",
            "instructor",
            "recording_debrief",
        }
        for key in ADVANCED_SCENARIOS:
            with self.subTest(scenario=key):
                realism = self.scenarios[key]["realism"]
                self.assertEqual(
                    realism["profile_version"], "advanced_mission_realism_v1"
                )
                self.assertTrue(required_domains.issubset(realism["required_bridge_domains"]))
                self.assertGreaterEqual(len(realism["competency_criteria"]), 6)
                self.assertGreater(float(realism["vessel"]["draft_m"]), 0.0)
                self.assertEqual(
                    realism["vessel"]["calibration_status"], "unverified_reference"
                )
                environment = realism["environment"]
                for field in (
                    "wind_speed_knots",
                    "wave_height_meters",
                    "visibility_km",
                    "current_speed_knots",
                    "tide_meters",
                ):
                    self.assertIn(field, environment)
                hydrodynamics = realism["hydrodynamics"]
                self.assertTrue(hydrodynamics["shallow_water_enabled"])
                self.assertGreater(float(hydrodynamics["water_depth_m"]), 0.0)
                self.assertGreaterEqual(float(hydrodynamics["minimum_ukc_m"]), 2.0)

    def test_channel_tasks_have_bounded_bank_effect_contracts(self) -> None:
        for key in ("narrow_channel_head_on", "narrow_channel_overtaking"):
            with self.subTest(scenario=key):
                hydro = self.scenarios[key]["realism"]["hydrodynamics"]
                self.assertTrue(hydro["bank_effect_enabled"])
                self.assertGreater(float(hydro["navigable_half_width_m"]), 0.0)
                self.assertGreater(float(hydro["bank_influence_distance_m"]), 0.0)
                self.assertGreater(float(hydro["bank_suction_force_n"]), 0.0)
                self.assertGreater(float(hydro["bank_yaw_moment_nm"]), 0.0)
                self.assertGreaterEqual(float(hydro["minimum_bank_clearance_m"]), 8.0)

    def test_realism_runtime_is_wired_without_changing_frozen_policy(self) -> None:
        controller = (
            ROOT
            / "scripts/training/ship_advanced_mission_realism_controller.gd"
        ).read_text(encoding="utf-8")
        dynamics = (
            ROOT / "scripts/physics/catamaran_three_dof_dynamics.gd"
        ).read_text(encoding="utf-8")
        player = (ROOT / "player.gd").read_text(encoding="utf-8")
        main_scene = (ROOT / "main.tscn").read_text(encoding="utf-8")
        self.assertIn("ShipAdvancedMissionRealismController", main_scene)
        self.assertIn("func run_predeparture_check", controller)
        self.assertIn("func inject_machinery_fault", controller)
        self.assertIn("func finalize_mission_debrief", controller)
        self.assertIn('"named_vessel_dynamics_calibrated": false', controller)
        self.assertIn('"physical_hil_verified": false', controller)
        self.assertIn('"production_authority": false', controller)
        self.assertIn('forcing.get("hydrodynamic_force_body_n"', dynamics)
        self.assertIn('forcing.get("port_thrust_factor"', dynamics)
        self.assertIn('forcing.get("steering_bias_deg"', dynamics)
        self.assertIn("ship_advanced_mission_realism_controller", player)

    def test_all_scenarios_reset_to_clear_weather_on_entry(self) -> None:
        controller = (ROOT / "scripts/world/ship_scenario_controller.gd").read_text(
            encoding="utf-8"
        )
        weather = (ROOT / "scripts/world/ship_weather_time_controller.gd").read_text(
            encoding="utf-8"
        )
        self.assertIn("_reset_default_clear_weather()", controller)
        self.assertIn(
            '_weather_time.call("apply_zero_fog_clear_baseline", {})', controller
        )
        self.assertIn("func apply_zero_fog_clear_baseline", weather)
        self.assertIn("_environment.fog_enabled = false", weather)
        self.assertIn("_environment.fog_density = 0.0", weather)
        self.assertIn("clear_overlay.a = 0.0", weather)
        self.assertIn("3.912 / visibility_m", weather)

    def test_dedicated_scenes_own_four_vertical_runtime_backdrop_walls(self) -> None:
        source = (ROOT / "scripts/world/ship_dedicated_task_scene.gd").read_text(
            encoding="utf-8"
        )
        self.assertIn('TASK_WALL_PREFIX := "TaskBackdrop_"', source)
        self.assertEqual(source.count('_add_task_wall("'), 4)
        self.assertIn('"task_wall_count": _task_walls().size()', source)
        self.assertIn('"task_walls_vertical": _task_walls_vertical()', source)

    def test_navigation_panel_exposes_realism_checks_actions_and_debrief(self) -> None:
        source = (
            ROOT / "scripts/ui/ship_navigation_planning_panel.gd"
        ).read_text(encoding="utf-8")
        for label in (
            "advanced_hydrodynamics",
            "advanced_bridge_readiness",
            "advanced_debrief",
        ):
            self.assertIn(label, source)
        for action in (
            "run_predeparture_check",
            "record_operator_action",
            "finalize_mission_debrief",
        ):
            self.assertIn(action, source)

    def test_top_tier_mapping_keeps_external_claims_fail_closed(self) -> None:
        mapping = json.loads(
            (
                ROOT
                / "data/verification/advanced_mission_top_tier_mapping_v1.json"
            ).read_text(encoding="utf-8")
        )
        capability_ids = {
            capability["id"] for capability in mapping["software_capabilities"]
        }
        self.assertTrue(
            {
                "TASK-HYDRODYNAMICS",
                "TASK-TRAFFIC-COLREG",
                "TASK-BRIDGE",
                "TASK-FAULTS",
                "TASK-ASSESSMENT",
            }.issubset(capability_ids)
        )
        external_gate_ids = {gate["id"] for gate in mapping["external_gates"]}
        self.assertTrue(
            {
                "NAMED-VESSEL-CALIBRATION",
                "OFFICIAL-NAVIGATION-PRODUCTS",
                "PHYSICAL-FULL-MISSION-BRIDGE",
                "PHYSICAL-HIL",
                "CERTIFICATION",
                "SEA-TRIAL-AND-PRODUCTION",
            }.issubset(external_gate_ids)
        )
        self.assertTrue(all(gate["status"] == "BLOCKED" for gate in mapping["external_gates"]))
        self.assertTrue(mapping["claims"])
        self.assertTrue(all(value is False for value in mapping["claims"].values()))

    def test_existing_36_and_44_dimension_champions_are_byte_identical(self) -> None:
        expected = {
            ROOT / "reports/artifacts/cargo_circuit_rl_v1/cargo_sac_policy.zip":
                "a6ccb46e1d89c3bea61e8ab8cea7b26fa2ef52813a7b77a4f77d4954e08553f5",
            ROOT / "reports/artifacts/cargo_circuit_dynamic_rl_v2/cargo_dynamic_sac_policy.zip":
                "0f19759cc96027673f5c0bfc050ec72d93d247c32cef57adbe9b6e454df53c20",
        }
        for path, expected_sha256 in expected.items():
            with self.subTest(path=path.name):
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected_sha256)

    def test_non47_training_function_smoke_covers_all_seven_scenarios(self) -> None:
        report = json.loads(
            (ROOT / "reports/non47_training_function_smoke_v1.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertTrue(report["accepted"])
        self.assertFalse(report["dimension_47_used"])
        self.assertEqual(report["observation_dimensions_tested"], [36, 44])
        self.assertEqual(report["scenario_keys"], self.profile["scenario_order"])
        self.assertTrue(report["frozen_policies_unchanged"])
        self.assertEqual(len(report["runs"]), 2)
        for run in report["runs"]:
            with self.subTest(observation_size=run["observation_size"]):
                self.assertTrue(run["training_complete"])
                self.assertGreaterEqual(
                    run["completed_timesteps"], run["requested_timesteps"]
                )
                self.assertTrue(run["checkpoint_exists"])
                self.assertTrue(run["model_exists"])
                self.assertTrue(run["all_scenarios_inference_passed"])
                self.assertEqual(len(run["scenario_inference_checks"]), 7)
                self.assertFalse(run["policy_qualification_claimed"])

    def test_frozen_policies_are_reported_honestly_on_advanced_transfer(self) -> None:
        report = json.loads(
            (
                ROOT
                / "reports/advanced_mission_existing_policy_baseline_v1.json"
            ).read_text(encoding="utf-8")
        )
        self.assertFalse(report["dimension_47_used"])
        self.assertEqual(report["observation_dimensions_tested"], [36, 44])
        self.assertTrue(report["policies_byte_identical"])
        self.assertEqual(report["scenario_keys"], self.profile["scenario_order"])
        self.assertEqual(report["total_transfer_count"], 14)
        self.assertEqual(len(report["results"]), 14)
        self.assertEqual(
            report["completed_transfer_count"],
            sum(
                bool(item["task_gate"]["full_mission_gate_passed"])
                for item in report["results"]
            ),
        )
        self.assertIn("not", report["claim_boundary"].lower())


if __name__ == "__main__":
    unittest.main()

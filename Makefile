PYTHON ?= .venv/bin/python
GODOT ?= godot

.PHONY: setup run editor quick-check privacy-scan test benchmark-verify benchmark-deep-verify port-contract-verify port-benchmark-verify port-benchmark-deep-verify safety-benchmark-verify safety-benchmark-deep-verify safety-utility-audit safety-utility-audit-verify rl-safety-effectiveness-prepare rl-safety-effectiveness-smoke rl-safety-effectiveness-smoke-verify rl-safety-effectiveness-finalize rl-safety-effectiveness-verify maritime-assurance maritime-assurance-verify named-vessel-twin-readiness named-vessel-twin-readiness-verify named-vessel-twin-smoke named-vessel-twin-smoke-verify physical-bridge-readiness physical-bridge-readiness-verify physical-hil-runtime-smoke physical-hil-runtime-smoke-verify mass-safety-case mass-safety-case-verify colreg-complex colreg-complex-verify rl-generalization-assurance rl-generalization-assurance-verify full-mission-bridge-assurance full-mission-bridge-assurance-verify maritime-cybersecurity-assurance maritime-cybersecurity-assurance-verify port-production-integration-assurance port-production-integration-assurance-verify full-visual-asset-audit full-visual-asset-audit-verify reliability-audit reliability-audit-v3 research-release research-release-verify full-visual-release full-visual-release-verify release-check godot-check godot-acceptance godot-button-inventory godot-button-interaction-smoke godot-ui-navigation-smoke godot-integrated-bridge-smoke godot-multisensor-fusion-smoke godot-execution-control-smoke godot-named-vessel-twin-smoke godot-instructor-debrief-smoke godot-port-operations-training-smoke godot-bridge-team-collaboration-smoke godot-physical-bridge-readiness-smoke godot-safety-case-smoke godot-colreg-complex-smoke godot-rl-generalization-smoke godot-full-mission-bridge-smoke godot-bridge-cybersecurity-smoke godot-port-production-integration-smoke godot-advanced-mission-smoke godot-advanced-mission-realism-smoke godot-safety-strategy-smoke godot-large-rock-training-contract godot-catamaran-hydrodynamics godot-cargo-collision-smoke

setup:
	bash tools/setup_rl_env.sh

run:
	bash tools/run_godot.sh run

editor:
	bash tools/run_godot.sh editor

quick-check:
	bash tools/run_godot.sh check

privacy-scan:
	python3 tools/public_privacy_scan.py

test:
	$(PYTHON) -m unittest discover -s tests -v

benchmark-verify:
	$(PYTHON) tools/run_navigation_benchmark.py verify

benchmark-deep-verify:
	$(PYTHON) tools/run_nonmutating_deep_verify.py navigation-v1

port-contract-verify:
	$(PYTHON) tools/validate_port_package.py data/rl/long_beach_ais_port_ops_benchmark_v2.json --require-research-ready

port-benchmark-verify:
	$(PYTHON) tools/run_port_ops_benchmark.py verify

port-benchmark-deep-verify:
	$(PYTHON) tools/run_nonmutating_deep_verify.py port-v2

safety-benchmark-verify:
	$(PYTHON) tools/run_safety_supervisor_benchmark.py verify

safety-benchmark-deep-verify:
	$(PYTHON) tools/run_nonmutating_deep_verify.py safety-v3

safety-utility-audit:
	$(PYTHON) tools/audit_safety_supervisor_utility_v3.py generate

safety-utility-audit-verify:
	$(PYTHON) tools/audit_safety_supervisor_utility_v3.py verify

rl-safety-effectiveness-prepare:
	$(PYTHON) tools/audit_rl_safety_effectiveness_v1.py prepare

rl-safety-effectiveness-smoke:
	$(PYTHON) tools/audit_rl_safety_effectiveness_v1.py smoke

rl-safety-effectiveness-smoke-verify:
	$(PYTHON) tools/audit_rl_safety_effectiveness_v1.py verify-smoke

rl-safety-effectiveness-finalize:
	$(PYTHON) tools/audit_rl_safety_effectiveness_v1.py finalize

rl-safety-effectiveness-verify:
	$(PYTHON) tools/audit_rl_safety_effectiveness_v1.py verify

maritime-assurance:
	$(PYTHON) tools/run_maritime_assurance.py generate

maritime-assurance-verify:
	$(PYTHON) tools/run_maritime_assurance.py verify

named-vessel-twin-readiness:
	$(PYTHON) tools/run_named_vessel_twin.py generate

named-vessel-twin-readiness-verify:
	$(PYTHON) tools/run_named_vessel_twin.py verify

named-vessel-twin-smoke:
	$(PYTHON) tools/run_named_vessel_twin.py smoke

named-vessel-twin-smoke-verify:
	$(PYTHON) tools/run_named_vessel_twin.py verify-smoke

physical-bridge-readiness:
	$(PYTHON) tools/run_physical_bridge_readiness.py generate

physical-bridge-readiness-verify:
	$(PYTHON) tools/run_physical_bridge_readiness.py verify

physical-hil-runtime-smoke:
	$(PYTHON) tools/run_physical_hil_runtime.py generate

physical-hil-runtime-smoke-verify:
	$(PYTHON) tools/run_physical_hil_runtime.py verify

mass-safety-case:
	$(PYTHON) tools/run_mass_safety_case.py generate

mass-safety-case-verify:
	$(PYTHON) tools/run_mass_safety_case.py verify

colreg-complex:
	$(PYTHON) tools/run_colreg_complex_assurance.py generate

colreg-complex-verify:
	$(PYTHON) tools/run_colreg_complex_assurance.py verify

rl-generalization-assurance:
	$(PYTHON) tools/run_rl_generalization_assurance.py generate

rl-generalization-assurance-verify:
	$(PYTHON) tools/run_rl_generalization_assurance.py verify

full-mission-bridge-assurance:
	$(PYTHON) tools/run_full_mission_bridge_assurance.py generate

full-mission-bridge-assurance-verify:
	$(PYTHON) tools/run_full_mission_bridge_assurance.py verify

maritime-cybersecurity-assurance:
	$(PYTHON) tools/run_maritime_cybersecurity_assurance.py generate

maritime-cybersecurity-assurance-verify:
	$(PYTHON) tools/run_maritime_cybersecurity_assurance.py verify

port-production-integration-assurance:
	$(PYTHON) tools/run_port_production_integration_assurance.py generate

port-production-integration-assurance-verify:
	$(PYTHON) tools/run_port_production_integration_assurance.py verify

full-visual-asset-audit:
	$(PYTHON) tools/audit_full_visual_release.py generate

full-visual-asset-audit-verify:
	$(PYTHON) tools/audit_full_visual_release.py verify

reliability-audit:
	$(MAKE) reliability-audit-v3

reliability-audit-v3:
	$(PYTHON) tools/run_simulator_reliability_audit.py verify \
		--godot-report reports/godot_acceptance_v3.json \
		--output-json reports/simulator_reliability_audit_v3.json \
		--output-markdown reports/simulator_reliability_audit_v3.md \
		--revision v3

research-release:
	$(PYTHON) tools/build_research_core_release.py build

research-release-verify:
	$(PYTHON) tools/build_research_core_release.py verify

full-visual-release:
	$(PYTHON) tools/build_full_visual_release.py build

full-visual-release-verify:
	$(PYTHON) tools/build_full_visual_release.py verify

release-check:
	python3 tools/public_privacy_scan.py
	$(PYTHON) tools/verify_mission_rl_release.py
	$(PYTHON) tools/release_check.py --strict-assets

godot-check:
	$(GODOT) --path . --check-only --quit
	$(GODOT) --headless --path . --quit-after 8

godot-acceptance:
	$(PYTHON) tools/run_godot_acceptance.py --godot "$(GODOT)"

godot-button-inventory:
	$(GODOT) --headless --path . --script res://tools/godot_button_inventory.gd

godot-button-interaction-smoke: godot-button-inventory
	$(GODOT) --headless --path . --script res://tools/godot_button_interaction_smoke.gd

godot-ui-navigation-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_ui_navigation_smoke.gd

godot-integrated-bridge-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_integrated_bridge_smoke.gd

godot-multisensor-fusion-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_multisensor_fusion_smoke.gd

godot-execution-control-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_execution_control_smoke.gd

godot-named-vessel-twin-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_named_vessel_twin_smoke.gd

godot-instructor-debrief-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_instructor_debrief_smoke.gd

godot-port-operations-training-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_port_operations_training_smoke.gd

godot-bridge-team-collaboration-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_bridge_team_collaboration_smoke.gd

godot-physical-bridge-readiness-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_physical_bridge_readiness_smoke.gd

godot-safety-case-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_safety_case_smoke.gd

godot-colreg-complex-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_colreg_complex_smoke.gd

godot-rl-generalization-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_rl_generalization_smoke.gd

godot-full-mission-bridge-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_full_mission_bridge_smoke.gd

godot-bridge-cybersecurity-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_bridge_cybersecurity_smoke.gd

godot-port-production-integration-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_port_production_integration_smoke.gd

godot-advanced-mission-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_advanced_mission_smoke.gd

godot-advanced-mission-realism-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_advanced_mission_realism_smoke.gd

godot-safety-strategy-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_safety_strategy_smoke_v3.gd

godot-large-rock-training-contract:
	$(GODOT) --headless --path . --script res://tools/large_rock_training_contract_smoke.gd

godot-catamaran-hydrodynamics:
	$(GODOT) --headless --path . --script res://tools/catamaran_hydrodynamics_smoke.gd

godot-cargo-collision-smoke:
	$(PYTHON) tools/run_cargo_collision_regression.py --godot "$(GODOT)"

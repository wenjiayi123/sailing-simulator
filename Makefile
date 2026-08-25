PYTHON ?= .venv/bin/python
GODOT ?= godot

.PHONY: setup run editor quick-check privacy-scan test benchmark-verify benchmark-deep-verify port-contract-verify port-benchmark-verify port-benchmark-deep-verify safety-benchmark-verify safety-benchmark-deep-verify safety-utility-audit safety-utility-audit-verify maritime-assurance maritime-assurance-verify reliability-audit reliability-audit-v3 research-release research-release-verify release-check godot-check godot-acceptance godot-button-inventory godot-button-interaction-smoke godot-ui-navigation-smoke godot-safety-strategy-smoke godot-large-rock-training-contract godot-catamaran-hydrodynamics godot-cargo-collision-smoke

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

maritime-assurance:
	$(PYTHON) tools/run_maritime_assurance.py generate

maritime-assurance-verify:
	$(PYTHON) tools/run_maritime_assurance.py verify

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

release-check:
	python3 tools/public_privacy_scan.py
	$(PYTHON) tools/release_check.py

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

godot-safety-strategy-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_safety_strategy_smoke_v3.gd

godot-large-rock-training-contract:
	$(GODOT) --headless --path . --script res://tools/large_rock_training_contract_smoke.gd

godot-catamaran-hydrodynamics:
	$(GODOT) --headless --path . --script res://tools/catamaran_hydrodynamics_smoke.gd

godot-cargo-collision-smoke:
	$(PYTHON) tools/run_cargo_collision_regression.py --godot "$(GODOT)"

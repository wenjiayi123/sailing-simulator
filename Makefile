PYTHON ?= .venv/bin/python
GODOT ?= godot

.PHONY: test benchmark-verify benchmark-deep-verify port-contract-verify port-benchmark-verify port-benchmark-deep-verify safety-benchmark-verify safety-benchmark-deep-verify safety-utility-audit safety-utility-audit-verify maritime-assurance maritime-assurance-verify reliability-audit reliability-audit-v3 research-release research-release-verify release-check godot-check godot-acceptance godot-ui-navigation-smoke godot-safety-strategy-smoke

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
	$(PYTHON) tools/release_check.py

godot-check:
	$(GODOT) --path . --check-only --quit
	$(GODOT) --headless --path . --quit-after 8

godot-acceptance:
	$(PYTHON) tools/run_godot_acceptance.py --godot "$(GODOT)"

godot-ui-navigation-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_ui_navigation_smoke.gd

godot-safety-strategy-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_safety_strategy_smoke_v3.gd

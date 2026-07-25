PYTHON ?= .venv/bin/python
GODOT ?= godot

.PHONY: test benchmark-verify benchmark-deep-verify port-contract-verify port-benchmark-verify port-benchmark-deep-verify reliability-audit release-check godot-check godot-acceptance godot-ui-navigation-smoke

test:
	$(PYTHON) -m unittest discover -s tests -v

benchmark-verify:
	$(PYTHON) tools/run_navigation_benchmark.py verify

benchmark-deep-verify:
	$(PYTHON) tools/run_navigation_benchmark.py verify --deep

port-contract-verify:
	$(PYTHON) tools/validate_port_package.py data/rl/long_beach_ais_port_ops_benchmark_v2.json --require-research-ready

port-benchmark-verify:
	$(PYTHON) tools/run_port_ops_benchmark.py verify

port-benchmark-deep-verify:
	$(PYTHON) tools/run_port_ops_benchmark.py verify --deep

reliability-audit:
	$(PYTHON) tools/run_simulator_reliability_audit.py verify

release-check:
	$(PYTHON) tools/release_check.py

godot-check:
	$(GODOT) --path . --check-only --quit
	$(GODOT) --headless --path . --quit-after 8

godot-acceptance:
	$(PYTHON) tools/run_godot_acceptance.py --godot "$(GODOT)"

godot-ui-navigation-smoke:
	$(GODOT) --headless --path . --script res://tools/godot_ui_navigation_smoke.gd

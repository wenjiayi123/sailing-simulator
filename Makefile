PYTHON ?= .venv/bin/python
GODOT ?= godot

.PHONY: test benchmark-verify benchmark-deep-verify reliability-audit release-check godot-check godot-acceptance

test:
	$(PYTHON) -m unittest discover -s tests -v

benchmark-verify:
	$(PYTHON) tools/run_navigation_benchmark.py verify

benchmark-deep-verify:
	$(PYTHON) tools/run_navigation_benchmark.py verify --deep

reliability-audit:
	$(PYTHON) tools/run_simulator_reliability_audit.py verify

release-check:
	$(PYTHON) tools/release_check.py

godot-check:
	$(GODOT) --path . --check-only --quit
	$(GODOT) --headless --path . --quit-after 8

godot-acceptance:
	$(PYTHON) tools/run_godot_acceptance.py --godot "$(GODOT)"

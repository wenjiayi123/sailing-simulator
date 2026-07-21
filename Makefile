PYTHON ?= .venv/bin/python
GODOT ?= godot

.PHONY: setup test godot-check godot-smoke capture-readme

setup:
	bash tools/setup_rl_env.sh

test:
	$(PYTHON) -m unittest tests.test_ship_rl -v

godot-check:
	$(GODOT) --headless --path . --quit-after 8

godot-smoke:
	$(GODOT) --headless --path . --script res://tools/ship_rl_smoke_test.gd

capture-readme:
	$(GODOT) --path . --script res://tools/capture_readme_screenshots.gd

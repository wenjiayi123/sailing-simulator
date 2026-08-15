extends SceneTree
# gdlint: disable=max-line-length

const REPORT_PATH := "res://reports/godot_button_inventory_v1.json"
const PANEL_NAMES := [
	"ShipRLControlPanel",
	"ShipRiskDecisionPanel",
	"ShipNavigationPlanningPanel",
	"ShipWeatherSeaPanel",
	"ShipSimulationReviewPanel",
	"ShipAISFleetPanel",
	"ShipInstructorConsolePanel",
	"ShipHREvidenceCenter",
	"CargoCircuitRLPanel",
]

var _errors: Array[String] = []
var _inventory: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene_status := change_scene_to_file("res://main.tscn")
	if scene_status != OK:
		_errors.append("main scene load failed: %s" % error_string(scene_status))
		_finish()
		return
	for _index in range(16):
		await process_frame
	var main := current_scene
	if main == null:
		_errors.append("main scene is unavailable")
		_finish()
		return

	for panel_name in PANEL_NAMES:
		var panel := main.get_node_or_null(NodePath(panel_name))
		if panel == null:
			_errors.append("missing panel: %s" % panel_name)
			continue
		var root := panel.get("_root") as Control
		if root == null:
			_errors.append("missing panel root: %s" % panel_name)
			continue
		_collect_panel_buttons(panel_name, root)
		if panel_name == "CargoCircuitRLPanel":
			var return_root := panel.get("_hub_return_root") as Control
			if return_root == null:
				_errors.append("missing H-hub return overlay")
			else:
				_collect_panel_buttons(panel_name, return_root)

	_finish()


func _collect_panel_buttons(panel_name: String, root: Control) -> void:
	for node in root.find_children("*", "Button", true, false):
		var button := node as Button
		if button == null:
			continue
		var expected_signal := "pressed"
		if button is OptionButton:
			expected_signal = "item_selected"
		elif button is CheckBox:
			expected_signal = "toggled"
		var connection_count := button.get_signal_connection_list(expected_signal).size()
		var record := {
			"panel": panel_name,
			"class": button.get_class(),
			"text": button.text,
			"signal": expected_signal,
			"handler_count": connection_count,
			"disabled": button.disabled,
			"visible": button.visible,
		}
		if button is OptionButton:
			var option := button as OptionButton
			var items: Array[String] = []
			for index in range(option.item_count):
				items.append(option.get_item_text(index))
			record["items"] = items
		_inventory.append(record)
		if connection_count == 0:
			_errors.append(
				"%s button '%s' has no %s handler"
				% [panel_name, button.text, expected_signal]
			)


func _finish() -> void:
	var payload := {
		"schema_version": "godot_button_inventory_v1",
		"generated_at": Time.get_datetime_string_from_system(true),
		"button_count": _inventory.size(),
		"buttons": _inventory,
		"errors": _errors,
		"passed": _errors.is_empty(),
		"boundary": "Runtime inventory and signal-binding audit only; action outcomes are covered by the button interaction regression.",
	}
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t") + "\n")
		file.close()
	print(
		"BUTTON_INVENTORY:%s:%d"
		% ["PASS" if _errors.is_empty() else "FAIL", _inventory.size()]
	)
	for error in _errors:
		push_error(error)
	quit(0 if _errors.is_empty() else 1)

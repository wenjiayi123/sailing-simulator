extends Node
class_name ShipInstructorExerciseController

## Deterministic instructor exercise timeline and equipment-fault matrix.
##
## This controller only operates the research bridge-equipment facade. It does
## not command the vessel, modify the motion model, or edit any policy artifact.

signal receipt_emitted(receipt: Dictionary)
signal exercise_state_changed(snapshot: Dictionary)

const SCHEMA_VERSION := "ship_instructor_exercise_v2"
const MAX_RECEIPTS := 512

const FAULT_DEFINITIONS := {
	"radar_power_loss": {
		"label": "雷达电源失效",
		"category": "RADAR",
		"default_value": true,
		"restore_value": false,
		"effect": "雷达目标与杂波输出归零",
	},
	"radar_range_bias_m": {
		"label": "雷达距离偏差",
		"category": "RADAR",
		"default_value": 45.0,
		"restore_value": 0.0,
		"effect": "所有雷达测距叠加确定性偏差",
	},
	"radar_bearing_bias_deg": {
		"label": "雷达方位偏差",
		"category": "RADAR",
		"default_value": 3.5,
		"restore_value": 0.0,
		"effect": "所有雷达方位叠加确定性偏差",
	},
	"gyro_bias_deg": {
		"label": "电罗经偏差",
		"category": "HEADING",
		"default_value": 7.5,
		"restore_value": 0.0,
		"effect": "首向与航向显示产生一致偏差",
	},
	"gnss_frozen": {
		"label": "全球导航卫星系统位置冻结",
		"category": "POSITION",
		"default_value": true,
		"restore_value": false,
		"effect": "电子海图位置保持在故障发生点并报警",
	},
	"ais_loss": {
		"label": "船舶自动识别系统数据丢失",
		"category": "TRAFFIC",
		"default_value": true,
		"restore_value": false,
		"effect": "电子海图与雷达融合不再提供自动识别系统记录",
	},
	"speed_log_loss": {
		"label": "计程仪失效",
		"category": "SPEED",
		"default_value": true,
		"restore_value": false,
		"effect": "操纵信息速度读数不可用",
	},
	"rudder_feedback_loss": {
		"label": "舵角反馈失效",
		"category": "STEERING",
		"default_value": true,
		"restore_value": false,
		"effect": "操纵信息舵角反馈不可用，不改变实际舵效",
	},
	"depth_sensor_loss": {
		"label": "测深仪失效",
		"category": "DEPTH",
		"default_value": true,
		"restore_value": false,
		"effect": "电子海图测深有效性报警",
	},
}

const EXERCISE_TEMPLATES := {
	"restricted_visibility_bridge": {
		"name": "受限能见度驾驶台设备处置",
		"objective": "识别雷达与自动识别系统分层失效，完成交叉核对和恢复确认",
		"events": [
			{"id": "RV-00", "at_s": 0.0, "action": "marker", "label": "演练开始：建立雷达/电子海图/目视交叉核对"},
			{"id": "RV-01", "at_s": 15.0, "action": "fault", "fault": "radar_power_loss", "value": true},
			{"id": "RV-02", "at_s": 35.0, "action": "restore", "fault": "radar_power_loss"},
			{"id": "RV-03", "at_s": 45.0, "action": "fault", "fault": "ais_loss", "value": true},
			{"id": "RV-04", "at_s": 70.0, "action": "restore", "fault": "ais_loss"},
			{"id": "RV-05", "at_s": 75.0, "action": "marker", "label": "演练结束：确认设备恢复与未确认告警"},
		],
	},
	"sensor_disagreement": {
		"name": "位置与首向传感器不一致",
		"objective": "通过独立信息源识别电罗经偏差与位置冻结，保持航行决策可解释",
		"events": [
			{"id": "SD-00", "at_s": 0.0, "action": "marker", "label": "演练开始：记录基准首向和位置"},
			{"id": "SD-01", "at_s": 10.0, "action": "fault", "fault": "gyro_bias_deg", "value": 7.5},
			{"id": "SD-02", "at_s": 25.0, "action": "fault", "fault": "gnss_frozen", "value": true},
			{"id": "SD-03", "at_s": 45.0, "action": "restore", "fault": "gnss_frozen"},
			{"id": "SD-04", "at_s": 60.0, "action": "restore", "fault": "gyro_bias_deg"},
			{"id": "SD-05", "at_s": 65.0, "action": "marker", "label": "演练结束：记录识别时间与恢复核验"},
		],
	},
	"conning_feedback_failure": {
		"name": "操纵信息反馈链失效",
		"objective": "在计程仪、舵角反馈和测深失效时识别不可用信息并执行交叉核对",
		"events": [
			{"id": "CF-00", "at_s": 0.0, "action": "marker", "label": "演练开始：确认操纵信息基准"},
			{"id": "CF-01", "at_s": 10.0, "action": "fault", "fault": "speed_log_loss", "value": true},
			{"id": "CF-02", "at_s": 20.0, "action": "fault", "fault": "rudder_feedback_loss", "value": true},
			{"id": "CF-03", "at_s": 30.0, "action": "fault", "fault": "depth_sensor_loss", "value": true},
			{"id": "CF-04", "at_s": 55.0, "action": "restore_all"},
			{"id": "CF-05", "at_s": 60.0, "action": "marker", "label": "演练结束：确认全部传感器恢复"},
		],
	},
}

@export var equipment_suite_path: NodePath = NodePath("../ShipNavigationEquipmentSuite")

var _equipment_suite: Node
var _template_key := ""
var _timeline: Array[Dictionary] = []
var _next_event_index := 0
var _elapsed_seconds := 0.0
var _running := false
var _receipts: Array[Dictionary] = []
var _receipt_sequence := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"ship_instructor_exercise_controller")
	_resolve_suite()
	set_process(true)


func _process(delta: float) -> void:
	if not _running or get_tree().paused:
		return
	_elapsed_seconds += maxf(delta, 0.0)
	_execute_due_events()


func _resolve_suite() -> void:
	_equipment_suite = get_node_or_null(equipment_suite_path)
	if _equipment_suite == null:
		_equipment_suite = get_tree().get_first_node_in_group(&"ship_navigation_equipment_suite")


func list_templates() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for key in EXERCISE_TEMPLATES.keys():
		var template := EXERCISE_TEMPLATES[key] as Dictionary
		result.append({
			"key": key,
			"name": template.get("name", key),
			"objective": template.get("objective", ""),
			"event_count": (template.get("events", []) as Array).size(),
		})
	return result


func load_exercise(template_key: String) -> Dictionary:
	if not EXERCISE_TEMPLATES.has(template_key):
		return _append_receipt("load_exercise", "", "REJECTED", {"reason": "UNKNOWN_TEMPLATE", "template": template_key})
	_running = false
	_elapsed_seconds = 0.0
	_next_event_index = 0
	_template_key = template_key
	_timeline.clear()
	for raw_event in (EXERCISE_TEMPLATES[template_key] as Dictionary).get("events", []) as Array:
		_timeline.append((raw_event as Dictionary).duplicate(true))
	var receipt := _append_receipt("load_exercise", "", "ACCEPTED", {"template": template_key, "event_count": _timeline.size()})
	_emit_state_changed()
	return receipt


func start_exercise() -> Dictionary:
	if _timeline.is_empty():
		return _append_receipt("start_exercise", "", "REJECTED", {"reason": "NO_EXERCISE_LOADED"})
	_running = true
	var receipt := _append_receipt("start_exercise", "", "ACCEPTED", {"template": _template_key, "next_event_index": _next_event_index})
	_execute_due_events()
	_emit_state_changed()
	return receipt


func pause_exercise() -> Dictionary:
	_running = false
	var receipt := _append_receipt("pause_exercise", "", "ACCEPTED", {"elapsed_seconds": _elapsed_seconds})
	_emit_state_changed()
	return receipt


func reset_exercise(clear_faults: bool = true) -> Dictionary:
	_running = false
	_elapsed_seconds = 0.0
	_next_event_index = 0
	if clear_faults:
		clear_equipment_faults("exercise_reset")
	var receipt := _append_receipt("reset_exercise", "", "ACCEPTED", {"template": _template_key, "faults_cleared": clear_faults})
	_emit_state_changed()
	return receipt


func execute_next_event() -> Dictionary:
	if _next_event_index >= _timeline.size():
		_running = false
		return _append_receipt("execute_next_event", "", "REJECTED", {"reason": "TIMELINE_COMPLETE"})
	var event := _timeline[_next_event_index]
	_elapsed_seconds = maxf(_elapsed_seconds, float(event.get("at_s", 0.0)))
	var receipt := _execute_event(event, "manual_step")
	_next_event_index += 1
	if _next_event_index >= _timeline.size():
		_running = false
	_emit_state_changed()
	return receipt


func inject_equipment_fault(fault_key: String, value: Variant = null, source: String = "instructor_manual") -> Dictionary:
	_resolve_suite()
	if not FAULT_DEFINITIONS.has(fault_key):
		return _append_receipt("equipment_fault", fault_key, "REJECTED", {"reason": "UNKNOWN_FAULT", "source": source})
	if _equipment_suite == null or not _equipment_suite.has_method("set_equipment_fault"):
		return _append_receipt("equipment_fault", fault_key, "REJECTED", {"reason": "EQUIPMENT_SUITE_UNAVAILABLE", "source": source})
	var definition := FAULT_DEFINITIONS[fault_key] as Dictionary
	var resolved_value: Variant = definition.get("default_value") if value == null else value
	var accepted := bool(_equipment_suite.call("set_equipment_fault", fault_key, resolved_value))
	var receipt := _append_receipt(
		"equipment_fault",
		fault_key,
		"EXECUTED" if accepted else "REJECTED",
		{"value": resolved_value, "source": source, "effect": definition.get("effect", "")},
	)
	_emit_state_changed()
	return receipt


func restore_equipment_fault(fault_key: String, source: String = "instructor_manual") -> Dictionary:
	if not FAULT_DEFINITIONS.has(fault_key):
		return _append_receipt("equipment_restore", fault_key, "REJECTED", {"reason": "UNKNOWN_FAULT", "source": source})
	var restore_value: Variant = (FAULT_DEFINITIONS[fault_key] as Dictionary).get("restore_value", false)
	_resolve_suite()
	if _equipment_suite == null or not _equipment_suite.has_method("set_equipment_fault"):
		return _append_receipt("equipment_restore", fault_key, "REJECTED", {"reason": "EQUIPMENT_SUITE_UNAVAILABLE", "source": source})
	var accepted := bool(_equipment_suite.call("set_equipment_fault", fault_key, restore_value))
	var receipt := _append_receipt(
		"equipment_restore",
		fault_key,
		"EXECUTED" if accepted else "REJECTED",
		{"value": restore_value, "source": source},
	)
	_emit_state_changed()
	return receipt


func clear_equipment_faults(source: String = "instructor_manual") -> Dictionary:
	_resolve_suite()
	if _equipment_suite == null or not _equipment_suite.has_method("clear_equipment_faults"):
		return _append_receipt("equipment_restore_all", "", "REJECTED", {"reason": "EQUIPMENT_SUITE_UNAVAILABLE", "source": source})
	_equipment_suite.call("clear_equipment_faults")
	var receipt := _append_receipt("equipment_restore_all", "", "EXECUTED", {"source": source})
	_emit_state_changed()
	return receipt


func get_fault_matrix() -> Array[Dictionary]:
	_resolve_suite()
	var current := {}
	if _equipment_suite != null and _equipment_suite.has_method("get_fault_state"):
		current = _equipment_suite.call("get_fault_state") as Dictionary
	var matrix: Array[Dictionary] = []
	for key in FAULT_DEFINITIONS.keys():
		var definition := (FAULT_DEFINITIONS[key] as Dictionary).duplicate(true)
		definition["key"] = key
		definition["current_value"] = current.get(key, definition.get("restore_value"))
		definition["active"] = not definition["current_value"] == definition.get("restore_value")
		matrix.append(definition)
	return matrix


func get_exercise_snapshot() -> Dictionary:
	var template := EXERCISE_TEMPLATES.get(_template_key, {}) as Dictionary
	return {
		"format": SCHEMA_VERSION,
		"template_key": _template_key,
		"template_name": template.get("name", "未载入"),
		"objective": template.get("objective", ""),
		"running": _running,
		"elapsed_seconds": snapped(_elapsed_seconds, 0.01),
		"next_event_index": _next_event_index,
		"event_count": _timeline.size(),
		"timeline": _timeline.duplicate(true),
		"receipts": _receipts.duplicate(true),
		"fault_matrix": get_fault_matrix(),
		"complete": not _timeline.is_empty() and _next_event_index >= _timeline.size(),
		"production_authority": false,
		"changes_motion_model": false,
		"changes_policy": false,
		"boundary": "Instructor-controlled research exercise timeline; equipment faults affect displays only and do not replace an approved simulator instructor operating station.",
	}


func _execute_due_events() -> void:
	while _running and _next_event_index < _timeline.size():
		var event := _timeline[_next_event_index]
		if float(event.get("at_s", INF)) > _elapsed_seconds:
			break
		_execute_event(event, "scheduled")
		_next_event_index += 1
	if _next_event_index >= _timeline.size() and not _timeline.is_empty():
		_running = false
		_append_receipt("exercise_complete", "", "EXECUTED", {"template": _template_key, "elapsed_seconds": _elapsed_seconds})
		_emit_state_changed()


func _execute_event(event: Dictionary, source: String) -> Dictionary:
	var action := String(event.get("action", ""))
	var event_id := String(event.get("id", ""))
	match action:
		"fault":
			return inject_equipment_fault(String(event.get("fault", "")), event.get("value"), source + ":" + event_id)
		"restore":
			return restore_equipment_fault(String(event.get("fault", "")), source + ":" + event_id)
		"restore_all":
			return clear_equipment_faults(source + ":" + event_id)
		"marker":
			return _append_receipt("marker", event_id, "EXECUTED", {"label": event.get("label", ""), "source": source})
		_:
			return _append_receipt("timeline_event", event_id, "REJECTED", {"reason": "UNKNOWN_ACTION", "action": action, "source": source})


func _append_receipt(action: String, event_or_fault_id: String, status: String, detail: Dictionary) -> Dictionary:
	_receipt_sequence += 1
	var receipt := {
		"receipt_id": "IEX-%06d" % _receipt_sequence,
		"sequence": _receipt_sequence,
		"utc": Time.get_datetime_string_from_system(true),
		"exercise_elapsed_seconds": snapped(_elapsed_seconds, 0.01),
		"template_key": _template_key,
		"action": action,
		"subject": event_or_fault_id,
		"status": status,
		"detail": detail.duplicate(true),
	}
	_receipts.append(receipt)
	while _receipts.size() > MAX_RECEIPTS:
		_receipts.remove_at(0)
	receipt_emitted.emit(receipt.duplicate(true))
	return receipt


func _emit_state_changed() -> void:
	exercise_state_changed.emit(get_exercise_snapshot())

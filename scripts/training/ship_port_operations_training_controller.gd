extends Node
class_name ShipPortOperationsTrainingController

## Procedural port-operations trainer.
##
## The trainer evaluates ordered actions, explicit confirmations, closed-loop
## communications and runtime speed gates. It never applies tug, mooring,
## anchor or thruster forces and therefore does not alter ship dynamics.

signal operation_receipt_emitted(receipt: Dictionary)
signal procedure_state_changed(snapshot: Dictionary)

const SCHEMA_VERSION := "ship_port_operations_training_v1"
const MAX_RECEIPTS := 512
const KNOTS_PER_MPS := 1.943844

const PROCEDURES := {
	"berthing": {
		"name": "靠泊作业",
		"objective": "完成从驾驶台交换信息到全船系牢的靠泊程序训练",
		"steps": [
			{"id": "B-01", "label": "船长/引航员交换船舶操纵特性、泊位和中止条件", "requires_confirmation": true, "requires_readback": true},
			{"id": "B-02", "label": "确认训练泊位几何、富余水深和非生产边界", "requires_confirmation": true, "requires_training_geometry_ack": true},
			{"id": "B-03", "label": "确认拖轮配置、系缆站和应急脱离方案", "requires_confirmation": true, "requires_readback": true},
			{"id": "B-04", "label": "进入最终进靠段前核验航速不大于 3 节", "requires_confirmation": true, "max_speed_knots": 3.0},
			{"id": "B-05", "label": "确认船身与泊位平行、横移趋势受控", "requires_confirmation": true},
			{"id": "B-06", "label": "收到首尾系缆站全船系牢回报并复诵", "requires_confirmation": true, "requires_readback": true},
		],
	},
	"unberthing": {
		"name": "离泊作业",
		"objective": "完成离泊前检查、解缆顺序、拖轮通信和安全离开程序",
		"steps": [
			{"id": "U-01", "label": "确认离泊计划、交通窗口、风流和中止条件", "requires_confirmation": true, "requires_readback": true},
			{"id": "U-02", "label": "核验训练泊位几何、富余水深和受限水域边界", "requires_confirmation": true, "requires_training_geometry_ack": true},
			{"id": "U-03", "label": "确认主机、舵机、通信和应急设备就绪", "requires_confirmation": true},
			{"id": "U-04", "label": "复诵解缆顺序并确认拖轮受力方向", "requires_confirmation": true, "requires_readback": true},
			{"id": "U-05", "label": "确认最后缆绳清爽且人员离开回弹危险区", "requires_confirmation": true},
			{"id": "U-06", "label": "低速离开泊位并确认安全间距", "requires_confirmation": true, "max_speed_knots": 5.0},
		],
	},
	"tug_operations": {
		"name": "拖轮协同",
		"objective": "训练拖轮配置、标准指令、复诵、受力监控和释放闭环",
		"steps": [
			{"id": "T-01", "label": "确认拖轮数量、系柱拉力、连接点和限制", "requires_confirmation": true},
			{"id": "T-02", "label": "指定拖轮呼号、作业位置与通信频道", "requires_confirmation": true, "requires_readback": true},
			{"id": "T-03", "label": "发出标准推/拉/停指令并收到完整复诵", "requires_confirmation": true, "requires_readback": true},
			{"id": "T-04", "label": "确认拖缆连接、人员清爽和回弹区管控", "requires_confirmation": true},
			{"id": "T-05", "label": "监控受力趋势并确认没有模拟力施加到船体", "requires_confirmation": true, "requires_no_actuation": true},
			{"id": "T-06", "label": "复诵停拖、解缆和拖轮离开报告", "requires_confirmation": true, "requires_readback": true},
		],
	},
	"anchoring": {
		"name": "锚泊作业",
		"objective": "训练锚地评估、备锚、抛锚、出链和走锚监测程序",
		"steps": [
			{"id": "A-01", "label": "评估锚地交通、天气、底质和回旋水域", "requires_confirmation": true},
			{"id": "A-02", "label": "核验训练水深、富余水深、锚链长度和非官方数据边界", "requires_confirmation": true, "requires_training_geometry_ack": true},
			{"id": "A-03", "label": "确认锚机、制链器、通信和人员防护就绪", "requires_confirmation": true, "requires_readback": true},
			{"id": "A-04", "label": "船速降至不大于 2 节后发出抛锚指令", "requires_confirmation": true, "requires_readback": true, "max_speed_knots": 2.0},
			{"id": "A-05", "label": "确认模拟出链节数、锚链方向和刹车状态", "requires_confirmation": true},
			{"id": "A-06", "label": "建立锚位警戒圈并完成走锚趋势核验", "requires_confirmation": true},
		],
	},
	"mooring": {
		"name": "系泊站作业",
		"objective": "训练首尾站协同、回弹区控制、缆绳顺序和全船系牢回报",
		"steps": [
			{"id": "M-01", "label": "首尾系缆站报告人员、设备与通信就绪", "requires_confirmation": true, "requires_readback": true},
			{"id": "M-02", "label": "确认回弹危险区、导缆孔和绞缆机风险", "requires_confirmation": true},
			{"id": "M-03", "label": "复诵首缆/尾缆/横缆/倒缆操作顺序", "requires_confirmation": true, "requires_readback": true},
			{"id": "M-04", "label": "确认每根模拟缆绳受力趋势和人员位置", "requires_confirmation": true, "requires_no_actuation": true},
			{"id": "M-05", "label": "平衡模拟缆绳负荷并锁定绞缆机", "requires_confirmation": true, "requires_no_actuation": true},
			{"id": "M-06", "label": "首尾站报告全船系牢，驾驶台完整复诵", "requires_confirmation": true, "requires_readback": true},
		],
	},
	"thruster_dry_run": {
		"name": "侧推器程序干运行",
		"objective": "在不施加船体力的前提下训练侧推器适用性、限制、指令和监控",
		"steps": [
			{"id": "TH-01", "label": "核对训练船型的侧推器配置与不可执行边界", "requires_confirmation": true, "requires_thruster_dry_run": true},
			{"id": "TH-02", "label": "确认最大持续时间、航速限制和禁用条件", "requires_confirmation": true},
			{"id": "TH-03", "label": "完成零输出功能检查并确认没有执行器连接", "requires_confirmation": true, "requires_no_actuation": true, "requires_thruster_dry_run": true},
			{"id": "TH-04", "label": "发出左/右侧推标准指令并收到复诵", "requires_confirmation": true, "requires_readback": true, "requires_thruster_dry_run": true},
			{"id": "TH-05", "label": "监控干运行计时、告警和中止口令", "requires_confirmation": true, "requires_thruster_dry_run": true},
			{"id": "TH-06", "label": "侧推归零并报告程序结束", "requires_confirmation": true, "requires_readback": true, "requires_thruster_dry_run": true},
		],
	},
}

@export var player_path: NodePath = NodePath("../Player")

var _player: Node3D
var _procedure_key := ""
var _step_index := 0
var _running := false
var _started_utc := ""
var _completed_steps: Array[Dictionary] = []
var _receipts: Array[Dictionary] = []
var _receipt_sequence := 0
var _training_profile := {
	"profile_id": "synthetic_port_operations_training_v1",
	"source": "simulator_procedural_training_default",
	"training_geometry_available": true,
	"berth_geometry_verified": false,
	"pilotage_and_tug_rules_verified": false,
	"official_depth_data": false,
	"thruster_configuration_verified": false,
	"actuation_connected": false,
	"production_authority": false,
}


func _ready() -> void:
	add_to_group(&"ship_port_operations_training_controller")
	_player = get_node_or_null(player_path) as Node3D


func list_procedures() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for key in PROCEDURES.keys():
		var procedure := PROCEDURES[key] as Dictionary
		result.append({
			"key": key,
			"name": procedure.get("name", key),
			"objective": procedure.get("objective", ""),
			"step_count": (procedure.get("steps", []) as Array).size(),
		})
	return result


func start_procedure(procedure_key: String) -> Dictionary:
	if not PROCEDURES.has(procedure_key):
		return _append_receipt("start_procedure", procedure_key, "REJECTED", {"reason": "UNKNOWN_PROCEDURE"})
	_procedure_key = procedure_key
	_step_index = 0
	_running = true
	_started_utc = Time.get_datetime_string_from_system(true)
	_completed_steps.clear()
	var receipt := _append_receipt("start_procedure", procedure_key, "ACCEPTED", {
		"procedure_name": (PROCEDURES[procedure_key] as Dictionary).get("name", procedure_key),
		"step_count": ((PROCEDURES[procedure_key] as Dictionary).get("steps", []) as Array).size(),
	})
	_emit_state()
	return receipt


func submit_current_step(evidence: Dictionary) -> Dictionary:
	if not _running or _procedure_key.is_empty():
		return _append_receipt("submit_step", "", "REJECTED", {"reason": "NO_ACTIVE_PROCEDURE"})
	var steps := (PROCEDURES[_procedure_key] as Dictionary).get("steps", []) as Array
	if _step_index >= steps.size():
		_running = false
		return _append_receipt("submit_step", "", "REJECTED", {"reason": "PROCEDURE_COMPLETE"})
	var step := steps[_step_index] as Dictionary
	var validation := _validate_step(step, evidence)
	if not bool(validation.get("passed", false)):
		return _append_receipt("submit_step", String(step.get("id", "")), "REJECTED", {
			"reason": validation.get("reason", "GATE_FAILED"),
			"requirements": step.duplicate(true),
			"runtime": validation.get("runtime", {}),
		})
	var completion := {
		"step": step.duplicate(true),
		"evidence": evidence.duplicate(true),
		"runtime": validation.get("runtime", {}),
		"completed_utc": Time.get_datetime_string_from_system(true),
	}
	_completed_steps.append(completion)
	var receipt := _append_receipt("submit_step", String(step.get("id", "")), "EXECUTED", completion)
	_step_index += 1
	if _step_index >= steps.size():
		_running = false
		_append_receipt("procedure_complete", _procedure_key, "EXECUTED", {"completed_steps": _completed_steps.size()})
	_emit_state()
	return receipt


func reset_procedure() -> Dictionary:
	var previous := _procedure_key
	_running = false
	_step_index = 0
	_completed_steps.clear()
	var receipt := _append_receipt("reset_procedure", previous, "ACCEPTED", {})
	_emit_state()
	return receipt


func get_training_profile() -> Dictionary:
	return _training_profile.duplicate(true)


func get_operation_snapshot() -> Dictionary:
	var procedure := PROCEDURES.get(_procedure_key, {}) as Dictionary
	var steps := procedure.get("steps", []) as Array
	var current_step := {}
	if _step_index >= 0 and _step_index < steps.size():
		current_step = (steps[_step_index] as Dictionary).duplicate(true)
	return {
		"format": SCHEMA_VERSION,
		"procedure_key": _procedure_key,
		"procedure_name": procedure.get("name", "未选择"),
		"objective": procedure.get("objective", ""),
		"running": _running,
		"started_utc": _started_utc,
		"step_index": _step_index,
		"step_count": steps.size(),
		"current_step": current_step,
		"completed_steps": _completed_steps.duplicate(true),
		"receipts": _receipts.duplicate(true),
		"complete": not steps.is_empty() and _step_index >= steps.size(),
		"training_profile": _training_profile.duplicate(true),
		"production_authority": false,
		"changes_motion_model": false,
		"changes_policy": false,
		"applies_physical_forces": false,
		"boundary": "Procedural port-operations training using synthetic geometry and explicit confirmations; no tug, anchor, mooring or thruster force is applied to the vessel.",
	}


func get_runtime_gate_snapshot() -> Dictionary:
	if _player == null or not is_instance_valid(_player):
		_player = get_node_or_null(player_path) as Node3D
	var telemetry := {}
	if _player != null and _player.has_method("get_ship_telemetry"):
		telemetry = _player.call("get_ship_telemetry") as Dictionary
	return {
		"ship_available": _player != null,
		"speed_knots": absf(float(telemetry.get("speed", 0.0))) * KNOTS_PER_MPS,
		"heading_degrees": telemetry.get("heading_degrees"),
		"collision_warning_active": telemetry.get("collision_warning_active", false),
		"actuation_connected": bool(_training_profile.get("actuation_connected", false)),
	}


func _validate_step(step: Dictionary, evidence: Dictionary) -> Dictionary:
	var runtime := get_runtime_gate_snapshot()
	if bool(step.get("requires_confirmation", false)) and not bool(evidence.get("confirmed", false)):
		return {"passed": false, "reason": "EXPLICIT_CONFIRMATION_REQUIRED", "runtime": runtime}
	if bool(step.get("requires_readback", false)) and not bool(evidence.get("readback_confirmed", false)):
		return {"passed": false, "reason": "CLOSED_LOOP_READBACK_REQUIRED", "runtime": runtime}
	if bool(step.get("requires_training_geometry_ack", false)):
		if not bool(evidence.get("training_geometry_acknowledged", false)):
			return {"passed": false, "reason": "TRAINING_GEOMETRY_ACKNOWLEDGEMENT_REQUIRED", "runtime": runtime}
		if not bool(_training_profile.get("training_geometry_available", false)):
			return {"passed": false, "reason": "TRAINING_GEOMETRY_UNAVAILABLE", "runtime": runtime}
	if step.has("max_speed_knots"):
		var limit := float(step.get("max_speed_knots", 0.0))
		if not bool(runtime.get("ship_available", false)):
			return {"passed": false, "reason": "SHIP_TELEMETRY_UNAVAILABLE", "runtime": runtime}
		if float(runtime.get("speed_knots", INF)) > limit:
			return {"passed": false, "reason": "SPEED_GATE_EXCEEDED", "runtime": runtime}
	if bool(step.get("requires_no_actuation", false)) and bool(_training_profile.get("actuation_connected", false)):
		return {"passed": false, "reason": "UNAUTHORIZED_ACTUATION_CONNECTED", "runtime": runtime}
	if bool(step.get("requires_thruster_dry_run", false)) and not bool(evidence.get("dry_run_confirmed", false)):
		return {"passed": false, "reason": "THRUSTER_DRY_RUN_CONFIRMATION_REQUIRED", "runtime": runtime}
	return {"passed": true, "reason": "GATES_PASSED", "runtime": runtime}


func _append_receipt(action: String, subject: String, status: String, detail: Dictionary) -> Dictionary:
	_receipt_sequence += 1
	var receipt := {
		"receipt_id": "PORTOPS-%06d" % _receipt_sequence,
		"sequence": _receipt_sequence,
		"utc": Time.get_datetime_string_from_system(true),
		"procedure_key": _procedure_key,
		"action": action,
		"subject": subject,
		"status": status,
		"detail": detail.duplicate(true),
	}
	_receipts.append(receipt)
	while _receipts.size() > MAX_RECEIPTS:
		_receipts.remove_at(0)
	operation_receipt_emitted.emit(receipt.duplicate(true))
	return receipt


func _emit_state() -> void:
	procedure_state_changed.emit(get_operation_snapshot())

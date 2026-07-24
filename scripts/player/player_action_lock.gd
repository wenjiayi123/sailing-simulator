class_name PlayerActionLock
extends Node

signal lock_state_changed(combined_mask: int, active_sources: Array[StringName])
signal lock_acquired(source: StringName, mask: int)
signal lock_released(source: StringName)
signal interrupt_requested(reason: StringName)

enum Channel {
	MOVEMENT = 1,
	JUMP = 2,
	ATTACK = 4,
	INTERACTION = 8,
	FREEZE_BODY = 16
}

const GAMEPLAY := Channel.MOVEMENT | Channel.JUMP | Channel.ATTACK | Channel.INTERACTION
const ALL := GAMEPLAY | Channel.FREEZE_BODY

var _locks: Dictionary = {}


func acquire(source: StringName, mask: int = ALL) -> void:
	if source.is_empty():
		push_warning("PlayerActionLock 拒绝了空来源锁。")
		return
	var sanitized_mask := mask & ALL
	if sanitized_mask == 0:
		return
	_locks[source] = sanitized_mask
	lock_acquired.emit(source, sanitized_mask)
	_emit_state_changed()


func release(source: StringName) -> void:
	if not _locks.erase(source):
		return
	lock_released.emit(source)
	_emit_state_changed()


func release_prefix(prefix: String) -> void:
	var removed: Array[StringName] = []
	for source_value in _locks.keys():
		var source := source_value as StringName
		if String(source).begins_with(prefix):
			removed.append(source)
	for source in removed:
		_locks.erase(source)
		lock_released.emit(source)
	if not removed.is_empty():
		_emit_state_changed()


func clear_all() -> void:
	if _locks.is_empty():
		return
	var previous_sources := get_active_sources()
	_locks.clear()
	for source in previous_sources:
		lock_released.emit(source)
	_emit_state_changed()


func request_interrupt(reason: StringName = &"external") -> void:
	interrupt_requested.emit(reason)


func is_locked(channel: Channel) -> bool:
	return (get_combined_mask() & channel) != 0


func is_any_locked(mask: int = ALL) -> bool:
	return (get_combined_mask() & mask) != 0


func has_source(source: StringName) -> bool:
	return _locks.has(source)


func get_source_mask(source: StringName) -> int:
	return int(_locks.get(source, 0))


func get_combined_mask() -> int:
	var combined := 0
	for mask_value in _locks.values():
		combined |= int(mask_value)
	return combined


func get_active_sources() -> Array[StringName]:
	var sources: Array[StringName] = []
	for source_value in _locks.keys():
		sources.append(source_value as StringName)
	sources.sort()
	return sources


func get_debug_text() -> String:
	if _locks.is_empty():
		return "UNLOCKED"
	var parts: PackedStringArray = []
	for source in get_active_sources():
		parts.append("%s=%d" % [source, get_source_mask(source)])
	return ", ".join(parts)


func _emit_state_changed() -> void:
	lock_state_changed.emit(get_combined_mask(), get_active_sources())

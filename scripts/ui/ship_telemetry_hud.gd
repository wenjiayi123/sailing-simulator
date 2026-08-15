extends CanvasLayer

const KNOTS_PER_MPS := 1.943844
const METERS_PER_NAUTICAL_MILE := 1852.0
const MAX_RUDDER_DEGREES := 35.0
const COLOR_PANEL := Color(0.006, 0.018, 0.034, 0.74)
const COLOR_CYAN := Color(0.28, 0.96, 1.0, 0.96)
const COLOR_GREEN := Color(0.46, 1.0, 0.58, 1.0)
const COLOR_AMBER := Color(1.0, 0.70, 0.24, 1.0)
const COLOR_SOFT := Color(0.70, 0.92, 1.0, 0.88)
const TOP_PANEL_HEIGHT := 114.0
const SIDE_PANEL_TOP := 222.0
const SIDE_PANEL_WIDTH := 224.0
const SIDE_PANEL_HEIGHT := 404.0
const BOTTOM_PANEL_WIDTH := 420.0
const BOTTOM_PANEL_HEIGHT := 58.0
const KEY_GUIDE_LEFT := 22.0
const KEY_GUIDE_TOP := 22.0
const KEY_GUIDE_WIDTH := 242.0
const KEY_GUIDE_HEIGHT := 112.0
const DEVELOPER_CREDIT_LEFT := 22.0
const DEVELOPER_CREDIT_TOP := 138.0
const DEVELOPER_CREDIT_WIDTH := 250.0
const DEVELOPER_CREDIT_HEIGHT := 76.0
const LEFT_AUX_LEFT := 22.0
const LEFT_AUX_TOP := 646.0
const LEFT_AUX_WIDTH := 286.0
const LEFT_AUX_HEIGHT := 252.0
const ALERT_PANEL_LEFT := 22.0
const ALERT_PANEL_TOP := 912.0
const ALERT_PANEL_WIDTH := 390.0
const ALERT_PANEL_HEIGHT := 120.0
const ENV_PANEL_WIDTH := 306.0
const ENV_PANEL_TOP := 646.0
const ENV_PANEL_HEIGHT := 172.0
const SENSOR_PANEL_WIDTH := 306.0
const SENSOR_PANEL_TOP := 832.0
const SENSOR_PANEL_HEIGHT := 194.0
const COMMAND_DECK_WIDTH := 760.0
const COMMAND_DECK_HEIGHT := 174.0
const MINI_DASH_TOP := 138.0
const MINI_DASH_SIZE := 126.0
const RADAR_SCOPE_LEFT := 266.0
const RADAR_SCOPE_TOP := 276.0
const RADAR_SCOPE_SIZE := 248.0
const RADAR_SCOPE_RANGE_METERS := 260.0
const HUD_LAYOUT_FILE := "user://ship_hud_layout.cfg"
const HUD_LAYOUT_EDIT_KEY := KEY_L
const HUD_LAYOUT_RESET_KEY := KEY_BACKSPACE

@export var player_path: NodePath = NodePath("../Player")

var _hud_root: Control
var _player: Node3D
var _labels: Dictionary = {}
var _status_label: Label
var _weather_label: Label
var _heading_label: Label
var _speed_gauge: SpeedGauge
var _compass_tape: CompassTape
var _compass_rose: CompassRose
var _rudder_gauge: RudderGauge
var _telegraph: TelegraphBar
var _route_orb: RouteOrbGauge
var _engine_core: EngineCoreGauge
var _safety_diamond: SafetyDiamondGauge
var _radar_scope: RadarScope
var _environment_dial: EnvironmentDial
var _sensor_grid: SensorFusionGrid
var _trend_chart: NavigationTrendChart
var _route_system: Node
var _obstacle_system: Node
var _weather_time_source: Node
var _scenario_source: Node
var _last_alert_text := ""
var _mileage_meters: float = 0.0
var _last_player_position: Vector3 = Vector3.ZERO
var _has_last_player_position := false
var _elapsed_time: float = 0.0
var _layout_draggables: Array[Control] = []
var _default_layout_offsets: Dictionary = {}
var _layout_edit_overlay: LayoutEditOverlay
var _layout_edit_enabled := false
var _dragged_control: Control
var _drag_mouse_origin := Vector2.ZERO
var _drag_offsets_origin: Dictionary = {}


class HoloPanel:
	extends PanelContainer

	var fill_color: Color = Color(0.006, 0.018, 0.034, 0.76)
	var accent_color: Color = Color(0.28, 0.96, 1.0, 0.90)
	var cut_size: float = 18.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func _draw() -> void:
		if size.x < 32.0 or size.y < 32.0:
			return
		var cut := minf(cut_size, minf(size.x, size.y) * 0.22)
		var polygon := PackedVector2Array([
			Vector2(cut, 0.0),
			Vector2(size.x - cut, 0.0),
			Vector2(size.x, cut),
			Vector2(size.x, size.y - cut),
			Vector2(size.x - cut, size.y),
			Vector2(cut, size.y),
			Vector2(0.0, size.y - cut),
			Vector2(0.0, cut)
		])
		draw_colored_polygon(polygon, fill_color)

		var border := accent_color
		border.a = 0.66
		var closed := polygon
		closed.append(polygon[0])
		draw_polyline(closed, border, 1.2, true)

		var glow := accent_color
		glow.a = 0.18
		draw_polyline(closed, glow, 5.0, true)

		var scan := accent_color
		scan.a = 0.035
		for y in range(18, int(size.y), 26):
			draw_line(Vector2(cut * 0.8, y), Vector2(size.x - cut * 0.8, y), scan, 1.0, true)

		_draw_corner(Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(0.0, 1.0), cut, border)
		_draw_corner(Vector2(size.x, 0.0), Vector2(-1.0, 0.0), Vector2(0.0, 1.0), cut, border)
		_draw_corner(Vector2(size.x, size.y), Vector2(-1.0, 0.0), Vector2(0.0, -1.0), cut, border)
		_draw_corner(Vector2(0.0, size.y), Vector2(1.0, 0.0), Vector2(0.0, -1.0), cut, border)

	func _draw_corner(origin: Vector2, horizontal: Vector2, vertical: Vector2, cut: float, color: Color) -> void:
		var length := cut + 22.0
		draw_line(origin + horizontal * cut, origin + horizontal * length, color, 2.0, true)
		draw_line(origin + vertical * cut, origin + vertical * length, color, 2.0, true)


class BridgeReticle:
	extends Control

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func _draw() -> void:
		var accent := Color(0.28, 0.96, 1.0, 0.22)
		var soft := Color(0.46, 1.0, 0.58, 0.16)
		var center := size * 0.5
		var wing := minf(size.x, size.y) * 0.115
		draw_line(center + Vector2(-wing, 0.0), center + Vector2(-38.0, 0.0), accent, 1.2, true)
		draw_line(center + Vector2(38.0, 0.0), center + Vector2(wing, 0.0), accent, 1.2, true)
		draw_line(center + Vector2(0.0, -wing * 0.55), center + Vector2(0.0, -24.0), accent, 1.0, true)
		draw_line(center + Vector2(0.0, 24.0), center + Vector2(0.0, wing * 0.55), accent, 1.0, true)
		draw_arc(center, 52.0, deg_to_rad(205.0), deg_to_rad(335.0), 40, soft, 1.0, true)
		draw_arc(center, 52.0, deg_to_rad(25.0), deg_to_rad(155.0), 40, soft, 1.0, true)


class LayoutEditOverlay:
	extends Control

	var tracked_controls: Array[Control] = []
	var active_control: Control
	var edit_enabled := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if not edit_enabled:
			return
		for control in tracked_controls:
			if control == null or not is_instance_valid(control) or not control.visible:
				continue
			var global_rect := control.get_global_rect()
			var rect := Rect2(global_rect.position, global_rect.size)
			var color := Color(1.0, 0.72, 0.26, 0.92) if control == active_control else Color(0.28, 0.96, 1.0, 0.62)
			draw_rect(rect, Color(color.r, color.g, color.b, 0.05), true)
			draw_rect(rect, color, false, 1.4)
			var corner := minf(18.0, minf(rect.size.x, rect.size.y) * 0.22)
			draw_line(rect.position, rect.position + Vector2(corner, 0.0), color, 2.0, true)
			draw_line(rect.position, rect.position + Vector2(0.0, corner), color, 2.0, true)
			draw_line(rect.position + Vector2(rect.size.x, 0.0), rect.position + Vector2(rect.size.x - corner, 0.0), color, 2.0, true)
			draw_line(rect.position + Vector2(rect.size.x, 0.0), rect.position + Vector2(rect.size.x, corner), color, 2.0, true)
			draw_line(rect.position + rect.size, rect.position + rect.size - Vector2(corner, 0.0), color, 2.0, true)
			draw_line(rect.position + rect.size, rect.position + rect.size - Vector2(0.0, corner), color, 2.0, true)
			draw_line(rect.position + Vector2(0.0, rect.size.y), rect.position + Vector2(corner, rect.size.y), color, 2.0, true)
			draw_line(rect.position + Vector2(0.0, rect.size.y), rect.position + Vector2(0.0, rect.size.y - corner), color, 2.0, true)


class SpeedGauge:
	extends Control

	var speed_knots: float = 0.0
	var max_knots: float = 35.0
	var accent: Color = Color(0.28, 0.96, 1.0, 0.96)

	func set_speed(value: float, max_value: float) -> void:
		speed_knots = value
		max_knots = maxf(max_value, 1.0)
		queue_redraw()

	func _draw() -> void:
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.36
		var start_angle := deg_to_rad(138.0)
		var end_angle := deg_to_rad(402.0)
		var ratio := clampf(absf(speed_knots) / max_knots, 0.0, 1.0)
		draw_arc(center, radius + 12.0, 0.0, TAU, 112, Color(0.28, 0.96, 1.0, 0.12), 1.0, true)
		draw_arc(center, radius * 0.62, 0.0, TAU, 80, Color(0.46, 1.0, 0.58, 0.12), 1.0, true)
		for spoke in range(0, 360, 30):
			var angle := deg_to_rad(float(spoke))
			var inner := center + Vector2(cos(angle), sin(angle)) * (radius * 0.66)
			var outer := center + Vector2(cos(angle), sin(angle)) * (radius + 8.0)
			draw_line(inner, outer, Color(0.28, 0.96, 1.0, 0.09), 1.0, true)
		draw_arc(center, radius, start_angle, end_angle, 96, Color(0.07, 0.20, 0.28, 0.88), 6.0, true)
		draw_arc(center, radius, start_angle, lerpf(start_angle, end_angle, ratio), 96, accent, 7.0, true)

		for index in range(0, 12):
			var tick_ratio := float(index) / 11.0
			var angle := lerpf(start_angle, end_angle, tick_ratio)
			var outer := center + Vector2(cos(angle), sin(angle)) * (radius + 5.0)
			var inner := center + Vector2(cos(angle), sin(angle)) * (radius - (9.0 if index % 2 == 0 else 5.0))
			draw_line(inner, outer, Color(0.67, 0.95, 1.0, 0.75), 1.2, true)

		var needle_angle := lerpf(start_angle, end_angle, ratio)
		var needle_end := center + Vector2(cos(needle_angle), sin(needle_angle)) * (radius - 12.0)
		draw_line(center, needle_end, Color(1.0, 0.92, 0.52, 0.95), 2.0, true)
		draw_circle(center, 3.5, Color(0.95, 1.0, 1.0, 0.96))

		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(0.0, center.y - 10.0), "SPEED", HORIZONTAL_ALIGNMENT_CENTER, size.x, 9, Color(0.68, 0.92, 1.0, 0.82))
		draw_string(font, Vector2(0.0, center.y + 8.0), "%05.1f kn" % speed_knots, HORIZONTAL_ALIGNMENT_CENTER, size.x, 18, Color(0.46, 1.0, 0.58, 1.0))
		draw_string(font, Vector2(0.0, center.y + 29.0), "LIVE WATER SPEED", HORIZONTAL_ALIGNMENT_CENTER, size.x, 9, Color(0.65, 0.82, 0.90, 0.78))


class CompassTape:
	extends Control

	var heading_degrees: float = 0.0
	var course_degrees: float = 0.0
	var target_degrees: float = 0.0

	func set_heading(heading: float, course: float, target: float) -> void:
		heading_degrees = fposmod(heading, 360.0)
		course_degrees = fposmod(course, 360.0)
		target_degrees = fposmod(target, 360.0)
		queue_redraw()

	func _draw() -> void:
		var center_x := size.x * 0.5
		var center_y := size.y * 0.56
		var tape_width := maxf(size.x - 44.0, 120.0)
		var left := (size.x - tape_width) * 0.5
		var track_top := center_y - 14.0
		var track_bottom := center_y + 15.0
		var wedge := PackedVector2Array([
			Vector2(left + 16.0, track_top),
			Vector2(left + tape_width - 16.0, track_top),
			Vector2(left + tape_width, center_y),
			Vector2(left + tape_width - 16.0, track_bottom),
			Vector2(left + 16.0, track_bottom),
			Vector2(left, center_y)
		])
		draw_colored_polygon(wedge, Color(0.02, 0.08, 0.12, 0.46))
		var rim := Color(0.21, 0.86, 1.0, 0.58)
		var closed := wedge
		closed.append(wedge[0])
		draw_polyline(closed, rim, 1.15, true)
		draw_line(Vector2(left + 28.0, center_y), Vector2(left + tape_width - 28.0, center_y), Color(0.28, 0.96, 1.0, 0.30), 1.0, true)

		var font := ThemeDB.fallback_font
		for offset in range(-90, 91, 10):
			var x := center_x + float(offset) / 90.0 * tape_width * 0.5
			var tick_heading := fposmod(heading_degrees + float(offset), 360.0)
			var major := offset % 30 == 0
			var tick_height := 18.0 if major else 10.0
			var color := Color(0.76, 0.98, 1.0, 0.90 if major else 0.55)
			draw_line(Vector2(x, center_y + 14.0), Vector2(x, center_y + 14.0 - tick_height), color, 1.1, true)
			if major:
				draw_string(font, Vector2(x - 26.0, center_y - 25.0), _bearing_label(tick_heading), HORIZONTAL_ALIGNMENT_CENTER, 52.0, 11, color)

		_draw_marker(_bearing_delta(course_degrees, heading_degrees), Color(0.45, 1.0, 0.58, 0.95), 0.42, tape_width, center_x, center_y, "COG")
		_draw_marker(_bearing_delta(target_degrees, heading_degrees), Color(1.0, 0.72, 0.28, 0.95), 0.34, tape_width, center_x, center_y, "TGT")

		draw_line(Vector2(center_x, center_y - 23.0), Vector2(center_x, center_y + 22.0), Color(0.96, 1.0, 1.0, 0.96), 1.5, true)
		draw_circle(Vector2(center_x, center_y - 23.0), 2.8, Color(0.96, 1.0, 1.0, 0.92))
		draw_string(font, Vector2(0.0, size.y - 6.0), "COURSE %06.2f     TARGET %06.2f" % [course_degrees, target_degrees], HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, Color(0.70, 0.90, 1.0, 0.82))

	func _draw_marker(delta: float, color: Color, y_ratio: float, tape_width: float, center_x: float, center_y: float, label: String) -> void:
		var x := center_x + clampf(delta / 90.0, -1.0, 1.0) * tape_width * 0.5
		var y := center_y + size.y * (y_ratio - 0.50)
		draw_line(Vector2(x, y - 9.0), Vector2(x, y + 9.0), color, 1.5, true)
		draw_circle(Vector2(x, y), 3.0, color)
		draw_string(ThemeDB.fallback_font, Vector2(x - 18.0, y - 12.0), label, HORIZONTAL_ALIGNMENT_CENTER, 36.0, 9, color)

	func _bearing_delta(value: float, reference: float) -> float:
		return wrapf(value - reference, -180.0, 180.0)

	func _bearing_label(value: float) -> String:
		var snapped := int(round(value / 10.0) * 10) % 360
		if snapped == 0:
			return "N"
		if snapped == 90:
			return "E"
		if snapped == 180:
			return "S"
		if snapped == 270:
			return "W"
		return "%03d" % snapped


class CompassRose:
	extends Control

	var heading_degrees: float = 0.0
	var course_degrees: float = 0.0
	var target_degrees: float = 0.0

	func set_heading(heading: float, course: float, target: float) -> void:
		heading_degrees = fposmod(heading, 360.0)
		course_degrees = fposmod(course, 360.0)
		target_degrees = fposmod(target, 360.0)
		queue_redraw()

	func _draw() -> void:
		var center := Vector2(size.x * 0.5, size.y * 0.47)
		var radius := minf(size.x, size.y) * 0.30
		var font := ThemeDB.fallback_font
		if radius < 26.0:
			return

		draw_arc(center, radius + 10.0, 0.0, TAU, 96, Color(0.28, 0.96, 1.0, 0.20), 1.0, true)
		draw_arc(center, radius, 0.0, TAU, 128, Color(0.28, 0.96, 1.0, 0.55), 1.4, true)
		draw_arc(center, radius * 0.64, 0.0, TAU, 96, Color(0.46, 1.0, 0.58, 0.20), 1.0, true)
		draw_arc(center, radius * 0.30, 0.0, TAU, 64, Color(0.70, 0.92, 1.0, 0.16), 1.0, true)

		for bearing in range(0, 360, 15):
			var angle := deg_to_rad(float(bearing) - heading_degrees - 90.0)
			var major := bearing % 45 == 0
			var outer := center + Vector2(cos(angle), sin(angle)) * radius
			var inner := center + Vector2(cos(angle), sin(angle)) * (radius - (10.0 if major else 5.0))
			var tick := Color(0.76, 0.98, 1.0, 0.88 if major else 0.48)
			draw_line(inner, outer, tick, 1.4 if major else 1.0, true)
			if major:
				var label_pos := center + Vector2(cos(angle), sin(angle)) * (radius - 23.0)
				draw_string(font, label_pos - Vector2(14.0, -4.0), _bearing_label(float(bearing)), HORIZONTAL_ALIGNMENT_CENTER, 28.0, 11, tick)

		_draw_bearing_marker(course_degrees, Color(0.46, 1.0, 0.58, 0.96), radius, center, "C")
		_draw_bearing_marker(target_degrees, Color(1.0, 0.70, 0.24, 0.96), radius + 7.0, center, "T")

		var bow := PackedVector2Array([
			center + Vector2(0.0, -radius - 16.0),
			center + Vector2(-6.0, -radius - 3.0),
			center + Vector2(6.0, -radius - 3.0)
		])
		draw_colored_polygon(bow, Color(0.96, 1.0, 1.0, 0.95))
		draw_line(center, center + Vector2(0.0, -radius + 8.0), Color(0.96, 1.0, 1.0, 0.72), 1.2, true)
		draw_circle(center, 3.4, Color(0.96, 1.0, 1.0, 0.95))

		draw_string(font, Vector2(0.0, size.y - 24.0), "AI COMPASS / 指南针", HORIZONTAL_ALIGNMENT_CENTER, size.x, 9, Color(0.70, 0.92, 1.0, 0.78))
		draw_string(font, Vector2(0.0, size.y - 8.0), "%06.2f deg  %s" % [heading_degrees, _cardinal(heading_degrees)], HORIZONTAL_ALIGNMENT_CENTER, size.x, 12, Color(0.46, 1.0, 0.58, 0.96))

	func _draw_bearing_marker(bearing: float, color: Color, radius: float, center: Vector2, label: String) -> void:
		var angle := deg_to_rad(fposmod(bearing, 360.0) - heading_degrees - 90.0)
		var point := center + Vector2(cos(angle), sin(angle)) * radius
		draw_circle(point, 3.2, color)
		draw_string(ThemeDB.fallback_font, point + Vector2(-10.0, -11.0), label, HORIZONTAL_ALIGNMENT_CENTER, 20.0, 9, color)

	func _bearing_label(value: float) -> String:
		var snapped := int(round(value / 45.0) * 45) % 360
		if snapped == 0:
			return "N"
		if snapped == 45:
			return "NE"
		if snapped == 90:
			return "E"
		if snapped == 135:
			return "SE"
		if snapped == 180:
			return "S"
		if snapped == 225:
			return "SW"
		if snapped == 270:
			return "W"
		return "NW"

	func _cardinal(degrees: float) -> String:
		var labels := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
		var index := int(round(fposmod(degrees, 360.0) / 45.0)) % labels.size()
		return labels[index]


class RudderGauge:
	extends Control

	var rudder: float = 0.0

	func set_rudder(value: float) -> void:
		rudder = clampf(value, -1.0, 1.0)
		queue_redraw()

	func _draw() -> void:
		var center := Vector2(size.x * 0.5, size.y * 0.58)
		var width := size.x - 34.0
		var left := center.x - width * 0.5
		var right := center.x + width * 0.5
		var font := ThemeDB.fallback_font
		draw_arc(center, width * 0.34, deg_to_rad(205.0), deg_to_rad(335.0), 64, Color(0.14, 0.50, 0.66, 0.58), 7.0, true)
		draw_line(Vector2(left, center.y), Vector2(right, center.y), Color(0.14, 0.50, 0.66, 0.82), 3.0, true)
		draw_line(Vector2(center.x, center.y - 13.0), Vector2(center.x, center.y + 13.0), Color(0.92, 1.0, 1.0, 0.82), 1.2, true)
		for index in range(-4, 5):
			var x := center.x + float(index) / 4.0 * width * 0.5
			var tick_height := 14.0 if index == 0 else 8.0
			draw_line(Vector2(x, center.y - tick_height), Vector2(x, center.y + tick_height), Color(0.72, 0.94, 1.0, 0.72), 1.0, true)
		var needle_x := center.x + rudder * width * 0.5
		var needle_color := Color(1.0, 0.76, 0.28, 1.0) if absf(rudder) > 0.35 else Color(0.46, 1.0, 0.58, 1.0)
		var blade := PackedVector2Array([
			Vector2(needle_x, center.y - 25.0),
			Vector2(needle_x - 5.0, center.y),
			Vector2(needle_x, center.y + 25.0),
			Vector2(needle_x + 5.0, center.y)
		])
		draw_colored_polygon(blade, needle_color)
		draw_string(font, Vector2(0.0, 7.0), "RUDDER VECTOR", HORIZONTAL_ALIGNMENT_CENTER, size.x, 9, Color(0.70, 0.92, 1.0, 0.82))
		draw_string(font, Vector2(0.0, center.y + 29.0), "PORT   %+05.1f deg   STBD" % (rudder * 35.0), HORIZONTAL_ALIGNMENT_CENTER, size.x, 12, needle_color)


class TelegraphBar:
	extends Control

	var throttle: float = 0.0

	func set_throttle(value: float) -> void:
		throttle = clampf(value, -1.0, 1.0)
		queue_redraw()

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var left := 16.0
		var right := size.x - 16.0
		var center_y := 30.0
		var track := PackedVector2Array([
			Vector2(left + 10.0, center_y - 13.0),
			Vector2(right - 10.0, center_y - 13.0),
			Vector2(right, center_y),
			Vector2(right - 10.0, center_y + 13.0),
			Vector2(left + 10.0, center_y + 13.0),
			Vector2(left, center_y)
		])
		draw_colored_polygon(track, Color(0.03, 0.09, 0.12, 0.72))
		var track_closed := track
		track_closed.append(track[0])
		draw_polyline(track_closed, Color(0.18, 0.70, 0.88, 0.84), 1.2, true)
		var center_x := size.x * 0.5
		draw_line(Vector2(center_x, center_y - 18.0), Vector2(center_x, center_y + 18.0), Color(0.95, 1.0, 1.0, 0.82), 1.0, true)
		for index in range(-4, 5):
			var x := center_x + float(index) / 4.0 * (right - left) * 0.5
			draw_line(Vector2(x, center_y + 13.0), Vector2(x, center_y + 20.0), Color(0.68, 0.92, 1.0, 0.60), 1.0, true)
		var marker_x := center_x + throttle * (right - left) * 0.5
		var marker := PackedVector2Array([
			Vector2(marker_x, center_y - 21.0),
			Vector2(marker_x - 7.0, center_y - 6.0),
			Vector2(marker_x - 7.0, center_y + 16.0),
			Vector2(marker_x, center_y + 23.0),
			Vector2(marker_x + 7.0, center_y + 16.0),
			Vector2(marker_x + 7.0, center_y - 6.0)
		])
		draw_colored_polygon(marker, Color(1.0, 0.72, 0.26, 0.96))
		draw_string(font, Vector2(0.0, 4.0), "ENGINE TELEGRAPH", HORIZONTAL_ALIGNMENT_CENTER, size.x, 9, Color(0.70, 0.92, 1.0, 0.82))
		draw_string(font, Vector2(0.0, 53.0), _gear_text(throttle), HORIZONTAL_ALIGNMENT_CENTER, size.x, 12, Color(0.46, 1.0, 0.58, 1.0))

	func _gear_text(value: float) -> String:
		if value > 0.82:
			return "FULL AHEAD // 前进四档"
		if value > 0.58:
			return "HALF AHEAD // 前进三档"
		if value > 0.24:
			return "SLOW AHEAD // 前进二档"
		if value > 0.06:
			return "DEAD SLOW // 前进一档"
		if value < -0.08:
			return "ASTERN // 倒车"
		return "STOP // 停车"


class RouteOrbGauge:
	extends Control

	var active := false
	var distance_m := 0.0
	var deviation_m := 0.0
	var eta_text := "--"

	func set_route(distance: float, deviation: float, eta: String, is_active: bool) -> void:
		distance_m = maxf(distance, 0.0)
		deviation_m = maxf(deviation, 0.0)
		eta_text = eta
		active = is_active
		queue_redraw()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.36
		var accent := Color(0.28, 0.96, 1.0, 0.88)
		var green := Color(0.46, 1.0, 0.58, 0.96)
		var amber := Color(1.0, 0.70, 0.24, 0.96)
		var fill := Color(0.006, 0.020, 0.034, 0.68)
		draw_circle(center, radius + 18.0, fill)
		draw_arc(center, radius + 19.0, 0.0, TAU, 128, Color(0.28, 0.96, 1.0, 0.28), 1.2, true)
		draw_arc(center, radius + 10.0, 0.0, TAU, 128, Color(0.46, 1.0, 0.58, 0.13), 1.0, true)
		for tick in range(0, 360, 30):
			var angle := deg_to_rad(float(tick) - 90.0)
			var outer := center + Vector2(cos(angle), sin(angle)) * (radius + 17.0)
			var inner := center + Vector2(cos(angle), sin(angle)) * (radius + (8.0 if tick % 90 == 0 else 12.0))
			draw_line(inner, outer, Color(0.70, 0.94, 1.0, 0.58), 1.0, true)

		var distance_ratio := clampf(1.0 - distance_m / 240.0, 0.0, 1.0)
		var arc_color := green if active else Color(0.70, 0.92, 1.0, 0.32)
		draw_arc(center, radius + 3.0, deg_to_rad(-90.0), deg_to_rad(-90.0 + 330.0 * distance_ratio), 96, arc_color, 5.0, true)
		var xte_color := amber if deviation_m > 18.0 else accent
		draw_arc(center, radius - 8.0, deg_to_rad(210.0), deg_to_rad(330.0), 64, xte_color, 3.0, true)

		draw_string(font, Vector2(0.0, center.y - 32.0), "ROUTE", HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, Color(0.70, 0.92, 1.0, 0.82))
		draw_string(font, Vector2(0.0, center.y - 12.0), "ETA " + eta_text, HORIZONTAL_ALIGNMENT_CENTER, size.x, 15, green if active else Color(0.70, 0.92, 1.0, 0.56))
		var waypoint_text := "%04.0f m WP" % distance_m if active else "NO ROUTE"
		draw_string(font, Vector2(0.0, center.y + 8.0), waypoint_text, HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, accent)
		draw_string(font, Vector2(0.0, center.y + 25.0), "XTE %04.0f m" % deviation_m, HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, xte_color)


class EngineCoreGauge:
	extends Control

	var speed_ratio := 0.0
	var throttle_load := 0.0
	var turn_authority := 0.0
	var alert := false

	func set_systems(speed_value: float, throttle_value: float, turn_value: float, is_alert: bool) -> void:
		speed_ratio = clampf(speed_value, 0.0, 1.0)
		throttle_load = clampf(throttle_value, 0.0, 1.0)
		turn_authority = clampf(turn_value, 0.0, 1.0)
		alert = is_alert
		queue_redraw()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.39
		var accent := Color(0.28, 0.96, 1.0, 0.88)
		var green := Color(0.46, 1.0, 0.58, 0.96)
		var amber := Color(1.0, 0.70, 0.24, 0.96)
		var shell := PackedVector2Array()
		for index in range(6):
			var angle := deg_to_rad(60.0 * float(index) - 30.0)
			shell.append(center + Vector2(cos(angle), sin(angle)) * (radius + 15.0))
		draw_colored_polygon(shell, Color(0.006, 0.020, 0.034, 0.68))
		var closed := shell
		closed.append(shell[0])
		draw_polyline(closed, accent if not alert else amber, 1.3, true)
		draw_polyline(closed, Color(0.28, 0.96, 1.0, 0.12), 5.0, true)

		_draw_ratio_arc(center, radius + 2.0, throttle_load, Color(1.0, 0.70, 0.24, 0.95), 6.0)
		_draw_ratio_arc(center, radius - 10.0, speed_ratio, Color(0.46, 1.0, 0.58, 0.95), 4.0)
		_draw_ratio_arc(center, radius - 22.0, turn_authority, Color(0.28, 0.96, 1.0, 0.88), 3.0)
		draw_circle(center, 4.0, Color(0.96, 1.0, 1.0, 0.92))
		draw_line(center + Vector2(-radius * 0.45, 0.0), center + Vector2(radius * 0.45, 0.0), Color(0.70, 0.92, 1.0, 0.20), 1.0, true)
		draw_line(center + Vector2(0.0, -radius * 0.45), center + Vector2(0.0, radius * 0.45), Color(0.70, 0.92, 1.0, 0.20), 1.0, true)

		draw_string(font, Vector2(0.0, center.y - 33.0), "ENGINE CORE", HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, Color(0.70, 0.92, 1.0, 0.82))
		draw_string(font, Vector2(0.0, center.y - 12.0), "LOAD %02d%%" % int(round(throttle_load * 100.0)), HORIZONTAL_ALIGNMENT_CENTER, size.x, 15, amber)
		draw_string(font, Vector2(0.0, center.y + 9.0), "SPD %02d%%  TURN %02d%%" % [int(round(speed_ratio * 100.0)), int(round(turn_authority * 100.0))], HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, green)
		draw_string(font, Vector2(0.0, center.y + 27.0), "AI DRIVE BUS", HORIZONTAL_ALIGNMENT_CENTER, size.x, 9, accent)

	func _draw_ratio_arc(center: Vector2, radius: float, ratio: float, color: Color, width: float) -> void:
		draw_arc(center, radius, deg_to_rad(130.0), deg_to_rad(410.0), 96, Color(0.12, 0.34, 0.42, 0.45), width, true)
		draw_arc(center, radius, deg_to_rad(130.0), deg_to_rad(130.0 + 280.0 * clampf(ratio, 0.0, 1.0)), 96, color, width, true)


class SafetyDiamondGauge:
	extends Control

	var warning_text := "CLEAR"
	var drift_degrees := 0.0
	var deviation_m := 0.0
	var alert := false

	func set_status(message: String, drift_value: float, deviation_value: float, is_alert: bool) -> void:
		warning_text = message
		drift_degrees = absf(drift_value)
		deviation_m = maxf(deviation_value, 0.0)
		alert = is_alert
		queue_redraw()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.43
		var accent := Color(0.28, 0.96, 1.0, 0.84)
		var green := Color(0.46, 1.0, 0.58, 0.96)
		var amber := Color(1.0, 0.70, 0.24, 0.96)
		var status_color := amber if alert else green
		var diamond := PackedVector2Array([
			center + Vector2(0.0, -radius - 12.0),
			center + Vector2(radius + 16.0, 0.0),
			center + Vector2(0.0, radius + 12.0),
			center + Vector2(-radius - 16.0, 0.0)
		])
		draw_colored_polygon(diamond, Color(0.006, 0.020, 0.034, 0.70))
		var closed := diamond
		closed.append(diamond[0])
		draw_polyline(closed, status_color, 1.3, true)
		draw_polyline(closed, Color(status_color.r, status_color.g, status_color.b, 0.14), 5.0, true)
		draw_line(diamond[0], diamond[2], Color(0.70, 0.92, 1.0, 0.14), 1.0, true)
		draw_line(diamond[1], diamond[3], Color(0.70, 0.92, 1.0, 0.14), 1.0, true)
		draw_arc(center, radius * 0.58, 0.0, TAU, 80, accent, 1.0, true)

		var safety_text := "ALERT" if alert else "CLEAR"
		if not alert and drift_degrees > 18.0:
			safety_text = "DRIFT"
			status_color = amber
		draw_string(font, Vector2(0.0, center.y - 34.0), "SAFETY", HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, Color(0.70, 0.92, 1.0, 0.82))
		draw_string(font, Vector2(0.0, center.y - 13.0), safety_text, HORIZONTAL_ALIGNMENT_CENTER, size.x, 16, status_color)
		draw_string(font, Vector2(0.0, center.y + 9.0), "DRIFT %04.1f" % drift_degrees, HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, accent)
		draw_string(font, Vector2(0.0, center.y + 27.0), "XTE %04.0f m" % deviation_m, HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, status_color)


class RadarScope:
	extends Control

	var ship_position := Vector3.ZERO
	var heading_degrees := 0.0
	var radar_range := 260.0
	var route_points: Array = []
	var route_loop := false
	var route_active := false
	var active_waypoint_index := -1
	var obstacles: Array = []
	var box_obstacles: Array = []
	var boundary_half_extent := 0.0

	func set_radar_data(
		position: Vector3,
		heading: float,
		route_data: Dictionary,
		obstacle_data: Dictionary,
		range_meters: float
	) -> void:
		ship_position = position
		heading_degrees = heading
		radar_range = maxf(range_meters, 1.0)
		route_points = route_data.get("points", [])
		route_loop = bool(route_data.get("loop", false))
		route_active = bool(route_data.get("active", false))
		active_waypoint_index = int(route_data.get("current_index", -1))
		obstacles = obstacle_data.get("rocks", [])
		box_obstacles = obstacle_data.get("boxes", [])
		boundary_half_extent = float(obstacle_data.get("boundary_half_extent", 0.0))
		queue_redraw()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.43
		var cyan := Color(0.28, 0.96, 1.0, 0.88)
		var green := Color(0.46, 1.0, 0.58, 0.96)
		var amber := Color(1.0, 0.70, 0.24, 0.96)
		var red := Color(1.0, 0.30, 0.24, 0.92)

		draw_circle(center, radius + 22.0, Color(0.006, 0.020, 0.034, 0.74))
		draw_arc(center, radius + 21.0, 0.0, TAU, 160, Color(0.28, 0.96, 1.0, 0.42), 1.4, true)
		draw_arc(center, radius + 12.0, 0.0, TAU, 128, Color(0.46, 1.0, 0.58, 0.12), 1.0, true)
		for ring in [0.33, 0.66, 1.0]:
			draw_arc(center, radius * float(ring), 0.0, TAU, 128, Color(0.28, 0.96, 1.0, 0.16), 1.0, true)
		for bearing in range(0, 360, 15):
			var angle := deg_to_rad(float(bearing) - 90.0)
			var major := bearing % 45 == 0
			var inner := center + Vector2(cos(angle), sin(angle)) * (radius - (13.0 if major else 7.0))
			var outer := center + Vector2(cos(angle), sin(angle)) * radius
			draw_line(inner, outer, Color(0.70, 0.94, 1.0, 0.70 if major else 0.32), 1.1 if major else 0.8, true)
		draw_line(center + Vector2(-radius, 0.0), center + Vector2(radius, 0.0), Color(0.28, 0.96, 1.0, 0.18), 1.0, true)
		draw_line(center + Vector2(0.0, -radius), center + Vector2(0.0, radius), Color(0.28, 0.96, 1.0, 0.18), 1.0, true)

		_draw_boundary(center, radius, cyan)
		_draw_route(center, radius, cyan, amber)
		_draw_box_obstacles(center, radius, amber)
		_draw_obstacles(center, radius, red, amber)
		_draw_ship(center, green)
		_draw_sweep(center, radius)

		draw_string(font, Vector2(0.0, 14.0), "RADAR // 小地图", HORIZONTAL_ALIGNMENT_CENTER, size.x, 12, cyan)
		draw_string(font, Vector2(0.0, size.y - 23.0), "RNG %03d m   HDG %03d" % [int(radar_range), int(round(heading_degrees)) % 360], HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, Color(0.70, 0.92, 1.0, 0.82))
		draw_string(font, Vector2(0.0, size.y - 8.0), "SHIP  WP  OBSTACLE  ROUTE", HORIZONTAL_ALIGNMENT_CENTER, size.x, 8, Color(0.70, 0.92, 1.0, 0.66))

	func _draw_route(center: Vector2, radius: float, route_color: Color, active_color: Color) -> void:
		if route_points.is_empty():
			return
		for index in range(route_points.size() - 1):
			_draw_route_segment(index, index + 1, center, radius, route_color)
		if route_loop and route_points.size() > 2:
			_draw_route_segment(route_points.size() - 1, 0, center, radius, route_color)

		var font := ThemeDB.fallback_font
		for index in range(route_points.size()):
			var point_data: Dictionary = route_points[index]
			var point_position := point_data.get("position", Vector3.ZERO) as Vector3
			var screen := _world_to_radar(point_position, center, radius)
			if not _inside_scope(screen, center, radius + 8.0):
				continue
			var active := bool(point_data.get("active", false)) or index == active_waypoint_index
			var color := active_color if active and route_active else route_color
			draw_circle(screen, 4.8 if active else 3.4, color)
			draw_arc(screen, 10.0 if active else 7.0, 0.0, TAU, 32, Color(color.r, color.g, color.b, 0.34), 1.0, true)
			draw_string(font, screen + Vector2(-17.0, -14.0), String(point_data.get("name", "WP")), HORIZONTAL_ALIGNMENT_CENTER, 34.0, 8, color)

	func _draw_route_segment(from_index: int, to_index: int, center: Vector2, radius: float, color: Color) -> void:
		var from_data: Dictionary = route_points[from_index]
		var to_data: Dictionary = route_points[to_index]
		var from_screen := _world_to_radar(from_data.get("position", Vector3.ZERO) as Vector3, center, radius)
		var to_screen := _world_to_radar(to_data.get("position", Vector3.ZERO) as Vector3, center, radius)
		if _inside_scope(from_screen, center, radius) and _inside_scope(to_screen, center, radius):
			draw_line(from_screen, to_screen, Color(color.r, color.g, color.b, 0.62), 1.8, true)

	func _draw_obstacles(center: Vector2, radius: float, rock_color: Color, ring_color: Color) -> void:
		for obstacle in obstacles:
			var data: Dictionary = obstacle
			var obstacle_position := data.get("position", Vector3.ZERO) as Vector3
			var screen := _world_to_radar(obstacle_position, center, radius)
			if not _inside_scope(screen, center, radius + 8.0):
				continue
			var obstacle_radius := clampf(float(data.get("radius", 5.0)) / radar_range * radius, 2.4, 7.5)
			draw_rect(Rect2(screen - Vector2(obstacle_radius, obstacle_radius), Vector2(obstacle_radius * 2.0, obstacle_radius * 2.0)), rock_color, false, 1.4)
			draw_arc(screen, obstacle_radius + 4.0, 0.0, TAU, 32, Color(ring_color.r, ring_color.g, ring_color.b, 0.42), 1.0, true)

	func _draw_box_obstacles(center: Vector2, radius: float, color: Color) -> void:
		for obstacle in box_obstacles:
			var data: Dictionary = obstacle
			var position := data.get("position", Vector3.ZERO) as Vector3
			var size3 := data.get("size", Vector3.ONE) as Vector3
			var half := Vector2(size3.x, size3.z) * 0.5
			var corners := [
				_world_to_radar(Vector3(position.x - half.x, 0.0, position.z - half.y), center, radius),
				_world_to_radar(Vector3(position.x + half.x, 0.0, position.z - half.y), center, radius),
				_world_to_radar(Vector3(position.x + half.x, 0.0, position.z + half.y), center, radius),
				_world_to_radar(Vector3(position.x - half.x, 0.0, position.z + half.y), center, radius)
			]
			var any_inside := false
			for corner in corners:
				if _inside_scope(corner, center, radius + 12.0):
					any_inside = true
					break
			if not any_inside:
				continue
			var polygon := PackedVector2Array(corners)
			draw_colored_polygon(polygon, Color(color.r, color.g, color.b, 0.10))
			polygon.append(corners[0])
			draw_polyline(polygon, Color(color.r, color.g, color.b, 0.68), 1.2, true)

	func _draw_boundary(center: Vector2, radius: float, color: Color) -> void:
		if boundary_half_extent <= 0.0:
			return
		var b := boundary_half_extent
		_draw_boundary_side(Vector2(-b, -b), Vector2(b, -b), center, radius, color)
		_draw_boundary_side(Vector2(b, -b), Vector2(b, b), center, radius, color)
		_draw_boundary_side(Vector2(b, b), Vector2(-b, b), center, radius, color)
		_draw_boundary_side(Vector2(-b, b), Vector2(-b, -b), center, radius, color)

	func _draw_boundary_side(from_xz: Vector2, to_xz: Vector2, center: Vector2, radius: float, color: Color) -> void:
		var last_point := Vector2.ZERO
		var last_inside := false
		for step in range(0, 25):
			var t := float(step) / 24.0
			var xz := from_xz.lerp(to_xz, t)
			var screen := _world_to_radar(Vector3(xz.x, 0.0, xz.y), center, radius)
			var inside := _inside_scope(screen, center, radius)
			if step > 0 and inside and last_inside:
				draw_line(last_point, screen, Color(color.r, color.g, color.b, 0.30), 1.0, true)
			last_point = screen
			last_inside = inside

	func _draw_ship(center: Vector2, color: Color) -> void:
		var ship := PackedVector2Array([
			center + Vector2(0.0, -12.0),
			center + Vector2(-7.0, 9.0),
			center + Vector2(0.0, 5.0),
			center + Vector2(7.0, 9.0)
		])
		draw_colored_polygon(ship, color)
		draw_arc(center, 17.0, deg_to_rad(220.0), deg_to_rad(320.0), 36, Color(color.r, color.g, color.b, 0.36), 1.2, true)
		draw_circle(center, 2.8, Color(0.96, 1.0, 1.0, 0.96))

	func _draw_sweep(center: Vector2, radius: float) -> void:
		var sweep_angle := fposmod(Time.get_ticks_msec() * 0.075, 360.0)
		var angle := deg_to_rad(sweep_angle - 90.0)
		var end := center + Vector2(cos(angle), sin(angle)) * radius
		draw_line(center, end, Color(0.46, 1.0, 0.58, 0.36), 1.2, true)

	func _world_to_radar(point: Vector3, center: Vector2, radius: float) -> Vector2:
		var relative := Vector2(point.x - ship_position.x, point.z - ship_position.z)
		var heading := deg_to_rad(heading_degrees)
		var forward := Vector2(sin(heading), cos(heading))
		var right := Vector2(cos(heading), -sin(heading))
		var local := Vector2(relative.dot(right), relative.dot(forward))
		var scale := radius / radar_range
		return center + Vector2(local.x, -local.y) * scale

	func _inside_scope(point: Vector2, center: Vector2, radius: float) -> bool:
		return point.distance_to(center) <= radius


class EnvironmentDial:
	extends Control

	var wind_speed := 0.0
	var wind_direction := 0.0
	var wave_height := 0.0
	var visibility := 20.0
	var current_speed := 0.0
	var current_direction := 0.0
	var tide := 0.0
	var time_label := "--"

	func set_environment(status: Dictionary) -> void:
		wind_speed = float(status.get("wind_speed_knots", 0.0))
		wind_direction = float(status.get("wind_direction_degrees", 0.0))
		wave_height = float(status.get("wave_height_meters", 0.0))
		visibility = float(status.get("visibility_km", 20.0))
		current_speed = float(status.get("current_speed_knots", 0.0))
		current_direction = float(status.get("current_direction_degrees", 0.0))
		tide = float(status.get("tide_meters", 0.0))
		time_label = String(status.get("time", "--"))
		queue_redraw()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var cyan := Color(0.28, 0.96, 1.0, 0.90)
		var green := Color(0.46, 1.0, 0.58, 0.94)
		var amber := Color(1.0, 0.70, 0.24, 0.94)
		var soft := Color(0.70, 0.92, 1.0, 0.78)
		var center := Vector2(size.x * 0.34, size.y * 0.54)
		var radius := minf(size.x, size.y) * 0.30
		draw_string(font, Vector2(0.0, 13.0), "ENVIRONMENT // 环境信息", HORIZONTAL_ALIGNMENT_CENTER, size.x, 11, cyan)
		draw_arc(center, radius, 0.0, TAU, 112, Color(0.28, 0.96, 1.0, 0.30), 1.2, true)
		draw_arc(center, radius * 0.62, 0.0, TAU, 90, Color(0.46, 1.0, 0.58, 0.16), 1.0, true)
		for index in range(0, 360, 45):
			var angle := deg_to_rad(float(index) - 90.0)
			var outer := center + Vector2(cos(angle), sin(angle)) * radius
			var inner := center + Vector2(cos(angle), sin(angle)) * (radius - 8.0)
			draw_line(inner, outer, soft, 1.0, true)
		_draw_vector_arrow(center, radius * 0.82, wind_direction, amber, "W")
		_draw_vector_arrow(center, radius * 0.56, current_direction, green, "C")
		draw_string(font, Vector2(center.x - 22.0, center.y + 5.0), "%02d:%02d" % [int(wind_direction) % 360, int(current_direction) % 360], HORIZONTAL_ALIGNMENT_CENTER, 44.0, 8, soft)
		var x := size.x * 0.62
		draw_string(font, Vector2(x, 36.0), "风 %04.1f kn" % wind_speed, HORIZONTAL_ALIGNMENT_LEFT, size.x - x - 8.0, 10, amber)
		draw_string(font, Vector2(x, 55.0), "浪 %03.1f m" % wave_height, HORIZONTAL_ALIGNMENT_LEFT, size.x - x - 8.0, 10, soft)
		draw_string(font, Vector2(x, 74.0), "能见 %04.1f km" % visibility, HORIZONTAL_ALIGNMENT_LEFT, size.x - x - 8.0, 10, green if visibility >= 8.0 else amber)
		draw_string(font, Vector2(x, 93.0), "流 %03.1f kn" % current_speed, HORIZONTAL_ALIGNMENT_LEFT, size.x - x - 8.0, 10, green)
		draw_string(font, Vector2(x, 112.0), "潮 %+03.1f m" % tide, HORIZONTAL_ALIGNMENT_LEFT, size.x - x - 8.0, 10, soft)
		draw_string(font, Vector2(x, 131.0), "时刻 " + time_label, HORIZONTAL_ALIGNMENT_LEFT, size.x - x - 8.0, 10, cyan)

	func _draw_vector_arrow(center: Vector2, length: float, degrees: float, color: Color, label: String) -> void:
		var angle := deg_to_rad(degrees - 90.0)
		var direction := Vector2(cos(angle), sin(angle))
		var end := center + direction * length
		draw_line(center, end, color, 2.0, true)
		draw_circle(end, 4.0, color)
		draw_string(ThemeDB.fallback_font, end + Vector2(-6.0, -8.0), label, HORIZONTAL_ALIGNMENT_CENTER, 12.0, 8, color)


class SensorFusionGrid:
	extends Control

	var heading := 0.0
	var speed_knots := 0.0
	var obstacle_count := 0
	var waypoint_count := 0
	var risk_active := false
	var route_deviation := 0.0
	var ship_position := Vector3.ZERO
	var obstacle_positions: Array[Vector3] = []

	func set_sensor_data(telemetry: Dictionary, route_data: Dictionary, obstacle_data: Dictionary, current_position: Vector3) -> void:
		heading = float(telemetry.get("heading_degrees", 0.0))
		speed_knots = absf(float(telemetry.get("speed", 0.0))) * KNOTS_PER_MPS
		risk_active = bool(telemetry.get("collision_warning_active", false))
		route_deviation = absf(float(route_data.get("deviation_distance", 0.0)))
		if String(route_data.get("deviation_side", "ON TRACK")) == "LEFT":
			route_deviation = -route_deviation
		ship_position = current_position
		var rocks: Array = obstacle_data.get("rocks", [])
		var boxes: Array = obstacle_data.get("boxes", [])
		obstacle_count = rocks.size() + boxes.size()
		obstacle_positions.clear()
		for raw_rock in rocks:
			if raw_rock is Dictionary:
				obstacle_positions.append((raw_rock as Dictionary).get("position", Vector3.ZERO) as Vector3)
		for raw_box in boxes:
			if raw_box is Dictionary:
				obstacle_positions.append((raw_box as Dictionary).get("position", Vector3.ZERO) as Vector3)
		var points: Array = route_data.get("points", [])
		waypoint_count = points.size()
		queue_redraw()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var cyan := Color(0.28, 0.96, 1.0, 0.90)
		draw_string(font, Vector2(0.0, 13.0), "NAVIGATION STATE // 计算视图（非实体传感器）", HORIZONTAL_ALIGNMENT_CENTER, size.x, 11, cyan)
		var gap := 8.0
		var tile_w := (size.x - gap) * 0.5
		var tile_h := (size.y - 27.0 - gap) * 0.5
		var origin := Vector2(0.0, 24.0)
		_draw_camera_tile(Rect2(origin, Vector2(tile_w, tile_h)), "航向/航速（动力学）")
		_draw_radar_tile(Rect2(origin + Vector2(tile_w + gap, 0.0), Vector2(tile_w, tile_h)), "障碍几何（场景）")
		_draw_sonar_tile(Rect2(origin + Vector2(0.0, tile_h + gap), Vector2(tile_w, tile_h)), "横向偏差（航线）")
		_draw_lidar_tile(Rect2(origin + Vector2(tile_w + gap, tile_h + gap), Vector2(tile_w, tile_h)), "数据契约")

	func _draw_tile_frame(rect: Rect2, title: String) -> void:
		draw_rect(rect, Color(0.010, 0.032, 0.046, 0.78), true)
		draw_rect(rect, Color(0.28, 0.96, 1.0, 0.28), false, 1.0)
		draw_string(ThemeDB.fallback_font, rect.position + Vector2(7.0, 13.0), title, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 14.0, 8, Color(0.70, 0.92, 1.0, 0.78))

	func _draw_camera_tile(rect: Rect2, title: String) -> void:
		_draw_tile_frame(rect, title)
		var horizon := rect.position.y + rect.size.y * 0.48
		draw_rect(Rect2(rect.position + Vector2(6.0, 19.0), Vector2(rect.size.x - 12.0, horizon - rect.position.y - 19.0)), Color(0.14, 0.48, 0.70, 0.28), true)
		draw_line(Vector2(rect.position.x + 8.0, horizon), Vector2(rect.position.x + rect.size.x - 8.0, horizon), Color(0.46, 1.0, 0.58, 0.52), 1.0, true)
		draw_string(ThemeDB.fallback_font, rect.position + Vector2(8.0, rect.size.y - 9.0), "HDG %03d  SPD %02.0f" % [int(heading) % 360, speed_knots], HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16.0, 8, Color(0.46, 1.0, 0.58, 0.78))

	func _draw_radar_tile(rect: Rect2, title: String) -> void:
		_draw_tile_frame(rect, title)
		var center := rect.position + rect.size * 0.5 + Vector2(0.0, 5.0)
		var radius := minf(rect.size.x, rect.size.y) * 0.30
		for ring in [0.4, 0.7, 1.0]:
			draw_arc(center, radius * float(ring), 0.0, TAU, 64, Color(0.46, 1.0, 0.58, 0.17), 1.0, true)
		draw_line(center, center + Vector2(0.0, -radius), Color(0.46, 1.0, 0.58, 0.46), 1.0, true)
		var display_range := 100.0
		for obstacle_position in obstacle_positions:
			display_range = maxf(display_range, Vector2(obstacle_position.x - ship_position.x, obstacle_position.z - ship_position.z).length())
		for obstacle_position in obstacle_positions:
			var relative := Vector2(obstacle_position.x - ship_position.x, obstacle_position.z - ship_position.z)
			var bearing := atan2(relative.x, relative.y) - deg_to_rad(heading)
			var distance_ratio := clampf(relative.length() / display_range, 0.0, 1.0)
			var marker := center + Vector2(sin(bearing), -cos(bearing)) * radius * distance_ratio
			draw_circle(marker, 2.1, Color(1.0, 0.70, 0.24, 0.90))

	func _draw_sonar_tile(rect: Rect2, title: String) -> void:
		_draw_tile_frame(rect, title)
		var center_y := rect.position.y + rect.size.y * 0.52
		var half_width := maxf(rect.size.x * 0.5 - 10.0, 1.0)
		var signed_offset := clampf(route_deviation / 120.0, -1.0, 1.0) * half_width
		draw_line(Vector2(rect.position.x + 9.0, center_y), Vector2(rect.end.x - 9.0, center_y), Color(0.28, 0.96, 1.0, 0.28), 1.0, true)
		draw_line(Vector2(rect.get_center().x, center_y - 12.0), Vector2(rect.get_center().x, center_y + 12.0), Color(0.46, 1.0, 0.58, 0.52), 1.0, true)
		draw_circle(Vector2(rect.get_center().x + signed_offset, center_y), 4.0, Color(1.0, 0.70, 0.24, 0.90))
		draw_string(ThemeDB.fallback_font, rect.position + Vector2(8.0, rect.size.y - 9.0), "XTE %04.0f m" % route_deviation, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16.0, 8, Color(0.70, 0.92, 1.0, 0.78))

	func _draw_lidar_tile(rect: Rect2, title: String) -> void:
		_draw_tile_frame(rect, title)
		var color := Color(1.0, 0.30, 0.24, 0.88) if risk_active else Color(0.46, 1.0, 0.58, 0.88)
		draw_string(ThemeDB.fallback_font, rect.position + Vector2(8.0, 30.0), "KINEMATICS  LIVE", HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16.0, 8, Color(0.70, 0.92, 1.0, 0.78))
		draw_string(ThemeDB.fallback_font, rect.position + Vector2(8.0, 42.0), "ROUTE / SCENE GEOMETRY", HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16.0, 8, Color(0.70, 0.92, 1.0, 0.78))
		draw_string(ThemeDB.fallback_font, rect.position + Vector2(8.0, rect.size.y - 9.0), "WP %02d  OBS %02d" % [waypoint_count, obstacle_count], HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16.0, 8, color)


class NavigationTrendChart:
	extends Control

	var speed_samples: Array[float] = []
	var heading_samples: Array[float] = []
	var deviation_samples: Array[float] = []
	var throttle_samples: Array[float] = []
	var sample_timer := 0.0
	var latest_mode := "--"

	func push_sample(delta: float, speed_knots: float, heading_degrees: float, deviation_m: float, throttle: float, mode: String) -> void:
		sample_timer -= delta
		latest_mode = mode
		if sample_timer > 0.0:
			return
		sample_timer = 0.25
		_append_limited(speed_samples, clampf(speed_knots / 40.0, 0.0, 1.0))
		_append_limited(heading_samples, fposmod(heading_degrees, 360.0) / 360.0)
		_append_limited(deviation_samples, clampf(deviation_m / 120.0, 0.0, 1.0))
		_append_limited(throttle_samples, clampf((throttle + 1.0) * 0.5, 0.0, 1.0))
		queue_redraw()

	func _append_limited(target: Array[float], value: float) -> void:
		target.append(value)
		while target.size() > 96:
			target.remove_at(0)

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var plot := Rect2(16.0, 34.0, maxf(size.x - 32.0, 1.0), maxf(size.y - 62.0, 1.0))
		draw_string(font, Vector2(16.0, 16.0), "NAVIGATION DATASTREAM // 航行数据流", HORIZONTAL_ALIGNMENT_LEFT, size.x - 32.0, 12, Color(0.28, 0.96, 1.0, 0.94))
		draw_string(font, Vector2(size.x - 160.0, 16.0), latest_mode, HORIZONTAL_ALIGNMENT_RIGHT, 144.0, 12, Color(0.46, 1.0, 0.58, 0.94))
		_draw_grid(plot)
		_draw_line_series(plot, speed_samples, Color(0.28, 0.96, 1.0, 0.92))
		_draw_line_series(plot, heading_samples, Color(1.0, 0.70, 0.24, 0.86))
		_draw_line_series(plot, deviation_samples, Color(1.0, 0.30, 0.24, 0.82))
		_draw_line_series(plot, throttle_samples, Color(0.46, 1.0, 0.58, 0.76))
		draw_string(font, Vector2(16.0, size.y - 20.0), "SPD    HDG    XTE    THR", HORIZONTAL_ALIGNMENT_LEFT, size.x - 32.0, 10, Color(0.70, 0.92, 1.0, 0.72))

	func _draw_grid(plot: Rect2) -> void:
		draw_rect(plot, Color(0.010, 0.032, 0.046, 0.58), true)
		draw_rect(plot, Color(0.28, 0.96, 1.0, 0.28), false, 1.0)
		for index in range(1, 6):
			var x := plot.position.x + plot.size.x * float(index) / 6.0
			var y := plot.position.y + plot.size.y * float(index) / 6.0
			draw_line(Vector2(x, plot.position.y), Vector2(x, plot.position.y + plot.size.y), Color(0.28, 0.96, 1.0, 0.08), 1.0, true)
			draw_line(Vector2(plot.position.x, y), Vector2(plot.position.x + plot.size.x, y), Color(0.28, 0.96, 1.0, 0.08), 1.0, true)

	func _draw_line_series(plot: Rect2, values: Array[float], color: Color) -> void:
		if values.size() <= 1:
			return
		var previous := _series_point(plot, 0, values)
		for index in range(1, values.size()):
			var current := _series_point(plot, index, values)
			draw_line(previous, current, color, 1.6, true)
			previous = current

	func _series_point(plot: Rect2, index: int, values: Array[float]) -> Vector2:
		var x_ratio := float(index) / maxf(float(values.size() - 1), 1.0)
		var y_ratio := clampf(values[index], 0.0, 1.0)
		return Vector2(plot.position.x + x_ratio * plot.size.x, plot.position.y + (1.0 - y_ratio) * plot.size.y)


func _ready() -> void:
	layer = 40
	_build_interface()
	_resolve_player()
	_resolve_route_system()
	_resolve_obstacle_system()
	_resolve_weather_time_system()
	_resolve_scenario_system()
	set_process(true)
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return
		if key_event.physical_keycode == HUD_LAYOUT_EDIT_KEY:
			_set_layout_edit_enabled(not _layout_edit_enabled)
			get_viewport().set_input_as_handled()
		elif _layout_edit_enabled and key_event.physical_keycode == HUD_LAYOUT_RESET_KEY:
			_reset_hud_layout()
			get_viewport().set_input_as_handled()
	elif _layout_edit_enabled and event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index != MOUSE_BUTTON_LEFT:
			return
		if mouse_event.pressed:
			_begin_layout_drag(mouse_event.position)
		else:
			_end_layout_drag()
		get_viewport().set_input_as_handled()
	elif _layout_edit_enabled and event is InputEventMouseMotion:
		var motion_event := event as InputEventMouseMotion
		_update_layout_drag(motion_event.position)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_elapsed_time += delta
	_update_weather_time_label()
	if _player == null or not is_instance_valid(_player) or not _player.is_in_group(&"player"):
		_resolve_player()

	if _player == null or not _player.has_method("get_ship_telemetry"):
		_status_label.text = "AI NAV SYSTEM // WAITING FOR VESSEL DATA"
		_heading_label.text = "HEADING --"
		_update_route_labels({})
		return

	_update_mileage()
	var data: Dictionary = _player.call("get_ship_telemetry")
	var speed_mps := float(data.get("speed", 0.0))
	if _player is CharacterBody3D:
		var ship_body := _player as CharacterBody3D
		var horizontal_velocity := Vector3(ship_body.velocity.x, 0.0, ship_body.velocity.z)
		if horizontal_velocity.length() > absf(speed_mps):
			speed_mps = horizontal_velocity.length()

	var speed_knots := speed_mps * KNOTS_PER_MPS
	var max_knots := float(data.get("max_forward_speed", 0.0)) * KNOTS_PER_MPS
	var heading := float(data.get("heading_degrees", 0.0))
	var course := float(data.get("course_degrees", 0.0))
	var target_heading := float(data.get("target_heading_degrees", 0.0))
	var rudder := float(data.get("rudder", 0.0))
	var throttle := float(data.get("throttle", 0.0))
	var collision_warning := String(data.get("collision_warning", "CLEAR"))
	var collision_warning_active := bool(data.get("collision_warning_active", false))
	var position := _player.global_position
	var route_data := _get_route_data(position)
	if bool(route_data.get("active", false)):
		target_heading = float(route_data.get("target_bearing_degrees", target_heading))
	var turn_authority := float(data.get("turn_authority", 0.0))
	var drift_degrees := float(data.get("drift_angle_degrees", 0.0))
	var deviation_distance := float(route_data.get("deviation_distance", 0.0))
	var current_distance := float(route_data.get("current_distance", 0.0))
	var route_active := bool(route_data.get("active", false))
	var radar_route_data := _get_radar_route_data()
	var obstacle_radar_data := _get_obstacle_radar_data()
	var weather_status := _get_weather_status()

	_status_label.text = collision_warning if collision_warning_active else "AI NAV SYSTEM // LIVE"
	_heading_label.text = "HEADING %06.2f deg" % heading
	_speed_gauge.set_speed(speed_knots, max_knots)
	_compass_tape.set_heading(heading, course, target_heading)
	_compass_rose.set_heading(heading, course, target_heading)
	_rudder_gauge.set_rudder(rudder)
	_telegraph.set_throttle(throttle)
	_route_orb.set_route(current_distance, deviation_distance, _format_eta(current_distance, absf(speed_mps), route_active), route_active)
	_engine_core.set_systems(clampf(absf(speed_mps) / maxf(float(data.get("max_forward_speed", 1.0)), 0.001), 0.0, 1.0), absf(throttle), turn_authority, collision_warning_active)
	_safety_diamond.set_status(collision_warning, drift_degrees, deviation_distance, collision_warning_active)
	_radar_scope.set_radar_data(position, heading, radar_route_data, obstacle_radar_data, RADAR_SCOPE_RANGE_METERS)
	if _environment_dial != null:
		_environment_dial.set_environment(weather_status)
	if _sensor_grid != null:
		var sensor_route_data: Dictionary = radar_route_data.duplicate(true)
		sensor_route_data["deviation_distance"] = deviation_distance
		sensor_route_data["deviation_side"] = String(route_data.get("deviation_side", "ON TRACK"))
		_sensor_grid.set_sensor_data(data, sensor_route_data, obstacle_radar_data, position)
	if _trend_chart != null:
		_trend_chart.push_sample(delta, absf(speed_knots), heading, deviation_distance, throttle, _control_mode_label(data))

	_update_label("speed", "%05.2f m/s  |  %05.1f kn" % [speed_mps, speed_knots])
	_update_label("speed_grade", _speed_grade(speed_knots, max_knots))
	_update_label("heading", "%06.2f deg  %s" % [heading, _cardinal(heading)])
	_update_label("course", "%06.2f deg" % course)
	_update_label("course_bottom", "%06.2f deg" % course)
	_update_label("target_heading", "%06.2f deg" % target_heading)
	_update_label("rudder", "%+05.1f deg  (%+04.0f%%)" % [rudder * MAX_RUDDER_DEGREES, rudder * 100.0])
	_update_label("throttle", "%s  %+04.0f%%" % [_throttle_gear(throttle), throttle * 100.0])
	_update_label("turn_authority", "%03.0f%%" % (turn_authority * 100.0))
	_update_label("drift", "%+05.1f deg" % drift_degrees)
	_update_label("position", "X %+08.1f   Z %+08.1f" % [position.x, position.z])
	_update_label("altitude", "Y %+07.1f" % position.y)
	_update_label("mileage", "%07.1f m  |  %05.3f NM" % [_mileage_meters, _mileage_meters / METERS_PER_NAUTICAL_MILE])
	_update_label("runtime", _format_time(_elapsed_time))
	_update_label("collision_warning", collision_warning)
	_set_label_color("collision_warning", COLOR_AMBER if collision_warning_active else COLOR_GREEN)
	_update_route_labels(route_data)
	_update_extended_dashboard(data, route_data, radar_route_data, obstacle_radar_data, weather_status, speed_knots, throttle, collision_warning, collision_warning_active)


func _resolve_player() -> void:
	var found_player := get_tree().get_first_node_in_group(&"player")
	if found_player == null:
		found_player = get_node_or_null(player_path)
	if found_player is Node3D:
		_player = found_player
		_last_player_position = _player.global_position
		_has_last_player_position = true


func _resolve_route_system() -> void:
	var found_route := get_node_or_null("../ShipRouteSystem")
	if found_route == null:
		found_route = get_tree().get_first_node_in_group(&"ship_route_system")
	if found_route != null and found_route.has_method("get_route_telemetry"):
		_route_system = found_route


func _resolve_obstacle_system() -> void:
	var found_obstacles := get_node_or_null("../ShipNavigationObstacles")
	if found_obstacles == null:
		found_obstacles = get_tree().get_first_node_in_group(&"ship_navigation_obstacle_system")
	if found_obstacles != null and found_obstacles.has_method("get_radar_obstacle_data"):
		_obstacle_system = found_obstacles


func _resolve_weather_time_system() -> void:
	var found_weather := get_node_or_null("../ShipWeatherTimeController")
	if found_weather == null:
		found_weather = get_tree().get_first_node_in_group(&"ship_weather_time_system")
	if found_weather != null and found_weather.has_method("get_weather_time_status"):
		_weather_time_source = found_weather


func _update_weather_time_label() -> void:
	if _weather_label == null:
		return
	var status := _get_weather_status()
	if status.is_empty():
		_weather_label.text = "SCN %s  WX --  TIME --  VIS --" % _get_scenario_display_name()
		return

	_weather_label.text = "SCN %s  WX %s  %s  %s  VIS %s" % [
		_get_scenario_display_name(),
		String(status.get("name", "--")),
		String(status.get("time", "--")),
		String(status.get("weather", "--")),
		String(status.get("visibility", "--"))
	]


func _get_weather_status() -> Dictionary:
	if _weather_time_source == null or not is_instance_valid(_weather_time_source):
		_resolve_weather_time_system()
	if _weather_time_source != null and _weather_time_source.has_method("get_weather_time_status"):
		return _weather_time_source.call("get_weather_time_status") as Dictionary
	return {}


func _resolve_scenario_system() -> void:
	var found_scenario := get_node_or_null("../ShipScenarioController")
	if found_scenario == null:
		found_scenario = get_tree().get_first_node_in_group(&"ship_scenario_system")
	if found_scenario != null and found_scenario.has_method("get_scenario_status"):
		_scenario_source = found_scenario


func _get_scenario_display_name() -> String:
	if _scenario_source == null or not is_instance_valid(_scenario_source):
		_resolve_scenario_system()
	if _scenario_source == null or not _scenario_source.has_method("get_scenario_status"):
		return "开放水域"
	var status: Dictionary = _scenario_source.call("get_scenario_status")
	return String(status.get("name", "开放水域"))


func _get_route_data(position: Vector3) -> Dictionary:
	if _route_system == null or not is_instance_valid(_route_system):
		_resolve_route_system()
	if _route_system != null and _route_system.has_method("get_route_telemetry"):
		return _route_system.call("get_route_telemetry", position) as Dictionary
	return {}


func _get_radar_route_data() -> Dictionary:
	if _route_system == null or not is_instance_valid(_route_system):
		_resolve_route_system()
	if _route_system != null and _route_system.has_method("get_radar_route_data"):
		return _route_system.call("get_radar_route_data") as Dictionary
	return {}


func _get_obstacle_radar_data() -> Dictionary:
	if _obstacle_system == null or not is_instance_valid(_obstacle_system):
		_resolve_obstacle_system()
	if _obstacle_system != null and _obstacle_system.has_method("get_radar_obstacle_data"):
		return _obstacle_system.call("get_radar_obstacle_data") as Dictionary
	return {}


func _register_layout_control(control: Control) -> void:
	if control == null:
		return
	_layout_draggables.append(control)
	_default_layout_offsets[String(control.name)] = _get_control_offsets(control)


func _get_control_offsets(control: Control) -> Dictionary:
	return {
		"left": control.offset_left,
		"top": control.offset_top,
		"right": control.offset_right,
		"bottom": control.offset_bottom
	}


func _apply_control_offsets(control: Control, offsets: Dictionary) -> void:
	control.offset_left = float(offsets.get("left", control.offset_left))
	control.offset_top = float(offsets.get("top", control.offset_top))
	control.offset_right = float(offsets.get("right", control.offset_right))
	control.offset_bottom = float(offsets.get("bottom", control.offset_bottom))


func _set_layout_edit_enabled(enabled: bool) -> void:
	_layout_edit_enabled = enabled
	_dragged_control = null
	if _layout_edit_overlay != null:
		_layout_edit_overlay.edit_enabled = enabled
		_layout_edit_overlay.active_control = null
		_layout_edit_overlay.visible = enabled
		_layout_edit_overlay.queue_redraw()


func _begin_layout_drag(mouse_position: Vector2) -> void:
	_dragged_control = _find_layout_control_at(mouse_position)
	if _dragged_control == null:
		if _layout_edit_overlay != null:
			_layout_edit_overlay.active_control = null
			_layout_edit_overlay.queue_redraw()
		return
	_drag_mouse_origin = mouse_position
	_drag_offsets_origin = _get_control_offsets(_dragged_control)
	if _layout_edit_overlay != null:
		_layout_edit_overlay.active_control = _dragged_control
		_layout_edit_overlay.queue_redraw()


func _update_layout_drag(mouse_position: Vector2) -> void:
	if _dragged_control == null:
		return
	var delta := mouse_position - _drag_mouse_origin
	_apply_control_offsets(_dragged_control, {
		"left": float(_drag_offsets_origin["left"]) + delta.x,
		"top": float(_drag_offsets_origin["top"]) + delta.y,
		"right": float(_drag_offsets_origin["right"]) + delta.x,
		"bottom": float(_drag_offsets_origin["bottom"]) + delta.y
	})
	if _layout_edit_overlay != null:
		_layout_edit_overlay.queue_redraw()


func _end_layout_drag() -> void:
	if _dragged_control != null:
		_save_hud_layout()
	_dragged_control = null
	if _layout_edit_overlay != null:
		_layout_edit_overlay.active_control = null
		_layout_edit_overlay.queue_redraw()


func _find_layout_control_at(point: Vector2) -> Control:
	for index in range(_layout_draggables.size() - 1, -1, -1):
		var control := _layout_draggables[index]
		if control == null or not is_instance_valid(control) or not control.visible:
			continue
		if control.get_global_rect().has_point(point):
			return control
	return null


func _load_hud_layout() -> void:
	var config := ConfigFile.new()
	if config.load(HUD_LAYOUT_FILE) != OK:
		return
	for control in _layout_draggables:
		if control == null or not is_instance_valid(control):
			continue
		var section := String(control.name)
		if not config.has_section(section):
			continue
		_apply_control_offsets(control, {
			"left": config.get_value(section, "left", control.offset_left),
			"top": config.get_value(section, "top", control.offset_top),
			"right": config.get_value(section, "right", control.offset_right),
			"bottom": config.get_value(section, "bottom", control.offset_bottom)
		})


func _save_hud_layout() -> void:
	var config := ConfigFile.new()
	for control in _layout_draggables:
		if control == null or not is_instance_valid(control):
			continue
		var section := String(control.name)
		var offsets := _get_control_offsets(control)
		config.set_value(section, "left", offsets["left"])
		config.set_value(section, "top", offsets["top"])
		config.set_value(section, "right", offsets["right"])
		config.set_value(section, "bottom", offsets["bottom"])
	config.save(HUD_LAYOUT_FILE)


func _reset_hud_layout() -> void:
	for control in _layout_draggables:
		if control == null or not is_instance_valid(control):
			continue
		var section := String(control.name)
		if _default_layout_offsets.has(section):
			_apply_control_offsets(control, _default_layout_offsets[section])
	_save_hud_layout()
	if _layout_edit_overlay != null:
		_layout_edit_overlay.queue_redraw()


func _update_mileage() -> void:
	if _player == null:
		return
	var current_position := _player.global_position
	if not _has_last_player_position:
		_last_player_position = current_position
		_has_last_player_position = true
		return
	var horizontal_step := Vector2(
		current_position.x - _last_player_position.x,
		current_position.z - _last_player_position.z
	).length()
	if horizontal_step < 150.0:
		_mileage_meters += horizontal_step
	_last_player_position = current_position


func _build_interface() -> void:
	var root := Control.new()
	root.name = "NavigationHudRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_hud_root = root

	var reticle := BridgeReticle.new()
	reticle.name = "AIBridgeReticle"
	reticle.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(reticle)

	var key_guide_panel := _make_panel(
		root,
		"HotkeyGuideCard",
		0.0,
		0.0,
		0.0,
		0.0,
		KEY_GUIDE_LEFT,
		KEY_GUIDE_TOP,
		KEY_GUIDE_LEFT + KEY_GUIDE_WIDTH,
		KEY_GUIDE_TOP + KEY_GUIDE_HEIGHT
	)
	key_guide_panel.z_index = 3
	key_guide_panel.cut_size = 12.0
	key_guide_panel.fill_color = Color(0.006, 0.018, 0.034, 0.66)
	key_guide_panel.accent_color = COLOR_CYAN
	_register_layout_control(key_guide_panel)
	var key_stack := _make_vbox(key_guide_panel, 10, 5, 10, 5, 1)
	var key_title := _make_label("快捷键 / HOTKEYS", 10, COLOR_CYAN, HORIZONTAL_ALIGNMENT_LEFT)
	key_title.add_theme_color_override("font_shadow_color", Color(0.0, 0.8, 1.0, 0.42))
	key_stack.add_child(key_title)
	_add_hotkey_line(key_stack, "Z/X/C", "RL / 船队 / 训练")
	_add_hotkey_line(key_stack, "V/N/W", "风险 / 海图 / 海况")
	_add_hotkey_line(key_stack, "P/I/O", "复盘 / AIS / 教员")
	_add_hotkey_line(key_stack, "G/T/1-4", "场景 / 天气 / 预设")
	_add_hotkey_line(key_stack, "L/BK", "HUD编辑 / 还原")
	_add_hotkey_line(key_stack, "E", "交互确认")
	_add_hotkey_line(key_stack, "方向键", "航行控制")
	_add_hotkey_line(key_stack, "A/D/R/F", "镜头旋转 / 俯仰")

	var developer_panel := _make_panel(
		root,
		"LeadDeveloperCreditPanel",
		0.0,
		0.0,
		0.0,
		0.0,
		DEVELOPER_CREDIT_LEFT,
		DEVELOPER_CREDIT_TOP,
		DEVELOPER_CREDIT_LEFT + DEVELOPER_CREDIT_WIDTH,
		DEVELOPER_CREDIT_TOP + DEVELOPER_CREDIT_HEIGHT
	)
	developer_panel.z_index = 5
	developer_panel.cut_size = 14.0
	developer_panel.fill_color = Color(0.006, 0.018, 0.034, 0.82)
	developer_panel.accent_color = Color(0.68, 1.0, 0.55, 0.98)
	_register_layout_control(developer_panel)
	var developer_stack := _make_vbox(developer_panel, 12, 7, 12, 6, 0)
	var developer_title := _make_label("核心研发 / LEAD DEVELOPER", 9, COLOR_AMBER, HORIZONTAL_ALIGNMENT_CENTER)
	developer_title.add_theme_color_override("font_shadow_color", Color(1.0, 0.55, 0.12, 0.46))
	developer_title.add_theme_constant_override("shadow_offset_x", 0)
	developer_title.add_theme_constant_override("shadow_offset_y", 0)
	developer_stack.add_child(developer_title)
	var developer_cn := _make_label("温家懿", 24, COLOR_GREEN, HORIZONTAL_ALIGNMENT_CENTER)
	developer_cn.add_theme_color_override("font_shadow_color", Color(0.18, 1.0, 0.46, 0.72))
	developer_cn.add_theme_constant_override("shadow_offset_x", 0)
	developer_cn.add_theme_constant_override("shadow_offset_y", 0)
	developer_stack.add_child(developer_cn)
	var developer_en := _make_label("WEN JIAYI  //  USV SIM CORE", 10, COLOR_CYAN, HORIZONTAL_ALIGNMENT_CENTER)
	developer_en.add_theme_color_override("font_shadow_color", Color(0.0, 0.8, 1.0, 0.42))
	developer_en.add_theme_constant_override("shadow_offset_x", 0)
	developer_en.add_theme_constant_override("shadow_offset_y", 0)
	developer_stack.add_child(developer_en)
	var developer_status := _make_label("RESEARCH BUILD ONLINE", 8, COLOR_SOFT, HORIZONTAL_ALIGNMENT_CENTER)
	developer_stack.add_child(developer_status)

	var top_panel := _make_panel(root, "HeadingCommandRibbon", 0.30, 0.0, 0.70, 0.0, 0.0, 16.0, 0.0, 16.0 + TOP_PANEL_HEIGHT)
	top_panel.z_index = 3
	top_panel.cut_size = 18.0
	_register_layout_control(top_panel)
	var top_stack := _make_vbox(top_panel, 14, 5, 14, 5, 0)
	_status_label = _make_label("AI NAV SYSTEM // BOOTING", 11, COLOR_SOFT, HORIZONTAL_ALIGNMENT_CENTER)
	top_stack.add_child(_status_label)
	_weather_label = _make_label("WX --  TIME --  VIS --", 11, COLOR_AMBER, HORIZONTAL_ALIGNMENT_CENTER)
	_weather_label.name = "WeatherTimeReadout"
	_weather_label.add_theme_color_override("font_shadow_color", Color(1.0, 0.55, 0.12, 0.42))
	_weather_label.add_theme_constant_override("shadow_offset_x", 0)
	_weather_label.add_theme_constant_override("shadow_offset_y", 0)
	top_stack.add_child(_weather_label)
	_heading_label = _make_label("HEADING --", 21, COLOR_CYAN, HORIZONTAL_ALIGNMENT_CENTER)
	_heading_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.8, 1.0, 0.58))
	_heading_label.add_theme_constant_override("shadow_offset_x", 0)
	_heading_label.add_theme_constant_override("shadow_offset_y", 0)
	top_stack.add_child(_heading_label)
	_compass_tape = CompassTape.new()
	_compass_tape.name = "CompassTape"
	_compass_tape.custom_minimum_size = Vector2(0.0, 52.0)
	top_stack.add_child(_compass_tape)

	_route_orb = RouteOrbGauge.new()
	_route_orb.name = "RouteOrbGauge"
	_route_orb.anchor_left = 0.0
	_route_orb.anchor_top = 0.0
	_route_orb.anchor_right = 0.0
	_route_orb.anchor_bottom = 0.0
	_route_orb.offset_left = 276.0
	_route_orb.offset_top = MINI_DASH_TOP
	_route_orb.offset_right = 276.0 + MINI_DASH_SIZE
	_route_orb.offset_bottom = MINI_DASH_TOP + MINI_DASH_SIZE
	_route_orb.z_index = 2
	root.add_child(_route_orb)
	_register_layout_control(_route_orb)

	_engine_core = EngineCoreGauge.new()
	_engine_core.name = "EngineCoreGauge"
	_engine_core.anchor_left = 1.0
	_engine_core.anchor_top = 0.0
	_engine_core.anchor_right = 1.0
	_engine_core.anchor_bottom = 0.0
	_engine_core.offset_left = -276.0 - MINI_DASH_SIZE
	_engine_core.offset_top = MINI_DASH_TOP
	_engine_core.offset_right = -276.0
	_engine_core.offset_bottom = MINI_DASH_TOP + MINI_DASH_SIZE
	_engine_core.z_index = 2
	root.add_child(_engine_core)
	_register_layout_control(_engine_core)

	_safety_diamond = SafetyDiamondGauge.new()
	_safety_diamond.name = "SafetyDiamondGauge"
	_safety_diamond.anchor_left = 0.5
	_safety_diamond.anchor_top = 1.0
	_safety_diamond.anchor_right = 0.5
	_safety_diamond.anchor_bottom = 1.0
	_safety_diamond.offset_left = 400.0
	_safety_diamond.offset_top = -236.0
	_safety_diamond.offset_right = 516.0
	_safety_diamond.offset_bottom = -120.0
	_safety_diamond.z_index = 2
	root.add_child(_safety_diamond)
	_register_layout_control(_safety_diamond)

	_radar_scope = RadarScope.new()
	_radar_scope.name = "RadarScope"
	_radar_scope.anchor_left = 0.0
	_radar_scope.anchor_top = 0.0
	_radar_scope.anchor_right = 0.0
	_radar_scope.anchor_bottom = 0.0
	_radar_scope.offset_left = RADAR_SCOPE_LEFT
	_radar_scope.offset_top = RADAR_SCOPE_TOP
	_radar_scope.offset_right = RADAR_SCOPE_LEFT + RADAR_SCOPE_SIZE
	_radar_scope.offset_bottom = RADAR_SCOPE_TOP + RADAR_SCOPE_SIZE
	_radar_scope.z_index = 2
	root.add_child(_radar_scope)
	_register_layout_control(_radar_scope)

	var left_panel := _make_panel(root, "PropulsionCluster", 0.0, 0.0, 0.0, 0.0, 22.0, SIDE_PANEL_TOP, 22.0 + SIDE_PANEL_WIDTH, SIDE_PANEL_TOP + SIDE_PANEL_HEIGHT)
	left_panel.z_index = 2
	left_panel.cut_size = 16.0
	_register_layout_control(left_panel)
	var left_stack := _make_vbox(left_panel, 12, 9, 12, 9, 4)
	left_stack.add_child(_section_title("PROPULSION // 航速"))
	_speed_gauge = SpeedGauge.new()
	_speed_gauge.name = "SpeedGauge"
	_speed_gauge.custom_minimum_size = Vector2(0.0, 116.0)
	left_stack.add_child(_speed_gauge)
	_add_metric(left_stack, "speed", "航速")
	_add_metric(left_stack, "speed_grade", "航速档位")
	_telegraph = TelegraphBar.new()
	_telegraph.name = "EngineTelegraph"
	_telegraph.custom_minimum_size = Vector2(0.0, 66.0)
	left_stack.add_child(_telegraph)
	_add_metric(left_stack, "throttle", "油门档位")
	_add_metric(left_stack, "turn_authority", "转向效率")
	_add_metric(left_stack, "runtime", "航行计时")

	var mission_panel := _make_panel(root, "MissionAndDeviceStack", 0.0, 0.0, 0.0, 0.0, LEFT_AUX_LEFT, LEFT_AUX_TOP, LEFT_AUX_LEFT + LEFT_AUX_WIDTH, LEFT_AUX_TOP + LEFT_AUX_HEIGHT)
	mission_panel.z_index = 2
	mission_panel.cut_size = 14.0
	mission_panel.fill_color = Color(0.006, 0.018, 0.034, 0.70)
	_register_layout_control(mission_panel)
	var mission_stack := _make_vbox(mission_panel, 12, 9, 12, 9, 3)
	mission_stack.add_child(_section_title("MISSION STATUS // 任务信息"))
	_add_metric(mission_stack, "mission_name", "任务名称", 16, 10, 72.0)
	_add_metric(mission_stack, "mission_phase", "任务阶段", 16, 10, 72.0)
	_add_metric(mission_stack, "mission_progress", "任务进度", 16, 10, 72.0)
	_add_metric(mission_stack, "mission_eta", "预计到达", 16, 10, 72.0)
	mission_stack.add_child(_section_title("USV / DEVICE // 设备状态"))
	_add_metric(mission_stack, "usv_mode", "控制模式", 16, 10, 72.0)
	_add_metric(mission_stack, "usv_power", "推进负荷", 16, 10, 72.0)
	_add_metric(mission_stack, "device_stack", "数据输入", 16, 10, 72.0)
	_add_metric(mission_stack, "payload_mass", "几何输入", 16, 10, 72.0)

	var alert_panel := _make_panel(root, "AlertStreamPanel", 0.0, 0.0, 0.0, 0.0, ALERT_PANEL_LEFT, ALERT_PANEL_TOP, ALERT_PANEL_LEFT + ALERT_PANEL_WIDTH, ALERT_PANEL_TOP + ALERT_PANEL_HEIGHT)
	alert_panel.z_index = 2
	alert_panel.cut_size = 14.0
	alert_panel.fill_color = Color(0.006, 0.018, 0.034, 0.72)
	alert_panel.accent_color = COLOR_AMBER
	_register_layout_control(alert_panel)
	var alert_stack := _make_vbox(alert_panel, 12, 9, 12, 9, 4)
	alert_stack.add_child(_section_title("EVENT STREAM // 告警记录"))
	_add_metric(alert_stack, "alert_primary", "最新事件", 17, 10, 72.0)
	_add_metric(alert_stack, "alert_route", "航线状态", 17, 10, 72.0)
	_add_metric(alert_stack, "alert_weather", "海况状态", 17, 10, 72.0)
	_add_metric(alert_stack, "alert_system", "系统状态", 17, 10, 72.0)

	var right_panel := _make_panel(root, "CourseCluster", 1.0, 0.0, 1.0, 0.0, -22.0 - SIDE_PANEL_WIDTH, SIDE_PANEL_TOP, -22.0, SIDE_PANEL_TOP + SIDE_PANEL_HEIGHT)
	right_panel.z_index = 2
	right_panel.cut_size = 16.0
	_register_layout_control(right_panel)
	var right_stack := _make_vbox(right_panel, 12, 9, 12, 9, 2)
	right_stack.add_child(_section_title("COURSE AI // 指南"))
	_compass_rose = CompassRose.new()
	_compass_rose.name = "CompassRose"
	_compass_rose.custom_minimum_size = Vector2(0.0, 82.0)
	right_stack.add_child(_compass_rose)
	_rudder_gauge = RudderGauge.new()
	_rudder_gauge.name = "RudderGauge"
	_rudder_gauge.custom_minimum_size = Vector2(0.0, 58.0)
	right_stack.add_child(_rudder_gauge)
	_add_metric(right_stack, "rudder", "舵角", 17, 10, 70.0)
	_add_metric(right_stack, "heading", "船首航向", 17, 10, 70.0)
	_add_metric(right_stack, "course", "实际航迹", 17, 10, 70.0)
	_add_metric(right_stack, "target_heading", "目标航向", 17, 10, 70.0)
	_add_metric(right_stack, "drift", "漂移角", 17, 10, 70.0)
	_add_metric(right_stack, "route_current", "当前目标点", 17, 10, 70.0)
	_add_metric(right_stack, "route_next", "下一个航点", 17, 10, 70.0)
	_add_metric(right_stack, "route_deviation", "偏航距离", 17, 10, 70.0)
	_add_metric(right_stack, "collision_warning", "航行警示", 17, 10, 70.0)

	var env_panel := _make_panel(root, "EnvironmentInfoPanel", 1.0, 0.0, 1.0, 0.0, -22.0 - ENV_PANEL_WIDTH, ENV_PANEL_TOP, -22.0, ENV_PANEL_TOP + ENV_PANEL_HEIGHT)
	env_panel.z_index = 2
	env_panel.cut_size = 14.0
	env_panel.fill_color = Color(0.006, 0.018, 0.034, 0.70)
	_register_layout_control(env_panel)
	var env_margin := _make_margin(12, 8, 12, 8)
	env_panel.add_child(env_margin)
	_environment_dial = EnvironmentDial.new()
	_environment_dial.name = "EnvironmentDial"
	_environment_dial.custom_minimum_size = Vector2(0.0, ENV_PANEL_HEIGHT - 16.0)
	env_margin.add_child(_environment_dial)

	var sensor_panel := _make_panel(root, "SensorFusionPanel", 1.0, 0.0, 1.0, 0.0, -22.0 - SENSOR_PANEL_WIDTH, SENSOR_PANEL_TOP, -22.0, SENSOR_PANEL_TOP + SENSOR_PANEL_HEIGHT)
	sensor_panel.z_index = 2
	sensor_panel.cut_size = 14.0
	sensor_panel.fill_color = Color(0.006, 0.018, 0.034, 0.70)
	_register_layout_control(sensor_panel)
	var sensor_margin := _make_margin(12, 8, 12, 8)
	sensor_panel.add_child(sensor_margin)
	_sensor_grid = SensorFusionGrid.new()
	_sensor_grid.name = "SensorFusionGrid"
	_sensor_grid.custom_minimum_size = Vector2(0.0, SENSOR_PANEL_HEIGHT - 16.0)
	sensor_margin.add_child(_sensor_grid)

	var bottom_panel := _make_panel(root, "NavDataSpine", 0.5, 1.0, 0.5, 1.0, -BOTTOM_PANEL_WIDTH * 0.5, -BOTTOM_PANEL_HEIGHT - 34.0, BOTTOM_PANEL_WIDTH * 0.5, -34.0)
	bottom_panel.z_index = 1
	bottom_panel.cut_size = 14.0
	_register_layout_control(bottom_panel)
	var bottom_grid := GridContainer.new()
	bottom_grid.columns = 2
	bottom_grid.add_theme_constant_override("h_separation", 14)
	bottom_grid.add_theme_constant_override("v_separation", 0)
	var bottom_margin := _make_margin(14, 7, 14, 7)
	bottom_panel.add_child(bottom_margin)
	bottom_margin.add_child(bottom_grid)
	_add_metric(bottom_grid, "position", "坐标 X/Z", 18, 11, 74.0)
	_add_metric(bottom_grid, "altitude", "高度 Y", 18, 11, 74.0)
	_add_metric(bottom_grid, "mileage", "累计里程", 18, 11, 74.0)
	_add_metric(bottom_grid, "course_bottom", "航迹角", 18, 11, 74.0)

	var command_deck := _make_panel(root, "CommandDataDeck", 0.5, 1.0, 0.5, 1.0, -COMMAND_DECK_WIDTH * 0.5, -COMMAND_DECK_HEIGHT - 122.0, COMMAND_DECK_WIDTH * 0.5, -122.0)
	command_deck.z_index = 1
	command_deck.cut_size = 18.0
	command_deck.fill_color = Color(0.006, 0.018, 0.034, 0.72)
	_register_layout_control(command_deck)
	var command_margin := _make_margin(16, 10, 16, 10)
	command_deck.add_child(command_margin)
	var command_stack := VBoxContainer.new()
	command_stack.add_theme_constant_override("separation", 6)
	command_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	command_margin.add_child(command_stack)
	var chip_row := HBoxContainer.new()
	chip_row.add_theme_constant_override("separation", 10)
	chip_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	command_stack.add_child(chip_row)
	_add_command_chip(chip_row, "mode_chip", "MODE --")
	_add_command_chip(chip_row, "route_chip", "ROUTE --")
	_add_command_chip(chip_row, "risk_chip", "RISK --")
	_add_command_chip(chip_row, "fleet_chip", "FLEET --")
	_trend_chart = NavigationTrendChart.new()
	_trend_chart.name = "NavigationTrendChart"
	_trend_chart.custom_minimum_size = Vector2(0.0, 118.0)
	command_stack.add_child(_trend_chart)

	_layout_edit_overlay = LayoutEditOverlay.new()
	_layout_edit_overlay.name = "HudLayoutEditOverlay"
	_layout_edit_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_layout_edit_overlay.z_index = 100
	_layout_edit_overlay.visible = false
	_layout_edit_overlay.tracked_controls = _layout_draggables
	root.add_child(_layout_edit_overlay)
	_load_hud_layout()


func _make_panel(
	parent: Control,
	panel_name: String,
	left: float,
	top: float,
	right: float,
	bottom: float,
	offset_left: float,
	offset_top: float,
	offset_right: float,
	offset_bottom: float
) -> HoloPanel:
	var panel := HoloPanel.new()
	panel.name = panel_name
	panel.anchor_left = left
	panel.anchor_top = top
	panel.anchor_right = right
	panel.anchor_bottom = bottom
	panel.offset_left = offset_left
	panel.offset_top = offset_top
	panel.offset_right = offset_right
	panel.offset_bottom = offset_bottom
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.fill_color = COLOR_PANEL
	panel.accent_color = COLOR_CYAN
	parent.add_child(panel)
	return panel


func _make_vbox(panel: PanelContainer, left: int, top: int, right: int, bottom: int, separation: int) -> VBoxContainer:
	var margin := _make_margin(left, top, right, bottom)
	panel.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", separation)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(stack)
	return stack


func _make_margin(left: int, top: int, right: int, bottom: int) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", left)
	margin.add_theme_constant_override("margin_top", top)
	margin.add_theme_constant_override("margin_right", right)
	margin.add_theme_constant_override("margin_bottom", bottom)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return margin


func _section_title(text: String) -> Label:
	var label := _make_label(text, 13, COLOR_CYAN, HORIZONTAL_ALIGNMENT_LEFT)
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.8, 1.0, 0.55))
	label.add_theme_constant_override("shadow_offset_x", 0)
	label.add_theme_constant_override("shadow_offset_y", 0)
	return label


func _add_hotkey_line(parent: Container, key_text: String, detail_text: String) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0.0, 9.0)
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)

	var key_label := _make_label(key_text, 8, COLOR_AMBER, HORIZONTAL_ALIGNMENT_LEFT)
	key_label.custom_minimum_size = Vector2(54.0, 0.0)
	key_label.clip_text = true
	row.add_child(key_label)

	var detail_label := _make_label(detail_text, 8, COLOR_SOFT, HORIZONTAL_ALIGNMENT_LEFT)
	detail_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_label.clip_text = true
	row.add_child(detail_label)


func _add_command_chip(parent: Container, key: String, text: String) -> void:
	var label := _make_label(text, 11, COLOR_GREEN, HORIZONTAL_ALIGNMENT_CENTER)
	label.custom_minimum_size = Vector2(126.0, 26.0)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_stylebox_override("normal", _chip_style(Color(0.010, 0.035, 0.052, 0.86), Color(0.28, 0.96, 1.0, 0.54)))
	parent.add_child(label)
	_labels[key] = label


func _add_metric(
	parent: Container,
	key: String,
	title: String,
	row_height: float = 18.0,
	font_size: int = 11,
	title_width: float = 76.0
) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0.0, row_height)
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)

	var title_label := _make_label(title, font_size, COLOR_SOFT, HORIZONTAL_ALIGNMENT_LEFT)
	title_label.custom_minimum_size = Vector2(title_width, 0.0)
	row.add_child(title_label)

	var value_label := _make_label("--", font_size, COLOR_GREEN, HORIZONTAL_ALIGNMENT_RIGHT)
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(value_label)
	_labels[key] = value_label


func _make_label(text: String, font_size: int, color: Color, alignment: HorizontalAlignment) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = alignment
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _chip_style(fill: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	return style


func _update_label(key: String, value: String) -> void:
	var label := _labels.get(key) as Label
	if label != null:
		label.text = value


func _set_label_color(key: String, color: Color) -> void:
	var label := _labels.get(key) as Label
	if label != null:
		label.add_theme_color_override("font_color", color)


func _update_extended_dashboard(
	telemetry: Dictionary,
	route_data: Dictionary,
	radar_route_data: Dictionary,
	obstacle_data: Dictionary,
	weather_status: Dictionary,
	speed_knots: float,
	throttle: float,
	collision_warning: String,
	collision_warning_active: bool
) -> void:
	var route_active := bool(route_data.get("active", false))
	var current_distance := float(route_data.get("current_distance", 0.0))
	var current_name := String(route_data.get("current_name", "--"))
	var next_name := String(route_data.get("next_name", "--"))
	var deviation := float(route_data.get("deviation_distance", 0.0))
	var obstacle_count := _obstacle_count(obstacle_data)
	var progress := _route_progress_percent(radar_route_data)
	var eta := _format_eta(current_distance, absf(float(telemetry.get("speed", 0.0))), route_active)
	var mode := _control_mode_label(telemetry)
	var propulsion_load := maxf(absf(throttle), speed_knots / maxf(float(telemetry.get("max_forward_speed", 1.0)) * KNOTS_PER_MPS, 0.1)) * 100.0
	var sea_alert := _sea_alert_label(weather_status)
	var route_alert := "正航" if deviation < 8.0 else ("偏航 %.0fm" % deviation)
	var risk_text := "CLEAR"
	if collision_warning_active:
		risk_text = collision_warning
	elif deviation >= 80.0:
		risk_text = "XTE HIGH %.0fm" % deviation
	elif obstacle_count >= 10:
		risk_text = "OBSTACLE DENSE"

	_update_label("mission_name", "%s / %s" % [_get_scenario_display_name(), current_name])
	_update_label("mission_phase", "航行阶段" if route_active else "待命阶段")
	_update_label("mission_progress", "%03.0f%%  NEXT %s" % [progress, next_name])
	_update_label("mission_eta", eta)
	_update_label("usv_mode", mode)
	_update_label("usv_power", "LOAD %03.0f%%  THR %.0f%%" % [propulsion_load, absf(throttle) * 100.0])
	_update_label("device_stack", "动力学 / 航线 / 场景几何")
	_update_label("payload_mass", "OBS %02d / WP %02d" % [obstacle_count, (radar_route_data.get("points", []) as Array).size()])
	_update_label("alert_primary", risk_text)
	_update_label("alert_route", "%s  %s" % [route_alert, current_name])
	_update_label("alert_weather", sea_alert)
	_update_label("alert_system", "HUD LIVE  T%.1fx" % Engine.time_scale)
	_update_label("mode_chip", mode)
	_update_label("route_chip", "WP %s  ETA %s" % [current_name, eta])
	_update_label("risk_chip", risk_text)
	_update_label("fleet_chip", "FLEET %02d  OBS %02d" % [_fleet_count(), obstacle_count])
	_set_label_color("mission_progress", COLOR_GREEN if progress >= 65.0 else COLOR_AMBER)
	_set_label_color("usv_power", COLOR_AMBER if propulsion_load >= 85.0 else COLOR_GREEN)
	_set_label_color("alert_primary", COLOR_AMBER if risk_text != "CLEAR" else COLOR_GREEN)
	_set_label_color("alert_route", _deviation_color(deviation))
	_set_label_color("alert_weather", COLOR_AMBER if sea_alert != "SEA NORMAL" else COLOR_GREEN)
	_set_label_color("risk_chip", COLOR_AMBER if risk_text != "CLEAR" else COLOR_GREEN)


func _route_progress_percent(radar_route_data: Dictionary) -> float:
	var points: Array = radar_route_data.get("points", [])
	if points.is_empty():
		return 0.0
	var current_index := int(radar_route_data.get("current_index", 0))
	var denominator := maxf(float(points.size() - 1), 1.0)
	if bool(radar_route_data.get("loop", false)):
		denominator = maxf(float(points.size()), 1.0)
	return clampf(float(current_index) / denominator * 100.0, 0.0, 100.0)


func _obstacle_count(obstacle_data: Dictionary) -> int:
	var rocks: Array = obstacle_data.get("rocks", [])
	var boxes: Array = obstacle_data.get("boxes", [])
	return rocks.size() + boxes.size()


func _fleet_count() -> int:
	return get_tree().get_nodes_in_group(&"ship_agent").size()


func _control_mode_label(telemetry: Dictionary) -> String:
	if bool(telemetry.get("external_agent_control_enabled", false)):
		return "RL 策略"
	if bool(telemetry.get("human_control_enabled", false)):
		return "人工驾驶"
	return "待机监控"


func _sea_alert_label(weather_status: Dictionary) -> String:
	var wind := float(weather_status.get("wind_speed_knots", 0.0))
	var wave := float(weather_status.get("wave_height_meters", 0.0))
	var visibility := float(weather_status.get("visibility_km", 20.0))
	if visibility < 3.0:
		return "LOW VIS %.1fkm" % visibility
	if wave >= 2.5:
		return "WAVE %.1fm" % wave
	if wind >= 22.0:
		return "WIND %.0fkn" % wind
	return "SEA NORMAL"


func _deviation_color(deviation: float) -> Color:
	if deviation >= 80.0:
		return Color(1.0, 0.30, 0.24, 0.96)
	if deviation >= 28.0:
		return COLOR_AMBER
	return COLOR_GREEN


func _update_route_labels(route_data: Dictionary) -> void:
	if not bool(route_data.get("active", false)):
		_update_label("route_current", "--")
		_update_label("route_next", "--")
		_update_label("route_deviation", "--")
		return

	var current_name := String(route_data.get("current_name", "--"))
	var next_name := String(route_data.get("next_name", "--"))
	var current_distance := float(route_data.get("current_distance", 0.0))
	var deviation_distance := float(route_data.get("deviation_distance", 0.0))
	var deviation_side := String(route_data.get("deviation_side", "ON TRACK"))

	_update_label("route_current", "%s  %05.1f m" % [current_name, current_distance])
	_update_label("route_next", next_name)
	if deviation_side == "ON TRACK":
		_update_label("route_deviation", "%05.1f m  正航" % deviation_distance)
	elif deviation_side == "LEFT":
		_update_label("route_deviation", "%05.1f m  左偏" % deviation_distance)
	else:
		_update_label("route_deviation", "%05.1f m  右偏" % deviation_distance)


func _format_eta(distance: float, speed: float, route_active: bool) -> String:
	if not route_active:
		return "--"
	if speed < 0.25:
		return "HOLD"
	var whole_seconds := int(ceil(distance / maxf(speed, 0.001)))
	var minutes := whole_seconds / 60
	var seconds := whole_seconds % 60
	if minutes >= 100:
		return "99m+"
	return "%02d:%02d" % [minutes, seconds]


func _speed_grade(speed_knots: float, max_knots: float) -> String:
	var ratio := clampf(speed_knots / maxf(max_knots, 0.001), 0.0, 1.0)
	if ratio > 0.82:
		return "FULL SEA SPEED"
	if ratio > 0.55:
		return "CRUISE SPEED"
	if ratio > 0.22:
		return "MANEUVERING"
	if ratio > 0.04:
		return "HARBOR SLOW"
	return "DRIFT / STOP"


func _throttle_gear(throttle: float) -> String:
	if throttle > 0.82:
		return "前进四档"
	if throttle > 0.58:
		return "前进三档"
	if throttle > 0.24:
		return "前进二档"
	if throttle > 0.06:
		return "前进一档"
	if throttle < -0.08:
		return "倒车"
	return "停车"


func _cardinal(degrees: float) -> String:
	var labels := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	var index := int(round(fposmod(degrees, 360.0) / 45.0)) % labels.size()
	return labels[index]


func _format_time(seconds: float) -> String:
	var whole_seconds := int(maxf(seconds, 0.0))
	var minutes := whole_seconds / 60
	var remaining_seconds := whole_seconds % 60
	return "%02d:%02d" % [minutes, remaining_seconds]

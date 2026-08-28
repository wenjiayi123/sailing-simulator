"""Target-controller HIL runtime with fail-safe timing and authority gates.

The runtime is deliberately independent from the vessel plant and RL policies.  It
accepts proposed commands, validates target-controller telemetry, and either emits
a bounded command or a neutral command.  It never grants production authority.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import socket
import statistics
import time
from typing import Any, Mapping, Sequence

from tools.ship_assurance.hil import decode_frame, encode_frame


NEUTRAL_COMMAND = {"throttle": 0.0, "rudder": 0.0}
REQUIRED_TELEMETRY_FIELDS = (
    "heading_deg",
    "latitude_deg",
    "longitude_deg",
    "speed_knots",
    "rudder_feedback",
    "throttle_feedback",
    "estop_channel_a",
    "estop_channel_b",
    "manual_override",
)


def _canonical(value: Mapping[str, Any]) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _finite(value: Any) -> bool:
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(float(value))


def _percentile(values: Sequence[float], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(float(item) for item in values)
    position = (len(ordered) - 1) * percentile
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


@dataclass(frozen=True)
class RuntimeLimits:
    cycle_period_ms: float
    execution_deadline_ms: float
    maximum_sensor_age_ms: float
    maximum_clock_offset_ms: float
    watchdog_timeout_ms: float
    recovery_healthy_cycles: int
    minimum_timing_samples: int
    minimum_throttle: float
    maximum_throttle: float
    maximum_absolute_rudder: float

    @classmethod
    def from_profile(cls, profile: Mapping[str, Any]) -> "RuntimeLimits":
        command = profile.get("command_limits", {})
        if not isinstance(command, Mapping):
            raise ValueError("command_limits must be an object")
        limits = cls(
            cycle_period_ms=float(profile["cycle_period_ms"]),
            execution_deadline_ms=float(profile["execution_deadline_ms"]),
            maximum_sensor_age_ms=float(profile["maximum_sensor_age_ms"]),
            maximum_clock_offset_ms=float(profile["maximum_clock_offset_ms"]),
            watchdog_timeout_ms=float(profile["watchdog_timeout_ms"]),
            recovery_healthy_cycles=int(profile["recovery_healthy_cycles"]),
            minimum_timing_samples=int(profile["minimum_timing_samples"]),
            minimum_throttle=float(command["minimum_throttle"]),
            maximum_throttle=float(command["maximum_throttle"]),
            maximum_absolute_rudder=float(command["maximum_absolute_rudder"]),
        )
        numeric = (
            limits.cycle_period_ms,
            limits.execution_deadline_ms,
            limits.maximum_sensor_age_ms,
            limits.maximum_clock_offset_ms,
            limits.watchdog_timeout_ms,
            limits.minimum_throttle,
            limits.maximum_throttle,
            limits.maximum_absolute_rudder,
        )
        if not all(math.isfinite(value) for value in numeric):
            raise ValueError("runtime limits must be finite")
        if (
            limits.cycle_period_ms <= 0.0
            or limits.execution_deadline_ms <= 0.0
            or limits.execution_deadline_ms >= limits.cycle_period_ms
            or limits.maximum_sensor_age_ms <= 0.0
            or limits.maximum_clock_offset_ms <= 0.0
            or limits.watchdog_timeout_ms <= limits.cycle_period_ms
            or limits.recovery_healthy_cycles < 2
            or limits.minimum_timing_samples < 1000
            or limits.minimum_throttle >= 0.0
            or limits.maximum_throttle <= 0.0
            or limits.maximum_absolute_rudder <= 0.0
        ):
            raise ValueError("runtime limits violate the fail-safe contract")
        return limits


def validate_runtime_profile(profile: Mapping[str, Any]) -> list[str]:
    errors: list[str] = []
    if profile.get("schema_version") != "physical_hil_runtime_profile_v1":
        errors.append("unsupported schema_version")
    if profile.get("execution_context") != "bench_functional_smoke":
        errors.append("checked-in profile must remain bench_functional_smoke")
    try:
        RuntimeLimits.from_profile(profile)
    except (KeyError, TypeError, ValueError) as error:
        errors.append(str(error))
    adapter = profile.get("target_controller_adapter", {})
    if not isinstance(adapter, Mapping):
        errors.append("target_controller_adapter must be an object")
    else:
        for key in (
            "transport",
            "telemetry_frame_type",
            "command_frame_type",
            "receipt_frame_type",
        ):
            if not str(adapter.get(key, "")).strip():
                errors.append(f"target_controller_adapter.{key} is required")
        for key in (
            "sequence_required",
            "monotonic_timestamp_required",
            "explicit_physical_io_enable_required",
        ):
            if adapter.get(key) is not True:
                errors.append(f"target_controller_adapter.{key} must be true")
    fields = profile.get("required_telemetry_fields", [])
    if not isinstance(fields, list) or set(fields) != set(REQUIRED_TELEMETRY_FIELDS):
        errors.append("required_telemetry_fields do not match runtime contract")
    estop = profile.get("dual_channel_emergency_stop", {})
    if not isinstance(estop, Mapping):
        errors.append("dual_channel_emergency_stop must be an object")
    else:
        if not str(estop.get("channel_a", "")).strip() or not str(estop.get("channel_b", "")).strip():
            errors.append("both emergency-stop channels are required")
        if estop.get("channel_a") == estop.get("channel_b"):
            errors.append("emergency-stop channels must be distinct")
        for key in (
            "reset_requires_both_channels_clear",
            "reset_requires_manual_confirmation",
            "reset_requires_key_confirmation",
        ):
            if estop.get(key) is not True:
                errors.append(f"dual_channel_emergency_stop.{key} must be true")
    recovery = profile.get("recovery_policy", {})
    if not isinstance(recovery, Mapping) or any(
        recovery.get(key) is not expected
        for key, expected in {
            "automatic_rearm": False,
            "neutral_during_recovery": True,
            "manual_confirmation_required": True,
            "key_confirmation_required": True,
        }.items()
    ):
        errors.append("recovery_policy must be manual and fail-safe")
    claims = profile.get("claims", {})
    if not isinstance(claims, Mapping) or any(value is not False for value in claims.values()):
        errors.append("checked-in runtime claims must remain false")
    return errors


class PhysicalHilRuntime:
    """Fail-safe state machine placed between a controller and actuator I/O."""

    def __init__(self, profile: Mapping[str, Any]) -> None:
        errors = validate_runtime_profile(profile)
        if errors:
            raise ValueError("; ".join(errors))
        self.profile_id = str(profile.get("profile_id", ""))
        self.limits = RuntimeLimits.from_profile(profile)
        self.state = "SAFE_NEUTRAL"
        self.armed = False
        self.last_sequence = -1
        self.last_valid_host_ns: int | None = None
        self.healthy_recovery_cycles = 0
        self.estop_channel_a = False
        self.estop_channel_b = False
        self.execution_times_ms: list[float] = []
        self.receipts: list[dict[str, Any]] = []
        self.receipt_chain_head = "0" * 64
        self.last_output = dict(NEUTRAL_COMMAND)

    def _append_receipt(self, event: str, reasons: Sequence[str], output: Mapping[str, Any]) -> dict[str, Any]:
        core = {
            "index": len(self.receipts),
            "previous_sha256": self.receipt_chain_head,
            "event": event,
            "state": self.state,
            "armed": self.armed,
            "reasons": list(reasons),
            "output": dict(output),
        }
        digest = hashlib.sha256(_canonical(core)).hexdigest()
        receipt = {**core, "sha256": digest}
        self.receipts.append(receipt)
        self.receipt_chain_head = digest
        return receipt

    def _neutral(self, event: str, reasons: Sequence[str]) -> dict[str, Any]:
        self.last_output = dict(NEUTRAL_COMMAND)
        receipt = self._append_receipt(event, reasons, self.last_output)
        return {"accepted": False, "state": self.state, "output": dict(self.last_output), "receipt": receipt}

    def arm(self, *, manual_confirmed: bool, key_confirmed: bool) -> bool:
        allowed = (
            self.state == "SAFE_NEUTRAL"
            and not self.estop_channel_a
            and not self.estop_channel_b
            and manual_confirmed
            and key_confirmed
        )
        if allowed:
            self.state = "ARMED"
            self.armed = True
        self._append_receipt(
            "ARM_REQUEST",
            ["ACCEPTED" if allowed else "MANUAL_AND_KEY_CONFIRMATION_REQUIRED"],
            self.last_output,
        )
        return allowed

    def process_cycle(
        self,
        telemetry: Mapping[str, Any],
        proposed_command: Mapping[str, Any],
        *,
        host_monotonic_ns: int,
        controller_monotonic_ns: int,
        sensor_monotonic_ns: int,
        measured_execution_ms: float | None = None,
    ) -> dict[str, Any]:
        started_ns = time.perf_counter_ns()
        reasons: list[str] = []
        sequence_raw = telemetry.get("sequence")
        if not isinstance(sequence_raw, int) or isinstance(sequence_raw, bool) or sequence_raw <= self.last_sequence:
            self.state = "INPUT_INVALID"
            self.armed = False
            return self._finish_cycle(started_ns, measured_execution_ms, "CYCLE_REJECTED", ["SEQUENCE_INVALID"])
        missing = [field for field in REQUIRED_TELEMETRY_FIELDS if field not in telemetry]
        numeric_fields = (
            "heading_deg",
            "latitude_deg",
            "longitude_deg",
            "speed_knots",
            "rudder_feedback",
            "throttle_feedback",
        )
        invalid_numeric = [field for field in numeric_fields if not _finite(telemetry.get(field))]
        if missing or invalid_numeric:
            self.state = "INPUT_INVALID"
            self.armed = False
            return self._finish_cycle(
                started_ns,
                measured_execution_ms,
                "CYCLE_REJECTED",
                [f"MISSING:{','.join(missing)}", f"NONFINITE:{','.join(invalid_numeric)}"],
            )
        self.last_sequence = int(sequence_raw)
        self.last_valid_host_ns = int(host_monotonic_ns)
        self.estop_channel_a = telemetry.get("estop_channel_a") is True
        self.estop_channel_b = telemetry.get("estop_channel_b") is True
        clock_offset_ms = abs(int(controller_monotonic_ns) - int(host_monotonic_ns)) / 1_000_000.0
        sensor_age_ms = (int(host_monotonic_ns) - int(sensor_monotonic_ns)) / 1_000_000.0
        timing_healthy = (
            clock_offset_ms <= self.limits.maximum_clock_offset_ms
            and -1.0 <= sensor_age_ms <= self.limits.maximum_sensor_age_ms
        )
        if self.estop_channel_a or self.estop_channel_b:
            self.state = "ESTOP_LATCHED"
            self.armed = False
            reasons.append("ESTOP_A" if self.estop_channel_a else "ESTOP_B")
        elif telemetry.get("manual_override") is True:
            self.state = "MANUAL_PRIORITY"
            self.armed = False
            reasons.append("MANUAL_OVERRIDE")
        elif not timing_healthy:
            self.state = "CLOCK_OR_SENSOR_TIME_INVALID"
            self.armed = False
            reasons.append("CLOCK_OFFSET" if clock_offset_ms > self.limits.maximum_clock_offset_ms else "SENSOR_AGE")
        elif self.state in {
            "DISCONNECTED",
            "CLOCK_OR_SENSOR_TIME_INVALID",
            "DEADLINE_OVERRUN",
            "INPUT_INVALID",
            "MANUAL_PRIORITY",
            "RECOVERY_PENDING",
        }:
            self.state = "RECOVERY_PENDING"
            self.healthy_recovery_cycles += 1
            reasons.append("MANUAL_RECOVERY_REQUIRED")
        if self.state != "ARMED" or not self.armed:
            return self._finish_cycle(started_ns, measured_execution_ms, "SAFE_NEUTRAL", reasons or [self.state])
        try:
            throttle = float(proposed_command["throttle"])
            rudder = float(proposed_command["rudder"])
        except (KeyError, TypeError, ValueError):
            self.state = "INPUT_INVALID"
            self.armed = False
            return self._finish_cycle(started_ns, measured_execution_ms, "CYCLE_REJECTED", ["COMMAND_INVALID"])
        if not math.isfinite(throttle) or not math.isfinite(rudder):
            self.state = "INPUT_INVALID"
            self.armed = False
            return self._finish_cycle(started_ns, measured_execution_ms, "CYCLE_REJECTED", ["COMMAND_NONFINITE"])
        bounded = {
            "throttle": max(self.limits.minimum_throttle, min(self.limits.maximum_throttle, throttle)),
            "rudder": max(-self.limits.maximum_absolute_rudder, min(self.limits.maximum_absolute_rudder, rudder)),
        }
        return self._finish_cycle(started_ns, measured_execution_ms, "BOUNDED_COMMAND", [], bounded)

    def _finish_cycle(
        self,
        started_ns: int,
        measured_execution_ms: float | None,
        event: str,
        reasons: Sequence[str],
        output: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        duration_ms = (
            float(measured_execution_ms)
            if measured_execution_ms is not None
            else (time.perf_counter_ns() - started_ns) / 1_000_000.0
        )
        self.execution_times_ms.append(duration_ms)
        if not math.isfinite(duration_ms) or duration_ms < 0.0 or duration_ms > self.limits.execution_deadline_ms:
            self.state = "DEADLINE_OVERRUN"
            self.armed = False
            event = "SAFE_NEUTRAL"
            reasons = [*reasons, "EXECUTION_DEADLINE_EXCEEDED"]
            output = NEUTRAL_COMMAND
        self.last_output = dict(output or NEUTRAL_COMMAND)
        receipt = self._append_receipt(event, reasons, self.last_output)
        return {
            "accepted": event == "BOUNDED_COMMAND",
            "state": self.state,
            "output": dict(self.last_output),
            "execution_time_ms": duration_ms,
            "receipt": receipt,
        }

    def poll_watchdog(self, *, host_monotonic_ns: int) -> dict[str, Any]:
        elapsed_ms = (
            math.inf
            if self.last_valid_host_ns is None
            else (int(host_monotonic_ns) - self.last_valid_host_ns) / 1_000_000.0
        )
        if elapsed_ms > self.limits.watchdog_timeout_ms:
            self.state = "DISCONNECTED"
            self.armed = False
            self.healthy_recovery_cycles = 0
            return self._neutral("WATCHDOG_TRIP", ["TELEMETRY_TIMEOUT"])
        return {"accepted": self.armed, "state": self.state, "output": dict(self.last_output)}

    def reset_estop(
        self,
        *,
        manual_confirmed: bool,
        key_confirmed: bool,
    ) -> bool:
        allowed = (
            self.state == "ESTOP_LATCHED"
            and not self.estop_channel_a
            and not self.estop_channel_b
            and manual_confirmed
            and key_confirmed
        )
        if allowed:
            self.state = "SAFE_NEUTRAL"
            self.armed = False
            self.healthy_recovery_cycles = 0
        self._append_receipt(
            "ESTOP_RESET_REQUEST",
            ["ACCEPTED" if allowed else "BOTH_CHANNELS_CLEAR_AND_DUAL_CONFIRMATION_REQUIRED"],
            NEUTRAL_COMMAND,
        )
        return allowed

    def recover(self, *, manual_confirmed: bool, key_confirmed: bool) -> bool:
        allowed = (
            self.state == "RECOVERY_PENDING"
            and self.healthy_recovery_cycles >= self.limits.recovery_healthy_cycles
            and not self.estop_channel_a
            and not self.estop_channel_b
            and manual_confirmed
            and key_confirmed
        )
        if allowed:
            self.state = "SAFE_NEUTRAL"
            self.armed = False
            self.healthy_recovery_cycles = 0
        self._append_receipt(
            "RECOVERY_REQUEST",
            ["ACCEPTED" if allowed else "HEALTHY_CYCLES_AND_DUAL_CONFIRMATION_REQUIRED"],
            NEUTRAL_COMMAND,
        )
        return allowed

    def timing_summary(self) -> dict[str, Any]:
        values = self.execution_times_ms
        return {
            "sample_count": len(values),
            "mean_ms": statistics.fmean(values) if values else 0.0,
            "p95_ms": _percentile(values, 0.95),
            "p99_ms": _percentile(values, 0.99),
            "maximum_ms": max(values, default=0.0),
            "deadline_ms": self.limits.execution_deadline_ms,
            "deadline_met": bool(values) and max(values) <= self.limits.execution_deadline_ms,
        }

    def verify_receipt_chain(self) -> bool:
        previous = "0" * 64
        for receipt in self.receipts:
            core = {key: value for key, value in receipt.items() if key != "sha256"}
            if core.get("previous_sha256") != previous:
                return False
            digest = hashlib.sha256(_canonical(core)).hexdigest()
            if receipt.get("sha256") != digest:
                return False
            previous = digest
        return previous == self.receipt_chain_head


class UdpTargetControllerAdapter:
    """Opt-in UDP adapter for a target controller; construction grants no authority."""

    def __init__(
        self,
        *,
        local_host: str,
        local_port: int,
        target_host: str,
        target_port: int,
        timeout_s: float = 0.2,
        allow_physical_io: bool = False,
    ) -> None:
        if target_host not in {"127.0.0.1", "::1", "localhost"} and not allow_physical_io:
            raise ValueError("non-loopback target requires explicit allow_physical_io")
        self.target = (str(target_host), int(target_port))
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind((str(local_host), int(local_port)))
        self.socket.settimeout(float(timeout_s))
        self.sequence = 0

    @property
    def local_address(self) -> tuple[str, int]:
        host, port = self.socket.getsockname()
        return str(host), int(port)

    def receive_telemetry(self) -> dict[str, Any]:
        raw, _source = self.socket.recvfrom(65535)
        frame = decode_frame(raw)
        if frame.get("type") != "telemetry":
            raise ValueError("target frame is not telemetry")
        return frame

    def send_command(self, *, session_id: str, monotonic_ns: int, payload: Mapping[str, Any]) -> None:
        frame = encode_frame(
            frame_type="command",
            session_id=session_id,
            sequence=self.sequence,
            monotonic_ns=monotonic_ns,
            payload=payload,
        )
        self.socket.sendto(frame, self.target)
        self.sequence += 1

    def close(self) -> None:
        self.socket.close()


def _sample(sequence: int, *, estop_a: bool = False, estop_b: bool = False, manual: bool = False) -> dict[str, Any]:
    return {
        "sequence": sequence,
        "heading_deg": 82.0,
        "latitude_deg": 33.75,
        "longitude_deg": -118.19,
        "speed_knots": 6.2,
        "rudder_feedback": 0.1,
        "throttle_feedback": 0.3,
        "estop_channel_a": estop_a,
        "estop_channel_b": estop_b,
        "manual_override": manual,
    }


def _cycle(
    runtime: PhysicalHilRuntime,
    sequence: int,
    host_ns: int,
    *,
    estop_a: bool = False,
    estop_b: bool = False,
    manual: bool = False,
    clock_offset_ms: float = 0.25,
    measured_execution_ms: float | None = None,
    command: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    return runtime.process_cycle(
        _sample(sequence, estop_a=estop_a, estop_b=estop_b, manual=manual),
        command or {"throttle": 0.32, "rudder": 0.18},
        host_monotonic_ns=host_ns,
        controller_monotonic_ns=host_ns + int(clock_offset_ms * 1_000_000.0),
        sensor_monotonic_ns=host_ns,
        measured_execution_ms=measured_execution_ms,
    )


def _estop_channel_smoke(profile: Mapping[str, Any], channel: str) -> dict[str, Any]:
    runtime = PhysicalHilRuntime(profile)
    armed = runtime.arm(manual_confirmed=True, key_confirmed=True)
    active_a = channel == "A"
    tripped = _cycle(runtime, 0, 0, estop_a=active_a, estop_b=not active_a)
    reset_while_active = runtime.reset_estop(manual_confirmed=True, key_confirmed=True)
    _cycle(runtime, 1, int(runtime.limits.cycle_period_ms * 1_000_000.0))
    reset_without_key = runtime.reset_estop(manual_confirmed=True, key_confirmed=False)
    reset_complete = runtime.reset_estop(manual_confirmed=True, key_confirmed=True)
    return {
        "armed": armed,
        "tripped": tripped["state"] == "ESTOP_LATCHED" and tripped["output"] == NEUTRAL_COMMAND,
        "reset_while_active_blocked": not reset_while_active,
        "reset_without_key_blocked": not reset_without_key,
        "manual_reset_complete": reset_complete and runtime.state == "SAFE_NEUTRAL" and not runtime.armed,
        "receipt_chain_valid": runtime.verify_receipt_chain(),
    }


def run_physical_hil_functional_smoke(profile: Mapping[str, Any]) -> dict[str, Any]:
    """Exercise runtime functions without claiming that physical hardware was used."""

    profile_errors = validate_runtime_profile(profile)
    if profile_errors:
        return {
            "schema_version": "physical_hil_runtime_functional_smoke_v1",
            "passed": False,
            "errors": profile_errors,
            "physical_hil_verified": False,
            "production_authority": False,
        }
    runtime = PhysicalHilRuntime(profile)
    limits = runtime.limits
    armed = runtime.arm(manual_confirmed=True, key_confirmed=True)
    period_ns = int(limits.cycle_period_ms * 1_000_000.0)
    nominal_outputs_bounded = True
    for sequence in range(limits.minimum_timing_samples):
        result = _cycle(runtime, sequence, sequence * period_ns)
        output = result["output"]
        nominal_outputs_bounded = nominal_outputs_bounded and (
            limits.minimum_throttle <= float(output["throttle"]) <= limits.maximum_throttle
            and abs(float(output["rudder"])) <= limits.maximum_absolute_rudder
        )
    timing = runtime.timing_summary()
    chain_valid = runtime.verify_receipt_chain()
    bounded_result = _cycle(
        runtime,
        limits.minimum_timing_samples,
        limits.minimum_timing_samples * period_ns,
        command={"throttle": 5.0, "rudder": -5.0},
    )
    command_clamped = bounded_result["output"] == {
        "throttle": limits.maximum_throttle,
        "rudder": -limits.maximum_absolute_rudder,
    }
    last_host_ns = limits.minimum_timing_samples * period_ns
    watchdog_host_ns = last_host_ns + int((limits.watchdog_timeout_ms + 1.0) * 1_000_000.0)
    watchdog = runtime.poll_watchdog(host_monotonic_ns=watchdog_host_ns)
    watchdog_neutral = watchdog["state"] == "DISCONNECTED" and watchdog["output"] == NEUTRAL_COMMAND
    recovery_not_automatic = True
    sequence = limits.minimum_timing_samples + 1
    for index in range(limits.recovery_healthy_cycles):
        recovered_cycle = _cycle(runtime, sequence + index, watchdog_host_ns + (index + 1) * period_ns)
        recovery_not_automatic = recovery_not_automatic and not recovered_cycle["accepted"]
    recovery_without_confirmation = runtime.recover(manual_confirmed=False, key_confirmed=False)
    recovery_without_key = runtime.recover(manual_confirmed=True, key_confirmed=False)
    recovery_complete = runtime.recover(manual_confirmed=True, key_confirmed=True)
    recovery_requires_rearm = recovery_complete and runtime.state == "SAFE_NEUTRAL" and not runtime.armed

    clock_runtime = PhysicalHilRuntime(profile)
    clock_runtime.arm(manual_confirmed=True, key_confirmed=True)
    clock_result = _cycle(
        clock_runtime,
        0,
        0,
        clock_offset_ms=limits.maximum_clock_offset_ms + 1.0,
    )
    deadline_runtime = PhysicalHilRuntime(profile)
    deadline_runtime.arm(manual_confirmed=True, key_confirmed=True)
    deadline_result = _cycle(
        deadline_runtime,
        0,
        0,
        measured_execution_ms=limits.execution_deadline_ms + 0.1,
    )
    manual_runtime = PhysicalHilRuntime(profile)
    manual_runtime.arm(manual_confirmed=True, key_confirmed=True)
    manual_result = _cycle(manual_runtime, 0, 0, manual=True)
    replay_runtime = PhysicalHilRuntime(profile)
    replay_runtime.arm(manual_confirmed=True, key_confirmed=True)
    _cycle(replay_runtime, 4, 0)
    replay_result = _cycle(replay_runtime, 4, period_ns)
    estop_a = _estop_channel_smoke(profile, "A")
    estop_b = _estop_channel_smoke(profile, "B")
    checks = {
        "runtime_profile_valid": not profile_errors,
        "manual_and_key_arm_required": armed,
        "minimum_wcet_sample_count_collected": timing["sample_count"] >= limits.minimum_timing_samples,
        "bench_wcet_within_deadline": timing["deadline_met"],
        "nominal_outputs_bounded": nominal_outputs_bounded,
        "out_of_range_command_clamped": command_clamped,
        "watchdog_disconnect_neutralized": watchdog_neutral,
        "disconnect_does_not_auto_rearm": recovery_not_automatic,
        "recovery_rejects_missing_confirmation": not recovery_without_confirmation and not recovery_without_key,
        "recovery_returns_safe_neutral_before_rearm": recovery_requires_rearm,
        "clock_offset_violation_neutralized": clock_result["state"] == "CLOCK_OR_SENSOR_TIME_INVALID" and clock_result["output"] == NEUTRAL_COMMAND,
        "execution_deadline_overrun_neutralized": deadline_result["state"] == "DEADLINE_OVERRUN" and deadline_result["output"] == NEUTRAL_COMMAND,
        "manual_override_has_priority": manual_result["state"] == "MANUAL_PRIORITY" and manual_result["output"] == NEUTRAL_COMMAND,
        "replayed_sequence_neutralized": replay_result["state"] == "INPUT_INVALID" and replay_result["output"] == NEUTRAL_COMMAND,
        "estop_channel_a_independently_trips": all(estop_a.values()),
        "estop_channel_b_independently_trips": all(estop_b.values()),
        "receipt_chain_is_tamper_evident": chain_valid,
    }
    return {
        "schema_version": "physical_hil_runtime_functional_smoke_v1",
        "profile_id": str(profile.get("profile_id", "")),
        "passed": all(checks.values()),
        "checks": checks,
        "timing": timing,
        "state_coverage": [
            "SAFE_NEUTRAL",
            "ARMED",
            "DISCONNECTED",
            "RECOVERY_PENDING",
            "CLOCK_OR_SENSOR_TIME_INVALID",
            "DEADLINE_OVERRUN",
            "MANUAL_PRIORITY",
            "INPUT_INVALID",
            "ESTOP_LATCHED",
        ],
        "dual_channel_emergency_stop": {"channel_a": estop_a, "channel_b": estop_b},
        "receipt_count": len(runtime.receipts),
        "receipt_chain_head_sha256": runtime.receipt_chain_head,
        "source_class": "BENCH_FUNCTIONAL_SMOKE",
        "target_controller_connected": False,
        "real_io_connected": False,
        "rtos_verified": False,
        "physical_hil_verified": False,
        "site_delivery_ready": False,
        "production_authority": False,
        "training_performed": False,
        "existing_model_modified": False,
        "boundary": "Runtime and fault-state functional smoke only. No target controller, real I/O rack, RTOS, independent emergency-stop wiring or witness was connected.",
    }

"""Protocol, watchdog, loopback and fault-injection support for HIL preparation."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import socket
from typing import Any, Mapping


SCHEMA = "xiaoyi_maritime_hil_frame_v1"


class FrameError(ValueError):
    """Raised when a HIL frame fails integrity or schema validation."""


def _canonical(value: Mapping[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def encode_frame(
    *,
    frame_type: str,
    session_id: str,
    sequence: int,
    monotonic_ns: int,
    payload: Mapping[str, Any],
) -> bytes:
    if frame_type not in ("telemetry", "command", "receipt"):
        raise ValueError("unsupported HIL frame type")
    core = {
        "schema": SCHEMA,
        "type": frame_type,
        "session_id": str(session_id),
        "sequence": int(sequence),
        "monotonic_ns": int(monotonic_ns),
        "payload": dict(payload),
    }
    return _canonical({**core, "sha256": hashlib.sha256(_canonical(core)).hexdigest()})


def decode_frame(data: bytes) -> dict[str, Any]:
    try:
        frame = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise FrameError("frame is not valid UTF-8 JSON") from error
    if not isinstance(frame, dict):
        raise FrameError("frame root must be an object")
    digest = str(frame.pop("sha256", ""))
    if not digest or hashlib.sha256(_canonical(frame)).hexdigest() != digest:
        raise FrameError("frame SHA-256 mismatch")
    if frame.get("schema") != SCHEMA:
        raise FrameError("unsupported HIL schema")
    if frame.get("type") not in ("telemetry", "command", "receipt"):
        raise FrameError("unsupported HIL frame type")
    if int(frame.get("sequence", -1)) < 0 or int(frame.get("monotonic_ns", -1)) < 0:
        raise FrameError("negative sequence or timestamp")
    if not isinstance(frame.get("payload"), dict):
        raise FrameError("payload must be an object")
    frame["sha256"] = digest
    return frame


def nmea_checksum(sentence_body: str) -> str:
    checksum = 0
    for character in sentence_body:
        checksum ^= ord(character)
    return f"{checksum:02X}"


def encode_nmea_telemetry(sequence: int, heading_deg: float, speed_knots: float, yaw_rate_deg_s: float) -> str:
    """Encode a checksum-protected proprietary NMEA 0183 telemetry sentence."""

    body = f"PXIYT,{int(sequence)},{float(heading_deg):.3f},{float(speed_knots):.3f},{float(yaw_rate_deg_s):.3f}"
    return f"${body}*{nmea_checksum(body)}\r\n"


def decode_nmea_telemetry(sentence: str) -> dict[str, float | int]:
    raw = sentence.strip()
    if not raw.startswith("$") or "*" not in raw:
        raise FrameError("invalid NMEA envelope")
    body, supplied = raw[1:].rsplit("*", 1)
    if nmea_checksum(body) != supplied.upper():
        raise FrameError("NMEA checksum mismatch")
    fields = body.split(",")
    if len(fields) != 5 or fields[0] != "PXIYT":
        raise FrameError("unsupported NMEA sentence")
    return {
        "sequence": int(fields[1]),
        "heading_deg": float(fields[2]),
        "speed_knots": float(fields[3]),
        "yaw_rate_deg_s": float(fields[4]),
    }


class UdpHilEndpoint:
    """Small UDP transport adapter; it does not grant actuation authority."""

    def __init__(self, host: str = "127.0.0.1", port: int = 0, timeout_s: float = 0.2) -> None:
        if host not in ("127.0.0.1", "::1", "localhost"):
            raise ValueError("reference HIL endpoint is loopback-only by default")
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind((host, int(port)))
        self.socket.settimeout(float(timeout_s))

    @property
    def address(self) -> tuple[str, int]:
        host, port = self.socket.getsockname()
        return str(host), int(port)

    def send(self, frame: bytes, destination: tuple[str, int]) -> None:
        self.socket.sendto(frame, destination)

    def receive(self, maximum_bytes: int = 65535) -> tuple[dict[str, Any], tuple[str, int]]:
        data, source = self.socket.recvfrom(maximum_bytes)
        return decode_frame(data), (str(source[0]), int(source[1]))

    def close(self) -> None:
        self.socket.close()

    def __enter__(self) -> "UdpHilEndpoint":
        return self

    def __exit__(self, *_args: Any) -> None:
        self.close()


@dataclass(frozen=True)
class GateConfig:
    maximum_age_ms: float
    watchdog_timeout_ms: float
    throttle_limit: float
    rudder_limit: float
    maximum_throttle_slew_per_s: float
    maximum_rudder_slew_per_s: float


class CommandGate:
    """Rejects stale/replayed/corrupt commands and neutralizes on timeout."""

    def __init__(self, config: GateConfig) -> None:
        self.config = config
        self.session_id: str | None = None
        self.last_sequence = -1
        self.last_valid_ns: int | None = None
        self.last_output_ns: int | None = None
        self.throttle = 0.0
        self.rudder = 0.0
        self.rejections: dict[str, int] = {}

    def _reject(self, reason: str) -> tuple[bool, str]:
        self.rejections[reason] = self.rejections.get(reason, 0) + 1
        return False, reason

    def accept(self, data: bytes, now_ns: int) -> tuple[bool, str]:
        try:
            frame = decode_frame(data)
        except FrameError:
            return self._reject("integrity")
        if frame["type"] != "command":
            return self._reject("wrong_type")
        if str(frame["session_id"]) != self.session_id and self.session_id is not None:
            return self._reject("session_change")
        sequence = int(frame["sequence"])
        if sequence <= self.last_sequence:
            return self._reject("replay_or_reorder")
        age_ms = (int(now_ns) - int(frame["monotonic_ns"])) / 1_000_000.0
        if age_ms < -1.0 or age_ms > self.config.maximum_age_ms:
            return self._reject("stale_or_future")
        payload = frame["payload"]
        try:
            throttle = float(payload["throttle"])
            rudder = float(payload["rudder"])
        except (KeyError, TypeError, ValueError):
            return self._reject("payload")
        if not math.isfinite(throttle) or not math.isfinite(rudder):
            return self._reject("payload")
        if abs(throttle) > self.config.throttle_limit or abs(rudder) > self.config.rudder_limit:
            return self._reject("range")
        self.session_id = str(frame["session_id"])
        self.last_sequence = sequence
        self.last_valid_ns = int(now_ns)
        self.last_output_ns = int(now_ns) if self.last_output_ns is None else self.last_output_ns
        self._move_toward(throttle, rudder, now_ns)
        return True, "accepted"

    def reset_session(self, session_id: str, now_ns: int, *, manual_authorized: bool) -> tuple[bool, str]:
        """Permit a sequence reset only after timeout and explicit authorization."""

        timed_out = self.last_valid_ns is None or (
            int(now_ns) - self.last_valid_ns
        ) / 1_000_000.0 > self.config.watchdog_timeout_ms
        if not manual_authorized:
            return self._reject("restart_not_authorized")
        if not timed_out:
            return self._reject("restart_while_active")
        self.session_id = str(session_id)
        self.last_sequence = -1
        self.last_valid_ns = None
        self.last_output_ns = int(now_ns)
        self.throttle = 0.0
        self.rudder = 0.0
        return True, "session_reset_authorized"

    def _move_toward(self, target_throttle: float, target_rudder: float, now_ns: int) -> None:
        previous = int(now_ns) if self.last_output_ns is None else self.last_output_ns
        dt = max((int(now_ns) - previous) / 1_000_000_000.0, 0.0)
        throttle_delta = self.config.maximum_throttle_slew_per_s * dt
        rudder_delta = self.config.maximum_rudder_slew_per_s * dt
        self.throttle += max(min(target_throttle - self.throttle, throttle_delta), -throttle_delta)
        self.rudder += max(min(target_rudder - self.rudder, rudder_delta), -rudder_delta)
        self.last_output_ns = int(now_ns)

    def output(self, now_ns: int) -> dict[str, Any]:
        timed_out = self.last_valid_ns is None or (
            int(now_ns) - self.last_valid_ns
        ) / 1_000_000.0 > self.config.watchdog_timeout_ms
        if timed_out:
            self.throttle = 0.0
            self.rudder = 0.0
        self.last_output_ns = int(now_ns)
        return {
            "mode": "FAIL_SAFE_NEUTRAL" if timed_out else "BOUNDED_COMMAND",
            "throttle": self.throttle,
            "rudder": self.rudder,
            "watchdog_timed_out": timed_out,
        }


def _corrupt(data: bytes) -> bytes:
    mutable = bytearray(data)
    mutable[max(0, len(mutable) // 2)] ^= 0x01
    return bytes(mutable)


def run_hil_loopback_campaign(profile: Mapping[str, Any]) -> dict[str, Any]:
    """Run logical-time loopback, integrity, replay, stale and watchdog tests."""

    period_ms = int(profile.get("cycle_period_ms", 50))
    cycles = int(profile.get("cycles", 160))
    config = GateConfig(
        maximum_age_ms=float(profile.get("maximum_frame_age_ms", 120.0)),
        watchdog_timeout_ms=float(profile.get("watchdog_timeout_ms", 150.0)),
        throttle_limit=float(profile.get("throttle_limit", 0.8)),
        rudder_limit=float(profile.get("rudder_limit", 0.7)),
        maximum_throttle_slew_per_s=float(profile.get("maximum_throttle_slew_per_s", 0.8)),
        maximum_rudder_slew_per_s=float(profile.get("maximum_rudder_slew_per_s", 1.2)),
    )
    gate = CommandGate(config)
    session = "software-loopback-v1"
    accepted = 0
    invalid_rejected = 0
    failures: list[str] = []
    previous_valid = b""
    dropout_window = set(range(20, 20 + math.ceil(config.watchdog_timeout_ms / period_ms) + 2))
    watchdog_neutralized = False
    injections = {
        "dropout": 0,
        "authorized_restart": 0,
        "unauthorized_session_change": 0,
        "corruption": 0,
        "replay": 0,
        "stale": 0,
        "out_of_range": 0,
    }
    authorized_restart_recovered = False
    chain = "0" * 64
    receipts = 0
    for sequence in range(cycles):
        now_ns = sequence * period_ms * 1_000_000
        if sequence in dropout_window:
            injections["dropout"] += 1
            output = gate.output(now_ns)
            watchdog_neutralized = watchdog_neutralized or output["watchdog_timed_out"]
            continue
        if sequence == max(dropout_window) + 1:
            session = "software-loopback-v1-restarted"
            restart_ok, restart_reason = gate.reset_session(
                session,
                now_ns,
                manual_authorized=True,
            )
            injections["authorized_restart"] += 1
            if not restart_ok:
                failures.append(f"authorized restart failed: {restart_reason}")
        payload = {
            "throttle": 0.35,
            "rudder": 0.20 if sequence % 40 < 20 else -0.20,
            "enable": False,
            "production_authority": False,
        }
        timestamp_ns = now_ns
        frame = encode_frame(
            frame_type="command",
            session_id=session,
            sequence=sequence,
            monotonic_ns=timestamp_ns,
            payload=payload,
        )
        expected_valid = True
        if sequence == 45:
            frame = encode_frame(
                frame_type="command",
                session_id="unauthorized-session",
                sequence=sequence,
                monotonic_ns=now_ns,
                payload=payload,
            )
            injections["unauthorized_session_change"] += 1
            expected_valid = False
        elif sequence == 55:
            frame = _corrupt(frame)
            injections["corruption"] += 1
            expected_valid = False
        elif sequence == 80 and previous_valid:
            frame = previous_valid
            injections["replay"] += 1
            expected_valid = False
        elif sequence == 105:
            frame = encode_frame(
                frame_type="command",
                session_id=session,
                sequence=sequence,
                monotonic_ns=now_ns - int((config.maximum_age_ms + 50.0) * 1_000_000),
                payload=payload,
            )
            injections["stale"] += 1
            expected_valid = False
        elif sequence == 130:
            frame = encode_frame(
                frame_type="command",
                session_id=session,
                sequence=sequence,
                monotonic_ns=now_ns,
                payload={**payload, "rudder": config.rudder_limit + 0.2},
            )
            injections["out_of_range"] += 1
            expected_valid = False
        ok, reason = gate.accept(frame, now_ns)
        if ok:
            accepted += 1
            previous_valid = frame
            if sequence == max(dropout_window) + 1:
                authorized_restart_recovered = True
            receipt = _canonical({"previous": chain, "sequence": sequence, "frame_sha256": hashlib.sha256(frame).hexdigest()})
            chain = hashlib.sha256(receipt).hexdigest()
            receipts += 1
        elif not expected_valid:
            invalid_rejected += 1
        else:
            failures.append(f"valid frame {sequence} rejected: {reason}")
        if ok is not expected_valid:
            failures.append(f"frame {sequence} validity mismatch")
        output = gate.output(now_ns)
        if abs(float(output["throttle"])) > config.throttle_limit + 1e-9 or abs(float(output["rudder"])) > config.rudder_limit + 1e-9:
            failures.append(f"bounded output exceeded at sequence {sequence}")

    nmea = encode_nmea_telemetry(7, 123.4, 8.6, -0.3)
    nmea_roundtrip = decode_nmea_telemetry(nmea)
    nmea_ok = nmea_roundtrip == {
        "sequence": 7,
        "heading_deg": 123.4,
        "speed_knots": 8.6,
        "yaw_rate_deg_s": -0.3,
    }
    expected_invalid = sum(
        injections[key]
        for key in (
            "unauthorized_session_change",
            "corruption",
            "replay",
            "stale",
            "out_of_range",
        )
    )
    checks = {
        "valid_frames_accepted": accepted > 0 and not failures,
        "invalid_frames_rejected": invalid_rejected == expected_invalid,
        "watchdog_neutralized_after_dropout": watchdog_neutralized,
        "authorized_restart_after_timeout": authorized_restart_recovered,
        "unauthorized_session_change_rejected": gate.rejections.get("session_change", 0) == 1,
        "bounded_slew_limited_output": not any("bounded output" in item for item in failures),
        "nmea_checksum_roundtrip": nmea_ok,
        "receipt_chain_complete": receipts == accepted and chain != "0" * 64,
    }
    return {
        "profile_id": str(profile.get("profile_id", "hil_loopback_v1")),
        "cycles": cycles,
        "accepted_frames": accepted,
        "invalid_frames_rejected": invalid_rejected,
        "fault_injections": injections,
        "watchdog_neutralized": watchdog_neutralized,
        "receipt_count": receipts,
        "receipt_chain_head_sha256": chain,
        "rejections": dict(sorted(gate.rejections.items())),
        "checks": checks,
        "passed": all(checks.values()) and not failures,
        "failures": failures,
        "software_loopback_verified": True,
        "physical_hardware_verified": False,
        "production_authority": False,
        "boundary": "UDP/NMEA codec, logical-time loopback, watchdog and fault-injection evidence only; no physical controller, actuator, bridge bus or class-witnessed HIL was connected.",
    }

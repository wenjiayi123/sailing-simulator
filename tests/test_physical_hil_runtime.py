from __future__ import annotations

import json
from pathlib import Path
import socket
import unittest

from tools.ship_assurance.hil import decode_frame, encode_frame
from tools.ship_assurance.physical_hil_runtime import (
    NEUTRAL_COMMAND,
    PhysicalHilRuntime,
    UdpTargetControllerAdapter,
    run_physical_hil_functional_smoke,
    validate_runtime_profile,
)


ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = ROOT / "data/verification/physical_hil_runtime_profile_v1.json"


def _profile() -> dict:
    return json.loads(PROFILE_PATH.read_text(encoding="utf-8"))


def _sample(sequence: int, **overrides: object) -> dict:
    sample = {
        "sequence": sequence,
        "heading_deg": 10.0,
        "latitude_deg": 1.0,
        "longitude_deg": 2.0,
        "speed_knots": 3.0,
        "rudder_feedback": 0.0,
        "throttle_feedback": 0.0,
        "estop_channel_a": False,
        "estop_channel_b": False,
        "manual_override": False,
    }
    sample.update(overrides)
    return sample


def _cycle(runtime: PhysicalHilRuntime, sequence: int, **overrides: object) -> dict:
    host_ns = sequence * 20_000_000
    return runtime.process_cycle(
        _sample(sequence, **overrides),
        {"throttle": 0.3, "rudder": 0.1},
        host_monotonic_ns=host_ns,
        controller_monotonic_ns=host_ns,
        sensor_monotonic_ns=host_ns,
    )


class PhysicalHilRuntimeTests(unittest.TestCase):
    def test_checked_in_profile_and_full_fault_campaign_pass(self) -> None:
        profile = _profile()
        self.assertEqual(validate_runtime_profile(profile), [])
        report = run_physical_hil_functional_smoke(profile)
        self.assertTrue(report["passed"], report)
        self.assertEqual(len(report["checks"]), 17)
        self.assertFalse(report["physical_hil_verified"])
        self.assertFalse(report["target_controller_connected"])
        self.assertFalse(report["training_performed"])
        self.assertFalse(report["existing_model_modified"])

    def test_each_estop_channel_latches_and_neutralizes(self) -> None:
        for channel in ("estop_channel_a", "estop_channel_b"):
            runtime = PhysicalHilRuntime(_profile())
            self.assertTrue(runtime.arm(manual_confirmed=True, key_confirmed=True))
            result = _cycle(runtime, 0, **{channel: True})
            self.assertEqual(result["state"], "ESTOP_LATCHED")
            self.assertEqual(result["output"], NEUTRAL_COMMAND)
            self.assertFalse(runtime.reset_estop(manual_confirmed=True, key_confirmed=True))

    def test_disconnect_recovery_never_rearms_automatically(self) -> None:
        runtime = PhysicalHilRuntime(_profile())
        self.assertTrue(runtime.arm(manual_confirmed=True, key_confirmed=True))
        _cycle(runtime, 0)
        result = runtime.poll_watchdog(host_monotonic_ns=200_000_000)
        self.assertEqual(result["state"], "DISCONNECTED")
        self.assertEqual(result["output"], NEUTRAL_COMMAND)
        for sequence in range(1, runtime.limits.recovery_healthy_cycles + 1):
            result = _cycle(runtime, sequence)
            self.assertFalse(result["accepted"])
        self.assertTrue(runtime.recover(manual_confirmed=True, key_confirmed=True))
        self.assertEqual(runtime.state, "SAFE_NEUTRAL")
        self.assertFalse(runtime.armed)

    def test_receipts_detect_tampering(self) -> None:
        runtime = PhysicalHilRuntime(_profile())
        runtime.arm(manual_confirmed=True, key_confirmed=True)
        _cycle(runtime, 0)
        self.assertTrue(runtime.verify_receipt_chain())
        runtime.receipts[-1]["output"]["throttle"] = 0.99
        self.assertFalse(runtime.verify_receipt_chain())

    def test_non_loopback_adapter_requires_explicit_physical_io_enable(self) -> None:
        with self.assertRaisesRegex(ValueError, "explicit allow_physical_io"):
            UdpTargetControllerAdapter(
                local_host="127.0.0.1",
                local_port=0,
                target_host="192.0.2.20",
                target_port=9100,
            )

    def test_target_controller_adapter_is_bidirectional_on_bench(self) -> None:
        controller = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        controller.bind(("127.0.0.1", 0))
        controller.settimeout(1.0)
        host, port = controller.getsockname()
        adapter = UdpTargetControllerAdapter(
            local_host="127.0.0.1",
            local_port=0,
            target_host=str(host),
            target_port=int(port),
        )
        try:
            telemetry = encode_frame(
                frame_type="telemetry",
                session_id="bench",
                sequence=3,
                monotonic_ns=100,
                payload=_sample(3),
            )
            controller.sendto(telemetry, adapter.local_address)
            received = adapter.receive_telemetry()
            self.assertEqual(received["sequence"], 3)
            adapter.send_command(
                session_id="bench",
                monotonic_ns=120,
                payload={"throttle": 0.2, "rudder": -0.1},
            )
            raw, _source = controller.recvfrom(65535)
            command = decode_frame(raw)
            self.assertEqual(command["type"], "command")
            self.assertEqual(command["payload"]["throttle"], 0.2)
        finally:
            adapter.close()
            controller.close()


if __name__ == "__main__":
    unittest.main()

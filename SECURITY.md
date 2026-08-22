# Security policy

## Supported scope

Security fixes target the current default branch. This repository is an
offline research simulator: it does not authorize commands to a real vessel,
VTS, TOS, bridge system, autopilot, engine, rudder, or navigation sensor.

## Reporting a vulnerability

Please use GitHub private vulnerability reporting when it is enabled. Include
the affected revision, reproduction steps, impact, and whether the issue can
cross the Python/Godot process boundary. Do not include credentials, personal
AIS records, or exploit payloads in a public issue.

## High-risk boundaries

- Stable-Baselines3 model archives can deserialize Python objects. Only load
  repository-bundled models after their SHA-256 matches a frozen evidence
  manifest; never load an untrusted model file.
- Treat imported AIS, ENC, port packages, experiment JSON, and replay files as
  untrusted input. Validate schema, size, path, source, and hash before use.
- Godot launches a pinned local Python entry point. User-controlled paths must
  not become arbitrary executable paths or shell fragments.
- `live_control_ready`, `deployment_authority`, and equivalent production
  gates must remain false unless the external approvals in
  `docs/PRODUCTION_READINESS.md` are independently completed.

See `docs/THREAT_MODEL.md` for the complete trust-boundary analysis.

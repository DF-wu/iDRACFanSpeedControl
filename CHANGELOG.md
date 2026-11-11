# Changelog

## Unreleased — proposed v3.0.0

This is a release proposal, not a published version. The previous published release is [v2.0.1](https://github.com/DF-wu/iDRACFanSpeedControl/releases/tag/v2.0.1), dated 2024-10-23. Review the [complete changes since v2.0.1](https://github.com/DF-wu/iDRACFanSpeedControl/compare/v2.0.1...master) and [publication checklist](docs/RELEASING.md).

### Release notes

- Reworked Bash controller with validated configuration, manual/once/continuous modes, explicit Dell automatic restoration, all-source fail-safe, and persistent cycle logs/healthchecks ([#1](https://github.com/DF-wu/iDRACFanSpeedControl/pull/1), [#2](https://github.com/DF-wu/iDRACFanSpeedControl/pull/2)).
- Pure Bash setup TUI, redacted configuration display, and diagnostics that read configured dependencies without changing fans ([#3](https://github.com/DF-wu/iDRACFanSpeedControl/pull/3)).
- Unified temperature source interface: ESXi NVMe, iDRAC sensors, local Linux SMART disks, and local/remote NVIDIA GPUs. Highest valid adjusted reading drives the curve; partial source/target failures retain other usable readings ([#4](https://github.com/DF-wu/iDRACFanSpeedControl/pull/4)).
- Reject implausible raw readings outside −20…150°C before applying offsets, avoiding packed SMART values being interpreted as temperatures ([#5](https://github.com/DF-wu/iDRACFanSpeedControl/pull/5)).
- Linear fan-speed interpolation enabled by default, including old configurations that omit the switch; ceiling rounding between four anchors, with stepwise/downshift hysteresis available by setting `FAN_SPEED_INTERPOLATION=false` ([#6](https://github.com/DF-wu/iDRACFanSpeedControl/pull/6)).
- Docker deployment with host networking, persistent logs, read-only SSH secrets, optional disk mappings/GPU access, and GHCR publication. Pull requests now validate the image build without publishing it.
- Updated English onboarding, operations, troubleshooting and release instructions, synchronized Traditional Chinese README, and minimal CodeRabbit GitHub App review configuration with owner activation instructions.

### Migration and compatibility

A major version is proposed because cumulative changes since v2.0.1 alter deployment, configuration validation, defaults, and fan-curve behavior. This is not a claim that v3.0.0 has been hardware-certified.

1. Stop the old controller and restore Dell automatic control before migration. Keep the known-good image, code, and protected configuration for rollback.
2. Merge the current `.env.example` into your configuration instead of blindly reusing a 2024 `.env`. Replace placeholders; explicitly select sources and verify required SSH keys/devices/GPU access.
3. Current default thresholds are **65/70/75/80°C**; duties are **30/30/40/50/60%**, with **70% fail-safe**. At the v2.0.1 tag, thresholds were 45/55/65/70°C and low/medium/high/critical duties were 20/30/40/60%. Review every threshold/duty against your hardware.
4. Interpolation is now default and ignores hysteresis. Explicitly set `FAN_SPEED_INTERPOLATION=false` to retain the stepwise decision model, then verify your configured anchors; this does not restore older default values automatically.
5. Runtime mode still defaults to `manual`; the current template selects `auto`. Keep the restartable Compose service on `auto`; run manual/once as one-off commands and explicitly restore afterward.
6. Bare scripts do not read `.env`; Compose does. Logs persist at `./logs/fan_control.log`, SSH secrets mount at `/run/secrets`, and every local disk needs its own device mapping. A local Docker build requires selecting that image in Compose.
7. Validate, diagnose, supervise manual/restore checks, then start unattended operation. See [upgrade and rollback](USAGE_GUIDE.md#upgrade-and-rollback).

Only one Dell PowerEdge R730xd with iDRAC 8 has historical hardware testing. No firmware version range, other server model, new hardware test, or production deployment is certified by this release preparation. Exit restoration remains best-effort; explicit stop and restore plus verification in iDRAC are required. A fresh fail-safe log can be healthy even when every temperature source has failed.

## v2.0.1 — 2024-10-23

Published as “v2.0.1 hotfix”. Use the actual Git tag `v2.0.1` as the migration baseline. See the [original release](https://github.com/DF-wu/iDRACFanSpeedControl/releases/tag/v2.0.1) for its historical notes.

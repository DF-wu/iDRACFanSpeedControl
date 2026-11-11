# Troubleshooting

If cooling or the current fan state is uncertain, follow [stop and restore](../USAGE_GUIDE.md#stop-and-restore-dell-automatic-control) first:

```bash
docker compose stop --timeout 90
docker compose run --rm --no-deps -e DRY_RUN=false idrac-fan-control restore
```

Confirm firmware automatic control in iDRAC. Keep the controller stopped while diagnosing. Exit restoration is best-effort and may not execute before Docker force-kills a process blocked in a foreground query/sleep.

## Collect evidence without changing fans

```bash
docker compose run --rm --no-deps idrac-fan-control config
make validate
docker compose run --rm --no-deps idrac-fan-control diagnose
docker compose ps
docker logs --tail 200 idrac-fan-control
tail -n 200 logs/fan_control.log
```

Set `LOG_LEVEL=DEBUG` in `.env` and rerun one-off diagnostics for command stages and source details. Recreate the service to apply environment changes when it is safe to restart. `diagnose` never sends fan raw commands, but it performs real read queries and creates/touches the log path. `DRY_RUN` suppresses only IPMI, so it is not a way to run arbitrary configured sources offline.

The config summary redacts passwords; still remove hostnames, addresses, service tags, and device identifiers before sharing. Never attach `.env` or private keys.

## Symptoms and checks

| Symptom | Check | Action |
| --- | --- | --- |
| Missing `.env` or placeholder validation errors | Root `.env`, selected sources, actual credentials/address | Run `make tui` or copy the template and replace selected-source placeholders. Alternate TUI config paths do not replace the required root `.env` |
| Local script ignores `.env` | Script reads exported environment only | Use Compose for deployment; the bare script does not load dotenv files |
| IPMI login or `mc info` fails | IPMI over LAN, routing/firewall, privileges, password, `lanplus` support | Resolve management access first; do not start auto |
| Fan raw command rejected | Exact model/firmware and OEM command support | Login success does not prove fan-command support. Only one R730xd/iDRAC 8 has historical testing; keep firmware control active on unsupported systems |
| ESXi has no temperature | SSH, full `DRIVE_DEVICE`, numeric `Drive Temperature` | Check the [ESXi identifier commands](../README.md#finding-the-esxi-drive-identifier) and select a device with usable SMART output |
| Linux disk has no temperature | Device mapping, permissions, `smartctl -A -j`, JSON fields | Map every selected device and discover its actual host path. Nonzero smartctl health bits alone do not invalidate a usable temperature |
| Sleeping disk disappears | `LINUX_DISK_NOCHECK=standby` and power state | A sleeping disk may intentionally have no reading; choose always-available sources instead of treating missing data as zero |
| Local GPU missing | Driver, NVIDIA Container Toolkit, Compose `gpus: all`, `nvidia-smi` | Verify host/container GPU access, then diagnose |
| Remote GPU fails | Shared SSH identity, key permissions, port, noninteractive PATH | Every host must run the read-only `nvidia-smi` query from [source examples](TEMPERATURE_SOURCES.md). Inspect warnings for each host |
| SSH host keys fail or are repeatedly relearned | Known-hosts file inside ephemeral containers | Verify fingerprints through a trusted channel and mount known-hosts; avoid disabling verification to hide errors |
| Source passes despite failed device/VM | Warnings and sensor labels | Multi-target sources pass if any target succeeds. Repair every expected target; the hottest component may be missing |
| Decision ignores a reading | Raw value, integer parsing, filters, offsets | Raw values outside −20…150°C are rejected. GPU/disk offsets subtract and clamp at zero |
| All sources fail | Fail-safe settings and `status=failsafe` | Enabled fail-safe applies its configured duty; disabled fail-safe leaves previous fan state with no new cycle record. Restore while fixing sources |
| Healthy but readings fail | Cycle status and warnings | Fail-safe records keep freshness healthy. Health does not guarantee temperature safety or source completeness |
| Container unhealthy | Writable log mount, record time, interval/command duration | Repair the loop/source instead of only increasing freshness. Docker does not restart solely on unhealthy |
| Manual duty changes again | Another controller/container/process | Stop all writers before one-off tests or final restore |
| Duty remains after once/manual | No exit restoration trap for those commands | Explicitly restore; do not use those commands as restartable service mode |
| Stop does not restore | Foreground sleep/query, force-kill, lost IPMI | Explicitly stop and restore; verify in iDRAC instead of relying on the trap |
| Local build has no effect | Compose `image:` | Select `idrac-fan-control:local`; `make docker-build` does not change the deployed image |
| Edited settings have no effect | Running environment/image vs `.env` | Validate and diagnose, then `docker compose up -d --force-recreate`; restart does not reload environment |

## Interpolation and hysteresis

`FAN_SPEED_INTERPOLATION=true` is default, including when omitted in old configs. Between low/medium/high/critical anchors it rounds upward, so the same logged level may have different duties. Below `TEMP_LOW`, idle remains separate; distinct idle/low speeds cause a jump at that boundary. At/above critical it clamps to the configured critical duty, which is not necessarily 100%.

Interpolation ignores `HYSTERESIS`. For the old staircase and downshift-only hysteresis, explicitly set `FAN_SPEED_INTERPOLATION=false`, validate, and recreate. `config` and `diagnose` show the mode and decision preview.

## Logs and health freshness

```bash
ls -ld logs
ls -l logs/fan_control.log
docker inspect idrac-fan-control --format '{{json .Mounts}}'
```

Default freshness is `CHECK_INTERVAL*3 + COMMAND_TIMEOUT` seconds (200 with defaults). Collection across multiple targets can take longer than one command timeout. Size interval/freshness for measured collection time while keeping fault detection useful. Health uses file modification time; one-off processes or touched files can mask a stale main loop. Check timestamps and cycle status too.

See [log retention](../USAGE_GUIDE.md#log-retention) and [upgrade/rollback](../USAGE_GUIDE.md#upgrade-and-rollback).

## Reporting an issue

Include model and firmware, image tag/digest and code revision, selected sources, redacted config/diagnose, recent logs, the preceding change, and `make test` results if available. State whether evidence uses mocks or hardware. Exclude credentials, keys, service tags, and public management endpoints.

Documentation last reviewed: November 11, 2026.

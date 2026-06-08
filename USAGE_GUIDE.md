# iDRAC Fan Control Runbook

This runbook is for day-to-day operation. Use [README.md](README.md) for setup, full configuration, and troubleshooting details.

## Daily Commands

Start the controller:

```bash
docker compose up -d
```

Watch decisions:

```bash
docker logs -f idrac-fan-control
tail -f logs/fan_control.log
```

Run one automatic cycle:

```bash
docker compose run --rm idrac-fan-control once
```

Set a manual fan speed:

```bash
docker compose run --rm idrac-fan-control manual 35
```

Restore Dell automatic fan control:

```bash
docker compose run --rm idrac-fan-control restore
```

Validate configuration:

```bash
docker compose run --rm idrac-fan-control validate
```

Print iDRAC status and temperature sensors:

```bash
docker compose run --rm idrac-fan-control status
```

## Emergency Procedure

1. Restore Dell automatic fan control.

```bash
docker compose run --rm idrac-fan-control restore
```

2. Stop the container.

```bash
docker compose down
```

3. Check temperatures from iDRAC Web UI or `status`.

```bash
docker compose run --rm idrac-fan-control status
```

4. Raise `FAILSAFE_FAN_SPEED` or the fan curve before starting auto mode again.

## Common Changes

Use iDRAC sensors without ESXi:

```env
TEMPERATURE_SOURCES=idrac
```

Use ESXi NVMe SMART plus iDRAC sensors:

```env
TEMPERATURE_SOURCES=esxi,idrac
```

Enable GPU temperature:

```env
TEMPERATURE_SOURCES=esxi,gpu
GPU_TEMP_OFFSET=15
```

Reduce speed changes near thresholds:

```env
HYSTERESIS=3
```

Use a conservative fail-safe:

```env
FAILSAFE_ON_ERROR=true
FAILSAFE_FAN_SPEED=80
```

## Maintenance

Update image and restart:

```bash
docker compose pull
docker compose up -d
```

Run tests after local changes:

```bash
make test
```

Build a local image:

```bash
make docker-build
```

Last reviewed: 2026-06-08.

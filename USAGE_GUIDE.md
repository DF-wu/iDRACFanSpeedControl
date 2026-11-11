# Operations guide

For first installation, prerequisites, configuration variables, and hardware limitations, start with [README.md](README.md). For errors, use [troubleshooting](docs/TROUBLESHOOTING.md). Commands below assume the repository directory, a reviewed `.env`, and the selected Compose image. They are operator instructions, not evidence of hardware testing.

## Before starting

1. Keep iDRAC Web UI or physical console access available. Historical testing covers only one R730xd with iDRAC 8; verify your own model and firmware.
2. Create `.env` with `make tui` or copy `.env.example`, set permissions to `600`, and replace selected-source placeholders. Keep `OPERATION_MODE=auto` for the long-running Compose service.
3. Prepare directories and the image, then perform checks that do not change fans:

   ```bash
   mkdir -p logs secrets
   docker compose pull
   make validate
   docker compose run --rm --no-deps idrac-fan-control config
   docker compose run --rm --no-deps idrac-fan-control diagnose
   ```

`validate` checks the configured `OPERATION_MODE`; it does not test connectivity. `diagnose` validates all selected sources, reads hardware/SSH endpoints, and creates/touches the log path without sending fan raw commands. Check each device/host warning as well as the overall result: a multi-target source passes if at least one target supplies a reading. Review the selected temperature and predicted duty against your hardware needs.

Before unattended operation, stop any active controller, test a conservative manual duty while watching iDRAC temperatures/fans, and explicitly restore. For example:

```bash
docker compose stop --timeout 90
docker compose run --rm --no-deps idrac-fan-control manual 70
docker compose run --rm --no-deps idrac-fan-control status
docker compose run --rm --no-deps idrac-fan-control restore
```

These commands change hardware. No duty is universally safe. `status` shows chassis and temperatures, not proof of the selected fan duty; verify fans and firmware automatic control in iDRAC. If any command fails, keep the controller stopped and resolve recovery before proceeding.

## Daily operation

After the supervised checks:

```bash
docker compose up -d
docker compose ps
docker logs -f idrac-fan-control
tail -f logs/fan_control.log
```

A successful cycle records `status=ok`, temperature, level, duty, and source details. All-source failure with `FAILSAFE_ON_ERROR=true` writes `status=failsafe` and applies `FAILSAFE_FAN_SPEED`. Partial failures continue with remaining readings; investigate them because the hottest component may be missing. With fail-safe disabled, all-source failure leaves the previous fan state and writes no new cycle record.

The healthcheck measures log freshness in `OPERATION_MODE=auto`, including fail-safe records. It does not prove safe temperatures, complete source coverage, or hardware response. Outside `auto`, it only validates configuration. Docker does not restart containers solely because they become unhealthy.

```bash
docker compose exec idrac-fan-control /usr/local/bin/fan-control.sh healthcheck
docker compose run --rm --no-deps idrac-fan-control diagnose
```

Use `exec` for the running controller healthcheck; a one-off `run ... healthcheck` uses the current disk `.env`, which may differ from the running container after edits. `config` is redacted, but review hostnames and addresses before sharing it.

## Manual and one-cycle operation

Stop the continuous controller first. `once` reads temperatures and applies one curve/fail-safe decision; `manual 70` applies a fixed duty. Both leave manual control active after exit. Only continuous `auto` has an exit restoration trap.

```bash
docker compose stop --timeout 90
docker compose run --rm --no-deps idrac-fan-control once
# Observe the hardware, then explicitly restore:
docker compose run --rm --no-deps idrac-fan-control restore
```

Manual accepts integer duty from 1–100. Without a CLI speed, it uses `MANUAL_FAN_SPEED` (template: `35`; runtime default: empty). Without either, it prompts on a terminal or fails with noninteractive stdin. Do not put `once` or `manual` into the long-running service: its restart policy can repeatedly execute them.

`DRY_RUN=true` suppresses IPMI calls, including restoration. It does not simulate sensor data or suppress SSH, `nvidia-smi`, or `smartctl` queries. Use `make test` and `make validate-example` for offline verification.

## Stop and restore Dell automatic control

Stop the loop **before the final restore**, so another cycle cannot retake manual control:

```bash
docker compose stop --timeout 90
docker compose run --rm --no-deps -e DRY_RUN=false idrac-fan-control restore
```

Confirm the restore command succeeded and verify firmware automatic control and temperatures in iDRAC. Keep the service stopped until the problem is understood. After successful recovery, `docker compose down` can remove the stopped service; logs remain in `./logs`.

`RESTORE_AUTO_ON_EXIT=true` is best-effort. Bash can defer signal handling while waiting for a foreground query or sleep; the default Compose stop timeout can expire first. The explicit 90-second wait accommodates the default 60-second sleep and usual command timing, but longer intervals, multiple slow sources, SIGKILL, host failure, or lost IPMI connectivity can still prevent trap restoration. The separate restore command remains required. If Docker or IPMI is unavailable, use the supported iDRAC/console recovery procedure for your server and verify cooling there.

For an incident, capture evidence after recovery:

```bash
docker logs --tail 200 idrac-fan-control > incident-container.log 2>&1
docker compose run --rm --no-deps idrac-fan-control config > incident-config.txt
docker compose run --rm --no-deps idrac-fan-control diagnose > incident-diagnose.txt 2>&1
```

Review these files before sharing. Never upload `.env`, private keys, service tags, or management credentials.

## Configuration changes and optional sources

`make tui` saves each submenu directly to `.env` and does not start the service. Stop and restore before changing the deployed configuration; use the root `.env`, review `config`, validate, diagnose, and repeat supervised checks as needed. Recreate the container with `docker compose up -d --force-recreate` after validation. `docker compose restart` does not reload environment changes.

- `idrac`: start with `TEMPERATURE_SOURCES=idrac`; inspect the sensor list and choose filters that cover relevant heat sources.
- `esxi`: configure host, username, password or key, and the full `DRIVE_DEVICE`. Use the identifier commands in [README.md](README.md#finding-the-esxi-drive-identifier).
- `linux_disk`: configure exact device paths and corresponding Compose `devices` mappings. Discover paths on your host; `/dev/nvme1` is an example, not a universal CD6 identifier.
- `gpu`: enable Compose `gpus: all` and install the host driver/toolkit before diagnostics.
- `remote_gpu`: configure hosts and a shared SSH identity. Every host must expose `nvidia-smi` in its noninteractive SSH PATH.

For keys, copy only the selected identity into `./secrets`, restrict it to `600`, and reference `/run/secrets/<filename>` in `.env`. New containers do not persist learned SSH host keys by default; provision a verified `known_hosts` mount and use `SSH_STRICT_HOST_KEY_CHECKING=yes` where required. See [source deployment examples](docs/TEMPERATURE_SOURCES.md).

Interpolation is now default even when an old `.env` omits the switch. It rounds duty upward between four anchors and ignores hysteresis. Set `FAN_SPEED_INTERPOLATION=false` to retain stepwise control with downshift-only hysteresis. See the [curve reference](README.md#temperature-sources-and-control-decisions).

## Upgrade and rollback

`latest` is mutable and follows default-branch builds. Before an upgrade, record the running image reference/digest and code revision, and back up `.env` plus Compose overrides privately:

```bash
umask 077
backup_dir="../idrac-fan-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"
cp .env docker-compose.yml "$backup_dir/"
# Also copy any Compose override files you use.
git rev-parse HEAD > "$backup_dir/code-revision.txt"
docker inspect idrac-fan-control --format '{{.Config.Image}} {{.Image}}' > "$backup_dir/container-image.txt"
docker image inspect "$(docker inspect idrac-fan-control --format '{{.Image}}')" \
  --format '{{json .RepoDigests}}' > "$backup_dir/image-digests.txt"
```

Stop and explicitly restore using the procedure above. Update only a clean checkout; preserve local Compose changes/overrides and do not discard them to force an update. For a branch following upstream:

```bash
git pull --ff-only
```

Review [migration notes](CHANGELOG.md), merge new `.env.example` options into the protected `.env`, and select the intended image in Compose. Prefer `ghcr.io/df-wu/idrac-fan-control@sha256:<recorded-digest>` or a published version tag over `latest`. `3.0.0` becomes available only after the proposed release is published. Do not paste the digest placeholder literally.

```bash
docker compose pull
make validate
docker compose run --rm --no-deps idrac-fan-control diagnose
# Repeat supervised manual/restore checks for behavior changes, then:
docker compose up -d --force-recreate
docker compose ps
```

For rollback, stop and restore again, select the saved known-good image digest (or retained local image), restore the matching code/config/Compose files, validate and diagnose, and only then restart. Restoring old code alone does not change the Compose image. Do not prune the previous image until the new deployment is verified. If the previous version cannot restore or monitor safely, keep Dell automatic control active instead of restarting it.

## Log retention

The controller appends to a single `logs/fan_control.log`; it does not rotate it. Configure host logrotate/retention and monitor space. Stderr appears in Docker logs; apply a host Docker logging policy as needed.

Documentation last reviewed: November 11, 2026.

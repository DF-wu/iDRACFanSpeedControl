# iDRAC Fan Speed Control

[![Docker image](https://img.shields.io/badge/GHCR-idrac--fan--control-blue)](https://github.com/DF-wu/iDRACFanSpeedControl/pkgs/container/idrac-fan-control)
[![Tests](https://img.shields.io/badge/tests-make%20test-green)](#testing)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Dell PowerEdge 伺服器風扇控制工具。它透過 iDRAC/IPMI raw command 設定風扇轉速，並可依 ESXi NVMe SMART、iDRAC temperature sensors、NVIDIA GPU 溫度自動調整。

> Safety first: 這個專案會覆寫 Dell 原廠風扇控制。設定錯誤可能讓硬體過熱。第一次使用請在旁監看溫度、保留 iDRAC Web UI 存取權，並確認 `restore` 指令可用。

![iDRAC 8 IPMI over LAN setting](images/image.png)

## What It Does

- `auto`: 持續讀取溫度，依 fan curve 設定風扇。
- `once`: 執行一次溫度讀取與風扇調整後離開。
- `manual`: 手動設定 1-100% 風扇 duty cycle。
- `restore`: 將 iDRAC 還原為 Dell 自動風扇控制。
- `status`: 印出 iDRAC chassis status 與 temperature sensors。
- `validate`: 檢查本機設定是否足以啟動目前模式。

## Improvements In This Version

- 溫度來源可選 `esxi`、`idrac`、`gpu`，也可混用。
- 溫度讀取失敗時套用 `FAILSAFE_FAN_SPEED`，不再掉到最低風扇轉速。
- 支援 hysteresis，避免溫度卡在閾值附近時風扇反覆跳速。
- 支援 ESXi SSH password 或 key authentication。
- IPMI 密碼改用 `IPMI_PASSWORD` environment 傳給 `ipmitool -E`，避免出現在 command line。
- 舊手動腳本已改成 wrapper，共用同一份核心邏輯。
- 新增 `make test`、Docker healthcheck、`.dockerignore`、`.gitignore`、MIT `LICENSE`。

## Requirements

| Requirement | Why |
| --- | --- |
| Dell PowerEdge with iDRAC | 送出 IPMI fan raw commands |
| iDRAC IPMI over LAN enabled | `ipmitool -I lanplus` 需要 LAN access |
| Docker / Docker Compose | 建議部署方式 |
| ESXi SSH access | 只有 `TEMPERATURE_SOURCES` 包含 `esxi` 時需要 |
| NVIDIA Container Toolkit | 只有 `gpu` 溫度來源需要 |

Tested target: Dell PowerEdge R730xd/R730XD class servers with iDRAC 8. Other Dell models may support the same OEM raw commands, but you should test with `manual` and `restore` before running unattended.

## Quick Start

1. Clone the repository.

```bash
git clone https://github.com/DF-wu/iDRACFanSpeedControl.git
cd iDRACFanSpeedControl
```

2. Create a private environment file.

```bash
cp .env.example .env
chmod 600 .env
```

3. Edit `.env`.

Minimum iDRAC-only auto mode:

```env
IDRAC_IP=192.0.2.10
IDRAC_ID=root
IDRAC_PASSWORD=change-me
OPERATION_MODE=auto
TEMPERATURE_SOURCES=idrac
```

ESXi NVMe SMART mode:

```env
TEMPERATURE_SOURCES=esxi
ESXI_HOST=192.0.2.20
ESXI_USERNAME=root
ESXI_PASSWORD=change-me
DRIVE_DEVICE=t10.NVMe____replace_with_your_device_identifier
```

4. Validate and start.

```bash
docker compose run --rm idrac-fan-control validate
docker compose up -d
docker logs -f idrac-fan-control
```

5. Restore Dell automatic control when needed.

```bash
docker compose run --rm idrac-fan-control restore
```

## Commands

Docker Compose passes extra arguments to the container entrypoint:

```bash
# Run continuously according to OPERATION_MODE=auto
docker compose up -d

# Run one automatic cycle
docker compose run --rm idrac-fan-control once

# Set manual fan speed to 35%
docker compose run --rm idrac-fan-control manual 35

# Restore Dell automatic fan control
docker compose run --rm idrac-fan-control restore

# Print chassis and temperature sensor status
docker compose run --rm idrac-fan-control status

# Validate config without touching fan speed
docker compose run --rm idrac-fan-control validate
```

Local script usage is the same:

```bash
src/FanControlWithEsxiSmart.sh manual 35
src/FanControlWithEsxiSmart.sh restore
```

## Temperature Sources

`TEMPERATURE_SOURCES` accepts comma-separated values.

| Source | Reads | Requires |
| --- | --- | --- |
| `esxi` | One NVMe drive's SMART temperature through `esxcli` | ESXi SSH, `DRIVE_DEVICE` |
| `idrac` | iDRAC temperature sensors from `ipmitool sdr type Temperature` | iDRAC credentials |
| `gpu` | NVIDIA GPU temperature from `nvidia-smi` | NVIDIA Container Toolkit |

Hybrid mode uses the highest decision temperature:

```text
decision_temperature = max(esxi_temp, idrac_sensor_temps..., gpu_temp - GPU_TEMP_OFFSET)
```

Examples:

```env
# No ESXi dependency. Use iDRAC sensors only.
TEMPERATURE_SOURCES=idrac

# NVMe SMART plus iDRAC ambient/CPU sensors.
TEMPERATURE_SOURCES=esxi,idrac

# NVMe SMART plus GPU compensation.
TEMPERATURE_SOURCES=esxi,gpu
GPU_TEMP_OFFSET=15

# Backward-compatible switch. This appends gpu to TEMPERATURE_SOURCES.
WITH_GPU_TEMP=true
```

## Fan Curve

The controller maps the decision temperature to a fan level.

| Level | Temperature range | Default speed |
| --- | --- | --- |
| `idle` | `< TEMP_LOW` | `FAN_SPEED_IDLE=25` |
| `low` | `TEMP_LOW` to `< TEMP_MEDIUM` | `FAN_SPEED_LOW=30` |
| `medium` | `TEMP_MEDIUM` to `< TEMP_HIGH` | `FAN_SPEED_MEDIUM=40` |
| `high` | `TEMP_HIGH` to `< TEMP_CRITICAL` | `FAN_SPEED_HIGH=50` |
| `critical` | `>= TEMP_CRITICAL` | `FAN_SPEED_CRITICAL=60` |
| `failsafe` | all temperature sources failed | `FAILSAFE_FAN_SPEED=70` |

Default thresholds:

```env
TEMP_LOW=65
TEMP_MEDIUM=70
TEMP_HIGH=75
TEMP_CRITICAL=80
HYSTERESIS=2
```

Hysteresis only delays downshifts. For example, if the current level is `high` and `TEMP_HIGH=75`, the controller keeps `high` until the temperature falls to `73C` or lower when `HYSTERESIS=2`.

## Configuration Reference

| Variable | Default | Notes |
| --- | --- | --- |
| `IDRAC_IP` | empty | Required for all fan commands |
| `IDRAC_ID` | `root` | iDRAC username |
| `IDRAC_PASSWORD` | empty | iDRAC password |
| `IPMI_INTERFACE` | `lanplus` | Usually keep this value |
| `IPMI_TIMEOUT` | `5` | Seconds per IPMI attempt |
| `IPMI_RETRIES` | `2` | IPMI retry count |
| `OPERATION_MODE` | `manual` | `auto`, `once`, or `manual` |
| `TEMPERATURE_SOURCES` | `esxi` | Comma-separated: `esxi,idrac,gpu` |
| `WITH_GPU_TEMP` | `false` | Backward-compatible GPU switch |
| `GPU_TEMP_OFFSET` | `15` | Subtracted from GPU temperature |
| `CHECK_INTERVAL` | `60` | Seconds between auto cycles |
| `COMMAND_TIMEOUT` | `20` | Wrapper timeout for SSH, IPMI, and GPU reads |
| `ESXI_HOST` | empty | Required when source includes `esxi` |
| `ESXI_USERNAME` | `root` | ESXi SSH username |
| `ESXI_PASSWORD` | empty | Use password auth when `ESXI_SSH_KEY` is empty |
| `ESXI_SSH_KEY` | empty | Optional SSH private key path |
| `ESXI_SSH_PORT` | `22` | ESXi SSH port |
| `SSH_CONNECT_TIMEOUT` | `10` | SSH connection timeout |
| `DRIVE_DEVICE` | empty | ESXi NVMe device identifier |
| `TEMP_LOW` | `65` | Idle to low threshold |
| `TEMP_MEDIUM` | `70` | Low to medium threshold |
| `TEMP_HIGH` | `75` | Medium to high threshold |
| `TEMP_CRITICAL` | `80` | High to critical threshold |
| `FAN_SPEED_IDLE` | `25` | Fan speed below `TEMP_LOW` |
| `FAN_SPEED_LOW` | `30` | Fan speed at low level |
| `FAN_SPEED_MEDIUM` | `40` | Fan speed at medium level |
| `FAN_SPEED_HIGH` | `50` | Fan speed at high level |
| `FAN_SPEED_CRITICAL` | `60` | Fan speed at critical level |
| `HYSTERESIS` | `2` | Degrees C before downshift |
| `FAILSAFE_ON_ERROR` | `true` | Apply fail-safe when all sources fail |
| `FAILSAFE_FAN_SPEED` | `70` | Conservative speed for sensor failure |
| `RESTORE_AUTO_ON_EXIT` | `true` | Restore Dell auto control when auto mode exits |
| `MANUAL_FAN_SPEED` | empty | Used by `manual` mode without an argument |
| `LOG_DIR` | `/var/log/fan-control` | Set empty only for tests |
| `LOG_FILE` | `fan_control.log` | Status log file name |
| `DRY_RUN` | `false` | Log commands without running `ipmitool` |

## Getting The ESXi Drive Identifier

SSH to the ESXi host and list storage devices:

```bash
ssh root@192.0.2.20
esxcli storage core device list
```

Find the NVMe device ID and test SMART temperature output:

```bash
esxcli storage core device smart get -d t10.NVMe____replace_with_your_device_identifier
```

Use that full ID as `DRIVE_DEVICE`.

## GPU Mode

Install NVIDIA Container Toolkit on the Docker host, then enable GPU access in `docker-compose.yml`:

```yaml
gpus: all
```

Set one of these in `.env`:

```env
TEMPERATURE_SOURCES=esxi,gpu
# or
WITH_GPU_TEMP=true
```

Verify GPU access:

```bash
docker run --rm --gpus all nvidia/cuda:12.9.0-runtime-ubuntu24.04 nvidia-smi
docker compose run --rm idrac-fan-control status
```

## Logs

Container logs show control decisions:

```bash
docker logs -f idrac-fan-control
```

Persistent fan-control logs are written to `./logs/fan_control.log` by the Compose volume:

```bash
tail -f logs/fan_control.log
```

Each line includes `status`, `temp`, `level`, `fan`, and source details.

## Testing

Run local tests:

```bash
make test
```

The tests cover:

- Bash syntax checks.
- Temperature source normalization.
- iDRAC sensor parsing.
- GPU offset decision logic.
- Fan curve and hysteresis behavior.
- Fail-safe behavior when every source fails.
- Validation for iDRAC-only auto mode.

Run a dry validation target:

```bash
make validate
```

Build a local image:

```bash
make docker-build
```

If you do not need GPU support, build with a smaller Ubuntu base:

```bash
docker build --build-arg BASE_IMAGE=ubuntu:24.04 -t idrac-fan-control:local .
```

## Troubleshooting

### `validate` says iDRAC config is missing

Set `IDRAC_IP`, `IDRAC_ID`, and `IDRAC_PASSWORD` in `.env`. Also confirm IPMI over LAN is enabled in iDRAC.

```bash
ipmitool -I lanplus -H "$IDRAC_IP" -U "$IDRAC_ID" -P "$IDRAC_PASSWORD" chassis status
```

### Auto mode fails because ESXi is missing

If you do not want ESXi SSH, use iDRAC sensors:

```env
TEMPERATURE_SOURCES=idrac
```

If you want ESXi SMART temperature, set `ESXI_HOST`, `ESXI_USERNAME`, `ESXI_PASSWORD` or `ESXI_SSH_KEY`, and `DRIVE_DEVICE`.

### Temperature reads fail and fans jump to fail-safe

That is intentional. The controller uses `FAILSAFE_FAN_SPEED` when no temperature source succeeds. Check the source-specific logs, then test each dependency:

```bash
docker compose run --rm idrac-fan-control status
ssh root@your-esxi-host
nvidia-smi
```

### Manual mode works, but auto mode is too noisy

Raise the fan curve or add hysteresis:

```env
TEMP_LOW=70
TEMP_MEDIUM=75
TEMP_HIGH=80
TEMP_CRITICAL=85
HYSTERESIS=3
```

### Restore automatic control

Run:

```bash
docker compose run --rm idrac-fan-control restore
```

This sends:

```text
raw 0x30 0x30 0x01 0x01
```

## Security Notes

- Keep `.env` private. This repository now ignores `.env`; if your clone still tracks it, run `git rm --cached .env`.
- Prefer a dedicated iDRAC account if your iDRAC version supports suitable privileges.
- Keep iDRAC and ESXi on a management network, not a public network.
- Prefer `ESXI_SSH_KEY` over password auth when possible.
- Review logs after every fan curve change.

## Repository Layout

```text
.
├── src/
│   ├── FanControlWithEsxiSmart.sh   # main entrypoint
│   └── setIdracFanSpeed.sh          # backward-compatible manual wrapper
├── tests/
│   └── fan-control.test.sh          # shell tests with mocked behavior
├── images/
│   └── image.png                    # iDRAC IPMI over LAN screenshot
├── .env.example                     # documented configuration template
├── docker-compose.yml
├── Dockerfile
├── Makefile
└── README.md
```

## Roadmap

- Add structured metrics output for Prometheus or node exporters.
- Add optional fan ramping for smoother transitions.
- Add log rotation examples for long-running hosts.
- Add model-specific notes for more Dell PowerEdge generations.

## License

MIT. See [LICENSE](LICENSE).

Last reviewed: 2026-06-08.

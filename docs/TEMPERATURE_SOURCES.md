# Temperature source interface

The controller treats every temperature provider through the same interface. `collect_temperature_readings` and `diagnose_mode` never branch on a source ID; they call the registered source methods instead.

## Interface contract

Register a source ID in `TEMPERATURE_SOURCE_IDS`, then implement these Bash functions in `src/FanControlWithEsxiSmart.sh`:

```bash
temperature_source_<id>_validate() { ...; }
temperature_source_<id>_collect() { ...; }
temperature_source_<id>_adjust() { ...; }
```

- `validate` checks required configuration and runtime commands. It returns nonzero on an invalid setup.
- `collect` prints one or more tab-separated records and returns zero when at least one reading is valid.
- `adjust` receives one integer Celsius value and prints the integer used by the fan curve.

Each collection record has this format:

```text
source_id<TAB>sensor_label<TAB>raw_temperature_celsius
```

Labels must not contain tabs or newlines. A source must reject missing, malformed, or unsupported readings instead of emitting `0`. The controller applies every source's `adjust` method, logs both raw and adjusted values when they differ, and selects the highest adjusted temperature.

`temperature_source_interface_complete` checks the contract during validation. The supported source list is an allowlist, so an environment value cannot invoke an arbitrary shell function.

## Built-in sources

| ID | Provider | Adjustment |
| --- | --- | --- |
| `idrac` | All readable `ipmitool sdr type Temperature` sensors | None |
| `esxi` | One ESXi storage device queried through SSH and `esxcli` | None |
| `gpu` | All local NVIDIA GPUs queried with `nvidia-smi` | `GPU_TEMP_OFFSET` |
| `linux_disk` | One or more local Linux devices queried with `smartctl -A -j` | `LINUX_DISK_TEMP_OFFSET` |
| `remote_gpu` | All NVIDIA GPUs on one or more Linux hosts queried through SSH | `REMOTE_GPU_TEMP_OFFSET` |

## Linux disk behavior

Set `LINUX_DISK_DEVICES` to comma-separated `/dev` paths. For NVMe, prefer the controller node such as `/dev/nvme1`; namespace paths such as `/dev/nvme1n1` also work when smartctl supports them.

The parser first reads smartctl's generic `temperature.current`, then checks the NVMe health log and ATA temperature attributes. It accepts a valid temperature even when smartctl's exit status reports disk health bits. A timeout, invalid JSON, inaccessible device, or absent temperature fails that device only. Set `LINUX_DISK_NOCHECK=standby` to avoid waking sleeping SATA/SAS disks; keep the default `never` for always-on devices such as the CD6.

The source requires `smartctl`, `jq`, and `timeout`. The container image includes them. Containers also need an explicit device mapping for every configured disk:

```yaml
services:
  idrac-fan-control:
    devices:
      - /dev/nvme1:/dev/nvme1
```

Grant access only to selected devices. Raw disk access is sensitive even though this controller invokes only the read-only `smartctl -A -j` query.

## TrueNAS CD6 plus remote GPU VMs

The following configuration combines a TrueNAS-hosted Kioxia CD6 with GPUs in two Linux VMs:

```dotenv
TEMPERATURE_SOURCES=linux_disk,remote_gpu

LINUX_DISK_DEVICES=/dev/nvme1
LINUX_DISK_TEMP_OFFSET=0
LINUX_DISK_NOCHECK=never

REMOTE_GPU_HOSTS=gpu-vm-1,gpu-vm-2
REMOTE_GPU_USERNAME=monitor
REMOTE_GPU_PASSWORD=
REMOTE_GPU_SSH_KEY=/run/secrets/gpu_vms_ed25519
REMOTE_GPU_SSH_PORT=22
REMOTE_GPU_TEMP_OFFSET=15
```

Each remote host must have `nvidia-smi` in its non-interactive SSH `PATH`. Use a restricted monitoring account and SSH key where practical. The controller runs only this remote command:

```bash
nvidia-smi --query-gpu=index,temperature.gpu --format=csv,noheader,nounits
```

Run `validate`, then `diagnose`. A healthy result includes one `source:linux_disk` row, one combined `source:remote_gpu` row, and a decision preview. A multi-device source passes when at least one configured target returns a reading and logs a warning for each failed target. `diagnose` returns nonzero when an enabled source returns no readings. Automatic control continues with remaining valid sources; if every source fails, the configured fail-safe applies.

## Upstream references

- [smartctl manual](https://github.com/smartmontools/smartmontools/blob/main/src/smartctl.8.in): Linux device forms, JSON output, and exit-status bitmask.
- [Docker Compose service `devices`](https://docs.docker.com/reference/compose-file/services/#devices): host-to-container device mapping syntax.
- [NVIDIA System Management Interface](https://docs.nvidia.com/deploy/nvidia-smi/index.html): selective GPU queries, CSV formatting, and Celsius temperature fields.
- [TrueNAS 25.10 disk API](https://api.truenas.com/v25.10/api_methods_disk.html): platform disk inventory and temperature methods used for deployment cross-checks.

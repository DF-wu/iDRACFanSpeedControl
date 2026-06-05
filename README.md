# 🌡️ iDRAC Fan Speed Control

[![Docker](https://img.shields.io/badge/Docker-Supported-blue?logo=docker)](https://hub.docker.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Tested](https://img.shields.io/badge/Tested-Dell%20R730XD-success)](https://www.dell.com/)

**Intelligent fan speed control for Dell PowerEdge servers** with smart temperature monitoring and GPU support. Control your server fans through IPMI commands over LAN, tested on R730XD servers with iDRAC 8.

## ✨ Features

- 🧠 **Smart Temperature Monitoring**: Automatically adjusts fan speed based on NVMe disk temperatures
- 🎮 **GPU Temperature Support**: Optional GPU temperature monitoring with NVIDIA Container Toolkit
- ⚙️ **Environment Variable Control**: Complete configuration through `.env` files
- 🐳 **Docker Deployment**: One-click deployment with no manual environment setup
- 🔥 **Decision Temperature Algorithm**: `max(disk_temp, gpu_temp - GPU_TEMP_OFFSET)` ensures optimal cooling
- 📊 **Configurable Thresholds**: Customize temperature and fan speed settings
- 🔄 **Auto/Manual Modes**: Flexible operation modes for different use cases

## ⚠️ Known Limitations

### ESXi Dependency for Temperature

This project currently **requires an ESXi host with SSH enabled** to read NVMe disk temperatures. The temperature is retrieved by SSH'ing into ESXi and running `esxcli storage core device smart get` for a single NVMe drive. This means:

- **No CPU or ambient temperature is monitored** — only one NVMe disk's SMART temperature is used. Server CPU, inlet, and exhaust sensors accessible via iDRAC IPMI are not utilized.
- **If ESXi is unreachable**, the script silently falls back to `0°C`, causing fan speed to drop to `FAN_SPEED_LOW` (30%). This is **not fail-safe** — if the ESXi host becomes unresponsive while the server is under load, fans will run at minimum speed.
- **Password-based SSH only** (`sshpass`). SSH key authentication is not supported.
- **New SSH connection per check cycle** — each `CHECK_INTERVAL` (default 60s) opens a fresh connection, adding latency and auth log noise.

**Planned improvements**: Decouple temperature from ESXi by supporting direct IPMI sensor reading, local SMART via `smartctl`/`nvme`, and adding a fail-safe fallback speed when temperature readings fail. See [TODO](#todo) below.

## 🚀 Quick Start

### Step 1: Setup Environment

Clone the repository and copy the example configuration:

```bash
git clone <repository-url>
cd iDRACFanSpeedControl
cp .env.example .env
```

Edit the `.env` file with your iDRAC and ESXi connection details:

```bash
# iDRAC Configuration
IDRAC_IP=192.168.1.100
IDRAC_ID=root  
IDRAC_PASSWORD=calvin

# ESXi Configuration (for disk temperature)
ESXI_HOST=192.168.1.10
ESXI_USERNAME=root
ESXI_PASSWORD=your_esxi_password

# Drive Identifier
DRIVE_DEVICE=t10.NVMe____KCD61LUL7T68____________________________015E8306E28EE38C

# GPU Temperature Monitoring (Optional)
WITH_GPU_TEMP=false  # Set to true to enable GPU temperature monitoring
```

### Step 2: Deploy the Service

Deploy using Docker Compose:

```bash
docker-compose up -d
```

### Step 3: Enable GPU Temperature Monitoring (Optional)

To enable GPU temperature monitoring:

1. Set `WITH_GPU_TEMP=true` in your `.env` file
2. Uncomment the GPU configuration in `docker-compose.yml`:

```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: all
          capabilities: [gpu]
```

## ⚙️ Configuration

### Temperature Thresholds

```bash
TEMP_LOW=65        # Low temperature threshold (°C)
TEMP_MEDIUM=70     # Medium temperature threshold (°C)  
TEMP_HIGH=75       # High temperature threshold (°C)
TEMP_CRITICAL=80   # Critical temperature threshold (°C)
```

### Fan Speed Settings

```bash
FAN_SPEED_LOW=30      # Fan speed for low temperature (%)
FAN_SPEED_MEDIUM=40   # Fan speed for medium temperature (%)
FAN_SPEED_HIGH=50     # Fan speed for high temperature (%)
FAN_SPEED_CRITICAL=60 # Fan speed for critical temperature (%)
```

### Operation Modes

```bash
OPERATION_MODE=auto   # auto: Automatic mode | manual: Manual mode
CHECK_INTERVAL=60     # Check interval in seconds (auto mode only)
```

## 🧮 Decision Temperature Algorithm

When GPU temperature monitoring is enabled, the system uses this algorithm to calculate the decision temperature:

```text
Decision Temperature = max(Disk Temperature, GPU Temperature - GPU_TEMP_OFFSET)
```

This algorithm ensures:

- **Proactive GPU cooling**: High GPU temperatures trigger increased fan speeds
- **Configurable offset compensation**: Adjustable offset (`GPU_TEMP_OFFSET`) accounts for thermal differences between GPU and system
- **Disk temperature baseline**: Disk temperature always serves as the minimum baseline

### Algorithm Examples

With default `GPU_TEMP_OFFSET=15°C`:

| Disk Temp | GPU Temp | GPU-15 | Decision Temp | Reasoning |
|-----------|----------|--------|---------------|-----------|
| 65°C | 70°C | 55°C | **65°C** | Disk temperature is higher |
| 65°C | 85°C | 70°C | **70°C** | GPU-15 is higher, use adjusted GPU temp |
| 75°C | 80°C | 65°C | **75°C** | Disk temperature remains baseline |

## 🔧 Troubleshooting

### Common Issues

#### GPU Temperature Reading Fails

```bash
# Check if NVIDIA GPU is available
nvidia-smi

# Verify Docker GPU support
docker run --rm --gpus all nvidia/cuda:12.9.0-runtime-ubuntu24.04 nvidia-smi
```

#### Cannot Connect to ESXi Host

```bash
# Test SSH connection
ssh root@your_esxi_host

# Note: ESXi SSH service must be enabled
```

#### iDRAC Connection Failed

```bash
# Test iDRAC connection
ipmitool -I lanplus -H your_idrac_ip -U root -P calvin chassis status
```

### Monitoring and Logs

```bash
# View container logs
docker logs idrac-fan-control

# View fan control records
docker exec idrac-fan-control tail -f /var/log/fan-control/fan_control.log
```

## 📋 Environment Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `IDRAC_IP` | - | iDRAC IP address |
| `IDRAC_ID` | root | iDRAC username |
| `IDRAC_PASSWORD` | - | iDRAC password |
| `ESXI_HOST` | - | ESXi host IP |
| `ESXI_USERNAME` | root | ESXi username |
| `ESXI_PASSWORD` | - | ESXi password |
| `DRIVE_DEVICE` | - | Disk identifier to monitor |
| `TEMP_LOW` | 65 | Low temperature threshold (°C) |
| `TEMP_MEDIUM` | 70 | Medium temperature threshold (°C) |
| `TEMP_HIGH` | 75 | High temperature threshold (°C) |
| `TEMP_CRITICAL` | 80 | Critical temperature threshold (°C) |
| `FAN_SPEED_LOW` | 30 | Low temperature fan speed (%) |
| `FAN_SPEED_MEDIUM` | 40 | Medium temperature fan speed (%) |
| `FAN_SPEED_HIGH` | 50 | High temperature fan speed (%) |
| `FAN_SPEED_CRITICAL` | 60 | Critical temperature fan speed (%) |
| `OPERATION_MODE` | auto | Operation mode (auto/manual) |
| `CHECK_INTERVAL` | 60 | Check interval in seconds |
| `WITH_GPU_TEMP` | false | Enable GPU temperature monitoring |
| `GPU_TEMP_OFFSET` | 15 | GPU temperature offset for decision algorithm (°C) |

## 🐳 Docker Compose Examples

### Basic Configuration (Disk Temperature Only)

```yaml
version: '3.8'
services:
  idrac-fan-control:
    container_name: idrac-fan-control
    image: ghcr.io/df-wu/idrac-fan-control:latest
    env_file:
      - .env
    volumes:
      - ./logs:/var/log/fan-control
    network_mode: host
    restart: always
```

### GPU-Enabled Configuration

```yaml
version: '3.8'
services:
  idrac-fan-control:
    container_name: idrac-fan-control
    image: ghcr.io/df-wu/idrac-fan-control:latest
    env_file:
      - .env
    volumes:
      - ./logs:/var/log/fan-control
    network_mode: host
    restart: always
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

## 🔍 Performance Tuning

### Adjusting Check Intervals

```bash
# Reduce system load (slower response)
CHECK_INTERVAL=120  # Check every 2 minutes

# Increase responsiveness (higher system load)
CHECK_INTERVAL=30   # Check every 30 seconds
```

### Custom Temperature Profiles

```bash
# Conservative Profile (fans start early, quieter operation)
TEMP_LOW=60
TEMP_MEDIUM=65
TEMP_HIGH=70
TEMP_CRITICAL=75

# Aggressive Profile (fans start later, potentially noisier but more efficient)
TEMP_LOW=70
TEMP_MEDIUM=75
TEMP_HIGH=80
TEMP_CRITICAL=85
```

## 💻 Supported Hardware

- ✅ **Tested**: Dell PowerEdge R730XD (iDRAC 8)
- 🔄 **Compatible**: All Dell PowerEdge servers with IPMI 2.0 support
- 🎮 **GPU Support**: NVIDIA GPUs (requires NVIDIA Container Toolkit)

## 📋 TODO / Roadmap

### High Priority

- [ ] **Decouple temperature from ESXi** — Add support for direct iDRAC IPMI sensor reading (`ipmitool sdr`) as primary or fallback temperature source. This would read CPU, inlet, and exhaust temperatures without needing ESXi SSH.
- [ ] **Fail-safe fallback behavior** — When temperature reading fails (SSH timeout, ESXi unreachable), default to a configurable `TEMP_FAILSAFE_SPEED` (e.g., 60%) instead of silently dropping to `FAN_SPEED_LOW`.
- [ ] **Add CPU temperature monitoring** — Read CPU/ambient/exhaust sensors via IPMI and include them in the decision temperature calculation.

### Medium Priority

- [ ] **SSH key authentication** — Support `ESXI_SSH_KEY` alongside password-based auth. Remove `sshpass` dependency when using keys.
- [ ] **Connection retry + health check** — Validate ESXi connectivity at startup. Add retry with backoff on SSH failures.
- [ ] **SSH connection reuse** — Use SSH `ControlMaster` to avoid opening a new connection every cycle.
- [ ] **Temperature hysteresis** — Add configurable deadband (e.g., 3°C) to prevent fan speed oscillation at threshold boundaries.
- [ ] **Fix log persistence** — Align Docker volume mount with script log path so logs survive container restarts.

### Low Priority / Nice to Have

- [ ] **Prometheus metrics endpoint** — Expose temperature and fan speed metrics for monitoring dashboards.
- [ ] **Health endpoint / webhook alerting** — Notify on temperature threshold breaches or connection failures.
- [ ] **Gradual fan ramping** — Smooth fan speed transitions instead of abrupt steps.
- [ ] **Clean up dead code** — Remove `src/.env` and `src/setIdracFanSpeed.sh`, or consolidate with main config.
- [ ] **Fix `imgaes/` directory typo** → `images/`.
- [ ] **Version tagging** — Add semver tags to Docker images instead of only `:latest`.
- [ ] **Tests** — Add basic smoke tests for temperature logic and IPMI command formatting.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request or open an Issue for bugs and feature requests.

---

## 🇹🇼 中文說明

這是一個 Dell PowerEdge 伺服器的智慧風扇控制工具，主要功能包括：

- **智慧溫度監控**：根據磁碟和 GPU 溫度自動調節風扇轉速
- **Docker 部署**：使用 Docker Compose 一鍵部署
- **環境變數控制**：所有設定都可以透過 .env 文件控制
- **決策溫度算法**：`max(磁碟溫度, GPU溫度-GPU_TEMP_OFFSET)`（預設偏移 15°C，可自訂）確保最佳散熱效果

### 快速使用

1. 複製 `.env.example` 為 `.env` 並修改設定
2. 執行 `docker-compose up -d` 啟動服務
3. 如需 GPU 支援，請設定 `WITH_GPU_TEMP=true` 並開啟 Docker Compose 中的 GPU 配置

已在 Dell R730XD (iDRAC 8) 上測試通過。

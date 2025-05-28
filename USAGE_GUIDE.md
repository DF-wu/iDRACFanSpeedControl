# 📖 iDRAC Fan Control Usage Guide

A comprehensive guide for deploying and using the iDRAC Fan Speed Control system with Docker.

## 🎯 Overview

This guide covers everything you need to know about deploying, configuring, and troubleshooting the iDRAC Fan Speed Control system. The system intelligently manages Dell PowerEdge server fan speeds based on disk and optional GPU temperatures.

## 📋 Prerequisites

### System Requirements

- **Docker** and **Docker Compose** installed
- Network access to both **iDRAC** and **ESXi** hosts
- **NVIDIA Container Toolkit** (optional, for GPU temperature monitoring)

### Required Information

Before deployment, gather the following information:

1. **iDRAC Details**:
   - IP address
   - Username (typically `root`)
   - Password

2. **ESXi Host Details**:
   - IP address or hostname
   - Username (typically `root`)
   - Password

3. **Drive Identifier**:
   - NVMe drive identifier from ESXi

## 🔍 Getting Drive Identifier

The drive identifier is crucial for temperature monitoring. Here's how to obtain it:

### Method 1: SSH to ESXi Host

```bash
# SSH to your ESXi host
ssh root@your_esxi_host

# List all storage devices
esxcli storage core device list

# Look for your NVMe drive and copy the Device UID
# Example output:
# t10.NVMe____KCD61LUL7T68____________________________015E8306E28EE38C
```

### Method 2: vSphere Client

1. Log into vSphere Client
2. Navigate to **Host** → **Configure** → **Storage Devices**
3. Find your NVMe drive and note the identifier

## 🚀 Deployment Guide

### Step 1: Download Project Files

```bash
# Clone the repository
git clone <repository-url>
cd iDRACFanSpeedControl

# Or download specific files
wget https://raw.githubusercontent.com/username/repo/main/docker-compose.yml
wget https://raw.githubusercontent.com/username/repo/main/.env.example
```

### Step 2: Configure Environment

```bash
# Copy example configuration
cp .env.example .env

# Edit the configuration file
nano .env
```

### Step 3: Basic Configuration

Edit your `.env` file with the following minimum required settings:

```bash
# ===== Required Settings =====
IDRAC_IP=192.168.1.100
IDRAC_ID=root
IDRAC_PASSWORD=your_idrac_password

ESXI_HOST=192.168.1.10
ESXI_USERNAME=root
ESXI_PASSWORD=your_esxi_password

DRIVE_DEVICE=your_drive_identifier_here

# ===== Optional Settings =====
WITH_GPU_TEMP=false
OPERATION_MODE=auto
CHECK_INTERVAL=60
```

### Step 4: Deploy the Service

#### Basic Deployment (Disk Temperature Only)

```bash
# Start the service
docker-compose up -d

# Check if it's running
docker ps
```

#### GPU-Enhanced Deployment

If you want GPU temperature monitoring:

1. **Enable GPU in configuration**:

```bash
# In .env file
WITH_GPU_TEMP=true
```

1. **Update docker-compose.yml**:

Uncomment the GPU configuration section:

```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: all
          capabilities: [gpu]
```

1. **Deploy with GPU support**:

```bash
docker-compose up -d
```

## 📊 Monitoring and Management

### Viewing Logs

```bash
# Real-time log viewing
docker logs -f idrac-fan-control

# View specific number of recent log lines
docker logs --tail 100 idrac-fan-control

# View logs from a specific time
docker logs --since 30m idrac-fan-control
```

### Checking Service Status

```bash
# Check container status
docker ps

# View container resource usage
docker stats idrac-fan-control

# Inspect container configuration
docker inspect idrac-fan-control
```

### Accessing Log Files

If you've mounted the logs directory:

```bash
# View fan control log
tail -f ./logs/fan_control.log

# View recent entries
cat ./logs/fan_control.log | tail -20
```

## ⚙️ Advanced Configuration

### Temperature Profile Customization

#### Conservative Profile (Quieter Operation)

```bash
TEMP_LOW=60
TEMP_MEDIUM=65
TEMP_HIGH=70
TEMP_CRITICAL=75

FAN_SPEED_LOW=25
FAN_SPEED_MEDIUM=35
FAN_SPEED_HIGH=45
FAN_SPEED_CRITICAL=55
```

#### Aggressive Profile (Better Cooling)

```bash
TEMP_LOW=70
TEMP_MEDIUM=75
TEMP_HIGH=80
TEMP_CRITICAL=85

FAN_SPEED_LOW=35
FAN_SPEED_MEDIUM=45
FAN_SPEED_HIGH=60
FAN_SPEED_CRITICAL=75
```

#### Silent Profile (Maximum Quiet)

```bash
TEMP_LOW=65
TEMP_MEDIUM=72
TEMP_HIGH=78
TEMP_CRITICAL=82

FAN_SPEED_LOW=20
FAN_SPEED_MEDIUM=25
FAN_SPEED_HIGH=35
FAN_SPEED_CRITICAL=50
```

### Monitoring Frequency Adjustment

```bash
# High responsiveness (more frequent checks)
CHECK_INTERVAL=30

# Balanced (default)
CHECK_INTERVAL=60

# Low impact (less frequent checks)
CHECK_INTERVAL=120
```

## 🛠️ Troubleshooting

### Common Issues and Solutions

#### Issue: Container Won't Start

**Symptoms**: Container exits immediately or fails to start

**Solutions**:

```bash
# Check container logs
docker logs idrac-fan-control

# Verify environment variables
docker run --rm --env-file .env ghcr.io/df-wu/idrac-fan-control:latest

# Check .env file format
cat .env | grep -v '^#' | grep -v '^$'
```

#### Issue: Cannot Connect to iDRAC

**Symptoms**: `Error: IDRAC connection failed`

**Solutions**:

```bash
# Test IPMI connection manually
ipmitool -I lanplus -H your_idrac_ip -U root -P your_password chassis status

# Check network connectivity
ping your_idrac_ip

# Verify iDRAC credentials
# Check iDRAC web interface access
```

#### Issue: Cannot Connect to ESXi

**Symptoms**: `SSH connection failed` or `Permission denied`

**Solutions**:

```bash
# Test SSH connection manually
ssh root@your_esxi_host

# Enable SSH on ESXi:
# 1. Access ESXi web interface
# 2. Navigate to Manage → Services
# 3. Start SSH service

# Check firewall settings on ESXi
```

#### Issue: GPU Temperature Not Reading

**Symptoms**: GPU temperature shows as 0 or error messages about nvidia-smi

**Solutions**:

```bash
# Verify NVIDIA Container Toolkit installation
docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi

# Check if GPU is accessible in container
docker exec idrac-fan-control nvidia-smi

# Verify GPU configuration in docker-compose.yml
```

#### Issue: Drive Temperature Not Reading

**Symptoms**: Disk temperature shows as 0 or cannot get temperature

**Solutions**:

```bash
# Verify drive identifier
ssh root@your_esxi_host
esxcli storage core device list

# Test temperature reading manually
esxcli storage core device smart get -d your_drive_device

# Check if drive supports SMART monitoring
```

### Debug Mode

Enable verbose logging for troubleshooting:

```bash
# Run container in interactive mode for debugging
docker run --rm -it --env-file .env \
  -e OPERATION_MODE=manual \
  ghcr.io/df-wu/idrac-fan-control:latest
```

### Performance Monitoring

Monitor system performance impact:

```bash
# Check system resource usage
docker stats

# Monitor network connections
netstat -an | grep :623  # IPMI port

# Check disk I/O
iostat -x 1
```

## 🔧 Maintenance

### Regular Tasks

#### Update Container Image

```bash
# Pull latest image
docker-compose pull

# Restart with new image
docker-compose up -d
```

#### Backup Configuration

```bash
# Backup configuration files
cp .env .env.backup.$(date +%Y%m%d)
cp docker-compose.yml docker-compose.yml.backup.$(date +%Y%m%d)
```

#### Log Rotation

```bash
# Rotate logs if they become too large
docker-compose exec idrac-fan-control logrotate /etc/logrotate.conf
```

### Health Checks

The container includes built-in health checks. Monitor health status:

```bash
# Check health status
docker inspect idrac-fan-control | grep Health -A 10

# View health check logs
docker logs idrac-fan-control 2>&1 | grep health
```

## 🔒 Security Considerations

### Network Security

- **Firewall Rules**: Limit container network access to only required ports
- **VPN Access**: Consider using VPN for remote iDRAC access
- **Network Segmentation**: Isolate management network from production

### Credential Security

- **Dedicated Accounts**: Create dedicated monitoring accounts with minimal privileges
- **Password Rotation**: Regularly rotate iDRAC and ESXi passwords
- **File Permissions**: Secure `.env` file permissions

```bash
# Secure .env file
chmod 600 .env
```

### Container Security

- **Regular Updates**: Keep container images updated
- **Non-root User**: Container runs as non-root user by default
- **Read-only Filesystem**: Mount configuration as read-only where possible

## 📈 Performance Optimization

### Resource Limits

Add resource limits to prevent excessive resource usage:

```yaml
# In docker-compose.yml
services:
  idrac-fan-control:
    # ... other configuration ...
    deploy:
      resources:
        limits:
          memory: 128M
          cpus: '0.5'
        reservations:
          memory: 64M
          cpus: '0.1'
```

### Network Optimization

- **Use Host Network**: `network_mode: host` for better IPMI performance
- **Connection Pooling**: Service maintains persistent connections
- **Timeout Configuration**: Adjust IPMI timeouts if needed

## 📞 Support and Community

### Getting Help

1. **Check Documentation**: Review this guide and README.md
2. **Search Issues**: Look for similar issues in the project repository
3. **Create Issue**: Submit detailed bug reports or feature requests
4. **Community Forum**: Participate in community discussions

### Contributing

- **Bug Reports**: Include logs, configuration, and environment details
- **Feature Requests**: Describe use case and expected behavior
- **Pull Requests**: Follow coding standards and include tests

---

## 🇹🇼 中文使用說明

### 快速部署指南

1. **下載配置文件**：複製 `.env.example` 為 `.env` 並填入您的設定
2. **必要設定**：
   - iDRAC IP、帳號、密碼
   - ESXi 主機 IP、帳號、密碼  
   - 磁碟識別碼（透過 ESXi 指令取得）
3. **啟動服務**：執行 `docker-compose up -d`
4. **GPU 支援**：如需 GPU 溫度監控，設定 `WITH_GPU_TEMP=true` 並開啟 Docker Compose 中的 GPU 配置

### 常見問題

- **連線失敗**：檢查網路連線和認證資訊
- **溫度讀取失敗**：確認磁碟識別碼正確且支援 SMART 監控
- **GPU 溫度錯誤**：確認已安裝 NVIDIA Container Toolkit

### 監控和維護

- 使用 `docker logs idrac-fan-control` 查看運行狀態
- 定期備份配置文件
- 根據需求調整溫度閾值和風扇轉速設定

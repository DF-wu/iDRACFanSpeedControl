#!/bin/bash
# Auto fan speed control based on NVMe drive temperature
# Support environment variable configuration


# Add path to common command locations in Alpine
PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:$PATH"

# Default values and environment variable loading
IDRAC_IP=${IDRAC_IP:-"REPLACE_TO_YOUR_IDRAC_IP"}
IDRAC_ID=${IDRAC_ID:-"REPLACE_TO_YOUR_IDRAC_ID"}
IDRAC_PASSWORD=${IDRAC_PASSWORD:-"REPLACE_TO_YOUR_IDRAC_PASSWORD"}
DRIVE_DEVICE=${DRIVE_DEVICE:-"t10.NVMe____KCD61LUL7T68____________________________015E8306E28EE38C"}

# Temperature thresholds (Celsius) - 與 .env 文件中的預設值保持一致
TEMP_LOW=${TEMP_LOW:-65}
TEMP_MEDIUM=${TEMP_MEDIUM:-70}
TEMP_HIGH=${TEMP_HIGH:-75}
TEMP_CRITICAL=${TEMP_CRITICAL:-80}

# Fan speeds for each temperature range (percentage) - 與 .env 文件中的預設值保持一致
FAN_SPEED_LOW=${FAN_SPEED_LOW:-30}
FAN_SPEED_MEDIUM=${FAN_SPEED_MEDIUM:-40}
FAN_SPEED_HIGH=${FAN_SPEED_HIGH:-50}
FAN_SPEED_CRITICAL=${FAN_SPEED_CRITICAL:-60}

# Operation mode: auto or manual
OPERATION_MODE=${OPERATION_MODE:-"manual"}

# Check interval (seconds) for auto mode
CHECK_INTERVAL=${CHECK_INTERVAL:-60}

# GPU temperature control flag - 新增 GPU 溫度控制開關
# 預設為 false，只有當使用者明確設定 WITH_GPU_TEMP=true 時才啟用 GPU 溫度監控
WITH_GPU_TEMP=${WITH_GPU_TEMP:-"false"}

GPU_TEMP_OFFSET=${GPU_TEMP_OFFSET:-15}

# ESXi variables
ESXI_HOST=${ESXI_HOST:-"REPLACE_TO_YOUR_ESXI_HOST"}
ESXI_USERNAME=${ESXI_USERNAME:-"REPLACE_TO_YOUR_ESXI_USERNAME"}
ESXI_PASSWORD=${ESXI_PASSWORD:-"REPLACE_TO_YOUR_ESXI_PASSWORD"}
 
# Function to get current drive temperature from ESXi host
get_drive_temp() {
    local temp=$(sshpass -p "${ESXI_PASSWORD}" ssh -o StrictHostKeyChecking=no "${ESXI_USERNAME}@${ESXI_HOST}" \
        "esxcli storage core device smart get -d ${DRIVE_DEVICE}" | \
        awk '/Drive Temperature/ {print $3}')
    echo "${temp:-0}"
}

# Function to get NVIDIA GPU temperature using nvidia-smi
# 這個函數透過 nvidia container toolkit 獲取 GPU 溫度
# 前提：容器必須使用 --gpus all 或 --runtime=nvidia 執行
get_nvidia_temp() {
    local temp
    # 使用 nvidia-smi 獲取第一個 GPU 的溫度
    # --query-gpu=temperature.gpu 只輸出溫度值
    # --format=csv,noheader,nounits 輸出純數字，不含單位和標題
    temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1)
    
    # 如果獲取失敗或為空，返回 0
    if [[ -z "$temp" ]] || ! [[ "$temp" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "$temp"
    fi
}

# Function to calculate decision temperature
# 決策溫度 = max(磁碟溫度, GPU溫度 - GPU_TEMP_OFFSET)
# 這個邏輯確保風扇轉速基於較高的溫度來源進行調節
get_decision_temp() {
    local disk_temp=$(get_drive_temp)
    local decision_temp=$disk_temp
    
    # 只有在啟用 GPU 溫度監控時才考慮 GPU 溫度
    if [[ "$WITH_GPU_TEMP" == "true" ]]; then
        local gpu_temp=$(get_nvidia_temp)
        local gpu_adjusted_temp=$((gpu_temp - GPU_TEMP_OFFSET))
        
        # 記錄原始溫度用於除錯
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Debug: Disk=${disk_temp}°C, GPU=${gpu_temp}°C, GPU_Adjusted=${gpu_adjusted_temp}°C" >&2
        
        # 取較大值作為決策溫度
        if [[ $gpu_adjusted_temp -gt $disk_temp ]]; then
            decision_temp=$gpu_adjusted_temp
        fi
        
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Decision temperature: ${decision_temp}°C (Disk: ${disk_temp}°C, GPU-${GPU_TEMP_OFFSET}: ${gpu_adjusted_temp}°C)" >&2
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Decision temperature: ${decision_temp}°C (Disk only mode)" >&2
    fi
    
    echo "$decision_temp"
}

# Function to set fan speed
set_fan_speed() {
    local fan_speed=$1
    
    # Convert decimal to hex
    local hex_speed=$(echo "obase=16;$fan_speed" | bc)
    echo "Setting fan speed to ${fan_speed}% (hex: ${hex_speed})"
    
    # Set fan control to manual
    ipmitool -I lanplus -H ${IDRAC_IP} -U ${IDRAC_ID} -P ${IDRAC_PASSWORD} raw 0x30 0x30 0x01 0x00
    
    # Set fan speed
    local raw_command="0x30 0x30 0x02 0xff 0x${hex_speed}"
    ipmitool -I lanplus -H ${IDRAC_IP} -U ${IDRAC_ID} -P ${IDRAC_PASSWORD} raw ${raw_command}
}

# Function to restore automatic fan control
restore_auto_control() {
    echo "Restoring automatic fan control..."
    ipmitool -I lanplus -H ${IDRAC_IP} -U ${IDRAC_ID} -P ${IDRAC_PASSWORD} raw 0x30 0x30 0x01 0x01
}

# Function to validate configuration
validate_config() {
    local error=0
    
    # Check required variables
    if [[ "$IDRAC_IP" == "REPLACE_TO_YOUR_IDRAC_IP" ]]; then
        echo "Error: IDRAC_IP not configured"
        error=1
    fi
    if [[ "$IDRAC_ID" == "REPLACE_TO_YOUR_IDRAC_ID" ]]; then
        echo "Error: IDRAC_ID not configured"
        error=1
    fi
    if [[ "$IDRAC_PASSWORD" == "REPLACE_TO_YOUR_IDRAC_PASSWORD" ]]; then
        echo "Error: IDRAC_PASSWORD not configured"
        error=1
    fi

    

    
    if [ $error -eq 1 ]; then
        exit 1
    fi
}

# Function to run in manual mode
manual_mode() {
    echo "Manual fan speed control mode"
    echo "Please input fan speed (1-100):"
    read -r fanSpeed

    # Validate input
    if ! [[ "$fanSpeed" =~ ^[0-9]+$ ]] || [ "$fanSpeed" -lt 1 ] || [ "$fanSpeed" -gt 100 ]; then
        echo "Invalid input: Fan speed must be a number between 1 and 100"
        exit 1
    fi

    # Set the fan speed to the provided value
    set_fan_speed "$fanSpeed"
}

# Function to run in automatic mode
auto_mode() {
    echo "Automatic fan speed control mode"
    if [[ "$WITH_GPU_TEMP" == "true" ]]; then
        echo "GPU temperature monitoring enabled - using decision temperature logic"
        echo "Decision Temperature = max(Disk Temperature, GPU Temperature - ${GPU_TEMP_OFFSET}°C)"
    else
        echo "GPU temperature monitoring disabled - using disk temperature only"
    fi
    echo "Monitoring interval: ${CHECK_INTERVAL} seconds"
    echo "Press Ctrl+C to exit and restore automatic control"
    
    # Set up trap for clean exit
    trap restore_auto_control EXIT
    
    local last_speed=""
    
    while true; do
        # Get current decision temperature (考慮 GPU 或僅磁碟溫度)
        local temp=$(get_decision_temp)
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Current control temperature: ${temp}°C"
        
        # Determine appropriate fan speed based on temperature
        local target_speed
        if [ "$temp" -ge "$TEMP_CRITICAL" ]; then
            target_speed=$FAN_SPEED_CRITICAL
        elif [ "$temp" -ge "$TEMP_HIGH" ]; then
            target_speed=$FAN_SPEED_HIGH
        elif [ "$temp" -ge "$TEMP_MEDIUM" ]; then
            target_speed=$FAN_SPEED_MEDIUM
        else
            target_speed=$FAN_SPEED_LOW
        fi
        
        # Only change speed if it's different from last setting
        if [ "$target_speed" != "$last_speed" ]; then
            set_fan_speed "$target_speed"
            last_speed="$target_speed"
            echo "Fan speed adjusted to ${target_speed}%"
        fi
        
        # Log the status
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Temp: ${temp}°C, Fan: ${target_speed}%" >> fan_control.log
        
        sleep "$CHECK_INTERVAL"
    done
}

# Main script
echo "iDRAC Fan Control Script"
echo "Operation Mode: ${OPERATION_MODE}"

# Validate configuration
validate_config

# Run in specified mode
case $OPERATION_MODE in
    "manual")
        manual_mode
        ;;
    "auto")
        auto_mode
        ;;
    *)
        echo "Invalid operation mode: ${OPERATION_MODE} (must be 'auto' or 'manual')"
        exit 1
        ;;
esac

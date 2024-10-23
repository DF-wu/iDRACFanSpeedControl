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

# Temperature thresholds (Celsius)   -xx means default value
TEMP_LOW=${TEMP_LOW:-45}
TEMP_MEDIUM=${TEMP_MEDIUM:-55}
TEMP_HIGH=${TEMP_HIGH:-65}
TEMP_CRITICAL=${TEMP_CRITICAL:-70}

# Fan speeds for each temperature range (percentage)
FAN_SPEED_LOW=${FAN_SPEED_LOW:-20}
FAN_SPEED_MEDIUM=${FAN_SPEED_MEDIUM:-30}
FAN_SPEED_HIGH=${FAN_SPEED_HIGH:-40}
FAN_SPEED_CRITICAL=${FAN_SPEED_CRITICAL:-60}

# Operation mode: auto or manual
OPERATION_MODE=${OPERATION_MODE:-"manual"}

# Check interval (seconds) for auto mode
CHECK_INTERVAL=${CHECK_INTERVAL:-60}



# ESXi variables
ESXI_HOST=${ESXI_HOST:-"REPLACE_TO_YOUR_ESXI_HOST"}
ESXI_USERNAME=${ESXI_USERNAME:-"REPLACE_TO_YOUR_ESXI_USERNAME"}
ESXI_PASSWORD=${ESXI_PASSWORD:-"REPLACE_TO_YOUR_ESXI_PASSWORD"}

 
# Function to get current drive temperature
get_drive_temp() {
    local temp=$(sshpass -p "${ESXI_PASSWORD}" ssh -o StrictHostKeyChecking=no "${ESXI_USERNAME}@${ESXI_HOST}" \
        "esxcli storage core device smart get -d ${DRIVE_DEVICE}" | \
        awk '/Drive Temperature/ {print $3}')
    echo "${temp:-0}"
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
    echo "Press Ctrl+C to exit and restore automatic control"
    
    # Set up trap for clean exit
    trap restore_auto_control EXIT
    
    local last_speed=""
    
    while true; do
        # Get current temperature
        local temp=$(get_drive_temp)
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Drive temperature: ${temp}°C"
        
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

#!/usr/bin/env bash

set -Eeuo pipefail

PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:${PATH}"

PROGRAM_NAME="$(basename "$0")"

: "${IDRAC_IP:=}"
: "${IDRAC_ID:=root}"
: "${IDRAC_PASSWORD:=}"
: "${IPMI_INTERFACE:=lanplus}"
: "${IPMI_TIMEOUT:=5}"
: "${IPMI_RETRIES:=2}"

: "${ESXI_HOST:=}"
: "${ESXI_USERNAME:=root}"
: "${ESXI_PASSWORD:=}"
: "${ESXI_SSH_KEY:=}"
: "${ESXI_SSH_PORT:=22}"
: "${SSH_CONNECT_TIMEOUT:=10}"
: "${SSH_STRICT_HOST_KEY_CHECKING:=accept-new}"
: "${DRIVE_DEVICE:=}"

: "${LINUX_DISK_DEVICES:=}"
: "${LINUX_DISK_TEMP_OFFSET:=0}"
: "${LINUX_DISK_NOCHECK:=never}"

: "${REMOTE_GPU_HOSTS:=}"
: "${REMOTE_GPU_USERNAME:=root}"
: "${REMOTE_GPU_PASSWORD:=}"
: "${REMOTE_GPU_SSH_KEY:=}"
: "${REMOTE_GPU_SSH_PORT:=22}"
: "${REMOTE_GPU_TEMP_OFFSET:=15}"

: "${OPERATION_MODE:=manual}"
: "${TEMPERATURE_SOURCES:=esxi}"
: "${WITH_GPU_TEMP:=false}"
: "${GPU_TEMP_OFFSET:=15}"
: "${CHECK_INTERVAL:=60}"
: "${COMMAND_TIMEOUT:=20}"

: "${TEMP_LOW:=65}"
: "${TEMP_MEDIUM:=70}"
: "${TEMP_HIGH:=75}"
: "${TEMP_CRITICAL:=80}"

: "${FAN_SPEED_IDLE:=${FAN_SPEED_LOW:-30}}"
: "${FAN_SPEED_LOW:=30}"
: "${FAN_SPEED_MEDIUM:=40}"
: "${FAN_SPEED_HIGH:=50}"
: "${FAN_SPEED_CRITICAL:=60}"
: "${FAILSAFE_FAN_SPEED:=70}"
: "${FAILSAFE_ON_ERROR:=true}"
: "${RESTORE_AUTO_ON_EXIT:=true}"
: "${HYSTERESIS:=2}"
: "${MANUAL_FAN_SPEED:=}"

: "${IDRAC_SENSOR_INCLUDE_REGEX:=}"
: "${IDRAC_SENSOR_EXCLUDE_REGEX:=no reading|disabled|not readable}"

: "${LOG_DIR:=/var/log/fan-control}"
: "${LOG_FILE:=fan_control.log}"
: "${LOG_LEVEL:=INFO}"
: "${HEALTHCHECK_MAX_AGE:=0}"
: "${DRY_RUN:=false}"

readonly TEMPERATURE_SOURCE_INTERFACE_VERSION=1
readonly TEMPERATURE_SOURCE_IDS="esxi idrac gpu linux_disk remote_gpu"

LAST_LEVEL=""
LAST_SPEED=""

usage() {
    cat <<EOF
iDRAC fan control

Usage:
  ${PROGRAM_NAME} auto                 Start continuous automatic control
  ${PROGRAM_NAME} once                 Run one automatic control cycle
  ${PROGRAM_NAME} manual [speed]       Set a manual fan speed percentage
  ${PROGRAM_NAME} restore              Return iDRAC to automatic fan control
  ${PROGRAM_NAME} status               Print iDRAC chassis and temperature status
  ${PROGRAM_NAME} validate             Validate local configuration
  ${PROGRAM_NAME} config               Print the effective configuration (secrets redacted)
  ${PROGRAM_NAME} diagnose             Probe every configured dependency without changing fans
  ${PROGRAM_NAME} healthcheck          Check config and automatic control loop freshness

The command defaults to OPERATION_MODE when no argument is supplied.
EOF
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_level_rank() {
    case "$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')" in
        DEBUG) printf '10' ;;
        INFO) printf '20' ;;
        WARN) printf '30' ;;
        ERROR) printf '40' ;;
        *) printf '20' ;;
    esac
}

log() {
    local level="$1"
    shift

    if (( $(log_level_rank "$level") < $(log_level_rank "$LOG_LEVEL") )); then
        return 0
    fi

    printf '%s [%s] %s\n' "$(timestamp)" "$level" "$*" >&2
}

compact_error() {
    local value="${1:-}"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    value="${value//$'\t'/ }"
    value="$(trim "$value")"
    printf '%.400s' "$value"
}

sanitize_log_field() {
    local value="${1:-}"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    value="${value//\"/\'}"
    printf '%s' "$value"
}

trim() {
    local value="$*"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

is_integer() {
    [[ "${1:-}" =~ ^-?[0-9]+$ ]]
}

is_true() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}

is_bool() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|0|true|false|yes|no|y|n|on|off) return 0 ;;
        *) return 1 ;;
    esac
}

require_command() {
    local command="$1"
    if ! command -v "$command" >/dev/null 2>&1; then
        log "ERROR" "Required command not found: ${command}"
        return 1
    fi
}

is_placeholder_value() {
    local value="$1"

    case "$value" in
        REPLACE_TO_YOUR_*|replace_with_*|your_*|change-me|changeme|t10.NVMe____replace*)
            return 0
            ;;
        192.0.2.*|198.51.100.*|203.0.113.*)
            # RFC 5737 documentation networks must never be used for a live target.
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

require_value() {
    local name="$1"
    local value="$2"
    if [[ -z "$value" ]]; then
        log "ERROR" "Missing required configuration: ${name}"
        return 1
    fi
    if is_placeholder_value "$value"; then
        log "ERROR" "Replace placeholder value for ${name}"
        return 1
    fi
}

validate_integer_range() {
    local name="$1"
    local value="$2"
    local min="$3"
    local max="$4"

    if ! is_integer "$value"; then
        log "ERROR" "${name} must be an integer, got '${value}'"
        return 1
    fi

    if (( value < min || value > max )); then
        log "ERROR" "${name} must be between ${min} and ${max}, got ${value}"
        return 1
    fi
}

normalize_sources() {
    local raw="${TEMPERATURE_SOURCES//[[:space:]]/}"
    local normalized=""
    local source
    local -a source_list

    IFS=',' read -r -a source_list <<< "$raw"
    for source in "${source_list[@]}"; do
        [[ -z "$source" ]] && continue
        source="$(printf '%s' "$source" | tr '[:upper:]' '[:lower:]')"
        if ! source_enabled_in_list "$source" "$normalized"; then
            normalized="${normalized:+${normalized},}${source}"
        fi
    done

    if is_true "$WITH_GPU_TEMP" && ! source_enabled_in_list "gpu" "$normalized"; then
        normalized="${normalized:+${normalized},}gpu"
    fi

    printf '%s' "$normalized"
}

source_enabled_in_list() {
    local wanted="$1"
    local list="${2:-}"
    local source
    local -a enabled_sources

    IFS=',' read -r -a enabled_sources <<< "$list"
    for source in "${enabled_sources[@]}"; do
        [[ "$source" == "$wanted" ]] && return 0
    done

    return 1
}

normalize_csv_list() {
    local raw="${1:-}"
    local normalized=""
    local item
    local -a items

    IFS=',' read -r -a items <<< "$raw"
    for item in "${items[@]}"; do
        item="$(trim "$item")"
        [[ -z "$item" ]] && continue
        if ! source_enabled_in_list "$item" "$normalized"; then
            normalized="${normalized:+${normalized},}${item}"
        fi
    done

    printf '%s' "$normalized"
}

temperature_source_supported() {
    local wanted="$1"
    local source

    for source in $TEMPERATURE_SOURCE_IDS; do
        [[ "$source" == "$wanted" ]] && return 0
    done
    return 1
}

temperature_source_method() {
    local source="$1"
    local method="$2"
    shift 2
    local function_name="temperature_source_${source}_${method}"

    temperature_source_supported "$source" || return 1
    declare -F "$function_name" >/dev/null 2>&1 || {
        log "ERROR" "Temperature source '${source}' does not implement ${method}() for interface v${TEMPERATURE_SOURCE_INTERFACE_VERSION}"
        return 1
    }
    "$function_name" "$@"
}

temperature_source_interface_complete() {
    local source="$1"
    local method

    for method in validate collect adjust; do
        declare -F "temperature_source_${source}_${method}" >/dev/null 2>&1 || return 1
    done
}

command_needs_ipmi() {
    case "$1" in
        auto|once|manual|restore|status|diagnose) return 0 ;;
        *) return 1 ;;
    esac
}

command_needs_temperature() {
    case "$1" in
        auto|once|diagnose) return 0 ;;
        *) return 1 ;;
    esac
}

validate_awk_regex() {
    local name="$1"
    local regex="$2"

    [[ -z "$regex" ]] && return 0
    if ! awk -v regex="$regex" 'BEGIN { exit !("probe" ~ regex || "probe" !~ regex) }' </dev/null 2>/dev/null; then
        log "ERROR" "${name} is not a valid awk regular expression"
        return 1
    fi
}

validate_sources() {
    local sources
    local source
    local error=0
    local -a source_list

    sources="$(normalize_sources)"
    if [[ -z "$sources" ]]; then
        log "ERROR" "TEMPERATURE_SOURCES must contain at least one source: ${TEMPERATURE_SOURCE_IDS// /, }"
        return 1
    fi

    IFS=',' read -r -a source_list <<< "$sources"
    for source in "${source_list[@]}"; do
        if ! temperature_source_supported "$source"; then
            log "ERROR" "Unsupported temperature source '${source}'. Use ${TEMPERATURE_SOURCE_IDS// /, }."
            error=1
        elif ! temperature_source_interface_complete "$source"; then
            log "ERROR" "Temperature source '${source}' has an incomplete interface"
            error=1
        fi
    done

    return "$error"
}

validate_config() {
    local command="${1:-$OPERATION_MODE}"
    local error=0
    local sources

    case "$command" in
        auto|once|manual|restore|status|validate|config|diagnose|healthcheck) ;;
        help|-h|--help) return 0 ;;
        *)
            log "ERROR" "Invalid command or OPERATION_MODE: ${command}"
            error=1
            ;;
    esac

    if ! is_bool "$DRY_RUN"; then
        log "ERROR" "DRY_RUN must be a boolean value"
        error=1
    fi
    validate_integer_range "COMMAND_TIMEOUT" "$COMMAND_TIMEOUT" 1 300 || error=1
    validate_integer_range "IPMI_TIMEOUT" "$IPMI_TIMEOUT" 1 60 || error=1
    validate_integer_range "IPMI_RETRIES" "$IPMI_RETRIES" 0 20 || error=1

    if [[ "$command" == "manual" && -n "$MANUAL_FAN_SPEED" ]]; then
        validate_integer_range "MANUAL_FAN_SPEED" "$MANUAL_FAN_SPEED" 1 100 || error=1
    fi

    if command_needs_temperature "$command"; then
        for bool_name in WITH_GPU_TEMP FAILSAFE_ON_ERROR RESTORE_AUTO_ON_EXIT; do
            if ! is_bool "${!bool_name}"; then
                log "ERROR" "${bool_name} must be a boolean value"
                error=1
            fi
        done

        validate_integer_range "TEMP_LOW" "$TEMP_LOW" 0 120 || error=1
        validate_integer_range "TEMP_MEDIUM" "$TEMP_MEDIUM" 0 120 || error=1
        validate_integer_range "TEMP_HIGH" "$TEMP_HIGH" 0 120 || error=1
        validate_integer_range "TEMP_CRITICAL" "$TEMP_CRITICAL" 0 120 || error=1
        validate_integer_range "FAN_SPEED_IDLE" "$FAN_SPEED_IDLE" 1 100 || error=1
        validate_integer_range "FAN_SPEED_LOW" "$FAN_SPEED_LOW" 1 100 || error=1
        validate_integer_range "FAN_SPEED_MEDIUM" "$FAN_SPEED_MEDIUM" 1 100 || error=1
        validate_integer_range "FAN_SPEED_HIGH" "$FAN_SPEED_HIGH" 1 100 || error=1
        validate_integer_range "FAN_SPEED_CRITICAL" "$FAN_SPEED_CRITICAL" 1 100 || error=1
        validate_integer_range "FAILSAFE_FAN_SPEED" "$FAILSAFE_FAN_SPEED" 1 100 || error=1
        validate_integer_range "CHECK_INTERVAL" "$CHECK_INTERVAL" 1 86400 || error=1
        validate_integer_range "SSH_CONNECT_TIMEOUT" "$SSH_CONNECT_TIMEOUT" 1 300 || error=1
        validate_integer_range "ESXI_SSH_PORT" "$ESXI_SSH_PORT" 1 65535 || error=1
        validate_integer_range "REMOTE_GPU_SSH_PORT" "$REMOTE_GPU_SSH_PORT" 1 65535 || error=1
        validate_integer_range "GPU_TEMP_OFFSET" "$GPU_TEMP_OFFSET" 0 120 || error=1
        validate_integer_range "LINUX_DISK_TEMP_OFFSET" "$LINUX_DISK_TEMP_OFFSET" 0 120 || error=1
        validate_integer_range "REMOTE_GPU_TEMP_OFFSET" "$REMOTE_GPU_TEMP_OFFSET" 0 120 || error=1
        validate_integer_range "HYSTERESIS" "$HYSTERESIS" 0 30 || error=1
        validate_integer_range "HEALTHCHECK_MAX_AGE" "$HEALTHCHECK_MAX_AGE" 0 86400 || error=1

        case "$(printf '%s' "$LOG_LEVEL" | tr '[:lower:]' '[:upper:]')" in
            DEBUG|INFO|WARN|ERROR) ;;
            *)
                log "ERROR" "LOG_LEVEL must be DEBUG, INFO, WARN, or ERROR"
                error=1
                ;;
        esac

        case "$(printf '%s' "$SSH_STRICT_HOST_KEY_CHECKING" | tr '[:upper:]' '[:lower:]')" in
            yes|no|ask|accept-new) ;;
            *)
                log "ERROR" "SSH_STRICT_HOST_KEY_CHECKING must be yes, no, ask, or accept-new"
                error=1
                ;;
        esac

        validate_awk_regex "IDRAC_SENSOR_INCLUDE_REGEX" "$IDRAC_SENSOR_INCLUDE_REGEX" || error=1
        validate_awk_regex "IDRAC_SENSOR_EXCLUDE_REGEX" "$IDRAC_SENSOR_EXCLUDE_REGEX" || error=1

        if is_integer "$TEMP_LOW" && is_integer "$TEMP_MEDIUM" && is_integer "$TEMP_HIGH" && is_integer "$TEMP_CRITICAL"; then
            if (( TEMP_LOW >= TEMP_MEDIUM || TEMP_MEDIUM >= TEMP_HIGH || TEMP_HIGH >= TEMP_CRITICAL )); then
                log "ERROR" "Temperature thresholds must increase: TEMP_LOW < TEMP_MEDIUM < TEMP_HIGH < TEMP_CRITICAL"
                error=1
            fi
        fi

        if is_integer "$FAN_SPEED_IDLE" && is_integer "$FAN_SPEED_LOW" && is_integer "$FAN_SPEED_MEDIUM" \
            && is_integer "$FAN_SPEED_HIGH" && is_integer "$FAN_SPEED_CRITICAL"; then
            if (( FAN_SPEED_IDLE > FAN_SPEED_LOW || FAN_SPEED_LOW > FAN_SPEED_MEDIUM \
                || FAN_SPEED_MEDIUM > FAN_SPEED_HIGH || FAN_SPEED_HIGH > FAN_SPEED_CRITICAL )); then
                log "ERROR" "Fan speeds must not decrease from idle through critical"
                error=1
            fi
            if is_integer "$FAILSAFE_FAN_SPEED" && (( FAILSAFE_FAN_SPEED < FAN_SPEED_CRITICAL )); then
                log "ERROR" "FAILSAFE_FAN_SPEED must be at least FAN_SPEED_CRITICAL"
                error=1
            fi
        fi
    fi

    if command_needs_ipmi "$command"; then
        require_value "IDRAC_IP" "$IDRAC_IP" || error=1
        require_value "IDRAC_ID" "$IDRAC_ID" || error=1
        require_value "IDRAC_PASSWORD" "$IDRAC_PASSWORD" || error=1
        if ! is_true "$DRY_RUN"; then
            require_command "ipmitool" || error=1
            require_command "timeout" || error=1
        fi
    fi

    if command_needs_temperature "$command"; then
        validate_sources || error=1
        sources="$(normalize_sources)"
        local source
        local -a source_list
        IFS=',' read -r -a source_list <<< "$sources"
        for source in "${source_list[@]}"; do
            temperature_source_method "$source" validate || error=1
        done
    fi

    return "$error"
}

fan_speed_to_hex() {
    local speed="$1"
    printf '%02x' "$speed"
}

run_ipmitool() {
    local args=("$@")

    if is_true "$DRY_RUN"; then
        log "INFO" "DRY_RUN ipmitool ${args[*]}"
        return 0
    fi

    log "DEBUG" "Running IPMI command against ${IDRAC_IP}: ${args[*]}"
    timeout "$COMMAND_TIMEOUT" env IPMI_PASSWORD="$IDRAC_PASSWORD" \
        ipmitool -I "$IPMI_INTERFACE" -H "$IDRAC_IP" -U "$IDRAC_ID" -E \
        -N "$IPMI_TIMEOUT" -R "$IPMI_RETRIES" "${args[@]}"
}

set_fan_speed() {
    local fan_speed="$1"
    local hex_speed

    validate_integer_range "fan speed" "$fan_speed" 1 100 || return 1
    hex_speed="$(fan_speed_to_hex "$fan_speed")"

    log "INFO" "Setting fan speed to ${fan_speed}% (0x${hex_speed})"
    run_ipmitool raw 0x30 0x30 0x01 0x00 || return 1
    run_ipmitool raw 0x30 0x30 0x02 0xff "0x${hex_speed}"
}

restore_auto_control() {
    log "INFO" "Restoring iDRAC automatic fan control"
    run_ipmitool raw 0x30 0x30 0x01 0x01
}

remote_quote() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\\\'\'}"
}

run_ssh_command() {
    local context="$1"
    local host="$2"
    local username="$3"
    local password="$4"
    local key="$5"
    local port="$6"
    local remote_command="$7"
    local ssh_command=(ssh -p "$port" -o "StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}" -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}")

    if [[ -n "$key" ]]; then
        ssh_command+=(-i "$key" -o BatchMode=yes)
    fi

    ssh_command+=("${username}@${host}" "$remote_command")
    log "DEBUG" "Running ${context} SSH query against ${host}:${port} as ${username}"

    if [[ -n "$password" && -z "$key" ]]; then
        SSHPASS="$password" timeout "$COMMAND_TIMEOUT" sshpass -e "${ssh_command[@]}"
    else
        timeout "$COMMAND_TIMEOUT" "${ssh_command[@]}"
    fi
}

run_esxi_command() {
    run_ssh_command "ESXi" "$ESXI_HOST" "$ESXI_USERNAME" "$ESXI_PASSWORD" \
        "$ESXI_SSH_KEY" "$ESXI_SSH_PORT" "$1"
}

get_esxi_drive_temperature() {
    local remote_device
    local output
    local temp

    remote_device="$(remote_quote "$DRIVE_DEVICE")"
    if ! output="$(run_esxi_command "esxcli storage core device smart get -d ${remote_device}")"; then
        log "DEBUG" "ESXi SMART query failed for device ${DRIVE_DEVICE}"
        return 1
    fi

    temp="$(awk '
        /Drive Temperature/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^-?[0-9]+$/) {
                    print $i
                    exit
                }
            }
        }
    ' <<< "$output")"

    if ! is_integer "$temp"; then
        log "DEBUG" "ESXi SMART output did not contain a numeric Drive Temperature"
        return 1
    fi

    printf 'esxi\t%s\t%s\n' "$DRIVE_DEVICE" "$temp"
}

parse_idrac_sdr_temperatures() {
    awk -F'|' \
        -v include_regex="$IDRAC_SENSOR_INCLUDE_REGEX" \
        -v exclude_regex="$IDRAC_SENSOR_EXCLUDE_REGEX" '
        function trim_value(value) {
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", value)
            return value
        }
        {
            sensor = trim_value($1)
            line = tolower($0)
            if (sensor == "") {
                next
            }
            if (exclude_regex != "" && line ~ exclude_regex) {
                next
            }
            if (include_regex != "" && sensor !~ include_regex) {
                next
            }
            for (i = 2; i <= NF; i++) {
                field = trim_value($i)
                if (field ~ /^-?[0-9]+[ \t]+degrees C/) {
                    split(field, parts, /[ \t]+/)
                    print "idrac\t" sensor "\t" parts[1]
                    next
                }
            }
        }
    '
}

get_idrac_temperatures() {
    local output
    local parsed

    if ! output="$(run_ipmitool sdr type Temperature)"; then
        log "DEBUG" "iDRAC sensor query failed"
        return 1
    fi

    parsed="$(parse_idrac_sdr_temperatures <<< "$output")"
    if [[ -z "$parsed" ]]; then
        log "DEBUG" "iDRAC returned no readable temperature sensors after filtering"
        return 1
    fi
    printf '%s\n' "$parsed"
}

get_gpu_temperatures() {
    local output

    command -v nvidia-smi >/dev/null 2>&1 || return 1

    if ! output="$(timeout "$COMMAND_TIMEOUT" nvidia-smi --query-gpu=index,temperature.gpu --format=csv,noheader,nounits)"; then
        log "DEBUG" "nvidia-smi temperature query failed"
        return 1
    fi

    parse_nvidia_smi_temperatures "gpu" "" <<< "$output"
}

parse_nvidia_smi_temperatures() {
    local source="$1"
    local label_prefix="$2"
    local index
    local temp
    local found=1

    while IFS=',' read -r index temp; do
        index="$(trim "$index")"
        temp="$(trim "$temp")"
        if is_integer "$temp"; then
            printf '%s\t%sgpu%s\t%s\n' "$source" "$label_prefix" "$index" "$temp"
            found=0
        fi
    done

    return "$found"
}

parse_smartctl_temperature() {
    jq -er '
        [
            .temperature.current?,
            .nvme_smart_health_information_log.temperature?,
            (
                .ata_smart_attributes.table[]?
                | select((.name // "" | ascii_downcase) | contains("temperature"))
                | .raw.value?
            )
        ]
        | map(if type == "string" then (tonumber? // empty) else . end)
        | map(select(type == "number"))
        | (.[0] // empty)
        | round
    ' 2>/dev/null
}

get_linux_disk_temperatures() {
    local devices
    local device
    local output
    local status
    local temp
    local label
    local found=1
    local -a device_list

    devices="$(normalize_csv_list "$LINUX_DISK_DEVICES")"
    IFS=',' read -r -a device_list <<< "$devices"
    for device in "${device_list[@]}"; do
        status=0
        output="$(timeout "$COMMAND_TIMEOUT" smartctl -n "$LINUX_DISK_NOCHECK" -A -j "$device" 2>/dev/null)" || status=$?
        if (( status == 124 )); then
            log "WARN" "Linux disk SMART query timed out for ${device}"
            continue
        fi

        if ! temp="$(parse_smartctl_temperature <<< "$output")" || ! is_integer "$temp"; then
            log "WARN" "Linux disk SMART output contained no temperature for ${device} (smartctl status ${status})"
            continue
        fi

        label="${device#/dev/}"
        printf 'linux_disk\t%s\t%s\n' "$label" "$temp"
        found=0
    done

    return "$found"
}

get_remote_gpu_temperatures() {
    local hosts
    local host
    local output
    local found=1
    local -a host_list
    local remote_command='nvidia-smi --query-gpu=index,temperature.gpu --format=csv,noheader,nounits'

    hosts="$(normalize_csv_list "$REMOTE_GPU_HOSTS")"
    IFS=',' read -r -a host_list <<< "$hosts"
    for host in "${host_list[@]}"; do
        if output="$(run_ssh_command "remote GPU" "$host" "$REMOTE_GPU_USERNAME" \
            "$REMOTE_GPU_PASSWORD" "$REMOTE_GPU_SSH_KEY" "$REMOTE_GPU_SSH_PORT" "$remote_command")" \
            && parse_nvidia_smi_temperatures "remote_gpu" "${host}/" <<< "$output"; then
            found=0
        else
            log "WARN" "Remote NVIDIA temperature query failed for ${host}"
        fi
    done

    return "$found"
}

apply_temperature_offset() {
    local temp="$1"
    local offset="$2"
    local adjusted=$((temp - offset))
    (( adjusted < 0 )) && adjusted=0
    printf '%s' "$adjusted"
}

temperature_source_esxi_validate() {
    local error=0

    require_value "ESXI_HOST" "$ESXI_HOST" || error=1
    require_value "ESXI_USERNAME" "$ESXI_USERNAME" || error=1
    require_value "DRIVE_DEVICE" "$DRIVE_DEVICE" || error=1
    if [[ -z "$ESXI_PASSWORD" && -z "$ESXI_SSH_KEY" ]]; then
        log "ERROR" "Set ESXI_PASSWORD or ESXI_SSH_KEY when TEMPERATURE_SOURCES includes esxi"
        error=1
    elif [[ -z "$ESXI_SSH_KEY" ]]; then
        require_value "ESXI_PASSWORD" "$ESXI_PASSWORD" || error=1
    elif is_placeholder_value "$ESXI_SSH_KEY"; then
        log "ERROR" "Replace placeholder value for ESXI_SSH_KEY"
        error=1
    elif [[ ! -r "$ESXI_SSH_KEY" ]]; then
        log "ERROR" "ESXI_SSH_KEY is not readable: ${ESXI_SSH_KEY}"
        error=1
    fi
    if ! is_true "$DRY_RUN"; then
        require_command "ssh" || error=1
        require_command "timeout" || error=1
        if [[ -n "$ESXI_PASSWORD" && -z "$ESXI_SSH_KEY" ]]; then
            require_command "sshpass" || error=1
        fi
    fi
    return "$error"
}

temperature_source_esxi_collect() { get_esxi_drive_temperature; }
temperature_source_esxi_adjust() { printf '%s' "$1"; }

temperature_source_idrac_validate() { return 0; }
temperature_source_idrac_collect() { get_idrac_temperatures; }
temperature_source_idrac_adjust() { printf '%s' "$1"; }

temperature_source_gpu_validate() {
    if ! is_true "$DRY_RUN" && ! command -v nvidia-smi >/dev/null 2>&1; then
        log "WARN" "GPU source is enabled but nvidia-smi is unavailable; fail-safe will be used if no other source succeeds"
    fi
}
temperature_source_gpu_collect() { get_gpu_temperatures; }
temperature_source_gpu_adjust() { apply_temperature_offset "$1" "$GPU_TEMP_OFFSET"; }

is_linux_device_path() {
    local path="$1"
    local relative
    local component
    local -a components

    [[ "$path" =~ ^/dev/[A-Za-z0-9._+:/-]+$ ]] || return 1
    relative="${path#/dev/}"
    [[ -n "$relative" && "$relative" != */ && "$relative" != *//* ]] || return 1

    IFS='/' read -r -a components <<< "$relative"
    for component in "${components[@]}"; do
        [[ "$component" != "." && "$component" != ".." ]] || return 1
    done
}

temperature_source_linux_disk_validate() {
    local devices
    local device
    local error=0
    local -a device_list

    require_value "LINUX_DISK_DEVICES" "$LINUX_DISK_DEVICES" || return 1
    devices="$(normalize_csv_list "$LINUX_DISK_DEVICES")"
    IFS=',' read -r -a device_list <<< "$devices"
    for device in "${device_list[@]}"; do
        if ! is_linux_device_path "$device"; then
            log "ERROR" "LINUX_DISK_DEVICES contains an invalid device path: ${device}"
            error=1
        fi
    done
    case "$LINUX_DISK_NOCHECK" in
        never|sleep|standby|idle) ;;
        *)
            log "ERROR" "LINUX_DISK_NOCHECK must be never, sleep, standby, or idle"
            error=1
            ;;
    esac
    if ! is_true "$DRY_RUN"; then
        require_command "smartctl" || error=1
        require_command "jq" || error=1
        require_command "timeout" || error=1
    fi
    return "$error"
}
temperature_source_linux_disk_collect() { get_linux_disk_temperatures; }
temperature_source_linux_disk_adjust() { apply_temperature_offset "$1" "$LINUX_DISK_TEMP_OFFSET"; }

temperature_source_remote_gpu_validate() {
    local hosts
    local host
    local error=0
    local -a host_list

    require_value "REMOTE_GPU_HOSTS" "$REMOTE_GPU_HOSTS" || error=1
    require_value "REMOTE_GPU_USERNAME" "$REMOTE_GPU_USERNAME" || error=1
    hosts="$(normalize_csv_list "$REMOTE_GPU_HOSTS")"
    IFS=',' read -r -a host_list <<< "$hosts"
    for host in "${host_list[@]}"; do
        if [[ ! "$host" =~ ^[A-Za-z0-9._:-]+$ ]]; then
            log "ERROR" "REMOTE_GPU_HOSTS contains an invalid hostname or address: ${host}"
            error=1
        fi
    done
    if [[ ! "$REMOTE_GPU_USERNAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log "ERROR" "REMOTE_GPU_USERNAME contains unsupported characters"
        error=1
    fi
    if [[ -z "$REMOTE_GPU_PASSWORD" && -z "$REMOTE_GPU_SSH_KEY" ]]; then
        log "ERROR" "Set REMOTE_GPU_PASSWORD or REMOTE_GPU_SSH_KEY when TEMPERATURE_SOURCES includes remote_gpu"
        error=1
    elif [[ -z "$REMOTE_GPU_SSH_KEY" ]]; then
        require_value "REMOTE_GPU_PASSWORD" "$REMOTE_GPU_PASSWORD" || error=1
    elif is_placeholder_value "$REMOTE_GPU_SSH_KEY"; then
        log "ERROR" "Replace placeholder value for REMOTE_GPU_SSH_KEY"
        error=1
    elif [[ ! -r "$REMOTE_GPU_SSH_KEY" ]]; then
        log "ERROR" "REMOTE_GPU_SSH_KEY is not readable: ${REMOTE_GPU_SSH_KEY}"
        error=1
    fi
    if ! is_true "$DRY_RUN"; then
        require_command "ssh" || error=1
        require_command "timeout" || error=1
        if [[ -n "$REMOTE_GPU_PASSWORD" && -z "$REMOTE_GPU_SSH_KEY" ]]; then
            require_command "sshpass" || error=1
        fi
    fi
    return "$error"
}
temperature_source_remote_gpu_collect() { get_remote_gpu_temperatures; }
temperature_source_remote_gpu_adjust() { apply_temperature_offset "$1" "$REMOTE_GPU_TEMP_OFFSET"; }

collect_temperature_readings() {
    local sources
    local source
    local output
    local found=1
    local -a source_list

    sources="$(normalize_sources)"
    IFS=',' read -r -a source_list <<< "$sources"

    for source in "${source_list[@]}"; do
        log "DEBUG" "Collecting temperature source: ${source}"
        if output="$(temperature_source_method "$source" collect)"; then
            printf '%s\n' "$output"
            found=0
        else
            log "WARN" "Temperature source '${source}' read failed"
        fi
    done

    return "$found"
}

calculate_decision_temperature() {
    local readings="$1"
    local source
    local label
    local temp
    local adjusted
    local max_temp=""
    local detail_text=""

    while IFS=$'\t' read -r source label temp; do
        [[ -z "${source:-}" || -z "${temp:-}" ]] && continue
        is_integer "$temp" || continue

        if ! adjusted="$(temperature_source_method "$source" adjust "$temp")" || ! is_integer "$adjusted"; then
            log "WARN" "Temperature source '${source}' returned an invalid adjusted value for ${label}"
            continue
        fi
        if [[ "$adjusted" != "$temp" ]]; then
            detail_text="${detail_text:+${detail_text}, }${source}:${label}=${temp}C(adjusted=${adjusted}C)"
        else
            detail_text="${detail_text:+${detail_text}, }${source}:${label}=${temp}C"
        fi

        if [[ -z "$max_temp" || "$adjusted" -gt "$max_temp" ]]; then
            max_temp="$adjusted"
        fi
    done <<< "$readings"

    [[ -n "$max_temp" ]] || return 1
    printf '%s\t%s\n' "$max_temp" "$detail_text"
}

get_decision_temperature() {
    local readings

    if ! readings="$(collect_temperature_readings)"; then
        return 1
    fi

    calculate_decision_temperature "$readings"
}

temperature_level() {
    local temp="$1"

    if (( temp >= TEMP_CRITICAL )); then
        printf 'critical'
    elif (( temp >= TEMP_HIGH )); then
        printf 'high'
    elif (( temp >= TEMP_MEDIUM )); then
        printf 'medium'
    elif (( temp >= TEMP_LOW )); then
        printf 'low'
    else
        printf 'idle'
    fi
}

level_rank() {
    case "$1" in
        idle) printf '0' ;;
        low) printf '1' ;;
        medium) printf '2' ;;
        high) printf '3' ;;
        critical) printf '4' ;;
        *) printf '-1' ;;
    esac
}

threshold_for_level() {
    case "$1" in
        low) printf '%s' "$TEMP_LOW" ;;
        medium) printf '%s' "$TEMP_MEDIUM" ;;
        high) printf '%s' "$TEMP_HIGH" ;;
        critical) printf '%s' "$TEMP_CRITICAL" ;;
        *) printf '%s' '-999' ;;
    esac
}

fan_speed_for_level() {
    case "$1" in
        idle) printf '%s' "$FAN_SPEED_IDLE" ;;
        low) printf '%s' "$FAN_SPEED_LOW" ;;
        medium) printf '%s' "$FAN_SPEED_MEDIUM" ;;
        high) printf '%s' "$FAN_SPEED_HIGH" ;;
        critical) printf '%s' "$FAN_SPEED_CRITICAL" ;;
        *) return 1 ;;
    esac
}

apply_hysteresis() {
    local temp="$1"
    local proposed_level="$2"
    local previous_level="${3:-}"
    local proposed_rank
    local previous_rank
    local previous_threshold

    [[ -n "$previous_level" ]] || {
        printf '%s' "$proposed_level"
        return 0
    }

    proposed_rank="$(level_rank "$proposed_level")"
    previous_rank="$(level_rank "$previous_level")"
    if (( previous_rank < 0 || proposed_rank < 0 || previous_rank == 0 )); then
        printf '%s' "$proposed_level"
        return 0
    fi

    if (( proposed_rank >= previous_rank )); then
        printf '%s' "$proposed_level"
        return 0
    fi

    previous_threshold="$(threshold_for_level "$previous_level")"
    if (( temp > previous_threshold - HYSTERESIS )); then
        printf '%s' "$previous_level"
    else
        printf '%s' "$proposed_level"
    fi
}

choose_fan_speed() {
    local temp="$1"
    local previous_level="${2:-}"
    local raw_level
    local level
    local speed

    raw_level="$(temperature_level "$temp")"
    level="$(apply_hysteresis "$temp" "$raw_level" "$previous_level")"
    speed="$(fan_speed_for_level "$level")"
    printf '%s\t%s\n' "$level" "$speed"
}

prepare_log_dir() {
    [[ -n "$LOG_DIR" ]] || return 0
    mkdir -p "$LOG_DIR" || return 1
    touch "${LOG_DIR}/${LOG_FILE}" || return 1
}

write_status_log() {
    local temp="$1"
    local level="$2"
    local speed="$3"
    local status="$4"
    local details="${5:-}"

    details="$(sanitize_log_field "$details")"
    [[ -n "$LOG_DIR" ]] || return 0
    prepare_log_dir || return 1
    printf '%s status=%s temp=%s level=%s fan=%s%% details="%s"\n' \
        "$(timestamp)" "$status" "$temp" "$level" "$speed" "$details" >> "${LOG_DIR}/${LOG_FILE}"
}

control_cycle() {
    local decision_line
    local temp
    local details
    local selected
    local level
    local speed

    if decision_line="$(get_decision_temperature)"; then
        IFS=$'\t' read -r temp details <<< "$decision_line"
        selected="$(choose_fan_speed "$temp" "$LAST_LEVEL")"
        IFS=$'\t' read -r level speed <<< "$selected"

        if [[ "$speed" != "$LAST_SPEED" ]]; then
            set_fan_speed "$speed" || return 1
        fi

        LAST_LEVEL="$level"
        LAST_SPEED="$speed"
        log "INFO" "Control temp ${temp}C -> ${level} (${speed}%). Sources: ${details}"
        write_status_log "$temp" "$level" "$speed" "ok" "$details"
        return 0
    fi

    log "ERROR" "No valid temperature readings were available"
    if is_true "$FAILSAFE_ON_ERROR"; then
        if [[ "$LAST_SPEED" != "$FAILSAFE_FAN_SPEED" ]]; then
            set_fan_speed "$FAILSAFE_FAN_SPEED" || return 1
        fi
        LAST_LEVEL="failsafe"
        LAST_SPEED="$FAILSAFE_FAN_SPEED"
        log "WARN" "Fail-safe fan speed applied: ${FAILSAFE_FAN_SPEED}%"
        write_status_log "unknown" "failsafe" "$FAILSAFE_FAN_SPEED" "failsafe" "temperature read failed"
        return 0
    fi

    return 1
}

manual_mode() {
    local speed="${1:-$MANUAL_FAN_SPEED}"

    if [[ -z "$speed" ]]; then
        if [[ -t 0 ]]; then
            printf 'Fan speed percentage (1-100): '
            read -r speed
        else
            log "ERROR" "Set MANUAL_FAN_SPEED or pass a speed argument when stdin is not interactive"
            return 1
        fi
    fi

    set_fan_speed "$speed"
}

cleanup_auto_mode() {
    trap - EXIT
    if is_true "$RESTORE_AUTO_ON_EXIT"; then
        restore_auto_control || log "ERROR" "Failed to restore iDRAC automatic fan control"
    fi
}

auto_mode() {
    prepare_log_dir || {
        log "ERROR" "Cannot write log file at ${LOG_DIR}/${LOG_FILE}"
        return 1
    }

    log "INFO" "Automatic fan control started"
    log "INFO" "Temperature sources: $(normalize_sources)"
    log "INFO" "Check interval: ${CHECK_INTERVAL}s, hysteresis: ${HYSTERESIS}C, fail-safe: ${FAILSAFE_FAN_SPEED}%"

    trap cleanup_auto_mode EXIT
    trap 'exit 130' INT TERM

    while true; do
        control_cycle || log "ERROR" "Control cycle failed"
        sleep "$CHECK_INTERVAL"
    done
}

once_mode() {
    prepare_log_dir || {
        log "ERROR" "Cannot write log file at ${LOG_DIR}/${LOG_FILE}"
        return 1
    }
    control_cycle
}

credential_state() {
    local value="${1:-}"

    if [[ -z "$value" ]]; then
        printf 'not set'
    elif is_placeholder_value "$value"; then
        printf 'placeholder (replace it)'
    else
        printf 'set (%s characters)' "${#value}"
    fi
}

config_row() {
    printf '  %-30s %s\n' "$1" "$2"
}

print_effective_config() {
    local esxi_auth="password"
    local remote_gpu_auth="password"

    [[ -n "$ESXI_SSH_KEY" ]] && esxi_auth="ssh-key"
    [[ -n "$REMOTE_GPU_SSH_KEY" ]] && remote_gpu_auth="ssh-key"

    printf 'Effective configuration (credentials are never printed)\n'
    printf '%s\n' '------------------------------------------------------------'
    config_row "Operation mode" "$OPERATION_MODE"
    config_row "Temperature sources" "$(normalize_sources)"
    config_row "iDRAC target" "${IDRAC_ID}@${IDRAC_IP:-not set} (${IPMI_INTERFACE})"
    config_row "iDRAC password" "$(credential_state "$IDRAC_PASSWORD")"
    config_row "ESXi target" "${ESXI_USERNAME}@${ESXI_HOST:-not set}:${ESXI_SSH_PORT}"
    config_row "ESXi authentication" "$esxi_auth"
    config_row "ESXi password" "$(credential_state "$ESXI_PASSWORD")"
    config_row "ESXi drive" "${DRIVE_DEVICE:-not set}"
    config_row "Linux disks" "${LINUX_DISK_DEVICES:-not set} (offset=${LINUX_DISK_TEMP_OFFSET} C, nocheck=${LINUX_DISK_NOCHECK})"
    config_row "Remote GPU targets" "${REMOTE_GPU_USERNAME}@${REMOTE_GPU_HOSTS:-not set}:${REMOTE_GPU_SSH_PORT}"
    config_row "Remote GPU authentication" "$remote_gpu_auth"
    config_row "Remote GPU password" "$(credential_state "$REMOTE_GPU_PASSWORD")"
    config_row "GPU offsets" "local=${GPU_TEMP_OFFSET} C, remote=${REMOTE_GPU_TEMP_OFFSET} C"
    config_row "Fan thresholds" "${TEMP_LOW}/${TEMP_MEDIUM}/${TEMP_HIGH}/${TEMP_CRITICAL} C"
    config_row "Fan speeds" "${FAN_SPEED_IDLE}/${FAN_SPEED_LOW}/${FAN_SPEED_MEDIUM}/${FAN_SPEED_HIGH}/${FAN_SPEED_CRITICAL}%"
    config_row "Hysteresis" "${HYSTERESIS} C"
    config_row "Fail-safe" "enabled=${FAILSAFE_ON_ERROR}, speed=${FAILSAFE_FAN_SPEED}%"
    config_row "Restore on exit" "$RESTORE_AUTO_ON_EXIT"
    config_row "Timing" "interval=${CHECK_INTERVAL}s, command-timeout=${COMMAND_TIMEOUT}s"
    config_row "Logging" "level=${LOG_LEVEL}, path=${LOG_DIR:-disabled}/${LOG_FILE}"
    config_row "Dry run" "$DRY_RUN"
}

diagnostic_row() {
    local status="$1"
    local component="$2"
    local detail="$3"
    printf '[%-4s] %-20s %s\n' "$status" "$component" "$detail"
}

reading_summary() {
    local readings="$1"
    local source
    local label
    local temp
    local summary=""

    while IFS=$'\t' read -r source label temp; do
        [[ -z "${source:-}" || -z "${temp:-}" ]] && continue
        summary="${summary:+${summary}, }${label}=${temp}C"
    done <<< "$readings"

    printf '%s' "$summary"
}

diagnose_mode() {
    local failures=0
    local output
    local summary
    local sources
    local source
    local readings=""
    local decision
    local temp
    local details
    local selected
    local level
    local speed
    local -a source_list

    printf 'iDRAC Fan Control diagnostics (read-only)\n'
    printf 'Generated: %s\n\n' "$(timestamp)"
    diagnostic_row "PASS" "configuration" "static validation passed"

    if [[ -z "$LOG_DIR" ]] || prepare_log_dir; then
        diagnostic_row "PASS" "log path" "${LOG_DIR:-disabled}"
    else
        diagnostic_row "FAIL" "log path" "cannot write ${LOG_DIR}/${LOG_FILE}"
        failures=$((failures + 1))
    fi

    if output="$(run_ipmitool mc info)"; then
        summary="$(awk -F: '/Firmware Revision|Product Name/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); printf "%s%s", separator, $2; separator=", " }' <<< "$output")"
        diagnostic_row "PASS" "iDRAC/IPMI" "${summary:-connection and authentication succeeded}"
    else
        diagnostic_row "FAIL" "iDRAC/IPMI" "connection, authentication, or IPMI-over-LAN failed"
        failures=$((failures + 1))
    fi

    sources="$(normalize_sources)"
    IFS=',' read -r -a source_list <<< "$sources"
    for source in "${source_list[@]}"; do
        output=""
        output="$(temperature_source_method "$source" collect)" || true

        if [[ -n "$output" ]]; then
            diagnostic_row "PASS" "source:${source}" "$(reading_summary "$output")"
            readings="${readings}${readings:+$'\n'}${output}"
        else
            diagnostic_row "FAIL" "source:${source}" "no valid temperature reading"
            failures=$((failures + 1))
        fi
    done

    if [[ -n "$readings" ]] && decision="$(calculate_decision_temperature "$readings")"; then
        IFS=$'\t' read -r temp details <<< "$decision"
        selected="$(choose_fan_speed "$temp")"
        IFS=$'\t' read -r level speed <<< "$selected"
        diagnostic_row "PASS" "decision preview" "${temp}C -> ${level} (${speed}%), no command sent"
        log "DEBUG" "Diagnostic source details: ${details}"
    else
        diagnostic_row "FAIL" "decision preview" "no usable temperature remains"
        failures=$((failures + 1))
    fi

    printf '\nResult: '
    if (( failures == 0 )); then
        printf 'PASS - controller dependencies are ready.\n'
        return 0
    fi

    printf 'FAIL - %s check(s) need attention. Set LOG_LEVEL=DEBUG for command context.\n' "$failures"
    return 1
}

healthcheck_mode() {
    local log_path
    local modified
    local now
    local age
    local max_age

    [[ "$OPERATION_MODE" == "auto" ]] || return 0
    if [[ -z "$LOG_DIR" ]]; then
        log "ERROR" "Healthcheck cannot verify auto mode when LOG_DIR is disabled"
        return 1
    fi

    log_path="${LOG_DIR}/${LOG_FILE}"
    if [[ ! -s "$log_path" ]]; then
        log "ERROR" "Healthcheck has no control-cycle record at ${log_path}"
        return 1
    fi

    if ! modified="$(stat -c '%Y' "$log_path" 2>/dev/null)"; then
        log "ERROR" "Healthcheck cannot read the modification time for ${log_path}"
        return 1
    fi

    now="$(date '+%s')"
    age=$((now - modified))
    (( age < 0 )) && age=0
    max_age="$HEALTHCHECK_MAX_AGE"
    (( max_age == 0 )) && max_age=$((CHECK_INTERVAL * 3 + COMMAND_TIMEOUT))

    if (( age > max_age )); then
        log "ERROR" "Healthcheck control loop is stale: last record ${age}s ago (limit ${max_age}s)"
        return 1
    fi

    log "DEBUG" "Healthcheck passed: last control record ${age}s ago"
}

status_mode() {
    log "INFO" "iDRAC chassis status"
    run_ipmitool chassis status
    printf '\n'
    log "INFO" "iDRAC temperature sensors"
    run_ipmitool sdr type Temperature
}

main() {
    local command="${1:-$OPERATION_MODE}"
    local manual_speed="${2:-}"

    case "$command" in
        help|-h|--help)
            usage
            return 0
            ;;
        config)
            print_effective_config
            return 0
            ;;
        validate)
            validate_config "$OPERATION_MODE" || return 1
            log "INFO" "Configuration is valid for OPERATION_MODE=${OPERATION_MODE}"
            return 0
            ;;
        healthcheck)
            validate_config "$OPERATION_MODE" || return 1
            healthcheck_mode
            return $?
            ;;
        diagnose)
            validate_config "diagnose" || return 1
            diagnose_mode
            return $?
            ;;
        auto|once|manual|restore|status)
            validate_config "$command" || return 1
            ;;
        *)
            log "ERROR" "Unknown command: ${command}"
            usage
            return 1
            ;;
    esac

    case "$command" in
        auto) auto_mode ;;
        once) once_mode ;;
        manual) manual_mode "$manual_speed" ;;
        restore) restore_auto_control ;;
        status) status_mode ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

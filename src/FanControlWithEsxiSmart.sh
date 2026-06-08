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
: "${DRY_RUN:=false}"

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
  ${PROGRAM_NAME} healthcheck          Validate configuration for Docker health checks

The command defaults to OPERATION_MODE when no argument is supplied.
EOF
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(timestamp)" "$level" "$*" >&2
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

command_needs_ipmi() {
    case "$1" in
        auto|once|manual|restore|status) return 0 ;;
        *) return 1 ;;
    esac
}

command_needs_temperature() {
    case "$1" in
        auto|once) return 0 ;;
        *) return 1 ;;
    esac
}

validate_sources() {
    local sources
    local source
    local error=0
    local -a source_list

    sources="$(normalize_sources)"
    if [[ -z "$sources" ]]; then
        log "ERROR" "TEMPERATURE_SOURCES must contain at least one source: esxi, idrac, gpu"
        return 1
    fi

    IFS=',' read -r -a source_list <<< "$sources"
    for source in "${source_list[@]}"; do
        case "$source" in
            esxi|idrac|gpu) ;;
            *)
                log "ERROR" "Unsupported temperature source '${source}'. Use esxi, idrac, or gpu."
                error=1
                ;;
        esac
    done

    return "$error"
}

validate_config() {
    local command="${1:-$OPERATION_MODE}"
    local error=0
    local sources

    case "$command" in
        auto|once|manual|restore|status|validate|healthcheck) ;;
        help|-h|--help) return 0 ;;
        *)
            log "ERROR" "Invalid command or OPERATION_MODE: ${command}"
            error=1
            ;;
    esac

    for bool_name in WITH_GPU_TEMP FAILSAFE_ON_ERROR RESTORE_AUTO_ON_EXIT DRY_RUN; do
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
    validate_integer_range "COMMAND_TIMEOUT" "$COMMAND_TIMEOUT" 1 300 || error=1
    validate_integer_range "SSH_CONNECT_TIMEOUT" "$SSH_CONNECT_TIMEOUT" 1 300 || error=1
    validate_integer_range "IPMI_TIMEOUT" "$IPMI_TIMEOUT" 1 60 || error=1
    validate_integer_range "IPMI_RETRIES" "$IPMI_RETRIES" 0 20 || error=1
    validate_integer_range "GPU_TEMP_OFFSET" "$GPU_TEMP_OFFSET" 0 120 || error=1
    validate_integer_range "HYSTERESIS" "$HYSTERESIS" 0 30 || error=1

    if is_integer "$TEMP_LOW" && is_integer "$TEMP_MEDIUM" && is_integer "$TEMP_HIGH" && is_integer "$TEMP_CRITICAL"; then
        if (( TEMP_LOW >= TEMP_MEDIUM || TEMP_MEDIUM >= TEMP_HIGH || TEMP_HIGH >= TEMP_CRITICAL )); then
            log "ERROR" "Temperature thresholds must increase: TEMP_LOW < TEMP_MEDIUM < TEMP_HIGH < TEMP_CRITICAL"
            error=1
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

        if source_enabled_in_list "esxi" "$sources"; then
            require_value "ESXI_HOST" "$ESXI_HOST" || error=1
            require_value "ESXI_USERNAME" "$ESXI_USERNAME" || error=1
            require_value "DRIVE_DEVICE" "$DRIVE_DEVICE" || error=1
            if [[ -z "$ESXI_PASSWORD" && -z "$ESXI_SSH_KEY" ]]; then
                log "ERROR" "Set ESXI_PASSWORD or ESXI_SSH_KEY when TEMPERATURE_SOURCES includes esxi"
                error=1
            fi
            if [[ -z "$ESXI_SSH_KEY" ]]; then
                require_value "ESXI_PASSWORD" "$ESXI_PASSWORD" || error=1
            elif is_placeholder_value "$ESXI_SSH_KEY"; then
                log "ERROR" "Replace placeholder value for ESXI_SSH_KEY"
                error=1
            fi
            if [[ -n "$ESXI_SSH_KEY" && ! -r "$ESXI_SSH_KEY" ]]; then
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
        fi

        if source_enabled_in_list "gpu" "$sources" && ! is_true "$DRY_RUN"; then
            if ! command -v nvidia-smi >/dev/null 2>&1; then
                log "WARN" "GPU source is enabled but nvidia-smi is not available; fail-safe will be used if no other source succeeds"
            fi
        fi
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

run_esxi_command() {
    local remote_command="$1"
    local ssh_command=(ssh -p "$ESXI_SSH_PORT" -o "StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}" -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}")

    if [[ -n "$ESXI_SSH_KEY" ]]; then
        ssh_command+=(-i "$ESXI_SSH_KEY" -o BatchMode=yes)
    fi

    ssh_command+=("${ESXI_USERNAME}@${ESXI_HOST}" "$remote_command")

    if [[ -n "$ESXI_PASSWORD" && -z "$ESXI_SSH_KEY" ]]; then
        timeout "$COMMAND_TIMEOUT" sshpass -p "$ESXI_PASSWORD" "${ssh_command[@]}"
    else
        timeout "$COMMAND_TIMEOUT" "${ssh_command[@]}"
    fi
}

get_esxi_drive_temperature() {
    local remote_device
    local output
    local temp

    remote_device="$(remote_quote "$DRIVE_DEVICE")"
    if ! output="$(run_esxi_command "esxcli storage core device smart get -d ${remote_device}" 2>/dev/null)"; then
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

    if ! output="$(run_ipmitool sdr type Temperature 2>/dev/null)"; then
        return 1
    fi

    parsed="$(parse_idrac_sdr_temperatures <<< "$output")"
    [[ -n "$parsed" ]] || return 1
    printf '%s\n' "$parsed"
}

get_gpu_temperatures() {
    local output
    local index
    local temp
    local found=1

    command -v nvidia-smi >/dev/null 2>&1 || return 1

    if ! output="$(timeout "$COMMAND_TIMEOUT" nvidia-smi --query-gpu=index,temperature.gpu --format=csv,noheader,nounits 2>/dev/null)"; then
        return 1
    fi

    while IFS=',' read -r index temp; do
        index="$(trim "$index")"
        temp="$(trim "$temp")"
        if is_integer "$temp"; then
            printf 'gpu\tgpu%s\t%s\n' "$index" "$temp"
            found=0
        fi
    done <<< "$output"

    return "$found"
}

collect_temperature_readings() {
    local sources
    local source
    local output
    local found=1
    local -a source_list

    sources="$(normalize_sources)"
    IFS=',' read -r -a source_list <<< "$sources"

    for source in "${source_list[@]}"; do
        case "$source" in
            esxi)
                if output="$(get_esxi_drive_temperature)"; then
                    printf '%s\n' "$output"
                    found=0
                else
                    log "WARN" "ESXi drive temperature read failed"
                fi
                ;;
            idrac)
                if output="$(get_idrac_temperatures)"; then
                    printf '%s\n' "$output"
                    found=0
                else
                    log "WARN" "iDRAC temperature sensor read failed"
                fi
                ;;
            gpu)
                if output="$(get_gpu_temperatures)"; then
                    printf '%s\n' "$output"
                    found=0
                else
                    log "WARN" "GPU temperature read failed"
                fi
                ;;
        esac
    done

    return "$found"
}

get_decision_temperature() {
    local readings
    local source
    local label
    local temp
    local adjusted
    local max_temp=""
    local detail_text=""

    if ! readings="$(collect_temperature_readings)"; then
        return 1
    fi

    while IFS=$'\t' read -r source label temp; do
        [[ -z "${source:-}" || -z "${temp:-}" ]] && continue
        is_integer "$temp" || continue

        adjusted="$temp"
        if [[ "$source" == "gpu" ]]; then
            adjusted=$(( temp - GPU_TEMP_OFFSET ))
            (( adjusted < 0 )) && adjusted=0
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
        validate|healthcheck)
            validate_config "$OPERATION_MODE"
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

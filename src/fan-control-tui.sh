#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_FILE="${ROOT_DIR}/.env.example"
CONFIG_FILE="${FAN_CONTROL_CONFIG:-${ROOT_DIR}/.env}"
CONTROLLER_SCRIPT="${SCRIPT_DIR}/FanControlWithEsxiSmart.sh"

CONFIG_KEYS=(
    IDRAC_IP IDRAC_ID IDRAC_PASSWORD IPMI_INTERFACE IPMI_TIMEOUT IPMI_RETRIES
    OPERATION_MODE CHECK_INTERVAL COMMAND_TIMEOUT DRY_RUN RESTORE_AUTO_ON_EXIT
    TEMPERATURE_SOURCES WITH_GPU_TEMP GPU_TEMP_OFFSET
    IDRAC_SENSOR_INCLUDE_REGEX IDRAC_SENSOR_EXCLUDE_REGEX
    ESXI_HOST ESXI_USERNAME ESXI_PASSWORD ESXI_SSH_KEY ESXI_SSH_PORT
    SSH_CONNECT_TIMEOUT SSH_STRICT_HOST_KEY_CHECKING DRIVE_DEVICE
    LINUX_DISK_DEVICES LINUX_DISK_TEMP_OFFSET LINUX_DISK_NOCHECK
    REMOTE_GPU_HOSTS REMOTE_GPU_USERNAME REMOTE_GPU_PASSWORD REMOTE_GPU_SSH_KEY
    REMOTE_GPU_SSH_PORT REMOTE_GPU_TEMP_OFFSET
    TEMP_LOW TEMP_MEDIUM TEMP_HIGH TEMP_CRITICAL
    FAN_SPEED_IDLE FAN_SPEED_LOW FAN_SPEED_MEDIUM FAN_SPEED_HIGH FAN_SPEED_CRITICAL
    HYSTERESIS FAILSAFE_ON_ERROR FAILSAFE_FAN_SPEED MANUAL_FAN_SPEED
    LOG_DIR LOG_FILE LOG_LEVEL HEALTHCHECK_MAX_AGE
)

if [[ -t 1 && "${NO_COLOR:-}" != "1" ]]; then
    COLOR_BLUE=$'\033[1;34m'
    COLOR_GREEN=$'\033[1;32m'
    COLOR_YELLOW=$'\033[1;33m'
    COLOR_RED=$'\033[1;31m'
    COLOR_DIM=$'\033[2m'
    COLOR_RESET=$'\033[0m'
else
    COLOR_BLUE=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_RED=""
    COLOR_DIM=""
    COLOR_RESET=""
fi

usage() {
    cat <<EOF
iDRAC Fan Control configuration TUI

Usage:
  $(basename "$0") [--config PATH]

Options:
  --config PATH   Edit a specific env file (default: ${CONFIG_FILE})
  -h, --help      Show this help
EOF
}

is_supported_key() {
    local wanted="$1"
    local key

    for key in "${CONFIG_KEYS[@]}"; do
        [[ "$key" == "$wanted" ]] && return 0
    done
    return 1
}

decode_env_value() {
    local value="${1:-}"

    if (( ${#value} >= 2 )) && [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
        value="${value//\\\'/\'}"
    elif (( ${#value} >= 2 )) && [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
        value="${value//\\\"/\"}"
    fi

    printf '%s' "$value"
}

encode_env_value() {
    local value="${1:-}"

    if [[ -z "$value" ]]; then
        printf ''
    elif [[ "$value" =~ ^[[:alnum:]_.,:/@+=%-]+$ ]]; then
        printf '%s' "$value"
    else
        value="${value//\'/\\\'}"
        printf "'%s'" "$value"
    fi
}

config_get() {
    local key="$1"
    local line
    local raw

    is_supported_key "$key" || return 2
    [[ -r "$CONFIG_FILE" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "${key}="* ]]; then
            raw="${line#*=}"
            decode_env_value "$raw"
            return 0
        fi
    done < "$CONFIG_FILE"
    return 1
}

config_set() {
    local key="$1"
    local value="$2"
    local encoded
    local tmp_file
    local line
    local found=false

    is_supported_key "$key" || {
        printf 'Unsupported configuration key: %s\n' "$key" >&2
        return 2
    }
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || {
        printf 'Configuration values cannot contain newlines.\n' >&2
        return 2
    }

    encoded="$(encode_env_value "$value")"
    tmp_file="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "${key}="* ]]; then
            printf '%s=%s\n' "$key" "$encoded" >> "$tmp_file"
            found=true
        else
            printf '%s\n' "$line" >> "$tmp_file"
        fi
    done < "$CONFIG_FILE"

    if [[ "$found" != "true" ]]; then
        printf '\n%s=%s\n' "$key" "$encoded" >> "$tmp_file"
    fi

    chmod 600 "$tmp_file"
    mv -f "$tmp_file" "$CONFIG_FILE"
}

initialize_config() {
    local config_dir

    config_dir="$(dirname "$CONFIG_FILE")"
    mkdir -p "$config_dir"
    config_dir="$(cd "$config_dir" && pwd)"
    CONFIG_FILE="${config_dir}/$(basename "$CONFIG_FILE")"

    if [[ ! -e "$CONFIG_FILE" ]]; then
        cp "$TEMPLATE_FILE" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        printf '%sCreated %s from .env.example.%s\n' "$COLOR_GREEN" "$CONFIG_FILE" "$COLOR_RESET"
    elif [[ ! -f "$CONFIG_FILE" || ! -r "$CONFIG_FILE" || ! -w "$CONFIG_FILE" ]]; then
        printf '%sConfig must be a readable and writable file: %s%s\n' "$COLOR_RED" "$CONFIG_FILE" "$COLOR_RESET" >&2
        return 1
    else
        chmod 600 "$CONFIG_FILE"
    fi
}

screen_clear() {
    if [[ -t 1 && -n "${TERM:-}" && "$TERM" != "dumb" ]]; then
        printf '\033[2J\033[H'
    fi
}

header() {
    screen_clear
    printf '%s╭────────────────────────────────────────────────────────────╮%s\n' "$COLOR_BLUE" "$COLOR_RESET"
    printf '%s│              iDRAC Fan Control · Setup TUI                │%s\n' "$COLOR_BLUE" "$COLOR_RESET"
    printf '%s╰────────────────────────────────────────────────────────────╯%s\n' "$COLOR_BLUE" "$COLOR_RESET"
    printf '%sConfig: %s%s\n\n' "$COLOR_DIM" "$CONFIG_FILE" "$COLOR_RESET"
}

pause_screen() {
    printf '\nPress Enter to continue... '
    IFS= read -r || true
}

notice() {
    printf '%s%s%s\n' "$COLOR_GREEN" "$*" "$COLOR_RESET"
}

warning() {
    printf '%s%s%s\n' "$COLOR_YELLOW" "$*" "$COLOR_RESET"
}

prompt_value() {
    local key="$1"
    local label="$2"
    local required="${3:-false}"
    local current
    local value

    current="$(config_get "$key" 2>/dev/null || true)"
    while true; do
        printf '%s [%s]: ' "$label" "${current:-empty}"
        IFS= read -r value || return 1
        if [[ "$value" == "-" ]]; then
            value=""
        elif [[ -z "$value" ]]; then
            value="$current"
        fi
        if [[ "$required" == "true" && -z "$value" ]]; then
            warning "${label} is required."
            continue
        fi
        config_set "$key" "$value"
        return 0
    done
}

prompt_secret() {
    local key="$1"
    local label="$2"
    local required="${3:-false}"
    local current
    local value
    local state="not set"

    current="$(config_get "$key" 2>/dev/null || true)"
    [[ -n "$current" ]] && state="already set"
    while true; do
        printf '%s [%s; Enter keeps current]: ' "$label" "$state"
        IFS= read -rs value || return 1
        printf '\n'
        if [[ "$value" == "-" ]]; then
            value=""
        elif [[ -z "$value" ]]; then
            value="$current"
        fi
        if [[ "$required" == "true" && -z "$value" ]]; then
            warning "${label} is required."
            continue
        fi
        config_set "$key" "$value"
        return 0
    done
}

prompt_integer() {
    local key="$1"
    local label="$2"
    local minimum="$3"
    local maximum="$4"
    local current
    local value

    current="$(config_get "$key" 2>/dev/null || true)"
    while true; do
        printf '%s (%s-%s) [%s]: ' "$label" "$minimum" "$maximum" "${current:-empty}"
        IFS= read -r value || return 1
        [[ -z "$value" ]] && value="$current"
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= minimum && value <= maximum )); then
            config_set "$key" "$value"
            return 0
        fi
        warning "Enter an integer from ${minimum} to ${maximum}."
    done
}

prompt_boolean() {
    local key="$1"
    local label="$2"
    local current
    local value

    current="$(config_get "$key" 2>/dev/null || true)"
    while true; do
        printf '%s (yes/no) [%s]: ' "$label" "${current:-empty}"
        IFS= read -r value || return 1
        [[ -z "$value" ]] && value="$current"
        case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
            y|yes|true|1|on) config_set "$key" "true"; return 0 ;;
            n|no|false|0|off) config_set "$key" "false"; return 0 ;;
            *) warning "Answer yes or no." ;;
        esac
    done
}

configure_idrac() {
    header
    printf '%siDRAC / IPMI%s\n\n' "$COLOR_BLUE" "$COLOR_RESET"
    prompt_value IDRAC_IP "iDRAC hostname or IP" true
    prompt_value IDRAC_ID "iDRAC username" true
    prompt_secret IDRAC_PASSWORD "iDRAC password" true
    prompt_integer IPMI_TIMEOUT "IPMI per-attempt timeout (seconds)" 1 60
    prompt_integer IPMI_RETRIES "IPMI retry count" 0 20
    notice "iDRAC settings saved."
}

select_sources() {
    local choice
    local sources

    header
    printf '%sTemperature source preset%s\n\n' "$COLOR_BLUE" "$COLOR_RESET"
    printf '  1) iDRAC sensors only                 recommended first setup\n'
    printf '  2) ESXi NVMe SMART only\n'
    printf '  3) Local Linux disk SMART only\n'
    printf '  4) iDRAC + local Linux disk SMART\n'
    printf '  5) iDRAC + local NVIDIA GPU\n'
    printf '  6) Local Linux disk + remote NVIDIA VMs\n'
    printf '  7) Custom source list\n\n'
    while true; do
        printf 'Choose [1-7]: '
        IFS= read -r choice || return 1
        case "$choice" in
            1) sources="idrac" ;;
            2) sources="esxi" ;;
            3) sources="linux_disk" ;;
            4) sources="idrac,linux_disk" ;;
            5) sources="idrac,gpu" ;;
            6) sources="linux_disk,remote_gpu" ;;
            7)
                prompt_value TEMPERATURE_SOURCES "Sources (esxi,idrac,gpu,linux_disk,remote_gpu)" true
                sources="$(config_get TEMPERATURE_SOURCES)"
                ;;
            *) warning "Choose a number from 1 to 7."; continue ;;
        esac
        break
    done

    config_set TEMPERATURE_SOURCES "$sources"
    config_set WITH_GPU_TEMP "false"
    if [[ ",$sources," == *,gpu,* ]]; then
        prompt_integer GPU_TEMP_OFFSET "GPU temperature offset (C)" 0 120
    fi
    if [[ ",$sources," == *,remote_gpu,* ]]; then
        prompt_integer REMOTE_GPU_TEMP_OFFSET "Remote GPU temperature offset (C)" 0 120
    fi
    notice "Temperature sources saved: ${sources}"
}

configure_esxi() {
    header
    printf '%sESXi NVMe SMART source%s\n\n' "$COLOR_BLUE" "$COLOR_RESET"
    prompt_value ESXI_HOST "ESXi hostname or IP" true
    prompt_value ESXI_USERNAME "ESXi SSH username" true
    prompt_integer ESXI_SSH_PORT "ESXi SSH port" 1 65535
    prompt_value ESXI_SSH_KEY "SSH private key path (- clears it; blank keeps current)" false
    if [[ -z "$(config_get ESXI_SSH_KEY 2>/dev/null || true)" ]]; then
        prompt_secret ESXI_PASSWORD "ESXi SSH password" true
    else
        warning "SSH key authentication selected; the password will be ignored."
    fi
    prompt_value DRIVE_DEVICE "Full ESXi storage device identifier" true
    notice "ESXi settings saved."
}

configure_linux_disk() {
    header
    printf '%sLocal Linux disk SMART source%s\n\n' "$COLOR_BLUE" "$COLOR_RESET"
    prompt_value LINUX_DISK_DEVICES "Device paths, comma-separated" true
    prompt_integer LINUX_DISK_TEMP_OFFSET "Disk temperature offset (C)" 0 120
    prompt_value LINUX_DISK_NOCHECK "Power mode check (never/sleep/standby/idle)" true
    notice "Linux disk settings saved. Map each device into the container before diagnostics."
}

configure_remote_gpu() {
    header
    printf '%sRemote NVIDIA GPU source%s\n\n' "$COLOR_BLUE" "$COLOR_RESET"
    prompt_value REMOTE_GPU_HOSTS "GPU VM hostnames or IPs, comma-separated" true
    prompt_value REMOTE_GPU_USERNAME "SSH username shared by GPU VMs" true
    prompt_integer REMOTE_GPU_SSH_PORT "SSH port" 1 65535
    prompt_value REMOTE_GPU_SSH_KEY "SSH private key path (- clears it; blank keeps current)" false
    if [[ -z "$(config_get REMOTE_GPU_SSH_KEY 2>/dev/null || true)" ]]; then
        prompt_secret REMOTE_GPU_PASSWORD "SSH password shared by GPU VMs" true
    else
        warning "SSH key authentication selected; the password will be ignored."
    fi
    prompt_integer REMOTE_GPU_TEMP_OFFSET "Remote GPU temperature offset (C)" 0 120
    notice "Remote GPU settings saved."
}

configure_curve() {
    header
    printf '%sFan curve%s\n' "$COLOR_BLUE" "$COLOR_RESET"
    printf '%sThresholds and speeds must rise from idle to critical.%s\n\n' "$COLOR_DIM" "$COLOR_RESET"
    prompt_integer TEMP_LOW "Low threshold (C)" 0 120
    prompt_integer TEMP_MEDIUM "Medium threshold (C)" 0 120
    prompt_integer TEMP_HIGH "High threshold (C)" 0 120
    prompt_integer TEMP_CRITICAL "Critical threshold (C)" 0 120
    prompt_integer FAN_SPEED_IDLE "Idle fan speed (%)" 1 100
    prompt_integer FAN_SPEED_LOW "Low fan speed (%)" 1 100
    prompt_integer FAN_SPEED_MEDIUM "Medium fan speed (%)" 1 100
    prompt_integer FAN_SPEED_HIGH "High fan speed (%)" 1 100
    prompt_integer FAN_SPEED_CRITICAL "Critical fan speed (%)" 1 100
    notice "Fan curve saved. Use Validate to catch ordering mistakes."
}

configure_safety() {
    local log_level

    header
    printf '%sSafety, timing, and logging%s\n\n' "$COLOR_BLUE" "$COLOR_RESET"
    prompt_integer HYSTERESIS "Downshift hysteresis (C)" 0 30
    prompt_integer CHECK_INTERVAL "Automatic check interval (seconds)" 1 86400
    prompt_integer COMMAND_TIMEOUT "External command timeout (seconds)" 1 300
    prompt_boolean FAILSAFE_ON_ERROR "Apply fail-safe if every source fails"
    prompt_integer FAILSAFE_FAN_SPEED "Fail-safe fan speed (%)" 1 100
    prompt_boolean RESTORE_AUTO_ON_EXIT "Restore Dell automatic control on exit"

    while true; do
        printf 'Log level DEBUG/INFO/WARN/ERROR [%s]: ' "$(config_get LOG_LEVEL 2>/dev/null || printf INFO)"
        IFS= read -r log_level || return 1
        [[ -z "$log_level" ]] && log_level="$(config_get LOG_LEVEL 2>/dev/null || printf INFO)"
        log_level="$(printf '%s' "$log_level" | tr '[:lower:]' '[:upper:]')"
        case "$log_level" in
            DEBUG|INFO|WARN|ERROR) config_set LOG_LEVEL "$log_level"; break ;;
            *) warning "Choose DEBUG, INFO, WARN, or ERROR." ;;
        esac
    done
    notice "Safety and logging settings saved."
}

quick_setup() {
    config_set OPERATION_MODE "auto"
    configure_idrac
    select_sources
    if [[ "$(config_get TEMPERATURE_SOURCES)" == *esxi* ]]; then
        configure_esxi
    fi
    if [[ "$(config_get TEMPERATURE_SOURCES)" == *linux_disk* ]]; then
        configure_linux_disk
    fi
    if [[ "$(config_get TEMPERATURE_SOURCES)" == *remote_gpu* ]]; then
        configure_remote_gpu
    fi
    header
    notice "Quick setup is complete. Run Validate, then Diagnostics before starting auto mode."
    pause_screen
}

masked_state() {
    local value="$1"
    if [[ -n "$value" && "$value" != "change-me" && "$value" != REPLACE_TO_YOUR_* ]]; then
        printf 'set (%s characters)' "${#value}"
    else
        printf 'not set / placeholder'
    fi
}

show_config() {
    local idrac_password
    local esxi_password
    local remote_gpu_password

    header
    idrac_password="$(config_get IDRAC_PASSWORD 2>/dev/null || true)"
    esxi_password="$(config_get ESXI_PASSWORD 2>/dev/null || true)"
    remote_gpu_password="$(config_get REMOTE_GPU_PASSWORD 2>/dev/null || true)"
    printf '%sEffective setup (secrets redacted)%s\n\n' "$COLOR_BLUE" "$COLOR_RESET"
    printf '  %-28s %s\n' "Mode" "$(config_get OPERATION_MODE 2>/dev/null || true)"
    printf '  %-28s %s\n' "Sources" "$(config_get TEMPERATURE_SOURCES 2>/dev/null || true)"
    printf '  %-28s %s@%s\n' "iDRAC" "$(config_get IDRAC_ID 2>/dev/null || true)" "$(config_get IDRAC_IP 2>/dev/null || true)"
    printf '  %-28s %s\n' "iDRAC password" "$(masked_state "$idrac_password")"
    printf '  %-28s %s@%s:%s\n' "ESXi" "$(config_get ESXI_USERNAME 2>/dev/null || true)" "$(config_get ESXI_HOST 2>/dev/null || true)" "$(config_get ESXI_SSH_PORT 2>/dev/null || true)"
    printf '  %-28s %s\n' "ESXi password" "$(masked_state "$esxi_password")"
    printf '  %-28s %s\n' "Drive device" "$(config_get DRIVE_DEVICE 2>/dev/null || true)"
    printf '  %-28s %s\n' "Linux disks" "$(config_get LINUX_DISK_DEVICES 2>/dev/null || true)"
    printf '  %-28s %s@%s:%s\n' "Remote GPU VMs" "$(config_get REMOTE_GPU_USERNAME 2>/dev/null || true)" "$(config_get REMOTE_GPU_HOSTS 2>/dev/null || true)" "$(config_get REMOTE_GPU_SSH_PORT 2>/dev/null || true)"
    printf '  %-28s %s\n' "Remote GPU password" "$(masked_state "$remote_gpu_password")"
    printf '  %-28s %s/%s/%s/%s C\n' "Thresholds" "$(config_get TEMP_LOW)" "$(config_get TEMP_MEDIUM)" "$(config_get TEMP_HIGH)" "$(config_get TEMP_CRITICAL)"
    printf '  %-28s %s/%s/%s/%s/%s %%\n' "Fan speeds" "$(config_get FAN_SPEED_IDLE)" "$(config_get FAN_SPEED_LOW)" "$(config_get FAN_SPEED_MEDIUM)" "$(config_get FAN_SPEED_HIGH)" "$(config_get FAN_SPEED_CRITICAL)"
    printf '  %-28s enabled=%s, %s%%\n' "Fail-safe" "$(config_get FAILSAFE_ON_ERROR)" "$(config_get FAILSAFE_FAN_SPEED)"
    printf '  %-28s %s\n' "Log level" "$(config_get LOG_LEVEL 2>/dev/null || printf INFO)"
    printf '\n%sNo fan command was sent.%s\n' "$COLOR_DIM" "$COLOR_RESET"
    pause_screen
}

load_config_environment() {
    local key
    local value

    for key in "${CONFIG_KEYS[@]}"; do
        if value="$(config_get "$key" 2>/dev/null)"; then
            export "${key}=${value}"
        fi
    done
}

run_controller() {
    local command="$1"

    header
    printf '%sRunning %s...%s\n\n' "$COLOR_BLUE" "$command" "$COLOR_RESET"

    if command -v docker >/dev/null 2>&1 \
        && docker compose version >/dev/null 2>&1 \
        && docker info >/dev/null 2>&1; then
        docker compose -f "${ROOT_DIR}/docker-compose.yml" run --rm --no-deps \
            --env-from-file "$CONFIG_FILE" \
            --volume "${CONTROLLER_SCRIPT}:/usr/local/bin/fan-control-dev.sh:ro" \
            --entrypoint /usr/local/bin/fan-control-dev.sh \
            idrac-fan-control "$command"
    else
        warning "Docker is unavailable; using local binaries for this check."
        (
            load_config_environment
            "$CONTROLLER_SCRIPT" "$command"
        )
    fi
}

run_and_pause() {
    local command="$1"

    if run_controller "$command"; then
        notice "${command} completed successfully."
    else
        warning "${command} reported a problem. Review the output above."
    fi
    pause_screen
}

main_menu() {
    local choice

    while true; do
        header
        printf '  1) Quick setup wizard\n'
        printf '  2) iDRAC / IPMI settings\n'
        printf '  3) Temperature source preset\n'
        printf '  4) ESXi NVMe source settings\n'
        printf '  5) Local Linux disk settings\n'
        printf '  6) Remote NVIDIA GPU settings\n'
        printf '  7) Fan curve\n'
        printf '  8) Safety, timing, and logging\n'
        printf '  9) Review redacted configuration\n'
        printf ' 10) Validate configuration\n'
        printf ' 11) Run read-only diagnostics\n'
        printf '  0) Save and exit\n\n'
        printf 'Choose [0-11]: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) quick_setup ;;
            2) configure_idrac; pause_screen ;;
            3) select_sources; pause_screen ;;
            4) configure_esxi; pause_screen ;;
            5) configure_linux_disk; pause_screen ;;
            6) configure_remote_gpu; pause_screen ;;
            7) configure_curve; pause_screen ;;
            8) configure_safety; pause_screen ;;
            9) show_config ;;
            10) run_and_pause validate ;;
            11) run_and_pause diagnose ;;
            0)
                header
                notice "Saved ${CONFIG_FILE} with mode 600."
                printf 'Next: make validate && docker compose up -d\n'
                return 0
                ;;
            *) warning "Choose a number from 0 to 11."; pause_screen ;;
        esac
    done
}

main() {
    while (( $# > 0 )); do
        case "$1" in
            --config)
                [[ $# -ge 2 ]] || { printf '%s\n' '--config requires a path' >&2; return 2; }
                CONFIG_FILE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                usage >&2
                return 2
                ;;
        esac
    done

    initialize_config
    main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

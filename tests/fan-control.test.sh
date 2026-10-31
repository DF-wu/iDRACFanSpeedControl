#!/usr/bin/env bash
# shellcheck disable=SC2034 # Test globals are consumed by sourced controller functions.

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export LOG_DIR=""
export DRY_RUN=true
export IDRAC_IP=10.0.0.10
export IDRAC_ID=root
export IDRAC_PASSWORD=test-password
export ESXI_HOST=10.0.0.20
export ESXI_USERNAME=root
export ESXI_PASSWORD=test-password
export DRIVE_DEVICE=test-drive
export LINUX_DISK_DEVICES=/dev/nvme1
export REMOTE_GPU_HOSTS=gpu-vm-1
export REMOTE_GPU_USERNAME=root
export REMOTE_GPU_PASSWORD=test-password

# shellcheck source=../src/FanControlWithEsxiSmart.sh
source "${ROOT_DIR}/src/FanControlWithEsxiSmart.sh"

LOG_DIR=""
PASS_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [[ "$expected" != "$actual" ]]; then
        fail "${message}: expected '${expected}', got '${actual}'"
    fi
    pass
}

assert_contains() {
    local needle="$1"
    local haystack="$2"
    local message="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        fail "${message}: expected output to contain '${needle}', got '${haystack}'"
    fi
    pass
}

test_normalize_sources() {
    TEMPERATURE_SOURCES=" esxi, idrac, esxi "
    WITH_GPU_TEMP=false
    assert_eq "esxi,idrac" "$(normalize_sources)" "deduplicates and trims temperature sources"

    TEMPERATURE_SOURCES="idrac"
    WITH_GPU_TEMP=true
    assert_eq "idrac,gpu" "$(normalize_sources)" "WITH_GPU_TEMP appends gpu source"
}

test_temperature_sources_share_complete_interface() {
    local source

    for source in $TEMPERATURE_SOURCE_IDS; do
        temperature_source_interface_complete "$source" || fail "${source} should implement the temperature source interface"
        pass
    done
}

test_hex_formatting() {
    assert_eq "1e" "$(fan_speed_to_hex 30)" "formats 30 percent as IPMI hex"
    assert_eq "64" "$(fan_speed_to_hex 100)" "formats 100 percent as IPMI hex"
    assert_eq "05" "$(fan_speed_to_hex 5)" "pads single digit fan speeds for IPMI raw command"
}

test_fan_speed_failure_restores_automatic_control() {
    local -a commands=()
    local original_run_ipmitool

    original_run_ipmitool="$(declare -f run_ipmitool)"
    DRY_RUN=false
    run_ipmitool() {
        commands+=("$*")
        [[ "$*" != "raw 0x30 0x30 0x02 0xff 0x23" ]]
    }

    set_fan_speed 35 >/dev/null 2>&1 && fail "set_fan_speed should fail when the duty command fails"
    assert_eq "raw 0x30 0x30 0x01 0x00" "${commands[0]}" "enables manual control first"
    assert_eq "raw 0x30 0x30 0x02 0xff 0x23" "${commands[1]}" "attempts the requested duty cycle"
    assert_eq "raw 0x30 0x30 0x01 0x01" "${commands[2]}" "restores Dell automatic control after a partial failure"
    eval "$original_run_ipmitool"
    DRY_RUN=true
}

test_remote_quote_handles_single_quotes() {
    assert_eq "'abc'\\''def'" "$(remote_quote "abc'def")" "quotes ESXi device IDs for remote shell"
}

test_esxi_password_is_not_in_process_arguments() {
    local output

    ESXI_HOST=10.0.0.20
    ESXI_USERNAME=root
    ESXI_PASSWORD='secret with spaces'
    ESXI_SSH_KEY=""
    ESXI_SSH_PORT=22
    timeout() {
        [[ "${SSHPASS:-}" == 'secret with spaces' ]] || return 2
        printf '%s' "$*"
    }

    output="$(run_esxi_command true)"
    assert_contains "sshpass -e" "$output" "passes the ESXi password through SSHPASS"
    if [[ "$output" == *'secret with spaces'* ]]; then
        fail "ESXi password must not be present in the sshpass argument list"
    fi
    pass
}

test_temperature_levels() {
    FAN_SPEED_INTERPOLATION=false
    TEMP_LOW=65
    TEMP_MEDIUM=70
    TEMP_HIGH=75
    TEMP_CRITICAL=80
    FAN_SPEED_IDLE=25
    FAN_SPEED_LOW=30
    FAN_SPEED_MEDIUM=40
    FAN_SPEED_HIGH=50
    FAN_SPEED_CRITICAL=60
    HYSTERESIS=2

    assert_eq $'idle\t25' "$(choose_fan_speed 64)" "uses idle speed below TEMP_LOW"
    assert_eq $'low\t30' "$(choose_fan_speed 65)" "uses low speed at TEMP_LOW"
    assert_eq $'medium\t40' "$(choose_fan_speed 70)" "uses medium speed at TEMP_MEDIUM"
    assert_eq $'high\t50' "$(choose_fan_speed 75)" "uses high speed at TEMP_HIGH"
    assert_eq $'critical\t60' "$(choose_fan_speed 80)" "uses critical speed at TEMP_CRITICAL"
}

test_hysteresis_only_delays_downshift() {
    FAN_SPEED_INTERPOLATION=false
    TEMP_LOW=65
    TEMP_MEDIUM=70
    TEMP_HIGH=75
    TEMP_CRITICAL=80
    HYSTERESIS=2

    assert_eq $'high\t50' "$(choose_fan_speed 74 high)" "keeps previous high level inside hysteresis band"
    assert_eq $'medium\t40' "$(choose_fan_speed 73 high)" "downshifts after leaving hysteresis band"
    assert_eq $'critical\t60' "$(choose_fan_speed 80 high)" "does not delay upshift"
}

test_idrac_sensor_parsing() {
    local input
    local output

    input=$'Inlet Temp       | 04h | ok  |  7.1 | 23 degrees C\nCPU1 Temp        | na  | ns  |  3.1 | No Reading\nExhaust Temp     | 05h | ok  |  7.1 | 41 degrees C'
    IDRAC_SENSOR_INCLUDE_REGEX=""
    IDRAC_SENSOR_EXCLUDE_REGEX="no reading|disabled|not readable"
    output="$(parse_idrac_sdr_temperatures <<< "$input")"

    assert_eq $'idrac\tInlet Temp\t23\nidrac\tExhaust Temp\t41' "$output" "parses readable iDRAC temperature sensors"
}

test_decision_temperature_uses_max_adjusted_source() {
    GPU_TEMP_OFFSET=15
    collect_temperature_readings() {
        printf 'esxi\tdrive0\t65\n'
        printf 'gpu\tgpu0\t90\n'
        printf 'idrac\tInlet Temp\t30\n'
    }

    local decision
    decision="$(get_decision_temperature)"
    assert_contains $'75\t' "$decision" "uses max of disk, iDRAC, and adjusted GPU temperature"
    assert_contains "gpu:gpu0=90C(adjusted=75C)" "$decision" "records adjusted GPU detail"
}

test_decision_temperature_rejects_implausible_readings() {
    local decision

    LINUX_DISK_TEMP_OFFSET=0
    REMOTE_GPU_TEMP_OFFSET=15
    decision="$(calculate_decision_temperature $'linux_disk\tnvme0\t11759\nremote_gpu\tgpu-vm/gpu0\t49')"

    assert_contains $'34\t' "$decision" "ignores an implausible SMART temperature"
    if [[ "$decision" == *"11759"* ]]; then
        fail "implausible readings must not appear in the accepted decision details"
    fi
    pass
}

test_linux_disk_source_collects_multiple_devices_and_accepts_smart_warning_status() {
    local output

    output="$(
        LINUX_DISK_DEVICES='/dev/nvme1, /dev/sdb'
        timeout() {
            shift
            "$@"
        }
        smartctl() {
            case "${*: -1}" in
                /dev/nvme1) printf '{"temperature":73}\n'; return 8 ;;
                /dev/sdb) printf '{"temperature":41}\n' ;;
            esac
        }
        parse_smartctl_temperature() {
            sed -nE 's/.*"temperature":([0-9]+).*/\1/p'
        }
        get_linux_disk_temperatures
    )"

    assert_contains $'linux_disk\tnvme1\t73' "$output" "keeps a valid reading when smartctl reports health status bits"
    assert_contains $'linux_disk\tsdb\t41' "$output" "collects every configured Linux disk"
}

test_smartctl_json_parser_supports_nvme_and_generic_temperature() {
    if ! command -v jq >/dev/null 2>&1; then
        pass
        return
    fi

    assert_eq "73" "$(parse_smartctl_temperature <<< '{"temperature":{"current":73},"nvme_smart_health_information_log":{"temperature":73}}')" "parses generic smartctl temperature.current"
    assert_eq "61" "$(parse_smartctl_temperature <<< '{"nvme_smart_health_information_log":{"temperature":61}}')" "parses the NVMe health log fallback"
}

test_remote_gpu_source_collects_multiple_hosts() {
    local output

    output="$(
        REMOTE_GPU_HOSTS='gpu-vm-1,gpu-vm-2'
        run_ssh_command() {
            local host="$2"
            if [[ "$host" == "gpu-vm-1" ]]; then
                printf '0, 81\n'
            else
                printf '0, 76\n1, 70\n'
            fi
        }
        get_remote_gpu_temperatures
    )"

    assert_contains $'remote_gpu\tgpu-vm-1/gpu0\t81' "$output" "labels a remote GPU with its VM"
    assert_contains $'remote_gpu\tgpu-vm-2/gpu1\t70' "$output" "collects every configured remote GPU VM"
}

test_source_specific_adjustment_is_dispatched_through_interface() {
    local decision

    REMOTE_GPU_TEMP_OFFSET=15
    LINUX_DISK_TEMP_OFFSET=0
    decision="$(calculate_decision_temperature $'linux_disk\tnvme1\t73\nremote_gpu\tgpu-vm/gpu0\t90')"
    assert_contains $'75\t' "$decision" "uses the highest source-adjusted temperature"
    assert_contains "remote_gpu:gpu-vm/gpu0=90C(adjusted=75C)" "$decision" "records remote GPU adjustment details"
}

test_linux_and_remote_sources_validate_configuration() {
    (
        OPERATION_MODE=auto
        TEMPERATURE_SOURCES=linux_disk,remote_gpu
        WITH_GPU_TEMP=false
        DRY_RUN=true
        IDRAC_IP=10.0.0.10
        IDRAC_ID=root
        IDRAC_PASSWORD=test-password
        LINUX_DISK_DEVICES=/dev/nvme1
        REMOTE_GPU_HOSTS=gpu-vm-1,gpu-vm-2
        REMOTE_GPU_USERNAME=monitor
        REMOTE_GPU_PASSWORD=test-password
        REMOTE_GPU_SSH_KEY=""
        validate_config auto >/dev/null 2>&1
    ) || fail "validate_config should accept Linux disk and remote GPU sources"
    pass

    (
        OPERATION_MODE=auto
        TEMPERATURE_SOURCES=linux_disk
        WITH_GPU_TEMP=false
        DRY_RUN=true
        IDRAC_IP=10.0.0.10
        IDRAC_ID=root
        IDRAC_PASSWORD=test-password
        LINUX_DISK_DEVICES='nvme1; touch /tmp/unsafe'
        validate_config auto >/dev/null 2>&1
    ) && fail "validate_config should reject unsafe Linux device paths"
    pass

    (
        OPERATION_MODE=auto
        TEMPERATURE_SOURCES=linux_disk
        WITH_GPU_TEMP=false
        DRY_RUN=true
        IDRAC_IP=10.0.0.10
        IDRAC_ID=root
        IDRAC_PASSWORD=test-password
        LINUX_DISK_DEVICES=/dev/../etc/passwd
        validate_config auto >/dev/null 2>&1
    ) && fail "validate_config should reject parent traversal in Linux device paths"
    pass

    (
        OPERATION_MODE=auto
        TEMPERATURE_SOURCES=linux_disk
        WITH_GPU_TEMP=false
        DRY_RUN=true
        IDRAC_IP=10.0.0.10
        IDRAC_ID=root
        IDRAC_PASSWORD=test-password
        LINUX_DISK_DEVICES=/dev/disk/by-id/nvme-KIOXIA_CD6
        validate_config auto >/dev/null 2>&1
    ) || fail "validate_config should accept nested Linux device paths"
    pass

    (
        OPERATION_MODE=auto
        TEMPERATURE_SOURCES=linux_disk
        WITH_GPU_TEMP=false
        DRY_RUN=true
        IDRAC_IP=10.0.0.10
        IDRAC_ID=root
        IDRAC_PASSWORD=test-password
        LINUX_DISK_DEVICES=/dev/sdb
        LINUX_DISK_NOCHECK=invalid
        validate_config auto >/dev/null 2>&1
    ) && fail "validate_config should reject an invalid smartctl power mode"
    pass
}

test_fail_safe_when_all_sources_fail() {
    FAILSAFE_ON_ERROR=true
    FAILSAFE_FAN_SPEED=70
    LAST_SPEED=""
    LAST_LEVEL=""

    get_decision_temperature() {
        return 1
    }

    set_fan_speed() {
        LAST_SET_SPEED="$1"
    }

    control_cycle >/dev/null 2>&1
    assert_eq "70" "$LAST_SET_SPEED" "applies fail-safe speed when readings fail"
    assert_eq "failsafe" "$LAST_LEVEL" "records fail-safe level"
}

test_validate_accepts_idrac_only_auto_mode() {
    OPERATION_MODE=auto
    TEMPERATURE_SOURCES=idrac
    WITH_GPU_TEMP=false
    DRY_RUN=true
    IDRAC_IP=10.0.0.10
    IDRAC_ID=root
    IDRAC_PASSWORD=test-password
    ESXI_HOST=""
    ESXI_PASSWORD=""
    DRIVE_DEVICE=""

    validate_config auto >/dev/null 2>&1 || fail "validate_config should not require ESXi when TEMPERATURE_SOURCES=idrac"
    pass
}

test_validate_rejects_placeholder_values() {
    (
        OPERATION_MODE=auto
        TEMPERATURE_SOURCES=idrac
        WITH_GPU_TEMP=false
        DRY_RUN=true
        IDRAC_IP=REPLACE_TO_YOUR_IDRAC_IP
        IDRAC_ID=root
        IDRAC_PASSWORD=REPLACE_TO_YOUR_IDRAC_PASSWORD
        validate_config auto >/dev/null 2>&1
    ) && fail "validate_config should reject placeholder iDRAC values"
    pass
}

test_documentation_networks_are_placeholders() {
    is_placeholder_value 192.0.2.10 || fail "RFC 5737 TEST-NET-1 should be treated as a placeholder"
    is_placeholder_value 198.51.100.20 || fail "RFC 5737 TEST-NET-2 should be treated as a placeholder"
    is_placeholder_value 203.0.113.30 || fail "RFC 5737 TEST-NET-3 should be treated as a placeholder"
    pass
}

test_validate_rejects_esxi_password_placeholder() {
    (
        OPERATION_MODE=auto
        TEMPERATURE_SOURCES=esxi
        WITH_GPU_TEMP=false
        DRY_RUN=true
        IDRAC_IP=10.0.0.10
        IDRAC_ID=root
        IDRAC_PASSWORD=test-password
        ESXI_HOST=10.0.0.20
        ESXI_USERNAME=root
        ESXI_PASSWORD=change-me
        ESXI_SSH_KEY=""
        DRIVE_DEVICE=test-drive
        validate_config auto >/dev/null 2>&1
    ) && fail "validate_config should reject placeholder ESXi password when no SSH key is configured"
    pass
}

test_fail_safe_can_be_disabled() {
    FAILSAFE_ON_ERROR=false
    LAST_SET_SPEED=""

    get_decision_temperature() {
        return 1
    }

    set_fan_speed() {
        LAST_SET_SPEED="$1"
    }

    control_cycle >/dev/null 2>&1 && fail "control_cycle should fail when fail-safe is disabled and readings fail"
    assert_eq "" "$LAST_SET_SPEED" "does not set a fan speed when fail-safe is disabled"
}

test_validate_rejects_unsafe_curve_and_transport_values() {
    (
        OPERATION_MODE=auto
        TEMPERATURE_SOURCES=idrac
        WITH_GPU_TEMP=false
        DRY_RUN=true
        IDRAC_IP=10.0.0.10
        IDRAC_ID=root
        IDRAC_PASSWORD=test-password
        ESXI_SSH_PORT=0
        FAN_SPEED_IDLE=40
        FAN_SPEED_LOW=30
        FAN_SPEED_MEDIUM=40
        FAN_SPEED_HIGH=50
        FAN_SPEED_CRITICAL=60
        FAILSAFE_FAN_SPEED=60
        LOG_LEVEL=INFO
        validate_config auto >/dev/null 2>&1
    ) && fail "validate_config should reject a falling fan curve and invalid SSH port"
    pass
}

test_validate_rejects_invalid_log_level_and_regex() {
    (
        OPERATION_MODE=auto
        TEMPERATURE_SOURCES=idrac
        WITH_GPU_TEMP=false
        DRY_RUN=true
        IDRAC_IP=10.0.0.10
        IDRAC_ID=root
        IDRAC_PASSWORD=test-password
        LOG_LEVEL=verbose
        IDRAC_SENSOR_INCLUDE_REGEX='['
        validate_config auto >/dev/null 2>&1
    ) && fail "validate_config should reject invalid debug and sensor filters"
    pass
}

test_restore_only_requires_ipmi_configuration() {
    (
        OPERATION_MODE=auto
        DRY_RUN=true
        IDRAC_IP=10.0.0.10
        IDRAC_ID=root
        IDRAC_PASSWORD=test-password
        FAN_SPEED_LOW=not-a-speed
        TEMP_CRITICAL=not-a-threshold
        validate_config restore >/dev/null 2>&1
    ) || fail "restore should not be blocked by unrelated fan curve values"
    pass
}

test_calculate_decision_temperature_accepts_precollected_readings() {
    local decision

    GPU_TEMP_OFFSET=10
    decision="$(calculate_decision_temperature $'idrac\tInlet\t42\ngpu\tgpu0\t90')"
    assert_contains $'80\t' "$decision" "calculates a decision from diagnostic readings"
    assert_contains "gpu:gpu0=90C(adjusted=80C)" "$decision" "keeps source details in diagnostic preview"
}

test_config_output_redacts_credentials() {
    local output

    IDRAC_IP=10.0.0.10
    IDRAC_PASSWORD=top-secret-password
    ESXI_PASSWORD=another-secret
    REMOTE_GPU_PASSWORD=remote-secret
    output="$(print_effective_config)"
    assert_contains "set (19 characters)" "$output" "shows credential state without values"
    if [[ "$output" == *top-secret-password* || "$output" == *another-secret* || "$output" == *remote-secret* ]]; then
        fail "print_effective_config must never print credentials"
    fi
    pass
}

test_healthcheck_checks_control_loop_freshness() {
    local temp_dir

    temp_dir="$(mktemp -d)"
    (
        OPERATION_MODE=auto
        LOG_DIR="$temp_dir"
        LOG_FILE=fan_control.log
        CHECK_INTERVAL=60
        COMMAND_TIMEOUT=20
        HEALTHCHECK_MAX_AGE=10
        printf 'recent control cycle\n' > "${temp_dir}/fan_control.log"
        healthcheck_mode
    ) || fail "healthcheck should accept a recent control cycle"

    (
        OPERATION_MODE=auto
        LOG_DIR="$temp_dir"
        LOG_FILE=fan_control.log
        CHECK_INTERVAL=1
        COMMAND_TIMEOUT=1
        HEALTHCHECK_MAX_AGE=1
        touch -d @1 "${temp_dir}/fan_control.log"
        healthcheck_mode >/dev/null 2>&1
    ) && fail "healthcheck should reject a stale control cycle"
    rm -rf "$temp_dir"
    pass
}

test_diagnose_reports_read_only_source_and_preview() {
    local output

    output="$(
        OPERATION_MODE=auto
        TEMPERATURE_SOURCES=idrac
        DRY_RUN=false
        IDRAC_IP=10.0.0.10
        IDRAC_ID=root
        IDRAC_PASSWORD=test-password
        LOG_DIR=""
        run_ipmitool() {
            [[ "$*" == "mc info" ]] && printf 'Firmware Revision : 2.60\n'
        }
        get_idrac_temperatures() {
            printf 'idrac\tInlet Temp\t42\n'
        }
        diagnose_mode
    )"
    assert_contains "[PASS] iDRAC/IPMI" "$output" "diagnose checks iDRAC connectivity"
    assert_contains "[PASS] source:idrac" "$output" "diagnose checks each selected source"
    assert_contains "decision preview" "$output" "diagnose previews the fan decision"
}

# Isolate curve settings and hardware stubs while retaining assertion totals.
run_isolated_test() {
    local count
    count="$("$1")"
    PASS_COUNT="$count"
}

interpolation_test_curve() {
    TEMP_LOW=65 TEMP_MEDIUM=70 TEMP_HIGH=75 TEMP_CRITICAL=80
    FAN_SPEED_IDLE=30 FAN_SPEED_LOW=35 FAN_SPEED_MEDIUM=45
    FAN_SPEED_HIGH=60 FAN_SPEED_CRITICAL=65 HYSTERESIS=2
}

test_interpolation_enabled_by_default() {
    local output
    output="$(env -u FAN_SPEED_INTERPOLATION bash -c '
        source "$1"
        TEMP_LOW=65 TEMP_MEDIUM=70 TEMP_HIGH=75 TEMP_CRITICAL=80
        FAN_SPEED_LOW=30 FAN_SPEED_MEDIUM=40 FAN_SPEED_HIGH=50 FAN_SPEED_CRITICAL=60
        choose_fan_speed 72
    ' bash "${ROOT_DIR}/src/FanControlWithEsxiSmart.sh")"
    assert_eq $'medium\t44' "$output" "missing switch enables interpolation"
}

test_interpolation_anchors_rounding_and_bounds() (
    interpolation_test_curve
    FAN_SPEED_INTERPOLATION=true
    local temp level speed previous=0
    local -a cases=(
        '0 idle 30' '64 idle 30' '65 low 35' '66 low 37'
        '69 low 43' '70 medium 45' '71 medium 48' '72 medium 51'
        '73 medium 54' '74 medium 57' '75 high 60' '76 high 61'
        '79 high 64' '80 critical 65' '120 critical 65'
    )
    for fixture in "${cases[@]}"; do
        read -r temp level speed <<< "$fixture"
        assert_eq "${level}"$'\t'"${speed}" "$(choose_fan_speed "$temp" critical)" "interpolates ${temp}C regardless of previous level"
    done
    for ((temp=0; temp<=120; temp++)); do
        IFS=$'\t' read -r level speed <<< "$(choose_fan_speed "$temp")"
        (( speed >= previous && speed >= 30 && speed <= 65 )) || fail "curve must be monotonic and bounded at ${temp}C"
        previous="$speed"
    done
    pass

    TEMP_LOW=10 TEMP_MEDIUM=13 TEMP_HIGH=20 TEMP_CRITICAL=31
    FAN_SPEED_IDLE=1 FAN_SPEED_LOW=1 FAN_SPEED_MEDIUM=2 FAN_SPEED_HIGH=6 FAN_SPEED_CRITICAL=100
    assert_eq $'idle\t1' "$(choose_fan_speed 9)" "preserves minimum idle duty below the first anchor"
    assert_eq $'low\t1' "$(choose_fan_speed 10)" "preserves minimum anchor duty"
    assert_eq $'low\t2' "$(choose_fan_speed 11)" "ceil fractional duty in a three-degree segment"
    assert_eq $'medium\t3' "$(choose_fan_speed 14)" "uses actual uneven segment width"
    assert_eq $'high\t49' "$(choose_fan_speed 25)" "ceil duty in an eleven-degree segment"
    assert_eq $'critical\t100' "$(choose_fan_speed 120)" "clamps to maximum duty"
    TEMP_MEDIUM=14
    assert_eq $'low\t2' "$(choose_fan_speed 12)" "ceil demand at an exact segment midpoint"
    FAN_SPEED_IDLE=100 FAN_SPEED_LOW=100 FAN_SPEED_MEDIUM=100 FAN_SPEED_HIGH=100
    assert_eq $'medium\t100' "$(choose_fan_speed 16)" "accepts flat fan anchors"
    printf '%s\n' "$PASS_COUNT"
)

test_legacy_mode_exact_hysteresis() (
    interpolation_test_curve
    FAN_SPEED_INTERPOLATION=false
    assert_eq $'medium\t45' "$(choose_fan_speed 72)" "disabled interpolation restores stepwise speed"
    assert_eq $'high\t60' "$(choose_fan_speed 74 high)" "legacy retains downshift inside band"
    assert_eq $'medium\t45' "$(choose_fan_speed 73 high)" "legacy releases at exact hysteresis boundary"
    assert_eq $'critical\t65' "$(choose_fan_speed 80 idle)" "legacy never delays upward cooling"
    assert_eq $'low\t35' "$(choose_fan_speed 64 low)" "legacy retains low near idle boundary"
    assert_eq $'idle\t30' "$(choose_fan_speed 63 low)" "legacy releases low at boundary"
    assert_eq $'idle\t30' "$(choose_fan_speed 60 critical)" "legacy supports multi-level downshift"
    printf '%s\n' "$PASS_COUNT"
)

test_interpolation_validation_and_config() (
    interpolation_test_curve
    OPERATION_MODE=auto TEMPERATURE_SOURCES=idrac WITH_GPU_TEMP=false DRY_RUN=true
    FAN_SPEED_INTERPOLATION=invalid
    if validate_config auto >/dev/null 2>&1; then
        fail "reject invalid interpolation boolean"
    fi
    pass
    # Recovery must remain available even if the new curve option is malformed.
    validate_config restore >/dev/null 2>&1 || fail "invalid interpolation must not block restore"
    pass
    FAN_SPEED_INTERPOLATION=true
    validate_config auto >/dev/null 2>&1 || fail "accept enabled interpolation"
    assert_contains 'piecewise linear' "$(print_effective_config)" "effective config identifies interpolation"
    assert_contains 'inactive' "$(print_effective_config)" "effective config explains unused hysteresis"
    FAN_SPEED_INTERPOLATION=false
    validate_config auto >/dev/null 2>&1 || fail "accept disabled interpolation"
    assert_contains 'stepwise' "$(print_effective_config)" "effective config identifies legacy mode"
    printf '%s\n' "$PASS_COUNT"
)

test_control_cycle_interpolation_and_recovery() (
    interpolation_test_curve
    FAN_SPEED_INTERPOLATION=true FAILSAFE_ON_ERROR=true FAILSAFE_FAN_SPEED=70
    LAST_LEVEL=high LAST_SPEED=60
    local reading=74 broken=false
    local -a applied=()
    get_decision_temperature() {
        [[ "$broken" == false ]] || return 1
        printf '%s\ttest sensor\n' "$reading"
    }
    set_fan_speed() { applied+=("$1"); }
    control_cycle >/dev/null 2>&1
    assert_eq 57 "$LAST_SPEED" "control cycle cools down without level hysteresis plateau"
    assert_eq medium "$LAST_LEVEL" "level remains the raw temperature band"
    reading=73
    control_cycle >/dev/null 2>&1
    assert_eq 54 "$LAST_SPEED" "updates speed within the same level"
    reading=74
    control_cycle >/dev/null 2>&1
    assert_eq 57 "$LAST_SPEED" "upward interpolation is immediate within a level"
    control_cycle >/dev/null 2>&1
    assert_eq '57 54 57' "${applied[*]}" "only changed duty sends a command"
    broken=true
    control_cycle >/dev/null 2>&1
    assert_eq 70 "$LAST_SPEED" "all-source failure enters failsafe"
    assert_eq failsafe "$LAST_LEVEL" "records failsafe state"
    broken=false reading=72
    control_cycle >/dev/null 2>&1
    assert_eq 51 "$LAST_SPEED" "recovers from failsafe to interpolated demand"
    assert_eq medium "$LAST_LEVEL" "clears failsafe level after recovery"
    set_fan_speed() { return 1; }
    reading=75
    if control_cycle >/dev/null 2>&1; then fail "failed duty command must fail cycle"; fi
    assert_eq 51 "$LAST_SPEED" "failed command does not overwrite last successful speed"
    assert_eq medium "$LAST_LEVEL" "failed command does not overwrite last successful level"
    set_fan_speed() { applied+=("$1"); }
    FAN_SPEED_INTERPOLATION=false LAST_LEVEL=high LAST_SPEED=60 reading=74
    control_cycle >/dev/null 2>&1
    assert_eq 60 "$LAST_SPEED" "legacy control cycle retains downshift hysteresis"
    reading=73
    control_cycle >/dev/null 2>&1
    assert_eq 45 "$LAST_SPEED" "legacy control cycle releases hysteresis exactly"
    broken=true
    control_cycle >/dev/null 2>&1
    broken=false reading=72
    control_cycle >/dev/null 2>&1
    assert_eq 45 "$LAST_SPEED" "legacy recovers from failsafe without an unknown-level hold"
    printf '%s\n' "$PASS_COUNT"
)

test_diagnose_interpolation_modes() (
    interpolation_test_curve
    OPERATION_MODE=auto TEMPERATURE_SOURCES=idrac WITH_GPU_TEMP=false DRY_RUN=false
    LOG_DIR=""
    local output
    run_ipmitool() {
        [[ "$*" == 'mc info' ]] || fail "diagnose must not send a fan command"
        printf 'Firmware Revision : test\n'
    }
    get_idrac_temperatures() { printf 'idrac\tTest sensor\t72\n'; }
    FAN_SPEED_INTERPOLATION=true
    output="$(diagnose_mode)"
    assert_contains '72C -> medium (51%)' "$output" "diagnose previews interpolated duty"
    assert_contains 'piecewise linear' "$output" "diagnose identifies interpolation mode"
    assert_contains 'inactive' "$output" "diagnose explains inactive hysteresis"
    FAN_SPEED_INTERPOLATION=false
    output="$(diagnose_mode)"
    assert_contains '72C -> medium (45%)' "$output" "diagnose previews legacy duty"
    assert_contains 'stepwise' "$output" "diagnose identifies legacy mode"
    printf '%s\n' "$PASS_COUNT"
)

run_isolated_test test_diagnose_interpolation_modes
test_interpolation_enabled_by_default
run_isolated_test test_interpolation_anchors_rounding_and_bounds
run_isolated_test test_legacy_mode_exact_hysteresis
run_isolated_test test_interpolation_validation_and_config
run_isolated_test test_control_cycle_interpolation_and_recovery
test_normalize_sources
test_temperature_sources_share_complete_interface
test_hex_formatting
test_fan_speed_failure_restores_automatic_control
test_remote_quote_handles_single_quotes
test_esxi_password_is_not_in_process_arguments
test_temperature_levels
test_hysteresis_only_delays_downshift
test_idrac_sensor_parsing
test_decision_temperature_uses_max_adjusted_source
test_decision_temperature_rejects_implausible_readings
test_linux_disk_source_collects_multiple_devices_and_accepts_smart_warning_status
test_smartctl_json_parser_supports_nvme_and_generic_temperature
test_remote_gpu_source_collects_multiple_hosts
test_source_specific_adjustment_is_dispatched_through_interface
test_linux_and_remote_sources_validate_configuration
test_fail_safe_when_all_sources_fail
test_validate_accepts_idrac_only_auto_mode
test_validate_rejects_placeholder_values
test_documentation_networks_are_placeholders
test_validate_rejects_esxi_password_placeholder
test_fail_safe_can_be_disabled
test_validate_rejects_unsafe_curve_and_transport_values
test_validate_rejects_invalid_log_level_and_regex
test_restore_only_requires_ipmi_configuration
test_calculate_decision_temperature_accepts_precollected_readings
test_config_output_redacts_credentials
test_healthcheck_checks_control_loop_freshness
test_diagnose_reports_read_only_source_and_preview

printf 'ok - %s assertions passed\n' "$PASS_COUNT"

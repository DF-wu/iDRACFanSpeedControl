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

test_hex_formatting() {
    assert_eq "1e" "$(fan_speed_to_hex 30)" "formats 30 percent as IPMI hex"
    assert_eq "64" "$(fan_speed_to_hex 100)" "formats 100 percent as IPMI hex"
    assert_eq "05" "$(fan_speed_to_hex 5)" "pads single digit fan speeds for IPMI raw command"
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
    output="$(print_effective_config)"
    assert_contains "set (19 characters)" "$output" "shows credential state without values"
    if [[ "$output" == *top-secret-password* || "$output" == *another-secret* ]]; then
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

test_normalize_sources
test_hex_formatting
test_remote_quote_handles_single_quotes
test_esxi_password_is_not_in_process_arguments
test_temperature_levels
test_hysteresis_only_delays_downshift
test_idrac_sensor_parsing
test_decision_temperature_uses_max_adjusted_source
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

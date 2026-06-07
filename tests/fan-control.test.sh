#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export LOG_DIR=""
export DRY_RUN=true
export IDRAC_IP=192.0.2.10
export IDRAC_ID=root
export IDRAC_PASSWORD=test-password
export ESXI_HOST=192.0.2.20
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
    IDRAC_IP=192.0.2.10
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

test_validate_rejects_esxi_password_placeholder() {
    (
        OPERATION_MODE=auto
        TEMPERATURE_SOURCES=esxi
        WITH_GPU_TEMP=false
        DRY_RUN=true
        IDRAC_IP=192.0.2.10
        IDRAC_ID=root
        IDRAC_PASSWORD=test-password
        ESXI_HOST=192.0.2.20
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

test_normalize_sources
test_hex_formatting
test_remote_quote_handles_single_quotes
test_temperature_levels
test_hysteresis_only_delays_downshift
test_idrac_sensor_parsing
test_decision_temperature_uses_max_adjusted_source
test_fail_safe_when_all_sources_fail
test_validate_accepts_idrac_only_auto_mode
test_validate_rejects_placeholder_values
test_validate_rejects_esxi_password_placeholder
test_fail_safe_can_be_disabled

printf 'ok - %s assertions passed\n' "$PASS_COUNT"

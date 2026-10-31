#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export NO_COLOR=1
export FAN_CONTROL_CONFIG="${TMP_DIR}/.env"

# shellcheck source=../src/fan-control-tui.sh
source "${ROOT_DIR}/src/fan-control-tui.sh"

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

    [[ "$expected" == "$actual" ]] || fail "${message}: expected '${expected}', got '${actual}'"
    pass
}

assert_contains() {
    local needle="$1"
    local haystack="$2"
    local message="$3"

    [[ "$haystack" == *"$needle"* ]] || fail "${message}: missing '${needle}'"
    pass
}

initialize_config

test_config_round_trip_and_preserves_comments() {
    local value
    local raw

    value="p@ss word's \$literal"
    config_set IDRAC_PASSWORD "$value"
    assert_eq "$value" "$(config_get IDRAC_PASSWORD)" "round-trips a quoted password without eval"
    raw="$(sed -n 's/^IDRAC_PASSWORD=//p' "$CONFIG_FILE")"
    assert_contains "'p@ss word\\'s \$literal'" "$raw" "quotes values that would be unsafe in env files"
    assert_contains '# Copy this file to .env' "$(sed -n '1p' "$CONFIG_FILE")" "preserves template comments"
}

test_config_set_does_not_duplicate_keys() {
    local count

    config_set IDRAC_IP 192.0.2.55
    config_set IDRAC_IP 192.0.2.56
    count="$(grep -c '^IDRAC_IP=' "$CONFIG_FILE")"
    assert_eq "1" "$count" "updates an existing key in place"
    assert_eq "192.0.2.56" "$(config_get IDRAC_IP)" "returns the newest value"
}

test_config_rejects_unknown_key_and_newline() {
    if config_set UNKNOWN_KEY value >/dev/null 2>&1; then
        fail "rejects an unknown key"
    fi
    if config_set IDRAC_ID $'root\nunsafe' >/dev/null 2>&1; then
        fail "rejects a multiline value"
    fi
    pass
}

test_sensitive_values_are_only_summarized() {
    assert_eq "set (6 characters)" "$(masked_state secret)" "masks configured secrets"
    assert_eq "not set / placeholder" "$(masked_state change-me)" "flags template placeholders"
}

test_load_config_environment_is_allowlisted() {
    local before

    config_set IDRAC_PASSWORD secret-value
    before="${PATH}"
    load_config_environment
    assert_eq "secret-value" "$IDRAC_PASSWORD" "loads known env keys"
    assert_eq "$before" "$PATH" "does not overwrite unrelated process environment"
}

test_new_source_configuration_round_trips() {
    config_set LINUX_DISK_DEVICES '/dev/nvme1,/dev/sdb'
    config_set REMOTE_GPU_HOSTS 'gpu-vm-1,gpu-vm-2'
    config_set REMOTE_GPU_PASSWORD 'remote secret'

    assert_eq '/dev/nvme1,/dev/sdb' "$(config_get LINUX_DISK_DEVICES)" "round-trips Linux disk devices"
    assert_eq 'gpu-vm-1,gpu-vm-2' "$(config_get REMOTE_GPU_HOSTS)" "round-trips remote GPU hosts"
    assert_eq 'remote secret' "$(config_get REMOTE_GPU_PASSWORD)" "round-trips the remote GPU credential"
    assert_eq 'set (13 characters)' "$(masked_state "$(config_get REMOTE_GPU_PASSWORD)")" "masks the remote GPU credential"
}

test_interpolation_round_trip() {
    assert_eq true "$(config_get FAN_SPEED_INTERPOLATION)" "new configurations enable interpolation"
    configure_curve <<< $'no\n\n\n\n\n\n\n\n\n' >/dev/null
    assert_eq false "$(config_get FAN_SPEED_INTERPOLATION)" "TUI disables interpolation"
    load_config_environment
    assert_eq false "$FAN_SPEED_INTERPOLATION" "controller environment preserves false"
    prompt_boolean FAN_SPEED_INTERPOLATION 'Interpolation' <<< yes >/dev/null
    assert_eq true "$(config_get FAN_SPEED_INTERPOLATION)" "TUI enables interpolation"
    load_config_environment
    assert_eq true "$FAN_SPEED_INTERPOLATION" "controller environment preserves true"
}

test_legacy_config_defaults_to_interpolation() {
    local CONFIG_FILE="${TMP_DIR}/legacy.env"
    local output
    sed '/^FAN_SPEED_INTERPOLATION=/d' "$FAN_CONTROL_CONFIG" > "$CONFIG_FILE"
    output="$(show_config <<< '')"
    assert_eq true "$(awk '/Fan speed interpolation/ {print $NF}' <<< "$output")" "review defaults existing env files to interpolation"
    config_set FAN_SPEED_INTERPOLATION ''
    output="$(show_config <<< '')"
    assert_eq true "$(awk '/Fan speed interpolation/ {print $NF}' <<< "$output")" "review treats an empty switch like the controller default"
    configure_curve <<< $'\n\n\n\n\n\n\n\n\n' >/dev/null
    assert_eq true "$(config_get FAN_SPEED_INTERPOLATION)" "blank TUI input applies default to existing env files"
}

test_legacy_config_defaults_to_interpolation

test_interpolation_round_trip

test_config_round_trip_and_preserves_comments
test_config_set_does_not_duplicate_keys
test_config_rejects_unknown_key_and_newline
test_sensitive_values_are_only_summarized
test_load_config_environment_is_allowlisted
test_new_source_configuration_round_trips

printf 'ok - %s assertions passed\n' "$PASS_COUNT"

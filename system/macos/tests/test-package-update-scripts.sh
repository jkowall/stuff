#!/bin/bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(dirname "$TEST_DIR")"
UPDATER_SCRIPT="${MACOS_DIR}/Update-AllPackages_Mac.sh"
SETUP_SCRIPT="${MACOS_DIR}/Setup-PackageUpdateTasks_Mac.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/package-update-tests.XXXXXX")"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        fail "${message} (expected=${expected}, actual=${actual})"
    fi
}

assert_file_exists() {
    [ -f "$1" ] || fail "Expected file to exist: $1"
}

assert_file_absent() {
    [ ! -e "$1" ] || fail "Expected path to be absent: $1"
}

assert_contains() {
    local file="$1"
    local text="$2"

    grep -F -- "$text" "$file" >/dev/null || fail "Expected ${file} to contain: ${text}"
}

assert_not_contains() {
    local file="$1"
    local text="$2"

    if grep -F -- "$text" "$file" >/dev/null; then
        fail "Expected ${file} not to contain: ${text}"
    fi
}

test_sourcing_does_not_create_log_directory() (
    local fixture_macos_dir="${TEST_ROOT}/hermetic source/system/macos"
    local fixture_updater="${fixture_macos_dir}/Update-AllPackages_Mac.sh"
    local fixture_log_dir="${TEST_ROOT}/hermetic source/system/logs"
    mkdir -p "$fixture_macos_dir"
    cp "$UPDATER_SCRIPT" "$fixture_updater"

    source "$fixture_updater"

    assert_file_absent "$fixture_log_dir"
)

test_summary_exit_codes() (
    source "$UPDATER_SCRIPT"

    local summary_dir="${TEST_ROOT}/summary logs"
    local summary_output="${summary_dir}/summary.out"
    mkdir -p "$summary_dir"
    LOG_FILE="${summary_dir}/updater.log"
    : > "$LOG_FILE"

    SUMMARY_TITLE=""
    show_notification() {
        SUMMARY_TITLE="$1"
    }

    reset_statuses() {
        BREW_STATUS="Success"
        MAS_STATUS="Skipped"
        MACUPDATER_STATUS="Success"
        NPM_STATUS="Success"
        PIP_STATUS="Skipped"
        PIPX_STATUS="Success"
        RUSTUP_STATUS="Success"
        LOG_CLEANUP_STATUS="Success"
    }

    run_summary_case() {
        local expected_status="$1"
        local expected_title="$2"
        local actual_status=0

        SUMMARY_TITLE=""
        if show_summary > "$summary_output"; then
            actual_status=0
        else
            actual_status=$?
        fi

        assert_eq "$expected_status" "$actual_status" "Summary exit status"
        assert_eq "$expected_title" "$SUMMARY_TITLE" "Summary notification title"
    }

    reset_statuses
    run_summary_case "0" "Package Updates Complete"

    reset_statuses
    NPM_STATUS="Warning"
    run_summary_case "2" "Package Updates Completed with Warnings"

    reset_statuses
    BREW_STATUS="Error"
    NPM_STATUS="Warning"
    run_summary_case "1" "Package Updates Completed with Errors"
)

test_host_scoped_log_retention() (
    source "$UPDATER_SCRIPT"

    local fixture_dir="${TEST_ROOT}/logs with spaces"
    local host_a="host-a.local"
    local host_b="host-b.local"
    local day=""
    local log_path=""
    local host_a_logs=()
    local host_b_logs=()
    mkdir -p "$fixture_dir"

    LOG_DIR="$fixture_dir"
    SCRIPT_NAME="Update-AllPackages_Mac"
    MACHINE_NAME="$host_a"

    for day in 01 02 03 04 05; do
        log_path="${LOG_DIR}/${SCRIPT_NAME}_${host_a}_2026-08-${day}_01-00.log"
        : > "$log_path"
        /usr/bin/touch -t "202608${day}0100" "$log_path"
        host_a_logs+=("$log_path")
    done

    for day in 01 02 03 04; do
        log_path="${LOG_DIR}/${SCRIPT_NAME}_${host_b}_2026-07-${day}_01-00.log"
        : > "$log_path"
        /usr/bin/touch -t "202607${day}0100" "$log_path"
        host_b_logs+=("$log_path")
    done

    local unrelated_file="${LOG_DIR}/unrelated updater log.log"
    : > "$unrelated_file"
    LOG_FILE="${host_a_logs[4]}"
    LOG_CLEANUP_STATUS="Skipped"

    cleanup_logs >/dev/null

    local host_a_remaining=("${LOG_DIR}/${SCRIPT_NAME}_${host_a}_"*.log)
    local host_b_remaining=("${LOG_DIR}/${SCRIPT_NAME}_${host_b}_"*.log)
    assert_eq "3" "${#host_a_remaining[@]}" "Current-host retained log count"
    assert_eq "4" "${#host_b_remaining[@]}" "Other-host retained log count"
    assert_file_absent "${host_a_logs[0]}"
    assert_file_absent "${host_a_logs[1]}"
    assert_file_exists "${host_a_logs[2]}"
    assert_file_exists "${host_a_logs[3]}"
    assert_file_exists "${host_a_logs[4]}"
    for log_path in "${host_b_logs[@]}"; do
        assert_file_exists "$log_path"
    done
    assert_file_exists "$unrelated_file"
    assert_eq "Success" "$LOG_CLEANUP_STATUS" "Log cleanup status"
)

test_launchd_rendering() (
    local fake_home="${TEST_ROOT}/home with spaces"
    local mock_bin="${TEST_ROOT}/mock bin"
    local launchctl_calls="${TEST_ROOT}/launchctl.calls"
    mkdir -p "$fake_home" "$mock_bin"
    : > "$launchctl_calls"

    cat > "${mock_bin}/launchctl" <<'MOCK'
#!/bin/bash
for argument in "$@"; do
    printf '%s\t' "$argument"
done >> "$LAUNCHCTL_CALLS"
printf '\n' >> "$LAUNCHCTL_CALLS"
MOCK
    chmod 755 "${mock_bin}/launchctl"

    HOME="$fake_home"
    PATH="${mock_bin}:/usr/bin:/bin:/usr/sbin:/sbin"
    LAUNCHCTL_CALLS="$launchctl_calls"
    export HOME PATH LAUNCHCTL_CALLS
    source "$SETUP_SCRIPT"

    local test_uid
    test_uid="$(id -u)"
    local main_bootstrap="bootstrap"$'\t'"gui/${test_uid}"$'\t'"${PLIST_PATH}"$'\t'
    local pending_bootstrap="bootstrap"$'\t'"gui/${test_uid}"$'\t'"${PENDING_PLIST_PATH}"$'\t'

    mkdir -p "$PLIST_DIR" "$RUNNER_DIR"
    : > "$PENDING_PLIST_PATH"
    : > "$PENDING_FILE"
    : > "$launchctl_calls"
    INTERACTIVE_MODE=0
    install_schedule > "${TEST_ROOT}/default-setup.out"

    /usr/bin/plutil -lint "$PLIST_PATH" >/dev/null
    assert_not_contains "$PLIST_PATH" "<string>--interactive</string>"
    assert_contains "$PLIST_PATH" "<key>Weekday</key>"
    assert_contains "$PLIST_PATH" "<integer>6</integer>"
    assert_contains "$PLIST_PATH" "<key>Hour</key>"
    assert_contains "$PLIST_PATH" "<integer>1</integer>"
    assert_contains "$PLIST_PATH" "<key>Minute</key>"
    assert_contains "$PLIST_PATH" "<integer>0</integer>"
    assert_contains "$PLIST_PATH" "<key>StandardOutPath</key>"
    assert_contains "$PLIST_PATH" "<string>/dev/null</string>"
    assert_contains "$PLIST_PATH" "<string>${LAUNCHD_LOG}</string>"
    assert_file_absent "$PENDING_PLIST_PATH"
    assert_file_absent "$PENDING_FILE"
    assert_contains "$launchctl_calls" "$main_bootstrap"
    assert_not_contains "$launchctl_calls" "$pending_bootstrap"

    : > "$launchctl_calls"
    INTERACTIVE_MODE=1
    install_schedule > "${TEST_ROOT}/interactive-setup.out"

    /usr/bin/plutil -lint "$PLIST_PATH" >/dev/null
    /usr/bin/plutil -lint "$PENDING_PLIST_PATH" >/dev/null
    assert_contains "$PLIST_PATH" "<string>--interactive</string>"
    assert_contains "$PENDING_PLIST_PATH" "<string>--run-pending</string>"
    assert_contains "$PENDING_PLIST_PATH" "<key>RunAtLoad</key>"
    assert_contains "$PENDING_PLIST_PATH" "<true/>"
    assert_contains "$PENDING_PLIST_PATH" "<key>StartInterval</key>"
    assert_contains "$PENDING_PLIST_PATH" "<integer>900</integer>"
    assert_contains "$PENDING_PLIST_PATH" "<key>WatchPaths</key>"
    assert_contains "$PENDING_PLIST_PATH" "<string>${PENDING_FILE}</string>"
    assert_contains "$PENDING_PLIST_PATH" "<string>/dev/null</string>"
    assert_contains "$PENDING_PLIST_PATH" "<string>${LAUNCHD_LOG}</string>"
    assert_contains "$launchctl_calls" "$main_bootstrap"
    assert_contains "$launchctl_calls" "$pending_bootstrap"

    : > "$PENDING_FILE"
    : > "$launchctl_calls"
    INTERACTIVE_MODE=0
    install_schedule > "${TEST_ROOT}/reinstall-setup.out"

    /usr/bin/plutil -lint "$PLIST_PATH" >/dev/null
    assert_not_contains "$PLIST_PATH" "<string>--interactive</string>"
    assert_file_absent "$PENDING_PLIST_PATH"
    assert_file_absent "$PENDING_FILE"
    assert_contains "$launchctl_calls" "$main_bootstrap"
    assert_not_contains "$launchctl_calls" "$pending_bootstrap"
)

assert_contains "$UPDATER_SCRIPT" 'if [ "${BASH_SOURCE[0]}" = "$0" ]; then'
assert_contains "$SETUP_SCRIPT" 'if [ "${BASH_SOURCE[0]}" = "$0" ]; then'
test_sourcing_does_not_create_log_directory
printf 'PASS: updater sourcing has no filesystem writes\n'
test_summary_exit_codes
printf 'PASS: summary exit statuses\n'
test_host_scoped_log_retention
printf 'PASS: host-scoped path-safe log retention\n'
test_launchd_rendering
printf 'PASS: launchd rendering policy\n'

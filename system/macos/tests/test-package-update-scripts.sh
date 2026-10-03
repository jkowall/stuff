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

assert_files_equal() {
    cmp -s "$1" "$2" || fail "Expected files to match: $1 and $2"
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
        CLAUDE_CODE_STATUS="Success"
        CLAUDE_DESKTOP_STATUS="Auto-update"
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

test_claude_code_update_status() (
    source "$UPDATER_SCRIPT"

    local fixture_dir="${TEST_ROOT}/claude update"
    local fake_claude="${fixture_dir}/claude"
    local calls_file="${fixture_dir}/calls"
    mkdir -p "$fixture_dir"
    : > "$calls_file"
    LOG_FILE="${fixture_dir}/updater.log"
    : > "$LOG_FILE"

    cat > "$fake_claude" <<'MOCK'
#!/bin/bash
printf '%s\n' "$1" >> "$CLAUDE_CALLS_FILE"
case "$1" in
    --version)
        printf '2.1.259 (Claude Code)\n'
        ;;
    update)
        if [ "${CLAUDE_UPDATE_FAIL:-0}" -eq 1 ]; then
            printf 'simulated update failure\n' >&2
            exit 1
        fi
        printf 'Claude Code is up to date\n'
        ;;
esac
MOCK
    chmod 755 "$fake_claude"

    CLAUDE_CODE_BINARY="$fake_claude"
    CLAUDE_CALLS_FILE="$calls_file"
    export CLAUDE_CALLS_FILE
    CLAUDE_CODE_STATUS="Skipped"
    update_claude_code > "${fixture_dir}/success.out"

    assert_eq "Success" "$CLAUDE_CODE_STATUS" "Claude Code successful update status"
    assert_contains "$calls_file" "update"
    assert_contains "$calls_file" "--version"

    CLAUDE_UPDATE_FAIL=1
    export CLAUDE_UPDATE_FAIL
    CLAUDE_CODE_STATUS="Skipped"
    if update_claude_code > "${fixture_dir}/failure.out"; then
        fail "Expected Claude Code update failure"
    fi
    assert_eq "Warning" "$CLAUDE_CODE_STATUS" "Claude Code failed update status"
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
    assert_files_equal "$UPDATER_SCRIPT" "$CACHED_UPDATE_SCRIPT"
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

test_run_with_timeout() (
    source "$UPDATER_SCRIPT"
    RUN_WITH_TIMEOUT_KILL_GRACE_SECONDS=2

    local fixture_dir="${TEST_ROOT}/timeout helper"
    mkdir -p "$fixture_dir"
    LOG_FILE="${fixture_dir}/updater.log"
    : > "$LOG_FILE"

    local mode=""
    local rc=0
    local output=""
    local started=0
    local elapsed=0
    local child_pid=""
    local waited=0
    local pid_file="${fixture_dir}/child.pid"
    local stderr_file="${fixture_dir}/stderr"

    for mode in native portable; do
        if [ "$mode" = "portable" ]; then
            RUN_WITH_TIMEOUT_FORCE_PORTABLE=1
        else
            RUN_WITH_TIMEOUT_FORCE_PORTABLE=0
        fi

        rc=0
        output="$(run_with_timeout 5 bash -c 'echo hello; exit 3' </dev/null)" || rc=$?
        assert_eq "3" "$rc" "[${mode}] exit status passes through"
        assert_eq "hello" "$output" "[${mode}] output passes through"

        rc=0
        run_with_timeout 0 bash -c 'exit 7' </dev/null || rc=$?
        assert_eq "7" "$rc" "[${mode}] zero disables the timeout"
        rc=0
        run_with_timeout not-a-number bash -c 'exit 8' </dev/null || rc=$?
        assert_eq "8" "$rc" "[${mode}] non-numeric value disables the timeout"

        rm -f "$pid_file"
        started=$SECONDS
        rc=0
        run_with_timeout 1 bash -c 'sleep 60 & echo $! > "$1"; wait' _ "$pid_file" </dev/null 2>"$stderr_file" || rc=$?
        elapsed=$((SECONDS - started))
        assert_eq "124" "$rc" "[${mode}] timed-out command returns 124"
        [ "$elapsed" -lt 15 ] || fail "[${mode}] timeout took too long to fire (${elapsed}s)"
        assert_contains "$stderr_file" "timed out after 1s"

        child_pid="$(cat "$pid_file")"
        waited=0
        while kill -0 "$child_pid" 2>/dev/null && [ "$waited" -lt 25 ]; do
            sleep 0.2
            waited=$((waited + 1))
        done
        if kill -0 "$child_pid" 2>/dev/null; then
            kill -9 "$child_pid" 2>/dev/null || true
            fail "[${mode}] timeout left a descendant process running"
        fi
    done

    RUN_WITH_TIMEOUT_FORCE_PORTABLE=1
    rc=0
    run_logged_with_timeout 1 bash -c 'echo started; sleep 30' </dev/null >/dev/null || rc=$?
    assert_eq "124" "$rc" "Logged timeout returns 124"
    assert_contains "$LOG_FILE" "started"
    assert_contains "$LOG_FILE" "timed out after 1s"
)

test_phase_timeout_sets_error_status() (
    source "$UPDATER_SCRIPT"

    local fixture_dir="${TEST_ROOT}/phase timeout"
    local mock_bin="${fixture_dir}/bin"
    mkdir -p "$mock_bin"
    LOG_FILE="${fixture_dir}/updater.log"
    : > "$LOG_FILE"

    cat > "${mock_bin}/mas" <<'MOCK'
#!/bin/bash
sleep 30
MOCK
    chmod 755 "${mock_bin}/mas"

    PATH="${mock_bin}:${PATH}"
    UPDATE_COMMAND_TIMEOUT_SECONDS=1
    RUN_WITH_TIMEOUT_KILL_GRACE_SECONDS=2
    MAS_STATUS="Skipped"
    update_mas >/dev/null </dev/null

    assert_eq "Error" "$MAS_STATUS" "Timed-out phase status"
    assert_contains "$LOG_FILE" "mas upgrade timed out after 1s"
)

test_run_phase_messages() (
    source "$UPDATER_SCRIPT"

    local fixture_dir="${TEST_ROOT}/phase messages"
    mkdir -p "$fixture_dir"
    LOG_FILE="${fixture_dir}/updater.log"
    : > "$LOG_FILE"

    notable_phase() {
        log "Info" "============================================================"
        log "Info" "Checking things"
        log "Success" "Everything is fine"
        log "Info" "trailing detail"
    }
    quiet_phase() {
        log "Info" "STARTING THING"
        log "Info" "thing not installed. Skipping."
        log "Info" "============================================================"
    }

    run_phase PHASE_RESULT notable_phase >/dev/null
    assert_eq "Everything is fine" "$PHASE_RESULT" "Phase message prefers the last Success/Warning/Error line"
    run_phase PHASE_RESULT quiet_phase >/dev/null
    assert_eq "thing not installed. Skipping." "$PHASE_RESULT" "Phase message falls back to the last Info line"
)

test_last_run_json() (
    source "$UPDATER_SCRIPT"

    local fixture_dir="${TEST_ROOT}/last run"
    mkdir -p "$fixture_dir"
    LOG_DIR="$fixture_dir"
    SCRIPT_DIR="$MACOS_DIR"
    SCRIPT_NAME="Update-AllPackages_Mac"
    MACHINE_NAME="host-a.local"
    LOG_FILE="${fixture_dir}/updater.log"
    : > "$LOG_FILE"

    BREW_STATUS="Success"
    BREW_MESSAGE=$'Homebrew "quoted" back\\slash\ttab caf\xc3\xa9'
    MAS_STATUS="Skipped"
    MAS_MESSAGE=""
    MACUPDATER_STATUS="Success"
    MACUPDATER_MESSAGE="MacUpdater found no non-MAS app updates."
    NPM_STATUS="Warning"
    NPM_MESSAGE=$'first line\nsecond line'
    CLAUDE_CODE_STATUS="Success"
    CLAUDE_CODE_MESSAGE="ok"
    CLAUDE_DESKTOP_STATUS="Auto-update"
    CLAUDE_DESKTOP_MESSAGE="ok"
    PIP_STATUS="Skipped"
    PIP_MESSAGE="ok"
    PIPX_STATUS="Success"
    PIPX_MESSAGE="ok"
    RUSTUP_STATUS="Success"
    RUSTUP_MESSAGE="ok"
    LOG_CLEANUP_STATUS="Success"
    LOG_CLEANUP_MESSAGE="ok"

    local json_path="${LOG_DIR}/Update-AllPackages_Mac_host-a.local_last-run.json"
    write_last_run_json 2 "2026-10-03T09:46:13Z" "2026-10-03T09:46:39Z"

    assert_file_exists "$json_path"
    assert_file_absent "${json_path}.tmp"

    local expected_sha=""
    expected_sha="$(file_sha256 "$UPDATER_SCRIPT")"
    EXPECTED_BREW_MESSAGE="$BREW_MESSAGE" EXPECTED_NPM_MESSAGE="$NPM_MESSAGE" \
        EXPECTED_SHA="$expected_sha" EXPECTED_LOG_FILE="$LOG_FILE" EXPECTED_SOURCE="${MACOS_DIR}/Update-AllPackages_Mac.sh" \
        python3 - "$json_path" <<'PY' || fail "last-run JSON content check failed"
import json
import os
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

assert data["schemaVersion"] == 1
assert data["script"] == "Update-AllPackages_Mac"
assert data["machine"] == "host-a.local"
assert data["startedAtUtc"] == "2026-10-03T09:46:13Z"
assert data["updatesCompletedAtUtc"] == "2026-10-03T09:46:39Z"
assert data["exitCode"] == 2 and isinstance(data["exitCode"], int)
assert data["outcome"] == "warning"
assert data["logFile"] == os.environ["EXPECTED_LOG_FILE"]
assert data["source"]["path"] == os.environ["EXPECTED_SOURCE"]
assert data["source"]["sha256"] == os.environ["EXPECTED_SHA"] and len(data["source"]["sha256"]) == 64
assert list(data["phases"]) == [
    "Brew", "Mas", "MacUpdater", "Npm", "ClaudeCode",
    "ClaudeDesktop", "Pip", "Pipx", "Rustup", "LogCleanup",
]
assert data["phases"]["Brew"] == {"status": "Success", "message": os.environ["EXPECTED_BREW_MESSAGE"]}
assert data["phases"]["Npm"] == {"status": "Warning", "message": os.environ["EXPECTED_NPM_MESSAGE"]}
assert data["phases"]["Mas"] == {"status": "Skipped", "message": ""}
PY

    local code=""
    local expected_outcome=""
    local actual_outcome=""
    for code in 0 1 2; do
        case "$code" in
            0) expected_outcome="clean" ;;
            1) expected_outcome="error" ;;
            2) expected_outcome="warning" ;;
        esac
        write_last_run_json "$code" "2026-10-03T09:46:13Z" "2026-10-03T09:46:39Z"
        actual_outcome="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["outcome"])' "$json_path")"
        assert_eq "$expected_outcome" "$actual_outcome" "Outcome for exit code ${code}"
    done
)

test_pip_skips_bulk_upgrades() (
    source "$UPDATER_SCRIPT"

    local fixture_dir="${TEST_ROOT}/pip skip"
    local mock_bin="${fixture_dir}/bin"
    local calls_file="${fixture_dir}/pip3.calls"
    mkdir -p "$mock_bin"
    : > "$calls_file"
    LOG_FILE="${fixture_dir}/updater.log"
    : > "$LOG_FILE"

    cat > "${mock_bin}/pip3" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$PIP3_CALLS_FILE"
MOCK
    chmod 755 "${mock_bin}/pip3"

    PATH="${mock_bin}:${PATH}"
    PIP3_CALLS_FILE="$calls_file"
    export PIP3_CALLS_FILE
    PIP_STATUS="Success"
    update_pip >/dev/null

    assert_eq "Skipped" "$PIP_STATUS" "pip bulk update status"
    [ ! -s "$calls_file" ] || fail "update_pip must not invoke pip3 (calls: $(cat "$calls_file"))"
)

test_uv_tool_fallback_without_pipx() (
    source "$UPDATER_SCRIPT"

    local fixture_dir="${TEST_ROOT}/uv fallback"
    local mock_bin="${fixture_dir}/bin"
    local calls_file="${fixture_dir}/uv.calls"
    mkdir -p "$mock_bin"
    : > "$calls_file"
    LOG_FILE="${fixture_dir}/updater.log"
    : > "$LOG_FILE"

    cat > "${mock_bin}/uv" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$UV_CALLS_FILE"
MOCK
    chmod 755 "${mock_bin}/uv"

    PATH="${mock_bin}:/usr/bin:/bin"
    if command -v pipx >/dev/null 2>&1; then
        printf 'SKIP: pipx is installed in the base PATH; cannot test the uv fallback here\n'
        return 0
    fi

    UV_CALLS_FILE="$calls_file"
    export UV_CALLS_FILE
    PIPX_STATUS="Skipped"
    update_pipx >/dev/null </dev/null

    assert_eq "Success" "$PIPX_STATUS" "uv fallback status"
    assert_contains "$calls_file" "tool upgrade --all"
)

assert_contains "$UPDATER_SCRIPT" 'if [ "${BASH_SOURCE[0]}" = "$0" ]; then'
assert_contains "$SETUP_SCRIPT" 'if [ "${BASH_SOURCE[0]}" = "$0" ]; then'
assert_contains "$UPDATER_SCRIPT" 'managed_packages.add("@anthropic-ai/claude-code")'
assert_not_contains "$UPDATER_SCRIPT" '@anthropic-ai/claude-code@next'
test_sourcing_does_not_create_log_directory
printf 'PASS: updater sourcing has no filesystem writes\n'
test_summary_exit_codes
printf 'PASS: summary exit statuses\n'
test_claude_code_update_status
printf 'PASS: Claude Code native update statuses\n'
test_host_scoped_log_retention
printf 'PASS: host-scoped path-safe log retention\n'
test_run_with_timeout
printf 'PASS: timeout helper (native and portable paths)\n'
test_phase_timeout_sets_error_status
printf 'PASS: timed-out phase reports Error\n'
test_run_phase_messages
printf 'PASS: phase message capture\n'
test_last_run_json
printf 'PASS: last-run JSON\n'
assert_not_contains "$UPDATER_SCRIPT" 'pip3 install'
assert_not_contains "$UPDATER_SCRIPT" 'pip3 list'
test_pip_skips_bulk_upgrades
printf 'PASS: pip bulk upgrades stay skipped\n'
test_uv_tool_fallback_without_pipx
printf 'PASS: uv tool fallback\n'
if [ -x /usr/bin/plutil ]; then
    test_launchd_rendering
    printf 'PASS: launchd rendering policy\n'
else
    printf 'SKIP: launchd rendering policy (needs macOS plutil)\n'
fi

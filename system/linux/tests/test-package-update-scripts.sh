#!/bin/bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_DIR="$(dirname "$TEST_DIR")"
UPDATER_SCRIPT="${LINUX_DIR}/Update-AllPackages_Linux.sh"
SETUP_SCRIPT="${LINUX_DIR}/Setup-PackageUpdateTasks_Linux.sh"
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
    local fixture_linux_dir="${TEST_ROOT}/hermetic source/system/linux"
    local fixture_updater="${fixture_linux_dir}/Update-AllPackages_Linux.sh"
    local fixture_log_dir="${TEST_ROOT}/hermetic source/system/logs"
    mkdir -p "$fixture_linux_dir"
    cp "$UPDATER_SCRIPT" "$fixture_updater"

    source "$fixture_updater"

    assert_file_absent "$fixture_log_dir"
)

test_summary_notifications() (
    source "$UPDATER_SCRIPT"

    local summary_dir="${TEST_ROOT}/summary logs"
    mkdir -p "$summary_dir"
    LOG_FILE="${summary_dir}/updater.log"
    : > "$LOG_FILE"

    SUMMARY_TITLE=""
    SUMMARY_TYPE=""
    show_notification() {
        SUMMARY_TITLE="$1"
        SUMMARY_TYPE="$3"
    }

    reset_statuses() {
        APT_STATUS="Success"
        SNAP_STATUS="Skipped"
        FLATPAK_STATUS="Skipped"
        NPM_STATUS="Success"
        CLAUDE_CODE_STATUS="Success"
        PIP_STATUS="Skipped"
        RUSTUP_STATUS="Success"
    }

    reset_statuses
    show_summary > "${summary_dir}/summary-success.out"
    assert_eq "Package Updates Completed" "$SUMMARY_TITLE" "All-success summary notification title"
    assert_eq "normal" "$SUMMARY_TYPE" "All-success summary notification type"

    reset_statuses
    CLAUDE_CODE_STATUS="Warning"
    SUMMARY_TITLE=""
    show_summary > "${summary_dir}/summary-warning.out"
    assert_eq "Package Updates Completed" "$SUMMARY_TITLE" "A Warning status alone still reports Completed (no dedicated warning tier, unlike macOS)"

    reset_statuses
    CLAUDE_CODE_STATUS="Error"
    SUMMARY_TITLE=""
    show_summary > "${summary_dir}/summary-error.out"
    assert_eq "Package Updates Completed with Errors" "$SUMMARY_TITLE" "Error summary notification title"
    assert_eq "critical" "$SUMMARY_TYPE" "Error summary notification type"
)

test_claude_code_update_status() (
    source "$UPDATER_SCRIPT"

    local fixture_dir="${TEST_ROOT}/claude update"
    local mock_bin="${fixture_dir}/mock-bin"
    local fake_claude="${fixture_dir}/claude"
    local calls_file="${fixture_dir}/calls"
    local sudo_calls_file="${fixture_dir}/sudo-calls"
    mkdir -p "$mock_bin"
    : > "$calls_file"
    : > "$sudo_calls_file"
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

    # A minimal `sudo` stand-in: it records exactly how it was invoked, then
    # strips a leading "-u <user>" and runs the rest directly. This lets the
    # test assert update_claude_code always runs as the target user (never
    # root) without needing real sudo/root privileges.
    cat > "${mock_bin}/sudo" <<'MOCK'
#!/bin/bash
{
    for arg in "$@"; do printf '%s\t' "$arg"; done
    printf '\n'
} >> "$SUDO_CALLS_FILE"

if [ "$1" = "-u" ]; then
    shift 2
fi

"$@"
MOCK
    chmod 755 "${mock_bin}/sudo"

    PATH="${mock_bin}:${PATH}"
    export PATH
    CLAUDE_CALLS_FILE="$calls_file"
    SUDO_CALLS_FILE="$sudo_calls_file"
    export CLAUDE_CALLS_FILE SUDO_CALLS_FILE

    CLAUDE_CODE_BINARY="$fake_claude"
    SUDO_USER="jkowall"

    CLAUDE_CODE_STATUS="Skipped"
    update_claude_code > "${fixture_dir}/success.out"

    assert_eq "Success" "$CLAUDE_CODE_STATUS" "Claude Code successful update status"
    assert_contains "$calls_file" "update"
    assert_contains "$calls_file" "--version"
    assert_contains "$sudo_calls_file" "jkowall"

    CLAUDE_UPDATE_FAIL=1
    export CLAUDE_UPDATE_FAIL
    CLAUDE_CODE_STATUS="Skipped"
    : > "$sudo_calls_file"
    if update_claude_code > "${fixture_dir}/failure.out"; then
        fail "Expected Claude Code update failure"
    fi
    assert_eq "Warning" "$CLAUDE_CODE_STATUS" "Claude Code failed update status"
    unset CLAUDE_UPDATE_FAIL

    # Regression guard for the actual bug found in production: this script
    # self-elevates to root for apt/snap/etc, but root's $HOME is /root, not
    # the invoking user's home. Without a resolved non-root SUDO_USER, the
    # update must be skipped outright rather than silently targeting the
    # wrong (root) account -- the same class of bug that left WSL's
    # Claude Code install permanently un-updated.
    SUDO_USER=""
    : > "$sudo_calls_file"
    CLAUDE_CODE_STATUS="Skipped"
    update_claude_code > "${fixture_dir}/no-user.out"
    assert_eq "Skipped" "$CLAUDE_CODE_STATUS" "Claude Code update without SUDO_USER is skipped, not misrouted to root"
    if [ -s "$sudo_calls_file" ]; then
        fail "Expected no sudo invocation when SUDO_USER is unset"
    fi

    SUDO_USER="root"
    CLAUDE_CODE_STATUS="Skipped"
    update_claude_code > "${fixture_dir}/root-user.out"
    assert_eq "Skipped" "$CLAUDE_CODE_STATUS" "Claude Code update invoked directly as root is skipped, not misrouted"
)

test_host_scoped_log_retention() (
    source "$UPDATER_SCRIPT"

    local fixture_dir="${TEST_ROOT}/log-retention"
    local host_a="host-a"
    local host_b="host-b"
    local day=""
    local log_path=""
    local host_a_logs=()
    local host_b_logs=()
    mkdir -p "$fixture_dir"

    LOG_DIR="$fixture_dir"
    SCRIPT_NAME="Update-AllPackages_Linux"
    MACHINE_NAME="$host_a"

    for day in 01 02 03 04 05; do
        log_path="${LOG_DIR}/${SCRIPT_NAME}_${host_a}_2026-08-${day}_01-00.log"
        : > "$log_path"
        touch -t "202608${day}0100" "$log_path"
        host_a_logs+=("$log_path")
    done

    for day in 01 02 03 04; do
        log_path="${LOG_DIR}/${SCRIPT_NAME}_${host_b}_2026-07-${day}_01-00.log"
        : > "$log_path"
        touch -t "202607${day}0100" "$log_path"
        host_b_logs+=("$log_path")
    done

    local unrelated_file="${LOG_DIR}/unrelated-updater.log"
    : > "$unrelated_file"
    LOG_FILE="${host_a_logs[4]}"

    cleanup_logs >/dev/null

    local host_a_remaining=("${LOG_DIR}/${SCRIPT_NAME}_${host_a}_"*.log)
    local host_b_remaining=("${LOG_DIR}/${SCRIPT_NAME}_${host_b}_"*.log)
    assert_eq "3" "${#host_a_remaining[@]}" "Current-host retained log count"
    assert_eq "4" "${#host_b_remaining[@]}" "Other-host retained log count (untouched)"
    assert_file_absent "${host_a_logs[0]}"
    assert_file_absent "${host_a_logs[1]}"
    assert_file_exists "${host_a_logs[2]}"
    assert_file_exists "${host_a_logs[3]}"
    assert_file_exists "${host_a_logs[4]}"
    for log_path in "${host_b_logs[@]}"; do
        assert_file_exists "$log_path"
    done
    assert_file_exists "$unrelated_file"
)

test_cron_rendering() (
    source "$SETUP_SCRIPT"

    local fixture_dir="${TEST_ROOT}/cron-fixture"
    local mock_bin="${fixture_dir}/mock-bin"
    local crontab_calls="${fixture_dir}/crontab.calls"
    local crontab_state="${fixture_dir}/crontab-state"
    mkdir -p "$mock_bin" "$crontab_state" "${fixture_dir}/etc-cron-d"
    : > "$crontab_calls"

    # A minimal `crontab` stand-in backed by one flat file per user, enough
    # to exercise cleanup_legacy_crontabs' list/rewrite/remove calls without
    # touching the real system crontab.
    cat > "${mock_bin}/crontab" <<'MOCK'
#!/bin/bash
{
    for arg in "$@"; do printf '%s\t' "$arg"; done
    printf '\n'
} >> "$CRONTAB_CALLS_FILE"

mkdir -p "$CRONTAB_STATE_DIR"

case "$1" in
    -l)
        user="$3"
        state_file="${CRONTAB_STATE_DIR}/${user}.crontab"
        if [ -f "$state_file" ]; then
            cat "$state_file"
        else
            exit 1
        fi
        ;;
    -u)
        user="$2"
        if [ "${3:-}" = "-" ]; then
            cat > "${CRONTAB_STATE_DIR}/${user}.crontab"
        fi
        ;;
    -r)
        user="$3"
        rm -f "${CRONTAB_STATE_DIR}/${user}.crontab"
        ;;
esac
MOCK
    chmod 755 "${mock_bin}/crontab"

    PATH="${mock_bin}:${PATH}"
    export PATH
    CRONTAB_CALLS_FILE="$crontab_calls"
    CRONTAB_STATE_DIR="$crontab_state"
    export CRONTAB_CALLS_FILE CRONTAB_STATE_DIR

    CRON_FILE="${fixture_dir}/etc-cron-d/weekly-package-updates"

    # Seed a legacy root crontab entry (old self-scheduling pattern) to
    # verify install_schedule cleans it up alongside an unrelated entry.
    printf '0 3 * * 0 /bin/bash %s\n0 9 * * 1 /usr/bin/true\n' "$UPDATE_SCRIPT" > "${crontab_state}/root.crontab"

    install_schedule > "${fixture_dir}/install.out"

    assert_file_exists "$CRON_FILE"
    assert_contains "$CRON_FILE" "$CRON_SCHEDULE"
    assert_contains "$CRON_FILE" "root /bin/bash"
    assert_contains "$CRON_FILE" "$UPDATE_SCRIPT"
    assert_contains "$CRON_FILE" "SHELL=/bin/bash"
    assert_not_contains "${crontab_state}/root.crontab" "$UPDATE_SCRIPT"
    assert_contains "${crontab_state}/root.crontab" "/usr/bin/true"

    remove_schedule > "${fixture_dir}/remove.out"
    assert_file_absent "$CRON_FILE"
)

test_pip_never_bulk_upgrades() (
    source "$UPDATER_SCRIPT"

    local fixture_dir="${TEST_ROOT}/pip-tooling"
    local mock_bin="${fixture_dir}/mock-bin"
    local calls_file="${fixture_dir}/calls"
    mkdir -p "$mock_bin"
    LOG_FILE="${fixture_dir}/updater.log"
    : > "$LOG_FILE"

    cat > "${mock_bin}/python3" <<'MOCK'
#!/bin/bash
printf 'python3 %s\n' "$*" >> "$CALLS_FILE"
case "$1" in
    -c)
        [ "${PIP_EXT_MANAGED:-0}" -eq 1 ]
        exit $?
        ;;
    -m)
        if [ "$3" = "install" ]; then
            exit "${PIP_RC:-0}"
        fi
        exit 0
        ;;
esac
MOCK
    cat > "${mock_bin}/pipx" <<'MOCK'
#!/bin/bash
printf 'pipx %s\n' "$*" >> "$CALLS_FILE"
exit "${PIPX_RC:-0}"
MOCK
    cat > "${mock_bin}/uv" <<'MOCK'
#!/bin/bash
printf 'uv %s\n' "$*" >> "$CALLS_FILE"
exit "${UV_RC:-0}"
MOCK
    chmod 755 "${mock_bin}/python3" "${mock_bin}/pipx" "${mock_bin}/uv"

    PATH="${mock_bin}:${PATH}"
    CALLS_FILE="$calls_file"
    export PATH CALLS_FILE
    SUDO_USER=""

    AVAILABLE_TOOLS="pipx uv"
    tool_available() { [[ " $AVAILABLE_TOOLS " == *" $1 "* ]]; }

    run_pip() {
        : > "$calls_file"
        PIP_STATUS="Skipped"
        PHASE_MESSAGES=()
        update_pip > "${fixture_dir}/run.out" || true
    }

    # PEP 668 system Python: no pip install at all, pipx handles tools.
    PIP_EXT_MANAGED=1 PIP_RC=0 PIPX_RC=0 run_pip
    assert_eq "Success" "$PIP_STATUS" "Externally-managed Python with healthy pipx"
    assert_not_contains "$calls_file" "install"
    assert_contains "$calls_file" "pipx upgrade-all"

    # Writable Python: only pip itself is upgraded, never a bulk list/upgrade.
    PIP_EXT_MANAGED=0 PIP_RC=0 PIPX_RC=0 run_pip
    assert_eq "Success" "$PIP_STATUS" "Writable Python self-upgrade status"
    assert_contains "$calls_file" "python3 -m pip install --upgrade pip"
    assert_not_contains "$calls_file" "--break-system-packages"
    assert_not_contains "$calls_file" "outdated"

    # A failed pip self-upgrade must surface even though the output is piped through tee.
    PIP_EXT_MANAGED=0 PIP_RC=1 PIPX_RC=0 run_pip
    assert_eq "Error" "$PIP_STATUS" "pip self-upgrade failure must not be masked by tee"
    assert_contains "$LOG_FILE" "pip self-upgrade failed with exit code 1"

    # A failed pipx upgrade is a warning and keeps the pip result.
    PIP_EXT_MANAGED=1 PIPX_RC=3 run_pip
    assert_eq "Warning" "$PIP_STATUS" "pipx failure status"

    # Without pipx, uv is used.
    AVAILABLE_TOOLS="uv"
    PIP_EXT_MANAGED=1 UV_RC=0 run_pip
    assert_eq "Success" "$PIP_STATUS" "uv fallback status"
    assert_contains "$calls_file" "uv tool upgrade --all"
    assert_not_contains "$calls_file" "pipx"

    # Without pipx or uv, nothing is bulk-upgraded.
    AVAILABLE_TOOLS=""
    PIP_EXT_MANAGED=1 run_pip
    assert_not_contains "$calls_file" "install"
    assert_not_contains "$calls_file" "uv"
)

test_run_with_timeout_terminates_commands() (
    source "$UPDATER_SCRIPT"

    local fixture_dir="${TEST_ROOT}/timeout"
    mkdir -p "$fixture_dir"
    LOG_FILE="${fixture_dir}/updater.log"
    : > "$LOG_FILE"
    PACKAGE_UPDATE_KILL_AFTER=1

    local rc=0
    run_with_timeout 5 true || rc=$?
    assert_eq "0" "$rc" "Successful command exit code passes through"

    rc=0
    run_with_timeout 5 bash -c 'exit 7' || rc=$?
    assert_eq "7" "$rc" "Failing command exit code passes through"

    local started=$SECONDS
    rc=0
    run_with_timeout 1 sleep 30 || rc=$?
    is_timeout_rc "$rc" || fail "Expected sleeper to time out (rc=${rc})"
    [ $((SECONDS - started)) -lt 10 ] || fail "Timeout did not terminate the sleeper promptly"

    started=$SECONDS
    rc=0
    run_with_timeout 1 bash -c 'trap "" TERM; while :; do sleep 1; done' || rc=$?
    is_timeout_rc "$rc" || fail "Expected TERM-ignoring command to be killed (rc=${rc})"
    [ $((SECONDS - started)) -lt 15 ] || fail "Kill-after did not terminate the TERM-ignoring command"

    PACKAGE_UPDATE_TIMEOUT=1
    APT_STATUS="Skipped"
    PHASE_MESSAGES=()
    fail_phase APT_STATUS 124 Warning "apt upgrade"
    assert_eq "Error" "$APT_STATUS" "A timeout escalates the phase to Error"
    assert_contains "$LOG_FILE" "apt upgrade timed out after 1s"

    SNAP_STATUS="Skipped"
    fail_phase SNAP_STATUS 1 Warning "snap refresh"
    assert_eq "Warning" "$SNAP_STATUS" "An ordinary failure keeps the default status"

    fail_phase SNAP_STATUS 1 Warning "snap refresh again"
    SNAP_STATUS="Error"
    raise_status SNAP_STATUS Warning
    assert_eq "Error" "$SNAP_STATUS" "raise_status never downgrades"
)

test_update_lock_prevents_second_instance() (
    source "$UPDATER_SCRIPT"

    command -v flock >/dev/null 2>&1 || { printf 'SKIP: flock not installed\n'; return 0; }

    local fixture_dir="${TEST_ROOT}/lock"
    mkdir -p "$fixture_dir"
    LOG_FILE="${fixture_dir}/updater.log"
    : > "$LOG_FILE"
    UPDATE_LOCK_FILE="${fixture_dir}/updater.lock"

    acquire_update_lock || fail "First instance should acquire the lock"

    local rc=0
    ( acquire_update_lock ) > /dev/null || rc=$?
    assert_eq "2" "$rc" "Second instance must be refused while the lock is held"
    assert_contains "$LOG_FILE" "Another package update is already running"

    exec 9>&-
    rc=0
    ( acquire_update_lock ) > /dev/null || rc=$?
    assert_eq "0" "$rc" "Lock is available again once released"
)

test_last_run_json() (
    source "$UPDATER_SCRIPT"

    local fixture_dir="${TEST_ROOT}/last-run"
    mkdir -p "$fixture_dir"
    LOG_FILE="${fixture_dir}/update.log"
    LAST_RUN_FILE="${fixture_dir}/Update-AllPackages_Linux_host_last-run.json"
    MACHINE_NAME="host"
    STARTED_AT_UTC="2026-10-03T09:00:00Z"

    reset_statuses() {
        APT_STATUS="Success"
        SNAP_STATUS="Skipped"
        FLATPAK_STATUS="Skipped"
        NPM_STATUS="Success"
        CLAUDE_CODE_STATUS="Success"
        PIP_STATUS="Success"
        RUSTUP_STATUS="Success"
        PHASE_MESSAGES=()
    }

    reset_statuses
    write_last_run_json
    assert_eq "clean" "$OUTCOME" "All-success outcome"
    assert_eq "0" "$EXIT_CODE" "All-success exit code"

    reset_statuses
    NPM_STATUS="Warning"
    write_last_run_json
    assert_eq "warning" "$OUTCOME" "Warning outcome"
    assert_eq "2" "$EXIT_CODE" "Warning exit code"

    reset_statuses
    NPM_STATUS="Warning"
    PIP_STATUS="Error"
    PHASE_MESSAGES[PIP_STATUS]=$'pip "quoted" \\ back\tslash\nnewline'
    write_last_run_json
    assert_eq "error" "$OUTCOME" "Error outcome wins over warning"
    assert_eq "1" "$EXIT_CODE" "Error exit code"
    assert_file_exists "$LAST_RUN_FILE"
    assert_file_absent "${LAST_RUN_FILE}.tmp.$$"

    command -v python3 >/dev/null 2>&1 || { printf 'SKIP: python3 unavailable for JSON validation\n'; return 0; }

    python3 - "$LAST_RUN_FILE" <<'PY' || fail "last-run JSON failed validation"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schemaVersion"] == 1
assert d["script"] == "Update-AllPackages_Linux"
assert d["machine"] == "host"
assert d["startedAtUtc"] == "2026-10-03T09:00:00Z"
assert d["updatesCompletedAtUtc"].endswith("Z")
assert d["exitCode"] == 1 and d["outcome"] == "error"
assert d["logFile"].endswith("update.log")
assert d["source"]["path"].endswith("Update-AllPackages_Linux.sh")
assert len(d["source"]["sha256"]) == 64
assert list(d["phases"]) == ["Apt", "Snap", "Flatpak", "Npm", "ClaudeCode", "Pip", "Rustup"]
assert d["phases"]["Npm"]["status"] == "Warning"
assert d["phases"]["Snap"]["status"] == "Skipped"
assert d["phases"]["Pip"]["status"] == "Error"
assert d["phases"]["Pip"]["message"] == 'pip "quoted" \\ back\tslash\nnewline', d["phases"]["Pip"]["message"]
PY
)

assert_contains "$UPDATER_SCRIPT" 'if [ "${BASH_SOURCE[0]}" = "$0" ]; then'
assert_contains "$SETUP_SCRIPT" 'if [ "${BASH_SOURCE[0]}" = "$0" ]; then'
# Regression guards: global pip packages must never be bulk-upgraded, and
# overlapping runs / hangs must stay guarded.
assert_not_contains "$UPDATER_SCRIPT" '--break-system-packages'
assert_not_contains "$UPDATER_SCRIPT" 'list --outdated'
assert_contains "$UPDATER_SCRIPT" 'acquire_update_lock || lock_rc=$?'
assert_contains "$UPDATER_SCRIPT" 'timeout --kill-after='
# Regression guard: Claude Code must be resolved against the invoking user
# (SUDO_USER), never defaulted straight to $HOME, since this script runs
# self-elevated to root and root's $HOME is /root.
assert_contains "$UPDATER_SCRIPT" 'target_user="${SUDO_USER:-}"'
assert_not_contains "$UPDATER_SCRIPT" 'CLAUDE_CODE_BINARY="${CLAUDE_CODE_BINARY:-${HOME}/.local/bin/claude}"'

test_sourcing_does_not_create_log_directory
printf 'PASS: updater sourcing has no filesystem writes\n'
test_summary_notifications
printf 'PASS: summary notification titles\n'
test_claude_code_update_status
printf 'PASS: Claude Code native update statuses\n'
test_host_scoped_log_retention
printf 'PASS: host-scoped log retention\n'
test_cron_rendering
printf 'PASS: cron rendering and legacy cleanup\n'
test_pip_never_bulk_upgrades
printf 'PASS: pip tooling never bulk-upgrades and propagates exit codes\n'
test_run_with_timeout_terminates_commands
printf 'PASS: run_with_timeout terminates hung commands\n'
test_update_lock_prevents_second_instance
printf 'PASS: update lock prevents overlapping runs\n'
test_last_run_json
printf 'PASS: last-run JSON is valid\n'

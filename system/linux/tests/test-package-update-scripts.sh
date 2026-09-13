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

assert_contains "$UPDATER_SCRIPT" 'if [ "${BASH_SOURCE[0]}" = "$0" ]; then'
assert_contains "$SETUP_SCRIPT" 'if [ "${BASH_SOURCE[0]}" = "$0" ]; then'
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

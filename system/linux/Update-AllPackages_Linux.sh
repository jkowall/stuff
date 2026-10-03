#!/bin/bash

# SYNOPSIS
#     Weekly package update script for apt, snap, flatpak, npm, Claude Code, pip tooling, and rustup.
# DESCRIPTION
#     Updates all packages from apt, snap, flatpak, npm global packages, Anthropic's native
#     Claude Code updater, pipx/uv-managed Python tools, and rustup-managed Rust toolchains.
#     Global pip packages are intentionally never bulk-upgraded.
#     Logs all output to a timestamped file, writes a machine-readable last-run JSON,
#     and shows desktop notifications.
#     Environment: PACKAGE_UPDATE_TIMEOUT (seconds per external command, default 1800, 0 disables),
#     PACKAGE_UPDATE_KILL_AFTER (grace seconds before SIGKILL, default 30).

# ============================================================================
# CONFIGURATION
# ============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
LOG_DIR="$(dirname "$SCRIPT_DIR")/logs"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
MACHINE_NAME="$(hostname)"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_${MACHINE_NAME}_${TIMESTAMP}.log"
LAST_RUN_FILE="${LOG_DIR}/${SCRIPT_NAME}_${MACHINE_NAME}_last-run.json"
UPDATE_LOCK_FILE="${UPDATE_LOCK_FILE:-/tmp/${SCRIPT_NAME}.${UID}.lock}"
CLAUDE_CODE_BINARY="${CLAUDE_CODE_BINARY:-}"
STARTED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

PACKAGE_UPDATE_TIMEOUT="${PACKAGE_UPDATE_TIMEOUT:-1800}"
PACKAGE_UPDATE_KILL_AFTER="${PACKAGE_UPDATE_KILL_AFTER:-30}"
case "$PACKAGE_UPDATE_TIMEOUT" in ''|*[!0-9]*) PACKAGE_UPDATE_TIMEOUT=1800 ;; esac
case "$PACKAGE_UPDATE_KILL_AFTER" in ''|*[!0-9]*) PACKAGE_UPDATE_KILL_AFTER=30 ;; esac

# Status tracking
APT_STATUS="Skipped"
SNAP_STATUS="Skipped"
FLATPAK_STATUS="Skipped"
NPM_STATUS="Skipped"
CLAUDE_CODE_STATUS="Skipped"
PIP_STATUS="Skipped"
RUSTUP_STATUS="Skipped"

# Phase name -> status variable, in report order. Messages are keyed by status variable name.
PHASE_ORDER=(Apt Snap Flatpak Npm ClaudeCode Pip Rustup)
declare -gA PHASE_STATUS_VARS=(
    [Apt]=APT_STATUS
    [Snap]=SNAP_STATUS
    [Flatpak]=FLATPAK_STATUS
    [Npm]=NPM_STATUS
    [ClaudeCode]=CLAUDE_CODE_STATUS
    [Pip]=PIP_STATUS
    [Rustup]=RUSTUP_STATUS
)
declare -gA PHASE_MESSAGES=()

OUTCOME="clean"
EXIT_CODE=0
TOOL_USER_PREFIX=()
TOOL_USER_BIN=""

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local color=""

    case "$level" in
        "Info")    color="\e[37m" ;; # White
        "Success") color="\e[32m" ;; # Green
        "Warning") color="\e[33m" ;; # Yellow
        "Error")   color="\e[31m" ;; # Red
        *)         color="\e[0m"  ;;
    esac

    local log_entry="[$timestamp] [$level] $message"
    echo -e "${color}${log_entry}\e[0m"
    echo "$log_entry" >> "$LOG_FILE"
}

show_notification() {
    local title="$1"
    local message="$2"
    local type="$3" # low, normal, critical

    if ! command -v notify-send >/dev/null 2>&1; then
        log "Warning" "notify-send not found. Skipping desktop notification."
        return
    fi

    if [ -z "${DISPLAY:-}" ] && [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        log "Info" "Desktop notification environment unavailable. Skipping notification."
        return
    fi

    if ! notify-send -u "$type" "$title" "$message" >/dev/null 2>&1; then
        log "Warning" "Desktop notification failed. Skipping notification."
    fi
}

# Runs a command with a hard time limit. Returns the command's exit code, or 124/137 on timeout.
# It does not log, so callers can safely redirect its output into the log file.
run_with_timeout() {
    local seconds="$1"
    shift
    timeout --kill-after="${PACKAGE_UPDATE_KILL_AFTER}" "$seconds" "$@"
}

is_timeout_rc() {
    [ "$1" -eq 124 ] || [ "$1" -eq 137 ]
}

status_rank() {
    case "$1" in
        Error)   echo 3 ;;
        Warning) echo 2 ;;
        Success) echo 1 ;;
        *)       echo 0 ;;
    esac
}

# Only ever escalates a status variable (Skipped < Success < Warning < Error).
raise_status() {
    local var="$1"
    local new_status="$2"

    if [ "$(status_rank "$new_status")" -gt "$(status_rank "${!var}")" ]; then
        printf -v "$var" '%s' "$new_status"
    fi
}

append_phase_message() {
    local var="$1"
    local message="$2"

    if [ -n "${PHASE_MESSAGES[$var]:-}" ]; then
        PHASE_MESSAGES[$var]+="; ${message}"
    else
        PHASE_MESSAGES[$var]="$message"
    fi
}

# Records a failed step against a phase. A timeout always escalates to Error.
fail_phase() {
    local var="$1"
    local rc="$2"
    local default_status="$3"
    local label="$4"
    local new_status="$default_status"
    local message=""

    if is_timeout_rc "$rc"; then
        new_status="Error"
        message="${label} timed out after ${PACKAGE_UPDATE_TIMEOUT}s and was terminated"
        log "Error" "${message}."
    else
        message="${label} failed with exit code ${rc}"
        log "$default_status" "${message}. Check log."
    fi

    raise_status "$var" "$new_status"
    append_phase_message "$var" "$message"
}

# Prevents overlapping runs. Returns 0 when acquired, 2 when another instance holds the lock.
acquire_update_lock() {
    if ! command -v flock >/dev/null 2>&1; then
        log "Warning" "flock not found. Running without an overlap lock."
        return 0
    fi

    if ! exec 9>"$UPDATE_LOCK_FILE"; then
        log "Warning" "Unable to open update lock ${UPDATE_LOCK_FILE}. Running without an overlap lock."
        return 0
    fi

    if ! flock -n 9; then
        log "Warning" "Another package update is already running (lock: ${UPDATE_LOCK_FILE})."
        return 2
    fi

    return 0
}

# This script self-elevates to root, so per-user tools (pipx, uv) must run as the invoking user.
refresh_tool_user_context() {
    TOOL_USER_PREFIX=()
    TOOL_USER_BIN=""

    # Cron runs this as root with no SUDO_USER, so fall back to PACKAGE_UPDATE_USER, then the script owner.
    local user="${SUDO_USER:-${PACKAGE_UPDATE_USER:-}}"
    local home=""

    if { [ -z "$user" ] || [ "$user" = "root" ]; } && [ "$EUID" -eq 0 ]; then
        user="$(stat -c %U "${BASH_SOURCE[0]}" 2>/dev/null || true)"
    fi

    if [ -n "$user" ] && [ "$user" != "root" ]; then
        home="$(getent passwd "$user" | cut -d: -f6)"
        if [ -n "$home" ]; then
            TOOL_USER_BIN="${home}/.local/bin"
            TOOL_USER_PREFIX=(sudo -u "$user" -H env "PATH=${TOOL_USER_BIN}:${PATH}")
        fi
    fi
}

tool_available() {
    PATH="${TOOL_USER_BIN:+${TOOL_USER_BIN}:}${PATH}" command -v "$1" >/dev/null 2>&1
}

update_apt() {
    log "Info" "============================================================"
    log "Info" "STARTING APT UPDATES"
    log "Info" "============================================================"

    if [ "$EUID" -ne 0 ]; then
        log "Error" "Apt update requires root privileges. Please run with sudo."
        APT_STATUS="Error"
        PHASE_MESSAGES[APT_STATUS]="Apt update requires root privileges"
        return
    fi

    local rc=0
    log "Info" "Running: apt update"
    if run_with_timeout "$PACKAGE_UPDATE_TIMEOUT" apt-get update -y >> "$LOG_FILE" 2>&1; then
        log "Info" "Running: apt upgrade -y"
        if run_with_timeout "$PACKAGE_UPDATE_TIMEOUT" apt-get upgrade -y >> "$LOG_FILE" 2>&1; then
            APT_STATUS="Success"
            PHASE_MESSAGES[APT_STATUS]="Apt packages updated successfully"
            log "Success" "Apt updates completed successfully"
        else
            rc=$?
            fail_phase APT_STATUS "$rc" Warning "apt upgrade"
        fi
    else
        rc=$?
        fail_phase APT_STATUS "$rc" Error "apt update"
    fi
}

update_snap() {
    if ! command -v snap >/dev/null 2>&1; then
        log "Info" "Snap not installed. Skipping."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING SNAP UPDATES"
    log "Info" "============================================================"

    local rc=0
    log "Info" "Running: snap refresh"
    if run_with_timeout "$PACKAGE_UPDATE_TIMEOUT" snap refresh >> "$LOG_FILE" 2>&1; then
        SNAP_STATUS="Success"
        PHASE_MESSAGES[SNAP_STATUS]="Snap packages refreshed successfully"
        log "Success" "Snap updates completed successfully"
    else
        rc=$?
        fail_phase SNAP_STATUS "$rc" Warning "snap refresh"
    fi
}

update_flatpak() {
    if ! command -v flatpak >/dev/null 2>&1; then
        log "Info" "Flatpak not installed. Skipping."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING FLATPAK UPDATES"
    log "Info" "============================================================"

    local rc=0
    log "Info" "Running: flatpak update -y"
    if run_with_timeout "$PACKAGE_UPDATE_TIMEOUT" flatpak update -y >> "$LOG_FILE" 2>&1; then
        FLATPAK_STATUS="Success"
        PHASE_MESSAGES[FLATPAK_STATUS]="Flatpak packages updated successfully"
        log "Success" "Flatpak updates completed successfully"
    else
        rc=$?
        fail_phase FLATPAK_STATUS "$rc" Warning "flatpak update"
    fi
}

update_npm() {
    if ! command -v npm >/dev/null 2>&1; then
        log "Info" "NPM not installed. Skipping."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING NPM GLOBAL UPDATES"
    log "Info" "============================================================"

    local rc=0
    log "Info" "Running: npm update -g"
    if run_with_timeout "$PACKAGE_UPDATE_TIMEOUT" npm update -g >> "$LOG_FILE" 2>&1; then
        NPM_STATUS="Success"
        PHASE_MESSAGES[NPM_STATUS]="npm global packages updated successfully"
        log "Success" "NPM global updates completed successfully"
    else
        rc=$?
        fail_phase NPM_STATUS "$rc" Warning "npm update -g"
    fi
}

update_claude_code() {
    log "Info" "============================================================"
    log "Info" "STARTING CLAUDE CODE UPDATE"
    log "Info" "============================================================"

    # This script self-elevates to root (see MAIN EXECUTION), and root's $HOME
    # is /root, not the invoking user's home. Claude Code is installed
    # per-user via the native installer (~/.local/bin/claude), so the update
    # must run as the original user (SUDO_USER) or it silently targets the
    # wrong (nonexistent) install path under /root.
    local target_user="${SUDO_USER:-}"

    if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
        log "Info" "No non-root invoking user detected (run via sudo as a real user to enable this). Skipping Claude Code update."
        CLAUDE_CODE_STATUS="Skipped"
        return 0
    fi

    local claude_binary="$CLAUDE_CODE_BINARY"
    if [ -z "$claude_binary" ]; then
        local target_home=""
        target_home="$(getent passwd "$target_user" | cut -d: -f6)"
        if [ -z "$target_home" ]; then
            log "Warning" "Could not resolve home directory for user ${target_user}. Skipping Claude Code update."
            CLAUDE_CODE_STATUS="Warning"
            PHASE_MESSAGES[CLAUDE_CODE_STATUS]="Could not resolve home directory for ${target_user}"
            return 1
        fi
        claude_binary="${target_home}/.local/bin/claude"
    fi

    if ! sudo -u "$target_user" test -x "$claude_binary"; then
        log "Info" "Anthropic-native Claude Code not found at ${claude_binary} for user ${target_user}. Skipping."
        CLAUDE_CODE_STATUS="Skipped"
        return 0
    fi

    local current_version=""
    current_version="$(sudo -u "$target_user" "$claude_binary" --version 2>>"$LOG_FILE")" || true
    if [ -n "$current_version" ]; then
        current_version="${current_version%%$'\n'*}"
        log "Info" "Current Claude Code: $current_version"
    fi

    local update_rc=0
    log "Info" "Running as ${target_user}: ${claude_binary} update"
    run_with_timeout "$PACKAGE_UPDATE_TIMEOUT" sudo -u "$target_user" "$claude_binary" update 2>&1 | tee -a "$LOG_FILE"
    update_rc=${PIPESTATUS[0]}
    if [ "$update_rc" -ne 0 ]; then
        fail_phase CLAUDE_CODE_STATUS "$update_rc" Warning "Claude Code native update"
        return 1
    fi

    local updated_version=""
    if ! updated_version="$(sudo -u "$target_user" "$claude_binary" --version 2>>"$LOG_FILE")" || [ -z "$updated_version" ]; then
        CLAUDE_CODE_STATUS="Warning"
        PHASE_MESSAGES[CLAUDE_CODE_STATUS]="Claude Code updated, but version verification failed"
        log "Warning" "Claude Code updated, but version verification failed."
        return 1
    fi

    updated_version="${updated_version%%$'\n'*}"
    CLAUDE_CODE_STATUS="Success"
    PHASE_MESSAGES[CLAUDE_CODE_STATUS]="Claude Code is current: ${updated_version}"
    log "Success" "Claude Code is current on the configured release channel: $updated_version"
}

# True when system Python is PEP 668 externally managed, where pip must not modify it.
pip_is_externally_managed() {
    python3 -c 'import os, sys, sysconfig; marker = os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED"); sys.exit(0 if sys.prefix == sys.base_prefix and os.path.exists(marker) else 1)' >/dev/null 2>&1
}

# Global pip packages are never bulk-upgraded (it breaks distro-managed Python tools).
# pip itself is upgraded only where that is valid, and isolated tools go through pipx or uv.
update_pip() {
    refresh_tool_user_context

    local have_pip=false
    local have_pipx=false
    local have_uv=false

    if command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
        have_pip=true
    fi
    if tool_available pipx; then have_pipx=true; fi
    if tool_available uv; then have_uv=true; fi

    if ! $have_pip && ! $have_pipx && ! $have_uv; then
        log "Info" "pip, pipx and uv not available. Skipping Python tooling updates."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING PIP UPDATES"
    log "Info" "============================================================"

    PIP_STATUS="Success"
    local rc=0

    if $have_pip; then
        if pip_is_externally_managed; then
            log "Info" "Skipping pip self-upgrade: system Python is externally managed (PEP 668)."
            append_phase_message PIP_STATUS "pip self-upgrade skipped (PEP 668)"
        else
            log "Info" "Upgrading pip itself via: python3 -m pip"
            run_with_timeout "$PACKAGE_UPDATE_TIMEOUT" python3 -m pip install --upgrade pip 2>&1 | tee -a "$LOG_FILE"
            rc=${PIPESTATUS[0]}
            if [ "$rc" -ne 0 ]; then
                fail_phase PIP_STATUS "$rc" Error "pip self-upgrade"
            else
                append_phase_message PIP_STATUS "pip self-upgrade completed"
            fi
        fi
    fi

    if $have_pipx; then
        log "Info" "Running: pipx upgrade-all"
        run_with_timeout "$PACKAGE_UPDATE_TIMEOUT" ${TOOL_USER_PREFIX[@]+"${TOOL_USER_PREFIX[@]}"} pipx upgrade-all 2>&1 | tee -a "$LOG_FILE"
        rc=${PIPESTATUS[0]}
        if [ "$rc" -ne 0 ]; then
            fail_phase PIP_STATUS "$rc" Warning "pipx upgrade-all"
        else
            append_phase_message PIP_STATUS "pipx upgrade-all completed"
        fi
    elif $have_uv; then
        log "Info" "Running: uv tool upgrade --all"
        run_with_timeout "$PACKAGE_UPDATE_TIMEOUT" ${TOOL_USER_PREFIX[@]+"${TOOL_USER_PREFIX[@]}"} uv tool upgrade --all 2>&1 | tee -a "$LOG_FILE"
        rc=${PIPESTATUS[0]}
        if [ "$rc" -ne 0 ]; then
            fail_phase PIP_STATUS "$rc" Warning "uv tool upgrade --all"
        else
            append_phase_message PIP_STATUS "uv tool upgrade --all completed"
        fi
    else
        log "Info" "Neither pipx nor uv found. Skipping tool upgrades (global pip packages are intentionally not bulk-upgraded)."
        append_phase_message PIP_STATUS "no pipx or uv; tool upgrades skipped"
    fi

    if [ "$PIP_STATUS" = "Success" ]; then
        log "Success" "Python tooling updates completed successfully"
    fi
}

update_rustup() {
    if ! command -v rustup >/dev/null 2>&1; then
        log "Info" "rustup not installed. Skipping."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING RUSTUP UPDATES"
    log "Info" "============================================================"

    log "Info" "Checking for rustup and toolchain updates..."
    local check_output=""
    local rc=0
    check_output=$(run_with_timeout "$PACKAGE_UPDATE_TIMEOUT" rustup check 2>&1 | tee -a "$LOG_FILE")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail_phase RUSTUP_STATUS "$rc" Warning "rustup check"
        return
    fi

    if echo "$check_output" | grep -q "Update available"; then
        log "Info" "Running: rustup update"
        run_with_timeout "$PACKAGE_UPDATE_TIMEOUT" rustup update 2>&1 | tee -a "$LOG_FILE"
        rc=${PIPESTATUS[0]}
        if [ "$rc" -eq 0 ]; then
            RUSTUP_STATUS="Success"
            PHASE_MESSAGES[RUSTUP_STATUS]="Rust toolchains updated successfully"
            log "Success" "rustup updates completed successfully"
        else
            fail_phase RUSTUP_STATUS "$rc" Warning "rustup update"
        fi
    else
        RUSTUP_STATUS="Success"
        PHASE_MESSAGES[RUSTUP_STATUS]="Rust toolchains are already up-to-date"
        log "Success" "Rust toolchains are already up-to-date"
    fi
}

show_summary() {
    echo ""
    log "Info" "============================================================"
    log "Info" "UPDATE SUMMARY"
    log "Info" "============================================================"

    local has_errors=false

    echo -e "APT:         $APT_STATUS"
    echo -e "SNAP:        $SNAP_STATUS"
    echo -e "FLATPAK:     $FLATPAK_STATUS"
    echo -e "NPM:         $NPM_STATUS"
    echo -e "CLAUDE CODE: $CLAUDE_CODE_STATUS"
    echo -e "PIP:         $PIP_STATUS"
    echo -e "RUSTUP:      $RUSTUP_STATUS"

    log "Info" "APT:         $APT_STATUS"
    log "Info" "SNAP:        $SNAP_STATUS"
    log "Info" "FLATPAK:     $FLATPAK_STATUS"
    log "Info" "NPM:         $NPM_STATUS"
    log "Info" "CLAUDE CODE: $CLAUDE_CODE_STATUS"
    log "Info" "PIP:         $PIP_STATUS"
    log "Info" "RUSTUP:      $RUSTUP_STATUS"

    if [[ "$APT_STATUS" == "Error" || "$SNAP_STATUS" == "Error" || "$FLATPAK_STATUS" == "Error" || "$NPM_STATUS" == "Error" || "$CLAUDE_CODE_STATUS" == "Error" || "$PIP_STATUS" == "Error" || "$RUSTUP_STATUS" == "Error" ]]; then
        has_errors=true
    fi

    log "Info" "============================================================"
    log "Info" "Log file saved to: $LOG_FILE"

    if [ "$has_errors" = true ]; then
        show_notification "Package Updates Completed with Errors" "Check the log for details: $LOG_FILE" "critical"
    else
        show_notification "Package Updates Completed" "All package managers updated successfully!" "normal"
    fi
}

json_escape() {
    local s="$1"

    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//[[:cntrl:]]/ }"
    printf '%s' "$s"
}

# Sets OUTCOME (clean|warning|error) and EXIT_CODE (0|2|1), matching the Windows updater.
compute_outcome() {
    local name=""
    local var=""
    local has_error=false
    local has_warning=false

    for name in "${PHASE_ORDER[@]}"; do
        var="${PHASE_STATUS_VARS[$name]}"
        case "${!var}" in
            Error)   has_error=true ;;
            Warning) has_warning=true ;;
        esac
    done

    if $has_error; then
        OUTCOME="error"
        EXIT_CODE=1
    elif $has_warning; then
        OUTCOME="warning"
        EXIT_CODE=2
    else
        OUTCOME="clean"
        EXIT_CODE=0
    fi
}

write_last_run_json() {
    compute_outcome

    local completed_at=""
    completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local sha256=""
    if [ -r "$SCRIPT_PATH" ] && command -v sha256sum >/dev/null 2>&1; then
        sha256="$(sha256sum "$SCRIPT_PATH" | cut -d' ' -f1)"
    fi

    local tmp_file="${LAST_RUN_FILE}.tmp.$$"
    local name=""
    local var=""
    local index=0
    local last_index=$(( ${#PHASE_ORDER[@]} - 1 ))
    local separator=","

    mkdir -p "$(dirname "$LAST_RUN_FILE")"

    {
        printf '{\n'
        printf '    "schemaVersion": 1,\n'
        printf '    "script": "%s",\n' "$(json_escape "$SCRIPT_NAME")"
        printf '    "machine": "%s",\n' "$(json_escape "$MACHINE_NAME")"
        printf '    "startedAtUtc": "%s",\n' "$(json_escape "$STARTED_AT_UTC")"
        printf '    "updatesCompletedAtUtc": "%s",\n' "$completed_at"
        printf '    "exitCode": %d,\n' "$EXIT_CODE"
        printf '    "outcome": "%s",\n' "$OUTCOME"
        printf '    "logFile": "%s",\n' "$(json_escape "$LOG_FILE")"
        printf '    "source": {\n'
        printf '        "path": "%s",\n' "$(json_escape "$SCRIPT_PATH")"
        printf '        "sha256": "%s"\n' "$sha256"
        printf '    },\n'
        printf '    "phases": {\n'
        for index in "${!PHASE_ORDER[@]}"; do
            name="${PHASE_ORDER[$index]}"
            var="${PHASE_STATUS_VARS[$name]}"
            separator=","
            if [ "$index" -eq "$last_index" ]; then separator=""; fi
            printf '        "%s": {\n' "$name"
            printf '            "status": "%s",\n' "$(json_escape "${!var}")"
            printf '            "message": "%s"\n' "$(json_escape "${PHASE_MESSAGES[$var]:-}")"
            printf '        }%s\n' "$separator"
        done
        printf '    }\n'
        printf '}\n'
    } > "$tmp_file" && mv -f "$tmp_file" "$LAST_RUN_FILE"
}

cleanup_logs() {
    log "Info" "Cleaning up old log files (keeping most recent 3)..."
    ls -t "${LOG_DIR}/${SCRIPT_NAME}_${MACHINE_NAME}_"*.log 2>/dev/null | tail -n +4 | xargs -r rm -f
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    # Ensure the script is running as root (self-elevate)
    if [ "$EUID" -ne 0 ]; then
        echo "This script requires root privileges for package updates. Elevating..."
        exec sudo "$0" "$@"
    fi

    STARTED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Ensure log directory and file exist. Root-owned logs in the script dir
    # are fine for this system script's simplicity.
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 666 "$LOG_FILE" 2>/dev/null

    log "Info" "============================================================"
    log "Info" "PACKAGE UPDATE STARTED (User=$(whoami), ActualUser=${SUDO_USER:-$(whoami)})"
    log "Info" "Script Directory: $SCRIPT_DIR"
    log "Info" "Log File: $LOG_FILE"
    log "Info" "============================================================"

    local lock_rc=0
    acquire_update_lock || lock_rc=$?
    if [ "$lock_rc" -eq 2 ]; then
        log "Info" "Exiting without running updates."
        return 0
    fi

    # Cleanup
    cleanup_logs

    # Show start notification
    # Note: notify-send as root needs to find the user session.
    # We use SUDO_USER if available to try and show it on the correct desktop.
    if [ -n "${SUDO_USER:-}" ]; then
        if ! sudo -u "$SUDO_USER" DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$SUDO_USER")/bus \
            notify-send -u low "Package Updates" "Starting updates for apt, snap, flatpak, npm, Claude Code, pip tooling, and rustup..." >/dev/null 2>&1; then
            log "Info" "Desktop notification environment unavailable. Skipping start notification."
        fi
    else
        show_notification "Package Updates Starting" "Updating apt, snap, flatpak, npm, Claude Code, pip tooling, and rustup packages..." "low"
    fi

    # Run Updates
    update_apt
    update_snap
    update_flatpak
    update_npm
    update_claude_code
    update_pip
    update_rustup

    # Summary
    show_summary
    write_last_run_json || log "Warning" "Could not write last-run status file: $LAST_RUN_FILE"

    echo ""
    log "Info" "Update process completed."
    # No read-host equivalent usually needed in bash for non-interactive execution, but added for terminal clarity
    if [ -t 0 ]; then
        read -p "Press Enter to close..."
    fi

    return "$EXIT_CODE"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi

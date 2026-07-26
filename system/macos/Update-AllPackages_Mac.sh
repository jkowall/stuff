#!/bin/bash

# SYNOPSIS
#     Weekly package update script for Homebrew, Mac App Store, MacUpdater, npm, pipx, and rustup on macOS.
# DESCRIPTION
#     Updates packages and apps from Homebrew, Mac App Store (via mas), MacUpdater, npm, pipx, and rustup-managed Rust toolchains.
#     Logs all output to a timestamped file and shows desktop notifications.

# ============================================================================
# CONFIGURATION
# ============================================================================

set -o pipefail

# launchd provides a minimal PATH, so include common package manager locations.
# Homebrew versioned Node formulae are keg-only, so npm is not linked into Homebrew's bin directory.
export PATH="/opt/homebrew/opt/node@24/bin:/usr/local/opt/node@24/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$(dirname "$SCRIPT_DIR")/logs"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
MACHINE_NAME="$(hostname)"
TIMESTAMP="$(date +%Y-%m-%d_%H-%m)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_${MACHINE_NAME}_${TIMESTAMP}.log"
INTERACTIVE_MODE=0
PENDING_ONLY=0
PENDING_FILE="${SCRIPT_DIR}/pending-interactive-update"
MACUPDATER_CLIENT="/Applications/MacUpdater.app/Contents/Resources/macupdater_client"
MACUPDATER_SCAN_TIMEOUT_SECONDS=120
MACUPDATER_APP_TIMEOUT_SECONDS=900

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interactive)
            INTERACTIVE_MODE=1
            shift
            ;;
        --interactive-run)
            INTERACTIVE_MODE=1
            shift
            ;;
        --run-pending)
            INTERACTIVE_MODE=1
            PENDING_ONLY=1
            shift
            ;;
        *)
            break
            ;;
    esac
done

# Ensure log directory exists
mkdir -p "$LOG_DIR"

if [ "$PENDING_ONLY" -eq 1 ] && [ ! -f "$PENDING_FILE" ]; then
    exit 0
fi

# Status tracking
BREW_STATUS="Skipped"
MAS_STATUS="Skipped"
MACUPDATER_STATUS="Skipped"
NPM_STATUS="Skipped"
PIP_STATUS="Skipped"
PIPX_STATUS="Skipped"
RUSTUP_STATUS="Skipped"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local color=""

    case "$level" in
        "Info")    color="\033[37m" ;; # White
        "Success") color="\033[32m" ;; # Green
        "Warning") color="\033[33m" ;; # Yellow
        "Error")   color="\033[31m" ;; # Red
        *)         color="\033[0m"  ;;
    esac

    local log_entry="[$timestamp] [$level] $message"
    echo -e "${color}${log_entry}\033[0m"
    echo "$log_entry" >> "$LOG_FILE"
}

is_data_saver_active() {
    # Check if Low Data Mode is enabled via the macOS Network framework.
    # Returns 0 (true) if constrained/Low Data Mode, 1 (false) otherwise.
    swift - 2>/dev/null <<'SWIFT'
import Network
import Foundation
let semaphore = DispatchSemaphore(value: 0)
let monitor = NWPathMonitor()
var isConstrained = false
monitor.pathUpdateHandler = { path in
    isConstrained = path.isConstrained
    semaphore.signal()
}
monitor.start(queue: DispatchQueue.global())
_ = semaphore.wait(timeout: .now() + 5)
monitor.cancel()
    exit(isConstrained ? 0 : 1)
SWIFT
}

mark_pending_interactive_run() {
    {
        printf 'created_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf 'script=%s\n' "$0"
        printf 'log=%s\n' "$LOG_FILE"
    } > "$PENDING_FILE"
    log "Warning" "Saved pending interactive update marker: $PENDING_FILE"
}

clear_pending_interactive_run() {
    if [ -f "$PENDING_FILE" ]; then
        rm -f "$PENDING_FILE"
        log "Info" "Cleared pending interactive update marker: $PENDING_FILE"
    fi
}

launch_interactive_terminal() {
    if [ "$INTERACTIVE_MODE" -ne 1 ]; then
        return 0
    fi

    if [ -t 0 ] || [ -t 1 ]; then
        clear_pending_interactive_run
        return 0
    fi

    local script_path
    script_path="$(/usr/bin/realpath "$0" 2>/dev/null || printf '%s' "$0")"
    local terminal_cmd
    terminal_cmd="bash '${script_path}' --interactive-run"

    log "Info" "Interactive mode requested. Relaunching in Terminal for user interaction."

    if ! /usr/bin/osascript <<OSA
with timeout of 30 seconds
    tell application "Terminal"
        activate
        do script "${terminal_cmd}"
    end tell
end timeout
OSA
    then
        log "Error" "Failed to launch Terminal for interactive update run."
        mark_pending_interactive_run
        return 1
    fi

    exit 0
}

show_notification() {
    local title="$1"
    local message="$2"

    # macOS native notification via AppleScript
    osascript - "$title" "$message" <<'OSA'
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
OSA
}

run_logged_with_timeout() {
    local timeout_seconds="$1"
    shift

    local output_file
    output_file="$(mktemp "${TMPDIR:-/tmp}/update-command-output.XXXXXX")" || {
        log "Error" "Unable to create temporary output file for command: $*"
        return 125
    }

    "$@" > "$output_file" 2>&1 &
    local command_pid=$!
    local elapsed=0
    local wait_interval=5

    while kill -0 "$command_pid" 2>/dev/null; do
        if [ "$elapsed" -ge "$timeout_seconds" ]; then
            log "Warning" "Command timed out after ${timeout_seconds}s: $*"
            kill "$command_pid" 2>/dev/null || true
            sleep 2
            kill -9 "$command_pid" 2>/dev/null || true
            wait "$command_pid" 2>/dev/null || true
            cat "$output_file" | tee -a "$LOG_FILE"
            rm -f "$output_file"
            return 124
        fi

        sleep "$wait_interval"
        elapsed=$((elapsed + wait_interval))
    done

    local command_status=0
    wait "$command_pid"
    command_status=$?
    cat "$output_file" | tee -a "$LOG_FILE"
    rm -f "$output_file"
    return "$command_status"
}

update_brew() {
    if ! command -v brew >/dev/null 2>&1; then
        log "Warning" "Homebrew not found. Skipping."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING HOMEBREW UPDATES"
    log "Info" "============================================================"

    log "Info" "Running: brew update"
    if brew update 2>&1 | tee -a "$LOG_FILE"; then
        log "Info" "Running: brew upgrade"
        if brew upgrade 2>&1 | tee -a "$LOG_FILE"; then
            log "Info" "Running: brew cleanup"
            brew cleanup 2>&1 | tee -a "$LOG_FILE"
            BREW_STATUS="Success"
            log "Success" "Homebrew updates completed successfully"
        else
            BREW_STATUS="Warning"
            log "Warning" "Brew upgrade encountered issues."
        fi
    else
        BREW_STATUS="Error"
        log "Error" "Brew update failed."
    fi
}

update_mas() {
    if ! command -v mas >/dev/null 2>&1; then
        log "Info" "mas (Mac App Store CLI) not installed. Skipping."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING MAC APP STORE UPDATES"
    log "Info" "============================================================"

    log "Info" "Running: mas upgrade"
    if mas upgrade 2>&1 | tee -a "$LOG_FILE"; then
        MAS_STATUS="Success"
        log "Success" "App Store updates completed successfully"
    else
        MAS_STATUS="Warning"
        log "Warning" "mas upgrade encountered issues (or no updates available)."
    fi
}

update_macupdater_apps() {
    if [ ! -x "$MACUPDATER_CLIENT" ]; then
        log "Info" "MacUpdater CLI not found. Skipping."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING MACUPDATER APP UPDATES"
    log "Info" "============================================================"

    log "Info" "Running: macupdater_client scan --outdated --quiet"
    if run_logged_with_timeout "$MACUPDATER_SCAN_TIMEOUT_SECONDS" "$MACUPDATER_CLIENT" scan --outdated --quiet; then
        log "Success" "MacUpdater scan completed successfully"
    else
        log "Warning" "MacUpdater live scan failed. Falling back to cached MacUpdater app list."
    fi

    local list_file
    list_file="$(mktemp "${TMPDIR:-/tmp}/macupdater-list.XXXXXX")" || {
        MACUPDATER_STATUS="Error"
        log "Error" "Unable to create temporary file for MacUpdater app list."
        return
    }

    if ! "$MACUPDATER_CLIENT" list --hide-uptodate-apps --hide-mas-apps --json --quiet > "$list_file" 2>>"$LOG_FILE"; then
        MACUPDATER_STATUS="Warning"
        log "Warning" "MacUpdater app list failed."
        rm -f "$list_file"
        return
    fi

    local app_count
    app_count="$(python3 - "$list_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

apps = [
    app for app in data.get("apps", [])
    if app.get("outdated") and app.get("auto_updatable") and app.get("installed_path")
]
print(len(apps))
PY
)"

    local manual_count
    manual_count="$(python3 - "$list_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

apps = [
    app for app in data.get("apps", [])
    if app.get("outdated") and not app.get("auto_updatable") and app.get("installed_path")
]
print(len(apps))
PY
)"

    if [ "$manual_count" -gt 0 ]; then
        log "Warning" "MacUpdater found $manual_count outdated non-auto-updatable app(s) that need manual or vendor-specific updates."
        python3 - "$list_file" <<'PY' | while IFS=$'\t' read -r app_name installed_version newest_version app_path; do
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

for app in data.get("apps", []):
    if app.get("outdated") and not app.get("auto_updatable") and app.get("installed_path"):
        print("\t".join([
            app.get("name") or "",
            app.get("installed_version") or "",
            app.get("newest_version") or "",
            app.get("installed_path") or "",
        ]))
PY
            log "Warning" "Manual MacUpdater update remains: ${app_name} (${installed_version} -> ${newest_version}) at ${app_path}"
        done
    fi

    if [ "$app_count" -eq 0 ]; then
        if [ "$manual_count" -gt 0 ]; then
            MACUPDATER_STATUS="Warning"
            log "Warning" "MacUpdater found no auto-updatable non-MAS app updates, but manual updates remain."
        else
            MACUPDATER_STATUS="Success"
            log "Success" "MacUpdater found no non-MAS app updates."
        fi
        rm -f "$list_file"
        return
    fi

    log "Info" "MacUpdater found $app_count auto-updatable non-MAS app update(s)."
    log "Info" "Running apps may be skipped by MacUpdater; they will not be force-quit by this script."

    local updates_file
    updates_file="$(mktemp "${TMPDIR:-/tmp}/macupdater-updates.XXXXXX")" || {
        MACUPDATER_STATUS="Error"
        log "Error" "Unable to create temporary file for MacUpdater updates."
        rm -f "$list_file"
        return
    }

    python3 - "$list_file" > "$updates_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

for app in data.get("apps", []):
    if app.get("outdated") and app.get("auto_updatable") and app.get("installed_path"):
        print("\t".join([
            app.get("name") or "",
            app.get("installed_version") or "",
            app.get("newest_version") or "",
            app.get("installed_path") or "",
        ]))
PY

    local updated=0
    local failed=0
    local app_name=""
    local installed_version=""
    local newest_version=""
    local app_path=""

    while IFS=$'\t' read -r app_name installed_version newest_version app_path; do
        [ -n "$app_path" ] || continue
        log "Info" "MacUpdater updating: ${app_name} (${installed_version} -> ${newest_version}) at ${app_path}"

        if run_logged_with_timeout "$MACUPDATER_APP_TIMEOUT_SECONDS" "$MACUPDATER_CLIENT" update --quiet "$app_path"; then
            updated=$((updated + 1))
            log "Success" "MacUpdater update completed for: ${app_name}"
        else
            failed=$((failed + 1))
            log "Warning" "MacUpdater update failed or was skipped for: ${app_name}"
        fi
    done < "$updates_file"

    rm -f "$list_file" "$updates_file"

    if [ "$failed" -gt 0 ] || [ "$manual_count" -gt 0 ]; then
        MACUPDATER_STATUS="Warning"
        log "Warning" "MacUpdater completed with $updated updated, $failed failed/skipped, and $manual_count manual update(s) remaining."
    else
        MACUPDATER_STATUS="Success"
        log "Success" "MacUpdater completed successfully ($updated updated)."
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

    log "Info" "Checking for outdated NPM packages..."
    # npm outdated exits with 1 if packages are outdated
    OUTDATED=$(npm outdated -g --parseable 2>/dev/null | awk -F: 'NF>=4 {print $(NF-2)}') || true
    
    if [ -n "$OUTDATED" ]; then
        log "Info" "Updating packages: $(echo $OUTDATED | tr '\n' ' ')"
        if npm install -g $OUTDATED 2>&1 | tee -a "$LOG_FILE"; then
            NPM_STATUS="Success"
            log "Success" "NPM global updates completed successfully"
        else
            NPM_STATUS="Warning"
            log "Warning" "NPM update encountered issues."
        fi
    else
        NPM_STATUS="Success"
        log "Success" "NPM global packages are already up-to-date"
    fi
}

update_pip() {
    if ! command -v pip3 >/dev/null 2>&1; then
        log "Info" "pip3 not installed. Skipping."
        PIP_STATUS="Skipped"
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING PIP UPDATES"
    log "Info" "============================================================"

    log "Info" "Skipping bulk pip package updates to avoid managed-environment dependency conflicts."
    log "Info" "Use pipx directly for app/tool updates when available."
    PIP_STATUS="Skipped"
}

update_pipx() {
    if ! command -v pipx >/dev/null 2>&1; then
        log "Info" "pipx not installed. Skipping."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING PIPX UPDATES"
    log "Info" "============================================================"

    log "Info" "Running: pipx upgrade-all"
    if pipx upgrade-all 2>&1 | tee -a "$LOG_FILE"; then
        PIPX_STATUS="Success"
        log "Success" "pipx upgrades completed successfully"
    else
        PIPX_STATUS="Warning"
        log "Warning" "pipx upgrade-all encountered issues."
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
    local check_status=0
    check_output="$(rustup check 2>&1)"
    check_status=$?
    printf '%s\n' "$check_output" | tee -a "$LOG_FILE"

    if echo "$check_output" | grep -qi "update available"; then
        log "Info" "Running: rustup update"
        if rustup update 2>&1 | tee -a "$LOG_FILE"; then
            RUSTUP_STATUS="Success"
            log "Success" "rustup updates completed successfully"
        else
            RUSTUP_STATUS="Warning"
            log "Warning" "rustup update encountered issues."
        fi
    else
        if [ "$check_status" -ne 0 ]; then
            RUSTUP_STATUS="Warning"
            log "Warning" "rustup check encountered issues."
            return
        fi

        RUSTUP_STATUS="Success"
        log "Success" "Rust toolchains are already up-to-date"
    fi
}

show_summary() {
    echo ""
    log "Info" "============================================================"
    log "Info" "UPDATE SUMMARY"
    log "Info" "============================================================"

    local has_errors=false
    local summary_lines=(
        "Homebrew:  $BREW_STATUS"
        "App Store: $MAS_STATUS"
        "MacUpdater: $MACUPDATER_STATUS"
        "NPM:       $NPM_STATUS"
        "PIP:       $PIP_STATUS"
        "PIPX:      $PIPX_STATUS"
        "Rustup:    $RUSTUP_STATUS"
    )
    local summary_message

    printf '%s\n' "${summary_lines[@]}" | tee -a "$LOG_FILE"
    summary_message="$(printf '%s\n' "${summary_lines[@]}")"

    if [[ "$BREW_STATUS" == "Error" || "$MAS_STATUS" == "Error" || "$MACUPDATER_STATUS" == "Error" || "$NPM_STATUS" == "Error" || "$PIP_STATUS" == "Error" || "$PIPX_STATUS" == "Error" || "$RUSTUP_STATUS" == "Error" ]]; then
        has_errors=true
    fi

    log "Info" "============================================================"
    log "Info" "Log file saved to: $LOG_FILE"

    if [ "$has_errors" = true ]; then
        show_notification "Package Updates Completed with Errors" "$summary_message"
    else
        show_notification "Package Updates Complete" "$summary_message"
    fi
}

cleanup_logs() {
    log "Info" "Cleaning up old log files (keeping most recent 3)..."
    ls -t "${LOG_DIR}/${SCRIPT_NAME}_${MACHINE_NAME}_"*.log 2>/dev/null | tail -n +4 | xargs -r rm -f
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Ensure log file exists
touch "$LOG_FILE"

log "Info" "============================================================"
log "Info" "PACKAGE UPDATE STARTED (User=$(whoami))"
log "Info" "Script Directory: $SCRIPT_DIR"
log "Info" "Log File: $LOG_FILE"
log "Info" "============================================================"

if ! launch_interactive_terminal; then
    log "Error" "Interactive launch failed."
    exit 1
fi

# Check for Data Saver / Low Data Mode
if is_data_saver_active; then
    log "Warning" "Low Data Mode (Data Saver) detected. Skipping auto updates to conserve data."
    show_notification "Package Updates Skipped" "Low Data Mode detected. Updates deferred to save data."
    exit 0
fi

# Cleanup
cleanup_logs

# Show start notification
show_notification "Package Updates" "Starting updates for Homebrew, App Store, MacUpdater, npm, pipx, and rustup..."

# Run Updates
update_brew
update_mas
update_macupdater_apps
update_npm
update_pip
update_pipx
update_rustup

# Summary
show_summary

echo ""
log "Info" "Update process completed."
if [ -t 0 ]; then
    read -p "Press Enter to close..."
fi

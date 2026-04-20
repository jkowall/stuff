#!/bin/bash

# SYNOPSIS
#     Weekly package update script for Homebrew, mas, npm, pip, and rustup on macOS.
# DESCRIPTION
#     Updates all packages from Homebrew (formulae and casks), Mac App Store (via mas), npm global packages, pip, and rustup-managed Rust toolchains.
#     Logs all output to a timestamped file and shows desktop notifications.

# ============================================================================
# CONFIGURATION
# ============================================================================

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$(dirname "$SCRIPT_DIR")/logs"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
MACHINE_NAME="$(hostname)"
TIMESTAMP="$(date +%Y-%m-%d_%H-%m)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_${MACHINE_NAME}_${TIMESTAMP}.log"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Status tracking
BREW_STATUS="Skipped"
MAS_STATUS="Skipped"
NPM_STATUS="Skipped"
PIP_STATUS="Skipped"
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

show_notification() {
    local title="$1"
    local message="$2"
    
    # macOS native notification via AppleScript
    osascript -e "display notification \"$message\" with title \"$title\""
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
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING PIP UPDATES"
    log "Info" "============================================================"

    log "Info" "Upgrading pip itself..."
    pip3 install --upgrade pip 2>&1 | tee -a "$LOG_FILE"

    log "Info" "Checking for outdated packages..."
    OUTDATED_JSON=$(pip3 list --outdated --format=json 2>/dev/null) || true

    if [ -z "$OUTDATED_JSON" ] || [ "$OUTDATED_JSON" = "[]" ]; then
        PIP_STATUS="Success"
        log "Success" "pip packages are already up-to-date"
        return
    fi

    PACKAGES=$(echo "$OUTDATED_JSON" | python3 -c "import sys,json; print(' '.join(p['name'] for p in json.load(sys.stdin)))" 2>/dev/null) || true

    if [ -z "$PACKAGES" ]; then
        PIP_STATUS="Success"
        log "Success" "pip packages are already up-to-date"
        return
    fi

    log "Info" "Found outdated packages: $(echo $PACKAGES | tr ' ' ', ')"

    # Upgrade one at a time to avoid dependency conflicts
    local succeeded=0
    local failed=""
    for pkg in $PACKAGES; do
        if pip3 install --upgrade "$pkg" >> "$LOG_FILE" 2>&1; then
            log "Success" "  Upgraded $pkg"
            succeeded=$((succeeded + 1))
        else
            log "Warning" "  Failed to upgrade $pkg (dependency conflict)"
            failed="$failed $pkg"
        fi
    done

    if [ -n "$failed" ]; then
        PIP_STATUS="Warning"
        log "Warning" "pip: $succeeded upgraded, some skipped due to dependency conflicts:$failed"
    else
        PIP_STATUS="Success"
        log "Success" "pip updates completed successfully ($succeeded upgraded)"
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
    if ! check_output=$(rustup check 2>&1 | tee -a "$LOG_FILE"); then
        RUSTUP_STATUS="Warning"
        log "Warning" "rustup check encountered issues."
        return
    fi

    if echo "$check_output" | grep -q "Update available"; then
        log "Info" "Running: rustup update"
        if rustup update 2>&1 | tee -a "$LOG_FILE"; then
            RUSTUP_STATUS="Success"
            log "Success" "rustup updates completed successfully"
        else
            RUSTUP_STATUS="Warning"
            log "Warning" "rustup update encountered issues."
        fi
    else
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

    echo "Homebrew:  $BREW_STATUS"
    echo "App Store: $MAS_STATUS"
    echo "NPM:       $NPM_STATUS"
    echo "PIP:       $PIP_STATUS"
    echo "Rustup:    $RUSTUP_STATUS"

    if [[ "$BREW_STATUS" == "Error" || "$MAS_STATUS" == "Error" || "$NPM_STATUS" == "Error" || "$PIP_STATUS" == "Error" || "$RUSTUP_STATUS" == "Error" ]]; then
        has_errors=true
    fi

    log "Info" "============================================================"
    log "Info" "Log file saved to: $LOG_FILE"

    if [ "$has_errors" = true ]; then
        show_notification "Package Updates" "Completed with Errors. Check log."
    else
        show_notification "Package Updates" "All systems updated successfully!"
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

# Check for Data Saver / Low Data Mode
if is_data_saver_active; then
    log "Warning" "Low Data Mode (Data Saver) detected. Skipping auto updates to conserve data."
    show_notification "Package Updates Skipped" "Low Data Mode detected. Updates deferred to save data."
    exit 0
fi

# Cleanup
cleanup_logs

# Show start notification
show_notification "Package Updates" "Starting updates for Homebrew, App Store, npm, pip, and rustup..."

# Run Updates
update_brew
update_mas
update_npm
update_pip
update_rustup

# Summary
show_summary

echo ""
log "Info" "Update process completed."
if [ -t 0 ]; then
    read -p "Press Enter to close..."
fi

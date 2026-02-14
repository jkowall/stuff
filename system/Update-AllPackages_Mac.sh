#!/bin/bash

# SYNOPSIS
#     Weekly package update script for Homebrew, mas, and npm on macOS.
# DESCRIPTION
#     Updates all packages from Homebrew (formulae and casks), Mac App Store (via mas), and npm global packages.
#     Logs all output to a timestamped file and shows desktop notifications.

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
MACHINE_NAME="$(hostname)"
TIMESTAMP="$(date +%Y-%m-%d_%H-%m)"
LOG_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}_${MACHINE_NAME}_${TIMESTAMP}.log"

# Status tracking
BREW_STATUS="Skipped"
MAS_STATUS="Skipped"
NPM_STATUS="Skipped"

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
    if brew update >> "$LOG_FILE" 2>&1; then
        log "Info" "Running: brew upgrade"
        if brew upgrade >> "$LOG_FILE" 2>&1; then
            log "Info" "Running: brew cleanup"
            brew cleanup >> "$LOG_FILE" 2>&1
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
    if mas upgrade >> "$LOG_FILE" 2>&1; then
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

    log "Info" "Running: npm update -g"
    if npm update -g >> "$LOG_FILE" 2>&1; then
        NPM_STATUS="Success"
        log "Success" "NPM global updates completed successfully"
    else
        NPM_STATUS="Warning"
        log "Warning" "NPM update encountered issues."
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

    if [[ "$BREW_STATUS" == "Error" || "$MAS_STATUS" == "Error" || "$NPM_STATUS" == "Error" ]]; then
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
    ls -t "${SCRIPT_DIR}/${SCRIPT_NAME}_${MACHINE_NAME}_"*.log 2>/dev/null | tail -n +4 | xargs -r rm -f
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

# Cleanup
cleanup_logs

# Show start notification
show_notification "Package Updates" "Starting updates for Homebrew, App Store, and npm..."

# Run Updates
update_brew
update_mas
update_npm

# Summary
show_summary

echo ""
log "Info" "Update process completed."
if [ -t 0 ]; then
    read -p "Press Enter to close..."
fi

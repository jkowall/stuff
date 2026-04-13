#!/bin/bash

# SYNOPSIS
#     Weekly package update script for apt, snap, flatpak, npm, pip, and rustup.
# DESCRIPTION
#     Updates all packages from apt, snap, flatpak, npm global packages, pip, and rustup-managed Rust toolchains.
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
APT_STATUS="Skipped"
SNAP_STATUS="Skipped"
FLATPAK_STATUS="Skipped"
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

update_apt() {
    log "Info" "============================================================"
    log "Info" "STARTING APT UPDATES"
    log "Info" "============================================================"

    if [ "$EUID" -ne 0 ]; then
        log "Error" "Apt update requires root privileges. Please run with sudo."
        APT_STATUS="Error"
        return
    fi

    log "Info" "Running: apt update"
    if apt-get update -y >> "$LOG_FILE" 2>&1; then
        log "Info" "Running: apt upgrade -y"
        if apt-get upgrade -y >> "$LOG_FILE" 2>&1; then
            APT_STATUS="Success"
            log "Success" "Apt updates completed successfully"
        else
            APT_STATUS="Warning"
            log "Warning" "Apt upgrade encountered issues. Check log."
        fi
    else
        APT_STATUS="Error"
        log "Error" "Apt update failed."
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

    log "Info" "Running: snap refresh"
    if snap refresh >> "$LOG_FILE" 2>&1; then
        SNAP_STATUS="Success"
        log "Success" "Snap updates completed successfully"
    else
        SNAP_STATUS="Warning"
        log "Warning" "Snap refresh encountered issues."
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

    log "Info" "Running: flatpak update -y"
    if flatpak update -y >> "$LOG_FILE" 2>&1; then
        FLATPAK_STATUS="Success"
        log "Success" "Flatpak updates completed successfully"
    else
        FLATPAK_STATUS="Warning"
        log "Warning" "Flatpak update encountered issues."
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
        if npm install -g $OUTDATED >> "$LOG_FILE" 2>&1; then
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

    echo -e "APT:      $APT_STATUS"
    echo -e "SNAP:     $SNAP_STATUS"
    echo -e "FLATPAK:  $FLATPAK_STATUS"
    echo -e "NPM:      $NPM_STATUS"
    echo -e "PIP:      $PIP_STATUS"
    echo -e "RUSTUP:   $RUSTUP_STATUS"

    if [[ "$APT_STATUS" == "Error" || "$SNAP_STATUS" == "Error" || "$FLATPAK_STATUS" == "Error" || "$NPM_STATUS" == "Error" || "$PIP_STATUS" == "Error" || "$RUSTUP_STATUS" == "Error" ]]; then
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

cleanup_logs() {
    log "Info" "Cleaning up old log files (keeping most recent 3)..."
    ls -t "${SCRIPT_DIR}/${SCRIPT_NAME}_${MACHINE_NAME}_"*.log 2>/dev/null | tail -n +4 | xargs -r rm -f
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Ensure the script is running as root (self-elevate)
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges for package updates. Elevating..."
    exec sudo "$0" "$@"
fi

# Ensure log file exists and is owned by the actual user if possible, 
# but for simplicity in system scripts, root-owned logs in script dir is fine.
touch "$LOG_FILE"
chmod 666 "$LOG_FILE" 2>/dev/null 

log "Info" "============================================================"
log "Info" "PACKAGE UPDATE STARTED (User=$(whoami), ActualUser=${SUDO_USER:-$(whoami)})"
log "Info" "Script Directory: $SCRIPT_DIR"
log "Info" "Log File: $LOG_FILE"
log "Info" "============================================================"

# Cleanup
cleanup_logs

# Show start notification
# Note: notify-send as root needs to find the user session. 
# We use SUDO_USER if available to try and show it on the correct desktop.
if [ -n "$SUDO_USER" ]; then
    if ! sudo -u "$SUDO_USER" DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$SUDO_USER")/bus \
        notify-send -u low "Package Updates" "Starting updates for apt, snap, flatpak, npm, pip, and rustup..." >/dev/null 2>&1; then
        log "Info" "Desktop notification environment unavailable. Skipping start notification."
    fi
else
    show_notification "Package Updates Starting" "Updating apt, snap, flatpak, npm, pip, and rustup packages..." "low"
fi

# Run Updates
update_apt
update_snap
update_flatpak
update_npm
update_pip
update_rustup

# Summary
show_summary

echo ""
log "Info" "Update process completed."
# No read-host equivalent usually needed in bash for non-interactive execution, but added for terminal clarity
if [ -t 0 ]; then
    read -p "Press Enter to close..."
fi

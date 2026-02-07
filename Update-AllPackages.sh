#!/bin/bash

################################################################################
# Update-AllPackages.sh
# macOS Package Manager Update Script
#
# SYNOPSIS
#     Updates all packages from Homebrew, MacPorts, npm, and pip.
#
# DESCRIPTION
#     Updates all packages from Homebrew (including casks), MacPorts (if installed),
#     npm global packages, and pip Python packages. Creates timestamped logs
#     and shows macOS notifications.
#
# USAGE
#     ./Update-AllPackages.sh [OPTIONS]
#
# OPTIONS
#     --skip-brew           Skip Homebrew updates
#     --skip-brew-cask      Skip Homebrew Cask updates
#     --skip-macports       Skip MacPorts updates
#     --skip-npm            Skip npm global updates
#     --skip-pip            Skip pip/pip3 updates
#
# AUTHOR
#     Auto-generated for macOS
#
################################################################################

# Exit on error
set -eo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
LOG_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}_${TIMESTAMP}.log"

# Parse command-line flags
SKIP_BREW=false
SKIP_BREW_CASK=false
SKIP_MACPORTS=false
SKIP_NPM=false
SKIP_PIP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-brew) SKIP_BREW=true; shift ;;
        --skip-brew-cask) SKIP_BREW_CASK=true; shift ;;
        --skip-macports) SKIP_MACPORTS=true; shift ;;
        --skip-npm) SKIP_NPM=true; shift ;;
        --skip-pip) SKIP_PIP=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

write_log() {
    local message="$1"
    local level="${2:-Info}"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local log_entry="[$timestamp] [$level] $message"
    
    # Determine color
    local color=""
    case $level in
        Success) color="\033[32m" ;;     # Green
        Warning) color="\033[33m" ;;     # Yellow
        Error) color="\033[31m" ;;       # Red
        *) color="\033[0m" ;;            # Reset
    esac
    
    echo -e "${color}${log_entry}\033[0m"
    echo "$log_entry" >> "$LOG_FILE"
}

show_notification() {
    local title="$1"
    local message="$2"
    osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
}

update_homebrew() {
    write_log "$(printf '=%.0s' {1..60})" Info
    write_log "STARTING HOMEBREW UPDATES" Info
    write_log "$(printf '=%.0s' {1..60})" Info
    
    if ! command -v brew &> /dev/null; then
        write_log "ERROR: Homebrew not found" Error
        return 1
    fi
    
    write_log "Found Homebrew at: $(which brew)" Info
    write_log "Running: brew update" Info
    
    if brew update 2>&1 | tee -a "$LOG_FILE"; then
        write_log "Running: brew upgrade" Info
        if brew upgrade 2>&1 | tee -a "$LOG_FILE"; then
            write_log "Homebrew updates completed successfully" Success
            return 0
        fi
    fi
    
    write_log "Homebrew updates had issues" Error
    return 1
}

update_homebrew_cask() {
    write_log "$(printf '=%.0s' {1..60})" Info
    write_log "STARTING HOMEBREW CASK UPDATES" Info
    write_log "$(printf '=%.0s' {1..60})" Info
    
    if ! command -v brew &> /dev/null; then
        write_log "ERROR: Homebrew not found" Error
        return 1
    fi
    
    write_log "Running: brew upgrade --cask" Info
    
    if brew upgrade --cask 2>&1 | tee -a "$LOG_FILE"; then
        write_log "Homebrew Cask updates completed successfully" Success
        return 0
    else
        write_log "Homebrew Cask updates had issues" Error
        return 1
    fi
}

update_macports() {
    write_log "$(printf '=%.0s' {1..60})" Info
    write_log "STARTING MACPORTS UPDATES" Info
    write_log "$(printf '=%.0s' {1..60})" Info
    
    if ! command -v port &> /dev/null; then
        write_log "MacPorts not installed - skipping" Info
        return 0
    fi
    
    write_log "Found MacPorts at: $(which port)" Info
    write_log "Running: sudo port selfupdate" Info
    
    if sudo port selfupdate 2>&1 | tee -a "$LOG_FILE"; then
        write_log "Running: sudo port upgrade outdated" Info
        if sudo port upgrade outdated 2>&1 | tee -a "$LOG_FILE"; then
            write_log "MacPorts updates completed successfully" Success
            return 0
        fi
    fi
    
    write_log "MacPorts updates had issues" Error
    return 1
}

update_npm() {
    write_log "$(printf '=%.0s' {1..60})" Info
    write_log "STARTING NPM GLOBAL UPDATES" Info
    write_log "$(printf '=%.0s' {1..60})" Info
    
    if ! command -v npm &> /dev/null; then
        write_log "ERROR: npm not found" Error
        return 1
    fi
    
    write_log "Found npm at: $(which npm)" Info
    write_log "Checking for outdated packages..." Info
    npm outdated -g 2>&1 | tee -a "$LOG_FILE" || true
    
    write_log "Running: npm update -g" Info
    if npm update -g 2>&1 | tee -a "$LOG_FILE"; then
        write_log "npm global updates completed successfully" Success
        return 0
    else
        write_log "npm updates had issues" Error
        return 1
    fi
}

update_pip() {
    write_log "$(printf '=%.0s' {1..60})" Info
    write_log "STARTING PIP UPDATES" Info
    write_log "$(printf '=%.0s' {1..60})" Info
    
    # Detect pip
    local pip_cmd=""
    if command -v pip3 &> /dev/null; then
        pip_cmd="pip3"
    elif command -v pip &> /dev/null; then
        pip_cmd="pip"
    else
        write_log "ERROR: pip/pip3 not found" Error
        return 1
    fi
    
    write_log "Found pip at: $(which $pip_cmd)" Info
    write_log "Running: $pip_cmd list --outdated" Info
    $pip_cmd list --outdated 2>&1 | tee -a "$LOG_FILE" || true
    
    write_log "Running: $pip_cmd install --upgrade pip" Info
    $pip_cmd install --upgrade pip 2>&1 | tee -a "$LOG_FILE" || true
    
    # Get list of outdated packages and upgrade
    write_log "Finding outdated packages..." Info
    local outdated=$($pip_cmd list --outdated --format=json 2>/dev/null | python3 -c 'import json,sys; pkgs=[x["name"] for x in json.load(sys.stdin)]; print(" ".join(pkgs))' 2>/dev/null || echo "")
    
    if [ -n "$outdated" ]; then
        write_log "Upgrading packages: $outdated" Info
        if $pip_cmd install --upgrade $outdated 2>&1 | tee -a "$LOG_FILE"; then
            write_log "pip packages updated successfully" Success
            return 0
        else
            write_log "pip updates had issues" Error
            return 1
        fi
    else
        write_log "All pip packages are up to date" Success
        return 0
    fi
}

show_summary() {
    write_log "" Info
    write_log "$(printf '=%.0s' {1..60})" Info
    write_log "UPDATE SUMMARY" Info
    write_log "$(printf '=%.0s' {1..60})" Info
    write_log "Log file saved to: $LOG_FILE" Info
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Show interactive menu
clear
echo ""
echo "========================================"
echo "  macOS Package Manager Update v1.0     "
echo "========================================"
echo ""
echo "This script will update:"
echo "  - Homebrew (brew)"
echo "  - Homebrew Casks (GUI apps)"
echo "  - MacPorts (if installed)"
echo "  - npm (global packages)"
echo "  - pip/pip3 (Python packages)"
echo ""
echo "Log file: $LOG_FILE"
echo ""
echo -n "Proceed with package updates? (y/n): "
read -r -n 1 REPLY
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Updates cancelled."
    exit 0
fi

echo ""

# Initialize log
write_log "$(printf '=%.0s' {1..60})" Info
write_log "PACKAGE UPDATE STARTED" Info
write_log "Script Directory: $SCRIPT_DIR" Info
write_log "Log File: $LOG_FILE" Info
write_log "$(printf '=%.0s' {1..60})" Info

# Show notification
show_notification "Package Updates Starting" "Updating macOS packages..."

# Clean up old logs (keep 3 most recent)
write_log "Cleaning up old log files..." Info
find "$SCRIPT_DIR" -name "${SCRIPT_NAME}_*.log" -type f | sort -r | tail -n +4 | while read -r old_log; do
    write_log "  Removing: $(basename "$old_log")" Info
    rm -f "$old_log"
done

# Track success/errors
HAS_ERRORS=0

# Run updates
if [ "$SKIP_BREW" = false ]; then
    update_homebrew || HAS_ERRORS=1
else
    write_log "Skipping Homebrew updates (flag set)" Info
fi

if [ "$SKIP_BREW_CASK" = false ]; then
    update_homebrew_cask || HAS_ERRORS=1
else
    write_log "Skipping Homebrew Cask updates (flag set)" Info
fi

if [ "$SKIP_MACPORTS" = false ]; then
    update_macports || HAS_ERRORS=1
else
    write_log "Skipping MacPorts updates (flag set)" Info
fi

if [ "$SKIP_NPM" = false ]; then
    update_npm || HAS_ERRORS=1
else
    write_log "Skipping npm updates (flag set)" Info
fi

if [ "$SKIP_PIP" = false ]; then
    update_pip || HAS_ERRORS=1
else
    write_log "Skipping pip updates (flag set)" Info
fi

# Show summary
show_summary

write_log "" Info
write_log "Update process completed." Info

# Show final result
echo ""
echo "========================================"
echo "         Updates Complete!              "
echo "========================================"
echo ""
if [ $HAS_ERRORS -eq 0 ]; then
    show_notification "Package Updates Completed" "All updates completed successfully!"
else
    show_notification "Package Updates Completed" "Some updates had warnings. Check log for details."
fi

echo "To view the full log file, run:"
echo "  cat \"$LOG_FILE\""
echo ""
echo -n "Press Enter to exit..."
read -r

exit 0

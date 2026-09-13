#!/bin/bash
#
# Pulls and applies the latest chezmoi-managed dotfiles (Claude/Codex/Antigravity/Cursor config).
# Thin wrapper around `chezmoi update`. Intended to be invoked by the cached runner that
# Setup-DotfileSyncTask_Mac.sh installs, or run manually at any time.

set -uo pipefail

LOG_DIR="${HOME}/Library/Logs"
LOG_FILE="${LOG_DIR}/com.jkowa.chezmoi-dotfile-sync.log"
mkdir -p "$LOG_DIR"

write_status() {
    local level="$1"
    local message="$2"
    local color=""
    case "$level" in
        "Info")    color="\033[36m" ;;
        "Success") color="\033[32m" ;;
        "Warning") color="\033[33m" ;;
        "Error")   color="\033[31m" ;;
    esac
    if [ -t 1 ]; then
        printf '%b\n' "${color}${message}\033[0m"
    else
        printf '%s\n' "$message"
    fi
}

if ! command -v chezmoi >/dev/null 2>&1; then
    write_status "Error" "chezmoi is not installed or not on PATH. Run Bootstrap-Machine_Mac.sh first."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: chezmoi not found" >> "$LOG_FILE"
    exit 1
fi

write_status "Info" "Running chezmoi update..."

{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] chezmoi update"
    chezmoi update --verbose
    exit_code=$?
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] exit $exit_code"
} >> "$LOG_FILE" 2>&1

if [ "$exit_code" -eq 0 ]; then
    write_status "Success" "Dotfiles are up to date."
else
    write_status "Error" "chezmoi update failed (exit $exit_code). See $LOG_FILE"
fi

exit "$exit_code"

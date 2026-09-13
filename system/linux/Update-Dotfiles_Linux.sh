#!/bin/bash
#
# Pulls and applies the latest chezmoi-managed dotfiles (Claude/Codex/Antigravity/Cursor config).
# Thin wrapper around `chezmoi update`. Works the same under native Linux and WSL.

set -uo pipefail

LOG_DIR="${HOME}/.local/state/dotfile-sync"
LOG_FILE="${LOG_DIR}/dotfile-sync.log"
mkdir -p "$LOG_DIR"

write_status() {
    local level="$1"
    local message="$2"
    local color=""
    case "$level" in
        "Info")    color="\e[36m" ;;
        "Success") color="\e[32m" ;;
        "Warning") color="\e[33m" ;;
        "Error")   color="\e[31m" ;;
    esac
    if [ -t 1 ]; then
        echo -e "${color}${message}\e[0m"
    else
        echo "$message"
    fi
}

if ! command -v chezmoi >/dev/null 2>&1; then
    write_status "Error" "chezmoi is not installed or not on PATH. Run Bootstrap-Machine_Linux.sh first."
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

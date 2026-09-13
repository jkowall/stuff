#!/bin/bash
#
# Bootstraps a fresh (or existing) macOS machine onto the chezmoi-managed dotfiles.
# Installs chezmoi if missing, initializes and applies the dotfiles source from the
# private repo, then installs the recurring sync launchd job. Safe to re-run.
#
# Usage: ./Bootstrap-Machine_Mac.sh [repo-url]
#   repo-url defaults to the SSH remote; pass the HTTPS URL instead if that's
#   what you've already authenticated on this machine.

set -euo pipefail

REPO_URL="${1:-git@github.com:jkowall/Private.git}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_TASK_SCRIPT="${SCRIPT_DIR}/Setup-DotfileSyncTask_Mac.sh"

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
    printf '%b\n' "${color}${message}\033[0m"
}

# 1. Install chezmoi if missing
if ! command -v chezmoi >/dev/null 2>&1; then
    write_status "Info" "chezmoi not found. Installing via Homebrew..."
    if command -v brew >/dev/null 2>&1; then
        brew install chezmoi
    else
        sh -c "$(curl -fsLS https://get.chezmoi.io)"
        export PATH="$HOME/.local/bin:$PATH"
    fi
    if ! command -v chezmoi >/dev/null 2>&1; then
        write_status "Error" "chezmoi install did not put it on PATH. Open a new shell and re-run this script."
        exit 1
    fi
    write_status "Success" "chezmoi installed."
else
    write_status "Success" "chezmoi already installed ($(chezmoi --version))."
fi

# 2. Initialize + apply the dotfiles source (idempotent)
SOURCE_PATH="$(chezmoi source-path 2>/dev/null || true)"
if [ -z "$SOURCE_PATH" ] || [ ! -d "$SOURCE_PATH" ]; then
    write_status "Info" "Initializing chezmoi from ${REPO_URL} ..."
    chezmoi init --apply "$REPO_URL"
    write_status "Success" "Dotfiles applied."
else
    write_status "Info" "chezmoi already initialized at ${SOURCE_PATH}. Running chezmoi update instead..."
    chezmoi update --verbose
fi

# 3. Install the recurring sync task
if [ ! -f "$SETUP_TASK_SCRIPT" ]; then
    write_status "Error" "Setup-DotfileSyncTask_Mac.sh not found next to this script at: ${SETUP_TASK_SCRIPT}"
    exit 1
fi

write_status "Info" "Installing the recurring dotfile-sync launchd job..."
"$SETUP_TASK_SCRIPT"

write_status "Success" "Bootstrap complete."

#!/bin/bash
#
# Bootstraps a fresh (or existing) Linux machine -- native or WSL -- onto the
# chezmoi-managed dotfiles. Installs chezmoi if missing, initializes and applies
# the dotfiles source from the private repo, then installs the recurring sync
# crontab entries. Safe to re-run.
#
# Usage: ./Bootstrap-Machine_Linux.sh [repo-url]
#   repo-url defaults to the SSH remote; pass the HTTPS URL instead if that's
#   what you've already authenticated on this machine.

set -euo pipefail

REPO_URL="${1:-git@github.com:jkowall/Private.git}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_TASK_SCRIPT="${SCRIPT_DIR}/Setup-DotfileSyncTask_Linux.sh"

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
    echo -e "${color}${message}\e[0m"
}

# Downloads the chezmoi release binary directly from GitHub and installs it to
# ~/.local/bin. Deliberately does NOT use the curl|sh installer at get.chezmoi.io:
# in testing it failed intermittently in ways that are hard to diagnose (the
# downloaded installer script parsed fine on its own, but repeated invocations
# sometimes produced a "chezmoi: <line>: Syntax error" from dash) -- fetching the
# known release asset directly is simpler and fully within our control.
install_chezmoi_from_release() {
    local os="linux"
    local arch
    case "$(uname -m)" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)
            write_status "Error" "Unsupported architecture: $(uname -m)"
            return 1
            ;;
    esac

    local version
    # No `grep -m1`: an early-exiting reader on the pipe can SIGPIPE curl mid-write,
    # which `set -e pipefail` then treats as a hard failure even if the value was
    # already captured. Let grep read the whole (small) response instead.
    version="$(curl -fsSL https://api.github.com/repos/twpayne/chezmoi/releases/latest \
        | grep '"tag_name"' | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/')"
    if [ -z "$version" ]; then
        write_status "Error" "Could not determine the latest chezmoi version from the GitHub API."
        return 1
    fi

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local tarball="${tmp_dir}/chezmoi.tar.gz"
    local url="https://github.com/twpayne/chezmoi/releases/download/v${version}/chezmoi_${version}_${os}_${arch}.tar.gz"

    write_status "Info" "Downloading chezmoi v${version} for ${os}/${arch}..."
    if ! curl -fsSL -o "$tarball" "$url"; then
        write_status "Error" "Failed to download ${url}"
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p "$HOME/.local/bin"
    tar -xzf "$tarball" -C "$tmp_dir" chezmoi
    install -m 755 "${tmp_dir}/chezmoi" "$HOME/.local/bin/chezmoi"
    rm -rf "$tmp_dir"
    export PATH="$HOME/.local/bin:$PATH"
}

# 1. Install chezmoi if missing
if ! command -v chezmoi >/dev/null 2>&1; then
    write_status "Info" "chezmoi not found. Installing..."
    install_chezmoi_from_release
    if ! command -v chezmoi >/dev/null 2>&1; then
        write_status "Error" "chezmoi install did not put it on PATH. Open a new shell and re-run this script."
        exit 1
    fi
    write_status "Success" "chezmoi installed ($(chezmoi --version))."
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
    write_status "Error" "Setup-DotfileSyncTask_Linux.sh not found next to this script at: ${SETUP_TASK_SCRIPT}"
    exit 1
fi

write_status "Info" "Installing the recurring dotfile-sync crontab entries..."
"$SETUP_TASK_SCRIPT"

write_status "Success" "Bootstrap complete."

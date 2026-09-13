#!/bin/bash
#
# Installs or removes a per-user crontab entry that keeps chezmoi-managed dotfiles
# synced every 30 minutes and at boot (@reboot -- the closest cron equivalent to
# "at logon" on a machine without a desktop session, which covers WSL too).
#
# Unlike Setup-PackageUpdateTasks_Linux.sh, this runs as the invoking user (not root)
# via the user's own crontab, since chezmoi update needs the user's own git/SSH
# credentials, not root's.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="${SCRIPT_DIR}/Update-Dotfiles_Linux.sh"
CRON_MARKER="# chezmoi-dotfile-sync"
CRON_SCHEDULE="*/30 * * * *"

write_status() {
    local level="$1"
    local message="$2"
    local color=""
    case "$level" in
        "Info")    color="\e[36m" ;;
        "Success") color="\e[32m" ;;
        "Warning") color="\e[33m" ;;
        "Error")   color="\e[31m" ;;
        *)         color="\e[0m"  ;;
    esac
    echo -e "${color}${message}\e[0m"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--remove]

Installs or removes this user's crontab entries for chezmoi dotfile sync
(every 30 minutes, plus @reboot).
EOF
}

remove_schedule() {
    local current_cron
    if ! current_cron="$(crontab -l 2>/dev/null)"; then
        write_status "Info" "No crontab found for $(whoami); nothing to remove."
        return
    fi

    local updated_cron
    updated_cron="$(printf '%s\n' "$current_cron" | grep -Fv "$CRON_MARKER" | grep -Fv "$UPDATE_SCRIPT" || true)"

    if [ "$updated_cron" = "$current_cron" ]; then
        write_status "Info" "No dotfile-sync crontab entries found."
        return
    fi

    if [ -n "$updated_cron" ]; then
        printf '%s\n' "$updated_cron" | crontab -
    else
        crontab -r
    fi
    write_status "Success" "Removed dotfile-sync crontab entries."
}

install_schedule() {
    if ! command -v crontab >/dev/null 2>&1; then
        write_status "Error" "crontab is not available. On WSL, install cron (sudo apt install cron) and ensure the service is running, or use Windows Task Scheduler on the Windows side instead."
        exit 1
    fi

    if [ ! -f "$UPDATE_SCRIPT" ]; then
        write_status "Error" "Update script not found: ${UPDATE_SCRIPT}"
        exit 1
    fi

    local current_cron
    current_cron="$(crontab -l 2>/dev/null || true)"
    local filtered_cron
    filtered_cron="$(printf '%s\n' "$current_cron" | grep -Fv "$CRON_MARKER" | grep -Fv "$UPDATE_SCRIPT" || true)"

    {
        if [ -n "$filtered_cron" ]; then
            printf '%s\n' "$filtered_cron"
        fi
        echo "${CRON_MARKER}"
        echo "${CRON_SCHEDULE} /bin/bash ${UPDATE_SCRIPT} >/dev/null 2>&1"
        echo "@reboot /bin/bash ${UPDATE_SCRIPT} >/dev/null 2>&1 ${CRON_MARKER}"
    } | crontab -

    write_status "Success" "Installed crontab entries for dotfile sync."
    write_status "Info" "Schedule: ${CRON_SCHEDULE}, plus @reboot"
    write_status "Info" "Script: ${UPDATE_SCRIPT}"
    write_status "Info" "To remove: $(basename "$0") --remove"

    if ! pgrep -x cron >/dev/null 2>&1 && ! pgrep -x crond >/dev/null 2>&1; then
        write_status "Warning" "cron daemon doesn't appear to be running. On WSL: sudo service cron start (and consider adding that to your shell profile, since WSL doesn't start services automatically)."
    fi
}

main() {
    case "${1:-}" in
        "") install_schedule ;;
        "--remove") remove_schedule ;;
        "-h"|"--help") usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi

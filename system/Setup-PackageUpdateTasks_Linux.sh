#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="${SCRIPT_DIR}/Update-AllPackages_Linux.sh"
LEGACY_UPDATE_SCRIPT="$(realpath "$UPDATE_SCRIPT" 2>/dev/null || printf '%s' "$UPDATE_SCRIPT")"
CRON_FILE="/etc/cron.d/weekly-package-updates"
CRON_SCHEDULE="0 1 * * 6"

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

Installs or removes the weekly cron schedule for Update-AllPackages_Linux.sh.
Also removes legacy crontab entries created by older self-scheduling versions.
EOF
}

require_root() {
    if [ "$EUID" -eq 0 ]; then
        return
    fi

    write_status "Info" "Elevating with sudo to manage system cron configuration..."
    exec sudo "$0" "$@"
}

rewrite_crontab_without_pattern() {
    local user_name="$1"
    local pattern="$2"
    local current_cron
    local updated_cron

    if ! current_cron="$(crontab -l -u "$user_name" 2>/dev/null)"; then
        return
    fi

    updated_cron="$(printf '%s\n' "$current_cron" | grep -Fv "$pattern" || true)"
    if [ "$updated_cron" = "$current_cron" ]; then
        return
    fi

    if [ -n "$updated_cron" ]; then
        printf '%s\n' "$updated_cron" | crontab -u "$user_name" -
    else
        crontab -r -u "$user_name"
    fi

    write_status "Info" "Removed legacy crontab entries for ${user_name}."
}

cleanup_legacy_crontabs() {
    rewrite_crontab_without_pattern "root" "$UPDATE_SCRIPT"
    if [ "$LEGACY_UPDATE_SCRIPT" != "$UPDATE_SCRIPT" ]; then
        rewrite_crontab_without_pattern "root" "$LEGACY_UPDATE_SCRIPT"
    fi

    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        rewrite_crontab_without_pattern "$SUDO_USER" "$UPDATE_SCRIPT"
        if [ "$LEGACY_UPDATE_SCRIPT" != "$UPDATE_SCRIPT" ]; then
            rewrite_crontab_without_pattern "$SUDO_USER" "$LEGACY_UPDATE_SCRIPT"
        fi
    fi
}

install_schedule() {
    local escaped_script_path
    local temp_file

    cleanup_legacy_crontabs

    printf -v escaped_script_path '%q' "$UPDATE_SCRIPT"
    temp_file="$(mktemp)"

    cat > "$temp_file" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${CRON_SCHEDULE} root /bin/bash ${escaped_script_path} >> /dev/null 2>&1
EOF

    install -m 644 "$temp_file" "$CRON_FILE"
    rm -f "$temp_file"

    write_status "Success" "Installed weekly cron schedule at ${CRON_FILE}."
    write_status "Info" "Schedule: Every Saturday at 1:00 AM"
    write_status "Info" "Script: ${UPDATE_SCRIPT}"
}

remove_schedule() {
    cleanup_legacy_crontabs

    if [ -f "$CRON_FILE" ]; then
        rm -f "$CRON_FILE"
        write_status "Success" "Removed ${CRON_FILE}."
    else
        write_status "Info" "No cron.d schedule file found at ${CRON_FILE}."
    fi
}

main() {
    local remove_mode=false

    case "${1:-}" in
        "")
            ;;
        "--remove")
            remove_mode=true
            ;;
        "-h"|"--help")
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac

    require_root "$@"

    if [ ! -f "$UPDATE_SCRIPT" ]; then
        write_status "Error" "Update script not found: ${UPDATE_SCRIPT}"
        exit 1
    fi

    if [ "$remove_mode" = true ]; then
        remove_schedule
    else
        install_schedule
    fi
}

main "$@"

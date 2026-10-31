#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="${SCRIPT_DIR}/Update-AllPackages_Linux.sh"
UNIT_NAME="weekly-package-updates"
INSTALL_DIR="/usr/local/lib/${UNIT_NAME}"
CACHED_UPDATE_SCRIPT="${INSTALL_DIR}/Update-AllPackages_Linux.sh"
LOG_DIR="/var/log/package-updates"
SYSTEMD_DIR="/etc/systemd/system"
CRON_FILE="/etc/cron.d/${UNIT_NAME}"
CRON_SCHEDULE="0 1 * * 6"
TIMER_SCHEDULE="Sat *-*-* 01:00:00"

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

Installs or removes the weekly schedule for Update-AllPackages_Linux.sh.
The updater is copied to ${INSTALL_DIR} (root-owned) and refreshes itself
from GitHub at the start of each run. Logs go to ${LOG_DIR}.
Uses a systemd timer (Saturday 1:00 AM, Persistent=true, so a run missed while the
machine was off starts after the next boot); falls back to cron without systemd.
Not used on WSL: the Windows updater already updates WSL. --remove still works there.
Also removes legacy crontab entries created by older versions.
EOF
}

require_root() {
    if [ "$EUID" -eq 0 ]; then
        return
    fi

    write_status "Info" "Elevating with sudo to manage the system schedule..."
    exec sudo "$0" "$@"
}

is_wsl() {
    [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

has_systemd() {
    [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
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

# Matches by file name so entries pointing at older repo layouts (e.g. system/Update-AllPackages_Linux.sh) go too.
cleanup_legacy_crontabs() {
    local pattern
    pattern="$(basename "$UPDATE_SCRIPT")"

    rewrite_crontab_without_pattern "root" "$pattern"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        rewrite_crontab_without_pattern "$SUDO_USER" "$pattern"
    fi

    if [ -f "$CRON_FILE" ]; then
        rm -f "$CRON_FILE"
        write_status "Info" "Removed ${CRON_FILE}."
    fi
}

# The account whose per-user tools (pipx, uv, Claude Code) the scheduled root run should update.
package_update_user() {
    local user="${SUDO_USER:-}"
    if [ -z "$user" ] || [ "$user" = "root" ]; then
        user="$(stat -c %U "$UPDATE_SCRIPT" 2>/dev/null || true)"
    fi
    if [ "$user" = "root" ]; then
        user=""
    fi
    printf '%s' "$user"
}

install_cached_updater() {
    install -d -m 755 "$INSTALL_DIR"
    install -m 755 "$UPDATE_SCRIPT" "$CACHED_UPDATE_SCRIPT"
    install -d -m 755 "$LOG_DIR"
}

install_systemd_units() {
    local user="$1"

    cat > "${SYSTEMD_DIR}/${UNIT_NAME}.service" <<EOF
[Unit]
Description=Weekly package updates (Update-AllPackages_Linux.sh)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment="PACKAGE_UPDATE_USER=${user}"
Environment="PACKAGE_UPDATE_LOG_DIR=${LOG_DIR}"
ExecStart=/bin/bash ${CACHED_UPDATE_SCRIPT}
# Exit code 2 means the run finished with warnings.
SuccessExitStatus=2
EOF

    cat > "${SYSTEMD_DIR}/${UNIT_NAME}.timer" <<EOF
[Unit]
Description=Run weekly package updates every Saturday at 1:00 AM

[Timer]
OnCalendar=${TIMER_SCHEDULE}
# Run at the next boot if the machine was off at the scheduled time.
Persistent=true

[Install]
WantedBy=timers.target
EOF

    chmod 644 "${SYSTEMD_DIR}/${UNIT_NAME}.service" "${SYSTEMD_DIR}/${UNIT_NAME}.timer"
    systemctl daemon-reload
    systemctl enable --now "${UNIT_NAME}.timer"
}

install_cron_file() {
    local user="$1"
    local escaped_script_path
    local temp_file

    printf -v escaped_script_path '%q' "$CACHED_UPDATE_SCRIPT"
    temp_file="$(mktemp)"

    cat > "$temp_file" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PACKAGE_UPDATE_USER=${user}
PACKAGE_UPDATE_LOG_DIR=${LOG_DIR}
${CRON_SCHEDULE} root /bin/bash ${escaped_script_path} >> /dev/null 2>&1
EOF

    install -m 644 "$temp_file" "$CRON_FILE"
    rm -f "$temp_file"
}

install_schedule() {
    local user
    user="$(package_update_user)"

    cleanup_legacy_crontabs
    install_cached_updater

    if has_systemd; then
        install_systemd_units "$user"
        write_status "Success" "Installed systemd timer ${UNIT_NAME}.timer."
        write_status "Info" "Schedule: Every Saturday at 1:00 AM (runs after boot if missed)"
    else
        install_cron_file "$user"
        write_status "Success" "Installed weekly cron schedule at ${CRON_FILE}."
        write_status "Info" "Schedule: Every Saturday at 1:00 AM"
        write_status "Warning" "systemd not found: cron skips runs missed while the machine is off."
    fi

    write_status "Info" "Runs: ${CACHED_UPDATE_SCRIPT} (refreshes itself from GitHub)"
    write_status "Info" "Logs: ${LOG_DIR}"
    if [ -n "$user" ]; then
        write_status "Info" "Per-user tools update as: ${user}"
    else
        write_status "Warning" "No non-root user found; pipx/uv/Claude Code updates will be skipped."
    fi
}

remove_schedule() {
    cleanup_legacy_crontabs

    if [ -f "${SYSTEMD_DIR}/${UNIT_NAME}.timer" ] || [ -f "${SYSTEMD_DIR}/${UNIT_NAME}.service" ]; then
        if has_systemd; then
            systemctl disable --now "${UNIT_NAME}.timer" >/dev/null 2>&1 || true
        fi
        rm -f "${SYSTEMD_DIR}/${UNIT_NAME}.timer" "${SYSTEMD_DIR}/${UNIT_NAME}.service"
        if has_systemd; then
            systemctl daemon-reload
        fi
        write_status "Success" "Removed systemd timer ${UNIT_NAME}.timer."
    fi

    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        write_status "Success" "Removed cached updater ${INSTALL_DIR}."
    fi

    write_status "Info" "Schedule removed. Logs kept in ${LOG_DIR}."
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

    if [ "$remove_mode" = false ] && is_wsl; then
        write_status "Error" "WSL detected. The Windows updater already updates WSL; no Linux schedule is needed."
        write_status "Info" "Run with --remove to clean up a schedule installed by an older version."
        exit 1
    fi

    require_root "$@"

    if [ "$remove_mode" = true ]; then
        remove_schedule
        exit 0
    fi

    if [ ! -f "$UPDATE_SCRIPT" ]; then
        write_status "Error" "Update script not found: ${UPDATE_SCRIPT}"
        exit 1
    fi

    install_schedule
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi

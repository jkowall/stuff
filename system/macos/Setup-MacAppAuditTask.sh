#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_SCRIPT="${SCRIPT_DIR}/audit_apps.sh"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/com.jkowa.weekly-app-audit.plist"
LABEL="com.jkowa.weekly-app-audit"
LAUNCHD_LOG="${HOME}/Library/Logs/com.jkowa.weekly-app-audit.log"

write_status() {
    local level="$1"
    local message="$2"
    local color=""

    case "$level" in
        "Info")    color="\033[36m" ;;
        "Success") color="\033[32m" ;;
        "Warning") color="\033[33m" ;;
        "Error")   color="\033[31m" ;;
        *)         color="\033[0m"  ;;
    esac

    echo -e "${color}${message}\033[0m"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--remove]

Installs or removes a weekly launchd job for audit_apps.sh.
Reinstalling replaces any existing job with the same label.
EOF
}

bootout_agent() {
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || \
        launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
}

bootstrap_agent() {
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || \
        launchctl load -w "$PLIST_PATH"
}

remove_schedule() {
    bootout_agent

    if [ -f "$PLIST_PATH" ]; then
        rm -f "$PLIST_PATH"
        write_status "Success" "Removed launchd job ${LABEL}."
    else
        write_status "Info" "No launchd job file found at ${PLIST_PATH}."
    fi
}

install_schedule() {
    mkdir -p "$PLIST_DIR" "$(dirname "$LAUNCHD_LOG")"
    bootout_agent

    cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${AUDIT_SCRIPT}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>7</integer>
        <key>Hour</key>
        <integer>2</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${LAUNCHD_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LAUNCHD_LOG}</string>
</dict>
</plist>
EOF

    bootstrap_agent

    write_status "Success" "Installed launchd job ${LABEL}."
    write_status "Info" "Schedule: Every Saturday at 2:00 AM (and at login)"
    write_status "Info" "Plist: ${PLIST_PATH}"
    write_status "Info" "Script: ${AUDIT_SCRIPT}"
}

main() {
    case "${1:-}" in
        "")
            install_schedule
            ;;
        "--remove")
            remove_schedule
            ;;
        "-h"|"--help")
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"

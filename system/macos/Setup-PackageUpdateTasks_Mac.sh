#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="${SCRIPT_DIR}/Update-AllPackages_Mac.sh"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/com.jkowa.weekly-package-updates.plist"
LABEL="com.jkowa.weekly-package-updates"
LAUNCHD_LOG="${HOME}/Library/Logs/com.jkowa.weekly-package-updates.log"
RUNNER_DIR="${HOME}/Library/Application Scripts/${LABEL}"
RUNNER_PATH="${RUNNER_DIR}/run.sh"
CACHED_UPDATE_SCRIPT="${RUNNER_DIR}/Update-AllPackages_Mac.sh"

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

Installs or removes a weekly launchd job for Update-AllPackages_Mac.sh.
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

    if [ -d "$RUNNER_DIR" ]; then
        rm -f "$RUNNER_PATH" "$CACHED_UPDATE_SCRIPT"
        rmdir "$RUNNER_DIR" 2>/dev/null || true
        write_status "Success" "Removed local runner ${RUNNER_DIR}."
    fi
}

install_runner() {
    mkdir -p "$RUNNER_DIR"

    install -m 755 "$UPDATE_SCRIPT" "$CACHED_UPDATE_SCRIPT"

    cat > "$RUNNER_PATH" <<EOF
#!/bin/bash

set -euo pipefail

SOURCE_SCRIPT="${UPDATE_SCRIPT}"
CACHED_SCRIPT="${CACHED_UPDATE_SCRIPT}"
LOG_PATH="${LAUNCHD_LOG}"

if [ -r "\$SOURCE_SCRIPT" ]; then
    if ! /usr/bin/install -m 755 "\$SOURCE_SCRIPT" "\$CACHED_SCRIPT" >> "\$LOG_PATH" 2>&1; then
        echo "Warning: failed to refresh cached updater from \$SOURCE_SCRIPT. Running existing cached copy." >> "\$LOG_PATH"
    fi
else
    echo "Warning: source updater is not readable: \$SOURCE_SCRIPT. Running existing cached copy." >> "\$LOG_PATH"
fi

if [ ! -x "\$CACHED_SCRIPT" ]; then
    echo "Error: cached updater is missing or not executable: \$CACHED_SCRIPT" >> "\$LOG_PATH"
    exit 126
fi

exec /bin/bash "\$CACHED_SCRIPT" "\$@"
EOF

    chmod 755 "$RUNNER_PATH"
}

install_schedule() {
    mkdir -p "$PLIST_DIR" "$(dirname "$LAUNCHD_LOG")"
    install_runner
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
        <string>${RUNNER_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>6</integer>
        <key>Hour</key>
        <integer>1</integer>
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
    write_status "Info" "Schedule: Every Saturday at 1:00 AM"
    write_status "Info" "Plist: ${PLIST_PATH}"
    write_status "Info" "Runner: ${RUNNER_PATH}"
    write_status "Info" "Source script: ${UPDATE_SCRIPT}"
    write_status "Info" "Cached script: ${CACHED_UPDATE_SCRIPT}"
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

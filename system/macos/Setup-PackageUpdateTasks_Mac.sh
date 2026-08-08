#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="${SCRIPT_DIR}/Update-AllPackages_Mac.sh"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/com.jkowa.weekly-package-updates.plist"
LABEL="com.jkowa.weekly-package-updates"
PENDING_PLIST_PATH="${PLIST_DIR}/com.jkowa.weekly-package-updates.pending.plist"
PENDING_LABEL="com.jkowa.weekly-package-updates.pending"
LAUNCHD_LOG="${HOME}/Library/Logs/com.jkowa.weekly-package-updates.log"
RUNNER_DIR="${HOME}/Library/Application Scripts/${LABEL}"
RUNNER_PATH="${RUNNER_DIR}/run.sh"
CACHED_UPDATE_SCRIPT="${RUNNER_DIR}/Update-AllPackages_Mac.sh"
PENDING_FILE="${RUNNER_DIR}/pending-interactive-update"
INTERACTIVE_MODE=0

write_status() {
    local level="$1"
    local message="$2"

    if [ -t 1 ]; then
        local color=""
        case "$level" in
            "Info")    color="\033[36m" ;;
            "Success") color="\033[32m" ;;
            "Warning") color="\033[33m" ;;
            "Error")   color="\033[31m" ;;
        esac
        printf '%b\n' "${color}${message}\033[0m"
    else
        printf '%s\n' "$message"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--interactive | --remove]

Installs or removes a weekly launchd job for Update-AllPackages_Mac.sh.
Reinstalling replaces any existing job with the same label.
The updater is cached under ~/Library/Application Scripts at install time so
launchd does not need runtime access to OneDrive/CloudStorage paths.
The default install is non-interactive and removes any pending retry job.
Use --interactive to open Terminal when launchd triggers so you can enter
sudo/app-specific passwords if required. Interactive installs also add a
15-minute pending retry job for cases where Terminal cannot open until login/unlock.
EOF
}

bootout_agent() {
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || \
        launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
    launchctl bootout "gui/$(id -u)" "$PENDING_PLIST_PATH" >/dev/null 2>&1 || \
        launchctl unload "$PENDING_PLIST_PATH" >/dev/null 2>&1 || true
}

bootstrap_agent() {
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || \
        launchctl load -w "$PLIST_PATH"

    if [ "$INTERACTIVE_MODE" -eq 1 ]; then
        launchctl bootstrap "gui/$(id -u)" "$PENDING_PLIST_PATH" >/dev/null 2>&1 || \
            launchctl load -w "$PENDING_PLIST_PATH"
    fi
}

remove_schedule() {
    bootout_agent

    if [ -f "$PLIST_PATH" ]; then
        rm -f "$PLIST_PATH"
        write_status "Success" "Removed launchd job ${LABEL}."
    else
        write_status "Info" "No launchd job file found at ${PLIST_PATH}."
    fi

    if [ -f "$PENDING_PLIST_PATH" ]; then
        rm -f "$PENDING_PLIST_PATH"
        write_status "Success" "Removed launchd job ${PENDING_LABEL}."
    else
        write_status "Info" "No launchd job file found at ${PENDING_PLIST_PATH}."
    fi

    if [ -d "$RUNNER_DIR" ]; then
        rm -f "$RUNNER_PATH" "$CACHED_UPDATE_SCRIPT" "$PENDING_FILE"
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

CACHED_SCRIPT="${CACHED_UPDATE_SCRIPT}"
LOG_PATH="${LAUNCHD_LOG}"
PENDING_FILE="${PENDING_FILE}"

if [ "\${1:-}" = "--run-pending" ] && [ ! -f "\$PENDING_FILE" ]; then
    exit 0
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

    local runner_args=""
    if [ "${INTERACTIVE_MODE}" -eq 1 ]; then
        runner_args="        <string>--interactive</string>"
    fi

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
${runner_args}
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
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>${LAUNCHD_LOG}</string>
</dict>
</plist>
EOF

    if [ "$INTERACTIVE_MODE" -eq 1 ]; then
        cat > "$PENDING_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PENDING_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${RUNNER_PATH}</string>
        <string>--run-pending</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>900</integer>
    <key>WatchPaths</key>
    <array>
        <string>${PENDING_FILE}</string>
    </array>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>${LAUNCHD_LOG}</string>
</dict>
</plist>
EOF
    else
        rm -f "$PENDING_PLIST_PATH" "$PENDING_FILE"
    fi

    bootstrap_agent

    write_status "Success" "Installed launchd job ${LABEL}."
    write_status "Info" "Schedule: Every Saturday at 1:00 AM"
    write_status "Info" "Plist: ${PLIST_PATH}"
    write_status "Info" "Runner: ${RUNNER_PATH}"
    write_status "Info" "Source script cached from: ${UPDATE_SCRIPT}"
    write_status "Info" "Launchd executes cached script: ${CACHED_UPDATE_SCRIPT}"
    if [ "$INTERACTIVE_MODE" -eq 1 ]; then
        write_status "Success" "Installed 15-minute pending retry job ${PENDING_LABEL}."
        write_status "Info" "Pending retry plist: ${PENDING_PLIST_PATH}"
        write_status "Info" "Pending marker: ${PENDING_FILE}"
    else
        write_status "Info" "Interactive pending retry job is not installed."
    fi
}

main() {
    case "${1:-}" in
        "")
            install_schedule
            ;;
        "--interactive")
            INTERACTIVE_MODE=1
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

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi

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
Use --interactive to open an interactive Terminal session when triggered by launchd
so you can enter sudo/app-specific passwords if required.
When interactive Terminal launch fails, a retry job is installed to run the
pending update after GUI login/unlock makes Terminal available.
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
    launchctl bootstrap "gui/$(id -u)" "$PENDING_PLIST_PATH" >/dev/null 2>&1 || \
        launchctl load -w "$PENDING_PLIST_PATH"
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

SOURCE_SCRIPT="${UPDATE_SCRIPT}"
CACHED_SCRIPT="${CACHED_UPDATE_SCRIPT}"
LOG_PATH="${LAUNCHD_LOG}"
PENDING_FILE="${PENDING_FILE}"

if [ "\${1:-}" = "--run-pending" ] && [ ! -f "\$PENDING_FILE" ]; then
    exit 0
fi

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
    <string>${LAUNCHD_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LAUNCHD_LOG}</string>
</dict>
</plist>
EOF

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
    <string>${LAUNCHD_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LAUNCHD_LOG}</string>
</dict>
</plist>
EOF

    bootstrap_agent

    write_status "Success" "Installed launchd job ${LABEL}."
    write_status "Success" "Installed launchd job ${PENDING_LABEL}."
    write_status "Info" "Schedule: Every Saturday at 1:00 AM"
    write_status "Info" "Plist: ${PLIST_PATH}"
    write_status "Info" "Pending retry plist: ${PENDING_PLIST_PATH}"
    write_status "Info" "Runner: ${RUNNER_PATH}"
    write_status "Info" "Source script: ${UPDATE_SCRIPT}"
    write_status "Info" "Cached script: ${CACHED_UPDATE_SCRIPT}"
    write_status "Info" "Pending marker: ${PENDING_FILE}"
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

main "$@"

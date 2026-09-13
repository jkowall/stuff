#!/bin/bash
#
# Installs or removes a launchd job that keeps chezmoi-managed dotfiles synced
# every 30 minutes and at login/unlock.
#
# The updater is cached under ~/Library/Application Scripts at install time so
# launchd does not need runtime access to OneDrive/CloudStorage paths (same reason
# Setup-PackageUpdateTasks_Mac.sh caches its own target script).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="${SCRIPT_DIR}/Update-Dotfiles_Mac.sh"
PLIST_DIR="${HOME}/Library/LaunchAgents"
LABEL="com.jkowa.chezmoi-dotfile-sync"
PLIST_PATH="${PLIST_DIR}/${LABEL}.plist"
RUNNER_DIR="${HOME}/Library/Application Scripts/${LABEL}"
RUNNER_PATH="${RUNNER_DIR}/run.sh"
CACHED_UPDATE_SCRIPT="${RUNNER_DIR}/Update-Dotfiles_Mac.sh"
LAUNCHD_LOG="${HOME}/Library/Logs/${LABEL}.log"
INTERVAL_SECONDS=1800

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

usage() {
    cat <<EOF
Usage: $(basename "$0") [--remove]

Installs or removes a launchd job that runs Update-Dotfiles_Mac.sh every
${INTERVAL_SECONDS} seconds and at login/unlock (RunAtLoad).
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
exec /bin/bash "${CACHED_UPDATE_SCRIPT}"
EOF
    chmod 755 "$RUNNER_PATH"
}

install_schedule() {
    if [ ! -f "$UPDATE_SCRIPT" ]; then
        write_status "Error" "Update script not found: ${UPDATE_SCRIPT}"
        exit 1
    fi

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
    <true/>
    <key>StartInterval</key>
    <integer>${INTERVAL_SECONDS}</integer>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>${LAUNCHD_LOG}</string>
</dict>
</plist>
EOF

    bootstrap_agent

    write_status "Success" "Installed launchd job ${LABEL}."
    write_status "Info" "Schedule: every ${INTERVAL_SECONDS}s, plus at login/unlock (RunAtLoad)"
    write_status "Info" "Plist: ${PLIST_PATH}"
    write_status "Info" "Runner: ${RUNNER_PATH}"
    write_status "Info" "To remove: $(basename "$0") --remove"
}

main() {
    case "${1:-}" in
        "") install_schedule ;;
        "--remove") remove_schedule ;;
        "-h"|"--help") usage ;;
        *) usage; exit 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi

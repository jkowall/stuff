#!/bin/bash

# SYNOPSIS
#     Weekly package update script for Homebrew, Mac App Store, Claude Code, MacUpdater, npm, pipx, and rustup on macOS.
# DESCRIPTION
#     Updates packages and apps from Homebrew, Mac App Store (via mas), Anthropic's native Claude Code updater,
#     MacUpdater, npm, pipx, and rustup-managed Rust toolchains.
#     Logs all output to a timestamped file and shows desktop notifications.

# ============================================================================
# CONFIGURATION
# ============================================================================

set -o pipefail

# launchd provides a minimal PATH, so include common package manager locations.
# Keep channel-managed CLIs outside Homebrew so formula/cask upgrades cannot replace them.
NPM_CHANNEL_PREFIX="${HOME}/.local"
export PATH="${NPM_CHANNEL_PREFIX}/bin:/opt/homebrew/opt/node@24/bin:/usr/local/opt/node@24/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$(dirname "$SCRIPT_DIR")/logs"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
MACHINE_NAME="$(hostname)"
TIMESTAMP="$(date +%Y-%m-%d_%H-%m)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_${MACHINE_NAME}_${TIMESTAMP}.log"
INTERACTIVE_MODE=0
PENDING_ONLY=0
PENDING_FILE="${SCRIPT_DIR}/pending-interactive-update"
MACUPDATER_CLIENT="/Applications/MacUpdater.app/Contents/Resources/macupdater_client"
MACUPDATER_SCAN_TIMEOUT_SECONDS=120
MACUPDATER_APP_TIMEOUT_SECONDS=900
CLAUDE_CODE_BINARY="${CLAUDE_CODE_BINARY:-${HOME}/.local/bin/claude}"
CLAUDE_DESKTOP_APP="${CLAUDE_DESKTOP_APP:-/Applications/Claude.app}"
BREW_UPDATE_MAX_ATTEMPTS=2
BREW_UPDATE_RETRY_DELAY_SECONDS=15
UPDATE_LOCK_FILE="/tmp/${SCRIPT_NAME}.${UID}.lock"
NPM_GENERIC_ALLOWED_SCRIPTS="@github/keytar,node-pty"
NPM_CHANNEL_PACKAGES=(
    "@openai/codex@alpha"
)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interactive)
            INTERACTIVE_MODE=1
            shift
            ;;
        --interactive-run)
            INTERACTIVE_MODE=1
            shift
            ;;
        --run-pending)
            INTERACTIVE_MODE=1
            PENDING_ONLY=1
            shift
            ;;
        *)
            break
            ;;
    esac
done

# Status tracking
BREW_STATUS="Skipped"
MAS_STATUS="Skipped"
MACUPDATER_STATUS="Skipped"
NPM_STATUS="Skipped"
CLAUDE_CODE_STATUS="Skipped"
CLAUDE_DESKTOP_STATUS="Skipped"
PIP_STATUS="Skipped"
PIPX_STATUS="Skipped"
RUSTUP_STATUS="Skipped"
LOG_CLEANUP_STATUS="Skipped"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local log_entry="[$timestamp] [$level] $message"

    if [ -t 1 ]; then
        local color=""
        case "$level" in
            "Info")    color="\033[37m" ;; # White
            "Success") color="\033[32m" ;; # Green
            "Warning") color="\033[33m" ;; # Yellow
            "Error")   color="\033[31m" ;; # Red
        esac
        printf '%b\n' "${color}${log_entry}\033[0m"
    else
        printf '%s\n' "$log_entry"
    fi

    printf '%s\n' "$log_entry" >> "$LOG_FILE"
}

is_data_saver_active() {
    # Check if Low Data Mode is enabled via the macOS Network framework.
    # Returns 0 (true) if constrained/Low Data Mode, 1 (false) otherwise.
    swift - 2>/dev/null <<'SWIFT'
import Network
import Foundation
let semaphore = DispatchSemaphore(value: 0)
let monitor = NWPathMonitor()
var isConstrained = false
monitor.pathUpdateHandler = { path in
    isConstrained = path.isConstrained
    semaphore.signal()
}
monitor.start(queue: DispatchQueue.global())
_ = semaphore.wait(timeout: .now() + 5)
monitor.cancel()
    exit(isConstrained ? 0 : 1)
SWIFT
}

mark_pending_interactive_run() {
    if ! {
        printf 'created_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf 'script=%s\n' "$0"
        printf 'log=%s\n' "$LOG_FILE"
    } > "$PENDING_FILE"; then
        log "Error" "Unable to save pending interactive update marker: $PENDING_FILE"
        return 1
    fi

    log "Warning" "Saved pending interactive update marker: $PENDING_FILE"
}

clear_pending_interactive_run() {
    if [ -f "$PENDING_FILE" ]; then
        if ! rm -f "$PENDING_FILE"; then
            log "Error" "Unable to clear pending interactive update marker: $PENDING_FILE"
            return 1
        fi
        log "Info" "Cleared pending interactive update marker: $PENDING_FILE"
    fi
}

launch_interactive_terminal() {
    if [ "$INTERACTIVE_MODE" -ne 1 ]; then
        return 0
    fi

    if [ -t 0 ] || [ -t 1 ]; then
        if ! clear_pending_interactive_run; then
            return 1
        fi
        return 0
    fi

    local script_path
    script_path="$(/usr/bin/realpath "$0" 2>/dev/null || printf '%s' "$0")"
    local terminal_cmd
    terminal_cmd="bash '${script_path}' --interactive-run"

    log "Info" "Interactive mode requested. Relaunching in Terminal for user interaction."

    if ! /usr/bin/osascript <<OSA
with timeout of 30 seconds
    tell application "Terminal"
        activate
        do script "${terminal_cmd}"
    end tell
end timeout
OSA
    then
        log "Error" "Failed to launch Terminal for interactive update run."
        mark_pending_interactive_run
        return 1
    fi

    exit 0
}

show_notification() {
    local title="$1"
    local message="$2"

    # macOS native notification via AppleScript
    osascript - "$title" "$message" <<'OSA'
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
OSA
}

run_logged_with_timeout() {
    local timeout_seconds="$1"
    shift

    local output_file
    output_file="$(mktemp "${TMPDIR:-/tmp}/update-command-output.XXXXXX")" || {
        log "Warning" "Unable to create temporary output file for command: $*"
        return 125
    }

    "$@" > "$output_file" 2>&1 &
    local command_pid=$!
    local elapsed=0
    local wait_interval=5

    while kill -0 "$command_pid" 2>/dev/null; do
        if [ "$elapsed" -ge "$timeout_seconds" ]; then
            log "Warning" "Command timed out after ${timeout_seconds}s: $*"
            kill "$command_pid" 2>/dev/null || true
            sleep 2
            kill -9 "$command_pid" 2>/dev/null || true
            wait "$command_pid" 2>/dev/null || true
            cat "$output_file" | tee -a "$LOG_FILE"
            rm -f "$output_file"
            return 124
        fi

        sleep "$wait_interval"
        elapsed=$((elapsed + wait_interval))
    done

    local command_status=0
    wait "$command_pid"
    command_status=$?
    cat "$output_file" | tee -a "$LOG_FILE"
    rm -f "$output_file"
    return "$command_status"
}

acquire_update_lock() {
    exec 9>"$UPDATE_LOCK_FILE"
    local open_status=$?
    if [ "$open_status" -ne 0 ]; then
        log "Error" "Unable to open package update lock: $UPDATE_LOCK_FILE"
        return 1
    fi

    /usr/bin/lockf -s -t 0 9
    local lock_status=$?
    case "$lock_status" in
        0)
            return 0
            ;;
        75)
            exec 9>&-
            log "Warning" "Another package update run is already active. Skipping this run."
            return 2
            ;;
        *)
            exec 9>&-
            log "Error" "Unable to acquire package update lock: $UPDATE_LOCK_FILE"
            return 1
            ;;
    esac
}

update_brew() {
    if ! command -v brew >/dev/null 2>&1; then
        log "Warning" "Homebrew not found. Skipping."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING HOMEBREW UPDATES"
    log "Info" "============================================================"

    local brew_update_succeeded=0
    local brew_update_attempt=1
    while [ "$brew_update_attempt" -le "$BREW_UPDATE_MAX_ATTEMPTS" ]; do
        log "Info" "Running: brew update (attempt ${brew_update_attempt}/${BREW_UPDATE_MAX_ATTEMPTS})"
        if brew update 2>&1 | tee -a "$LOG_FILE"; then
            brew_update_succeeded=1
            break
        fi

        if [ "$brew_update_attempt" -lt "$BREW_UPDATE_MAX_ATTEMPTS" ]; then
            log "Warning" "Brew update failed; retrying once in ${BREW_UPDATE_RETRY_DELAY_SECONDS} seconds in case the network is still recovering."
            sleep "$BREW_UPDATE_RETRY_DELAY_SECONDS"
        fi
        brew_update_attempt=$((brew_update_attempt + 1))
    done

    if [ "$brew_update_succeeded" -ne 1 ]; then
        BREW_STATUS="Error"
        log "Error" "Brew update failed after ${BREW_UPDATE_MAX_ATTEMPTS} attempts."
        return
    fi

    local brew_warning=0

    log "Info" "Running: brew upgrade"
    if ! brew upgrade 2>&1 | tee -a "$LOG_FILE"; then
        BREW_STATUS="Warning"
        log "Warning" "Brew upgrade encountered issues."
        return
    fi

    log "Info" "Running: brew cleanup"
    if ! brew cleanup 2>&1 | tee -a "$LOG_FILE"; then
        brew_warning=1
        log "Warning" "Brew cleanup encountered issues."
    fi

    if [ "$brew_warning" -eq 0 ]; then
        BREW_STATUS="Success"
        log "Success" "Homebrew updates completed successfully"
    else
        BREW_STATUS="Warning"
        log "Warning" "Homebrew updates completed with one or more warnings."
    fi
}

update_claude_code() {
    if [ ! -x "$CLAUDE_CODE_BINARY" ]; then
        log "Info" "Anthropic-native Claude Code not found at ${CLAUDE_CODE_BINARY}. Skipping."
        return 0
    fi

    log "Info" "============================================================"
    log "Info" "STARTING CLAUDE CODE UPDATE"
    log "Info" "============================================================"

    local current_version=""
    current_version="$("$CLAUDE_CODE_BINARY" --version 2>>"$LOG_FILE")" || true
    if [ -n "$current_version" ]; then
        current_version="${current_version%%$'\n'*}"
        log "Info" "Current Claude Code: $current_version"
    fi

    log "Info" "Running: ${CLAUDE_CODE_BINARY} update"
    if ! "$CLAUDE_CODE_BINARY" update 2>&1 | tee -a "$LOG_FILE"; then
        CLAUDE_CODE_STATUS="Warning"
        log "Warning" "Claude Code native update encountered issues."
        return 1
    fi

    local updated_version=""
    if ! updated_version="$("$CLAUDE_CODE_BINARY" --version 2>>"$LOG_FILE")" || [ -z "$updated_version" ]; then
        CLAUDE_CODE_STATUS="Warning"
        log "Warning" "Claude Code updated, but version verification failed."
        return 1
    fi

    updated_version="${updated_version%%$'\n'*}"
    CLAUDE_CODE_STATUS="Success"
    log "Success" "Claude Code is current on the configured release channel: $updated_version"
}

update_or_audit_claude_desktop() {
    if command -v brew >/dev/null 2>&1 && brew list --cask claude >/dev/null 2>&1; then
        log "Info" "Running: brew upgrade --cask --greedy-auto-updates claude"
        if brew upgrade --cask --greedy-auto-updates claude 2>&1 | tee -a "$LOG_FILE"; then
            CLAUDE_DESKTOP_STATUS="Success"
            log "Success" "Claude Desktop is up-to-date through Homebrew."
            return 0
        fi

        CLAUDE_DESKTOP_STATUS="Warning"
        log "Warning" "Claude Desktop Homebrew update encountered issues."
        return 1
    fi

    if [ ! -d "$CLAUDE_DESKTOP_APP" ]; then
        log "Info" "Claude Desktop is not installed. Skipping."
        return 0
    fi

    local desktop_version="unknown"
    desktop_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${CLAUDE_DESKTOP_APP}/Contents/Info.plist" 2>/dev/null)" || desktop_version="unknown"

    local desktop_auto_updates_disabled=""
    desktop_auto_updates_disabled="$(/usr/bin/defaults read com.anthropic.claudefordesktop disableAutoUpdates 2>/dev/null)" || true
    case "$desktop_auto_updates_disabled" in
        1|true|TRUE|yes|YES)
            CLAUDE_DESKTOP_STATUS="Warning"
            log "Warning" "Claude Desktop ${desktop_version} is installed, but its vendor auto-updater is disabled."
            return 1
            ;;
    esac

    CLAUDE_DESKTOP_STATUS="Auto-update"
    log "Info" "Claude Desktop ${desktop_version} uses Anthropic's built-in auto-updater; no supported headless update command is available."
}

update_mas() {
    if ! command -v mas >/dev/null 2>&1; then
        log "Info" "mas (Mac App Store CLI) not installed. Skipping."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING MAC APP STORE UPDATES"
    log "Info" "============================================================"

    log "Info" "Running: mas upgrade"
    if mas upgrade 2>&1 | tee -a "$LOG_FILE"; then
        MAS_STATUS="Success"
        log "Success" "App Store updates completed successfully"
    else
        MAS_STATUS="Warning"
        log "Warning" "mas upgrade encountered issues (or no updates available)."
    fi
}

update_macupdater_apps() {
    if [ ! -x "$MACUPDATER_CLIENT" ]; then
        log "Info" "MacUpdater CLI not found. Skipping."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING MACUPDATER APP UPDATES"
    log "Info" "============================================================"

    local scan_warning=0
    log "Info" "Running: macupdater_client scan --outdated --quiet"
    if run_logged_with_timeout "$MACUPDATER_SCAN_TIMEOUT_SECONDS" "$MACUPDATER_CLIENT" scan --outdated --quiet; then
        log "Success" "MacUpdater scan completed successfully"
    else
        scan_warning=1
        log "Warning" "MacUpdater live scan failed. Falling back to cached MacUpdater app list."
    fi

    local list_file
    list_file="$(mktemp "${TMPDIR:-/tmp}/macupdater-list.XXXXXX")" || {
        MACUPDATER_STATUS="Error"
        log "Error" "Unable to create temporary file for MacUpdater app list."
        return
    }

    if ! "$MACUPDATER_CLIENT" list --hide-uptodate-apps --hide-mas-apps --json --quiet > "$list_file" 2>>"$LOG_FILE"; then
        MACUPDATER_STATUS="Warning"
        log "Warning" "MacUpdater app list failed."
        rm -f "$list_file"
        return
    fi

    local app_counts
    if ! app_counts="$(python3 - "$list_file" 2>>"$LOG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

if not isinstance(data, dict) or not isinstance(data.get("apps"), list):
    raise ValueError("MacUpdater JSON does not contain an apps list")
if any(not isinstance(app, dict) for app in data["apps"]):
    raise ValueError("MacUpdater JSON contains an invalid app entry")

auto_apps = [
    app for app in data.get("apps", [])
    if app.get("outdated") and app.get("auto_updatable") and app.get("installed_path")
]
manual_apps = [
    app for app in data.get("apps", [])
    if app.get("outdated") and not app.get("auto_updatable") and app.get("installed_path")
]
print(f"{len(auto_apps)}\t{len(manual_apps)}")
PY
)"; then
        MACUPDATER_STATUS="Warning"
        log "Warning" "Unable to parse or validate the MacUpdater JSON app list."
        rm -f "$list_file"
        return
    fi

    local app_count=""
    local manual_count=""
    IFS=$'\t' read -r app_count manual_count <<< "$app_counts"
    if [[ ! "$app_count" =~ ^[0-9]+$ || ! "$manual_count" =~ ^[0-9]+$ ]]; then
        MACUPDATER_STATUS="Warning"
        log "Warning" "MacUpdater returned invalid app counts after JSON parsing."
        rm -f "$list_file"
        return
    fi

    if [ "$manual_count" -gt 0 ]; then
        log "Warning" "MacUpdater found $manual_count outdated non-auto-updatable app(s) that need manual or vendor-specific updates."
        python3 - "$list_file" <<'PY' | while IFS=$'\t' read -r app_name installed_version newest_version app_path; do
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

for app in data.get("apps", []):
    if app.get("outdated") and not app.get("auto_updatable") and app.get("installed_path"):
        print("\t".join([
            str(app.get("name") or ""),
            str(app.get("installed_version") or ""),
            str(app.get("newest_version") or ""),
            str(app.get("installed_path") or ""),
        ]))
PY
            log "Warning" "Manual MacUpdater update remains: ${app_name} (${installed_version} -> ${newest_version}) at ${app_path}"
        done
    fi

    if [ "$app_count" -eq 0 ]; then
        if [ "$manual_count" -gt 0 ]; then
            MACUPDATER_STATUS="Warning"
            log "Warning" "MacUpdater found no auto-updatable non-MAS app updates, but manual updates remain."
        elif [ "$scan_warning" -eq 1 ]; then
            MACUPDATER_STATUS="Warning"
            log "Warning" "MacUpdater cached data found no non-MAS app updates, but the live scan failed."
        else
            MACUPDATER_STATUS="Success"
            log "Success" "MacUpdater found no non-MAS app updates."
        fi
        rm -f "$list_file"
        return
    fi

    log "Info" "MacUpdater found $app_count auto-updatable non-MAS app update(s)."
    log "Info" "Running apps may be skipped by MacUpdater; they will not be force-quit by this script."

    local updates_file
    updates_file="$(mktemp "${TMPDIR:-/tmp}/macupdater-updates.XXXXXX")" || {
        MACUPDATER_STATUS="Error"
        log "Error" "Unable to create temporary file for MacUpdater updates."
        rm -f "$list_file"
        return
    }

    if ! python3 - "$list_file" > "$updates_file" 2>>"$LOG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

for app in data.get("apps", []):
    if app.get("outdated") and app.get("auto_updatable") and app.get("installed_path"):
        print("\t".join([
            str(app.get("name") or ""),
            str(app.get("installed_version") or ""),
            str(app.get("newest_version") or ""),
            str(app.get("installed_path") or ""),
        ]))
PY
    then
        MACUPDATER_STATUS="Warning"
        log "Warning" "Unable to prepare the parsed MacUpdater update list."
        rm -f "$list_file" "$updates_file"
        return
    fi

    local updated=0
    local failed=0
    local app_name=""
    local installed_version=""
    local newest_version=""
    local app_path=""

    while IFS=$'\t' read -r app_name installed_version newest_version app_path; do
        [ -n "$app_path" ] || continue
        log "Info" "MacUpdater updating: ${app_name} (${installed_version} -> ${newest_version}) at ${app_path}"

        if run_logged_with_timeout "$MACUPDATER_APP_TIMEOUT_SECONDS" "$MACUPDATER_CLIENT" update --quiet "$app_path"; then
            updated=$((updated + 1))
            log "Success" "MacUpdater update completed for: ${app_name}"
        else
            failed=$((failed + 1))
            log "Warning" "MacUpdater update failed or was skipped for: ${app_name}"
        fi
    done < "$updates_file"

    rm -f "$list_file" "$updates_file"

    if [ "$failed" -gt 0 ] || [ "$manual_count" -gt 0 ] || [ "$scan_warning" -eq 1 ]; then
        MACUPDATER_STATUS="Warning"
        log "Warning" "MacUpdater completed with $updated updated, $failed failed/skipped, $manual_count manual update(s), and live-scan warning=$scan_warning."
    else
        MACUPDATER_STATUS="Success"
        log "Success" "MacUpdater completed successfully ($updated updated)."
    fi
}

get_npm_installed_version() {
    local prefix="$1"
    local package_name="$2"

    npm list -g --prefix "$prefix" "$package_name" --depth=0 --json 2>>"$LOG_FILE" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(data.get("dependencies", {}).get(sys.argv[1], {}).get("version", ""))
' "$package_name" 2>>"$LOG_FILE"
}

verify_npm_channel_package() {
    local package_name="$1"
    local expected_version="$2"
    local binary_path="$3"
    local installed_version=""
    local version_output=""

    installed_version="$(get_npm_installed_version "$NPM_CHANNEL_PREFIX" "$package_name")" || true
    if [ "$installed_version" != "$expected_version" ]; then
        log "Warning" "NPM channel package version verification failed for ${package_name}: expected ${expected_version}, found ${installed_version:-missing}."
        return 1
    fi

    if [ ! -x "$binary_path" ]; then
        log "Warning" "NPM channel executable is missing or not executable: $binary_path"
        return 1
    fi

    if ! version_output="$("$binary_path" --version 2>&1)" || [ -z "$version_output" ]; then
        log "Warning" "NPM channel executable health check failed: $binary_path --version"
        return 1
    fi

    if [[ "$version_output" != *"$expected_version"* ]]; then
        log "Warning" "NPM channel executable version verification failed for ${package_name}: expected ${expected_version}, output was ${version_output}."
        return 1
    fi

    version_output="${version_output%%$'\n'*}"
    log "Info" "Verified NPM channel package ${package_name}@${installed_version}; executable reports: ${version_output}"
    return 0
}

update_npm() {
    if ! command -v npm >/dev/null 2>&1; then
        log "Info" "NPM not installed. Skipping."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING NPM GLOBAL UPDATES"
    log "Info" "============================================================"

    log "Info" "Checking for outdated NPM packages..."
    # npm outdated exits with 1 if packages are outdated
    local outdated_json=""
    outdated_json=$(npm outdated -g --json 2>>"$LOG_FILE") || true

    if ! OUTDATED=$(python3 -c '
import json
import sys

data = json.load(sys.stdin)
if "error" in data:
    raise ValueError("npm outdated returned an error")

managed_packages = {
    package_spec.rsplit("@", 1)[0]
    for package_spec in sys.argv[1:]
}
managed_packages.add("npm")
managed_packages.add("@anthropic-ai/claude-code")

for package, versions in data.items():
    if package in managed_packages:
        continue
    if isinstance(versions, dict) and versions.get("latest"):
        print("{}@{}".format(package, versions["latest"]))
' "${NPM_CHANNEL_PACKAGES[@]}" <<< "$outdated_json"); then
        NPM_STATUS="Warning"
        log "Warning" "Unable to parse the NPM outdated package list."
        return
    fi

    local package_args=()
    if [ -n "$OUTDATED" ]; then
        while IFS= read -r package_spec; do
            [ -n "$package_spec" ] && package_args+=("$package_spec")
        done <<< "$OUTDATED"
    fi

    local attempted=0
    local failed=0
    local package_spec
    for package_spec in "${package_args[@]}"; do
        attempted=$((attempted + 1))
        log "Info" "Updating NPM global package: $package_spec"
        if npm install -g --strict-allow-scripts --allow-scripts="$NPM_GENERIC_ALLOWED_SCRIPTS" "$package_spec" 2>&1 | tee -a "$LOG_FILE"; then
            log "Success" "NPM global package updated: $package_spec"
        else
            failed=$((failed + 1))
            log "Warning" "NPM global package update failed: $package_spec"
        fi
    done

    if ! mkdir -p "${NPM_CHANNEL_PREFIX}/bin"; then
        NPM_STATUS="Warning"
        log "Warning" "Unable to create NPM channel prefix: $NPM_CHANNEL_PREFIX"
        return
    fi

    for package_spec in "${NPM_CHANNEL_PACKAGES[@]}"; do
        local package_name="${package_spec%@*}"
        local binary_name=""
        case "$package_name" in
            "@openai/codex") binary_name="codex" ;;
            *)
                failed=$((failed + 1))
                log "Warning" "No executable health check is configured for NPM channel package: $package_name"
                continue
                ;;
        esac

        local current_version=""
        current_version="$(get_npm_installed_version "$NPM_CHANNEL_PREFIX" "$package_name")" || true

        local channel_version=""
        if ! channel_version=$(npm view "$package_spec" version 2>>"$LOG_FILE"); then
            failed=$((failed + 1))
            log "Warning" "Unable to resolve NPM release channel: $package_spec"
            continue
        fi

        local binary_path="${NPM_CHANNEL_PREFIX}/bin/${binary_name}"
        if [ "$current_version" = "$channel_version" ] \
            && verify_npm_channel_package "$package_name" "$channel_version" "$binary_path"; then
            log "Success" "NPM channel package is current and healthy: ${package_name}@${channel_version}"
            continue
        fi

        attempted=$((attempted + 1))
        log "Info" "Updating NPM channel package in ${NPM_CHANNEL_PREFIX}: $package_spec"
        if npm install -g --prefix "$NPM_CHANNEL_PREFIX" --strict-allow-scripts "$package_spec" 2>&1 | tee -a "$LOG_FILE" \
            && verify_npm_channel_package "$package_name" "$channel_version" "$binary_path"; then
            log "Success" "NPM channel package updated and verified: ${package_name}@${channel_version}"
        else
            failed=$((failed + 1))
            log "Warning" "NPM channel package update or verification failed: $package_spec"
        fi
    done

    if [ "$failed" -gt 0 ]; then
        NPM_STATUS="Warning"
        log "Warning" "NPM updates completed with $failed failure(s)."
    elif [ "$attempted" -gt 0 ]; then
        NPM_STATUS="Success"
        log "Success" "NPM global updates completed successfully"
    else
        NPM_STATUS="Success"
        log "Success" "NPM global packages are already up-to-date"
    fi
}

update_pip() {
    if ! command -v pip3 >/dev/null 2>&1; then
        log "Info" "pip3 not installed. Skipping."
        PIP_STATUS="Skipped"
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING PIP UPDATES"
    log "Info" "============================================================"

    log "Info" "Skipping bulk pip package updates to avoid managed-environment dependency conflicts."
    log "Info" "Use pipx directly for app/tool updates when available."
    PIP_STATUS="Skipped"
}

update_pipx() {
    if ! command -v pipx >/dev/null 2>&1; then
        log "Info" "pipx not installed. Skipping."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING PIPX UPDATES"
    log "Info" "============================================================"

    log "Info" "Running: pipx upgrade-all"
    if pipx upgrade-all 2>&1 | tee -a "$LOG_FILE"; then
        PIPX_STATUS="Success"
        log "Success" "pipx upgrades completed successfully"
    else
        PIPX_STATUS="Warning"
        log "Warning" "pipx upgrade-all encountered issues."
    fi
}

update_rustup() {
    if ! command -v rustup >/dev/null 2>&1; then
        log "Info" "rustup not installed. Skipping."
        return
    fi

    log "Info" "============================================================"
    log "Info" "STARTING RUSTUP UPDATES"
    log "Info" "============================================================"

    log "Info" "Checking for rustup and toolchain updates..."
    local check_output=""
    local check_status=0
    check_output="$(rustup check 2>&1)"
    check_status=$?
    printf '%s\n' "$check_output" | tee -a "$LOG_FILE"

    if echo "$check_output" | grep -qi "update available"; then
        log "Info" "Running: rustup update"
        if rustup update 2>&1 | tee -a "$LOG_FILE"; then
            RUSTUP_STATUS="Success"
            log "Success" "rustup updates completed successfully"
        else
            RUSTUP_STATUS="Warning"
            log "Warning" "rustup update encountered issues."
        fi
    else
        if [ "$check_status" -ne 0 ]; then
            RUSTUP_STATUS="Warning"
            log "Warning" "rustup check encountered issues."
            return
        fi

        RUSTUP_STATUS="Success"
        log "Success" "Rust toolchains are already up-to-date"
    fi
}

show_summary() {
    echo ""
    log "Info" "============================================================"
    log "Info" "UPDATE SUMMARY"
    log "Info" "============================================================"

    local has_errors=0
    local has_warnings=0
    local summary_lines=(
        "Homebrew:  $BREW_STATUS"
        "App Store: $MAS_STATUS"
        "MacUpdater: $MACUPDATER_STATUS"
        "NPM:       $NPM_STATUS"
        "Claude Code: $CLAUDE_CODE_STATUS"
        "Claude Desktop: $CLAUDE_DESKTOP_STATUS"
        "PIP:       $PIP_STATUS"
        "PIPX:      $PIPX_STATUS"
        "Rustup:    $RUSTUP_STATUS"
        "Log cleanup: $LOG_CLEANUP_STATUS"
    )
    local statuses=(
        "$BREW_STATUS"
        "$MAS_STATUS"
        "$MACUPDATER_STATUS"
        "$NPM_STATUS"
        "$CLAUDE_CODE_STATUS"
        "$CLAUDE_DESKTOP_STATUS"
        "$PIP_STATUS"
        "$PIPX_STATUS"
        "$RUSTUP_STATUS"
        "$LOG_CLEANUP_STATUS"
    )
    local summary_message
    local status

    printf '%s\n' "${summary_lines[@]}" | tee -a "$LOG_FILE"
    summary_message="$(printf '%s\n' "${summary_lines[@]}")"

    for status in "${statuses[@]}"; do
        case "$status" in
            "Error") has_errors=1 ;;
            "Warning") has_warnings=1 ;;
        esac
    done

    log "Info" "============================================================"
    log "Info" "Log file saved to: $LOG_FILE"

    if [ "$has_errors" -eq 1 ]; then
        log "Error" "Package updates completed with errors."
        show_notification "Package Updates Completed with Errors" "$summary_message" || true
        return 1
    elif [ "$has_warnings" -eq 1 ]; then
        log "Warning" "Package updates completed with warnings."
        show_notification "Package Updates Completed with Warnings" "$summary_message" || true
        return 2
    else
        log "Success" "Package updates completed cleanly."
        show_notification "Package Updates Complete" "$summary_message" || true
        return 0
    fi
}

cleanup_logs() {
    log "Info" "Cleaning up old log files (keeping most recent 3)..."

    local log_files=()
    local log_file
    for log_file in "${LOG_DIR}/${SCRIPT_NAME}_${MACHINE_NAME}_"*.log; do
        [ -f "$log_file" ] && log_files+=("$log_file")
    done

    while [ "${#log_files[@]}" -gt 3 ]; do
        local oldest_log="${log_files[0]}"
        for log_file in "${log_files[@]}"; do
            if [ "$log_file" -ot "$oldest_log" ]; then
                oldest_log="$log_file"
            fi
        done

        if ! rm -f -- "$oldest_log"; then
            LOG_CLEANUP_STATUS="Warning"
            log "Warning" "Unable to remove old updater log: $oldest_log"
            return
        fi

        local remaining_logs=()
        for log_file in "${log_files[@]}"; do
            if [ "$log_file" != "$oldest_log" ]; then
                remaining_logs+=("$log_file")
            fi
        done
        log_files=("${remaining_logs[@]}")
    done

    LOG_CLEANUP_STATUS="Success"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
# Ensure log directory exists
if ! mkdir -p "$LOG_DIR"; then
    printf 'Error: unable to create log directory: %s\n' "$LOG_DIR" >&2
    exit 1
fi

if [ "$PENDING_ONLY" -eq 1 ] && [ ! -f "$PENDING_FILE" ]; then
    exit 0
fi

# Ensure log file exists
if ! touch "$LOG_FILE"; then
    printf 'Error: unable to create log file: %s\n' "$LOG_FILE" >&2
    exit 1
fi

log "Info" "============================================================"
log "Info" "PACKAGE UPDATE STARTED (User=$(whoami))"
log "Info" "Script Directory: $SCRIPT_DIR"
log "Info" "Log File: $LOG_FILE"
log "Info" "============================================================"

if ! launch_interactive_terminal; then
    log "Error" "Interactive launch failed."
    exit 1
fi

# Check for Data Saver / Low Data Mode
if is_data_saver_active; then
    log "Warning" "Low Data Mode (Data Saver) detected. Skipping auto updates to conserve data."
    show_notification "Package Updates Skipped" "Low Data Mode detected. Updates deferred to save data."
    exit 0
fi

acquire_update_lock
LOCK_STATUS=$?
if [ "$LOCK_STATUS" -ne 0 ]; then
    if [ "$LOCK_STATUS" -eq 2 ]; then
        if [ "$INTERACTIVE_MODE" -eq 1 ]; then
            if ! mark_pending_interactive_run; then
                LOCK_STATUS=1
            fi
        fi
        if [ "$LOCK_STATUS" -eq 2 ]; then
            show_notification "Package Updates Already Running" "Skipped a duplicate package update run." || true
        else
            show_notification "Package Updates Could Not Start" "Another update is running, and the interactive retry could not be saved." || true
        fi
    else
        show_notification "Package Updates Could Not Start" "Unable to acquire the package update lock." || true
    fi
    exit "$LOCK_STATUS"
fi

# Cleanup
cleanup_logs

# Show start notification
show_notification "Package Updates" "Starting updates for Homebrew, App Store, Claude Code, MacUpdater, npm, pipx, and rustup..."

# Run Updates
update_brew
update_or_audit_claude_desktop
update_mas
update_macupdater_apps
update_npm
update_claude_code
update_pip
update_pipx
update_rustup

# Summary
show_summary
FINAL_EXIT_CODE=$?

echo ""
log "Info" "Update process completed."
if [ -t 0 ]; then
    read -r -p "Press Enter to close..."
fi

exit "$FINAL_EXIT_CODE"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi

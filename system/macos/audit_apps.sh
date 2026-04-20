#!/bin/bash

# SYNOPSIS
#     Audits installed GUI applications on macOS and identifies their installation source.
# DESCRIPTION
#     Scans /Applications and ~/Applications to find .app bundles.
#     Cross-references with:
#     - Homebrew Casks (brew list --casks)
#     - Mac App Store (mas list)
#     Outputs a JSON file containing the audit results.

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="${1:-$SCRIPT_DIR/mac_apps_audit.json}"
LOG_FILE="$SCRIPT_DIR/audit.log"

# Exclude Apple system apps
EXCLUDE_PREFIX="/System/Applications"

# ============================================================================
# FUNCTIONS
# ============================================================================

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

get_app_info() {
    local app_path="$1"
    local app_name=$(basename "$app_path" .app)
    local version=$(defaults read "$app_path/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "Unknown")
    local bundle_id=$(defaults read "$app_path/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "Unknown")
    
    echo "$app_name|$version|$bundle_id|$app_path"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

log "Starting Mac App Audit..."

# 1. Gather Managed Apps
log "Fetching Homebrew Casks..."
BREW_CASKS=$(brew list --casks 2>/dev/null)

log "Fetching Mac App Store Apps..."
MAS_APPS=$(mas list 2>/dev/null)

# 2. Find All Apps
log "Scanning /Applications and ~/Applications..."
# Using mdfind is much faster than find for .app bundles
ALL_APPS=$(mdfind "kMDItemContentType == 'com.apple.application-bundle'" -onlyin /Applications -onlyin ~/Applications)

# Filter out system apps and non-top-level apps (like those inside other apps)
FILTERED_APPS=""
while read -r app; do
    if [[ "$app" == "$EXCLUDE_PREFIX"* ]]; then continue; fi
    # Only include apps directly in /Applications or ~/Applications or one level deep
    # (Prevents listing helpers inside app bundles)
    if [[ $(echo "$app" | tr -cd '/' | wc -c) -gt 4 ]]; then continue; fi
    FILTERED_APPS+="$app"$'\n'
done <<< "$ALL_APPS"

# 3. Process and Build JSON
log "Processing $(echo "$FILTERED_APPS" | wc -l | xargs) applications..."

echo "[" > "$OUTPUT_FILE"
FIRST=true

while read -r app_path; do
    if [ -z "$app_path" ]; then continue; fi
    
    info=$(get_app_info "$app_path")
    IFS='|' read -r name version bundle_id path <<< "$info"
    
    source="Manual"
    source_id=""
    
    # Check Homebrew
    # Many casks have names that match the app bundle name or bundle ID
    # We also check the app's location if it's in /Applications
    if echo "$BREW_CASKS" | grep -qx "$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"; then
        source="Homebrew"
        source_id=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    elif brew info --cask --json=v2 --installed 2>/dev/null | python3 -c "import sys, json; apps = json.load(sys.stdin)['casks']; [print(a['token']) for a in apps if any('$path'.startswith(p) for p in a.get('artifacts', []) if isinstance(p, list) and '.app' in str(p))]" | grep -q "."; then
        source="Homebrew"
        source_id=$(brew info --cask --json=v2 --installed 2>/dev/null | python3 -c "import sys, json; apps = json.load(sys.stdin)['casks']; [print(a['token']) for a in apps if any('$path'.startswith(p) for p in a.get('artifacts', []) if isinstance(p, list) and '.app' in str(p))]" | head -n 1)
    fi
    
    # Check MAS
    # mas list output format: 123456789 Name (Version)
    if echo "$MAS_APPS" | grep -qi "$name"; then
        source="App Store"
        source_id=$(echo "$MAS_APPS" | grep -qi "$name" | head -n 1 | awk '{print $1}')
    fi

    if [ "$FIRST" = true ]; then
        FIRST=false
    else
        echo "," >> "$OUTPUT_FILE"
    fi

    cat <<EOF >> "$OUTPUT_FILE"
  {
    "name": "$(echo "$name" | sed 's/"/\\"/g')",
    "version": "$(echo "$version" | sed 's/"/\\"/g')",
    "bundle_id": "$(echo "$bundle_id" | sed 's/"/\\"/g')",
    "path": "$(echo "$path" | sed 's/"/\\"/g')",
    "source": "$source",
    "source_id": "$source_id"
  }
EOF

done <<< "$FILTERED_APPS"

echo "]" >> "$OUTPUT_FILE"

log "Audit complete. Results saved to: $OUTPUT_FILE"
log "Summary:"
python3 -c "import json; data = json.load(open('$OUTPUT_FILE')); sources = [d['source'] for d in data]; print('\n'.join([f'  {s}: {sources.count(s)}' for s in sorted(set(sources))]))" | tee -a "$LOG_FILE"

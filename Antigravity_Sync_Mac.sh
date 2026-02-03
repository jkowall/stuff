#!/bin/zsh
# Antigravity_Sync_Mac.sh

# Load config from JSON file
CONFIG_FILE="$HOME/Private/Configs/Antigravity_Sync_Mac.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    echo "Please create it with DefaultBackupPath."
    exit 1
fi
# Parse path using python3 and expand tilde
RAW_PATH=$(python3 -c "import json, os; print(os.path.expanduser(json.load(open('$CONFIG_FILE'))['DefaultBackupPath']))")
BASE_BACKUP_DIR="$RAW_PATH"
# Parse optional PreRestorePath
PRE_RESTORE_BASE=$(python3 -c "import json, os; config = json.load(open('$CONFIG_FILE')); print(os.path.expanduser(config.get('PreRestorePath', '/tmp')))")
# Use hostname for subfolder to match Windows/Linux behavior
HOSTNAME=$(hostname)
BACKUP_DIR_DEFAULT="$BASE_BACKUP_DIR/$HOSTNAME"

# Parse flags
VERSIONED=false
for arg in "$@"; do
    if [[ "$arg" == "-v" || "$arg" == "--versioned" ]]; then
        VERSIONED=true
    fi
done

# CLI Check
if ! command -v antigravity &> /dev/null; then
    echo -e "\033[31mError: 'antigravity' CLI not found. Please ensure it is installed and in your PATH.\033[0m"
    exit 1
fi

# Function to display interactive menu
show_menu() {
    local title=$1
    shift
    local menu_options=("$@")
    local count=${#menu_options[@]}
    local selected=1  # zsh arrays are 1-indexed
    local key

    # Enable raw terminal mode
    stty -echo
    tput civis # Hide cursor

    while true; do
        clear
        echo "=== $title ==="
        # zsh arrays are 1-indexed, so loop from 1 to count
        for i in {1..$count}; do
            if [[ $i -eq $selected ]]; then
                echo -e "\033[32m > ${menu_options[$i]}\033[0m"
            else
                echo "   ${menu_options[$i]}"
            fi
        done

        # Read a single character first
        read -s -k1 key
        if [[ "$key" == $'\e' ]]; then
            # Read the rest of the escape sequence
            read -s -k2 -t 0.1 rest
            key="$key$rest"
        fi
        
        case "$key" in
            $'\e[A') # Up Arrow
                selected=$(( (selected - 2 + count) % count + 1 ))
                ;;
            $'\e[B') # Down Arrow
                selected=$(( selected % count + 1 ))
                ;;
            $'\n'|"") # Enter key
                break
                ;;
        esac
    done

    # Restore terminal
    stty echo
    tput cnorm # Show cursor
    return $((selected - 1))  # Return 0-indexed for compatibility
}

# Git helpers
git_sync_pull() {
    local target_dir=$1
    echo "Checking for remote updates in $BASE_BACKUP_DIR..."
    local repo_root=$(cd "$BASE_BACKUP_DIR" && git rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$repo_root" ]]; then
        (cd "$repo_root" && git pull --stat)
    else
        echo "Warning: Base backup directory is not inside a git repository."
    fi
}

git_sync_push() {
    local target_dir=$1
    echo "Staging changes for remote sync..."
    local repo_root=$(cd "$BASE_BACKUP_DIR" && git rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$repo_root" ]]; then
        (
            cd "$repo_root"
            echo "Changes to be committed:"
            git add .
            git status --short
            git commit -m "Auto-backup Antigravity settings ($HOSTNAME): $(date)"
            echo "Pushing to remote..."
            git push
        )
    else
        echo "Warning: Base backup directory is not inside a git repository."
    fi
}

# Git Pull at Start
read -q "pull_choice?Pull latest settings from Git? (y/n): "
echo
if [[ $pull_choice == "y" || $pull_choice == "Y" ]]; then
    git_sync_pull
fi

# Determine Action
show_menu "Select Action" "Backup" "Restore"
choice_idx=$?
choice=$((choice_idx + 1))

if [[ $choice -eq 2 ]]; then
    # List available machine backups
    echo "Available machine backups in $BASE_BACKUP_DIR:"
    machine_paths=()
    machine_display=()
    # In zsh, find output can be loaded into array
    for d in "$BASE_BACKUP_DIR"/*(N/); do
        mod_date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$d")
        machine_paths+=("$d")
        machine_display+=("$(basename "$d") (Last Modified: $mod_date)")
    done
    
    if [[ ${#machine_paths[@]} -eq 0 ]]; then
        echo "No backups found. Defaulting to $BACKUP_DIR_DEFAULT"
        BACKUP_DIR="$BACKUP_DIR_DEFAULT"
    else
        show_menu "Select Backup to Restore" "${machine_display[@]}"
        machine_idx=$?
        BACKUP_DIR="${machine_paths[$((machine_idx + 1))]}"
    fi
else
    if [[ "$VERSIONED" == "true" ]]; then
        BACKUP_DIR_DEFAULT="$BASE_BACKUP_DIR/${HOSTNAME}_$(date +%Y%m%d_%H%M%S)"
    fi
    echo "Enter the full path for the backup folder (default: $BACKUP_DIR_DEFAULT):"
    read input_dir
    BACKUP_DIR="${input_dir:-$BACKUP_DIR_DEFAULT}"
fi

MAC_SETTINGS="$HOME/Library/Application Support/Antigravity/User"
GLOBAL_RULES="$HOME/.gemini"
EXT_FILE="$BACKUP_DIR/extensions_mac.txt"

if [[ $choice -eq 1 ]]; then
    echo "Starting Backup to $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    cp "$MAC_SETTINGS/settings.json" "$BACKUP_DIR/" 2>/dev/null
    cp "$MAC_SETTINGS/keybindings.json" "$BACKUP_DIR/" 2>/dev/null
    
    # Backup Global Rules (.gemini directory)
    if [[ -d "$GLOBAL_RULES" ]]; then
        echo "  - Backing up global rules (.gemini folder)..."
        # Use rsync to exclude junk files if available, otherwise fallback to cp
        if command -v rsync &> /dev/null; then
            rsync -av --exclude="antigravity-browser-profile/" \
                      --exclude="antigravity/conversations/" \
                      --exclude="antigravity/annotations/" \
                      --exclude="antigravity/code_tracker/" \
                      --exclude="tmp/" \
                      --exclude="installation_id" \
                      --exclude="state.json" \
                      "$GLOBAL_RULES/" "$BACKUP_DIR/.gemini/" > /dev/null
        else
            cp -R "$GLOBAL_RULES" "$BACKUP_DIR/"
        fi
        echo "  - Global rules backed up (clean sync)."
    fi
    
    # Backup GEMINI.md
    if [[ -f "$HOME/.gemini/GEMINI.md" ]]; then
        cp "$HOME/.gemini/GEMINI.md" "$BACKUP_DIR/" 2>/dev/null
        echo "  - GEMINI.md backed up."
    fi

    echo "Exporting extension list..."
    antigravity --list-extensions > "$EXT_FILE" 2>/dev/null
    echo "Backup complete."
    
    # Git Push
    read -q "push_choice?Push changes to Git? (y/n): "
    echo
    if [[ $push_choice == "y" || $push_choice == "Y" ]]; then
        git_sync_push
    fi

    # 4. Pruning Policy (for versioned backups)
    if [[ "$VERSIONED" == "true" ]]; then
        echo "Checking for old backups to prune..."
        RETENTION_DAYS=30
        # Find directories starting with HOSTNAME_ that are older than 30 days
        OLD_BACKUPS=()
        while IFS= read -r d; do
            OLD_BACKUPS+=("$d")
        done < <(find "$BASE_BACKUP_DIR" -maxdepth 1 -type d -name "${HOSTNAME}_*" -mtime +$RETENTION_DAYS)

        if [[ ${#OLD_BACKUPS[@]} -gt 0 ]]; then
            echo "Found ${#OLD_BACKUPS[@]} backups older than $RETENTION_DAYS days."
            read -q "prune_choice?Prune old backups? (y/n): "
            echo
            if [[ $prune_choice == "y" || $prune_choice == "Y" ]]; then
                for d in "${OLD_BACKUPS[@]}"; do
                    rm -rf "$d"
                    echo "  - Deleted: $(basename "$d")"
                done
                echo "Old backups pruned."
            fi
        fi
    fi

elif [[ $choice -eq 2 ]]; then
    echo "Starting Restore from $BACKUP_DIR..."
    
    # 1. Pre-restore Backup (Safety Net)
    # Move to a non-git directory (default /tmp) and keep only 2
    PRE_RESTORE_ROOT="$PRE_RESTORE_BASE/antigravity_pre_restore"
    PRE_RESTORE_DIR="$PRE_RESTORE_ROOT/backup_$(date +%Y%m%d_%H%M%S)"
    echo "Creating safety backup of current local settings to $PRE_RESTORE_DIR..."
    mkdir -p "$PRE_RESTORE_DIR"
    [[ -f "$MAC_SETTINGS/settings.json" ]] && cp "$MAC_SETTINGS/settings.json" "$PRE_RESTORE_DIR/"
    [[ -f "$MAC_SETTINGS/keybindings.json" ]] && cp "$MAC_SETTINGS/keybindings.json" "$PRE_RESTORE_DIR/"
    [[ -d "$GLOBAL_RULES" ]] && cp -R "$GLOBAL_RULES" "$PRE_RESTORE_DIR/"

    # Prune to keep only 2 most recent backups
    if [[ -d "$PRE_RESTORE_ROOT" ]]; then
        # List backups by time (newest first), take from 3rd onwards
        backups_to_remove=$(ls -dt "$PRE_RESTORE_ROOT"/backup_* 2>/dev/null | tail -n +3)
        if [[ -n "$backups_to_remove" ]]; then
            echo "Pruning old pre-restore backups..."
            echo "$backups_to_remove" | xargs rm -rf
        fi
    fi

    # 2. Settings Diff Preview
    if [[ -f "$BACKUP_DIR/settings.json" && -f "$MAC_SETTINGS/settings.json" ]]; then
        echo "Changes detected in settings.json (Local vs Backup):"
        if ! diff --brief "$MAC_SETTINGS/settings.json" "$BACKUP_DIR/settings.json" > /dev/null; then
            read -q "show_diff?Preview settings changes? (y/n): "
            echo
            if [[ $show_diff == "y" || $show_diff == "Y" ]]; then
                diff -u "$MAC_SETTINGS/settings.json" "$BACKUP_DIR/settings.json" | head -n 30
                echo "..."
            fi
        else
            echo "  - Local settings match backup."
        fi
    fi

    if [[ -f "$BACKUP_DIR/settings.json" ]]; then
        mkdir -p "$MAC_SETTINGS"
        cp "$BACKUP_DIR/settings.json" "$MAC_SETTINGS/"
        echo "  - Restored settings.json"
    fi

    if [[ -f "$BACKUP_DIR/keybindings.json" ]]; then
        mkdir -p "$MAC_SETTINGS"
        cp "$BACKUP_DIR/keybindings.json" "$MAC_SETTINGS/"
        echo "  - Restored keybindings.json"
    fi

    if [[ -d "$BACKUP_DIR/.gemini" ]]; then
        echo "  - Restoring .gemini rules..."
        if command -v rsync &> /dev/null; then
            mkdir -p "$HOME/.gemini"
            rsync -av "$BACKUP_DIR/.gemini/" "$HOME/.gemini/" > /dev/null
        else
            cp -R "$BACKUP_DIR/.gemini" "$HOME/"
        fi
        echo "  - Restored .gemini rules"
    fi

    if [[ -f "$BACKUP_DIR/GEMINI.md" ]]; then
        mkdir -p "$HOME/.gemini"
        cp "$BACKUP_DIR/GEMINI.md" "$HOME/.gemini/"
        echo "  - Restored GEMINI.md"
    fi
    
    # Find extension list (check multiple possible names for cross-platform restore)
    EXT_TO_RESTORE=""
    for f in "extensions_mac.txt" "extensions.txt" "extensions_linux.txt" "extensions_wsl.txt"; do
        if [[ -f "$BACKUP_DIR/$f" ]]; then
            EXT_TO_RESTORE="$BACKUP_DIR/$f"
            echo "  - Found extension list: $f"
            break
        fi
    done

    if [[ -n "$EXT_TO_RESTORE" ]]; then
        # Check for local extensions not in backup
        local_exts=$(antigravity --list-extensions 2>/dev/null | tr -d '\r' | sort)
        backup_exts=$(cat "$EXT_TO_RESTORE" | tr -d '\r' | sort)
        new_local_exts=$(comm -23 <(echo "$local_exts") <(echo "$backup_exts") | grep -v "^$")

        if [[ -n "$new_local_exts" ]]; then
            echo -e "\033[33mWarning: The following local extensions are NOT in the backup being restored:\033[0m"
            echo "$new_local_exts" | sed 's/^/  - /'
            echo "Restoring may cause inconsistencies if these are not backed up. It's recommended to create a new backup first."
            read -q "sync_backup?Create a new backup instead? (y/n): "
            echo
            if [[ $sync_backup == "y" || $sync_backup == "Y" ]]; then
                echo "Aborting restore. Please run the script and select 'Backup'."
                exit 0
            fi
        fi

        read -q "install_choice?Reinstall all extensions from list? (y/n): "
        echo
        if [[ $install_choice == "y" || $install_choice == "Y" ]]; then
            echo "Installing/updating extensions..."
            while read -r ext; do
                if [[ -n "$ext" ]]; then
                    echo "  Installing: $ext"
                    antigravity --install-extension "$ext" --force 2>/dev/null
                fi
            done < <(tr -d '\r' < "$EXT_TO_RESTORE")
        fi
    fi
    echo "Restore complete."
fi

#!/bin/bash
# Antigravity_Sync_Linux.sh

# Load config from JSON file
CONFIG_FILE="$HOME/Private/Configs/Antigravity_Sync_Linux.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    echo "Please create it with DefaultBackupPath."
    exit 1
fi

# Parse path using python3 and expand tilde
RAW_PATH=$(python3 -c "import json, os; print(os.path.expanduser(json.load(open('$CONFIG_FILE'))['DefaultBackupPath']))")
BASE_BACKUP_DIR="$RAW_PATH"
# Use hostname for subfolder to match Windows behavior
HOSTNAME=$(hostname)
BACKUP_DIR_DEFAULT="$BASE_BACKUP_DIR/$HOSTNAME"

# Function to display interactive menu (Bash compatible)
show_menu() {
    local title=$1
    shift
    local options=("$@")
    local count=${#options[@]}
    local selected=0
    local key

    # Enable raw terminal mode
    stty -echo
    tput civis # Hide cursor

    while true; do
        clear
        echo "=== $title ==="
        for i in $(seq 0 $((count - 1))); do
            if [[ $i -eq $selected ]]; then
                echo -e "\033[32m > ${options[$i]}\033[0m"
            else
                echo "   ${options[$i]}"
            fi
        done

        # Read a single character
        read -s -n 1 key
        # Handle escape sequences for arrow keys
        if [[ "$key" == $'\e' ]]; then
            read -s -n 2 -t 0.1 rest
            key="$key$rest"
        fi
        
        case "$key" in
            $'\e[A') # Up Arrow
                selected=$(( (selected - 1 + count) % count ))
                ;;
            $'\e[B') # Down Arrow
                selected=$(( (selected + 1) % count ))
                ;;
            "") # Enter key
                break
                ;;
        esac
    done

    # Restore terminal
    stty echo
    tput cnorm # Show cursor
    return $selected
}

# Git helpers
git_sync_pull() {
    local target_dir=$1
    echo "Checking for remote updates in $target_dir..."
    # Find the git root for the base backup directory
    local repo_root=$(cd "$BASE_BACKUP_DIR" && git rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$repo_root" ]]; then
        (cd "$repo_root" && git pull)
    else
        echo "Warning: Base backup directory is not inside a git repository."
    fi
}

git_sync_push() {
    local target_dir=$1
    echo "Syncing backup to remote..."
    local repo_root=$(cd "$BASE_BACKUP_DIR" && git rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$repo_root" ]]; then
        (cd "$repo_root" && git add . && git commit -m "Auto-backup Antigravity settings ($HOSTNAME): $(date)" && git push)
    else
        echo "Warning: Base backup directory is not inside a git repository."
    fi
}

# Git Pull at Start
echo -n "Pull latest settings from Git? (y/n): "
read -n 1 -r pull_choice
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
    options=()
    while IFS= read -r d; do
        options+=("$(basename "$d")")
    done < <(find "$BASE_BACKUP_DIR" -maxdepth 1 -type d ! -path "$BASE_BACKUP_DIR" ! -path "*/.*")
    
    if [[ ${#options[@]} -eq 0 ]]; then
        echo "No backups found. Defaulting to $BACKUP_DIR_DEFAULT"
        BACKUP_DIR="$BACKUP_DIR_DEFAULT"
    else
        show_menu "Select Machine to Restore From" "${options[@]}"
        machine_idx=$?
        BACKUP_DIR="$BASE_BACKUP_DIR/${options[$machine_idx]}"
    fi
else
    echo "Enter the full path (default: $BACKUP_DIR_DEFAULT):"
    read input_dir
    BACKUP_DIR="${input_dir:-$BACKUP_DIR_DEFAULT}"
fi
echo "Selected backup folder: $BACKUP_DIR"

LINUX_SETTINGS="$HOME/.config/Antigravity/User"
GLOBAL_RULES="$HOME/.gemini"
EXT_FILE="$BACKUP_DIR/extensions_linux.txt"

if [[ $choice -eq 1 ]]; then
    echo "Starting Backup to $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    
    # Backup Settings
    if [[ -d "$LINUX_SETTINGS" ]]; then
        cp "$LINUX_SETTINGS/settings.json" "$BACKUP_DIR/" 2>/dev/null
        cp "$LINUX_SETTINGS/keybindings.json" "$BACKUP_DIR/" 2>/dev/null
        echo "  - Settings backed up."
    else
        echo "  - Settings folder not found at $LINUX_SETTINGS"
    fi

    # Backup Global Rules (.gemini directory)
    if [[ -d "$GLOBAL_RULES" ]]; then
        # Use -a to preserve permissions and recurse correctly
        cp -a "$GLOBAL_RULES" "$BACKUP_DIR/"
        echo "  - Global rules (.gemini folder) backed up."
    fi
    
    # Backup GEMINI.md explicitly if it exists (for visibility/parity with Win script)
    if [[ -f "$HOME/.gemini/GEMINI.md" ]]; then
        cp "$HOME/.gemini/GEMINI.md" "$BACKUP_DIR/" 2>/dev/null
        echo "  - GEMINI.md backed up."
    fi
    
    echo "Exporting extension list..."
    antigravity --list-extensions > "$EXT_FILE" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        echo "  - Extensions exported to $EXT_FILE"
    else
        echo "  - Warning: Failed to export extensions"
    fi

    echo "Backup complete."
    
    # Git Push
    echo -n "Push changes to Git? (y/n): "
    read -n 1 -r push_choice
    echo
    if [[ $push_choice == "y" || $push_choice == "Y" ]]; then
        git_sync_push
    fi

elif [[ $choice -eq 2 ]]; then
    echo "Starting Restore from $BACKUP_DIR..."
    
    if [[ -f "$BACKUP_DIR/settings.json" ]]; then
        mkdir -p "$LINUX_SETTINGS"
        cp "$BACKUP_DIR/settings.json" "$LINUX_SETTINGS/"
        echo "  - Restored settings.json"
    fi

    if [[ -f "$BACKUP_DIR/keybindings.json" ]]; then
        mkdir -p "$LINUX_SETTINGS"
        cp "$BACKUP_DIR/keybindings.json" "$LINUX_SETTINGS/"
        echo "  - Restored keybindings.json"
    fi

    if [[ -d "$BACKUP_DIR/.gemini" ]]; then
        # Use -a and ensure we don't end up with .gemini/.gemini
        cp -a "$BACKUP_DIR/.gemini" "$HOME/"
        echo "  - Restored .gemini rules"
    fi

    if [[ -f "$BACKUP_DIR/GEMINI.md" ]]; then
        mkdir -p "$HOME/.gemini"
        cp "$BACKUP_DIR/GEMINI.md" "$HOME/.gemini/"
        echo "  - Restored GEMINI.md"
    fi
    
    # Find extension list (check multiple possible names for cross-platform restore)
    EXT_TO_RESTORE=""
    echo "  - Checking for extension lists in $BACKUP_DIR..."
    for f in "extensions_linux.txt" "extensions.txt" "extensions_wsl.txt" "extensions_mac.txt" "extensions_mac.txt"; do
        if [[ -f "$BACKUP_DIR/$f" ]]; then
            EXT_TO_RESTORE="$BACKUP_DIR/$f"
            echo "  - Found extension list: $f"
            break
        fi
    done
    
    # Fallback: check for any .txt file starting with extensions
    if [[ -z "$EXT_TO_RESTORE" ]]; then
        fallback_ext=$(find "$BACKUP_DIR" -maxdepth 1 -name "extensions*.txt" -print -quit)
        if [[ -n "$fallback_ext" ]]; then
            EXT_TO_RESTORE="$fallback_ext"
            echo "  - Found extension list (fallback): $(basename "$EXT_TO_RESTORE")"
        fi
    fi

    if [[ -n "$EXT_TO_RESTORE" ]]; then
        echo -n "Reinstall all extensions from list? (y/n): "
        read install_choice
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

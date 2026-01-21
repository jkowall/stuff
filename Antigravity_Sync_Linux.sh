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
BACKUP_DIR_DEFAULT="$RAW_PATH"

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
    # Find the git root for the backup directory
    local repo_root=$(cd "$target_dir" && git rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$repo_root" ]]; then
        (cd "$repo_root" && git pull)
    else
        echo "Warning: Backup directory is not inside a git repository."
    fi
}

git_sync_push() {
    local target_dir=$1
    echo "Syncing backup to remote..."
    local repo_root=$(cd "$target_dir" && git rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$repo_root" ]]; then
        (cd "$repo_root" && git add . && git commit -m "Auto-backup Antigravity settings: $(date)" && git push)
    else
        echo "Warning: Backup directory is not inside a git repository."
    fi
}

# Determine Action
show_menu "Select Action" "Backup" "Restore"
choice_idx=$?
choice=$((choice_idx + 1))

echo "Enter the full path for the backup folder (default: $BACKUP_DIR_DEFAULT):"
read input_dir
BACKUP_DIR="${input_dir:-$BACKUP_DIR_DEFAULT}"

LINUX_SETTINGS="$HOME/.config/Antigravity/User"
GLOBAL_RULES="$HOME/.gemini"
EXT_FILE="$BACKUP_DIR/extensions_linux.txt"

if [[ $choice -eq 1 ]]; then
    echo "Starting Backup..."
    mkdir -p "$BACKUP_DIR"
    
    # Backup Settings
    if [[ -d "$LINUX_SETTINGS" ]]; then
        cp "$LINUX_SETTINGS/settings.json" "$BACKUP_DIR/" 2>/dev/null
        cp "$LINUX_SETTINGS/keybindings.json" "$BACKUP_DIR/" 2>/dev/null
        echo "  - Settings backed up."
    else
        echo "  - Settings folder not found at $LINUX_SETTINGS"
    fi

    # Backup Global Rules
    if [[ -d "$GLOBAL_RULES" ]]; then
        cp -R "$GLOBAL_RULES" "$BACKUP_DIR/"
        echo "  - Global rules (.gemini) backed up."
    fi
    
    # Backup GEMINI.md explicitly if it exists
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

    echo "Backup complete to $BACKUP_DIR."
    
    # Git Push
    echo -n "Push changes to Git? (y/n): "
    read -n 1 -r push_choice
    echo
    if [[ $push_choice == "y" || $push_choice == "Y" ]]; then
        git_sync_push "$BACKUP_DIR"
    fi

elif [[ $choice -eq 2 ]]; then
    # Git Pull
    echo -n "Pull latest settings from Git? (y/n): "
    read -n 1 -r pull_choice
    echo
    if [[ $pull_choice == "y" || $pull_choice == "Y" ]]; then
        git_sync_pull "$BACKUP_DIR"
    fi

    echo "Starting Restore..."
    
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
        cp -R "$BACKUP_DIR/.gemini" "$HOME/"
        echo "  - Restored .gemini rules"
    fi

    if [[ -f "$BACKUP_DIR/GEMINI.md" ]]; then
        mkdir -p "$HOME/.gemini"
        cp "$BACKUP_DIR/GEMINI.md" "$HOME/.gemini/"
        echo "  - Restored GEMINI.md"
    fi
    
    if [[ -f "$EXT_FILE" ]]; then
        echo "Found extensions_linux.txt. Reinstall all extensions? (y/n)"
        read -n 1 -r install_choice
        echo
        if [[ $install_choice == "y" || $install_choice == "Y" ]]; then
            echo "Installing/updating extensions..."
            while read -r ext; do
                if [[ -n "$ext" ]]; then
                    echo "  Installing: $ext"
                    antigravity --install-extension "$ext" --force 2>/dev/null
                fi
            done < <(tr -d '\r' < "$EXT_FILE")
        fi
    fi
    echo "Restore complete."
fi

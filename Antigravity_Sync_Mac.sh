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
# Use hostname for subfolder to match Windows/Linux behavior
HOSTNAME=$(hostname)
BACKUP_DIR_DEFAULT="$BASE_BACKUP_DIR/$HOSTNAME"

# Function to display interactive menu
show_menu() {
    local title=$1
    shift
    local options=("$@")
    local count=${#options[@]}
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
                echo -e "\033[32m > ${options[$i]}\033[0m"
            else
                echo "   ${options[$i]}"
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
    echo "Checking for remote updates in $target_dir..."
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
    options=()
    # In zsh, find output can be loaded into array
    for d in "$BASE_BACKUP_DIR"/*(N/); do
        options+=("$(basename "$d")")
    done
    
    if [[ ${#options[@]} -eq 0 ]]; then
        echo "No backups found. Defaulting to $BACKUP_DIR_DEFAULT"
        BACKUP_DIR="$BACKUP_DIR_DEFAULT"
    else
        show_menu "Select Machine to Restore From" "${options[@]}"
        machine_idx=$?
        BACKUP_DIR="$BASE_BACKUP_DIR/${options[$((machine_idx + 1))]}"
    fi
else
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
        cp -R "$GLOBAL_RULES" "$BACKUP_DIR/"
        echo "  - Global rules (.gemini folder) backed up."
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

elif [[ $choice -eq 2 ]]; then
    echo "Starting Restore from $BACKUP_DIR..."
    
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
        cp -R "$BACKUP_DIR/.gemini" "$HOME/"
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
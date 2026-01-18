#!/bin/zsh
# Antigravity_Sync_Mac.sh

# Load config from JSON file
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/Antigravity_Sync_Mac.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    echo "Please create it with DefaultBackupPath."
    exit 1
fi
DEFAULT_BACKUP_PATH=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['DefaultBackupPath'])")

# Function to display interactive menu
show_menu() {
    local title=$1
    shift
    local options=("$@")
    local selected=0
    local key

    # Enable raw terminal mode
    stty -echo
    tput civis # Hide cursor

    while true; do
        clear
        echo "=== $title ==="
        for i in {0..$((${#options[@]} - 1))}; do
            if [[ $i -eq $selected ]]; then
                echo -e "\033[32m > ${options[$i]}\033[0m"
            else
                echo "   ${options[$i]}"
            fi
        done

        # Read key (handling escape sequences for arrows)
        read -s -n3 key
        case "$key" in
            $'\e[A') # Up Arrow
                selected=$(( (selected - 1 + ${#options[@]}) % ${#options[@]} ))
                ;;
            $'\e[B') # Down Arrow
                selected=$(( (selected + 1) % ${#options[@]} ))
                ;;
            "") # Enter (empty string because -n3 reads escape seq, Enter is just \n)
                break
                ;;
            $'\e') # Escape (might be part of escape sequence or standalone)
                # If we read only \e, it's just ESC. But read -n3 might have swallowed more.
                # For simplicity, we just use Enter to select.
                ;;
        esac
    done

    # Restore terminal
    stty echo
    tput cnorm # Show cursor
    return $selected
}

# Determine Action
show_menu "Select Action" "Backup" "Restore"
choice_idx=$?
choice=$((choice_idx + 1))

echo "Enter the full path for the backup folder (default: $DEFAULT_BACKUP_PATH):"
read input_dir
BACKUP_DIR="${input_dir:-$DEFAULT_BACKUP_PATH}"


MAC_SETTINGS="$HOME/Library/Application Support/Antigravity/User"
GLOBAL_RULES="$HOME/.gemini"
EXT_FILE="$BACKUP_DIR/extensions.txt"

if [[ $choice -eq 1 ]]; then
    mkdir -p "$BACKUP_DIR"
    cp "$MAC_SETTINGS/settings.json" "$BACKUP_DIR/" 2>/dev/null
    cp "$MAC_SETTINGS/keybindings.json" "$BACKUP_DIR/" 2>/dev/null
    cp -R "$GLOBAL_RULES" "$BACKUP_DIR/"
    
    echo "Exporting extension list..."
    antigravity --list-extensions > "$EXT_FILE"
    echo "Backup complete to $BACKUP_DIR."

elif [[ $choice -eq 2 ]]; then
    if [[ -f "$BACKUP_DIR/settings.json" ]]; then
        cp "$BACKUP_DIR/settings.json" "$MAC_SETTINGS/"
        echo "Restored settings.json"
    else
        echo "Skipping settings.json (not found in backup)"
    fi

    if [[ -f "$BACKUP_DIR/keybindings.json" ]]; then
        cp "$BACKUP_DIR/keybindings.json" "$MAC_SETTINGS/"
        echo "Restored keybindings.json"
    else
        echo "Skipping keybindings.json (not found in backup)"
    fi

    if [[ -d "$BACKUP_DIR/.gemini" ]]; then
        cp -R "$BACKUP_DIR/.gemini" "$HOME/"
        echo "Restored .gemini rules"
    else
        echo "Skipping .gemini rules (not found in backup)"
    fi
    
    if [[ -f "$EXT_FILE" ]]; then
        echo "Found extensions.txt. Reinstall all extensions? (y/n)"
        read install_choice
        if [[ $install_choice == "y" ]]; then
            # Use tr to remove carriage returns (\r) in case the file came from Windows
            tr -d '\r' < "$EXT_FILE" | xargs -L 1 antigravity --install-extension
        fi
    fi
    echo "Restore complete."
fi
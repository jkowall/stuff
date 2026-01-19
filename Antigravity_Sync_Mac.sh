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
                echo "\033[32m > ${options[$i]}\033[0m"
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
    return $((selected - 1))  # Return 0-indexed for compatibility with rest of script
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
            echo "Installing/updating extensions..."
            # Use tr to remove carriage returns (\r) in case the file came from Windows
            # Use --force to update to latest versions, suppress stderr noise from internal messages
            tr -d '\r' < "$EXT_FILE" | while read -r ext; do
                echo "  Installing: $ext"
                antigravity --install-extension "$ext" --force 2>/dev/null
            done
        fi
    fi
    echo "Restore complete."
fi
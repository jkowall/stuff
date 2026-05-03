#!/bin/bash
# LLM_Sync_Linux.sh

CONFIG_FILE="$HOME/Private/Configs/LLM_Sync_Linux.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    echo "Please create it with DefaultBackupPath."
    exit 1
fi

BASE_BACKUP_DIR=$(python3 -c "import json, os; print(os.path.expanduser(json.load(open('$CONFIG_FILE'))['DefaultBackupPath']))")
PRE_RESTORE_BASE=$(python3 -c "import json, os; config = json.load(open('$CONFIG_FILE')); print(os.path.expanduser(config.get('PreRestorePath', '/tmp')))")
resolve_machine_name() {
    local explicit_name=$1
    if [[ -n "$explicit_name" ]]; then
        printf '%s\n' "$explicit_name"
        return 0
    fi

    local raw_name
    raw_name=$(hostname)

    # Avoid using domain suffixes in backup folder names.
    printf '%s\n' "${raw_name%%.*}"
}

VERSIONED=false
DRY_RUN=false
CONFLICT_POLICY="interactive"
ACTION=""
MACHINE_NAME=""
for arg in "$@"; do
    case "$arg" in
        backup|restore|audit|migrate-skills)
            ACTION="$arg"
            ;;
        -v|--versioned)
            VERSIONED=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --conflict-policy=*)
            CONFLICT_POLICY="${arg#*=}"
            ;;
        --machine-name=*)
            MACHINE_NAME="${arg#*=}"
            ;;
    esac
done

HOSTNAME=$(resolve_machine_name "$MACHINE_NAME")
BACKUP_DIR_DEFAULT="$BASE_BACKUP_DIR/$HOSTNAME"

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[dry-run] $*"
    else
        command "$@"
    fi
}

remove_tree() {
    local path=$1
    if [[ -e "$path" ]]; then
        run_cmd rm -rf "$path"
    fi
}

ensure_shared_skills_dir() {
    run_cmd mkdir -p "$HOME/.skills"
}

show_menu() {
    local title=$1
    shift
    local menu_options=("$@")
    local count=${#menu_options[@]}
    local selected=0
    local key

    stty -echo
    tput civis

    while true; do
        clear
        echo "=== $title ==="
        for i in $(seq 0 $((count - 1))); do
            if [[ $i -eq $selected ]]; then
                echo -e "\033[32m > ${menu_options[$i]}\033[0m"
            else
                echo "   ${menu_options[$i]}"
            fi
        done

        read -s -n 1 key
        if [[ "$key" == $'\e' ]]; then
            read -s -n 2 -t 0.1 rest
            key="$key$rest"
        fi

        case "$key" in
            $'\e[A')
                selected=$(( (selected - 1 + count) % count ))
                ;;
            $'\e[B')
                selected=$(( (selected + 1) % count ))
                ;;
            "")
                break
                ;;
        esac
    done

    stty echo
    tput cnorm
    return $selected
}

copy_file_if_exists() {
    local source_root=$1
    local relative_path=$2
    local destination_root=$3
    local source_path="$source_root/$relative_path"
    local destination_path="$destination_root/$relative_path"

    [[ -f "$source_path" ]] || return 0
    run_cmd mkdir -p "$(dirname "$destination_path")"
    run_cmd cp "$source_path" "$destination_path"
}

sync_dir_mirror() {
    local source_dir=$1
    local destination_dir=$2
    shift 2
    local exclude_args=()

    [[ -d "$source_dir" ]] || return 0
    run_cmd mkdir -p "$destination_dir"
    for pattern in "$@"; do
        exclude_args+=(--exclude "$pattern")
    done
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[dry-run] rsync -a --delete ${exclude_args[*]} \"$source_dir/\" \"$destination_dir/\""
    else
        rsync -a --delete "${exclude_args[@]}" "$source_dir"/ "$destination_dir"/
    fi
}

backup_codex() {
    local root=$1/codex
    remove_tree "$root"
    run_cmd mkdir -p "$root"
    copy_file_if_exists "$HOME/.codex" "AGENTS.md" "$root"
    copy_file_if_exists "$HOME/.codex" "config.toml" "$root"
    sync_dir_mirror "$HOME/.codex/memories" "$root/memories"
    sync_dir_mirror "$HOME/.codex/rules" "$root/rules"
    sync_dir_mirror "$HOME/.codex/skills" "$root/skills" ".system/"
}

backup_gemini() {
    local root=$1/gemini
    remove_tree "$root"
    run_cmd mkdir -p "$root"
    copy_file_if_exists "$HOME/.gemini" "GEMINI.md" "$root"
    copy_file_if_exists "$HOME/.gemini" "settings.json" "$root"
    copy_file_if_exists "$HOME/.gemini" "antigravity/mcp_config.json" "$root"
    copy_file_if_exists "$HOME/.gemini" "antigravity/user_settings.pb" "$root"
    copy_file_if_exists "$HOME/.gemini" "antigravity/browserAllowlist.txt" "$root"
    copy_file_if_exists "$HOME/.gemini" "antigravity/browserOnboardingStatus.txt" "$root"
    sync_dir_mirror "$HOME/.gemini/antigravity/knowledge" "$root/antigravity/knowledge"
    sync_dir_mirror "$HOME/.gemini/antigravity/scratch" "$root/antigravity/scratch"
}

backup_claude() {
    local root=$1/claude
    remove_tree "$root"
    run_cmd mkdir -p "$root"
    copy_file_if_exists "$HOME/.claude" "settings.json" "$root"
    copy_file_if_exists "$HOME/.claude" "statusline-command.sh" "$root"
    sync_dir_mirror "$HOME/.claude/skills" "$root/skills" ".git/"
}

backup_agents() {
    local root=$1/agents
    remove_tree "$root"
    run_cmd mkdir -p "$root"
    sync_dir_mirror "$HOME/.agents/skills" "$root/skills" ".git/"
}

backup_shared_skills() {
    local root=$1/shared-skills
    [[ -d "$HOME/.skills" ]] || return 0
    remove_tree "$root"
    run_cmd mkdir -p "$root"
    sync_dir_mirror "$HOME/.skills" "$root" ".git/"
}

backup_all() {
    local root=$1
    run_cmd mkdir -p "$root"
    echo "Backing up Codex..."
    backup_codex "$root"
    echo "Backing up Gemini..."
    backup_gemini "$root"
    echo "Backing up Claude..."
    backup_claude "$root"
    echo "Backing up Agents..."
    backup_agents "$root"
    echo "Backing up shared skills..."
    backup_shared_skills "$root"
}

path_signature() {
    local path=$1
    [[ -e "$path" ]] || return 0
    if [[ -f "$path" ]]; then
        sha256sum "$path" | awk '{print "FILE:" $1}'
        return 0
    fi
    find "$path" -type f -print0 | sort -z | xargs -0 sha256sum | sed "s|$path/||" | tr '\n' '|'
}

archive_skill_item() {
    local source_path=$1
    local archive_root=$2
    [[ -e "$source_path" ]] || return 0
    run_cmd mkdir -p "$archive_root"
    local destination="$archive_root/$(basename "$source_path")"
    if [[ -d "$source_path" ]]; then
        sync_dir_mirror "$source_path" "$destination" ".git/"
    else
        copy_file_if_exists "$(dirname "$source_path")" "$(basename "$source_path")" "$archive_root"
    fi
    remove_tree "$source_path"
}

resolve_skill_conflict() {
    local assistant_name=$1
    local local_path=$2
    local shared_path=$3
    local decision="$CONFLICT_POLICY"

    if [[ "$decision" == "interactive" ]]; then
        echo "Skill conflict for $assistant_name:$(basename "$local_path")"
        echo -n "Choose local or shared? (l/s): "
        read -n 1 -r choice
        echo
        if [[ "$choice" == "l" || "$choice" == "L" ]]; then
            decision="prefer-local"
        else
            decision="prefer-shared"
        fi
    fi

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    if [[ "$decision" == "prefer-local" ]]; then
        archive_skill_item "$shared_path" "$HOME/.skills/.conflicts/$assistant_name/$timestamp"
        if [[ -d "$local_path" ]]; then
            sync_dir_mirror "$local_path" "$shared_path" ".git/"
        else
            copy_file_if_exists "$(dirname "$local_path")" "$(basename "$local_path")" "$HOME/.skills"
        fi
        archive_skill_item "$local_path" "$(dirname "$local_path")/_migrated_to_shared/$timestamp"
        echo "Promoted local skill to shared: $(basename "$local_path")"
        return
    fi

    archive_skill_item "$local_path" "$(dirname "$local_path")/_migrated_to_shared/$timestamp"
    echo "Kept shared skill: $(basename "$local_path")"
}

audit_skills() {
    ensure_shared_skills_dir
    echo "=== Shared Skills Audit ==="
    local shared_count=0
    if [[ -d "$HOME/.skills" ]]; then
        shared_count=$(find "$HOME/.skills" -mindepth 1 -maxdepth 1 ! -name ".git" | wc -l)
    fi
    echo "Shared skills root: $HOME/.skills"
    echo "Shared skills: $shared_count"

    for assistant in codex claude; do
        local skill_root="$HOME/.${assistant}/skills"
        if [[ ! -d "$skill_root" ]]; then
            echo "[$assistant] no assistant-local shared-skill directory"
            continue
        fi

        local local_count
        local_count=$(find "$skill_root" -mindepth 1 -maxdepth 1 ! -name ".git" ! -name ".system" | wc -l)
        echo "[$assistant] local skills: $local_count"
        while IFS= read -r item; do
            local name
            name=$(basename "$item")
            if [[ -e "$HOME/.skills/$name" ]]; then
                echo "  - duplicate: $name"
            fi
        done < <(find "$skill_root" -mindepth 1 -maxdepth 1 ! -name ".git" ! -name ".system")
    done
}

migrate_skills() {
    ensure_shared_skills_dir
    for assistant in codex claude; do
        local skill_root="$HOME/.${assistant}/skills"
        [[ -d "$skill_root" ]] || continue
        echo "Migrating skills from $assistant..."
        while IFS= read -r item; do
            local name
            name=$(basename "$item")
            local shared_path="$HOME/.skills/$name"
            if [[ ! -e "$shared_path" ]]; then
                if [[ -d "$item" ]]; then
                    sync_dir_mirror "$item" "$shared_path" ".git/"
                else
                    copy_file_if_exists "$(dirname "$item")" "$name" "$HOME/.skills"
                fi
                archive_skill_item "$item" "$skill_root/_migrated_to_shared/$(date +%Y%m%d_%H%M%S)"
                echo "Promoted to shared: $name"
                continue
            fi

            local local_sig
            local shared_sig
            local_sig=$(path_signature "$item")
            shared_sig=$(path_signature "$shared_path")
            if [[ "$local_sig" == "$shared_sig" ]]; then
                archive_skill_item "$item" "$skill_root/_migrated_to_shared/$(date +%Y%m%d_%H%M%S)"
                echo "Archived duplicate local skill: $name"
                continue
            fi

            resolve_skill_conflict "$assistant" "$item" "$shared_path"
        done < <(find "$skill_root" -mindepth 1 -maxdepth 1 ! -name ".git" ! -name ".system")
    done
}

preview_diff_if_changed() {
    local local_file=$1
    local backup_file=$2
    local label=$3
    [[ -f "$local_file" && -f "$backup_file" ]] || return 0
    if ! cmp -s "$local_file" "$backup_file"; then
        echo "=== $label ==="
        diff -u "$local_file" "$backup_file" | head -n 40
        echo "..."
    fi
}

preview_restore_diffs() {
    local root=$1
    echo -n "Preview text diffs before restore? (y/n): "
    read -n 1 -r preview_choice
    echo
    [[ $preview_choice == "y" || $preview_choice == "Y" ]] || return 0

    preview_diff_if_changed "$HOME/.codex/AGENTS.md" "$root/codex/AGENTS.md" "codex/AGENTS.md"
    preview_diff_if_changed "$HOME/.codex/config.toml" "$root/codex/config.toml" "codex/config.toml"
    preview_diff_if_changed "$HOME/.gemini/GEMINI.md" "$root/gemini/GEMINI.md" "gemini/GEMINI.md"
    preview_diff_if_changed "$HOME/.gemini/settings.json" "$root/gemini/settings.json" "gemini/settings.json"
    preview_diff_if_changed "$HOME/.gemini/antigravity/mcp_config.json" "$root/gemini/antigravity/mcp_config.json" "gemini/antigravity/mcp_config.json"
    preview_diff_if_changed "$HOME/.claude/settings.json" "$root/claude/settings.json" "claude/settings.json"
    preview_diff_if_changed "$HOME/.claude/statusline-command.sh" "$root/claude/statusline-command.sh" "claude/statusline-command.sh"
}

restore_codex() {
    local root=$1/codex
    [[ -d "$root" ]] || return 0
    run_cmd mkdir -p "$HOME/.codex"
    copy_file_if_exists "$root" "AGENTS.md" "$HOME/.codex"
    copy_file_if_exists "$root" "config.toml" "$HOME/.codex"
    sync_dir_mirror "$root/memories" "$HOME/.codex/memories"
    sync_dir_mirror "$root/rules" "$HOME/.codex/rules"
    sync_dir_mirror "$root/skills" "$HOME/.codex/skills" ".system/"
}

restore_gemini() {
    local root=$1/gemini
    [[ -d "$root" ]] || return 0
    run_cmd mkdir -p "$HOME/.gemini"
    copy_file_if_exists "$root" "GEMINI.md" "$HOME/.gemini"
    copy_file_if_exists "$root" "settings.json" "$HOME/.gemini"
    copy_file_if_exists "$root" "antigravity/mcp_config.json" "$HOME/.gemini"
    copy_file_if_exists "$root" "antigravity/user_settings.pb" "$HOME/.gemini"
    copy_file_if_exists "$root" "antigravity/browserAllowlist.txt" "$HOME/.gemini"
}

restore_claude() {
    local root=$1/claude
    [[ -d "$root" ]] || return 0
    run_cmd mkdir -p "$HOME/.claude"
    copy_file_if_exists "$root" "settings.json" "$HOME/.claude"
    copy_file_if_exists "$root" "statusline-command.sh" "$HOME/.claude"
    [[ -f "$HOME/.claude/statusline-command.sh" ]] && run_cmd chmod +x "$HOME/.claude/statusline-command.sh"
    sync_dir_mirror "$root/skills" "$HOME/.claude/skills" ".git/"
}

restore_agents() {
    local root=$1/agents
    [[ -d "$root" ]] || return 0
    run_cmd mkdir -p "$HOME/.agents"
    sync_dir_mirror "$root/skills" "$HOME/.agents/skills" ".git/"
}

restore_shared_skills() {
    local root=$1/shared-skills
    [[ -d "$root" ]] || return 0
    run_cmd mkdir -p "$HOME/.skills"
    sync_dir_mirror "$root" "$HOME/.skills" ".git/"
}

create_safety_backup() {
    local restore_label=$1
    local safe_label
    safe_label=$(echo "$restore_label" | tr '\\/:*?"<>|' '_')
    local pre_restore_root="$PRE_RESTORE_BASE/llm_sync_pre_restore"
    local pre_restore_dir="$pre_restore_root/backup_${safe_label}_$(date +%Y%m%d_%H%M%S)"

    echo "Creating safety backup at $pre_restore_dir..."
    backup_all "$pre_restore_dir"

    if [[ -d "$pre_restore_root" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            ls -dt "$pre_restore_root"/backup_* 2>/dev/null | tail -n +3 | while IFS= read -r old_backup; do
                [[ -n "$old_backup" ]] && echo "[dry-run] rm -rf \"$old_backup\""
            done
        else
            ls -dt "$pre_restore_root"/backup_* 2>/dev/null | tail -n +3 | xargs -r rm -rf
        fi
    fi
}

git_sync_pull() {
    local repo_root
    repo_root=$(cd "$BASE_BACKUP_DIR" && git rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$repo_root" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "[dry-run] (cd \"$repo_root\" && git pull --stat)"
        else
            (cd "$repo_root" && git pull --stat)
        fi
    else
        echo "Warning: Base backup directory is not inside a Git repository."
    fi
}

git_sync_push() {
    local target_dir=$1
    local repo_root
    repo_root=$(cd "$BASE_BACKUP_DIR" && git rev-parse --show-toplevel 2>/dev/null)
    if [[ -z "$repo_root" ]]; then
        echo "Warning: Base backup directory is not inside a Git repository."
        return
    fi

    local relative_target
    relative_target=$(python3 -c "import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$target_dir" "$repo_root")
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[dry-run] (cd \"$repo_root\" && git add -- \"$relative_target\" && git commit -S ... && git pull --rebase && git push)"
        return
    fi
    (
        cd "$repo_root" || exit 1
        git add -- "$relative_target"
        if git diff --cached --quiet -- "$relative_target"; then
            echo "No backup changes to commit."
            exit 0
        fi
        git commit -S -m "Auto-backup LLM settings ($HOSTNAME): $(date '+%Y-%m-%d %H:%M:%S')" -- "$relative_target" || exit 1
        git pull --rebase || { git rebase --abort 2>/dev/null; git pull; }
        git push
    )
}

if [[ -z "$ACTION" ]]; then
    show_menu "Select Action" "Backup" "Restore" "Audit" "Migrate-Skills"
    choice_idx=$?
    case "$choice_idx" in
        0) ACTION="backup" ;;
        1) ACTION="restore" ;;
        2) ACTION="audit" ;;
        *) ACTION="migrate-skills" ;;
    esac
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry run mode enabled. No files will be changed."
fi

ensure_shared_skills_dir

if [[ "$ACTION" == "audit" ]]; then
    audit_skills
    exit 0
fi

if [[ "$ACTION" == "migrate-skills" ]]; then
    migrate_skills
    exit 0
fi

echo -n "Pull latest settings from Git? (y/n): "
read -n 1 -r pull_choice
echo
if [[ $pull_choice == "y" || $pull_choice == "Y" ]]; then
    git_sync_pull
fi

BACKUP_DIR="$BACKUP_DIR_DEFAULT"
if [[ "$ACTION" == "backup" && "$VERSIONED" == "true" ]]; then
    BACKUP_DIR="$BASE_BACKUP_DIR/${HOSTNAME}_$(date +%Y-%m-%d_%H%M%S)"
fi

if [[ "$ACTION" == "backup" ]]; then
    echo "Enter the full path (default: $BACKUP_DIR):"
    read input_dir
    BACKUP_DIR="${input_dir:-$BACKUP_DIR}"
    backup_all "$BACKUP_DIR"
    echo "Backup complete."

    echo -n "Push backup changes to Git? (y/n): "
    read -n 1 -r push_choice
    echo
    if [[ $push_choice == "y" || $push_choice == "Y" ]]; then
        git_sync_push "$BACKUP_DIR"
    fi

    if [[ "$VERSIONED" == "true" ]]; then
        OLD_BACKUPS=$(find "$BASE_BACKUP_DIR" -maxdepth 1 -type d -name "${HOSTNAME}_*" -mtime +30)
        if [[ -n "$OLD_BACKUPS" ]]; then
            echo "Old versioned backups found."
            echo -n "Prune old backups? (y/n): "
            read -n 1 -r prune_choice
            echo
            if [[ $prune_choice == "y" || $prune_choice == "Y" ]]; then
                if [[ "$DRY_RUN" == "true" ]]; then
                    echo "$OLD_BACKUPS" | while IFS= read -r old_backup; do
                        [[ -n "$old_backup" ]] && echo "[dry-run] rm -rf \"$old_backup\""
                    done
                else
                    echo "$OLD_BACKUPS" | xargs -r rm -rf
                fi
            fi
        fi
    fi
else
    machine_paths=()
    machine_display=()
    while IFS= read -r directory; do
        mod_date=$(date -r "$directory" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "Unknown Date")
        machine_paths+=("$directory")
        machine_display+=("$(basename "$directory") (Last Modified: $mod_date)")
    done < <(find "$BASE_BACKUP_DIR" -maxdepth 1 -type d ! -path "$BASE_BACKUP_DIR" ! -path "*/.*" | sort)

    if [[ ${#machine_paths[@]} -eq 0 ]]; then
        echo "No backups found in $BASE_BACKUP_DIR"
        exit 1
    fi

    show_menu "Select Backup to Restore" "${machine_display[@]}"
    machine_idx=$?
    BACKUP_DIR="${machine_paths[$machine_idx]}"

    create_safety_backup "$(basename "$BACKUP_DIR")"
    preview_restore_diffs "$BACKUP_DIR"

    echo "Restoring Codex..."
    restore_codex "$BACKUP_DIR"
    echo "Restoring Gemini..."
    restore_gemini "$BACKUP_DIR"
    echo "Restoring Claude..."
    restore_claude "$BACKUP_DIR"
    echo "Restoring Agents..."
    restore_agents "$BACKUP_DIR"
    echo "Restoring shared skills..."
    restore_shared_skills "$BACKUP_DIR"
    echo "Restore complete."
fi

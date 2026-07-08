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
DESTRUCTIVE_MIGRATE=false
ACTION=""
MACHINE_NAME=""
for arg in "$@"; do
    case "$arg" in
        backup|restore|audit|sync-skills|migrate-skills)
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
        --destructive-migrate)
            DESTRUCTIVE_MIGRATE=true
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

confirm() {
    local prompt=$1
    local response=""
    if [[ "$DRY_RUN" == "true" && ! -t 0 ]]; then
        echo "$prompt (y/n): n"
        return 1
    fi

    echo -n "$prompt (y/n): "
    read -r response
    [[ "$response" == [yY]* ]]
}

remove_tree() {
    local target_path=$1
    if [[ -e "$target_path" ]]; then
        run_cmd rm -rf "$target_path"
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
        echo "[dry-run] rsync -a --checksum --delete ${exclude_args[*]} \"$source_dir/\" \"$destination_dir/\""
    else
        rsync -a --checksum --delete "${exclude_args[@]}" "$source_dir"/ "$destination_dir"/
    fi
}

copy_top_level_item() {
    local source_path=$1
    local destination_path=$2

    [[ -e "$source_path" ]] || return 0
    run_cmd mkdir -p "$(dirname "$destination_path")"
    if [[ -d "$source_path" ]]; then
        sync_dir_mirror "$source_path" "$destination_path" ".git/"
    else
        run_cmd cp "$source_path" "$destination_path"
    fi
}

find_assistant_skill_items() {
    local skill_root=$1
    [[ -d "$skill_root" ]] || return 0
    find "$skill_root" -mindepth 1 -maxdepth 1 \
        ! -name ".git" \
        ! -name ".system" \
        ! -name "_migrated_to_shared" \
        ! -name ".conflicts" | sort
}

find_shared_skill_items() {
    [[ -d "$HOME/.skills" ]] || return 0
    find "$HOME/.skills" -mindepth 1 -maxdepth 1 \
        ! -name ".git" \
        ! -name ".conflicts" \
        ! -name "_migrated_to_shared" | sort
}

backup_codex() {
    local root=$1/codex
    remove_tree "$root"
    run_cmd mkdir -p "$root"
    copy_file_if_exists "$HOME/.codex" "AGENTS.md" "$root"
    copy_file_if_exists "$HOME/.codex" "config.toml" "$root"
    sync_dir_mirror "$HOME/.codex/memories" "$root/memories"
    sync_dir_mirror "$HOME/.codex/rules" "$root/rules"
    sync_dir_mirror "$HOME/.codex/skills" "$root/skills" ".system/" ".git/" ".conflicts/" "_migrated_to_shared/"
}

backup_gemini() {
    local root=$1/gemini
    remove_tree "$root"
    run_cmd mkdir -p "$root"
    copy_file_if_exists "$HOME/.gemini" "GEMINI.md" "$root"
    copy_file_if_exists "$HOME/.gemini" "settings.json" "$root"
    copy_file_if_exists "$HOME/.gemini" "config/mcp_config.json" "$root"
    for antigravity_dir in antigravity antigravity-ide; do
        copy_file_if_exists "$HOME/.gemini" "$antigravity_dir/mcp_config.json" "$root"
        copy_file_if_exists "$HOME/.gemini" "$antigravity_dir/user_settings.pb" "$root"
        copy_file_if_exists "$HOME/.gemini" "$antigravity_dir/browserAllowlist.txt" "$root"
        copy_file_if_exists "$HOME/.gemini" "$antigravity_dir/browserOnboardingStatus.txt" "$root"
        sync_dir_mirror "$HOME/.gemini/$antigravity_dir/knowledge" "$root/$antigravity_dir/knowledge"
        sync_dir_mirror "$HOME/.gemini/$antigravity_dir/scratch" "$root/$antigravity_dir/scratch"
    done
}

backup_claude() {
    local root=$1/claude
    remove_tree "$root"
    run_cmd mkdir -p "$root"
    copy_file_if_exists "$HOME/.claude" "settings.json" "$root"
    copy_file_if_exists "$HOME/.claude" "statusline-command.sh" "$root"
    sync_dir_mirror "$HOME/.claude/skills" "$root/skills" ".git/" ".conflicts/" "_migrated_to_shared/"
}

backup_agents() {
    local root=$1/agents
    remove_tree "$root"
    run_cmd mkdir -p "$root"
    sync_dir_mirror "$HOME/.agents/skills" "$root/skills" ".git/" ".conflicts/" "_migrated_to_shared/"
}

backup_shared_skills() {
    local root=$1/shared-skills
    [[ -d "$HOME/.skills" ]] || return 0
    remove_tree "$root"
    run_cmd mkdir -p "$root"
    sync_dir_mirror "$HOME/.skills" "$root" ".git/" ".conflicts/" "_migrated_to_shared/"
}

backup_portable_app_configs() {
    local root=$1/app-configs
    remove_tree "$root"
    run_cmd mkdir -p "$root"

    local config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
    local claude_app="$config_home/Claude"
    copy_file_if_exists "$claude_app" "claude_desktop_config.json" "$root/claude"
    copy_file_if_exists "$claude_app" "extensions-installations.json" "$root/claude"
    copy_file_if_exists "$claude_app" "extensions-blocklist.json" "$root/claude"
    copy_file_if_exists "$claude_app" "cowork-enabled-cli-ops.json" "$root/claude"
    sync_dir_mirror "$claude_app/Claude Extensions Settings" "$root/claude/Claude Extensions Settings"

    local codex_app="$config_home/Codex"
    copy_file_if_exists "$codex_app" "browser-sidebar-local-servers.json" "$root/codex"

    local openai_codex_app="$config_home/OpenAI/Codex"
    copy_file_if_exists "$openai_codex_app" "chrome-native-hosts-v2.json" "$root/openai-codex"
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
    echo "Backing up portable app config..."
    backup_portable_app_configs "$root"
}

path_signature() {
    local target_path=$1
    [[ -e "$target_path" ]] || return 0
    if [[ -f "$target_path" ]]; then
        sha256sum "$target_path" | awk '{print "FILE:" $1}'
        return 0
    fi
    find "$target_path" -type f -print0 | sort -z | xargs -0 sha256sum | sed "s|$target_path/||" | tr '\n' '|'
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

resolve_sync_skill_conflict() {
    local assistant_name=$1
    local local_path=$2
    local shared_path=$3
    local decision="$CONFLICT_POLICY"
    local skill_name
    skill_name=$(basename "$local_path")

    if [[ "$decision" == "interactive" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "[dry-run] skill conflict for $assistant_name:$skill_name; would prompt, default preview keeps shared"
            decision="prefer-shared"
        else
            echo "Skill conflict for $assistant_name:$skill_name"
            echo -n "Choose local or shared? (l/s): "
            read -n 1 -r choice
            echo
            if [[ "$choice" == "l" || "$choice" == "L" ]]; then
                decision="prefer-local"
            else
                decision="prefer-shared"
            fi
        fi
    fi

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    if [[ "$decision" == "prefer-local" ]]; then
        copy_top_level_item "$shared_path" "$HOME/.skills/.conflicts/$assistant_name/$timestamp/$skill_name"
        copy_top_level_item "$local_path" "$shared_path"
        echo "Updated shared skill from $assistant_name: $skill_name"
        return
    fi

    copy_top_level_item "$local_path" "$HOME/.skills/.conflicts/$assistant_name/$timestamp/$skill_name"
    echo "Kept shared skill and preserved conflicting local copy: $skill_name"
}

audit_skills() {
    ensure_shared_skills_dir
    echo "=== Shared Skills Audit ==="
    local shared_count=0
    if [[ -d "$HOME/.skills" ]]; then
        shared_count=$(find_shared_skill_items | wc -l | awk '{print $1}')
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
        local_count=$(find_assistant_skill_items "$skill_root" | wc -l | awk '{print $1}')
        echo "[$assistant] local skills: $local_count"
        while IFS= read -r item; do
            local skill_name
            skill_name=$(basename "$item")
            if [[ -e "$HOME/.skills/$skill_name" ]]; then
                echo "  - duplicate: $skill_name"
            fi
        done < <(find_assistant_skill_items "$skill_root")
    done
}

sync_skills() {
    ensure_shared_skills_dir
    for assistant in codex claude; do
        local skill_root="$HOME/.${assistant}/skills"
        [[ -d "$skill_root" ]] || continue
        echo "Syncing skills from $assistant into shared set..."
        while IFS= read -r item; do
            local skill_name
            skill_name=$(basename "$item")
            local shared_path="$HOME/.skills/$skill_name"
            if [[ ! -e "$shared_path" ]]; then
                copy_top_level_item "$item" "$shared_path"
                echo "Added shared skill from $assistant: $skill_name"
                continue
            fi

            local local_sig
            local shared_sig
            local_sig=$(path_signature "$item")
            shared_sig=$(path_signature "$shared_path")
            if [[ "$local_sig" != "$shared_sig" ]]; then
                resolve_sync_skill_conflict "$assistant" "$item" "$shared_path"
            fi
        done < <(find_assistant_skill_items "$skill_root")
    done

    for assistant in codex claude; do
        local skill_root="$HOME/.${assistant}/skills"
        run_cmd mkdir -p "$skill_root"
        echo "Mirroring shared skills into $assistant..."
        while IFS= read -r item; do
            local skill_name
            skill_name=$(basename "$item")
            local destination="$skill_root/$skill_name"
            if [[ ! -e "$destination" || "$(path_signature "$item")" != "$(path_signature "$destination")" ]]; then
                copy_top_level_item "$item" "$destination"
                echo "Mirrored shared skill to $assistant: $skill_name"
            fi
        done < <(find_shared_skill_items)
    done
}

destructive_migrate_skills() {
    ensure_shared_skills_dir
    for assistant in codex claude; do
        local skill_root="$HOME/.${assistant}/skills"
        [[ -d "$skill_root" ]] || continue
        echo "Migrating skills from $assistant..."
        while IFS= read -r item; do
            local skill_name
            skill_name=$(basename "$item")
            local shared_path="$HOME/.skills/$skill_name"
            if [[ ! -e "$shared_path" ]]; then
                if [[ -d "$item" ]]; then
                    sync_dir_mirror "$item" "$shared_path" ".git/"
                else
                    copy_file_if_exists "$(dirname "$item")" "$skill_name" "$HOME/.skills"
                fi
                archive_skill_item "$item" "$skill_root/_migrated_to_shared/$(date +%Y%m%d_%H%M%S)"
                echo "Promoted to shared: $skill_name"
                continue
            fi

            local local_sig
            local shared_sig
            local_sig=$(path_signature "$item")
            shared_sig=$(path_signature "$shared_path")
            if [[ "$local_sig" == "$shared_sig" ]]; then
                archive_skill_item "$item" "$skill_root/_migrated_to_shared/$(date +%Y%m%d_%H%M%S)"
                echo "Archived duplicate local skill: $skill_name"
                continue
            fi

            resolve_skill_conflict "$assistant" "$item" "$shared_path"
        done < <(find_assistant_skill_items "$skill_root")
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
    confirm "Preview text diffs before restore" || return 0

    preview_diff_if_changed "$HOME/.codex/AGENTS.md" "$root/codex/AGENTS.md" "codex/AGENTS.md"
    preview_diff_if_changed "$HOME/.codex/config.toml" "$root/codex/config.toml" "codex/config.toml"
    preview_diff_if_changed "$HOME/.gemini/GEMINI.md" "$root/gemini/GEMINI.md" "gemini/GEMINI.md"
    preview_diff_if_changed "$HOME/.gemini/settings.json" "$root/gemini/settings.json" "gemini/settings.json"
    preview_diff_if_changed "$HOME/.gemini/config/mcp_config.json" "$root/gemini/config/mcp_config.json" "gemini/config/mcp_config.json"
    preview_diff_if_changed "$HOME/.gemini/antigravity/mcp_config.json" "$root/gemini/antigravity/mcp_config.json" "gemini/antigravity/mcp_config.json"
    preview_diff_if_changed "$HOME/.gemini/antigravity-ide/mcp_config.json" "$root/gemini/antigravity-ide/mcp_config.json" "gemini/antigravity-ide/mcp_config.json"
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
    sync_dir_mirror "$root/skills" "$HOME/.codex/skills" ".system/" ".git/" ".conflicts/" "_migrated_to_shared/"
}

restore_gemini() {
    local root=$1/gemini
    [[ -d "$root" ]] || return 0
    run_cmd mkdir -p "$HOME/.gemini"
    copy_file_if_exists "$root" "GEMINI.md" "$HOME/.gemini"
    copy_file_if_exists "$root" "settings.json" "$HOME/.gemini"
    copy_file_if_exists "$root" "config/mcp_config.json" "$HOME/.gemini"
    for antigravity_dir in antigravity antigravity-ide; do
        copy_file_if_exists "$root" "$antigravity_dir/mcp_config.json" "$HOME/.gemini"
        copy_file_if_exists "$root" "$antigravity_dir/user_settings.pb" "$HOME/.gemini"
        copy_file_if_exists "$root" "$antigravity_dir/browserAllowlist.txt" "$HOME/.gemini"
    done
}

restore_claude() {
    local root=$1/claude
    [[ -d "$root" ]] || return 0
    run_cmd mkdir -p "$HOME/.claude"
    copy_file_if_exists "$root" "settings.json" "$HOME/.claude"
    copy_file_if_exists "$root" "statusline-command.sh" "$HOME/.claude"
    [[ -f "$HOME/.claude/statusline-command.sh" ]] && run_cmd chmod +x "$HOME/.claude/statusline-command.sh"
    sync_dir_mirror "$root/skills" "$HOME/.claude/skills" ".git/" ".conflicts/" "_migrated_to_shared/"
}

restore_agents() {
    local root=$1/agents
    [[ -d "$root" ]] || return 0
    run_cmd mkdir -p "$HOME/.agents"
    sync_dir_mirror "$root/skills" "$HOME/.agents/skills" ".git/" ".conflicts/" "_migrated_to_shared/"
}

restore_shared_skills() {
    local root=$1/shared-skills
    [[ -d "$root" ]] || return 0
    run_cmd mkdir -p "$HOME/.skills"
    sync_dir_mirror "$root" "$HOME/.skills" ".git/" ".conflicts/" "_migrated_to_shared/"
}

restore_portable_app_configs() {
    local root=$1/app-configs
    [[ -d "$root" ]] || return 0

    local config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
    local claude_app="$config_home/Claude"
    run_cmd mkdir -p "$claude_app"
    copy_file_if_exists "$root/claude" "claude_desktop_config.json" "$claude_app"
    copy_file_if_exists "$root/claude" "extensions-installations.json" "$claude_app"
    copy_file_if_exists "$root/claude" "extensions-blocklist.json" "$claude_app"
    copy_file_if_exists "$root/claude" "cowork-enabled-cli-ops.json" "$claude_app"
    sync_dir_mirror "$root/claude/Claude Extensions Settings" "$claude_app/Claude Extensions Settings"

    local codex_app="$config_home/Codex"
    run_cmd mkdir -p "$codex_app"
    copy_file_if_exists "$root/codex" "browser-sidebar-local-servers.json" "$codex_app"

    local openai_codex_app="$config_home/OpenAI/Codex"
    run_cmd mkdir -p "$openai_codex_app"
    copy_file_if_exists "$root/openai-codex" "chrome-native-hosts-v2.json" "$openai_codex_app"
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
    show_menu "Select Action" "Backup" "Restore" "Audit" "Sync-Skills" "Migrate-Skills"
    choice_idx=$?
    case "$choice_idx" in
        0) ACTION="backup" ;;
        1) ACTION="restore" ;;
        2) ACTION="audit" ;;
        3) ACTION="sync-skills" ;;
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

if [[ "$ACTION" == "sync-skills" ]]; then
    sync_skills
    exit 0
fi

if [[ "$ACTION" == "migrate-skills" ]]; then
    if [[ "$DESTRUCTIVE_MIGRATE" == "true" ]]; then
        destructive_migrate_skills
    else
        echo "migrate-skills now aliases safe sync-skills. Use --destructive-migrate to archive/remove local copies."
        sync_skills
    fi
    exit 0
fi

if confirm "Pull latest settings from Git"; then
    git_sync_pull
fi

BACKUP_DIR="$BACKUP_DIR_DEFAULT"
if [[ "$ACTION" == "backup" && "$VERSIONED" == "true" ]]; then
    BACKUP_DIR="$BASE_BACKUP_DIR/${HOSTNAME}_$(date +%Y-%m-%d_%H%M%S)"
fi

if [[ "$ACTION" == "backup" ]]; then
    if [[ "$DRY_RUN" == "true" && ! -t 0 ]]; then
        echo "Using default backup path: $BACKUP_DIR"
    else
        echo "Enter the full path (default: $BACKUP_DIR):"
        read input_dir
        BACKUP_DIR="${input_dir:-$BACKUP_DIR}"
    fi
    backup_all "$BACKUP_DIR"
    echo "Backup complete."

    if confirm "Push backup changes to Git"; then
        git_sync_push "$BACKUP_DIR"
    fi

    if [[ "$VERSIONED" == "true" ]]; then
        OLD_BACKUPS=$(find "$BASE_BACKUP_DIR" -maxdepth 1 -type d -name "${HOSTNAME}_*" -mtime +30)
        if [[ -n "$OLD_BACKUPS" ]]; then
            echo "Old versioned backups found."
            if confirm "Prune old backups"; then
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
    echo "Restoring portable app config..."
    restore_portable_app_configs "$BACKUP_DIR"
    echo "Restore complete."
fi

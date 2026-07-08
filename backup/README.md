# Backup Scripts

This directory contains the backup and sync tooling for IDE, LLM, and Plex data.

## Scripts

| Script | Purpose |
|--------|---------|
| `Antigravity_Sync_Win.ps1` | Windows Antigravity backup and restore with WSL-aware support |
| `Antigravity_Sync_Linux.sh` | Linux Antigravity backup and restore |
| `Antigravity_Sync_Mac.sh` | macOS Antigravity backup and restore |
| `LLM_Sync_Win.ps1` | Windows backup, restore, audit, and shared-skill mirror for Codex, Gemini, Claude, and Agents |
| `LLM_Sync_Linux.sh` | Linux backup, restore, audit, and shared-skill mirror for Codex, Gemini, Claude, and Agents |
| `LLM_Sync_Mac.sh` | macOS backup, restore, audit, and shared-skill mirror for Codex, Gemini, Claude, and Agents |
| `plex_backup.ps1` | Plex backup workflow that stops services and archives data |

## LLM Sync Model

The LLM sync scripts treat the backup location as a machine-scoped golden master:

```text
<BaseBackupPath>/
  <machine-name>/
    codex/
    gemini/
    claude/
    agents/
    shared-skills/
    app-configs/
```

### What Gets Backed Up

- `codex/`: portable `AGENTS.md`, `config.toml`, `memories/`, `rules/`, and non-system `skills/`
- `gemini/`: portable `GEMINI.md`, `settings.json`, `config/mcp_config.json`, selected `antigravity` and `antigravity-ide` config files, plus optional backup snapshots of `knowledge/` and `scratch/`
- `claude/`: portable `settings.json` and `skills/` excluding nested `.git`
- `agents/`: portable `.agents/skills/` content excluding nested `.git`
- `shared-skills/`: canonical `~/.skills` content excluding nested `.git`, `.conflicts`, and migration archives
- `app-configs/`: portable Claude and Codex app config and extension metadata only

### What Does Not Get Backed Up

- auth/session files
- caches and logs
- local databases
- project-local conversation state
- machine-specific indexes
- nested `.git` directories inside shared skill stores
- browser profiles, IndexedDB, cookies, Crashpad, Sentry, tokens, and app sessions
- Claude app `config.json`, because it can contain OAuth token cache state

## Shared Skills

The scripts now assume `~/.skills` is the canonical shared skill location.

Behavior:

- `backup` and `restore` auto-create `~/.skills` if it is missing
- `audit` reports shared skills plus assistant-local duplicates
- `sync-skills` builds the union of Codex and Claude skills in `~/.skills`
- `sync-skills` mirrors the shared set back into `~/.codex/skills` and `~/.claude/skills` without deleting extra local skill folders
- `migrate-skills` is a compatibility alias for `sync-skills` unless the explicit destructive flag is used
- if a shared and local skill differ, the script uses the selected conflict policy and preserves conflict copies under `~/.skills/.conflicts/`

## Conflict Handling

`sync-skills` and `migrate-skills` support three conflict policies:

- `interactive`: ask whether to keep the local or shared copy
- `prefer-local`: update shared from local, preserving the previous shared copy under `.conflicts`
- `prefer-shared`: keep shared, preserving the conflicting local copy under `.conflicts`

Legacy destructive migration is opt-in only:

- Windows: `-DestructiveMigrate`
- macOS/Linux: `--destructive-migrate`

Recommended workflow:

1. Run `audit` first.
2. Run `sync-skills` with `--dry-run` or `-DryRun`.
3. Run real `sync-skills`.
4. Run `backup` with dry-run.
5. Run real `backup`.
6. Inspect the private backup diff before pushing.

For normal backup and restore, keep the workflow conservative:

- use `backup` to publish local intentional changes into the golden master
- use `restore` only when you want to pull the golden master back down
- use `dry-run` before either when you are unsure

### Gemini Restore Scope

Gemini restore is intentionally narrower than Gemini backup:

- restored: `GEMINI.md`, `settings.json`, `config/mcp_config.json`, `antigravity/mcp_config.json`, `antigravity/user_settings.pb`, `antigravity/browserAllowlist.txt`, `antigravity-ide/mcp_config.json`, `antigravity-ide/user_settings.pb`, and `antigravity-ide/browserAllowlist.txt`
- not restored: `antigravity/knowledge`, `antigravity/scratch`, `antigravity/browserOnboardingStatus.txt`, `antigravity-ide/knowledge`, `antigravity-ide/scratch`, and `antigravity-ide/browserOnboardingStatus.txt`

This keeps the LLM sync suite focused on portable Gemini config while avoiding noisy or machine-specific Antigravity state during restore.

## Commands

### Windows

```powershell
.\LLM_Sync_Win.ps1 -Action audit
.\LLM_Sync_Win.ps1 -Action sync-skills -DryRun
.\LLM_Sync_Win.ps1 -Action sync-skills -ConflictPolicy prefer-local
.\LLM_Sync_Win.ps1 -Action backup -Versioned
.\LLM_Sync_Win.ps1 -Action restore -WhatIf
```

### Linux

```bash
./LLM_Sync_Linux.sh audit
./LLM_Sync_Linux.sh sync-skills --dry-run
./LLM_Sync_Linux.sh sync-skills --conflict-policy=prefer-shared
./LLM_Sync_Linux.sh backup
./LLM_Sync_Linux.sh backup --machine-name=JKWORK
./LLM_Sync_Linux.sh restore --dry-run
```

### macOS

```bash
./LLM_Sync_Mac.sh audit
./LLM_Sync_Mac.sh sync-skills --dry-run
./LLM_Sync_Mac.sh sync-skills --conflict-policy=prefer-local
./LLM_Sync_Mac.sh backup
./LLM_Sync_Mac.sh backup --machine-name=JKWORK
./LLM_Sync_Mac.sh restore --dry-run
```

On macOS and Linux, the default machine folder now uses the short host name with any domain suffix removed, so `JKWORK.local` becomes `JKWORK`. Use `--machine-name=<name>` to override it explicitly.

## Config Files

These scripts expect config files in your private config repo:

- `C:\Users\<you>\Private\Configs\LLM_Sync_Win.json`
- `~/Private/Configs/LLM_Sync_Linux.json`
- `~/Private/Configs/LLM_Sync_Mac.json`

Example Windows config:

```json
{
  "BaseBackupPath": "C:\\Users\\jkowa\\Private\\LLM",
  "PreRestorePath": "D:\\tmp"
}
```

Example Linux/macOS config:

```json
{
  "DefaultBackupPath": "~/Private/LLM",
  "PreRestorePath": "/tmp"
}
```

## Testing Strategy

Safest order:

1. `audit`
2. `sync-skills` with dry-run
3. real `sync-skills`
4. `backup` with dry-run
5. real `backup`
6. inspect `git -C ~/Private/LLM diff`
7. push

Use `restore` only after the backup tree looks correct.

# Backup Scripts

This directory contains the backup and sync tooling for IDE, LLM, and Plex data.

## Scripts

| Script | Purpose |
|--------|---------|
| `Antigravity_Sync_Win.ps1` | Windows Antigravity backup and restore with WSL-aware support |
| `Antigravity_Sync_Linux.sh` | Linux Antigravity backup and restore |
| `Antigravity_Sync_Mac.sh` | macOS Antigravity backup and restore |
| `LLM_Sync_Win.ps1` | Windows backup, restore, audit, and shared-skill migration for Codex, Gemini, Claude |
| `LLM_Sync_Linux.sh` | Linux backup, restore, audit, and shared-skill migration for Codex, Gemini, Claude |
| `LLM_Sync_Mac.sh` | macOS backup, restore, audit, and shared-skill migration for Codex, Gemini, Claude |
| `plex_backup.ps1` | Plex backup workflow that stops services and archives data |

## LLM Sync Model

The LLM sync scripts treat the backup location as a machine-scoped golden master:

```text
<BaseBackupPath>/
  <machine-name>/
    codex/
    gemini/
    claude/
    shared-skills/
```

### What Gets Backed Up

- `codex/`: portable `AGENTS.md`, `config.toml`, `memories/`, `rules/`, and non-system `skills/`
- `gemini/`: portable `GEMINI.md`, `settings.json`, selected `antigravity` config files, plus optional backup snapshots of `knowledge/` and `scratch/`
- `claude/`: portable `settings.json` and `skills/` excluding nested `.git`
- `shared-skills/`: canonical `~/.skills` content excluding nested `.git`

### What Does Not Get Backed Up

- auth/session files
- caches and logs
- local databases
- project-local conversation state
- machine-specific indexes
- nested `.git` directories inside shared skill stores

## Shared Skills

The scripts now assume `~/.skills` is the canonical shared skill location.

Behavior:

- `backup` and `restore` auto-create `~/.skills` if it is missing
- `audit` reports shared skills plus assistant-local duplicates
- `migrate-skills` promotes assistant-local skills into `~/.skills`
- local skill copies are archived into `_migrated_to_shared/<timestamp>/` before removal
- if a shared and local skill differ, the script uses the selected conflict policy

## Conflict Handling

`migrate-skills` supports three conflict policies:

- `interactive`: ask whether to keep the local or shared copy
- `prefer-local`: update shared from local, then archive the local copy
- `prefer-shared`: keep shared, archive the local copy

Recommended workflow:

1. Run `audit` first.
2. Run `migrate-skills` with `--dry-run` or `-DryRun`.
3. Review archived paths and backup diffs.
4. Run `backup`.
5. Push only after reviewing the machine subtree diff.

For normal backup and restore, keep the workflow conservative:

- use `backup` to publish local intentional changes into the golden master
- use `restore` only when you want to pull the golden master back down
- use `dry-run` before either when you are unsure

### Gemini Restore Scope

Gemini restore is intentionally narrower than Gemini backup:

- restored: `GEMINI.md`, `settings.json`, `antigravity/mcp_config.json`, `antigravity/user_settings.pb`, and `antigravity/browserAllowlist.txt`
- not restored: `antigravity/knowledge`, `antigravity/scratch`, and `antigravity/browserOnboardingStatus.txt`

This keeps the LLM sync suite focused on portable Gemini config while avoiding noisy or machine-specific Antigravity state during restore.

## Commands

### Windows

```powershell
.\LLM_Sync_Win.ps1 -Action audit
.\LLM_Sync_Win.ps1 -Action migrate-skills -DryRun
.\LLM_Sync_Win.ps1 -Action migrate-skills -ConflictPolicy prefer-local
.\LLM_Sync_Win.ps1 -Action backup -Versioned
.\LLM_Sync_Win.ps1 -Action restore -WhatIf
```

### Linux

```bash
./LLM_Sync_Linux.sh audit
./LLM_Sync_Linux.sh migrate-skills --dry-run
./LLM_Sync_Linux.sh migrate-skills --conflict-policy=prefer-shared
./LLM_Sync_Linux.sh backup
./LLM_Sync_Linux.sh restore --dry-run
```

### macOS

```bash
./LLM_Sync_Mac.sh audit
./LLM_Sync_Mac.sh migrate-skills --dry-run
./LLM_Sync_Mac.sh migrate-skills --conflict-policy=prefer-local
./LLM_Sync_Mac.sh backup
./LLM_Sync_Mac.sh restore --dry-run
```

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
2. `migrate-skills` with dry-run
3. `backup` with dry-run
4. real `backup`
5. inspect Git diff
6. push

Use `restore` only after the backup tree looks correct.

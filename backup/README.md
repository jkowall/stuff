# Backup Scripts

This directory contains the backup and sync tooling for LLM and Plex data.

## Scripts

| Script | Purpose |
|--------|---------|
| `LLM_Sync_Win.ps1` | Windows backup, restore, audit, shared-skill mirror, and repository-skill installer |
| `LLM_Sync_Linux.sh` | Linux backup, restore, audit, shared-skill mirror, and repository-skill installer |
| `LLM_Sync_Mac.sh` | macOS backup, restore, audit, shared-skill mirror, and repository-skill installer |
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
- `install-repo-skills` installs every valid package from the repository's `skills/` directory into `~/.skills`, then mirrors just those packages to Codex and Claude
- `migrate-skills` is a compatibility alias for `sync-skills` unless the explicit destructive flag is used
- if a shared and local skill differ, the script uses the selected conflict policy and preserves conflict copies under `~/.skills/.conflicts/`

`install-repo-skills` treats the checked-out repository version as authoritative for
same-named packages. It preserves each differing shared or assistant-local copy under
`~/.skills/.conflicts/repo-install/<timestamp>/` before replacement and never deletes
unrelated skills. Before copying anything, it validates every package's frontmatter,
matching directory/name, and non-empty description. Dry-run totals distinguish
planned updates from already-current packages. Use the preview first when you have
local customizations.

## Conflict Handling

`sync-skills` and `migrate-skills` support three conflict policies:

- `interactive`: ask whether to keep the local or shared copy
- `prefer-local`: update shared from local, preserving the previous shared copy under `.conflicts`
- `prefer-shared`: keep shared, preserving the conflicting local copy under `.conflicts`

Legacy destructive migration is opt-in only:

- Windows: `-DestructiveMigrate`
- macOS/Linux: `--destructive-migrate`

Recommended workflow:

1. Preview `install-repo-skills` when installing or updating repository skills.
2. Run real `install-repo-skills` and restart the assistant session.
3. Run `audit` first for the broader shared set.
4. Run `sync-skills` with `--dry-run` or `-DryRun`.
5. Run real `sync-skills`.
6. Run `backup` with dry-run.
7. Run real `backup`.
8. Inspect the private backup diff before pushing.

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
.\LLM_Sync_Win.ps1 -Action install-repo-skills -DryRun
.\LLM_Sync_Win.ps1 -Action install-repo-skills
.\LLM_Sync_Win.ps1 -Action sync-skills -DryRun
.\LLM_Sync_Win.ps1 -Action sync-skills -ConflictPolicy prefer-local
.\LLM_Sync_Win.ps1 -Action backup -Versioned
.\LLM_Sync_Win.ps1 -Action restore -WhatIf
```

### Linux

```bash
./LLM_Sync_Linux.sh audit
./LLM_Sync_Linux.sh install-repo-skills --dry-run
./LLM_Sync_Linux.sh install-repo-skills
./LLM_Sync_Linux.sh sync-skills --dry-run
./LLM_Sync_Linux.sh sync-skills --conflict-policy=prefer-shared
./LLM_Sync_Linux.sh backup
./LLM_Sync_Linux.sh backup --machine-name=JKWORK
./LLM_Sync_Linux.sh restore --dry-run
```

### macOS

```bash
./LLM_Sync_Mac.sh audit
./LLM_Sync_Mac.sh install-repo-skills --dry-run
./LLM_Sync_Mac.sh install-repo-skills
./LLM_Sync_Mac.sh sync-skills --dry-run
./LLM_Sync_Mac.sh sync-skills --conflict-policy=prefer-local
./LLM_Sync_Mac.sh backup
./LLM_Sync_Mac.sh backup --machine-name=JKWORK
./LLM_Sync_Mac.sh restore --dry-run
```

On macOS and Linux, the default machine folder now uses the short host name with any domain suffix removed, so `JKWORK.local` becomes `JKWORK`. Use `--machine-name=<name>` to override it explicitly.

## Config Files

Backup and restore expect config files in your private config repo:

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

`audit`, `sync-skills`, `migrate-skills`, and `install-repo-skills` are
configuration-free and can run directly from a fresh checkout.

## Testing Strategy

Safest order:

1. `install-repo-skills` with dry-run when repository skills changed
2. real `install-repo-skills`
3. `audit`
4. `sync-skills` with dry-run
5. real `sync-skills`
6. `backup` with dry-run
7. real `backup`
8. inspect `git -C ~/Private/LLM diff`
9. push

Use `restore` only after the backup tree looks correct.

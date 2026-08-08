# Personal Scripts Collection

A collection of PowerShell and shell scripts for system automation, backup, and media management.

## Documentation

| File | Description |
|------|-------------|
| [`README.md`](README.md) | This file; documents all scripts and configuration |
| [`AGENTS.md`](AGENTS.md) | Instructions for AI coding assistants working with this repo |
| [`backup/README.md`](backup/README.md) | Detailed backup and sync workflow documentation |
| [`skills/README.md`](skills/README.md) | Workflow skill catalog, safety model, and installation instructions |
| [`LLM_Instructions.md`](LLM_Instructions.md) | Public-safe professional identity and working preferences for AI services |

## Scripts

### Backup & Sync

LLM Sync scripts provide a cross-platform backup, restore, and skill mirror flow for assistant home directories and a shared `~/.skills` folder.

**Key Features:**

- **Per-Assistant Subdirectories**: Each machine backup stores `codex/`, `gemini/`, `claude/`, `agents/`, `shared-skills/`, and portable `app-configs/` separately for safer restores.
- **Shared Skill Mirror**: `sync-skills` unions Codex and Claude skills into `~/.skills`, then mirrors the shared set back into both assistant-local skill directories without deleting extra local skill folders.
- **Repository Skill Installer**: `install-repo-skills` safely installs or updates every skill in this repository, preserving differing installed copies before replacement. Skill-only actions do not require backup configuration.
- **Conservative Whitelisting**: Sync only portable config, prompts, rules, memories, skills, Antigravity and Antigravity IDE config, and app metadata. Skip auth/session files, caches, logs, local databases, browser profiles, and project-local conversation state.
- **Safety Restore Flow**: Restore creates a pre-restore snapshot outside Git and can preview diffs for key text config files before overwrite.
- **Scoped Git Integration**: Optional pull before sync and push after backup, staging only the selected backup subtree instead of unrelated repo changes.
- **Dry Run Support**: Preview file operations and Git mutations before changing anything.

| Script | Description |
|--------|-------------|
| [`LLM_Sync_Win.ps1`](backup/LLM_Sync_Win.ps1) | Windows backup and restore for portable Codex, Gemini, Claude, Agents, and shared `.skills` settings. Gemini restore skips volatile Antigravity state. |
| [`LLM_Sync_Mac.sh`](backup/LLM_Sync_Mac.sh) | macOS backup and restore for portable Codex, Gemini, Claude, Agents, and shared `.skills` settings. Gemini restore skips volatile Antigravity state. |
| [`LLM_Sync_Linux.sh`](backup/LLM_Sync_Linux.sh) | Linux backup and restore for portable Codex, Gemini, Claude, Agents, and shared `.skills` settings. Gemini restore skips volatile Antigravity state. |
| [`plex_backup.ps1`](backup/plex_backup.ps1) | Backup Plex Media Server data and registry settings to a compressed 7z archive. Handles service stop/start automatically. |

### Workflow Skills

The [`skills/`](skills/README.md) catalog contains seven reusable workflows:

- exact-head maintainer PR review through a verified terminal state
- dependency and security-alert remediation across repositories
- Spacelift cross-source artifact reconciliation
- macOS updater health diagnosis
- resumable Featurebase and product-feedback backlog cleanup
- contract redline and execution-readiness review
- validated upstream technical proposals and PR slicing

Each package documents its inputs, evidence order, procedure, mutation boundaries,
output, and stopping conditions. Install all of them with the platform LLM sync
script; see the examples below or the [skill catalog](skills/README.md).

### System Maintenance

The `system/` directory is organized by platform: `macos/`, `windows/`, and `linux/`.

#### macOS (`system/macos/`)

| Script | Description |
|--------|-------------|
| [`audit_apps.sh`](system/macos/audit_apps.sh) | Audits installed GUI applications and identifies their source (Homebrew, App Store, or Manual). |
| [`sync_apps.sh`](system/macos/sync_apps.sh) | Compares an audit file with local state and installs missing managed apps. |
| [`Update-AllPackages_Mac.sh`](system/macos/Update-AllPackages_Mac.sh) | Weekly updater for Homebrew, Mac App Store (`mas`), MacUpdater, generic npm packages, pipx apps when installed, and rustup. It skips bulk pip updates and tracks Codex alpha and Claude next independently under `~/.local`. |
| [`Setup-PackageUpdateTasks_Mac.sh`](system/macos/Setup-PackageUpdateTasks_Mac.sh) | Installs/removes the macOS weekly launchd job for updates. |
| [`test-package-update-scripts.sh`](system/macos/tests/test-package-update-scripts.sh) | Offline regression tests for updater status, host-scoped log retention, and launchd rendering. |

#### Windows (`system/windows/`)

| Script | Description |
|--------|-------------|
| [`Update-AllPackages_Win.ps1`](system/windows/Update-AllPackages_Win.ps1) | Weekly updater for winget, Windows Store, Chocolatey, generic npm packages, WSL apt, and pip. It tracks Codex alpha and Claude next, updating each independently from the generic npm batch. |
| [`Update-AllPackages_Win.Core.ps1`](system/windows/Update-AllPackages_Win.Core.ps1) | Side-effect-free parser, status, and atomic last-run record helpers. |
| [`Setup-PackageUpdateTasks.ps1`](system/windows/Setup-PackageUpdateTasks.ps1) | Sets up a Windows Task Scheduler task for weekly updates and keeps the scheduled run window visible after completion. |
| [`Test-Update-AllPackages_Win.ps1`](system/windows/tests/Test-Update-AllPackages_Win.ps1) | Offline regression tests for WinGet parsing, status records, and task rendering. |
| [`list_apps.ps1`](system/windows/list_apps.ps1) | Lists installed applications from multiple sources (Registry, Store, Winget, etc.). |
| [`Update-CloudflareDNS.ps1`](system/windows/Update-CloudflareDNS.ps1) | Dynamic DNS updater for Cloudflare with optional daily Task Scheduler management. |
| [`clean_plex.ps1`](system/windows/clean_plex.ps1) | Cleans up orphaned data and caches in Plex Media Server. |
| [`restart_camera_hub.ps1`](system/windows/restart_camera_hub.ps1) | Restarts the Elgato Camera Hub application. |
| [`Toggle-PrompterDisplayAndRestartCameraHub.ps1`](system/windows/Toggle-PrompterDisplayAndRestartCameraHub.ps1) | Toggles the Elgato Prompter display and restarts Camera Hub after power-off. |

#### Linux (`system/linux/`)

| Script | Description |
|--------|-------------|
| [`Update-AllPackages_Linux.sh`](system/linux/Update-AllPackages_Linux.sh) | Linux (Ubuntu) package updater (apt, snap, flatpak, npm, pip, rustup). |
| [`Setup-PackageUpdateTasks_Linux.sh`](system/linux/Setup-PackageUpdateTasks_Linux.sh) | Installs/removes the Linux weekly cron schedule. |

Package updater scripts no longer schedule themselves when you run them manually. Use the platform-specific setup script to install or remove the weekly schedule:

- Windows: `system/windows/Setup-PackageUpdateTasks.ps1`
- Linux: `system/linux/Setup-PackageUpdateTasks_Linux.sh`
- macOS: `system/macos/Setup-PackageUpdateTasks_Mac.sh`

Run the package-updater regression suites without invoking package managers or changing scheduler state:

```bash
/bin/bash system/macos/tests/test-package-update-scripts.sh
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\system\windows\tests\Test-Update-AllPackages_Win.ps1
```

The Windows updater writes `system/logs/Update-AllPackages_Win_<machine>_last-run.json` before its keep-open delay. Use `system/windows/Setup-PackageUpdateTasks.ps1 -RenderOnly` to inspect the task definition without elevation or scheduler changes.

The Cloudflare dynamic DNS updater can install or remove its own daily Windows Task Scheduler entry. The task runs at 12:00 PM by default under the signed-in user and catches up when the PC becomes available after a missed run:

```powershell
# Install or update the daily task at noon
.\system\windows\Update-CloudflareDNS.ps1 -InstallScheduledTask

# Choose another local time
.\system\windows\Update-CloudflareDNS.ps1 -InstallScheduledTask -DailyAt '06:30'

# Remove the task
.\system\windows\Update-CloudflareDNS.ps1 -RemoveScheduledTask
```

### Media Processing

| Script | Description |
|--------|-------------|
| [`Convert-Mp4ToIg.ps1`](media/Convert-Mp4ToIg.ps1) | Batch converts MP4 files for Instagram (1080x1350 portrait format) using FFmpeg. |
| [`instagram.ps1`](media/instagram.ps1) | Re-encodes videos for Instagram in a directory using FFmpeg. |
| [`download.ps1`](media/download.ps1) | Downloads media from YouTube or SoundCloud using yt-dlp and scdl. |

## Configuration

Backup and restore actions use external JSON config files stored in your **Private repository** (`C:\Users\jkowa\Private\Configs`). These config files are **not tracked in Git** here to protect sensitive data. `audit`, `sync-skills`, `migrate-skills`, and `install-repo-skills` do not require them.

### Required Config Files (In Private Repo)

| Config File | Required By | Keys |
|-------------|-------------|------|
| `Update-CloudflareDNS.json` | `Update-CloudflareDNS.ps1` | `ApiToken`, `ZoneId`, `DnsRecordName`, `TtlValue` |
| `LLM_Sync_Win.json` | `LLM_Sync_Win.ps1` | `BaseBackupPath`, `PreRestorePath` (optional) |
| `LLM_Sync_Mac.json` | `LLM_Sync_Mac.sh` | `DefaultBackupPath`, `PreRestorePath` (optional) |
| `LLM_Sync_Linux.json` | `LLM_Sync_Linux.sh` | `DefaultBackupPath`, `PreRestorePath` (optional) |
| `plex_backup.json` | `plex_backup.ps1` | `PlexDataPath`, `BackupDestination`, `TempWorkingPath`, `7ZipPath` |

### Example Config Templates

**LLM_Sync_Win.json:**

```json
{
    "BaseBackupPath": "C:\\Users\\jkowa\\OneDrive\\Stuff\\assistant-backups",
    "PreRestorePath": "D:\\tmp"
}
```

**LLM_Sync_Mac.json / LLM_Sync_Linux.json:**

```json
{
    "DefaultBackupPath": "~/assistant-backups",
    "PreRestorePath": "/tmp"
}
```

**Update-CloudflareDNS.json:**

```json
{
    "ApiToken": "your-cloudflare-api-token",
    "ZoneId": "your-zone-id",
    "DnsRecordName": "subdomain.example.com",
    "TtlValue": 120
}
```

**plex_backup.json:**

```json
{
    "PlexDataPath": "D:\\plex",
    "BackupDestination": "E:\\backups\\plex",
    "TempWorkingPath": "D:\\tmp",
    "7ZipPath": "C:\\path\\to\\7z.exe"
}
```

### LLM Sync Examples

**Windows backup (default machine folder):**

```powershell
.\backup\LLM_Sync_Win.ps1 -Action backup
```

**Windows versioned backup preview only:**

```powershell
.\backup\LLM_Sync_Win.ps1 -Action backup -Versioned -DryRun
```

**Windows shared skill sync preview:**

```powershell
.\backup\LLM_Sync_Win.ps1 -Action sync-skills -DryRun
```

**Windows install or update repository skills:**

```powershell
.\backup\LLM_Sync_Win.ps1 -Action install-repo-skills -DryRun
.\backup\LLM_Sync_Win.ps1 -Action install-repo-skills
```

**Windows restore preview using PowerShell WhatIf:**

```powershell
.\backup\LLM_Sync_Win.ps1 -Action restore -WhatIf
```

**Linux backup preview only:**

```bash
./backup/LLM_Sync_Linux.sh backup --dry-run
```

**Linux shared skill sync:**

```bash
./backup/LLM_Sync_Linux.sh sync-skills
```

**Linux install or update repository skills:**

```bash
./backup/LLM_Sync_Linux.sh install-repo-skills --dry-run
./backup/LLM_Sync_Linux.sh install-repo-skills
```

**Linux backup with explicit machine name:**

```bash
./backup/LLM_Sync_Linux.sh backup --machine-name=JKWORK
```

**macOS restore preview only:**

```bash
./backup/LLM_Sync_Mac.sh restore --dry-run
```

**macOS shared skill sync:**

```bash
./backup/LLM_Sync_Mac.sh sync-skills
```

**macOS install or update repository skills:**

```bash
./backup/LLM_Sync_Mac.sh install-repo-skills --dry-run
./backup/LLM_Sync_Mac.sh install-repo-skills
```

**macOS backup with normalized machine name:**

```bash
./backup/LLM_Sync_Mac.sh backup
```

On macOS and Linux, the backup folder now defaults to the short host name without any domain suffix, so a host like `JKWORK.local` backs up under `JKWORK`. You can override that with `--machine-name=<name>`.

**Backup layout:**

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

## Prerequisites

- **PowerShell 5.1+** (Windows scripts)
- **FFmpeg** - Required for media conversion scripts
- **yt-dlp** - Required for `download.ps1`
- **scdl** - Required for SoundCloud downloads in `download.ps1`
- **NanaZip/7-Zip** - Required for `plex_backup.ps1`

## License

See [LICENSE](LICENSE) for details.

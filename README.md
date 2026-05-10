# Personal Scripts Collection

A collection of PowerShell and shell scripts for system automation, backup, and media management.

## Documentation

| File | Description |
|------|-------------|
| [`README.md`](README.md) | This file; documents all scripts and configuration |
| [`AGENTS.md`](AGENTS.md) | Instructions for AI coding assistants working with this repo |
| [`backup/README.md`](backup/README.md) | Detailed backup and sync workflow documentation |
| [`LLM_Instructions.md`](LLM_Instructions.md) | Personal LLM preferences for use across AI services |

## Scripts

### Backup & Sync

Antigravity Sync scripts provide a unified way to manage your IDE configuration across Windows, macOS, and Linux.

**Key Features:**

- **Cross-Platform Parity**: Identical feature set across all supported operating systems.
- **Versioned Backups**: Use the `-v` (Mac/Linux) or `-Versioned` (Windows) flag to create timestamped snapshots instead of overwriting the default local backup.
- **Automated Pruning**: Automatically offers to delete versioned backups older than 30 days to save space.
- **Safety First**:
  - **Pre-restore Backups**: Every restore operation automatically creates a "safety" backup of your current local state before applying changes.
  - **Settings Diff Preview**: Displays differences between your local `settings.json` and the backup, allowing you to preview changes before they are applied.
- **Lean Sync (Whitelisting)**: Instead of excluding junk, the scripts use a strict whitelist for the `.gemini` directory. Only essential configuration (settings, MCP configs, user profiles) is synced, avoiding bloat from machine-specific AI indices (150MB+).
- **Extension Reconciliation**: Compares locally installed extensions with the backup and warns you if you have local extensions that aren't backed up.
- **Git Integration**: Optional prompt to pull latest changes from Git before sync and push updates after backup.

LLM Sync scripts provide a separate cross-platform backup and restore flow for assistant home directories and an optional shared `~/.skills` folder.

**Key Features:**

- **Per-Assistant Subdirectories**: Each machine backup stores `codex/`, `gemini/`, `claude/`, `agents/`, and optional `shared-skills/` separately for safer restores.
- **Conservative Whitelisting**: Sync only portable config, prompts, rules, memories, and skills. Skip auth/session files, caches, logs, local databases, and project-local conversation state.
- **Safety Restore Flow**: Restore creates a pre-restore snapshot outside Git and can preview diffs for key text config files before overwrite.
- **Scoped Git Integration**: Optional pull before sync and push after backup, staging only the selected backup subtree instead of unrelated repo changes.
- **Dry Run Support**: Preview file operations and Git mutations before changing anything.

| Script | Description |
|--------|-------------|
| [`Antigravity_Sync_Win.ps1`](backup/Antigravity_Sync_Win.ps1) | Primary sync tool for Windows. Supports WSL environments and integrated Git sync. |
| [`Antigravity_Sync_Mac.sh`](backup/Antigravity_Sync_Mac.sh) | macOS implementation with feature parity and Git sync. |
| [`Antigravity_Sync_Linux.sh`](backup/Antigravity_Sync_Linux.sh) | Linux implementation with feature parity and Git sync. |
| [`LLM_Sync_Win.ps1`](backup/LLM_Sync_Win.ps1) | Windows backup and restore for portable Codex, Gemini, Claude, Agents, and shared `.skills` settings. Gemini restore skips volatile Antigravity state. |
| [`LLM_Sync_Mac.sh`](backup/LLM_Sync_Mac.sh) | macOS backup and restore for portable Codex, Gemini, Claude, Agents, and shared `.skills` settings. Gemini restore skips volatile Antigravity state. |
| [`LLM_Sync_Linux.sh`](backup/LLM_Sync_Linux.sh) | Linux backup and restore for portable Codex, Gemini, Claude, Agents, and shared `.skills` settings. Gemini restore skips volatile Antigravity state. |
| [`plex_backup.ps1`](backup/plex_backup.ps1) | Backup Plex Media Server data and registry settings to a compressed 7z archive. Handles service stop/start automatically. |

### System Maintenance

The `system/` directory is organized by platform: `macos/`, `windows/`, and `linux/`.

#### macOS (`system/macos/`)

| Script | Description |
|--------|-------------|
| [`audit_apps.sh`](system/macos/audit_apps.sh) | Audits installed GUI applications and identifies their source (Homebrew, App Store, or Manual). |
| [`sync_apps.sh`](system/macos/sync_apps.sh) | Compares an audit file with local state and installs missing managed apps. |
| [`Update-AllPackages_Mac.sh`](system/macos/Update-AllPackages_Mac.sh) | Weekly package updater (brew, mas, npm, pip, rustup). |
| [`Setup-PackageUpdateTasks_Mac.sh`](system/macos/Setup-PackageUpdateTasks_Mac.sh) | Installs/removes the macOS weekly launchd job for updates. |

#### Windows (`system/windows/`)

| Script | Description |
|--------|-------------|
| [`Update-AllPackages_Win.ps1`](system/windows/Update-AllPackages_Win.ps1) | Weekly update script for winget, Windows Store, Chocolatey, npm, WSL apt, and pip packages. |
| [`Setup-PackageUpdateTasks.ps1`](system/windows/Setup-PackageUpdateTasks.ps1) | Sets up a Windows Task Scheduler task for weekly updates. |
| [`list_apps.ps1`](system/windows/list_apps.ps1) | Lists installed applications from multiple sources (Registry, Store, Winget, etc.). |
| [`Update-CloudflareDNS.ps1`](system/windows/Update-CloudflareDNS.ps1) | Dynamic DNS updater for Cloudflare. |
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

### Media Processing

| Script | Description |
|--------|-------------|
| [`Convert-Mp4ToIg.ps1`](media/Convert-Mp4ToIg.ps1) | Batch converts MP4 files for Instagram (1080x1350 portrait format) using FFmpeg. |
| [`instagram.ps1`](media/instagram.ps1) | Re-encodes videos for Instagram in a directory using FFmpeg. |
| [`download.ps1`](media/download.ps1) | Downloads media from YouTube or SoundCloud using yt-dlp and scdl. |

## Configuration

Scripts that require personal configuration now use external JSON config files stored in your **Private repository** (`C:\Users\jkowa\Private\Configs`). These config files are **not tracked in Git** here to protect sensitive data.

### Required Config Files (In Private Repo)

| Config File | Required By | Keys |
|-------------|-------------|------|
| `Update-CloudflareDNS.json` | `Update-CloudflareDNS.ps1` | `ApiToken`, `ZoneId`, `DnsRecordName`, `TtlValue` |
| `Antigravity_Sync_Win.json` | `Antigravity_Sync_Win.ps1` | `BaseBackupPath`, `PreRestorePath` (optional) |
| `Antigravity_Sync_Mac.json` | `Antigravity_Sync_Mac.sh` | `DefaultBackupPath`, `PreRestorePath` (optional) |
| `Antigravity_Sync_Linux.json` | `Antigravity_Sync_Linux.sh` | `DefaultBackupPath`, `PreRestorePath` (optional) |
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

**Windows restore preview using PowerShell WhatIf:**

```powershell
.\backup\LLM_Sync_Win.ps1 -Action restore -WhatIf
```

**Linux backup preview only:**

```bash
./backup/LLM_Sync_Linux.sh backup --dry-run
```

**Linux backup with explicit machine name:**

```bash
./backup/LLM_Sync_Linux.sh backup --machine-name=JKWORK
```

**macOS restore preview only:**

```bash
./backup/LLM_Sync_Mac.sh restore --dry-run
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
```

## Prerequisites

- **PowerShell 5.1+** (Windows scripts)
- **Antigravity CLI** - Required for sync scripts
- **FFmpeg** - Required for media conversion scripts
- **yt-dlp** - Required for `download.ps1`
- **scdl** - Required for SoundCloud downloads in `download.ps1`
- **NanaZip/7-Zip** - Required for `plex_backup.ps1`

## License

See [LICENSE](LICENSE) for details.

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

### Backup

| Script | Description |
|--------|-------------|
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
output, and stopping conditions. See the [skill catalog](skills/README.md) for
installation instructions.

### System Maintenance

The `system/` directory is organized by platform: `macos/`, `windows/`, and `linux/`.

#### macOS (`system/macos/`)

| Script | Description |
|--------|-------------|
| [`audit_apps.sh`](system/macos/audit_apps.sh) | Audits installed GUI applications and identifies their source (Homebrew, App Store, or Manual). |
| [`sync_apps.sh`](system/macos/sync_apps.sh) | Compares an audit file with local state and installs missing managed apps. |
| [`Update-AllPackages_Mac.sh`](system/macos/Update-AllPackages_Mac.sh) | Weekly updater for Homebrew, Mac App Store (`mas`), Claude Code, MacUpdater, generic npm packages, pipx apps when installed, and rustup. It tracks Codex alpha under `~/.local`, updates Anthropic's native Claude Code installation on its configured channel, and reports how Claude Desktop is updated. |
| [`Setup-PackageUpdateTasks_Mac.sh`](system/macos/Setup-PackageUpdateTasks_Mac.sh) | Installs/removes the macOS weekly launchd job for updates. |
| [`test-package-update-scripts.sh`](system/macos/tests/test-package-update-scripts.sh) | Offline regression tests for updater status, Claude Code handling, host-scoped log retention, and launchd rendering. |

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

For the freshest Claude Code releases on macOS, migrate once to Anthropic's native `latest` installation with `claude install latest`. The scheduled updater then runs `~/.local/bin/claude update` and verifies the resulting version. Claude Desktop remains separate and uses its built-in auto-updater unless installed as the Homebrew `claude` cask.

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

Backup actions use external JSON config files stored in your **Private repository** (`C:\Users\jkowa\Private\Configs`). These config files are **not tracked in Git** here to protect sensitive data.

### Required Config Files (In Private Repo)

| Config File | Required By | Keys |
|-------------|-------------|------|
| `Update-CloudflareDNS.json` | `Update-CloudflareDNS.ps1` | `ApiToken`, `ZoneId`, `DnsRecordName`, `TtlValue` |
| `plex_backup.json` | `plex_backup.ps1` | `PlexDataPath`, `BackupDestination`, `TempWorkingPath`, `7ZipPath` |

### Example Config Templates

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

## Prerequisites

- **PowerShell 5.1+** (Windows scripts)
- **FFmpeg** - Required for media conversion scripts
- **yt-dlp** - Required for `download.ps1`
- **scdl** - Required for SoundCloud downloads in `download.ps1`
- **NanaZip/7-Zip** - Required for `plex_backup.ps1`

## License

See [LICENSE](LICENSE) for details.

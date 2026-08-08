# System Scripts

This directory contains system automation and maintenance scripts, organized by platform.

## Directory Structure

- **`macos/`**: macOS-specific shell scripts.
- **`windows/`**: Windows-specific PowerShell scripts.
- **`linux/`**: Linux-specific shell scripts.

## macOS Scripts (`system/macos/`)

| Script | Description |
|--------|-------------|
| `audit_apps.sh` | Audits installed GUI applications and identifies their source (Brew, MAS, or Manual). |
| `sync_apps.sh` | Compares an audit file with local state and installs missing managed apps. |
| `Update-AllPackages_Mac.sh` | Weekly updater for Homebrew, Mac App Store (`mas`), MacUpdater, generic npm packages, pipx apps when installed, and rustup. It skips bulk pip updates and tracks Codex alpha and Claude next independently under `~/.local`. |
| `Setup-PackageUpdateTasks_Mac.sh` | Installs/removes the macOS weekly launchd job for updates. |
| `tests/test-package-update-scripts.sh` | Dependency-free offline regression tests for updater status, host-scoped log retention, and launchd rendering. |

## Windows Scripts (`system/windows/`)

| Script | Description |
|--------|-------------|
| `Update-AllPackages_Win.ps1` | Weekly updater for winget, Windows Store, Chocolatey, generic npm packages, WSL apt, and pip. It tracks Codex alpha and Claude next, updating each independently from the generic npm batch. |
| `Update-AllPackages_Win.Core.ps1` | Side-effect-free parser, status, and atomic last-run record helpers used by the updater and tests. |
| `Setup-PackageUpdateTasks.ps1` | Sets up a Windows Task Scheduler task for weekly updates and keeps the scheduled run window visible after completion. |
| `tests/Test-Update-AllPackages_Win.ps1` | Dependency-free offline regression tests for WinGet parsing, status records, and task rendering. |
| `list_apps.ps1` | Lists installed apps from Registry, Store, Winget, Choco, Scoop, and npm. |
| `Update-CloudflareDNS.ps1` | Dynamic DNS updater for Cloudflare. |
| `clean_plex.ps1` | Cleanup utility for Plex Media Server data. |
| `restart_camera_hub.ps1` | Restarts Elgato Camera Hub application. |
| `Toggle-PrompterDisplayAndRestartCameraHub.ps1` | Toggles the Elgato Prompter display and restarts Camera Hub after power-off. |

The Windows updater atomically writes `logs/Update-AllPackages_Win_<machine>_last-run.json` after updates finish and before any configured keep-open delay. Run `Setup-PackageUpdateTasks.ps1 -RenderOnly` to inspect the scheduled-task definition as JSON without elevation or Task Scheduler changes.

## Linux Scripts (`system/linux/`)

| Script | Description |
|--------|-------------|
| `Update-AllPackages_Linux.sh` | Weekly updater for apt, snap, flatpak, npm, pip, and rustup. |
| `Setup-PackageUpdateTasks_Linux.sh` | Installs/removes the Linux weekly cron schedule. |

## Offline Package Updater Tests

These tests do not invoke package managers or modify live scheduler state.

```bash
/bin/bash system/macos/tests/test-package-update-scripts.sh
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\system\windows\tests\Test-Update-AllPackages_Win.ps1
```

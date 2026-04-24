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
| `Update-AllPackages_Mac.sh` | Weekly updater for brew, mas, npm, pip, and rustup. |
| `Setup-PackageUpdateTasks_Mac.sh` | Installs/removes the macOS weekly launchd job for updates. |

## Windows Scripts (`system/windows/`)

| Script | Description |
|--------|-------------|
| `Update-AllPackages_Win.ps1` | Weekly updater for winget, Windows Store, Chocolatey, npm, WSL apt, and pip. |
| `Setup-PackageUpdateTasks.ps1` | Sets up a Windows Task Scheduler task for weekly updates. |
| `list_apps.ps1` | Lists installed apps from Registry, Store, Winget, Choco, Scoop, and npm. |
| `Update-CloudflareDNS.ps1` | Dynamic DNS updater for Cloudflare. |
| `clean_plex.ps1` | Cleanup utility for Plex Media Server data. |
| `restart_camera_hub.ps1` | Restarts Elgato Camera Hub application. |

## Linux Scripts (`system/linux/`)

| Script | Description |
|--------|-------------|
| `Update-AllPackages_Linux.sh` | Weekly updater for apt, snap, flatpak, npm, pip, and rustup. |
| `Setup-PackageUpdateTasks_Linux.sh` | Installs/removes the Linux weekly cron schedule. |

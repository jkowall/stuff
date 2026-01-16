# Personal Scripts Collection

A collection of PowerShell and shell scripts for system automation, backup, and media management.

## Scripts

### Backup & Sync

| Script | Description |
|--------|-------------|
| [`Antigravity_Sync_Win.ps1`](Antigravity_Sync_Win.ps1) | Backup and restore Antigravity IDE settings, extensions, and global AI rules on Windows. Supports WSL environments. |
| [`Antigravity_Sync_Mac.sh`](Antigravity_Sync_Mac.sh) | Backup and restore Antigravity IDE settings on macOS. |
| [`plex_backup.ps1`](plex_backup.ps1) | Backup Plex Media Server data and registry settings to a compressed 7z archive. Handles service stop/start automatically. |

### System Maintenance

| Script | Description |
|--------|-------------|
| [`Update-AllPackages.ps1`](Update-AllPackages.ps1) | Weekly update script for winget, Chocolatey, and npm packages. Logs output and shows toast notifications. |
| [`Setup-PackageUpdateTasks.ps1`](Setup-PackageUpdateTasks.ps1) | Sets up a Windows Task Scheduler task to run `Update-AllPackages.ps1` weekly (Saturdays at 1 PM). |
| [`Update-CloudflareDNS.ps1`](Update-CloudflareDNS.ps1) | Dynamic DNS updater for Cloudflare. Updates a DNS record with your current public IP address. |
| [`clean_plex.ps1`](clean_plex.ps1) | Cleans up orphaned data, caches, logs, and temporary files in Plex Media Server. Triggers Plex's internal cleanup tasks via API. |
| [`list_apps.ps1`](list_apps.ps1) | Lists installed applications from multiple sources: Registry, Microsoft Store, Winget, Chocolatey, Scoop, and npm. |
| [`restart_camera_hub.ps1`](restart_camera_hub.ps1) | Restarts the Elgato Camera Hub application. |

### Media Processing

| Script | Description |
|--------|-------------|
| [`Convert mp4 to ig.ps1`](Convert%20mp4%20to%20ig.ps1) | Batch converts MP4 files for Instagram (1080x1350 portrait format) using FFmpeg. |
| [`instagram.ps1`](instagram.ps1) | Re-encodes videos for Instagram in a directory using FFmpeg. |
| [`download.ps1`](download.ps1) | Downloads media from YouTube or SoundCloud using yt-dlp and scdl. |

## Configuration

Scripts that require personal configuration use external JSON config files. These config files are **not tracked in Git** to protect sensitive data.

### Required Config Files

| Config File | Required By | Keys |
|-------------|-------------|------|
| `Update-CloudflareDNS.json` | `Update-CloudflareDNS.ps1` | `ApiToken`, `ZoneId`, `DnsRecordName`, `TtlValue` |
| `Antigravity_Sync_Win.json` | `Antigravity_Sync_Win.ps1` | `BaseBackupPath` |
| `Antigravity_Sync_Mac.json` | `Antigravity_Sync_Mac.sh` | `DefaultBackupPath` |
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

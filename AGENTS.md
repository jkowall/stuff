# AGENTS.md - AI Assistant Instructions

This file provides instructions for AI coding assistants working with this repository.

## Repository Overview

This is a personal scripts collection containing PowerShell (.ps1) and shell (.sh) scripts for:
- System backup and sync
- Package management automation
- Media file processing
- DNS management
- Application utilities

## Important Files

### Configuration Files (Git-Ignored)

The following JSON config files contain **personal/sensitive data** and are excluded from version control:

| File | Contains |
|------|----------|
| `Update-CloudflareDNS.json` | Cloudflare API token, Zone ID, domain name |
| `Antigravity_Sync_Win.json` | Personal backup directory path |
| `Antigravity_Sync_Mac.json` | Personal backup directory path |
| `plex_backup.json` | Local paths for Plex data, backups, and tools |

**Never hardcode personal data directly in scripts.** Always use the corresponding JSON config file.

### Key Scripts

- **`Update-AllPackages.ps1`** - Main package update script, creates timestamped `.log` files
- **`plex_backup.ps1`** - Requires admin privileges, stops Plex services during backup
- **`Update-CloudflareDNS.ps1`** - Makes external API calls to Cloudflare

## Coding Guidelines

### PowerShell Scripts

1. **Config Loading Pattern** - Scripts should load config at the start:
   ```powershell
   $ConfigPath = Join-Path $PSScriptRoot "ScriptName.json"
   if (-not (Test-Path $ConfigPath)) {
       Write-Error "Config file not found: $ConfigPath"
       exit 1
   }
   $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
   ```

2. **Logging** - Use `Write-Log` helper functions where available
3. **Error Handling** - Use try/catch blocks and proper exit codes

### Shell Scripts

1. **Config Loading** - Use Python to parse JSON:
   ```bash
   VALUE=$(python3 -c "import json; print(json.load(open('config.json'))['Key'])")
   ```

### When Modifying Scripts

1. Check if the script has a corresponding `.json` config file
2. Never commit personal paths, tokens, or credentials
3. Update README.md if adding new scripts or config requirements
4. Log files (`.log`) are auto-generated and git-ignored

## File Structure

```
.
├── .gitignore                    # Excludes .log and config files
├── README.md                     # User documentation
├── AGENTS.md                     # This file (AI instructions)
├── LICENSE                       # License file
│
├── # Backup Scripts
├── Antigravity_Sync_Win.ps1      # Windows Antigravity backup
├── Antigravity_Sync_Mac.sh       # macOS Antigravity backup
├── plex_backup.ps1               # Plex Media Server backup
│
├── # System Maintenance
├── Update-AllPackages.ps1        # Package updater
├── Setup-PackageUpdateTasks.ps1  # Task scheduler setup
├── Update-CloudflareDNS.ps1      # Dynamic DNS
├── clean_plex.ps1                # Plex cleanup
├── list_apps.ps1                 # List installed apps
├── restart_camera_hub.ps1        # Restart Elgato Camera Hub
│
├── # Media Processing
├── Convert mp4 to ig.ps1         # Instagram video converter
├── instagram.ps1                 # Instagram re-encoder
└── download.ps1                  # YouTube/SoundCloud downloader
```

## Testing Notes

- `plex_backup.ps1` requires Plex to be installed and admin rights
- `Update-CloudflareDNS.ps1` makes live API calls - test with caution
- Media scripts require FFmpeg, yt-dlp, and scdl installed

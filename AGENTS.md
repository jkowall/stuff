# AGENTS.md - AI Assistant Instructions

This file provides centralized instructions for all AI coding assistants working with this repository. Agent-specific files (`CLAUDE.md`, `GEMINI.md`) defer to this file.

## Repository Overview

This is a personal scripts collection containing PowerShell (.ps1), shell (.sh), and Python (.py) scripts organized into subdirectories:

- **`backup/`** - IDE configuration sync and Plex backup
- **`system/`** - Package management, DNS updates, system maintenance
- **`media/`** - Video conversion and media downloading
- **`finance_tools/`** - Portfolio sync and financial reporting

## Important Files

### Configuration Management

All sensitive JSON config files are now stored in a dedicated **Private repository** at `~/Private/Configs` (Unix) or `C:\Users\jkowa\Private\Configs` (Windows). 

| File | Contains |
|------|----------|
| `Update-CloudflareDNS.json` | Cloudflare API token, Zone ID, domain name |
| `Antigravity_Sync_Win.json` | Personal backup directory path |
| `Antigravity_Sync_Mac.json` | Personal backup directory path |
| `Antigravity_Sync_Linux.json` | Personal backup directory path |
| `plex_backup.json` | Local paths for Plex data, backups, and tools |

**Never hardcode personal data directly in scripts.** Always ensure scripts point to the centralized location in the `Private` repository.

### Documentation Files

| File | Purpose |
|------|--------|
| `README.md` | User-facing documentation for all scripts |
| `AGENTS.md` | Centralized AI assistant instructions (this file) |
| `CLAUDE.md` | Claude Code entry point; defers to AGENTS.md |
| `GEMINI.md` | Gemini entry point; defers to AGENTS.md |
| `LLM_Instructions.md` | Personal LLM preferences for use across AI services (git-ignored, contains personal data) |

### Key Scripts

- **`system/Update-AllPackages_Win.ps1`** - Windows package update script, creates timestamped `.log` files
- **`system/Update-AllPackages_Linux.sh`** - Linux (Ubuntu) package update script
- **`system/Update-AllPackages_Mac.sh`** - macOS package update script
- **`system/Setup-PackageUpdateTasks.ps1`** - Windows Task Scheduler setup and cleanup for package updates
- **`system/Setup-PackageUpdateTasks_Linux.sh`** - Linux cron setup and cleanup for package updates
- **`system/Setup-PackageUpdateTasks_Mac.sh`** - macOS launchd setup and cleanup for package updates
- **`system/Update-CloudflareDNS.ps1`** - Makes external API calls to Cloudflare
- **`backup/plex_backup.ps1`** - Requires admin privileges, stops Plex services during backup
- **`backup/Antigravity_Sync_*`** - Cross-platform sync suite (Win/Mac/Linux) with versioning, safety backups, and extension reconciliation
- **`finance_tools/schwab_sync.py`** - Portfolio sync with Seeking Alpha; supports email reports and history tracking

## Coding Guidelines

### Common Patterns across Sync Scripts

1. **Pre-restore Safety**: Always implement a "safety backup" of current local settings before performing a restoration. Store these in a non-Git tracked directory (default: `/tmp` or `D:\tmp`) and keep only the latest 2 versions.
2. **Whitelist Synch**: Use a whitelist approach for IDE configuration (especially `.gemini`). Only sync known configuration files (JSON, PB, TXT) and specific user folders (`knowledge`, `scratch`). Explicitly exclude transient/large data like browser profiles and machine-specific AI indices.
3. **Interactive Menus**: Use arrow-key navigable menus for action selection and backup choice.
3. **CLI Verification**: Check for the presence of required CLIs (like `antigravity`) before execution.
4. **Versioning & Pruning**: Support timestamped folder creation (e.g., `-v` flag) paired with a 30-day auto-pruning logic for maintenance.
5. **Diff Preview**: Offer users a logic-based comparison (diff) of settings files before overwriting local data.

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

### Python Scripts

1. **Config Loading** - Use `argparse` for CLI arguments and JSON for config files
2. **Dependencies** - Document required packages; use standard library where possible
3. **Error Handling** - Use try/except with meaningful error messages and proper exit codes
4. **Secrets** - Never hardcode API keys or credentials; load from config files or environment variables

### When Modifying Scripts

1. Check if the script has a corresponding `.json` config file
2. Never commit personal paths, tokens, or credentials
3. Update README.md if adding new scripts or config requirements
4. Update AGENTS.md file structure if adding new files
5. Log files (`.log`) are auto-generated and git-ignored

## Git Practices

### Commit Signing

**All commits must be signed.** Use GPG or SSH signing:

```bash
git commit -S -m "commit message"
```

Or configure automatic signing:
```bash
git config commit.gpgsign true
```

## File Structure

```
.
├── .gitignore                        # Excludes .log and config files
├── README.md                         # User documentation
├── AGENTS.md                         # Centralized AI instructions (this file)
├── CLAUDE.md                         # Claude Code entry point
├── GEMINI.md                         # Gemini entry point
├── LLM_Instructions.md               # Personal LLM preferences (git-ignored)
├── LICENSE                            # License file
│
├── backup/                            # Backup & Sync
│   ├── Antigravity_Sync_Win.ps1       # Windows Antigravity sync (Git-integrated)
│   ├── Antigravity_Sync_Mac.sh        # macOS Antigravity sync (Git-integrated)
│   ├── Antigravity_Sync_Linux.sh      # Linux Antigravity sync (Git-integrated)
│   └── plex_backup.ps1               # Plex Media Server backup
│
├── system/                            # System Maintenance
│   ├── Update-AllPackages_Win.ps1     # Windows package updater
│   ├── Update-AllPackages_Linux.sh    # Linux package updater
│   ├── Update-AllPackages_Mac.sh      # macOS package updater
│   ├── Setup-PackageUpdateTasks.ps1   # Windows Task Scheduler setup
│   ├── Setup-PackageUpdateTasks_Linux.sh # Linux cron setup
│   ├── Setup-PackageUpdateTasks_Mac.sh # macOS launchd setup
│   ├── Update-CloudflareDNS.ps1       # Dynamic DNS
│   ├── clean_plex.ps1                # Plex cleanup
│   ├── list_apps.ps1                 # List installed apps
│   └── restart_camera_hub.ps1        # Restart Elgato Camera Hub
│
├── media/                             # Media Processing
│   ├── Convert-Mp4ToIg.ps1           # Instagram video converter
│   ├── instagram.ps1                 # Instagram re-encoder
│   └── download.ps1                  # YouTube/SoundCloud downloader
│
└── finance_tools/                     # Finance
    └── schwab_sync.py                # Schwab portfolio sync with Seeking Alpha
```

## Testing Notes

- `backup/plex_backup.ps1` requires Plex to be installed and admin rights
- `system/Update-CloudflareDNS.ps1` makes live API calls; test with caution
- Media scripts require FFmpeg, yt-dlp, and scdl installed
- `finance_tools/schwab_sync.py` calls Seeking Alpha API and can send emails; test with `--dry-run` or limited scope

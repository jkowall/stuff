# AGENTS.md - AI Assistant Instructions

This file provides centralized instructions for all AI coding assistants working with this repository. Agent-specific files (`CLAUDE.md`, `GEMINI.md`) defer to this file.

## Repository Overview

This is a personal scripts collection containing PowerShell (.ps1), shell (.sh), and Python (.py) scripts organized into subdirectories:

- **`backup/`** - IDE configuration sync and Plex backup
- **`system/`** - Package management, DNS updates, system maintenance
- **`media/`** - Video conversion and media downloading

## Important Files

### Configuration Management

All sensitive JSON config files are now stored in a dedicated **Private repository** at `~/Private/Configs` (Unix) or `C:\Users\jkowa\Private\Configs` (Windows). 

| File | Contains |
|------|----------|
| `Update-CloudflareDNS.json` | Cloudflare API token, Zone ID, domain name |
| `Antigravity_Sync_Win.json` | Personal backup directory path |
| `Antigravity_Sync_Mac.json` | Personal backup directory path |
| `Antigravity_Sync_Linux.json` | Personal backup directory path |
| `LLM_Sync_Win.json` | Personal backup directory path |
| `LLM_Sync_Mac.json` | Personal backup directory path |
| `LLM_Sync_Linux.json` | Personal backup directory path |
| `plex_backup.json` | Local paths for Plex data, backups, and tools |

**Never hardcode personal data directly in scripts.** Always ensure scripts point to the centralized location in the `Private` repository.

### Documentation Files

| File | Purpose |
|------|--------|
| `README.md` | User-facing documentation for all scripts |
| `AGENTS.md` | Centralized AI assistant instructions (this file) |
| `CLAUDE.md` | Claude Code entry point; defers to AGENTS.md |
| `GEMINI.md` | Gemini entry point; defers to AGENTS.md |
| `LLM_Instructions.md` | Personal LLM preferences for use across AI services |

### Key Scripts

- **`system/windows/Update-AllPackages_Win.ps1`** - Windows package update script, creates timestamped `.log` files
- **`system/linux/Update-AllPackages_Linux.sh`** - Linux (Ubuntu) package update script
- **`system/macos/Update-AllPackages_Mac.sh`** - macOS package update script
- **`system/windows/Setup-PackageUpdateTasks.ps1`** - Windows Task Scheduler setup and cleanup for package updates
- **`system/linux/Setup-PackageUpdateTasks_Linux.sh`** - Linux cron setup and cleanup for package updates
- **`system/macos/Setup-PackageUpdateTasks_Mac.sh`** - macOS launchd setup and cleanup for package updates
- **`system/windows/Update-CloudflareDNS.ps1`** - Makes external API calls to Cloudflare
- **`system/macos/audit_apps.sh`** - Audits installed Mac GUI apps
- **`system/macos/sync_apps.sh`** - Syncs Mac apps between machines
- **`backup/plex_backup.ps1`** - Requires admin privileges, stops Plex services during backup
- **`backup/Antigravity_Sync_*`** - Cross-platform sync suite (Win/Mac/Linux) with versioning, safety backups, and extension reconciliation
- **`backup/LLM_Sync_*`** - Cross-platform sync suite (Win/Mac/Linux) for portable Codex, Gemini, Claude, Agents, and shared `.skills` settings

## Coding Guidelines

### Common Patterns across Sync Scripts

1. **Pre-restore Safety**: Always implement a "safety backup" of current local settings before performing a restoration. Store these in a non-Git tracked directory (default: `/tmp" or "D:\tmp`) and keep only the latest 2 versions.
2. **Whitelist Synch**: Use a whitelist approach for IDE configuration (especially `.gemini`). Only sync known configuration files (JSON, PB, TXT) and specific user folders (`knowledge`, `scratch`). Explicitly exclude transient/large data like browser profiles and machine-specific AI indices.
3. **Interactive Menus**: Use arrow-key navigable menus for action selection and backup choice.
4. **CLI Verification**: Check for the presence of required CLIs (like `antigravity`, `mas`) before execution.
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
├── LLM_Instructions.md               # Personal LLM preferences
├── LICENSE                            # License file
│
├── backup/                            # Backup & Sync
│   ├── Antigravity_Sync_Win.ps1       # Windows Antigravity sync (Git-integrated)
│   ├── Antigravity_Sync_Mac.sh        # macOS Antigravity sync (Git-integrated)
│   ├── Antigravity_Sync_Linux.sh      # Linux Antigravity sync (Git-integrated)
│   ├── LLM_Sync_Win.ps1               # Windows Codex/Gemini/Claude/Agents/shared-skills sync
│   ├── LLM_Sync_Mac.sh                # macOS Codex/Gemini/Claude/Agents/shared-skills sync
│   ├── LLM_Sync_Linux.sh              # Linux Codex/Gemini/Claude/Agents/shared-skills sync
│   └── plex_backup.ps1               # Plex Media Server backup
│
├── system/                            # System Maintenance
│   ├── README.md                      # Overview of system scripts
│   ├── macos/                         # macOS scripts
│   │   ├── audit_apps.sh              # List GUI apps and sources
│   │   ├── sync_apps.sh               # Install missing apps from audit
│   │   ├── Update-AllPackages_Mac.sh  # macOS package updater
│   │   └── Setup-PackageUpdateTasks_Mac.sh # macOS launchd setup
│   ├── windows/                       # Windows scripts
│   │   ├── Update-AllPackages_Win.ps1 # Windows package updater
│   │   ├── Setup-PackageUpdateTasks.ps1 # Windows Task Scheduler setup
│   │   ├── Update-CloudflareDNS.ps1    # Dynamic DNS
│   │   ├── clean_plex.ps1             # Plex cleanup
│   │   ├── list_apps.ps1              # List installed apps
│   │   └── restart_camera_hub.ps1     # Restart Elgato Camera Hub
│   └── linux/                         # Linux scripts
│       ├── Update-AllPackages_Linux.sh # Linux package updater
│       └── Setup-PackageUpdateTasks_Linux.sh # Linux cron setup
│
├── media/                             # Media Processing
│   ├── Convert-Mp4ToIg.ps1           # Instagram video converter
│   ├── instagram.ps1                 # Instagram re-encoder
│   └── download.ps1                  # YouTube/SoundCloud downloader
```

## Testing Notes

- `backup/plex_backup.ps1` requires Plex to be installed and admin rights
- `system/Update-CloudflareDNS.ps1` makes live API calls; test with caution
- Media scripts require FFmpeg, yt-dlp, and scdl installed

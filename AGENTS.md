# AGENTS.md - AI Assistant Instructions

This file provides centralized instructions for all AI coding assistants working with this repository. Agent-specific files (`CLAUDE.md`, `GEMINI.md`) defer to this file.

## Repository Overview

This is a personal scripts collection containing PowerShell (.ps1), shell (.sh), and Python (.py) scripts organized into subdirectories:

- **`backup/`** - LLM configuration sync and Plex backup
- **`system/`** - Package management, DNS updates, system maintenance
- **`media/`** - Video conversion and media downloading

## Karpathy-Inspired Coding Protocol

Incorporate the behavioral guidance from [multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills) when writing, reviewing, or refactoring code. These rules are meant to reduce hidden assumptions, overengineering, unrelated edits, and unverifiable outcomes.

1. **Think Before Coding**: Do not silently pick an interpretation when requirements are ambiguous. State material assumptions, surface tradeoffs, push back when a simpler or safer approach exists, and ask before proceeding when uncertainty creates real implementation risk.
2. **Simplicity First**: Implement the minimum coherent solution that satisfies the request. Do not add speculative features, one-off abstractions, unnecessary configurability, or defensive code for impossible scenarios. If a smaller approach would solve the same problem clearly, use it.
3. **Surgical Changes**: Touch only files and lines that directly support the request. Match the existing style, avoid drive-by refactors, and do not rewrite adjacent comments or formatting. Clean up unused code only when your change created it; mention unrelated dead code instead of removing it.
4. **Goal-Driven Execution**: Convert non-trivial tasks into verifiable success criteria. For bugs, reproduce or isolate the failure before fixing when practical. For behavior changes, identify the smallest meaningful test or command that proves the result, then loop until it passes or report the blocker.

## Important Files

### Configuration Management

All sensitive JSON config files are now stored in a dedicated **Private repository** at `~/Private/Configs` (Unix) or `C:\Users\jkowa\Private\Configs` (Windows). 

| File | Contains |
|------|----------|
| `Update-CloudflareDNS.json` | Cloudflare API token, Zone ID, domain name |
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
- **`system/windows/Toggle-PrompterDisplayAndRestartCameraHub.ps1`** - Toggles the Elgato Prompter display and restarts Camera Hub after power-off
- **`system/macos/audit_apps.sh`** - Audits installed Mac GUI apps
- **`system/macos/sync_apps.sh`** - Syncs Mac apps between machines
- **`backup/plex_backup.ps1`** - Requires admin privileges, stops Plex services during backup
- **`backup/LLM_Sync_*`** - Cross-platform sync suite (Win/Mac/Linux) for portable Codex, Gemini, Claude, Agents, and shared `.skills` settings

## Coding Guidelines

### Common Patterns across Sync Scripts

1. **Pre-restore Safety**: Always implement a "safety backup" of current local settings before performing a restoration. Store these in a non-Git tracked directory (default: `/tmp" or "D:\tmp`) and keep only the latest 2 versions.
2. **Whitelist Synch**: Use a whitelist approach for assistant configuration (especially `.gemini`). Only sync known configuration files (JSON, PB, TXT) and specific user folders (`knowledge`, `scratch`). Explicitly exclude transient/large data like browser profiles and machine-specific AI indices.
3. **Interactive Menus**: Use arrow-key navigable menus for action selection and backup choice.
4. **CLI Verification**: Check for the presence of required CLIs before execution.
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
│   │   ├── restart_camera_hub.ps1     # Restart Elgato Camera Hub
│   │   └── Toggle-PrompterDisplayAndRestartCameraHub.ps1 # Toggle Prompter and restart Camera Hub
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

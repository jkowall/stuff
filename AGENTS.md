# AGENTS.md - AI Assistant Instructions

This file provides centralized instructions for all AI coding assistants working with this repository. Agent-specific files (`CLAUDE.md`, `GEMINI.md`) defer to this file.

## Repository Overview

This is a personal scripts collection containing PowerShell (.ps1), shell (.sh), and Python (.py) scripts organized into subdirectories:

- **`backup/`** - LLM configuration sync and Plex backup
- **`skills/`** - Public, portable procedural skills installed through the LLM sync scripts
- **`system/`** - Package management, DNS updates, system maintenance
- **`media/`** - Video conversion and media downloading

## Public Repository Boundary

This repository is public. Professional identity, working preferences, public paths, documentation, and redacted examples are allowed when they support the scripts or documentation.

Keep credentials, private communications, customer data, and sensitive personal details out of this repository. Store that material in the dedicated Private repository and reference it from scripts when needed.

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

**Never hardcode credentials or sensitive personal data directly in scripts.** Always ensure scripts point to the centralized location in the `Private` repository.

### Documentation Files

| File | Purpose |
|------|--------|
| `README.md` | User-facing documentation for all scripts |
| `AGENTS.md` | Centralized AI assistant instructions (this file) |
| `skills/README.md` | Workflow skill catalog and cross-platform installation |
| `CLAUDE.md` | Claude Code entry point; defers to AGENTS.md |
| `GEMINI.md` | Gemini entry point; defers to AGENTS.md |
| `LLM_Instructions.md` | Public-safe professional identity and working preferences for AI services |

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
- **`backup/LLM_Sync_*`** - Cross-platform sync suite (Win/Mac/Linux) for portable Codex, Gemini, Claude, Agents, shared `.skills` settings, and repository skill installation

### Workflow Skill Guidelines

- Each directory directly under `skills/` is one installable package and must contain a `SKILL.md` with YAML frontmatter whose `name` matches the directory and whose `description` is non-empty.
- Descriptions must say what the skill does and when it should trigger. Procedures must define stable inputs, evidence order, mutation boundaries, output, and stopping conditions.
- Skills in this public repository may name public projects and public paths, but must not contain customer data, private communications, credentials, internal identifiers, or confidential examples.
- Keep organization-specific live knowledge outside this repository. A skill may tell the agent where to look during an authorized session, but must not embed private source contents.
- When packages are added or renamed, update `skills/README.md`, the root `README.md`, and verify all three `install-repo-skills` actions.

## Coding Guidelines

### Common Patterns across Sync Scripts

1. **Pre-restore Safety**: Always implement a "safety backup" of current local settings before performing a restoration. Store these in a non-Git tracked directory (default: `/tmp" or "D:\tmp`) and keep only the latest 2 versions.
2. **Whitelist Synch**: Use a whitelist approach for assistant configuration (especially `.gemini`). Only sync known configuration files (JSON, PB, TXT) and specific user folders (`knowledge`, `scratch`). Explicitly exclude transient/large data like browser profiles and machine-specific AI indices.
3. **Interactive Menus**: Use arrow-key navigable menus for action selection and backup choice.
4. **CLI Verification**: Check for the presence of required CLIs before execution.
4. **Versioning & Pruning**: Support timestamped folder creation (e.g., `-v` flag) paired with a 30-day auto-pruning logic for maintenance.
5. **Diff Preview**: Offer users a logic-based comparison (diff) of settings files before overwriting local data.

### PowerShell Scripts

1. **Config Loading Pattern** - Config-dependent actions should load and validate config before use. Actions documented as configuration-free may branch before initialization:
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

1. **Config Loading** - Use Python to parse JSON for config-dependent actions. Configuration-free actions may run before this initialization:
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
2. Never commit tokens, credentials, customer data, private communications, or sensitive personal details. Public paths and non-sensitive professional context are allowed when they support the script or documentation.
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
├── LLM_Instructions.md               # Public-safe professional identity and working preferences
├── LICENSE                            # License file
│
├── backup/                            # Backup & Sync
│   ├── LLM_Sync_Win.ps1               # Windows Codex/Gemini/Claude/Agents/shared-skills sync
│   ├── LLM_Sync_Mac.sh                # macOS Codex/Gemini/Claude/Agents/shared-skills sync
│   ├── LLM_Sync_Linux.sh              # Linux Codex/Gemini/Claude/Agents/shared-skills sync
│   └── plex_backup.ps1               # Plex Media Server backup
│
├── skills/                            # Portable workflow skills
│   ├── README.md                      # Catalog and installation
│   └── <skill-name>/SKILL.md          # One procedural package per directory
│
├── system/                            # System Maintenance
│   ├── README.md                      # Overview of system scripts
│   ├── macos/                         # macOS scripts
│   │   ├── audit_apps.sh              # List GUI apps and sources
│   │   ├── sync_apps.sh               # Install missing apps from audit
│   │   ├── Update-AllPackages_Mac.sh  # macOS package updater
│   │   ├── Setup-PackageUpdateTasks_Mac.sh # macOS launchd setup
│   │   └── tests/test-package-update-scripts.sh # Offline macOS updater tests
│   ├── windows/                       # Windows scripts
│   │   ├── Update-AllPackages_Win.ps1 # Windows package updater
│   │   ├── Update-AllPackages_Win.Core.ps1 # Pure updater helpers
│   │   ├── Setup-PackageUpdateTasks.ps1 # Windows Task Scheduler setup
│   │   ├── tests/Test-Update-AllPackages_Win.ps1 # Offline Windows updater tests
│   │   ├── tests/fixtures/winget-cases.json # WinGet parser fixtures
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

- Run `/bin/bash system/macos/tests/test-package-update-scripts.sh` for offline macOS updater status, retention, and launchd-rendering coverage.
- Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\system\windows\tests\Test-Update-AllPackages_Win.ps1` for offline Windows parser, status-record, and scheduler-rendering coverage.
- `backup/plex_backup.ps1` requires Plex to be installed and admin rights
- `system/Update-CloudflareDNS.ps1` makes live API calls; test with caution
- Media scripts require FFmpeg, yt-dlp, and scdl installed

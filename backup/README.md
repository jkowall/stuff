# Backup Scripts

This directory contains the backup tooling for Plex data.

## Scripts

| Script | Purpose |
|--------|---------|
| `plex_backup.ps1` | Plex backup workflow that stops services and archives data |

## Config Files

Backup expects a config file in your private config repo:

- `C:\Users\<you>\Private\Configs\plex_backup.json`

`audit`-style dry runs are not applicable here; review the script directly before running it.

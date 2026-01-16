<#
.SYNOPSIS
    Cleans up orphaned data and temporary files in the Plex Media Server directory.
.DESCRIPTION
    Triggers Plex's internal cleanup tasks (Empty Trash, Clean Bundles, Optimize DB) via API,
    and manually deletes temporary caches and logs.
.NOTES
    Requires Plex Media Server to be running for API tasks.
    Safe to run periodically.
#>

param(
    [Parameter()]
    [switch]$WhatIf,
    
    [Parameter()]
    [string]$PlexUrl = "http://127.0.0.1:32400",
    
    [Parameter()]
    [int]$LogRetentionDays = 7
)

$ErrorActionPreference = 'Stop'

# --- Configuration & Discovery ---

function Get-PlexToken {
    $Token = Get-ItemProperty -Path "HKCU:\Software\Plex, Inc.\Plex Media Server" -Name "PlexOnlineToken" -ErrorAction SilentlyContinue
    if ($Token) { return $Token.PlexOnlineToken }
    return $null
}

function Get-PlexDataPath {
    # Check common locations or registry
    $RegPath = Get-ItemProperty -Path "HKLM\SOFTWARE\Plex, Inc.\Plex Media Server" -Name "LocalAppDataPath" -ErrorAction SilentlyContinue
    if ($RegPath -and (Test-Path $RegPath.LocalAppDataPath)) {
        return Join-Path $RegPath.LocalAppDataPath "Plex Media Server"
    }
    
    # Default location if not in registry (D:\Plex was seen in backup script)
    $KnownPaths = @(
        "D:\Plex\Plex Media Server",
        "$env:LOCALAPPDATA\Plex Media Server"
    )
    
    foreach ($Path in $KnownPaths) {
        if (Test-Path $Path) { return $Path }
    }
    
    return $null
}

$PlexToken = Get-PlexToken
$PlexDataPath = Get-PlexDataPath

if (!$PlexToken) {
    Write-Warning "Plex Online Token not found in registry. API tasks will likely fail."
}

if (!$PlexDataPath) {
    Write-Error "Plex Data Path could not be detected. Please specify or ensure Plex is installed."
    exit 1
}

Write-Host "Plex Data Path: $PlexDataPath" -ForegroundColor Cyan

# --- Helper Functions ---

function Invoke-PlexApi {
    param([string]$Endpoint, [string]$Method = "PUT")
    
    $Url = "$PlexUrl$Endpoint"
    if ($Url -match "\?") { $Url += "&X-Plex-Token=$PlexToken" }
    else { $Url += "?X-Plex-Token=$PlexToken" }
    
    if ($WhatIf) {
        Write-Host "[What-If] Would call Plex API: $Method $Url" -ForegroundColor Gray
        return
    }
    
    try {
        Invoke-RestMethod -Uri $Url -Method $Method -ErrorAction Stop
        Write-Host "Success: $Endpoint" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to call $Endpoint : $($_.Exception.Message)"
    }
}

function Remove-OrphanedFiles {
    param(
        [string]$Path,
        [string]$Filter = "*",
        [int]$OlderThanDays = 0,
        [switch]$Recurse
    )
    
    if (!(Test-Path $Path)) { return }
    
    $Files = Get-ChildItem -Path $Path -Filter $Filter -File -Recurse:$Recurse | Where-Object {
        if ($OlderThanDays -gt 0) {
            $_.LastWriteTime -lt (Get-Date).AddDays(-$OlderThanDays)
        }
        else {
            $true
        }
    }
    
    foreach ($File in $Files) {
        if ($WhatIf) {
            Write-Host "[What-If] Would delete: $($File.FullName)" -ForegroundColor Gray
        }
        else {
            Write-Host "Deleting: $($File.FullName)" -ForegroundColor DarkGray
            Remove-Item $File.FullName -Force
        }
    }
}

# --- Execution ---

Write-Host "`n--- Triggering Plex Internal Cleanups ---" -ForegroundColor Yellow

# 1. Empty Trash
Write-Host "Emptying Trash..."
# Try global endpoint first
Invoke-PlexApi "/library/sections/all/emptyTrash"

# Also try section by section just in case
try {
    $Sections = Invoke-RestMethod -Uri "$PlexUrl/library/sections?X-Plex-Token=$PlexToken" -Method GET -ErrorAction SilentlyContinue
    foreach ($Section in $Sections.MediaContainer.Directory) {
        $Key = $Section.key
        $Title = $Section.title
        Write-Host "Emptying Trash for section $Key ($Title)..."
        Invoke-PlexApi "/library/sections/$Key/emptyTrash"
    }
}
catch {
    Write-Warning "Failed to fetch library sections for granular Empty Trash."
}

# 2. Clean Bundles
Write-Host "Cleaning Bundles..."
Invoke-PlexApi "/library/clean/bundles"

# 3. Optimize Database
Write-Host "Optimizing Database..."
Invoke-PlexApi "/library/optimize"

Write-Host "`n--- Cleaning File System ---" -ForegroundColor Yellow

# 4. Photo Transcoder Cache (SAFE TO DELETE - regenerates on browsing)
# These are thumbnails, posters, etc cached for specific devices.
$PhotoCachePath = Join-Path $PlexDataPath "Cache\PhotoTranscoder"
if (Test-Path $PhotoCachePath) {
    $SizeBefore = (Get-ChildItem $PhotoCachePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
    Write-Host "Cleaning Photo Transcoder Cache ($([math]::Round($SizeBefore, 2)) MB)..."
    Remove-OrphanedFiles -Path $PhotoCachePath -Recurse
}

# 5. Transcode Sessions (Old ones only)
$TranscodeSessionsPath = Join-Path $PlexDataPath "Cache\Transcode\Sessions"
Write-Host "Cleaning old transcode sessions..."
Remove-OrphanedFiles -Path $TranscodeSessionsPath -OlderThanDays 1 -Recurse

# 6. Logs
$LogsPath = Join-Path $PlexDataPath "Logs"
Write-Host "Cleaning logs older than $LogRetentionDays days..."
Remove-OrphanedFiles -Path $LogsPath -Filter "*.log*" -OlderThanDays $LogRetentionDays

# 7. Crash Reports
$CrashReportsPath = Join-Path $PlexDataPath "Crash Reports"
Write-Host "Cleaning all crash reports..."
Remove-OrphanedFiles -Path $CrashReportsPath -Recurse

# 8. Updates (Installer files)
$UpdatesPath = Join-Path $PlexDataPath "Updates"
Write-Host "Cleaning old update installers..."
Remove-OrphanedFiles -Path $UpdatesPath -Recurse

Write-Host "`nCleanup Complete!" -ForegroundColor Green

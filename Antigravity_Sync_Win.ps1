#Requires -Version 5.1
<#
.SYNOPSIS
    Backup and restore Antigravity settings, extensions, and global AI rules.

.DESCRIPTION
    A streamlined script to sync Antigravity IDE configuration across machines.
    Supports Windows and WSL environments with robust directory mirroring.

.PARAMETER Action
    'backup' or 'restore'

.PARAMETER Versioned
    Creates timestamped backup (backup only)

.PARAMETER LogFile
    Path to log file (default: scriptname.log)

.PARAMETER IncludeWSL
    Enable WSL support (auto-detects default distro)

.EXAMPLE
    .\Antigravity_Sync_Win.ps1 -Action backup -IncludeWSL
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false, Position = 0)]
    [ValidateSet("backup", "restore")]
    [string]$Action,

    [Parameter()]
    [switch]$Versioned,

    [Parameter()]
    [string]$LogFile,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$IncludeWSL,

    [Parameter()]
    [string]$WSLDistro
)

# Initialize LogFile if not set
if (-not $LogFile) {
    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)
    $LogFile = Join-Path $PSScriptRoot "$scriptName.log"
}

#region Configuration
# Load configuration from JSON file
$ConfigPath = Join-Path $PSScriptRoot "Antigravity_Sync_Win.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config file not found: $ConfigPath. Please create it with BaseBackupPath."
    exit 1
}
$ConfigData = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$Script:Config = @{
    BaseBackupPath = $ConfigData.BaseBackupPath
    SettingsFiles  = @("settings.json", "keybindings.json")
    Win            = @{
        Name     = "Windows"
        Settings = "$env:APPDATA\Antigravity\User"
        Rules    = "$env:USERPROFILE\.gemini"
        ExtFile  = "extensions.txt"
        WSL      = $null
    }
}


function Get-WSLConfig {
    param([string]$DistroName)
    $wslExe = Get-Command "wsl.exe" -ErrorAction SilentlyContinue
    if (-not $wslExe) { return $null }
    
    try {
        $rawOutput = wsl.exe --list --quiet 2>&1 | Out-String
        $cleanOutput = $rawOutput -replace '\x00', ''
        $distros = $cleanOutput -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        
        if (-not $distros) {
            Write-Log "No WSL distributions found." -Level Warning
            return $null
        }
        
        if ($DistroName) { $target = $distros | Where-Object { $_ -eq $DistroName } | Select-Object -First 1 }
        else { $target = $distros | Select-Object -First 1 }
        
        if (-not $target) {
            Write-Log "WSL distro '$DistroName' not found. Available: $($distros -join ', ')" -Level Warning
            return $null
        }
        
        $user = (wsl.exe -d $target whoami 2>&1).Trim() -replace '\x00', ''
        $wslHome = "\\wsl`$\$target\home\$user"
        return @{
            Name     = "WSL ($target)"
            Settings = "$wslHome\.config\Antigravity\User"
            Rules    = "$wslHome\.gemini"
            ExtFile  = "extensions_wsl.txt"
            WSL      = @{ Distro = $target; User = $user }
        }
    }
    catch {
        Write-Log "Error detecting WSL: $_" -Level Warning
        return $null
    }
}

function Get-MenuChoice {
    param(
        [string]$Title = "Select Action:",
        [string[]]$Options = @("Backup", "Restore")
    )
    $selectedIndex = 0
    $hostRaw = $Host.UI.RawUI
    $origColor = $hostRaw.ForegroundColor
    
    while ($true) {
        Clear-Host
        Write-Host "=== $Title ===" -ForegroundColor Cyan
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $selectedIndex) {
                Write-Host " > $($Options[$i])" -ForegroundColor Green
            }
            else {
                Write-Host "   $($Options[$i])"
            }
        }
        
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        if ($key.VirtualKeyCode -eq 38) {
            # Up Arrow
            $selectedIndex = ($selectedIndex - 1 + $Options.Count) % $Options.Count
        }
        elseif ($key.VirtualKeyCode -eq 40) {
            # Down Arrow
            $selectedIndex = ($selectedIndex + 1) % $Options.Count
        }
        elseif ($key.VirtualKeyCode -eq 13) {
            # Enter
            return $Options[$selectedIndex].ToLower()
        }
        elseif ($key.VirtualKeyCode -eq 27) {
            # Esc
            exit 0
        }
    }
}

#endregion

#region Helpers
function Write-Log {
    param([string]$Message, [ValidateSet("Info", "Success", "Warning", "Error")]$Level = "Info")
    $logEntry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    $colors = @{ Info = "Cyan"; Success = "Green"; Warning = "Yellow"; Error = "Red" }
    Write-Host $logEntry -ForegroundColor $colors[$Level]
    if ($LogFile) { Add-Content -Path $LogFile -Value $logEntry -ErrorAction SilentlyContinue }
}

function Run-Antigravity {
    param([string]$Command, [hashtable]$Env)
    if ($Env.WSL) {
        return wsl.exe -d $Env.WSL.Distro -- bash -c "antigravity $Command" 2>&1
    }
    return & antigravity $Command 2>&1
}

function Sync-Path {
    param([string]$Source, [string]$Dest, [switch]$IsFile)
    if (!(Test-Path $Source)) { return "Skipped (source not found)" }
    
    if ($IsFile) {
        Copy-Item -Path $Source -Destination $Dest -Force -ErrorAction Stop
        return "Success"
    }
    else {
        # Check for WSL symlink to Windows
        if ($Source -match '^\\\\wsl') {
            $distro = $Source.Split('\')[3]
            $target = wsl.exe -d $distro -- bash -c "readlink -f ~/.gemini" 2>&1
            if (($target | Out-String) -match '/mnt/[a-z]/') { return "Skipped (symlinked to Windows)" }
        }
        
        $parent = Split-Path -Parent $Dest
        if (!(Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        
        # Use robocopy for robust directory sync
        $args = @($Source, $Dest, "/E", "/XJ", "/XD", ".gemini", "/R:1", "/W:1", "/NFL", "/NDL", "/NJH", "/NJS")
        & robocopy $args | Out-Null
        return "Success"
    }
}
#endregion

#region Main Logic
function Invoke-Sync {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($SourceEnv, $BackupRoot, [switch]$Restore)
    
    $envName = $SourceEnv.Name
    if ($Restore) { $targetPath = $BackupRoot }
    else {
        if ($SourceEnv.WSL) { $targetPath = Join-Path $BackupRoot "WSL_$($SourceEnv.WSL.Distro)" }
        else { $targetPath = $BackupRoot }
    }
    
    if (!$Restore -and !(Test-Path $targetPath)) { New-Item -ItemType Directory -Path $targetPath -Force | Out-Null }
    
    Write-Log "----------------------------------------"
    Write-Log "$($Action.ToUpper())ing $envName..."
    
    # 1. Settings Files
    foreach ($file in $Script:Config.SettingsFiles) {
        if ($Restore) { 
            $src = Join-Path $targetPath $file
            $dst = Join-Path $SourceEnv.Settings $file
        }
        else {
            $src = Join-Path $SourceEnv.Settings $file
            $dst = $targetPath
        }
        
        if ($PSCmdlet.ShouldProcess($src, "Sync to $dst")) {
            try { 
                $res = Sync-Path -Source $src -Dest $dst -IsFile
                if ($res -eq "Success") { $level = "Success" } else { $level = "Warning" }
                Write-Log "  Settings ($file): $res" -Level $level
            }
            catch { Write-Log "  Settings ($file): Error - $_" -Level Error }
        }
    }
    
    # 2. Global Rules (.gemini)
    if ($Restore) {
        $rulesSrc = Join-Path $targetPath ".gemini"
        $rulesDst = $SourceEnv.Rules
    }
    else {
        $rulesSrc = $SourceEnv.Rules
        $rulesDst = Join-Path $targetPath ".gemini"
    }
    
    if ($PSCmdlet.ShouldProcess($rulesSrc, "Sync to $rulesDst")) {
        try {
            $res = Sync-Path -Source $rulesSrc -Dest $rulesDst
            if ($res -eq "Success") { $level = "Success" } else { $level = "Warning" }
            Write-Log "  Rules (.gemini): $res" -Level $level
        }
        catch { Write-Log "  Rules (.gemini): Error - $_" -Level Error }
    }
    
    # 3. Extensions
    $extPath = Join-Path $targetPath $SourceEnv.ExtFile
    if ($Restore) {
        if (Test-Path $extPath) {
            $exts = Get-Content $extPath | Where-Object { $_.Trim() }
            Write-Log "  Found $($exts.Count) extensions."
            if ($Force -or (Read-Host "  Reinstall extensions for $envName? (y/n)") -eq 'y') {
                foreach ($ext in $exts) {
                    Write-Progress -Activity "Installing for $envName" -Status $ext
                    Run-Antigravity "--install-extension $ext" $SourceEnv | Out-Null
                }
                Write-Log "  Extensions: Reinstalled" -Level Success
            }
        }
    }
    else {
        $exts = Run-Antigravity "--list-extensions" $SourceEnv
        if ($LASTEXITCODE -eq 0 -and $exts) {
            $extStrings = $exts | Where-Object { $_ -is [string] -and $_.Trim() }
            $extStrings | Out-File -FilePath $extPath -Encoding UTF8 -Force
            Write-Log "  Extensions: Exported $($extStrings.Count)" -Level Success
        }
        else { Write-Log "  Extensions: CLI failed or not found" -Level Warning }
    }
}

try {
    if (-not $Action) {
        $Action = Get-MenuChoice
    }

    Write-Log "=== Antigravity Sync Started ==="
    $machineName = $env:COMPUTERNAME
    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    if ($Versioned) { $subFolder = "${machineName}_${timestamp}" } else { $subFolder = $machineName }
    $backupRoot = Join-Path $Script:Config.BaseBackupPath $subFolder
    
    if ($Action -eq "restore") {
        # Select version if multiple exist
        $backups = Get-ChildItem $Script:Config.BaseBackupPath -Directory | Sort-Object Name -Descending
        if ($backups.Count -gt 1 -and !$Force) {
            Write-Log "Select backup to restore:"
            for ($i = 0; $i -lt $backups.Count; $i++) { Write-Host "  [$i] $($backups[$i].Name)" }
            $sel = Read-Host "Choice"
            if ($sel -match '^\d+$' -and $sel -lt $backups.Count) { $backupRoot = $backups[$sel].FullName }
        }
    }

    $Envs = @($Script:Config.Win)
    if ($IncludeWSL) {
        $wslEnv = Get-WSLConfig -DistroName $WSLDistro
        if ($wslEnv) { $Envs += $wslEnv } else { Write-Log "WSL distro not found" -Level Warning }
    }
    
    foreach ($env in $Envs) { Invoke-Sync -SourceEnv $env -BackupRoot $backupRoot -Restore:($Action -eq "restore") }
    
    Write-Log "=== Sync Completed ===" -Level Success
}
catch {
    Write-Log "Fatal error: $_" -Level Error
    exit 1
}
#endregion

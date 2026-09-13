<#
.SYNOPSIS
    Pulls and applies the latest chezmoi-managed dotfiles (Claude/Codex/Antigravity/Cursor config).
.DESCRIPTION
    Thin wrapper around `chezmoi update` (git pull + apply in one step) for the
    dotfiles source at ~/Private/dotfiles. Intended to be run on a schedule by
    Setup-DotfileSyncTask_Win.ps1, or manually at any time.
.PARAMETER NoPause
    Do not wait for Enter before exiting (used for scheduled/unattended runs).
#>

param(
    [switch]$NoPause
)

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $Color = switch ($Level) {
        "Info" { "Cyan" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
    }
    $Icon = switch ($Level) {
        "Info" { "[*]" }
        "Success" { "[+]" }
        "Warning" { "[!]" }
        "Error" { "[X]" }
    }
    Write-Host "$Icon $Message" -ForegroundColor $Color
}

$ScriptDir = $PSScriptRoot
$LogDir = Join-Path (Split-Path $ScriptDir -Parent) "logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$MachineName = $env:COMPUTERNAME
$Timestamp = Get-Date -Format "yyyy-MM-dd"
$LogFile = Join-Path $LogDir "Update-Dotfiles_Win_${MachineName}_${Timestamp}.log"
$RunAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$ChezmoiCmd = Get-Command chezmoi -ErrorAction SilentlyContinue
if (-not $ChezmoiCmd) {
    $Message = "chezmoi is not installed or not on PATH. Run Bootstrap-Machine_Win.ps1 first."
    Write-Status $Message -Level Error
    Add-Content -Path $LogFile -Value "[$RunAt] ERROR: $Message"
    if (-not $NoPause) { Read-Host "Press Enter to exit" }
    exit 1
}

Write-Status "Running chezmoi update..." -Level Info

$Output = & chezmoi update --verbose 2>&1
$ExitCode = $LASTEXITCODE

Add-Content -Path $LogFile -Value "[$RunAt] chezmoi update (exit $ExitCode)"
Add-Content -Path $LogFile -Value $Output

if ($ExitCode -eq 0) {
    Write-Status "Dotfiles are up to date." -Level Success
}
else {
    Write-Status "chezmoi update failed (exit $ExitCode). See $LogFile" -Level Error
}

if (-not $NoPause) {
    Write-Host ""
    Write-Host "Press Enter to exit..."
    Read-Host
}

exit $ExitCode

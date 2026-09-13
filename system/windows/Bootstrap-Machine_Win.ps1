<#
.SYNOPSIS
    Bootstraps a fresh (or existing) Windows machine onto the chezmoi-managed dotfiles.
.DESCRIPTION
    Installs chezmoi if missing, initializes and applies the dotfiles source from the
    private repo, then installs the recurring sync task via Setup-DotfileSyncTask_Win.ps1.
    Safe to re-run on an already-bootstrapped machine.
.PARAMETER RepoUrl
    Git URL of the private dotfiles repo. Defaults to the SSH remote; pass the HTTPS
    URL instead if that's what you've already authenticated on this machine.
.PARAMETER NoPause
    Do not wait for Enter before exiting.
.EXAMPLE
    .\Bootstrap-Machine_Win.ps1
.EXAMPLE
    .\Bootstrap-Machine_Win.ps1 -RepoUrl https://github.com/jkowall/Private.git
#>

param(
    [string]$RepoUrl = "git@github.com:jkowall/Private.git",
    [switch]$NoPause
)

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )
    $Color = switch ($Level) { "Info" { "Cyan" } "Success" { "Green" } "Warning" { "Yellow" } "Error" { "Red" } }
    $Icon = switch ($Level) { "Info" { "[*]" } "Success" { "[+]" } "Warning" { "[!]" } "Error" { "[X]" } }
    Write-Host "$Icon $Message" -ForegroundColor $Color
}

$ScriptDir = $PSScriptRoot
$SetupTaskScript = Join-Path $ScriptDir "Setup-DotfileSyncTask_Win.ps1"

# 1. Install chezmoi if missing
if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
    Write-Status "chezmoi not found. Installing via winget..." -Level Info
    winget install --id twpayne.chezmoi -e --accept-source-agreements --accept-package-agreements
    if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
        Write-Status "chezmoi install did not put it on PATH for this session. Open a new terminal and re-run this script." -Level Error
        if (-not $NoPause) { Read-Host "Press Enter to exit" }
        exit 1
    }
    Write-Status "chezmoi installed." -Level Success
}
else {
    Write-Status "chezmoi already installed ($((chezmoi --version) -join ' '))." -Level Success
}

# 2. Initialize + apply the dotfiles source (idempotent: no-op if already initialized to the same repo)
$SourcePath = (& chezmoi source-path 2>$null)
if (-not $SourcePath -or -not (Test-Path $SourcePath)) {
    Write-Status "Initializing chezmoi from $RepoUrl ..." -Level Info
    chezmoi init --apply $RepoUrl
    if ($LASTEXITCODE -ne 0) {
        Write-Status "chezmoi init --apply failed (exit $LASTEXITCODE). Check git auth for $RepoUrl." -Level Error
        if (-not $NoPause) { Read-Host "Press Enter to exit" }
        exit 1
    }
    Write-Status "Dotfiles applied." -Level Success
}
else {
    Write-Status "chezmoi already initialized at $SourcePath. Running chezmoi update instead..." -Level Info
    chezmoi update --verbose
}

# 3. Install the recurring sync task
if (-not (Test-Path $SetupTaskScript)) {
    Write-Status "Setup-DotfileSyncTask_Win.ps1 not found next to this script at: $SetupTaskScript" -Level Error
    if (-not $NoPause) { Read-Host "Press Enter to exit" }
    exit 1
}

Write-Status "Installing the recurring dotfile-sync task..." -Level Info
& $SetupTaskScript -NoPause

Write-Status "Bootstrap complete." -Level Success

if (-not $NoPause) {
    Write-Host ""
    Write-Host "Press Enter to exit..."
    Read-Host
}

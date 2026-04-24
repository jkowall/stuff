<#
.SYNOPSIS
    Weekly package update script for winget, Windows Store, Chocolatey, npm, WSL apt, and pip.
.DESCRIPTION
    Updates all packages from winget, Windows Store, Chocolatey,
    npm global packages, WSL Ubuntu (apt), and pip global packages.
    Logs all output to a timestamped file and shows toast notifications.
.NOTES
    Author: Auto-generated
#>

#Requires -Version 5.1

param(
    [switch]$SkipAdminChocolatey,
    [switch]$SkipUserChocolatey,
    [switch]$SkipWinget,
    [switch]$SkipWindowsStore,
    [switch]$SkipNpm,
    [switch]$SkipWsl,
    [switch]$SkipPip,
    [switch]$Elevated
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$ScriptDir = $PSScriptRoot
$LogDir = Join-Path (Split-Path $ScriptDir -Parent) "logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$ScriptName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$MachineName = $env:COMPUTERNAME
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$LogFile = Join-Path $LogDir "${ScriptName}_${MachineName}_$Timestamp.log"

# Track results for summary
$Results = @{
    Winget          = @{ Status = "Skipped"; Message = "" }
    WindowsStore    = @{ Status = "Skipped"; Message = "" }
    ChocolateyAdmin = @{ Status = "Skipped"; Message = "" }
    ChocolateyUser  = @{ Status = "Skipped"; Message = "" }
    Npm             = @{ Status = "Skipped"; Message = "" }
    Wsl             = @{ Status = "Skipped"; Message = "" }
    Pip             = @{ Status = "Skipped"; Message = "" }
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"

    # Write to console with color
    $Color = switch ($Level) {
        "Info" { "White" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
    }

    # Use Write-Host for console output. Transcript will capture this too.
    Write-Host $LogEntry -ForegroundColor $Color

    # If transcript is not running, append to file manually as a backup
    if (-not $script:TranscriptActive) {
        try {
            Add-Content -Path $LogFile -Value $LogEntry -ErrorAction SilentlyContinue
        }
        catch {}
    }
}

function Test-DataSaver {
    <#
    .SYNOPSIS
        Checks if the current network connection is metered (Data Saver / Metered Connection).
    .OUTPUTS
        $true if metered connection is active, $false otherwise.
    #>
    try {
        [void][Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
        $Profile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
        if ($null -eq $Profile) { return $false }
        $Cost = $Profile.GetConnectionCost()
        return ($Cost.NetworkCostType -ne [Windows.Networking.Connectivity.NetworkCostType]::Unrestricted) -or
               $Cost.Roaming -or $Cost.ApproachingDataLimit -or $Cost.OverDataLimit
    }
    catch {
        Write-Log "Could not determine metered connection status: $($_.Exception.Message)" -Level Warning
        return $false
    }
}

function Show-ToastNotification {
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Type = "Info"
    )

    try {
        # Try BurntToast first (nicer notifications)
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast -ErrorAction SilentlyContinue
            $Icon = switch ($Type) {
                "Info" { "Information" }
                "Warning" { "Warning" }
                "Error" { "Error" }
            }
            New-BurntToastNotification -Text $Title, $Message -AppLogo $null
            return
        }
    }
    catch {
        # Fall through to native method
    }

    # Fallback to native Windows toast
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

        $Template = @"
<toast>
    <visual>
        <binding template="ToastText02">
            <text id="1">$Title</text>
            <text id="2">$Message</text>
        </binding>
    </visual>
</toast>
"@
        $Xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $Xml.LoadXml($Template)
        $Toast = [Windows.UI.Notifications.ToastNotification]::new($Xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Package Updater").Show($Toast)
    }
    catch {
        # Last resort - balloon tip
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $Balloon = New-Object System.Windows.Forms.NotifyIcon
            $Balloon.Icon = [System.Drawing.SystemIcons]::Information
            $Balloon.BalloonTipIcon = $Type
            $Balloon.BalloonTipTitle = $Title
            $Balloon.BalloonTipText = $Message
            $Balloon.Visible = $true
            $Balloon.ShowBalloonTip(5000)
            Start-Sleep -Milliseconds 100
        }
        catch {
            Write-Log "Could not show toast notification: $_" -Level Warning
        }
    }
}

function Get-WingetCommand {
    $WingetCommand = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $WingetCommand) {
        $WingetCommand = Get-Command winget -ErrorAction Stop
    }

    return $WingetCommand
}

function Get-NpmCommand {
    $NpmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $NpmCommand) {
        $NpmCommand = Get-Command npm -ErrorAction Stop
    }

    return $NpmCommand
}

function Update-Winget {
    Write-Log "=" * 60 -Level Info
    Write-Log "STARTING WINGET UPDATES" -Level Info
    Write-Log "=" * 60 -Level Info

    try {
        # Check if winget is available
        $WingetPath = Get-WingetCommand
        Write-Log "Found winget at: $($WingetPath.Source)" -Level Info

        # Pin packages with broken version detection so they don't re-upgrade every run
        $WingetPins = @("Syncthing.Syncthing")
        foreach ($Pin in $WingetPins) {
            & $WingetPath.Source pin list | Select-String -Quiet $Pin
            if (-not $?) {
                Write-Log "Pinning $Pin (broken version detection)" -Level Info
                & $WingetPath.Source pin add $Pin --blocking 2>&1 | Out-Null
            }
        }

        # Run winget upgrade directly to preserve progress bars
        Write-Log "Running: winget upgrade --all --source winget --include-unknown --accept-package-agreements --accept-source-agreements" -Level Info

        & $WingetPath.Source upgrade --all --source winget --include-unknown --accept-package-agreements --accept-source-agreements

        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null) {
            $script:Results.Winget.Status = "Success"
            $script:Results.Winget.Message = "Winget packages updated successfully"
            Write-Log "Winget updates completed successfully" -Level Success
        }
        else {
            $script:Results.Winget.Status = "Warning"
            $script:Results.Winget.Message = "Winget completed with exit code: $LASTEXITCODE"
            Write-Log "Winget completed with exit code: $LASTEXITCODE" -Level Warning
        }

        # Explicitly upgrade PowerShell — winget upgrade --all often skips it
        # due to MSI installer detection issues
        Write-Log "Ensuring PowerShell 7+ is up to date..." -Level Info
        & $WingetPath.Source upgrade Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null) {
            Write-Log "PowerShell upgrade check completed" -Level Success
        }
        else {
            Write-Log "PowerShell upgrade completed with exit code: $LASTEXITCODE (may already be current)" -Level Warning
        }
    }
    catch {
        $script:Results.Winget.Status = "Error"
        $script:Results.Winget.Message = $_.Exception.Message
        Write-Log "Winget update failed: $($_.Exception.Message)" -Level Error
        Show-ToastNotification -Title "Winget Update Failed" -Message $_.Exception.Message -Type Error
    }
}

function Update-WindowsStore {
    Write-Log "=" * 60 -Level Info
    Write-Log "STARTING WINDOWS STORE UPDATES" -Level Info
    Write-Log "=" * 60 -Level Info

    try {
        $WingetPath = Get-WingetCommand
        Write-Log "Found winget at: $($WingetPath.Source)" -Level Info

        Write-Log "Running: winget upgrade --all --source msstore --include-unknown --accept-package-agreements --accept-source-agreements" -Level Info

        & $WingetPath.Source upgrade --all --source msstore --include-unknown --accept-package-agreements --accept-source-agreements

        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null) {
            $script:Results.WindowsStore.Status = "Success"
            $script:Results.WindowsStore.Message = "Windows Store packages updated successfully"
            Write-Log "Windows Store updates completed successfully" -Level Success
        }
        else {
            $script:Results.WindowsStore.Status = "Warning"
            $script:Results.WindowsStore.Message = "Windows Store updates completed with exit code: $LASTEXITCODE"
            Write-Log "Windows Store updates completed with exit code: $LASTEXITCODE" -Level Warning
        }
    }
    catch {
        $script:Results.WindowsStore.Status = "Error"
        $script:Results.WindowsStore.Message = $_.Exception.Message
        Write-Log "Windows Store update failed: $($_.Exception.Message)" -Level Error
        Show-ToastNotification -Title "Windows Store Update Failed" -Message $_.Exception.Message -Type Error
    }
}

function Update-Chocolatey {
    Write-Log "=" * 60 -Level Info
    Write-Log "STARTING CHOCOLATEY UPDATES" -Level Info
    Write-Log "=" * 60 -Level Info

    try {
        # Check if choco is available
        $ChocoPath = Get-Command choco -ErrorAction Stop
        Write-Log "Found Chocolatey at: $($ChocoPath.Source)" -Level Info

        # Chocolatey admin upgrade

        if ($IsAdmin) {
            Write-Log "Running choco upgrade..." -Level Info
            & choco upgrade all -y
        }
        else {
            Write-Log "ERROR: Update-ChocolateyAdmin called without Administrator privileges." -Level Error
            throw "Elevation required for Chocolatey admin updates."
        }

        $script:Results.ChocolateyAdmin.Status = "Success"
        $script:Results.ChocolateyAdmin.Message = "Chocolatey packages updated successfully"
        Write-Log "Chocolatey updates completed successfully" -Level Success
    }
    catch {
        $script:Results.ChocolateyAdmin.Status = "Error"
        $script:Results.ChocolateyAdmin.Message = $_.Exception.Message
        Write-Log "Chocolatey admin update failed: $($_.Exception.Message)" -Level Error
        Show-ToastNotification -Title "Chocolatey Admin Update Failed" -Message $_.Exception.Message -Type Error
    }
}


function Update-WslPackages {
    Write-Log "=" * 60 -Level Info
    Write-Log "STARTING WSL UBUNTU APT UPDATES" -Level Info
    Write-Log "=" * 60 -Level Info

    try {
        $WslPath = Get-Command wsl.exe -ErrorAction Stop
        Write-Log "Found wsl at: $($WslPath.Source)" -Level Info

        # Verify Ubuntu distro is available
        # wsl.exe -l outputs UTF-16LE with null chars; strip them for reliable matching
        $RawDistros = & wsl.exe -l -q 2>&1 | Out-String
        $CleanDistros = $RawDistros -replace "`0", ""
        if ($CleanDistros -notmatch "Ubuntu") {
            throw "Ubuntu WSL distro not found (installed: $($CleanDistros.Trim()))"
        }

        Write-Log "Running: apt-get update && apt-get upgrade && apt-get autoremove" -Level Info

        & wsl.exe -d Ubuntu -- bash -c "sudo apt-get update -y && sudo apt-get upgrade -y && sudo apt-get autoremove -y"

        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null) {
            $script:Results.Wsl.Status = "Success"
            $script:Results.Wsl.Message = "WSL Ubuntu packages updated successfully"
            Write-Log "WSL Ubuntu updates completed successfully" -Level Success
        }
        else {
            $script:Results.Wsl.Status = "Warning"
            $script:Results.Wsl.Message = "WSL apt completed with exit code: $LASTEXITCODE"
            Write-Log "WSL apt completed with exit code: $LASTEXITCODE" -Level Warning
        }
    }
    catch {
        $script:Results.Wsl.Status = "Error"
        $script:Results.Wsl.Message = $_.Exception.Message
        Write-Log "WSL Ubuntu update failed: $($_.Exception.Message)" -Level Error
        Show-ToastNotification -Title "WSL Update Failed" -Message $_.Exception.Message -Type Error
    }
}

function Update-Pip {
    Write-Log "=" * 60 -Level Info
    Write-Log "STARTING PIP UPDATES" -Level Info
    Write-Log "=" * 60 -Level Info

    try {
        $PipPath = Get-Command pip -ErrorAction Stop
        Write-Log "Found pip at: $($PipPath.Source)" -Level Info

        # Upgrade pip itself first
        Write-Log "Upgrading pip itself..." -Level Info
        & pip install --upgrade pip 2>&1 | ForEach-Object { Write-Log $_ -Level Info }

        # Get outdated packages as JSON
        Write-Log "Checking for outdated packages..." -Level Info
        $OutdatedJson = & pip list --outdated --format=json 2>&1

        $Outdated = @()
        try {
            $Outdated = $OutdatedJson | ConvertFrom-Json
        }
        catch {
            Write-Log "Could not parse pip outdated output" -Level Warning
        }

        if ($Outdated.Count -gt 0) {
            $PackageNames = $Outdated | ForEach-Object { $_.name }
            $PackageList = $PackageNames -join ", "
            Write-Log "Found $($Outdated.Count) outdated packages: $PackageList" -Level Info

            # Upgrade one at a time to avoid dependency conflicts —
            # packages with upper-bound constraints (e.g. pylint->astroid,
            # torch->setuptools) will fail individually instead of breaking the batch
            $Succeeded = 0
            $Failed = @()
            foreach ($Pkg in $PackageNames) {
                & pip install --upgrade $Pkg 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
                    Write-Log "  Failed to upgrade $Pkg (dependency conflict)" -Level Warning
                    $Failed += $Pkg
                }
                else {
                    Write-Log "  Upgraded $Pkg" -Level Success
                    $Succeeded++
                }
            }

            if ($Failed.Count -gt 0) {
                $script:Results.Pip.Status = "Warning"
                $script:Results.Pip.Message = "$Succeeded upgraded, $($Failed.Count) skipped (dependency conflicts): $($Failed -join ', ')"
                Write-Log "pip: $Succeeded upgraded, $($Failed.Count) skipped due to dependency conflicts" -Level Warning
            }
            else {
                $script:Results.Pip.Status = "Success"
                $script:Results.Pip.Message = "pip packages updated successfully ($Succeeded upgraded)"
                Write-Log "pip updates completed successfully" -Level Success
            }
        }
        else {
            $script:Results.Pip.Status = "Success"
            $script:Results.Pip.Message = "pip packages are already up-to-date"
            Write-Log "pip packages are already up-to-date" -Level Success
        }
    }
    catch {
        $script:Results.Pip.Status = "Error"
        $script:Results.Pip.Message = $_.Exception.Message
        Write-Log "pip update failed: $($_.Exception.Message)" -Level Error
        Show-ToastNotification -Title "pip Update Failed" -Message $_.Exception.Message -Type Error
    }
}

function Update-NpmGlobal {
    Write-Log "=" * 60 -Level Info
    Write-Log "STARTING NPM GLOBAL UPDATES" -Level Info
    Write-Log "=" * 60 -Level Info

    try {
        # Check if npm is available
        $NpmPath = Get-NpmCommand
        Write-Log "Found npm at: $($NpmPath.Source)" -Level Info

        Write-Log "Checking for outdated global packages..." -Level Info
        $OutdatedText = & $NpmPath.Source outdated -g --json 2>&1 | Out-String
        $OutdatedExitCode = $LASTEXITCODE

        if ($OutdatedExitCode -gt 1) {
            throw "npm outdated failed with exit code $OutdatedExitCode. Output: $($OutdatedText.Trim())"
        }

        $PackagesToUpdate = @()
        $OutdatedText = $OutdatedText.Trim()
        if ($OutdatedText) {
            $OutdatedPackages = $OutdatedText | ConvertFrom-Json
            foreach ($Property in $OutdatedPackages.PSObject.Properties) {
                $PackageName = $Property.Name
                $PackageInfo = $Property.Value
                $TargetVersion = if ($PackageInfo.latest) { $PackageInfo.latest } else { "latest" }
                $PackagesToUpdate += "$PackageName@$TargetVersion"
                Write-Log "  ${PackageName}: $($PackageInfo.current) -> $TargetVersion" -Level Info
            }
        }

        if ($PackagesToUpdate.Count -gt 0) {
            $PackageList = $PackagesToUpdate -join " "
            Write-Log "Updating packages: $PackageList" -Level Info

            & $NpmPath.Source install -g $PackagesToUpdate

            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
                $script:Results.Npm.Status = "Warning"
                $script:Results.Npm.Message = "npm completed with exit code: $LASTEXITCODE"
                Write-Log "npm completed with exit code: $LASTEXITCODE" -Level Warning
                return
            }

            $script:Results.Npm.Status = "Success"
            $script:Results.Npm.Message = "npm global packages updated successfully"
            Write-Log "npm global updates completed successfully" -Level Success
        }
        else {
            $script:Results.Npm.Status = "Success"
            $script:Results.Npm.Message = "npm global packages are already up-to-date"
            Write-Log "npm global packages are already up-to-date" -Level Success
        }
    }
    catch {
        $script:Results.Npm.Status = "Error"
        $script:Results.Npm.Message = $_.Exception.Message
        Write-Log "npm global update failed: $($_.Exception.Message)" -Level Error
        Show-ToastNotification -Title "npm Update Failed" -Message $_.Exception.Message -Type Error
    }
}

function Show-Summary {
    Write-Log "" -Level Info
    Write-Log "=" * 60 -Level Info
    Write-Log "UPDATE SUMMARY" -Level Info
    Write-Log "=" * 60 -Level Info

    $HasErrors = $false

    foreach ($Key in $Results.Keys) {
        $Result = $Results[$Key]
        $StatusIcon = switch ($Result.Status) {
            "Success" { "[OK]" }
            "Warning" { "[!!]" }
            "Error" { "[XX]" }
            "Skipped" { "[--]" }
        }
        $Level = switch ($Result.Status) {
            "Success" { "Success" }
            "Warning" { "Warning" }
            "Error" { "Error" }
            "Skipped" { "Info" }
        }

        Write-Log "$StatusIcon $Key : $($Result.Status) - $($Result.Message)" -Level $Level

        if ($Result.Status -eq "Error") {
            $HasErrors = $true
        }
    }

    Write-Log "=" * 60 -Level Info
    Write-Log "Log file saved to: $LogFile" -Level Info

    # Final notification
    if ($HasErrors) {
        Show-ToastNotification -Title "Package Updates Completed with Errors" -Message "Check the log for details: $LogFile" -Type Warning
    }
    else {
        Show-ToastNotification -Title "Package Updates Completed" -Message "All package managers updated successfully!" -Type Info
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Set window title
$Host.UI.RawUI.WindowTitle = "Package Updater - $Timestamp"

# Initialize log with Transcript
try {
    Start-Transcript -Path $LogFile -Append -IncludeInvocationHeader -ErrorAction Stop
    $script:TranscriptActive = $true
}
catch {
    $script:TranscriptActive = $false
}

Write-Log "=" * 60 -Level Info
Write-Log "PACKAGE UPDATE STARTED (Elevated=$Elevated, Admin=$IsAdmin)" -Level Info
Write-Log "Script Directory: $ScriptDir" -Level Info
Write-Log "Log File: $LogFile" -Level Info
Write-Log "=" * 60 -Level Info

# Check for Data Saver / Metered Connection
if (Test-DataSaver) {
    Write-Log "Metered connection (Data Saver) detected. Skipping auto updates to conserve data." -Level Warning
    Show-ToastNotification -Title "Package Updates Skipped" -Message "Metered connection detected. Updates deferred to save data." -Type Warning
    if ($script:TranscriptActive) {
        try { Stop-Transcript -ErrorAction SilentlyContinue } catch {}
    }
    exit 0
}

# Clean up old log files (keep only 3 most recent)
$LogPattern = Join-Path $LogDir "${ScriptName}_*.log"
$OldLogs = Get-ChildItem -Path $LogPattern -ErrorAction SilentlyContinue |
Sort-Object LastWriteTime -Descending |
Select-Object -Skip 3
if ($OldLogs) {
    Write-Log "Cleaning up $($OldLogs.Count) old log file(s)..." -Level Info
    $OldLogs | ForEach-Object {
        Write-Log "  Removing: $($_.Name)" -Level Info
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

# Show start notification
Show-ToastNotification -Title "Package Updates Starting" -Message "Updating winget, Windows Store, Chocolatey, npm, WSL apt, and pip packages..." -Type Info

# Handle split execution (User vs Elevated)

if (-not $IsAdmin -and -not $Elevated) {
    # 1. Run Other Non-Admin Tasks (if any)
    # (Currently all tasks are moved to elevated to avoid warnings)

    # 2. Check if we need elevation for other tasks
    $NeedsElevation = $false
    if (-not $SkipWinget) { $NeedsElevation = $true }
    if (-not $SkipWindowsStore) { $NeedsElevation = $true }
    if (-not $SkipAdminChocolatey) { $NeedsElevation = $true }
    if (-not $SkipNpm) {
        try {
            $NpmPath = Get-NpmCommand
            if ($NpmPath) {
                $NpmDir = Split-Path (Split-Path $NpmPath.Source -Parent) -Parent
                if ($NpmDir -like "*Program Files*") { $NeedsElevation = $true }
            }
        }
        catch {
            Write-Log "npm was not found while checking elevation requirements; skipping npm elevation check." -Level Warning
        }
    }

    if ($NeedsElevation) {
        Write-Log "Admin tasks pending. Requesting one-time elevation..." -Level Warning
        $RelaunchArgs = @("-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-Elevated")
        if ($SkipWinget) { $RelaunchArgs += "-SkipWinget" }
        if ($SkipWindowsStore) { $RelaunchArgs += "-SkipWindowsStore" }
        if ($SkipAdminChocolatey) { $RelaunchArgs += "-SkipAdminChocolatey" }
        if ($SkipNpm) { $RelaunchArgs += "-SkipNpm" }
        if ($SkipWsl) { $RelaunchArgs += "-SkipWsl" }
        if ($SkipPip) { $RelaunchArgs += "-SkipPip" }
        $RelaunchArgs += "-SkipUserChocolatey" # Handled in this process

        Start-Process "powershell.exe" -ArgumentList $RelaunchArgs -Verb RunAs -Wait
    }
}
elseif ($Elevated -and -not $IsAdmin) {
    Write-Log "ERROR: Elevated switch set but process is NOT running as Administrator." -Level Error
}
else {
    # Running as Admin (or explicitly requested elevated tasks)
    if (-not $SkipWinget) { Update-Winget }
    if (-not $SkipWindowsStore) { Update-WindowsStore }
    if (-not $SkipAdminChocolatey -or -not $SkipUserChocolatey) { Update-Chocolatey }
    if (-not $SkipNpm) { Update-NpmGlobal }
    if (-not $SkipWsl) { Update-WslPackages }
    if (-not $SkipPip) { Update-Pip }
}

# Stop Transcript
if ($script:TranscriptActive) {
    try { Stop-Transcript -ErrorAction SilentlyContinue } catch {}
}

if ($Elevated -or $IsAdmin) {
    # Only show summary and completion wait in the "active" or final process
    Show-Summary
    Write-Log "" -Level Info
    Write-Log "Update process completed. Press Enter to close this window..." -Level Info
    Read-Host
}

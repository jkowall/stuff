<#
.SYNOPSIS
    Weekly package update script for winget, Chocolatey, and npm.
.DESCRIPTION
    Updates all packages from winget, Chocolatey (both admin and user), and npm global packages.
    Logs all output to a timestamped file and shows toast notifications.
.NOTES
    Schedule: Saturdays at 1:00 PM
    Author: Auto-generated
#>

#Requires -Version 5.1

param(
    [switch]$SkipAdminChocolatey,
    [switch]$SkipUserChocolatey,
    [switch]$SkipWinget,
    [switch]$SkipNpm
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$ScriptDir = $PSScriptRoot
$ScriptName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$LogFile = Join-Path $ScriptDir "${ScriptName}_$Timestamp.log"

# Track results for summary
$Results = @{
    Winget          = @{ Status = "Skipped"; Message = "" }
    ChocolateyAdmin = @{ Status = "Skipped"; Message = "" }
    ChocolateyUser  = @{ Status = "Skipped"; Message = "" }
    Npm             = @{ Status = "Skipped"; Message = "" }
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
    Write-Host $LogEntry -ForegroundColor $Color
    
    # Append to log file
    Add-Content -Path $LogFile -Value $LogEntry
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

function Update-Winget {
    Write-Log "=" * 60 -Level Info
    Write-Log "STARTING WINGET UPDATES" -Level Info
    Write-Log "=" * 60 -Level Info
    
    try {
        # Check if winget is available
        $WingetPath = Get-Command winget -ErrorAction Stop
        Write-Log "Found winget at: $($WingetPath.Source)" -Level Info
        
        # Run winget upgrade with --include-unknown
        Write-Log "Running: winget upgrade --all --include-unknown --accept-package-agreements --accept-source-agreements" -Level Info
        
        $Output = & winget upgrade --all --include-unknown --accept-package-agreements --accept-source-agreements 2>&1
        $Output | ForEach-Object { Write-Log $_ -Level Info }
        
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
    }
    catch {
        $script:Results.Winget.Status = "Error"
        $script:Results.Winget.Message = $_.Exception.Message
        Write-Log "Winget update failed: $($_.Exception.Message)" -Level Error
        Show-ToastNotification -Title "Winget Update Failed" -Message $_.Exception.Message -Type Error
    }
}

function Update-ChocolateyAdmin {
    Write-Log "=" * 60 -Level Info
    Write-Log "STARTING CHOCOLATEY ADMIN UPDATES" -Level Info
    Write-Log "=" * 60 -Level Info
    
    try {
        # Check if choco is available
        $ChocoPath = Get-Command choco -ErrorAction Stop
        Write-Log "Found Chocolatey at: $($ChocoPath.Source)" -Level Info
        
        # Check if running as admin
        $IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        
        if ($IsAdmin) {
            Write-Log "Running as Administrator - executing choco upgrade directly" -Level Info
            $Output = & choco upgrade all -y 2>&1
            $Output | ForEach-Object { Write-Log $_ -Level Info }
        }
        else {
            Write-Log "Not running as Administrator - requesting elevation" -Level Warning
            Write-Log "A UAC prompt will appear. Please approve to update admin-installed packages." -Level Warning
            
            # Create a temporary script to run elevated
            $TempScript = Join-Path $env:TEMP "choco-admin-update.ps1"
            $TempLog = Join-Path $env:TEMP "choco-admin-update.log"
            
            @"
`$ErrorActionPreference = 'Continue'
`$Output = & choco upgrade all -y 2>&1
`$Output | Out-File -FilePath '$TempLog' -Encoding UTF8
"@ | Out-File -FilePath $TempScript -Encoding UTF8
            
            $Process = Start-Process -FilePath "powershell.exe" `
                -ArgumentList "-ExecutionPolicy Bypass -File `"$TempScript`"" `
                -Verb RunAs `
                -Wait `
                -PassThru
            
            # Read and log the output
            if (Test-Path $TempLog) {
                Get-Content $TempLog | ForEach-Object { Write-Log $_ -Level Info }
                Remove-Item $TempLog -Force -ErrorAction SilentlyContinue
            }
            Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
            
            if ($Process.ExitCode -ne 0) {
                throw "Elevated Chocolatey process exited with code: $($Process.ExitCode)"
            }
        }
        
        $script:Results.ChocolateyAdmin.Status = "Success"
        $script:Results.ChocolateyAdmin.Message = "Chocolatey admin packages updated successfully"
        Write-Log "Chocolatey admin updates completed successfully" -Level Success
    }
    catch {
        $script:Results.ChocolateyAdmin.Status = "Error"
        $script:Results.ChocolateyAdmin.Message = $_.Exception.Message
        Write-Log "Chocolatey admin update failed: $($_.Exception.Message)" -Level Error
        Show-ToastNotification -Title "Chocolatey Admin Update Failed" -Message $_.Exception.Message -Type Error
    }
}

function Update-ChocolateyUser {
    Write-Log "=" * 60 -Level Info
    Write-Log "STARTING CHOCOLATEY USER UPDATES" -Level Info
    Write-Log "=" * 60 -Level Info
    
    try {
        # Check if choco is available
        $ChocoPath = Get-Command choco -ErrorAction Stop
        Write-Log "Found Chocolatey at: $($ChocoPath.Source)" -Level Info
        
        Write-Log "Running: choco upgrade all -y (as current user)" -Level Info
        
        $Output = & choco upgrade all -y 2>&1
        $Output | ForEach-Object { Write-Log $_ -Level Info }
        
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null) {
            $script:Results.ChocolateyUser.Status = "Success"
            $script:Results.ChocolateyUser.Message = "Chocolatey user packages updated successfully"
            Write-Log "Chocolatey user updates completed successfully" -Level Success
        }
        else {
            $script:Results.ChocolateyUser.Status = "Warning"
            $script:Results.ChocolateyUser.Message = "Chocolatey completed with exit code: $LASTEXITCODE"
            Write-Log "Chocolatey completed with exit code: $LASTEXITCODE" -Level Warning
        }
    }
    catch {
        $script:Results.ChocolateyUser.Status = "Error"
        $script:Results.ChocolateyUser.Message = $_.Exception.Message
        Write-Log "Chocolatey user update failed: $($_.Exception.Message)" -Level Error
        Show-ToastNotification -Title "Chocolatey User Update Failed" -Message $_.Exception.Message -Type Error
    }
}

function Update-NpmGlobal {
    Write-Log "=" * 60 -Level Info
    Write-Log "STARTING NPM GLOBAL UPDATES" -Level Info
    Write-Log "=" * 60 -Level Info
    
    try {
        # Check if npm is available
        $NpmPath = Get-Command npm -ErrorAction Stop
        Write-Log "Found npm at: $($NpmPath.Source)" -Level Info
        
        # First, list outdated packages
        Write-Log "Checking for outdated global packages..." -Level Info
        $Outdated = & npm outdated -g 2>&1
        if ($Outdated) {
            $Outdated | ForEach-Object { Write-Log $_ -Level Info }
        }
        else {
            Write-Log "No outdated packages found" -Level Info
        }
        
        # Update all global packages
        Write-Log "Running: npm update -g" -Level Info
        $Output = & npm update -g 2>&1
        $Output | ForEach-Object { Write-Log $_ -Level Info }
        
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null) {
            $script:Results.Npm.Status = "Success"
            $script:Results.Npm.Message = "npm global packages updated successfully"
            Write-Log "npm global updates completed successfully" -Level Success
        }
        else {
            $script:Results.Npm.Status = "Warning"
            $script:Results.Npm.Message = "npm completed with exit code: $LASTEXITCODE"
            Write-Log "npm completed with exit code: $LASTEXITCODE" -Level Warning
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

# Initialize log
Write-Log "=" * 60 -Level Info
Write-Log "PACKAGE UPDATE STARTED" -Level Info
Write-Log "Script Directory: $ScriptDir" -Level Info
Write-Log "Log File: $LogFile" -Level Info
Write-Log "=" * 60 -Level Info

# Clean up old log files (keep only 3 most recent)
$LogPattern = Join-Path $ScriptDir "${ScriptName}_*.log"
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
Show-ToastNotification -Title "Package Updates Starting" -Message "Updating winget, Chocolatey, and npm packages..." -Type Info

# Run updates
if (-not $SkipWinget) {
    Update-Winget
}
else {
    Write-Log "Skipping Winget updates (flag set)" -Level Info
}

if (-not $SkipAdminChocolatey) {
    Update-ChocolateyAdmin
}
else {
    Write-Log "Skipping Chocolatey admin updates (flag set)" -Level Info
}

if (-not $SkipUserChocolatey) {
    Update-ChocolateyUser
}
else {
    Write-Log "Skipping Chocolatey user updates (flag set)" -Level Info
}

if (-not $SkipNpm) {
    Update-NpmGlobal
}
else {
    Write-Log "Skipping npm updates (flag set)" -Level Info
}

# Show summary
Show-Summary

Write-Log "" -Level Info
Write-Log "Update process completed. Press Enter to close this window..." -Level Info

# Keep window open for review
Read-Host

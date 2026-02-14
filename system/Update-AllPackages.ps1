<#
.SYNOPSIS
    Weekly package update script for winget, Chocolatey, and npm.
.DESCRIPTION
    Updates all packages from winget, Chocolatey (both admin and user), and npm global packages.
    Logs all output to a timestamped file and shows toast notifications.
.NOTES
    Author: Auto-generated
#>

#Requires -Version 5.1

param(
    [switch]$SkipAdminChocolatey,
    [switch]$SkipUserChocolatey,
    [switch]$SkipWinget,
    [switch]$SkipNpm,
    [switch]$Elevated
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$ScriptDir = $PSScriptRoot
$ScriptName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$MachineName = $env:COMPUTERNAME
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$LogFile = Join-Path $ScriptDir "${ScriptName}_${MachineName}_$Timestamp.log"

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
        
        # Run winget upgrade directly to preserve progress bars
        Write-Log "Running: winget upgrade --all --include-unknown --accept-package-agreements --accept-source-agreements" -Level Info
        
        & winget upgrade --all --include-unknown --accept-package-agreements --accept-source-agreements
        
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
        
        # Check if npm is installed in Program Files (requires admin)
        $NpmDir = Split-Path (Split-Path $NpmPath.Source -Parent) -Parent
        $RequiresAdmin = $NpmDir -like "*Program Files*"
        
        # Running npm update (using global $IsAdmin)
        
        Write-Log "Running npm update..." -Level Info
        & npm update -g
            
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

function Verify-ScheduledTask {
    $TaskName = $ScriptName
    $ScriptPath = $PSCommandPath
    
    try {
        $ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        
        if ($ExistingTask) {
            # Check if trigger matches Saturday at 1 AM
            $Trigger = $ExistingTask.Triggers | Where-Object { $_.WeeklyDetails -and $_.WeeklyDetails.DaysOfWeek -eq "Saturday" -and $_.StartBoundary -like "*T01:00:00" }
            if ($Trigger) {
                Write-Log "Scheduled task '$TaskName' is correctly configured." -Level Info
                return
            }
            Write-Log "Scheduled task '$TaskName' exists but configuration might be different. Recommended: Saturday at 1:00 AM." -Level Warning
            # We found a task, so we don't need to prompt to create one.
            return
        }
        else {
            Write-Log "Scheduled task '$TaskName' not found." -Level Warning
        }

        # If we get here, the task is completely missing
        Write-Host ""
        Write-Host "--- SCHEDULED TASK SETUP ---" -ForegroundColor Cyan
        Write-Host "This script is not currently scheduled to run weekly."
        $Choice = Read-Host "Would you like to schedule it to run every Saturday at 1:00 AM? (y/n)"
        
        if ($Choice -eq 'y') {
            Write-Log "User requested to schedule the task." -Level Info
            
            # Remove existing task if it exists to prevent duplicates
            if ($ExistingTask) {
                Write-Log "Removing existing task to prevent duplicates..." -Level Info
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            }
            
            $Action = New-ScheduledTaskAction `
                -Execute "powershell.exe" `
                -Argument "-ExecutionPolicy Bypass -NoExit -File `"$ScriptPath`"" `
                -WorkingDirectory $ScriptDir
            
            $Trigger = New-ScheduledTaskTrigger `
                -Weekly `
                -DaysOfWeek Saturday `
                -At "1:00AM"
            
            $Settings = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -StartWhenAvailable `
                -RunOnlyIfNetworkAvailable `
                -WakeToRun:$false
            
            $Principal = New-ScheduledTaskPrincipal `
                -UserId $env:USERNAME `
                -LogonType Interactive `
                -RunLevel Limited
            
            Register-ScheduledTask `
                -TaskName $TaskName `
                -Action $Action `
                -Trigger $Trigger `
                -Settings $Settings `
                -Principal $Principal `
                -Description "Weekly update of winget, Chocolatey, and npm packages. Runs every Saturday at 1:00 AM."
            
            Write-Log "Scheduled task '$TaskName' created successfully!" -Level Success
            Show-ToastNotification -Title "Task Scheduled" -Message "Weekly updates scheduled for Saturdays at 1:00 AM" -Type Info
        }
    }
    catch {
        Write-Log "Failed to verify or create scheduled task: $($_.Exception.Message)" -Level Error
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

# Handle split execution (User vs Elevated)

if (-not $IsAdmin -and -not $Elevated) {
    # Verify scheduling (only once in the main process)
    Verify-ScheduledTask
    
    # 1. Run Other Non-Admin Tasks (if any)
    # (Currently all tasks are moved to elevated to avoid warnings)
    
    # 2. Check if we need elevation for other tasks
    $NeedsElevation = $false
    if (-not $SkipWinget) { $NeedsElevation = $true }
    if (-not $SkipAdminChocolatey) { $NeedsElevation = $true }
    if (-not $SkipNpm) {
        $NpmPath = Get-Command npm -ErrorAction SilentlyContinue
        if ($NpmPath) {
            $NpmDir = Split-Path (Split-Path $NpmPath.Source -Parent) -Parent
            if ($NpmDir -like "*Program Files*") { $NeedsElevation = $true }
        }
    }

    if ($NeedsElevation) {
        Write-Log "Admin tasks pending. Requesting one-time elevation..." -Level Warning
        
        $RelaunchArgs = @("-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-Elevated")
        if ($SkipWinget) { $RelaunchArgs += "-SkipWinget" }
        if ($SkipAdminChocolatey) { $RelaunchArgs += "-SkipAdminChocolatey" }
        if ($SkipNpm) { $RelaunchArgs += "-SkipNpm" }
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
    if (-not $SkipAdminChocolatey -or -not $SkipUserChocolatey) { Update-Chocolatey }
    if (-not $SkipNpm) { Update-NpmGlobal }
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

<#
.SYNOPSIS
    Sets up Windows Task Scheduler tasks for weekly package updates.
.DESCRIPTION
    Creates a scheduled task to run Update-AllPackages_Win.ps1 every Saturday at 1:00 AM.
    Can also be used to update or remove scheduled tasks and clean up legacy entries.
    The update script covers winget, Windows Store, Chocolatey, npm, WSL apt, and pip.
.PARAMETER Remove
    Remove the scheduled task instead of creating it.
.PARAMETER InstallBurntToast
    Install the BurntToast module for nicer toast notifications.
.EXAMPLE
    .\Setup-PackageUpdateTasks.ps1
    Creates the scheduled task.
.EXAMPLE
    .\Setup-PackageUpdateTasks.ps1 -Remove
    Removes the scheduled task.
#>

param(
    [switch]$Remove,
    [switch]$InstallBurntToast
)

$TaskName = "Weekly Package Updates"
$ScriptDir = $PSScriptRoot
$UpdateScript = Join-Path $ScriptDir "Update-AllPackages_Win.ps1"

function Get-PackageUpdateTasks {
    try {
        @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
            $_.TaskName -eq $TaskName -or
            ($_.Actions | Where-Object {
                $_.Execute -match 'powershell(\.exe)?$' -and
                $_.Arguments -like "*Update-AllPackages_Win.ps1*"
            })
        })
    }
    catch {
        @()
    }
}

function Remove-PackageUpdateTasks {
    param(
        [switch]$SilentIfMissing
    )

    $Tasks = Get-PackageUpdateTasks | Sort-Object TaskPath, TaskName -Unique
    if (-not $Tasks) {
        if (-not $SilentIfMissing) {
            Write-Status "No scheduled package update tasks found" -Level Warning
        }
        return
    }

    foreach ($Task in $Tasks) {
        Write-Status "Removing scheduled task: $($Task.TaskPath)$($Task.TaskName)" -Level Info
        Unregister-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -Confirm:$false
    }
}

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

# ============================================================================
# INSTALL BURNTTOAST (OPTIONAL)
# ============================================================================

if ($InstallBurntToast) {
    Write-Status "Installing BurntToast module for toast notifications..." -Level Info

    try {
        if (Get-Module -ListAvailable -Name BurntToast) {
            Write-Status "BurntToast is already installed" -Level Success
        }
        else {
            Install-Module -Name BurntToast -Scope CurrentUser -Force -AllowClobber
            Write-Status "BurntToast installed successfully" -Level Success
        }
    }
    catch {
        Write-Status "Failed to install BurntToast: $($_.Exception.Message)" -Level Warning
        Write-Status "The script will use native Windows notifications as fallback" -Level Info
    }
}

# ============================================================================
# REMOVE TASK
# ============================================================================

if ($Remove) {
    try {
        Remove-PackageUpdateTasks
        Write-Status "Package update scheduled task cleanup completed" -Level Success
    }
    catch {
        Write-Status "Failed to remove scheduled task: $($_.Exception.Message)" -Level Error
    }

    exit
}

# ============================================================================
# CREATE/UPDATE TASK
# ============================================================================

Write-Status "Setting up scheduled task: $TaskName" -Level Info
Write-Status "Script to run: $UpdateScript" -Level Info

# Verify the update script exists
if (-not (Test-Path $UpdateScript)) {
    Write-Status "Update script not found at: $UpdateScript" -Level Error
    Write-Status "Please ensure Update-AllPackages_Win.ps1 is in the same directory as this script" -Level Error
    exit 1
}

try {
    Remove-PackageUpdateTasks -SilentIfMissing

    # Create the action - run PowerShell with the script
    $Action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -NoExit -File `"$UpdateScript`"" `
        -WorkingDirectory $ScriptDir

    # Create the trigger - every Saturday at 1:00 AM
    $Trigger = New-ScheduledTaskTrigger `
        -Weekly `
        -DaysOfWeek Saturday `
        -At "1:00AM"

    # Create settings
    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable `
        -WakeToRun:$false

    # Create principal - run as current user, interactive (so you can see the window)
    $Principal = New-ScheduledTaskPrincipal `
        -UserId $env:USERNAME `
        -LogonType Interactive `
        -RunLevel Limited

    # Register the task
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $Action `
        -Trigger $Trigger `
        -Settings $Settings `
        -Principal $Principal `
        -Description "Weekly update of winget, Windows Store, Chocolatey, npm, WSL apt, and pip packages. Runs every Saturday at 1:00 AM."

    Write-Status "Scheduled task created successfully!" -Level Success
    Write-Status "" -Level Info
    Write-Status "Task Details:" -Level Info
    Write-Status "  Name: $TaskName" -Level Info
    Write-Status "  Schedule: Every Saturday at 1:00 AM" -Level Info
    Write-Status "  Script: $UpdateScript" -Level Info
    Write-Status "" -Level Info
    Write-Status "To run the update manually, execute:" -Level Info
    Write-Host "  .\Update-AllPackages_Win.ps1" -ForegroundColor White
    Write-Status "" -Level Info
    Write-Status "To remove this scheduled task, run:" -Level Info
    Write-Host "  .\Setup-PackageUpdateTasks.ps1 -Remove" -ForegroundColor White

}
catch {
    Write-Status "Failed to create scheduled task: $($_.Exception.Message)" -Level Error
    Write-Status "" -Level Info
    Write-Status "You may need to run this script as Administrator to create scheduled tasks." -Level Warning
    Write-Status "Try: Start-Process powershell -Verb RunAs -ArgumentList '-File `"$PSCommandPath`"'" -Level Info
}

Write-Host ""
Write-Host "Press Enter to exit..."
Read-Host

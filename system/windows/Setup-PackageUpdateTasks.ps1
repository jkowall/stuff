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
.PARAMETER NoPause
    Do not wait for Enter before the setup script exits.
.PARAMETER RenderOnly
    Print the task definition as JSON without elevation or Task Scheduler changes.
.EXAMPLE
    .\Setup-PackageUpdateTasks.ps1
    Creates the scheduled task.
.EXAMPLE
    .\Setup-PackageUpdateTasks.ps1 -Remove
    Removes the scheduled task.
#>

param(
    [switch]$Remove,
    [switch]$InstallBurntToast,
    [switch]$NoPause,
    [switch]$RenderOnly
)

$TaskName = "Weekly Package Updates"
$ScriptDir = $PSScriptRoot
$UpdateScript = Join-Path $ScriptDir "Update-AllPackages_Win.ps1"
$ScheduledRunKeepOpenMinutes = 720
$SetupExitCode = 0
$TaskUser = if ($env:USERNAME) { $env:USERNAME } elseif ($env:USER) { $env:USER } else { "current-user" }

function Get-PackageUpdateTaskSpec {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,
        [Parameter(Mandatory = $true)]
        [string]$UpdateScript,
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)]
        [string]$UserId,
        [Parameter(Mandatory = $true)]
        [int]$KeepOpenMinutes
    )

    return [ordered]@{
        taskName    = $TaskName
        action      = [ordered]@{
            execute          = "powershell.exe"
            arguments        = "-WindowStyle Normal -NoProfile -ExecutionPolicy Bypass -File `"$UpdateScript`" -NoPause -KeepOpenMinutes $KeepOpenMinutes"
            workingDirectory = $WorkingDirectory
        }
        trigger     = [ordered]@{
            weekly    = $true
            daysOfWeek = @("Saturday")
            at         = "01:00"
        }
        settings    = [ordered]@{
            allowStartIfOnBatteries    = $true
            dontStopIfGoingOnBatteries = $true
            startWhenAvailable         = $true
            runOnlyIfNetworkAvailable  = $true
            multipleInstances          = "IgnoreNew"
            wakeToRun                  = $false
        }
        principal   = [ordered]@{
            userId    = $UserId
            logonType = "Interactive"
            runLevel  = "Highest"
        }
        description = "Weekly update of winget, Windows Store, Chocolatey, npm, WSL apt, and pip packages. Runs every Saturday at 1:00 AM."
    }
}

$TaskSpec = Get-PackageUpdateTaskSpec `
    -TaskName $TaskName `
    -UpdateScript $UpdateScript `
    -WorkingDirectory $ScriptDir `
    -UserId $TaskUser `
    -KeepOpenMinutes $ScheduledRunKeepOpenMinutes

if ($RenderOnly) {
    $TaskSpec | ConvertTo-Json -Depth 5
    exit 0
}

$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Get-PackageUpdateTasks {
    @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
        $_.TaskName -eq $TaskName -or
        ($_.Actions | Where-Object {
            $_.Execute -match 'powershell(\.exe)?$' -and
            $_.Arguments -like "*Update-AllPackages_Win.ps1*"
        })
    })
}

function Remove-PackageUpdateTasks {
    $Tasks = Get-PackageUpdateTasks | Sort-Object TaskPath, TaskName -Unique
    if (-not $Tasks) {
        Write-Status "No scheduled package update tasks found" -Level Warning
        return
    }

    foreach ($Task in $Tasks) {
        Write-Status "Removing scheduled task: $($Task.TaskPath)$($Task.TaskName)" -Level Info
        Unregister-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -Confirm:$false -ErrorAction Stop
    }
}

function Remove-LegacyPackageUpdateTasks {
    $LegacyTasks = Get-PackageUpdateTasks |
        Where-Object { $_.TaskName -ne $TaskName -or $_.TaskPath -ne "\" } |
        Sort-Object TaskPath, TaskName -Unique

    foreach ($Task in $LegacyTasks) {
        Write-Status "Removing legacy scheduled task: $($Task.TaskPath)$($Task.TaskName)" -Level Info
        Unregister-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -Confirm:$false -ErrorAction Stop
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

if (-not $IsAdmin) {
    Write-Status "Administrator privileges are required to manage the elevated scheduled task. Requesting elevation..." -Level Warning

    $RelaunchArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($Remove) { $RelaunchArgs += "-Remove" }
    if ($InstallBurntToast) { $RelaunchArgs += "-InstallBurntToast" }
    if ($NoPause) { $RelaunchArgs += "-NoPause" }

    try {
        $ElevatedProcess = Start-Process "powershell.exe" -ArgumentList $RelaunchArgs -Verb RunAs -Wait -PassThru -ErrorAction Stop
        exit $ElevatedProcess.ExitCode
    }
    catch {
        Write-Status "Elevation was not completed: $($_.Exception.Message)" -Level Error
        exit 1
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
        exit 1
    }

    exit 0
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
    # Create the action - run PowerShell with the script
    $ActionParameters = @{
        Execute          = $TaskSpec.action.execute
        Argument         = $TaskSpec.action.arguments
        WorkingDirectory = $TaskSpec.action.workingDirectory
        ErrorAction      = "Stop"
    }
    $Action = New-ScheduledTaskAction @ActionParameters

    # Create the trigger - every Saturday at 1:00 AM
    $TriggerParameters = @{
        Weekly     = $TaskSpec.trigger.weekly
        DaysOfWeek = $TaskSpec.trigger.daysOfWeek
        At         = $TaskSpec.trigger.at
        ErrorAction = "Stop"
    }
    $Trigger = New-ScheduledTaskTrigger @TriggerParameters

    # Create settings
    $SettingsParameters = @{
        AllowStartIfOnBatteries    = $TaskSpec.settings.allowStartIfOnBatteries
        DontStopIfGoingOnBatteries = $TaskSpec.settings.dontStopIfGoingOnBatteries
        StartWhenAvailable         = $TaskSpec.settings.startWhenAvailable
        RunOnlyIfNetworkAvailable  = $TaskSpec.settings.runOnlyIfNetworkAvailable
        MultipleInstances          = $TaskSpec.settings.multipleInstances
        WakeToRun                  = $TaskSpec.settings.wakeToRun
        ErrorAction                = "Stop"
    }
    $Settings = New-ScheduledTaskSettingsSet @SettingsParameters

    # Create principal - run elevated as current user so scheduled runs do not stall at UAC.
    $PrincipalParameters = @{
        UserId      = $TaskSpec.principal.userId
        LogonType   = $TaskSpec.principal.logonType
        RunLevel    = $TaskSpec.principal.runLevel
        ErrorAction = "Stop"
    }
    $Principal = New-ScheduledTaskPrincipal @PrincipalParameters

    # Register the task
    Register-ScheduledTask `
        -TaskName $TaskSpec.taskName `
        -Action $Action `
        -Trigger $Trigger `
        -Settings $Settings `
        -Principal $Principal `
        -Description $TaskSpec.description `
        -Force `
        -ErrorAction Stop

    Write-Status "Scheduled task created or updated successfully!" -Level Success

    try {
        Remove-LegacyPackageUpdateTasks
    }
    catch {
        Write-Status "The canonical task is installed, but legacy task cleanup failed: $($_.Exception.Message)" -Level Warning
        $SetupExitCode = 2
    }

    Write-Status "" -Level Info
    Write-Status "Task Details:" -Level Info
    Write-Status "  Name: $TaskName" -Level Info
    Write-Status "  Schedule: Every Saturday at 1:00 AM" -Level Info
    Write-Status "  Run level: Highest available privileges" -Level Info
    Write-Status "  Multiple instances: Ignore new starts while a run is active" -Level Info
    Write-Status "  Window: Normal PowerShell window, kept open for $ScheduledRunKeepOpenMinutes minutes after completion" -Level Info
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
    $SetupExitCode = 1
}

if (-not $NoPause) {
    Write-Host ""
    Write-Host "Press Enter to exit..."
    Read-Host
}

exit $SetupExitCode

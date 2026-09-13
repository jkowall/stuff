<#
.SYNOPSIS
    Sets up a Windows Task Scheduler task that keeps chezmoi-managed dotfiles in sync.
.DESCRIPTION
    Creates a task that runs Update-Dotfiles_Win.ps1 every 30 minutes and at logon.
    No elevation is required since chezmoi update only touches the current user's
    profile and its own git repo checkout.
.PARAMETER Remove
    Remove the scheduled task instead of creating it.
.PARAMETER NoPause
    Do not wait for Enter before the setup script exits.
.PARAMETER RenderOnly
    Print the task definition as JSON without touching Task Scheduler.
.EXAMPLE
    .\Setup-DotfileSyncTask_Win.ps1
.EXAMPLE
    .\Setup-DotfileSyncTask_Win.ps1 -Remove
#>

param(
    [switch]$Remove,
    [switch]$NoPause,
    [switch]$RenderOnly
)

$TaskName = "Chezmoi Dotfile Sync"
$ScriptDir = $PSScriptRoot
$UpdateScript = Join-Path $ScriptDir "Update-Dotfiles_Win.ps1"
$TaskUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$RepeatMinutes = 30

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

$TaskSpec = [ordered]@{
    taskName = $TaskName
    action   = [ordered]@{
        execute          = "powershell.exe"
        arguments        = "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$UpdateScript`" -NoPause"
        workingDirectory = $ScriptDir
    }
    triggers = @("Every $RepeatMinutes minutes, indefinitely", "At logon")
    settings = [ordered]@{
        allowStartIfOnBatteries    = $true
        dontStopIfGoingOnBatteries = $true
        startWhenAvailable         = $true
        runOnlyIfNetworkAvailable  = $true
        multipleInstances          = "IgnoreNew"
    }
    principal = [ordered]@{
        userId    = $TaskUser
        logonType = "S4U"
        runLevel  = "Limited"
    }
    description = "Keeps chezmoi-managed dotfiles (Claude/Codex/Antigravity/Cursor config) synced every $RepeatMinutes minutes and at logon."
}

if ($RenderOnly) {
    $TaskSpec | ConvertTo-Json -Depth 6
    exit 0
}

if ($Remove) {
    try {
        $Existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($Existing) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-Status "Removed scheduled task: $TaskName" -Level Success
        }
        else {
            Write-Status "No scheduled task named '$TaskName' found." -Level Warning
        }
    }
    catch {
        Write-Status "Failed to remove scheduled task: $($_.Exception.Message)" -Level Error
        if (-not $NoPause) { Read-Host "Press Enter to exit" }
        exit 1
    }
    if (-not $NoPause) { Read-Host "Press Enter to exit" }
    exit 0
}

if (-not (Test-Path $UpdateScript)) {
    Write-Status "Update script not found at: $UpdateScript" -Level Error
    Write-Status "Ensure Update-Dotfiles_Win.ps1 is in the same directory as this script." -Level Error
    exit 1
}

try {
    $Action = New-ScheduledTaskAction -Execute $TaskSpec.action.execute -Argument $TaskSpec.action.arguments -WorkingDirectory $TaskSpec.action.workingDirectory -ErrorAction Stop

    # Task Scheduler rejects [TimeSpan]::MaxValue (produces an out-of-range ISO8601
    # duration); a 10-year duration is effectively "indefinitely" in practice.
    $RepeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $RepeatMinutes) -RepetitionDuration (New-TimeSpan -Days 3650) -ErrorAction Stop
    $LogonTrigger = New-ScheduledTaskTrigger -AtLogOn -ErrorAction Stop

    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries:$TaskSpec.settings.allowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries:$TaskSpec.settings.dontStopIfGoingOnBatteries `
        -StartWhenAvailable:$TaskSpec.settings.startWhenAvailable `
        -RunOnlyIfNetworkAvailable:$TaskSpec.settings.runOnlyIfNetworkAvailable `
        -MultipleInstances $TaskSpec.settings.multipleInstances `
        -ErrorAction Stop

    $Principal = New-ScheduledTaskPrincipal -UserId $TaskSpec.principal.userId -LogonType $TaskSpec.principal.logonType -RunLevel $TaskSpec.principal.runLevel -ErrorAction Stop

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $Action `
        -Trigger @($RepeatTrigger, $LogonTrigger) `
        -Settings $Settings `
        -Principal $Principal `
        -Description $TaskSpec.description `
        -Force `
        -ErrorAction Stop | Out-Null

    Write-Status "Scheduled task '$TaskName' created or updated." -Level Success
    Write-Status "  Runs: every $RepeatMinutes minutes, and at logon" -Level Info
    Write-Status "  Script: $UpdateScript" -Level Info
    Write-Status "To remove: .\Setup-DotfileSyncTask_Win.ps1 -Remove" -Level Info
}
catch {
    Write-Status "Failed to create scheduled task: $($_.Exception.Message)" -Level Error
    if (-not $NoPause) { Read-Host "Press Enter to exit" }
    exit 1
}

if (-not $NoPause) {
    Write-Host ""
    Write-Host "Press Enter to exit..."
    Read-Host
}

<#
.SYNOPSIS
    Sets up Windows scheduled tasks that keep chezmoi-managed dotfiles in sync.
.DESCRIPTION
    Creates two tasks via schtasks.exe: a recurring one (every 30 minutes) and an
    at-logon one, both running Update-Dotfiles_Win.ps1 as the current user with a
    limited (non-elevated) run level.

    Uses schtasks.exe rather than the ScheduledTasks PowerShell module's
    Register-ScheduledTask/New-ScheduledTaskPrincipal cmdlets: in some restricted
    shell contexts (observed running inside an agentic coding tool's shell), those
    cmdlets fail with "Access is denied" while trying to resolve an explicit
    principal's SID, even for the current user with a Limited run level. schtasks.exe
    (/ru <user> /it) does not hit the same restriction and produces an equivalent
    task. If you don't see this problem in your own normal terminal, either path
    works; schtasks.exe is kept here since it's known to work everywhere.
.PARAMETER Remove
    Remove both scheduled tasks instead of creating them.
.PARAMETER NoPause
    Do not wait for Enter before the setup script exits.
.PARAMETER RenderOnly
    Print the schtasks commands that would run, without touching Task Scheduler.
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
$LogonTaskName = "Chezmoi Dotfile Sync - Logon"
$ScriptDir = $PSScriptRoot
$UpdateScript = Join-Path $ScriptDir "Update-Dotfiles_Win.ps1"
$RepeatMinutes = 30
$RunArg = "powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$UpdateScript`" -NoPause"

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

if ($RenderOnly) {
    Write-Host "schtasks /create /tn `"$TaskName`" /tr `"$RunArg`" /sc minute /mo $RepeatMinutes /ru `"$env:USERNAME`" /it /rl LIMITED /f"
    Write-Host "schtasks /create /tn `"$LogonTaskName`" /tr `"$RunArg`" /sc onlogon /ru `"$env:USERNAME`" /it /rl LIMITED /f"
    exit 0
}

if ($Remove) {
    foreach ($name in @($TaskName, $LogonTaskName)) {
        schtasks /query /tn $name >$null 2>&1
        if ($LASTEXITCODE -eq 0) {
            schtasks /delete /tn $name /f | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Status "Removed scheduled task: $name" -Level Success
            }
            else {
                Write-Status "Failed to remove scheduled task: $name" -Level Error
            }
        }
        else {
            Write-Status "No scheduled task named '$name' found." -Level Warning
        }
    }
    if (-not $NoPause) { Read-Host "Press Enter to exit" }
    exit 0
}

if (-not (Test-Path $UpdateScript)) {
    Write-Status "Update script not found at: $UpdateScript" -Level Error
    Write-Status "Ensure Update-Dotfiles_Win.ps1 is in the same directory as this script." -Level Error
    exit 1
}

$ExitCode = 0

schtasks /create /tn $TaskName /tr $RunArg /sc minute /mo $RepeatMinutes /ru $env:USERNAME /it /rl LIMITED /f | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Status "Scheduled task '$TaskName' created or updated (every $RepeatMinutes minutes)." -Level Success
}
else {
    Write-Status "Failed to create scheduled task '$TaskName' (schtasks exit $LASTEXITCODE)." -Level Error
    $ExitCode = 1
}

schtasks /create /tn $LogonTaskName /tr $RunArg /sc onlogon /ru $env:USERNAME /it /rl LIMITED /f | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Status "Scheduled task '$LogonTaskName' created or updated (at logon)." -Level Success
}
else {
    # Non-fatal: some restricted shell contexts can't register ONLOGON triggers even
    # though the recurring one above works fine. The 30-minute task alone still
    # guarantees sync; the logon trigger is a nice-to-have low-latency top-up.
    Write-Status "Could not create '$LogonTaskName' (schtasks exit $LASTEXITCODE) -- continuing without it. The recurring $RepeatMinutes-minute task above still covers sync." -Level Warning
}

if ($ExitCode -eq 0) {
    Write-Status "Script: $UpdateScript" -Level Info
    Write-Status "To remove: .\Setup-DotfileSyncTask_Win.ps1 -Remove" -Level Info
}

if (-not $NoPause) {
    Write-Host ""
    Write-Host "Press Enter to exit..."
    Read-Host
}

exit $ExitCode

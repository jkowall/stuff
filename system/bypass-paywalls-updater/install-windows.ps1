#requires -Version 5.1
<#
.SYNOPSIS
Install a per-user daily Bypass Paywalls Clean updater outside OneDrive.
.PARAMETER PythonExe
Optional Python 3.9+ executable. Otherwise probe py, python3, then python.
.PARAMETER Uninstall
Remove this user's scheduled task, retaining extension files and backups.
#>
[CmdletBinding()]
param(
    [string]$PythonExe,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try {
    $UserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $TaskName = "Bypass Paywalls Updater-$UserSid"
    $State = Join-Path $env:LOCALAPPDATA 'Bypass Paywalls Updater'
    $Target = Join-Path $State 'extension'
    $Runtime = Join-Path $State 'update.py'
    $Log = Join-Path $State 'updater.log'
    $Existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    if ($Uninstall) {
        if ($Existing) {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
        Write-Host 'Daily updater removed. Extension files and backups retained.'
        exit 0
    }

    # Pin the actual interpreter path, rather than relying on a scheduled PATH
    # or a launcher alias whose selected Python may change between sessions.
    $Candidates = @()
    if ($PythonExe) {
        $Candidates += [pscustomobject]@{ Exe = $PythonExe; Prefix = @() }
    } else {
        foreach ($Name in @('py', 'python3', 'python')) {
            $Command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($Command) {
                $Prefix = @()
                if ($Name -eq 'py') { $Prefix = @('-3') }
                $Candidates += [pscustomobject]@{ Exe = $Command.Source; Prefix = $Prefix }
            }
        }
    }
    $Python = $null
    foreach ($Candidate in $Candidates) {
        try {
            $ProbeArgs = @($Candidate.Prefix) + @('-c',
                'import sys; assert sys.version_info >= (3,9); print(sys.executable)')
            $Probe = & $Candidate.Exe @ProbeArgs 2>$null
            if ($LASTEXITCODE -eq 0 -and $Probe -and
                (Test-Path -LiteralPath ([string]$Probe) -PathType Leaf)) {
                $Python = [string]$Probe
                break
            }
        } catch { continue }
    }
    if (-not $Python) {
        throw 'Python 3.9+ is required. Install from https://www.python.org/downloads/windows/ and rerun, or pass -PythonExe.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\curl.exe'))) {
        throw 'Windows curl.exe is required (included with current Windows 10/11).'
    }

    New-Item -ItemType Directory -Path $State -Force | Out-Null
    if ($Existing) { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'update.py') -Destination $Runtime -Force
    # Bootstrap directly from the maintainer. No synchronized extension files,
    # browser profiles, credentials, or backups are needed from another PC.
    & $Python $Runtime --initialize --extension-dir $Target --state-dir $State --log-file $Log
    if ($LASTEXITCODE -ne 0) { throw "Initial update failed. See $Log" }

    $BackgroundPython = Join-Path (Split-Path -Parent $Python) 'pythonw.exe'
    if (-not (Test-Path -LiteralPath $BackgroundPython -PathType Leaf)) {
        $BackgroundPython = $Python
    }
    $TaskArguments = '"{0}" --extension-dir "{1}" --state-dir "{2}" --log-file "{3}"' -f
        $Runtime, $Target, $State, $Log
    $Action = New-ScheduledTaskAction -Execute $BackgroundPython -Argument $TaskArguments -WorkingDirectory $State
    $Triggers = @(
        New-ScheduledTaskTrigger -Daily -At '09:00'
        New-ScheduledTaskTrigger -AtLogOn -User $UserSid
    )
    $Principal = New-ScheduledTaskPrincipal -UserId $UserSid -LogonType Interactive -RunLevel Limited
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Triggers `
        -Principal $Principal -Settings $Settings `
        -Description 'Update the local unpacked Bypass Paywalls Clean extension daily and at login.' `
        -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Installed task: $TaskName"
    Write-Host 'Checks daily at 09:00 and at login, while this user is logged in.'
    Write-Host "In chrome://extensions, enable Developer mode and load unpacked once: $Target"
    Write-Host "Log: $Log"
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}

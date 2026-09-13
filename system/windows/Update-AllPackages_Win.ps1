<#
.SYNOPSIS
    Weekly package update script for winget, Windows Store, Chocolatey, npm, WSL apt/Claude Code, and pip.
.DESCRIPTION
    Updates all packages from winget, Windows Store, Chocolatey,
    npm global packages, WSL Ubuntu (apt and the native Claude Code installer), and pip global packages.
    Logs all output to a timestamped file and shows toast notifications.
.NOTES
    Author: Auto-generated
#>

#Requires -Version 5.1

param(
    [switch]$SkipAdminChocolatey,
    [switch]$SkipWinget,
    [switch]$SkipWindowsStore,
    [switch]$SkipNpm,
    [switch]$SkipWsl,
    [switch]$SkipPip,
    [switch]$Elevated,
    [switch]$UserWingetOnly,
    [switch]$NoPause,
    [int]$KeepOpenMinutes = 0
)

$CoreScriptPath = Join-Path $PSScriptRoot "Update-AllPackages_Win.Core.ps1"
if (-not (Test-Path $CoreScriptPath)) {
    Write-Error "Required updater core file was not found: $CoreScriptPath"
    exit 1
}
. $CoreScriptPath

# ============================================================================
# CONFIGURATION
# ============================================================================

$RunStartedAt = Get-Date
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$ScriptDir = $PSScriptRoot
$LogDir = Join-Path (Split-Path $ScriptDir -Parent) "logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$ScriptName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$LogScriptName = if ($UserWingetOnly) {
    "${ScriptName}_UserWinget"
}
elseif ($Elevated) {
    "${ScriptName}_Elevated"
}
else {
    $ScriptName
}
$StatusScriptName = if ($UserWingetOnly) { "${ScriptName}_UserWinget" } else { $ScriptName }
$MachineName = $env:COMPUTERNAME
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$LogFile = Join-Path $LogDir "${LogScriptName}_${MachineName}_$Timestamp.log"
$LastRunStatusFile = Join-Path $LogDir "${StatusScriptName}_${MachineName}_last-run.json"

# Track results for summary
$Results = @{
    Execution       = @{ Status = "Skipped"; Message = "" }
    Winget          = @{ Status = "Skipped"; Message = "" }
    SABnzbd         = @{ Status = "Skipped"; Message = "" }
    WindowsStore    = @{ Status = "Skipped"; Message = "" }
    ChocolateyAdmin = @{ Status = "Skipped"; Message = "" }
    Npm             = @{ Status = "Skipped"; Message = "" }
    Wsl             = @{ Status = "Skipped"; Message = "" }
    WslClaude       = @{ Status = "Skipped"; Message = "" }
    Pip             = @{ Status = "Skipped"; Message = "" }
}
$FinalExitCode = 0
$UpdateMutexName = "Global\Stuff.UpdateAllPackages.Win"
$WingetLockPath = Join-Path $LogDir "Update-AllPackages_Win_Winget.lock"
$SabnzbdRestartMarkerPrefix = "Update-AllPackages_Win_RestartSABnzbd_"
$SabnzbdStagingRoot = Join-Path `
    ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) `
    "Stuff.UpdateAllPackages.Staging"
$SabnzbdLatestReleaseApi = "https://api.github.com/repos/sabnzbd/sabnzbd/releases/latest"
$UserWingetTaskName = "Weekly Package Updates - User Winget"
$UserWingetTaskPath = "\"
$script:UserWingetTaskMayBeRunning = $false

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
        $WingetCommand = Get-Command winget -ErrorAction SilentlyContinue
    }

    if ($WingetCommand) {
        return $WingetCommand
    }

    $WindowsAppsWinget = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
    if (Test-Path $WindowsAppsWinget) {
        return [pscustomobject]@{ Source = $WindowsAppsWinget }
    }

    $AppInstaller = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue
    if ($AppInstaller) {
        $PackagedWinget = Join-Path $AppInstaller.InstallLocation "winget.exe"
        if (Test-Path $PackagedWinget) {
            return [pscustomobject]@{ Source = $PackagedWinget }
        }
    }

    throw "winget was not found in PATH, WindowsApps, or the Desktop App Installer package."
}

function Get-NpmCommand {
    $NpmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $NpmCommand) {
        $NpmCommand = Get-Command npm -ErrorAction Stop
    }

    return $NpmCommand
}

function Get-WingetUpgradeIds {
    param(
        [Parameter(Mandatory = $true)]
        $WingetPath,
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [string[]]$ExcludePackageIds = @()
    )

    Write-Log "Checking for remaining $Source upgrades..." -Level Info
    $Output = & $WingetPath.Source upgrade --source $Source --include-unknown --accept-source-agreements 2>&1
    $QueryExitCode = $LASTEXITCODE

    foreach ($Line in $Output) {
        $Text = "$Line".Trim()
        if ([string]::IsNullOrWhiteSpace($Text)) { continue }
        Write-Log $Text -Level Info
    }

    if ($QueryExitCode -ne $null -and (Test-WingetNoApplicableExitCode -ExitCode $QueryExitCode)) {
        Write-Log "No applicable $Source upgrades remain. Exit code: $QueryExitCode" -Level Info
        return @()
    }
    if ($QueryExitCode -ne 0 -and $QueryExitCode -ne $null) {
        throw "winget upgrade discovery for source '$Source' failed with exit code: $QueryExitCode"
    }

    return @(ConvertFrom-WingetUpgradeOutput -Output @($Output) -Source $Source -ExcludePackageIds $ExcludePackageIds)
}

function Get-WingetPackageServiceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    $ServiceName = switch ($PackageId) {
        "Cloudflare.cloudflared" { "cloudflared" }
        default { $null }
    }

    if (-not $ServiceName) { return $null }

    $Service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $Service) { return $null }

    return [pscustomobject]@{
        Name       = $Service.Name
        WasRunning = ("$($Service.Status)" -eq "Running")
    }
}

function Start-ServiceWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [timespan]$Timeout = ([timespan]::FromSeconds(30)),
        [int]$RetryCount = 3,
        [timespan]$RetryDelay = ([timespan]::FromSeconds(5))
    )

    $Service = Get-Service -Name $Name -ErrorAction Stop
    if ("$($Service.Status)" -eq "Running") { return "Running" }

    # A freshly-installed/upgraded binary is sometimes still locked for a
    # moment (e.g. by antivirus scanning or the outgoing process exiting), so
    # Start-Service can fail transiently right after setup reports success.
    # Retry briefly before giving up.
    $LastError = $null
    for ($Attempt = 1; $Attempt -le $RetryCount; $Attempt++) {
        try {
            Start-Service -Name $Name -ErrorAction Stop
            $Service = Get-Service -Name $Name -ErrorAction Stop
            $Service.WaitForStatus("Running", $Timeout)
            $Service.Refresh()

            if ("$($Service.Status)" -ne "Running") {
                throw "Service '$Name' did not reach the Running state within $([int]$Timeout.TotalSeconds) seconds."
            }

            return "Restored"
        }
        catch {
            $LastError = $_
            if ($Attempt -lt $RetryCount) {
                Write-Log "Attempt $Attempt of $RetryCount to start service '$Name' failed: $($_.Exception.Message). Retrying in $([int]$RetryDelay.TotalSeconds)s." -Level Warning
                Start-Sleep -Seconds $RetryDelay.TotalSeconds
            }
        }
    }

    throw $LastError
}

function Restore-WingetPackageServiceState {
    [CmdletBinding()]
    param(
        $ServiceState,
        [timespan]$Timeout = ([timespan]::FromSeconds(30)),
        [int]$RetryCount = 3,
        [timespan]$RetryDelay = ([timespan]::FromSeconds(5))
    )

    if (-not $ServiceState -or -not $ServiceState.WasRunning) { return "Skipped" }

    return Start-ServiceWithRetry -Name $ServiceState.Name -Timeout $Timeout -RetryCount $RetryCount -RetryDelay $RetryDelay
}

function Test-UserWingetScheduledTaskDefinition {
    param(
        [Parameter(Mandatory = $true)]
        $Task,
        [Parameter(Mandatory = $true)]
        [string]$TaskName,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedScriptPath
    )

    if ("$($Task.State)" -eq "Disabled") {
        throw "Scheduled task '$TaskName' is disabled. Run Setup-PackageUpdateTasks.ps1 to repair it."
    }
    if ("$($Task.Principal.RunLevel)" -ne "Limited") {
        throw "Scheduled task '$TaskName' is not configured to run with limited privileges. Run Setup-PackageUpdateTasks.ps1 to repair it."
    }
    if ("$($Task.Principal.LogonType)" -ne "Interactive") {
        throw "Scheduled task '$TaskName' is not configured for the interactive user. Run Setup-PackageUpdateTasks.ps1 to repair it."
    }

    $CurrentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $TaskAccount = New-Object System.Security.Principal.NTAccount("$($Task.Principal.UserId)")
    $TaskUserSid = $TaskAccount.Translate([Security.Principal.SecurityIdentifier]).Value
    if ($TaskUserSid -ne $CurrentUserSid) {
        throw "Scheduled task '$TaskName' belongs to a different user. Run Setup-PackageUpdateTasks.ps1 to repair it."
    }

    $Actions = @($Task.Actions)
    $ExpectedScriptFullPath = [System.IO.Path]::GetFullPath($ExpectedScriptPath)
    $ActionIsValid = $Actions.Count -eq 1 -and
        "$($Actions[0].Execute)" -match '(?i)(^|\\)powershell(?:\.exe)?$' -and
        "$($Actions[0].Arguments)" -like '*-UserWingetOnly*' -and
        "$($Actions[0].Arguments)".IndexOf($ExpectedScriptFullPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    if (-not $ActionIsValid) {
        throw "Scheduled task '$TaskName' does not contain the expected user-context updater action. Run Setup-PackageUpdateTasks.ps1 to repair it."
    }

    return $true
}

function Invoke-UserWingetScheduledUpdate {
    [CmdletBinding()]
    param(
        [string]$TaskName = $script:UserWingetTaskName,
        [string]$TaskPath = $script:UserWingetTaskPath,
        [string]$ExpectedScriptPath = $PSCommandPath,
        [timespan]$Timeout = ([timespan]::FromMinutes(10)),
        [ValidateRange(1, 60000)]
        [int]$PollIntervalMilliseconds = 500
    )

    $Tasks = @(Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop)
    if ($Tasks.Count -ne 1) {
        throw "Expected exactly one scheduled task at '$TaskPath$TaskName', but found $($Tasks.Count)."
    }
    $Task = $Tasks[0]
    $script:UserWingetTaskMayBeRunning = @("Queued", "Running") -contains "$($Task.State)"

    try {
        $null = Test-UserWingetScheduledTaskDefinition `
            -Task $Task `
            -TaskName $TaskName `
            -ExpectedScriptPath $ExpectedScriptPath

        $PreviousInfo = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
        $CurrentTasks = @(Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop)
        if ($CurrentTasks.Count -ne 1) {
            throw "Expected exactly one scheduled task at '$TaskPath$TaskName', but found $($CurrentTasks.Count)."
        }
        $Task = $CurrentTasks[0]
        $WasAlreadyRunning = ("$($Task.State)" -eq "Running")
        $WasAlreadyActive = @("Queued", "Running") -contains "$($Task.State)"
        $script:UserWingetTaskMayBeRunning = $true
        if (-not $WasAlreadyActive) {
            Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
        }

        $Deadline = [datetime]::UtcNow.Add($Timeout)
        while ($true) {
            if ([datetime]::UtcNow -ge $Deadline) {
                $TimeoutMessage = "Timed out after $([int]$Timeout.TotalSeconds) seconds waiting for scheduled task '$TaskName'."
                try {
                    Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
                }
                catch {
                    $TimeoutMessage += " Stop failed: $($_.Exception.Message)"
                }

                $StopDeadline = [datetime]::UtcNow.AddSeconds(30)
                do {
                    $Task = @(Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop)[0]
                    $TaskIsActive = @("Queued", "Running") -contains "$($Task.State)"
                    if (-not $TaskIsActive) { break }
                    Start-Sleep -Milliseconds $PollIntervalMilliseconds
                } while ([datetime]::UtcNow -lt $StopDeadline)

                if ($TaskIsActive) {
                    throw "$TimeoutMessage The task could not be confirmed stopped; aborting further WinGet work."
                }

                $script:UserWingetTaskMayBeRunning = $false
                throw $TimeoutMessage
            }

            Start-Sleep -Milliseconds $PollIntervalMilliseconds
            $CurrentInfo = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
            $Task = @(Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop)[0]
            $RunWasObserved = $WasAlreadyRunning -or ($CurrentInfo.LastRunTime -gt $PreviousInfo.LastRunTime)
            $TaskIsActive = @("Queued", "Running") -contains "$($Task.State)"
            if (-not $RunWasObserved -or $TaskIsActive -or [int64]$CurrentInfo.LastTaskResult -eq 267009) {
                continue
            }

            # Confirm the terminal state once more so a delayed task start cannot be
            # mistaken for completion while Task Scheduler still reports Ready.
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
            $ConfirmedInfo = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
            $ConfirmedTask = @(Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop)[0]
            $ConfirmedTaskIsActive = @("Queued", "Running") -contains "$($ConfirmedTask.State)"
            $ConfirmedRunMatches = $WasAlreadyRunning -or ($ConfirmedInfo.LastRunTime -ge $CurrentInfo.LastRunTime)
            if ($ConfirmedRunMatches -and -not $ConfirmedTaskIsActive -and [int64]$ConfirmedInfo.LastTaskResult -ne 267009) {
                $script:UserWingetTaskMayBeRunning = $false
                return [int64]$ConfirmedInfo.LastTaskResult
            }
        }
    }
    catch {
        $OriginalError = $_
        try {
            $CurrentTasks = @(Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop)
            $script:UserWingetTaskMayBeRunning = if ($CurrentTasks.Count -eq 1) {
                @("Queued", "Running") -contains "$($CurrentTasks[0].State)"
            }
            else {
                $CurrentTasks.Count -gt 1
            }
        }
        catch {
            $script:UserWingetTaskMayBeRunning = $true
        }
        throw $OriginalError
    }
}

function Invoke-WingetExplicitUpgrades {
    param(
        [Parameter(Mandatory = $true)]
        $WingetPath,
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [string[]]$PackageIds = @()
    )

    $Succeeded = 0
    $Failed = New-Object System.Collections.Generic.List[string]
    $NoLongerApplicable = New-Object System.Collections.Generic.List[string]

    foreach ($PackageId in ($PackageIds | Where-Object { $_ } | Select-Object -Unique)) {
        $ServiceState = Get-WingetPackageServiceState -PackageId $PackageId
        if ($ServiceState -and $ServiceState.WasRunning) {
            Write-Log "Preserving the running state of service '$($ServiceState.Name)' during the $PackageId upgrade." -Level Info
        }

        Write-Log "Running: winget upgrade --id $PackageId -e --source $Source --include-unknown --accept-package-agreements --accept-source-agreements" -Level Info
        & $WingetPath.Source upgrade --id $PackageId -e --source $Source --include-unknown --accept-package-agreements --accept-source-agreements
        $WingetExitCode = $LASTEXITCODE

        $ServiceRestoreFailure = $null
        try {
            $ServiceRestoreResult = Restore-WingetPackageServiceState -ServiceState $ServiceState
            if ($ServiceRestoreResult -eq "Restored") {
                Write-Log "Restored service '$($ServiceState.Name)' after the $PackageId upgrade." -Level Success
            }
            elseif ($ServiceRestoreResult -eq "Running") {
                Write-Log "Service '$($ServiceState.Name)' remained running after the $PackageId upgrade." -Level Info
            }
        }
        catch {
            $ServiceRestoreFailure = $_.Exception.Message
            Write-Log "Could not restore service '$($ServiceState.Name)' after the $PackageId upgrade: $ServiceRestoreFailure" -Level Error
        }

        if ($ServiceRestoreFailure) {
            $Failed.Add($PackageId)
            Write-Log "Explicit upgrade for $PackageId returned exit code '$WingetExitCode', but its pre-upgrade service state was not restored." -Level Warning
        }
        elseif ($WingetExitCode -eq 0 -or $WingetExitCode -eq $null) {
            $Succeeded++
            Write-Log "Explicit upgrade completed for $PackageId" -Level Success
        }
        elseif ($WingetExitCode -ne $null -and (Test-WingetNoApplicableExitCode -ExitCode $WingetExitCode)) {
            $NoLongerApplicable.Add($PackageId)
            Write-Log "No applicable upgrade remains for $PackageId; continuing. Exit code: $WingetExitCode" -Level Info
        }
        else {
            $Failed.Add($PackageId)
            if ($PackageId -eq "Spotify.Spotify" -and $WingetExitCode -eq -1978335146) {
                Write-Log "Explicit upgrade could not update $PackageId because its installer prohibits elevation; update it from a normal user session. Exit code: $WingetExitCode" -Level Warning
            }
            else {
                Write-Log "Explicit upgrade failed for $PackageId with exit code: $WingetExitCode" -Level Warning
            }
        }
    }

    return [pscustomobject]@{
        Succeeded = $Succeeded
        Failed    = @($Failed)
        NoLongerApplicable = @($NoLongerApplicable)
    }
}

function Initialize-SabnzbdStagingRoot {
    if (-not $IsAdmin) {
        throw "SABnzbd's protected staging directory requires administrator privileges."
    }

    $ProgramFilesPath = [System.IO.Path]::GetFullPath(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    ).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $FullStagingRoot = [System.IO.Path]::GetFullPath($SabnzbdStagingRoot)
    if (-not $FullStagingRoot.StartsWith(
            $ProgramFilesPath + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Refusing to use an unprotected SABnzbd staging path: $FullStagingRoot"
    }

    $ProgramFilesItem = Get-Item -LiteralPath $ProgramFilesPath -Force -ErrorAction Stop
    if (($ProgramFilesItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to stage beneath a reparse-point Program Files directory."
    }

    if ([System.IO.Directory]::Exists($FullStagingRoot)) {
        $StagingRootItem = Get-Item -LiteralPath $FullStagingRoot -Force -ErrorAction Stop
        if (($StagingRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The SABnzbd staging root must not be a reparse point."
        }
    }
    else {
        [System.IO.Directory]::CreateDirectory($FullStagingRoot) | Out-Null
    }

    # Protect this persistent root from the normal-user side of the updater.
    # It lives directly beneath Program Files so an unelevated process cannot
    # pre-create or swap it before these explicit rules are applied.
    $AdministratorsSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    $SystemSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18")
    $InheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $Security = [System.Security.AccessControl.DirectorySecurity]::new()
    $Security.SetAccessRuleProtection($true, $false)
    foreach ($Sid in @($AdministratorsSid, $SystemSid)) {
        $Security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $Sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                $InheritanceFlags,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            ))
    }
    $Security.SetOwner($AdministratorsSid)
    Set-Acl -LiteralPath $FullStagingRoot -AclObject $Security -ErrorAction Stop

    $ProtectedAcl = Get-Acl -LiteralPath $FullStagingRoot -ErrorAction Stop
    $StagingRootItem = Get-Item -LiteralPath $FullStagingRoot -Force -ErrorAction Stop
    if (-not $ProtectedAcl.AreAccessRulesProtected -or
        ($StagingRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Could not verify the protected SABnzbd staging root."
    }

    return $FullStagingRoot
}

function Get-SabnzbdInstallation {
    $UninstallKeyPaths = @(
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\SABnzbd",
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\SABnzbd"
    )
    $Entries = @(
        foreach ($KeyPath in $UninstallKeyPaths) {
            if (-not (Test-Path -LiteralPath $KeyPath)) { continue }
            $Entry = Get-ItemProperty -LiteralPath $KeyPath -ErrorAction Stop
            if ("$($Entry.Publisher)" -cne "The SABnzbd-Team" -or "$($Entry.DisplayName)" -notlike "SABnzbd *") {
                throw "The SABnzbd uninstall entry had unexpected publisher or product metadata: $KeyPath"
            }
            $Entry
        }
    )

    if ($Entries.Count -eq 0) { return $null }
    if ($Entries.Count -ne 1) {
        throw "Expected one machine-wide SABnzbd installation, but found $($Entries.Count)."
    }

    $VersionText = "$($Entries[0].DisplayVersion)"
    if ($VersionText -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
        throw "Unsupported installed SABnzbd version: $VersionText"
    }

    $InstallDirectories = New-Object System.Collections.Generic.List[string]
    foreach ($KeyPath in @(
            "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\SABnzbd",
            "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\SABnzbd"
        )) {
        if (Test-Path -LiteralPath $KeyPath) {
            $InstallDirectory = "$( (Get-Item -LiteralPath $KeyPath -ErrorAction Stop).GetValue('') )".Trim()
            if ($InstallDirectory) { $InstallDirectories.Add($InstallDirectory) }
        }
    }

    $UninstallString = "$($Entries[0].UninstallString)"
    if ($UninstallString -match '^"([^"]+)"') {
        $InstallDirectories.Add((Split-Path -Parent $Matches[1]))
    }
    elseif ($UninstallString) {
        $InstallDirectories.Add((Split-Path -Parent ($UninstallString -split '\s+')[0]))
    }
    if ($env:ProgramFiles) {
        $InstallDirectories.Add((Join-Path $env:ProgramFiles "SABnzbd"))
    }

    $ExecutablePaths = @(
        $InstallDirectories |
            Where-Object { $_ } |
            ForEach-Object { Join-Path $_ "SABnzbd.exe" } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            ForEach-Object { [System.IO.Path]::GetFullPath($_) } |
            Sort-Object -Unique
    )
    if ($ExecutablePaths.Count -ne 1) {
        throw "Expected one installed SABnzbd executable, but found $($ExecutablePaths.Count)."
    }

    return [pscustomobject]@{
        Version        = [version]$VersionText
        VersionText    = $VersionText
        ExecutablePath = $ExecutablePaths[0]
    }
}

function Confirm-SabnzbdFileAtPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedVersion
    )

    $Item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    $null = Confirm-SabnzbdSignedFileMetadata `
        -SignatureStatus "$($Signature.Status)" `
        -SignerSubject "$($Signature.SignerCertificate.Subject)" `
        -CompanyName "$($Item.VersionInfo.CompanyName)" `
        -ProductName "$($Item.VersionInfo.ProductName)" `
        -ProductVersion "$($Item.VersionInfo.ProductVersion)" `
        -ExpectedVersion $ExpectedVersion
    return $Item
}

function Get-SabnzbdProcessesAtPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath
    )

    $ExpectedPath = [System.IO.Path]::GetFullPath($ExecutablePath)
    return @(
        foreach ($Process in @(Get-Process -Name "SABnzbd" -ErrorAction SilentlyContinue)) {
            try {
                if ($Process.Path -and
                    [System.IO.Path]::GetFullPath($Process.Path).Equals(
                        $ExpectedPath,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )) {
                    $Process
                }
            }
            catch {
                # Ignore inaccessible or already-exited processes.
            }
        }
    )
}

function Restore-SabnzbdUserProcessIfRequested {
    $MarkerNamePattern = "^{0}[0-9a-f]{{32}}\.marker$" -f [regex]::Escape($SabnzbdRestartMarkerPrefix)
    $RestartMarkers = @(Get-ChildItem `
            -LiteralPath $LogDir `
            -Filter "${SabnzbdRestartMarkerPrefix}*.marker" `
            -File `
            -Force `
            -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -cmatch $MarkerNamePattern -and
                ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0
            })
    if ($RestartMarkers.Count -eq 0) { return }

    try {
        if ($IsAdmin) {
            throw "SABnzbd desktop restart must run without administrator privileges."
        }

        $Installation = Get-SabnzbdInstallation
        if (-not $Installation) {
            throw "SABnzbd is not installed."
        }
        $null = Confirm-SabnzbdFileAtPath `
            -Path $Installation.ExecutablePath `
            -ExpectedVersion $Installation.VersionText

        $MatchingProcesses = @(Get-SabnzbdProcessesAtPath -ExecutablePath $Installation.ExecutablePath)
        if ($MatchingProcesses.Count -eq 0) {
            Write-Log "Restoring the SABnzbd desktop process as the limited interactive user." -Level Info
            $StartedProcess = Start-Process `
                -FilePath $Installation.ExecutablePath `
                -WorkingDirectory (Split-Path -Parent $Installation.ExecutablePath) `
                -PassThru `
                -ErrorAction Stop

            $StartDeadline = [datetime]::UtcNow.AddSeconds(30)
            do {
                Start-Sleep -Milliseconds 500
                $MatchingProcesses = @(Get-SabnzbdProcessesAtPath -ExecutablePath $Installation.ExecutablePath |
                        Where-Object { $_.Id -eq $StartedProcess.Id })
            } while ($MatchingProcesses.Count -eq 0 -and [datetime]::UtcNow -lt $StartDeadline)
            if ($MatchingProcesses.Count -eq 0) {
                throw "SABnzbd did not restart within 30 seconds."
            }
        }

        foreach ($Marker in $RestartMarkers) {
            [System.IO.File]::Delete($Marker.FullName)
        }
        $script:Results.SABnzbd.Status = "Success"
        $script:Results.SABnzbd.Message = "SABnzbd desktop process is running as the limited interactive user"
        Write-Log $script:Results.SABnzbd.Message -Level Success
    }
    catch {
        $script:Results.SABnzbd.Status = "Error"
        $script:Results.SABnzbd.Message = "Could not restore SABnzbd desktop process: $($_.Exception.Message)"
        Write-Log $script:Results.SABnzbd.Message -Level Error
    }
}

function Restore-SabnzbdUserProcessWithPackageLock {
    $RecoveryLock = $null
    try {
        $RecoveryLock = Enter-PackageUpdateFileLock -Path $WingetLockPath
        Restore-SabnzbdUserProcessIfRequested
    }
    catch {
        $script:Results.SABnzbd.Status = "Error"
        $script:Results.SABnzbd.Message = "Could not enter the package lock for SABnzbd recovery: $($_.Exception.Message)"
        Write-Log $script:Results.SABnzbd.Message -Level Error
    }
    finally {
        if ($RecoveryLock) {
            $RecoveryLock.Dispose()
        }
    }
}

function Update-UserContextWinget {
    Write-Log ("=" * 60) -Level Info
    Write-Log "STARTING USER-CONTEXT WINGET UPDATES" -Level Info
    Write-Log ("=" * 60) -Level Info

    $WingetLock = $null
    try {
        if ($IsAdmin) {
            throw "User-context Winget updates must not run with administrator privileges."
        }

        Restore-SabnzbdUserProcessWithPackageLock
        $WingetPath = Get-WingetCommand
        Write-Log "Found winget at: $($WingetPath.Source)" -Level Info
        $PackageIds = @(Get-UserContextWingetPackageIds)
        $WingetLock = Enter-PackageUpdateFileLock -Path $WingetLockPath
        Write-Log "Acquired exclusive WinGet lock: $WingetLockPath" -Level Info
        $ExplicitResult = Invoke-WingetExplicitUpgrades -WingetPath $WingetPath -Source "winget" -PackageIds $PackageIds

        if ($ExplicitResult.Failed.Count -gt 0) {
            $script:Results.Winget.Status = "Warning"
            $script:Results.Winget.Message = "User-context Winget updates failed: $($ExplicitResult.Failed -join ', ')"
        }
        else {
            $script:Results.Winget.Status = "Success"
            $script:Results.Winget.Message = "User-context Winget packages checked successfully: $($PackageIds -join ', ')"
        }
    }
    catch {
        $script:Results.Winget.Status = "Error"
        $script:Results.Winget.Message = $_.Exception.Message
        Write-Log "User-context Winget update failed: $($_.Exception.Message)" -Level Error
    }
    finally {
        if ($WingetLock) {
            $WingetLock.Dispose()
        }
    }
}

function Update-Winget {
    Write-Log ("=" * 60) -Level Info
    Write-Log "STARTING WINGET UPDATES" -Level Info
    Write-Log ("=" * 60) -Level Info

    try {
        # Check if winget is available
        $WingetPath = Get-WingetCommand
        Write-Log "Found winget at: $($WingetPath.Source)" -Level Info

        # iCUE currently requires a firmware update before its package upgrade can complete.
        $WingetExcludeIds = @("Corsair.iCUE.5")

        $DiscoveryLock = Enter-PackageUpdateFileLock -Path $WingetLockPath
        Write-Log "Acquired exclusive WinGet lock for discovery: $WingetLockPath" -Level Info
        try {
            # Pin packages with broken version detection so they don't re-upgrade every run
            $WingetPins = @("Syncthing.Syncthing", "BillStewart.SyncthingWindowsSetup")
            foreach ($Pin in $WingetPins) {
                $PinExists = & $WingetPath.Source pin list | Select-String -Quiet -SimpleMatch $Pin
                if (-not $PinExists) {
                    Write-Log "Pinning $Pin (broken version detection)" -Level Info
                    & $WingetPath.Source pin add --id $Pin -e --blocking 2>&1 | Out-Null
                }
            }

            # Explicit targeting lets us skip packages that need manual intervention.
            # PowerShell also commonly needs explicit handling due to MSI detection issues.
            $ExplicitIds = Get-WingetUpgradeIds -WingetPath $WingetPath -Source "winget" -ExcludePackageIds $WingetExcludeIds
            $ExecutionPlan = Split-WingetUpgradeIdsByContext -PackageIds $ExplicitIds
        }
        finally {
            $DiscoveryLock.Dispose()
        }

        $UserContextFailed = New-Object System.Collections.Generic.List[string]
        $UserContextSucceeded = 0
        if ($ExecutionPlan.UserContext.Count -gt 0) {
            Write-Log "Routing user-only Winget packages to the limited scheduled task: $($ExecutionPlan.UserContext -join ', ')" -Level Info
            try {
                $UserTaskExitCode = Invoke-UserWingetScheduledUpdate
                if ($UserTaskExitCode -eq 0) {
                    $UserContextSucceeded = $ExecutionPlan.UserContext.Count
                    Write-Log "User-context Winget task completed successfully." -Level Success
                }
                else {
                    foreach ($PackageId in $ExecutionPlan.UserContext) { $UserContextFailed.Add($PackageId) }
                    Write-Log "User-context Winget task completed with exit code: $UserTaskExitCode" -Level Warning
                }
            }
            catch {
                if ($script:UserWingetTaskMayBeRunning) {
                    throw "The user-context Winget task may still be active; stopping the elevated Winget phase to avoid concurrent package operations. $($_.Exception.Message)"
                }
                foreach ($PackageId in $ExecutionPlan.UserContext) { $UserContextFailed.Add($PackageId) }
                Write-Log "Could not complete user-context Winget updates: $($_.Exception.Message)" -Level Warning
            }
        }

        $UpgradeLock = Enter-PackageUpdateFileLock -Path $WingetLockPath
        Write-Log "Acquired exclusive WinGet lock for elevated upgrades: $WingetLockPath" -Level Info
        try {
            $ExplicitResult = Invoke-WingetExplicitUpgrades -WingetPath $WingetPath -Source "winget" -PackageIds $ExecutionPlan.Elevated
        }
        finally {
            $UpgradeLock.Dispose()
        }
        $Succeeded = $ExplicitResult.Succeeded + $UserContextSucceeded
        $FailedCandidates = @($ExplicitResult.Failed) + @($UserContextFailed)
        [string[]]$Failed = @($FailedCandidates | Where-Object { $_ })

        if ($Failed.Count -eq 0) {
            $script:Results.Winget.Status = "Success"
            if ($Succeeded -gt 0) {
                $script:Results.Winget.Message = "Winget packages updated successfully ($Succeeded upgrades; skipped: $($WingetExcludeIds -join ', '))"
            }
            else {
                $script:Results.Winget.Message = "Winget packages updated successfully (skipped: $($WingetExcludeIds -join ', '))"
            }
        }
        else {
            $script:Results.Winget.Status = "Warning"
            if ($Failed.Count -gt 0) {
                $script:Results.Winget.Message = "Winget completed with issues; packages requiring attention: $($Failed -join ', ')"
            }
            else {
                $script:Results.Winget.Message = "Winget completed with issues"
            }
        }
    }
    catch {
        $script:Results.Winget.Status = "Error"
        $script:Results.Winget.Message = $_.Exception.Message
        Write-Log "Winget update failed: $($_.Exception.Message)" -Level Error
        Show-ToastNotification -Title "Winget Update Failed" -Message $_.Exception.Message -Type Error
    }
}

function Update-SabnzbdFromOfficialRelease {
    Write-Log ("=" * 60) -Level Info
    Write-Log "CHECKING OFFICIAL SABNZBD RELEASE" -Level Info
    Write-Log ("=" * 60) -Level Info

    $TemporaryDirectory = $null
    $InstallerPath = $null
    $InstallerGuard = $null
    $WingetLock = $null
    $UpdateFailure = $null
    $RuntimeRestoreFailure = $null
    $UpdatePerformed = $false
    $InstalledAfter = $null
    $ServiceWasRunning = $false
    $DesktopWasRunning = $false
    $RestartMarkerCreated = $false
    $RestartMarkerPath = $null

    try {
        if (-not $IsAdmin) {
            throw "The official SABnzbd machine installer requires administrator privileges."
        }

        $Installation = Get-SabnzbdInstallation
        if (-not $Installation) {
            $script:Results.SABnzbd.Status = "Skipped"
            $script:Results.SABnzbd.Message = "SABnzbd is not installed"
            Write-Log $script:Results.SABnzbd.Message -Level Info
            return
        }
        $null = Confirm-SabnzbdFileAtPath `
            -Path $Installation.ExecutablePath `
            -ExpectedVersion $Installation.VersionText

        $Headers = @{
            "Accept"               = "application/vnd.github+json"
            "User-Agent"           = "Update-AllPackages-Win"
            "X-GitHub-Api-Version" = "2022-11-28"
        }
        Write-Log "Checking SABnzbd's official stable release metadata." -Level Info
        $Release = Invoke-RestMethod `
            -Uri $SabnzbdLatestReleaseApi `
            -Headers $Headers `
            -TimeoutSec 30 `
            -ErrorAction Stop
        $Plan = Get-SabnzbdOfficialUpdatePlan `
            -InstalledVersion $Installation.VersionText `
            -Release $Release
        Write-Log "SABnzbd versions: installed=$($Installation.VersionText) official=$($Plan.TargetVersionText)" -Level Info

        if (-not $Plan.NeedsUpdate) {
            $script:Results.SABnzbd.Status = "Success"
            $script:Results.SABnzbd.Message = "SABnzbd $($Installation.VersionText) is current with the official stable release"
            Write-Log $script:Results.SABnzbd.Message -Level Success
            return
        }

        $ProtectedStagingRoot = Initialize-SabnzbdStagingRoot
        $TemporaryDirectory = Join-Path `
            $ProtectedStagingRoot `
            ("Update-AllPackages_Win_SABnzbd_{0}_{1}" -f $PID, [guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($TemporaryDirectory) | Out-Null
        $StagingItem = Get-Item -LiteralPath $TemporaryDirectory -Force -ErrorAction Stop
        if (($StagingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The SABnzbd per-run staging directory must not be a reparse point."
        }
        $InstallerPath = Join-Path $TemporaryDirectory $Plan.AssetName

        Write-Log "Downloading the signed SABnzbd $($Plan.TargetVersionText) installer from the official GitHub release." -Level Info
        Invoke-WebRequest `
            -Uri $Plan.DownloadUrl `
            -Headers @{ "User-Agent" = "Update-AllPackages-Win" } `
            -OutFile $InstallerPath `
            -UseBasicParsing `
            -TimeoutSec 180 `
            -ErrorAction Stop
        $DownloadedSize = (Get-Item -LiteralPath $InstallerPath -ErrorAction Stop).Length
        if ($DownloadedSize -ne $Plan.Size) {
            throw "Downloaded SABnzbd installer size was $DownloadedSize bytes, expected $($Plan.Size)."
        }

        $WingetLock = Enter-PackageUpdateFileLock -Path $WingetLockPath
        Write-Log "Acquired exclusive package lock for the SABnzbd installer: $WingetLockPath" -Level Info

        # A newly published WinGet upgrade may have completed while the official
        # installer downloaded. Re-check under the shared package lock.
        $Installation = Get-SabnzbdInstallation
        if (-not $Installation) {
            throw "SABnzbd disappeared before the official update could start."
        }
        if ($Installation.Version -ge $Plan.TargetVersion) {
            $script:Results.SABnzbd.Status = "Success"
            $script:Results.SABnzbd.Message = "SABnzbd $($Installation.VersionText) became current before the official fallback ran"
            Write-Log $script:Results.SABnzbd.Message -Level Success
            return
        }

        $SabnzbdService = Get-Service -Name "SABnzbd" -ErrorAction SilentlyContinue
        $ServiceWasRunning = $SabnzbdService -and "$($SabnzbdService.Status)" -eq "Running"
        $DesktopWasRunning = -not $ServiceWasRunning -and
            @(Get-SabnzbdProcessesAtPath -ExecutablePath $Installation.ExecutablePath).Count -gt 0

        if ($DesktopWasRunning) {
            $RestartTasks = @(Get-ScheduledTask `
                    -TaskName $UserWingetTaskName `
                    -TaskPath $UserWingetTaskPath `
                    -ErrorAction Stop)
            if ($RestartTasks.Count -ne 1) {
                throw "The limited user helper required to restart SABnzbd is not installed. Run Setup-PackageUpdateTasks.ps1."
            }
            $null = Test-UserWingetScheduledTaskDefinition `
                -Task $RestartTasks[0] `
                -TaskName $UserWingetTaskName `
                -ExpectedScriptPath $PSCommandPath

            $RestartMarkerPath = Join-Path $LogDir ("{0}{1}.marker" -f `
                    $SabnzbdRestartMarkerPrefix, `
                    [guid]::NewGuid().ToString("N"))
            $MarkerText = "requestedAtUtc=$([datetime]::UtcNow.ToString('o'));target=$($Plan.TargetVersionText)"
            $MarkerBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(
                $MarkerText + [Environment]::NewLine
            )
            $MarkerStream = [System.IO.File]::Open(
                $RestartMarkerPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            try {
                $MarkerStream.Write($MarkerBytes, 0, $MarkerBytes.Length)
                $MarkerStream.Flush($true)
            }
            finally {
                $MarkerStream.Dispose()
            }
            $RestartMarkerCreated = $true
        }

        # Hold a read-only handle that denies writes/deletes from validation
        # through process completion, closing the verify-to-execute race.
        $InstallerGuard = [System.IO.File]::Open(
            $InstallerPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $ActualSha256 = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256 -ErrorAction Stop).Hash
        $Signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath -ErrorAction Stop
        $InstallerItem = Get-Item -LiteralPath $InstallerPath -ErrorAction Stop
        $null = Confirm-SabnzbdInstallerTrust `
            -ExpectedSha256 $Plan.Sha256 `
            -ActualSha256 $ActualSha256 `
            -SignatureStatus "$($Signature.Status)" `
            -SignerSubject "$($Signature.SignerCertificate.Subject)" `
            -CompanyName "$($InstallerItem.VersionInfo.CompanyName)" `
            -ProductName "$($InstallerItem.VersionInfo.ProductName)" `
            -ProductVersion "$($InstallerItem.VersionInfo.ProductVersion)" `
            -ExpectedVersion $Plan.TargetVersionText

        Write-Log "Verified official SHA-256 and SignPath signature. Installing SABnzbd $($Plan.TargetVersionText) silently." -Level Info
        $InstallerProcess = Start-Process `
            -FilePath $InstallerPath `
            -ArgumentList "/S" `
            -WindowStyle Hidden `
            -Wait `
            -PassThru `
            -ErrorAction Stop
        if ($InstallerProcess.ExitCode -ne 0) {
            throw "SABnzbd installer exited with code $($InstallerProcess.ExitCode)."
        }
        $InstallerGuard.Dispose()
        $InstallerGuard = $null

        $VerificationDeadline = [datetime]::UtcNow.AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 500
            $InstalledAfter = Get-SabnzbdInstallation
        } while ((-not $InstalledAfter -or $InstalledAfter.Version -lt $Plan.TargetVersion) -and
            [datetime]::UtcNow -lt $VerificationDeadline)
        if (-not $InstalledAfter -or $InstalledAfter.Version -lt $Plan.TargetVersion) {
            $FoundVersion = if ($InstalledAfter) { $InstalledAfter.VersionText } else { "not installed" }
            throw "SABnzbd verification failed: expected at least $($Plan.TargetVersionText), found $FoundVersion."
        }
        $null = Confirm-SabnzbdFileAtPath `
            -Path $InstalledAfter.ExecutablePath `
            -ExpectedVersion $InstalledAfter.VersionText
        $UpdatePerformed = $true
    }
    catch {
        $UpdateFailure = $_.Exception.Message
    }
    finally {
        if ($InstallerGuard) {
            $InstallerGuard.Dispose()
        }
        if ($WingetLock) {
            $WingetLock.Dispose()
        }

        if ($ServiceWasRunning) {
            try {
                $null = Start-ServiceWithRetry -Name "SABnzbd"
            }
            catch {
                $RuntimeRestoreFailure = $_.Exception.Message
            }
        }
        elseif ($RestartMarkerCreated) {
            try {
                $RestartExitCode = Invoke-UserWingetScheduledUpdate
                $RestoreInstallation = Get-SabnzbdInstallation
                if (-not $RestoreInstallation) {
                    throw "SABnzbd was not installed after the limited helper completed."
                }
                $ProcessDeadline = [datetime]::UtcNow.AddSeconds(30)
                do {
                    $SabnzbdProcesses = @(Get-SabnzbdProcessesAtPath `
                            -ExecutablePath $RestoreInstallation.ExecutablePath)
                    if ($SabnzbdProcesses.Count -gt 0) { break }
                    Start-Sleep -Milliseconds 500
                } while ([datetime]::UtcNow -lt $ProcessDeadline)
                if ($SabnzbdProcesses.Count -eq 0) {
                    throw "The limited helper did not restore the SABnzbd desktop process (task exit code $RestartExitCode)."
                }
                if ($RestartMarkerPath -and (Test-Path -LiteralPath $RestartMarkerPath -PathType Leaf)) {
                    [System.IO.File]::Delete($RestartMarkerPath)
                }
                if ($RestartExitCode -ne 0) {
                    Write-Log "SABnzbd was restored, but the limited helper reported exit code $RestartExitCode." -Level Warning
                }
            }
            catch {
                $RuntimeRestoreFailure = $_.Exception.Message
            }
        }

        if ($TemporaryDirectory -and [System.IO.Directory]::Exists($TemporaryDirectory)) {
            try {
                $FullTemporaryDirectory = [System.IO.Path]::GetFullPath($TemporaryDirectory)
                $FullProtectedStagingRoot = [System.IO.Path]::GetFullPath($SabnzbdStagingRoot).TrimEnd(
                    [System.IO.Path]::DirectorySeparatorChar
                )
                if (-not $FullTemporaryDirectory.StartsWith(
                        $FullProtectedStagingRoot + [System.IO.Path]::DirectorySeparatorChar,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )) {
                    throw "Refusing to remove unexpected temporary directory: $FullTemporaryDirectory"
                }
                $StagingItem = Get-Item -LiteralPath $FullTemporaryDirectory -Force -ErrorAction Stop
                if (($StagingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Refusing to remove a reparse-point SABnzbd staging directory."
                }
                if ($InstallerPath -and [System.IO.File]::Exists($InstallerPath)) {
                    [System.IO.File]::Delete($InstallerPath)
                }
                $RemainingEntries = [System.IO.Directory]::GetFileSystemEntries($FullTemporaryDirectory)
                if ($RemainingEntries.Count -ne 0) {
                    throw "Refusing to remove a non-empty SABnzbd staging directory."
                }
                [System.IO.Directory]::Delete($FullTemporaryDirectory, $false)
            }
            catch {
                Write-Log "Could not remove SABnzbd temporary directory: $($_.Exception.Message)" -Level Warning
            }
        }
    }

    if ($RuntimeRestoreFailure) {
        $RuntimeMessage = "Could not restore SABnzbd's prior running state: $RuntimeRestoreFailure"
        $UpdateFailure = if ($UpdateFailure) { "$UpdateFailure $RuntimeMessage" } else { $RuntimeMessage }
    }

    if ($UpdateFailure) {
        $script:Results.SABnzbd.Status = "Error"
        $script:Results.SABnzbd.Message = $UpdateFailure
        Write-Log "Official SABnzbd update failed: $UpdateFailure" -Level Error
    }
    elseif ($UpdatePerformed) {
        $script:Results.SABnzbd.Status = "Success"
        $script:Results.SABnzbd.Message = "SABnzbd updated and verified at $($InstalledAfter.VersionText)"
        Write-Log $script:Results.SABnzbd.Message -Level Success
    }
}

function Update-WindowsStore {
    Write-Log ("=" * 60) -Level Info
    Write-Log "STARTING WINDOWS STORE UPDATES" -Level Info
    Write-Log ("=" * 60) -Level Info

    $WingetLock = $null
    try {
        $WingetPath = Get-WingetCommand
        Write-Log "Found winget at: $($WingetPath.Source)" -Level Info
        $WingetLock = Enter-PackageUpdateFileLock -Path $WingetLockPath
        Write-Log "Acquired exclusive WinGet lock for Windows Store updates: $WingetLockPath" -Level Info

        Write-Log "Running: winget upgrade --all --source msstore --include-unknown --accept-package-agreements --accept-source-agreements" -Level Info

        & $WingetPath.Source upgrade --all --source msstore --include-unknown --accept-package-agreements --accept-source-agreements
        $BulkExitCode = $LASTEXITCODE
        $BulkNoLongerApplicable = ($BulkExitCode -ne $null -and (Test-WingetNoApplicableExitCode -ExitCode $BulkExitCode))
        $BulkSucceeded = ($BulkExitCode -eq 0 -or $BulkExitCode -eq $null -or $BulkNoLongerApplicable)

        if ($BulkExitCode -eq 0 -or $BulkExitCode -eq $null) {
            Write-Log "Windows Store updates completed successfully" -Level Success
        }
        elseif ($BulkNoLongerApplicable) {
            Write-Log "No applicable Windows Store upgrades remain. Exit code: $BulkExitCode" -Level Info
        }
        else {
            Write-Log "Windows Store updates completed with exit code: $BulkExitCode" -Level Warning
        }

        $ExplicitIds = Get-WingetUpgradeIds -WingetPath $WingetPath -Source "msstore"
        $ExplicitResult = Invoke-WingetExplicitUpgrades -WingetPath $WingetPath -Source "msstore" -PackageIds $ExplicitIds

        if ($BulkSucceeded -and $ExplicitResult.Failed.Count -eq 0) {
            $script:Results.WindowsStore.Status = "Success"
            if ($ExplicitResult.Succeeded -gt 0) {
                $script:Results.WindowsStore.Message = "Windows Store packages updated successfully ($($ExplicitResult.Succeeded) explicit checks)"
            }
            else {
                $script:Results.WindowsStore.Message = "Windows Store packages updated successfully"
            }
        }
        else {
            $script:Results.WindowsStore.Status = "Warning"
            if ($ExplicitResult.Failed.Count -gt 0) {
                $script:Results.WindowsStore.Message = "Windows Store completed with issues; failed explicit upgrades: $($ExplicitResult.Failed -join ', ')"
            }
            else {
                $script:Results.WindowsStore.Message = "Windows Store updates completed with exit code: $BulkExitCode"
            }
        }
    }
    catch {
        $script:Results.WindowsStore.Status = "Error"
        $script:Results.WindowsStore.Message = $_.Exception.Message
        Write-Log "Windows Store update failed: $($_.Exception.Message)" -Level Error
        Show-ToastNotification -Title "Windows Store Update Failed" -Message $_.Exception.Message -Type Error
    }
    finally {
        if ($WingetLock) {
            $WingetLock.Dispose()
        }
    }
}

function Update-Chocolatey {
    Write-Log ("=" * 60) -Level Info
    Write-Log "STARTING CHOCOLATEY UPDATES" -Level Info
    Write-Log ("=" * 60) -Level Info

    try {
        # Check if choco is available
        $ChocoPath = Get-Command choco -ErrorAction Stop
        Write-Log "Found Chocolatey at: $($ChocoPath.Source)" -Level Info

        # Chocolatey admin upgrade

        if ($IsAdmin) {
            Write-Log "Running choco upgrade..." -Level Info
            & $ChocoPath.Source upgrade all -y
            $ChocolateyExitCode = $LASTEXITCODE
            if ($ChocolateyExitCode -eq 0 -or $ChocolateyExitCode -eq $null) {
                $script:Results.ChocolateyAdmin.Status = "Success"
                $script:Results.ChocolateyAdmin.Message = "Chocolatey packages updated successfully"
                Write-Log "Chocolatey updates completed successfully" -Level Success
            }
            elseif ($ChocolateyExitCode -eq 2) {
                $script:Results.ChocolateyAdmin.Status = "Success"
                $script:Results.ChocolateyAdmin.Message = "Chocolatey packages are already up-to-date"
                Write-Log "Chocolatey found no outdated packages" -Level Success
            }
            elseif (@(1605, 1614) -contains $ChocolateyExitCode) {
                $script:Results.ChocolateyAdmin.Status = "Success"
                $script:Results.ChocolateyAdmin.Message = "Chocolatey completed with valid package no-op exit code $ChocolateyExitCode"
                Write-Log $script:Results.ChocolateyAdmin.Message -Level Success
            }
            elseif (@(1641, 3010) -contains $ChocolateyExitCode) {
                $script:Results.ChocolateyAdmin.Status = "Warning"
                $script:Results.ChocolateyAdmin.Message = "Chocolatey completed successfully, but a reboot is required (exit code $ChocolateyExitCode)"
                Write-Log $script:Results.ChocolateyAdmin.Message -Level Warning
            }
            elseif ($ChocolateyExitCode -eq 350) {
                $script:Results.ChocolateyAdmin.Status = "Warning"
                $script:Results.ChocolateyAdmin.Message = "Chocolatey deferred updates because a reboot is already pending (exit code 350)"
                Write-Log $script:Results.ChocolateyAdmin.Message -Level Warning
            }
            else {
                throw "Chocolatey completed with exit code: $ChocolateyExitCode"
            }
        }
        else {
            Write-Log "ERROR: Update-ChocolateyAdmin called without Administrator privileges." -Level Error
            throw "Elevation required for Chocolatey admin updates."
        }

    }
    catch {
        $script:Results.ChocolateyAdmin.Status = "Error"
        $script:Results.ChocolateyAdmin.Message = $_.Exception.Message
        Write-Log "Chocolatey admin update failed: $($_.Exception.Message)" -Level Error
        Show-ToastNotification -Title "Chocolatey Admin Update Failed" -Message $_.Exception.Message -Type Error
    }
}


function Update-WslPackages {
    Write-Log ("=" * 60) -Level Info
    Write-Log "STARTING WSL UBUNTU APT UPDATES" -Level Info
    Write-Log ("=" * 60) -Level Info

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

        $WslAptCommand = "export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get upgrade -y && apt-get autoremove -y"
        Write-Log "Running as WSL root: $WslAptCommand" -Level Info

        # Windows elevation does not grant Linux sudo rights inside WSL.
        # Run the apt workflow as the WSL root user so scheduled runs are non-interactive.
        $WslOutput = & wsl.exe -d Ubuntu -u root -- bash -lc $WslAptCommand 2>&1
        $WslExitCode = $LASTEXITCODE
        foreach ($Line in $WslOutput) {
            if ($Line) {
                Write-Log "$Line" -Level Info
            }
        }

        if ($WslExitCode -eq 0 -or $WslExitCode -eq $null) {
            $script:Results.Wsl.Status = "Success"
            $script:Results.Wsl.Message = "WSL Ubuntu packages updated successfully"
            Write-Log "WSL Ubuntu updates completed successfully" -Level Success
        }
        else {
            $script:Results.Wsl.Status = "Warning"
            $script:Results.Wsl.Message = "WSL apt completed with exit code: $WslExitCode"
            Write-Log "WSL apt completed with exit code: $WslExitCode" -Level Warning
        }
    }
    catch {
        $script:Results.Wsl.Status = "Error"
        $script:Results.Wsl.Message = $_.Exception.Message
        Write-Log "WSL Ubuntu update failed: $($_.Exception.Message)" -Level Error
        Show-ToastNotification -Title "WSL Update Failed" -Message $_.Exception.Message -Type Error
    }
}

function Update-WslClaudeCode {
    Write-Log ("=" * 60) -Level Info
    Write-Log "STARTING WSL CLAUDE CODE UPDATE" -Level Info
    Write-Log ("=" * 60) -Level Info

    try {
        $WslPath = Get-Command wsl.exe -ErrorAction Stop
        Write-Log "Found wsl at: $($WslPath.Source)" -Level Info

        $RawDistros = & wsl.exe -l -q 2>&1 | Out-String
        $CleanDistros = $RawDistros -replace "`0", ""
        if ($CleanDistros -notmatch "Ubuntu") {
            throw "Ubuntu WSL distro not found (installed: $($CleanDistros.Trim()))"
        }

        # Deliberately run as the distro's default user, not root: Claude Code is
        # installed per-user via the native installer (~/.local/bin/claude). Root's
        # PATH instead resolves a Windows npm shim through the /mnt/c interop mount,
        # which is a different install entirely and would silently update the wrong thing.
        $ClaudeCheck = (& wsl.exe -d Ubuntu -- bash -lc "command -v claude" 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $ClaudeCheck) {
            $script:Results.WslClaude.Status = "Skipped"
            $script:Results.WslClaude.Message = "Claude Code not found in WSL Ubuntu (expected native install at ~/.local/bin/claude)"
            Write-Log $script:Results.WslClaude.Message -Level Info
            return
        }
        Write-Log "Found WSL claude at: $ClaudeCheck" -Level Info

        $CurrentVersion = (& wsl.exe -d Ubuntu -- bash -lc "claude --version" 2>&1 | Out-String).Trim()
        Write-Log "Current WSL Claude Code: $CurrentVersion" -Level Info

        Write-Log "Running as WSL default user: claude update" -Level Info
        $UpdateOutput = & wsl.exe -d Ubuntu -- bash -lc "claude update" 2>&1
        $UpdateExitCode = $LASTEXITCODE
        foreach ($Line in $UpdateOutput) {
            if ($Line) {
                Write-Log "$Line" -Level Info
            }
        }

        if ($UpdateExitCode -ne 0 -and $null -ne $UpdateExitCode) {
            $script:Results.WslClaude.Status = "Warning"
            $script:Results.WslClaude.Message = "claude update completed with exit code: $UpdateExitCode"
            Write-Log $script:Results.WslClaude.Message -Level Warning
            return
        }

        $UpdatedVersion = (& wsl.exe -d Ubuntu -- bash -lc "claude --version" 2>&1 | Out-String).Trim()
        if (-not $UpdatedVersion) {
            $script:Results.WslClaude.Status = "Warning"
            $script:Results.WslClaude.Message = "Claude Code updated, but version verification failed."
            Write-Log $script:Results.WslClaude.Message -Level Warning
            return
        }

        $script:Results.WslClaude.Status = "Success"
        $script:Results.WslClaude.Message = "WSL Claude Code is current: $UpdatedVersion (was: $CurrentVersion)"
        Write-Log $script:Results.WslClaude.Message -Level Success
    }
    catch {
        $script:Results.WslClaude.Status = "Error"
        $script:Results.WslClaude.Message = $_.Exception.Message
        Write-Log "WSL Claude Code update failed: $($_.Exception.Message)" -Level Error
        Show-ToastNotification -Title "WSL Claude Code Update Failed" -Message $_.Exception.Message -Type Error
    }
}

function Update-Pip {
    Write-Log ("=" * 60) -Level Info
    Write-Log "STARTING PIP UPDATES" -Level Info
    Write-Log ("=" * 60) -Level Info

    try {
        $PipPath = Get-Command pip -ErrorAction Stop
        Write-Log "Found pip at: $($PipPath.Source)" -Level Info

        # Upgrade pip itself first
        Write-Log "Upgrading pip itself..." -Level Info
        $PipUpgradeOutput = & $PipPath.Source install --upgrade pip 2>&1
        $PipUpgradeExitCode = $LASTEXITCODE
        $PipUpgradeOutput | ForEach-Object { Write-Log "$_" -Level Info }
        if ($PipUpgradeExitCode -ne 0 -and $PipUpgradeExitCode -ne $null) {
            throw "pip self-update completed with exit code: $PipUpgradeExitCode"
        }

        # Get outdated packages as JSON
        Write-Log "Checking for outdated packages..." -Level Info
        $OutdatedJson = & $PipPath.Source list --outdated --format=json 2>&1
        $PipListExitCode = $LASTEXITCODE
        if ($PipListExitCode -ne 0 -and $PipListExitCode -ne $null) {
            throw "pip outdated check completed with exit code: $PipListExitCode"
        }

        $OutdatedJsonText = ($OutdatedJson | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($OutdatedJsonText)) {
            throw "pip outdated check returned no JSON output"
        }

        try {
            $Outdated = @($OutdatedJsonText | ConvertFrom-Json)
        }
        catch {
            throw "Could not parse pip outdated output: $($_.Exception.Message)"
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
                & $PipPath.Source install --upgrade $Pkg 2>&1 | Out-Null
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

function Invoke-NativeCaptured {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandPath,
        [string[]]$Arguments = @()
    )

    $ErrorFile = New-TemporaryFile
    try {
        $OutputText = (& $CommandPath @Arguments 2> $ErrorFile | Out-String).Trim()
        $ExitCode = $LASTEXITCODE
        $RawErrorText = Get-Content -Path $ErrorFile -Raw -ErrorAction SilentlyContinue
        $ErrorText = if ($RawErrorText) { $RawErrorText.Trim() } else { "" }

        return [pscustomobject]@{
            Output   = $OutputText
            Error    = $ErrorText
            ExitCode = $ExitCode
        }
    }
    finally {
        Remove-Item -Path $ErrorFile -Force -ErrorAction SilentlyContinue
    }
}

function Write-NpmCommandOutput {
    param(
        [Parameter(Mandatory = $true)]
        $CommandResult
    )

    if ($CommandResult.Output) {
        $CommandResult.Output -split '\r?\n' | ForEach-Object {
            if ($_ -ne "") { Write-Log "$_" -Level Info }
        }
    }
    if ($CommandResult.Error) {
        $CommandResult.Error -split '\r?\n' | ForEach-Object {
            if ($_ -ne "") { Write-Log "$_" -Level Warning }
        }
    }
}

function Invoke-NpmInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NpmCommand,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $Result = Invoke-NativeCaptured -CommandPath $NpmCommand -Arguments $Arguments
    Write-NpmCommandOutput -CommandResult $Result
    $CombinedOutput = (($Result.Output, $Result.Error) -join "`n").Trim()

    return [pscustomobject]@{
        Success        = ($Result.ExitCode -eq 0 -or $Result.ExitCode -eq $null)
        ExitCode       = $Result.ExitCode
        BlockedScripts = ($CombinedOutput -match '(?is)install-scripts.*blocked')
        Output         = $CombinedOutput
    }
}

function Update-NpmChannelPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NpmCommand,
        [Parameter(Mandatory = $true)]
        [string]$NpmPrefix,
        [Parameter(Mandatory = $true)]
        [string]$NpmRoot,
        [Parameter(Mandatory = $true)]
        [string]$PackageName,
        [Parameter(Mandatory = $true)]
        [string]$Channel,
        [Parameter(Mandatory = $true)]
        [string]$ShimName,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [switch]$AllowPackageScripts
    )

    try {
        $ViewResult = Invoke-NativeCaptured -CommandPath $NpmCommand -Arguments @(
            "view", $PackageName, "dist-tags.$Channel", "--json", "--loglevel=error"
        )
        if ($ViewResult.Error) {
            Write-NpmCommandOutput -CommandResult ([pscustomobject]@{ Output = ""; Error = $ViewResult.Error })
        }
        if ($ViewResult.ExitCode -ne 0 -and $ViewResult.ExitCode -ne $null) {
            throw "Could not resolve the $PackageName $Channel channel (exit code $($ViewResult.ExitCode)): $($ViewResult.Error)"
        }

        try {
            $TargetVersion = "$($ViewResult.Output | ConvertFrom-Json)".Trim()
        }
        catch {
            throw "Could not parse the $PackageName $Channel version: $($_.Exception.Message)"
        }
        if ([string]::IsNullOrWhiteSpace($TargetVersion)) {
            throw "The $PackageName $Channel channel returned no version"
        }

        $PackageDirectory = $NpmRoot
        foreach ($PathPart in $PackageName.Split('/')) {
            $PackageDirectory = Join-Path $PackageDirectory $PathPart
        }
        $PackageJsonPath = Join-Path $PackageDirectory "package.json"
        $ShimPath = Join-Path $NpmPrefix "$ShimName.cmd"
        $CurrentVersion = $null
        if (Test-Path $PackageJsonPath) {
            try {
                $CurrentVersion = (Get-Content -Path $PackageJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json).version
            }
            catch {
                Write-Log "Could not read the installed $DisplayName version; reinstalling it." -Level Warning
            }
        }

        Write-Log "$DisplayName channel ${Channel}: installed=$CurrentVersion target=$TargetVersion" -Level Info
        if ($CurrentVersion -ne $TargetVersion -or -not (Test-Path $ShimPath)) {
            $InstallArguments = @("install", "-g", "--prefix", $NpmPrefix, "--loglevel=error", "--strict-allow-scripts")
            if ($AllowPackageScripts) {
                $InstallArguments += "--allow-scripts=$PackageName"
            }
            $InstallArguments += "$PackageName@$TargetVersion"

            Write-Log "Installing $DisplayName $Channel version $TargetVersion..." -Level Info
            $InstallResult = Invoke-NpmInstall -NpmCommand $NpmCommand -Arguments $InstallArguments
            if (-not $InstallResult.Success) {
                throw "$DisplayName installation completed with exit code $($InstallResult.ExitCode): $($InstallResult.Output)"
            }
            if ($InstallResult.BlockedScripts) {
                throw "$DisplayName installation completed with blocked install scripts"
            }
        }

        if (-not (Test-Path $PackageJsonPath)) {
            throw "$DisplayName package metadata was not found after installation: $PackageJsonPath"
        }
        $InstalledVersion = (Get-Content -Path $PackageJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json).version
        if ($InstalledVersion -ne $TargetVersion) {
            throw "$DisplayName package verification failed: expected $TargetVersion, found $InstalledVersion"
        }
        if (-not (Test-Path $ShimPath)) {
            throw "$DisplayName command shim was not found: $ShimPath"
        }

        $VersionResult = Invoke-NativeCaptured -CommandPath $ShimPath -Arguments @("--version")
        Write-NpmCommandOutput -CommandResult $VersionResult
        $VersionOutput = (($VersionResult.Output, $VersionResult.Error) -join "`n").Trim()
        if ($VersionResult.ExitCode -ne 0 -and $VersionResult.ExitCode -ne $null) {
            throw "$DisplayName command verification completed with exit code $($VersionResult.ExitCode): $VersionOutput"
        }
        if ($VersionOutput -notmatch [regex]::Escape($TargetVersion)) {
            throw "$DisplayName command verification did not report version ${TargetVersion}: $VersionOutput"
        }

        Write-Log "$DisplayName $TargetVersion verified at $ShimPath" -Level Success
        return [pscustomobject]@{
            Status  = "Success"
            Message = "$DisplayName $Channel $TargetVersion verified"
            Version = $TargetVersion
        }
    }
    catch {
        Write-Log "$DisplayName $Channel update failed: $($_.Exception.Message)" -Level Warning
        return [pscustomobject]@{
            Status  = "Warning"
            Message = "$DisplayName ${Channel}: $($_.Exception.Message)"
            Version = $null
        }
    }
}

function Get-NpmTrustedNativeModuleDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NpmRoot
    )

    if (-not (Test-Path $NpmRoot)) { return @() }

    return @(Get-ChildItem -Path $NpmRoot -Filter package.json -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $NormalizedDirectory = $_.DirectoryName.Replace('/', '\')
            $NormalizedDirectory -match '\\node_modules\\(?:@github\\keytar|node-pty)$'
        } |
        ForEach-Object { $_.DirectoryName } |
        Sort-Object -Unique)
}

function Test-NpmTrustedNativeModules {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ModuleDirectories
    )

    $NodePath = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $NodePath) {
        $NodePath = Get-Command node -ErrorAction Stop
    }

    $Failed = New-Object System.Collections.Generic.List[string]
    foreach ($ModuleDirectory in $ModuleDirectories) {
        $ModuleName = Split-Path $ModuleDirectory -Leaf
        $HealthResult = Invoke-NativeCaptured -CommandPath $NodePath.Source -Arguments @(
            "-e", "require(process.argv[1]);", $ModuleDirectory
        )
        if ($HealthResult.ExitCode -eq 0 -or $HealthResult.ExitCode -eq $null) {
            Write-Log "Verified native npm module: $ModuleDirectory" -Level Success
        }
        else {
            $Failed.Add($ModuleName)
            $HealthOutput = (($HealthResult.Output, $HealthResult.Error) -join "`n").Trim()
            Write-Log "Native npm module health check failed for ${ModuleDirectory}: $HealthOutput" -Level Warning
        }
    }

    return @($Failed)
}

function Update-NpmGlobal {
    Write-Log ("=" * 60) -Level Info
    Write-Log "STARTING NPM GLOBAL UPDATES" -Level Info
    Write-Log ("=" * 60) -Level Info

    try {
        $NpmPath = Get-NpmCommand
        Write-Log "Found npm at: $($NpmPath.Source)" -Level Info

        $PrefixResult = Invoke-NativeCaptured -CommandPath $NpmPath.Source -Arguments @("prefix", "-g")
        if ($PrefixResult.ExitCode -ne 0 -and $PrefixResult.ExitCode -ne $null) {
            throw "Could not determine npm's global prefix (exit code $($PrefixResult.ExitCode)): $($PrefixResult.Error)"
        }
        $PrefixLines = @($PrefixResult.Output -split '\r?\n' | Where-Object { $_.Trim() })
        if ($PrefixLines.Count -eq 0) {
            throw "npm returned an empty global prefix"
        }
        $PrefixText = $PrefixLines[-1].Trim()

        $CandidatePrefix = [System.IO.Path]::GetFullPath($PrefixText)
        $UserRoot = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\') + '\'
        if ($CandidatePrefix.StartsWith($UserRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $NpmPrefix = $CandidatePrefix
            Write-Log "Using existing per-user npm global prefix: $NpmPrefix" -Level Info
        }
        else {
            $NpmPrefix = Join-Path $env:APPDATA "npm"
            Write-Log "npm's configured global prefix is not user-owned; using per-user prefix for global packages: $NpmPrefix" -Level Warning
        }
        if (-not (Test-Path $NpmPrefix)) {
            New-Item -ItemType Directory -Path $NpmPrefix -Force | Out-Null
        }
        $NpmRoot = Join-Path $NpmPrefix "node_modules"

        $Issues = New-Object System.Collections.Generic.List[string]
        $GenericUpdated = 0
        $ManagedPackages = @("npm", "@openai/codex", "@anthropic-ai/claude-code")

        try {
            Write-Log "Checking for outdated global packages in $NpmPrefix..." -Level Info
            $OutdatedResult = Invoke-NativeCaptured -CommandPath $NpmPath.Source -Arguments @(
                "outdated", "-g", "--prefix", $NpmPrefix, "--json", "--loglevel=error"
            )
            if ($OutdatedResult.Error) {
                Write-NpmCommandOutput -CommandResult ([pscustomobject]@{ Output = ""; Error = $OutdatedResult.Error })
            }
            if ($OutdatedResult.ExitCode -ne 0 -and $OutdatedResult.ExitCode -ne 1 -and $OutdatedResult.ExitCode -ne $null) {
                throw "npm outdated completed with exit code $($OutdatedResult.ExitCode): $($OutdatedResult.Error)"
            }
            if ([string]::IsNullOrWhiteSpace($OutdatedResult.Output)) {
                throw "npm outdated returned no JSON output"
            }

            try {
                $OutdatedPackages = $OutdatedResult.Output | ConvertFrom-Json
            }
            catch {
                throw "Could not parse npm outdated output: $($_.Exception.Message)"
            }

            foreach ($Property in $OutdatedPackages.PSObject.Properties) {
                $PackageName = $Property.Name
                if ($ManagedPackages -contains $PackageName.ToLowerInvariant()) {
                    Write-Log "Skipping separately managed npm package: $PackageName" -Level Info
                    continue
                }

                $PackageInfo = $Property.Value
                $TargetVersion = if ($PackageInfo.latest) { "$($PackageInfo.latest)" } else { "latest" }
                Write-Log "Updating ${PackageName}: $($PackageInfo.current) -> $TargetVersion" -Level Info
                $InstallArguments = @(Get-NpmGenericInstallArguments `
                    -NpmPrefix $NpmPrefix `
                    -PackageName $PackageName `
                    -TargetVersion $TargetVersion)
                $InstallResult = Invoke-NpmInstall -NpmCommand $NpmPath.Source -Arguments $InstallArguments
                if (-not $InstallResult.Success) {
                    $Issues.Add("$PackageName failed with exit code $($InstallResult.ExitCode)")
                    continue
                }
                if ($InstallResult.BlockedScripts) {
                    $Issues.Add("$PackageName completed with blocked install scripts")
                    continue
                }

                $GenericUpdated++
                Write-Log "Updated npm package: $PackageName" -Level Success
            }
        }
        catch {
            $Issues.Add("generic npm packages: $($_.Exception.Message)")
            Write-Log "Generic npm update failed: $($_.Exception.Message)" -Level Warning
        }

        # These packages intentionally track prerelease channels and must not be
        # folded into npm's stable `latest` update path.
        $CodexResult = Update-NpmChannelPackage `
            -NpmCommand $NpmPath.Source `
            -NpmPrefix $NpmPrefix `
            -NpmRoot $NpmRoot `
            -PackageName "@openai/codex" `
            -Channel "alpha" `
            -ShimName "codex" `
            -DisplayName "Codex"
        if ($CodexResult.Status -ne "Success") { $Issues.Add($CodexResult.Message) }

        $ClaudeResult = Update-NpmChannelPackage `
            -NpmCommand $NpmPath.Source `
            -NpmPrefix $NpmPrefix `
            -NpmRoot $NpmRoot `
            -PackageName "@anthropic-ai/claude-code" `
            -Channel "next" `
            -ShimName "claude" `
            -DisplayName "Claude Code" `
            -AllowPackageScripts
        if ($ClaudeResult.Status -ne "Success") { $Issues.Add($ClaudeResult.Message) }

        $NativeModuleDirectories = @(Get-NpmTrustedNativeModuleDirectories -NpmRoot $NpmRoot)
        if ($NativeModuleDirectories.Count -gt 0) {
            Write-Log "Rebuilding installed @github/keytar and node-pty packages with their lifecycle scripts allowed..." -Level Info
            $RebuildArguments = @(Get-NpmTrustedNativeRebuildArguments -NpmPrefix $NpmPrefix)
            $RebuildResult = Invoke-NpmInstall -NpmCommand $NpmPath.Source -Arguments $RebuildArguments
            if (-not $RebuildResult.Success) {
                $Issues.Add("trusted native package rebuild failed with exit code $($RebuildResult.ExitCode)")
            }
            elseif ($RebuildResult.BlockedScripts) {
                $Issues.Add("trusted native package rebuild left lifecycle scripts blocked")
            }

            try {
                $NativeFailures = @(Test-NpmTrustedNativeModules -ModuleDirectories $NativeModuleDirectories)
                if ($NativeFailures.Count -gt 0) {
                    $Issues.Add("native module health checks failed: $($NativeFailures -join ', ')")
                }
            }
            catch {
                $Issues.Add("native module health check could not run: $($_.Exception.Message)")
                Write-Log "Native npm module health check could not run: $($_.Exception.Message)" -Level Warning
            }
        }
        else {
            Write-Log "No installed @github/keytar or node-pty modules require a native health check." -Level Info
        }

        if ($Issues.Count -gt 0) {
            $script:Results.Npm.Status = "Warning"
            $script:Results.Npm.Message = $Issues -join "; "
            Write-Log "npm completed with issues: $($Issues -join '; ')" -Level Warning
        }
        else {
            $script:Results.Npm.Status = "Success"
            $script:Results.Npm.Message = "npm packages verified ($GenericUpdated generic updates; $($CodexResult.Message); $($ClaudeResult.Message))"
            Write-Log "npm global updates and channel verification completed successfully" -Level Success
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
    param([switch]$SuppressNotification)

    Write-Log "" -Level Info
    Write-Log ("=" * 60) -Level Info
    Write-Log "UPDATE SUMMARY" -Level Info
    Write-Log ("=" * 60) -Level Info

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
    }

    Write-Log ("=" * 60) -Level Info
    Write-Log "Log file saved to: $LogFile" -Level Info

    $ExitCode = Get-PackageUpdateExitCode -Results $Results

    if (-not $SuppressNotification) {
        if ($ExitCode -eq 1) {
            Show-ToastNotification -Title "Package Updates Completed with Errors" -Message "Check the log for details: $LogFile" -Type Warning | Out-Null
        }
        elseif ($ExitCode -eq 2) {
            Show-ToastNotification -Title "Package Updates Completed with Warnings" -Message "Some updates need attention. Check the log: $LogFile" -Type Warning | Out-Null
        }
        else {
            Show-ToastNotification -Title "Package Updates Completed" -Message "All package managers updated successfully!" -Type Info | Out-Null
        }
    }

    return $ExitCode
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

Write-Log ("=" * 60) -Level Info
Write-Log "PACKAGE UPDATE STARTED (Elevated=$Elevated, Admin=$IsAdmin)" -Level Info
Write-Log "Script Directory: $ScriptDir" -Level Info
Write-Log "Log File: $LogFile" -Level Info
Write-Log ("=" * 60) -Level Info

# Check for Data Saver / Metered Connection
if (Test-DataSaver) {
    if ($UserWingetOnly) {
        # A pending desktop restart is local recovery work, not a download. Do
        # it even when package network traffic is deferred on a metered link.
        Restore-SabnzbdUserProcessWithPackageLock
    }
    $Results.Execution.Status = "Warning"
    $Results.Execution.Message = "Metered connection (Data Saver) detected. Skipping auto updates to conserve data."
    $FinalExitCode = Get-PackageUpdateExitCode -Results $Results
    Write-Log $Results.Execution.Message -Level Warning
    if (-not $UserWingetOnly) {
        Show-ToastNotification -Title "Package Updates Skipped" -Message "Metered connection detected. Updates deferred to save data." -Type Warning
    }

    try {
        $SourceSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256 -ErrorAction Stop).Hash
        $LastRunRecord = New-PackageUpdateLastRunRecord `
            -ScriptName $ScriptName `
            -MachineName $MachineName `
            -StartedAt $RunStartedAt `
            -UpdatesCompletedAt (Get-Date) `
            -ExitCode $FinalExitCode `
            -KeepOpenMinutes $KeepOpenMinutes `
            -LogFile $LogFile `
            -SourcePath $PSCommandPath `
            -SourceSha256 $SourceSha256 `
            -Results $Results
        $null = Write-AtomicJsonFile -Path $LastRunStatusFile -InputObject $LastRunRecord
        Write-Log "Last-run status saved to: $LastRunStatusFile" -Level Info
    }
    catch {
        Write-Log "Could not persist metered-skip last-run status: $($_.Exception.Message)" -Level Warning
    }

    if ($script:TranscriptActive) {
        try { Stop-Transcript -ErrorAction SilentlyContinue } catch {}
    }
    exit $FinalExitCode
}

# Clean up old log files (keep only 3 most recent)
$LogPattern = Join-Path $LogDir "${LogScriptName}_${MachineName}_*.log"
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
if (-not $UserWingetOnly) {
    Show-ToastNotification -Title "Package Updates Starting" -Message "Updating winget, Windows Store, Chocolatey, npm, WSL apt/Claude Code, and pip packages..." -Type Info
}

# Handle split execution (User vs Elevated)

if ($UserWingetOnly) {
    if ($IsAdmin) {
        $Results.Execution.Status = "Error"
        $Results.Execution.Message = "User-context Winget mode was launched with administrator privileges"
        $Results.Winget.Status = "Error"
        $Results.Winget.Message = $Results.Execution.Message
        $FinalExitCode = 1
        Write-Log $Results.Execution.Message -Level Error
    }
    else {
        Update-UserContextWinget
        $Results.Execution.Status = "Success"
        $Results.Execution.Message = "User-context Winget execution completed"
    }
}
elseif (-not $IsAdmin -and -not $Elevated) {
    # All enabled package-manager phases execute in one elevated child so that
    # filtered runs cannot silently skip user-prefix npm, WSL, or pip work.
    $NeedsElevation = (-not $SkipWinget) -or
        (-not $SkipWindowsStore) -or
        (-not $SkipAdminChocolatey) -or
        (-not $SkipNpm) -or
        (-not $SkipWsl) -or
        (-not $SkipPip)

    if ($NeedsElevation) {
        Write-Log "Admin tasks pending. Requesting one-time elevation..." -Level Warning
        $RelaunchArgs = @("-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-Elevated")
        if ($SkipWinget) { $RelaunchArgs += "-SkipWinget" }
        if ($SkipWindowsStore) { $RelaunchArgs += "-SkipWindowsStore" }
        if ($SkipAdminChocolatey) { $RelaunchArgs += "-SkipAdminChocolatey" }
        if ($SkipNpm) { $RelaunchArgs += "-SkipNpm" }
        if ($SkipWsl) { $RelaunchArgs += "-SkipWsl" }
        if ($SkipPip) { $RelaunchArgs += "-SkipPip" }
        if ($NoPause) { $RelaunchArgs += "-NoPause" }
        if ($KeepOpenMinutes -gt 0) { $RelaunchArgs += @("-KeepOpenMinutes", $KeepOpenMinutes) }

        try {
            $ElevatedProcess = Start-Process "powershell.exe" -ArgumentList $RelaunchArgs -Verb RunAs -Wait -PassThru -ErrorAction Stop
            $FinalExitCode = $ElevatedProcess.ExitCode
            if ($FinalExitCode -eq 1) {
                Write-Log "Elevated package update process failed with exit code 1." -Level Error
            }
            elseif ($FinalExitCode -eq 2) {
                Write-Log "Elevated package update process completed with warnings." -Level Warning
            }
        }
        catch {
            $FinalExitCode = 1
            Write-Log "Could not start the elevated package update process: $($_.Exception.Message)" -Level Error
        }
    }
}
elseif ($Elevated -and -not $IsAdmin) {
    Write-Log "ERROR: Elevated switch set but process is NOT running as Administrator." -Level Error
    $FinalExitCode = 1
}
else {
    # Running as Admin (or explicitly requested elevated tasks)
    $UpdateMutex = $null
    $UpdateMutexAcquired = $false
    try {
        $UpdateMutex = [System.Threading.Mutex]::new($false, $UpdateMutexName)
        try {
            $UpdateMutexAcquired = $UpdateMutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $UpdateMutexAcquired = $true
            Write-Log "Recovered the updater mutex from an interrupted prior run." -Level Warning
        }

        if (-not $UpdateMutexAcquired) {
            $Results.Execution.Status = "Warning"
            $Results.Execution.Message = "Another package update process is already running; this duplicate run was skipped"
            $FinalExitCode = 2
            Write-Log $Results.Execution.Message -Level Warning
        }
        else {
            Write-Log "Acquired exclusive package updater mutex: $UpdateMutexName" -Level Info
            if (-not $SkipWinget) {
                Update-Winget
                Update-SabnzbdFromOfficialRelease
            }
            if (-not $SkipWindowsStore) {
                if ($script:UserWingetTaskMayBeRunning) {
                    $Results.WindowsStore.Status = "Warning"
                    $Results.WindowsStore.Message = "Skipped to avoid overlapping a user-context Winget task that may still be active"
                    Write-Log $Results.WindowsStore.Message -Level Warning
                }
                else {
                    Update-WindowsStore
                }
            }
            if (-not $SkipAdminChocolatey) { Update-Chocolatey }
            if (-not $SkipNpm) { Update-NpmGlobal }
            if (-not $SkipWsl) {
                Update-WslPackages
                Update-WslClaudeCode
            }
            if (-not $SkipPip) { Update-Pip }
            $Results.Execution.Status = "Success"
            $Results.Execution.Message = "Exclusive package update execution completed"
        }
    }
    catch {
        $Results.Execution.Status = "Error"
        $Results.Execution.Message = "Could not coordinate package update execution: $($_.Exception.Message)"
        $FinalExitCode = 1
        Write-Log $Results.Execution.Message -Level Error
    }
    finally {
        if ($UpdateMutex) {
            if ($UpdateMutexAcquired) {
                try {
                    $UpdateMutex.ReleaseMutex()
                    Write-Log "Released exclusive package updater mutex before the completion wait." -Level Info
                }
                catch {
                    $Results.Execution.Status = "Error"
                    $Results.Execution.Message = "Could not release the package updater mutex: $($_.Exception.Message)"
                    $FinalExitCode = 1
                    Write-Log $Results.Execution.Message -Level Error
                }
            }
            $UpdateMutex.Dispose()
        }
    }
}

# Stop Transcript
if ($script:TranscriptActive) {
    try { Stop-Transcript -ErrorAction SilentlyContinue } catch {}
    $script:TranscriptActive = $false
}

if ($UserWingetOnly -or $Elevated -or $IsAdmin) {
    # Only show summary and completion wait in the "active" or final process
    $SummaryExitCode = Show-Summary -SuppressNotification:$UserWingetOnly
    if ($FinalExitCode -eq 1 -or $SummaryExitCode -eq 1) {
        $FinalExitCode = 1
    }
    elseif ($FinalExitCode -eq 2 -or $SummaryExitCode -eq 2) {
        $FinalExitCode = 2
    }
    else {
        $FinalExitCode = 0
    }

    try {
        $SourceSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256 -ErrorAction Stop).Hash
        $LastRunRecord = New-PackageUpdateLastRunRecord `
            -ScriptName $ScriptName `
            -MachineName $MachineName `
            -StartedAt $RunStartedAt `
            -UpdatesCompletedAt (Get-Date) `
            -ExitCode $FinalExitCode `
            -KeepOpenMinutes $KeepOpenMinutes `
            -LogFile $LogFile `
            -SourcePath $PSCommandPath `
            -SourceSha256 $SourceSha256 `
            -Results $Results
        $null = Write-AtomicJsonFile -Path $LastRunStatusFile -InputObject $LastRunRecord
        Write-Log "Last-run status saved to: $LastRunStatusFile" -Level Info
    }
    catch {
        Write-Log "Could not persist last-run status: $($_.Exception.Message)" -Level Warning
        if ($FinalExitCode -eq 0) { $FinalExitCode = 2 }
    }

    Write-Log "" -Level Info
    if ($KeepOpenMinutes -gt 0) {
        $CloseAt = (Get-Date).AddMinutes($KeepOpenMinutes)
        Write-Log "Update process completed. Keeping this window open until $($CloseAt.ToString('yyyy-MM-dd HH:mm')) unless you close it first." -Level Info
        Start-Sleep -Seconds ($KeepOpenMinutes * 60)
    }
    elseif ($NoPause) {
        Write-Log "Update process completed." -Level Info
    }
    else {
        Write-Log "Update process completed. Press Enter to close this window..." -Level Info
        Read-Host
    }
}

exit $FinalExitCode

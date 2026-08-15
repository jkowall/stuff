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
    [switch]$SkipWinget,
    [switch]$SkipWindowsStore,
    [switch]$SkipNpm,
    [switch]$SkipWsl,
    [switch]$SkipPip,
    [switch]$Elevated,
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
$MachineName = $env:COMPUTERNAME
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$LogFile = Join-Path $LogDir "${ScriptName}_${MachineName}_$Timestamp.log"
$LastRunStatusFile = Join-Path $LogDir "${ScriptName}_${MachineName}_last-run.json"

# Track results for summary
$Results = @{
    Execution       = @{ Status = "Skipped"; Message = "" }
    Winget          = @{ Status = "Skipped"; Message = "" }
    WindowsStore    = @{ Status = "Skipped"; Message = "" }
    ChocolateyAdmin = @{ Status = "Skipped"; Message = "" }
    Npm             = @{ Status = "Skipped"; Message = "" }
    Wsl             = @{ Status = "Skipped"; Message = "" }
    Pip             = @{ Status = "Skipped"; Message = "" }
}
$FinalExitCode = 0
$UpdateMutexName = "Global\Stuff.UpdateAllPackages.Win"

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

function Restore-WingetPackageServiceState {
    [CmdletBinding()]
    param(
        $ServiceState,
        [timespan]$Timeout = ([timespan]::FromSeconds(30))
    )

    if (-not $ServiceState -or -not $ServiceState.WasRunning) { return "Skipped" }

    $Service = Get-Service -Name $ServiceState.Name -ErrorAction Stop
    if ("$($Service.Status)" -eq "Running") { return "Running" }

    Start-Service -Name $ServiceState.Name -ErrorAction Stop
    $Service = Get-Service -Name $ServiceState.Name -ErrorAction Stop
    $Service.WaitForStatus("Running", $Timeout)
    $Service.Refresh()

    if ("$($Service.Status)" -ne "Running") {
        throw "Service '$($ServiceState.Name)' did not reach the Running state within $([int]$Timeout.TotalSeconds) seconds."
    }

    return "Restored"
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
        $ExplicitResult = Invoke-WingetExplicitUpgrades -WingetPath $WingetPath -Source "winget" -PackageIds $ExplicitIds

        if ($ExplicitResult.Failed.Count -eq 0) {
            $script:Results.Winget.Status = "Success"
            if ($ExplicitResult.Succeeded -gt 0) {
                $script:Results.Winget.Message = "Winget packages updated successfully ($($ExplicitResult.Succeeded) explicit checks; skipped: $($WingetExcludeIds -join ', '))"
            }
            else {
                $script:Results.Winget.Message = "Winget packages updated successfully (skipped: $($WingetExcludeIds -join ', '))"
            }
        }
        else {
            $script:Results.Winget.Status = "Warning"
            if ($ExplicitResult.Failed.Count -gt 0) {
                $script:Results.Winget.Message = "Winget completed with issues; failed explicit upgrades: $($ExplicitResult.Failed -join ', ')"
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

function Update-WindowsStore {
    Write-Log ("=" * 60) -Level Info
    Write-Log "STARTING WINDOWS STORE UPDATES" -Level Info
    Write-Log ("=" * 60) -Level Info

    try {
        $WingetPath = Get-WingetCommand
        Write-Log "Found winget at: $($WingetPath.Source)" -Level Info

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
                $InstallResult = Invoke-NpmInstall -NpmCommand $NpmPath.Source -Arguments @(
                    "install", "-g", "--prefix", $NpmPrefix, "--loglevel=error",
                    "--strict-allow-scripts", "--allow-scripts=@github/keytar,node-pty", "$PackageName@$TargetVersion"
                )
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

    # Final notification
    if ($ExitCode -eq 1) {
        Show-ToastNotification -Title "Package Updates Completed with Errors" -Message "Check the log for details: $LogFile" -Type Warning | Out-Null
        return 1
    }
    elseif ($ExitCode -eq 2) {
        Show-ToastNotification -Title "Package Updates Completed with Warnings" -Message "Some updates need attention. Check the log: $LogFile" -Type Warning | Out-Null
        return 2
    }
    else {
        Show-ToastNotification -Title "Package Updates Completed" -Message "All package managers updated successfully!" -Type Info | Out-Null
        return 0
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

Write-Log ("=" * 60) -Level Info
Write-Log "PACKAGE UPDATE STARTED (Elevated=$Elevated, Admin=$IsAdmin)" -Level Info
Write-Log "Script Directory: $ScriptDir" -Level Info
Write-Log "Log File: $LogFile" -Level Info
Write-Log ("=" * 60) -Level Info

# Check for Data Saver / Metered Connection
if (Test-DataSaver) {
    $Results.Execution.Status = "Warning"
    $Results.Execution.Message = "Metered connection (Data Saver) detected. Skipping auto updates to conserve data."
    $FinalExitCode = 2
    Write-Log $Results.Execution.Message -Level Warning
    Show-ToastNotification -Title "Package Updates Skipped" -Message "Metered connection detected. Updates deferred to save data." -Type Warning

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
$LogPattern = Join-Path $LogDir "${ScriptName}_${MachineName}_*.log"
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
            if (-not $SkipWinget) { Update-Winget }
            if (-not $SkipWindowsStore) { Update-WindowsStore }
            if (-not $SkipAdminChocolatey) { Update-Chocolatey }
            if (-not $SkipNpm) { Update-NpmGlobal }
            if (-not $SkipWsl) { Update-WslPackages }
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

if ($Elevated -or $IsAdmin) {
    # Only show summary and completion wait in the "active" or final process
    $SummaryExitCode = Show-Summary
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

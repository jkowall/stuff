#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$TestsRun = 0
$TestRoot = $null

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:TestsRun++
    if ($Expected -ne $Actual) {
        throw "$Message Expected='$Expected' Actual='$Actual'"
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:TestsRun++
    if (-not $Condition) { throw $Message }
}

function Assert-SequenceEqual {
    param(
        [object[]]$Expected,
        [object[]]$Actual,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:TestsRun++
    if ($Expected.Count -ne $Actual.Count) {
        throw "$Message ExpectedCount=$($Expected.Count) ActualCount=$($Actual.Count)"
    }
    for ($Index = 0; $Index -lt $Expected.Count; $Index++) {
        if ("$($Expected[$Index])" -cne "$($Actual[$Index])") {
            throw "$Message DifferenceAt=$Index Expected='$($Expected[$Index])' Actual='$($Actual[$Index])'"
        }
    }
}

function Assert-PowerShellSyntax {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Tokens = $null
    $ParseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$ParseErrors) | Out-Null
    Assert-Equal -Expected 0 -Actual (@($ParseErrors).Count) -Message "PowerShell syntax errors in $Path."
}

try {
    $WindowsDirectory = Split-Path $PSScriptRoot -Parent
    $CorePath = Join-Path $WindowsDirectory "Update-AllPackages_Win.Core.ps1"
    $UpdaterPath = Join-Path $WindowsDirectory "Update-AllPackages_Win.ps1"
    $SetupPath = Join-Path $WindowsDirectory "Setup-PackageUpdateTasks.ps1"
    $FixturePath = Join-Path (Join-Path $PSScriptRoot "fixtures") "winget-cases.json"

    foreach ($ScriptPath in @($CorePath, $UpdaterPath, $SetupPath, $PSCommandPath)) {
        Assert-PowerShellSyntax -Path $ScriptPath
    }

    $UpdaterSource = Get-Content -LiteralPath $UpdaterPath -Raw -ErrorAction Stop
    Assert-True `
        -Condition ($UpdaterSource.Contains('Get-NpmTrustedNativeRebuildArguments -NpmPrefix $NpmPrefix')) `
        -Message "Updater did not use the tested trusted-native npm rebuild arguments."
    Assert-True `
        -Condition ($UpdaterSource.Contains('Get-NpmGenericInstallArguments')) `
        -Message "Updater did not use the tested generic npm install arguments."
    Assert-True `
        -Condition ($UpdaterSource.Contains('Invoke-WingetExplicitUpgrades -WingetPath $WingetPath -Source "winget" -PackageIds $ExecutionPlan.Elevated')) `
        -Message "Updater did not restrict elevated Winget execution to the elevation-aware plan."
    Assert-True `
        -Condition ($UpdaterSource.Contains('$UserWingetTaskName = "Weekly Package Updates - User Winget"')) `
        -Message "Updater user-context task name changed without matching test coverage."
    Assert-True `
        -Condition ($UpdaterSource.Contains('Update-SabnzbdFromOfficialRelease')) `
        -Message "Updater did not invoke the official SABnzbd release fallback."
    Assert-True `
        -Condition ($UpdaterSource.Contains('[System.IO.FileMode]::CreateNew')) `
        -Message "SABnzbd restart requests were not created atomically."
    Assert-True `
        -Condition ($UpdaterSource.Contains('[guid]::NewGuid().ToString("N")')) `
        -Message "SABnzbd restart requests did not use unpredictable marker names."
    Assert-True `
        -Condition (-not $UpdaterSource.Contains('$SabnzbdRestartMarkerPath = Join-Path')) `
        -Message "Updater retained a predictable elevated SABnzbd restart marker path."
    Assert-True `
        -Condition ($UpdaterSource.Contains('[Environment+SpecialFolder]::ProgramFiles') -and
            $UpdaterSource.Contains('$Security.SetAccessRuleProtection($true, $false)')) `
        -Message "SABnzbd installer staging was not placed beneath a protected administrative root."
    Assert-True `
        -Condition ($UpdaterSource.Contains('[System.IO.Directory]::Delete($FullTemporaryDirectory, $false)') -and
            -not $UpdaterSource.Contains('[System.IO.Directory]::Delete($FullTemporaryDirectory, $true)')) `
        -Message "SABnzbd installer staging cleanup was not exact and non-recursive."
    Assert-True `
        -Condition ($UpdaterSource.Contains('elseif ($Elevated)')) `
        -Message "Elevated child logging was not separated from the non-elevated parent log."
    Assert-True `
        -Condition ($UpdaterSource.Contains('Start-ServiceWithRetry -Name "SABnzbd"')) `
        -Message "SABnzbd service restart did not reuse the retrying Start-ServiceWithRetry helper."

    $UpdaterTokens = $null
    $UpdaterParseErrors = $null
    $UpdaterAst = [System.Management.Automation.Language.Parser]::ParseFile($UpdaterPath, [ref]$UpdaterTokens, [ref]$UpdaterParseErrors)
    $ExpectedWingetLockCalls = [ordered]@{
        "Update-UserContextWinget" = 1
        "Update-Winget"            = 2
        "Update-SabnzbdFromOfficialRelease" = 1
        "Update-WindowsStore"       = 1
    }
    foreach ($FunctionName in $ExpectedWingetLockCalls.Keys) {
        $FunctionAst = $UpdaterAst.Find({
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $FunctionName
            }, $true)
        $LockCallCount = [regex]::Matches(
            $FunctionAst.Extent.Text,
            [regex]::Escape('Enter-PackageUpdateFileLock -Path $WingetLockPath')
        ).Count
        Assert-Equal `
            -Expected $ExpectedWingetLockCalls[$FunctionName] `
            -Actual $LockCallCount `
            -Message "$FunctionName did not hold the shared WinGet lock at every expected call site."
    }
    foreach ($FunctionName in @(
            "Get-WingetPackageServiceState",
            "Start-ServiceWithRetry",
            "Restore-WingetPackageServiceState",
            "Test-UserWingetScheduledTaskDefinition",
            "Invoke-UserWingetScheduledUpdate"
        )) {
        $FunctionAst = $UpdaterAst.Find({
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $FunctionName
            }, $true)
        Assert-True -Condition ($null -ne $FunctionAst) -Message "Updater did not define $FunctionName."
        Invoke-Expression $FunctionAst.Extent.Text
    }

    $script:MockService = $null
    $script:MockStartServiceCalls = 0
    $script:MockStartServiceFailure = $false
    $script:MockStartServiceFailuresRemaining = 0
    function Get-Service {
        [CmdletBinding()]
        param([string]$Name)

        if ($script:MockService -and $script:MockService.Name -eq $Name) { return $script:MockService }
        return $null
    }
    function Start-Service {
        [CmdletBinding()]
        param([string]$Name)

        $script:MockStartServiceCalls++
        if ($script:MockStartServiceFailuresRemaining -gt 0) {
            $script:MockStartServiceFailuresRemaining--
            throw "mock service start failure"
        }
        if ($script:MockStartServiceFailure) { throw "mock service start failure" }
    }
    function Write-Log {
        param($Message, [string]$Level = "Info")
    }

    Assert-Equal -Expected $null -Actual (Get-WingetPackageServiceState -PackageId "Beeper.Beeper") -Message "Unrelated Winget package unexpectedly mapped to a service."

    $script:MockService = [pscustomobject]@{ Name = "cloudflared"; Status = "Running" }
    $script:MockService | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($DesiredStatus, $Timeout) $this.Status = "$DesiredStatus" }
    $script:MockService | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
    $CloudflaredState = Get-WingetPackageServiceState -PackageId "Cloudflare.cloudflared"
    Assert-Equal -Expected "cloudflared" -Actual $CloudflaredState.Name -Message "Cloudflared package mapped to the wrong service."
    Assert-Equal -Expected $true -Actual $CloudflaredState.WasRunning -Message "Cloudflared running state was not captured."
    Assert-Equal -Expected "Running" -Actual (Restore-WingetPackageServiceState -ServiceState $CloudflaredState) -Message "An already-running cloudflared service was not preserved."
    Assert-Equal -Expected 0 -Actual $script:MockStartServiceCalls -Message "An already-running cloudflared service was restarted unnecessarily."

    $script:MockService.Status = "Stopped"
    Assert-Equal -Expected "Restored" -Actual (Restore-WingetPackageServiceState -ServiceState $CloudflaredState) -Message "A stopped cloudflared service was not restored."
    Assert-Equal -Expected 1 -Actual $script:MockStartServiceCalls -Message "Cloudflared service restore did not invoke Start-Service exactly once."
    Assert-Equal -Expected "Running" -Actual $script:MockService.Status -Message "Cloudflared service did not reach the Running state after restore."

    $script:MockService.Status = "Stopped"
    $script:MockStartServiceCalls = 0
    $script:MockStartServiceFailuresRemaining = 1
    Assert-Equal -Expected "Restored" -Actual (Restore-WingetPackageServiceState -ServiceState $CloudflaredState -RetryCount 2 -RetryDelay ([timespan]::Zero)) -Message "Cloudflared service was not restored after a transient Start-Service failure."
    Assert-Equal -Expected 2 -Actual $script:MockStartServiceCalls -Message "Restore did not retry Start-Service after a transient failure."

    $script:MockService.Status = "Stopped"
    $script:MockStartServiceCalls = 0
    $script:MockStartServiceFailuresRemaining = 0
    $script:MockStartServiceFailure = $true
    $RestoreFailed = $false
    try {
        Restore-WingetPackageServiceState -ServiceState $CloudflaredState -RetryCount 2 -RetryDelay ([timespan]::Zero) | Out-Null
    }
    catch {
        $RestoreFailed = $true
    }
    Assert-Equal -Expected $true -Actual $RestoreFailed -Message "Cloudflared service start failure was not surfaced."
    Assert-Equal -Expected 2 -Actual $script:MockStartServiceCalls -Message "Restore did not exhaust the configured retry count before surfacing failure."

    $script:MockScheduledTaskStarted = $false
    $script:MockScheduledTaskStopped = $false
    $script:MockScheduledTaskCompletes = $true
    $script:MockScheduledTaskResult = 0
    $script:MockScheduledTaskRunLevel = "Limited"
    $script:MockScheduledTaskState = $null
    $script:MockScheduledTaskInfoPolls = 0
    $script:MockStartScheduledTaskCalls = 0
    $script:MockStopScheduledTaskCalls = 0
    $script:MockExternalStartOnBaseline = $false
    $script:MockScheduledTaskBefore = [datetime]::Parse("2026-09-05T20:00:00Z")
    $script:MockScheduledTaskAfter = [datetime]::Parse("2026-09-05T20:01:00Z")
    $script:MockUpdaterPath = (Resolve-Path $UpdaterPath).Path
    $script:MockTaskUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    function Get-ScheduledTask {
        [CmdletBinding()]
        param(
            [string]$TaskName,
            [string]$TaskPath
        )

        if ($TaskName -ne "Mock User Winget" -or $TaskPath -ne "\") {
            throw "Unexpected scheduled task lookup: $TaskPath$TaskName"
        }

        $State = if ($script:MockScheduledTaskState) { $script:MockScheduledTaskState } else { "Ready" }
        if ($script:MockScheduledTaskStarted -and -not $script:MockScheduledTaskStopped) {
            if (-not $script:MockScheduledTaskCompletes -or $script:MockScheduledTaskInfoPolls -le 1) {
                $State = "Running"
            }
        }

        return [pscustomobject]@{
            State     = $State
            Principal = [pscustomobject]@{
                RunLevel = $script:MockScheduledTaskRunLevel
                LogonType = "Interactive"
                UserId = $script:MockTaskUser
            }
            Actions = @([pscustomobject]@{
                    Execute = "powershell.exe"
                    Arguments = "-File `"$($script:MockUpdaterPath)`" -UserWingetOnly -NoPause"
                })
        }
    }
    function Get-ScheduledTaskInfo {
        [CmdletBinding()]
        param(
            [string]$TaskName,
            [string]$TaskPath
        )

        if ($TaskName -ne "Mock User Winget" -or $TaskPath -ne "\") {
            throw "Unexpected scheduled task info lookup: $TaskPath$TaskName"
        }
        if ($script:MockExternalStartOnBaseline -and -not $script:MockScheduledTaskStarted) {
            $script:MockExternalStartOnBaseline = $false
            $script:MockScheduledTaskStarted = $true
        }

        if ($script:MockScheduledTaskStarted -and -not $script:MockScheduledTaskStopped) {
            $script:MockScheduledTaskInfoPolls++
        }
        $RunStarted = $script:MockScheduledTaskStarted -and -not $script:MockScheduledTaskStopped
        $Running = $RunStarted -and (-not $script:MockScheduledTaskCompletes -or $script:MockScheduledTaskInfoPolls -le 1)
        return [pscustomobject]@{
            LastRunTime    = if ($RunStarted) { $script:MockScheduledTaskAfter } else { $script:MockScheduledTaskBefore }
            LastTaskResult = if ($Running) { 267009 } else { $script:MockScheduledTaskResult }
        }
    }
    function Start-ScheduledTask {
        [CmdletBinding()]
        param(
            [string]$TaskName,
            [string]$TaskPath
        )

        if ($TaskName -ne "Mock User Winget" -or $TaskPath -ne "\") {
            throw "Unexpected scheduled task start: $TaskPath$TaskName"
        }

        $script:MockStartScheduledTaskCalls++
        $script:MockScheduledTaskStarted = $true
    }
    function Stop-ScheduledTask {
        [CmdletBinding()]
        param(
            [string]$TaskName,
            [string]$TaskPath
        )

        if ($TaskName -ne "Mock User Winget" -or $TaskPath -ne "\") {
            throw "Unexpected scheduled task stop: $TaskPath$TaskName"
        }

        $script:MockStopScheduledTaskCalls++
        $script:MockScheduledTaskStopped = $true
    }
    function Start-Sleep {
        param([int]$Milliseconds)
    }

    Assert-Equal `
        -Expected 0 `
        -Actual (Invoke-UserWingetScheduledUpdate -TaskName "Mock User Winget" -TaskPath "\" -ExpectedScriptPath $UpdaterPath -Timeout ([timespan]::FromSeconds(1)) -PollIntervalMilliseconds 1) `
        -Message "Limited user-context task success was not propagated."
    Assert-Equal -Expected 1 -Actual $script:MockStartScheduledTaskCalls -Message "User-context task was not started exactly once."
    Assert-Equal -Expected $false -Actual $script:UserWingetTaskMayBeRunning -Message "Completed user-context task remained marked active."

    $script:MockScheduledTaskStarted = $false
    $script:MockScheduledTaskStopped = $false
    $script:MockScheduledTaskInfoPolls = 0
    $script:MockStartScheduledTaskCalls = 0
    $script:MockExternalStartOnBaseline = $true
    Assert-Equal `
        -Expected 0 `
        -Actual (Invoke-UserWingetScheduledUpdate -TaskName "Mock User Winget" -TaskPath "\" -ExpectedScriptPath $UpdaterPath -Timeout ([timespan]::FromSeconds(1)) -PollIntervalMilliseconds 1) `
        -Message "An externally started user-context task was not joined successfully."
    Assert-Equal -Expected 0 -Actual $script:MockStartScheduledTaskCalls -Message "An already active user-context task was redundantly started."

    $script:MockScheduledTaskStarted = $false
    $script:MockScheduledTaskStopped = $false
    $script:MockScheduledTaskInfoPolls = 0
    $script:MockScheduledTaskResult = 2
    Assert-Equal `
        -Expected 2 `
        -Actual (Invoke-UserWingetScheduledUpdate -TaskName "Mock User Winget" -TaskPath "\" -ExpectedScriptPath $UpdaterPath -Timeout ([timespan]::FromSeconds(1)) -PollIntervalMilliseconds 1) `
        -Message "Limited user-context task warning was not propagated."

    $script:MockScheduledTaskStarted = $false
    $script:MockScheduledTaskStopped = $false
    $script:MockScheduledTaskInfoPolls = 0
    $script:MockScheduledTaskCompletes = $false
    $TaskWaitTimedOut = $false
    try {
        Invoke-UserWingetScheduledUpdate `
            -TaskName "Mock User Winget" `
            -TaskPath "\" `
            -ExpectedScriptPath $UpdaterPath `
            -Timeout ([timespan]::FromMilliseconds(10)) `
            -PollIntervalMilliseconds 1 | Out-Null
    }
    catch {
        $TaskWaitTimedOut = ($_.Exception.Message -like "Timed out*")
    }
    Assert-Equal -Expected $true -Actual $TaskWaitTimedOut -Message "User-context task timeout was not surfaced."
    Assert-Equal -Expected 1 -Actual $script:MockStopScheduledTaskCalls -Message "Timed-out user-context task was not stopped."
    Assert-Equal -Expected $false -Actual $script:UserWingetTaskMayBeRunning -Message "Stopped user-context task remained marked active."

    $script:MockScheduledTaskCompletes = $true
    $script:MockScheduledTaskStarted = $false
    $script:MockScheduledTaskStopped = $false
    $script:MockScheduledTaskRunLevel = "Highest"
    $WrongRunLevelRejected = $false
    try {
        Invoke-UserWingetScheduledUpdate -TaskName "Mock User Winget" -TaskPath "\" -ExpectedScriptPath $UpdaterPath | Out-Null
    }
    catch {
        $WrongRunLevelRejected = ($_.Exception.Message -like "*not configured to run with limited privileges*")
    }
    Assert-Equal -Expected $true -Actual $WrongRunLevelRejected -Message "An elevated user-context helper task was not rejected."

    $script:MockScheduledTaskRunLevel = "Limited"
    $script:MockScheduledTaskState = "Disabled"
    $DisabledTaskRejected = $false
    try {
        Invoke-UserWingetScheduledUpdate -TaskName "Mock User Winget" -TaskPath "\" -ExpectedScriptPath $UpdaterPath | Out-Null
    }
    catch {
        $DisabledTaskRejected = ($_.Exception.Message -like "*is disabled*")
    }
    Assert-Equal -Expected $true -Actual $DisabledTaskRejected -Message "A disabled user-context helper task was not rejected before installation."
    $script:MockScheduledTaskState = $null

    $script:MockScheduledTaskRunLevel = "Highest"
    $script:MockScheduledTaskStarted = $true
    $script:MockScheduledTaskCompletes = $false
    $script:UserWingetTaskMayBeRunning = $false
    try {
        Invoke-UserWingetScheduledUpdate -TaskName "Mock User Winget" -TaskPath "\" -ExpectedScriptPath $UpdaterPath | Out-Null
    }
    catch {}
    Assert-Equal -Expected $true -Actual $script:UserWingetTaskMayBeRunning -Message "A running helper with an invalid definition did not fail closed."
    $script:MockScheduledTaskStarted = $false
    $script:MockScheduledTaskCompletes = $true
    $script:MockScheduledTaskRunLevel = "Limited"
    $script:UserWingetTaskMayBeRunning = $false

    $MeteredBlockStart = $UpdaterSource.IndexOf("if (Test-DataSaver)", [System.StringComparison]::Ordinal)
    Assert-True -Condition ($MeteredBlockStart -ge 0) -Message "Updater did not contain the metered-connection branch."
    $MeteredBlockExit = $UpdaterSource.IndexOf("exit `$FinalExitCode", $MeteredBlockStart, [System.StringComparison]::Ordinal)
    $MeteredStatusWrite = $UpdaterSource.IndexOf("Write-AtomicJsonFile", $MeteredBlockStart, [System.StringComparison]::Ordinal)
    Assert-True -Condition ($MeteredBlockExit -gt $MeteredBlockStart) -Message "Metered-connection branch did not exit with the computed status."
    Assert-True -Condition ($MeteredStatusWrite -gt $MeteredBlockStart -and $MeteredStatusWrite -lt $MeteredBlockExit) -Message "Metered-connection branch did not atomically publish last-run status before exiting."
    $MeteredBlockSource = $UpdaterSource.Substring($MeteredBlockStart, $MeteredBlockExit - $MeteredBlockStart)
    Assert-True -Condition ($MeteredBlockSource.Contains('$Results.Execution.Status = "Warning"')) -Message "Metered-connection branch did not classify the skip as a warning."
    Assert-True -Condition ($MeteredBlockSource.Contains('Restore-SabnzbdUserProcessWithPackageLock')) -Message "Metered-connection handling skipped pending SABnzbd recovery."
    Assert-True -Condition ($MeteredBlockSource.Contains('$FinalExitCode = Get-PackageUpdateExitCode -Results $Results')) -Message "Metered-connection branch did not preserve phase errors in its exit code."

    . $CorePath

    Assert-SequenceEqual `
        -Expected @("Spotify.Spotify") `
        -Actual @(Get-UserContextWingetPackageIds) `
        -Message "User-context Winget package allowlist was incorrect."

    $WingetExecutionPlan = Split-WingetUpgradeIdsByContext -PackageIds @(
        "Cloudflare.cloudflared",
        "Spotify.Spotify",
        "Beeper.Beeper",
        "Spotify.Spotify"
    )
    Assert-SequenceEqual `
        -Expected @("Cloudflare.cloudflared", "Beeper.Beeper") `
        -Actual @($WingetExecutionPlan.Elevated) `
        -Message "Elevated Winget routing removed or reordered the wrong package IDs."
    Assert-SequenceEqual `
        -Expected @("Spotify.Spotify") `
        -Actual @($WingetExecutionPlan.UserContext) `
        -Message "Spotify was not routed exclusively to the user context."

    $Fixtures = Get-Content -LiteralPath $FixturePath -Raw -ErrorAction Stop | ConvertFrom-Json
    foreach ($Case in $Fixtures.parserCases) {
        $ActualIds = @(ConvertFrom-WingetUpgradeOutput `
            -Output @($Case.output) `
            -Source $Case.source `
            -ExcludePackageIds @($Case.excludePackageIds))
        Assert-SequenceEqual -Expected @($Case.expectedIds) -Actual $ActualIds -Message "WinGet parser case failed: $($Case.name)."
    }

    foreach ($Case in $Fixtures.exitCodeCases) {
        $ActualClassification = Test-WingetNoApplicableExitCode -ExitCode $Case.code
        Assert-Equal -Expected $Case.noApplicable -Actual $ActualClassification -Message "WinGet exit-code classification failed for $($Case.code)."
    }

    $CleanResults = [ordered]@{
        Execution = @{ Status = "Success"; Message = "done" }
        Winget    = @{ Status = "Success"; Message = "done" }
        Npm       = @{ Status = "Skipped"; Message = "" }
    }
    Assert-Equal -Expected 0 -Actual (Get-PackageUpdateExitCode -Results $CleanResults) -Message "Clean aggregate exit code was incorrect."

    $WarningResults = [ordered]@{
        Execution = @{ Status = "Success"; Message = "done" }
        Winget    = @{ Status = "Warning"; Message = "partial" }
    }
    Assert-Equal -Expected 2 -Actual (Get-PackageUpdateExitCode -Results $WarningResults) -Message "Warning aggregate exit code was incorrect."

    $ErrorResults = [ordered]@{
        Execution = @{ Status = "Error"; Message = "failed" }
        Winget    = @{ Status = "Warning"; Message = "partial" }
    }
    Assert-Equal -Expected 1 -Actual (Get-PackageUpdateExitCode -Results $ErrorResults) -Message "Error aggregate exit code was incorrect."

    $NpmPrefix = "C:\Users\TEST\AppData\Roaming\npm"
    $NativeRebuildArguments = @(Get-NpmTrustedNativeRebuildArguments -NpmPrefix $NpmPrefix)
    Assert-SequenceEqual `
        -Expected @(
            "rebuild",
            "-g",
            "--prefix", $NpmPrefix,
            "--loglevel=error",
            "--allow-scripts=@github/keytar,node-pty",
            "@github/keytar",
            "node-pty"
        ) `
        -Actual $NativeRebuildArguments `
        -Message "Trusted native npm rebuild arguments were incorrect."

    $GenericInstallArguments = @(Get-NpmGenericInstallArguments `
        -NpmPrefix $NpmPrefix `
        -PackageName "@google/gemini-cli" `
        -TargetVersion "1.2.3")
    Assert-SequenceEqual `
        -Expected @(
            "install",
            "-g",
            "--prefix", $NpmPrefix,
            "--loglevel=error",
            "--strict-allow-scripts",
            "--allow-scripts=@github/keytar,node-pty",
            "@google/gemini-cli@1.2.3"
        ) `
        -Actual $GenericInstallArguments `
        -Message "Generic npm install arguments granted unexpected lifecycle scripts."

    $PnpmInstallArguments = @(Get-NpmGenericInstallArguments `
        -NpmPrefix $NpmPrefix `
        -PackageName "pnpm" `
        -TargetVersion "12.3.4")
    Assert-SequenceEqual `
        -Expected @(
            "install",
            "-g",
            "--prefix", $NpmPrefix,
            "--loglevel=error",
            "--strict-allow-scripts",
            "--allow-scripts=@github/keytar,node-pty,pnpm@12.3.4",
            "pnpm@12.3.4"
        ) `
        -Actual $PnpmInstallArguments `
        -Message "pnpm did not receive an exact-version lifecycle-script approval."
    Assert-Equal `
        -Expected $false `
        -Actual (@($PnpmInstallArguments) -contains "--dangerously-allow-all-scripts") `
        -Message "pnpm install arguments enabled arbitrary lifecycle scripts."

    $PnpmLatestArguments = @(Get-NpmGenericInstallArguments `
        -NpmPrefix $NpmPrefix `
        -PackageName "pnpm" `
        -TargetVersion "latest")
    Assert-True `
        -Condition (@($PnpmLatestArguments) -contains "--allow-scripts=@github/keytar,node-pty,pnpm") `
        -Message "pnpm latest fallback used an invalid versioned lifecycle-script approval."

    function New-TestSabnzbdRelease {
        param(
            [string]$Tag = "5.1.2",
            [bool]$Draft = $false,
            [bool]$Prerelease = $false,
            [string]$Url = "",
            [AllowEmptyString()]
            [string]$Digest = "sha256:fce78f1e9d2018c78467420840c7e218b0f5163c8681744ec626072383afaa4c",
            [string]$State = "uploaded",
            [int64]$Size = 23992456,
            [int]$AssetCount = 1
        )

        $AssetName = "SABnzbd-$Tag-win-setup.exe"
        if (-not $Url) {
            $Url = "https://github.com/sabnzbd/sabnzbd/releases/download/$Tag/$AssetName"
        }
        $Assets = @(
            for ($Index = 0; $Index -lt $AssetCount; $Index++) {
                [pscustomobject]@{
                    name                 = $AssetName
                    state                = $State
                    size                 = $Size
                    digest               = $Digest
                    browser_download_url = $Url
                }
            }
        )
        return [pscustomobject]@{
            tag_name   = $Tag
            draft      = $Draft
            prerelease = $Prerelease
            assets     = $Assets
        }
    }

    $SabnzbdRelease = New-TestSabnzbdRelease
    $SabnzbdPlan = Get-SabnzbdOfficialUpdatePlan `
        -InstalledVersion "5.0.4" `
        -Release $SabnzbdRelease
    Assert-Equal -Expected "5.1.2" -Actual $SabnzbdPlan.TargetVersionText -Message "Official SABnzbd target version was incorrect."
    Assert-Equal -Expected $true -Actual $SabnzbdPlan.NeedsUpdate -Message "Older SABnzbd installation did not require an update."
    Assert-Equal -Expected "SABnzbd-5.1.2-win-setup.exe" -Actual $SabnzbdPlan.AssetName -Message "Official SABnzbd installer name was incorrect."
    Assert-Equal `
        -Expected "FCE78F1E9D2018C78467420840C7E218B0F5163C8681744EC626072383AFAA4C" `
        -Actual $SabnzbdPlan.Sha256 `
        -Message "Official SABnzbd SHA-256 digest was not normalized."
    Assert-Equal `
        -Expected $false `
        -Actual (Get-SabnzbdOfficialUpdatePlan -InstalledVersion "5.1.2" -Release $SabnzbdRelease).NeedsUpdate `
        -Message "Current SABnzbd installation incorrectly required an update."
    Assert-Equal `
        -Expected $false `
        -Actual (Get-SabnzbdOfficialUpdatePlan -InstalledVersion "5.2.0" -Release $SabnzbdRelease).NeedsUpdate `
        -Message "Newer SABnzbd installation was incorrectly selected for downgrade."

    $RejectedSabnzbdReleases = @(
        @{ Label = "draft"; Release = (New-TestSabnzbdRelease -Draft $true) },
        @{ Label = "prerelease"; Release = (New-TestSabnzbdRelease -Prerelease $true) },
        @{ Label = "non-numeric tag"; Release = (New-TestSabnzbdRelease -Tag "v5.1.2") },
        @{ Label = "wrong host"; Release = (New-TestSabnzbdRelease -Url "https://example.com/SABnzbd-5.1.2-win-setup.exe") },
        @{ Label = "missing digest"; Release = (New-TestSabnzbdRelease -Digest "") },
        @{ Label = "pending asset"; Release = (New-TestSabnzbdRelease -State "new") },
        @{ Label = "duplicate asset"; Release = (New-TestSabnzbdRelease -AssetCount 2) }
    )
    foreach ($Case in $RejectedSabnzbdReleases) {
        $ReleaseRejected = $false
        try {
            Get-SabnzbdOfficialUpdatePlan -InstalledVersion "5.0.4" -Release $Case.Release | Out-Null
        }
        catch {
            $ReleaseRejected = $true
        }
        Assert-Equal -Expected $true -Actual $ReleaseRejected -Message "Unsafe SABnzbd $($Case.Label) metadata was accepted."
    }

    $SabnzbdTrustParameters = @{
        ExpectedSha256 = "FCE78F1E9D2018C78467420840C7E218B0F5163C8681744EC626072383AFAA4C"
        ActualSha256   = "fce78f1e9d2018c78467420840c7e218b0f5163c8681744ec626072383afaa4c"
        SignatureStatus = "Valid"
        SignerSubject  = "CN=SignPath Foundation, O=SignPath Foundation, L=Lewes, S=Delaware, C=US"
        CompanyName    = "The SABnzbd-Team"
        ProductName    = "SABnzbd 5.1.2"
        ProductVersion = "5.1.2"
        ExpectedVersion = "5.1.2"
    }
    Assert-Equal `
        -Expected $true `
        -Actual (Confirm-SabnzbdInstallerTrust @SabnzbdTrustParameters) `
        -Message "Trusted official SABnzbd installer metadata was rejected."

    $RejectedTrustValues = @(
        @{ Label = "hash"; Key = "ActualSha256"; Value = ("0" * 64) },
        @{ Label = "signature status"; Key = "SignatureStatus"; Value = "HashMismatch" },
        @{ Label = "signer"; Key = "SignerSubject"; Value = "CN=Unexpected Publisher" },
        @{ Label = "company"; Key = "CompanyName"; Value = "Unexpected Publisher" },
        @{ Label = "product version"; Key = "ProductVersion"; Value = "5.1.1" }
    )
    foreach ($Case in $RejectedTrustValues) {
        $Parameters = $SabnzbdTrustParameters.Clone()
        $Parameters[$Case.Key] = $Case.Value
        $TrustRejected = $false
        try {
            Confirm-SabnzbdInstallerTrust @Parameters | Out-Null
        }
        catch {
            $TrustRejected = $true
        }
        Assert-Equal -Expected $true -Actual $TrustRejected -Message "Unsafe SABnzbd $($Case.Label) metadata was accepted."
    }

    $TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("windows-updater-tests.{0}" -f [guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::CreateDirectory($TestRoot) | Out-Null
    $PackageLockPath = Join-Path $TestRoot "winget.lock"
    $FirstPackageLock = Enter-PackageUpdateFileLock -Path $PackageLockPath -Timeout ([timespan]::Zero)
    $ConcurrentLockRejected = $false
    try {
        try {
            $UnexpectedLock = Enter-PackageUpdateFileLock -Path $PackageLockPath -Timeout ([timespan]::Zero)
            $UnexpectedLock.Dispose()
        }
        catch {
            $ConcurrentLockRejected = ($_.Exception.Message -like "Timed out*waiting for package update lock*")
        }
    }
    finally {
        $FirstPackageLock.Dispose()
    }
    Assert-Equal -Expected $true -Actual $ConcurrentLockRejected -Message "Concurrent WinGet execution was not blocked by the shared file lock."
    $ReacquiredPackageLock = Enter-PackageUpdateFileLock -Path $PackageLockPath -Timeout ([timespan]::Zero)
    $ReacquiredPackageLock.Dispose()
    Assert-Equal -Expected $true -Actual ([System.IO.File]::Exists($PackageLockPath)) -Message "WinGet file lock could not be reacquired after release."
    $StatusPath = Join-Path $TestRoot "Update-AllPackages_Win_TEST_last-run.json"
    $StartedAt = [datetime]::Parse("2026-08-08T05:00:00Z").ToUniversalTime()
    $CompletedAt = [datetime]::Parse("2026-08-08T05:04:00Z").ToUniversalTime()

    $CleanRecord = New-PackageUpdateLastRunRecord `
        -ScriptName "Update-AllPackages_Win" `
        -MachineName "TEST" `
        -StartedAt $StartedAt `
        -UpdatesCompletedAt $CompletedAt `
        -ExitCode 0 `
        -KeepOpenMinutes 720 `
        -LogFile "C:\logs\test.log" `
        -SourcePath "C:\scripts\Update-AllPackages_Win.ps1" `
        -SourceSha256 "ABCDEF" `
        -Results $CleanResults
    $null = Write-AtomicJsonFile -Path $StatusPath -InputObject $CleanRecord

    $WrittenRecord = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
    Assert-Equal -Expected 1 -Actual $WrittenRecord.schemaVersion -Message "Last-run schema version was incorrect."
    Assert-Equal -Expected 0 -Actual $WrittenRecord.exitCode -Message "Initial last-run exit code was incorrect."
    Assert-Equal -Expected "clean" -Actual $WrittenRecord.outcome -Message "Initial last-run outcome was incorrect."
    Assert-Equal -Expected 720 -Actual $WrittenRecord.keepOpenMinutes -Message "Last-run keep-open duration was incorrect."
    Assert-Equal -Expected "abcdef" -Actual $WrittenRecord.source.sha256 -Message "Last-run source hash was not normalized."
    Assert-Equal -Expected "Success" -Actual $WrittenRecord.phases.Execution.status -Message "Last-run phase status was incorrect."

    $WarningRecord = New-PackageUpdateLastRunRecord `
        -ScriptName "Update-AllPackages_Win" `
        -MachineName "TEST" `
        -StartedAt $StartedAt `
        -UpdatesCompletedAt $CompletedAt.AddMinutes(1) `
        -ExitCode 2 `
        -KeepOpenMinutes 720 `
        -LogFile "C:\logs\test.log" `
        -SourcePath "C:\scripts\Update-AllPackages_Win.ps1" `
        -SourceSha256 "123456" `
        -Results $WarningResults
    $null = Write-AtomicJsonFile -Path $StatusPath -InputObject $WarningRecord

    $ReplacedRecord = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
    Assert-Equal -Expected 2 -Actual $ReplacedRecord.exitCode -Message "Atomic replacement did not publish the new exit code."
    Assert-Equal -Expected "warning" -Actual $ReplacedRecord.outcome -Message "Atomic replacement did not publish the new outcome."
    Assert-Equal -Expected 0 -Actual (@([System.IO.Directory]::GetFiles($TestRoot, "*.tmp")).Count) -Message "Atomic writer left temporary files behind."
    Assert-Equal -Expected 0 -Actual (@([System.IO.Directory]::GetFiles($TestRoot, "*.bak")).Count) -Message "Atomic writer left backup files behind after a successful replacement."

    $PowerShellExecutable = @(
        (Join-Path $PSHOME "powershell.exe"),
        (Join-Path $PSHOME "pwsh.exe"),
        (Join-Path $PSHOME "pwsh")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $PowerShellExecutable) {
        throw "Could not locate the current PowerShell executable under $PSHOME."
    }

    $RenderOutput = @(& $PowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $SetupPath -RenderOnly 2>&1)
    $RenderExitCode = $LASTEXITCODE
    $RenderText = ($RenderOutput | ForEach-Object { "$_" }) -join [Environment]::NewLine
    Assert-Equal -Expected 0 -Actual $RenderExitCode -Message "Setup render-only mode failed. Output: $RenderText"
    $TaskSpecs = $RenderText | ConvertFrom-Json
    $TaskSpec = $TaskSpecs.weekly
    $UserWingetTaskSpec = $TaskSpecs.userWinget

    $ExpectedWindowsDirectory = (Resolve-Path $WindowsDirectory).Path
    $ExpectedUpdateScript = (Resolve-Path $UpdaterPath).Path
    Assert-Equal -Expected "powershell.exe" -Actual $TaskSpec.action.execute -Message "Rendered task executable was incorrect."
    Assert-Equal -Expected $ExpectedWindowsDirectory -Actual $TaskSpec.action.workingDirectory -Message "Rendered task working directory was incorrect."
    Assert-True -Condition ($TaskSpec.action.arguments.Contains("-File `"$ExpectedUpdateScript`"")) -Message "Rendered task arguments did not quote the updater path."
    Assert-True -Condition ($TaskSpec.action.arguments.Contains("-KeepOpenMinutes 720")) -Message "Rendered task arguments did not retain the 720-minute window."
    Assert-Equal -Expected $true -Actual $TaskSpec.trigger.weekly -Message "Rendered trigger was not weekly."
    Assert-True -Condition (@($TaskSpec.trigger.daysOfWeek) -contains "Saturday") -Message "Rendered trigger did not include Saturday."
    Assert-Equal -Expected "01:00" -Actual $TaskSpec.trigger.at -Message "Rendered trigger time was incorrect."
    Assert-Equal -Expected "IgnoreNew" -Actual $TaskSpec.settings.multipleInstances -Message "Rendered multiple-instance policy was incorrect."
    Assert-Equal -Expected "Interactive" -Actual $TaskSpec.principal.logonType -Message "Rendered logon type was incorrect."
    Assert-Equal -Expected "Highest" -Actual $TaskSpec.principal.runLevel -Message "Rendered run level was incorrect."
    Assert-Equal -Expected "powershell.exe" -Actual $UserWingetTaskSpec.action.execute -Message "Rendered user-context task executable was incorrect."
    Assert-Equal -Expected "Weekly Package Updates - User Winget" -Actual $UserWingetTaskSpec.taskName -Message "Rendered user-context task name did not match the updater lookup."
    Assert-Equal -Expected $ExpectedWindowsDirectory -Actual $UserWingetTaskSpec.action.workingDirectory -Message "Rendered user-context task working directory was incorrect."
    Assert-True -Condition ($UserWingetTaskSpec.action.arguments.Contains("-UserWingetOnly")) -Message "Rendered user-context task was not fixed to user-only Winget mode."
    Assert-Equal -Expected $false -Actual ($UserWingetTaskSpec.action.arguments.Contains("-Elevated")) -Message "Rendered user-context task requested elevation."
    Assert-Equal -Expected "Interactive" -Actual $UserWingetTaskSpec.principal.logonType -Message "Rendered user-context task logon type was incorrect."
    Assert-Equal -Expected "Limited" -Actual $UserWingetTaskSpec.principal.runLevel -Message "Rendered user-context task run level was not limited."
    Assert-Equal -Expected $false -Actual $UserWingetTaskSpec.settings.runOnlyIfNetworkAvailable -Message "Local SABnzbd recovery was incorrectly gated on network availability."
    Assert-Equal -Expected $TaskSpec.principal.userId -Actual $UserWingetTaskSpec.principal.userId -Message "Scheduled tasks did not use the same user identity."
    Assert-Equal -Expected $null -Actual $UserWingetTaskSpec.PSObject.Properties["trigger"] -Message "On-demand user-context task unexpectedly had a trigger."

    Write-Host "Passed $TestsRun Windows updater offline assertions." -ForegroundColor Green
    exit 0
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
finally {
    if ($TestRoot -and [System.IO.Directory]::Exists($TestRoot)) {
        [System.IO.Directory]::Delete($TestRoot, $true)
    }
}

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
    $MeteredBlockStart = $UpdaterSource.IndexOf("if (Test-DataSaver)", [System.StringComparison]::Ordinal)
    Assert-True -Condition ($MeteredBlockStart -ge 0) -Message "Updater did not contain the metered-connection branch."
    $MeteredBlockExit = $UpdaterSource.IndexOf("exit `$FinalExitCode", $MeteredBlockStart, [System.StringComparison]::Ordinal)
    $MeteredStatusWrite = $UpdaterSource.IndexOf("Write-AtomicJsonFile", $MeteredBlockStart, [System.StringComparison]::Ordinal)
    Assert-True -Condition ($MeteredBlockExit -gt $MeteredBlockStart) -Message "Metered-connection branch did not exit with the computed status."
    Assert-True -Condition ($MeteredStatusWrite -gt $MeteredBlockStart -and $MeteredStatusWrite -lt $MeteredBlockExit) -Message "Metered-connection branch did not atomically publish last-run status before exiting."
    $MeteredBlockSource = $UpdaterSource.Substring($MeteredBlockStart, $MeteredBlockExit - $MeteredBlockStart)
    Assert-True -Condition ($MeteredBlockSource.Contains('$Results.Execution.Status = "Warning"')) -Message "Metered-connection branch did not classify the skip as a warning."
    Assert-True -Condition ($MeteredBlockSource.Contains('$FinalExitCode = 2')) -Message "Metered-connection branch did not use the warning exit code."

    . $CorePath

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

    $TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("windows-updater-tests.{0}" -f [guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::CreateDirectory($TestRoot) | Out-Null
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
    $TaskSpec = $RenderText | ConvertFrom-Json

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

#Requires -Version 5.1

function Test-WingetNoApplicableExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    return @(-1978335212, -1978335189) -contains $ExitCode
}

function ConvertFrom-WingetUpgradeOutput {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Output,
        [Parameter(Mandatory = $true)]
        [ValidateSet("winget", "msstore")]
        [string]$Source,
        [string[]]$ExcludePackageIds = @()
    )

    $Ids = New-Object System.Collections.Generic.List[string]
    $IdColumnStart = -1
    $VersionColumnStart = -1
    $InUpgradeTable = $false

    foreach ($Line in $Output) {
        $Text = "$Line".Trim()
        if ([string]::IsNullOrWhiteSpace($Text)) { continue }

        if ($Text -match '^Name\s+Id\s+Version\s+Available(?:\s+Source)?$') {
            $IdColumnStart = $Text.IndexOf("Id")
            $VersionColumnStart = $Text.IndexOf("Version", $IdColumnStart + 2)
            $InUpgradeTable = $false
            continue
        }

        if ($IdColumnStart -ge 0 -and $Text -match '^-{3,}$') {
            $InUpgradeTable = $true
            continue
        }

        if ($InUpgradeTable -and $Text -match '^\d+\s+(?:upgrades?\b|package\(s\)(?:\s|$))') {
            $InUpgradeTable = $false
            continue
        }

        if (-not $InUpgradeTable) { continue }
        if ($VersionColumnStart -le $IdColumnStart -or $Text.Length -le $IdColumnStart) { continue }

        $IdColumnWidth = $VersionColumnStart - $IdColumnStart
        $AvailableWidth = [Math]::Min($IdColumnWidth, $Text.Length - $IdColumnStart)
        $Id = $Text.Substring($IdColumnStart, $AvailableWidth).Trim()

        if ($Source -eq "msstore") {
            if ($Id -notmatch '^(?=.*[A-Za-z])[A-Za-z0-9][A-Za-z0-9_.+-]*$') { continue }
        }
        elseif ($Id -notmatch '^(?=.*[A-Za-z])(?=.*\.)[A-Za-z0-9][A-Za-z0-9_.+-]*$') {
            continue
        }

        if ($ExcludePackageIds -contains $Id) { continue }
        if (-not $Ids.Contains($Id)) { $Ids.Add($Id) }
    }

    return @($Ids)
}

function Get-UserContextWingetPackageIds {
    return @("Spotify.Spotify")
}

function Split-WingetUpgradeIdsByContext {
    param(
        [string[]]$PackageIds = @(),
        [string[]]$UserContextPackageIds = @(Get-UserContextWingetPackageIds)
    )

    $UniqueIds = @($PackageIds | Where-Object { $_ } | Select-Object -Unique)
    return [pscustomobject]@{
        Elevated    = @($UniqueIds | Where-Object { $UserContextPackageIds -notcontains $_ })
        UserContext = @($UniqueIds | Where-Object { $UserContextPackageIds -contains $_ })
    }
}

function Get-PackageUpdateExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Results
    )

    $HasWarnings = $false
    foreach ($Key in $Results.Keys) {
        $Status = "$($Results[$Key].Status)"
        if ($Status -eq "Error") { return 1 }
        if ($Status -eq "Warning") { $HasWarnings = $true }
    }

    if ($HasWarnings) { return 2 }
    return 0
}

function Get-NpmTrustedNativeRebuildArguments {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$NpmPrefix
    )

    return @(
        "rebuild",
        "-g",
        "--prefix", $NpmPrefix,
        "--loglevel=error",
        "--allow-scripts=@github/keytar,node-pty",
        "@github/keytar",
        "node-pty"
    )
}

function Get-NpmGenericInstallArguments {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$NpmPrefix,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageName,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetVersion
    )

    $AllowedScripts = New-Object System.Collections.Generic.List[string]
    $AllowedScripts.Add("@github/keytar")
    $AllowedScripts.Add("node-pty")
    if ($PackageName -ieq "pnpm") {
        $PnpmApproval = if ($TargetVersion -eq "latest") { "pnpm" } else { "pnpm@$TargetVersion" }
        $AllowedScripts.Add($PnpmApproval)
    }

    return @(
        "install",
        "-g",
        "--prefix", $NpmPrefix,
        "--loglevel=error",
        "--strict-allow-scripts",
        "--allow-scripts=$($AllowedScripts -join ',')",
        "$PackageName@$TargetVersion"
    )
}

function Get-SabnzbdOfficialUpdatePlan {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$InstalledVersion,
        [Parameter(Mandatory = $true)]
        $Release
    )

    if ($InstalledVersion -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
        throw "Unsupported installed SABnzbd version: $InstalledVersion"
    }
    if ($Release.PSObject.Properties["draft"] -eq $null -or
        $Release.draft -isnot [bool] -or $Release.draft) {
        throw "The SABnzbd release metadata did not identify a published release."
    }
    if ($Release.PSObject.Properties["prerelease"] -eq $null -or
        $Release.prerelease -isnot [bool] -or $Release.prerelease) {
        throw "The SABnzbd release metadata did not identify a stable release."
    }

    $TargetVersion = "$($Release.tag_name)"
    if ($TargetVersion -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
        throw "Unsupported official SABnzbd release tag: $TargetVersion"
    }

    $InstalledVersionObject = [version]$InstalledVersion
    $TargetVersionObject = [version]$TargetVersion
    $AssetName = "SABnzbd-$TargetVersion-win-setup.exe"
    $Assets = @($Release.assets | Where-Object { "$($_.name)" -ceq $AssetName })
    if ($Assets.Count -ne 1) {
        throw "Expected exactly one official SABnzbd Windows installer named '$AssetName', but found $($Assets.Count)."
    }

    $Asset = $Assets[0]
    if ("$($Asset.state)" -cne "uploaded") {
        throw "The official SABnzbd Windows installer asset is not fully uploaded."
    }
    if ([int64]$Asset.size -lt 1000000 -or [int64]$Asset.size -gt 209715200) {
        throw "The official SABnzbd Windows installer asset has an unexpected size: $($Asset.size) bytes."
    }

    $ExpectedUrl = "https://github.com/sabnzbd/sabnzbd/releases/download/$TargetVersion/$AssetName"
    $DownloadUrl = "$($Asset.browser_download_url)"
    if (-not $DownloadUrl.Equals($ExpectedUrl, [System.StringComparison]::Ordinal)) {
        throw "The official SABnzbd Windows installer URL was unexpected: $DownloadUrl"
    }

    $Digest = "$($Asset.digest)"
    if ($Digest -notmatch '^sha256:([0-9a-fA-F]{64})$') {
        throw "The official SABnzbd Windows installer did not include a valid SHA-256 digest."
    }

    return [pscustomobject]@{
        InstalledVersion = $InstalledVersionObject
        TargetVersion    = $TargetVersionObject
        TargetVersionText = $TargetVersion
        NeedsUpdate      = $TargetVersionObject -gt $InstalledVersionObject
        AssetName        = $AssetName
        DownloadUrl      = $DownloadUrl
        Sha256           = $Matches[1].ToUpperInvariant()
        Size             = [int64]$Asset.size
    }
}

function Confirm-SabnzbdSignedFileMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SignatureStatus,
        [Parameter(Mandatory = $true)]
        [string]$SignerSubject,
        [Parameter(Mandatory = $true)]
        [string]$CompanyName,
        [Parameter(Mandatory = $true)]
        [string]$ProductName,
        [Parameter(Mandatory = $true)]
        [string]$ProductVersion,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedVersion
    )

    if ($SignatureStatus -cne "Valid") {
        throw "SABnzbd file signature status was '$SignatureStatus', not 'Valid'."
    }
    if ($SignerSubject -notmatch '(?:^|,\s*)CN=SignPath Foundation(?:,|$)' -or
        $SignerSubject -notmatch '(?:^|,\s*)O=SignPath Foundation(?:,|$)') {
        throw "SABnzbd file signer was unexpected: $SignerSubject"
    }
    if ($CompanyName -cne "The SABnzbd-Team") {
        throw "SABnzbd file company metadata was unexpected: $CompanyName"
    }
    if ($ProductName -cne "SABnzbd $ExpectedVersion") {
        throw "SABnzbd file product metadata was unexpected: $ProductName"
    }
    if ($ProductVersion -cne $ExpectedVersion) {
        throw "SABnzbd file version was '$ProductVersion', expected '$ExpectedVersion'."
    }

    return $true
}

function Confirm-SabnzbdInstallerTrust {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256,
        [Parameter(Mandatory = $true)]
        [string]$ActualSha256,
        [Parameter(Mandatory = $true)]
        [string]$SignatureStatus,
        [Parameter(Mandatory = $true)]
        [string]$SignerSubject,
        [Parameter(Mandatory = $true)]
        [string]$CompanyName,
        [Parameter(Mandatory = $true)]
        [string]$ProductName,
        [Parameter(Mandatory = $true)]
        [string]$ProductVersion,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedVersion
    )

    if (-not $ActualSha256.Equals($ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "SABnzbd installer SHA-256 did not match the official release digest."
    }

    return Confirm-SabnzbdSignedFileMetadata `
        -SignatureStatus $SignatureStatus `
        -SignerSubject $SignerSubject `
        -CompanyName $CompanyName `
        -ProductName $ProductName `
        -ProductVersion $ProductVersion `
        -ExpectedVersion $ExpectedVersion
}

function Enter-PackageUpdateFileLock {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [timespan]$Timeout = ([timespan]::FromMinutes(10)),
        [ValidateRange(1, 60000)]
        [int]$PollIntervalMilliseconds = 250
    )

    $FullPath = [System.IO.Path]::GetFullPath($Path)
    $Directory = [System.IO.Path]::GetDirectoryName($FullPath)
    if (-not [System.IO.Directory]::Exists($Directory)) {
        throw "Package update lock directory does not exist: $Directory"
    }

    $Deadline = [datetime]::UtcNow.Add($Timeout)
    while ($true) {
        try {
            return [System.IO.File]::Open(
                $FullPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        }
        catch [System.IO.IOException] {
            if ([datetime]::UtcNow -ge $Deadline) {
                throw "Timed out after $([int]$Timeout.TotalSeconds) seconds waiting for package update lock: $FullPath"
            }
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
        }
    }
}

function New-PackageUpdateLastRunRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        [Parameter(Mandatory = $true)]
        [string]$MachineName,
        [Parameter(Mandatory = $true)]
        [datetime]$StartedAt,
        [Parameter(Mandatory = $true)]
        [datetime]$UpdatesCompletedAt,
        [Parameter(Mandatory = $true)]
        [ValidateSet(0, 1, 2)]
        [int]$ExitCode,
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 2147483647)]
        [int]$KeepOpenMinutes,
        [Parameter(Mandatory = $true)]
        [string]$LogFile,
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$SourceSha256,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Results
    )

    $Outcome = switch ($ExitCode) {
        0 { "clean" }
        1 { "error" }
        2 { "warning" }
    }

    $Phases = [ordered]@{}
    foreach ($Key in @($Results.Keys | Sort-Object)) {
        $Phases[$Key] = [ordered]@{
            status  = "$($Results[$Key].Status)"
            message = "$($Results[$Key].Message)"
        }
    }

    return [ordered]@{
        schemaVersion         = 1
        script                = $ScriptName
        machine               = $MachineName
        startedAtUtc          = $StartedAt.ToUniversalTime().ToString("o")
        updatesCompletedAtUtc = $UpdatesCompletedAt.ToUniversalTime().ToString("o")
        exitCode              = $ExitCode
        outcome               = $Outcome
        keepOpenMinutes       = $KeepOpenMinutes
        logFile               = $LogFile
        source                = [ordered]@{
            path   = $SourcePath
            sha256 = $SourceSha256.ToLowerInvariant()
        }
        phases                = $Phases
    }
}

function Write-AtomicJsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        $InputObject
    )

    $FullPath = [System.IO.Path]::GetFullPath($Path)
    $Directory = [System.IO.Path]::GetDirectoryName($FullPath)
    if (-not [System.IO.Directory]::Exists($Directory)) {
        throw "Atomic JSON destination directory does not exist: $Directory"
    }

    $TemporaryName = "{0}.{1}.{2}.tmp" -f [System.IO.Path]::GetFileName($FullPath), $PID, [guid]::NewGuid().ToString("N")
    $TemporaryPath = Join-Path $Directory $TemporaryName
    $BackupName = "{0}.{1}.{2}.bak" -f [System.IO.Path]::GetFileName($FullPath), $PID, [guid]::NewGuid().ToString("N")
    $BackupPath = Join-Path $Directory $BackupName
    $Encoding = New-Object System.Text.UTF8Encoding($false)
    $Json = $InputObject | ConvertTo-Json -Depth 8
    $ReplacementSucceeded = $false

    try {
        [System.IO.File]::WriteAllText($TemporaryPath, $Json + [Environment]::NewLine, $Encoding)
        if ([System.IO.File]::Exists($FullPath)) {
            [System.IO.File]::Replace($TemporaryPath, $FullPath, $BackupPath, $true)
            $ReplacementSucceeded = $true
        }
        else {
            [System.IO.File]::Move($TemporaryPath, $FullPath)
        }
    }
    finally {
        if ([System.IO.File]::Exists($TemporaryPath)) {
            [System.IO.File]::Delete($TemporaryPath)
        }
        if ($ReplacementSucceeded -and [System.IO.File]::Exists($BackupPath)) {
            try { [System.IO.File]::Delete($BackupPath) } catch {}
        }
    }

    return $FullPath
}

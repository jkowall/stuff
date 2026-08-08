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
    $Encoding = New-Object System.Text.UTF8Encoding($false)
    $Json = $InputObject | ConvertTo-Json -Depth 8

    try {
        [System.IO.File]::WriteAllText($TemporaryPath, $Json + [Environment]::NewLine, $Encoding)
        if ([System.IO.File]::Exists($FullPath)) {
            [System.IO.File]::Replace($TemporaryPath, $FullPath, $null, $true)
        }
        else {
            [System.IO.File]::Move($TemporaryPath, $FullPath)
        }
    }
    finally {
        if ([System.IO.File]::Exists($TemporaryPath)) {
            [System.IO.File]::Delete($TemporaryPath)
        }
    }

    return $FullPath
}

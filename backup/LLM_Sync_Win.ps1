#Requires -Version 5.1
<#
.SYNOPSIS
    Backup and restore Codex, Gemini, Claude, and shared skills across machines.

.DESCRIPTION
    Creates per-machine backups with assistant-specific subdirectories:
    codex/, gemini/, claude/, agents/, and shared-skills/.

    The sync is intentionally conservative. It keeps portable configuration,
    prompts, rules, memories, and skills while excluding auth/session data,
    caches, logs, local databases, and machine-specific project state.

.PARAMETER Action
    'backup', 'restore', 'audit', 'sync-skills', 'migrate-skills', or
    'install-repo-skills'

.PARAMETER Versioned
    Creates a timestamped machine backup folder for backup operations.

.PARAMETER LogFile
    Path to the log file. Defaults to LLM_Sync_Win.log beside the script.

.PARAMETER Force
    Skips most confirmation prompts.

.PARAMETER DryRun
    Shows what would change without writing files or running Git mutations.

.PARAMETER ConflictPolicy
    Controls how skill sync handles shared-skill conflicts:
    'interactive', 'prefer-local', or 'prefer-shared'

.PARAMETER DestructiveMigrate
    Allows the legacy migrate-skills behavior that archives and removes
    assistant-local copies. Without this switch, migrate-skills safely aliases
    sync-skills.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false, Position = 0)]
    [ValidateSet("backup", "restore", "audit", "sync-skills", "migrate-skills", "install-repo-skills")]
    [string]$Action,

    [Parameter()]
    [switch]$Versioned,

    [Parameter()]
    [string]$LogFile,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [ValidateSet("interactive", "prefer-local", "prefer-shared")]
    [string]$ConflictPolicy = "interactive",

    [Parameter()]
    [switch]$DestructiveMigrate
)

if (-not $LogFile) {
    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)
    $LogFile = Join-Path $PSScriptRoot "$scriptName.log"
}

$Script:ConfigPath = Join-Path $env:USERPROFILE "Private\Configs\LLM_Sync_Win.json"
$Script:ConfigData = $null
$Script:PreRestoreBase = $null
$Script:BaseBackupPath = $null
$Script:IsDryRun = [bool]($DryRun -or $WhatIfPreference)
$Script:RepoSkillsPath = Join-Path (Split-Path $PSScriptRoot -Parent) "skills"
$Script:SharedSkills = @{
    Name         = "shared-skills"
    Source       = Join-Path $env:USERPROFILE ".skills"
    ExcludeNames = @(".git", ".conflicts", "_migrated_to_shared")
}

$Script:Assistants = @(
    @{
        Name         = "codex"
        Source       = Join-Path $env:USERPROFILE ".codex"
        RootFiles    = @("AGENTS.md", "config.toml")
        NestedFiles  = @()
        Directories  = @(
            @{ RelativePath = "memories"; ExcludeNames = @() },
            @{ RelativePath = "rules"; ExcludeNames = @() },
            @{ RelativePath = "skills"; ExcludeNames = @(".system", ".git", ".conflicts", "_migrated_to_shared") }
        )
        PreviewFiles = @("AGENTS.md", "config.toml", "rules\default.rules")
    },
    @{
        Name         = "gemini"
        Source       = Join-Path $env:USERPROFILE ".gemini"
        RootFiles    = @("GEMINI.md", "settings.json")
        NestedFiles  = @(
            "config\mcp_config.json",
            "antigravity\mcp_config.json",
            "antigravity\user_settings.pb",
            "antigravity\browserAllowlist.txt",
            "antigravity\browserOnboardingStatus.txt",
            "antigravity-ide\mcp_config.json",
            "antigravity-ide\user_settings.pb",
            "antigravity-ide\browserAllowlist.txt",
            "antigravity-ide\browserOnboardingStatus.txt"
        )
        Directories  = @(
            @{ RelativePath = "antigravity\knowledge"; ExcludeNames = @() },
            @{ RelativePath = "antigravity\scratch"; ExcludeNames = @() },
            @{ RelativePath = "antigravity-ide\knowledge"; ExcludeNames = @() },
            @{ RelativePath = "antigravity-ide\scratch"; ExcludeNames = @() }
        )
        PreviewFiles = @(
            "GEMINI.md",
            "settings.json",
            "config\mcp_config.json",
            "antigravity\mcp_config.json",
            "antigravity-ide\mcp_config.json",
            "antigravity\browserAllowlist.txt"
        )
    },
    @{
        Name         = "claude"
        Source       = Join-Path $env:USERPROFILE ".claude"
        RootFiles    = @("settings.json", "statusline-command.sh")
        NestedFiles  = @()
        Directories  = @(
            @{ RelativePath = "skills"; ExcludeNames = @(".git", ".conflicts", "_migrated_to_shared") }
        )
        PreviewFiles = @("settings.json", "statusline-command.sh")
    },
    @{
        Name           = "agents"
        Source         = Join-Path $env:USERPROFILE ".agents"
        RootFiles      = @()
        NestedFiles    = @()
        Directories    = @(
            @{ RelativePath = "skills"; ExcludeNames = @(".git", ".conflicts", "_migrated_to_shared") }
        )
        PreviewFiles   = @()
        SkillMigration = $false
    }
)

$Script:AppConfigs = @(
    @{
        Name         = "claude"
        Source       = Join-Path $env:APPDATA "Claude"
        RootFiles    = @(
            "claude_desktop_config.json",
            "extensions-installations.json",
            "extensions-blocklist.json",
            "cowork-enabled-cli-ops.json"
        )
        Directories  = @(
            @{ RelativePath = "Claude Extensions Settings"; ExcludeNames = @() }
        )
        PreviewFiles = @("claude_desktop_config.json", "extensions-installations.json")
    },
    @{
        Name         = "codex"
        Source       = Join-Path $env:APPDATA "Codex"
        RootFiles    = @("browser-sidebar-local-servers.json")
        Directories  = @()
        PreviewFiles = @("browser-sidebar-local-servers.json")
    },
    @{
        Name         = "openai-codex"
        Source       = Join-Path $env:APPDATA "OpenAI\Codex"
        RootFiles    = @("chrome-native-hosts-v2.json")
        Directories  = @()
        PreviewFiles = @("chrome-native-hosts-v2.json")
    }
)

function Write-Log {
    param([string]$Message, [ValidateSet("Info", "Success", "Warning", "Error")]$Level = "Info")
    $logEntry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    $colors = @{ Info = "Cyan"; Success = "Green"; Warning = "Yellow"; Error = "Red" }
    Write-Host $logEntry -ForegroundColor $colors[$Level]
    if ($LogFile -and -not $Script:IsDryRun) {
        Add-Content -Path $LogFile -Value $logEntry -ErrorAction SilentlyContinue
    }
}

function Test-IsDryRun {
    return [bool]$Script:IsDryRun
}

function Initialize-BackupConfiguration {
    if (-not (Test-Path $Script:ConfigPath)) {
        throw "Config file not found: $($Script:ConfigPath). Please create it with BaseBackupPath."
    }

    $Script:ConfigData = Get-Content $Script:ConfigPath -Raw | ConvertFrom-Json
    if (-not $Script:ConfigData.BaseBackupPath) {
        throw "Config file $($Script:ConfigPath) does not define BaseBackupPath."
    }

    $defaultPreRestore = if (Test-Path "D:\") { "D:\tmp" } else { $env:TEMP }
    $Script:PreRestoreBase = if ($Script:ConfigData.PreRestorePath) { $Script:ConfigData.PreRestorePath } else { $defaultPreRestore }
    $Script:BaseBackupPath = $Script:ConfigData.BaseBackupPath
}

function Get-SkillRoot {
    param([hashtable]$Assistant)
    if ($Assistant.ContainsKey("SkillMigration") -and -not $Assistant.SkillMigration) {
        return $null
    }
    if ($Assistant.Name -eq "gemini") {
        return $null
    }
    return Join-Path $Assistant.Source "skills"
}

function Get-SkillExcludeNames {
    param([hashtable]$Assistant)

    $skillDirectory = $Assistant.Directories | Where-Object { $_.RelativePath -eq "skills" } | Select-Object -First 1
    if ($skillDirectory) {
        return $skillDirectory.ExcludeNames
    }

    return @()
}

function Get-MenuChoice {
    param(
        [string]$Title,
        [string[]]$Options
    )

    $selectedIndex = 0
    while ($true) {
        Clear-Host
        Write-Host "=== $Title ===" -ForegroundColor Cyan
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $selectedIndex) {
                Write-Host " > $($Options[$i])" -ForegroundColor Green
            }
            else {
                Write-Host "   $($Options[$i])"
            }
        }

        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        if ($key.VirtualKeyCode -eq 38) {
            $selectedIndex = ($selectedIndex - 1 + $Options.Count) % $Options.Count
        }
        elseif ($key.VirtualKeyCode -eq 40) {
            $selectedIndex = ($selectedIndex + 1) % $Options.Count
        }
        elseif ($key.VirtualKeyCode -eq 13) {
            return $Options[$selectedIndex].ToLower()
        }
        elseif ($key.VirtualKeyCode -eq 27) {
            exit 0
        }
    }
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        if (Test-IsDryRun) {
            Write-Log "Dry run: would create directory $Path"
        }
        else {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
    }
}

function Ensure-SharedSkillsDirectory {
    Ensure-Directory -Path $Script:SharedSkills.Source
}

function Copy-FileIfExists {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    if (-not (Test-Path $sourcePath)) {
        return
    }

    $destinationPath = Join-Path $DestinationRoot $RelativePath
    Ensure-Directory -Path (Split-Path -Parent $destinationPath)
    if (Test-IsDryRun) {
        Write-Log "Dry run: would copy file $sourcePath -> $destinationPath"
    }
    else {
        Copy-Item -Path $sourcePath -Destination $destinationPath -Force
    }
}

function Copy-FilteredDirectory {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string[]]$ExcludeNames = @()
    )

    if (-not (Test-Path $SourcePath)) {
        return $false
    }

    if (Test-Path $DestinationPath) {
        if (Test-IsDryRun) {
            Write-Log "Dry run: would replace directory $DestinationPath"
        }
        else {
            Remove-Item -Path $DestinationPath -Recurse -Force
        }
    }
    Ensure-Directory -Path $DestinationPath

    foreach ($item in Get-ChildItem -Force $SourcePath) {
        if ($ExcludeNames -contains $item.Name) {
            continue
        }

        $targetPath = Join-Path $DestinationPath $item.Name
        if ($item.PSIsContainer) {
            Copy-FilteredDirectory -SourcePath $item.FullName -DestinationPath $targetPath -ExcludeNames $ExcludeNames | Out-Null
        }
        else {
            Ensure-Directory -Path (Split-Path -Parent $targetPath)
            if (Test-IsDryRun) {
                Write-Log "Dry run: would copy file $($item.FullName) -> $targetPath"
            }
            else {
                Copy-Item -Path $item.FullName -Destination $targetPath -Force
            }
        }
    }

    return $true
}

function Remove-PathIfExists {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) {
        return
    }
    if (Test-IsDryRun) {
        Write-Log "Dry run: would remove $Path"
    }
    elseif (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Remove-Item -LiteralPath $Path -Force
    }
    else {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Copy-TopLevelItem {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    $sourceItem = Get-Item -LiteralPath $SourcePath -Force -ErrorAction SilentlyContinue
    if (-not $sourceItem) {
        return
    }

    Ensure-Directory -Path (Split-Path -Parent $DestinationPath)
    if (Get-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue) {
        Remove-PathIfExists -Path $DestinationPath
    }

    if (Test-IsDryRun) {
        Write-Log "Dry run: would copy $SourcePath -> $DestinationPath"
    }
    else {
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Recurse -Force
    }
}

function Test-RepoSkillPackage {
    param([System.IO.DirectoryInfo]$SourceItem)

    $skillFile = Join-Path $SourceItem.FullName "SKILL.md"
    if (-not (Test-Path -LiteralPath $skillFile) -or (Test-Path -LiteralPath (Join-Path $SourceItem.FullName ".git"))) {
        return $false
    }

    $content = Get-Content -LiteralPath $skillFile -Raw
    $frontmatterMatch = [regex]::Match(
        $content,
        '\A---\r?\n(?<frontmatter>.*?)\r?\n---(?:\r?\n|\z)',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $frontmatterMatch.Success) {
        return $false
    }

    $frontmatter = $frontmatterMatch.Groups['frontmatter'].Value
    $nameMatch = [regex]::Match($frontmatter, '(?m)^name:\s*(?<value>[^\r\n]+?)\s*$')
    $descriptionMatch = [regex]::Match($frontmatter, '(?m)^description:\s*(?<value>[^\r\n]+?)\s*$')
    if (-not $nameMatch.Success -or -not $descriptionMatch.Success) {
        return $false
    }

    $declaredName = $nameMatch.Groups['value'].Value.Trim().Trim('"').Trim("'")
    $description = $descriptionMatch.Groups['value'].Value.Trim().Trim('"').Trim("'")
    return (($declaredName -eq $SourceItem.Name) -and -not [string]::IsNullOrWhiteSpace($description))
}

function Install-RepoSkillCopy {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$ArchivePath,
        [string]$CopyLabel
    )

    $Script:RepoSkillCopyChanged = $false
    $destinationItem = Get-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
    if ($destinationItem) {
        if ((Test-Path -LiteralPath $DestinationPath) -and
            (Get-PathSignature -Path $DestinationPath) -eq (Get-PathSignature -Path $SourcePath)) {
            return
        }

        Copy-TopLevelItem -SourcePath $DestinationPath -DestinationPath $ArchivePath
        if (Test-IsDryRun) {
            Write-Log "Would preserve previous $CopyLabel copy: $(Split-Path $SourcePath -Leaf)"
        }
        else {
            Write-Log "Preserved previous $CopyLabel copy: $(Split-Path $SourcePath -Leaf)"
        }
    }

    Copy-TopLevelItem -SourcePath $SourcePath -DestinationPath $DestinationPath
    $Script:RepoSkillCopyChanged = $true
}

function Get-PathSignature {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    $item = Get-Item -LiteralPath $Path
    if (-not $item.PSIsContainer) {
        return "FILE:$((Get-FileHash -Algorithm SHA256 -Path $Path).Hash)"
    }

    $basePath = (Resolve-Path $Path).Path
    $parts = foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -Force -File | Sort-Object FullName) {
        $relative = $file.FullName.Substring($basePath.Length).TrimStart('\')
        "$relative::$((Get-FileHash -Algorithm SHA256 -Path $file.FullName).Hash)"
    }
    return "DIR:$([string]::Join('|', $parts))"
}

function Archive-SkillItem {
    param(
        [string]$SourcePath,
        [string]$ArchiveRoot
    )

    if (-not (Test-Path $SourcePath)) {
        return
    }

    Ensure-Directory -Path $ArchiveRoot
    $destination = Join-Path $ArchiveRoot (Split-Path $SourcePath -Leaf)
    Copy-TopLevelItem -SourcePath $SourcePath -DestinationPath $destination
    Remove-PathIfExists -Path $SourcePath
}

function Resolve-SkillConflict {
    param(
        [string]$AssistantName,
        [string]$LocalPath,
        [string]$SharedPath
    )

    $decision = $ConflictPolicy
    if ($decision -eq "interactive" -and -not $Force) {
        Write-Log "Skill conflict for '$($AssistantName):$(Split-Path $LocalPath -Leaf)'." -Level Warning
        Write-Host "  [l] prefer local and update shared"
        Write-Host "  [s] prefer shared and archive local"
        $choice = Read-Host "Choice"
        if ($choice -eq "l") { $decision = "prefer-local" }
        else { $decision = "prefer-shared" }
    }
    elseif ($decision -eq "interactive") {
        $decision = "prefer-shared"
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    if ($decision -eq "prefer-local") {
        $sharedArchiveRoot = Join-Path $Script:SharedSkills.Source ".conflicts\$AssistantName\$timestamp"
        Archive-SkillItem -SourcePath $SharedPath -ArchiveRoot $sharedArchiveRoot
        Copy-TopLevelItem -SourcePath $LocalPath -DestinationPath $SharedPath
        $localArchiveRoot = Join-Path (Split-Path $LocalPath -Parent) "_migrated_to_shared\$timestamp"
        Archive-SkillItem -SourcePath $LocalPath -ArchiveRoot $localArchiveRoot
        Write-Log "Conflict resolved by promoting local copy to shared for $(Split-Path $LocalPath -Leaf)." -Level Success
        return
    }

    $archiveRoot = Join-Path (Split-Path $LocalPath -Parent) "_migrated_to_shared\$timestamp"
    Archive-SkillItem -SourcePath $LocalPath -ArchiveRoot $archiveRoot
    Write-Log "Conflict resolved by keeping shared copy for $(Split-Path $LocalPath -Leaf)." -Level Success
}

function Resolve-SkillSyncConflict {
    param(
        [string]$AssistantName,
        [string]$LocalPath,
        [string]$SharedPath
    )

    $decision = $ConflictPolicy
    $skillName = Split-Path $LocalPath -Leaf
    if ($decision -eq "interactive" -and -not $Force -and -not (Test-IsDryRun)) {
        Write-Log "Skill conflict for '$($AssistantName):$skillName'." -Level Warning
        Write-Host "  [l] prefer local and update shared"
        Write-Host "  [s] prefer shared and preserve local conflict copy"
        $choice = Read-Host "Choice"
        if ($choice -eq "l") { $decision = "prefer-local" }
        else { $decision = "prefer-shared" }
    }
    elseif ($decision -eq "interactive") {
        Write-Log "Skill conflict for '$($AssistantName):$skillName'; defaulting preview/forced run to prefer-shared." -Level Warning
        $decision = "prefer-shared"
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    if ($decision -eq "prefer-local") {
        $sharedArchive = Join-Path $Script:SharedSkills.Source ".conflicts\$AssistantName\$timestamp\$skillName"
        Copy-TopLevelItem -SourcePath $SharedPath -DestinationPath $sharedArchive
        Copy-TopLevelItem -SourcePath $LocalPath -DestinationPath $SharedPath
        Write-Log "Updated shared skill from $AssistantName: $skillName" -Level Success
        return
    }

    $localArchive = Join-Path $Script:SharedSkills.Source ".conflicts\$AssistantName\$timestamp\$skillName"
    Copy-TopLevelItem -SourcePath $LocalPath -DestinationPath $localArchive
    Write-Log "Kept shared skill and preserved conflicting local copy: $skillName" -Level Success
}

function Invoke-SkillAudit {
    Ensure-SharedSkillsDirectory
    Write-Log "=== Shared Skills Audit ==="

    $sharedNames = @{}
    if (Test-Path $Script:SharedSkills.Source) {
        foreach ($item in Get-ChildItem -LiteralPath $Script:SharedSkills.Source -Force) {
            if ($Script:SharedSkills.ExcludeNames -contains $item.Name) { continue }
            $sharedNames[$item.Name] = $true
        }
    }

    Write-Log "Shared skill root: $($Script:SharedSkills.Source)"
    Write-Host "Shared skills: $($sharedNames.Keys.Count)"

    foreach ($assistant in $Script:Assistants) {
        $skillRoot = Get-SkillRoot -Assistant $assistant
        if (-not $skillRoot) {
            Write-Host "[$($assistant.Name)] no assistant-local shared-skill directory"
            continue
        }

        $excludeNames = Get-SkillExcludeNames -Assistant $assistant
        $localItems = @()
        if (Test-Path $skillRoot) {
            $localItems = Get-ChildItem -LiteralPath $skillRoot -Force |
                Where-Object { $excludeNames -notcontains $_.Name }
        }

        $duplicateNames = $localItems | Where-Object { $sharedNames.ContainsKey($_.Name) } | Select-Object -ExpandProperty Name
        Write-Host "[$($assistant.Name)] local skills: $($localItems.Count); duplicates in shared: $($duplicateNames.Count)"
        foreach ($name in $duplicateNames) {
            Write-Host "  - $name"
        }
    }
}

function Invoke-SkillSync {
    Ensure-SharedSkillsDirectory
    Write-Log "=== Shared Skills Sync ==="

    foreach ($assistant in $Script:Assistants) {
        $skillRoot = Get-SkillRoot -Assistant $assistant
        if (-not $skillRoot -or -not (Test-Path $skillRoot)) {
            continue
        }

        $excludeNames = Get-SkillExcludeNames -Assistant $assistant
        Write-Log "Syncing skills from $($assistant.Name) into shared set..."
        foreach ($item in Get-ChildItem -LiteralPath $skillRoot -Force) {
            if ($excludeNames -contains $item.Name) {
                continue
            }

            $sharedPath = Join-Path $Script:SharedSkills.Source $item.Name
            if (-not (Test-Path $sharedPath)) {
                Copy-TopLevelItem -SourcePath $item.FullName -DestinationPath $sharedPath
                Write-Log "Added shared skill from $($assistant.Name): $($item.Name)" -Level Success
                continue
            }

            $localSignature = Get-PathSignature -Path $item.FullName
            $sharedSignature = Get-PathSignature -Path $sharedPath
            if ($localSignature -ne $sharedSignature) {
                Resolve-SkillSyncConflict -AssistantName $assistant.Name -LocalPath $item.FullName -SharedPath $sharedPath
            }
        }
    }

    $sharedItems = @()
    if (Test-Path $Script:SharedSkills.Source) {
        $sharedItems = Get-ChildItem -LiteralPath $Script:SharedSkills.Source -Force |
            Where-Object { $Script:SharedSkills.ExcludeNames -notcontains $_.Name }
    }

    foreach ($assistant in $Script:Assistants) {
        $skillRoot = Get-SkillRoot -Assistant $assistant
        if (-not $skillRoot) {
            continue
        }

        Ensure-Directory -Path $skillRoot
        Write-Log "Mirroring shared skills into $($assistant.Name)..."
        foreach ($item in $sharedItems) {
            $destination = Join-Path $skillRoot $item.Name
            if (-not (Test-Path $destination) -or (Get-PathSignature -Path $destination) -ne (Get-PathSignature -Path $item.FullName)) {
                Copy-TopLevelItem -SourcePath $item.FullName -DestinationPath $destination
                Write-Log "Mirrored shared skill to $($assistant.Name): $($item.Name)" -Level Success
            }
        }
    }
}

function Invoke-RepoSkillInstall {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Stop"
    try {
        if (-not (Test-Path $Script:RepoSkillsPath)) {
            throw "Repository skills directory not found: $($Script:RepoSkillsPath)"
        }

        Ensure-SharedSkillsDirectory
        $timestamp = "$(Get-Date -Format 'yyyyMMdd_HHmmss')_$PID"
        $repoSkillItems = @(
            Get-ChildItem -LiteralPath $Script:RepoSkillsPath -Directory |
                Where-Object { -not ($_.Name.StartsWith('.')) } |
                Sort-Object Name
        )

        if ($repoSkillItems.Count -eq 0) {
            throw "No repository skill packages found in $($Script:RepoSkillsPath)"
        }

        foreach ($sourceItem in $repoSkillItems) {
            if (-not (Test-RepoSkillPackage -SourceItem $sourceItem)) {
                throw "$($sourceItem.Name)/SKILL.md must have frontmatter with a matching name and non-empty description."
            }
        }

        $updatedCount = 0
        foreach ($sourceItem in $repoSkillItems) {
            $skillName = $sourceItem.Name
            $packageChanged = $false
            $sharedPath = Join-Path $Script:SharedSkills.Source $skillName
            $sharedArchive = Join-Path $Script:SharedSkills.Source ".conflicts\repo-install\$timestamp\shared\$skillName"
            Install-RepoSkillCopy -SourcePath $sourceItem.FullName -DestinationPath $sharedPath -ArchivePath $sharedArchive -CopyLabel "shared"
            if ($Script:RepoSkillCopyChanged) {
                $packageChanged = $true
            }

            foreach ($assistant in $Script:Assistants | Where-Object { $_.Name -in @("codex", "claude") }) {
                $skillRoot = Get-SkillRoot -Assistant $assistant
                Ensure-Directory -Path $skillRoot
                $destination = Join-Path $skillRoot $skillName
                $localArchive = Join-Path $Script:SharedSkills.Source ".conflicts\repo-install\$timestamp\$($assistant.Name)\$skillName"
                Install-RepoSkillCopy -SourcePath $sourceItem.FullName -DestinationPath $destination -ArchivePath $localArchive -CopyLabel $assistant.Name
                if ($Script:RepoSkillCopyChanged) {
                    $packageChanged = $true
                }
            }

            if ($packageChanged) {
                $updatedCount++
                if (Test-IsDryRun) {
                    Write-Log "Would install or update repository skill: $skillName"
                }
                else {
                    Write-Log "Installed or updated repository skill: $skillName" -Level Success
                }
            }
            else {
                Write-Log "Repository skill already current: $skillName"
            }
        }

        $currentCount = $repoSkillItems.Count - $updatedCount
        if (Test-IsDryRun) {
            Write-Log "Validated $($repoSkillItems.Count) repository skills; would update $updatedCount and leave $currentCount already current."
        }
        else {
            Write-Log "Validated $($repoSkillItems.Count) repository skills; updated $updatedCount and left $currentCount already current." -Level Success
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Invoke-DestructiveSkillMigration {
    Ensure-SharedSkillsDirectory
    Write-Log "=== Shared Skills Migration ==="

    foreach ($assistant in $Script:Assistants) {
        $skillRoot = Get-SkillRoot -Assistant $assistant
        if (-not $skillRoot -or -not (Test-Path $skillRoot)) {
            continue
        }

        $excludeNames = Get-SkillExcludeNames -Assistant $assistant

        Write-Log "Migrating skills from $($assistant.Name)..."
        foreach ($item in Get-ChildItem -LiteralPath $skillRoot -Force) {
            if ($excludeNames -contains $item.Name) {
                continue
            }

            $sharedPath = Join-Path $Script:SharedSkills.Source $item.Name
            if (-not (Test-Path $sharedPath)) {
                Copy-TopLevelItem -SourcePath $item.FullName -DestinationPath $sharedPath
                $archiveRoot = Join-Path $skillRoot "_migrated_to_shared\$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                Archive-SkillItem -SourcePath $item.FullName -ArchiveRoot $archiveRoot
                Write-Log "Promoted $($item.Name) from $($assistant.Name) to shared skills." -Level Success
                continue
            }

            $localSignature = Get-PathSignature -Path $item.FullName
            $sharedSignature = Get-PathSignature -Path $sharedPath
            if ($localSignature -eq $sharedSignature) {
                $archiveRoot = Join-Path $skillRoot "_migrated_to_shared\$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                Archive-SkillItem -SourcePath $item.FullName -ArchiveRoot $archiveRoot
                Write-Log "Archived duplicate local skill $($item.Name) from $($assistant.Name)." -Level Success
                continue
            }

            Resolve-SkillConflict -AssistantName $assistant.Name -LocalPath $item.FullName -SharedPath $sharedPath
        }
    }
}

function Sync-AssistantBackup {
    param(
        [hashtable]$Assistant,
        [string]$DestinationRoot
    )

    $assistantDestination = Join-Path $DestinationRoot $Assistant.Name
    if (Test-Path $assistantDestination) {
        if (Test-IsDryRun) {
            Write-Log "Dry run: would replace assistant backup at $assistantDestination"
        }
        else {
            Remove-Item -Path $assistantDestination -Recurse -Force
        }
    }
    Ensure-Directory -Path $assistantDestination

    foreach ($relativeFile in $Assistant.RootFiles) {
        Copy-FileIfExists -SourceRoot $Assistant.Source -DestinationRoot $assistantDestination -RelativePath $relativeFile
    }
    foreach ($relativeFile in $Assistant.NestedFiles) {
        Copy-FileIfExists -SourceRoot $Assistant.Source -DestinationRoot $assistantDestination -RelativePath $relativeFile
    }
    foreach ($directory in $Assistant.Directories) {
        $sourceDirectory = Join-Path $Assistant.Source $directory.RelativePath
        $destinationDirectory = Join-Path $assistantDestination $directory.RelativePath
        Copy-FilteredDirectory -SourcePath $sourceDirectory -DestinationPath $destinationDirectory -ExcludeNames $directory.ExcludeNames | Out-Null
    }
}

function Sync-SharedSkillsBackup {
    param([string]$DestinationRoot)

    if (-not (Test-Path $Script:SharedSkills.Source)) {
        return
    }

    $sharedDestination = Join-Path $DestinationRoot $Script:SharedSkills.Name
    Copy-FilteredDirectory -SourcePath $Script:SharedSkills.Source -DestinationPath $sharedDestination -ExcludeNames $Script:SharedSkills.ExcludeNames | Out-Null
}

function Sync-AppConfigBackup {
    param(
        [hashtable]$AppConfig,
        [string]$DestinationRoot
    )

    if (-not (Test-Path $AppConfig.Source)) {
        return
    }

    $appRoot = Join-Path (Join-Path $DestinationRoot "app-configs") $AppConfig.Name
    if (Test-Path $appRoot) {
        if (Test-IsDryRun) {
            Write-Log "Dry run: would replace app config backup at $appRoot"
        }
        else {
            Remove-Item -Path $appRoot -Recurse -Force
        }
    }
    Ensure-Directory -Path $appRoot

    foreach ($relativeFile in $AppConfig.RootFiles) {
        Copy-FileIfExists -SourceRoot $AppConfig.Source -DestinationRoot $appRoot -RelativePath $relativeFile
    }
    foreach ($directory in $AppConfig.Directories) {
        $sourceDirectory = Join-Path $AppConfig.Source $directory.RelativePath
        $destinationDirectory = Join-Path $appRoot $directory.RelativePath
        Copy-FilteredDirectory -SourcePath $sourceDirectory -DestinationPath $destinationDirectory -ExcludeNames $directory.ExcludeNames | Out-Null
    }
}

function Restore-Assistant {
    param(
        [hashtable]$Assistant,
        [string]$BackupRoot
    )

    $assistantBackup = Join-Path $BackupRoot $Assistant.Name
    if (-not (Test-Path $assistantBackup)) {
        Write-Log "Assistant backup not found for '$($Assistant.Name)'; skipping." -Level Warning
        return
    }

    if (-not (Test-Path $Assistant.Source)) {
        Ensure-Directory -Path $Assistant.Source
    }

    foreach ($relativeFile in $Assistant.RootFiles) {
        Copy-FileIfExists -SourceRoot $assistantBackup -DestinationRoot $Assistant.Source -RelativePath $relativeFile
    }
    foreach ($relativeFile in $Assistant.NestedFiles) {
        if ($Assistant.Name -eq "gemini" -and $relativeFile -in @("antigravity\browserOnboardingStatus.txt", "antigravity-ide\browserOnboardingStatus.txt")) {
            continue
        }
        Copy-FileIfExists -SourceRoot $assistantBackup -DestinationRoot $Assistant.Source -RelativePath $relativeFile
    }
    foreach ($directory in $Assistant.Directories) {
        if ($Assistant.Name -eq "gemini" -and $directory.RelativePath -in @("antigravity\knowledge", "antigravity\scratch", "antigravity-ide\knowledge", "antigravity-ide\scratch")) {
            continue
        }
        $sourceDirectory = Join-Path $assistantBackup $directory.RelativePath
        if (-not (Test-Path $sourceDirectory)) {
            continue
        }
        $destinationDirectory = Join-Path $Assistant.Source $directory.RelativePath
        Copy-FilteredDirectory -SourcePath $sourceDirectory -DestinationPath $destinationDirectory -ExcludeNames $directory.ExcludeNames | Out-Null
    }
}

function Restore-SharedSkills {
    param([string]$BackupRoot)

    $sharedBackup = Join-Path $BackupRoot $Script:SharedSkills.Name
    if (-not (Test-Path $sharedBackup)) {
        return
    }

    Copy-FilteredDirectory -SourcePath $sharedBackup -DestinationPath $Script:SharedSkills.Source -ExcludeNames $Script:SharedSkills.ExcludeNames | Out-Null
}

function Restore-AppConfig {
    param(
        [hashtable]$AppConfig,
        [string]$BackupRoot
    )

    $appBackup = Join-Path (Join-Path $BackupRoot "app-configs") $AppConfig.Name
    if (-not (Test-Path $appBackup)) {
        return
    }

    Ensure-Directory -Path $AppConfig.Source
    foreach ($relativeFile in $AppConfig.RootFiles) {
        Copy-FileIfExists -SourceRoot $appBackup -DestinationRoot $AppConfig.Source -RelativePath $relativeFile
    }
    foreach ($directory in $AppConfig.Directories) {
        $sourceDirectory = Join-Path $appBackup $directory.RelativePath
        if (-not (Test-Path $sourceDirectory)) {
            continue
        }
        $destinationDirectory = Join-Path $AppConfig.Source $directory.RelativePath
        Copy-FilteredDirectory -SourcePath $sourceDirectory -DestinationPath $destinationDirectory -ExcludeNames $directory.ExcludeNames | Out-Null
    }
}

function Create-SafetyBackup {
    param([string]$RestoreLabel)

    $preRestoreRoot = Join-Path $Script:PreRestoreBase "llm_sync_pre_restore"
    $safeLabel = $RestoreLabel -replace '[\\/:*?"<>|]', '_'
    $preRestoreDir = Join-Path $preRestoreRoot "backup_$safeLabel`_$((Get-Date).ToString('yyyyMMdd_HHmmss'))"

    Write-Log "Creating safety backup of current assistant settings to $preRestoreDir..."
    foreach ($assistant in $Script:Assistants) {
        Sync-AssistantBackup -Assistant $assistant -DestinationRoot $preRestoreDir
    }
    Sync-SharedSkillsBackup -DestinationRoot $preRestoreDir
    foreach ($appConfig in $Script:AppConfigs) {
        Sync-AppConfigBackup -AppConfig $appConfig -DestinationRoot $preRestoreDir
    }

    if (Test-Path $preRestoreRoot) {
        $oldBackups = Get-ChildItem $preRestoreRoot -Directory |
            Where-Object { $_.Name -like "backup_*" } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 2

        if ($oldBackups) {
            Write-Log "Pruning old pre-restore backups..."
            if (Test-IsDryRun) {
                foreach ($backup in $oldBackups) {
                    Write-Log "Dry run: would remove old safety backup $($backup.FullName)"
                }
            }
            else {
                $oldBackups | Remove-Item -Recurse -Force
            }
        }
    }
}

function Preview-RestoreDiffs {
    param([string]$BackupRoot)

    if ($Force) {
        return
    }

    $diffItems = @()
    foreach ($assistant in $Script:Assistants) {
        $assistantBackup = Join-Path $BackupRoot $assistant.Name
        foreach ($relativePath in $assistant.PreviewFiles) {
            $localFile = Join-Path $assistant.Source $relativePath
            $backupFile = Join-Path $assistantBackup $relativePath
            if ((Test-Path $localFile) -and (Test-Path $backupFile)) {
                $localHash = Get-FileHash -Algorithm SHA256 -Path $localFile
                $backupHash = Get-FileHash -Algorithm SHA256 -Path $backupFile
                if ($localHash.Hash -ne $backupHash.Hash) {
                    $diffItems += [pscustomobject]@{
                        Assistant = $assistant.Name
                        Relative  = $relativePath
                        Local     = $localFile
                        Backup    = $backupFile
                    }
                }
            }
        }
    }
    foreach ($appConfig in $Script:AppConfigs) {
        $appBackup = Join-Path (Join-Path $BackupRoot "app-configs") $appConfig.Name
        foreach ($relativePath in $appConfig.PreviewFiles) {
            $localFile = Join-Path $appConfig.Source $relativePath
            $backupFile = Join-Path $appBackup $relativePath
            if ((Test-Path $localFile) -and (Test-Path $backupFile)) {
                $localHash = Get-FileHash -Algorithm SHA256 -Path $localFile
                $backupHash = Get-FileHash -Algorithm SHA256 -Path $backupFile
                if ($localHash.Hash -ne $backupHash.Hash) {
                    $diffItems += [pscustomobject]@{
                        Assistant = "app-configs/$($appConfig.Name)"
                        Relative  = $relativePath
                        Local     = $localFile
                        Backup    = $backupFile
                    }
                }
            }
        }
    }

    if (-not $diffItems) {
        Write-Log "No text config differences detected in the preview set."
        return
    }

    Write-Log "Preview-eligible file changes detected:"
    foreach ($item in $diffItems) {
        Write-Host "  - [$($item.Assistant)] $($item.Relative)"
    }

    if ((Read-Host "Preview text diffs? (y/n)") -ne 'y') {
        return
    }

    foreach ($item in $diffItems) {
        Write-Host ""
        Write-Host "=== [$($item.Assistant)] $($item.Relative) ===" -ForegroundColor Cyan
        $diff = Compare-Object (Get-Content $item.Local) (Get-Content $item.Backup) -SyncWindow 2
        if ($diff) {
            $diff | Select-Object -First 40 | Out-String | Write-Host
        }
    }
}

function Get-GitRepoRoot {
    param([string]$Path)

    $current = $Path
    while ($current -and (Split-Path $current)) {
        if (Test-Path (Join-Path $current ".git")) {
            return $current
        }
        $current = Split-Path $current -Parent
    }
    return $null
}

function Get-RelativePath {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )

    $resolvedBase = (Resolve-Path $BasePath).Path
    $resolvedTarget = (Resolve-Path $TargetPath).Path
    if (-not $resolvedBase.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $resolvedBase += [System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = New-Object System.Uri($resolvedBase)
    $targetUri = New-Object System.Uri($resolvedTarget)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

function Invoke-GitSync {
    param(
        [ValidateSet("pull", "push")]
        [string]$Action,
        [string]$TargetPath
    )

    $repoRoot = Get-GitRepoRoot -Path $Script:BaseBackupPath
    if (-not $repoRoot) {
        Write-Log "Backup path is not inside a Git repository; skipping Git $Action." -Level Warning
        return
    }

    $previousLocation = Get-Location
    try {
        Set-Location $repoRoot
        if ($Action -eq "pull") {
            if (Test-IsDryRun) {
                Write-Log "Dry run: would run git pull --stat in $repoRoot"
                return
            }
            Write-Log "Pulling latest changes for backup repository..."
            & git pull --stat
            return
        }

        $relativeTarget = Get-RelativePath -BasePath $repoRoot -TargetPath $TargetPath
        if (Test-IsDryRun) {
            Write-Log "Dry run: would git add/commit/pull/push subtree $relativeTarget"
            return
        }
        Write-Log "Staging backup changes from $relativeTarget..."
        & git add -- $relativeTarget
        & git diff --cached --quiet -- $relativeTarget
        if ($LASTEXITCODE -eq 0) {
            Write-Log "No staged backup changes to commit."
            return
        }

        $message = "Auto-backup LLM settings ($env:COMPUTERNAME): $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        & git commit -S -m $message -- $relativeTarget
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Git commit failed." -Level Error
            return
        }

        & git pull --rebase
        if ($LASTEXITCODE -ne 0) {
            Write-Log "git pull --rebase failed; attempting a normal pull." -Level Warning
            & git rebase --abort 2>$null
            & git pull
        }

        Write-Log "Pushing backup changes..."
        & git push
    }
    catch {
        Write-Log "Git $Action failed: $_" -Level Error
    }
    finally {
        Set-Location $previousLocation
    }
}

try {
    if (-not $Action) {
        $Action = Get-MenuChoice -Title "Select Action" -Options @("Backup", "Restore", "Audit", "Sync-Skills", "Migrate-Skills", "Install-Repo-Skills")
    }

    Write-Log "=== LLM Sync Started ==="
    if (Test-IsDryRun) {
        Write-Log "Dry run mode enabled. No files will be changed."
    }

    Ensure-SharedSkillsDirectory

    if ($Action -eq "audit") {
        Invoke-SkillAudit
        Write-Log "=== LLM Sync Completed ===" -Level Success
        return
    }

    if ($Action -eq "sync-skills") {
        Invoke-SkillSync
        Write-Log "=== LLM Sync Completed ===" -Level Success
        return
    }

    if ($Action -eq "migrate-skills") {
        if ($DestructiveMigrate) {
            Invoke-DestructiveSkillMigration
        }
        else {
            Write-Log "migrate-skills now aliases safe sync-skills. Use -DestructiveMigrate to archive/remove local copies." -Level Warning
            Invoke-SkillSync
        }
        Write-Log "=== LLM Sync Completed ===" -Level Success
        return
    }

    if ($Action -eq "install-repo-skills") {
        Invoke-RepoSkillInstall
        Write-Log "=== LLM Sync Completed ===" -Level Success
        return
    }

    Initialize-BackupConfiguration
    $machineName = $env:COMPUTERNAME
    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $subFolder = if ($Versioned -and $Action -eq "backup") { "${machineName}_$timestamp" } else { $machineName }
    $backupRoot = Join-Path $Script:BaseBackupPath $subFolder

    if ($Force -or (Read-Host "Pull latest settings from Git? (y/n)") -eq 'y') {
        Invoke-GitSync -Action pull -TargetPath $Script:BaseBackupPath
    }

    if ($Action -eq "restore") {
        $backups = Get-ChildItem $Script:BaseBackupPath -Directory | Sort-Object LastWriteTime -Descending
        if (-not $backups) {
            Write-Log "No machine backups found under $($Script:BaseBackupPath)." -Level Error
            exit 1
        }

        if ($backups.Count -gt 1 -and -not $Force) {
            Write-Log "Select backup to restore:"
            for ($i = 0; $i -lt $backups.Count; $i++) {
                $dateString = $backups[$i].LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                Write-Host "  [$i] $($backups[$i].Name) (Modified: $dateString)"
            }
            $selection = Read-Host "Choice"
            if ($selection -match '^\d+$' -and [int]$selection -lt $backups.Count) {
                $backupRoot = $backups[[int]$selection].FullName
            }
            else {
                $backupRoot = $backups[0].FullName
            }
        }
        else {
            $backupRoot = $backups[0].FullName
        }

        Create-SafetyBackup -RestoreLabel (Split-Path $backupRoot -Leaf)
        Preview-RestoreDiffs -BackupRoot $backupRoot
        foreach ($assistant in $Script:Assistants) {
            Write-Log "Restoring $($assistant.Name)..."
            Restore-Assistant -Assistant $assistant -BackupRoot $backupRoot
        }
        Write-Log "Restoring $($Script:SharedSkills.Name)..."
        Restore-SharedSkills -BackupRoot $backupRoot
        foreach ($appConfig in $Script:AppConfigs) {
            Write-Log "Restoring app-configs/$($appConfig.Name)..."
            Restore-AppConfig -AppConfig $appConfig -BackupRoot $backupRoot
        }
    }
    else {
        Ensure-Directory -Path $backupRoot
        foreach ($assistant in $Script:Assistants) {
            Write-Log "Backing up $($assistant.Name)..."
            Sync-AssistantBackup -Assistant $assistant -DestinationRoot $backupRoot
        }
        Write-Log "Backing up $($Script:SharedSkills.Name)..."
        Sync-SharedSkillsBackup -DestinationRoot $backupRoot
        foreach ($appConfig in $Script:AppConfigs) {
            Write-Log "Backing up app-configs/$($appConfig.Name)..."
            Sync-AppConfigBackup -AppConfig $appConfig -DestinationRoot $backupRoot
        }

        if ($Force -or (Read-Host "Push backup changes to Git? (y/n)") -eq 'y') {
            Invoke-GitSync -Action push -TargetPath $backupRoot
        }

        if ($Versioned) {
            $retentionDays = 30
            $oldBackups = Get-ChildItem $Script:BaseBackupPath -Directory |
                Where-Object { $_.Name -match "^$machineName\_" -and $_.LastWriteTime -lt (Get-Date).AddDays(-$retentionDays) }

            if ($oldBackups) {
                Write-Log "Found $($oldBackups.Count) versioned backups older than $retentionDays days."
                if ($Force -or (Read-Host "Prune old backups? (y/n)") -eq 'y') {
                    if (Test-IsDryRun) {
                        foreach ($backup in $oldBackups) {
                            Write-Log "Dry run: would remove old versioned backup $($backup.FullName)"
                        }
                    }
                    else {
                        $oldBackups | Remove-Item -Recurse -Force
                        Write-Log "Old backups pruned." -Level Success
                    }
                }
            }
        }
    }

    Write-Log "=== LLM Sync Completed ===" -Level Success
}
catch {
    Write-Log "Fatal error: $_" -Level Error
    exit 1
}

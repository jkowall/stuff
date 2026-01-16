<#
.SYNOPSIS
    Plex Media Server Backup Script
    
.DESCRIPTION
    Backs up Plex data and registry settings to a compressed archive.
    Uses a temporary fast directory (D:\tmp) for intermediate operations.
    Robustly stops Plex services and processes before backup.
    
.NOTES
    Prerequisite: NanaZip (winget install M2Team.NanaZip)
#>

# Self-elevation logic
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator privileges..."
    $ScriptPath = $MyInvocation.MyCommand.Definition
    Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -File `"$ScriptPath`"" -Verb RunAs
    exit
}

# Load configuration from JSON file
$ConfigPath = Join-Path $PSScriptRoot "plex_backup.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config file not found: $ConfigPath. Please create it with PlexDataPath, BackupDestination, TempWorkingPath, and 7ZipPath."
    exit 1
}
$ConfigData = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# Configuration
$PlexDataPath = $ConfigData.PlexDataPath
$BackupDestination = $ConfigData.BackupDestination
$TempWorkingPath = $ConfigData.TempWorkingPath
$RegistryKey = "HKLM\SOFTWARE\Plex, Inc.\Plex Media Server"
$7ZipPath = $ConfigData.'7ZipPath'
$PlexServiceNames = @("PlexService", "Plex Media Server")
$MaxBackups = 2


# Generate timestamp for this backup
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Temporary directory for intermediate steps
$CurrentTempDir = Join-Path $TempWorkingPath "PlexBackup_Work_$Timestamp"
$LogFile = Join-Path $CurrentTempDir "backup_log_$Timestamp.txt"

# Track which services we stop so we can restart them
$StoppedServices = @()
$ServicesRestarted = $false

# Start logging
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $LogEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Write-Host $LogEntry
    if (Test-Path $CurrentTempDir) {
        Add-Content -Path $LogFile -Value $LogEntry
    }
}

try {
    Write-Log "=== Plex Media Server Backup Started ==="
    Write-Log "Timestamp: $Timestamp"
    Write-Log "Backup Destination: $BackupDestination"
    Write-Log "Temporary Working Path: $TempWorkingPath"
    
    # Prerequisite checks
    if (!(Test-Path -Path $PlexDataPath)) {
        throw "Plex data path not found: $PlexDataPath"
    }
    
    if (!(Test-Path -Path $7ZipPath)) {
        throw "NanaZip/7-Zip not found at: $7ZipPath`nInstall via: winget install M2Team.NanaZip"
    }

    # Create temporary working directory
    if (!(Test-Path -Path $TempWorkingPath)) {
        New-Item -ItemType Directory -Path $TempWorkingPath | Out-Null
        Write-Log "Created temporary working root: $TempWorkingPath"
    }
    New-Item -ItemType Directory -Path $CurrentTempDir | Out-Null
    Write-Log "Created temporary working directory: $CurrentTempDir"
    
    # Create final backup destination if needed
    if (!(Test-Path -Path $BackupDestination)) {
        New-Item -ItemType Directory -Path $BackupDestination | Out-Null
        Write-Log "Created backup destination: $BackupDestination"
    }
    
    # Robustly Stop Plex Services and Processes
    Write-Log "Attempting to stop all Plex-related services..."
    foreach ($SvcName in $PlexServiceNames) {
        $Service = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
        if ($Service -and $Service.Status -eq 'Running') {
            Write-Log "  Stopping service: $SvcName..."
            Stop-Service -Name $SvcName -Force
            $Service.WaitForStatus('Stopped', '00:00:30')
            $StoppedServices += $SvcName
            Write-Log "  $SvcName stopped."
        }
    }

    # Stop any leftover processes (important if not running as service or if service stop didn't kill all children)
    $PlexProcesses = Get-Process -Name "Plex Media Server*", "PlexDLNA*", "PlexTuner*", "PlexUpdate*" -ErrorAction SilentlyContinue
    if ($PlexProcesses) {
        Write-Log "  Terminating $($PlexProcesses.Count) remaining Plex processes..."
        $PlexProcesses | Stop-Process -Force
        Start-Sleep -Seconds 2
        Write-Log "  Processes terminated."
    }
    
    # Backup Plex data directory to Temp
    Write-Log "Copying Plex data to temporary storage..."
    $WorkingDataDir = Join-Path $CurrentTempDir "PlexData"
    New-Item -ItemType Directory -Path $WorkingDataDir | Out-Null
    
    $SourceFiles = Get-ChildItem -Path $PlexDataPath -Recurse -File
    $TotalFiles = $SourceFiles.Count
    $TotalSizeBytes = ($SourceFiles | Measure-Object -Property Length -Sum).Sum
    $TotalSizeMB = [math]::Round($TotalSizeBytes / 1MB, 2)
    Write-Log "  Source: $TotalFiles files, $TotalSizeMB MB"
    
    $copiedCount = 0
    $copiedBytes = 0
    
    foreach ($file in $SourceFiles) {
        $relativePath = $file.FullName.Substring($PlexDataPath.Length)
        $destPath = Join-Path $WorkingDataDir $relativePath
        $destDir = Split-Path -Parent $destPath
        
        if (!(Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        
        Copy-Item -Path $file.FullName -Destination $destPath -Force
        
        # Report every 50 files to UI/Log to show movement
        if ($copiedCount % 50 -eq 0 -or $copiedCount -eq $TotalFiles) {
            Write-Log "  [Copying] ($([math]::Round($copiedCount/$TotalFiles*100))%) File: $($file.Name)"
        }
        
        $copiedCount++
        $copiedBytes += $file.Length
        Write-Progress -Activity "Copying Plex Data to $TempWorkingPath" -Status "$copiedCount of $TotalFiles files ($([math]::Round($copiedBytes/1MB, 1)) MB)" -PercentComplete ([math]::Round(($copiedBytes / $TotalSizeBytes) * 100))
    }
    Write-Progress -Activity "Copying Plex Data to $TempWorkingPath" -Completed
    Write-Log "Data copy to temporary storage complete."
    
    # Backup registry to Temp
    Write-Log "Exporting registry key to temporary storage..."
    $TempRegPath = Join-Path $CurrentTempDir "PlexRegistry_$Timestamp.reg"
    $RegResult = reg export $RegistryKey $TempRegPath /y 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Log "  Registry export complete." }
    else { Write-Log "  Registry export warning: $RegResult" -Level "WARN" }
    
    # Compress within Temp
    Write-Log "Compressing backup in temporary storage..."
    $DataArchive = Join-Path $CurrentTempDir "PlexBackup_$Timestamp.7z"
    $job = Start-Job -ScriptBlock {
        param($7z, $archive, $data, $reg)
        & $7z a -t7z -mx=9 $archive $data $reg 2>&1
        return $LASTEXITCODE
    } -ArgumentList $7ZipPath, $DataArchive, $WorkingDataDir, $TempRegPath
    
    # Restart Services EARLY to minimize downtime
    if ($StoppedServices.Count -gt 0) {
        Write-Log "Restarting Plex services early (compression is running in background)..."
        foreach ($SvcName in $StoppedServices) {
            Write-Log "  Starting $SvcName..."
            Start-Service -Name $SvcName -ErrorAction SilentlyContinue
            $Service = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
            if ($Service) { $Service.WaitForStatus('Running', '00:00:30') }
            Write-Log "  $SvcName started."
        }
        $ServicesRestarted = $true
    }

    # Monitor progress by checking archive size
    $expectedRatio = 0.3
    $expectedSize = $TotalSizeBytes * $expectedRatio
    while ($job.State -eq 'Running') {
        Start-Sleep -Milliseconds 500
        if (Test-Path $DataArchive) {
            $currSize = (Get-Item $DataArchive).Length
            $pct = [math]::Min(99, [math]::Round(($currSize / $expectedSize) * 100))
            Write-Progress -Activity "Compressing Plex Backup" -Status "$([math]::Round($currSize/1MB,1)) MB written" -PercentComplete $pct
        }
    }
    Write-Progress -Activity "Compressing Plex Backup" -Completed
    $jobResult = Receive-Job -Job $job
    Remove-Job -Job $job -Force
    
    if (!(Test-Path $DataArchive)) { throw "7-Zip compression failed - archive not created" }
    Write-Log "Compression complete."

    # Move to Final Destination
    Write-Log "Moving final backup to destination ($BackupDestination)..."
    $FinalArchivePath = Join-Path $BackupDestination "PlexBackup_$Timestamp.7z"
    $FinalLogPath = Join-Path $BackupDestination "backup_log_$Timestamp.txt"
    
    Move-Item -Path $DataArchive -Destination $FinalArchivePath -Force
    Write-Log "  Archive moved successfully."
    
    Move-Item -Path $LogFile -Destination $FinalLogPath -Force
    # Re-map log file to final destination
    $LogFile = $FinalLogPath
    Write-Log "  Log moved successfully."

    # Cleanup Temp
    Write-Log "Cleaning up temporary working directory..."
    Remove-Item -Path $CurrentTempDir -Recurse -Force
    Write-Log "  Temp cleanup complete."
    
    # Retention
    Write-Log "Applying retention policy (keeping $MaxBackups)..."
    $OldBackups = Get-ChildItem -Path $BackupDestination -Filter "PlexBackup_*.7z" | Sort-Object LastWriteTime -Descending | Select-Object -Skip $MaxBackups
    $OldLogs = Get-ChildItem -Path $BackupDestination -Filter "backup_log_*.txt" | Sort-Object LastWriteTime -Descending | Select-Object -Skip $MaxBackups
    $OldBackups | ForEach-Object { Remove-Item $_.FullName -Force; Write-Log "  Deleted old backup: $($_.Name)" }
    $OldLogs | ForEach-Object { Remove-Item $_.FullName -Force; Write-Log "  Deleted old log: $($_.Name)" }

    Write-Log "Plex backup completed successfully!"
    
}
catch {
    Write-Log "BACKUP FAILED: $_" -Level "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
    throw
}
finally {
    # Restart Services if not already done
    if (!$ServicesRestarted -and $StoppedServices.Count -gt 0) {
        Write-Log "Restarting Plex services in cleanup block..."
        foreach ($SvcName in $StoppedServices) {
            Write-Log "  Starting $SvcName..."
            Start-Service -Name $SvcName -ErrorAction SilentlyContinue
            $Service = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
            if ($Service) { $Service.WaitForStatus('Running', '00:00:30') }
            Write-Log "  $SvcName started."
        }
    }
    Write-Log "Backup script finished."
}
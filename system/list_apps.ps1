<#
.SYNOPSIS
    Lists installed applications from multiple sources.

.DESCRIPTION
    Scans multiple installation sources to find all installed applications:
    - Windows Registry (traditional Win32 installers)
    - Microsoft Store (UWP/MSIX apps)
    - Winget packages
    - Chocolatey packages
    - Scoop packages
    - NPM global packages

.PARAMETER Filter
    Optional. Filter applications by name (supports wildcards).

.PARAMETER Source
    Optional. Limit to specific sources. Valid values: Registry, Store, Winget, Chocolatey, Scoop, NPM, All
    Default: All

.PARAMETER ExportPath
    Optional. Path to export results (supports .csv and .json extensions).

.PARAMETER IncludeSystemComponents
    Switch to include system components (usually hidden from Programs & Features).

.EXAMPLE
    .\List Apps.ps1
    Lists all installed applications from all sources.

.EXAMPLE
    .\List Apps.ps1 -Source Winget
    Lists only Winget-installed packages.

.EXAMPLE
    .\List Apps.ps1 -Filter "*Chrome*" -Source Registry,Store
    Lists Chrome-related apps from Registry and Microsoft Store.

.EXAMPLE
    .\List Apps.ps1 -ExportPath "C:\apps.json"
    Exports all applications to a JSON file.
#>

[CmdletBinding()]
param(
    [string]$Filter = "*",
    [ValidateSet("Registry", "Store", "Winget", "Chocolatey", "Scoop", "NPM", "All")]
    [string[]]$Source = @("All"),
    [string]$ExportPath,
    [switch]$IncludeSystemComponents
)

#region Helper Functions

function ConvertTo-ReadableDate {
    param([string]$DateString)
    
    if ([string]::IsNullOrWhiteSpace($DateString)) { return $null }
    
    if ($DateString -match '^\d{8}$') {
        try {
            return [datetime]::ParseExact($DateString, 'yyyyMMdd', $null)
        }
        catch { return $null }
    }
    return $null
}

function Format-Size {
    param([int64]$SizeKB)
    
    if ($SizeKB -le 0) { return $null }
    
    $SizeBytes = $SizeKB * 1024
    switch ($SizeBytes) {
        { $_ -ge 1GB } { return "{0:N2} GB" -f ($_ / 1GB) }
        { $_ -ge 1MB } { return "{0:N2} MB" -f ($_ / 1MB) }
        { $_ -ge 1KB } { return "{0:N2} KB" -f ($_ / 1KB) }
        default { return "$_ B" }
    }
}

function Test-CommandExists {
    param([string]$Command)
    return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

#endregion

#region Source Collection Functions

function Get-RegistryApps {
    param([string]$Filter, [bool]$IncludeSystem)
    
    Write-Host "  Scanning Windows Registry..." -ForegroundColor Gray
    
    $UninstallPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    
    $SeenApps = @{}
    $Apps = [System.Collections.ArrayList]::new()
    
    foreach ($Path in $UninstallPaths) {
        if (-not (Test-Path $Path)) { continue }
        
        Get-ChildItem $Path -ErrorAction SilentlyContinue | ForEach-Object {
            $Props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            
            if (-not $Props.DisplayName) { return }
            if (-not $IncludeSystem -and $Props.SystemComponent -eq 1) { return }
            if ($Props.DisplayName -notlike $Filter) { return }
            
            $dedupKey = "$($Props.DisplayName)|$($Props.DisplayVersion)"
            if ($SeenApps.ContainsKey($dedupKey)) { return }
            $SeenApps[$dedupKey] = $true
            
            [void]$Apps.Add([PSCustomObject]@{
                    Name        = $Props.DisplayName
                    Version     = $Props.DisplayVersion
                    Publisher   = $Props.Publisher
                    InstallDate = ConvertTo-ReadableDate $Props.InstallDate
                    Size        = Format-Size $Props.EstimatedSize
                    Source      = "Registry"
                    Location    = $Props.InstallLocation
                })
        }
    }
    
    Write-Host "    Found $($Apps.Count) apps" -ForegroundColor DarkGray
    return $Apps
}

function Get-StoreApps {
    param([string]$Filter)
    
    Write-Host "  Scanning Microsoft Store apps..." -ForegroundColor Gray
    
    $Apps = [System.Collections.ArrayList]::new()
    
    try {
        $packages = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -notlike "Microsoft.Windows.*" -and
            $_.Name -notlike "Microsoft.UI.*" -and
            $_.Name -notlike "Microsoft.VCLibs.*" -and
            $_.Name -notlike "Microsoft.NET.*" -and
            $_.IsFramework -eq $false
        }
        
        foreach ($pkg in $packages) {
            # Try to get the display name from manifest
            $displayName = $pkg.Name
            try {
                $manifest = Get-AppxPackageManifest $pkg -ErrorAction SilentlyContinue
                if ($manifest.Package.Properties.DisplayName -and 
                    $manifest.Package.Properties.DisplayName -notlike "ms-resource:*") {
                    $displayName = $manifest.Package.Properties.DisplayName
                }
            }
            catch { }
            
            if ($displayName -notlike $Filter) { continue }
            
            # Parse publisher name
            $pubName = $null
            if ($pkg.Publisher) {
                $parts = $pkg.Publisher -split ','
                $pubName = $parts[0] -replace 'CN=', ''
            }
            
            [void]$Apps.Add([PSCustomObject]@{
                    Name        = $displayName
                    Version     = $pkg.Version.ToString()
                    Publisher   = $pubName
                    InstallDate = $null
                    Size        = $null
                    Source      = "Store"
                    Location    = $pkg.InstallLocation
                })
        }
    }
    catch {
        Write-Warning "Could not retrieve Microsoft Store apps: $_"
    }
    
    Write-Host "    Found $($Apps.Count) apps" -ForegroundColor DarkGray
    return $Apps
}

function Get-WingetApps {
    param([string]$Filter)
    
    if (-not (Test-CommandExists "winget")) {
        Write-Host "  Winget not installed, skipping..." -ForegroundColor DarkGray
        return @()
    }
    
    Write-Host "  Scanning Winget packages..." -ForegroundColor Gray
    
    $Apps = [System.Collections.ArrayList]::new()
    
    try {
        # Use winget export to get JSON output
        $output = winget list --disable-interactivity 2>$null
        
        # Parse the tabular output (skip header lines)
        $lines = $output | Where-Object { $_ -match '\S' }
        $dataStarted = $false
        
        foreach ($line in $lines) {
            # Look for the separator line
            if ($line -match '^-+') {
                $dataStarted = $true
                continue
            }
            
            if (-not $dataStarted) { continue }
            
            # Parse the line - winget uses fixed-width columns
            # Format: Name, Id, Version, Available, Source
            if ($line -match '^(.+?)\s{2,}(\S+)\s+(\S+)') {
                $name = $Matches[1].Trim()
                $version = $Matches[3].Trim()
                
                if ($name -notlike $Filter) { continue }
                
                [void]$Apps.Add([PSCustomObject]@{
                        Name        = $name
                        Version     = $version
                        Publisher   = $null
                        InstallDate = $null
                        Size        = $null
                        Source      = "Winget"
                        Location    = $null
                    })
            }
        }
    }
    catch {
        Write-Warning "Could not retrieve Winget packages: $_"
    }
    
    Write-Host "    Found $($Apps.Count) packages" -ForegroundColor DarkGray
    return $Apps
}

function Get-ChocolateyApps {
    param([string]$Filter)
    
    if (-not (Test-CommandExists "choco")) {
        Write-Host "  Chocolatey not installed, skipping..." -ForegroundColor DarkGray
        return @()
    }
    
    Write-Host "  Scanning Chocolatey packages..." -ForegroundColor Gray
    
    $Apps = [System.Collections.ArrayList]::new()
    
    try {
        $output = choco list --local-only --limit-output 2>$null
        
        foreach ($line in $output) {
            if ($line -match '^(.+)\|(.+)$') {
                $name = $Matches[1]
                $version = $Matches[2]
                
                if ($name -notlike $Filter) { continue }
                
                [void]$Apps.Add([PSCustomObject]@{
                        Name        = $name
                        Version     = $version
                        Publisher   = $null
                        InstallDate = $null
                        Size        = $null
                        Source      = "Chocolatey"
                        Location    = "$env:ChocolateyInstall\lib\$name"
                    })
            }
        }
    }
    catch {
        Write-Warning "Could not retrieve Chocolatey packages: $_"
    }
    
    Write-Host "    Found $($Apps.Count) packages" -ForegroundColor DarkGray
    return $Apps
}

function Get-ScoopApps {
    param([string]$Filter)
    
    if (-not (Test-CommandExists "scoop")) {
        Write-Host "  Scoop not installed, skipping..." -ForegroundColor DarkGray
        return @()
    }
    
    Write-Host "  Scanning Scoop packages..." -ForegroundColor Gray
    
    $Apps = [System.Collections.ArrayList]::new()
    
    try {
        $scoopDir = if ($env:SCOOP) { $env:SCOOP } else { "$env:USERPROFILE\scoop" }
        $appsDir = Join-Path $scoopDir "apps"
        
        if (Test-Path $appsDir) {
            Get-ChildItem $appsDir -Directory | Where-Object { $_.Name -ne "scoop" } | ForEach-Object {
                $appName = $_.Name
                $currentDir = Join-Path $_.FullName "current"
                $version = "Unknown"
                
                # Try to get version from manifest
                $manifestPath = Join-Path $currentDir "manifest.json"
                if (Test-Path $manifestPath) {
                    try {
                        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
                        $version = $manifest.version
                    }
                    catch { }
                }
                
                if ($appName -notlike $Filter) { return }
                
                [void]$Apps.Add([PSCustomObject]@{
                        Name        = $appName
                        Version     = $version
                        Publisher   = $null
                        InstallDate = $_.CreationTime
                        Size        = $null
                        Source      = "Scoop"
                        Location    = $currentDir
                    })
            }
        }
    }
    catch {
        Write-Warning "Could not retrieve Scoop packages: $_"
    }
    
    Write-Host "    Found $($Apps.Count) packages" -ForegroundColor DarkGray
    return $Apps
}

function Get-NpmGlobalApps {
    param([string]$Filter)
    
    if (-not (Test-CommandExists "npm")) {
        Write-Host "  NPM not installed, skipping..." -ForegroundColor DarkGray
        return @()
    }
    
    Write-Host "  Scanning NPM global packages..." -ForegroundColor Gray
    
    $Apps = [System.Collections.ArrayList]::new()
    
    try {
        $output = npm list -g --depth=0 --json 2>$null | ConvertFrom-Json
        
        if ($output.dependencies) {
            $output.dependencies.PSObject.Properties | ForEach-Object {
                $name = $_.Name
                $version = $_.Value.version
                
                if ($name -notlike $Filter) { return }
                
                [void]$Apps.Add([PSCustomObject]@{
                        Name        = $name
                        Version     = $version
                        Publisher   = $null
                        InstallDate = $null
                        Size        = $null
                        Source      = "NPM"
                        Location    = $null
                    })
            }
        }
    }
    catch {
        Write-Warning "Could not retrieve NPM packages: $_"
    }
    
    Write-Host "    Found $($Apps.Count) packages" -ForegroundColor DarkGray
    return $Apps
}

#endregion

#region Main Execution

Write-Host "`nScanning for installed applications..." -ForegroundColor Cyan

$AllApps = [System.Collections.ArrayList]::new()
$Sources = if ($Source -contains "All") { @("Registry", "Store", "Winget", "Chocolatey", "Scoop", "NPM") } else { $Source }

foreach ($src in $Sources) {
    $apps = switch ($src) {
        "Registry" { Get-RegistryApps -Filter $Filter -IncludeSystem $IncludeSystemComponents }
        "Store" { Get-StoreApps -Filter $Filter }
        "Winget" { Get-WingetApps -Filter $Filter }
        "Chocolatey" { Get-ChocolateyApps -Filter $Filter }
        "Scoop" { Get-ScoopApps -Filter $Filter }
        "NPM" { Get-NpmGlobalApps -Filter $Filter }
    }
    if ($apps -and $apps.Count -gt 0) {
        [void]$AllApps.AddRange(@($apps))
    }
}

# Sort results
$SortedApps = $AllApps | Sort-Object Source, Name

# Summary by source
Write-Host "`n📊 Summary by Source:" -ForegroundColor Cyan
$SortedApps | Group-Object Source | ForEach-Object {
    Write-Host "   $($_.Name): $($_.Count)" -ForegroundColor White
}
Write-Host "   ─────────────────" -ForegroundColor DarkGray
Write-Host "   Total: $($SortedApps.Count)" -ForegroundColor Green

# Export if path specified
if ($ExportPath) {
    $extension = [System.IO.Path]::GetExtension($ExportPath).ToLower()
    
    switch ($extension) {
        ".csv" {
            $SortedApps | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
            Write-Host "`n✅ Exported to: $ExportPath" -ForegroundColor Green
        }
        ".json" {
            $SortedApps | ConvertTo-Json -Depth 3 | Out-File -Path $ExportPath -Encoding UTF8
            Write-Host "`n✅ Exported to: $ExportPath" -ForegroundColor Green
        }
        default {
            Write-Warning "Unsupported export format. Use .csv or .json"
        }
    }
}
else {
    # Display results grouped by source
    Write-Host "`n📋 Installed Applications:" -ForegroundColor Cyan
    $SortedApps | Format-Table Name, Version, Publisher, Source, @{
        Label      = "Install Date"
        Expression = { if ($_.InstallDate) { $_.InstallDate.ToString("yyyy-MM-dd") } else { "" } }
    } -AutoSize
}

# Return the objects for pipeline use
$SortedApps

#endregion

<#
.SYNOPSIS
    Updates Cloudflare DNS record with the current public IP address.
.DESCRIPTION
    This script retrieves your public IP address and updates the specified Cloudflare DNS record.
    It can also install or remove a daily Windows Task Scheduler task for itself.
.PARAMETER InstallScheduledTask
    Installs or updates the daily scheduled task and exits without updating DNS.
.PARAMETER RemoveScheduledTask
    Removes the scheduled task and exits without updating DNS.
.PARAMETER DailyAt
    The local time for the daily task. Defaults to 12:00 PM.
.PARAMETER TaskName
    The scheduled task name. Defaults to "Cloudflare Dynamic DNS Update".
.EXAMPLE
    .\Update-CloudflareDNS.ps1
    Checks the public IP address and updates Cloudflare when needed.
.EXAMPLE
    .\Update-CloudflareDNS.ps1 -InstallScheduledTask
    Installs the daily task for 12:00 PM.
.EXAMPLE
    .\Update-CloudflareDNS.ps1 -InstallScheduledTask -DailyAt '06:30'
    Installs the daily task for 6:30 AM.
.EXAMPLE
    .\Update-CloudflareDNS.ps1 -RemoveScheduledTask
    Removes the daily task.
.NOTES
    Requires a Cloudflare API token with Zone:DNS edit permissions.
#>

[CmdletBinding(DefaultParameterSetName = 'UpdateDns')]
param (
    [Parameter(Mandatory = $true, ParameterSetName = 'InstallTask')]
    [switch]$InstallScheduledTask,

    [Parameter(Mandatory = $true, ParameterSetName = 'RemoveTask')]
    [switch]$RemoveScheduledTask,

    [Parameter(ParameterSetName = 'InstallTask')]
    [datetime]$DailyAt = [datetime]::Today.AddHours(12),

    [Parameter(ParameterSetName = 'InstallTask')]
    [Parameter(ParameterSetName = 'RemoveTask')]
    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'Cloudflare Dynamic DNS Update'
)

$ConfigPath = Join-Path $env:USERPROFILE "Private\Configs\Update-CloudflareDNS.json"

function Install-CloudflareDnsScheduledTask {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [datetime]$At
    )

    if ($env:OS -ne 'Windows_NT') {
        throw 'Scheduled task installation is only supported on Windows.'
    }

    if (-not (Test-Path $ConfigPath)) {
        throw "Config file not found: $ConfigPath. Create it before installing the scheduled task."
    }

    $PowerShellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
    $ActionArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $Action = New-ScheduledTaskAction `
        -Execute $PowerShellPath `
        -Argument $ActionArguments `
        -WorkingDirectory $PSScriptRoot
    $Trigger = New-ScheduledTaskTrigger -Daily -At $At
    $Principal = New-ScheduledTaskPrincipal `
        -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive `
        -RunLevel Limited
    $Settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

    Register-ScheduledTask `
        -TaskName $Name `
        -Action $Action `
        -Trigger $Trigger `
        -Principal $Principal `
        -Settings $Settings `
        -Description 'Updates the configured Cloudflare DNS record to the current public IPv4 address.' `
        -Force | Out-Null

    $TaskInfo = Get-ScheduledTaskInfo -TaskName $Name
    Write-Output "Scheduled task '$Name' installed. Next run: $($TaskInfo.NextRunTime)."
}

function Remove-CloudflareDnsScheduledTask {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue)) {
        Write-Output "Scheduled task '$Name' is not installed."
        return
    }

    Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    Write-Output "Scheduled task '$Name' removed."
}

try {
    if ($InstallScheduledTask) {
        Install-CloudflareDnsScheduledTask -Name $TaskName -At $DailyAt
        exit 0
    }

    if ($RemoveScheduledTask) {
        Remove-CloudflareDnsScheduledTask -Name $TaskName
        exit 0
    }
}
catch {
    Write-Error $_
    exit 1
}

# Load configuration from JSON file
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config file not found: $ConfigPath. Please create it with ApiToken, ZoneId, DnsRecordName, and TtlValue."
    exit 1
}
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$ApiToken = $Config.ApiToken
$ZoneId = $Config.ZoneId
$DnsRecordName = $Config.DnsRecordName
$TtlValue = $Config.TtlValue

# Function to get the public IP address
function Get-PublicIpAddress {
    try {
        $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim()
        return $publicIp # Return only the IP address
    }
    catch {
        Write-Error "Failed to retrieve public IP address: $_"
        exit 1
    }
}

# Function to get the DNS record ID
function Get-CloudflareDnsRecord {
    try {
        $headers = @{
            'Authorization' = "Bearer $ApiToken"
            'Content-Type'  = 'application/json'
        }
        
        $apiUrl = "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records?name=$DnsRecordName"
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
        
        if ($response.success -and $response.result.Count -gt 0) {
            return $response.result[0]
        }
        else {
            Write-Error "Failed to retrieve DNS record: $($response.errors | ConvertTo-Json)"
            exit 1
        }
    }
    catch {
        Write-Error "API call to retrieve DNS record failed: $_"
        exit 1
    }
}

# Function to update the DNS record
function Update-CloudflareDnsRecord {
    param (
        [Parameter(Mandatory = $true)]
        [string]$RecordId,
        
        [Parameter(Mandatory = $true)]
        [string]$IpAddress,
        
        [Parameter(Mandatory = $true)]
        [string]$RecordType
    )
    
    try {
        $headers = @{
            'Authorization' = "Bearer $ApiToken"
            'Content-Type'  = 'application/json'
        }
        
        $body = @{
            type    = $RecordType
            name    = $DnsRecordName
            content = $IpAddress
            ttl     = $TtlValue
            proxied = $false
        } | ConvertTo-Json -Depth 10
        
        $apiUrl = "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records/$RecordId"
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Put -Body $body
        
        if ($response.success) {
            Write-Output "DNS record updated successfully."
            return $true
        }
        else {
            Write-Error "Failed to update DNS record: $($response.errors | ConvertTo-Json)"
            return $false
        }
    }
    catch {
        Write-Error "API call to update DNS record failed: $_"
        return $false
    }
}

# Main script execution
Write-Output "Starting Cloudflare DNS update for $DnsRecordName at $(Get-Date)"

# Get the current public IP
$currentIp = Get-PublicIpAddress

# Get the current DNS record
$dnsRecord = Get-CloudflareDnsRecord

# Check if the IP address needs updating
if ($dnsRecord.content -eq $currentIp) {
    Write-Output "IP address is unchanged. No update required."
}
else {
    Write-Output "Current DNS record IP: $($dnsRecord.content)"
    Write-Output "New IP address: $currentIp"
    Write-Output "Updating DNS record..."
    
    $result = Update-CloudflareDnsRecord -RecordId $dnsRecord.id -IpAddress $currentIp -RecordType $dnsRecord.type
    
    if ($result) {
        Write-Output "DNS record for $DnsRecordName updated to $currentIp"
    }
}

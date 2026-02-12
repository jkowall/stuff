<#
.SYNOPSIS
    Updates Cloudflare DNS record with the current public IP address.
.DESCRIPTION
    This script retrieves your public IP address and updates the specified Cloudflare DNS record.
.NOTES
    Requires a Cloudflare API token with Zone:DNS edit permissions.
#>

# Load configuration from JSON file
$ConfigPath = Join-Path $env:USERPROFILE "Private\Configs\Update-CloudflareDNS.json"
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
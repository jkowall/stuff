<#
.SYNOPSIS
Toggles the Elgato Prompter display and restarts Camera Hub after turning it off.

.DESCRIPTION
Camera Hub exposes the same local JSON-RPC websocket used by the Stream Deck
Camera Hub plugin. This script toggles the Prompter "enablePrompter" property
and then restarts Camera Hub when the new state is off, which works around the
Camera Hub hang that can follow powering the Prompter display down.
#>

[CmdletBinding()]
param(
    [ValidateSet('Off', 'Always', 'Never')]
    [string]$RestartWhen = 'Off',

    [int]$AfterToggleDelayMilliseconds = 1500,

    [int]$ResponseTimeoutMilliseconds = 2500,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$logPath = Join-Path $env:TEMP 'Toggle-PrompterDisplayAndRestartCameraHub.log'
$restartScript = Join-Path $PSScriptRoot 'restart_camera_hub.ps1'
$script:RpcId = 0

function Write-Log {
    param([string]$Message)

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $logPath -Value "[$timestamp] $Message"
}

function Receive-WebSocketText {
    param(
        [Parameter(Mandatory)]
        [Net.WebSockets.ClientWebSocket]$WebSocket,

        [Parameter(Mandatory)]
        [int]$TimeoutMilliseconds
    )

    $buffer = [byte[]]::new(65536)
    $stream = [IO.MemoryStream]::new()

    do {
        $cts = [Threading.CancellationTokenSource]::new()
        $cts.CancelAfter($TimeoutMilliseconds)

        try {
            $segment = [ArraySegment[byte]]::new($buffer)
            $result = $WebSocket.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult()
        } finally {
            $cts.Dispose()
        }

        if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
            throw 'Camera Hub websocket closed before returning a response.'
        }

        if ($result.Count -gt 0) {
            $stream.Write($buffer, 0, $result.Count)
        }
    } while (-not $result.EndOfMessage)

    [Text.Encoding]::UTF8.GetString($stream.ToArray())
}

function Invoke-CameraHubRpc {
    param(
        [Parameter(Mandatory)]
        [string]$Method,

        [hashtable]$Params
    )

    $script:RpcId++
    $id = $script:RpcId

    foreach ($port in 1834..1843) {
        $websocket = [Net.WebSockets.ClientWebSocket]::new()

        try {
            $connectTimeout = [Threading.CancellationTokenSource]::new()
            $connectTimeout.CancelAfter($ResponseTimeoutMilliseconds)
            $websocket.ConnectAsync([Uri]"ws://127.0.0.1:$port", $connectTimeout.Token).GetAwaiter().GetResult()

            $request = [ordered]@{
                jsonrpc = '2.0'
                method = $Method
                id = $id
            }

            if ($PSBoundParameters.ContainsKey('Params')) {
                $request['params'] = $Params
            }

            $json = $request | ConvertTo-Json -Compress -Depth 10
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            $websocket.SendAsync(
                [ArraySegment[byte]]::new($bytes),
                [Net.WebSockets.WebSocketMessageType]::Text,
                $true,
                [Threading.CancellationToken]::None
            ).GetAwaiter().GetResult()

            while ($true) {
                $text = Receive-WebSocketText -WebSocket $websocket -TimeoutMilliseconds $ResponseTimeoutMilliseconds
                $response = $text | ConvertFrom-Json

                $responses = if ($response -is [array]) { $response } else { @($response) }
                foreach ($item in $responses) {
                    if ($item.id -ne $id) {
                        continue
                    }

                    if ($item.PSObject.Properties.Name -contains 'error') {
                        throw "Camera Hub RPC '$Method' failed: $($item.error.message)"
                    }

                    return [pscustomobject]@{
                        Port = $port
                        Result = $item.result
                    }
                }
            }
        } catch {
            Write-Log "RPC '$Method' failed on port ${port}: $($_.Exception.Message)"
        } finally {
            if ($connectTimeout) {
                $connectTimeout.Dispose()
            }
            $websocket.Dispose()
        }
    }

    throw "Camera Hub did not respond to RPC '$Method' on ports 1834-1843."
}

function Restart-CameraHub {
    if (-not (Test-Path -LiteralPath $restartScript)) {
        throw "Restart script not found: $restartScript"
    }

    Write-Log "Restarting Camera Hub with $restartScript"
    & $restartScript *> $null
}

function Toggle-PrompterDisplay {
    $properties = (Invoke-CameraHubRpc -Method 'getSupportedPrompterProperties').Result
    $enablePrompter = $properties | Where-Object { $_.propertyID -eq 17 } | Select-Object -First 1

    if (-not $enablePrompter) {
        throw 'Camera Hub did not report the Prompter enable property.'
    }

    $currentValue = [int]$enablePrompter.value
    $newValue = if ($currentValue -eq 0) { 1 } else { 0 }

    Write-Log "Prompter display current=$currentValue new=$newValue dryRun=$DryRun"

    if ($DryRun) {
        return [pscustomobject]@{
            CurrentValue = $currentValue
            NewValue = $newValue
            RestartCameraHub = $false
        }
    }

    $result = (Invoke-CameraHubRpc -Method 'setPrompterProperty' -Params @{
        propertyID = 17
        value = $newValue
    }).Result

    if (($result.PSObject.Properties.Name -contains 'value') -and -not [bool]$result.value) {
        throw 'Camera Hub rejected the Prompter display toggle.'
    }

    $shouldRestart = ($RestartWhen -eq 'Always') -or (($RestartWhen -eq 'Off') -and ($newValue -eq 0))

    if ($shouldRestart) {
        Start-Sleep -Milliseconds $AfterToggleDelayMilliseconds
        Restart-CameraHub
    }

    [pscustomobject]@{
        CurrentValue = $currentValue
        NewValue = $newValue
        RestartCameraHub = $shouldRestart
    }
}

function Write-Result {
    param([Parameter(ValueFromPipeline)]$Result)

    process {
        $Result | Format-List | Out-String | ForEach-Object { Write-Log $_.Trim() }
    }
}

try {
    Toggle-PrompterDisplay | Write-Result
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"

    if ($DryRun) {
        throw
    }

    Write-Log 'Restarting Camera Hub and retrying the Prompter toggle once.'
    Restart-CameraHub
    Start-Sleep -Seconds 3
    Toggle-PrompterDisplay | Write-Result
}

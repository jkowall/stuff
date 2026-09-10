<#
.SYNOPSIS
Toggles the Elgato Prompter display and verifies the requested state.

.DESCRIPTION
Camera Hub exposes the same local JSON-RPC websocket used by the Stream Deck
Camera Hub plugin. Toggle is the default; use -Action On or -Action Off to
request a specific state. Retries preserve the original target, including when a command
succeeds but its response is lost. After a restart the script waits for Camera
Hub and reapplies the target if necessary. Verification checks Camera Hub's
reported state; it cannot confirm the physical panel is dark.

.EXAMPLE
.\Toggle-PrompterDisplayAndRestartCameraHub.ps1

.EXAMPLE
.\Toggle-PrompterDisplayAndRestartCameraHub.ps1 -Action On
#>

[CmdletBinding()]
param(
    [ValidateSet('Off', 'On', 'Toggle')]
    [string]$Action = 'Toggle',

    [ValidateSet('Off', 'Always', 'Never')]
    [string]$RestartWhen = 'Off',

    [ValidateRange(0, 60000)]
    [int]$AfterToggleDelayMilliseconds = 1500,

    [ValidateRange(100, 10000)]
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

    $deadline = [Diagnostics.Stopwatch]::StartNew()
    try {
        do {
            $remaining = $TimeoutMilliseconds - [int]$deadline.ElapsedMilliseconds
            if ($remaining -le 0) { throw 'Camera Hub response timed out.' }
            $cts = [Threading.CancellationTokenSource]::new()
            $cts.CancelAfter($remaining)

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
    } finally {
        $stream.Dispose()
    }
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
        $connectTimeout = $null
        $requestTimeout = $null

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
            $requestTimeout = [Threading.CancellationTokenSource]::new()
            $requestTimeout.CancelAfter($ResponseTimeoutMilliseconds)
            $deadline = [Diagnostics.Stopwatch]::StartNew()
            $websocket.SendAsync(
                [ArraySegment[byte]]::new($bytes),
                [Net.WebSockets.WebSocketMessageType]::Text,
                $true,
                $requestTimeout.Token
            ).GetAwaiter().GetResult()

            while ($true) {
                $remaining = $ResponseTimeoutMilliseconds - [int]$deadline.ElapsedMilliseconds
                if ($remaining -le 0) { throw 'Camera Hub RPC response timed out.' }
                $text = Receive-WebSocketText -WebSocket $websocket -TimeoutMilliseconds $remaining
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
            if ($requestTimeout) { $requestTimeout.Dispose() }
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

function Get-PrompterValue {
    $properties = (Invoke-CameraHubRpc -Method 'getSupportedPrompterProperties').Result
    $enablePrompter = $properties | Where-Object { $_.propertyID -eq 17 } | Select-Object -First 1

    if (-not $enablePrompter) {
        throw 'Camera Hub did not report the Prompter enable property.'
    }

    if ($null -eq $enablePrompter.value -or [string]$enablePrompter.value -notin @('0', '1')) {
        throw 'Camera Hub returned an invalid Prompter enable value.'
    }
    return [int]$enablePrompter.value
}

function Wait-PrompterReady {
    # Allow startup and USB discovery to finish instead of relying on a fixed sleep.
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    do {
        try { return Get-PrompterValue } catch {
            Write-Log "Waiting for Camera Hub: $($_.Exception.Message)"
        }
        Start-Sleep -Milliseconds 1000
    } while ($deadline.Elapsed.TotalSeconds -lt 45)
    throw 'Camera Hub/Prompter did not become ready after restarting.'
}

function Set-PrompterValue {
    param([int]$Value)

    $result = (Invoke-CameraHubRpc -Method 'setPrompterProperty' -Params @{
        propertyID = 17
        value = $Value
    }).Result

    if (($result.PSObject.Properties.Name -contains 'value') -and -not [bool]$result.value) {
        throw 'Camera Hub rejected the Prompter display command.'
    }
}

function Confirm-PrompterValue {
    param([int]$Value)

    for ($check = 0; $check -lt 5; $check++) {
        if ((Get-PrompterValue) -eq $Value) { return }
        Start-Sleep -Milliseconds 500
    }
    throw "Camera Hub did not retain the requested Prompter state ($Value)."
}

function Toggle-PrompterDisplay {
    # Resolve a toggle only once, before any writes or recovery.
    $target = switch ($Action) { 'Off' { 0 } 'On' { 1 } 'Toggle' { $null } }
    $restarted = $false
    $initialValue = $null
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $currentValue = Get-PrompterValue
            if ($null -eq $initialValue) { $initialValue = $currentValue }
            if ($null -eq $target) { $target = 1 - $currentValue }
            Write-Log "Prompter action=$Action current=$currentValue target=$target dryRun=$DryRun"

            if ($DryRun) {
                return [pscustomobject]@{
                    CurrentValue = $initialValue
                    NewValue = $target
                    RestartCameraHub = $false
                    Verified = $false
                }
            }

            # Send explicit Off/On even if the cached property already matches.
            Set-PrompterValue -Value $target
            Start-Sleep -Milliseconds $AfterToggleDelayMilliseconds
            $shouldRestart = ($RestartWhen -eq 'Always') -or (($RestartWhen -eq 'Off') -and ($target -eq 0))
            if ($shouldRestart -and -not $restarted) {
                Restart-CameraHub
                $restarted = $true
                $afterRestart = Wait-PrompterReady
                if ($afterRestart -ne $target) {
                    Set-PrompterValue -Value $target
                    Start-Sleep -Milliseconds $AfterToggleDelayMilliseconds
                }
            }
            Confirm-PrompterValue -Value $target

            return [pscustomobject]@{
                CurrentValue = $initialValue
                NewValue = $target
                RestartCameraHub = $restarted
                Verified = $true
            }
        } catch {
            Write-Log "Attempt $($attempt + 1) failed: $($_.Exception.Message)"
            if ($DryRun -or $attempt -eq 1) { throw }
            if ($RestartWhen -ne 'Never' -and -not $restarted) {
                Restart-CameraHub
                $restarted = $true
            }
            $null = Wait-PrompterReady
        }
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

    throw
}

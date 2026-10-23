<#
.SYNOPSIS
Restarts the Elgato Camera Hub application on Windows.

.DESCRIPTION
Closes Camera Hub gracefully (falling back to a forced stop), waits for every
Camera Hub process to exit, relaunches it hidden, and waits until its local
websocket port (1834-1843) accepts connections. Throws if Camera Hub does not
come back, so callers can rely on the exit status.

.NOTES
Run with Administrator privileges only if Camera Hub was started elevated.
#>

[CmdletBinding()]
param(
    [string]$ProcessName = 'Camera Hub',
    [string]$DefaultAppPath = 'C:\Program Files\Elgato\CameraHub\Camera Hub.exe',

    [ValidateRange(5, 120)]
    [int]$ReadyTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

function Test-CameraHubPort {
    foreach ($port in 1834..1843) {
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $connect = $client.ConnectAsync('127.0.0.1', $port)
            if ($connect.Wait(300) -and $client.Connected) { return $true }
        } catch {
            # Port closed; try the next one.
        } finally {
            $client.Dispose()
        }
    }
    return $false
}

Write-Host 'Attempting to restart Elgato Camera Hub...'

$processes = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
$appPath = $DefaultAppPath

if ($processes.Count -gt 0) {
    $runningPath = $processes | Where-Object { $_.Path } | Select-Object -ExpandProperty Path -First 1
    if ($runningPath) { $appPath = $runningPath }

    Write-Host "Closing Camera Hub (PID: $($processes.Id -join ', '))..."
    foreach ($process in $processes) {
        if ($process.MainWindowHandle -ne 0) { $null = $process.CloseMainWindow() }
    }
    $null = $processes | Wait-Process -Timeout 2 -ErrorAction SilentlyContinue

    $remaining = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($remaining.Count -gt 0) {
        Write-Host 'Graceful close did not finish; forcing stop.'
        $remaining | Stop-Process -Force -ErrorAction Stop
        $remaining | Wait-Process -Timeout 10 -ErrorAction Stop
    }
} else {
    Write-Host 'Elgato Camera Hub process not found.'
}

if (-not (Test-Path -LiteralPath $appPath)) {
    throw "Application path not found: '$appPath'"
}

Write-Host 'Starting Elgato Camera Hub...'
Start-Process -FilePath $appPath -WindowStyle Hidden -ErrorAction Stop

$deadline = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-CameraHubPort)) {
    if ($deadline.Elapsed.TotalSeconds -ge $ReadyTimeoutSeconds) {
        throw "Camera Hub did not open a websocket port within $ReadyTimeoutSeconds seconds."
    }
    Start-Sleep -Milliseconds 500
}

# Camera Hub ignores -WindowStyle Hidden and opens its window, so hide it once it appears.
Add-Type -Namespace CameraHub -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
$hideDeadline = [Diagnostics.Stopwatch]::StartNew()
$hidden = 0
while ($hideDeadline.Elapsed.TotalSeconds -lt 8) {
    foreach ($process in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        $process.Refresh()
        if ($process.MainWindowHandle -ne 0) {
            [void][CameraHub.Win32]::ShowWindow($process.MainWindowHandle, 0)
            $hidden++
        }
    }
    if ($hidden -gt 0) { break }
    Start-Sleep -Milliseconds 250
}

Write-Host 'Restart process completed.'

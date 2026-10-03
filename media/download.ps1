<#
.SYNOPSIS
    Download audio/video from YouTube or SoundCloud.

.EXAMPLE
    .\download.ps1 https://youtu.be/XXXX
    .\download.ps1 https://youtu.be/XXXX -Mode Mp3
    .\download.ps1 https://youtu.be/XXXX -MaxHeight 2160
    .\download.ps1 -RefreshCookies                  # re-export cookies from your browser
    .\download.ps1 -RefreshCookies -Browser chrome
#>
param (
    [Parameter(Position = 0)]
    [string]$url,

    [ValidateSet('Ask', 'Mp3', 'Video')]
    [string]$Mode = 'Ask',

    # Cap video resolution. 0 = no cap (can be multi-GB 4K).
    [int]$MaxHeight = 1080,

    # Browser to pull cookies from. Firefox is the most reliable on Windows;
    # Chrome/Edge 127+ encrypt cookies in a way yt-dlp often cannot read.
    [ValidateSet('firefox', 'chrome', 'edge', 'brave', 'chromium', 'opera', 'vivaldi')]
    [string]$Browser = 'firefox',

    [switch]$RefreshCookies
)

$ErrorActionPreference = 'Stop'

$music_dir   = "E:\vid\music"
$listen_dir  = "D:\listen"
$cookiesFile = Join-Path $PSScriptRoot "cookies.txt"
$cookieMaxAgeDays = 14

function Require-Tool([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "$name not found on PATH."
    }
}

function Update-Cookies {
    # Exports fresh YouTube cookies from the browser profile into cookies.txt.
    Write-Host "Exporting cookies from $Browser (close the browser first if this fails)..."
    $tmp = "$cookiesFile.new"
    Remove-Item $tmp -ErrorAction SilentlyContinue
    & yt-dlp.exe --cookies-from-browser $Browser --cookies $tmp --skip-download --no-warnings `
        --playlist-items 0 "https://www.youtube.com/" 2>&1 | Out-Null
    if ((Test-Path $tmp) -and ((Get-Item $tmp).Length -gt 200)) {
        Move-Item $tmp $cookiesFile -Force
        Write-Host "Cookies saved to $cookiesFile" -ForegroundColor Green
        return $true
    }
    Remove-Item $tmp -ErrorAction SilentlyContinue
    Write-Warning "Could not export cookies from $Browser. Make sure you are logged in to YouTube there, the browser is closed, and try -Browser firefox."
    return $false
}

function Test-CookiesStale {
    if (-not (Test-Path $cookiesFile)) { return $true }
    return ((Get-Date) - (Get-Item $cookiesFile).LastWriteTime).TotalDays -gt $cookieMaxAgeDays
}

# Resilience flags shared by every yt-dlp call
$common = @(
    '--retries', 'infinite',
    '--fragment-retries', 'infinite',
    '--socket-timeout', '30',
    '--no-mtime'
)

function Invoke-YtDlp([string[]]$ytArgs) {
    $cookieArgs = @()
    if (Test-Path $cookiesFile) { $cookieArgs = @('--cookies', $cookiesFile) }
    & yt-dlp.exe @cookieArgs @common @ytArgs
    return $LASTEXITCODE
}

# ---- Cookie refresh only ----
if ($RefreshCookies) {
    Require-Tool yt-dlp.exe
    if (Update-Cookies) { exit 0 } else { exit 1 }
}

if (-not $url) {
    Write-Host "Usage: .\download.ps1 <url> [-Mode Mp3|Video] [-MaxHeight 1080] | -RefreshCookies"
    exit 1
}

# ---- SoundCloud ----
if ($url -like "*soundcloud.com*") {
    Write-Host "SoundCloud URL detected."
    Require-Tool scdl.exe
    scdl.exe -l $url --onlymp3 --path $listen_dir
    exit $LASTEXITCODE
}

# ---- YouTube ----
if ($url -notlike "*youtube.com*" -and $url -notlike "*youtu.be*") {
    Write-Host "Could not determine platform from URL."
    exit 1
}

Write-Host "YouTube URL detected."
Require-Tool yt-dlp.exe
Require-Tool ffmpeg.exe

if ($Mode -eq 'Ask') {
    Write-Host "Select the download type:"
    Write-Host "1. MP3 (audio only)"
    Write-Host "2. Video (default)"
    $choice = Read-Host "Enter your choice (1 or 2, default is 2)"
    $Mode = if ($choice -eq "1") { 'Mp3' } else { 'Video' }
}

if (Test-CookiesStale) {
    Write-Host "cookies.txt is missing or older than $cookieMaxAgeDays days, refreshing..."
    [void](Update-Cookies)
}

if ($Mode -eq 'Mp3') {
    $ytArgs = @(
        '--extract-audio', '--audio-format', 'mp3',
        '--format', 'bestaudio/best',
        '-o', "$listen_dir\%(title)s.%(ext)s", $url
    )
} else {
    $cap = if ($MaxHeight -gt 0) { "[height<=$MaxHeight]" } else { "" }
    $fmt = "bestvideo$cap[ext=mp4]+bestaudio[ext=m4a]/best$cap[ext=mp4]/best$cap"
    $ytArgs = @('--format', $fmt, '-o', "$music_dir\%(title)s.%(ext)s", $url)
}

$code = Invoke-YtDlp $ytArgs

# One automatic retry with fresh cookies and a fresh yt-dlp if the first attempt failed
if ($code -ne 0) {
    Write-Warning "yt-dlp failed (exit $code). Updating yt-dlp and refreshing cookies, then retrying once."
    & yt-dlp.exe -U 2>&1 | Out-Host
    [void](Update-Cookies)
    $code = Invoke-YtDlp $ytArgs
}

if ($code -ne 0) { Write-Error "Download failed (exit $code)." }
exit $code

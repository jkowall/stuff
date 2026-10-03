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

    [switch]$RefreshCookies,

    # Overwrite an existing file without asking
    [switch]$Force,

    # Scan download folders for leftover fragments/partials and offer to delete them
    [switch]$Cleanup
)

# yt-dlp emits UTF-8; without this, titles with characters like the full-width bar get mangled
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = 'Continue'

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
    # Out-Host keeps yt-dlp output on screen instead of leaking into the return value
    & yt-dlp.exe @cookieArgs @common @ytArgs | Out-Host
    return [int]$LASTEXITCODE
}

# ---- Cookie refresh only ----
if ($RefreshCookies) {
    Require-Tool yt-dlp.exe
    if (Update-Cookies) { exit 0 } else { exit 1 }
}

# ---- Leftover scan: -Cleanup ----
function Get-Leftovers([string]$dir) {
    if (-not (Test-Path $dir)) { return }
    $files = Get-ChildItem -LiteralPath $dir -File -Force
    foreach ($f in $files) {
        if ($f.Name -match '\.(part|ytdl|temp)$' -or $f.Name -match '\.part-Frag\d+$') {
            [pscustomobject]@{ File = $f; Kind = 'partial'; Safe = $false }
        } elseif ($f.Name -match '^(?<base>.+)\.f\d+\.\w+$') {
            $base = $Matches['base']
            $hasFinal = $files | Where-Object {
                $_.Name -ne $f.Name -and $_.Name.StartsWith("$base.") -and $_.Name -notmatch '\.f\d+\.\w+$' -and $_.Name -notmatch '\.(part|ytdl|temp)$'
            }
            [pscustomobject]@{ File = $f; Kind = 'fragment'; Safe = [bool]$hasFinal }
        }
    }
}

if ($Cleanup) {
    $items = @($music_dir, $listen_dir | ForEach-Object { Get-Leftovers $_ })
    if (-not $items) { Write-Host "No leftovers found."; exit 0 }
    $items | ForEach-Object {
        $tag = if ($_.Safe) { 'DELETE (merged copy exists)' } elseif ($_.Kind -eq 'partial') { 'DELETE (incomplete download)' } else { 'KEEP   (no merged copy, may be your only file)' }
        Write-Host ("{0,-46} {1,9:N1} MB  {2}" -f $tag, ($_.File.Length / 1MB), $_.File.FullName)
    }
    $del = @($items | Where-Object { $_.Safe -or $_.Kind -eq 'partial' })
    if ($del) {
        $total = ($del | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum / 1MB
        $ans = Read-Host ("Delete {0} file(s), {1:N0} MB? (y/N)" -f $del.Count, $total)
        if ($ans -match '^(y|yes)$') { $del | ForEach-Object { Remove-Item -LiteralPath $_.File.FullName -Force }; Write-Host "Deleted." }
    }
    exit 0
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

# ---- Existing file check: compare and ask before overwriting ----
$cookieArgs = @(); if (Test-Path $cookiesFile) { $cookieArgs = @('--cookies', $cookiesFile) }
$info = & yt-dlp.exe @cookieArgs --no-warnings --print '%(filename)s|%(filesize_approx)s|%(duration)s' @ytArgs 2>$null |
    Select-Object -Last 1
if ($info) {
    $parts = $info -split '\|'
    $target = $parts[0]
    if ($Mode -eq 'Mp3') { $target = [IO.Path]::ChangeExtension($target, 'mp3') }
    if (Test-Path -LiteralPath $target) {
        $existing = Get-Item -LiteralPath $target
        $remoteSize = 0L; [void][long]::TryParse($parts[1], [ref]$remoteSize)
        Write-Host ""
        Write-Host "Already exists: $target" -ForegroundColor Yellow
        Write-Host ("  Local : {0:N1} MB, modified {1}" -f ($existing.Length / 1MB), $existing.LastWriteTime)
        if ($Mode -eq 'Video' -and $remoteSize -gt 0) {
            $pct = [math]::Round(100 * $existing.Length / $remoteSize)
            Write-Host ("  Remote: ~{0:N1} MB estimated (local is {1}% of that)" -f ($remoteSize / 1MB), $pct)
        }
        if ($parts[2] -and $parts[2] -ne 'NA') {
            Write-Host ("  Remote duration: {0}" -f [TimeSpan]::FromSeconds([double]$parts[2]).ToString())
        }
        if ($Force) {
            Write-Host "-Force given, overwriting."
        } else {
            $ans = Read-Host "Overwrite? (y/N)"
            if ($ans -notmatch '^(y|yes)$') { Write-Host "Skipped."; exit 0 }
        }
        $ytArgs = @('--force-overwrites') + $ytArgs
    }
}

$code = Invoke-YtDlp $ytArgs

# One automatic retry with fresh cookies and a fresh yt-dlp if the first attempt failed
if ($code -ne 0) {
    Write-Warning "yt-dlp failed (exit $code). Updating yt-dlp and refreshing cookies, then retrying once."
    & yt-dlp.exe -U 2>&1 | Out-Host
    [void](Update-Cookies)
    $code = Invoke-YtDlp $ytArgs
}

# Remove this title's leftover fragments/partials once the final file is in place
if ($code -eq 0 -and $target -and (Test-Path -LiteralPath $target)) {
    $dir = Split-Path $target
    $base = [IO.Path]::GetFileNameWithoutExtension($target)
    Get-ChildItem -LiteralPath $dir -File -Force | Where-Object {
        $_.Name.StartsWith("$base.") -and ($_.Name -match '\.f\d+\.\w+$' -or $_.Name -match '\.(part|ytdl|temp)$')
    } | ForEach-Object { Write-Host "Cleaning up $($_.Name)"; Remove-Item -LiteralPath $_.FullName -Force }
}

if ($code -ne 0) { Write-Error "Download failed (exit $code)." }
exit $code

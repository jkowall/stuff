<#
.SYNOPSIS
    Prepares videos and photos in a directory for Instagram using FFmpeg.

.DESCRIPTION
    Scans a directory (non-recursive) for .mp4 videos and .png/.jpg/.jpeg photos
    and writes Instagram-ready versions into an "instagram" subfolder.

    Videos: re-encoded to 1080x1350 (4:5) with padding, 30fps, libx264/aac,
    matching the existing reels convention.

    Photos: resized so the long edge is at most -PhotoLongEdge pixels,
    ORIGINAL ASPECT RATIO PRESERVED (no crop, no letterbox bars), exported
    as high-quality JPEG. This is deliberately different from the video
    padding approach — forcing stills to a fixed 4:5 canvas adds ugly bars
    to landscape/square shots, and Instagram's feed supports a wide range
    of aspect ratios natively.

.PARAMETER Directory
    Directory containing the source files. Prompted for if omitted.

.PARAMETER PhotoLongEdge
    Max pixel length of the photo's long edge. Default 1600.

.PARAMETER PhotoQuality
    FFmpeg mjpeg -q:v value, 2 (best) to 31 (worst). Default 2.

.PARAMETER FFmpegPath
    Path to ffmpeg.exe if not on PATH. Default "ffmpeg".

.EXAMPLE
    .\instagram.ps1 -Directory "E:\Pictures\2026\09\PNG"
#>

param (
    [string]$Directory,
    [int]$PhotoLongEdge = 1600,
    [int]$PhotoQuality = 2,
    [string]$FFmpegPath = "ffmpeg"
)

if (-not $Directory) {
    $Directory = Read-Host "Enter the directory containing files to process"
}

if (-Not (Test-Path $Directory)) {
    Write-Error "The directory does not exist: $Directory"
    exit 1
}

$instagramDir = Join-Path $Directory "instagram"
if (-Not (Test-Path $instagramDir)) {
    New-Item -ItemType Directory -Path $instagramDir | Out-Null
}

# ---- Videos ----
$videoFiles = Get-ChildItem -Path $Directory -Filter *.mp4 -File
Write-Host "Found $($videoFiles.Count) video(s)."

foreach ($file in $videoFiles) {
    $inputFile = $file.FullName
    $outputFile = Join-Path $instagramDir ($file.BaseName + ".ig.mp4")

    Write-Host "Processing video: $($file.Name)" -ForegroundColor Yellow

    & $FFmpegPath -y -i $inputFile `
        -vf "fps=30,scale=1080:1350:force_original_aspect_ratio=decrease,pad=1080:1350:(ow-iw)/2:(oh-ih)/2:color=black,format=yuv420p" `
        -c:v libx264 -preset slow -crf 18 -b:v 3500k -maxrate 5000k -bufsize 5000k `
        -c:a aac -b:a 192k -ar 44100 -movflags +faststart `
        $outputFile

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  -> $outputFile" -ForegroundColor Green
    } else {
        Write-Warning "  FFmpeg failed on $($file.Name) (exit $LASTEXITCODE)"
    }
}

# ---- Photos ----
$photoFiles = Get-ChildItem -Path (Join-Path $Directory "*") -Include *.png, *.jpg, *.jpeg -File
Write-Host "Found $($photoFiles.Count) photo(s)."

foreach ($file in $photoFiles) {
    $inputFile = $file.FullName
    $outputFile = Join-Path $instagramDir ($file.BaseName + ".jpg")

    Write-Host "Processing photo: $($file.Name)" -ForegroundColor Yellow

    & $FFmpegPath -y -i $inputFile `
        -vf "scale=w=${PhotoLongEdge}:h=${PhotoLongEdge}:force_original_aspect_ratio=decrease:force_divisible_by=2" `
        -q:v $PhotoQuality -pix_fmt yuvj420p -frames:v 1 -update 1 `
        $outputFile

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  -> $outputFile" -ForegroundColor Green
    } else {
        Write-Warning "  FFmpeg failed on $($file.Name) (exit $LASTEXITCODE)"
    }
}

Write-Host "--------------------------------------------------"
Write-Host "Done. Instagram-ready files are in: $instagramDir" -ForegroundColor Cyan

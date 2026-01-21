<#
.SYNOPSIS
    Batch converts MP4 files in the current directory and subdirectories for Instagram using FFmpeg.

.DESCRIPTION
    This script recursively finds all .mp4 files in the directory it is run from and its subdirectories.
    For each file, it uses FFmpeg to convert it to a format suitable for Instagram,
    applying specific settings for resolution (default 1080x1350 portrait with padding),
    bitrate, frame rate, and codecs.
    Original files are renamed with .orig.mp4 extension and Instagram-ready files use .ig.mp4 extension.

.NOTES
    Author: Updated version
    Version: 2.0
    Requires: FFmpeg (ffmpeg.exe) to be installed and accessible.
              You can download FFmpeg from https://ffmpeg.org/download.html

    Before running:
    1. Ensure FFmpeg is installed.
    2. If ffmpeg.exe is not in your system PATH, update the $ffmpegPath variable below.
    3. Place this script in the directory containing the .mp4 files you want to convert.
    4. Run the script from PowerShell in that directory.

.PARAMETER FFmpegPath
    Specifies the full path to ffmpeg.exe if it's not in your system's PATH.
    Default: "ffmpeg" (assumes it's in PATH).

.EXAMPLE
    .\Convert.ps1
    (Assumes ffmpeg is in PATH)

.EXAMPLE
    .\Convert.ps1 -FFmpegPath "C:\ffmpeg\bin\ffmpeg.exe"
    (Specifies a custom path to ffmpeg.exe)
#>

param (
    [string]$FFmpegPath = "ffmpeg"
)

# Get the current script directory
$ScriptDirectory = Get-Location

# Get all .mp4 files in the current directory and all subdirectories
# Skip files that already have .orig.mp4 or .ig.mp4 extensions
Write-Host "Searching for .mp4 files in $ScriptDirectory and subdirectories..."
$videoFiles = Get-ChildItem -Path $ScriptDirectory -Filter "*.mp4" -File -Recurse | 
    Where-Object { $_.Name -notmatch '\.orig\.mp4$' -and $_.Name -notmatch '\.ig\.mp4$' }

if ($videoFiles.Count -eq 0) {
    Write-Host "No .mp4 files found to process in $ScriptDirectory and subdirectories."
    exit 0
}

Write-Host "Found $($videoFiles.Count) .mp4 file(s) to process."

foreach ($file in $videoFiles) {
    $inputFilePath = $file.FullName
    $directory = $file.DirectoryName
    $baseName = $file.BaseName
    
    # New naming convention: change extension to .ig.mp4 instead of appending _instagram
    $outputFileName = "$baseName.ig.mp4"
    $outputFilePath = Join-Path -Path $directory -ChildPath $outputFileName
    
    # New naming convention for original: change extension to .orig.mp4
    $originalFileName = "$baseName.orig.mp4"
    $originalFilePath = Join-Path -Path $directory -ChildPath $originalFileName

    Write-Host "--------------------------------------------------"
    Write-Host "Processing: $($file.Name)" -ForegroundColor Yellow
    Write-Host "In directory: $directory"

    # FFmpeg video filter and arguments remain the same
    $ffmpegVideoFilter = 'fps=30,scale=1080:1350:force_original_aspect_ratio=decrease,pad=1080:1350:(ow-iw)/2:(oh-ih)/2:color=black'

    # FFmpeg arguments
    $ffmpegArgs = @(
        "-y",
        "-i", "`"$inputFilePath`"",
        "-c:v", "libx264",
        "-b:v", "3500k",
        "-maxrate", "5000k",
        "-bufsize", "5000k",
        "-vf", $ffmpegVideoFilter,
        "-c:a", "aac",
        "-b:a", "128k",
        "-ar", "44100",
        "-movflags", "+faststart",
        "`"$outputFilePath`""
    )

    Write-Host "Outputting to: $outputFilePath"
    Write-Host "FFmpeg command: $FFmpegPath $($ffmpegArgs -join ' ')"

    try {
        # Start FFmpeg process
        $process = Start-Process -FilePath $FFmpegPath -ArgumentList $ffmpegArgs -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue

        if ($process.ExitCode -eq 0) {
            Write-Host "Successfully converted $($file.Name)" -ForegroundColor Green
            
            # Rename the original file instead of moving it
            try {
                Rename-Item -Path $inputFilePath -NewName $originalFileName -Force
                Write-Host "Renamed original file to $originalFileName" -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to rename original file to $originalFileName. Error: $($_.Exception.Message)"
            }
        } else {
            Write-Warning "FFmpeg failed to convert $($file.Name). Exit Code: $($process.ExitCode)"
            Write-Warning "Check FFmpeg output for errors if it was visible, or run the command manually for more details."
        }
    }
    catch {
        Write-Error "An error occurred while trying to run FFmpeg for $($file.Name). Error: $($_.Exception.Message)"
        Write-Error "Ensure FFmpeg path is correct and FFmpeg is working."
    }
}

Write-Host "--------------------------------------------------"
Write-Host "Batch processing finished." -ForegroundColor Cyan

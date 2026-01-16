# Prompt user for directory
$directory = Read-Host "Enter the directory containing .mp4 files"

# Check if the directory exists
if (-Not (Test-Path $directory)) {
    Write-Host "The directory does not exist. Please try again."
    exit
}

# Create the 'instagram' subdirectory if it doesn't exist
$instagramDir = Join-Path $directory "instagram"
if (-Not (Test-Path $instagramDir)) {
    New-Item -ItemType Directory -Path $instagramDir
}

# Process all .mp4 files in the directory
Get-ChildItem -Path $directory -Filter *.mp4 | ForEach-Object {
    $inputFile = $_.FullName
    $outputFile = Join-Path $instagramDir ("instagram_" + $_.Name)
    
    # Re-encode the video using ffmpeg
    ffmpeg -i $inputFile -vf "scale=1080:1350:force_original_aspect_ratio=decrease,pad=1080:1350:(ow-iw)/2:(oh-ih)/2,format=yuv420p" -c:v libx264 -preset slow -crf 18 -c:a aac -b:a 192k -movflags +faststart $outputFile
    
    Write-Host "Processed: $($_.Name)"
}

Write-Host "All videos have been processed and saved in the 'instagram' subdirectory."

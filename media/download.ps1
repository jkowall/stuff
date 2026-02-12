param (
    [Parameter(Mandatory=$true)]
    [string]$url
)

$music_dir = "E:\vid\music"
$listen_dir = "D:\listen"

if ($url -like "*soundcloud.com*") {
    # SoundCloud Option
    Write-Host "SoundCloud URL detected."
    $output_dir = $listen_dir

    # SoundCloud download command
    scdl.exe -l $url --onlymp3 --path $output_dir
}
elseif ($url -like "*youtube.com*" -or $url -like "*youtu.be*") {
    # YouTube Option
    Write-Host "YouTube URL detected."

    # Prompt the user for download type with a default option
    Write-Host "Select the download type:"
    Write-Host "1. MP3 (audio only)"
    Write-Host "2. Video (default)"
    $downloadTypeChoice = Read-Host "Enter your choice (1 or 2, default is 2)"

    if ($downloadTypeChoice -eq "1") {
        $download_dir = $listen_dir
        $download_format = "bestaudio/best"
        $output_format = "$download_dir\%(title)s.%(ext)s"
        yt-dlp.exe --cookies=cookies.txt --extract-audio --audio-format mp3 --format $download_format -o $output_format $url
    } else {
        # Default to video if no valid input is provided
        $download_dir = $music_dir
        $download_format = "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"
        $output_format = "$download_dir\%(title)s.%(ext)s"
        yt-dlp.exe --cookies=cookies.txt --format $download_format -o $output_format $url
    }
}
else {
    Write-Host "Could not determine platform from URL."
}


param (
    [Parameter(Mandatory=$true)]
    [string]
    $Directory,

    [string]
    $OutputDirectory = (Join-Path -Path $Directory -ChildPath "Output"),

    [string]
    $MediaInfo = "C:\Tools\Applications\MediaInfoCLI\MediaInfo.exe"
)

if(-not (Test-Path -Path $OutputDirectory)){

    New-Item -ItemType Directory -Force -Path $OutputDirectory

}

$MediaFiles = Get-ChildItem -Path $Directory | Where-Object { $_.Extension -eq ".mkv"}

$MediaFiles | ForEach-Object {

    $OutputFile = (Join-Path -Path $OutputDirectory -ChildPath ($_.Name))

    Write-Output $OutputFile
    ffmpeg -i $_.FullName -map 0 -c:v copy -c:a aac -channel_layout 5.1 outputfile.mkv


}


$MediaFiles[0] | ForEach-Object {

    $AudioInfo = & $MediaInfo --Output=JSON $_.FullName | ConvertFrom-Json

    $NonStandardChannels = $AudioInfo.media.track | Where-Object {

        $_."@type" -eq "Audio" -and
        $_.Channels -eq 6

    }

}
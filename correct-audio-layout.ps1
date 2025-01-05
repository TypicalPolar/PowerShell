param (
    [Parameter(Mandatory=$true)]
    [string]
    $Directory,

    [string]
    $OutputDirectory = (Join-Path -Path $Directory -ChildPath "Output"),

    [string]
    $MediaInfo = "C:\Tools\Applications\MediaInfoCLI\MediaInfo.exe"
)

$StandardLayout = "L R C LFE Ls Rs"

function Find-IrregularAudioLayouts {
    param (
        [string]$FilePath
    )

    $AudioInfo = & $MediaInfo --Output=JSON $FilePath | ConvertFrom-Json

    $NonStandardChannels = $AudioInfo.media.track | Where-Object {

        $_."@type" -eq "Audio" -and
        $_.Channels -eq 6 -and
        $_.ChannelLayout -ne $StandardLayout

    }

    Return $NonStandardChannels
    
}

function Set-StandardAudioLayout {
    param (
        $FileData,
        [array]$IrregularAudioNumber
    )
    
    $OutputFile = (Join-Path -Path $OutputDirectory -ChildPath ($FileData.Name))

    $Command = "ffmpeg -i `"$($_.FullName)`" -map 0 -c:v copy -c:a copy"

    $IrregularAudioNumber | ForEach-Object {

        $AudioNumber = $_-1 # Index starts at 0

        $Command += " -c:a:$AudioNumber aac -channel_layout:a:$AudioNumber 5.1"
    }

    $Command += " `"$OutputFile`""

    Invoke-Expression $Command

}


if(-not (Test-Path -Path $OutputDirectory)){

    New-Item -ItemType Directory -Force -Path $OutputDirectory

}

$MediaFiles = Get-ChildItem -Path $Directory | Where-Object { $_.Extension -eq ".mkv"}

$MediaFiles | ForEach-Object {

    $NonStandardTracks = Find-IrregularAudioLayouts -FilePath $_.FullName

    Write-Host "Processing $($_.BaseName)"

    if($NonStandardTracks){

        $Count = ($NonStandardTracks | Measure-Object).Count
        Write-Host "$Count track(s) located with irregular audio layouts."

        Set-StandardAudioLayout `
        -FileData $_ `
        -IrregularAudioNumber $NonStandardTracks."@typeorder"

    }

    Write-Host "`n"

}
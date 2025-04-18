param (
    [Parameter(Mandatory=$true)]
    [string]
    $Source,
    [string]
    $MediaInfo = "C:\Tools\Applications\MediaInfoCLI\MediaInfo.exe"    
)

# For Testing
$Source = ""

$Queue = Get-ChildItem -Path $Source

function Get-AudioInfo {
    param (
        $File
    )

    $FileInfo = (& $MediaInfo --Output=JSON $File | ConvertFrom-Json).media.track

    return $FileInfo |
    Where-Object {
        $_."@type" -eq "Audio"
    } |
    Select-Object @{
        Name = "AudioIndex"
        Expression = { $_.'@typeorder' - 1 }
    }, Format, Channels, ChannelPositions, ChannelLayout

}

function Format-TrackCommand {
    param (
        [System.Object]
        $Track
    )

    if($Track.Channels -in @(1,2,3,6,7,8)){
        $Channels = $Track.Channels
    }else{
        # Stereo is fallback
        $Channels = 2
    }

    $Settings = switch ($Channels) {
        "1" {
            @{
                "ac" = 1
                "layout" = "1.0"
                "bitrate" = "128k"
            }
            break
        }
        "2" {
            @{
                "ac" = 2
                "layout" = "2.0"
                "bitrate" = "320k"
            }
            break
        }
        "3" {
            @{
                "ac" = 3
                "layout" = "2.1"
                "bitrate" = "320k"
            }
            break
        }
        "6" {
            @{
                "ac" = 6
                "layout" = "5.1"
                "bitrate" = "640k"
            }
            break
        }
        "7" {
            @{
                "ac" = 6
                "layout" = "5.1"
                "bitrate" = "640k"
            }
            break
        }
        "8" {
            @{
                "ac" = 8
                "layout" = "7.1"
                "bitrate" = "896k"
            }
            break
        }
    }

    return " -c:a:$($Track.AudioIndex) aac -b:a:$($Track.AudioIndex) $($Settings.bitrate) -filter:a:$($Track.AudioIndex) `"aresample=48000,channelmap=channel_layout=$($Settings.layout)`"" 
        
}

# For Testing
$File = $Queue[0].FullName
$TestAudioInfo = Get-AudioInfo -File $File
Format-TrackCommand -Track $TestAudioInfo[1]

$FilePath = "c:\somefile\file.mkv"
$OutputPath = "c:\somefile\file-converted.mkv"
$Command = $null
$Command = "ffmpeg -i `"$FilePath`" -map 0 -c:v copy"

Get-AudioInfo -File $File | ForEach-Object {
    $Command += Format-TrackCommand -Track $_
}

$Command += " `"$OutputPath`""
param (
    [Parameter(Mandatory=$true)]
    [string]
    $Source,
    [string]
    $Destination = (
        Join-Path `
        -Path (Get-ChildItem -Path $Source | 
        Where-Object {$_.DirectoryName} | 
        Select-Object -ExpandProperty DirectoryName -First 1) `
        -ChildPath "\Converted"
    ),
    [string]
    $MediaInfo = "C:\Tools\Applications\MediaInfoCLI\MediaInfo.exe"    
)

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
                "layout" = "mono"
                "bitrate" = "128k"
            }
            break
        }
        "2" {
            @{
                "ac" = 2
                "layout" = "stereo"
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

New-Item -ItemType Directory -Path $Destination -Force | Out-Null

$Queue | Sort-Object Name | ForEach-Object {
    $SourceFile = $_.FullName
    $DestinationFile = Join-Path -Path $Destination -ChildPath $_.Name

    $Command = $null
    $Command = "ffmpeg -loglevel fatal -i `"$SourceFile`" -map 0 -c:v copy"    
    Get-AudioInfo -File $SourceFile | ForEach-Object {
        $Command += Format-TrackCommand -Track $_
    }
    $Command += " `"$DestinationFile`""

    Write-Host "Started Encoding: $($_.Name)"
    Invoke-Expression $Command
    Write-Host "Encode has completed!`n"
}

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

# For Testing
$File = $Queue[0].FullName
Get-AudioInfo -File $File

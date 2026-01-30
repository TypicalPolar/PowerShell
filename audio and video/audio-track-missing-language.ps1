function Get-AudioTracks {

    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    if( !(Test-Path -LiteralPath $Path) ){
        throw "Path is invalid or inaccessible"
    }

    return (
        (MediaInfo --Output=JSON $path | ConvertFrom-Json).media.track |
        Where-Object { $_."@type" -eq "Audio" }
    )

}

$Directory = ""

Get-ChildItem -LiteralPath $Directory |
Where-Object { $_.Extension -like "*mkv*"} |
Select-Object -ExpandProperty FullName |
ForEach-Object {
    Get-AudioTracks -Path $_ |
    Where-Object { -not $_.Language }
}

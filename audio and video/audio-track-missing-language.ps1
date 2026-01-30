function Get-AudioTracks {

    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    if( !(Test-Path -LiteralPath $Path) ){
        throw "Path is invalid or inaccessible"
    }

    (mkvmerge -J $Path | ConvertFrom-Json).tracks |
    Where-Object {
        $_.type -eq "audio"
    }

}

function Set-MkvTrackLanguage {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [int]$TrackId,
        [ValidatePattern('^[a-z]{3}$')]
        [string]$Language = "eng",
        [switch]$WhatIf
    )

    $args = @(
        $Path,
        "--edit", "track:@$TrackId",
        "--set", "language=$Language",
        "--verbose"
    )

    if ($WhatIf) {
        "WHATIF: mkvpropedit $($args -join ' ')"
        return
    }

    mkvpropedit @args
    if ($LASTEXITCODE -ne 0) {
        throw "mkvpropedit failed: $Path track:$TrackId"
    }
}


$Directory = "M:\Series\Is It Wrong to Try to Pick Up Girls in a Dungeon\S02\test"

Get-ChildItem -LiteralPath $Directory |
Where-Object { $_.Extension -like "*mkv*"} |
Select-Object -ExpandProperty FullName |
ForEach-Object {

    $File = $_

    Get-AudioTracks -Path $_ |
    Where-Object {  $_.properties.language -eq "und" -or -not $_.properties.language } |
    ForEach-Object {
            Set-MkvTrackLanguage -Path $File -TrackId $_.properties.number
    }

}
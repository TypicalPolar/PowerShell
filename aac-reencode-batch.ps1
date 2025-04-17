param (
    [Parameter(Mandatory=$true)]
    [string]
    $FolderPath,

    [array]
    $CodecFilter,

    [string]
    $ResultSuffix = "-Converted"
)


# Normalizing path so it always includes a backslash
if (-not $folderPath.EndsWith("\")) {
    $folderPath += "\"
}

$MediaFiles = Get-ChildItem -Path $FolderPath |
    Select-Object Name,BaseName,FullName,Extension |
    Where-Object { $_.Extension -eq ".mkv"}

$MediaFiles | ForEach-Object {

    $AudioStreams = @()

    Write-Output "`n`nProcessing: $($_.BaseName)"

    $ffprobeOutput = ffprobe -v error -select_streams a -show_entries stream=index,codec_name,index:stream_tags=language -of csv=p=0 $_.FullName

    $AudioStreams = $(

        $IndexNumber = 0

        $ffprobeOutput | ForEach-Object {
            $fields = $_ -split ','

            [PSCustomObject]@{
                GlobalIndex = $fields[0]
                AudioIndex = $IndexNumber
                CodecName = $fields[1]
                Language = $fields[2]
            }

            $IndexNumber++

        }
    )
    
    $OutputFile = "$folderPath$($_.BaseName)$ResultSuffix$($_.Extension)"

    if ($CodecFilter){
        
        $Command = "ffmpeg -i `"$($_.FullName)`" -map 0 -c:v copy -c:s copy"

        $FilteredStreams = $AudioStreams |
            Where-Object {$_.CodecName -in $CodecFilter}

        Write-Output "Streams to Convert: $($FilteredStreams.Count)"

        $FilteredStreams |
            ForEach-Object {

                $Command += " -c:a:$($_.AudioIndex) aac -b:a:$($_.AudioIndex) 640k -ar 48000"
                
            }

        $Command += " `"$OutputFile`""

        Invoke-Expression $Command

    }else{

        Write-Output "Converting all audio streams"

        $Command = "ffmpeg -i `"$($_.FullName)`" -map 0 -c:v copy -c:a aac -b:a 640k -ar 48000 -c:s copy `"$OutputFile`""

        Invoke-Expression $Command

    }

}
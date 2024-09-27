param (
    [array]$Urls
)

# General Settings
$StorageFolder = ($env:USERPROFILE + "\Downloads\RipMe")
$JarFile = ($StorageFolder + "\ripme.jar")
$Threads = 5
$CooldownTimer = 300 # Specified in Seconds
$JobWaitInternal = 10 # Specified in Seconds
$JobMaxNoProgressCheck = 12

# Creating Folder If Missing
if (!(Test-Path -PathType Container $StorageFolder)) {

    Write-Host "Creating directory: $StorageFolder"
    New-Item -ItemType Directory -Path $StorageFolder

}

# RipMe Function
function Start-RipMe {
    param(
        $Url
    )

    # Resetting job counters
    $NoProgressCount = '0'
    $JobLastOutput = ""

    $DownloadJob = Start-Job -ScriptBlock {
        param(
            $JarFile,
            $StorageFolder,
            $Url,
            $Threads
        )

        @("$JarFile","$StorageFolder","$Url","$Threads") | ForEach-Object {
            Write-Host "Variable Result: $_"
        }

        java -jar $JarFile --ripsdirectory $StorageFolder --url $Url --threads $Threads --skip404

    } -ArgumentList $JarFile, $StorageFolder, $Url, $Threads

    # Monitoring the job
    while ($DownloadJob.State -eq 'Running'){

        $JobCurrentOutput = Receive-Job -Job $DownloadJob -Keep

        if ($JobCurrentOutput -ne $JobLastOutput){

            # Refreshing progress counter
            $NoProgressCount = '0'
            $JobLastOutput = $JobCurrentOutput

        }else{

            # Increasing progress counter due to lack of progress
            Write-Host "No progress has been made in $NoProgressCount checks."
            $NoProgressCount++

        }

        if($NoProgressCount -ge $JobMaxNoProgressCheck){

            Write-Host "Progress has ceased, terminating job"
            Stop-Job -Job $DownloadJob

        }

        Start-Sleep -Seconds $JobWaitInternal

    }

    # Providing result
    if ($DownloadJob.State -eq 'Completed') {

        $result = Receive-Job -Job $DownloadJob
        Write-Host "Function completed successfully:"

    } elseif ($DownloadJob.State -eq 'Stopped') {

        Write-Host "Function was terminated due to lack of progress."

    } else {

        Write-Host "Job is in state: $($DownloadJob.State)"

    }

    # Cleanup the job
    Remove-Job -Job $DownloadJob
    
}

# Cooldown Settings
$BatchCounter = 0
$BatchLastItem = $Urls.Count

$Urls | ForEach-Object {
    
    Start-RipMe -Url $_

    # Cooldown
    if($BatchCounter -lt $BatchLastItem){

        Write-Host "Beginning cooldown... Please wait."
        Start-Sleep -Seconds $CooldownTimer

    }else{
        Write-Host "Last item, skipping cooldown"
    }

    $BatchCounter++
    
}


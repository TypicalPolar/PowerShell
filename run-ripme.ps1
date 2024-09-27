param (
    [array]$Urls
)

#
# Settings
#

# File and Storage Settings
$StorageFolder = ($env:USERPROFILE + "\Downloads\RipMe")
$JarFile = ($StorageFolder + "\ripme.jar")

# Performance Settings
$Threads = 5

# Timeout Settings
$CooldownTimer = 300 # Specified in Seconds
$MaxJobTime = 10 # In Minutes

# Creating Folder If Missing
if (!(Test-Path -PathType Container $StorageFolder)) {

    Write-Host "Creating directory: $StorageFolder"
    New-Item -ItemType Directory -Path $StorageFolder

}

#
# Functions
#

# RipMe Function
function Start-RipMe {
    param(
        $Url
    )

    # Initial Start Message
    Write-Host "Starting job for URL: $Url" -ForegroundColor Blue

    # Running as a job for monitoring
    $DownloadJob = Start-Job -ScriptBlock {
        param(
            $JarFile,
            $StorageFolder,
            $Url,
            $Threads
        )

        java -jar $JarFile --ripsdirectory $StorageFolder --url $Url --threads $Threads --skip404

    } -ArgumentList $JarFile, $StorageFolder, $Url, $Threads

    # Monitor: This will loop every minute until the job stops or the Max Job Time has been reached.

    $JobMonitorCounter = $null # Resetting counter

    while ($DownloadJob.State -eq 'Running'){

        Start-Sleep -Seconds 60


        if($JobMonitorCounter -ge $MaxJobTime){

            Write-Host "Job has exceeded it's threshold. Terminating job...." -ForegroundColor DarkRed
            Stop-Job -Job $DownloadJob

        }else{

            $JobMonitorCounter++
            Write-Host "- Still processing... $JobMonitorCounter minute(s) have elapsed" -ForegroundColor DarkGray

        }

    }

    # Providing result
    if ($DownloadJob.State -eq 'Completed') {

        # $result = Receive-Job -Job $DownloadJob
        Write-Host "- The job has completed successfully!" -ForegroundColor DarkGreen

    } elseif ($DownloadJob.State -eq 'Stopped') {

        Write-Host "- The job was terminated due to lack of progress." -ForegroundColor DarkRed

    } else {

        Write-Host "- The job ended in state: $($DownloadJob.State)" -ForegroundColor DarkRed

    }

    # Cleanup the job
    Remove-Job -Job $DownloadJob
    
}

# Variables required for cooldown counting
$BatchCounter = 0
$BatchLastItem = $Urls.Count

# Looping through URLs and starting the functions
$Urls | ForEach-Object {
    
    Start-RipMe -Url $_

    $BatchCounter++

    # Checking if a cooldown is required based on timer
    if($BatchCounter -lt $BatchLastItem){

        Write-Host "- Cooldown required, please wait!"
        Start-Sleep -Seconds $CooldownTimer

    }else{

        Write-Host "- Cooldown is not required."

    }

    
}

Write-Host "Script has ended."

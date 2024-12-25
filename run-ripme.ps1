param (
    [array]$Urls,
    [string]$ResultFile = ".\result\$(Get-Date -Format 'MM-dd-yyyy_HHmmss').csv",
    [string]$CsvFile,
    [int]$CooldownTimer = 300
)


#
# Settings
#

$StorageFolder = ($env:USERPROFILE + "\Downloads\RipMe")
$JarFile = Join-Path -Path $StorageFolder -ChildPath "ripme.jar"
$Threads = 5 # Thread Performance
$MaxJobTime = 10 # Job Timeout in Minutes

# Creating Folder If Missing
if (!(Test-Path -PathType Container $StorageFolder)) {

    Write-Host "Creating directory: $StorageFolder"
    New-Item -ItemType Directory -Path $StorageFolder

}

#
# Checks
#

# Parameter Check
if(($Urls -and $CsvFile) -or (!($Urls) -and !($CsvFile))){
    Write-Error "Parameters error! You must use one parameter." -ErrorAction Stop
}

# CSV File Actually Exists
if($CsvFile){
    if(!(Test-Path -Path $CsvFile)){
        Write-Error "Invalid CSV Path!" -ErrorAction Stop
    }
}

#
# CSV Handling
#

if($CsvFile){
    $Urls = Import-Csv -Path $CsvFile -Header URLs | 
        Select-Object -ExpandProperty URLs
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

        Write-Host "- The job has completed successfully!" -ForegroundColor DarkGreen
        $FinalStatus = "Completed"

    } elseif ($DownloadJob.State -eq 'Stopped') {

        Write-Host "- The job was terminated due to lack of progress." -ForegroundColor DarkRed
        $FinalStatus = "Terminated"

    } else {

        Write-Host "- The job ended in state: $($DownloadJob.State)" -ForegroundColor DarkRed
        $FinalStatus = "Error"

    }

    # Cleanup the job
    Remove-Job -Job $DownloadJob
    
    Return $FinalStatus
}

# Variables required for cooldown counting
$BatchCounter = 0
$BatchLastItem = $Urls.Count

# Creating Array for Batch Results
$BatchResult = @()

# Looping through URLs and starting the functions
$Urls | ForEach-Object {

    $result = $null
    $result = Start-RipMe -Url $_

    $BatchCounter++

    # Checking if a cooldown is required based on timer
    if($BatchCounter -lt $BatchLastItem){

        Write-Host "- Cooldown required, please wait!"
        Start-Sleep -Seconds $CooldownTimer

    }else{

        Write-Host "- Cooldown is not required."

    }

    $BatchResult += [PSCustomObject]@{

        Job = $_
        Result = $result

    }
}

$BatchResult | Export-Csv -Path $ResultFile -NoTypeInformation

return $BatchResult


Write-Host "Script has ended."

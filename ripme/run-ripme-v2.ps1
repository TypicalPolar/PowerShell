[CmdletBinding()]
param(

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({
        if(-not (Test-Path $_)){
            throw "Queue file not found: $_"
        }
        if((Get-ChildItem $_).Extension -ne ".txt"){
            throw "Queue file must be a .txt file."
        }
        return $true
    })]
    [string]$QueueFile,

    [string]$Directory =    "D:/RipMe",
    [string]$Output =       (Join-Path -Path $Directory -ChildPath "Output/"),
    [string]$JarFile =      (Join-Path -Path $Directory -ChildPath "ripme.jar"),
    [string]$LogFile = (
        Join-Path -Path ( Join-Path -Path $Directory -ChildPath 'Logs') `
            -ChildPath ("{0:MM-dd-yyyy_HHmmss}.csv" -f (Get-Date)
        )
    ),

    [int]$CooldownSeconds = 300,
    [int]$TimeoutMinutes =  10,
    [int]$Threads =         5
)

# Functions
function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Info','Warning','Error','Debug')]
        [string]$Level,

        [string]$Category,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$LogPath = $LogFile
    )

    if (-not (Test-Path (Split-Path $LogPath))) {
        New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force
    }

    $LogEntry = [PSCustomObject]@{
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Level     = $Level
        Category  = $Category
        Message   = $Message
    }

    $LogEntry | Export-Csv -Path $LogPath -Append -NoTypeInformation -Encoding UTF8 | Out-Null
}

function Invoke-Rip {
    param (
        [Parameter(Mandatory)]
        [string]$Url
    )

    $CurrentJob = Start-Job -ScriptBlock {

        $Arguments = @(
            '-jar', $JarFile
            '--ripsdirectory', $Output
            '--url', $Url
            '--threads', $Threads
            '--skip404'
        )

        Start-Process "Java"  -ArgumentList $Arguments -NoNewWindow -Wait

    } -ArgumentList $JarFile, $Output, $Url, $Threads

    $Timer = [Diagnostics.Stopwatch]::StartNew()

    while($CurrentJob.State -eq 'Running'){
        if ($Timer.Elapsed.Minutes -ge $TimeoutMinutes){
            Stop-Job -Job $CurrentJob
        }
    }

    $Timer.Stop()

    Remove-Job -Job $CurrentJob

    if($DownloadJob.State -eq 'Completed'){
        return "Completed"
    } elseif ($DownloadJob.State -eq 'Stopped'){
        return "Timed Out"
    } else {
        return "Error"
    }
}

# Pre-Flight Checks
if (-not (Test-Path -LiteralPath $Directory)) {
    throw "The specified directory '$Directory' does not exist. Please create it before running the script."
}

if (-not (Test-Path -LiteralPath $JarFile)) {
    throw "RipMe jar file is missing at this location: '$JarFile'."
}

@($Output, (Split-Path -Parent $LogFile)) | ForEach-Object {
    if (-not (Test-Path -LiteralPath $_)){
        Write-Verbose "Creating directory: $_"
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    throw "Java is not installed or is missing from environment variables."
}

# Queue List
$Urls = (
    Get-Content -LiteralPath $QueueFile -ErrorAction Stop |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and ($_ -notmatch '^\s*#') } | # ignore blanks and '# comments'
        Select-Object -Unique
)

$Urls | ForEach-Object {
    
    $Result
    $Result = Invoke-Rip -Url $_

    Write-Log -Level "Info" -Category $Result -Message $_

    if($_ -ne $Urls[-1]){
        Write-Host "Cooldown has begun, please wait..."
        Start-Sleep -Seconds $CooldownSeconds
    }

}
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
function Invoke-Rip {
    param (
        $Url
    )

    $Arguments = @(
        '-jar', $JarFile
        '--ripsdirectory', $Output
        '--url', $Url
        '--threads', $Threads
        '--skip404'
    )
    
}

# Pre-Flight Checks
if (-not (Test-Path -LiteralPath $Directory)) {
    throw "The specified directory '$Directory' does not exist. Please create it before running the script."
}

if (-not (Test-Path -LiteralPath $JarFile)) {
    throw "Jar file not found at '$JarFile'."
}

@($Output, (Split-Path -Parent $LogFile)) | ForEach-Object {
    if (-not (Test-Path -LiteralPath $_)){
        Write-Verbose "Creating directory: $_"
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    throw "Java is not available on PATH. Please install it or add it to PATH."
}

# Queue List
$Urls = (
    Get-Content -LiteralPath $QueueFile -ErrorAction Stop |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and ($_ -notmatch '^\s*#') } | # ignore blanks and '# comments'
        Select-Object -Unique
)
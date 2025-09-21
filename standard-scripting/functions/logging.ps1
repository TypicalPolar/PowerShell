function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Info','Warning','Error','Debug')]
        [string]$Level,

        [string]$Category,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$LogPath = "C:\tools\app\$((Get-Date).ToString("yyyy-MM-dd")).log"
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

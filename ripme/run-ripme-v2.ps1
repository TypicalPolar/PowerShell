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
            -ChildPath ("{0:yyyy-MM-dd_HHmmss}.csv" -f (Get-Date)
        )
    ),

    [ValidateRange(0, [int]::MaxValue)]
    [int]$CooldownSeconds = 300,

    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes =  10,

    [ValidateRange(1, 32)]
    [int]$Threads =         5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared run identifier — used to correlate the CSV log with per-URL stdout/stderr files in %TEMP%
$RunTimestamp = [IO.Path]::GetFileNameWithoutExtension($LogFile)
$TempPrefix   = Join-Path $env:TEMP "ripme_$RunTimestamp"

# Functions
function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Info','Warning','Error','Debug')]
        [string]$Level,

        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Url,

        [int]$ExitCode = -1,
        [double]$DurationSeconds = 0,
        [string]$StdOutPath = '',
        [string]$StdErrPath = '',

        [string]$LogPath = $LogFile
    )

    $LogDir = Split-Path $LogPath
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    $LogEntry = [PSCustomObject]@{
        Timestamp       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Level           = $Level
        Status          = $Status
        Url             = $Url
        ExitCode        = $ExitCode
        DurationSeconds = [math]::Round($DurationSeconds, 1)
        StdOutPath      = $StdOutPath
        StdErrPath      = $StdErrPath
    }

    $LogEntry | Export-Csv -Path $LogPath -Append -NoTypeInformation -Encoding UTF8
}

function Invoke-Rip {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [int]$Index
    )

    $IndexStr   = '{0:D3}' -f $Index
    $StdOutPath = "${TempPrefix}_${IndexStr}.stdout.log"
    $StdErrPath = "${TempPrefix}_${IndexStr}.stderr.log"

    $Arguments = @(
        '-jar', $JarFile
        '--ripsdirectory', $Output
        '--url', $Url
        '--threads', $Threads
        '--skip404'
    )

    $Proc      = $null
    $TimedOut  = $false
    $Stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $TimeoutMs = $TimeoutMinutes * 60 * 1000

    try {
        $Proc = Start-Process -FilePath 'java' `
            -ArgumentList $Arguments `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $StdOutPath `
            -RedirectStandardError  $StdErrPath

        while (-not $Proc.WaitForExit(1000)) {
            if ($Stopwatch.ElapsedMilliseconds -ge $TimeoutMs) {
                $TimedOut = $true
                break
            }
            $Pct = [math]::Min(100, ($Stopwatch.ElapsedMilliseconds / $TimeoutMs) * 100)
            Write-Progress -Id 1 -ParentId 0 -Activity "Ripping: $Url" `
                -Status ("Elapsed {0:N0}s / Timeout {1}s" -f $Stopwatch.Elapsed.TotalSeconds, ($TimeoutMinutes * 60)) `
                -PercentComplete $Pct
        }

        if ($TimedOut) {
            # /T = tree, /F = force. Kills java + any descendants even if shutdown hooks hang.
            & taskkill.exe /PID $Proc.Id /T /F 1>$null 2>$null
            $Proc.WaitForExit(5000) | Out-Null
        }
    }
    finally {
        $Stopwatch.Stop()
        Write-Progress -Id 1 -ParentId 0 -Activity "Ripping: $Url" -Completed

        # Defensive: kill anything still alive if we're unwinding from an exception or Ctrl+C
        if ($null -ne $Proc -and -not $Proc.HasExited) {
            & taskkill.exe /PID $Proc.Id /T /F 1>$null 2>$null
            $Proc.WaitForExit(5000) | Out-Null
        }
    }

    $ExitCode = if ($null -ne $Proc) { $Proc.ExitCode } else { -1 }

    $Status = if ($TimedOut)         { 'Timed Out' }
              elseif ($ExitCode -eq 0) { 'Completed' }
              else                     { 'Error' }

    return [pscustomobject]@{
        Status          = $Status
        ExitCode        = $ExitCode
        DurationSeconds = $Stopwatch.Elapsed.TotalSeconds
        StdOutPath      = $StdOutPath
        StdErrPath      = $StdErrPath
    }
}

function Start-Cooldown {
    [CmdletBinding()]
    param([int]$Seconds)

    if ($Seconds -le 0) { return }

    $Stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($Stopwatch.Elapsed.TotalSeconds -lt $Seconds) {
        $Remaining = [int]($Seconds - $Stopwatch.Elapsed.TotalSeconds)
        $Pct       = [math]::Min(100, ($Stopwatch.Elapsed.TotalSeconds / $Seconds) * 100)
        Write-Progress -Id 1 -ParentId 0 -Activity "Cooldown" `
            -Status "Waiting ${Remaining}s before next URL" `
            -PercentComplete $Pct
        Start-Sleep -Seconds 1
    }
    Write-Progress -Id 1 -ParentId 0 -Activity "Cooldown" -Completed
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

# Queue List — normalize (lowercase + strip trailing slash) for dedup, keep first-seen casing for the rip
$Seen = @{}
$Urls = @(
    Get-Content -LiteralPath $QueueFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and ($_ -notmatch '^\s*#') } |
        ForEach-Object {
            $Norm = $_.ToLowerInvariant().TrimEnd('/')
            if (-not $Seen.ContainsKey($Norm)) {
                $Seen[$Norm] = $true
                $_
            }
        }
)

if ($Urls.Count -eq 0) {
    Write-Warning "Queue file '$QueueFile' contains no URLs after filtering blanks/comments. Nothing to do."
    return
}

Write-Host "Processing $($Urls.Count) URL(s)."
Write-Host "Log:       $LogFile"
Write-Host "Temp logs: ${TempPrefix}_*.{stdout,stderr}.log"

for ($i = 0; $i -lt $Urls.Count; $i++) {
    $Url    = $Urls[$i]
    $UrlNum = $i + 1

    Write-Progress -Id 0 -Activity "RipMe Batch" `
        -Status "URL $UrlNum of $($Urls.Count): $Url" `
        -PercentComplete (($i / $Urls.Count) * 100)

    Write-Host "[$UrlNum/$($Urls.Count)] Starting: $Url"

    $Result = $null
    try {
        $Result = Invoke-Rip -Url $Url -Index $UrlNum
    }
    catch {
        # Catch-and-continue: log the exception to this URL's stderr file so StdErrPath stays meaningful
        $IndexStr   = '{0:D3}' -f $UrlNum
        $StdErrPath = "${TempPrefix}_${IndexStr}.stderr.log"
        $_ | Out-String | Set-Content -LiteralPath $StdErrPath -Encoding UTF8

        $Result = [pscustomobject]@{
            Status          = 'Error'
            ExitCode        = -1
            DurationSeconds = 0
            StdOutPath      = ''
            StdErrPath      = $StdErrPath
        }
        Write-Warning "[$UrlNum/$($Urls.Count)] Invoke-Rip threw: $($_.Exception.Message)"
    }

    Write-Host ("[{0}/{1}] {2} (exit={3}, duration={4:N1}s)" -f `
        $UrlNum, $Urls.Count, $Result.Status, $Result.ExitCode, $Result.DurationSeconds)

    Write-Log -Level Info `
        -Status          $Result.Status `
        -Url             $Url `
        -ExitCode        $Result.ExitCode `
        -DurationSeconds $Result.DurationSeconds `
        -StdOutPath      $Result.StdOutPath `
        -StdErrPath      $Result.StdErrPath

    $IsLast = ($i -eq $Urls.Count - 1)
    if (-not $IsLast) {
        Write-Host "Cooldown: $CooldownSeconds seconds..."
        Start-Cooldown -Seconds $CooldownSeconds
    }
}

Write-Progress -Id 0 -Activity "RipMe Batch" -Completed
Write-Host "Batch complete. See log: $LogFile"

[CmdletBinding()]
param(
    [string]$RootFolder = "C:\Projects\RS-Forum-Parsing",

    [string]$ParserScriptName = "parse-sub-forum-threads.ps1",

    [ValidateSet('Normal', 'Moderate', 'Aggressive')]
    [string]$DiscoveryBehavior = 'Normal',

    [switch]$ForceRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-BatchLog {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$timestamp] [$Level] $Message"
}

function Get-ProgressCsvPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputCsvPath
    )

    $directory = [System.IO.Path]::GetDirectoryName($OutputCsvPath)
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = (Get-Location).Path
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($OutputCsvPath)
    $extension = [System.IO.Path]::GetExtension($OutputCsvPath)

    return [System.IO.Path]::Combine($directory, "$baseName.progress$extension")
}

$ParserScriptPath = Join-Path $RootFolder $ParserScriptName

if (-not (Test-Path -LiteralPath $RootFolder)) {
    throw "Root folder not found: $RootFolder"
}

if (-not (Test-Path -LiteralPath $ParserScriptPath)) {
    throw "Parser script not found: $ParserScriptPath"
}

Write-BatchLog -Level INFO -Message "Root folder: $RootFolder"
Write-BatchLog -Level INFO -Message "Parser script: $ParserScriptPath"
Write-BatchLog -Level INFO -Message "DiscoveryBehavior: $DiscoveryBehavior"
Write-BatchLog -Level INFO -Message ("Run mode: " + ($(if ($ForceRestart) { 'Fresh start (-ForceRestart)' } else { 'Skip completed / resume existing jobs' })))

$JsonFiles = Get-ChildItem -Path $RootFolder -Directory |
    Sort-Object Name |
    ForEach-Object {
        Get-ChildItem -Path $_.FullName -File -Filter *.json | Sort-Object Name
    }

if (-not $JsonFiles) {
    Write-BatchLog -Level WARN -Message "No JSON files found under subfolders of: $RootFolder"
    return
}

$jobNumber = 0
$totalJobs = @($JsonFiles).Count
$successCount = 0
$skipCount = 0
$errorCount = 0

foreach ($JsonFile in $JsonFiles) {
    $jobNumber++

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($JsonFile.Name)
    $outputCsvPath = Join-Path $JsonFile.DirectoryName ("threads-$baseName.csv")
    $progressCsvPath = Get-ProgressCsvPath -OutputCsvPath $outputCsvPath

    Write-BatchLog -Level INFO -Message "[$jobNumber/$totalJobs] JSON: $($JsonFile.FullName)"
    Write-BatchLog -Level INFO -Message "[$jobNumber/$totalJobs] Output CSV: $outputCsvPath"

    if (-not $ForceRestart) {
        $outputExists = Test-Path -LiteralPath $outputCsvPath
        $progressExists = Test-Path -LiteralPath $progressCsvPath

        if ($outputExists -and $progressExists) {
            Write-BatchLog -Level INFO -Message "[$jobNumber/$totalJobs] Skipping already-initialized job because output and progress files both exist."
            $skipCount++
            continue
        }
    }

    try {
        $params = @{
            InputJsonPath     = $JsonFile.FullName
            OutputCsvPath     = $outputCsvPath
            DiscoveryBehavior = $DiscoveryBehavior
        }

        if ($ForceRestart) {
            $params['ForceRestart'] = $true
        }

        & $ParserScriptPath @params

        Write-BatchLog -Level INFO -Message "[$jobNumber/$totalJobs] Completed successfully."
        $successCount++
    }
    catch {
        Write-BatchLog -Level ERROR -Message "[$jobNumber/$totalJobs] Failed: $($_.Exception.Message)"
        $errorCount++
        continue
    }
}

Write-BatchLog -Level INFO -Message "Batch run complete."
Write-BatchLog -Level INFO -Message "Successful: $successCount"
Write-BatchLog -Level INFO -Message "Skipped: $skipCount"
Write-BatchLog -Level INFO -Message "Errors: $errorCount"
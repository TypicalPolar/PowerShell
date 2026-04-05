<#
.SYNOPSIS
Parses Wayback Machine CDX JSON data to extract page titles from archived RuneScape forum URLs.

.DESCRIPTION
This script processes a previously exported CDX JSON file from the Wayback Machine and attempts to extract
the HTML <title> from the earliest known archived capture of each unique URL.

If the HTML <title> is generic (for example, a RuneScape site-wide title), the script will automatically
try one or more replacement extraction rules to locate a better thread title from the HTML body.

It is designed to be:
- Resumable (safe to stop and restart at any time)
- Fault-tolerant (handles Wayback slowness and failures)
- Auditable (keeps a full attempt log)

Results are stored in two files:
- Results CSV (current best state per URL)
- Attempt log CSV (append-only history of all attempts)

This script does NOT query CDX live. It expects a pre-exported JSON file.

.PARAMETER JsonPath
Path to the CDX JSON file exported from the Wayback Machine.

.PARAMETER ResultsCsvPath
Path to the results CSV file. This file is continuously rewritten with the latest known result per URL.

.PARAMETER AttemptLogPath
Path to the attempt log CSV file. This file is append-only and records every attempt made.

.PARAMETER DiscoveryBehavior
Controls how aggressively the script searches for usable titles across available captures.

Available modes:

- Normal:
  * Uses only the earliest capture per URL
  * Does NOT attempt fallback to later captures
  * Skips non-200 and non-HTML captures
  * Fastest and cleanest initial pass

- Moderate:
  * Starts with earliest capture
  * Falls back to later captures if needed
  * Continues past generic titles (tries to find better ones)
  * Skips non-200 and non-HTML captures
  * Recommended for second pass / recovery

- Aggressive:
  * Enables full fallback behavior
  * Continues past generic titles
  * May include non-200 / non-HTML captures
  * Tries more captures per URL
  * Best for stubborn or incomplete results

Explicit parameters override this preset.

.PARAMETER UseIdReplay
Uses Wayback "id_" replay mode instead of normal replay.

.PARAMETER MaxItems
Limits the number of unique URLs processed (after deduplication).

.PARAMETER GenericTitlePatterns
List of strings or regex patterns that identify generic titles.

.PARAMETER GenericTitleReplacementRules
List of replacement rule names to try when a generic title is found.

Current supported rule names:
- DivClassTitleThrd

These rules are tried in order. The first one that extracts a non-empty title wins.

.PARAMETER SkipNonHtmlOrNon200
If enabled, skips CDX entries where:
- statuscode != 200
- mimetype != text/html

.PARAMETER MaxFallbackCaptures
Maximum number of captures to try per URL when fallback is enabled.

.PARAMETER RequestTimeoutSeconds
Timeout for each Wayback request.

.PARAMETER RetryCount
Number of retry attempts for failed requests. A value of 2 means up to 3 total tries.

.PARAMETER RetryDelaySeconds
Delay between retry attempts.

.PARAMETER InterRequestDelayMilliseconds
Optional delay between requests to avoid overwhelming Wayback.

.EXAMPLE
.\Get-WaybackTitles.ps1 `
  -JsonPath ".\cdx.json" `
  -ResultsCsvPath ".\results.csv" `
  -AttemptLogPath ".\attempt-log.csv" `
  -DiscoveryBehavior Normal `
  -GenericTitlePatterns @(
      'RuneScape - The Number 1 Free Multiplayer Game',
      'RuneScape - the massive online adventure game by Jagex Ltd'
  ) `
  -GenericTitleReplacementRules @(
      'DivClassTitleThrd'
  )

.NOTES
- Script is safe to stop at any time.
- Progress is saved after each URL.
- Attempt log is written immediately per attempt.
- Results file uses safe rewrite to avoid corruption.
- Titles are preserved as-is as much as possible.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JsonPath,

    [Parameter(Mandatory = $true)]
    [string]$ResultsCsvPath,

    [Parameter(Mandatory = $true)]
    [string]$AttemptLogPath,

    [ValidateSet("Normal", "Moderate", "Aggressive")]
    [string]$DiscoveryBehavior = "Normal",

    [switch]$UseIdReplay,

    [int]$MaxItems = 0,

    [string[]]$GenericTitlePatterns = @(),

    [string[]]$GenericTitleReplacementRules = @('DivClassTitleThrd'),

    [Nullable[bool]]$SkipNonHtmlOrNon200 = $null,

    [int]$MaxFallbackCaptures = 0,

    [ValidateRange(1, 600)]
    [int]$RequestTimeoutSeconds = 30,

    [ValidateRange(0, 20)]
    [int]$RetryCount = 2,

    [ValidateRange(0, 300)]
    [int]$RetryDelaySeconds = 2,

    [ValidateRange(0, 60000)]
    [int]$InterRequestDelayMilliseconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DiscoveryBehaviorConfig {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Normal", "Moderate", "Aggressive")]
        [string]$Behavior,

        [Nullable[bool]]$SkipNonHtmlOrNon200Override,

        [int]$MaxFallbackCapturesOverride
    )

    switch ($Behavior) {
        'Normal' {
            $config = [pscustomobject]@{
                AllowLaterCaptureFallback = $false
                ContinueAfterGenericTitle = $false
                SkipNonHtmlOrNon200      = $true
                MaxFallbackCaptures      = 1
            }
        }
        'Moderate' {
            $config = [pscustomobject]@{
                AllowLaterCaptureFallback = $true
                ContinueAfterGenericTitle = $true
                SkipNonHtmlOrNon200      = $true
                MaxFallbackCaptures      = 5
            }
        }
        'Aggressive' {
            $config = [pscustomobject]@{
                AllowLaterCaptureFallback = $true
                ContinueAfterGenericTitle = $true
                SkipNonHtmlOrNon200      = $false
                MaxFallbackCaptures      = 0
            }
        }
    }

    if ($null -ne $SkipNonHtmlOrNon200Override) {
        $config.SkipNonHtmlOrNon200 = [bool]$SkipNonHtmlOrNon200Override
    }

    if ($MaxFallbackCapturesOverride -gt 0) {
        $config.MaxFallbackCaptures = $MaxFallbackCapturesOverride
    }

    return $config
}

$BehaviorConfig = Get-DiscoveryBehaviorConfig `
    -Behavior $DiscoveryBehavior `
    -SkipNonHtmlOrNon200Override $SkipNonHtmlOrNon200 `
    -MaxFallbackCapturesOverride $MaxFallbackCaptures

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO ] $Message"
}

function Write-WarnText {
    param([string]$Message)
    Write-Warning $Message
}

function Ensure-ParentDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function New-OrderedResultRow {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalUrl
    )

    return [ordered]@{
        OriginalUrl       = $OriginalUrl
        FirstTimestamp    = ''
        UsedTimestamp     = ''
        WaybackUrl        = ''
        Title             = ''
        Result            = ''
        UsedFallback      = ''
        AttemptCount      = 0
        StatusCodeFromCdx = ''
        MimeTypeFromCdx   = ''
        ErrorMessage      = ''
        LastAttemptUtc    = ''
    }
}

function New-OrderedAttemptLogRow {
    return [ordered]@{
        OriginalUrl       = ''
        CaptureTimestamp  = ''
        WaybackUrl        = ''
        AttemptUtc        = ''
        AttemptNumber     = 0
        UsedFallback      = ''
        Result            = ''
        Title             = ''
        ErrorMessage      = ''
    }
}

function Import-CdxJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "JSON file not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $json = $raw | ConvertFrom-Json

    if (-not $json -or $json.Count -lt 2) {
        throw "CDX JSON appears empty or invalid."
    }

    $rows = New-Object System.Collections.Generic.List[object]

    for ($i = 1; $i -lt $json.Count; $i++) {
        $row = @($json[$i])
        if ($row.Count -lt 7) {
            Write-WarnText "Skipping malformed CDX row at index $i (fewer than 7 fields)."
            continue
        }

        $obj = [pscustomobject]@{
            UrlKey     = [string]$row[0]
            Timestamp  = [string]$row[1]
            Original   = [string]$row[2]
            MimeType   = [string]$row[3]
            StatusCode = [string]$row[4]
            Digest     = [string]$row[5]
            Length     = [string]$row[6]
        }

        if ([string]::IsNullOrWhiteSpace($obj.Original) -or [string]::IsNullOrWhiteSpace($obj.Timestamp)) {
            Write-WarnText "Skipping malformed CDX row at index $i (missing Original or Timestamp)."
            continue
        }

        $rows.Add($obj)
    }

    return $rows
}

function Group-CdxCapturesByUrl {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$Rows
    )

    $groups = @{}

    foreach ($row in $Rows) {
        if (-not $groups.ContainsKey($row.Original)) {
            $groups[$row.Original] = New-Object System.Collections.Generic.List[object]
        }
        $groups[$row.Original].Add($row)
    }

    $workItems = New-Object System.Collections.Generic.List[object]

    foreach ($originalUrl in ($groups.Keys | Sort-Object)) {
        $captures = @($groups[$originalUrl] | Sort-Object -Property Timestamp)

        $firstTimestamp = ''
        if ($captures.Count -gt 0) {
            $firstTimestamp = [string]$captures[0].Timestamp
        }

        $workItems.Add([pscustomobject]@{
            OriginalUrl    = $originalUrl
            FirstTimestamp = $firstTimestamp
            Captures       = $captures
        })
    }

    return $workItems
}

function Load-ResultsState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $lookup = @{}

    if (-not (Test-Path -LiteralPath $Path)) {
        return $lookup
    }

    $rows = Import-Csv -LiteralPath $Path
    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace($row.OriginalUrl)) {
            continue
        }

        $attemptCount = 0
        if (-not [string]::IsNullOrWhiteSpace($row.AttemptCount)) {
            [void][int]::TryParse([string]$row.AttemptCount, [ref]$attemptCount)
        }

        $lookup[$row.OriginalUrl] = [ordered]@{
            OriginalUrl       = [string]$row.OriginalUrl
            FirstTimestamp    = [string]$row.FirstTimestamp
            UsedTimestamp     = [string]$row.UsedTimestamp
            WaybackUrl        = [string]$row.WaybackUrl
            Title             = [string]$row.Title
            Result            = [string]$row.Result
            UsedFallback      = [string]$row.UsedFallback
            AttemptCount      = $attemptCount
            StatusCodeFromCdx = [string]$row.StatusCodeFromCdx
            MimeTypeFromCdx   = [string]$row.MimeTypeFromCdx
            ErrorMessage      = [string]$row.ErrorMessage
            LastAttemptUtc    = [string]$row.LastAttemptUtc
        }
    }

    return $lookup
}

function Save-ResultsState {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Lookup,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Ensure-ParentDirectory -Path $Path
    $tmpPath = "$Path.tmp"

    $rows = foreach ($key in ($Lookup.Keys | Sort-Object)) {
        $row = $Lookup[$key]
        [pscustomobject]([ordered]@{
            OriginalUrl       = $row.OriginalUrl
            FirstTimestamp    = $row.FirstTimestamp
            UsedTimestamp     = $row.UsedTimestamp
            WaybackUrl        = $row.WaybackUrl
            Title             = $row.Title
            Result            = $row.Result
            UsedFallback      = $row.UsedFallback
            AttemptCount      = $row.AttemptCount
            StatusCodeFromCdx = $row.StatusCodeFromCdx
            MimeTypeFromCdx   = $row.MimeTypeFromCdx
            ErrorMessage      = $row.ErrorMessage
            LastAttemptUtc    = $row.LastAttemptUtc
        })
    }

    $rows | Export-Csv -LiteralPath $tmpPath -NoTypeInformation -Encoding UTF8

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
    Move-Item -LiteralPath $tmpPath -Destination $Path -Force
}

function Ensure-AttemptLogFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Ensure-ParentDirectory -Path $Path

    if (-not (Test-Path -LiteralPath $Path)) {
        @() | Select-Object OriginalUrl, CaptureTimestamp, WaybackUrl, AttemptUtc, AttemptNumber, UsedFallback, Result, Title, ErrorMessage |
            Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    }
}

function Write-AttemptLogRow {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Row,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Ensure-AttemptLogFile -Path $Path
    [pscustomobject]$Row | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -Append
}

function Should-SkipUrl {
    param(
        [hashtable]$ResultsLookup,
        [Parameter(Mandatory = $true)][string]$OriginalUrl
    )

    if (-not $ResultsLookup.ContainsKey($OriginalUrl)) {
        return $false
    }

    $existing = $ResultsLookup[$OriginalUrl]
    return ([string]$existing.Result -eq 'Success' -or [string]$existing.Result -eq 'SuccessFromReplacementRule')
}

function Build-WaybackUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][string]$OriginalUrl,
        [switch]$UseIdReplay
    )

    if ($UseIdReplay) {
        return "https://web.archive.org/web/$($Timestamp)id_/$OriginalUrl"
    }

    return "https://web.archive.org/web/$Timestamp/$OriginalUrl"
}

function Get-HtmlTitle {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Html
    )

    if ([string]::IsNullOrEmpty($Html)) {
        return $null
    }

    $match = [regex]::Match($Html, '(?is)<title\b[^>]*>(.*?)</title>')
    if (-not $match.Success) {
        return $null
    }

    $title = $match.Groups[1].Value

    try {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $title = [System.Web.HttpUtility]::HtmlDecode($title)
    }
    catch {
    }

    $title = $title -replace "`0", ''

    if ($title.Length -eq 0) {
        return $null
    }

    return $title
}

function Decode-HtmlText {
    param(
        [AllowNull()][string]$Text
    )

    if ($null -eq $Text) {
        return $null
    }

    $value = $Text
    try {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $value = [System.Web.HttpUtility]::HtmlDecode($value)
    }
    catch {
    }

    # Strip tags if any slipped in.
    $value = [regex]::Replace($value, '(?is)<[^>]+>', '')
    $value = $value -replace "`0", ''
    return $value
}

function Test-IsGenericTitle {
    param(
        [AllowNull()][string]$Title,
        [string[]]$Patterns
    )

    if ([string]::IsNullOrEmpty($Title)) {
        return $false
    }

    if (-not $Patterns -or $Patterns.Count -eq 0) {
        return $false
    }

    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            continue
        }

        try {
            if ($Title -match $pattern) {
                return $true
            }
        }
        catch {
            if ($Title.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }
    }

    return $false
}

function Get-ReplacementTitleFromHtml {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Html,

        [string[]]$Rules
    )

    if ([string]::IsNullOrEmpty($Html)) {
        return $null
    }

    if (-not $Rules -or $Rules.Count -eq 0) {
        return $null
    }

    foreach ($rule in $Rules) {
        switch ($rule) {
            'DivClassTitleThrd' {
                # Match a div whose class attribute contains BOTH "title" and "thrd"
                # in any order, with any extra classes allowed.
                $pattern = '(?is)<div\b(?=[^>]*\bclass\s*=\s*["''][^"'']*\btitle\b)(?=[^>]*\bclass\s*=\s*["''][^"'']*\bthrd\b)[^>]*>(.*?)</div>'
                $match = [regex]::Match($Html, $pattern)

                if ($match.Success) {
                    $candidate = Decode-HtmlText -Text $match.Groups[1].Value
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                        return $candidate
                    }
                }
            }

            default {
                Write-WarnText "Unknown GenericTitleReplacementRule '$rule' was ignored."
            }
        }
    }

    return $null
}

function Invoke-WaybackRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$RetryCount,
        [Parameter(Mandatory = $true)][int]$RetryDelaySeconds
    )

    $lastError = $null

    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Uri $Url `
                -Method Get `
                -MaximumRedirection 10 `
                -TimeoutSec $TimeoutSeconds `
                -UseBasicParsing `
                -ErrorAction Stop

            return [pscustomobject]@{
                Success      = $true
                Status       = 'Success'
                Content      = [string]$response.Content
                ErrorMessage = ''
            }
        }
        catch {
            $lastError = $_
            $message = $_.Exception.Message
            $status = 'RequestFailed'

            if ($message -match 'timed out' -or $message -match 'operation has timed out') {
                $status = 'Timeout'
            }

            if ($attempt -lt $RetryCount -and $RetryDelaySeconds -gt 0) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }

            if ($attempt -eq $RetryCount) {
                return [pscustomobject]@{
                    Success      = $false
                    Status       = $status
                    Content      = ''
                    ErrorMessage = $message
                }
            }
        }
    }

    return [pscustomobject]@{
        Success      = $false
        Status       = 'RequestFailed'
        Content      = ''
        ErrorMessage = if ($lastError) { $lastError.Exception.Message } else { 'Unknown request failure.' }
    }
}

function Get-AttemptCount {
    param(
        [hashtable]$ResultsLookup,
        [Parameter(Mandatory = $true)][string]$OriginalUrl
    )

    if ($ResultsLookup.ContainsKey($OriginalUrl)) {
        return [int]$ResultsLookup[$OriginalUrl].AttemptCount
    }

    return 0
}

function Update-ResultsRow {
    param(
        [Parameter(Mandatory = $true)][hashtable]$ResultsLookup,
        [Parameter(Mandatory = $true)][string]$OriginalUrl,
        [Parameter(Mandatory = $true)][string]$FirstTimestamp,
        [Parameter(Mandatory = $true)][string]$UsedTimestamp,
        [Parameter(Mandatory = $true)][string]$WaybackUrl,
        [AllowNull()][string]$Title,
        [Parameter(Mandatory = $true)][string]$Result,
        [Parameter(Mandatory = $true)][bool]$UsedFallback,
        [Parameter(Mandatory = $true)][string]$StatusCodeFromCdx,
        [Parameter(Mandatory = $true)][string]$MimeTypeFromCdx,
        [AllowNull()][string]$ErrorMessage,
        [Parameter(Mandatory = $true)][string]$LastAttemptUtc
    )

    if ($ResultsLookup.ContainsKey($OriginalUrl)) {
        $row = $ResultsLookup[$OriginalUrl]
    }
    else {
        $row = New-OrderedResultRow -OriginalUrl $OriginalUrl
    }

    $row.OriginalUrl       = $OriginalUrl
    $row.FirstTimestamp    = $FirstTimestamp
    $row.UsedTimestamp     = $UsedTimestamp
    $row.WaybackUrl        = $WaybackUrl
    $row.Title             = if ($null -ne $Title) { $Title } else { '' }
    $row.Result            = $Result
    $row.UsedFallback      = $UsedFallback
    $row.AttemptCount      = [int]$row.AttemptCount
    $row.StatusCodeFromCdx = $StatusCodeFromCdx
    $row.MimeTypeFromCdx   = $MimeTypeFromCdx
    $row.ErrorMessage      = if ($null -ne $ErrorMessage) { $ErrorMessage } else { '' }
    $row.LastAttemptUtc    = $LastAttemptUtc

    $ResultsLookup[$OriginalUrl] = $row
}

function Increment-ResultsAttemptCount {
    param(
        [Parameter(Mandatory = $true)][hashtable]$ResultsLookup,
        [Parameter(Mandatory = $true)][string]$OriginalUrl,
        [Parameter(Mandatory = $true)][string]$FirstTimestamp
    )

    if (-not $ResultsLookup.ContainsKey($OriginalUrl)) {
        $row = New-OrderedResultRow -OriginalUrl $OriginalUrl
        $row.FirstTimestamp = $FirstTimestamp
        $ResultsLookup[$OriginalUrl] = $row
    }

    $ResultsLookup[$OriginalUrl].AttemptCount = ([int]$ResultsLookup[$OriginalUrl].AttemptCount) + 1
}

function Is-CdxRowEligible {
    param(
        [Parameter(Mandatory = $true)]$Capture,
        [Parameter(Mandatory = $true)][bool]$SkipNonHtmlOrNon200
    )

    if (-not $SkipNonHtmlOrNon200) {
        return $true
    }

    $is200 = ([string]$Capture.StatusCode -eq '200')
    $isHtml = ([string]$Capture.MimeType -eq 'text/html')

    return ($is200 -and $isHtml)
}

if (-not (Test-Path -LiteralPath $JsonPath)) {
    throw "JsonPath does not exist: $JsonPath"
}

Ensure-ParentDirectory -Path $ResultsCsvPath
Ensure-ParentDirectory -Path $AttemptLogPath

Write-Info "Loading existing results state..."
$ResultsLookup = Load-ResultsState -Path $ResultsCsvPath

Write-Info "Loading CDX JSON..."
$cdxRows = Import-CdxJson -Path $JsonPath

Write-Info "Grouping captures by original URL..."
$workItems = Group-CdxCapturesByUrl -Rows $cdxRows

if ($MaxItems -gt 0) {
    $workItems = @($workItems | Select-Object -First $MaxItems)
    Write-Info "MaxItems applied. Processing first $MaxItems unique URLs after dedupe."
}

Ensure-AttemptLogFile -Path $AttemptLogPath

Write-Info "DiscoveryBehavior = $DiscoveryBehavior"
Write-Info ("UseIdReplay = {0}" -f $UseIdReplay.IsPresent)
Write-Info ("AllowLaterCaptureFallback = {0}" -f $BehaviorConfig.AllowLaterCaptureFallback)
Write-Info ("ContinueAfterGenericTitle = {0}" -f $BehaviorConfig.ContinueAfterGenericTitle)
Write-Info ("SkipNonHtmlOrNon200 = {0}" -f $BehaviorConfig.SkipNonHtmlOrNon200)
Write-Info ("MaxFallbackCaptures = {0}" -f $(if ($BehaviorConfig.MaxFallbackCaptures -eq 0) { 'unlimited' } else { $BehaviorConfig.MaxFallbackCaptures }))
Write-Info ("GenericTitleReplacementRules = {0}" -f ($GenericTitleReplacementRules -join ', '))

$total = @($workItems).Count
$index = 0

foreach ($item in $workItems) {
    $index++
    $originalUrl = [string]$item.OriginalUrl
    $firstTimestamp = [string]$item.FirstTimestamp

    Write-Host ""
    Write-Host ("[{0}/{1}] {2}" -f $index, $total, $originalUrl)

    if (Should-SkipUrl -ResultsLookup $ResultsLookup -OriginalUrl $originalUrl) {
        Write-Info "Skipping URL because results already show Success or SuccessFromReplacementRule."
        continue
    }

    $captures = @($item.Captures | Sort-Object -Property Timestamp)

    if (-not $BehaviorConfig.AllowLaterCaptureFallback) {
        $captures = @($captures | Select-Object -First 1)
    }

    if ($BehaviorConfig.MaxFallbackCaptures -gt 0) {
        $captures = @($captures | Select-Object -First $BehaviorConfig.MaxFallbackCaptures)
    }

    $finalized = $false
    $genericStored = $false
    $attemptNumber = Get-AttemptCount -ResultsLookup $ResultsLookup -OriginalUrl $originalUrl

    foreach ($capture in $captures) {
        $usedTimestamp = [string]$capture.Timestamp
        $usedFallback = ($usedTimestamp -ne $firstTimestamp)
        $attemptNumber++
        $attemptUtc = [DateTime]::UtcNow.ToString("o")
        $waybackUrl = Build-WaybackUrl -Timestamp $usedTimestamp -OriginalUrl $originalUrl -UseIdReplay:$UseIdReplay

        if (-not (Is-CdxRowEligible -Capture $capture -SkipNonHtmlOrNon200 $BehaviorConfig.SkipNonHtmlOrNon200)) {
            $result = 'SkippedByCdxFilter'
            $errorMessage = "Skipped because CDX row was not statuscode=200 and mimetype=text/html."

            Increment-ResultsAttemptCount -ResultsLookup $ResultsLookup -OriginalUrl $originalUrl -FirstTimestamp $firstTimestamp

            $attemptRow = New-OrderedAttemptLogRow
            $attemptRow.OriginalUrl      = $originalUrl
            $attemptRow.CaptureTimestamp = $usedTimestamp
            $attemptRow.WaybackUrl       = $waybackUrl
            $attemptRow.AttemptUtc       = $attemptUtc
            $attemptRow.AttemptNumber    = $attemptNumber
            $attemptRow.UsedFallback     = $usedFallback
            $attemptRow.Result           = $result
            $attemptRow.Title            = ''
            $attemptRow.ErrorMessage     = $errorMessage
            Write-AttemptLogRow -Row $attemptRow -Path $AttemptLogPath

            Update-ResultsRow `
                -ResultsLookup $ResultsLookup `
                -OriginalUrl $originalUrl `
                -FirstTimestamp $firstTimestamp `
                -UsedTimestamp $usedTimestamp `
                -WaybackUrl $waybackUrl `
                -Title '' `
                -Result $result `
                -UsedFallback $usedFallback `
                -StatusCodeFromCdx ([string]$capture.StatusCode) `
                -MimeTypeFromCdx ([string]$capture.MimeType) `
                -ErrorMessage $errorMessage `
                -LastAttemptUtc $attemptUtc

            Save-ResultsState -Lookup $ResultsLookup -Path $ResultsCsvPath
            Write-Info "Skipped capture due to CDX filter: $usedTimestamp"
            continue
        }

        Write-Info "Trying capture: $usedTimestamp"
        Write-Info "Wayback URL: $waybackUrl"

        Increment-ResultsAttemptCount -ResultsLookup $ResultsLookup -OriginalUrl $originalUrl -FirstTimestamp $firstTimestamp

        $request = Invoke-WaybackRequest `
            -Url $waybackUrl `
            -TimeoutSeconds $RequestTimeoutSeconds `
            -RetryCount $RetryCount `
            -RetryDelaySeconds $RetryDelaySeconds

        $result = ''
        $title = ''
        $errorMessage = ''

        if (-not $request.Success) {
            $result = [string]$request.Status
            $errorMessage = [string]$request.ErrorMessage
        }
        else {
            $html = [string]$request.Content
            $title = Get-HtmlTitle -Html $html

            if ([string]::IsNullOrEmpty($title)) {
                $result = 'NoTitle'
                $errorMessage = 'Archived page was fetched, but no non-empty <title> was found.'
            }
            elseif (Test-IsGenericTitle -Title $title -Patterns $GenericTitlePatterns) {
                $replacementTitle = Get-ReplacementTitleFromHtml -Html $html -Rules $GenericTitleReplacementRules

                if (-not [string]::IsNullOrWhiteSpace($replacementTitle)) {
                    $title = $replacementTitle
                    $result = 'SuccessFromReplacementRule'
                    $errorMessage = ''
                }
                else {
                    $result = 'GenericTitle'
                    $errorMessage = ''
                    $genericStored = $true
                }
            }
            else {
                $result = 'Success'
                $errorMessage = ''
            }
        }

        $attemptRow = New-OrderedAttemptLogRow
        $attemptRow.OriginalUrl      = $originalUrl
        $attemptRow.CaptureTimestamp = $usedTimestamp
        $attemptRow.WaybackUrl       = $waybackUrl
        $attemptRow.AttemptUtc       = $attemptUtc
        $attemptRow.AttemptNumber    = $attemptNumber
        $attemptRow.UsedFallback     = $usedFallback
        $attemptRow.Result           = $result
        $attemptRow.Title            = if ($title) { $title } else { '' }
        $attemptRow.ErrorMessage     = $errorMessage
        Write-AttemptLogRow -Row $attemptRow -Path $AttemptLogPath

        Update-ResultsRow `
            -ResultsLookup $ResultsLookup `
            -OriginalUrl $originalUrl `
            -FirstTimestamp $firstTimestamp `
            -UsedTimestamp $usedTimestamp `
            -WaybackUrl $waybackUrl `
            -Title $(if ($title) { $title } else { '' }) `
            -Result $result `
            -UsedFallback $usedFallback `
            -StatusCodeFromCdx ([string]$capture.StatusCode) `
            -MimeTypeFromCdx ([string]$capture.MimeType) `
            -ErrorMessage $errorMessage `
            -LastAttemptUtc $attemptUtc

        Save-ResultsState -Lookup $ResultsLookup -Path $ResultsCsvPath

        if ($result -eq 'Success' -or $result -eq 'SuccessFromReplacementRule') {
            Write-Info "Successful title captured."
            Write-Info "Using Title: $title"
            $finalized = $true
            break
        }
        elseif ($result -eq 'GenericTitle') {
            Write-Info "GenericTitle detected and stored."

            if (-not $BehaviorConfig.AllowLaterCaptureFallback -or -not $BehaviorConfig.ContinueAfterGenericTitle) {
                $finalized = $true
                break
            }

            Write-Info "Continuing past GenericTitle due to DiscoveryBehavior."
        }
        else {
            Write-Info "Attempt result: $result"
        }

        if ($InterRequestDelayMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $InterRequestDelayMilliseconds
        }
    }

    if (-not $finalized) {
        if ($genericStored) {
            Write-Info "Finished URL with GenericTitle because no replacement rule succeeded."
        }
        else {
            Write-Info "Finished URL without Success."
        }
    }

    if ($InterRequestDelayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $InterRequestDelayMilliseconds
    }
}

Write-Host ""
Write-Info "Done."
Write-Info "Results CSV: $ResultsCsvPath"
Write-Info "Attempt log CSV: $AttemptLogPath"
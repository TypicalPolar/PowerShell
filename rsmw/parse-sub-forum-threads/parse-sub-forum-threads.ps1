[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputJsonPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputCsvPath,

    [ValidateSet('Normal', 'Moderate', 'Aggressive')]
    [string]$DiscoveryBehavior = 'Normal',

    [switch]$ForceRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------
# Path helpers
# -----------------------------
function Get-SiblingPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$Suffix
    )

    $directory = [System.IO.Path]::GetDirectoryName($BasePath)
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = (Get-Location).Path
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($BasePath)
    $extension = [System.IO.Path]::GetExtension($BasePath)

    return [System.IO.Path]::Combine($directory, "$baseName$Suffix$extension")
}

function Get-LogPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $directory = [System.IO.Path]::GetDirectoryName($BasePath)
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = (Get-Location).Path
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($BasePath)
    return [System.IO.Path]::Combine($directory, "$baseName.log.txt")
}

$ProgressCsvPath = Get-SiblingPath -BasePath $OutputCsvPath -Suffix '.progress'
$LogPath         = Get-LogPath -BasePath $OutputCsvPath

# -----------------------------
# Logging
# -----------------------------
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$timestamp] [$Level] $Message"

    Write-Host $line
    Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
}

# -----------------------------
# CSV / file writers
# -----------------------------
function Write-Utf8BomText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8Bom)
}

function Initialize-CsvFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$Columns
    )

    $headerLine = ($Columns -join ',') + [Environment]::NewLine
    Write-Utf8BomText -Path $Path -Text $headerLine
}

function Convert-ObjectsToCsvText {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$InputObjects
    )

    $csvLines = $InputObjects | ConvertTo-Csv -NoTypeInformation
    return (($csvLines -join [Environment]::NewLine) + [Environment]::NewLine)
}

# -----------------------------
# Text helpers
# -----------------------------
function Normalize-Whitespace {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) { return $null }

    $decoded = [System.Net.WebUtility]::HtmlDecode($Text)
    $decoded = $decoded -replace '&nbsp;', ' '
    $decoded = $decoded -replace '\s+', ' '
    $decoded = $decoded.Trim()

    if ([string]::IsNullOrWhiteSpace($decoded)) { return $null }
    return $decoded
}

function Strip-Html {
    param(
        [AllowNull()]
        [string]$Html
    )

    if ($null -eq $Html) { return $null }

    $text = $Html -replace '(?is)<br\s*/?>', "`n"
    $text = $text -replace '(?is)<[^>]+>', ' '
    return (Normalize-Whitespace -Text $text)
}

function Convert-ForumDateToIso {
    param(
        [AllowNull()]
        [string]$DateText
    )

    if ([string]::IsNullOrWhiteSpace($DateText)) { return $null }

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::None

    $formats = @(
        'dd-MMM-yyyy HH:mm:ss'
    )

    foreach ($format in $formats) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($DateText, $format, $culture, $styles, [ref]$parsed)) {
            return $parsed.ToString('yyyy-MM-dd HH:mm:ss')
        }
    }

    return $null
}

# -----------------------------
# URL helpers
# -----------------------------
function Remove-ForumUrlJunk {
    param(
        [AllowNull()]
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }

    $clean = $Url.Trim()
    $clean = $clean -replace '#.*$', ''
    $clean = $clean -replace ',goto,\d+$', ''
    $clean = $clean -replace ',goto,\d+.*$', ''

    return $clean
}

function Get-QuickFindCode {
    param(
        [AllowNull()]
        [string]$ForumUrl
    )

    if ([string]::IsNullOrWhiteSpace($ForumUrl)) { return $null }

    $clean = Remove-ForumUrlJunk -Url $ForumUrl

    if ($clean -match 'forums\.ws\?(?<qfc>.+)$') {
        return $matches['qfc']
    }

    return $null
}

function Resolve-ForumUrlAbsolute {
    param(
        [AllowNull()]
        [string]$RawForumUrl,

        [AllowNull()]
        [string]$OriginalUrl
    )

    if ([string]::IsNullOrWhiteSpace($RawForumUrl)) { return $null }

    $clean = Remove-ForumUrlJunk -Url $RawForumUrl

    if ($clean -match '^(?i)https?://') {
        return $clean
    }

    if ([string]::IsNullOrWhiteSpace($OriginalUrl)) {
        return $null
    }

    try {
        $baseUri = [System.Uri]::new($OriginalUrl)
        $resolved = [System.Uri]::new($baseUri, $clean)
        return $resolved.AbsoluteUri
    }
    catch {
        return $null
    }
}

function Get-SnapshotUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Timestamp,

        [Parameter(Mandatory = $true)]
        [string]$OriginalUrl
    )

    return "https://web.archive.org/web/$Timestamp/$OriginalUrl"
}

# -----------------------------
# Parsing helpers
# -----------------------------
function Parse-LastPostBlock {
    param(
        [AllowNull()]
        [string]$Html
    )

    $result = [ordered]@{
        last_update     = $null
        last_updated_by = $null
    }

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return [pscustomobject]$result
    }

    $dateMatch = [regex]::Match($Html, '(?i)(?<dt>\d{2}-[A-Za-z]{3}-\d{4}\s+\d{2}:\d{2}:\d{2})')
    if ($dateMatch.Success) {
        $result['last_update'] = $dateMatch.Groups['dt'].Value
    }

    $plain = Strip-Html -Html $Html
    if (-not [string]::IsNullOrWhiteSpace($plain)) {
        $byMatch = [regex]::Match($plain, '(?i)\bby\s+(?<user>.+)$')
        if ($byMatch.Success) {
            $result['last_updated_by'] = Normalize-Whitespace -Text $byMatch.Groups['user'].Value
        }
    }

    return [pscustomobject]$result
}

function Get-CreatorFromMatchedHtml {
    param(
        [AllowNull()]
        [string]$MatchedHtml,

        [Parameter(Mandatory = $true)]
        [ValidateSet('table_row', 'data_row', 'thread_plate')]
        [string]$Layout
    )

    if ([string]::IsNullOrWhiteSpace($MatchedHtml)) { return $null }

    switch ($Layout) {
        'table_row' {
            $creatorPattern = '(?is)created by\s*<span\b[^>]*class=["''][^"'']*\busername\b[^"'']*["''][^>]*>(?<creator>.*?)</span>'
            $creatorMatch = [regex]::Match($MatchedHtml, $creatorPattern)
            if ($creatorMatch.Success) {
                return Normalize-Whitespace -Text (Strip-Html -Html $creatorMatch.Groups['creator'].Value)
            }
        }
        'data_row' {
            $creatorPattern = '(?is)created by\s*<span\b[^>]*class=["''][^"'']*\busername\b[^"'']*["''][^>]*>(?<creator>.*?)</span>'
            $creatorMatch = [regex]::Match($MatchedHtml, $creatorPattern)
            if ($creatorMatch.Success) {
                return Normalize-Whitespace -Text (Strip-Html -Html $creatorMatch.Groups['creator'].Value)
            }
        }
        'thread_plate' {
            $creatorLinePattern = '(?is)<p\b[^>]*class=["''][^"'']*\bthread-plate__summary\b[^"'']*["''][^>]*>(?<creatorline>.*?)</p>'
            $creatorLineMatch = [regex]::Match($MatchedHtml, $creatorLinePattern)
            if ($creatorLineMatch.Success) {
                $creatorLine = Normalize-Whitespace -Text (Strip-Html -Html $creatorLineMatch.Groups['creatorline'].Value)
                if ($creatorLine -match '(?i)^created by\s+(?<user>.+)$') {
                    return Normalize-Whitespace -Text $matches['user']
                }
            }
        }
    }

    return $null
}

function Get-ParseAssessment {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Record
    )

    $expectedFields = @(
        'quick_find_code',
        'thread_name',
        'thread_creator',
        'last_update',
        'last_updated_by'
    )

    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($field in $expectedFields) {
        if (-not $Record.ContainsKey($field) -or [string]::IsNullOrWhiteSpace([string]$Record[$field])) {
            $missing.Add($field)
        }
    }

    if ($missing.Count -eq 0) {
        return [pscustomobject]@{
            parse_result   = 'success'
            missing_fields = $null
            parse_notes    = 'All core fields extracted.'
        }
    }

    $missingText = ($missing -join ', ')
    return [pscustomobject]@{
        parse_result   = 'partial'
        missing_fields = $missingText
        parse_notes    = "Missing expected fields: $missingText"
    }
}

function Parse-ThreadEntriesFromHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Html,

        [Parameter(Mandatory = $true)]
        [string]$SnapshotDate,

        [Parameter(Mandatory = $true)]
        [string]$SnapshotUrl,

        [Parameter(Mandatory = $true)]
        [string]$SourceOriginalUrl,

        [Parameter(Mandatory = $true)]
        [string]$SourceUrlKey,

        [Parameter(Mandatory = $true)]
        [int]$RowIndex
    )

    $results = New-Object System.Collections.Generic.List[object]
    $allMatches = New-Object System.Collections.Generic.List[object]

    $patterns = @(
        @{
            Layout  = 'table_row'
            Pattern = '(?is)<tr\b[^>]*class=["''][^"'']*\bthdnrml\b[^"'']*["''][^>]*>.*?<td\b[^>]*class=["''][^"'']*\bthreadtitle\b[^"'']*["''][^>]*>.*?<a\b[^>]*href=["''](?<href>[^"'']+)["''][^>]*>(?<title>.*?)</a>.*?</td>.*?<td\b[^>]*class=["''][^"'']*\bupdated\b[^"'']*["''][^>]*>(?<lastpost>.*?)</td>.*?</tr>'
        }
        @{
            Layout  = 'data_row'
            Pattern = '(?is)<span\b[^>]*class=["''][^"'']*\bdataRow\b[^"'']*["''][^>]*>\s*<a\b[^>]*href=["''](?<href>[^"'']+)["''][^>]*>.*?<h4>(?<title>.*?)</h4>.*?</a>\s*<span\b[^>]*class=["''][^"'']*\blastPost\b[^"'']*["''][^>]*>\s*<a\b[^>]*href=["''][^"'']+["''][^>]*>(?<lastpost>.*?)</a>\s*</span>\s*</span>'
        }
        @{
            Layout  = 'thread_plate'
            Pattern = '(?is)<article\b[^>]*class=["''][^"'']*\bthread-plate\b[^"'']*["''][^>]*>.*?<a\b[^>]*class=["''][^"'']*\bthread-plate__main-link\b[^"'']*["''][^>]*href=["''](?<href>[^"'']+)["''][^>]*>.*?<h3\b[^>]*class=["''][^"'']*\bthread-plate__title\b[^"'']*["''][^>]*>(?<title>.*?)</h3>.*?</a>.*?<a\b[^>]*class=["''][^"'']*\bthread-plate__last-post\b[^"'']*["''][^>]*>(?<lastpost>.*?)</a>.*?</article>'
        }
    )

    foreach ($entry in $patterns) {
        $regex = [regex]::new(
            $entry.Pattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )

        $regexMatches = $regex.Matches($Html)

        foreach ($m in $regexMatches) {
            $allMatches.Add([pscustomobject]@{
                Index  = $m.Index
                Layout = $entry.Layout
                Match  = $m
            })
        }
    }

    foreach ($item in ($allMatches | Sort-Object Index)) {
        $layout = $item.Layout
        $m = $item.Match
        $matchedHtml = $m.Value

        $href = Remove-ForumUrlJunk -Url $m.Groups['href'].Value
        $title = Normalize-Whitespace -Text (Strip-Html -Html $m.Groups['title'].Value)
        $creator = Get-CreatorFromMatchedHtml -MatchedHtml $matchedHtml -Layout $layout

        $lastPostData = Parse-LastPostBlock -Html $m.Groups['lastpost'].Value
        $forumUrlAbsolute = Resolve-ForumUrlAbsolute -RawForumUrl $href -OriginalUrl $SourceOriginalUrl
        $quickFindCode = Get-QuickFindCode -ForumUrl $href
        $lastUpdateIso = Convert-ForumDateToIso -DateText $lastPostData.last_update

        $record = [ordered]@{
            quick_find_code      = $quickFindCode
            thread_name          = $title
            thread_creator       = $creator
            last_update          = $lastPostData.last_update
            last_updated_by      = $lastPostData.last_updated_by
            snapshot_date        = $SnapshotDate
            last_update_iso      = $lastUpdateIso
            forum_url            = $href
            forum_url_absolute   = $forumUrlAbsolute
            snapshot_url         = $SnapshotUrl
            source_original_url  = $SourceOriginalUrl
            source_urlkey        = $SourceUrlKey
            layout_type          = $layout
            row_index            = $RowIndex
            parse_result         = $null
            missing_fields       = $null
            parse_notes          = $null
        }

        $assessment = Get-ParseAssessment -Record $record
        $record['parse_result']   = $assessment.parse_result
        $record['missing_fields'] = $assessment.missing_fields
        $record['parse_notes']    = $assessment.parse_notes

        $results.Add([pscustomobject]$record)
    }

    return $results
}

# -----------------------------
# Discovery behavior
# -----------------------------
function Test-RowAllowed {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Row,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Normal', 'Moderate', 'Aggressive')]
        [string]$Mode
    )

    $mimetype = [string]$Row['mimetype']
    $statuscode = [string]$Row['statuscode']

    switch ($Mode) {
        'Normal' {
            return ($mimetype -eq 'text/html' -and $statuscode -eq '200')
        }
        'Moderate' {
            $looksHtml = (
                [string]::IsNullOrWhiteSpace($mimetype) -or
                $mimetype -match '(?i)html'
            )

            $statusAllowed = (
                [string]::IsNullOrWhiteSpace($statuscode) -or
                $statuscode -match '^(200|30[12378])$'
            )

            return ($looksHtml -and $statusAllowed)
        }
        'Aggressive' {
            return $true
        }
    }

    return $false
}

# -----------------------------
# HTTP
# -----------------------------
function New-HttpClient {
    return $null
}

function Get-UrlContent {
    param(
        [Parameter(Mandatory = $false)]
        $Client,

        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $maxAttempts = 3
    $lastError = $null

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Start-Sleep -Milliseconds 250

            $response = Invoke-WebRequest `
                -Uri $Url `
                -UseBasicParsing `
                -TimeoutSec 30 `
                -Headers @{ 'User-Agent' = 'RunescapeForumSnapshotParser/1.0' } `
                -MaximumRedirection 10 `
                -ErrorAction Stop

            return $response.Content
        }
        catch {
            $lastError = $_
            Write-Log -Level 'WARN' -Message "Attempt $attempt failed for URL: $Url -- $($_.Exception.Message)"
            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Milliseconds 750
            }
        }
    }

    throw $lastError
}

# -----------------------------
# Progress helpers
# -----------------------------
function Get-ProgressColumns {
    return @(
        'row_index',
        'timestamp',
        'original',
        'snapshot_url',
        'discovery_behavior',
        'status',
        'thread_count',
        'started_at',
        'completed_at',
        'error_message',
        'notes'
    )
}

function Get-OutputColumns {
    return @(
        'quick_find_code',
        'thread_name',
        'thread_creator',
        'last_update',
        'last_updated_by',
        'snapshot_date',
        'last_update_iso',
        'forum_url',
        'forum_url_absolute',
        'snapshot_url',
        'source_original_url',
        'source_urlkey',
        'layout_type',
        'row_index',
        'parse_result',
        'missing_fields',
        'parse_notes'
    )
}

function Import-ProgressMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $map = @{}

    if (-not (Test-Path -LiteralPath $Path)) {
        return $map
    }

    $rows = Import-Csv -LiteralPath $Path
    foreach ($row in $rows) {
        $map[[int]$row.row_index] = $row
    }

    return $map
}

function Export-ProgressMap {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Map,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $orderedRows = $Map.GetEnumerator() |
        Sort-Object Key |
        ForEach-Object { $_.Value }

    $csvText = Convert-ObjectsToCsvText -InputObjects @($orderedRows)
    Write-Utf8BomText -Path $Path -Text $csvText
}

# -----------------------------
# Startup validation
# -----------------------------
if (-not (Test-Path -LiteralPath $InputJsonPath)) {
    throw "Input JSON file not found: $InputJsonPath"
}

$OutputExists = Test-Path -LiteralPath $OutputCsvPath
$ProgressExists = Test-Path -LiteralPath $ProgressCsvPath
$LogExists = Test-Path -LiteralPath $LogPath

if ($ForceRestart) {
    foreach ($path in @($OutputCsvPath, $ProgressCsvPath, $LogPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}
else {
    if ($ProgressExists -and -not $OutputExists) {
        throw "Progress file exists but output CSV does not. Use -ForceRestart or restore the output CSV.`nProgress: $ProgressCsvPath`nOutput:   $OutputCsvPath"
    }

    if ($OutputExists -and -not $ProgressExists) {
        throw "Output CSV exists but progress CSV does not. Use -ForceRestart or restore the progress CSV.`nOutput:   $OutputCsvPath`nProgress: $ProgressCsvPath"
    }
}

if (-not (Test-Path -LiteralPath $LogPath)) {
    New-Item -ItemType File -Path $LogPath -Force | Out-Null
}

$script:LogPath = $LogPath

Write-Log -Level 'INFO' -Message "Input JSON: $InputJsonPath"
Write-Log -Level 'INFO' -Message "Output CSV: $OutputCsvPath"
Write-Log -Level 'INFO' -Message "Progress CSV: $ProgressCsvPath"
Write-Log -Level 'INFO' -Message "Log file: $LogPath"
Write-Log -Level 'INFO' -Message "DiscoveryBehavior: $DiscoveryBehavior"
Write-Log -Level 'INFO' -Message ("Run mode: " + ($(if ($ForceRestart) { 'Fresh start (-ForceRestart)' } else { 'Resume by default' })))

if (-not (Test-Path -LiteralPath $OutputCsvPath)) {
    Initialize-CsvFile -Path $OutputCsvPath -Columns (Get-OutputColumns)
}

if (-not (Test-Path -LiteralPath $ProgressCsvPath)) {
    Initialize-CsvFile -Path $ProgressCsvPath -Columns (Get-ProgressColumns)
}

# -----------------------------
# Load input JSON
# -----------------------------
Write-Log -Level 'INFO' -Message 'Loading input JSON...'
$jsonText = Get-Content -LiteralPath $InputJsonPath -Raw -Encoding UTF8
$data = ConvertFrom-Json -InputObject $jsonText

if ($null -eq $data) {
    throw "Input JSON could not be parsed."
}

if ($data -isnot [System.Collections.IList]) {
    $data = @($data)
}

$dataCount = @($data).Count
if ($dataCount -lt 2) {
    throw "Input JSON does not appear to contain a header row plus data rows."
}

$header = @($data[0])
$requiredHeaders = @('urlkey', 'timestamp', 'original', 'mimetype', 'statuscode', 'digest', 'length')

foreach ($requiredHeader in $requiredHeaders) {
    if ($header -notcontains $requiredHeader) {
        throw "Missing required header in JSON: $requiredHeader"
    }
}

$headerIndex = @{}
for ($i = 0; $i -lt $header.Count; $i++) {
    $headerIndex[[string]$header[$i]] = $i
}

$dataRows = @($data | Select-Object -Skip 1)
Write-Log -Level 'INFO' -Message "Loaded $($dataRows.Count) data rows."

# -----------------------------
# Load progress state
# -----------------------------
$progressMap = Import-ProgressMap -Path $ProgressCsvPath

$terminalStatuses = @(
    'Complete',
    'CompleteWithPartials',
    'NoThreadsFound',
    'SkippedByDiscovery'
)

$httpClient = New-HttpClient

try {
    for ($rowIndex = 0; $rowIndex -lt $dataRows.Count; $rowIndex++) {
        if ($progressMap.ContainsKey($rowIndex)) {
            $existingStatus = [string]$progressMap[$rowIndex].status
            if ($terminalStatuses -contains $existingStatus) {
                Write-Log -Level 'INFO' -Message "Skipping already completed row_index=$rowIndex (status=$existingStatus)"
                continue
            }
        }

        $rowArray = @($dataRows[$rowIndex])
        $row = @{
            urlkey     = [string]$rowArray[$headerIndex['urlkey']]
            timestamp  = [string]$rowArray[$headerIndex['timestamp']]
            original   = [string]$rowArray[$headerIndex['original']]
            mimetype   = [string]$rowArray[$headerIndex['mimetype']]
            statuscode = [string]$rowArray[$headerIndex['statuscode']]
            digest     = [string]$rowArray[$headerIndex['digest']]
            length     = [string]$rowArray[$headerIndex['length']]
        }

        $snapshotUrl = Get-SnapshotUrl -Timestamp $row.timestamp -OriginalUrl $row.original
        $startedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

        Write-Log -Level 'INFO' -Message "[$rowIndex/$($dataRows.Count - 1)] Processing snapshot: $snapshotUrl"

        try {
            if (-not (Test-RowAllowed -Row $row -Mode $DiscoveryBehavior)) {
                Write-Log -Level 'INFO' -Message "Row $rowIndex skipped by DiscoveryBehavior=$DiscoveryBehavior (mimetype=$($row.mimetype), statuscode=$($row.statuscode))"

                $progressMap[$rowIndex] = [pscustomobject][ordered]@{
                    row_index          = $rowIndex
                    timestamp          = $row.timestamp
                    original           = $row.original
                    snapshot_url       = $snapshotUrl
                    discovery_behavior = $DiscoveryBehavior
                    status             = 'SkippedByDiscovery'
                    thread_count       = 0
                    started_at         = $startedAt
                    completed_at       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    error_message      = $null
                    notes              = "Skipped by discovery filters. mimetype=$($row.mimetype); statuscode=$($row.statuscode)"
                }

                Export-ProgressMap -Map $progressMap -Path $ProgressCsvPath
                continue
            }

            try {
                $html = Get-UrlContent -Client $httpClient -Url $snapshotUrl
            }
            catch {
                Write-Log -Level 'ERROR' -Message "Fetch failed for row $rowIndex -- $($_.Exception.Message)"

                $progressMap[$rowIndex] = [pscustomobject][ordered]@{
                    row_index          = $rowIndex
                    timestamp          = $row.timestamp
                    original           = $row.original
                    snapshot_url       = $snapshotUrl
                    discovery_behavior = $DiscoveryBehavior
                    status             = 'FetchFailed'
                    thread_count       = 0
                    started_at         = $startedAt
                    completed_at       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    error_message      = $_.Exception.Message
                    notes              = 'HTTP fetch failed.'
                }

                Export-ProgressMap -Map $progressMap -Path $ProgressCsvPath
                continue
            }

            try {
                $threadRecords = @(Parse-ThreadEntriesFromHtml `
                    -Html $html `
                    -SnapshotDate $row.timestamp `
                    -SnapshotUrl $snapshotUrl `
                    -SourceOriginalUrl $row.original `
                    -SourceUrlKey $row.urlkey `
                    -RowIndex $rowIndex)
            }
            catch {
                Write-Log -Level 'ERROR' -Message "Parse failed for row $rowIndex -- $($_.Exception.Message)"

                $progressMap[$rowIndex] = [pscustomobject][ordered]@{
                    row_index          = $rowIndex
                    timestamp          = $row.timestamp
                    original           = $row.original
                    snapshot_url       = $snapshotUrl
                    discovery_behavior = $DiscoveryBehavior
                    status             = 'ParseFailed'
                    thread_count       = 0
                    started_at         = $startedAt
                    completed_at       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    error_message      = $_.Exception.Message
                    notes              = 'HTML parsing failed.'
                }

                Export-ProgressMap -Map $progressMap -Path $ProgressCsvPath
                continue
            }

            if ($threadRecords.Count -eq 0) {
                Write-Log -Level 'WARN' -Message "No supported thread containers found for row $rowIndex."

                $progressMap[$rowIndex] = [pscustomobject][ordered]@{
                    row_index          = $rowIndex
                    timestamp          = $row.timestamp
                    original           = $row.original
                    snapshot_url       = $snapshotUrl
                    discovery_behavior = $DiscoveryBehavior
                    status             = 'NoThreadsFound'
                    thread_count       = 0
                    started_at         = $startedAt
                    completed_at       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    error_message      = $null
                    notes              = 'Snapshot fetched successfully, but no supported thread containers were found.'
                }

                Export-ProgressMap -Map $progressMap -Path $ProgressCsvPath
                continue
            }

            foreach ($record in $threadRecords) {
                $record | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Append -Encoding UTF8

                $titleForLog = if ([string]::IsNullOrWhiteSpace($record.thread_name)) { '<no title>' } else { $record.thread_name }
                Write-Log -Level 'INFO' -Message "Captured thread: $titleForLog"
            }

            $partialCount = @($threadRecords | Where-Object { $_.parse_result -eq 'partial' }).Count
            $status = if ($partialCount -gt 0) { 'CompleteWithPartials' } else { 'Complete' }

            Write-Log -Level 'INFO' -Message "Row $rowIndex complete. Extracted $($threadRecords.Count) thread(s); partials=$partialCount"

            $progressMap[$rowIndex] = [pscustomobject][ordered]@{
                row_index          = $rowIndex
                timestamp          = $row.timestamp
                original           = $row.original
                snapshot_url       = $snapshotUrl
                discovery_behavior = $DiscoveryBehavior
                status             = $status
                thread_count       = $threadRecords.Count
                started_at         = $startedAt
                completed_at       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                error_message      = $null
                notes              = if ($partialCount -gt 0) { "Completed with $partialCount partial thread row(s)." } else { 'Completed successfully.' }
            }

            Export-ProgressMap -Map $progressMap -Path $ProgressCsvPath
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Log -Level 'ERROR' -Message "Unhandled row failure for row $rowIndex -- $errorMessage"

            $progressMap[$rowIndex] = [pscustomobject][ordered]@{
                row_index          = $rowIndex
                timestamp          = $row.timestamp
                original           = $row.original
                snapshot_url       = $snapshotUrl
                discovery_behavior = $DiscoveryBehavior
                status             = 'UnhandledRowFailure'
                thread_count       = 0
                started_at         = $startedAt
                completed_at       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                error_message      = $errorMessage
                notes              = 'Unhandled exception during row processing.'
            }

            Export-ProgressMap -Map $progressMap -Path $ProgressCsvPath
            continue
        }
    }

    Write-Log -Level 'INFO' -Message 'Run completed.'
}
finally {
    if ($null -ne $httpClient -and $httpClient -is [System.IDisposable]) {
        $httpClient.Dispose()
    }
}
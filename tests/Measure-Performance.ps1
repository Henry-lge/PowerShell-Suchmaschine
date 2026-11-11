using module "../src/Persistence/DateiRepository.psm1"
using module "../src/Persistence/SqliteDateiRepository.psm1"
using module "../src/Crawler/Crawler.psm1"
using module "../src/DocScanner/DocScanner.psm1"
using module "../src/Model/Datei.psm1"
using module "../src/Common/PathUtil.psm1"

#requires -Version 7.2

param(
    [Parameter(Mandatory)]
    [string]$RootPath,

    [ValidateRange(1, 100000)]
    [int]$Iterations = 100,

    [ValidateRange(0, 1000)]
    [int]$WarmupRuns = 3,

    [ValidateRange(1, 10000)]
    [int]$SaveBatchSize = 200,

    [string]$SearchQuery = "benchmarktoken",

    [string]$CsvPath = (
        Join-Path ([System.IO.Path]::GetTempPath()) (
            "Suchmaschine-Benchmark-{0}.csv" -f (
                [datetime]::Now.ToString("yyyyMMdd-HHmmss") + "-" +
                [guid]::NewGuid().ToString("N")
            )
        )
    )
)

class TimingRepository : DateiRepository {
    [SqliteDateiRepository]$Inner

    [double]$GetMilliseconds
    [long]$GetCalls
    [double]$SaveBatchMilliseconds
    [long]$SaveBatchCalls
    [double]$RemoveMilliseconds
    [long]$RemoveCalls
    [double]$GetPathsUnderMilliseconds
    [long]$GetPathsUnderCalls

    hidden [double] GetElapsedMilliseconds([long]$startTimestamp) {
        return (
            ([System.Diagnostics.Stopwatch]::GetTimestamp() - $startTimestamp) *
            1000.0 / [System.Diagnostics.Stopwatch]::Frequency
        )
    }

    TimingRepository([SqliteDateiRepository]$inner) {
        $this.Inner = $inner
    }

    [void] ResetTimings() {
        $this.GetMilliseconds = 0
        $this.GetCalls = 0
        $this.SaveBatchMilliseconds = 0
        $this.SaveBatchCalls = 0
        $this.RemoveMilliseconds = 0
        $this.RemoveCalls = 0
        $this.GetPathsUnderMilliseconds = 0
        $this.GetPathsUnderCalls = 0
    }

    [Datei] Get([string]$path) {
        $startTimestamp = [System.Diagnostics.Stopwatch]::GetTimestamp()
        try {
            return $this.Inner.Get($path)
        }
        finally {
            $this.GetMilliseconds += $this.GetElapsedMilliseconds($startTimestamp)
            $this.GetCalls++
        }
    }

    [System.Collections.Generic.Dictionary[string, Datei]] GetMany([string[]]$paths) {
        return $this.Inner.GetMany($paths)
    }

    [void] Save([Datei]$datei) {
        $this.Inner.Save($datei)
    }

    [void] SaveBatch([Datei[]]$dateien) {
        $startTimestamp = [System.Diagnostics.Stopwatch]::GetTimestamp()
        try {
            $this.Inner.SaveBatch($dateien)
        }
        finally {
            $this.SaveBatchMilliseconds += $this.GetElapsedMilliseconds($startTimestamp)
            $this.SaveBatchCalls++
        }
    }

    [void] Remove([string]$path) {
        $startTimestamp = [System.Diagnostics.Stopwatch]::GetTimestamp()
        try {
            $this.Inner.Remove($path)
        }
        finally {
            $this.RemoveMilliseconds += $this.GetElapsedMilliseconds($startTimestamp)
            $this.RemoveCalls++
        }
    }

    [void] RemoveBatch([string[]]$paths) {
        $this.Inner.RemoveBatch($paths)
    }

    [string[]] GetPathsUnder([string]$folderPath) {
        $startTimestamp = [System.Diagnostics.Stopwatch]::GetTimestamp()
        try {
            return $this.Inner.GetPathsUnder($folderPath)
        }
        finally {
            $this.GetPathsUnderMilliseconds += $this.GetElapsedMilliseconds($startTimestamp)
            $this.GetPathsUnderCalls++
        }
    }
}

class TimingDocScanner : DocScanner {
    [double]$ReadContentMilliseconds
    [long]$ReadContentCalls

    [void] ResetTimings() {
        $this.ReadContentMilliseconds = 0
        $this.ReadContentCalls = 0
    }

    [string] ReadContent([System.IO.FileInfo]$file) {
        $startTimestamp = [System.Diagnostics.Stopwatch]::GetTimestamp()
        try {
            return ([DocScanner]$this).ReadContent($file)
        }
        finally {
            $this.ReadContentMilliseconds += (
                ([System.Diagnostics.Stopwatch]::GetTimestamp() - $startTimestamp) *
                1000.0 / [System.Diagnostics.Stopwatch]::Frequency
            )
            $this.ReadContentCalls++
        }
    }
}

function New-TimedCrawler {
    param(
        [Parameter(Mandatory)]
        [TimingRepository]$Repository,

        [Parameter(Mandatory)]
        [int]$BatchSize,

        [Parameter(Mandatory)]
        [string]$ExcludedPath
    )

    $crawler = [Crawler]::new()
    $crawler.Repository = $Repository
    $crawler.DocScanner = [TimingDocScanner]::new()
    $crawler.SaveBatchSize = $BatchSize
    $crawler.CollectFiles = $false
    $crawler.ExcludedPaths = @($ExcludedPath)
    $crawler.ProgressOutput = $false
    $crawler.WarningOutput = $false
    $crawler.VerboseOutput = $false
    return $crawler
}

function Invoke-TimedScan {
    param(
        [TimingRepository]$Repository,
        [int]$BatchSize,
        [string]$ExcludedPath,
        [string]$RootPath
    )

    $crawler = New-TimedCrawler $Repository $BatchSize $ExcludedPath
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $crawler.ScanFolder($RootPath)
    $timer.Stop()
    return [PSCustomObject]@{
        ElapsedMilliseconds = $timer.Elapsed.TotalMilliseconds
        Summary = $crawler.GetSummary()
        DocScanner = $crawler.DocScanner
    }
}

function Add-Measurement {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Rows,

        [Parameter(Mandatory)]
        [int]$Iteration,

        [Parameter(Mandatory)]
        [string]$Scenario,

        [Parameter(Mandatory)]
        [string]$Stage,

        [Parameter(Mandatory)]
        [double]$ElapsedMilliseconds,

        [long]$CallCount = 1,

        [long]$ItemCount = 0,

        [int]$ScannedFiles = 0,

        [int]$FailedFiles = 0,

        [int]$Errors = 0
    )

    $Rows.Add([PSCustomObject][ordered]@{
        Iteration = $Iteration
        Scenario = $Scenario
        Stage = $Stage
        ElapsedMs = $ElapsedMilliseconds
        CallCount = $CallCount
        ItemCount = $ItemCount
        ScannedFiles = $ScannedFiles
        FailedFiles = $FailedFiles
        Errors = $Errors
    })
}

function Add-ScanMeasurements {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]]$Rows,

        [Parameter(Mandatory)]
        [int]$Iteration,

        [Parameter(Mandatory)]
        [string]$Scenario,

        [Parameter(Mandatory)]
        [double]$ElapsedMilliseconds,

        [Parameter(Mandatory)]
        [object]$Summary,

        [Parameter(Mandatory)]
        [TimingRepository]$Repository,

        [Parameter(Mandatory)]
        [TimingDocScanner]$DocScanner
    )

    $scannedFiles = $Summary.ScannedFiles
    $otherCrawlerMilliseconds = [Math]::Max(
        0,
        $ElapsedMilliseconds -
        $Repository.GetMilliseconds -
        $Repository.SaveBatchMilliseconds -
        $Repository.RemoveMilliseconds -
        $Repository.GetPathsUnderMilliseconds -
        $DocScanner.ReadContentMilliseconds
    )

    $phases = @(
        @{ Stage = "Crawler gesamt"; Ms = $ElapsedMilliseconds; Calls = 1; Items = $scannedFiles }
        @{ Stage = "DB Lesen: Get"; Ms = $Repository.GetMilliseconds; Calls = $Repository.GetCalls; Items = $scannedFiles }
        @{ Stage = "DB Schreiben: SaveBatch"; Ms = $Repository.SaveBatchMilliseconds; Calls = $Repository.SaveBatchCalls; Items = $Summary.NewFiles }
        @{ Stage = "DB Löschen: Remove"; Ms = $Repository.RemoveMilliseconds; Calls = $Repository.RemoveCalls; Items = $Summary.DeletedFiles }
        @{ Stage = "DB Ordnerabfrage"; Ms = $Repository.GetPathsUnderMilliseconds; Calls = $Repository.GetPathsUnderCalls; Items = $Summary.DeletedFiles }
        @{ Stage = "DocScanner: Inhalt lesen"; Ms = $DocScanner.ReadContentMilliseconds; Calls = $DocScanner.ReadContentCalls; Items = $Summary.ContentFilesRead }
        @{ Stage = "Crawler: übrige Arbeit"; Ms = $otherCrawlerMilliseconds; Calls = 1; Items = $scannedFiles }
    )
    foreach ($phase in $phases) {
        Add-Measurement $Rows $Iteration $Scenario $phase.Stage $phase.Ms `
            $phase.Calls $phase.Items $scannedFiles $Summary.FailedFiles $Summary.Errors
    }
}

function Get-TimeSummary {
    param(
        [object[]]$Measurements,
        [string]$Scenario,
        [string]$Stage
    )

    $values = @(
        $Measurements |
            Where-Object { $_.Scenario -eq $Scenario -and $_.Stage -eq $Stage } |
            ForEach-Object { [double]$_.ElapsedMs } |
            Sort-Object
    )
    if ($values.Count -eq 0) {
        return $null
    }

    $middle = [int][Math]::Floor($values.Count / 2)
    $median = [double]$values[$middle]
    if ($values.Count % 2 -eq 0) {
        $median = ($median + [double]$values[$middle - 1]) / 2
    }

    $p95Index = [int][Math]::Ceiling($values.Count * 0.95) - 1
    return [PSCustomObject]@{
        Count = $values.Count
        Median = $median
        P95 = [double]$values[$p95Index]
    }
}

function Add-DatabaseMeasurements {
    param(
        [SqliteDateiRepository]$Database,
        [string]$RootPath,
        [string]$Query,
        [System.Collections.Generic.List[object]]$Rows,
        [int]$Iteration,
        [string]$Scenario,
        [int]$ScannedFiles,
        [bool]$Record = $true
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $paths = $Database.GetPathsUnder($RootPath)
    $timer.Stop()
    if ($Record) {
        Add-Measurement $Rows $Iteration $Scenario "SQLite: GetPathsUnder" `
            $timer.Elapsed.TotalMilliseconds 1 $paths.Count $ScannedFiles
    }

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $results = @(Search-Query -Database $Database -Query $Query -Limit 100)
    $timer.Stop()
    if ($Record) {
        Add-Measurement $Rows $Iteration $Scenario "SQLite: Search-Query" `
            $timer.Elapsed.TotalMilliseconds 1 $results.Count $ScannedFiles
    }

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $files = $Database.GetMany($paths)
    $timer.Stop()
    if ($Record) {
        Add-Measurement $Rows $Iteration $Scenario "SQLite: GetMany" `
            $timer.Elapsed.TotalMilliseconds 1 $files.Count $ScannedFiles
    }

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $Database.RemoveBatch($paths)
    $timer.Stop()
    if ($Record) {
        Add-Measurement $Rows $Iteration $Scenario "SQLite: RemoveBatch" `
            $timer.Elapsed.TotalMilliseconds 1 $paths.Count $ScannedFiles
    }
}

$normalizedRoot = [System.IO.Path]::GetFullPath($RootPath)
if (-not [System.IO.Directory]::Exists($normalizedRoot)) {
    throw "Scan root does not exist or is inaccessible: $normalizedRoot"
}
if ([string]::IsNullOrWhiteSpace($SearchQuery)) {
    throw "SearchQuery must not be empty."
}
if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    throw "CsvPath must not be empty."
}
$fullCsvPath = [System.IO.Path]::GetFullPath($CsvPath)
if (
    $PSBoundParameters.ContainsKey("CsvPath") -and
    [PathUtil]::IsSameOrUnder($fullCsvPath, $normalizedRoot)
) {
    throw "CsvPath must be outside the scan root."
}

$scratchDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
    "powershell-suchmaschine-benchmark-" + [guid]::NewGuid().ToString("N")
)
[System.IO.Directory]::CreateDirectory($scratchDirectory) | Out-Null
$databasePath = $null
$database = $null
$rows = [System.Collections.Generic.List[object]]::new()

try {
    $totalRuns = $WarmupRuns + $Iterations
    $lastScannedFiles = 0

    for ($run = 1; $run -le $totalRuns; $run++) {
        $isWarmup = $run -le $WarmupRuns
        $iteration = $run - $WarmupRuns
        $runDirectory = Join-Path $scratchDirectory "run-$run"
        [System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null
        $databasePath = Join-Path $runDirectory "benchmark.sqlite3"
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $database = Initialize-Database -DatabasePath $databasePath
        $timer.Stop()
        if (-not $isWarmup) {
            Add-Measurement $rows $iteration "Leere Datenbank" "Initialize-Database" `
                $timer.Elapsed.TotalMilliseconds
        }

        $repository = [TimingRepository]::new($database)
        Add-DatabaseMeasurements $database $normalizedRoot $SearchQuery $rows `
            $iteration "Leere Datenbank" 0 (-not $isWarmup)

        $repository.ResetTimings()
        $scan = Invoke-TimedScan $repository $SaveBatchSize $scratchDirectory $normalizedRoot
        $summary = $scan.Summary
        if (-not $isWarmup) {
            $lastScannedFiles = $summary.ScannedFiles
            Add-ScanMeasurements $rows $iteration "Leere Datenbank" `
                $scan.ElapsedMilliseconds $summary $repository $scan.DocScanner
        }

        $database.Dispose()
        $database = $null
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $database = Initialize-Database -DatabasePath $databasePath
        $timer.Stop()
        if (-not $isWarmup) {
            Add-Measurement $rows $iteration "Gefuellte Datenbank" "Initialize-Database" `
                $timer.Elapsed.TotalMilliseconds
        }
        $repository = [TimingRepository]::new($database)

        $repository.ResetTimings()
        $scan = Invoke-TimedScan $repository $SaveBatchSize $scratchDirectory $normalizedRoot
        $summary = $scan.Summary
        if (-not $isWarmup) {
            $lastScannedFiles = $summary.ScannedFiles
            Add-ScanMeasurements $rows $iteration "Gefuellte Datenbank" `
                $scan.ElapsedMilliseconds $summary $repository $scan.DocScanner
        }
        Add-DatabaseMeasurements $database $normalizedRoot $SearchQuery $rows `
            $iteration "Gefuellte Datenbank" $lastScannedFiles (-not $isWarmup)

        $database.Dispose()
        $database = $null
        [System.IO.Directory]::Delete($runDirectory, $true)
    }

    $csvParent = [System.IO.Path]::GetDirectoryName(
        [System.IO.Path]::GetFullPath($CsvPath)
    )
    if (-not [System.IO.Directory]::Exists($csvParent)) {
        [System.IO.Directory]::CreateDirectory($csvParent) | Out-Null
    }
    $csvRows = foreach ($row in $rows) {
        [PSCustomObject][ordered]@{
            Iteration = $row.Iteration
            Scenario = $row.Scenario
            Stage = $row.Stage
            ElapsedMs = $row.ElapsedMs.ToString(
                "R",
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            CallCount = $row.CallCount
            ItemCount = $row.ItemCount
            ScannedFiles = $row.ScannedFiles
            FailedFiles = $row.FailedFiles
            Errors = $row.Errors
        }
    }
    $csvRows | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding utf8

    $summaryRows = foreach ($group in ($rows | Group-Object Scenario, Stage)) {
        $summary = Get-TimeSummary $group.Group $group.Group[0].Scenario $group.Group[0].Stage
        [PSCustomObject]@{
            Datenbank = $group.Group[0].Scenario
            Komponente = $group.Group[0].Stage
            Laeufe = $summary.Count
            Median_ms = [Math]::Round($summary.Median, 2)
            P95_ms = [Math]::Round($summary.P95, 2)
            Aufrufe_je_Lauf = [Math]::Round(
                ($group.Group | Measure-Object -Property CallCount -Average).Average, 1
            )
            Elemente_je_Lauf = [Math]::Round(
                ($group.Group | Measure-Object -Property ItemCount -Average).Average, 1
            )
        }
    }

    Write-Host ("Komponenten je Datenbankzustand; Messlaeufe: {0}, Warm-ups: {1}" -f
        $Iterations, $WarmupRuns)
    Write-Host "Zeiten in ms (Median / P95); Aufrufe und Elemente sind Mittelwerte je Lauf:"
    $summaryRows | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host ("Scan-Dateien: {0}; Suchbegriff: {1}; Rohdaten: {2}" -f
        $lastScannedFiles, $SearchQuery, [System.IO.Path]::GetFullPath($CsvPath))
}
finally {
    if ($null -ne $database) {
        $database.Dispose()
    }

    if ([System.IO.Directory]::Exists($scratchDirectory)) {
        [System.IO.Directory]::Delete($scratchDirectory, $true)
    }
}

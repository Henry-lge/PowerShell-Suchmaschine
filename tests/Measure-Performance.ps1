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
    [double]$GetManyMilliseconds
    [long]$GetManyCalls
    [double]$SaveMilliseconds
    [long]$SaveCalls
    [double]$SaveBatchMilliseconds
    [long]$SaveBatchCalls
    [double]$RemoveMilliseconds
    [long]$RemoveCalls
    [double]$RemoveBatchMilliseconds
    [long]$RemoveBatchCalls
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
        $this.GetManyMilliseconds = 0
        $this.GetManyCalls = 0
        $this.SaveMilliseconds = 0
        $this.SaveCalls = 0
        $this.SaveBatchMilliseconds = 0
        $this.SaveBatchCalls = 0
        $this.RemoveMilliseconds = 0
        $this.RemoveCalls = 0
        $this.RemoveBatchMilliseconds = 0
        $this.RemoveBatchCalls = 0
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
        $startTimestamp = [System.Diagnostics.Stopwatch]::GetTimestamp()
        try {
            return $this.Inner.GetMany($paths)
        }
        finally {
            $this.GetManyMilliseconds += $this.GetElapsedMilliseconds($startTimestamp)
            $this.GetManyCalls++
        }
    }

    [void] Save([Datei]$datei) {
        $startTimestamp = [System.Diagnostics.Stopwatch]::GetTimestamp()
        try {
            $this.Inner.Save($datei)
        }
        finally {
            $this.SaveMilliseconds += $this.GetElapsedMilliseconds($startTimestamp)
            $this.SaveCalls++
        }
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
        $startTimestamp = [System.Diagnostics.Stopwatch]::GetTimestamp()
        try {
            $this.Inner.RemoveBatch($paths)
        }
        finally {
            $this.RemoveBatchMilliseconds += $this.GetElapsedMilliseconds($startTimestamp)
            $this.RemoveBatchCalls++
        }
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
            return base.ReadContent($file)
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

function Get-Percentile {
    param(
        [Parameter(Mandatory)]
        [double[]]$Values,

        [Parameter(Mandatory)]
        [double]$Percentile
    )

    $sorted = @($Values | Sort-Object)
    if ($Percentile -eq 50 -and $sorted.Count % 2 -eq 0) {
        $middle = [int]($sorted.Count / 2)
        return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
    }

    $index = [int][Math]::Max(
        0,
        [Math]::Ceiling($Percentile / 100 * $sorted.Count) - 1
    )
    return [double]$sorted[$index]
}

function Get-MeasurementSummary {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]]$Rows
    )

    $summary = [System.Collections.Generic.List[object]]::new()
    foreach ($group in ($Rows | Group-Object Scenario, Stage)) {
        $values = [double[]]@($group.Group | ForEach-Object { $_.ElapsedMs })
        $mean = ($values | Measure-Object -Average).Average
        $sumOfSquares = 0.0
        foreach ($value in $values) {
            $sumOfSquares += [Math]::Pow($value - $mean, 2)
        }
        $standardDeviation = 0.0
        if ($values.Count -gt 1) {
            $standardDeviation = [Math]::Sqrt($sumOfSquares / ($values.Count - 1))
        }

        $calls = [long](($group.Group | Measure-Object -Property CallCount -Sum).Sum)
        $meanPerCall = 0.0
        if ($calls -gt 0) {
            $meanPerCall = (
                [double](($group.Group | Measure-Object -Property ElapsedMs -Sum).Sum) /
                $calls
            )
        }

        $scenario = $group.Group[0].Scenario
        $totalRows = @(
            $Rows | Where-Object {
                $_.Scenario -eq $scenario -and $_.Stage -eq "Crawler gesamt"
            }
        )
        $shareOfCrawlerPercent = $null
        if ($totalRows.Count -gt 0) {
            $meanCrawlerMilliseconds = (
                $totalRows | Measure-Object -Property ElapsedMs -Average
            ).Average
            if ($meanCrawlerMilliseconds -gt 0) {
                $shareOfCrawlerPercent = 100 * $mean / $meanCrawlerMilliseconds
            }
        }

        $summary.Add([PSCustomObject][ordered]@{
            Szenario = $scenario
            Messpunkt = $group.Group[0].Stage
            N = $values.Count
            Mittel_ms = $mean
            Median_ms = Get-Percentile -Values $values -Percentile 50
            P95_ms = Get-Percentile -Values $values -Percentile 95
            SD_ms = $standardDeviation
            Min_ms = ($values | Measure-Object -Minimum).Minimum
            Max_ms = ($values | Measure-Object -Maximum).Maximum
            Mittel_je_Aufruf_ms = $meanPerCall
            Anteil_Crawler_prozent = $shareOfCrawlerPercent
        })
    }

    return $summary.ToArray()
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
$databasePath = Join-Path $scratchDirectory "benchmark.sqlite3"
$database = $null
$rows = [System.Collections.Generic.List[object]]::new()

try {
    $initializationTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $database = Initialize-Database -DatabasePath $databasePath
    $initializationTimer.Stop()

    $repository = [TimingRepository]::new($database)
    $totalRuns = $WarmupRuns + $Iterations
    $lastScannedFiles = 0

    for ($run = 1; $run -le $totalRuns; $run++) {
        $isWarmup = $run -le $WarmupRuns
        $iteration = $run - $WarmupRuns
        $repository.ResetTimings()
        $crawler = New-TimedCrawler -Repository $repository -BatchSize $SaveBatchSize `
            -ExcludedPath $scratchDirectory
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $crawler.ScanFolder($normalizedRoot)
        $timer.Stop()

        $summary = $crawler.GetSummary()
        $timings = [PSCustomObject]@{
            RepositoryGet = $repository.GetMilliseconds
            RepositoryGetCalls = $repository.GetCalls
            SaveBatch = $repository.SaveBatchMilliseconds
            SaveBatchCalls = $repository.SaveBatchCalls
            Remove = $repository.RemoveMilliseconds
            RemoveCalls = $repository.RemoveCalls
            GetPathsUnder = $repository.GetPathsUnderMilliseconds
            GetPathsUnderCalls = $repository.GetPathsUnderCalls
            ReadContent = $crawler.DocScanner.ReadContentMilliseconds
            ReadContentCalls = $crawler.DocScanner.ReadContentCalls
        }
        $otherCrawlerMilliseconds = [Math]::Max(
            0,
            $timer.Elapsed.TotalMilliseconds -
            $timings.RepositoryGet -
            $timings.SaveBatch -
            $timings.Remove -
            $timings.GetPathsUnder -
            $timings.ReadContent
        )

        if (-not $isWarmup) {
            $lastScannedFiles = $summary.ScannedFiles
            $scenario = "Indexierung"
            Add-Measurement $rows $iteration $scenario "Crawler gesamt" `
                $timer.Elapsed.TotalMilliseconds 1 $summary.ScannedFiles `
                $summary.ScannedFiles $summary.FailedFiles $summary.Errors
            Add-Measurement $rows $iteration $scenario "DB Lesen: Get" `
                $timings.RepositoryGet $timings.RepositoryGetCalls $summary.ScannedFiles `
                $summary.ScannedFiles $summary.FailedFiles $summary.Errors
            Add-Measurement $rows $iteration $scenario "DB Schreiben: SaveBatch" `
                $timings.SaveBatch $timings.SaveBatchCalls $summary.NewFiles `
                $summary.ScannedFiles $summary.FailedFiles $summary.Errors
            Add-Measurement $rows $iteration $scenario "DB Löschen: Remove" `
                $timings.Remove $timings.RemoveCalls $summary.DeletedFiles `
                $summary.ScannedFiles $summary.FailedFiles $summary.Errors
            Add-Measurement $rows $iteration $scenario "DB Ordnerabfrage" `
                $timings.GetPathsUnder $timings.GetPathsUnderCalls $summary.DeletedFiles `
                $summary.ScannedFiles $summary.FailedFiles $summary.Errors
            Add-Measurement $rows $iteration $scenario "DocScanner: Inhalt lesen" `
                $timings.ReadContent $timings.ReadContentCalls $summary.ContentFilesRead `
                $summary.ScannedFiles $summary.FailedFiles $summary.Errors
            Add-Measurement $rows $iteration $scenario "Crawler: übrige Arbeit" `
                $otherCrawlerMilliseconds 1 $summary.ScannedFiles `
                $summary.ScannedFiles $summary.FailedFiles $summary.Errors
        }

        $repository.ResetTimings()
        $crawler = New-TimedCrawler -Repository $repository -BatchSize $SaveBatchSize `
            -ExcludedPath $scratchDirectory
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $crawler.ScanFolder($normalizedRoot)
        $timer.Stop()

        $summary = $crawler.GetSummary()
        $otherCrawlerMilliseconds = [Math]::Max(
            0,
            $timer.Elapsed.TotalMilliseconds -
            $repository.GetMilliseconds -
            $repository.SaveBatchMilliseconds -
            $repository.RemoveMilliseconds -
            $repository.GetPathsUnderMilliseconds -
            $crawler.DocScanner.ReadContentMilliseconds
        )

        if (-not $isWarmup) {
            $lastScannedFiles = $summary.ScannedFiles
            $scenario = "Unveraenderter Rescan"
            Add-Measurement $rows $iteration $scenario "Crawler gesamt" `
                $timer.Elapsed.TotalMilliseconds 1 $summary.ScannedFiles `
                $summary.ScannedFiles $summary.FailedFiles $summary.Errors
            Add-Measurement $rows $iteration $scenario "DB Lesen: Get" `
                $repository.GetMilliseconds $repository.GetCalls $summary.ScannedFiles `
                $summary.ScannedFiles $summary.FailedFiles $summary.Errors
            Add-Measurement $rows $iteration $scenario "DB Schreiben: SaveBatch" `
                $repository.SaveBatchMilliseconds $repository.SaveBatchCalls 0 `
                $summary.ScannedFiles $summary.FailedFiles $summary.Errors
            Add-Measurement $rows $iteration $scenario "DB Löschen: Remove" `
                $repository.RemoveMilliseconds $repository.RemoveCalls `
                $summary.DeletedFiles $summary.ScannedFiles $summary.FailedFiles `
                $summary.Errors
            Add-Measurement $rows $iteration $scenario "DB Ordnerabfrage" `
                $repository.GetPathsUnderMilliseconds $repository.GetPathsUnderCalls `
                $summary.DeletedFiles $summary.ScannedFiles $summary.FailedFiles `
                $summary.Errors
            Add-Measurement $rows $iteration $scenario "DocScanner: Inhalt lesen" `
                $crawler.DocScanner.ReadContentMilliseconds `
                $crawler.DocScanner.ReadContentCalls 0 $summary.ScannedFiles `
                $summary.FailedFiles $summary.Errors
            Add-Measurement $rows $iteration $scenario "Crawler: übrige Arbeit" `
                $otherCrawlerMilliseconds 1 $summary.ScannedFiles `
                $summary.ScannedFiles $summary.FailedFiles $summary.Errors
        }

        $indexedPaths = $database.GetPathsUnder($normalizedRoot)
        $getManyTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $null = $database.GetMany($indexedPaths)
        $getManyTimer.Stop()
        $searchTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $searchResults = $database.Search($SearchQuery, 100, $null)
        $searchTimer.Stop()
        $deleteTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $database.RemoveBatch($indexedPaths)
        $deleteTimer.Stop()

        if (-not $isWarmup) {
            Add-Measurement $rows $iteration "Datenbank isoliert" `
                "DB Lesen: GetMany" $getManyTimer.Elapsed.TotalMilliseconds 1 `
                $indexedPaths.Count $lastScannedFiles
            Add-Measurement $rows $iteration "Datenbank isoliert" `
                "DB Suche: Search" $searchTimer.Elapsed.TotalMilliseconds 1 `
                $searchResults.Count $lastScannedFiles
            Add-Measurement $rows $iteration "Datenbank isoliert" `
                "DB Löschen: RemoveBatch" $deleteTimer.Elapsed.TotalMilliseconds 1 `
                $indexedPaths.Count $lastScannedFiles
        }

        if (($run % 10) -eq 0 -or $run -eq $totalRuns) {
            Write-Progress -Activity "Performance-Messung" `
                -Status "$run von $totalRuns Durchlaeufen" `
                -PercentComplete ([int](100 * $run / $totalRuns))
        }
    }
    Write-Progress -Activity "Performance-Messung" -Completed

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

    Write-Host ""
    Write-Host "Performance-Messung: PowerShell-Suchmaschine" -ForegroundColor Cyan
    Write-Host ("Scan-Root:       {0}" -f $normalizedRoot)
    Write-Host ("Messlaeufe:      {0} (plus {1} Warm-ups)" -f $Iterations, $WarmupRuns)
    Write-Host ("Dateien/Scan:    {0}" -f $lastScannedFiles)
    Write-Host ("SaveBatchSize:   {0}" -f $SaveBatchSize)
    Write-Host ("DB-Initialisierung (einmalig, nicht in Messwerten): {0:N2} ms" -f
        $initializationTimer.Elapsed.TotalMilliseconds)
    $scanMeasurements = @($rows | Where-Object { $_.Stage -eq "Crawler gesamt" })
    $failedFiles = [long]((
        $scanMeasurements | Measure-Object -Property FailedFiles -Sum
    ).Sum)
    $scanErrors = [long]((
        $scanMeasurements | Measure-Object -Property Errors -Sum
    ).Sum)
    Write-Host ("Fehlgeschlagene Dateien/Fehler in Messscans: {0}/{1}" -f
        $failedFiles, $scanErrors)
    Write-Host ""
    Write-Host "Zeiten je Durchlauf in ms; P95 ist das 95. Perzentil." `
        -ForegroundColor DarkGray

    $displayRows = Get-MeasurementSummary -Rows $rows |
        Sort-Object Szenario, Messpunkt |
        Select-Object Szenario, Messpunkt, N,
            @{Name = "Mittel"; Expression = { [Math]::Round($_.Mittel_ms, 2) }},
            @{Name = "Median"; Expression = { [Math]::Round($_.Median_ms, 2) }},
            @{Name = "P95"; Expression = { [Math]::Round($_.P95_ms, 2) }},
            @{Name = "SD"; Expression = { [Math]::Round($_.SD_ms, 2) }},
            @{Name = "Min"; Expression = { [Math]::Round($_.Min_ms, 2) }},
            @{Name = "Max"; Expression = { [Math]::Round($_.Max_ms, 2) }},
            @{Name = "% Crawler"; Expression = {
                if ($null -eq $_.Anteil_Crawler_prozent) {
                    "-"
                }
                else {
                    "{0:N1}" -f $_.Anteil_Crawler_prozent
                }
            }},
            @{Name = "ms/Aufruf"; Expression = {
                [Math]::Round($_.Mittel_je_Aufruf_ms, 4)
            }}
    $displayRows | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host ("Rohdaten: {0}" -f [System.IO.Path]::GetFullPath($CsvPath)) `
        -ForegroundColor Green
    Write-Host (
        "Hinweis: 'Crawler: übrige Arbeit' umfasst Dateisystem-Auflistung, " +
        "Metadaten, Steuerlogik und PowerShell-Overhead. " +
        "Dateisystem-Caches und externe Reader beeinflussen die Messung."
    ) -ForegroundColor DarkGray
}
finally {
    if ($null -ne $database) {
        $database.Dispose()
    }

    foreach ($suffix in @("", "-shm", "-wal", "-journal")) {
        $file = "$databasePath$suffix"
        if ([System.IO.File]::Exists($file)) {
            [System.IO.File]::Delete($file)
        }
    }
    if ([System.IO.Directory]::Exists($scratchDirectory)) {
        [System.IO.Directory]::Delete($scratchDirectory)
    }
}

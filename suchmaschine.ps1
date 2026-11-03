# Crawler-Modul laden (es lädt den DocScanner, das Modell und das Repository).
using module "./src/Crawler/Crawler.psm1"
using module "./src/Persistence/SqliteDateiRepository.psm1"

param(
    # Startordner für den Scan. Standardmäßig der Benutzerordner.
    [string]$RootPath = $HOME,

    # Zusätzliche absolute Ordnerpfade, die übersprungen werden.
    [string[]]$ExcludePath = @(),

    # Optionaler FTS5-Suchausdruck; ohne Wert wird nur gescannt.
    [string]$Query = "logisch",

    # Persistenter SQLite-Index.
    [string]$DatabasePath = (Join-Path $PSScriptRoot "data/index.sqlite3"),

    # Maximale Anzahl an Suchtreffern.
    [ValidateRange(1, 1000)]
    [int]$SearchLimit = 100
)

$database = Initialize-Database -DatabasePath $DatabasePath

try {
    # Crawler mit Standardeinstellungen erstellen.
    $crawler = [Crawler]::new()
    $crawler.Repository = $database
    $crawler.ExcludedPaths = $ExcludePath

    # Optional: Fortschritt bei großen Scans ausgeben
    $crawler.ProgressOutput = $true
    $crawler.ProgressInterval = 1000
    $crawler.VerboseOutput = $false

    # Dauer des Scans messen.
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Startordner rekursiv durchsuchen.
    $crawler.ScanFolder($RootPath)

    # Zeitmessung nach dem Scan beenden.
    $stopwatch.Stop()

    # Zusammenfassung des Scans ausgeben.
    $crawler.GetSummary() | Format-List | Out-Host

    # Fehler, gruppiert nach dem Schritt, in dem sie aufgetreten sind.
    if ($crawler.Errors.Count -gt 0) {
        $crawler.Errors |
            Group-Object Phase |
            Select-Object @{ Name = "Phase"; Expression = { $_.Name } }, Count |
            Format-Table -AutoSize |
            Out-Host
    }

    Write-Host "Database: $DatabasePath"
    Write-Host "Supported content types: $($crawler.DocScanner.GetSupportedExtensions() -join ', ')"
    Write-Host "Scan duration: $($stopwatch.Elapsed.TotalSeconds.ToString('F3')) seconds"

    if (-not [string]::IsNullOrWhiteSpace($Query)) {
        $results = @(Search-Query -Database $database -Query $Query -Limit $SearchLimit)
        if ($results.Count -eq 0) {
            Write-Warning (
                "Keine Treffer fuer '{0}'. Die Volltextsuche findet indexierte " +
                "Woerter/Phrasen, keine beliebigen Teilzeichenketten. Pruefe " +
                "Suchbegriff, Scan-Ordner und ob passende Reader Inhalte lesen konnten." -f
                $Query
            )
        }
        else {
            $results | ForEach-Object {
                [PSCustomObject]@{
                    Pfad    = $_.File.Path
                    Treffer = $_.Snippet
                    Score   = $_.Score
                }
            } | Format-List | Out-Host
        }
    }
}
finally {
    $database.Dispose()
}

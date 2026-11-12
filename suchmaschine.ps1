# Crawler-Modul und SQLite-Repository laden.
using module "./src/Crawler/Crawler.psm1"
using module "./src/Persistence/SqliteDateiRepository.psm1"

# CmdletBinding sorgt dafür, dass unbekannte oder falsch geschriebene
# Parameter einen Fehler auslösen, statt still ignoriert zu werden.
[CmdletBinding()]
param(
    # Startordner für den Scan. Standardmäßig der Benutzerordner.
    [string]$RootPath = (Join-Path $HOME ""),

    # Zusätzliche absolute Ordnerpfade, die übersprungen werden.
    [string[]]$ExcludePath = @(),

    # Optionaler FTS5-Suchausdruck; ohne Wert wird nur gescannt.
    [string]$Query = "ist",

    # Persistenter SQLite-Index.
    [string]$DatabasePath = (Join-Path $PSScriptRoot "data/index.sqlite3"),

    # Maximale Anzahl an Suchtreffern.
    [ValidateRange(1, 1000)]
    [int]$SearchLimit = 100,

    # Suchbereich: Dateiname, extrahierter Dateiinhalt oder beides.
    [ValidateSet("FileName", "Content", "Both")]
    [string]$SearchMode = "Both"
)

# Der Crawler öffnet die Datenbank unter DatabasePath selbst. Nur so kann er
# einen eigenen Schreib-Thread starten, der speichert, während weiter gelesen
# wird. Ein über $crawler.Repository übergebenes Repository wird dagegen im
# Hauptthread beschrieben.
$crawler = [Crawler]::new()
$crawler.DatabasePath = $DatabasePath
$crawler.ExcludedPaths = $ExcludePath

# Optional: Fortschritt bei großen Scans ausgeben.
$crawler.ProgressOutput = $true
$crawler.ProgressInterval = 1000
$crawler.VerboseOutput = $false

try {
    # Dauer des Scans messen.
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $crawler.ScanFolder($RootPath)
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

    # Videos werden nach dem Scan im Hintergrund gelesen, auf Fotos werden
    # dort die Objekte erkannt; alle übrigen Inhalte sind bereits im Index.
    # Das Skript wartet darauf, weil Dispose() die Verarbeitung sonst
    # abbrechen würde (Abgebrochenes holt der nächste Scan nach).
    $pending = $crawler.GetBackgroundPending()

    if ($pending -gt 0) {
        Write-Host "Processing $pending file(s) in the background (videos, objects in photos) ..."
        $backgroundWatch = [System.Diagnostics.Stopwatch]::StartNew()

        while (-not $crawler.WaitForBackground(5000)) {
            Write-Host "  remaining: $($crawler.GetBackgroundPending())"
        }

        Write-Host (
            "Background done: {0} read, {1} failed, {2:F1} seconds" -f
            $crawler.BackgroundCompleted,
            $crawler.BackgroundFailed,
            $backgroundWatch.Elapsed.TotalSeconds
        )
    }

    # Gesucht wird über die Datenbank des Crawlers, solange sie noch offen
    # ist; Dispose() im finally-Block schließt sie.
    if (-not [string]::IsNullOrWhiteSpace($Query)) {
        $results = @(
            Search-Query -Database $crawler.Repository -Query $Query `
                -Limit $SearchLimit -SearchMode $SearchMode
        )
        if ($results.Count -eq 0) {
            # Klammern nötig: -f bindet stärker als +, sonst würde nur der
            # letzte Teil formatiert.
            Write-Warning ((
                "Keine Treffer fuer '{0}'. Die Volltextsuche findet indexierte " +
                "Woerter/Phrasen, keine beliebigen Teilzeichenketten. Pruefe " +
                "Suchbegriff, Scan-Ordner und ob passende Reader Inhalte lesen konnten."
            ) -f $Query)
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
    # Schließt Worker, Schreib-Thread, Hintergrundverarbeitung und die
    # Datenbank.
    $crawler.Dispose()
}

# Crawler-Modul laden (es lädt den DocScanner, das Modell und das Repository).
using module "./src/Crawler/Crawler.psm1"

param(
    # Startordner für den Scan. Standardmäßig der Benutzerordner.
    [string]$RootPath = $HOME,

    # Zusätzliche absolute Ordnerpfade, die übersprungen werden.
    [string[]]$ExcludePath = @()
)

# Crawler mit Standardeinstellungen erstellen.
$crawler = [Crawler]::new()
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

Write-Host "Supported content types: $($crawler.DocScanner.GetSupportedExtensions() -join ', ')"
Write-Host "Scan duration: $($stopwatch.Elapsed.TotalSeconds.ToString('F3')) seconds"

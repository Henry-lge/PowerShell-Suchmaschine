# Crawler-Modul laden (es lädt den DocScanner, das Modell und das Repository).
using module "./src/Crawler/Crawler.psm1"
using module "./src/Persistence/LuceneDateiRepository.psm1"

param(
    # Startordner für den Scan. Standardmäßig der Benutzerordner.
    [string]$RootPath = $HOME,

    # Zusätzliche absolute Ordnerpfade, die übersprungen werden.
    [string[]]$ExcludePath = @(),

    # Verzeichnis für die automatisch installierten Lucene.Net-DLLs.
    [string]$LuceneAssemblyPath = (Join-Path $PSScriptRoot "lib/Lucene.Net"),

    # Persistenter Lucene-Index.
    [string]$IndexPath = (Join-Path $PSScriptRoot "data/index")
)

& (Join-Path $PSScriptRoot "src/Persistence/Install-LuceneNet.ps1") `
    -Destination $LuceneAssemblyPath

# Crawler mit Standardeinstellungen erstellen.
$crawler = [Crawler]::new()
$crawler.ExcludedPaths = $ExcludePath
try {
    $repository = [LuceneDateiRepository]::new(
        $IndexPath,
        $LuceneAssemblyPath
    )
}
catch {
    throw "Lucene repository could not be initialized: $($_.Exception.Message)"
}
$crawler.Repository = $repository

# Optional: Fortschritt bei großen Scans ausgeben
$crawler.ProgressOutput = $true
$crawler.ProgressInterval = 1000
$crawler.VerboseOutput = $false

# Dauer des Scans messen.
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    # Startordner rekursiv durchsuchen.
    $crawler.ScanFolder($RootPath)
}
finally {
    # Indexwriter und Dateisperren zuverlässig freigeben.
    if ($null -ne $repository) {
        $repository.Dispose()
    }
    $stopwatch.Stop()
}

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

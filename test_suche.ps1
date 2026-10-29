using module "./src/Crawler/Crawler.psm1"
using module "./src/Persistence/SqliteDateiRepository.psm1"

param(
    [string]$RootPath = (Join-Path $HOME "Documents"),
    [string]$Query = "Coulouris",
    [string]$DatabasePath = (Join-Path $PSScriptRoot "data/index.sqlite3")
)

$database = Initialize-Database -DatabasePath $DatabasePath

try {
    $crawler = [Crawler]::new()
    $crawler.Repository = $database
    $crawler.ProgressOutput = $true
    $crawler.ProgressInterval = 1000
    $crawler.ScanFolder($RootPath)

    $crawler.GetSummary() | Format-List

    $results = @(Search-Query -Database $database -Query $Query)
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
        } | Format-List
    }
}
finally {
    $database.Dispose()
}

using module "./src/Persistence/SqliteDateiRepository.psm1"

param(
    [string]$Query = $,
    [string]$DatabasePath = "$PSScriptRoot/data/index.sqlite3",
    [int]$Limit = 100,
    [string]$Extension
)

# Datenbank initialisieren
$database = Initialize-Database -DatabasePath $DatabasePath

try {
    # Datenbanksuche über die bestehende Schnittstelle
    $results = @(Search-Query `
        -Database $database `
        -Query $Query `
        -Limit $Limit `
        -Extension $Extension)

    # Ergebnisse ausgeben
    if ($results.Count -eq 0) {
        Write-Host "Keine Treffer gefunden."
    }
    else {
        foreach ($result in $results) {
            [PSCustomObject]@{
                Pfad    = $result.File.Path
                Treffer = $result.Snippet
                Score   = $result.Score
            }
        }
    }
}
finally {
    # Datenbankverbindung schließen
    $database.Dispose()
}

#requires -Version 7.2

using module "./src/Persistence/SqliteDateiRepository.psm1"

param(
    [string]$DatabasePath = (Join-Path $PSScriptRoot "data/search.sqlite3")
)

$database = Initialize-Database -DatabasePath $DatabasePath
try {
    Write-Host "SQLite database is ready: $DatabasePath"
}
finally {
    $database.Dispose()
}
Set-Location $PSScriptRoot

Write-Host "=========================================" -ForegroundColor Green
Write-Host "    Starte PowerShell-Suchmaschine...    " -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green

$csprojPath = "./src/GUI/FileSearcherApp.csproj"

if (Test-Path $csprojPath) {
    # Start der GUI
    dotnet run --project $csprojPath
} else {
    Write-Error "Konnte die Projektdatei unter '$csprojPath' nicht finden!"
}
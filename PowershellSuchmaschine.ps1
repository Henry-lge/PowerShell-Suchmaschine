Set-Location $PSScriptRoot

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "     Starte Avalonia GUI...              " -ForegroundColor Yellow
Write-Host "=========================================" -ForegroundColor Cyan

$csprojPath = "./src/GUI/FileSearcherApp.csproj"

if (Test-Path $csprojPath) {
    # Start der GUI
    dotnet run --project $csprojPath
} else {
    Write-Error "Konnte die Projektdatei unter '$csprojPath' nicht finden!"
}
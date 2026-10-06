Clear-Host
Write-Host "`n--- Dateisuche starten ---" -ForegroundColor Yellow
$searchPath = Read-Host "Suchpfad eingeben (z.B. . oder /home/user)"

# Das ist eine temporäre Variante fuer die Datei Suche. Diese soll dann mit der eigentlichen Schnittstelle ersetzt werden
# Wurde mit KI geschrieben !
if (-not (Test-Path $searchPath)) {
    Write-Host "Fehler: Pfad existiert nicht!" -ForegroundColor Red
    Start-Sleep -Seconds 2
    break
}

$searchTerm = Read-Host "Suchmuster (z.B. *.txt oder *bericht*)"

Write-Host "Suche läuft..." -ForegroundColor Yellow
$files = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    $foundPaths = [System.IO.Directory]::EnumerateFiles($searchPath, $searchTerm, [System.IO.SearchOption]::AllDirectories)
    foreach ($path in $foundPaths) {
        $fileInfo = [System.IO.FileInfo]::new($path)
        $files.Add([PSCustomObject]@{
            Name         = $fileInfo.Name
            Directory    = $fileInfo.DirectoryName
            SizeKB       = [Math]::Round($fileInfo.Length / 1KB, 2)
            LastModified = $fileInfo.LastWriteTime
        })
    }
} catch {
    Write-Warning "Hinweis: $_"
}

if ($files.Count -eq 0) {
    Write-Host "`nKeine Dateien gefunden." -ForegroundColor Yellow
} else {
    Write-Host "`nErgebnis ($($files.Count) Dateien gefunden):" -ForegroundColor Green
    $files | Format-SpectreTable
}

Write-Host "`nDrücke eine beliebige Taste, um ins Menü zurückzukehren..." -ForegroundColor DarkGray
[Console]::ReadKey($true) | Out-Null
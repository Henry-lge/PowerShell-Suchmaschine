$ModuleName = "Suchmachiene.Datenbank"
$ModuleDir = "$PSScriptRoot/$ModuleName"

Write-Host "==> Initialisiere Projektstruktur für $ModuleName..." -ForegroundColor Cyan

$folders = @("$ModuleDir", "$ModuleDir/Classes", "$ModuleDir/Public", "$ModuleDir/Private")
foreach ($folder in $folders) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
}

$ManifestPath = "$ModuleDir/$ModuleName.psd1"
if (Test-Path $ManifestPath) {
    Remove-Item -Path $ManifestPath -Force
}

New-ModuleManifest -Path $ManifestPath `
    -RootModule "$ModuleName.psm1" `
    -FunctionsToExport @('Initialize-Datenbank', 'Register-File') `
    -ModuleVersion '1.0.0'

Write-Host "==> Setup erfolgreich abgeschlossen!" -ForegroundColor Green
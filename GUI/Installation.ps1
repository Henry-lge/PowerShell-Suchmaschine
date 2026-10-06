if (-not (Get-Module -ListAvailable -Name "PwshSpectreConsole")) {
    Write-Host "Installiere PwshSpectreConsole..." -ForegroundColor Cyan
    Install-Module -Name "PwshSpectreConsole" -Scope CurrentUser -Force
}
if (-not (Get-Module -ListAvailable -Name "PwshSpectreConsole")) {
    Write-Host "Installiere PwshSpectreConsole..." -ForegroundColor Cyan
    Install-Module -Name "PwshSpectreConsole" -Scope CurrentUser -Force
}
if (-not (Get-Module -ListAvailable -Name "WriteAscii")) {
    Write-Host "Installiere WriteAscii..." -ForegroundColor Cyan
    Install-Module WriteAscii -Scope CurrentUser -Force
}
. "$PSScriptRoot\Installation.ps1"
Import-Module "PwshSpectreConsole"

. "$PSScriptRoot\Stylesheet.ps1"

do {
    Clear-Host
    Write-Seperator
   'Dateisuche' | Write-Ascii -ForegroundColor green
    Write-Seperator

    $choice = Read-SpectreSelection -Title "Hauptmenü - Bitte wähle eine Option:" -Choices @(
        "Dateien suchen (nach Name/Muster)",
        "Beenden"
    )

    switch ($choice) {
        "Dateien suchen (nach Name/Muster)" {
            . "$PSScriptRoot\DateiSuchenGUI.ps1"
        }
    }
} until ($choice -eq "Beenden")
Clear-Host


$counter = 0

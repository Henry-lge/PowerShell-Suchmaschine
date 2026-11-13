
Set-Location $PSScriptRoot

# Fehlerdialog für alle Plattformen
function Show-ErrorDialog {
    param(
        [string]$Title = "Fehler",
        [string]$Message
    )

    if ($IsWindows) {
        try {
            Add-Type -AssemblyName PresentationFramework -ErrorAction Stop

            [System.Windows.MessageBox]::Show(
                $Message,
                $Title,
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
        }
        catch {
            Write-Host "$Title : $Message" -ForegroundColor Red
        }
    }
    elseif ($IsLinux) {
        if (Get-Command zenity -ErrorAction SilentlyContinue) {
            & zenity --error --title="$Title" --text="$Message"
        }
        elseif (Get-Command kdialog -ErrorAction SilentlyContinue) {
            & kdialog --error "$Message" --title "$Title"
        }
        else {
            Write-Host "$Title : $Message" -ForegroundColor Red
        }
    }
    elseif ($IsMacOS) {
        try {
            $escapedMessage = $Message.Replace('"', '\"')
            $escapedTitle = $Title.Replace('"', '\"')

            & osascript -e "display dialog `"$escapedMessage`" with title `"$escapedTitle`" buttons {`"OK`"} default button 1 with icon stop" 2>$null
        }
        catch {
            Write-Host "$Title : $Message" -ForegroundColor Red
        }
    }
    else {
        Write-Host "$Title : $Message" -ForegroundColor Red
    }
}

Write-Host "=========================================" -ForegroundColor Green
Write-Host "    Starte PowerShell-Suchmaschine...    " -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green


# Betriebssystem erkennen
if ($IsWindows) {
    $platform = "Windows"
}
elseif ($IsLinux) {
    $platform = "Linux"
}
elseif ($IsMacOS) {
    $platform = "macOS"
}
else {
    $platform = "Unbekannt"
}

Write-Host "Betriebssystem: $platform" -ForegroundColor Cyan


# .NET SDK Version prüfen
$requiredVersion = [version]"10.0"

try {
    $dotnetCommand = Get-Command dotnet -ErrorAction Stop
    $dotnetVersionOutput = & $dotnetCommand.Source --version 2>$null

    if ($LASTEXITCODE -ne 0) {
        throw ".NET SDK konnte nicht ausgeführt werden."
    }

    $installedVersion = [version]$dotnetVersionOutput

    Write-Host ".NET SDK Version: $installedVersion" -ForegroundColor Cyan

    if ($installedVersion -lt $requiredVersion) {
        throw "Mindestens .NET SDK 10.0 erforderlich. Installiert: $installedVersion"
    }

    Write-Host ".NET SDK Prüfung erfolgreich!" -ForegroundColor Green
}
catch {
    Show-ErrorDialog `
        -Title ".NET SDK Fehler" `
        -Message "$($_.Exception.Message)`n`nBitte installiere .NET SDK 10.0 oder höher:`nhttps://dotnet.microsoft.com/download/dotnet/10.0"

    exit 1
}


# Projektdatei prüfen
$csprojPath = Join-Path $PSScriptRoot "src/GUI/FileSearcherApp.csproj"

if (Test-Path $csprojPath) {
    Write-Host ""
    Write-Host "Starte GUI..." -ForegroundColor Green

    dotnet run --project $csprojPath
    exit $LASTEXITCODE
}
else {
    Show-ErrorDialog `
        -Title "Projektdatei nicht gefunden" `
        -Message "Die Projektdatei konnte nicht gefunden werden:`n`n$csprojPath"

    exit 1
}

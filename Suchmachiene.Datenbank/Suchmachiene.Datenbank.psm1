# zuerst Klassen laden
Get-ChildItem -Path "$PSScriptRoot/Classes" -Filter "*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
    . $_.FullName
}

# 2. dann Funktionen laden
Get-ChildItem -Path "$PSScriptRoot/Public", "$PSScriptRoot/Private" -Filter "*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
    . $_.FullName
}
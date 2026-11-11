Write-Output "Ich bin ein Powershell skript :DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
class Data {
    [string]$Name
    [string]$Path
    [string]$Extension
    [string]$Size
    [string]$CreationTimeUtc
    [string]$LastWriteTimeUtc
}

$dateien = @()
# Objekt erstellen und Eigenschaften zuweisen
$datei1 = [Data]::new()
    $datei1.Name = "Datei 1"
    $datei1.Path = "Desktop/Datei1.txt"
    $datei1.Extension = ".txt"
    $datei1.Size = "123 KB"
    $datei1.CreationTimeUtc = "2023-01-01 10:00:00"
    $datei1.LastWriteTimeUtc = "2023-01-01 10:30:00"

$datei2 = [Data]::new()
    $datei2.Name = "Datei 2"
    $datei2.Path = "Desktop/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/Datei2.txt"
    $datei2.Extension = ".txt"
    $datei2.Size = "456 KB"
    $datei2.CreationTimeUtc = "2023-02-01 11:00:00"
    $datei2.LastWriteTimeUtc = "2023-04-01 11:30:00"    

$datei3 = [Data]::new()
    $datei3.Name = "Datei 3"
    $datei3.Path = "Desktop/Datei3.txt"
    $datei3.Extension = ".txt"
    $datei3.Size = "789 KB"
    $datei3.CreationTimeUtc = "2023-03-01 12:00:00"
    $datei3.LastWriteTimeUtc = "2023-05-01 12:30:00"


$dateien += $datei1
$dateien += $datei2
$dateien += $datei3

# Tabellarische Ausgabe  -> längste Name und Path ermitteln; Tabellarische Ansicht Nick
Write-Output "Ich bin ein Powershell skript :DDD"
foreach ($d in $dateien) {
    Write-Output "$($d.Name) $($d.Extension) | $($d.Path)"
} 


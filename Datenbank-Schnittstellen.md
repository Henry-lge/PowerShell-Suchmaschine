# Datenbank

## Klassen

### File
```
class File {
    path
    name
    size
    lastIndexed
    md5Hash
    isIndexed

    Search() # in der Datei
}
```
### Folder
```
class Folder {
    path
    name
    size
    files # array von klassen File

    getFolders() # gibt nen Array mit den Klassen Folder zurück

    getAllFiles # gibt nen Array mit allen files auch in unter ordnern zurück

    indexAll() # indexiert alle files

    Search() # sucht in dateien in den ordner, mit parameter kann man dann auch unterordner durchsuchen


}
```


# Schnittstellen

## 1. Get-File
Akzeptiert einen Pfad als Parameter und gibt ein Datei-Objekt (File-Objekt) zurück. Dieses enthält alle wichtigen Metadaten, wie zum Beispiel den Indizierungsstatus, den Zeitpunkt des letzten Zugriffs bzw. der letzten Änderung sowie den zugehörigen Hash-Wert.

```powershell
Get-File ./File.txt
```

## 2. Get-Folder
Akzeptiert einen Pfad als Parameter und gibt ein Ordner-Objekt (Folder-Objekt) zurück. Neben den Standardinformationen stellt dieses Objekt direkt nützliche Zusatzfunktionen zur Verfügung – wie etwa eine integrierte Suchmethode direkt in der Klasse.

```powershell
$folder = Get-Folder ./Folder
$files = $folder.Search(regex="*.txt")
```

## 3. Search
Nimmt entweder einen Pfad oder ein Ordner-Objekt als Parameter entgegen. Ein zusätzlicher Parameter legt fest, ob die Suche ausschließlich auf die Dateinamen beschränkt ist oder auch den Inhalt der Dateien durchsucht. 

Die Funktion gibt ein Such-Objekt zurück, das alle Details zu den Fundstellen sowie Methoden für die erweiterte Steuerung enthält. Das Skript stoppt beispielsweise nach 100 Treffern; über `SearchNext(100)` können flexibel weitere Treffer nachgeladen werden. Zudem werden Regex-Ausschlüsse (`exclude`) unterstützt.

```powershell
$searchResult = Search ./Folder --regex '*.txt' --sort 'size' --limit 100
$searchResult = $searchResult.SearchNext(100, filter="*.zip")
```

## Modul Aufbau

Modulname ``Suchmachiene.Datenbank`` 

Dateien in ``Suchmachiene.Datenbank/Classes`` sind alle Klassen, diese können auch außerhalb des Modules genutzt werden.

Dateien in ``Suchmachiene.Datenbank/Private`` sind nur intern also innerhalb des Modules nutzbar. Zum beispiel für uns zur Verbindung zur Datenbank oder außlagerung von Logikbausteinen.

Dateien in ``Suchmachiene.Datenbank/Private`` sind nur außerhalb nutzbar, diese können die Anderen Teams/Module importieren und voll nutzen. 

Beispiel:
```
# Datenbank-Modul importieren
Import-Module ./Suchmachiene.Datenbank/Suchmachiene.Datenbank.psd1 -Force

# Jetzt können alle unsere funktionen in Public genutze werden

Register-File ./Beispiel.txt
#oder
Get-ChildItem -Path "." -File -Recurse | Register-File

``` 

Die Datei ``Suchmachiene.Datenbank.psm1`` beschreibt das modul.
Die Datei ``Suchmachiene.Datenbank.psd1`` wird mit den Script ``Setup-Datenbank.ps1`` automatisch erstellt. 
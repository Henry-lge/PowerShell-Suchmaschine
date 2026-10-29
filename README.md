# PowerShell-Suchmaschine

Eine dateibasierte Volltextsuche: Das Programm durchläuft Ordner rekursiv,
erfasst Dateimetadaten und liest - sofern ein passender Reader verfügbar ist -
den Text aus unterstützten Dateien aus. Ein Repository speichert den Index.
Für dauerhafte Speicherung und Volltextsuche mit SQLite siehe
[DATABASE.md](./DATABASE.md).
Eine ausführliche Erklärung der Klassen, Reader und Abläufe steht in der
[Code- und Architekturführung](./CODE_GUIDE.md).

## Voraussetzungen

- PowerShell 7.2 oder neuer
- Für SQLite: Internetzugriff beim erstmaligen Einrichten der SQLite-Laufzeit
  (NuGet-Pakete werden heruntergeladen)
- Für bestimmte Archivformate: `tar` oder 7-Zip, abhängig vom Format und den
  installierten Programmen

## Start

Im Projektverzeichnis:

```powershell
pwsh -File ./suchmaschine.ps1
```

Standardmäßig wird das Benutzerverzeichnis (`$HOME`) gescannt. Ein anderer
Startordner und zusätzliche auszuschließende absolute Ordnerpfade lassen sich
als Parameter übergeben:

```powershell
pwsh -File ./suchmaschine.ps1 `
    -RootPath "$HOME/Documents" `
    -ExcludePath @("$HOME/Documents/Private", "$HOME/Documents/Backup")
```

Das Startskript zeigt nach dem Scan eine Zusammenfassung, Fehler nach
Verarbeitungsphase, die verfügbaren Dateiendungen und die Laufzeit an.
Ausgeschlossene Ordnernamen sind standardmäßig unter anderem `.git`,
`node_modules`, `.venv` und `__pycache__`.

> **Wichtig:** Das Startskript verwendet standardmäßig ein
> `InMemoryDateiRepository`. Der Index bleibt daher nur bis zum Ende der
> PowerShell-Sitzung erhalten und dieses Skript bietet selbst keine
> Suchabfrage. Für einen persistenten Index muss der `Crawler` wie in
> [DATABASE.md](./DATABASE.md) gezeigt an `SqliteDateiRepository` angeschlossen
> werden.

## Ablauf eines Scans

1. Der `Crawler` durchläuft Ordner iterativ und erfasst Metadaten wie Pfad,
   Größe, Endung und Änderungszeit.
2. Der Crawler vergleicht den Zeitstempel `LastWriteTimeUtc` mit dem
   Repository. Unveränderte Dateien werden nicht erneut gelesen.
3. Für neue oder geänderte Dateien entscheidet der `DocScanner`, ob ein
   verfügbarer Reader existiert und die Datei höchstens 10 MB groß ist.
4. Der Reader extrahiert Text. Der Crawler schreibt die Datei in Batches ins
   Repository und meldet Fehler mit Phase und Pfad.
5. Bei Ordnerscans werden nicht mehr vorhandene Dateien aus dem Repository
   entfernt. Dateien in Ordnern, die wegen eines Auflistungsfehlers nicht
   geprüft werden konnten, gelten nicht als gelöscht.

Cloud-Platzhalter (zum Beispiel „Dateien bei Bedarf“) werden standardmäßig
nicht heruntergeladen. Mit der Option `ReadCloudOnlyFiles` kann dieses
Verhalten für einen selbst erstellten Crawler geändert werden. Symbolischen
Ordnerlinks folgt der Crawler standardmäßig nicht.

Der Vergleich auf Änderungen basiert auf dem Änderungszeitstempel. Eine
Ausnahme ist ein Cloud-Platzhalter, der seit dem letzten Scan heruntergeladen
wurde: Er wird erneut gelesen, auch wenn sein Zeitstempel gleich geblieben ist.
Wird ein anderer Dateiinhalt geändert, ohne dass sich der Zeitstempel ändert,
erkennt der Crawler die Änderung nicht.

Das Flussdiagramm und die schrittweise Erklärung der Scan-Logik stehen in der
[Code- und Architekturführung](./CODE_GUIDE.md#3-ein-ganzer-ordnerscan-als-flussdiagramm).

## Unterstützte Inhalte

Die verfügbaren Endungen hängen von den registrierten Readern ab. Mit
`$crawler.DocScanner.GetReaderOverview()` lassen sich in PowerShell Reader,
Verfügbarkeit und Endungen anzeigen. Grundsätzlich sind Reader für folgende
Gruppen vorhanden:

- Klartext, Markup und Daten: Text, Markdown, HTML/XML, CSV/TSV, JSON, YAML,
  INI/CFG, TOML, Untertitel, Kalender und Kontakte
- Office: moderne und ältere Word-, Excel- und PowerPoint-Dateien, RTF,
  OpenDocument und Apple-iWork-Dateien
- EPUB sowie E-Mail-Dateien im EML- und MSG-Format
- Archive: ZIP sowie - abhängig von verfügbaren Systemprogrammen - TAR,
  komprimierte TAR-Archive, 7z und RAR. Archive werden nur aufgelistet, nicht
  entpackt; ihr Indextext besteht aus den enthaltenen Dateinamen.

Die Reader für PDF, Bilder/OCR sowie Audio- und Video-Metadaten sind derzeit
registriert, aber nicht verfügbar (`IsAvailable()` liefert `$false`). Diese
Dateien werden daher nicht inhaltlich indiziert. Dateien über 10 MB werden
ebenfalls nicht inhaltlich gelesen; Metadaten können trotzdem gespeichert
werden. Die aktuelle Größenbegrenzung ist über
`$crawler.DocScanner.MaxContentSizeBytes` änderbar.

## Projektstruktur

| Pfad | Aufgabe |
|---|---|
| [suchmaschine.ps1](./suchmaschine.ps1) | Einfacher Einstiegspunkt für einen Scan; verwendet standardmäßig den In-Memory-Speicher. |
| [src/Crawler/](./src/Crawler/) | Ordnerdurchlauf, Änderungs- und Lösch-Erkennung, Fehler und Scan-Zusammenfassung. |
| [src/DocScanner/](./src/DocScanner/) | Auswahl des Readers und Extraktion von Dateiinhalten. |
| [src/DocScanner/Readers/](./src/DocScanner/Readers/) | Format-spezifische Reader und gemeinsame Parser-Hilfen. |
| [src/Model/](./src/Model/) | Datei- und Scan-Fehlermodelle. |
| [src/Persistence/](./src/Persistence/) | Repository-Schnittstelle, In-Memory- und SQLite-Implementierung sowie SQLite-Laufzeitinstallation. |
| [src/Common/](./src/Common/) | Plattformgerechter Pfadvergleich und Erkennung von Cloud-Platzhaltern. |
| [tests/](./tests/) | Pester-Tests für die SQLite-Implementierung. |
| `lib/sqlite/` | Lokal abgelegte SQLite-.NET- und native Laufzeitdateien; wird bei Bedarf eingerichtet und nicht versioniert. |

Die Architektur trennt Dateisystemdurchlauf, Inhaltsextraktion und Speicherung.
Der Crawler hängt nur von der Schnittstelle `DateiRepository` ab. So kann
derselbe Ablauf mit dem In-Memory- oder dem SQLite-Repository arbeiten.

Für Klassendiagramm, Reader-Details, Hilfsparser, Fehlerpfade und ein Beispiel
zum Hinzufügen eines Readers siehe
[CODE_GUIDE.md](./CODE_GUIDE.md).

## Fehler und Scan-Ergebnisse

`Crawler.Errors` enthält typisierte `ScanError`-Objekte mit Pfad, Nachricht,
Zeitpunkt und Phase (`Folder`, `Metadata`, `Content` oder `Repository`).
`GetSummary()` liefert Zähler für Ordner, Dateien, gelesene/übersprungene
Inhalte, Löschungen und Fehler. Fehlerhafte Dateien werden nicht als
erfolgreich indiziert gespeichert und können bei einem späteren Scan erneut
versucht werden.

## Entwicklung und Tests

Die Tests benötigen Pester und PowerShell 7.2 oder neuer:

```powershell
Invoke-Pester ./tests/SqliteDateiRepository.Tests.ps1
```

Die SQLite-Tests decken Schema-Erstellung, Metadaten, Volltextsuche,
Aktualisierungen, Transaktionen, Synchronisierung, Persistenz und Fehler nach
dem Schließen des Repositories ab.

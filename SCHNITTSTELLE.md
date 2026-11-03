# Schnittstelle GUI ↔ Datenbank

Diese Schnittstelle verbindet die Avalonia-Oberfläche (C#) mit der SQLite-Suche (PowerShell).
Die GUI schickt einen Suchbegriff, die Datenbankseite liefert eine Trefferliste zurück.

- **Dateien:** `Invoke-GuiSearch.ps1`, `src/GUI/SearchBridge.cs`
- **Aufruf aus der GUI:** `MainWindow.axaml.cs` → `OnSearchClicked`
- **Vorgehen:** Pro Suche startet die GUI ein `pwsh`, sendet JSON über stdin und liest JSON von stdout.

---

## 1. Überblick

```
MainWindow (XAML + Code-Behind)
      │  SearchAsync(text)
      ▼
ISearchService  ◄── hilf die Sucheimplementierung von Suchenmethode abgrenzen
      ▼
PowerShellSearchService  (SearchBridge.cs)
      │  startet:  pwsh -File Invoke-GuiSearch.ps1 -DatabasePath <db>
      │  stdin  ◄── JSON-Anfrage
      │  stdout ──► JSON-Antwort
      ▼
Invoke-GuiSearch.ps1
      ├─ Namenssuche   → SQL LIKE auf files_metadata
      └─ Inhaltssuche  → Search-Query (FTS5) auf files_fts
      ▼
data/search.sqlite3
```

Die GUI kennt nur `ISearchService`. Die Implementierung lässt sich austauschen
(z. B. HTTP-Server oder direkter SQLite-Zugriff), ohne das Fenster zu ändern.

## 2. Dateien

| Datei | Zweck |
|---|---|
| `Invoke-GuiSearch.ps1` (Repo-Wurzel) | Nimmt JSON-Anfrage entgegen, sucht, gibt JSON zurück |
| `src/GUI/SearchBridge.cs` | `SearchHit`, `ISearchService`, `PowerShellSearchService`, `SearchBridge`, `SearchException` |
| `src/GUI/MainWindow.axaml.cs` | Ruft `SearchAsync` auf und füllt die Ergebnisliste |
| `src/GUI/MainWindow.axaml` | Layout: `SearchBox`, Button, `ResultsList` |
| `data/search.sqlite3` | Index (wird vom Crawler gefüllt, nicht im Git) |

## 3. Voraussetzungen

- PowerShell 7.2 oder neuer, `pwsh` muss im `PATH` liegen (`pwsh --version`).
  Unter Windows reicht `powershell.exe` (5.1) **nicht**.
- .NET SDK passend zum `.csproj` (aktuell `net10.0`).
- Gefüllte Datenbank `data/search.sqlite3` (siehe DATENBASE.md).
- Beim ersten Datenbankzugriff Internet (NuGet-Download der SQLite-Bibliotheken).

## 4. Dateisystem - Datenbank

Die Suche arbeitet auf dem Index, nicht direkt auf dem Dateisystem. Neue oder
geänderte Dateien werden erst nach einem erneuten Crawler-Lauf gefunden.

Der Datenbankpfad ist fest `data/search.sqlite3` in der Repo-Wurzel.

## 5. Starten und testen

**Schnittstelle ohne GUI testen** (in der Repo-Wurzel):

```in powershell
'{"query":"Inhalt","limit":5}'                | pwsh -NoProfile -File ./Invoke-GuiSearch.ps1
'{"query":"dateiname","mode":"name"}'         | pwsh -NoProfile -File ./Invoke-GuiSearch.ps1
'{"query":"*.dateierweiterung","limit":3}'    | pwsh -NoProfile -File ./Invoke-GuiSearch.ps1
```

Erwartet: eine JSON-Zeile mit `"ok":true`.

**GUI starten:**

```in powershell
cd src/GUI
dotnet run
```

oder Run Program.cs 

## 6. Suchmodi

Der Parameter `mode` steuert, wo gesucht wird.

| `mode` | Verhalten |
|---|---|
| `both` (Standard) | Erst Dateiname, dann Inhalt, Duplikate entfernt |
| `name` | Nur Dateiname (SQL `LIKE` auf `files_metadata.filename`) |
| `content` | Nur Inhalt (FTS5 über `Search-Query`) |

Regeln:

- **Name:** Mehrere Wörter sind UND-verknüpft. `*` und `?` sind Platzhalter
  (`*.txt`, `bericht*`). Ohne Platzhalter gilt "Name enthält das Wort".
- **Inhalt:** Jedes Wort wird als Phrase an FTS5 übergeben (Sonderzeichen wie
  `C++` oder `foo-bar` verursachen keine Syntaxfehler). Mit `prefix: true`
  wird per Wortanfang gesucht (`vorl` findet `Vorlesung`).
- Enthält der Suchtext `*` oder `?`, wird im Modus `both` die Inhaltssuche
  übersprungen.
- Der Inhalt wird nur gefunden, wenn ein Reader den Text extrahiert hat
  (PDF, Bilder u. a. sind derzeit nicht verfügbar).

## 7. Vertrag (JSON)

**Anfrage** (stdin):

```json
{ "query": "vorlesung", "limit": 100, "extension": ".pdf", "prefix": true, "mode": "both" }
```

| Feld | Typ | Pflicht | Bedeutung |
|---|---|---|---|
| `query` | string | ja | Suchtext |
| `limit` | int | nein | 1–1000, Standard 100 |
| `extension` | string | nein | Dateiendung, mit oder ohne Punkt |
| `prefix` | bool | nein | Wortanfangssuche im Inhalt |
| `mode` | string | nein | `both`, `name`, `content` |

**Antwort** (stdout, eine Zeile):

```json
{ "ok": true, "count": 1, "results": [
  { "path": "C:\\Users\\x\\Documents\\blabla.txt",
    "fileName": "blabla.txt",
    "extension": ".txt",
    "lastWriteUtc": "2026-11-03T10:00:00.0000000Z",
    "snippet": "... [und] was? ...",
    "score": 4.5,
    "matchedIn": "Inhalt" } ] }
```

Bei Fehlern: `{ "ok": false, "error": "..." }` (Exit-Code 1). Die GUI wandelt das
in eine `SearchException` um.

| Feld im JSON | Property in `SearchHit` | Hinweis |
|---|---|---|
| `path` | `Path` | Vollständiger Pfad |
| `fileName` | `FileName` | Dateiname mit Endung |
| `extension` | `Extension` | Kleingeschrieben, mit Punkt |
| `lastWriteUtc` | `LastWriteUtc` | UTC, zur Anzeige `.ToLocalTime()` |
| `snippet` | `Snippet` | Textausschnitt, Treffer in `[ ]`; leer bei Namenstreffern |
| `score` | `Score` | Relevanz (höher = besser); bei Namenstreffern 0 |
| `matchedIn` | `MatchedIn` | `Name` oder `Inhalt` |

**Wichtig:** Ändert man ein Feld, müssen `Invoke-GuiSearch.ps1` **und** der Record
`SearchHit` angepasst werden. Sonst bleibt das Feld in der GUI leer.

## 8. Bekannte Grenzen

- Jede Suche startet ein neues `pwsh` (ca. 0,5–2 s). Daher Suche auf Button/Enter,
  nicht bei jedem Tastendruck.
- Die Namenssuche liest `files_metadata` direkt (Spalten `path`, `filename`,
  `extension`, `last_write_time_utc_ticks`). Ändert sich das Schema, muss
  `Search-FileName` in `Invoke-GuiSearch.ps1` angepasst werden.
- `LIKE` ist nur für ASCII-Zeichen unabhängig von Groß-/Kleinschreibung.
- Neue Dateien erscheinen erst nach erneutem Crawler-Lauf.

---

# Anleitung: Anzeige der Ergebnisse (Fenster „Ergebnisse“) ändern

Diese Anleitung ist für alle, die das Aussehen der Trefferliste ändern.
**Die Suche selbst muss dafür nicht angefasst werden.**

## Wo liegt was?

| Was du ändern willst | Wo |
|---|---|
| Aussehen der Liste, Spalten, Farben, Schrift | `src/GUI/MainWindow.axaml` |
| Was in die Liste geschrieben wird | `src/GUI/MainWindow.axaml.cs` → `OnSearchClicked` |
| Text einer Zeile ohne Template | `SearchHit.ToString()` in `src/GUI/SearchBridge.cs` |
| Welche Daten ein Treffer hat | `SearchHit` in `SearchBridge.cs` (Felder siehe Tabelle oben) |

**Nicht ändern**, wenn du nur die Anzeige anpasst: `PowerShellSearchService` und `Invoke-GuiSearch.ps1`.

## Wie kommen die Daten in die Liste?

In `MainWindow.axaml.cs`:

```csharp
ResultsList.Items.Clear();                                    // Liste leeren
var hits = await _search.SearchAsync(SearchBox.Text ?? "");   // Suche, liefert SearchHit-Objekte
foreach (var hit in hits) ResultsList.Items.Add(hit);         // jeden Treffer eintragen
```

Wichtig:

- Die Liste enthält **`SearchHit`-Objekte**, keine fertigen Texte.
- Daneben schreibt der Code auch **normale Strings** hinein: `"Keine Treffer."` und
  `"Fehler: ..."`. Ein Template muss daher entweder nur für `SearchHit` gelten
  (siehe unten) oder beide Fälle behandeln.
- Ohne Template zeigt die Liste `SearchHit.ToString()`, z. B.
  `[Inhalt] blabla.txt — C:\Users\...\blabla.txt`.

